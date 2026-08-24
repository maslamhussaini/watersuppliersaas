// =============================================================================
// test/registration_integration_test.dart
// The whole registration path, end to end, against the fake auth client.
//
// Configuration-independent by construction: mailer_autoconfirm,
// phone_autoconfirm and "is there an SMS provider" are each DRIVEN here rather
// than assumed, because the real project's settings are still unknown and the
// implementation must be correct whichever way they are set.
//
// Provisioning is a plain callback, so the RPC is never called and no database
// is required — what is under test is the ORDERING around it: the gate before,
// the key handed over, and what happens to the attempt on success or failure.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/auth/ws_auth_client.dart';
import 'package:watersuppliersaas/services/auth/ws_phone_verification.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_attempt_store.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_flow.dart';
import 'package:watersuppliersaas/services/storage/ws_kv_preferences.dart';

import 'support/fake_auth_client.dart';

void main() {
  const phone = '+923009876543';
  late WsFakePreferencesBackend backend;

  setUp(() => backend = WsFakePreferencesBackend());

  WsRegistrationAttemptStore attemptStore() =>
      WsRegistrationAttemptStore(WsPreferencesKeyValueStore(backend));

  WsRegistrationFlow newFlow(FakeAuthClient fake) => WsRegistrationFlow(
        WsPhoneVerification(fake),
        store: attemptStore(),
        email: 'owner@example.com',
        orgName: 'Kent Water',
        ownerName: 'Essa',
        orgPhone: '+923009999999',
        address: 'Karachi',
      );

  Future<WsRegistrationFlow?> resumed(FakeAuthClient fake) =>
      WsRegistrationFlow.resume(
        verification: WsPhoneVerification(fake),
        store: attemptStore(),
      );

  Future<WsRegistrationState> begin(WsRegistrationFlow f) => f.start(
        email: 'owner@example.com',
        password: 'sup3rsecret',
        phone: phone,
        redirectTo: 'https://example.test/',
      );

  /// Registration all the way to a verified phone.
  Future<WsRegistrationFlow> verified(FakeAuthClient fake) async {
    final flow = newFlow(fake);
    await begin(flow);
    await flow.submitCode('123456');
    return flow;
  }

  // ═══ THE HAPPY PATH, END TO END ═══════════════════════════════════════════

  group('session → phone → OTP → organization', () {
    test('runs the whole sequence and provisions once', () async {
      final fake = FakeAuthClient();
      final flow = await verified(fake);

      final keys = <String>[];
      final id = await flow.provisionOrganization((clientUuid) async {
        keys.add(clientUuid);
        return 42;
      });

      expect(fake.calls, ['signUp', 'updatePhone', 'verifyPhoneChangeOtp']);
      expect(id, 42);
      expect(keys, hasLength(1), reason: 'provisioning called exactly once');
      expect(flow.organizationId, 42);
    });

    test('PROVISIONING RECEIVES THE ORIGINAL KEY', () async {
      final fake = FakeAuthClient();
      final flow = newFlow(fake);
      await begin(flow);
      final key = flow.clientUuid!;

      // Everything that could plausibly reset it, first.
      await flow.submitCode('000000');
      await flow.resendCode();
      await flow.submitCode('123456');

      String? handedOver;
      await flow.provisionOrganization((clientUuid) async {
        handedOver = clientUuid;
        return 7;
      });

      expect(handedOver, key,
          reason: 'migration 014 resolves an existing organization only when '
              'the key is byte-identical');
    });

    test('signUp exactly once, signInWithOtp never', () async {
      final fake = FakeAuthClient();
      final flow = newFlow(fake);
      await begin(flow);
      await flow.submitCode('000000');
      await flow.resendCode();
      await flow.submitCode('123456');
      await flow.provisionOrganization((_) async => 1);

      expect(fake.signUpCount, 1);
      expect(fake.signInWithOtpCalls, 0,
          reason: 'signInWithOtp would create a second auth user keyed on the '
              'phone, and the organization would attach to whichever held the '
              'session');
    });

    test('a verified phone is otpProven', () async {
      final flow = await verified(FakeAuthClient());
      expect(flow.assurance, WsPhoneAssurance.otpProven);
      expect(flow.isPhoneOwnershipProven, isTrue);
    });
  });

  // ═══ THE BRANCHES WE REFUSE TO ASSUME ═════════════════════════════════════

  group('email confirmation ON', () {
    test('stops at emailConfirmationPending and touches nothing else',
        () async {
      final fake = FakeAuthClient(sessionAfterSignUp: false);
      final flow = newFlow(fake);

      expect(await begin(flow), WsRegistrationState.emailConfirmationPending);
      expect(fake.calls, ['signUp'],
          reason: 'no updateUser without a session — it would throw '
              'AuthSessionMissingException');
      expect(flow.canProvisionOrganization, isFalse);
    });

    test('the attempt is still persisted, so the key survives the wait',
        () async {
      final fake = FakeAuthClient(sessionAfterSignUp: false);
      final flow = newFlow(fake);
      await begin(flow);
      final key = flow.clientUuid!;

      // The user goes to their email, comes back tomorrow-ish, reloads.
      final back = await resumed(fake);

      expect(back!.clientUuid, key);
      expect(back.state, WsRegistrationState.emailConfirmationPending);
    });

    test('and provisioning is refused from that state', () async {
      final fake = FakeAuthClient(sessionAfterSignUp: false);
      final flow = newFlow(fake);
      await begin(flow);

      expect(() => flow.provisionOrganization((_) async => 1),
          throwsA(isA<StateError>()));
    });
  });

  group('session missing', () {
    test('never issues an updateUser it knows will fail', () async {
      final fake = FakeAuthClient(startSignedIn: false);
      final flow = newFlow(fake);

      await flow.resumeWithSession(phone: phone);

      expect(flow.state, WsRegistrationState.sessionMissing);
      expect(fake.calls, isEmpty,
          reason: 'checked before the call, so the failure names the cause');
    });

    test('is distinct from emailConfirmationPending', () async {
      final a = FakeAuthClient(startSignedIn: false);
      final flowA = newFlow(a);
      await flowA.resumeWithSession(phone: phone);

      final b = FakeAuthClient(sessionAfterSignUp: false);
      final flowB = newFlow(b);
      await begin(flowB);

      expect(flowA.state, isNot(flowB.state),
          reason: 'one needs a sign-in, the other needs an email click — '
              'different screens');
    });
  });

  group('phone_autoconfirm ON', () {
    test('may provision but stays serverAsserted', () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      final flow = newFlow(fake);
      await begin(flow);

      expect(flow.state, WsRegistrationState.phoneAlreadyConfirmed);
      expect(flow.canProvisionOrganization, isTrue);
      expect(flow.assurance, WsPhoneAssurance.serverAsserted);
      expect(flow.isPhoneOwnershipProven, isFalse,
          reason: 'a dashboard toggle is not evidence that anybody holds the '
              'number');
    });

    test('and provisioning still uses the same key', () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      final flow = newFlow(fake);
      await begin(flow);
      final key = flow.clientUuid!;

      String? given;
      await flow.provisionOrganization((u) async {
        given = u;
        return 3;
      });

      expect(given, key);
    });
  });

  group('no SMS provider', () {
    test('is recorded as a provider error, not thrown at the caller', () async {
      final fake = FakeAuthClient(
        updatePhoneError: const WsAuthException('not configured',
            code: 'phone_provider_disabled', statusCode: 422),
      );
      final flow = newFlow(fake);

      // The machine RECORDS failures rather than throwing — a registration
      // screen needs a state to render, not an exception to catch.
      await begin(flow);

      expect(flow.lastError, WsOtpError.phoneProviderUnavailable);
      expect(flow.canProvisionOrganization, isFalse);
      expect(fake.signUpCount, 1,
          reason: 'the auth user exists; only the phone step failed');
    });

    test('the key is kept, so a retry after fixing the provider reuses it',
        () async {
      final fake = FakeAuthClient(
        updatePhoneError: const WsAuthException('not configured',
            code: 'phone_provider_disabled', statusCode: 422),
      );
      final flow = newFlow(fake);
      await begin(flow);
      final key = flow.clientUuid!;

      final back = await resumed(fake);
      expect(back!.clientUuid, key,
          reason: 'a misconfigured project must not cost the user their '
              'registration attempt');
    });
  });

  // ═══ PROVISIONING FAILURE MODES ═══════════════════════════════════════════

  group('provisioning failures never cost the key', () {
    test('a thrown RPC leaves the attempt on disk', () async {
      final fake = FakeAuthClient();
      final flow = await verified(fake);
      final key = flow.clientUuid!;

      await expectLater(
        flow.provisionOrganization((_) async => throw Exception('timeout')),
        throwsA(isA<Exception>()),
      );

      final still = await attemptStore().load();
      expect(still, isNotNull, reason: 'the RPC may already have committed');
      expect(still!.clientUuid, key);
    });

    test('and the retry resolves with the SAME key', () async {
      final fake = FakeAuthClient();
      final flow = await verified(fake);
      final key = flow.clientUuid!;

      try {
        await flow.provisionOrganization((_) async => throw Exception('lost'));
      } catch (_) {}

      // The user reloads and presses Create again.
      final retry = await resumed(fake);
      expect(retry!.clientUuid, key);
    });

    test('success clears the attempt', () async {
      final fake = FakeAuthClient();
      final flow = await verified(fake);

      await flow.provisionOrganization((_) async => 42);

      expect(await attemptStore().load(), isNull);
      expect(await resumed(fake), isNull);
    });

    test('provisioning twice is refused rather than making a second org',
        () async {
      final flow = await verified(FakeAuthClient());
      await flow.provisionOrganization((_) async => 42);

      expect(() => flow.provisionOrganization((_) async => 99),
          throwsA(isA<StateError>()));
    });

    test('an unverified flow cannot reach the RPC at all', () async {
      final fake = FakeAuthClient();
      final flow = newFlow(fake);
      await begin(flow);

      var called = false;
      await expectLater(
        flow.provisionOrganization((_) async {
          called = true;
          return 1;
        }),
        throwsA(isA<StateError>()),
      );
      expect(called, isFalse,
          reason: 'the gate is checked BEFORE the RPC, not after');
    });
  });

  // ═══ RELOAD IN THE MIDDLE ═════════════════════════════════════════════════

  test('a reload mid-OTP resumes and provisions with the original key',
      () async {
    final fake = FakeAuthClient();
    final flow = newFlow(fake);
    await begin(flow);
    final key = flow.clientUuid!;

    // Browser reload: the widget State is gone.
    final back = await resumed(fake);
    expect(back!.clientUuid, key);
    expect(back.isAwaitingCode, isTrue);

    await back.submitCode('123456');

    String? given;
    await back.provisionOrganization((u) async {
      given = u;
      return 11;
    });

    expect(given, key);
    expect(fake.signUpCount, 1, reason: 'resuming must not sign up again');
    expect(fake.signInWithOtpCalls, 0);
  });
}
