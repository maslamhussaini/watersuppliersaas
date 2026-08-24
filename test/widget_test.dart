// =============================================================================
// test/widget_test.dart
//
// WHY THIS PUMPS WsLoginScreen RATHER THAN WaterFlowApp
//
// It used to pump the whole app and assert on the first frame. That worked
// only while the first frame WAS the login screen. Once a splash screen was
// added ahead of the auth gate, frame one became the splash — which also
// renders "WaterFlow", so the first assertion kept passing and quietly hid the
// fact that the login screen was never being built at all.
//
// Pumping WsLoginScreen directly tests what the name promises and removes four
// dependencies this test never wanted: splash timing, WsAuthGate, Supabase
// initialisation, and startup routing. None of those are the login experience.
//
// Nothing in lib/ was changed to make this pass. The screen still renders both
// strings; the old test simply stopped reaching it.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watersuppliersaas/screens/login_screen.dart';
import 'package:watersuppliersaas/theme/ws_theme.dart';

void main() {
  testWidgets('renders the login experience', (WidgetTester tester) async {
    // MaterialApp supplies the Directionality, Theme and Navigator that any
    // Scaffold needs. WsLoginScreen makes no service calls while building, so
    // no Supabase client is required.
    await tester.pumpWidget(
      MaterialApp(
        theme: WsTheme.light(),
        home: const WsLoginScreen(),
      ),
    );

    expect(find.text('WaterFlow'), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
  });
}
