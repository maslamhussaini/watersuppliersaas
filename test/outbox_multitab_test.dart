// =============================================================================
// test/outbox_multitab_test.dart
// Two tabs, one localStorage. Defect #7.
//
// ─── THE DEFECT THIS FILE EXISTS FOR ─────────────────────────────────────────
//
// Found in real-browser E2E, not by any local test. Two tabs at one origin
// share a single localStorage. Each ran its own WsOutbox with an in-memory
// snapshot taken once at startup, and every save overwrote the SAME key
// wholesale. A tab that had been open a while therefore blasted its stale view
// over whatever the other tab had written — silently destroying unsent
// deliveries.
//
// It defeated durability, ownership filtering and the sign-out warning
// simultaneously, because none of them help if the file is replaced underneath.
//
// Read-merge-write was considered and REJECTED: it narrows the window from
// hours to microseconds but leaves a real lost-update race, and localStorage
// has no atomic compare-and-swap to close it. Two tabs are genuinely parallel:
//
//     A: load   B: load   A: merge   B: merge   A: save   B: save
//                                                          ^ A's item gone
//
// The fix is structural. Each instance owns outbox.instance.<uuid> and writes
// ONLY that key. Loading reads every instance key and merges by clientUuid.
// No instance ever writes another's key, so the lost update is not narrowed —
// it cannot occur.
//
// Two WsOutbox instances over ONE WsMemoryKeyValueStore is exactly two tabs
// sharing one localStorage.
// =============================================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_kv_store.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';

void main() {
  late WsMemoryKeyValueStore backend; // the shared localStorage
  String? signedIn;

  setUp(() {
    backend = WsMemoryKeyValueStore();
    signedIn = 'user-A';
  });

  /// One tab. Its own instance id, its own in-memory snapshot, the same backend.
  WsOutbox tab({
    String? instanceId,
    WsPostResult Function(WsOutboxItem)? post,
    List<String>? posted,
  }) =>
      WsOutbox(
        store: WsOutboxKvStore(backend, instanceId: instanceId),
        currentUserId: () => signedIn,
        poster: (item) async {
          posted?.add(item.clientUuid);
          return post?.call(item) ?? const WsPostResult.success(documentId: 1);
        },
      );

  Future<WsOutboxItem> queue(WsOutbox box, String uuid, {String? label}) =>
      box.enqueue(
        clientUuid: uuid,
        rpc: 'ws_record_delivery',
        args: {'p_customerid': 1},
        label: label ?? 'delivery $uuid',
      );

  /// Every instance key currently in the shared backend.
  List<String> instanceKeys() => backend.values.keys
      .where((k) => k.contains(WsOutboxKvStore.instancePrefix))
      .toList();

  // ═══ A · TWO INSTANCES FROM EMPTY STORAGE ═════════════════════════════════

  test('A. two instances enqueue concurrently; both items survive', () async {
    final a = tab(instanceId: 'A');
    final b = tab(instanceId: 'B');

    await queue(a, 'a-1');
    await queue(b, 'b-1'); // b loaded when empty — the stale case

    final fresh = tab(instanceId: 'C');
    await fresh.load();

    expect(fresh.items.map((e) => e.clientUuid).toSet(), {'a-1', 'b-1'});
    expect(instanceKeys().length, 2, reason: 'one key per instance');
  });

  // ═══ B · THE DEFECT ═══════════════════════════════════════════════════════

  test("B. a stale instance cannot remove another's PENDING item", () async {
    final a = tab(instanceId: 'A');
    final b = tab(instanceId: 'B');

    // B loads FIRST, while the store is empty. Its snapshot is now stale
    // forever — this is the tab that used to destroy everything.
    await b.load();

    // A then queues real, unsent work.
    await queue(a, 'a-pending', label: '8 out / 4 in — QA Customer 45');
    expect(a.pendingCount, 1);

    // B writes, using its stale (empty) view. Before the fix this overwrote
    // the shared key and A's delivery was gone.
    await queue(b, 'b-1');

    final fresh = tab(instanceId: 'C');
    await fresh.load();

    expect(fresh.byUuid('a-pending'), isNotNull,
        reason: "THE DEFECT: a stale tab's write destroyed unsent work");
    expect(fresh.byUuid('a-pending')!.status, WsOutboxStatus.pending);
    expect(fresh.byUuid('a-pending')!.label,
        '8 out / 4 in — QA Customer 45');
    expect(fresh.byUuid('b-1'), isNotNull);
  });

  // ═══ C · NO LOSS ACROSS REPEATED INTERLEAVED WRITES ═══════════════════════

  test('C. repeated interleaved writes lose nothing and duplicate nothing',
      () async {
    final a = tab(instanceId: 'A');
    final b = tab(instanceId: 'B');
    await a.load();
    await b.load();

    for (var i = 0; i < 5; i++) {
      await queue(a, 'a-$i');
      await queue(b, 'b-$i');
    }

    final fresh = tab(instanceId: 'C');
    await fresh.load();

    expect(fresh.items.length, 10);
    expect(fresh.items.map((e) => e.clientUuid).toSet().length, 10,
        reason: 'no duplicate clientUuid');
  });

  // ═══ D · DRAIN vs ENQUEUE ═════════════════════════════════════════════════

  test('D. one instance drains while another enqueues', () async {
    final a = tab(instanceId: 'A');
    final b = tab(instanceId: 'B');
    await b.load();

    await queue(a, 'a-1');
    await a.drain();
    expect(a.byUuid('a-1')!.status, WsOutboxStatus.synced);

    await queue(b, 'b-1');

    final fresh = tab(instanceId: 'C');
    await fresh.load();

    expect(fresh.byUuid('a-1')!.status, WsOutboxStatus.synced,
        reason: 'synced is terminal and must win the merge');
    expect(fresh.byUuid('a-1')!.documentId, isNotNull,
        reason: 'the documentId must survive too');
    expect(fresh.byUuid('b-1')!.status, WsOutboxStatus.pending);
  });

  // ═══ E · RETRY ════════════════════════════════════════════════════════════

  test('E. retry from one instance while the other holds newer items',
      () async {
    final a = tab(
        instanceId: 'A', post: (_) => const WsPostResult.permanent('refused'));
    await queue(a, 'a-1');
    await a.drain();
    expect(a.byUuid('a-1')!.status, WsOutboxStatus.failed);

    final b = tab(instanceId: 'B');
    await queue(b, 'b-1');

    await a.retry('a-1');

    final fresh = tab(instanceId: 'C');
    await fresh.load();

    expect(fresh.byUuid('a-1')!.status, WsOutboxStatus.pending,
        reason: 'the retry is more recent than the failure');
    expect(fresh.byUuid('b-1'), isNotNull);
  });

  // ═══ F · DISCARD ══════════════════════════════════════════════════════════

  test("F. discard removes only the caller's item", () async {
    final a = tab(instanceId: 'A');
    final b = tab(instanceId: 'B');
    await queue(a, 'a-1');
    await queue(b, 'b-1');

    expect(await b.discard('b-1'), isTrue);

    final fresh = tab(instanceId: 'C');
    await fresh.load();

    expect(fresh.byUuid('a-1'), isNotNull,
        reason: "one tab's discard must not reach another tab's key");
    expect(fresh.byUuid('b-1'), isNull);
  });

  // ═══ G · GC NEVER TAKES PENDING WORK ══════════════════════════════════════

  test('G. GC leaves a key holding pending work alone', () async {
    final abandoned = tab(instanceId: 'DEAD');
    await queue(abandoned, 'stranded');
    expect(abandoned.pendingCount, 1);

    final live = tab(instanceId: 'LIVE');
    await live.load();
    final removed = await WsOutboxKvStore(backend, instanceId: 'LIVE')
        .collectGarbage(const Duration(days: 7));

    expect(removed, 0, reason: 'pending work is never collected');
    final fresh = tab(instanceId: 'C');
    await fresh.load();
    expect(fresh.byUuid('stranded'), isNotNull);
  });

  test('G2. GC removes a key whose items are all synced AND old', () async {
    // Hand-write an instance key holding one old synced record.
    final old = DateTime.now().subtract(const Duration(days: 30));
    backend.values['outbox.instance.OLD'] = jsonEncode([
      {
        'seq': 1,
        'clientUuid': 'ancient',
        'rpc': 'ws_record_delivery',
        'args': {},
        'label': 'old',
        'createdAt': old.toIso8601String(),
        'syncedAt': old.toIso8601String(),
        'status': 'synced',
        'attempts': 1,
      }
    ]);

    final removed = await WsOutboxKvStore(backend, instanceId: 'LIVE')
        .collectGarbage(const Duration(days: 7));

    expect(removed, 1);
    expect(backend.values.containsKey('outbox.instance.OLD'), isFalse);
  });

  test('G3. GC keeps a RECENT synced key — the 7-day policy is unchanged',
      () async {
    final a = tab(instanceId: 'A');
    await queue(a, 'a-1');
    await a.drain();

    final removed = await WsOutboxKvStore(backend, instanceId: 'LIVE')
        .collectGarbage(const Duration(days: 7));

    expect(removed, 0, reason: 'synced today is far inside the 7-day window');
  });

  // ═══ H · PRUNING POLICY UNCHANGED ═════════════════════════════════════════

  test('H. pruning still keeps recent synced items and never pending',
      () async {
    final a = tab(instanceId: 'A');
    await queue(a, 'a-1');
    await queue(a, 'a-2');
    await a.drain();
    expect(a.items.where((e) => e.status == WsOutboxStatus.synced).length, 2);

    final b = tab(instanceId: 'B');
    await queue(b, 'b-pending');

    final fresh = tab(instanceId: 'C');
    await fresh.load();
    expect(fresh.items.length, 3, reason: 'nothing is old enough to prune');
    expect(fresh.pendingCount, 1);
  });

  // ═══ I · LEGACY MIGRATION ═════════════════════════════════════════════════

  group('I. legacy outbox.queue', () {
    void writeLegacy() {
      backend.values[WsOutboxKvStore.storageKey] = jsonEncode([
        {
          'seq': 1,
          'clientUuid': 'legacy-1',
          'rpc': 'ws_record_delivery',
          'args': {},
          'label': 'from before the fix',
          'createdAt': DateTime.now().toIso8601String(),
          'status': 'pending',
          'attempts': 0,
        }
      ]);
    }

    test('is adopted, and the key removed only AFTER the write', () async {
      writeLegacy();
      final a = tab(instanceId: 'A');
      await a.load();

      expect(a.byUuid('legacy-1'), isNotNull, reason: 'adopted');
      expect(a.byUuid('legacy-1')!.status, WsOutboxStatus.pending);
      expect(backend.values.containsKey(WsOutboxKvStore.storageKey), isFalse,
          reason: 'removed only after the instance key was written');
      expect(backend.values.containsKey('outbox.instance.A'), isTrue);
    });

    test('migration is idempotent', () async {
      writeLegacy();
      final a = tab(instanceId: 'A');
      await a.load();

      // A second instance starts; the legacy key is already gone.
      final b = tab(instanceId: 'B');
      await b.load();

      expect(b.items.where((e) => e.clientUuid == 'legacy-1').length, 1,
          reason: 'adopting twice must not duplicate');
    });

    test('legacy work is never lost even if adoption is repeated', () async {
      writeLegacy();
      // Adopt into A, then re-plant the legacy key as a crash would leave it.
      final a = tab(instanceId: 'A');
      await a.load();
      writeLegacy();

      final b = tab(instanceId: 'B');
      await b.load();
      expect(b.items.where((e) => e.clientUuid == 'legacy-1').length, 1);
    });
  });

  // ═══ J · PER-KEY CORRUPTION ═══════════════════════════════════════════════

  test('J. one corrupt instance key does not cost the others', () async {
    final a = tab(instanceId: 'A');
    await queue(a, 'a-1');

    backend.values['outbox.instance.BROKEN'] = '{not json at all';

    final fresh = tab(instanceId: 'C');
    await fresh.load();

    expect(fresh.byUuid('a-1'), isNotNull,
        reason: 'per-key isolation: the healthy key still loads');
    expect(backend.values.containsKey('outbox.instance.BROKEN.corrupt'), isTrue,
        reason: 'the unreadable bytes are kept, never discarded');
    expect(fresh.loadIssue, isNotNull, reason: 'and it is reported out loud');
  });

  // ═══ K · DETERMINISTIC ORDERING ═══════════════════════════════════════════

  test('K. duplicate seq orders deterministically by createdAt then uuid',
      () async {
    // Two instances each assign seq from their own view, so both mint seq 1.
    final a = tab(instanceId: 'A');
    final b = tab(instanceId: 'B');
    await b.load();
    await queue(a, 'zzz-first');
    await queue(b, 'aaa-second');

    expect(a.items.first.seq, 1);
    expect(b.items.first.seq, 1, reason: 'independent instances collide on seq');

    final one = tab(instanceId: 'C');
    await one.load();
    final two = tab(instanceId: 'D');
    await two.load();

    expect(one.items.map((e) => e.clientUuid).toList(),
        two.items.map((e) => e.clientUuid).toList(),
        reason: 'two loads of the same data must order identically');
  });

  test('K2. single-instance ordering is untouched', () async {
    final a = tab(instanceId: 'A');
    await queue(a, 'first');
    await queue(a, 'second');
    await queue(a, 'third');

    expect(a.items.map((e) => e.seq).toList(), [1, 2, 3]);
    expect(a.items.map((e) => e.clientUuid).toList(),
        ['first', 'second', 'third'],
        reason: 'seq is unique in one instance, so the tiebreaks never run');
  });

  // ═══ MERGE IDENTITY ═══════════════════════════════════════════════════════
  //
  // Caught by outbox_storage_test, not by anything here: the merge keyed on
  // '${item['clientUuid']}', which yields the STRING "null" when the field is
  // absent. Every identity-less record therefore collided on one key and ate
  // the ones before it — deduplication turning into data loss. Records without
  // a clientUuid are now kept apart instead of folded together.

  test('records with no clientUuid are kept, not collapsed together',
      () async {
    backend.values['outbox.instance.LEGACYISH'] = jsonEncode([
      {'label': 'no uuid A', 'rpc': 'ws_record_delivery', 'args': {}},
      {'label': 'no uuid B', 'rpc': 'ws_record_delivery', 'args': {}},
    ]);

    final loaded = await WsOutboxKvStore(backend, instanceId: 'C').load();

    expect(loaded, hasLength(2),
        reason: 'two identity-less records must not merge into one');
    expect(loaded.map((e) => e['label']), containsAll(['no uuid A', 'no uuid B']));
  });

  test('an empty-string clientUuid is treated as no identity', () async {
    backend.values['outbox.instance.ODD'] = jsonEncode([
      {'clientUuid': '', 'label': 'blank A'},
      {'clientUuid': '', 'label': 'blank B'},
    ]);

    final loaded = await WsOutboxKvStore(backend, instanceId: 'C').load();
    expect(loaded, hasLength(2));
  });

  test('real clientUuids still deduplicate across keys', () async {
    // The merge must still do its job — the fix above must not disable it.
    final a = tab(instanceId: 'A');
    await queue(a, 'shared');
    backend.values['outbox.instance.B'] = backend.values['outbox.instance.A']!;

    final fresh = tab(instanceId: 'C');
    await fresh.load();

    expect(fresh.items, hasLength(1),
        reason: 'the same clientUuid in two keys is ONE delivery');
  });

  // ═══ OWNERSHIP STILL APPLIES ACROSS THE MERGE ═════════════════════════════

  test('ownership filtering survives a multi-key merge', () async {
    signedIn = 'user-A';
    final a = tab(instanceId: 'A');
    await queue(a, 'a-1');

    signedIn = 'user-B';
    final b = tab(instanceId: 'B');
    await queue(b, 'b-1');

    final fresh = tab(instanceId: 'C');
    await fresh.load();

    signedIn = 'user-B';
    expect(fresh.visibleToCurrentUser.map((e) => e.clientUuid), ['b-1'],
        reason: "merging keys must not expose one driver's work to another");

    signedIn = 'user-A';
    expect(fresh.visibleToCurrentUser.map((e) => e.clientUuid), ['a-1']);
  });
}
