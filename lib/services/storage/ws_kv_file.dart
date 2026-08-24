// =============================================================================
// lib/services/storage/ws_kv_file.dart
// The non-web store: one JSON map, written atomically.
//
// Temp-file-plus-rename, the same discipline the outbox file store uses, for
// the same reason: a process that dies mid-write must leave either the old
// contents or the new ones, never half of either.
//
// This does NOT replace WsOutboxFileStore. That store keeps its own salvage
// logic — the leftover-.tmp recovery and the truncated-JSON brace scanner —
// and this file is not in its path.
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'ws_key_value_store.dart';

class WsFileKeyValueStore implements WsKeyValueStore {
  final File file;

  WsFileKeyValueStore(String path) : file = File(path);

  File get _tmp => File('${file.path}.tmp');

  Map<String, String>? _cache;

  Future<Map<String, String>> _load() async {
    if (_cache != null) return _cache!;

    // A leftover temp file means the last write finished writing but died
    // before the rename. Its contents are newer and complete — recover it
    // rather than discarding a successful write.
    if (await _tmp.exists() && !await file.exists()) {
      await _tmp.rename(file.path);
    }

    if (!await file.exists()) return _cache = {};

    try {
      final decoded = jsonDecode(await file.readAsString());
      return _cache = {
        if (decoded is Map)
          for (final e in decoded.entries)
            if (e.value is String) '${e.key}': e.value as String,
      };
    } catch (_) {
      // Unreadable. Starting empty loses state; refusing to start loses the
      // app. The caller learns about it when its own key comes back null.
      return _cache = {};
    }
  }

  Future<void> _flush() async {
    final parent = file.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    await _tmp.writeAsString(jsonEncode(_cache), flush: true);
    await _tmp.rename(file.path);
  }

  @override
  Future<String?> read(String key) async => (await _load())[key];

  @override
  Future<void> write(String key, String value) async {
    (await _load())[key] = value;
    await _flush();
  }

  @override
  Future<void> remove(String key) async {
    (await _load()).remove(key);
    await _flush();
  }

  @override
  Future<void> clear() async {
    _cache = {};
    await _flush();
  }
}
