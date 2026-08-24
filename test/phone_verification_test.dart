// =============================================================================
// test/phone_verification_test.dart
// The registration sequence, and the one call it must never make.
//
// The client is injected, so "email confirmation is on", "phone_autoconfirm is
// on", "the SMS provider is not configured" and "the code expired" are all
// driven directly. None of them can be produced on demand against a real
// project, and two of them depend on dashboard settings we deliberately do not
// assume.
//
// THE CENTRAL TEST is 'signInWithOtp is never called'. The fake counts
// invocations, so that assertion observes behaviour rather than claiming
// something about source text — it keeps failing if somebody adds the call
// later, which a grep-based check would not.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/auth/ws_auth_client.dart';
import 'package:watersuppliersaas/services/auth/ws_phone_verification.dart';
import 'package:watersuppliersaas/supabase_config.dart';

import 'support/fake_auth_client.dart';

void main() {
  const phone = '+923001234567';

  Future<WsRegistrationOutcome> register(
    WsPhoneVerification v, {
    String p = phone,
  }) =>
      v.startRegistration(
        email: 'owner@example.com',
        password: 'sup3rsecret',
        phone: p,
        redirectTo: 'https://example.test/',
      );

  // ═══ THE SEQUENCE ═════════════════════════════════════════════════════════

  group('the registration sequence', () {
    test('is exactly signUp → updatePhone → verifyOTP', () async {
      final fake = FakeAuthClient();
      final v = WsPhoneVerification(fake);

      await register(v);
      await v.confirmPhone(phone: phone, token: '123456');

      expect(fake.calls, ['signUp', 'updatePhone', 'verifyPhoneChangeOtp']);
    });

    test('SIGNINWITHOTP IS NEVER CALLED — it would create a second user',
        () async {
      final fake = FakeAuthClient();
      final v = WsPhoneVerification(fake);

      await register(v);
      await v.resendCode(phone);
      try {
        await v.confirmPhone(phone: phone, token: 'wrong!');
      } catch (_) {}
      await v.confirmPhone(phone: phone, token: '123456');

      expect(fake.signInWithOtpCalls, 0,
          reason: 'signInWithOtp(phone:) with shouldCreateUser defaulting to '
              'true creates a SEPARATE auth user keyed on the phone. The owner '
              'would hold two accounts and the organization would attach to '
              'whichever one had the session.');
      expect(fake.calls, isNot(contains('signInWithOtp')));
    });

    test('the phone is attached to the SAME user, after the session exists',
        () async {
      final fake = FakeAuthClient();
      await register(WsPhoneVerification(fake));

      expect(fake.calls.indexOf('signUp'),
          lessThan(fake.calls.indexOf('updatePhone')),
          reason: 'updateUser() throws AuthSessionMissingException without a '
              'session, so the order is forced');
      expect(fake.phonesSet, [phone]);
    });

    test('the redirect URL is passed through to signUp', () async {
      final fake = FakeAuthClient();
      await register(WsPhoneVerification(fake));
      expect(fake.redirectSeen, 'https://example.test/');
    });
  });

  // ═══ THE THREE SETTINGS WE REFUSE TO ASSUME ═══════════════════════════════

  group('email confirmation ON (mailer_autoconfirm = false)', () {
    test('stops before the phone rather than throwing', () async {
      final fake = FakeAuthClient(sessionAfterSignUp: false);
      final outcome = await register(WsPhoneVerification(fake));

      expect(outcome.state, WsRegistrationState.emailConfirmationPending);
      expect(fake.calls, ['signUp'],
          reason: 'calling updateUser() here would throw '
              'AuthSessionMissingException — there is no session to attach to');
    });

    test('and does not let the caller provision', () async {
      final fake = FakeAuthClient(sessionAfterSignUp: false);
      final outcome = await register(WsPhoneVerification(fake));
      expect(outcome.canProvisionOrganization, isFalse);
      expect(outcome.message, contains('confirm your address'));
    });
  });

  group('phone_autoconfirm ON', () {
    test('is detected instead of waiting for a code that never arrives',
        () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      final outcome = await register(WsPhoneVerification(fake));

      expect(outcome.state, WsRegistrationState.phoneAlreadyConfirmed);
      expect(fake.calls, ['signUp', 'updatePhone'],
          reason: 'no OTP was sent, so there is nothing to verify');
    });

    test('provisioning is allowed, because the session is real', () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      final outcome = await register(WsPhoneVerification(fake));
      expect(outcome.canProvisionOrganization, isTrue,
          reason: 'refusing here would make registration impossible while the '
              'toggle is on, which is not the same thing as secure');
    });

    test('but it is NOT proof that anyone holds that number', () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      final outcome = await register(WsPhoneVerification(fake));

      expect(outcome.assurance, WsPhoneAssurance.serverAsserted);
      expect(outcome.isPhoneOwnershipProven, isFalse,
          reason: 'no code was delivered — a dashboard toggle said not to '
              'bother checking. Treating that as verification would turn an '
              'administrative setting into an anti-abuse guarantee.');
    });

    test('the two successes are distinguishable, which is the whole point',
        () async {
      final auto = await register(
          WsPhoneVerification(FakeAuthClient(autoconfirmPhone: true)));

      final otpFake = FakeAuthClient();
      final v = WsPhoneVerification(otpFake);
      await register(v);
      final proven = await v.confirmPhone(phone: phone, token: '123456');

      expect(auto.canProvisionOrganization, proven.canProvisionOrganization,
          reason: 'both may continue');
      expect(auto.assurance, isNot(proven.assurance),
          reason: 'but they are not worth the same as evidence');
    });
  });

  group('no SMS provider configured', () {
    test('surfaces as an actionable failure, not a crash', () async {
      final fake = FakeAuthClient(
        updatePhoneError: const WsAuthException('SMS provider not configured',
            code: 'phone_provider_disabled', statusCode: 422),
      );
      final v = WsPhoneVerification(fake);

      await expectLater(register(v), throwsA(isA<WsAuthException>()));
      try {
        await register(v);
      } on WsAuthException catch (e) {
        expect(wsClassifyOtpError(e), WsOtpError.phoneProviderUnavailable);
        expect(wsClassifyOtpError(e).message, contains('verify your number '
            'later'));
      }
    });
  });

  // ═══ THE PROVISIONING GATE ════════════════════════════════════════════════

  group('the provisioning gate', () {
    test('an unverified phone does NOT open it', () async {
      final outcome = await register(WsPhoneVerification(FakeAuthClient()));
      expect(outcome.state, WsRegistrationState.phoneOtpSent);
      expect(outcome.canProvisionOrganization, isFalse,
          reason: 'a session alone is the behaviour this phase replaces');
    });

    test('a verified phone opens it', () async {
      final fake = FakeAuthClient();
      final v = WsPhoneVerification(fake);
      await register(v);
      final outcome = await v.confirmPhone(phone: phone, token: '123456');

      expect(outcome.state, WsRegistrationState.phoneOtpVerified);
      expect(outcome.canProvisionOrganization, isTrue);
      expect(outcome.user!.isPhoneConfirmed, isTrue);
      expect(outcome.assurance, WsPhoneAssurance.otpProven);
      expect(outcome.isPhoneOwnershipProven, isTrue);
    });

    test('a success that leaves the phone unconfirmed is treated as failure',
        () async {
      final fake = FakeAuthClient(confirmOnVerify: false);
      final v = WsPhoneVerification(fake);
      await register(v);

      await expectLater(
        v.confirmPhone(phone: phone, token: '123456'),
        throwsA(isA<WsAuthException>()),
        reason: 'the gate must not default open',
      );
    });
  });

  // ═══ EVERY WAY THE CODE FAILS ═════════════════════════════════════════════

  group('OTP failures are classified, not swallowed', () {
    Future<WsOtpError> classify(Object error) async {
      final fake = FakeAuthClient(verifyError: error);
      final v = WsPhoneVerification(fake);
      await register(v);
      try {
        await v.confirmPhone(phone: phone, token: '123456');
        fail('should have thrown');
      } catch (e) {
        return wsClassifyOtpError(e);
      }
    }

    test('expired', () async {
      expect(
        await classify(const WsAuthException('Token has expired',
            code: 'otp_expired', statusCode: 403)),
        WsOtpError.expired,
      );
    });

    test('rate limited by code', () async {
      expect(
        await classify(const WsAuthException('too many',
            code: 'over_sms_send_rate_limit', statusCode: 429)),
        WsOtpError.rateLimited,
      );
    });

    test('rate limited by status alone', () async {
      expect(
        await classify(const WsAuthException('slow down', statusCode: 429)),
        WsOtpError.rateLimited,
      );
    });

    test('number already registered', () async {
      expect(
        await classify(const WsAuthException('phone taken',
            code: 'phone_exists', statusCode: 422)),
        WsOtpError.phoneAlreadyInUse,
      );
    });

    test('session expired mid-verification', () async {
      expect(
        await classify(const WsAuthException('no session',
            code: 'session_not_found', statusCode: 401)),
        WsOtpError.sessionMissing,
      );
    });

    test('a wrong code is reported as wrong', () async {
      final fake = FakeAuthClient();
      final v = WsPhoneVerification(fake);
      await register(v);

      try {
        await v.confirmPhone(phone: phone, token: '000000');
        fail('should have thrown');
      } catch (e) {
        expect(wsClassifyOtpError(e), WsOtpError.incorrect);
      }
      expect(fake.tokensTried, ['000000']);
    });

    test('an empty code never reaches the server', () async {
      final fake = FakeAuthClient();
      final v = WsPhoneVerification(fake);
      await register(v);

      await expectLater(v.confirmPhone(phone: phone, token: '  '),
          throwsA(isA<WsAuthException>()));
      expect(fake.calls, isNot(contains('verifyPhoneChangeOtp')));
    });

    test('wrong and expired are NOT distinguishable, and we do not pretend',
        () {
      // This is GoTrue's actual reply to a wrong code, verbatim. The same
      // sentence comes back for a code that timed out.
      final ambiguous = wsClassifyOtpError(const WsAuthException(
          'Token has expired or is invalid',
          statusCode: 403));

      expect(ambiguous, WsOtpError.incorrect);
      expect(ambiguous.message, contains('wrong or has expired'),
          reason: 'telling someone their code is wrong when it merely timed '
              'out sends them back to re-typing a code that can never work');

      // An explicit code is unambiguous, so that path stays precise.
      expect(
        wsClassifyOtpError(const WsAuthException('Token has expired',
            code: 'otp_expired', statusCode: 403)),
        WsOtpError.expired,
      );
    });

    test('an unrecognised failure still produces usable advice', () {
      expect(wsClassifyOtpError(const WsAuthException('???')),
          WsOtpError.unknown);
      expect(WsOtpError.unknown.message, isNotEmpty);
      expect(wsClassifyOtpError(StateError('not an auth error')),
          WsOtpError.unknown);
    });
  });

  // ═══ RESEND ═══════════════════════════════════════════════════════════════

  group('resend', () {
    test('asks the server, and keeps no cooldown clock of its own', () async {
      final fake = FakeAuthClient();
      final v = WsPhoneVerification(fake);
      await register(v);

      await v.resendCode(phone);
      await v.resendCode(phone);

      expect(fake.calls.where((c) => c == 'resend').length, 2,
          reason: 'Supabase owns the interval and answers 429 past it; a '
              'second clock here would be the one that is wrong');
    });

    test('a server cooldown is classified as rate limiting', () async {
      final fake = FakeAuthClient(
        resendError: const WsAuthException('For security purposes, you can '
            'only request this after 60 seconds',
            code: 'over_sms_send_rate_limit', statusCode: 429),
      );
      final v = WsPhoneVerification(fake);
      await register(v);

      try {
        await v.resendCode(phone);
        fail('should have thrown');
      } catch (e) {
        expect(wsClassifyOtpError(e), WsOtpError.rateLimited);
      }
    });

    test('does NOT send a channel, because the API cannot carry one', () async {
      // The signature of resendPhoneChangeOtp is the assertion: it takes only a
      // phone. gotrue's resend() has no channel parameter, so accepting one
      // here and dropping it would read like a capability at the call site.
      final fake = FakeAuthClient();
      final whatsapp =
          WsPhoneVerification(fake, channel: WsOtpChannel.whatsapp);

      await whatsapp.resendCode(phone);

      expect(fake.resendCount, 1);
      expect(whatsapp.channel, WsOtpChannel.whatsapp,
          reason: 'the intent is still recorded for wording and for the day '
              'gotrue carries it — it is simply never put on the wire');
    });

    test('the channel makes no difference to what is sent', () async {
      final sms = FakeAuthClient();
      final whatsapp = FakeAuthClient();

      await WsPhoneVerification(sms, channel: WsOtpChannel.sms)
          .resendCode(phone);
      await WsPhoneVerification(whatsapp, channel: WsOtpChannel.whatsapp)
          .resendCode(phone);

      expect(sms.calls, whatsapp.calls,
          reason: 'the server owns delivery; a UI switch here would be a lie');
    });

    test('SMS is the default intent', () {
      expect(WsPhoneVerification(FakeAuthClient()).channel, WsOtpChannel.sms);
    });
  });

  // ═══ RESUMING AN INTERRUPTED REGISTRATION ═════════════════════════════════

  group('an interrupted registration can be resumed', () {
    test('attachPhone works on its own for a user who already signed up',
        () async {
      // The app was closed between signUp and the code arriving. There is a
      // session and no confirmed phone.
      final fake = FakeAuthClient(startSignedIn: true);
      final v = WsPhoneVerification(fake);

      final outcome = await v.attachPhone(phone);

      expect(outcome.state, WsRegistrationState.phoneOtpSent);
      expect(fake.calls, ['updatePhone'],
          reason: 'registering again would create a second auth user');
    });

    test('and refuses without a session rather than throwing from gotrue',
        () async {
      final fake = FakeAuthClient(startSignedIn: false);
      final v = WsPhoneVerification(fake);

      try {
        await v.attachPhone(phone);
        fail('should have thrown');
      } catch (e) {
        expect(wsClassifyOtpError(e), WsOtpError.sessionMissing);
      }
      expect(fake.calls, isEmpty,
          reason: 'checked before the call, so the failure names the cause');
    });
  });

  // ═══ PHONE NUMBERS ════════════════════════════════════════════════════════

  group('phone numbers', () {
    test('formatting is normalised', () {
      expect(wsNormalisePhone(' +92 300 123-4567 '), '+923001234567');
      expect(wsNormalisePhone('+92 (300) 1234567'), '+923001234567');
      expect(wsNormalisePhone('00923001234567'), '+923001234567');
    });

    test('a country code is required, never guessed', () {
      expect(wsIsValidPhone('03001234567'), isFalse,
          reason: 'inferring +92 would send a customer’s code to the wrong '
              'country the first time someone typed a local format');
      expect(wsIsValidPhone('+923001234567'), isTrue);
    });

    test('obvious nonsense is rejected', () {
      expect(wsIsValidPhone(''), isFalse);
      expect(wsIsValidPhone('+0123456789'), isFalse);
      expect(wsIsValidPhone('+12'), isFalse);
      expect(wsIsValidPhone('not a phone'), isFalse);
    });

    test('a bad number is rejected BEFORE the auth user is created', () async {
      final fake = FakeAuthClient();
      final v = WsPhoneVerification(fake);

      await expectLater(register(v, p: '03001234567'),
          throwsA(isA<WsAuthException>()));
      expect(fake.calls, isEmpty,
          reason: 'otherwise a typo strands a half-registered account');
    });

    test('the normalised form is what gets stored', () async {
      final fake = FakeAuthClient();
      await register(WsPhoneVerification(fake), p: '+92 300 123 4567');
      expect(fake.phonesSet, ['+923001234567']);
    });
  });

  // ═══ THE REDIRECT URL MOVED WITHOUT CHANGING ══════════════════════════════

  group('redirect URL configuration', () {
    test('falls back to the previous hard-coded literal', () {
      // .env is not loaded in tests and no --dart-define is set, which is
      // exactly the "unset" case. Behaviour must be identical to before.
      expect(WsConfig.redirectUrl, 'https://watersuppliersaas.vercel.app/');
    });

    test('is never empty', () {
      expect(WsConfig.redirectUrl, isNotEmpty,
          reason: 'an empty redirect makes Supabase fall back to the Site URL, '
              'which is a third behaviour again');
    });
  });
}
