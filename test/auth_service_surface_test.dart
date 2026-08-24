// =============================================================================
// test/auth_service_surface_test.dart
// AuthService must not offer a way around the registration state machine.
//
// ─── WHY THIS IS A SOURCE AUDIT ──────────────────────────────────────────────
//
// The rule being protected is a NEGATIVE about the public surface: no thin
// AuthService pass-through to a step of the OTP sequence. A behavioural test
// cannot express that, because the danger is a method that nothing calls —
// there is no behaviour to observe. Relying on "the test would not compile if
// it came back" is worse: it would fail as a compile error in an unrelated
// file, with nothing saying why.
//
// So this reads the source and asserts the declarations are absent, alongside
// behavioural tests proving the legitimate route still works and that the
// guards the wrappers skipped are still enforced.
//
// Three were removed:
//   verifyPhone()            → confirmPhone()   ← could manufacture otpProven
//   startPhoneVerification() → attachPhone()
//   resendPhoneCode()        → resendCode()
// =============================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/auth/ws_auth_client.dart';
import 'package:watersuppliersaas/services/auth/ws_phone_verification.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_attempt_store.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_flow.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';

import 'support/fake_auth_client.dart';

/// Source with comments stripped, so a tombstone mentioning a removed name is
/// not mistaken for the declaration coming back.
String _codeOf(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: '$path not found — run from the '
      'package root');
  return file
      .readAsLinesSync()
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  const phone = '+923009876543';
  late WsMemoryKeyValueStore kv;

  setUp(() => kv = WsMemoryKeyValueStore());

  WsRegistrationAttemptStore store() => WsRegistrationAttemptStore(kv);

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

  // ═══ THE SURFACE ══════════════════════════════════════════════════════════

  group('AuthService exposes no bypass of the registration flow', () {
    late String authService;

    setUp(() => authService = _codeOf('lib/services/auth_service.dart'));

    test('verifyPhone is gone', () {
      expect(authService, isNot(contains('verifyPhone(')),
          reason: 'it returned phoneOtpVerified whenever the server said the '
              'number was confirmed — under phone_autoconfirm that is true '
              'without any code having been sent');
    });

    test('startPhoneVerification is gone', () {
      expect(authService, isNot(contains('startPhoneVerification')),
          reason: 'it could attach a phone and trigger an OTP without the '
              'attempt knowing or persisting anything');
    });

    test('resendPhoneCode is gone', () {
      expect(authService, isNot(contains('resendPhoneCode')),
          reason: 'it skipped the phoneOtpSent prerequisite');
    });

    test('and none of the three sequence steps is called directly', () {
      // AuthService may hold the WsPhoneVerification instance — the flow needs
      // it — but must not invoke a step of the sequence itself.
      for (final step in ['.confirmPhone(', '.attachPhone(', '.resendCode(']) {
        expect(authService, isNot(contains(step)),
            reason: 'only WsRegistrationFlow may call $step');
      }
    });

    test('the flow-facing entry points survive', () {
      // The removal must not have taken the legitimate surface with it.
      for (final kept in [
        'resumeRegistration',
        'beginRegistration',
        'beginAdditionalOrganization',
        'provisionForRegistration',
      ]) {
        expect(authService, contains(kept));
      }
    });
  });

  group('the lower-level operations remain, and only the flow calls them', () {
    test('WsPhoneVerification still implements all three', () {
      final service = _codeOf('lib/services/auth/ws_phone_verification.dart');
      expect(service, contains('confirmPhone('));
      expect(service, contains('attachPhone('));
      expect(service, contains('resendCode('));
    });

    test('WsRegistrationFlow is the only production caller', () {
      final flow = _codeOf('lib/services/auth/ws_registration_flow.dart');
      expect(flow, contains('verification.confirmPhone('));
      expect(flow, contains('verification.attachPhone('));
      expect(flow, contains('verification.resendCode('));
    });

    test('no screen calls a verification step directly', () {
      for (final screen in [
        'lib/screens/register_screen.dart',
        'lib/screens/organization_selector_screen.dart',
      ]) {
        final code = _codeOf(screen);
        expect(code, isNot(contains('confirmPhone(')));
        expect(code, isNot(contains('attachPhone(')));
        // The screen calls flow.resendCode() — the FLOW's method, which is
        // guarded — never the service's resendCode(phone).
        expect(code, isNot(contains('phoneVerification')));
      }
    });
  });

  // ═══ THE GUARDS THE WRAPPERS SKIPPED ══════════════════════════════════════

  group('the guards are still enforced', () {
    test('phoneOtpSent is the prerequisite for resend', () async {
      final autoconfirmed =
          await registration(FakeAuthClient(autoconfirmPhone: true));
      expect(autoconfirmed.state, WsRegistrationState.phoneAlreadyConfirmed);
      expect(autoconfirmed.resendCode(), throwsA(isA<StateError>()),
          reason: 'nothing was sent, so there is nothing to re-send');

      final pending = await registration(FakeAuthClient(
        sessionAfterSignUp: false,
      ));
      expect(pending.state, WsRegistrationState.emailConfirmationPending);
      expect(pending.resendCode(), throwsA(isA<StateError>()));
    });

    test('phoneAlreadyConfirmed cannot become an OTP-verification path',
        () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      final flow = await registration(fake);

      expect(flow.submitCode('123456'), throwsA(isA<StateError>()));
      expect(fake.calls, isNot(contains('verifyPhoneChangeOtp')));
      expect(flow.assurance, WsPhoneAssurance.serverAsserted);
      expect(flow.isPhoneOwnershipProven, isFalse);
    });

    test('serverAsserted cannot become otpProven', () async {
      final flow = await registration(FakeAuthClient(autoconfirmPhone: true));
      try {
        await flow.submitCode('123456');
      } catch (_) {}
      expect(flow.assurance, isNot(WsPhoneAssurance.otpProven));
    });
  });

  // ═══ THE LEGITIMATE ROUTE IS UNCHANGED ════════════════════════════════════

  group('registration still runs the whole phone flow through the machine', () {
    test('attachPhone → phoneOtpSent → resend → submitCode → otpProven',
        () async {
      final fake = FakeAuthClient();
      final flow = await registration(fake);

      expect(flow.state, WsRegistrationState.phoneOtpSent);
      await flow.resendCode();
      expect(flow.state, WsRegistrationState.phoneOtpSent,
          reason: 'a resend leaves the machine where it was');
      await flow.submitCode('123456');

      expect(flow.state, WsRegistrationState.phoneOtpVerified);
      expect(flow.assurance, WsPhoneAssurance.otpProven);
      expect(fake.calls,
          ['signUp', 'updatePhone', 'resend', 'verifyPhoneChangeOtp']);
    });

    test('resend preserves the clientuuid', () async {
      final fake = FakeAuthClient();
      final flow = await registration(fake);
      final key = flow.clientUuid!;

      await flow.resendCode();
      expect(flow.clientUuid, key);

      // And after a reload, which is where an in-memory key would be lost.
      final resumed = await WsRegistrationFlow.resume(
        verification: WsPhoneVerification(fake),
        store: store(),
      );
      expect(resumed!.clientUuid, key);
    });

    test('wrong code, resend, rate limit and session loss keep ONE key',
        () async {
      final keys = <String>{};

      final fake = FakeAuthClient();
      final flow = await registration(fake);
      keys.add(flow.clientUuid!);

      await flow.submitCode('000000'); // wrong
      keys.add(flow.clientUuid!);
      await flow.resendCode();
      keys.add(flow.clientUuid!);

      // A rate-limited resend.
      final limited = FakeAuthClient(
        resendError: const WsAuthException('wait',
            code: 'over_sms_send_rate_limit', statusCode: 429),
      );
      final resumed = await WsRegistrationFlow.resume(
        verification: WsPhoneVerification(limited),
        store: store(),
      );
      await resumed!.resendCode();
      expect(resumed.lastError, WsOtpError.rateLimited);
      keys.add(resumed.clientUuid!);

      expect(keys, hasLength(1));
      expect(fake.signUpCount, 1);
      expect(fake.signInWithOtpCalls, 0);
    });
  });
}
