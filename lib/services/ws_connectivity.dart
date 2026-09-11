// =============================================================================
// lib/services/ws_connectivity.dart
// "Is there a network at all?" — and nothing more than that.
//
// ─── WHAT THIS IS FOR ────────────────────────────────────────────────────────
//
// Offline, a Supabase read is a guaranteed failure that still costs real time:
// postgrest retries every GET four times with 1s + 2s + 4s backoff before it
// gives up (postgrest_builder.dart, maxRetries = 3, retryEnabled defaults to
// true). Seven seconds of deliberate sleeping, per read, to reach a cache that
// was already in memory.
//
// So this exists to SKIP a call that cannot succeed. That is its whole job.
//
// ─── WHAT IT MUST NEVER BE USED FOR ──────────────────────────────────────────
//
// `navigator.onLine == true` means the browser believes it has an interface.
// It does NOT mean Supabase is reachable: a captive portal, a DNS failure, a
// firewall or a backend outage all report true.
//
// Therefore:
//
//   false  →  trustworthy. Skip the request; it cannot succeed.
//   true   →  NOT trustworthy. Behave exactly as before — try the server,
//             fall back to cache on failure.
//
// Every caller must be written so that a wrong `true` costs nothing but the
// old behaviour. Nothing may treat `true` as proof of anything.
//
// ─── WHY THERE IS NO LISTENER, NOTIFIER OR CACHED FLAG ───────────────────────
//
// The value is read fresh at the moment of the call. A notifier updated by
// window online/offline events would add state that can be stale exactly when
// it matters — during the transition — and nothing here needs to REACT to
// connectivity, only to ask about it. The outbox already has its own recovery
// triggers and is deliberately untouched.
// =============================================================================

import 'ws_connectivity_stub.dart'
    if (dart.library.js_interop) 'ws_connectivity_web.dart' as platform;

class WsConnectivity {
  WsConnectivity._();

  /// Injectable. Tests drive both states through this; production leaves it.
  ///
  /// Defaults to the platform reader, which returns TRUE on any platform that
  /// cannot answer — including the Dart VM the tests run on. Assuming online
  /// is the conservative default: it reproduces the previous behaviour exactly
  /// (try the server, fall back on failure) rather than silently serving cache
  /// to a device that could have reached the network.
  static bool Function() isOnline = platform.browserIsOnline;

  /// Restores the production reader. For tearDown.
  static void reset() => isOnline = platform.browserIsOnline;
}

/// Thrown to skip a network call that cannot succeed, so the EXISTING cache
/// fallback in each caller's `catch` handles it — unchanged.
///
/// A sentinel rather than a restructure on purpose: every one of these call
/// sites already has a correct, tested offline path. Reaching it by a
/// different route is a far smaller change than rewriting five methods, and it
/// cannot alter what happens when the device is online.
class WsOfflineSkip implements Exception {
  const WsOfflineSkip();
  @override
  String toString() => 'device is offline, used local data';
}
