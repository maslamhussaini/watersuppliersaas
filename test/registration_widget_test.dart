// =============================================================================
// test/registration_widget_test.dart
// The screen itself, pumped.
//
// registration_screen_test.dart asserts the CONTRACT the screen consumes. This
// asserts that the screen actually renders it — the gap between those two is
// exactly where a wiring mistake inside build() would hide.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/screens/register_screen.dart';
import 'package:watersuppliersaas/services/auth/ws_auth_client.dart';
import 'package:watersuppliersaas/services/auth/ws_phone_verification.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_attempt_store.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_flow.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';

import 'support/fake_auth_client.dart';

void main() {
  late WsMemoryKeyValueStore kv;
  late List<String> provisionedWith;

  setUp(() {
    kv = WsMemoryKeyValueStore();
    provisionedWith = [];
  });

  WsRegistrationFlow build(FakeAuthClient fake) => WsRegistrationFlow(
        WsPhoneVerification(fake),
        store: WsRegistrationAttemptStore(kv),
        email: 'owner@example.com',
        orgName: 'Kent Water',
        ownerName: 'Essa',
        orgPhone: '+923009999999',
        address: 'Karachi',
      );

  WsRegistrationDeps deps(
    FakeAuthClient fake, {
    WsRegistrationFlow? existing,
    bool resumeThrows = false,
  }) =>
      WsRegistrationDeps(
        resume: () async {
          if (resumeThrows) throw StateError('storage unavailable');
          return existing;
        },
        begin: ({
          required String email,
          required String orgName,
          required String ownerName,
          required String orgPhone,
          required String address,
        }) async =>
            build(fake),
        provision: (flow) async {
          provisionedWith.add(flow.clientUuid!);
          return 42;
        },
      );

  Future<void> pump(WidgetTester tester, WsRegistrationDeps d) async {
    await tester.pumpWidget(MaterialApp(home: WsRegisterScreen(deps: d)));
    await tester.pumpAndSettle();
  }

  /// A flow already sitting in [state], as a reload would find it.
  Future<WsRegistrationFlow> flowIn(
    FakeAuthClient fake, {
    bool verify = false,
  }) async {
    final f = build(fake);
    await f.start(
      email: 'owner@example.com',
      password: 'sup3rsecret',
      phone: '+923009876543',
    );
    if (verify) await f.submitCode('123456');
    return f;
  }

  // ═══ EVERY STATE RENDERS ══════════════════════════════════════════════════

  testWidgets('emailConfirmationPending explains the email, not "created"',
      (tester) async {
    final fake = FakeAuthClient(sessionAfterSignUp: false);
    final flow = await flowIn(fake);

    await pump(tester, deps(fake, existing: flow));

    expect(find.text('Confirm your email'), findsOneWidget);
    expect(find.textContaining('has NOT been created'), findsOneWidget,
        reason: 'the old screen said "Account created." and pushed /home, '
            'where the gate bounced the user back to login');
    expect(find.textContaining('Verification code'), findsNothing);
  });

  testWidgets('sessionMissing offers a sign-in and no OTP field',
      (tester) async {
    final fake = FakeAuthClient(
      verifyError: const WsAuthException('gone',
          code: 'session_not_found', statusCode: 401),
    );
    final flow = await flowIn(fake);
    await flow.submitCode('123456');
    expect(flow.state, WsRegistrationState.sessionMissing);

    await pump(tester, deps(fake, existing: flow));

    expect(find.text('Your session expired'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.textContaining('Verification code'), findsNothing);
  });

  testWidgets('phoneOtpSent shows the code field, Verify and Resend',
      (tester) async {
    final fake = FakeAuthClient();
    final flow = await flowIn(fake);

    await pump(tester, deps(fake, existing: flow));

    expect(find.text('Verify your phone'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Verification code *'),
        findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Verify'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Send a new code'), findsOneWidget);
    expect(find.textContaining('+923009876543'), findsOneWidget);
  });

  testWidgets('NO CHANNEL SELECTOR is offered', (tester) async {
    final fake = FakeAuthClient();
    await pump(tester, deps(fake, existing: await flowIn(fake)));

    // The channel is server-controlled; a toggle would not change delivery.
    expect(find.textContaining('WhatsApp'), findsNothing);
    expect(find.textContaining('SMS'), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('phoneAlreadyConfirmed shows progress, never an OTP field',
      (tester) async {
    final fake = FakeAuthClient(autoconfirmPhone: true);
    final flow = await flowIn(fake);
    expect(flow.state, WsRegistrationState.phoneAlreadyConfirmed);

    await tester.pumpWidget(
        MaterialApp(home: WsRegisterScreen(deps: deps(fake, existing: flow))));
    await tester.pump();

    expect(find.textContaining('Verification code'), findsNothing,
        reason: 'no code was delivered, so asking for one would be a lie');
  });

  testWidgets('phoneOtpVerified provisions with the ORIGINAL key',
      (tester) async {
    final fake = FakeAuthClient();
    final flow = await flowIn(fake, verify: true);
    final key = flow.clientUuid!;

    await tester.pumpWidget(
        MaterialApp(home: WsRegisterScreen(deps: deps(fake, existing: flow))));
    await tester.pump();
    await tester.pump();

    expect(provisionedWith, [key]);
  });

  // ═══ NO SECOND KEY FROM THE WIDGET LAYER ══════════════════════════════════

  testWidgets('a rebuild does not mint a second clientuuid', (tester) async {
    final fake = FakeAuthClient();
    final flow = await flowIn(fake);
    final key = flow.clientUuid!;
    final d = deps(fake, existing: flow);

    await pump(tester, d);
    // Rebuild the same State repeatedly — setState, MediaQuery change, etc.
    await tester.pump();
    await tester.pump();
    await pump(tester, d); // and a full re-open

    expect(flow.clientUuid, key);
    expect(fake.signUpCount, 1,
        reason: 'rebuilding a widget must never re-register anybody');
    expect(fake.signInWithOtpCalls, 0);
  });

  testWidgets('resuming renders the OTP step rather than the wizard',
      (tester) async {
    final fake = FakeAuthClient();
    await pump(tester, deps(fake, existing: await flowIn(fake)));

    expect(find.text('Verify your phone'), findsOneWidget);
    expect(find.text('About you'), findsNothing,
        reason: 'a resumed attempt must not restart at step 1');
  });

  // ═══ STORAGE FAILURE IS VISIBLE ═══════════════════════════════════════════

  testWidgets('a storage failure keeps the form usable but SAYS SO',
      (tester) async {
    final fake = FakeAuthClient();

    await pump(tester, deps(fake, resumeThrows: true));

    // Usable.
    expect(find.text('About you'), findsOneWidget);
    // And honest about what was lost.
    expect(find.textContaining('cannot save your progress'), findsOneWidget,
        reason: 'silently pretending the attempt is being saved sends the user '
            'off to wait for an SMS they cannot come back from');
  });

  testWidgets('a healthy store shows no warning', (tester) async {
    final fake = FakeAuthClient();
    await pump(tester, deps(fake));

    expect(find.textContaining('cannot save your progress'), findsNothing);
    expect(find.text('About you'), findsOneWidget);
  });

  // ═══ THE PHONE IS AN IDENTITY FIELD ═══════════════════════════════════════

  testWidgets('the phone field is required and wants a country code',
      (tester) async {
    final fake = FakeAuthClient();
    await pump(tester, deps(fake));

    expect(find.text('Your phone *'), findsOneWidget);
    expect(find.textContaining('+923001234567'), findsOneWidget,
        reason: 'the format has to be shown, not guessed at');
  });
}
