// =============================================================================
// lib/services/storage/ws_key_value_store.dart
// One small durable key/value seam, and nothing else.
//
// ─── WHY ─────────────────────────────────────────────────────────────────────
//
// The outbox and What's New both persist through path_provider, which has NO
// web implementation — and web is the only platform this project targets. Both
// therefore raised at startup and, until ws_startup.dart, took the GPS provider
// down with them.
//
// The fix is not to rewrite either of them. It is to give them a storage seam
// with two implementations, so the queue engine, its FIFO order, its retry
// budget and its idempotency all stay exactly as they are and only the bytes
// underneath change platform.
//
//     Outbox / What's New / Registration attempt
//                     ↓
//              WsKeyValueStore
//                ↙          ↘
//        file store      preferences store
//
// ─── NO kIsWeb ABOVE THIS LINE ───────────────────────────────────────────────
//
// Platform selection happens in ws_kv_default.dart and NOWHERE else. If a
// business-logic file ever needs to ask which platform it is on, this seam has
// failed at its job.
//
// Strings only. Callers own their own encoding, which keeps this interface
// small enough that a second implementation is obviously correct by reading it.
// =============================================================================

/// Durable string storage, keyed. Every method must tolerate being called
/// before anything has been written.
abstract class WsKeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> remove(String key);

  /// Everything this store owns. Used by sign-out-and-forget and by tests.
  Future<void> clear();
}

/// For tests, and for any platform where persistence is genuinely unavailable.
///
/// Losing state on restart is bad; refusing to start is worse. A caller that
/// gets this still works for the length of a session.
class WsMemoryKeyValueStore implements WsKeyValueStore {
  final Map<String, String> values;

  WsMemoryKeyValueStore([Map<String, String>? initial])
      : values = {...?initial};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<void> clear() async => values.clear();
}

/// Thrown by nothing here. Present so callers that DO care about a bad payload
/// have one type to catch, rather than each inventing their own.
///
/// Note the division of labour: this seam stores and returns strings, and
/// never inspects them. Deciding that a payload is corrupt — and what to
/// salvage from it — belongs to the layer that wrote it and knows its shape.
class WsStorageFormatException implements Exception {
  final String key;
  final String detail;

  const WsStorageFormatException(this.key, this.detail);

  @override
  String toString() => 'WsStorageFormatException($key): $detail';
}

/// Namespaces a store so several callers can share one backend without
/// colliding. `ws.outbox`, `ws.whatsNew`, `ws.registration`.
class WsPrefixedKeyValueStore implements WsKeyValueStore {
  final WsKeyValueStore inner;
  final String prefix;
  final Set<String> _own = {};

  WsPrefixedKeyValueStore(this.inner, this.prefix);

  String _k(String key) => '$prefix.$key';

  @override
  Future<String?> read(String key) => inner.read(_k(key));

  @override
  Future<void> write(String key, String value) {
    _own.add(key);
    return inner.write(_k(key), value);
  }

  @override
  Future<void> remove(String key) {
    _own.remove(key);
    return inner.remove(_k(key));
  }

  /// Clears only what THIS namespace wrote — clearing the shared backend would
  /// take the other callers' state with it.
  @override
  Future<void> clear() async {
    for (final key in _own.toList()) {
      await inner.remove(_k(key));
    }
    _own.clear();
  }
}
