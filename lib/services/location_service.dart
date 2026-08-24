// =============================================================================
// lib/services/location_service.dart
// Capturing a position, and every way that fails.
//
// ─── THE PLUGIN IS ISOLATED, NOT ABSENT ──────────────────────────────────────
//
// This file has ONE import: dart:async. It holds every rule about capturing a
// position — when to ask, what to remember, what to reject — and none of them
// need a device to exercise, which is why the whole of location_test.dart runs
// without one.
//
// The plugin lives behind [WsLocationService.provider] in
// location_geolocator.dart. main() assigns the real one; tests assign a fake;
// leaving it unset degrades to "unsupported" rather than crashing.
//
// geolocator ships web, Android, iOS, Windows and Linux implementations. This
// project currently targets web only, where the browser prompts and needs no
// manifest. The two declarations Android and iOS would need are documented in
// location_geolocator.dart — they are configuration, not code, and this file
// would not change.
//
// ─── PRIVACY ─────────────────────────────────────────────────────────────────
//
// Capture happens on exactly two occasions: the user presses "Capture current
// location" on a customer, or a delivery is saved. There is no stream, no
// background listener, no history table. A position is read, attached to one
// document, and never read again.
// =============================================================================

import 'dart:async';

/// Why a capture produced nothing. Each maps to different advice for the user,
/// which is the only reason to distinguish them.
enum WsLocationFailure {
  /// The user said no. Asking again immediately is how apps get their
  /// permission permanently denied.
  permissionDenied,

  /// Denied with "don't ask again" — only Settings can undo it.
  permissionDeniedForever,

  /// Location is switched off on the device, so no app can get a fix.
  serviceDisabled,

  /// The device tried and could not get a fix in time. Indoors, usually.
  timeout,

  /// No provider is wired in — the state this build ships in.
  unsupported,

  /// Anything else the platform threw.
  error,
}

class WsPosition {
  final double latitude;
  final double longitude;

  /// Metres. Null when the platform does not report it.
  final double? accuracy;

  /// WHEN THE READING WAS TAKEN. Not when it was saved and not when it synced
  /// — a delivery queued underground carries the moment it happened.
  final DateTime capturedAt;

  const WsPosition({
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
    this.accuracy,
  });

  /// Rejects the impossible. The database has the same check; doing it here as
  /// well means a broken platform reading never becomes a failed save.
  bool get isValid =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      !(latitude == 0 && longitude == 0);

  Map<String, dynamic> toArgs() => {
        'p_latitude': latitude,
        'p_longitude': longitude,
        'p_accuracy': accuracy,
        'p_capturedat': capturedAt.toUtc().toIso8601String(),
      };

  @override
  String toString() =>
      '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}'
      '${accuracy == null ? '' : ' ±${accuracy!.round()}m'}';
}

class WsLocationResult {
  final WsPosition? position;
  final WsLocationFailure? failure;

  const WsLocationResult.success(WsPosition this.position) : failure = null;
  const WsLocationResult.failed(WsLocationFailure this.failure)
      : position = null;

  bool get ok => position != null;

  /// What to actually say to a driver. Deliberately about what they can DO.
  String get message {
    switch (failure) {
      case WsLocationFailure.permissionDenied:
        return 'Location permission was declined. The delivery will be saved '
            'without it.';
      case WsLocationFailure.permissionDeniedForever:
        return 'Location is blocked for this app. Turn it on in Settings if '
            'you want deliveries tagged.';
      case WsLocationFailure.serviceDisabled:
        return 'Location is switched off on this device.';
      case WsLocationFailure.timeout:
        return 'Could not get a location in time — you may be indoors.';
      case WsLocationFailure.unsupported:
        return 'Location capture is not available in this build.';
      case WsLocationFailure.error:
      case null:
        return 'Could not read the location.';
    }
  }
}

/// The seam. Implemented by a plugin adapter in production and by a fake in
/// tests, so every branch below can be driven without a device.
abstract class WsLocationProvider {
  Future<WsLocationResult> current({Duration timeout});
}

/// The provider this build ships with: honest about doing nothing.
class WsUnsupportedLocationProvider implements WsLocationProvider {
  const WsUnsupportedLocationProvider();

  @override
  Future<WsLocationResult> current({Duration timeout = Duration.zero}) async =>
      const WsLocationResult.failed(WsLocationFailure.unsupported);
}

class WsLocationService {
  WsLocationService._();

  /// Swap this for a real provider to enable capture. Nothing else changes.
  static WsLocationProvider provider = const WsUnsupportedLocationProvider();

  /// Remembers a refusal for the rest of the session.
  ///
  /// WITHOUT THIS the app asks again on every screen that captures, which is
  /// how a user ends up choosing "never ask again" — and then the feature is
  /// off permanently rather than off for today.
  static WsLocationFailure? _declined;

  static bool get isDeclined => _declined != null;

  /// Called when the user asks for location explicitly, which is consent to
  /// try again even after an earlier refusal.
  static void clearDecline() => _declined = null;

  /// A single reading.
  ///
  /// [userInitiated] is the difference between a button press and a background
  /// step of saving a delivery. A user who pressed the button gets a fresh
  /// attempt; the automatic path respects an earlier refusal silently.
  static Future<WsLocationResult> capture({
    Duration timeout = const Duration(seconds: 8),
    bool userInitiated = false,
  }) async {
    if (userInitiated) clearDecline();

    final declined = _declined;
    if (declined != null) return WsLocationResult.failed(declined);

    try {
      final result = await provider.current(timeout: timeout);

      if (!result.ok) {
        // Only a REFUSAL is remembered. A timeout indoors says nothing about
        // consent, and suppressing later attempts because of it would break
        // capture for the rest of the day.
        if (result.failure == WsLocationFailure.permissionDenied ||
            result.failure == WsLocationFailure.permissionDeniedForever) {
          _declined = result.failure;
        }
        return result;
      }

      if (!result.position!.isValid) {
        return const WsLocationResult.failed(WsLocationFailure.error);
      }
      return result;
    } on TimeoutException {
      return const WsLocationResult.failed(WsLocationFailure.timeout);
    } catch (_) {
      return const WsLocationResult.failed(WsLocationFailure.error);
    }
  }

  /// For tests.
  static void reset() {
    provider = const WsUnsupportedLocationProvider();
    _declined = null;
  }
}

// ─── The adapter ──────────────────────────────────────────────────────────────
//
// See location_geolocator.dart. It is a single class with no policy in it: it
// checks whether location services are on, resolves the permission, takes ONE
// reading with getCurrentPosition, and maps the result into WsLocationResult.
// Every decision about that result is made above.
