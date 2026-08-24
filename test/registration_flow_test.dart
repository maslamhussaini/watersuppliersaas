// =============================================================================
// test/registration_flow_test.dart
// The registration state machine, and the invariant it exists to hold:
//
//     ONE signUp → ONE auth user → ONE clientuuid → ONE organization
//
// Nothing here touches a UI. Every state the eventual screen will render is
// reachable and asserted, so wiring it becomes a rendering job rather than
// another architectural decision.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/auth/ws_phone_verification.dart';
import 'package:watersuppliersaas/services/auth/ws_auth_client.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_flow.dart';

import 'support/fake_auth_client.dart';

void main() {
  const phone = '+923001234567';

  WsRegistrationFlow flowFor(FakeAuthClient fake, {String? uuid}) =>
      WsRegistrationFlow(
        WsPhoneVerification(fake),
        newUuid: uuid == null ? null : () => uuid,
      );

  Future<WsRegistrationState> start(WsRegistrationFlow f) => f.start(
        email: 'owner@example.com',
        password: 'sup3rsecret',
        phone: phone,
        redirectTo: 'https://example.test/',
      );

  // ═══ THE CLIENTUUID ═══════════════════════════════════════════════════════

  group('one attempt, one clientuuid', () {
    test('is generated once and never changes', () async {
      final fake = FakeAuthClient();
      final flow = flowFor(fake);

      expect(flow.clientUuid, isNull, reason: 'nothing has started yet');
      await start(flow);
      final key = flow.clientUuid;
      expect(key, isNotNull);

      await flow.submitCode('000000'); // wrong
      await flow.resendCode();
      await flow.submitCode('999999'); // wrong again
      await flow.submitCode('123456'); // right

      expect(flow.clientUuid, key,
          reason: 'a second key would make ws_create_organization mint a '
              'SECOND organization, and migration 014 would never see the '
              'collision it exists to catch');
    });

    test('a wrong code does not restart the attempt', () async {
      final fake = FakeAuthClient();
      final flow = flowFor(fake);
      await start(flow);

      await flow.submitCode('000000');

      expect(flow.state, WsRegistrationState.phoneOtpSent);
      expect(flow.codeAttempts, 1);
      expect(fake.signUpCount, 1,
          reason: 'signing up again would be the second auth identity');
    });

    test('starting the same flow twice is refused', () async {
      final flow = flowFor(FakeAuthClient());
      await start(flow);
      expect(start(flow), throwsA(isA<StateError>()));
    });

    test('resuming never goes back through signUp', () async {
      final fake = FakeAuthClient(startSignedIn: true);
      final flow = flowFor(fake);

      await flow.resumeWithSession(phone: phone);

      expect(fake.calls, ['updatePhone']);
      expect(fake.signUpCount, 0);
      expect(flow.clientUuid, isNotNull,
          reason: 'a resumed attempt still needs a key to provision with');
    });
  });

  // ═══ EVERY STATE THE UI WILL HAVE TO RENDER ═══════════════════════════════

  group('states', () {
    test('email confirmation pending', () async {
      final flow = flowFor(FakeAuthClient(sessionAfterSignUp: false));
      expect(await start(flow), WsRegistrationState.emailConfirmationPending);
      expect(flow.needsUserActionOutsideRegistration, isTrue);
      expect(flow.canProvisionOrganization, isFalse);
      expect(flow.isAwaitingCode, isFalse);
    });

    test('session missing, and it is NOT the same as email pending', () async {
      final flow = flowFor(FakeAuthClient(startSignedIn: false));

      final state = await flow.resumeWithSession(phone: phone);

      expect(state, WsRegistrationState.sessionMissing);
      expect(state, isNot(WsRegistrationState.emailConfirmationPending),
          reason: 'one is the project policy on a fresh sign-up, the other is '
              'a session that expired underneath a resumed attempt — they need '
              'different screens');
      expect(flow.lastError, WsOtpError.sessionMissing);
    });

    test('awaiting a code', () async {
      final flow = flowFor(FakeAuthClient());
      expect(await start(flow), WsRegistrationState.phoneOtpSent);
      expect(flow.isAwaitingCode, isTrue);
      expect(flow.canProvisionOrganization, isFalse);
    });

    test('phone already confirmed', () async {
      final flow = flowFor(FakeAuthClient(autoconfirmPhone: true));
      expect(await start(flow), WsRegistrationState.phoneAlreadyConfirmed);
      expect(flow.isAwaitingCode, isFalse);
      expect(flow.canProvisionOrganization, isTrue);
    });

    test('otp verified', () async {
      final flow = flowFor(FakeAuthClient());
      await start(flow);
      expect(await flow.submitCode('123456'),
          WsRegistrationState.phoneOtpVerified);
      expect(flow.canProvisionOrganization, isTrue);
    });

    test('a session that dies mid-flow lands in sessionMissing', () async {
      final fake = FakeAuthClient(
        verifyError: const WsAuthException('no session',
            code: 'session_not_found', statusCode: 401),
      );
      final flow = flowFor(fake);
      await start(flow);

      expect(await flow.submitCode('123456'),
          WsRegistrationState.sessionMissing);
      expect(flow.needsUserActionOutsideRegistration, isTrue);
    });
  });

  // ═══ THE RULE ABOUT phone_autoconfirm ═════════════════════════════════════

  group('an administrative setting is not a verification guarantee', () {
    test('autoconfirm may provision but proves nothing', () async {
      final flow = flowFor(FakeAuthClient(autoconfirmPhone: true));
      await start(flow);

      expect(flow.canProvisionOrganization, isTrue);
      expect(flow.assurance, WsPhoneAssurance.serverAsserted);
      expect(flow.isPhoneOwnershipProven, isFalse,
          reason: 'nobody received anything at that number');
    });

    test('a real OTP proves it', () async {
      final flow = flowFor(FakeAuthClient());
      await start(flow);
      await flow.submitCode('123456');

      expect(flow.assurance, WsPhoneAssurance.otpProven);
      expect(flow.isPhoneOwnershipProven, isTrue);
    });

    test('anything gating quota must ask for ownership, not permission', () {
      // The distinction, stated as a test so it survives a refactor.
      expect(WsPhoneAssurance.values,
          containsAll([WsPhoneAssurance.serverAsserted,
              WsPhoneAssurance.otpProven]));
      expect(WsPhoneAssurance.serverAsserted,
          isNot(WsPhoneAssurance.otpProven));
    });
  });

  // ═══ PROVISIONING ═════════════════════════════════════════════════════════

  group('provisioning', () {
    Future<WsRegistrationFlow> verified() async {
      final flow = flowFor(FakeAuthClient());
      await start(flow);
      await flow.submitCode('123456');
      return flow;
    }

    test('records the organization and closes the gate', () async {
      final flow = await verified();
      flow.markOrganizationProvisioned(42);

      expect(flow.organizationId, 42);
      expect(flow.isComplete, isTrue);
      expect(flow.canProvisionOrganization, isFalse,
          reason: 'the gate must not stay open once an organization exists');
    });

    test('recording the SAME id twice is a no-op — that is a lost response',
        () async {
      final flow = await verified();
      flow.markOrganizationProvisioned(42);
      flow.markOrganizationProvisioned(42);
      expect(flow.organizationId, 42);
    });

    test('a DIFFERENT id is refused loudly', () async {
      final flow = await verified();
      flow.markOrganizationProvisioned(42);

      expect(() => flow.markOrganizationProvisioned(43),
          throwsA(isA<StateError>()),
          reason: 'two organizations for one clientuuid means migration 014 '
              'has been bypassed and we must not paper over it');
    });

    test('cannot provision from an unverified state', () async {
      final flow = flowFor(FakeAuthClient());
      await start(flow);
      expect(() => flow.markOrganizationProvisioned(1),
          throwsA(isA<StateError>()));
    });

    test('cannot provision while email confirmation is pending', () async {
      final flow = flowFor(FakeAuthClient(sessionAfterSignUp: false));
      await start(flow);
      expect(() => flow.markOrganizationProvisioned(1),
          throwsA(isA<StateError>()));
    });
  });

  // ═══ ILLEGAL TRANSITIONS ══════════════════════════════════════════════════

  group('illegal transitions are refused, not ignored', () {
    test('submitting a code before one was sent', () async {
      final flow = flowFor(FakeAuthClient(sessionAfterSignUp: false));
      await start(flow);
      expect(flow.submitCode('123456'), throwsA(isA<StateError>()));
    });

    test('resending before one was sent', () async {
      final flow = flowFor(FakeAuthClient(autoconfirmPhone: true));
      await start(flow);
      expect(flow.resendCode(), throwsA(isA<StateError>()));
    });

    test('resuming with no phone at all', () {
      final flow = flowFor(FakeAuthClient(startSignedIn: true));
      expect(flow.resumeWithSession(), throwsA(isA<StateError>()));
    });
  });

  // ═══ RESEND ═══════════════════════════════════════════════════════════════

  group('resend', () {
    test('counts, and leaves the key and the state alone', () async {
      final fake = FakeAuthClient();
      final flow = flowFor(fake);
      await start(flow);
      final key = flow.clientUuid;

      await flow.resendCode();
      await flow.resendCode();

      expect(flow.resendCount, 2);
      expect(fake.resendCount, 2);
      expect(flow.state, WsRegistrationState.phoneOtpSent);
      expect(flow.clientUuid, key);
    });

    test('a server cooldown is recorded without losing the attempt', () async {
      final fake = FakeAuthClient(
        resendError: const WsAuthException('wait 60 seconds',
            code: 'over_sms_send_rate_limit', statusCode: 429),
      );
      final flow = flowFor(fake);
      await start(flow);

      await flow.resendCode();

      expect(flow.lastError, WsOtpError.rateLimited);
      expect(flow.resendCount, 0, reason: 'nothing was actually sent');
      expect(flow.state, WsRegistrationState.phoneOtpSent,
          reason: 'the attempt survives a cooldown');
    });
  });

  // ═══ THE NEGATIVE, AGAIN, AT THIS LAYER ═══════════════════════════════════

  test('the state machine never reaches signInWithOtp', () async {
    final fake = FakeAuthClient();
    final flow = flowFor(fake);

    await start(flow);
    await flow.submitCode('000000');
    await flow.resendCode();
    await flow.submitCode('123456');
    flow.markOrganizationProvisioned(7);

    expect(fake.signInWithOtpCalls, 0);
    expect(fake.signUpCount, 1);
    expect(fake.calls.where((c) => c == 'signUp').length, 1,
        reason: 'ONE signUp → ONE auth user, across the entire flow');
  });
}
