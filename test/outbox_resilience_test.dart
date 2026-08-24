// =============================================================================
// test/outbox_resilience_test.dart
//
// The four fixes, executed:
//
//   · network failures must never consume the permanent-failure budget
//   · a corrupt queue file must never look like an empty queue
//   · reconcile() must never take a payment's id for a delivery
//   · (the delivery key fix is a widget-state change; its invariant — one key
//     reused across attempts — is covered here at the queue level)
//
// Pure Dart: no Flutter binding, no device, no network.
//
//   flutter test test/outbox_resilience_test.dart
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_lookup.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_store.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ws_resilience');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  String path(String name) => '${dir.path}/$name';

  Future<WsOutboxItem> queueOne(WsOutbox box, {String? uuid}) => box.enqueue(
        clientUuid: uuid ?? wsNewUuid(),
        rpc: 'ws_record_delivery',
        args: const {'p_customerid': 1, 'p_delivered': 2},
        label: '2 out — Hotel ABC',
      );

  // ═══ 1. NETWORK FAILURES DO NOT BURN THE BUDGET ═══════════════════════════

  group('network failures', () {
    test('a delivery with no signal stays pending forever, never failed',
        () async {
      final box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: (_) async =>
            const WsPostResult.network('SocketException: no route to host'),
        maxAutoAttempts: 3, // deliberately tiny
      );
      await box.load();
      final item = await queueOne(box);

      // Far more drains than the budget would ever allow.
      for (var i = 0; i < 30; i++) {
        await box.drain();
      }

      expect(item.status, WsOutboxStatus.pending,
          reason: 'a van out of coverage is not a failed delivery');
      expect(item.attempts, 30, reason: 'every attempt is still recorded');
      expect(item.budgetedAttempts, 0,
          reason: 'none of them counted against the budget');
      expect(item.lastWasNetwork, isTrue);
      expect(box.failedCount, 0);
    });

    test('reconnecting syncs it with no manual retry', () async {
      var offline = true;
      final box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: (_) async => offline
            ? const WsPostResult.network('Failed host lookup')
            : const WsPostResult.success(documentId: 99),
        maxAutoAttempts: 3,
      );
      await box.load();
      final item = await queueOne(box);

      for (var i = 0; i < 10; i++) {
        await box.drain();
      }
      expect(item.status, WsOutboxStatus.pending);

      offline = false;
      await box.drain(); // the ordinary automatic drain, not retry()

      expect(item.status, WsOutboxStatus.synced);
      expect(item.documentId, 99);
    });

    test('a network failure still BLOCKS the items behind it (FIFO)',
        () async {
      final box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: (_) async => const WsPostResult.network('offline'),
      );
      await box.load();
      final first = await queueOne(box);
      final second = await queueOne(box);

      await box.drain();

      expect(first.attempts, 1);
      expect(second.attempts, 0,
          reason: 'order must hold — a later document may depend on this one');
    });
  });

  // ═══ 2. SERVER FAILURES STILL DO ═════════════════════════════════════════

  group('server failures', () {
    test('a repeating 500 still ends in failed after the budget', () async {
      final box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: (_) async =>
            const WsPostResult.retryable('Internal Server Error',
                statusCode: 500),
        maxAutoAttempts: 3,
      );
      await box.load();
      final item = await queueOne(box);

      await box.drain();
      expect(item.status, WsOutboxStatus.pending);
      await box.drain();
      expect(item.status, WsOutboxStatus.pending);
      await box.drain();

      expect(item.status, WsOutboxStatus.failed,
          reason: 'a server that keeps breaking needs a human');
      expect(item.budgetedAttempts, 3);
      expect(item.lastWasNetwork, isFalse);
    });

    test('a permanent error fails immediately and needs a manual retry',
        () async {
      var reject = true;
      final box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: (_) async => reject
            ? const WsPostResult.permanent('permission denied', code: '42501')
            : const WsPostResult.success(documentId: 5),
        maxAutoAttempts: 8,
      );
      await box.load();
      final item = await queueOne(box);

      await box.drain();
      expect(item.status, WsOutboxStatus.failed);
      expect(item.lastCode, '42501');

      final attemptsAtFailure = item.attempts;
      reject = false;
      await box.drain();
      expect(item.attempts, attemptsAtFailure,
          reason: 'permanent failures are never retried automatically');
      expect(item.status, WsOutboxStatus.failed);

      expect(await box.retry(item.clientUuid), isTrue);
      expect(item.budgetedAttempts, 0, reason: 'manual retry clears the budget');
      await box.drain();
      expect(item.status, WsOutboxStatus.synced);
    });

    test('only the server failures in a mixed run count', () async {
      var mode = 'network';
      final box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: (_) async => mode == 'network'
            ? const WsPostResult.network('offline')
            : const WsPostResult.retryable('500', statusCode: 500),
        maxAutoAttempts: 3,
      );
      await box.load();
      final item = await queueOne(box);

      for (var i = 0; i < 10; i++) {
        await box.drain();
      }
      expect(item.budgetedAttempts, 0);
      expect(item.status, WsOutboxStatus.pending);

      mode = 'server';
      await box.drain();
      await box.drain();
      expect(item.status, WsOutboxStatus.pending,
          reason: 'two server failures, budget is three');
      await box.drain();
      expect(item.status, WsOutboxStatus.failed);
      expect(item.attempts, 13, reason: 'all attempts are still counted');
      expect(item.budgetedAttempts, 3);
    });
  });

  // ═══ 3. THE BUDGET SURVIVES A RESTART ════════════════════════════════════

  group('persistence', () {
    test('budgetedAttempts round-trips through the file', () async {
      final p = path('q.json');
      final a = WsOutbox(
        store: WsOutboxFileStore(p),
        poster: (_) async => const WsPostResult.retryable('500'),
        maxAutoAttempts: 5,
      );
      await a.load();
      final item = await queueOne(a);
      await a.drain();
      await a.drain();
      expect(item.budgetedAttempts, 2);

      final b = WsOutbox(
          store: WsOutboxFileStore(p),
          poster: (_) async => const WsPostResult.success());
      await b.load();
      expect(b.byUuid(item.clientUuid)!.budgetedAttempts, 2,
          reason: 'a restart must not hand out a fresh budget');
    });

    test('a queue written before the split keeps its old budget', () async {
      final p = path('legacy.json');
      // 'attempts' but no 'budgetedAttempts' — the shape written by the
      // previous version.
      await File(p).writeAsString(jsonEncode([
        {
          'seq': 1,
          'clientUuid': 'legacy-key',
          'rpc': 'ws_record_delivery',
          'args': <String, dynamic>{},
          'label': 'old',
          'createdAt': DateTime.now().toIso8601String(),
          'status': 'pending',
          'attempts': 6,
        }
      ]));

      final box = WsOutbox(
          store: WsOutboxFileStore(p),
          poster: (_) async => const WsPostResult.success());
      await box.load();

      expect(box.byUuid('legacy-key')!.budgetedAttempts, 6,
          reason: 'falls back to attempts rather than resetting to zero');
    });
  });

  // ═══ 4. A CORRUPT QUEUE FILE IS NEVER SILENT ═════════════════════════════

  group('corrupt queue file', () {
    /// Writes a real three-item queue and returns its file contents.
    Future<String> healthyQueueText() async {
      final p = path('c.json');
      final box = WsOutbox(
          store: WsOutboxFileStore(p),
          poster: (_) async => const WsPostResult.network('offline'));
      await box.load();
      for (var i = 0; i < 3; i++) {
        await queueOne(box);
      }
      return File(p).readAsString();
    }

    test('intact records are salvaged and stay pending', () async {
      final full = await healthyQueueText();
      // Rebuilt rather than sliced at a guessed offset: two COMPLETE records
      // followed by a third cut off mid-way and no closing bracket. That is
      // what a write interrupted by a dying battery leaves behind, and the
      // first two deliveries in it are perfectly intact.
      final records = (jsonDecode(full) as List).cast<Map<String, dynamic>>();
      final p = path('c.json');
      await File(p).writeAsString('[${jsonEncode(records[0])},'
          '${jsonEncode(records[1])},'
          '${jsonEncode(records[2]).substring(0, 40)}');

      final box = WsOutbox(
          store: WsOutboxFileStore(p),
          poster: (_) async => const WsPostResult.network('offline'));
      await box.load();

      expect(box.loadIssue, isNotNull,
          reason: 'THE POINT: the damage must be reported, not swallowed');
      expect(box.items.length, 2, reason: 'the two whole records survived');
      expect(box.loadIssue!.salvaged, 2);
      expect(box.loadIssue!.unrecoverable, 1);
      expect(box.pendingCount, 2, reason: 'and they are still queued to send');
      expect(File(box.loadIssue!.quarantinePath).existsSync(), isTrue,
          reason: 'the original bytes are kept for a human');
    });

    test('unreadable rubbish is reported rather than looking empty', () async {
      final p = path('junk.json');
      await File(p).writeAsString('%%% not json at all %%%');

      final box = WsOutbox(
          store: WsOutboxFileStore(p),
          poster: (_) async => const WsPostResult.success());
      await box.load();

      expect(box.items, isEmpty);
      expect(box.loadIssue, isNotNull,
          reason: 'an empty queue and a destroyed queue must not look alike');
      expect(box.loadIssue!.salvaged, 0);
      expect(File(box.loadIssue!.quarantinePath).existsSync(), isTrue);
    });

    test('salvaged items are rewritten cleanly and load normally next time',
        () async {
      final full = await healthyQueueText();
      final p = path('c.json');
      await File(p).writeAsString('${full.substring(0, full.length - 30)}garbage');

      final first = WsOutbox(
          store: WsOutboxFileStore(p),
          poster: (_) async => const WsPostResult.network('offline'));
      await first.load();
      final salvaged = first.items.length;
      expect(first.loadIssue, isNotNull);

      final second = WsOutbox(
          store: WsOutboxFileStore(p),
          poster: (_) async => const WsPostResult.network('offline'));
      await second.load();

      expect(second.loadIssue, isNull, reason: 'the file is healthy again');
      expect(second.items.length, salvaged);
    });

    test('a healthy file reports no issue', () async {
      final p = path('ok.json');
      final box = WsOutbox(
          store: WsOutboxFileStore(p),
          poster: (_) async => const WsPostResult.network('offline'));
      await box.load();
      await queueOne(box);
      await box.drain();

      final reopened = WsOutbox(
          store: WsOutboxFileStore(p),
          poster: (_) async => const WsPostResult.success());
      await reopened.load();
      expect(reopened.loadIssue, isNull);
      expect(reopened.items.length, 1);
    });

    test('the warning stays until it is acknowledged', () async {
      final p = path('sticky.json');
      await File(p).writeAsString('{ broken');

      final box = WsOutbox(
          store: WsOutboxFileStore(p),
          poster: (_) async => const WsPostResult.success());
      await box.load();
      expect(box.loadIssue, isNotNull);

      await queueOne(box);
      await box.drain();
      expect(box.loadIssue, isNotNull,
          reason: 'a later success does not undo the loss');

      box.acknowledgeLoadIssue();
      expect(box.loadIssue, isNull);
    });
  });

  // ═══ 5. reconcile() PICKS THE RIGHT DOCUMENT ═════════════════════════════

  group('lookup row selection', () {
    // ws_record_delivery stamps its clientuuid on the payment it creates too,
    // so a delivery key really does return two rows.
    const deliveryWithCash = [
      {'doctype': 'payment', 'docid': 17, 'docnumber': 'RCPT-000003'},
      {'doctype': 'delivery', 'docid': 34, 'docnumber': 'DEL-000006'},
    ];

    test('THE REGRESSION: payment row first, delivery id still chosen', () {
      final row = wsPickLookupRow(deliveryWithCash, 'ws_record_delivery');
      expect(row, isNotNull);
      expect(row!['docid'], 34);
      expect(row['doctype'], 'delivery');
      expect(wsPickLookupDocId(deliveryWithCash, 'ws_record_delivery'), 34,
          reason: 'never 17 — that is the payment, not the delivery');
    });

    test('and the same result whichever order the server returns them', () {
      final reversed = deliveryWithCash.reversed.toList();
      expect(wsPickLookupDocId(reversed, 'ws_record_delivery'), 34);
      expect(wsPickLookupDocId(deliveryWithCash, 'ws_record_delivery'), 34);
    });

    test('a standalone payment resolves to the payment row', () {
      expect(wsPickLookupDocId(deliveryWithCash, 'ws_record_payment'), 17);
    });

    test('a missing doctype returns null, so the item stays queued', () {
      expect(wsPickLookupRow(deliveryWithCash, 'ws_record_purchase'), isNull);
      expect(wsPickLookupRow(const [], 'ws_record_delivery'), isNull);
    });

    test('an unknown rpc refuses to guess', () {
      expect(wsPickLookupRow(deliveryWithCash, 'ws_record_something'), isNull);
    });

    test('every posting rpc has a doctype', () {
      for (final rpc in const [
        'ws_record_delivery',
        'ws_record_payment',
        'ws_record_purchase',
        'ws_record_vendor_payment',
      ]) {
        expect(wsDoctypeForRpc[rpc], isNotNull, reason: rpc);
      }
    });
  });

  // ═══ 6. ONE KEY PER SAVE, REUSED BY EVERY ATTEMPT ════════════════════════

  group('idempotency key lifetime', () {
    test('re-posting under one key never produces a second item', () async {
      var fail = true;
      final posted = <String>[];
      final box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: (i) async {
          posted.add(i.clientUuid);
          return fail
              ? const WsPostResult.network('timeout')
              : const WsPostResult.success(documentId: 1);
        },
      );
      await box.load();

      // The screen holds ONE key and hands it to every attempt.
      const key = 'fixed-key-for-one-save-action';
      await queueOne(box, uuid: key);
      await box.drain();
      await queueOne(box, uuid: key); // user taps Save again
      await box.drain();

      expect(box.items.length, 1, reason: 'one Save action, one document');
      fail = false;
      await box.drain();
      expect(box.items.single.status, WsOutboxStatus.synced);
      expect(posted.toSet(), {key},
          reason: 'every attempt carried the same key to the server');
    });
  });
}
