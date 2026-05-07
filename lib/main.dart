// =============================================================================
// lib/main.dart
// WaterFlow — Entry point, theme, routing
// =============================================================================

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/customer_portal_screen.dart';
import 'services/supabase_service.dart';
import 'services/auth_service.dart';
import 'theme/ws_theme.dart';
import 'models/ws_models.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://wbwsikbmnjmhqtlfocus.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Indid3Npa2JtbmptaHF0bGZvY3VzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQ1OTQ0ODUsImV4cCI6MjA4MDE3MDQ4NX0.4WdKl_kwRk0GYi7Y6aOKt1MwOSuhEsf7aJ9cH64XWYs',
  );

  runApp(const WaterFlowApp());
}

final supabase = Supabase.instance.client;

class WaterFlowApp extends StatelessWidget {
  const WaterFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WaterFlow',
      debugShowCheckedModeBanner: false,
      theme: WsTheme.light(),
      home: const WsAuthGate(),
    );
  }
}

// ─── Auth Gate ────────────────────────────────────────────────────────────────
// Decides which screen to show based on auth + role

class WsAuthGate extends StatelessWidget {
  const WsAuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = supabase.auth.currentSession;
        if (session == null) return const WsLoginScreen();

        return FutureBuilder<WsUserRole>(
          future: AuthService.resolveRole(session.user.id),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.data == WsUserRole.customer) {
              return const WsCustomerPortalScreen();
            }
            return const WsDashboardScreen();
          },
        );
      },
    );
  }
}