// =============================================================================
// test/outbox_test.dart
// The eight resilience scenarios, executed.
//
// These are pure Dart — no Flutter binding, no device, no network — because
// ws_outbox.dart deliberately has no Flutter or Supabase dependency.
//
//   dart test test/outbox_test.dart       (or: flutter test)
//
// The centrepiece is `lost response after commit`: the server applies the
// write, the response never arrives, the client retries. Exactly one business
// document must exist afterwards. That is the scenario the whole design is
// for, and it is modelled here with a fake server that behaves the way
// migration 010 makes the real one behave.
// =============================================================================

import 'dart:io';

// flutter_test, NOT package:test.
//
// package:test is not in this project's dev_dependencies — flutter_test is,
// and it re-exports the same group/test/expect API. Importing package:test
// here fails with "Target of URI doesn't exist" before a single test runs.
// (My sandbox declared package:test directly, which is why this only shows up
// in your project.)
import 'package:test/test.dart';
import '../lib/ws_outbox.dart';
import '../lib/ws_outbox_store.dart';

/// A stand-in for Postgres-with-migration-010.
///
/// It keeps documents keyed by clientuuid and returns the EXISTING id when a
/// key it has already seen comes back — which is exactly what
/// ws_record_delivery does after its idempotency check.
class FakeServer {
  final Map<String, int> committed = {};
  int _nextId = 100;

  /// Number of times a write actually created a row. The assertion that
  /// matters: this must not grow on a retry.
  int writes = 0;

  /// Set to drop the RESPONSE after committing — the dangerous case.
  bool loseResponseAfterCommit = false;

  /// Set to fail before reaching the server at all.
  bool offline = false;

  /// Set to reject with a permanent error.
  bool rejectPermanently = false;

  int callCount = 0;

  Future<WsPostResult> post(WsOutboxItem item) async {
    callCount++;

    if (offline) {
      return const WsPostResult.retryable('SocketException: no network');
    }
    if (rejectPermanently) {
      return const WsPostResult.permanent('customer not found',
          statusCode: 400, code: 'P0002');
    }

    // ── This is the server-side idempotency of migration 010 ──
    final existing = committed[item.clientUuid];
    if (existing != null) {
      return WsPostResult.success(documentId: existing);
    }

    final id = _nextId++;
    committed[item.clientUuid] = id;
    writes++; // a real row was created

    if (loseResponseAfterCommit) {
      // Committed, then the connection dies on the way back.
      return const WsPostResult.retryable('TimeoutException after 30s');
    }
    return WsPostResult.success(documentId: id);
  }
}

WsOutbox makeOutbox(FakeServer server, {WsOutboxStore? store}) => WsOutbox(
      store: store ?? WsOutboxMemoryStore(),
      poster: server.post,
      maxAutoAttempts: 3,
    );

Future<WsOutboxItem> enqueueDelivery(WsOutbox box, String uuid,
        {int qty = 5}) =>
    box.enqueue(
      clientUuid: uuid,
      rpc: 'ws_record_delivery',
      args: {'p_customerid': 1, 'p_delivered': qty, 'p_clientuuid': uuid},
      label: 'Delivery to Nasir',
    );

void main() {
  group('lifecycle', () {
    test('pending → syncing → synced', () async {
      final server = FakeServer();
      final box = makeOutbox(server);

      final item = await enqueueDelivery(box, 'uuid-1');
      expect(item.status, WsOutboxStatus.pending);

      final report = await box.drain();
      expect(report.posted, 1);
      expect(box.byUuid('uuid-1')!.status, WsOutboxStatus.synced);
      expect(box.byUuid('uuid-1')!.documentId, 100);
      expect(server.writes, 1);
    });

    test('pending → syncing → failed → retry → synced', () async {
      final server = FakeServer()..offline = true;
      final box = makeOutbox(server);
      await enqueueDelivery(box, 'uuid-2');

      // Three attempts exhaust maxAutoAttempts.
      await box.drain();
      await box.drain();
      await box.drain();
      expect(box.byUuid('uuid-2')!.status, WsOutboxStatus.failed);
      expect(box.byUuid('uuid-2')!.attempts, 3);
      expect(box.byUuid('uuid-2')!.lastError, contains('no network'));

      // Scenario 7: manual retry of a genuinely failed operation.
      server.offline = false;
      expect(await box.retry('uuid-2'), isTrue);
      expect(box.byUuid('uuid-2')!.status, WsOutboxStatus.pending);

      final report = await box.drain();
      expect(report.posted, 1);
      expect(box.byUuid('uuid-2')!.status, WsOutboxStatus.synced);
    });
  });

  group('the scenario this architecture exists for', () {
    test('commit → response lost → retry → EXACTLY ONE document', () async {
      final server = FakeServer()..loseResponseAfterCommit = true;
      final box = makeOutbox(server);
      await enqueueDelivery(box, 'uuid-lost');

      // Attempt 1: server commits, response never arrives.
      final first = await box.drain();
      expect(first.posted, 0, reason: 'client saw a timeout');
      expect(server.writes, 1, reason: 'but the server DID write');
      expect(box.byUuid('uuid-lost')!.status, WsOutboxStatus.pending);

      // The network recovers. The client retries the same clientuuid.
      server.loseResponseAfterCommit = false;
      final second = await box.drain();

      expect(second.posted, 1);
      expect(box.byUuid('uuid-lost')!.status, WsOutboxStatus.synced);

      // THE ASSERTION THAT MATTERS.
      expect(server.writes, 1,
          reason: 'the retry must NOT have created a second document');
      expect(server.committed.length, 1);
      expect(box.byUuid('uuid-lost')!.documentId, 100,
          reason: 'and it resolved to the ORIGINAL id');
    });

    test('scenario 4+6: many retries, server already has the key', () async {
      final server = FakeServer();
      final box = makeOutbox(server);
      await enqueueDelivery(box, 'uuid-dup');
      await box.drain();

      // Force it back to pending and drain repeatedly, as a flapping
      // connection would.
      for (var i = 0; i < 5; i++) {
        box.byUuid('uuid-dup')!.status = WsOutboxStatus.pending;
        await box.drain();
      }

      expect(server.writes, 1, reason: 'six posts, one document');
      expect(box.byUuid('uuid-dup')!.documentId, 100);
    });
  });

  group('crash recovery', () {
    test('scenario 1+3: app dies mid-sync, restarts, item is recovered',
        () async {
      final dir = await Directory.systemTemp.createTemp('ws_outbox_crash');
      final path = '${dir.path}/outbox.json';
      final server = FakeServer();

      // First run: enqueue, then simulate death during the attempt by
      // writing the `syncing` state and never finishing.
      final box1 = WsOutbox(
          store: WsOutboxFileStore(path), poster: server.post);
      await box1.load();
      await enqueueDelivery(box1, 'uuid-crash');
      box1.byUuid('uuid-crash')!.status = WsOutboxStatus.syncing;
      await box1.store
          .save(box1.items.map((e) => e.toJson()).toList());

      // Second run: a fresh process reads the file.
      final box2 = WsOutbox(
          store: WsOutboxFileStore(path), poster: server.post);
      await box2.load();

      expect(box2.byUuid('uuid-crash')!.status, WsOutboxStatus.pending,
          reason: 'a stranded `syncing` item must be recovered to pending');

      final report = await box2.drain();
      expect(report.posted, 1);
      expect(server.writes, 1);

      await dir.delete(recursive: true);
    });

    test('a half-written file does not lose the queue', () async {
      final dir = await Directory.systemTemp.createTemp('ws_outbox_tmp');
      final path = '${dir.path}/outbox.json';

      // Simulate dying between writing the temp file and renaming it.
      await File('$path.tmp').writeAsString(
          '[{"seq":1,"clientUuid":"uuid-tmp","rpc":"ws_record_delivery",'
          '"args":{},"label":"x","createdAt":"2026-01-01T00:00:00.000",'
          '"status":"pending","attempts":0}]');

      final loaded = await WsOutboxFileStore(path).load();
      expect(loaded.length, 1,
          reason: 'the completed .tmp is a valid queue and must be recovered');
      expect(loaded.first['clientUuid'], 'uuid-tmp');

      await dir.delete(recursive: true);
    });

    test('corrupt JSON is set aside, not deleted', () async {
      final dir = await Directory.systemTemp.createTemp('ws_outbox_corrupt');
      final path = '${dir.path}/outbox.json';
      await File(path).writeAsString('{ this is not json');

      final loaded = await WsOutboxFileStore(path).load();
      expect(loaded, isEmpty);

      final saved = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrupt.'))
          .toList();
      expect(saved.length, 1, reason: 'kept for manual recovery');

      await dir.delete(recursive: true);
    });
  });

  group('ordering', () {
    test('scenario 8: processed in creation order', () async {
      final server = FakeServer();
      final order = <String>[];
      final box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: (item) async {
          order.add(item.clientUuid);
          return server.post(item);
        },
      );

      await enqueueDelivery(box, 'a');
      await enqueueDelivery(box, 'b');
      await enqueueDelivery(box, 'c');
      await box.drain();

      expect(order, ['a', 'b', 'c']);
    });

    test('a retryable failure BLOCKS the items behind it', () async {
      final server = FakeServer()..offline = true;
      final box = makeOutbox(server);
      await enqueueDelivery(box, 'a');
      await enqueueDelivery(box, 'b');

      final report = await box.drain();
      expect(report.stoppedOn?.clientUuid, 'a');
      expect(box.byUuid('b')!.attempts, 0,
          reason: 'b must not be attempted while a is unresolved');
    });

    test('a PERMANENT failure does not block the queue forever', () async {
      final server = FakeServer()..rejectPermanently = true;
      final box = makeOutbox(server);
      await enqueueDelivery(box, 'bad');

      await box.drain();
      expect(box.byUuid('bad')!.status, WsOutboxStatus.failed);
      expect(box.byUuid('bad')!.lastCode, 'P0002');

      // A later, valid item still gets through.
      server.rejectPermanently = false;
      await enqueueDelivery(box, 'good');
      final report = await box.drain();
      expect(report.posted, 1);
      expect(box.byUuid('good')!.status, WsOutboxStatus.synced);
    });

    test('retrying keeps its place in the order', () async {
      final server = FakeServer();
      final box = makeOutbox(server);
      final a = await enqueueDelivery(box, 'a');
      final b = await enqueueDelivery(box, 'b');
      expect(a.seq < b.seq, isTrue);

      box.byUuid('a')!.status = WsOutboxStatus.failed;
      await box.retry('a');
      expect(box.byUuid('a')!.seq, a.seq, reason: 'seq must not change');
    });
  });

  group('housekeeping', () {
    test('enqueueing the same key twice is one item', () async {
      final box = makeOutbox(FakeServer());
      await enqueueDelivery(box, 'same');
      await enqueueDelivery(box, 'same', qty: 99);
      expect(box.items.length, 1);
    });

    test('synced items are KEPT for diagnosis', () async {
      final box = makeOutbox(FakeServer());
      await enqueueDelivery(box, 'keep');
      await box.drain();
      expect(box.items.length, 1);
      expect(box.byUuid('keep')!.status, WsOutboxStatus.synced);
      expect(box.pendingCount, 0);
    });

    test('old synced items are pruned, pending never is', () async {
      final box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: FakeServer().post,
        keepSynced: 1,
      );
      await enqueueDelivery(box, 'old');
      await enqueueDelivery(box, 'new');
      await box.drain();
      expect(box.items.length, 1, reason: 'keepSynced: 1');

      final offline = FakeServer()..offline = true;
      final box2 = WsOutbox(
          store: WsOutboxMemoryStore(),
          poster: offline.post,
          keepSynced: 0);
      await enqueueDelivery(box2, 'p1');
      await box2.drain();
      expect(box2.items.length, 1, reason: 'a pending item is never pruned');
    });

    test('concurrent drains do not double-post', () async {
      final server = FakeServer();
      final box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: (item) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return server.post(item);
        },
      );
      await enqueueDelivery(box, 'race');

      final results = await Future.wait([box.drain(), box.drain()]);
      expect(results.where((r) => r.skippedBusy).length, 1);
      expect(server.writes, 1);
    });
  });
}
