// =============================================================================
// lib/services/ws_startup.dart
// Bringing up the optional subsystems, one at a time, so that none of them can
// take the others down with it.
//
// ─── THE BUG THIS EXISTS TO PREVENT ──────────────────────────────────────────
//
// main() used to do this:
//
//     try {
//       await WsOutboxService.init();                              // ①
//       await WsWhatsNew.init();                                   // ②
//       WsLocationService.provider = const WsGeolocatorProvider(); // ③
//     } catch (e) {
//       debugPrint('Outbox init failed (queued items are still on disk): $e');
//     }
//
// ① uses path_provider's getApplicationSupportDirectory(), which has no web
// implementation. On web — the only platform this project targets — it raises,
// and ② and ③ then never run at all.
//
// ③ is the one that hurts. Without that assignment WsLocationService keeps its
// default provider, which reports `unsupported` for every capture. GPS was not
// broken; it was never switched on. The unit tests could not see it because
// they inject a provider directly, which is the blind spot every seam creates:
// it proves the wiring WORKS without proving anyone DID the wiring.
//
// The catch message compounded it by claiming "queued items are still on disk"
// on a platform that has no disk.
//
// ─── THE RULE ────────────────────────────────────────────────────────────────
//
// Each subsystem gets its own try/catch. A failure is recorded and reported,
// never swallowed silently, and never allowed to skip the next one. None of
// these three is required for the app to start, sign in, or be used — which is
// exactly why none of them may prevent the others from starting.
// =============================================================================

import 'package:flutter/foundation.dart';

import 'location_geolocator.dart';
import 'location_service.dart';
import 'outbox/ws_outbox_supabase.dart';
import 'whats_new.dart';

/// What came up and what did not. Returned rather than only logged so a
/// diagnostics screen can show it and so tests can assert on it.
class WsStartupReport {
  final Map<String, Object> failures;

  const WsStartupReport(this.failures);

  bool get allOk => failures.isEmpty;

  bool failed(String subsystem) => failures.containsKey(subsystem);

  /// Names of the subsystems that came up. Order is the order they were tried.
  final List<String> started = const [];

  @override
  String toString() => allOk
      ? 'startup: all subsystems ready'
      : 'startup: ${failures.length} subsystem(s) unavailable — '
          '${failures.keys.join(', ')}';
}

/// Subsystem identifiers, so tests and diagnostics agree on the spelling.
class WsSubsystem {
  static const outbox = 'outbox';
  static const whatsNew = 'whatsNew';
  static const location = 'location';
}

/// Starts the optional subsystems independently.
///
/// Every parameter is injectable so the failure of each can be driven in a
/// test — none of these can be made to fail on demand otherwise, which is how
/// the original bug survived a full test suite.
///
/// NEVER THROWS. A caller that awaits this can rely on reaching the next line.
Future<WsStartupReport> wsStartSubsystems({
  Future<void> Function()? initOutbox,
  Future<void> Function()? initWhatsNew,
  void Function()? initLocation,
  void Function(String message)? log,
}) async {
  final failures = <String, Object>{};
  final report = log ?? debugPrint;

  Future<void> attempt(String name, Future<void> Function() body,
      String consequence) async {
    try {
      await body();
    } catch (e) {
      failures[name] = e;
      // Said out loud, and accurately. The previous message asserted that
      // queued items were safe on disk, which on web was not true.
      report('startup: $name unavailable — $consequence ($e)');
    }
  }

  await attempt(
    WsSubsystem.outbox,
    initOutbox ?? WsOutboxService.init,
    'documents saved while offline will not be queued on this platform',
  );

  await attempt(
    WsSubsystem.whatsNew,
    initWhatsNew ?? WsWhatsNew.init,
    'release notes will show again next launch',
  );

  await attempt(
    WsSubsystem.location,
    () async {
      (initLocation ?? _installGeolocator)();
    },
    'deliveries will be saved without a location',
  );

  return WsStartupReport(failures);
}

void _installGeolocator() {
  WsLocationService.provider = const WsGeolocatorProvider();
}
