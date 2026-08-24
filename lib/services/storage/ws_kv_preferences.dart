// =============================================================================
// lib/services/storage/ws_kv_preferences.dart
// The web-capable store, on shared_preferences.
//
// NO SALVAGE MACHINERY HERE, deliberately.
//
// The file store recovers a half-written queue: it renames a leftover .tmp back
// over the target, and scans a truncated file for whole top-level objects. That
// exists because a process can die between opening a file and finishing the
// write, leaving a real byte-level partial.
//
// shared_preferences has no such failure mode — a set() either lands or does
// not, and on web it is backed by localStorage, which is likewise all-or-
// nothing per key. Inventing a salvage path here would be machinery that can
// never run, tested against a state that cannot occur, and it would imply a
// guarantee about torn writes that this backend does not actually need.
//
// What DOES survive is corruption reporting: a value that will not parse is
// reported by the layer that knows its shape, exactly as on the file store.
// =============================================================================

import 'package:shared_preferences/shared_preferences.dart';

import 'ws_key_value_store.dart';

/// The one call this file makes into the plugin, behind an interface so tests
/// never need a platform channel.
abstract class WsPreferencesBackend {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
  Future<Set<String>> keys();
}

class WsSharedPreferencesBackend implements WsPreferencesBackend {
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<String?> getString(String key) async => (await _p).getString(key);

  @override
  Future<void> setString(String key, String value) async =>
      (await _p).setString(key, value);

  @override
  Future<void> remove(String key) async => (await _p).remove(key);

  @override
  Future<Set<String>> keys() async => (await _p).getKeys();
}

/// In-memory backend for tests. Distinct from [WsMemoryKeyValueStore] because
/// this one lets a test drive the PREFERENCES implementation itself rather than
/// bypassing it.
class WsFakePreferencesBackend implements WsPreferencesBackend {
  final Map<String, String> values = {};
  int writes = 0;

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<Set<String>> keys() async => values.keys.toSet();
}

class WsPreferencesKeyValueStore implements WsKeyValueStore {
  final WsPreferencesBackend backend;

  /// Only keys under this prefix are touched by [clear], so the app never wipes
  /// preferences it does not own — including Supabase's own persisted session,
  /// which lives in the same store and must survive.
  final String namespace;

  WsPreferencesKeyValueStore(this.backend, {this.namespace = 'ws'});

  String _k(String key) => '$namespace.$key';

  @override
  Future<String?> read(String key) => backend.getString(_k(key));

  @override
  Future<void> write(String key, String value) =>
      backend.setString(_k(key), value);

  @override
  Future<void> remove(String key) => backend.remove(_k(key));

  @override
  Future<void> clear() async {
    for (final key in await backend.keys()) {
      if (key.startsWith('$namespace.')) await backend.remove(key);
    }
  }
}
