// =============================================================================
// test/registration_persistence_test.dart
// ONE registration attempt = ONE clientuuid, across everything that can
// interrupt it.
//
// The interruptions are simulated the way they actually happen: a NEW flow
// object built over the SAME backend. That is exactly what a browser reload,
// a route recreation and an app restart look like from the storage layer —
// everything in memory is gone, the backend is not.
// =============================================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/auth/ws_auth_client.dart';
import 'package:watersuppliersaas/services/auth/ws_phone_verification.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_attempt_store.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_flow.dart';
import 'package:watersuppliersaas/services/storage/ws_kv_preferences.dart';

import 'support/fake_auth_client.dart';

void main() {
  // Deliberately does NOT contain '123456'. The fake's correct code is
  // 123456, and the obvious test number +923001234567 contains those digits —
  // which made the "no OTP is written down" assertion fail on the PHONE, a
  // false positive that would have been silenced rather than understood.
  const phone = '+923009876543';
  late WsFakePreferencesBackend backend;

  setUp(() => backend = WsFakePreferencesBackend());

  WsRegistrationAttemptStore attemptStore() => WsRegistrationAttemptStore(
        WsPreferencesKeyValueStore(backend),
      );

  WsRegistrationFlow flowOver(FakeAuthClient fake) => WsRegistrationFlow(
        WsPhoneVerification(fake),
        store: attemptStore(),
        email: 'owner@example.com',
        orgName: 'Kent Water',
        ownerName: 'Essa',
        orgPhone: '+923009999999',
        address: 'Karachi',
      );

  /// What a browser reload looks like: nothing in memory, same backend.
  Future<WsRegistrationFlow?> afterReload(FakeAuthClient fake) =>
      WsRegistrationFlow.resume(
        verification: WsPhoneVerification(fake),
        store: attemptStore(),
      );

  Future<WsRegistrationState> start(WsRegistrationFlow f) => f.start(
        email: 'owner@example.com',
        password: 'sup3rsecret',
        phone: phone,
        redirectTo: 'https://example.test/',
      );

  // ═══ THE INVARIANT ════════════════════════════════════════════════════════

  group('one attempt, one clientuuid — across every interruption', () {
    test('a browser reload restores the SAME key', () async {
      final fake = FakeAuthClient();
      final flow = flowOver(fake);
      await start(flow);
      final key = flow.clientUuid!;

      final resumed = await afterReload(fake);

      expect(resumed, isNotNull);
      expect(resumed!.clientUuid, key);
    });

    test('a wrong code does not change it, before OR after a reload', () async {
      final fake = FakeAuthClient();
      final flow = flowOver(fake);
      await start(flow);
      final key = flow.clientUuid!;

      await flow.submitCode('000000');
      expect(flow.clientUuid, key);

      expect((await afterReload(fake))!.clientUuid, key,
          reason: 'a mistyped code must cost a retype, never a second '
              'organization');
    });

    test('a resend does not change it', () async {
      final fake = FakeAuthClient();
      final flow = flowOver(fake);
      await start(flow);
      final key = flow.clientUuid!;

      await flow.resendCode();

      expect(flow.clientUuid, key);
      expect((await afterReload(fake))!.clientUuid, key);
    });

    test('a rate limit does not change it', () async {
      final fake = FakeAuthClient(
        resendError: const WsAuthException('wait 60 seconds',
            code: 'over_sms_send_rate_limit', statusCode: 429),
      );
      final flow = flowOver(fake);
      await start(flow);
      final key = flow.clientUuid!;

      await flow.resendCode();

      expect(flow.lastError, WsOtpError.rateLimited);
      expect((await afterReload(fake))!.clientUuid, key);
    });

    test('a session expiry does not change it', () async {
      final fake = FakeAuthClient(
        verifyError: const WsAuthException('no session',
            code: 'session_not_found', statusCode: 401),
      );
      final flow = flowOver(fake);
      await start(flow);
      final key = flow.clientUuid!;

      await flow.submitCode('123456');
      expect(flow.state, WsRegistrationState.sessionMissing);

      final resumed = await afterReload(fake);
      expect(resumed!.clientUuid, key);
      expect(resumed.state, WsRegistrationState.sessionMissing,
          reason: 'the screen must know to ask for a sign-in, not restart');
    });

    test('every state transition keeps it', () async {
      final fake = FakeAuthClient();
      final flow = flowOver(fake);
      await start(flow);
      final key = flow.clientUuid!;

      await flow.submitCode('000000');
      await flow.resendCode();
      await flow.submitCode('123456');

      expect(flow.state, WsRegistrationState.phoneOtpVerified);
      expect(flow.clientUuid, key);
      expect((await afterReload(fake))!.clientUuid, key);
    });

    test('a fresh store instance over the same backend sees it', () async {
      final fake = FakeAuthClient();
      await start(flowOver(fake));

      final direct = await WsRegistrationAttemptStore(
        WsPreferencesKeyValueStore(backend),
      ).load();

      expect(direct, isNotNull);
      expect(direct!.clientUuid, isNotEmpty);
    });

    test('copyWith CANNOT replace the key', () {
      final a = WsRegistrationAttempt(
        clientUuid: 'original',
        state: 'phoneOtpSent',
        startedAt: DateTime.utc(2026, 8, 14),
      );
      // There is no clientUuid parameter to pass. This is a compile-time
      // guarantee, not a runtime check — the bug cannot be written.
      expect(a.copyWith(state: 'phoneOtpVerified').clientUuid, 'original');
    });
  });

  // ═══ WHAT IS RESTORED ═════════════════════════════════════════════════════

  group('a resumed attempt knows where it was', () {
    test('the state and phone come back', () async {
      final fake = FakeAuthClient();
      await start(flowOver(fake));

      final resumed = await afterReload(fake);

      expect(resumed!.state, WsRegistrationState.phoneOtpSent);
      expect(resumed.phone, phone);
      expect(resumed.isAwaitingCode, isTrue);
    });

    test('the business draft comes back, so nothing is re-asked', () async {
      final fake = FakeAuthClient();
      await start(flowOver(fake));

      final resumed = await afterReload(fake);

      expect(resumed!.orgName, 'Kent Water');
      expect(resumed.ownerName, 'Essa');
      expect(resumed.address, 'Karachi');
      expect(resumed.email, 'owner@example.com');
    });

    test('SERVERASSERTED DOES NOT BECOME OTPPROVEN ACROSS A RELOAD', () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      await start(flowOver(fake));

      final resumed = await afterReload(fake);

      expect(resumed!.state, WsRegistrationState.phoneAlreadyConfirmed);
      expect(resumed.assurance, WsPhoneAssurance.serverAsserted);
      expect(resumed.isPhoneOwnershipProven, isFalse,
          reason: 'a reload must not silently upgrade a dashboard toggle into '
              'proof that somebody holds the number');
    });

    test('otpProven survives as otpProven', () async {
      final fake = FakeAuthClient();
      final flow = flowOver(fake);
      await start(flow);
      await flow.submitCode('123456');

      final resumed = await afterReload(fake);
      expect(resumed!.assurance, WsPhoneAssurance.otpProven);
    });

    test('emailConfirmationPending survives', () async {
      final fake = FakeAuthClient(sessionAfterSignUp: false);
      await start(flowOver(fake));

      final resumed = await afterReload(fake);
      expect(resumed!.state, WsRegistrationState.emailConfirmationPending);
      expect(resumed.needsUserActionOutsideRegistration, isTrue);
    });

    test('resuming does not re-run signUp', () async {
      final fake = FakeAuthClient();
      await start(flowOver(fake));
      await afterReload(fake);

      expect(fake.signUpCount, 1,
          reason: 'a second signUp is a second auth identity');
      expect(fake.signInWithOtpCalls, 0);
    });
  });

  // ═══ CLEARING ═════════════════════════════════════════════════════════════

  group('the attempt ends exactly twice: provisioned, or abandoned', () {
    Future<WsRegistrationFlow> verified(FakeAuthClient fake) async {
      final flow = flowOver(fake);
      await start(flow);
      await flow.submitCode('123456');
      return flow;
    }

    test('successful provisioning clears it', () async {
      final fake = FakeAuthClient();
      final flow = await verified(fake);

      await flow.completeProvisioning(42);

      expect(flow.organizationId, 42);
      expect(await attemptStore().load(), isNull);
      expect(await afterReload(fake), isNull,
          reason: 'there is nothing left to resume');
    });

    test('abandoning clears it', () async {
      final fake = FakeAuthClient();
      final flow = flowOver(fake);
      await start(flow);

      await flow.abandon();

      expect(await afterReload(fake), isNull);
    });

    test('a lost provisioning response keeps the SAME key for the retry',
        () async {
      final fake = FakeAuthClient();
      final flow = await verified(fake);
      final key = flow.clientUuid!;

      // The RPC committed; the response never arrived, so nothing was cleared.
      // The user reloads and tries again.
      final retry = await afterReload(fake);

      expect(retry!.clientUuid, key,
          reason: 'ws_create_organization resolves to the organization it '
              'already made ONLY if the key is identical');
    });

    test('recording a different organization id is refused', () async {
      final flow = await verified(FakeAuthClient());
      await flow.completeProvisioning(42);

      expect(() => flow.markOrganizationProvisioned(43),
          throwsA(isA<StateError>()));
    });

    test('recording the same id twice is a no-op', () async {
      final flow = await verified(FakeAuthClient());
      await flow.completeProvisioning(42);
      await flow.completeProvisioning(42);
      expect(flow.organizationId, 42);
    });
  });

  // ═══ BAD PERSISTED DATA ═══════════════════════════════════════════════════

  group('unusable stored state never becomes a fake resume', () {
    Future<void> store(String raw) => backend.setString(
        'ws.${WsRegistrationAttemptStore.storageKey}', raw);

    test('corrupt JSON resumes as nothing', () async {
      await store('{half a jso');
      expect(await afterReload(FakeAuthClient()), isNull);
    });

    test('a missing clientUuid resumes as nothing', () async {
      await store(jsonEncode({
        'state': 'phoneOtpSent',
        'startedAt': DateTime.utc(2026, 8, 14).toIso8601String(),
      }));
      expect(await afterReload(FakeAuthClient()), isNull,
          reason: 'resuming without the key would be a new attempt wearing the '
              'old one\'s clothes');
    });

    test('a missing timestamp resumes as nothing', () async {
      await store(jsonEncode({'clientUuid': 'k', 'state': 'phoneOtpSent'}));
      expect(await afterReload(FakeAuthClient()), isNull);
    });

    test('a stale attempt is not resumed', () async {
      final fake = FakeAuthClient();
      await start(flowOver(fake));

      final resumed = await WsRegistrationFlow.resume(
        verification: WsPhoneVerification(fake),
        store: attemptStore(),
        now: DateTime.now().toUtc().add(const Duration(days: 2)),
      );

      expect(resumed, isNull);
      expect(await attemptStore().load(), isNull,
          reason: 'and it is cleared, not re-decided on every launch');
    });

    test('an unknown state falls back without losing the key', () async {
      await store(jsonEncode({
        'clientUuid': 'k',
        'state': 'someStateFromANewerBuild',
        'startedAt': DateTime.now().toUtc().toIso8601String(),
      }));

      final resumed = await afterReload(FakeAuthClient());

      expect(resumed!.clientUuid, 'k',
          reason: 'the KEY must survive; the step can be re-walked');
      expect(resumed.state, WsRegistrationState.notStarted);
    });
  });

  // ═══ SECRETS ══════════════════════════════════════════════════════════════

  group('nothing secret is written', () {
    test('the persisted payload has no credential fields', () async {
      final fake = FakeAuthClient();
      final flow = flowOver(fake);
      await start(flow);
      await flow.submitCode('123456');

      final raw = (await backend
          .getString('ws.${WsRegistrationAttemptStore.storageKey}'))!;
      final fields = jsonDecode(raw) as Map<String, dynamic>;

      for (final forbidden in [
        'password', 'otp', 'otpCode', 'code', 'token', 'jwt',
        'accessToken', 'access_token', 'refreshToken', 'refresh_token',
        'session',
      ]) {
        expect(fields.containsKey(forbidden), isFalse,
            reason: 'field "$forbidden" must never be persisted');
      }
    });

    test('and no value is JWT-shaped or a bearer token', () async {
      final fake = FakeAuthClient();
      await start(flowOver(fake));

      final raw = (await backend
          .getString('ws.${WsRegistrationAttemptStore.storageKey}'))!;
      for (final v in (jsonDecode(raw) as Map<String, dynamic>).values) {
        expect('$v', isNot(matches(RegExp(r'^eyJ[A-Za-z0-9_-]{10,}\.'))));
        expect('$v'.toLowerCase(), isNot(contains('bearer ')));
      }
    });

    test('the password used to register is nowhere in the backend', () async {
      final fake = FakeAuthClient();
      await start(flowOver(fake));

      for (final stored in backend.values.values) {
        expect(stored, isNot(contains('sup3rsecret')),
            reason: 'the password never leaves the form');
      }
    });

    test('the OTP the user typed is not written down', () async {
      final fake = FakeAuthClient();
      final flow = flowOver(fake);
      await start(flow);
      await flow.submitCode('123456');

      for (final stored in backend.values.values) {
        expect(stored, isNot(contains('123456')),
            reason: 'writing down the code that proves possession of the '
                'phone would defeat asking for it');
      }
    });
  });

  // ═══ WITHOUT A STORE, NOTHING CHANGES ═════════════════════════════════════

  test('a flow with no store behaves exactly as before', () async {
    final fake = FakeAuthClient();
    final flow = WsRegistrationFlow(WsPhoneVerification(fake));

    await start(flow);
    await flow.submitCode('123456');

    expect(flow.state, WsRegistrationState.phoneOtpVerified);
    expect(flow.clientUuid, isNotEmpty);
    expect(backend.values, isEmpty,
        reason: 'persistence is opt-in; the pre-existing suites rely on that');
  });

  // ═══ THE STALE-STATE DEFECT, FOUND BY REAL E2E ═══════════════════════════
  //
  // Everything above resumes with a fake whose session AGREES with what was
  // persisted, because a fake cannot mint a session out of band. Real life can:
  // the confirmation link is opened in the mail client, not in the app.
  //
  // Against a real project with mailer_autoconfirm off — Supabase's default —
  // the sequence was:
  //
  //   sign up  ->  saved as emailConfirmationPending (correct: no session)
  //   confirm the email elsewhere
  //   sign in  ->  a REAL session now exists
  //   Create Organization  ->  "Cannot provision from state
  //                             emailConfirmationPending"
  //
  // leaving the user with an account, no business and no way forward: every
  // retry restored the same stale label. resume() trusted the stored state.
  // The session is the fact.

  group('a stored no-session state is reconciled against a live session', () {
    test('emailConfirmationPending + a real session can provision', () async {
      final signUp = FakeAuthClient(sessionAfterSignUp: false);
      await start(flowOver(signUp));

      // The link is opened elsewhere and the user signs in. A NEW client that
      // is already signed in — nothing in memory carries over, which is the
      // whole point.
      final resumed = await afterReload(FakeAuthClient(startSignedIn: true));

      expect(resumed, isNotNull);
      expect(resumed!.state, WsRegistrationState.emailConfirmationPending,
          reason: 'the stored label is kept — it is history, not a lie');
      expect(resumed.canProvisionOrganization, isTrue,
          reason: 'THE DEFECT: the gate read the stale label instead of the '
              'live session and refused to create the organization');
      expect(resumed.needsUserActionOutsideRegistration, isFalse,
          reason: 'the email was confirmed seconds ago — do not send them back '
              'to do it again');
    });

    test('provisioning runs, and keeps the ORIGINAL clientuuid', () async {
      final signUp = FakeAuthClient(sessionAfterSignUp: false);
      final first = flowOver(signUp);
      await start(first);
      final originalKey = first.clientUuid;

      final resumed = await afterReload(FakeAuthClient(startSignedIn: true));

      String? keyUsed;
      final orgId = await resumed!.provisionOrganization((uuid) async {
        keyUsed = uuid;
        return 77;
      });

      expect(orgId, 77);
      expect(keyUsed, originalKey,
          reason: 'one attempt, one clientuuid, one organization — surviving '
              'an email round trip and a sign-in');
      expect(resumed.isComplete, isTrue);
    });

    test('WITHOUT a session it still refuses, exactly as before', () async {
      final signUp = FakeAuthClient(sessionAfterSignUp: false);
      await start(flowOver(signUp));

      final resumed = await afterReload(FakeAuthClient(startSignedIn: false));

      expect(resumed!.canProvisionOrganization, isFalse,
          reason: 'the fix is narrow — a genuinely unauthenticated user is '
              'untouched and must still go and confirm their email');
      expect(resumed.needsUserActionOutsideRegistration, isTrue);
      expect(resumed.provisionOrganization((_) async => 1),
          throwsA(isA<StateError>()));
    });

    test('an unrelated stored state is not reconciled', () async {
      // phoneOtpSent says nothing about a missing session, so a live session
      // must not silently promote it into a provisionable attempt.
      final fake = FakeAuthClient();
      await start(flowOver(fake));

      final resumed = await afterReload(FakeAuthClient(startSignedIn: true));

      expect(resumed!.state, WsRegistrationState.phoneOtpSent);
      expect(resumed.canProvisionOrganization, isFalse,
          reason: 'only the two no-session states are reconciled; the phone '
              'still has to be verified');
    });
  });

}
