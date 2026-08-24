// =============================================================================
// test/registration_production_wiring_test.dart
// The four closures in WsRegistrationDeps.production(), exercised for real.
//
// ─── THE GAP THIS CLOSES ─────────────────────────────────────────────────────
//
// registration_widget_test.dart INJECTS deps, so it proves the screen renders
// each state correctly while saying nothing about whether the production
// factory is wired to the right AuthService methods. A transposed pair of
// closures there would pass every other suite in the repo and fail on the first
// real registration.
//
// Nothing is mocked at the factory boundary: this calls
// WsRegistrationDeps.production() itself. What makes that possible without a
// live Supabase client is that AuthService already carries two seams —
// authClientOverride and attemptStoreOverride — so phoneVerification and
// registrationStore resolve to fakes and `supabase` is never evaluated.
//
// The exception is `provision`, which necessarily reaches the RPC. That is
// asserted at the boundary: the call arrives at createOrganizationForCurrentUser
// and fails there for want of a client, which proves the delegation without
// needing a database.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/screens/register_screen.dart';
import 'package:watersuppliersaas/services/auth/ws_phone_verification.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_attempt_store.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_flow.dart';
import 'package:watersuppliersaas/services/auth_service.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';

import 'support/fake_auth_client.dart';

void main() {
  const phone = '+923009876543';
  late FakeAuthClient fake;
  late WsMemoryKeyValueStore kv;

  setUp(() {
    fake = FakeAuthClient();
    kv = WsMemoryKeyValueStore();
    AuthService.authClientOverride = fake;
    AuthService.attemptStoreOverride = WsRegistrationAttemptStore(kv);
  });

  tearDown(() {
    AuthService.authClientOverride = null;
    AuthService.attemptStoreOverride = null;
  });

  /// The REAL factory. Not a fake, not a copy of its wiring.
  WsRegistrationDeps production() => WsRegistrationDeps.production();

  Future<WsRegistrationFlow> beginViaProduction() => production().begin(
        email: 'owner@example.com',
        orgName: 'Kent Water',
        ownerName: 'Essa',
        orgPhone: '+923009999999',
        address: 'Karachi',
      );

  Future<WsRegistrationState> start(WsRegistrationFlow f) => f.start(
        email: 'owner@example.com',
        password: 'sup3rsecret',
        phone: phone,
      );

  // ═══ resume ═══════════════════════════════════════════════════════════════

  group('production().resume', () {
    test('returns null when there is no attempt', () async {
      expect(await production().resume(), isNull);
    });

    test('returns the persisted attempt, with its key', () async {
      final flow = await beginViaProduction();
      await start(flow);
      final key = flow.clientUuid!;

      final resumed = await production().resume();

      expect(resumed, isNotNull);
      expect(resumed!.clientUuid, key,
          reason: 'if resume were wired to the wrong method this would be a '
              'fresh key, and the next provisioning would build a second '
              'organization');
      expect(resumed.state, WsRegistrationState.phoneOtpSent);
    });

    test('reads the SAME store that begin writes to', () async {
      await start(await beginViaProduction());

      // Straight out of the backing store, bypassing AuthService entirely.
      final direct = await WsRegistrationAttemptStore(kv).load();
      final viaProduction = await production().resume();

      expect(direct, isNotNull);
      expect(viaProduction!.clientUuid, direct!.clientUuid,
          reason: 'resume and begin must not be pointed at different stores');
    });
  });

  // ═══ begin ════════════════════════════════════════════════════════════════

  group('production().begin', () {
    test('produces a flow that persists through the real store', () async {
      final flow = await beginViaProduction();
      await start(flow);

      expect(flow.clientUuid, isNotNull);
      expect(await WsRegistrationAttemptStore(kv).load(), isNotNull,
          reason: 'begin must hand the flow a store, or nothing survives a '
              'reload');
    });

    test('carries the business draft through, in the right fields', () async {
      final flow = await beginViaProduction();

      // Transposed arguments in the factory would surface exactly here.
      expect(flow.email, 'owner@example.com');
      expect(flow.orgName, 'Kent Water');
      expect(flow.ownerName, 'Essa');
      expect(flow.orgPhone, '+923009999999');
      expect(flow.address, 'Karachi');
    });

    test('runs the real auth sequence: signUp then updatePhone', () async {
      await start(await beginViaProduction());

      expect(fake.calls, ['signUp', 'updatePhone'],
          reason: 'the production flow is wired to the same verification '
              'sequence as every other suite');
    });
  });

  // ═══ provision ════════════════════════════════════════════════════════════

  group('production().provision', () {
    Future<WsRegistrationFlow> verified() async {
      final flow = await beginViaProduction();
      await start(flow);
      await flow.submitCode('123456');
      return flow;
    }

    test('delegates as far as the real RPC call', () async {
      final flow = await verified();
      expect(flow.canProvisionOrganization, isTrue);

      // Reaches createOrganizationForCurrentUser, which needs a client. The
      // failure IS the evidence: a mis-wired closure would fail differently,
      // or not at all.
      await expectLater(
        production().provision(flow),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('Supabase is not initialized'))),
      );
    });

    test('the gate still runs FIRST, before any delegation', () async {
      // Not verified: provisioning must be refused by the state machine before
      // the RPC is reached at all.
      final flow = await beginViaProduction();
      await start(flow);
      expect(flow.canProvisionOrganization, isFalse);

      await expectLater(
        production().provision(flow),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('Cannot provision from state'))),
      );
    });

    test('a failed provisioning leaves the attempt recoverable', () async {
      final flow = await verified();
      final key = flow.clientUuid!;

      try {
        await production().provision(flow);
      } catch (_) {}

      final resumed = await production().resume();
      expect(resumed, isNotNull, reason: 'the RPC may have committed');
      expect(resumed!.clientUuid, key);
    });
  });

  // ═══ THE NEGATIVE, THROUGH THE PRODUCTION PATH ════════════════════════════

  test('the production wiring never calls signInWithOtp', () async {
    final flow = await beginViaProduction();
    await start(flow);
    await flow.submitCode('000000');
    await flow.resendCode();
    await flow.submitCode('123456');
    try {
      await production().provision(flow);
    } catch (_) {}

    expect(fake.signInWithOtpCalls, 0);
    expect(fake.signUpCount, 1,
        reason: 'one registration attempt, one auth user, through the real '
            'factory');
  });

  test('one key survives the whole production journey', () async {
    final keys = <String>{};

    final flow = await beginViaProduction();
    await start(flow);
    keys.add(flow.clientUuid!);

    keys.add((await production().resume())!.clientUuid!); // reload
    await flow.submitCode('000000');
    keys.add(flow.clientUuid!);
    await flow.resendCode();
    keys.add((await production().resume())!.clientUuid!);
    await flow.submitCode('123456');
    keys.add(flow.clientUuid!);

    expect(keys, hasLength(1));
  });

  // ═══ THE SCREEN ACTUALLY USES THE PRODUCTION FACTORY ══════════════════════
  //
  // Everything above proves the factory is wired correctly. These prove the
  // SCREEN reaches for it — a WsRegisterScreen that quietly built its own deps,
  // or read a different store, would pass every other test in the repo.
  //
  // No deps are injected. `_deps = widget.deps ?? WsRegistrationDeps.production()`
  // therefore takes the production branch, and AuthService's two seams keep
  // `supabase` out of the picture.

  group('WsRegisterScreen with NO injected deps', () {
    testWidgets('resumes through the production factory', (tester) async {
      // An attempt already on disk, put there without touching the screen.
      final seeded = await beginViaProduction();
      await start(seeded);
      final key = seeded.clientUuid!;

      await tester.pumpWidget(const MaterialApp(home: WsRegisterScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Verify your phone'), findsOneWidget,
          reason: 'the screen rendered a RESUMED attempt, so it went through '
              'production().resume() → AuthService → the same store');
      expect(find.text('About you'), findsNothing);

      // And it did not mint a replacement on the way.
      expect((await production().resume())!.clientUuid, key);
    });

    testWidgets('shows the wizard when production() finds no attempt',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WsRegisterScreen()));
      await tester.pumpAndSettle();

      expect(find.text('About you'), findsOneWidget);
      expect(find.textContaining('cannot save your progress'), findsNothing,
          reason: 'the production store resolved fine; no degradation warning');
    });

    testWidgets('renders emailConfirmationPending from the production store',
        (tester) async {
      AuthService.authClientOverride = FakeAuthClient(sessionAfterSignUp: false);
      final seeded = await beginViaProduction();
      await start(seeded);

      await tester.pumpWidget(const MaterialApp(home: WsRegisterScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Confirm your email'), findsOneWidget);
      expect(find.textContaining('has NOT been created'), findsOneWidget);
    });
  });

  // ═══ THE WHOLE JOURNEY, THROUGH THE PRODUCTION FACTORY ════════════════════
  //
  //   submit → OTP sent → wrong code → resend → reload → verify → provision
  //          → response lost → reload → retry
  //
  // Every step that has ever produced a duplicate organization in this codebase
  // is in here, in order, and the assertion at the end is a Set of size one.
  // resume/begin go through WsRegistrationDeps.production() — the real factory,
  // not a copy of its wiring — so a mis-wired closure fails this test too.

  test('ONE uuid survives the entire journey, end to end', () async {
    final keys = <String>{};
    final keysSeenByRpc = <String>[];
    var organizationRows = 0;

    void note(WsRegistrationFlow f) => keys.add(f.clientUuid!);

    // 1. Submit the wizard.
    var flow = await beginViaProduction();
    await start(flow);
    note(flow);
    expect(flow.state, WsRegistrationState.phoneOtpSent,
        reason: 'a code was sent');

    // 2. A mistyped code.
    await flow.submitCode('000000');
    note(flow);
    expect(flow.state, WsRegistrationState.phoneOtpSent,
        reason: 'still waiting — a typo costs a retype, not the attempt');

    // 3. Ask for another.
    await flow.resendCode();
    note(flow);

    // 4. Browser reload. Everything in memory is gone.
    flow = (await production().resume())!;
    note(flow);
    expect(flow.isAwaitingCode, isTrue);

    // 5. The right code this time.
    await flow.submitCode('123456');
    note(flow);
    expect(flow.assurance, WsPhoneAssurance.otpProven);

    // 6. Provision — the RPC commits, then the connection drops.
    try {
      await flow.provisionOrganization((clientUuid) async {
        keysSeenByRpc.add(clientUuid);
        organizationRows++;
        throw Exception('connection dropped before the reply');
      });
    } catch (_) {}
    note(flow);

    // The attempt is still there, because the row may exist.
    expect(await production().resume(), isNotNull);

    // 7. Reload again and retry.
    flow = (await production().resume())!;
    note(flow);
    final organizationId = await flow.provisionOrganization((clientUuid) async {
      keysSeenByRpc.add(clientUuid);
      // Same key → migration 014 returns the row it already made.
      return 42;
    });

    // ── the invariants ──────────────────────────────────────────────────────
    expect(keys, hasLength(1),
        reason: 'ONE registration attempt = ONE clientuuid, across a wrong '
            'code, a resend, two reloads and a lost response');
    expect(keysSeenByRpc.toSet(), hasLength(1),
        reason: 'and the RPC saw that same key both times');
    expect(keysSeenByRpc.first, keys.single);
    expect(organizationRows, 1, reason: 'ONE organization row');
    expect(organizationId, 42);

    expect(fake.signUpCount, 1, reason: 'ONE auth user');
    expect(fake.signInWithOtpCalls, 0,
        reason: 'the call that would have created a second identity');

    expect(await production().resume(), isNull,
        reason: 'the successful retry cleared the attempt');
  });
}
