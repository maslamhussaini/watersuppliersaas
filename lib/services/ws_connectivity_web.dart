// =============================================================================
// lib/services/ws_connectivity_web.dart
// The web half of the conditional import in ws_connectivity.dart.
//
// dart:js_interop is part of the SDK, so this adds NO dependency. package:web
// would do the same job but is only a transitive dependency here, and relying
// on one that pubspec does not declare is how a working build breaks later.
// =============================================================================

import 'dart:js_interop';

@JS('navigator')
external _Navigator get _navigator;

extension type _Navigator._(JSObject _) implements JSObject {
  external bool get onLine;
}

/// `navigator.onLine`. False is trustworthy; true is not — see the contract in
/// ws_connectivity.dart.
bool browserIsOnline() {
  try {
    return _navigator.onLine;
  } catch (_) {
    // Any interop surprise must not break a read. Assume online, which is the
    // previous behaviour.
    return true;
  }
}
