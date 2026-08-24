// =============================================================================
// lib/services/outbox/ws_outbox_store.dart
// Where the outbox lives on disk. Storage ONLY — no queue logic, no accounting.
//
// The interface exists so the JSON file can be replaced with SQLite later
// without touching the queue. The queue never opens a file; it asks the store
// to load and save a list.
//
// ─── WHY THE WRITE IS ATOMIC ─────────────────────────────────────────────────
// A queue that corrupts itself on a crash is worse than no queue: it loses
// documents silently. Every save writes a temporary file, flushes it, and then
// RENAMES it over the real one. Rename is atomic on every platform this app
// runs on, so a reader either sees the whole previous file or the whole new
// one — never a half-written array of JSON.
//
// The obvious version — open the real file and write into it — has a window,
// measured in milliseconds but hit eventually, where the process dies with a
// truncated file and the entire pending queue is gone.
// =============================================================================

import 'dart:convert';
import 'dart:io';

/// Storage contract. Deliberately tiny: load everything, save everything.
///
/// The whole queue is rewritten on each change. That is the right trade at
/// this size — an outbox holds tens of items, not thousands — and it removes
/// every partial-update failure mode. If the queue ever grows to where this
/// matters, that is the signal to move to SQLite, and only this file changes.
abstract class WsOutboxStore {
  Future<List<Map<String, dynamic>>> load();
  Future<void> save(List<Map<String, dynamic>> items);

  /// Wipe everything. Used by tests and by "sign out and forget this device".
  Future<void> clear();
}

/// JSON file implementation.
class WsOutboxFileStore implements WsOutboxStore {
  final File file;

  WsOutboxFileStore(String path) : file = File(path);

  File get _tmp => File('${file.path}.tmp');

  @override
  Future<List<Map<String, dynamic>>> load() async {
    try {
      if (!await file.exists()) {
        // A .tmp with no real file means the process died between writing the
        // temp and renaming it. That temp IS a complete, valid queue — it was
        // fully written before the rename was attempted — so recover it rather
        // than starting empty and losing every pending document.
        if (await _tmp.exists()) {
          await _tmp.rename(file.path);
        } else {
          return [];
        }
      }
      final text = await file.readAsString();
      if (text.trim().isEmpty) return [];
      final decoded = jsonDecode(text);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } on FormatException {
      // Corrupt JSON. Do NOT delete it — a human may be able to recover
      // documents from it by hand. Move it aside and carry on with an empty
      // queue, which is the only state we can trust.
      try {
        final stamp = DateTime.now().millisecondsSinceEpoch;
        await file.rename('${file.path}.corrupt.$stamp');
      } catch (_) {/* best effort */}
      return [];
    }
  }

  @override
  Future<void> save(List<Map<String, dynamic>> items) async {
    final dir = file.parent;
    if (!await dir.exists()) await dir.create(recursive: true);

    // Write → flush → rename. See the header.
    final sink = _tmp.openSync(mode: FileMode.write);
    try {
      sink.writeStringSync(jsonEncode(items));
      sink.flushSync();
    } finally {
      sink.closeSync();
    }
    await _tmp.rename(file.path);
  }

  @override
  Future<void> clear() async {
    if (await file.exists()) await file.delete();
    if (await _tmp.exists()) await _tmp.delete();
  }
}

/// In-memory store, for tests and for a "do not persist" mode.
class WsOutboxMemoryStore implements WsOutboxStore {
  List<Map<String, dynamic>> _items = [];

  @override
  Future<List<Map<String, dynamic>>> load() async =>
      _items.map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Future<void> save(List<Map<String, dynamic>> items) async =>
      _items = items.map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Future<void> clear() async => _items = [];
}
