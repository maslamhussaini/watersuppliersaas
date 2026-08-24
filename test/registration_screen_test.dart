// =============================================================================
// test/registration_screen_test.dart
// The UI contract, driven through AuthService's injectable seams.
//
// The screen is deliberately NOT pumped here: it reaches main.dart's supabase
// getter through AuthService, which needs a live client. What IS tested is the
// contract the screen depends on — that resume returns the same attempt, that
// the states it switches on are reachable, and that no path mints a second key.
// A screen test that needed a Supabase instance would test the mock, not us.
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

  WsRegistrationAttemptStore store() =>
      WsRegistrationAttemptStore(WsPreferencesKeyValueStore(backend));

  /// What initState does: resume, else begin. Mirrors _restore() exactly.
  Future<WsRegistrationFlow> screenOpens(FakeAuthClient fake) async =>
      await WsRegistrationFlow.resume(
        verification: WsPhoneVerification(fake),
        store: store(),
      ) ??
      WsRegistrationFlow(
        WsPhoneVerification(fake),
        store: store(),
        email: 'owner@example.com',
        orgName: 'Kent Water',
        ownerName: 'Essa',
        orgPhone: '+923009999999',
        address: 'Karachi',
      );

  Future<WsRegistrationState> submit(WsRegistrationFlow f) => f.start(
        email: 'owner@example.com',
        password: 'sup3rsecret',
        phone: phone,
      );

  // ═══ THE SCREEN NEVER MINTS A SECOND KEY ══════════════════════════════════

  group('reopening the screen resumes rather than restarting', () {
    test('a reload while the OTP is pending keeps the key', () async {
      final fake = FakeAuthClient();
      final first = await screenOpens(fake);
      await submit(first);
      final key = first.clientUuid!;

      // Browser reload: State is gone, initState runs again.
      final second = await screenOpens(fake);

      expect(second.clientUuid, key);
      expect(second.isAwaitingCode, isTrue);
      expect(fake.signUpCount, 1,
          reason: 'reopening the screen must not sign up a second time');
    });

    test('a reload after a wrong code keeps the key', () async {
      final fake = FakeAuthClient();
      final first = await screenOpens(fake);
      await submit(first);
      final key = first.clientUuid!;
      await first.submitCode('000000');

      expect((await screenOpens(fake)).clientUuid, key);
    });

    test('a resend then a reload keeps the key', () async {
      final fake = FakeAuthClient();
      final first = await screenOpens(fake);
      await submit(first);
      final key = first.clientUuid!;
      await first.resendCode();

      expect((await screenOpens(fake)).clientUuid, key);
    });

    test('a session expiry then a reopen keeps the key', () async {
      final fake = FakeAuthClient(
        verifyError: const WsAuthException('gone',
            code: 'session_not_found', statusCode: 401),
      );
      final first = await screenOpens(fake);
      await submit(first);
      final key = first.clientUuid!;
      await first.submitCode('123456');

      final second = await screenOpens(fake);
      expect(second.clientUuid, key);
      expect(second.state, WsRegistrationState.sessionMissing,
          reason: 'the screen renders the sign-in notice, not the wizard');
    });

    test('emailConfirmationPending survives a reopen', () async {
      final fake = FakeAuthClient(sessionAfterSignUp: false);
      final first = await screenOpens(fake);
      await submit(first);
      final key = first.clientUuid!;

      final second = await screenOpens(fake);
      expect(second.clientUuid, key);
      expect(second.state, WsRegistrationState.emailConfirmationPending);
    });

    test('across the ENTIRE journey only one key is ever produced', () async {
      final fake = FakeAuthClient();
      final keys = <String>{};

      var flow = await screenOpens(fake);
      await submit(flow);
      keys.add(flow.clientUuid!);

      flow = await screenOpens(fake); // reload
      keys.add(flow.clientUuid!);
      await flow.submitCode('000000'); // wrong
      keys.add(flow.clientUuid!);
      await flow.resendCode();
      keys.add(flow.clientUuid!);

      flow = await screenOpens(fake); // reload again
      keys.add(flow.clientUuid!);
      await flow.submitCode('123456');
      keys.add(flow.clientUuid!);

      expect(keys, hasLength(1),
          reason: 'every extra key here is an extra organization');
      expect(fake.signUpCount, 1);
      expect(fake.signInWithOtpCalls, 0);
    });
  });

  // ═══ PROVISIONING FROM THE SCREEN ═════════════════════════════════════════

  group('provisioning', () {
    Future<WsRegistrationFlow> ready(FakeAuthClient fake) async {
      final flow = await screenOpens(fake);
      await submit(flow);
      await flow.submitCode('123456');
      return flow;
    }

    test('the gate opens and the original key is used', () async {
      final fake = FakeAuthClient();
      final flow = await ready(fake);
      final key = flow.clientUuid!;

      String? used;
      await flow.provisionOrganization((u) async {
        used = u;
        return 42;
      });

      expect(used, key);
      expect(await store().load(), isNull, reason: 'the attempt is finished');
    });

    test('a failure keeps the attempt so the retry resolves', () async {
      final fake = FakeAuthClient();
      final flow = await ready(fake);
      final key = flow.clientUuid!;

      try {
        await flow.provisionOrganization((_) async => throw Exception('502'));
      } catch (_) {}

      final retry = await screenOpens(fake);
      expect(retry.clientUuid, key);
      expect(retry.canProvisionOrganization, isTrue,
          reason: 'the user can press Create again and land on the same org');
    });

    test('phoneAlreadyConfirmed provisions without claiming a code was sent',
        () async {
      final fake = FakeAuthClient(autoconfirmPhone: true);
      final flow = await screenOpens(fake);
      await submit(flow);

      expect(flow.isAwaitingCode, isFalse,
          reason: 'the OTP step must not be shown — no code was delivered');
      expect(flow.canProvisionOrganization, isTrue);
      expect(flow.assurance, WsPhoneAssurance.serverAsserted);
    });
  });

  // ═══ THE SELECTOR RECOVERY PATH ═══════════════════════════════════════════

  group('the organization selector recovers the same attempt', () {
    test('it finds a pending attempt instead of starting a new one', () async {
      final fake = FakeAuthClient();
      final registration = await screenOpens(fake);
      await submit(registration);
      await registration.submitCode('123456');
      final key = registration.clientUuid!;

      // The user closed the tab, confirmed email, signed in, landed here.
      final recovered = await WsRegistrationFlow.resume(
        verification: WsPhoneVerification(fake),
        store: store(),
      );

      expect(recovered, isNotNull);
      expect(recovered!.clientUuid, key,
          reason: 'this screen used to mint its own key, which would have '
              'built a SECOND organization for an attempt whose RPC may '
              'already have committed');
    });

    test('with no pending attempt it is free to start a fresh one', () async {
      final fake = FakeAuthClient();

      final none = await WsRegistrationFlow.resume(
        verification: WsPhoneVerification(fake),
        store: store(),
      );
      expect(none, isNull);

      // An existing user adding a second organization: a new key is correct,
      // and it is DURABLE before anything reaches the RPC.
      final fresh = await WsRegistrationFlow.beginForExistingUser(
        verification: WsPhoneVerification(fake),
        store: store(),
        orgName: 'Second Depot',
        ownerName: 'Essa',
        orgPhone: '+923009999999',
        address: 'Lahore',
      );

      expect(fresh.clientUuid, isNotEmpty);
      expect((await store().load())!.clientUuid, fresh.clientUuid,
          reason: 'persisted before returning, not after the RPC');
    });
  });
}
