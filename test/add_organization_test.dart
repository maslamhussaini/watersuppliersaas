// =============================================================================
// test/add_organization_test.dart
// An existing owner adding ANOTHER organization.
//
// ─── THE BUG THIS LOCKS DOWN ─────────────────────────────────────────────────
//
// The selector used to do:
//
//     beginRegistration()          ← key in memory only, nothing persisted
//     newAttemptKey()
//     createOrganizationForCurrentUser(...)   ← RPC, bypassing the flow
//     abandon()
//
// If that RPC committed and its response was lost, there was nothing on disk to
// resume. The reload minted a fresh key and built a SECOND organization —
// exactly what migration 014 exists to prevent, defeated one layer above it.
//
// The critical test is 'a lost response is resolved by the retry', which walks
// persist → commit → lose the response → reload → resume → retry, and asserts
// one key and one organization.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/auth/ws_phone_verification.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_attempt_store.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_flow.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';

import 'support/fake_auth_client.dart';

void main() {
  late FakeAuthClient fake;
  late WsMemoryKeyValueStore kv;

  setUp(() {
    fake = FakeAuthClient(startSignedIn: true);
    kv = WsMemoryKeyValueStore();
  });

  WsRegistrationAttemptStore store() => WsRegistrationAttemptStore(kv);

  /// What the selector does when there is no pending attempt.
  Future<WsRegistrationFlow> addOrganization() =>
      WsRegistrationFlow.beginForExistingUser(
        verification: WsPhoneVerification(fake),
        store: store(),
        orgName: 'Second Depot',
        ownerName: 'Essa',
        orgPhone: '+923009999999',
        address: 'Lahore',
      );

  /// A reload: nothing in memory, same backing store.
  Future<WsRegistrationFlow?> afterReload() => WsRegistrationFlow.resume(
        verification: WsPhoneVerification(fake),
        store: store(),
      );

  // ═══ THE KEY IS DURABLE BEFORE THE RPC ════════════════════════════════════

  group('the key is on disk before anything can commit', () {
    test('beginForExistingUser persists before it returns', () async {
      final flow = await addOrganization();

      final saved = await store().load();
      expect(saved, isNotNull,
          reason: 'the previous version left this null until a state '
              'transition that this path never makes');
      expect(saved!.clientUuid, flow.clientUuid);
    });

    test('a reload BEFORE the RPC recovers the same key', () async {
      final flow = await addOrganization();
      final key = flow.clientUuid!;

      final resumed = await afterReload();

      expect(resumed, isNotNull);
      expect(resumed!.clientUuid, key);
      expect(resumed.canProvisionOrganization, isTrue,
          reason: 'a resumed add-organization attempt must still be able to '
              'finish');
    });

    test('the business draft survives the reload too', () async {
      await addOrganization();
      final resumed = await afterReload();

      expect(resumed!.orgName, 'Second Depot');
      expect(resumed.address, 'Lahore');
    });
  });

  // ═══ NO PHONE, NO OTP, NO ASSURANCE ═══════════════════════════════════════

  group('this path is authenticated, not verified', () {
    test('no auth calls are made at all', () async {
      await addOrganization();

      expect(fake.calls, isEmpty,
          reason: 'the user is already signed in — no signUp, no updatePhone, '
              'no OTP');
      expect(fake.signUpCount, 0);
      expect(fake.signInWithOtpCalls, 0);
    });

    test('ASSURANCE STAYS NONE — this is not evidence of a phone', () async {
      final flow = await addOrganization();

      expect(flow.canProvisionOrganization, isTrue);
      expect(flow.assurance, WsPhoneAssurance.none);
      expect(flow.isPhoneOwnershipProven, isFalse,
          reason: 'quota or trial enforcement must not mistake an '
              'add-organization attempt for a verified registration');
    });

    test('and it survives a reload as none, not as proven', () async {
      await addOrganization();
      final resumed = await afterReload();

      expect(resumed!.isExistingUserSession, isTrue);
      expect(resumed.assurance, WsPhoneAssurance.none);
    });
  });

  // ═══ PROVISIONING ═════════════════════════════════════════════════════════

  group('provisioning goes through the same gate as registration', () {
    test('the RPC receives the persisted key', () async {
      final flow = await addOrganization();
      final key = (await store().load())!.clientUuid;

      String? used;
      await flow.provisionOrganization((u) async {
        used = u;
        return 42;
      });

      expect(used, key);
    });

    test('success clears the attempt', () async {
      final flow = await addOrganization();
      await flow.provisionOrganization((_) async => 42);

      expect(await store().load(), isNull);
      expect(await afterReload(), isNull);
    });

    test('a throw AFTER the commit leaves the attempt intact', () async {
      final flow = await addOrganization();
      final key = flow.clientUuid!;
      var committed = false;

      try {
        await flow.provisionOrganization((_) async {
          committed = true; // the database wrote the row
          throw Exception('gateway timeout'); // the answer never arrived
        });
      } catch (_) {}

      expect(committed, isTrue);
      final saved = await store().load();
      expect(saved, isNotNull, reason: 'the row may exist; we must be able to '
          'resolve it rather than make another');
      expect(saved!.clientUuid, key);
    });

    test('A LOST RESPONSE IS RESOLVED BY THE RETRY', () async {
      // persist → commit → response lost → reload → resume → retry
      final keysSeenByRpc = <String>[];
      var rowsCreated = 0;

      final first = await addOrganization();
      try {
        await first.provisionOrganization((u) async {
          keysSeenByRpc.add(u);
          rowsCreated++; // ws_create_organization commits
          throw Exception('connection dropped before the reply');
        });
      } catch (_) {}

      // The user reloads and presses Save again.
      final retry = await afterReload();
      final id = await retry!.provisionOrganization((u) async {
        keysSeenByRpc.add(u);
        // Migration 014: same key, so no second row — the existing id returns.
        return 42;
      });

      expect(keysSeenByRpc.toSet(), hasLength(1),
          reason: 'ONE key reached the RPC across both attempts; a second key '
              'is a second organization');
      expect(rowsCreated, 1);
      expect(id, 42);
      expect(await store().load(), isNull, reason: 'and now it is finished');
    });

    test('pressing Save twice cannot make a second organization', () async {
      final flow = await addOrganization();
      await flow.provisionOrganization((_) async => 42);

      await expectLater(
        flow.provisionOrganization((_) async => 99),
        throwsA(isA<StateError>()),
      );
      expect(flow.organizationId, 42);
    });

    test('recording a different organization id is refused', () async {
      final flow = await addOrganization();
      await flow.provisionOrganization((_) async => 42);

      expect(() => flow.markOrganizationProvisioned(43),
          throwsA(isA<StateError>()));
    });
  });

  // ═══ A PENDING REGISTRATION WINS ══════════════════════════════════════════

  test('an interrupted REGISTRATION is resumed before anything new is made',
      () async {
    // Someone half-way through first-time registration lands on the selector.
    final registering = FakeAuthClient();
    final registration = WsRegistrationFlow(
      WsPhoneVerification(registering),
      store: store(),
      email: 'owner@example.com',
      orgName: 'Kent Water',
      ownerName: 'Essa',
    );
    await registration.start(
      email: 'owner@example.com',
      password: 'sup3rsecret',
      phone: '+923009876543',
    );
    await registration.submitCode('123456');
    final key = registration.clientUuid!;

    // The selector checks for a pending attempt FIRST.
    final pending = await WsRegistrationFlow.resume(
      verification: WsPhoneVerification(registering),
      store: store(),
    );

    expect(pending, isNotNull,
        reason: 'creating a new attempt here would strand the registration '
            'whose RPC may already have committed');
    expect(pending!.clientUuid, key);
    expect(pending.isExistingUserSession, isFalse,
        reason: 'it is a registration, and must not be mistaken for an '
            'add-organization attempt');
    expect(pending.assurance, WsPhoneAssurance.otpProven);
  });
}
