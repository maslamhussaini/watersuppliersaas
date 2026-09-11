// =============================================================================
// test/store_snapshot_test.dart
//
// Phase B1 — the branch must survive a cold offline start.
//
// ─── THE BLOCKER ─────────────────────────────────────────────────────────────
//
// delivery_screen._save():
//
//     final storeId = WsStoreService.currentStoreId;
//     if (storeId == null) {
//       throw StateError('No store selected — cannot record a delivery.');
//     }
//
// _selected is a static in-memory field, populated only by load() calling the
// ws_my_stores RPC. Offline on a cold start it is null, so Save throws BEFORE
// the delivery reaches the outbox — the durable queue never gets a chance.
//
// This is why B1 came first: caching customers and products would not have
// helped, because this fails earlier, inside _save itself.
//
// ─── WHAT MUST REMAIN TRUE ───────────────────────────────────────────────────
//
// ws_my_stores applies ws.can_access_store() server-side and is the only list
// worth trusting. The snapshot REPLAYS that answer; it never computes one. RLS
// is untouched, and ws.resolve_store still raises 22023 for a store outside the
// caller's organization — so a tampered snapshot buys a rejected delivery, not
// a cross-tenant write.
//
// Pure Dart: no Flutter binding, no Supabase, no platform channel.
// =============================================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';
import 'package:watersuppliersaas/services/store_service.dart';
import 'package:watersuppliersaas/services/ws_store_snapshot.dart';

const driverA = 'uid-driver-a';
const driverB = 'uid-driver-b';
const orgOne = 1;
const orgTwo = 2;

List<WsStore> branches() => const [
      WsStore(
          storeId: 10, storeCode: 'MAIN', storeName: 'Main', isDefault: true),
      WsStore(
          storeId: 20, storeCode: 'NTH', storeName: 'North', isDefault: false),
    ];

void main() {
  late WsMemoryKeyValueStore kv;
  late WsStoreSnapshotStore store;

  setUp(() {
    kv = WsMemoryKeyValueStore();
    store = WsStoreSnapshotStore(kv);
  });

  WsStoreSnapshot snapshot({
    String uid = driverA,
    int orgId = orgOne,
    int? selected = 20,
    List<WsStore>? stores,
  }) =>
      WsStoreSnapshot.of(
        authUserId: uid,
        orgId: orgId,
        stores: stores ?? branches(),
        selectedStoreId: selected,
      );

  // ═══ 1 · ONLINE LOAD PERSISTS THE SNAPSHOT ════════════════════════════════

  group('1. a successful online load is written down', () {
    test('the snapshot round-trips', () async {
      await store.write(snapshot());
      final back = await store.readFor(driverA, orgOne);

      expect(back, isNotNull);
      expect(back!.authUserId, driverA);
      expect(back.orgId, orgOne);
      expect(back.selectedStoreId, 20);
      expect(back.storeList.map((s) => s.storeId), [10, 20]);
    });

    test('branches rebuild through the SAME parser as the server', () async {
      // Stored under the ws_my_stores column names, so WsStore.fromJson reads
      // it — not a second parser that could drift from the online path.
      await store.write(snapshot());
      final rebuilt = (await store.readFor(driverA, orgOne))!.storeList;

      expect(rebuilt.first.storeName, 'Main');
      expect(rebuilt.first.storeCode, 'MAIN');
      expect(rebuilt.first.isDefault, isTrue);
      expect(rebuilt.last.isDefault, isFalse);
    });

    test('it uses the shared key/value seam, not a new mechanism', () async {
      await store.write(snapshot());
      expect(kv.values.keys, contains(WsStoreSnapshotStore.storageKey));
    });

    test('a later write replaces the earlier — the server is authoritative',
        () async {
      await store.write(snapshot(selected: 20));
      await store.write(snapshot(
        selected: 10,
        stores: const [
          WsStore(
              storeId: 10, storeCode: 'MAIN', storeName: 'Main', isDefault: true)
        ],
      ));

      final back = await store.readFor(driverA, orgOne);
      expect(back!.selectedStoreId, 10);
      expect(back.storeList, hasLength(1),
          reason: 'a branch revoked server-side must not outlive the refresh');
    });
  });

  // ═══ 2 · A STORAGE FAILURE MUST NOT BREAK A GOOD ONLINE LOAD ══════════════

  test('2. a storage failure is survivable — the branches are already in memory',
      () async {
    final failing = _ThrowingKv();
    final s = WsStoreSnapshotStore(failing);

    await expectLater(s.write(snapshot()), throwsA(isA<StateError>()));

    // WsStoreService._persistSnapshot wraps this in try/catch precisely so a
    // full disk cannot fail a load that otherwise worked. Reading back is
    // likewise non-fatal.
    expect(await s.readFor(driverA, orgOne), isNull);
  });

  // ═══ 3 · OFFLINE RESTORE FOR THE SAME USER AND ORG ════════════════════════

  test('3. a valid snapshot is returned for the same user and org', () async {
    await store.write(snapshot());
    final back = await store.readFor(driverA, orgOne);

    expect(back, isNotNull);
    expect(back!.selectedStoreId, 20,
        reason: 'the branch the driver was working in, not the default');
  });

  // ═══ 4 · ANOTHER USER IS REFUSED ══════════════════════════════════════════

  test('4. a snapshot belonging to another driver is refused', () async {
    await store.write(snapshot(uid: driverA));

    expect(await store.readFor(driverB, orgOne), isNull,
        reason: 'THE SHARED-DEVICE RULE: two drivers, one tablet. The second '
            "must never inherit the first's branch");
  });

  // ═══ 5 · ANOTHER ORGANIZATION IS REFUSED ══════════════════════════════════

  test('5. a snapshot belonging to another organization is refused', () async {
    await store.write(snapshot(orgId: orgOne));

    expect(await store.readFor(driverA, orgTwo), isNull,
        reason: 'a user can belong to several organizations; branches from one '
            'must never be offered while another is active');
  });

  // ═══ 6 · ABSENCE NEVER INVENTS A BRANCH ═══════════════════════════════════

  group('6. absence invents nothing', () {
    test('an empty store yields nothing', () async {
      expect(await store.readFor(driverA, orgOne), isNull);
    });

    test('an empty string yields nothing', () async {
      kv.values[WsStoreSnapshotStore.storageKey] = '';
      expect(await store.readFor(driverA, orgOne), isNull);
    });

    test('a snapshot with no readable branch yields nothing', () async {
      // Cannot satisfy select(), so it is indistinguishable from having none.
      await store.write(snapshot(stores: const []));
      expect(await store.readFor(driverA, orgOne), isNull);
    });
  });

  // ═══ 7 · MALFORMED INPUT FAILS SAFELY ═════════════════════════════════════

  group('7. corrupt snapshots fail safely', () {
    void put(String raw) => kv.values[WsStoreSnapshotStore.storageKey] = raw;

    test('unparseable JSON yields null, not an exception', () async {
      put('{not json');
      expect(await store.readFor(driverA, orgOne), isNull);
    });

    test('valid JSON of the wrong shape yields null', () async {
      put(jsonEncode(['a', 'list']));
      expect(await store.readFor(driverA, orgOne), isNull);
    });

    test('a missing authUserId yields null', () async {
      put(jsonEncode({
        'orgId': orgOne,
        'stores': [],
        'savedAt': DateTime.now().toIso8601String(),
      }));
      expect(await store.readFor(driverA, orgOne), isNull);
    });

    test('a missing orgId yields null', () async {
      put(jsonEncode({
        'authUserId': driverA,
        'stores': [],
        'savedAt': DateTime.now().toIso8601String(),
      }));
      expect(await store.readFor(driverA, orgOne), isNull,
          reason: 'without an org it cannot be scoped, so it is unusable');
    });

    test('one unreadable branch does not cost the others', () async {
      put(jsonEncode({
        'authUserId': driverA,
        'orgId': orgOne,
        'stores': [
          {'storeid': 10, 'storename': 'Main', 'isdefault': true},
          {'no_storeid_here': true},
          {'storeid': 20, 'storename': 'North', 'isdefault': false},
        ],
        'selectedStoreId': 20,
        'savedAt': DateTime.now().toIso8601String(),
      }));

      final back = await store.readFor(driverA, orgOne);
      expect(back, isNotNull);
      expect(back!.storeList.map((s) => s.storeId), [10, 20],
          reason: 'per-row isolation: one bad row must not lose the branches a '
              'driver can actually use');
    });

    test('readFor never throws', () async {
      put('  binary garbage');
      expect(() => store.readFor(driverA, orgOne), returnsNormally);
      expect(await store.readFor(driverA, orgOne), isNull);
    });
  });

  // ═══ 8 · SIGN-OUT CLEARS IT ═══════════════════════════════════════════════

  test('8. clear() removes the snapshot', () async {
    await store.write(snapshot());
    expect(await store.readFor(driverA, orgOne), isNotNull);

    await store.clear();

    expect(await store.readFor(driverA, orgOne), isNull);
    expect(kv.values.containsKey(WsStoreSnapshotStore.storageKey), isFalse);
  });

  // ═══ 9 · WHAT _save() ACTUALLY NEEDS ══════════════════════════════════════

  group('9. the restored selection is usable by _save()', () {
    test('a stored selection survives', () async {
      await store.write(snapshot(selected: 20));
      final back = await store.readFor(driverA, orgOne);

      expect(back!.selectedStoreId, isNotNull,
          reason: 'THE BLOCKER: currentStoreId null makes _save throw before '
              'the delivery reaches the outbox');
      expect(back.storeList.any((s) => s.storeId == back.selectedStoreId),
          isTrue,
          reason: 'and it must still be one of the branches the server '
              'offered, or select() would reject it');
    });

    test('a selection no longer in the list is detectable', () async {
      // WsStoreService falls back to the default rather than trusting the
      // stored id. Here we only assert the snapshot exposes enough to notice.
      await store.write(snapshot(selected: 999));
      final back = await store.readFor(driverA, orgOne);

      expect(back!.selectedStoreId, 999);
      expect(back.storeList.any((s) => s.storeId == 999), isFalse);
    });

    test('a null selection is preserved as null, not defaulted here', () async {
      await store.write(snapshot(selected: null));
      final back = await store.readFor(driverA, orgOne);

      expect(back!.selectedStoreId, isNull,
          reason: 'choosing the default belongs to WsStoreService, not to the '
              'storage layer');
    });
  });

  // ═══ NO SECRET IS EVER PERSISTED ══════════════════════════════════════════

  test('no credential, token or secret is written', () async {
    await store.write(snapshot());
    final raw = kv.values[WsStoreSnapshotStore.storageKey]!;

    for (final forbidden in [
      'access_token', 'refresh_token', 'password', 'apikey', 'bearer',
    ]) {
      expect(raw.toLowerCase(), isNot(contains(forbidden)));
    }
    expect(raw, isNot(matches(RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.'))),
        reason: 'that is the shape of a JWT');
  });

  test('the persisted surface is exactly the declared fields', () async {
    await store.write(snapshot());
    final decoded = jsonDecode(kv.values[WsStoreSnapshotStore.storageKey]!)
        as Map<String, dynamic>;

    expect(decoded.keys.toSet(),
        {'authUserId', 'orgId', 'stores', 'selectedStoreId', 'savedAt'},
        reason: 'a new field here is a deliberate decision, not an accident');
  });
}

/// Storage that refuses to write, to drive the one path that cannot otherwise
/// be provoked.
class _ThrowingKv implements WsKeyValueStore {
  @override
  Future<String?> read(String key) async => throw StateError('storage is gone');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('storage is gone');

  @override
  Future<void> remove(String key) async => throw StateError('storage is gone');

  @override
  Future<void> clear() async => throw StateError('storage is gone');

  @override
  Future<List<String>> keys() async => throw StateError('storage is gone');
}
