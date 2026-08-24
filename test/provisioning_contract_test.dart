// =============================================================================
// test/provisioning_contract_test.dart
// The two — and only two — ways an organization may be provisioned, and the
// single rule both of them go through.
//
// ─── WHY THIS FILE EXISTS SEPARATELY ─────────────────────────────────────────
//
// The provisioning rule was written down twice: once in canProvisionOrganization
// and once inside markOrganizationProvisioned. The copies drifted, and an
// add-organization attempt passed the outer gate, reached the RPC, and was then
// refused on the way back — after the database had already committed.
//
// Both now delegate to one private predicate. These tests walk the FULL path
// for each contract, because that is the only shape that catches two checks
// disagreeing; calling either one alone passed the whole time.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/auth/ws_phone_verification.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_attempt_store.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_flow.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';

import 'support/fake_auth_client.dart';

void main() {
  const phone = '+923009876543';
  late WsMemoryKeyValueStore kv;

  setUp(() => kv = WsMemoryKeyValueStore());

  WsRegistrationAttemptStore store() => WsRegistrationAttemptStore(kv);

  Future<WsRegistrationFlow?> reload(FakeAuthClient fake) =>
      WsRegistrationFlow.resume(
        verification: WsPhoneVerification(fake),
        store: store(),
      );

  // ── contract 1: first-time registration ──────────────────────────────────
  Future<WsRegistrationFlow> registration(FakeAuthClient fake) async {
    final flow = WsRegistrationFlow(
      WsPhoneVerification(fake),
      store: store(),
      email: 'owner@example.com',
      orgName: 'Kent Water',
      ownerName: 'Essa',
    );
    await flow.start(
      email: 'owner@example.com',
      password: 'sup3rsecret',
      phone: phone,
    );
    return flow;
  }

  // ── contract 2: existing owner, another organization ─────────────────────
  Future<WsRegistrationFlow> addOrganization(FakeAuthClient fake) =>
      WsRegistrationFlow.beginForExistingUser(
        verification: WsPhoneVerification(fake),
        store: store(),
        orgName: 'Second Depot',
        ownerName: 'Essa',
        orgPhone: '+923009999999',
        address: 'Lahore',
      );

  // ═══ ONE RULE, TWO WAYS THROUGH IT ════════════════════════════════════════

  group('the gate and the post-RPC check never disagree', () {
    test('REGISTRATION passes both, records, and clears', () async {
      final fake = FakeAuthClient();
      final flow = await registration(fake);
      await flow.submitCode('123456');

      expect(flow.canProvisionOrganization, isTrue); // outer gate
      final id = await flow.provisionOrganization((_) async => 42);

      expect(id, 42);
      expect(flow.organizationId, 42); // post-RPC check passed
      expect(await store().load(), isNull); // attempt cleared
    });

    test('EXISTING USER passes both, records, and clears', () async {
      // This is the case that used to reach the RPC and then be refused.
      final fake = FakeAuthClient(startSignedIn: true);
      final flow = await addOrganization(fake);

      expect(flow.canProvisionOrganization, isTrue);
      expect(flow.isExistingUserSession, isTrue);

      var reachedRpc = false;
      final id = await flow.provisionOrganization((_) async {
        reachedRpc = true;
        return 77;
      });

      expect(reachedRpc, isTrue);
      expect(id, 77);
      expect(flow.organizationId, 77,
          reason: 'the post-RPC gate must accept what the outer gate allowed — '
              'refusing here happens AFTER the database has committed');
      expect(await store().load(), isNull);
    });

    test('a state neither contract covers is refused by BOTH', () async {
      final fake = FakeAuthClient(sessionAfterSignUp: false);
      final flow = await registration(fake); // emailConfirmationPending

      expect(flow.canProvisionOrganization, isFalse);
      expect(() => flow.provisionOrganization((_) async => 1),
          throwsA(isA<StateError>()));
      expect(() => flow.markOrganizationProvisioned(1),
          throwsA(isA<StateError>()),
          reason: 'both gates must reject the same states, not just one');
    });

    test('an unverified phone is refused by BOTH', () async {
      final flow = await registration(FakeAuthClient()); // phoneOtpSent

      expect(flow.canProvisionOrganization, isFalse);
      expect(() => flow.markOrganizationProvisioned(1),
          throwsA(isA<StateError>()));
    });
  });

  // ═══ ASSURANCE IS NOT SHARED BETWEEN THE CONTRACTS ════════════════════════

  group('provisionable does not mean phone-verified', () {
    test('registration with a real OTP is otpProven', () async {
      final flow = await registration(FakeAuthClient());
      await flow.submitCode('123456');
      expect(flow.assurance, WsPhoneAssurance.otpProven);
    });

    test('phone_autoconfirm is serverAsserted, never otpProven', () async {
      final flow = await registration(FakeAuthClient(autoconfirmPhone: true));
      expect(flow.assurance, WsPhoneAssurance.serverAsserted);
      expect(flow.isPhoneOwnershipProven, isFalse);
    });

    test('ADD-ORGANIZATION IS none — it says nothing about a phone', () async {
      final flow = await addOrganization(FakeAuthClient(startSignedIn: true));

      expect(flow.canProvisionOrganization, isTrue);
      expect(flow.assurance, WsPhoneAssurance.none);
      expect(flow.isPhoneOwnershipProven, isFalse);
    });

    test('all three provisionable cases are distinguishable', () async {
      final otp = await registration(FakeAuthClient());
      await otp.submitCode('123456');
      final auto = await registration(FakeAuthClient(autoconfirmPhone: true));

      // Fresh store so the add-org attempt does not resume the registration.
      kv = WsMemoryKeyValueStore();
      final add = await addOrganization(FakeAuthClient(startSignedIn: true));

      final assurances = {otp.assurance, auto.assurance, add.assurance};
      expect(assurances, hasLength(3),
          reason: 'collapsing these is how a dashboard toggle or an '
              'add-organization click becomes "phone verified" for quota');
    });
  });

  // ═══ LOST RESPONSE, BOTH CONTRACTS ════════════════════════════════════════

  group('a committed RPC whose response is lost', () {
    /// persist → commit → lose the reply → reload → resume → retry
    Future<void> assertResolves(
      FakeAuthClient fake,
      Future<WsRegistrationFlow> Function() begin,
    ) async {
      final keysSeen = <String>[];
      var rows = 0;

      final first = await begin();
      try {
        await first.provisionOrganization((u) async {
          keysSeen.add(u);
          rows++; // ws_create_organization commits
          throw Exception('connection dropped before the reply');
        });
      } catch (_) {}

      // Attempt retained, because the row may exist.
      final saved = await store().load();
      expect(saved, isNotNull);
      expect(saved!.clientUuid, first.clientUuid);

      // Reload — nothing in memory.
      final resumed = await reload(fake);
      expect(resumed!.clientUuid, first.clientUuid);

      final id = await resumed.provisionOrganization((u) async {
        keysSeen.add(u);
        // Same key, so migration 014 returns the existing row rather than
        // making another.
        return 42;
      });

      expect(keysSeen.toSet(), hasLength(1),
          reason: 'ONE clientuuid across both attempts');
      expect(rows, 1, reason: 'ONE organization row');
      expect(id, 42);
      expect(await store().load(), isNull,
          reason: 'the successful retry clears the attempt');
    }

    test('first-time registration resolves to the same organization',
        () async {
      final fake = FakeAuthClient();
      await assertResolves(fake, () async {
        final flow = await registration(fake);
        await flow.submitCode('123456');
        return flow;
      });
      expect(fake.signUpCount, 1);
      expect(fake.signInWithOtpCalls, 0);
    });

    test('add-organization resolves to the same organization', () async {
      final fake = FakeAuthClient(startSignedIn: true);
      await assertResolves(fake, () => addOrganization(fake));
      expect(fake.signUpCount, 0, reason: 'no signUp on this path at all');
      expect(fake.signInWithOtpCalls, 0);
    });
  });

  // ═══ WHAT SURVIVES A RELOAD ═══════════════════════════════════════════════

  group('assurance survives a reload without being upgraded', () {
    test('phoneOtpSent resumes as itself', () async {
      final fake = FakeAuthClient();
      await registration(fake);
      final back = await reload(fake);

      expect(back!.state, WsRegistrationState.phoneOtpSent);
      expect(back.isAwaitingCode, isTrue);
      expect(back.assurance, WsPhoneAssurance.none);
    });

    test('phoneAlreadyConfirmed stays serverAsserted', () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      await registration(fake);
      expect((await reload(fake))!.assurance, WsPhoneAssurance.serverAsserted);
    });

    test('phoneOtpVerified stays otpProven', () async {
      final fake = FakeAuthClient();
      final flow = await registration(fake);
      await flow.submitCode('123456');
      expect((await reload(fake))!.assurance, WsPhoneAssurance.otpProven);
    });

    test('existingUserSession stays none', () async {
      final fake = FakeAuthClient(startSignedIn: true);
      await addOrganization(fake);
      final back = await reload(fake);

      expect(back!.isExistingUserSession, isTrue);
      expect(back.assurance, WsPhoneAssurance.none);
      expect(back.canProvisionOrganization, isTrue);
    });
  });

  // ═══ phone_autoconfirm CANNOT MANUFACTURE otpProven ═══════════════════════
  //
  // The rule, and the only route to it:
  //
  //     OTP actually sent → phoneOtpSent → submitCode() → phoneOtpVerified
  //                                                            → otpProven
  //
  // AuthService.verifyPhone used to hand confirmPhone() to any caller, skipping
  // the phoneOtpSent check. Under phone_autoconfirm the server reports the
  // number confirmed without sending anything, so that path could return
  // phoneOtpVerified — and therefore otpProven — for a code that never existed.
  // It was removed rather than double-gated: the state machine owns this
  // transition, and a second gate is a second thing to drift.

  group('phone_autoconfirm cannot manufacture otpProven', () {
    test('submitCode is REFUSED from phoneAlreadyConfirmed', () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      final flow = await registration(fake);

      expect(flow.state, WsRegistrationState.phoneAlreadyConfirmed);
      expect(flow.assurance, WsPhoneAssurance.serverAsserted);

      // Even with the code the fake regards as correct.
      expect(flow.submitCode('123456'), throwsA(isA<StateError>()),
          reason: 'no code was sent, so there is nothing to verify — and '
              'verifying anyway would mint otpProven out of a dashboard '
              'toggle');
    });

    test('the verify call never reaches the client', () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      final flow = await registration(fake);

      try {
        await flow.submitCode('123456');
      } catch (_) {}

      expect(fake.calls, isNot(contains('verifyPhoneChangeOtp')),
          reason: 'refused before the network, not after');
      expect(fake.tokensTried, isEmpty);
    });

    test('assurance stays serverAsserted after the refused attempt', () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      final flow = await registration(fake);

      try {
        await flow.submitCode('123456');
      } catch (_) {}

      expect(flow.assurance, WsPhoneAssurance.serverAsserted);
      expect(flow.isPhoneOwnershipProven, isFalse);
    });

    test('and it stays serverAsserted across a reload', () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      await registration(fake);

      final back = await reload(fake);

      expect(back!.assurance, WsPhoneAssurance.serverAsserted);
      expect(() => back.submitCode('123456'), throwsA(isA<StateError>()),
          reason: 'a reload must not reopen the door either');
    });

    test('the legitimate route still produces otpProven', () async {
      // The control: an OTP genuinely sent, then verified.
      final fake = FakeAuthClient(); // autoconfirm OFF
      final flow = await registration(fake);

      expect(flow.state, WsRegistrationState.phoneOtpSent,
          reason: 'a code WAS sent on this path');
      await flow.submitCode('123456');

      expect(flow.state, WsRegistrationState.phoneOtpVerified);
      expect(flow.assurance, WsPhoneAssurance.otpProven);
      expect(fake.tokensTried, ['123456'],
          reason: 'the code actually went to the server');
    });
  });
}
