// =============================================================================
// test/outbox_storage_test.dart
// The outbox on the key/value seam.
//
// This is a STORAGE migration, so the tests that matter are the ones proving
// the queue engine did not change: FIFO across a reload, retry metadata
// surviving, acknowledging one item leaving the others alone, and clientuuid
// replayed byte-identical.
//
// The existing suites (outbox_test, outbox_resilience_test) continue to drive
// the file store and are untouched.
// =============================================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_kv_store.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';
import 'package:watersuppliersaas/services/storage/ws_kv_preferences.dart';

void main() {
  late WsFakePreferencesBackend backend;

  setUp(() => backend = WsFakePreferencesBackend());

  WsOutboxKvStore store() =>
      WsOutboxKvStore(WsPreferencesKeyValueStore(backend));

  /// A fresh WsOutbox over the SAME backend — what a browser reload looks like.
  WsOutbox open({WsPostResult Function(WsOutboxItem)? post}) => WsOutbox(
        store: store(),
        poster: (item) async =>
            post?.call(item) ?? const WsPostResult.network('offline'),
      );

  Future<WsOutboxItem> queue(WsOutbox box, String label, {String? uuid}) =>
      box.enqueue(
        clientUuid: uuid ?? wsNewUuid(),
        rpc: 'ws_record_delivery',
        args: {'p_customerid': 1, 'p_delivered': 2, 'p_storeid': 3},
        label: label,
      );

  // ═══ PERSISTENCE ══════════════════════════════════════════════════════════

  group('the queue survives a reload', () {
    test('a queued item is still there in a fresh instance', () async {
      final box = open();
      await box.load();
      await queue(box, 'first');
      await box.drain();

      final reopened = open();
      await reopened.load();

      expect(reopened.items, hasLength(1));
      expect(reopened.items.single.label, 'first');
    });

    test('FIFO ORDER SURVIVES — the whole point of the queue', () async {
      final box = open();
      await box.load();
      for (final n in ['a', 'b', 'c', 'd']) {
        await queue(box, n);
      }
      await box.drain();

      final reopened = open();
      await reopened.load();

      expect(reopened.items.map((i) => i.label), ['a', 'b', 'c', 'd'],
          reason: 'a queue that reorders on reload posts a payment before the '
              'delivery it settles');
    });

    test('the clientuuid is replayed unchanged', () async {
      final box = open();
      await box.load();
      await queue(box, 'delivery', uuid: 'fixed-key-1');
      await box.drain();

      final posted = <String>[];
      final reopened = WsOutbox(
        store: store(),
        poster: (item) async {
          posted.add(item.clientUuid);
          return const WsPostResult.success(documentId: 9);
        },
      );
      await reopened.load();
      await reopened.drain();

      expect(posted, ['fixed-key-1'],
          reason: 'a new key on retry is a second document; migration 014 '
              'resolves the original only if the key is identical');
    });

    test('the payload is replayed unchanged', () async {
      final box = open();
      await box.load();
      await queue(box, 'delivery', uuid: 'k');
      await box.drain();

      Map<String, dynamic>? seen;
      final reopened = WsOutbox(
        store: store(),
        poster: (item) async {
          seen = Map<String, dynamic>.from(item.args);
          return const WsPostResult.success(documentId: 1);
        },
      );
      await reopened.load();
      await reopened.drain();

      expect(seen, {'p_customerid': 1, 'p_delivered': 2, 'p_storeid': 3});
    });

    test('retry metadata survives', () async {
      final box = open(post: (_) => const WsPostResult.retryable('server said no'));
      await box.load();
      await queue(box, 'doomed');
      await box.drain();

      final attemptsBefore = box.items.single.budgetedAttempts;
      expect(attemptsBefore, greaterThan(0));

      final reopened = open();
      await reopened.load();

      expect(reopened.items.single.budgetedAttempts, attemptsBefore,
          reason: 'losing the attempt count on reload resets the retry budget '
              'and retries forever');
    });

    test('syncing the head leaves the rest queued, still in order', () async {
      final box = open();
      await box.load();
      await queue(box, 'keep-1', uuid: 'u1');
      await queue(box, 'sync-me', uuid: 'u2');
      await queue(box, 'keep-2', uuid: 'u3');
      await box.drain();

      // Only the FIRST is accepted; the rest stay offline. It has to be the
      // first: the queue is FIFO WITH BLOCKING, so a stuck item deliberately
      // holds up everything behind it — a payment must never be posted before
      // the delivery it settles.
      final selective = WsOutbox(
        store: store(),
        poster: (item) async => item.clientUuid == 'u1'
            ? const WsPostResult.success(documentId: 5)
            : const WsPostResult.network('offline'),
      );
      await selective.load();
      await selective.drain();

      final reopened = open();
      await reopened.load();

      final byUuid = {for (final i in reopened.items) i.clientUuid: i.status};
      expect(byUuid['u1'], WsOutboxStatus.synced);
      expect(byUuid['u2'], isNot(WsOutboxStatus.synced));
      expect(byUuid['u3'], isNot(WsOutboxStatus.synced),
          reason: 'one document being accepted must not mark its neighbours '
              'as delivered');
      expect(reopened.items.map((i) => i.clientUuid), ['u1', 'u2', 'u3'],
          reason: 'and order is still FIFO afterwards');
    });

    test('an empty queue reads as empty, not as an error', () async {
      final box = open();
      await box.load();
      expect(box.items, isEmpty);
      expect(store().lastLoadIssue, isNull);
    });
  });

  // ═══ CORRUPTION IS REPORTED, NOT SWALLOWED ════════════════════════════════

  group('corruption goes through the existing contract', () {
    Future<WsOutboxKvStore> withStored(String raw) async {
      await backend.setString('ws.${WsOutboxKvStore.storageKey}', raw);
      return store();
    }

    test('unparseable JSON is reported through lastLoadIssue', () async {
      final s = await withStored('[{"half":');
      final items = await s.load();

      expect(items, isEmpty);
      expect(s.lastLoadIssue, isNotNull,
          reason: 'a queue that loses documents must say so out loud');
      expect(s.lastLoadIssue!.detail, contains('not valid JSON'));
    });

    test('the unreadable payload is kept, never deleted', () async {
      const raw = '[{"half":';
      final s = await withStored(raw);
      await s.load();

      expect(await backend.getString('ws.${WsOutboxKvStore.quarantineKey}'),
          raw,
          reason: 'a corrupt queue may be the only record that a delivery '
              'happened');
    });

    test('a JSON document of the wrong shape is reported', () async {
      final s = await withStored(jsonEncode({'not': 'a list'}));
      await s.load();
      expect(s.lastLoadIssue!.detail, contains('not a list'));
    });

    test('unrecoverable == -1 MEANS "unknown", not "minus one record"',
        () async {
      // Deliberate sentinel. When nothing parsed, there is no structure left to
      // walk, so the number of lost records genuinely cannot be counted — and
      // reporting 0 would read as "nothing was lost", which is the one thing we
      // know is false.
      //
      // The file store CAN give a real count because its brace scanner walks
      // the wreckage record by record. That difference is a property of the
      // backend, not an inconsistency to paper over, so WsOutboxLoadIssue keeps
      // its existing contract and this store reports honestly within it.
      final s = await withStored('[{"totally');
      await s.load();

      final issue = s.lastLoadIssue!;
      expect(issue.unrecoverable, -1);
      expect(issue.salvaged, 0);
      expect(issue.everythingRecovered, isFalse,
          reason: 'unknown loss must never read as no loss');
    });

    test('a partially readable queue reports a REAL count, not the sentinel',
        () async {
      final s = await withStored(jsonEncode([
        {'id': '1'},
        42,
        {'id': '2'},
      ]));
      await s.load();

      expect(s.lastLoadIssue!.unrecoverable, 1,
          reason: 'the sentinel is only for when counting is impossible');
    });

    test('nothing is ever deleted, whichever way it failed', () async {
      for (final raw in ['[{"half":', '{"not":"a list"}', '[1,2,3]']) {
        final fresh = WsFakePreferencesBackend();
        await fresh.setString('ws.${WsOutboxKvStore.storageKey}', raw);
        final s = WsOutboxKvStore(WsPreferencesKeyValueStore(fresh));
        await s.load();

        expect(await fresh.getString('ws.${WsOutboxKvStore.quarantineKey}'),
            raw,
            reason: 'quarantine-never-delete holds for every failure mode');
      }
    });

    test('one bad record does not cost the whole queue', () async {
      final s = await withStored(jsonEncode([
        {'id': '1', 'label': 'good'},
        'this is not a record',
        {'id': '2', 'label': 'also good'},
      ]));

      final items = await s.load();

      expect(items, hasLength(2));
      expect(s.lastLoadIssue!.salvaged, 2);
      expect(s.lastLoadIssue!.unrecoverable, 1);
    });

    test('a clean load clears any previous issue', () async {
      final s = await withStored('[nonsense');
      await s.load();
      expect(s.lastLoadIssue, isNotNull);

      await s.save([]);
      await s.load();
      expect(s.lastLoadIssue, isNull);
    });
  });

  // ═══ NAMESPACE SAFETY ═════════════════════════════════════════════════════

  group('the outbox does not trample its neighbours', () {
    test('clear() removes only the queue key', () async {
      // Supabase persists the session in this same backend. Wiping it would
      // sign the user out every time the queue was cleared.
      await backend.setString('sb-localhost-auth-token', 'session-value');
      await backend.setString('ws.whatsNew.lastSeen', '1.5.0');

      final s = store();
      await s.save([
        {'id': '1'}
      ]);
      await s.clear();

      expect(await backend.getString('sb-localhost-auth-token'),
          'session-value');
      expect(await backend.getString('ws.whatsNew.lastSeen'), '1.5.0');
      expect(await s.load(), isEmpty);
    });

    test('the queue and What\'s New coexist in one backend', () async {
      final s = store();
      await s.save([
        {'id': '1', 'label': 'delivery'}
      ]);
      await WsPreferencesKeyValueStore(backend)
          .write('whatsNew.lastSeen', '1.5.0');

      expect(await s.load(), hasLength(1));
      expect(
        await WsPreferencesKeyValueStore(backend).read('whatsNew.lastSeen'),
        '1.5.0',
      );
    });
  });

  // ═══ THE STORE CONTRACT, SHARED ═══════════════════════════════════════════

  group('WsOutboxStore contract', () {
    test('save then load round-trips the item maps unchanged', () async {
      final s = store();
      final items = [
        {'id': '1', 'clientUuid': 'a', 'args': {'x': 1}},
        {'id': '2', 'clientUuid': 'b', 'args': {'y': 2}},
      ];
      await s.save(items);
      expect(await store().load(), items);
    });

    test('save replaces rather than appends', () async {
      final s = store();
      await s.save([{'id': '1'}]);
      await s.save([{'id': '2'}]);
      expect(await store().load(), [{'id': '2'}]);
    });

    test('clear empties it', () async {
      final s = store();
      await s.save([{'id': '1'}]);
      await s.clear();
      expect(await store().load(), isEmpty);
    });

    test('a memory-backed store satisfies the same contract', () async {
      final s = WsOutboxKvStore(WsMemoryKeyValueStore());
      await s.save([{'id': '1'}]);
      expect(await s.load(), [{'id': '1'}]);
      expect(s.lastLoadIssue, isNull);
    });
  });
}
