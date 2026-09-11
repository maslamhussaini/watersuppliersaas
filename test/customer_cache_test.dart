// =============================================================================
// test/customer_cache_test.dart
//
// Phase B3 — customers on the device, so New Delivery can be completed offline.
//
// ─── THE FAILURE THIS FILE MOSTLY EXISTS TO PREVENT ──────────────────────────
//
// A PARTIAL CACHE READ AS COMPLETE.
//
// Quota dies at shard 31 of 50, a naive reader serves two thirds of the
// customers, and a driver concludes the missing one does not exist. That is
// worse than an empty field: an empty field is obviously broken, a short list
// is not. The manifest is the commit record, and most of the group below is
// about refusing to serve anything without a valid one.
//
// Pure Dart: no Flutter binding, no Supabase, no platform channel.
// =============================================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/cache/ws_customer_cache.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';
import 'package:watersuppliersaas/services/supabase_service.dart';

const driverA = 'uid-driver-a';
const driverB = 'uid-driver-b';
const orgOne = 1;
const orgTwo = 2;

List<Map<String, dynamic>> customers(int n, {int from = 1}) => [
      for (var i = from; i < from + n; i++)
        {
          'customerid': i,
          'customername': 'Customer $i',
          'customercode': 'C$i',
          'phone': '030000$i',
          'storeid': i.isEven ? 10 : 20,
          'areaid': 5,
          'areaname': 'Zone 5',
          'rateperbottle': 100,
          'rateoverride': null,
          'bottlebalance': i,
        },
    ];

void main() {
  late WsMemoryKeyValueStore kv;

  setUp(() {
    kv = WsMemoryKeyValueStore();
    WsCustomerCache.storage = () async => kv;
    wsOfflineCustomerSearchUnavailable.value = null;
  });

  Future<bool> put(List<Map<String, dynamic>> rows,
          {String uid = driverA, int orgId = orgOne, DateTime? at}) =>
      WsCustomerCache.replace(uid: uid, orgId: orgId, rows: rows, at: at);

  Future<List<WsCustomerRow>?> get({String uid = driverA, int orgId = orgOne}) =>
      WsCustomerCache.load(uid: uid, orgId: orgId);

  int shardCount() =>
      kv.values.keys.where((k) => k.contains(WsCustomerCache.shardPrefix)).length;

  // ═══ PROJECTION ═══════════════════════════════════════════════════════════

  group('projection', () {
    test('round-trips every field the delivery flow reads', () async {
      await put([
        {
          'customerid': 7,
          'customername': 'Hotel ABC',
          'customercode': 'H1',
          'phone': '03001234567',
          'storeid': 10,
          'areaid': 3,
          'areaname': 'Clifton',
          'rateperbottle': 120,
          'rateoverride': 90,
          'bottlebalance': 4,
        }
      ]);

      final c = (await get())!.single;
      expect(c.customerId, 7);
      expect(c.customerName, 'Hotel ABC');
      expect(c.customerCode, 'H1');
      expect(c.phone, '03001234567');
      expect(c.storeId, 10);
      expect(c.areaName, 'Clifton');
      expect(c.bottleBalance, 4);
      expect(c.effectiveRate, 90, reason: 'rateOverride wins over areaRate');
    });

    test('effectiveRate falls back to the area rate, then zero', () async {
      await put([
        {'customerid': 1, 'customername': 'A', 'rateperbottle': 120},
        {'customerid': 2, 'customername': 'B'},
      ]);
      final rows = (await get())!;
      expect(rows.first.effectiveRate, 120);
      expect(rows.last.effectiveRate, 0);
    });

    // ─── THE SCHEMA MISMATCH THIS GROUP EXISTS FOR ─────────────────────────
    //
    // Population first read vw_ws_customerbalance and failed in the browser:
    //
    //     column vw_ws_customerbalance.storeid does not exist
    //
    // The view is migration 007 with an explicit column list; storeid landed on
    // ws_tblcustomers in migration 015 and the view was never updated. It also
    // exposes the area rate under its real name, `rateperbottle` — there has
    // never been a column called `arearate`. That was only the Dart field name,
    // and reading it here silently produced a null rate on every cached row.
    //
    // Source is now ws_tblcustomers, the same table WsLookupService.customers
    // searches, with areaname and rateperbottle embedded across the existing
    // areaid foreign key.

    test('storeid survives — it is what the branch filter needs', () async {
      await put([
        {'customerid': 1, 'customername': 'A', 'storeid': 42},
        {'customerid': 2, 'customername': 'B'},
      ]);
      final rows = (await get())!;

      expect(rows.first.storeId, 42,
          reason: 'ws_tblcustomers.storeid — absent from the balance view, '
              'which is why the population source changed');
      expect(rows.last.storeId, isNull,
          reason: 'a customer with no branch is legitimate, not an error');
    });

    test('rateperbottle is the area rate, and arearate is nothing', () async {
      await put([
        {'customerid': 1, 'customername': 'A', 'rateperbottle': 150},
        // The old, wrong key. It must NOT be honoured — silently accepting it
        // is how the null rate went unnoticed.
        {'customerid': 2, 'customername': 'B', 'arearate': 150},
      ]);
      final rows = (await get())!;

      expect(rows.first.areaRate, 150);
      expect(rows.last.areaRate, isNull,
          reason: 'there is no such column; reading it produced a null rate on '
              'every row and a zero effectiveRate');
      expect(rows.first.effectiveRate, 150);
      expect(rows.last.effectiveRate, 0);
    });

    test('effectiveRate stays rateOverride ?? ratePerBottle ?? 0', () async {
      await put([
        {'customerid': 1, 'customername': 'A', 'rateperbottle': 100, 'rateoverride': 80},
        {'customerid': 2, 'customername': 'B', 'rateperbottle': 100},
        {'customerid': 3, 'customername': 'C'},
      ]);
      final rows = (await get())!;

      expect(rows[0].effectiveRate, 80, reason: 'the override wins');
      expect(rows[1].effectiveRate, 100, reason: 'then the area rate');
      expect(rows[2].effectiveRate, 0, reason: 'then zero');
    });

    test('a row with no customerid makes the shard unreadable', () async {
      await put(customers(2));
      final m = jsonDecode(kv.values[WsCustomerCache.manifestKey]!);
      final key = '${WsCustomerCache.shardPrefix}${m['generation']}.0';
      kv.values[key] = jsonEncode([
        {'customername': 'No id here'}
      ]);

      expect(await get(), isNull,
          reason: 'a customer that cannot be selected is not a smaller cache');
    });
  });

  // ═══ FLATTENING THE EMBEDDED AREA ═════════════════════════════════════════
  //
  // PostgREST returns an embed as a nested object, or as a single-element list
  // depending on how it resolves the relationship. Both shapes are handled in
  // one place so that variability never reaches a cache reader — and neither
  // shape can be produced from a live response in a unit test, which makes this
  // the part most worth pinning.

  group('the embedded ws_tblareas is flattened onto the row', () {
    test('a nested object becomes areaname + rateperbottle', () {
      final out = WsDataService.flattenCustomerRow({
        'customerid': 1,
        'customername': 'Hotel ABC',
        'storeid': 10,
        'areaid': 3,
        'ws_tblareas': {'areaname': 'Clifton', 'rateperbottle': 120},
      });

      expect(out['areaname'], 'Clifton');
      expect(out['rateperbottle'], 120);
      expect(out.containsKey('ws_tblareas'), isFalse,
          reason: 'the nested shape must not reach the cache');
      expect(out['storeid'], 10, reason: 'the rest of the row is untouched');
    });

    test('a single-element list is handled identically', () {
      final out = WsDataService.flattenCustomerRow({
        'customerid': 1,
        'customername': 'A',
        'ws_tblareas': [
          {'areaname': 'Clifton', 'rateperbottle': 120}
        ],
      });

      expect(out['areaname'], 'Clifton');
      expect(out['rateperbottle'], 120);
    });

    test('a customer with no area survives with nulls', () {
      // areaid is nullable (on delete set null), so this is ordinary data.
      final out = WsDataService.flattenCustomerRow({
        'customerid': 1,
        'customername': 'A',
        'ws_tblareas': null,
      });

      expect(out['areaname'], isNull);
      expect(out['rateperbottle'], isNull);
      expect(out['customerid'], 1);
    });

    test('an empty embed list is not an error', () {
      final out = WsDataService.flattenCustomerRow({
        'customerid': 1,
        'customername': 'A',
        'ws_tblareas': const [],
      });

      expect(out['areaname'], isNull);
      expect(out.containsKey('ws_tblareas'), isFalse);
    });

    test('a flattened row round-trips into WsCustomerRow', () async {
      // The whole point: what flatten produces is what the cache reads.
      final flat = WsDataService.flattenCustomerRow({
        'customerid': 9,
        'customername': 'Hotel ABC',
        'customercode': 'H1',
        'phone': '03001234567',
        'storeid': 10,
        'areaid': 3,
        'rateoverride': null,
        'bottlebalance': 6,
        'ws_tblareas': {'areaname': 'Clifton', 'rateperbottle': 120},
      });

      await put([flat]);
      final c = (await get())!.single;

      expect(c.customerId, 9);
      expect(c.storeId, 10);
      expect(c.areaName, 'Clifton');
      expect(c.areaRate, 120);
      expect(c.effectiveRate, 120);
      expect(c.bottleBalance, 6);
    });
  });

  // ═══ SHARD BOUNDARIES ═════════════════════════════════════════════════════

  group('shard boundaries', () {
    for (final n in [499, 500, 501, 1001]) {
      test('$n customers round-trip exactly', () async {
        expect(await put(customers(n)), isTrue);

        final rows = await get();
        expect(rows, isNotNull);
        expect(rows!, hasLength(n));
        expect(rows.first.customerId, 1);
        expect(rows.last.customerId, n);

        final expectedShards = (n / WsCustomerCache.shardSize).ceil();
        expect(shardCount(), expectedShards);
      });
    }

    test('zero customers is a valid, empty cache', () async {
      expect(await put(const []), isTrue);
      expect(await get(), isEmpty,
          reason: 'an organization with no customers is not a broken cache');
    });
  });

  // ═══ MANIFEST IS THE COMMIT ═══════════════════════════════════════════════

  group('the manifest is the commit record', () {
    test('it is written and names the shard count', () async {
      await put(customers(501));
      final m = jsonDecode(kv.values[WsCustomerCache.manifestKey]!);

      expect(m['shardCount'], 2);
      expect(m['rowCount'], 501);
      expect(m['authUserId'], driverA);
      expect(m['orgId'], orgOne);
    });

    test('MISSING manifest => the whole cache is unavailable', () async {
      await put(customers(600));
      expect(shardCount(), 2);

      kv.values.remove(WsCustomerCache.manifestKey);

      expect(await get(), isNull,
          reason: 'the shards are still there — without the commit they are '
              'not a cache');
    });

    test('unparseable manifest => unavailable', () async {
      await put(customers(10));
      kv.values[WsCustomerCache.manifestKey] = '{not json';
      expect(await get(), isNull);
    });

    test('SHARD-COUNT MISMATCH => unavailable', () async {
      await put(customers(1001)); // 3 shards
      final m = jsonDecode(kv.values[WsCustomerCache.manifestKey]!)
          as Map<String, dynamic>;
      kv.values[WsCustomerCache.manifestKey] =
          jsonEncode({...m, 'shardCount': 5});

      expect(await get(), isNull,
          reason: 'THE PARTIAL-CACHE GUARD: claiming more shards than exist '
              'must never yield the shards that do');
    });

    test('rowCount mismatch => unavailable', () async {
      await put(customers(10));
      final m = jsonDecode(kv.values[WsCustomerCache.manifestKey]!)
          as Map<String, dynamic>;
      kv.values[WsCustomerCache.manifestKey] =
          jsonEncode({...m, 'rowCount': 99});

      expect(await get(), isNull);
    });

    test('a MISSING shard => unavailable, not a shorter list', () async {
      await put(customers(1001));
      final m = jsonDecode(kv.values[WsCustomerCache.manifestKey]!);
      kv.values.remove('${WsCustomerCache.shardPrefix}${m['generation']}.1');

      expect(await get(), isNull,
          reason: 'serving shards 0 and 2 would silently lose 500 customers');
    });

    test('a CORRUPT shard => unavailable', () async {
      await put(customers(600));
      final m = jsonDecode(kv.values[WsCustomerCache.manifestKey]!);
      kv.values['${WsCustomerCache.shardPrefix}${m['generation']}.0'] =
          '{not json';

      expect(await get(), isNull);
    });
  });

  // ═══ CEILING ══════════════════════════════════════════════════════════════

  group('the 25,000 ceiling', () {
    test('exactly 25,000 is cached', () async {
      expect(await put(customers(WsCustomerCache.maxCustomers)), isTrue);
      expect((await get())!, hasLength(WsCustomerCache.maxCustomers));
      expect(wsOfflineCustomerSearchUnavailable.value, isNull);
    });

    test('25,001 caches NOTHING and says why', () async {
      expect(await put(customers(WsCustomerCache.maxCustomers + 1)), isFalse);

      expect(await get(), isNull);
      expect(shardCount(), 0, reason: 'never the first 25,000 of 25,001');
      expect(wsOfflineCustomerSearchUnavailable.value, isNotNull);
      expect(wsOfflineCustomerSearchUnavailable.value, contains('online only'));
    });

    test('going over the ceiling clears a previously good cache', () async {
      await put(customers(100));
      expect(await get(), isNotNull);

      await put(customers(WsCustomerCache.maxCustomers + 1));

      expect(await get(), isNull,
          reason: 'a stale 100-customer cache for a 25,001-customer org would '
              'be confidently wrong');
    });
  });

  // ═══ REFRESH SAFETY ═══════════════════════════════════════════════════════

  group('a refresh never damages a good cache', () {
    test('a quota failure mid-write leaves the OLD cache intact', () async {
      await put(customers(600)); // 2 shards, generation 1
      final before = (await get())!;
      expect(before, hasLength(600));

      // Storage that accepts the first shard then refuses.
      WsCustomerCache.storage = () async => _FlakyKv(kv, failAfterWrites: 1);
      final ok = await put(customers(2000));

      expect(ok, isFalse);

      WsCustomerCache.storage = () async => kv;
      final after = await get();
      expect(after, isNotNull,
          reason: 'THE OLD CACHE MUST SURVIVE — a good stale cache beats none');
      expect(after!, hasLength(600));
      expect(wsOfflineCustomerSearchUnavailable.value, isNotNull);
    });

    test('a successful refresh replaces the rows and removes the old shards',
        () async {
      await put(customers(600));
      final firstGen =
          jsonDecode(kv.values[WsCustomerCache.manifestKey]!)['generation'];

      await put(customers(3, from: 900));

      final rows = (await get())!;
      expect(rows, hasLength(3));
      expect(rows.first.customerId, 900);

      final orphans = kv.values.keys
          .where((k) => k.contains('${WsCustomerCache.shardPrefix}$firstGen.'));
      expect(orphans, isEmpty, reason: 'the superseded generation is removed');
    });

    test('the new generation never collides with the one in use', () async {
      await put(customers(10), at: DateTime.now());
      final gen1 =
          jsonDecode(kv.values[WsCustomerCache.manifestKey]!)['generation'];
      await put(customers(10));
      final gen2 =
          jsonDecode(kv.values[WsCustomerCache.manifestKey]!)['generation'];

      expect(gen2, greaterThan(gen1));
    });
  });

  // ═══ OWNERSHIP ════════════════════════════════════════════════════════════

  group('ownership', () {
    test('another driver gets nothing', () async {
      await put(customers(10), uid: driverA);
      expect(await get(uid: driverB), isNull,
          reason: 'THE SHARED-DEVICE RULE: two drivers, one tablet');
    });

    test('another organization gets nothing', () async {
      await put(customers(10), orgId: orgOne);
      expect(await get(orgId: orgTwo), isNull);
    });

    test('the right user and org gets it', () async {
      await put(customers(10));
      expect(await get(), hasLength(10));
    });

    test('a foreign cache also reads as stale', () async {
      await put(customers(10), uid: driverA, at: DateTime.now());
      expect(
        await WsCustomerCache.isStale(uid: driverB, orgId: orgOne),
        isTrue,
      );
    });
  });

  // ═══ SIGN-OUT ═════════════════════════════════════════════════════════════

  test('clear() removes every shard AND the manifest', () async {
    await put(customers(1001));
    expect(shardCount(), 3);

    await WsCustomerCache.clear();

    expect(kv.values.containsKey(WsCustomerCache.manifestKey), isFalse);
    expect(shardCount(), 0);
    expect(await get(), isNull);
  });

  // ═══ STALENESS ════════════════════════════════════════════════════════════

  group('staleness', () {
    test('no cache is stale', () async {
      expect(await WsCustomerCache.isStale(uid: driverA, orgId: orgOne), isTrue);
    });

    test('a fresh cache is not stale', () async {
      await put(customers(5), at: DateTime.now());
      expect(await WsCustomerCache.isStale(uid: driverA, orgId: orgOne), isFalse);
    });

    test('older than six hours is stale', () async {
      await put(customers(5),
          at: DateTime.now().subtract(const Duration(hours: 7)));
      expect(await WsCustomerCache.isStale(uid: driverA, orgId: orgOne), isTrue);
    });

    test('stale still LOADS — offline, old data beats none', () async {
      await put(customers(5),
          at: DateTime.now().subtract(const Duration(days: 30)));
      expect(await get(), hasLength(5));
    });
  });

  // ═══ SEARCH PARITY ════════════════════════════════════════════════════════

  group('search matches the online semantics', () {
    final rows = [
      const WsCustomerRow(
          customerId: 1,
          customerName: 'Hotel ABC',
          customerCode: 'H1',
          phone: '03001112222',
          storeId: 10),
      const WsCustomerRow(
          customerId: 2,
          customerName: 'abc traders',
          customerCode: 'T9',
          phone: '03335556666',
          storeId: 20),
      const WsCustomerRow(
          customerId: 3,
          customerName: 'Zain Store',
          customerCode: 'ABC-7',
          phone: '03007778888',
          storeId: 10),
    ];

    List<WsCustomerRow> search(String q,
            {int? storeId,
            bool includeAllStores = false,
            bool isMultiStore = false,
            int limit = 20}) =>
        WsCustomerCache.searchIn(rows, q,
            storeId: storeId,
            includeAllStores: includeAllStores,
            isMultiStore: isMultiStore,
            limit: limit);

    test('matches on name, phone AND code — the same three columns', () {
      expect(search('hotel').map((c) => c.customerId), [1]);
      expect(search('3335556').map((c) => c.customerId), [2]);
      expect(search('abc-7').map((c) => c.customerId), [3]);
    });

    test('is case-insensitive, like ilike', () {
      final hits = search('ABC').map((c) => c.customerId).toSet();
      expect(hits, {1, 2, 3},
          reason: 'Hotel ABC by name, abc traders by name, ABC-7 by code');
    });

    test('is a substring match, not a prefix match', () {
      expect(search('raders').map((c) => c.customerId), [2]);
    });

    test('orders by name DESCENDING, case-insensitively', () {
      // The online query is `.order('customername')`, and postgrest 2.8.0
      // signs that as `order(column, {bool ascending = false})` — the default
      // is DESC, not ASC as the SQL keyword suggests. A live request confirms
      // it: order=customername.desc.nullslast.
      final names = search('a').map((c) => c.customerName).toList();
      expect(names, ['Zain Store', 'Hotel ABC', 'abc traders'],
          reason: 'descending, and case-insensitive — a case-SENSITIVE sort '
              'would put lowercase "abc traders" first under DESC');
    });

    test('DESC vs ASC changes MEMBERSHIP, not just order, under the limit', () {
      // Why the sort direction is a correctness issue rather than cosmetics.
      // The online query applies limit(20); reversing the sort returns a
      // different twenty. This is the exact failure a driver would hit:
      // a customer findable online and missing offline.
      final many = [
        for (var i = 1; i <= 30; i++)
          WsCustomerRow(
              customerId: i,
              customerName: 'Customer ${i.toString().padLeft(2, '0')}')
      ];

      final hits = WsCustomerCache.searchIn(many, 'customer', limit: 20);

      expect(hits, hasLength(20));
      expect(hits.first.customerName, 'Customer 30');
      expect(hits.last.customerName, 'Customer 11');
      expect(hits.map((c) => c.customerId), isNot(contains(1)),
          reason: 'ASC would have returned 01–20 — a disjoint set from 11–30');
    });

    test('honours the 20-result limit', () {
      final many = [
        for (var i = 0; i < 50; i++)
          WsCustomerRow(customerId: i, customerName: 'Customer $i')
      ];
      expect(WsCustomerCache.searchIn(many, 'customer', limit: 20), hasLength(20));
    });

    test('filters by branch only when multi-store and not including all', () {
      // [3, 1] not [1, 3]: 'Zain Store' sorts before 'Hotel ABC' descending.
      expect(search('0300', storeId: 10, isMultiStore: true)
          .map((c) => c.customerId), [3, 1]);

      expect(
          search('0300', storeId: 10, isMultiStore: false)
              .map((c) => c.customerId),
          [3, 1],
          reason: 'single-store orgs are never filtered — 2 has no 0300 phone');

      expect(
          search('03', storeId: 10, isMultiStore: true, includeAllStores: true)
              .map((c) => c.customerId)
              .toSet(),
          {1, 2, 3},
          reason: 'includeAllStores spans branches, as it does online');
    });

    test('no match yields an empty list', () {
      expect(search('zzzzz'), isEmpty);
    });
  });

  // ═══ SELECTION BY ID ══════════════════════════════════════════════════════

  test('a cached customer can be found by id for offline selection', () async {
    await put(customers(1001));
    final rows = (await get())!;

    final c = rows.where((r) => r.customerId == 777).single;
    expect(c.customerName, 'Customer 777');
    expect(c.areaName, 'Zone 5',
        reason: 'the area name the delivery screen shows for a selection');
  });

  // ═══ NO SECRET PERSISTED ══════════════════════════════════════════════════

  test('no credential or token is written', () async {
    await put(customers(5));
    final all = kv.values.values.join('\n');
    for (final forbidden in ['access_token', 'refresh_token', 'password', 'bearer']) {
      expect(all.toLowerCase(), isNot(contains(forbidden)));
    }
    expect(all, isNot(matches(RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.'))));
  });
}

/// Accepts [failAfterWrites] writes, then refuses — a quota running out
/// part-way through a multi-shard population.
class _FlakyKv implements WsKeyValueStore {
  final WsMemoryKeyValueStore inner;
  final int failAfterWrites;
  int _writes = 0;

  _FlakyKv(this.inner, {required this.failAfterWrites});

  @override
  Future<void> write(String key, String value) async {
    if (_writes++ >= failAfterWrites) {
      throw StateError('QuotaExceededError');
    }
    return inner.write(key, value);
  }

  @override
  Future<String?> read(String key) => inner.read(key);
  @override
  Future<void> remove(String key) => inner.remove(key);
  @override
  Future<void> clear() => inner.clear();
  @override
  Future<List<String>> keys() => inner.keys();
}
