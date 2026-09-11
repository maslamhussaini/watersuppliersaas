// =============================================================================
// test/master_cache_test.dart
//
// Phase B2 — staff and products available offline.
//
// New Delivery could not open offline: fetchStaff() threw (unguarded, from a
// bare `_load();` in initState, so it became an unhandled async error), and
// fetchProducts()/fetchDefaultProductId() degraded to an empty picker.
//
// ─── THE RULES THIS FILE PINS ────────────────────────────────────────────────
//
// FALLBACK, NEVER PREFERRED. Every read asks the server first; the cache
// answers only when the server could not. A successful fetch always overwrites.
//
// OWNERSHIP. Bound to uid AND orgId, the same rule WsSessionSnapshot and
// WsStoreSnapshot already apply. Two drivers on one tablet must not see each
// other's staff; a user in several organizations must not see one org's
// products while another is active.
//
// NEVER FATAL. A cache write must not fail a fetch that already succeeded, and
// a read must not throw. The outbox shares this storage — losing a delivery to
// a cache write would be an appalling trade.
//
// Scope: staff and products only. Customers are B3 (sharding + a 25,000
// ceiling). Areas are not cached — New Delivery uses areaName only as picker
// subtitle text. Pricing is not cached and is unchanged.
// =============================================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/cache/ws_master_cache.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';

const driverA = 'uid-driver-a';
const driverB = 'uid-driver-b';
const orgOne = 1;
const orgTwo = 2;

final staffRows = [
  {'internaluserid': 1, 'fullname': 'Asif', 'isactive': true},
  {'internaluserid': 2, 'fullname': 'Bilal', 'isactive': true},
];

final productRows = [
  {'productid': 1, 'productname': '19 Ltr Bottle', 'saleprice': 120},
  {'productid': 2, 'productname': '10 Ltr Bottle', 'saleprice': 200},
];

void main() {
  late WsMemoryKeyValueStore kv;

  setUp(() {
    kv = WsMemoryKeyValueStore();
    WsMasterCache.storage = () async => kv;
  });

  tearDown(() => WsMasterCache.storage = () async => WsMemoryKeyValueStore());

  Future<void> writeStaff({String uid = driverA, int orgId = orgOne, DateTime? at}) =>
      WsMasterCache.write(WsMasterCache.staffKey,
          uid: uid, orgId: orgId, rows: staffRows, at: at);

  // ═══ 1 · A SUCCESSFUL FETCH IS WRITTEN DOWN ═══════════════════════════════

  group('1. writing', () {
    test('rows round-trip', () async {
      await writeStaff();
      final env = await WsMasterCache.read(WsMasterCache.staffKey,
          uid: driverA, orgId: orgOne);

      expect(env, isNotNull);
      expect(env!.rows, hasLength(2));
      expect(env.rows.first['fullname'], 'Asif');
      expect(env.authUserId, driverA);
      expect(env.orgId, orgOne);
    });

    test('meta carries the default product id', () async {
      await WsMasterCache.write(WsMasterCache.productsKey,
          uid: driverA,
          orgId: orgOne,
          rows: productRows,
          meta: {'defaultProductId': 1});

      final env = await WsMasterCache.read(WsMasterCache.productsKey,
          uid: driverA, orgId: orgOne);
      expect(env!.meta['defaultProductId'], 1,
          reason: 'one number, meaningless without the list it indexes into, '
              'so it lives with that list rather than in a key of its own');
    });

    test('a later write replaces the earlier — the server is authoritative',
        () async {
      await writeStaff();
      await WsMasterCache.write(WsMasterCache.staffKey,
          uid: driverA, orgId: orgOne, rows: [staffRows.first]);

      final env = await WsMasterCache.read(WsMasterCache.staffKey,
          uid: driverA, orgId: orgOne);
      expect(env!.rows, hasLength(1),
          reason: 'a driver deactivated server-side must not outlive a refresh');
    });

    test('staff and products are separate entries', () async {
      await writeStaff();
      await WsMasterCache.write(WsMasterCache.productsKey,
          uid: driverA, orgId: orgOne, rows: productRows);

      expect(kv.values.keys,
          containsAll([WsMasterCache.staffKey, WsMasterCache.productsKey]));
    });

    test('it uses the shared key/value seam, not a new mechanism', () async {
      await writeStaff();
      expect(kv.values.keys, contains(WsMasterCache.staffKey));
    });
  });

  // ═══ 2 · STORAGE FAILURE IS NEVER FATAL ═══════════════════════════════════

  group('2. a failing store never breaks the caller', () {
    setUp(() => WsMasterCache.storage = () async => _ThrowingKv());

    test('write swallows and logs rather than throwing', () async {
      // The caller already has its answer from the server. A full quota must
      // not turn a successful fetch into an exception.
      expect(
        WsMasterCache.write(WsMasterCache.staffKey,
            uid: driverA, orgId: orgOne, rows: staffRows),
        completes,
      );
    });

    test('read yields null rather than throwing', () async {
      expect(
        await WsMasterCache.read(WsMasterCache.staffKey,
            uid: driverA, orgId: orgOne),
        isNull,
      );
    });

    test('clear is survivable', () async {
      expect(WsMasterCache.clear(), completes);
    });

    test('isStale reports stale when storage is unusable', () async {
      expect(
        await WsMasterCache.isStale(WsMasterCache.staffKey,
            uid: driverA, orgId: orgOne),
        isTrue,
        reason: 'unknown age means worth refreshing, not worth trusting',
      );
    });
  });

  // ═══ 3/4 · OWNERSHIP ══════════════════════════════════════════════════════

  group('3. bound to the user and the organization', () {
    test("another driver's cache is refused", () async {
      await writeStaff(uid: driverA);

      expect(
        await WsMasterCache.read(WsMasterCache.staffKey,
            uid: driverB, orgId: orgOne),
        isNull,
        reason: 'THE SHARED-DEVICE RULE: two drivers, one tablet',
      );
    });

    test("another organization's cache is refused", () async {
      await writeStaff(orgId: orgOne);

      expect(
        await WsMasterCache.read(WsMasterCache.staffKey,
            uid: driverA, orgId: orgTwo),
        isNull,
        reason: 'a user can belong to several organizations; one org\'s staff '
            'must never appear while another is active',
      );
    });

    test('the right user and org still gets it', () async {
      await writeStaff();
      expect(
        await WsMasterCache.read(WsMasterCache.staffKey,
            uid: driverA, orgId: orgOne),
        isNotNull,
      );
    });
  });

  // ═══ 5 · STALENESS DRIVES THE REFRESH ═════════════════════════════════════

  group('5. staleness', () {
    test('a missing entry is stale — this is what makes the first refresh run',
        () async {
      expect(
        await WsMasterCache.isStale(WsMasterCache.staffKey,
            uid: driverA, orgId: orgOne),
        isTrue,
      );
    });

    test('a fresh entry is not stale', () async {
      await writeStaff(at: DateTime.now());
      expect(
        await WsMasterCache.isStale(WsMasterCache.staffKey,
            uid: driverA, orgId: orgOne),
        isFalse,
      );
    });

    test('an old entry is stale', () async {
      await writeStaff(at: DateTime.now().subtract(const Duration(hours: 2)));
      expect(
        await WsMasterCache.isStale(WsMasterCache.staffKey,
            uid: driverA, orgId: orgOne),
        isTrue,
      );
    });

    test('stale still READS — a stale cache beats none offline', () async {
      await writeStaff(at: DateTime.now().subtract(const Duration(days: 30)));
      final env = await WsMasterCache.read(WsMasterCache.staffKey,
          uid: driverA, orgId: orgOne);

      expect(env, isNotNull,
          reason: 'staleAfter marks data worth refreshing, NOT data to discard');
      expect(env!.rows, hasLength(2));
    });

    test("another user's entry reads as stale", () async {
      await writeStaff(uid: driverA, at: DateTime.now());
      expect(
        await WsMasterCache.isStale(WsMasterCache.staffKey,
            uid: driverB, orgId: orgOne),
        isTrue,
      );
    });
  });

  // ═══ 6 · MALFORMED INPUT FAILS SAFELY ═════════════════════════════════════

  group('6. corrupt entries fail safely', () {
    void put(String raw) => kv.values[WsMasterCache.staffKey] = raw;

    Future<WsCacheEnvelope?> readStaff() => WsMasterCache.read(
        WsMasterCache.staffKey, uid: driverA, orgId: orgOne);

    test('unparseable JSON yields null', () async {
      put('{not json');
      expect(await readStaff(), isNull);
    });

    test('valid JSON of the wrong shape yields null', () async {
      put(jsonEncode(['a', 'list']));
      expect(await readStaff(), isNull);
    });

    test('a missing authUserId yields null', () async {
      put(jsonEncode({'orgId': orgOne, 'rows': [], 'cachedAt': '2026-01-01'}));
      expect(await readStaff(), isNull);
    });

    test('a missing orgId yields null', () async {
      put(jsonEncode(
          {'authUserId': driverA, 'rows': [], 'cachedAt': '2026-01-01'}));
      expect(await readStaff(), isNull);
    });

    test('a missing cachedAt yields null', () async {
      put(jsonEncode({'authUserId': driverA, 'orgId': orgOne, 'rows': []}));
      expect(await readStaff(), isNull,
          reason: 'without an age it cannot drive the refresh trigger');
    });

    test('one unreadable row does not cost the others', () async {
      put(jsonEncode({
        'authUserId': driverA,
        'orgId': orgOne,
        'cachedAt': DateTime.now().toIso8601String(),
        'rows': [
          {'internaluserid': 1, 'fullname': 'Asif'},
          'this is not a row',
          {'internaluserid': 2, 'fullname': 'Bilal'},
        ],
      }));

      final env = await readStaff();
      expect(env!.rows, hasLength(2),
          reason: 'per-row isolation, as the store snapshot already applies to '
              'branches');
    });

    test('an empty string yields null', () async {
      put('');
      expect(await readStaff(), isNull);
    });

    test('read never throws', () async {
      put('  binary garbage');
      expect(() => readStaff(), returnsNormally);
      expect(await readStaff(), isNull);
    });
  });

  // ═══ 7 · SIGN-OUT CLEARS BOTH ═════════════════════════════════════════════

  test('7. clear() removes staff AND products', () async {
    await writeStaff();
    await WsMasterCache.write(WsMasterCache.productsKey,
        uid: driverA, orgId: orgOne, rows: productRows);

    await WsMasterCache.clear();

    expect(kv.values.containsKey(WsMasterCache.staffKey), isFalse);
    expect(kv.values.containsKey(WsMasterCache.productsKey), isFalse);
  });

  // ═══ NO SECRET IS PERSISTED ═══════════════════════════════════════════════

  test('no credential, token or secret is written', () async {
    await writeStaff();
    final raw = kv.values[WsMasterCache.staffKey]!;

    for (final forbidden in [
      'access_token', 'refresh_token', 'password', 'apikey', 'bearer',
    ]) {
      expect(raw.toLowerCase(), isNot(contains(forbidden)));
    }
    expect(raw, isNot(matches(RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.'))));
  });

  test('the persisted surface is exactly the declared fields', () async {
    await writeStaff();
    final decoded =
        jsonDecode(kv.values[WsMasterCache.staffKey]!) as Map<String, dynamic>;

    expect(decoded.keys.toSet(),
        {'authUserId', 'orgId', 'cachedAt', 'rows', 'meta'},
        reason: 'a new field here is a deliberate decision, not an accident');
  });
}

/// Storage that refuses everything, to drive the paths that cannot otherwise
/// be provoked.
class _ThrowingKv implements WsKeyValueStore {
  @override
  Future<String?> read(String key) async => throw StateError('storage is gone');
  @override
  Future<void> write(String k, String v) async =>
      throw StateError('storage is gone');
  @override
  Future<void> remove(String key) async => throw StateError('storage is gone');
  @override
  Future<void> clear() async => throw StateError('storage is gone');
  @override
  Future<List<String>> keys() async => throw StateError('storage is gone');
}
