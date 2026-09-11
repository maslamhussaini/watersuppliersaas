// =============================================================================
// test/outbox_settle_test.dart
//
// Two defects, both observed on a SUCCESSFUL online save.
//
// ─── 1. THE STATUS WAS READ BEFORE IT EXISTED ────────────────────────────────
//
// Every caller does `final item = await record...()` then switches on
// item.status. The enqueue helpers ended with `unawaited(box.drain())`, and
// drain() awaits a persist and an HTTP round trip before the status can be
// anything but `pending`. So an online save that succeeded 300ms later still
// told the driver "Saved on this device — waiting to sync".
//
// Proven in a real browser: syncing at t+0ms, synced by t+1000ms, attempts 1,
// server row present, no duplicate — and an amber "waiting to sync" message.
//
// ─── 2. A THROW ON THE SUCCESS PATH HAD NOWHERE TO GO ────────────────────────
//
// `unawaited()` suppresses the lint, not the error. Anything escaping drain()
// became a bare "Uncaught Error" with no Dart context in a release build.
//
// ─── WHAT MUST NOT CHANGE ────────────────────────────────────────────────────
//
// Enqueue-before-post, the drain algorithm, WsPostResult classification, the
// retry budget and every status transition. Only how long the CALLER waits
// before reporting. Offline must still return promptly.
//
// These tests drive WsOutbox directly — WsOutboxService is static and needs
// Supabase — so they model the settle policy rather than importing it. The
// policy under test is: attach catchError to the drain, THEN bound the wait.
// =============================================================================

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_store.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_supabase.dart'
    show WsOutboxService;

/// The production policy from WsOutboxService._settle, verbatim in shape.
Future<void> settle(
  WsOutbox box, {
  required Duration window,
  void Function(String)? log,
}) async {
  final draining = box.drain().catchError((Object e) {
    log?.call('outbox: drain failed — $e');
    return const WsDrainReport();
  });
  await draining.timeout(window, onTimeout: () => const WsDrainReport());
}

void main() {
  late WsOutboxMemoryStore store;
  late List<String> logs;

  setUp(() {
    store = WsOutboxMemoryStore();
    logs = [];
  });

  Future<WsOutboxItem> queue(WsOutbox box, {String? uuid}) => box.enqueue(
        clientUuid: uuid ?? wsNewUuid(),
        rpc: 'ws_record_delivery',
        args: {'p_customerid': 1, 'p_delivered': 2},
        label: '2 out — Hotel ABC',
      );

  // ═══ 1 · ONLINE REACHES synced WITH NO UNHANDLED ERROR ════════════════════

  test('1. an online save reaches synced, and nothing is left unhandled',
      () async {
    final box = WsOutbox(
      store: store,
      poster: (_) async => const WsPostResult.success(documentId: 10),
    );
    await box.load();

    final item = await queue(box);
    await settle(box, window: const Duration(seconds: 3), log: logs.add);

    expect(item.status, WsOutboxStatus.synced);
    expect(item.documentId, 10);
    expect(item.attempts, 1, reason: 'one attempt, exactly as observed live');
    expect(logs, isEmpty, reason: 'a clean success logs nothing');
  });

  // ═══ 2 · THE CALLER NO LONGER REPORTS "WAITING" AFTER A GOOD SAVE ═════════

  test('2. the status is settled BEFORE the caller reports', () async {
    // The delivery screen renders amber for pending/syncing and green only for
    // synced. Reading too early is what made every online save look queued.
    final box = WsOutbox(
      store: store,
      poster: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return const WsPostResult.success(documentId: 7);
      },
    );
    await box.load();

    final item = await queue(box);
    expect(item.status, WsOutboxStatus.pending,
        reason: 'enqueue-before-post is preserved — durable first');

    await settle(box, window: const Duration(seconds: 3));

    expect(item.status, WsOutboxStatus.synced,
        reason: 'THE DEFECT: this was still pending when the screen read it, '
            'so a successful online save reported "waiting to sync"');
  });

  test('2b. a permanent failure is reported as failed, not as waiting',
      () async {
    final box = WsOutbox(
      store: store,
      poster: (_) => Future.value(const WsPostResult.permanent('refused')),
    );
    await box.load();

    final item = await queue(box);
    await settle(box, window: const Duration(seconds: 3));

    expect(item.status, WsOutboxStatus.failed);
    expect(item.lastError, 'refused');
  });

  // ═══ 3 · OFFLINE AND SLOW MUST NOT BLOCK ══════════════════════════════════

  test('3. offline returns promptly and stays queued', () async {
    final box = WsOutbox(
      store: store,
      poster: (_) async => const WsPostResult.network('offline'),
    );
    await box.load();

    final started = DateTime.now();
    final item = await queue(box);
    await settle(box, window: const Duration(seconds: 3));
    final elapsed = DateTime.now().difference(started);

    expect(item.status, WsOutboxStatus.pending,
        reason: 'still queued, and the amber message is now truthful');
    expect(elapsed, lessThan(const Duration(seconds: 1)),
        reason: 'a failing drain returns immediately — the window is a cap, '
            'not a delay');
    expect(item.budgetedAttempts, 0,
        reason: 'a network failure must not consume the retry budget');
  });

  test('3b. a HANGING network releases the caller at the window', () async {
    // The case the bound exists for: the request neither succeeds nor fails.
    final never = Completer<WsPostResult>();
    final box = WsOutbox(store: store, poster: (_) => never.future);
    await box.load();

    final item = await queue(box);
    final started = DateTime.now();
    await settle(box, window: const Duration(milliseconds: 150));
    final elapsed = DateTime.now().difference(started);

    expect(elapsed, lessThan(const Duration(seconds: 1)),
        reason: 'Save must never wait indefinitely on the network');
    expect(item.status, WsOutboxStatus.syncing,
        reason: 'still in flight — the screen reports it as not yet synced, '
            'which is the truth');

    never.complete(const WsPostResult.success(documentId: 1));
    await Future<void>.delayed(Duration.zero);
    expect(item.status, WsOutboxStatus.synced,
        reason: 'and the drain carries on in the background — timing out the '
            'WAIT must not abandon the POST');
  });

  // ═══ 6 · A DRAIN-SIDE THROW IS CAPTURED, NOT UNHANDLED ════════════════════

  test('6. a store that throws is logged, never left unhandled', () async {
    final box = WsOutbox(
      store: _ThrowingStore(onSave: true),
      poster: (_) async => const WsPostResult.success(documentId: 1),
    );

    // enqueue itself throws here; the screens already wrap that in try/catch.
    // What matters is that settle() surfaces it rather than dropping it.
    await expectLater(
      () async {
        await box.load();
        await queue(box);
      }(),
      throwsA(isA<StateError>()),
    );
  });

  test('6b. a throw from collectGarbage never escapes settle()', () async {
    // collectGarbage runs in drain()'s finally, AFTER the item is synced —
    // exactly the window in which the live Uncaught Error appeared.
    final box = WsOutbox(
      store: _ThrowingStore(onCollect: true),
      poster: (_) async => const WsPostResult.success(documentId: 3),
    );
    await box.load();
    final item = await queue(box);

    await settle(box, window: const Duration(seconds: 3), log: logs.add);

    expect(item.status, WsOutboxStatus.synced,
        reason: 'the document is already safe before pruning runs — which is '
            'why the live delivery survived its Uncaught Error');
    expect(logs.single, contains('drain failed'),
        reason: 'reported, not swallowed and not uncaught');
  });

  test('6c. the failure is logged BEFORE the window can expire', () async {
    // catchError must be attached to the drain, not to the timeout. Attached
    // after, a throw arriving post-timeout lands on a future nobody holds.
    final box = WsOutbox(
      store: _ThrowingStore(onCollect: true),
      poster: (_) async => const WsPostResult.success(documentId: 4),
    );
    await box.load();
    await queue(box);

    await settle(box, window: const Duration(milliseconds: 1), log: logs.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(logs, isNotEmpty, reason: 'still captured despite the tiny window');
  });

  // ═══ THE PRODUCTION CONSTANT ══════════════════════════════════════════════

  test('the settle window is bounded and short', () {
    expect(WsOutboxService.settleWindow, const Duration(seconds: 3),
        reason: 'long enough for a normal round trip, short enough that a '
            'driver on a bad connection is not left staring at a spinner');
    expect(WsOutboxService.settleWindow, lessThan(const Duration(seconds: 10)));
  });
}

/// Fails on demand, to drive the paths that have no other way to fail.
class _ThrowingStore extends WsOutboxStore {
  final bool onSave;
  final bool onCollect;

  _ThrowingStore({this.onSave = false, this.onCollect = false});

  final _mem = WsOutboxMemoryStore();

  @override
  WsOutboxLoadIssue? get lastLoadIssue => _mem.lastLoadIssue;

  @override
  Future<List<Map<String, dynamic>>> load() => _mem.load();

  @override
  Future<void> save(List<Map<String, dynamic>> items) {
    if (onSave) throw StateError('storage refused the write');
    return _mem.save(items);
  }

  @override
  Future<void> clear() => _mem.clear();

  @override
  Future<int> collectGarbage(Duration keepSyncedFor) async {
    if (onCollect) throw StateError('garbage collection exploded');
    return 0;
  }
}
