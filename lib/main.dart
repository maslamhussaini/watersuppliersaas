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
import 'services/auth/ws_session_snapshot.dart';
import 'services/cache/ws_customer_cache.dart';
import 'services/storage/ws_kv_default.dart';
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
        currentOrganization: WsAuthGate._organizationOrSnapshot,
        resolveRole: WsAuthGate._resolveAndLoad,
      );
}

/// Says out loud that the account details on screen came from this device, not
/// from the server.
///
/// Without it, "we could not reach the server" and "your account is fine" look
/// identical — and a driver who does not know they are offline has no reason to
/// wonder why a customer they added on another device is missing.
///
/// Renders nothing at all when online, so it costs nothing in the normal case.
/// Public only so a widget test can mount it directly. Nothing else constructs
/// it — WsAuthGate wraps the dashboard with it and that is the sole use.
class WsOfflineSessionBanner extends StatelessWidget {
  final Widget child;

  const WsOfflineSessionBanner({super.key, required this.child});

  static const offlineSessionMessage =
      'Offline — using account details saved on this device. Some data may be '
      'out of date.';

  Widget _strip(String message) => Material(
        color: WsColors.amber,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.cloud_off, size: 16, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  /// ─── TWO INDEPENDENT CONDITIONS ──────────────────────────────────────────
  ///
  /// They are not the same thing and one does not imply the other:
  ///
  ///   · running on the saved session snapshot means the server is unreachable;
  ///   · customer search being online-only can happen while perfectly ONLINE,
  ///     because an organization over the 25,000 ceiling is refused a cache
  ///     during an ordinary refresh.
  ///
  /// So both are listened to, and each contributes its own strip. Collapsing
  /// them into one message would state something false in whichever case is
  /// not currently true.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge(
            [wsUsingOfflineSession, wsOfflineCustomerSearchUnavailable]),
        builder: (context, _) {
          final messages = <String>[
            if (wsUsingOfflineSession.value) offlineSessionMessage,
            if (wsOfflineCustomerSearchUnavailable.value != null)
              wsOfflineCustomerSearchUnavailable.value!,
          ];

          // Nothing to say costs nothing: the child is returned untouched, so
          // the ordinary online case gains no wrapper.
          if (messages.isEmpty) return child;

          return Column(
            children: [
              for (final m in messages) _strip(m),
              Expanded(child: child),
            ],
          );
        },
      );
}

/// True while the app is running on the saved snapshot instead of live data.
///
/// Exists so "we cannot reach the server" is visibly different from "your
/// account is broken" — the two produced the same screen before, and only one
/// of them is the user's problem.
final ValueNotifier<bool> wsUsingOfflineSession = ValueNotifier(false);

/// How long startup waits for the server before falling back.
///
/// The complaint was an app that appeared to hang. Offline, a PostgREST call
/// does not fail promptly — it waits on TCP — so without a bound the spinner is
/// the whole experience. Long enough for a slow-but-working connection, short
/// enough that a driver does not think the app is broken.
const wsStartupResolveWindow = Duration(seconds: 8);

class WsAuthGate extends StatefulWidget {
  /// Null in production. Injected by test/auth_gate_test.dart.
  final WsAuthGateDeps? deps;

  const WsAuthGate({super.key, this.deps});

  @override
  State<WsAuthGate> createState() => _WsAuthGateState();

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
  static Future<WsSessionSnapshotStore> _snapshots() async =>
      WsSessionSnapshotStore(await wsOpenDefaultKeyValueStore());

  /// Which organization, asking the server first and the snapshot only if the
  /// server cannot be reached.
  ///
  /// A NULL ANSWER IS NOT A FAILURE. Zero organizations, or several, is a real
  /// result meaning "show the selector", and it must not be overridden by a
  /// snapshot — otherwise a user who left an organization would be silently
  /// put back into it. Only a throw or a timeout falls back.
  static Future<WsOrganization?> _organizationOrSnapshot() async {
    final uid = supabaseClient?.auth.currentSession?.user.id;
    try {
      final org = await WsTenantService.currentOrganization
          .timeout(wsStartupResolveWindow);
      wsUsingOfflineSession.value = false;
      return org;
    } catch (e) {
      // NO SESSION, NO FALLBACK. The snapshot cannot create or extend one, and
      // without a uid there is nothing to match it against.
      if (uid == null) rethrow;

      final snap = await (await _snapshots()).readFor(uid);
      if (snap == null) {
        // Nothing saved for THIS user. Fall through to the existing error
        // screen rather than inventing an organization.
        rethrow;
      }

      debugPrint('startup: server unreachable, using saved organization — $e');
      wsUsingOfflineSession.value = true;
      return snap.organizationOrNull;
    }
  }

  /// Role and permissions, with the same rule, and the snapshot written on the
  /// way through whenever the server answered.
  static Future<WsUserRole> _resolveAndLoad(String uid, int orgId) async {
    try {
      final role =
          await AuthService.resolveRole(uid, orgId: orgId)
              .timeout(wsStartupResolveWindow);
      await AuthService.loadPermissions(orgId).timeout(wsStartupResolveWindow);

      // THE SERVER ANSWERED, SO THE SERVER WINS. Overwrite whatever was saved.
      // Failing to save must never fail a sign-in that otherwise worked.
      try {
        final org = await WsTenantService.currentOrganization; // cached by now
        if (org != null) {
          await (await _snapshots()).write(WsSessionSnapshot.of(
            authUserId: uid,
            org: org,
            role: role,
            permissions: AuthService.permissions,
          ));
        }
      } catch (e) {
        debugPrint('startup: could not save the session snapshot — $e');
      }

      wsUsingOfflineSession.value = false;
      return role;
    } catch (e) {
      final snap = await (await _snapshots()).readFor(uid);
      // Must belong to this user AND this organization. A snapshot for a
      // different org says nothing about the role held in this one.
      if (snap == null || snap.orgId != orgId) rethrow;

      // Without this the user would arrive with a role but no permissions, so
      // every control would be disabled — which reads as a broken account
      // rather than a missing network.
      AuthService.applySnapshotPermissions(orgId, snap.permissions);

      debugPrint('startup: server unreachable, using saved role — $e');
      wsUsingOfflineSession.value = true;
      return snap.role;
    }
  }

}

/// Holds the gate's futures so a rebuild REUSES them instead of restarting.
///
/// ─── THE INSTABILITY THIS FIXES ──────────────────────────────────────────────
///
/// build() used to construct everything inline:
///
///     final d = deps ?? WsAuthGateDeps.production();     // new deps per build
///     FutureBuilder(future: d.currentOrganization(), …)  // NEW future per build
///     FutureBuilder(future: d.resolveRole(uid, orgId), …)// NEW future per build
///
/// A FutureBuilder handed a brand-new future reports ConnectionState.waiting
/// again, and both builders return a CircularProgressIndicator while waiting —
/// so every rebuild REPLACED THE WHOLE DASHBOARD WITH A SPINNER and then put it
/// back.
///
/// The rebuilds come from the auth stream. Offline, token refresh fails and
/// retries, emitting repeated auth events. Each one restarted both futures, and
/// resolveRole then waited the full wsStartupResolveWindow (8s) before falling
/// back to the snapshot. That is the dashboard "refreshing repeatedly and never
/// settling".
///
/// ─── KEYED, NOT JUST CACHED ──────────────────────────────────────────────────
///
/// A memo here is only safe if it can never hand one identity's answer to
/// another. Both futures are therefore keyed:
///
///   organization → uid + the currently selected organization id
///   role         → uid + the resolved orgId
///
/// so signing in as someone else, switching organization, or signing out and
/// back in all produce a different key and a fresh resolve. Sign-out clears
/// both outright rather than relying on the key alone.
class _WsAuthGateState extends State<WsAuthGate> {
  /// Built ONCE. A new deps object per build would also mean a new
  /// authChanges stream reference each time, which is the other half of the
  /// churn.
  late final WsAuthGateDeps _deps = widget.deps ?? WsAuthGateDeps.production();

  String? _orgKey;
  Future<WsOrganization?>? _orgFuture;

  String? _roleKey;
  Future<WsUserRole>? _roleFuture;

  /// Includes the selected organization id: WsTenantService.selectOrganization
  /// clears its own cache, and without this the gate would keep serving the
  /// organization the user just switched away from.
  Future<WsOrganization?> _organizationFor(String uid) {
    final key = '$uid|${WsTenantService.selectedOrgId}';
    if (_orgKey != key || _orgFuture == null) {
      _orgKey = key;
      _orgFuture = _deps.currentOrganization();
    }
    return _orgFuture!;
  }

  Future<WsUserRole> _roleFor(String uid, int orgId) {
    final key = '$uid|$orgId';
    if (_roleKey != key || _roleFuture == null) {
      _roleKey = key;
      _roleFuture = _deps.resolveRole(uid, orgId);
    }
    return _roleFuture!;
  }

  /// Called when there is no session. Without this, signing out and back in as
  /// the SAME user would reuse a future resolved before the sign-out — and the
  /// organization selection is cleared by sign-out, so that answer is stale.
  void _forgetResolved() {
    _orgKey = null;
    _orgFuture = null;
    _roleKey = null;
    _roleFuture = null;
  }

  @override
  Widget build(BuildContext context) {
    final d = _deps;

    return StreamBuilder<Object?>(
      stream: d.authChanges,
      builder: (context, snapshot) {
        // No client and no session both land here, exactly as before.
        final uid = d.currentUserId();
        if (uid == null) {
          // Sign-out, or a session that never restored. Drop the resolved
          // futures so the next sign-in resolves fresh.
          _forgetResolved();
          return const WsLoginScreen();
        }

        return FutureBuilder<WsOrganization?>(
          future: _organizationFor(uid),
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
              return WsAuthGate._errorScreen(
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
              future: _roleFor(uid, org.orgId),
              builder: (context, roleSnap) {
                if (roleSnap.connectionState != ConnectionState.done) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }

                // A thrown future also leaves hasData false, so the old check
                // turned any permission-load failure into the same silent hang.
                if (roleSnap.hasError) {
                  return WsAuthGate._errorScreen(
                    'Could not determine your access level',
                    roleSnap.error.toString(),
                  );
                }

                if (roleSnap.data == WsUserRole.customer) {
                  return const WsCustomerPortalScreen();
                }

                return const WsOfflineSessionBanner(
                  child: WsDashboardScreen(),
                );
              },
            );
          },
        );
      },
    );
  }

}
