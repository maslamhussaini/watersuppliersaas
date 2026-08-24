// =============================================================================
// lib/main.dart
// WaterFlow — Entry point, theme, routing
// =============================================================================

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/splash_screen.dart';
import 'services/ws_startup.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/customer_portal_screen.dart';
import 'screens/organization_selector_screen.dart';
import 'services/auth_service.dart';
import 'services/tenant_service.dart';
import 'theme/ws_theme.dart';
import 'models/ws_models.dart';

// ─── Startup ──────────────────────────────────────────────────────────────────
//
// Supabase is connected by default. Credentials are read from the .env file in
// the project root by lib/supabase_config.dart; --dart-define still overrides
// them for CI and staging.
//
// THERE IS NO DEMO FALLBACK ANY MORE.
// Falling back to an in-memory store when config was missing produced the worst
// possible failure: the app started, looked completely normal, accepted a login
// and showed nothing — indistinguishable from a real account with no data. A
// misconfiguration should stop you at the door and say what to fix, not
// impersonate a working app.

import 'supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Reads .env. Never throws — a missing file becomes a setup screen that names
  // the file, rather than a stack trace on a white screen.
  await WsConfig.load();

  if (!WsConfig.isConfigured) {
    runApp(
      _SetupRequiredApp(
        problem: 'Supabase is not configured.',
        fix: WsConfig.diagnosis,
      ),
    );
    return;
  }

  if (WsConfig.looksLikeServiceRoleKey) {
    // Refusing to start is the correct response. A service_role key bypasses
    // row level security entirely, so a build carrying one exposes every
    // tenant's data to anyone who opens the app.
    runApp(
      const _SetupRequiredApp(
        problem: 'That looks like a service_role key.',
        fix:
            'Never ship the service_role key in a client — it bypasses row '
            'level security and would expose every tenant.\n\n'
            'Use the anon / public key from Project Settings → API.',
      ),
    );
    return;
  }

  try {
    // `anonKey`, not `publishableKey`: the newer name does not exist on earlier
    // supabase_flutter 2.x releases, and this spelling compiles on all of them.
    // ignore: deprecated_member_use
    await Supabase.initialize(url: WsConfig.url, anonKey: WsConfig.anonKey);
    debugPrint('Supabase connected: ${WsConfig.url}');

    // The optional subsystems: the offline queue, release notes, and the GPS
    // provider. AFTER Supabase.initialize, because the first outbox drain posts
    // immediately.
    //
    // Each starts INDEPENDENTLY — see ws_startup.dart. They used to share one
    // try/catch, so the outbox failing on web (path_provider has no web
    // implementation) silently skipped the other two, and the GPS provider was
    // never installed on the only platform this project ships to.
    debugPrint('${await wsStartSubsystems()}');
  } catch (e) {
    runApp(
      _SetupRequiredApp(
        problem: 'Could not connect to Supabase.',
        fix: 'Check the URL and key in lib/supabase_config.dart, and your '
            'internet connection.\n\n$e',
      ),
    );
    return;
  }

  runApp(const WaterFlowApp());
}

/// Shown instead of the app when configuration is wrong. Deliberately plain and
/// specific: it names the file to edit.
class _SetupRequiredApp extends StatelessWidget {
  final String problem;
  final String fix;
  const _SetupRequiredApp({required this.problem, required this.fix});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF007ECC),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.settings_suggest_outlined,
                    size: 48,
                    color: Color(0xFF007ECC),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    problem,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    fix,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

SupabaseClient? get supabaseClient {
  try {
    return Supabase.instance.client;
  } catch (_) {
    return null;
  }
}

bool get supabaseClientInitialized {
  try {
    Supabase.instance.client;
    return true;
  } catch (_) {
    return false;
  }
}

SupabaseClient get supabase {
  final client = supabaseClient;
  if (client == null) {
    throw StateError('Supabase is not initialized');
  }
  return client;
}

class WaterFlowApp extends StatelessWidget {
  const WaterFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WaterFlow',
      debugShowCheckedModeBanner: false,
      theme: WsTheme.light(),
      // '/home' stays the auth gate: everything that navigates there wants
      // the gate's decision, not the splash again.
      routes: {'/home': (_) => const WsAuthGate()},
      // The splash covers the first frame only, then hands over to the gate.
      home: WsSplashScreen(next: (_) => const WsAuthGate()),
      // The corner DEMO banner is gone. Demo state is announced on the login
      // screen instead — same warning, at the moment it matters, without
      // defacing every screen.
      //
      // textScaler is clamped so a phone set to 200% system font does not
      // shatter the tables and cards. Users can still enlarge text, just not
      // past the point where the layout stops working.
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.8,
        maxScaleFactor: 1.4,
        child: child ?? const SizedBox(),
      ),
    );
  }
}

// ─── Auth Gate ────────────────────────────────────────────────────────────────
// Decides which screen to show based on auth + role

/// The three facts the gate needs, and nothing else.
///
/// SAME SHAPE AS WsRegistrationDeps, for the same reason: the gate reaches
/// Supabase.instance for a client, a session and an organization, so it could
/// not be pumped in a test at all — its routing was correct by inspection only,
/// which is the state that hid three defects earlier in this project.
///
/// The DECISIONS are unchanged and still live in build(). This only says where
/// the inputs come from. Production passes nothing.
class WsAuthGateDeps {
  /// Rebuild trigger. The gate re-reads [currentUserId] on each event.
  final Stream<Object?> authChanges;

  /// Null when there is no session. Collapses the old two-step check —
  /// "no client" and "no session" both meant the login screen.
  final String? Function() currentUserId;

  final Future<WsOrganization?> Function() currentOrganization;

  final Future<WsUserRole> Function(String uid, int orgId) resolveRole;

  const WsAuthGateDeps({
    required this.authChanges,
    required this.currentUserId,
    required this.currentOrganization,
    required this.resolveRole,
  });

  factory WsAuthGateDeps.production() => WsAuthGateDeps(
        authChanges:
            supabaseClient?.auth.onAuthStateChange ?? const Stream.empty(),
        currentUserId: () => supabaseClient?.auth.currentSession?.user.id,
        currentOrganization: () => WsTenantService.currentOrganization,
        resolveRole: WsAuthGate._resolveAndLoad,
      );
}

class WsAuthGate extends StatelessWidget {
  /// Null in production. Injected by test/auth_gate_test.dart.
  final WsAuthGateDeps? deps;

  const WsAuthGate({super.key, this.deps});

  /// Shown instead of an endless spinner when the gate cannot proceed.
  /// It always offers Sign out, so a broken account is never a dead end.
  static Widget _errorScreen(String title, String detail) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 44, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: AuthService.signOut,
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    ),
  );

  /// Resolves the coarse role and warms the permission cache in one step.
  static Future<WsUserRole> _resolveAndLoad(String uid, int orgId) async {
    final role = await AuthService.resolveRole(uid, orgId: orgId);
    await AuthService.loadPermissions(orgId);
    return role;
  }

  @override
  Widget build(BuildContext context) {
    final d = deps ?? WsAuthGateDeps.production();

    return StreamBuilder<Object?>(
      stream: d.authChanges,
      builder: (context, snapshot) {
        // No client and no session both land here, exactly as before.
        final uid = d.currentUserId();
        if (uid == null) {
          return const WsLoginScreen();
        }

        return FutureBuilder<WsOrganization?>(
          future: d.currentOrganization(),
          builder: (context, orgSnap) {
            // connectionState, NOT hasData.
            //
            // This is a Future<WsOrganization?>. When it completes with null —
            // which is exactly what happens for a user who has no organization
            // yet — `hasData` stays FALSE, because AsyncSnapshot treats a null
            // value as "no data". The old `if (!orgSnap.hasData)` therefore
            // showed the spinner forever and the app hung on a blank screen
            // with a loading indicator. Nothing was retrying and nothing had
            // failed; the future had already completed successfully with null.
            if (orgSnap.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            if (orgSnap.hasError) {
              return _errorScreen(
                'Could not load your organization',
                orgSnap.error.toString(),
              );
            }

            final org = orgSnap.data;
            if (org == null) {
              // No organization, or several — let the user pick or create one.
              return const WsOrganizationSelectorScreen();
            }

            // Resolve the role AND load permission codes before routing, so
            // the first frame of the dashboard already knows what to show.
            return FutureBuilder<WsUserRole>(
              future: d.resolveRole(uid, org.orgId),
              builder: (context, roleSnap) {
                if (roleSnap.connectionState != ConnectionState.done) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }

                // A thrown future also leaves hasData false, so the old check
                // turned any permission-load failure into the same silent hang.
                if (roleSnap.hasError) {
                  return _errorScreen(
                    'Could not determine your access level',
                    roleSnap.error.toString(),
                  );
                }

                if (roleSnap.data == WsUserRole.customer) {
                  return const WsCustomerPortalScreen();
                }

                return const WsDashboardScreen();
              },
            );
          },
        );
      },
    );
  }

}
