// =============================================================================
// lib/services/location_geolocator.dart
// The real location provider, and the only file that touches the plugin.
//
// ─── WHY IT IS ITS OWN FILE ──────────────────────────────────────────────────
//
// location_service.dart holds every rule — when to ask, what to remember, what
// to reject — and has no plugin import at all, so all of it stays testable
// without a device. This file is the thin adapter that turns geolocator's API
// into WsLocationResult, and it contains no policy.
//
// ─── PLATFORM SUPPORT ────────────────────────────────────────────────────────
//
// geolocator ships implementations for web, Android, iOS, Windows and Linux.
// This project currently targets WEB ONLY (.metadata lists root and web), and
// the browser Geolocation API needs no manifest — the browser prompts, and a
// refusal arrives here as permissionDenied like anywhere else.
//
// If Android and iOS targets are added later, this file does not change. What
// they need is declaration, not code:
//
//   android/app/src/main/AndroidManifest.xml
//     <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
//     <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
//
//   ios/Runner/Info.plist
//     <key>NSLocationWhenInUseUsageDescription</key>
//     <string>Used to tag deliveries with where they were made.</string>
//
// WHEN IN USE, never "always". This app captures on an explicit save and
// nowhere else, so background authorisation would be asking for a permission
// it does not use — which reviewers reject and users notice.
// =============================================================================

import 'package:geolocator/geolocator.dart';

import 'location_service.dart';

class WsGeolocatorProvider implements WsLocationProvider {
  const WsGeolocatorProvider();

  @override
  Future<WsLocationResult> current({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    // ── is location switched on at all? ─────────────────────────────────
    // Asked first because requesting permission while the service is off
    // produces a prompt that cannot lead anywhere useful.
    if (!await Geolocator.isLocationServiceEnabled()) {
      return const WsLocationResult.failed(WsLocationFailure.serviceDisabled);
    }

    // ── permission ──────────────────────────────────────────────────────
    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      // Only asked when it has never been decided. WsLocationService remembers
      // a refusal for the session, so this prompt appears once, not on every
      // delivery.
      permission = await Geolocator.requestPermission();
    }

    switch (permission) {
      case LocationPermission.deniedForever:
        return const WsLocationResult.failed(
            WsLocationFailure.permissionDeniedForever);
      case LocationPermission.denied:
        return const WsLocationResult.failed(
            WsLocationFailure.permissionDenied);
      case LocationPermission.unableToDetermine:
        return const WsLocationResult.failed(WsLocationFailure.error);
      case LocationPermission.whileInUse:
      case LocationPermission.always:
        break;
    }

    // ── one reading ─────────────────────────────────────────────────────
    //
    // getCurrentPosition, NOT getPositionStream. A single fix on demand is the
    // whole of this feature; a stream would be background tracking, which this
    // app does not do and does not ask permission for.
    final position = await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        // The plugin throws TimeoutException past this; WsLocationService
        // catches it and reports a timeout rather than a crash.
        timeLimit: timeout,
      ),
    );

    return WsLocationResult.success(WsPosition(
      latitude: position.latitude,
      longitude: position.longitude,
      // Reported in metres. Some platforms return 0 when they do not know,
      // which is a claim of perfect precision and worse than saying nothing.
      accuracy: position.accuracy > 0 ? position.accuracy : null,
      // The device's own timestamp when available: on a queued delivery this
      // is the difference between when it happened and when it synced.
      capturedAt: position.timestamp.toLocal(),
    ));
  }
}
