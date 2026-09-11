// =============================================================================
// test/session_snapshot_test.dart
//
// Phase A — the app must open without a network.
//
// ─── THE PROBLEM ─────────────────────────────────────────────────────────────
//
// WsAuthGate gates the whole application behind two live PostgREST queries:
// currentOrganization() and resolveRole(). Offline the first hangs on TCP —
// the "stuck on loading" report — then fails into "Could not load your
// organization". The user never reaches a screen, so every offline-first
// mechanism below that point is unreachable too.
//
// Neither question changes minute to minute. So the answer is written down and
// used ONLY when the server cannot be asked.
//
// ─── WHAT MUST REMAIN TRUE ───────────────────────────────────────────────────
//
// This is not an authentication bypass and these tests exist mostly to prove
// that. The snapshot is read only after Supabase has restored a session and
// produced a uid; it cannot create one. It is bound to that uid, so a shared
// tablet cannot hand the previous driver's organization to the next. And it is
// never preferred over the server — whenever the server answers, it wins.
//
// Permission codes decide which controls RENDER. Every write is still checked
// by RLS, which this cannot reach, so a tampered snapshot buys a visible menu
// item and a server rejection behind it.
// =============================================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/models/ws_models.dart';
import 'package:watersuppliersaas/services/auth/ws_session_snapshot.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';

const driverA = 'uid-driver-a';
const driverB = 'uid-driver-b';

WsOrganization org({int id = 7, String name = 'Blue Water'}) => WsOrganization(
      orgId: id,
      authUserId: driverA,
      orgName: name,
      ownerName: 'Owner',
      phone: '+923001234567',
      address: 'Karachi',
      currencySymbol: 'Rs',
    );

void main() {
  late WsMemoryKeyValueStore kv;
  late WsSessionSnapshotStore store;

  setUp(() {
    kv = WsMemoryKeyValueStore();
    store = WsSessionSnapshotStore(kv);
  });

  WsSessionSnapshot snapshotFor(
    String uid, {
    int orgId = 7,
    WsUserRole role = WsUserRole.admin,
    Set<String> perms = const {'delivery.manage', 'customers.view'},
  }) =>
      WsSessionSnapshot.of(
        authUserId: uid,
        org: org(id: orgId),
        role: role,
        permissions: WsPermissions(perms),
      );

  // ═══ 1 · ONLINE RESOLUTION SAVES THE SNAPSHOT ═════════════════════════════

  group('online resolution writes a usable snapshot', () {
    test('a written snapshot round-trips', () async {
      await store.write(snapshotFor(driverA));
      final back = await store.readFor(driverA);

      expect(back, isNotNull);
      expect(back!.authUserId, driverA);
      expect(back.orgId, 7);
      expect(back.role, WsUserRole.admin);
      expect(back.permissions.has('delivery.manage'), isTrue);
      expect(back.permissions.has('org.manage'), isFalse);
    });

    test('the organization rebuilds through the SAME parser as the server',
        () async {
      // Deliberately not a second serialiser: the snapshot stores the
      // snake_case column names WsOrganization.fromJson already reads, so it
      // cannot drift from the online path.
      await store.write(snapshotFor(driverA));
      final rebuilt = (await store.readFor(driverA))!.organizationOrNull;

      expect(rebuilt, isNotNull);
      expect(rebuilt!.orgId, 7);
      expect(rebuilt.orgName, 'Blue Water');
      expect(rebuilt.currencySymbol, 'Rs');
    });

    test('it is stored under the shared key/value seam, not a new mechanism',
        () async {
      await store.write(snapshotFor(driverA));
      expect(kv.values.keys, contains(WsSessionSnapshotStore.storageKey));
    });

    test('a later write replaces the earlier one — the server is authoritative',
        () async {
      await store.write(snapshotFor(driverA, role: WsUserRole.admin));
      await store.write(snapshotFor(driverA,
          role: WsUserRole.staff, perms: {'delivery.view'}));

      final back = await store.readFor(driverA);
      expect(back!.role, WsUserRole.staff);
      expect(back.permissions.has('delivery.manage'), isFalse,
          reason: 'a demotion on the server must not be outlived by the '
              'snapshot it replaces');
    });
  });

  // ═══ 2 · OFFLINE USES A VALID SNAPSHOT ════════════════════════════════════

  test('2. a valid snapshot is returned for the user it belongs to', () async {
    await store.write(snapshotFor(driverA));
    expect(await store.readFor(driverA), isNotNull);
  });

  // ═══ 3 · NO SNAPSHOT DOES NOT BYPASS AUTHENTICATION ═══════════════════════

  group('3. absence never invents an account', () {
    test('an empty store yields nothing', () async {
      expect(await store.readFor(driverA), isNull,
          reason: 'null sends the gate down the existing login/error path');
    });

    test('an empty string yields nothing', () async {
      kv.values[WsSessionSnapshotStore.storageKey] = '';
      expect(await store.readFor(driverA), isNull);
    });

    test('clear() removes it — the shared-device sign-out rule', () async {
      await store.write(snapshotFor(driverA));
      await store.clear();
      expect(await store.readFor(driverA), isNull);
    });
  });

  // ═══ 4 · ANOTHER USER'S SNAPSHOT IS REFUSED ═══════════════════════════════

  group("4. one driver's snapshot is unreachable to another", () {
    test('a snapshot for driver A is refused to driver B', () async {
      await store.write(snapshotFor(driverA));

      expect(await store.readFor(driverB), isNull,
          reason: 'THE SHARED-DEVICE RULE: two drivers, one tablet. The second '
              "must never inherit the first's organization or permissions");
    });

    test('and B does not get A\'s role or permissions by any route', () async {
      await store.write(snapshotFor(driverA,
          role: WsUserRole.admin, perms: {'org.manage', 'users.manage'}));

      final forB = await store.readFor(driverB);
      expect(forB, isNull);
    });

    test('an empty uid matches nothing', () async {
      await store.write(snapshotFor(driverA));
      expect(await store.readFor(''), isNull);
    });
  });

  // ═══ 6 · MALFORMED INPUT FAILS SAFELY ═════════════════════════════════════

  group('6. corrupt or unreadable snapshots fail safely', () {
    Future<void> put(String raw) async =>
        kv.values[WsSessionSnapshotStore.storageKey] = raw;

    test('unparseable JSON yields null, not an exception', () async {
      await put('{not json at all');
      expect(await store.readFor(driverA), isNull);
    });

    test('valid JSON of the wrong shape yields null', () async {
      await put(jsonEncode(['a', 'list']));
      expect(await store.readFor(driverA), isNull);
    });

    test('a missing authUserId yields null', () async {
      await put(jsonEncode({
        'organization': {'orgid': 7},
        'role': 'admin',
        'permissionCodes': <String>[],
        'savedAt': DateTime.now().toIso8601String(),
      }));
      expect(await store.readFor(driverA), isNull,
          reason: 'with no owner it cannot be bound to a session, so it is '
              'unusable by definition');
    });

    test('an unknown role yields null rather than a guess', () async {
      await put(jsonEncode({
        'authUserId': driverA,
        'organization': {'orgid': 7},
        'role': 'superuser',
        'permissionCodes': <String>[],
        'savedAt': DateTime.now().toIso8601String(),
      }));
      expect(await store.readFor(driverA), isNull);
    });

    test('an organization with no orgid yields null', () async {
      await put(jsonEncode({
        'authUserId': driverA,
        'organization': {'orgname': 'Blue Water'},
        'role': 'admin',
        'permissionCodes': <String>[],
        'savedAt': DateTime.now().toIso8601String(),
      }));
      expect(await store.readFor(driverA), isNull);
    });

    test('orgid is the real guard — WsOrganization.fromJson is lenient',
        () async {
      // Recorded because writing this test wrongly is how it was learned.
      //
      // WsOrganization.fromJson does NOT throw on missing fields: _reqStr,
      // _reqInt and _reqBool all fall back to defaults ('', 0, true). So an
      // organization stripped to just an orgid rebuilds happily with empty
      // strings, and organizationOrNull cannot reject it.
      //
      // The protection that actually works is the explicit orgid check in
      // WsSessionSnapshot.fromJson. This pins that division so nobody later
      // assumes organizationOrNull is validating the payload.
      await put(jsonEncode({
        'authUserId': driverA,
        'organization': {'orgid': 7},
        'role': 'admin',
        'permissionCodes': <String>[],
        'savedAt': DateTime.now().toIso8601String(),
      }));

      final back = await store.readFor(driverA);
      expect(back, isNotNull, reason: 'lenient parser, so this does rebuild');
      expect(back!.orgId, 7);
      expect(back.organizationOrNull!.orgName, '',
          reason: 'defaulted, not rejected — which is exactly why orgid must '
              'be checked separately');
    });

    test('non-string permission codes are dropped, not fatal', () async {
      await put(jsonEncode({
        'authUserId': driverA,
        'organization': snapshotFor(driverA).organization,
        'role': 'staff',
        'permissionCodes': ['delivery.manage', 42, null, 'customers.view'],
        'savedAt': DateTime.now().toIso8601String(),
      }));

      final back = await store.readFor(driverA);
      expect(back, isNotNull);
      expect(back!.permissionCodes, ['delivery.manage', 'customers.view']);
    });

    test('a corrupt snapshot is not thrown from readFor', () async {
      await put('  binary garbage');
      expect(() => store.readFor(driverA), returnsNormally);
      expect(await store.readFor(driverA), isNull);
    });
  });

  // ═══ WHAT THE SNAPSHOT DELIBERATELY DOES NOT CARRY ════════════════════════

  test('no credential, token or secret is ever persisted', () async {
    await store.write(snapshotFor(driverA));
    final raw = kv.values[WsSessionSnapshotStore.storageKey]!;

    // Supabase owns the session. This holds routing facts and nothing else —
    // writing a token here would turn a convenience into a credential store.
    for (final forbidden in [
      'access_token', 'refresh_token', 'password', 'apikey', 'Bearer',
    ]) {
      expect(raw.toLowerCase(), isNot(contains(forbidden.toLowerCase())));
    }
    expect(raw, isNot(matches(RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.'))),
        reason: 'that is the shape of a JWT');
  });

  test('the persisted surface is exactly the declared fields', () async {
    await store.write(snapshotFor(driverA));
    final decoded = jsonDecode(kv.values[WsSessionSnapshotStore.storageKey]!)
        as Map<String, dynamic>;

    expect(decoded.keys.toSet(), {
      'authUserId', 'organization', 'role', 'permissionCodes', 'savedAt',
    }, reason: 'a new field here is a deliberate decision, not an accident');
  });
}
