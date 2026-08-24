// =============================================================================
// test/auth_gate_test.dart
// The routing decision, executed rather than read.
//
// ─── WHY THIS FILE EXISTS ────────────────────────────────────────────────────
//
// WsAuthGate decides where every signed-in user lands, and until now the only
// widget test in the project asserted that the login screen renders two
// strings. Everything else about the gate was "correct by inspection".
//
// That is the exact state that hid three defects earlier in this project: the
// GPS provider that was never installed, the two provisioning gates that
// disagreed, and _provisionIfReady being unreachable from _restore. Each read
// fine.
//
// The REAL gate is pumped here — no parallel routing logic, no reimplementation
// of the decision. Only the three inputs are injected.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/main.dart';
import 'package:watersuppliersaas/models/ws_models.dart';
import 'package:watersuppliersaas/screens/customer_portal_screen.dart';
import 'package:watersuppliersaas/screens/dashboard_screen.dart';
import 'package:watersuppliersaas/screens/login_screen.dart';
import 'package:watersuppliersaas/screens/organization_selector_screen.dart';

void main() {
  WsOrganization org(int id, String name) => WsOrganization(
        orgId: id,
        authUserId: 'auth-1',
        orgName: name,
        ownerName: 'Essa',
        phone: '+923009876543',
        address: 'Karachi',
      );

  /// Builds the REAL gate with the three inputs supplied.
  Widget gate({
    String? uid,
    Future<WsOrganization?>? organization,
    WsUserRole role = WsUserRole.staff,
    Object? roleError,
    Object? orgError,
    List<String>? resolveCalls,
  }) =>
      MaterialApp(
        home: WsAuthGate(
          deps: WsAuthGateDeps(
            authChanges: const Stream.empty(),
            currentUserId: () => uid,
            currentOrganization: () =>
                orgError != null
                    ? Future.error(orgError)
                    : (organization ?? Future.value(null)),
            resolveRole: (u, orgId) async {
              resolveCalls?.add('$u/$orgId');
              if (roleError != null) throw roleError;
              return role;
            },
          ),
        ),
      );

  // ═══ THE SIX ROUTING DECISIONS ════════════════════════════════════════════

  testWidgets('1. no session → login', (tester) async {
    await tester.pumpWidget(gate(uid: null));
    await tester.pumpAndSettle();

    expect(find.byType(WsLoginScreen), findsOneWidget);
    expect(find.byType(WsDashboardScreen), findsNothing);
    expect(find.byType(WsOrganizationSelectorScreen), findsNothing);
  });

  testWidgets('2. session + no organization → selector', (tester) async {
    await tester.pumpWidget(
      gate(uid: 'user-1', organization: Future.value(null)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WsOrganizationSelectorScreen), findsOneWidget,
        reason: 'a completed Future<WsOrganization?> of null is the NORMAL '
            'state for someone who has just confirmed their email — it must '
            'not be mistaken for "still loading"');
    expect(find.byType(WsDashboardScreen), findsNothing);
  });

  testWidgets('3. session + organization + portal role → customer portal',
      (tester) async {
    await tester.pumpWidget(gate(
      uid: 'user-1',
      organization: Future.value(org(1, 'Kent Water')),
      role: WsUserRole.customer,
    ));
    await tester.pumpAndSettle();

    expect(find.byType(WsCustomerPortalScreen), findsOneWidget);
    expect(find.byType(WsDashboardScreen), findsNothing);
  });

  testWidgets('4. session + organization + staff role → dashboard',
      (tester) async {
    await tester.pumpWidget(gate(
      uid: 'user-1',
      organization: Future.value(org(1, 'Kent Water')),
      role: WsUserRole.staff,
    ));
    await tester.pumpAndSettle();

    expect(find.byType(WsDashboardScreen), findsOneWidget);
    expect(find.byType(WsCustomerPortalScreen), findsNothing);
  });

  testWidgets('4b. admin also reaches the dashboard, not the portal',
      (tester) async {
    await tester.pumpWidget(gate(
      uid: 'user-1',
      organization: Future.value(org(1, 'Kent Water')),
      role: WsUserRole.admin,
    ));
    await tester.pumpAndSettle();

    expect(find.byType(WsDashboardScreen), findsOneWidget,
        reason: 'only the portal role diverges; admin and staff share the '
            'dashboard and differ by permission codes');
  });

  testWidgets('5. the selected organization is the one whose role is resolved',
      (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(gate(
      uid: 'user-7',
      organization: Future.value(org(42, 'Second Depot')),
      resolveCalls: calls,
    ));
    await tester.pumpAndSettle();

    expect(calls, ['user-7/42'],
        reason: 'resolving against the wrong organization would grant one '
            "org's permissions inside another");
    expect(find.byType(WsDashboardScreen), findsOneWidget);
  });

  testWidgets('6. several organizations → selector, never an arbitrary pick',
      (tester) async {
    // WsTenantService returns null when the choice is ambiguous. The gate must
    // treat that as "ask", not as "none" and not as "take the first".
    await tester.pumpWidget(
      gate(uid: 'user-1', organization: Future.value(null)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WsOrganizationSelectorScreen), findsOneWidget);
    expect(find.byType(WsDashboardScreen), findsNothing,
        reason: 'silently choosing one of several organizations would show a '
            "different business's data without saying so");
  });

  // ═══ THE STATES THAT MUST NOT REACH THE DASHBOARD ═════════════════════════

  group('registration states cannot enter the authenticated area', () {
    // emailConfirmationPending and sessionMissing share one property that
    // matters here: NO SESSION. The state machine's own tests prove they
    // produce no session; this proves what the gate does when it sees that.

    testWidgets('emailConfirmationPending (no session) → login, not /home',
        (tester) async {
      await tester.pumpWidget(gate(uid: null));
      await tester.pumpAndSettle();

      expect(find.byType(WsLoginScreen), findsOneWidget);
      expect(find.byType(WsDashboardScreen), findsNothing);
      expect(find.byType(WsOrganizationSelectorScreen), findsNothing,
          reason: 'no session means no authenticated screen at all');
    });

    testWidgets('sessionMissing (session expired) → login, not /home',
        (tester) async {
      await tester.pumpWidget(gate(uid: null));
      await tester.pumpAndSettle();

      expect(find.byType(WsLoginScreen), findsOneWidget);
      expect(find.byType(WsDashboardScreen), findsNothing);
    });

    testWidgets('successful provisioning DOES reach an authenticated screen',
        (tester) async {
      // The control. After provisionForRegistration the user has a session and
      // an organization, so /home must resolve to the dashboard.
      await tester.pumpWidget(gate(
        uid: 'user-1',
        organization: Future.value(org(1, 'Kent Water')),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(WsDashboardScreen), findsOneWidget);
    });
  });

  // ═══ FAILURES ARE NOT SILENT HANGS ════════════════════════════════════════

  group('a failure shows a way out, not a spinner', () {
    testWidgets('an organization load error offers Sign out', (tester) async {
      await tester.pumpWidget(
        gate(uid: 'user-1', orgError: Exception('network')),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not load your organization'),
          findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Sign out'), findsOneWidget,
          reason: 'a broken account must never be a dead end');
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a role/permission error offers Sign out', (tester) async {
      await tester.pumpWidget(gate(
        uid: 'user-1',
        organization: Future.value(org(1, 'Kent Water')),
        roleError: Exception('permission load failed'),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not determine your access level'),
          findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Sign out'), findsOneWidget);
      expect(find.byType(WsDashboardScreen), findsNothing,
          reason: 'failing to load permissions must not fall through to a '
              'dashboard that then renders with none');
    });

    testWidgets('a pending organization future shows the spinner, not login',
        (tester) async {
      // Deliberately never completes.
      await tester.pumpWidget(gate(
        uid: 'user-1',
        organization: Completer<WsOrganization?>().future,
      ));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(WsLoginScreen), findsNothing,
          reason: 'still loading is not the same as signed out');
    });
  });

  // ═══ /home IS THE GATE, NOT A SCREEN ══════════════════════════════════════

  testWidgets('/home resolves to the gate itself', (tester) async {
    await tester.pumpWidget(MaterialApp(
      routes: {'/home': (_) => const WsAuthGate()},
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => Navigator.of(context).pushNamed('/home'),
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    // No client in a test binding, so the production factory yields no uid and
    // the gate routes to login. The POINT is that /home built a WsAuthGate and
    // made a decision, rather than being a landing screen of its own.
    expect(find.byType(WsAuthGate), findsOneWidget);
    expect(find.byType(WsLoginScreen), findsOneWidget);
  });
}
