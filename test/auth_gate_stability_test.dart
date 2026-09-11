// =============================================================================
// test/auth_gate_stability_test.dart
//
// Phase 1 — the gate must not restart its work on every rebuild.
//
// ─── THE INSTABILITY ─────────────────────────────────────────────────────────
//
// WsAuthGate.build used to construct everything inline:
//
//     final d = deps ?? WsAuthGateDeps.production();     // new deps per build
//     FutureBuilder(future: d.currentOrganization(), …)  // NEW future per build
//     FutureBuilder(future: d.resolveRole(uid, orgId), …)// NEW future per build
//
// A FutureBuilder handed a brand-new future reports ConnectionState.waiting
// again, and both builders show a CircularProgressIndicator while waiting — so
// EVERY REBUILD REPLACED THE DASHBOARD WITH A SPINNER and then put it back.
//
// The rebuilds come from the auth stream: offline, token refresh fails and
// retries, emitting repeated events. Each one restarted both futures, and
// resolveRole then waited the full 8-second window before its snapshot
// fallback. That is the dashboard "refreshing repeatedly and never settling".
//
// ─── WHAT THESE TESTS PIN ────────────────────────────────────────────────────
//
// Reuse is only safe if it can never serve one identity's answer to another.
// So alongside "does not re-resolve" there are tests for every case where it
// MUST re-resolve: another user, another organization, and sign-out followed by
// signing back in as the same user.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/main.dart';
import 'package:watersuppliersaas/models/ws_models.dart';
import 'package:watersuppliersaas/screens/dashboard_screen.dart';
import 'package:watersuppliersaas/screens/login_screen.dart';
import 'package:watersuppliersaas/services/tenant_service.dart';

WsOrganization org(int id) => WsOrganization(
      orgId: id,
      authUserId: 'auth-1',
      orgName: 'Org $id',
      ownerName: 'Essa',
      phone: '+923009876543',
      address: 'Karachi',
    );

void main() {
  late StreamController<Object?> auth;
  late List<String> orgCalls;
  late List<String> roleCalls;
  String? uid;
  int orgId = 1;

  setUp(() {
    auth = StreamController<Object?>.broadcast();
    orgCalls = [];
    roleCalls = [];
    uid = 'user-a';
    orgId = 1;
  });

  tearDown(() => auth.close());

  Widget gate() => MaterialApp(
        home: WsAuthGate(
          deps: WsAuthGateDeps(
            authChanges: auth.stream,
            currentUserId: () => uid,
            currentOrganization: () async {
              orgCalls.add('$uid');
              return org(orgId);
            },
            resolveRole: (u, o) async {
              roleCalls.add('$u/$o');
              return WsUserRole.staff;
            },
          ),
        ),
      );

  /// One auth event, of the kind an offline token-refresh retry emits.
  Future<void> authEvent(WidgetTester t) async {
    auth.add('tokenRefreshed');
    await t.pumpAndSettle();
  }

  // ═══ THE FIX ══════════════════════════════════════════════════════════════

  testWidgets('repeated auth events do NOT re-resolve', (t) async {
    await t.pumpWidget(gate());
    await t.pumpAndSettle();

    expect(find.byType(WsDashboardScreen), findsOneWidget);
    expect(orgCalls, hasLength(1));
    expect(roleCalls, hasLength(1));

    for (var i = 0; i < 5; i++) {
      await authEvent(t);
    }

    expect(orgCalls, hasLength(1),
        reason: 'THE DEFECT: a new future per build restarted this every time');
    expect(roleCalls, hasLength(1),
        reason: 'and this one waited 8 seconds offline before falling back');
  });

  testWidgets('the dashboard never flashes back to a spinner', (t) async {
    await t.pumpWidget(gate());
    await t.pumpAndSettle();
    expect(find.byType(WsDashboardScreen), findsOneWidget);

    // pump(), not pumpAndSettle(): settle would hide a spinner that appeared
    // and resolved between frames — which is exactly the flicker being fixed.
    auth.add('tokenRefreshed');
    await t.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the dashboard must survive the rebuild, not be replaced');
    expect(find.byType(WsDashboardScreen), findsOneWidget);
  });

  // ═══ IT MUST STILL RE-RESOLVE WHEN IDENTITY CHANGES ═══════════════════════

  testWidgets('a different user re-resolves both', (t) async {
    await t.pumpWidget(gate());
    await t.pumpAndSettle();
    expect(roleCalls, ['user-a/1']);

    uid = 'user-b';
    await authEvent(t);

    expect(orgCalls, hasLength(2));
    expect(roleCalls, ['user-a/1', 'user-b/1'],
        reason: "one driver's role must never be served to another");
  });

  testWidgets('an organization switch re-resolves both', (t) async {
    // Driven through the REAL mechanism. Writing this test by only changing the
    // fake's orgId failed, and rightly so: the organization future is keyed on
    // WsTenantService.selectedOrgId, which is what an actual switch changes.
    // A test that moved a variable the key does not read proved nothing.
    WsTenantService.clearSelection();
    await t.pumpWidget(gate());
    await t.pumpAndSettle();
    expect(roleCalls, ['user-a/1']);

    orgId = 2;
    WsTenantService.selectOrganization(2);
    await authEvent(t);

    expect(orgCalls, hasLength(2),
        reason: 'the previous organization must not survive a switch');
    expect(roleCalls, ['user-a/1', 'user-a/2'],
        reason: 'a role held in one organization says nothing about another');

    WsTenantService.clearSelection(); // leave no static state behind
  });

  testWidgets('sign-out then back in as the SAME user re-resolves', (t) async {
    await t.pumpWidget(gate());
    await t.pumpAndSettle();
    expect(roleCalls, hasLength(1));

    uid = null; // sign out
    await authEvent(t);
    expect(find.byType(WsLoginScreen), findsOneWidget);

    uid = 'user-a'; // same user signs back in
    await authEvent(t);

    expect(roleCalls, hasLength(2),
        reason: 'sign-out clears the organization selection, so the previous '
            'answer is stale even for the same uid');
    expect(orgCalls, hasLength(2));
  });

  testWidgets('signing out drops the resolved state immediately', (t) async {
    await t.pumpWidget(gate());
    await t.pumpAndSettle();

    uid = null;
    await authEvent(t);

    expect(find.byType(WsDashboardScreen), findsNothing);
    expect(find.byType(WsLoginScreen), findsOneWidget);
  });

  // ═══ THE FIRST RESOLVE IS UNCHANGED ═══════════════════════════════════════

  testWidgets('a cold start still resolves exactly once', (t) async {
    await t.pumpWidget(gate());
    await t.pumpAndSettle();

    expect(orgCalls, hasLength(1));
    expect(roleCalls, hasLength(1));
    expect(find.byType(WsDashboardScreen), findsOneWidget);
  });

  testWidgets('a pending resolve still shows the spinner, not the dashboard',
      (t) async {
    final held = Completer<WsOrganization?>();
    await t.pumpWidget(MaterialApp(
      home: WsAuthGate(
        deps: WsAuthGateDeps(
          authChanges: auth.stream,
          currentUserId: () => 'user-a',
          currentOrganization: () => held.future,
          resolveRole: (u, o) async => WsUserRole.staff,
        ),
      ),
    ));
    await t.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: 'reuse must not skip the loading state on a genuine first load');

    held.complete(org(1));
    await t.pumpAndSettle();
    expect(find.byType(WsDashboardScreen), findsOneWidget);
  });
}
