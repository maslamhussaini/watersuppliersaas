// =============================================================================
// lib/services/ws_connectivity_stub.dart
// The non-web half of the conditional import in ws_connectivity.dart.
//
// Used by the Dart VM the tests run on, where there is no navigator to ask.
// Returns TRUE — "assume online" — so the default behaviour is the previous
// behaviour: try the server, fall back to cache on failure. A stub that
// claimed offline would silently route every test through the cache path.
// =============================================================================

bool browserIsOnline() => true;
