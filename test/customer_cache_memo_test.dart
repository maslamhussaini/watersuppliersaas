// =============================================================================
// test/customer_cache_memo_test.dart
//
// The in-memory memo for the parsed customer cache.
//
// ─── WHAT IT IS FOR ──────────────────────────────────────────────────────────
//
// load() is called once per KEYSTROKE by the offline customer search, and again
// on selection. At the 25,000 ceiling each call meant 50 shard reads, 50
// jsonDecodes and 25,000 object constructions. The memo removes the repeated
// parse. It changes no format, no rule, and no ordering.
//
// ─── WHAT IT MUST NEVER DO ───────────────────────────────────────────────────
//
// A memo on a MULTI-TENANT cache is a correctness risk before it is a
// performance win: serving one driver's customers to another, or resurrecting a
// cache the manifest says is gone, would be far worse than the slowness it
// fixes. So most of this file is about the cases where it must NOT be used.
//
// The counting store is the instrument: it records every read, so "did this
// call touch the shards" is observable rather than inferred from a stopwatch.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/cache/ws_customer_cache.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';

/// Counts reads per key so shard access can be asserted on directly.
class CountingStore implements WsKeyValueStore {
  final WsMemoryKeyValueStore inner = WsMemoryKeyValueStore();
  final List<String> reads = [];

  int get shardReads =>
      reads.where((k) => k.contains(WsCustomerCache.shardPrefix)).length;
  int get manifestReads =>
      reads.where((k) => k == WsCustomerCache.manifestKey).length;
  void resetCounts() => reads.clear();

  @override
  Future<String?> read(String key) {
    reads.add(key);
    return inner.read(key);
  }

  @override
  Future<void> write(String key, String value) => inner.write(key, value);
  @override
  Future<void> remove(String key) => inner.remove(key);
  @override
  Future<List<String>> keys() => inner.keys();
  @override
  Future<void> clear() => inner.clear();
}

const driverA = 'uid-driver-a';
const driverB = 'uid-driver-b';
const orgOne = 1;
const orgTwo = 2;

List<Map<String, dynamic>> customers(int n, {String prefix = 'Customer'}) => [
      for (var i = 1; i <= n; i++)
        {
          'customerid': i,
          'customername': '$prefix $i',
          'phone': '030000$i',
          'storeid': 10,
          'areaid': 5,
          'areaname': 'Zone 5',
          'rateperbottle': 100,
          'bottlebalance': i,
        },
    ];

void main() {
  late CountingStore kv;

  setUp(() {
    kv = CountingStore();
    WsCustomerCache.storage = () async => kv;
    WsCustomerCache.forgetMemo(); // static state must not leak between tests
    wsOfflineCustomerSearchUnavailable.value = null;
  });

  tearDown(WsCustomerCache.forgetMemo);

  Future<bool> put(List<Map<String, dynamic>> rows,
          {String uid = driverA, int orgId = orgOne}) =>
      WsCustomerCache.replace(uid: uid, orgId: orgId, rows: rows);

  Future<List<WsCustomerRow>?> load(
          {String uid = driverA, int orgId = orgOne}) =>
      WsCustomerCache.load(uid: uid, orgId: orgId);

  // ═══ THE POINT OF THE MEMO ════════════════════════════════════════════════

  test('the first load parses the shards', () async {
    await put(customers(1200)); // 3 shards at shardSize 500
    kv.resetCounts();

    final rows = await load();

    expect(rows, hasLength(1200));
    expect(kv.shardReads, 3, reason: 'a cold load must read every shard');
  });

  test('a second load with the same identity reads NO shards', () async {
    await put(customers(1200));
    await load();
    kv.resetCounts();

    final rows = await load();

    expect(rows, hasLength(1200));
    expect(kv.shardReads, 0,
        reason: 'THE FIX: this is the per-keystroke re-parse being removed');
    expect(kv.manifestReads, 1,
        reason: 'the manifest is STILL read every time — it stays the only '
            'authority on whether a cache exists and whose it is');
  });

  test('the memo survives many loads, as a keystroke burst would', () async {
    await put(customers(1200));
    await load();
    kv.resetCounts();

    for (var i = 0; i < 10; i++) {
      expect(await load(), hasLength(1200));
    }
    expect(kv.shardReads, 0);
  });

  // ═══ INVALIDATION ═════════════════════════════════════════════════════════

  test('replace() invalidates — a later load sees the NEW rows', () async {
    await put(customers(600, prefix: 'Old'));
    expect((await load())!.first.customerName, 'Old 1');

    await put(customers(600, prefix: 'New'));
    kv.resetCounts();
    final rows = await load();

    expect(rows!.first.customerName, 'New 1',
        reason: 'a stale memo here would show customers that no longer exist');
    expect(kv.shardReads, greaterThan(0), reason: 're-parsed, not reused');
  });

  /// ─── THIS TEST HAS LESS TEETH THAN IT LOOKS, AND THAT IS WORTH SAYING ────
  ///
  /// Mutation testing: deleting `forgetMemo()` from clear() breaks NOTHING
  /// here. The reason is structural — clear() removes the manifest, and load()
  /// returns null on a missing manifest BEFORE it ever consults the memo. So a
  /// cleared cache can never be served from memory whether the memo was reset
  /// or not.
  ///
  /// The forgetMemo() call in clear() therefore buys memory release on
  /// sign-out (several MB at the ceiling), not correctness. It is kept for
  /// that reason. This test pins the OUTCOME that matters — a cleared cache
  /// reads as absent — and is recorded here as evidence about what it does
  /// not prove, rather than left to imply coverage it does not have.
  test('clear() leaves no readable cache', () async {
    await put(customers(600));
    expect(await load(), isNotNull);

    await WsCustomerCache.clear();

    expect(await load(), isNull,
        reason: 'the sign-out path, via WsMasterCache.clear()');
  });

  test('a generation change is never served from the old memo', () async {
    await put(customers(600, prefix: 'Gen1'));
    await load(); // memo now holds generation 1

    // A second snapshot writes a NEW generation and commits the manifest last.
    await put(customers(600, prefix: 'Gen2'));

    expect((await load())!.first.customerName, 'Gen2 1',
        reason: 'generation IS the memo key, so a new snapshot keys out the '
            'previous one by construction');
  });

  // ═══ OWNERSHIP — THE PART THAT MATTERS MOST ═══════════════════════════════

  test('another user gets nothing, not the memoised rows', () async {
    await put(customers(600), uid: driverA);
    expect(await load(uid: driverA), hasLength(600));

    expect(await load(uid: driverB), isNull,
        reason: "one driver's customers must never reach another on a shared "
            'tablet — ownership is re-checked from the manifest on EVERY read');
  });

  test('another organization gets nothing, not the memoised rows', () async {
    await put(customers(600), orgId: orgOne);
    expect(await load(orgId: orgOne), hasLength(600));

    expect(await load(orgId: orgTwo), isNull,
        reason: 'a user in two organizations must not see one while the other '
            'is selected');
  });

  test('a refused read does not evict the legitimate memo', () async {
    await put(customers(600), uid: driverA);
    await load(uid: driverA);

    await load(uid: driverB); // refused
    kv.resetCounts();

    expect(await load(uid: driverA), hasLength(600));
    expect(kv.shardReads, 0,
        reason: 'the rightful owner should not be punished by someone else '
            'being turned away');
  });

  // ═══ SAFETY PROTOCOL UNCHANGED ════════════════════════════════════════════

  test('a corrupt shard is never memoised as a good cache', () async {
    await put(customers(600));
    // Break one shard AFTER a successful cold read would have happened.
    final shard = (await kv.keys())
        .firstWhere((k) => k.contains(WsCustomerCache.shardPrefix));
    await kv.write(shard, 'not json');

    expect(await load(), isNull,
        reason: 'all-or-nothing still holds');
    expect(await load(), isNull,
        reason: 'and the failed read must not have populated the memo');
  });

  test('the returned list cannot be mutated by one caller', () async {
    await put(customers(600));
    final rows = (await load())!;

    expect(() => rows.sort((a, b) => 0), throwsUnsupportedError,
        reason: 'callers share one instance now, so in-place mutation would '
            'corrupt the next reader');
  });

  test('search results are unchanged by memoisation', () async {
    await put(customers(30));
    final first = WsCustomerCache.searchIn((await load())!, 'customer',
        limit: 20);
    final second = WsCustomerCache.searchIn((await load())!, 'customer',
        limit: 20);

    expect(first.map((c) => c.customerId), second.map((c) => c.customerId));
    expect(first.first.customerName, 'Customer 9',
        reason: 'DESC ordering is untouched by this change');
  });
}
