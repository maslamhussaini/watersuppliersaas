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

  /// Set by [load] when the stored queue could not be read cleanly, null when
  /// it could. READ AFTER EVERY LOAD — this is how a corrupt file stops being
  /// a silent event.
  WsOutboxLoadIssue? get lastLoadIssue;
}

/// What went wrong reading the queue, and what was rescued from it.
///
/// Exists because the previous behaviour — quarantine the file, return an
/// empty list — is indistinguishable from "you had nothing queued". The user
/// walks away believing their pending deliveries synced. The file survived on
/// disk, but nobody knew to go looking for it.
class WsOutboxLoadIssue {
  /// Where the unreadable bytes were moved. Never deleted.
  final String quarantinePath;

  /// How many complete records were recovered from the damage.
  final int salvaged;

  /// How many top-level records could not be recovered at all.
  final int unrecoverable;

  final String detail;

  const WsOutboxLoadIssue({
    required this.quarantinePath,
    required this.salvaged,
    required this.unrecoverable,
    required this.detail,
  });

  bool get everythingRecovered => unrecoverable == 0;

  @override
  String toString() => 'WsOutboxLoadIssue(salvaged: $salvaged, '
      'unrecoverable: $unrecoverable, file: $quarantinePath)';
}

/// JSON file implementation.
class WsOutboxFileStore implements WsOutboxStore {
  final File file;

  WsOutboxFileStore(String path) : file = File(path);

  File get _tmp => File('${file.path}.tmp');

  WsOutboxLoadIssue? _issue;

  @override
  WsOutboxLoadIssue? get lastLoadIssue => _issue;

  @override
  Future<List<Map<String, dynamic>>> load() async {
    _issue = null; // a fresh verdict on every load
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
    } on FormatException catch (e) {
      return _recover(e);
    }
  }

  /// Corrupt JSON. Salvage what is still readable, keep the original bytes,
  /// and RECORD THAT IT HAPPENED.
  ///
  /// The old behaviour returned an empty list, which reads to every layer
  /// above as "nothing was queued". Damage to the end of the file — the
  /// likeliest kind, a write cut short by a dying battery — leaves every
  /// earlier record perfectly intact, and throwing those away was a real loss
  /// of pending deliveries.
  Future<List<Map<String, dynamic>>> _recover(FormatException cause) async {
    String text = '';
    try {
      text = await file.readAsString();
    } catch (_) {/* unreadable; salvage nothing */}

    final salvaged = <Map<String, dynamic>>[];
    var unrecoverable = 0;
    for (final chunk in _topLevelObjects(text)) {
      try {
        final decoded = jsonDecode(chunk);
        if (decoded is Map && decoded['clientUuid'] != null) {
          salvaged.add(Map<String, dynamic>.from(decoded));
        } else {
          unrecoverable++;
        }
      } on FormatException {
        // A record damaged mid-way. Counted, not guessed at: half a delivery
        // is not a delivery.
        unrecoverable++;
      }
    }

    var quarantine = file.path;
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      quarantine = '${file.path}.corrupt.$stamp';
      await file.rename(quarantine);
    } catch (_) {/* best effort — the issue is reported either way */}

    _issue = WsOutboxLoadIssue(
      quarantinePath: quarantine,
      salvaged: salvaged.length,
      unrecoverable: unrecoverable,
      detail: cause.message,
    );

    // Salvaged records are handed back as the queue. They are rewritten to a
    // clean file by the first save, so the next start is normal.
    if (salvaged.isNotEmpty) {
      try {
        await save(salvaged);
      } catch (_) {/* the in-memory copy is still returned */}
    }
    return salvaged;
  }

  /// Splits a damaged JSON array into its top-level `{...}` chunks by tracking
  /// brace depth, ignoring braces inside strings and escapes.
  ///
  /// Deliberately not a JSON parser: the input is by definition not valid
  /// JSON. It only has to find where each record starts and stops so the
  /// intact ones can be decoded individually.
  static Iterable<String> _topLevelObjects(String text) sync* {
    var depth = 0, start = -1;
    var inString = false, escaped = false;

    for (var i = 0; i < text.length; i++) {
      final c = text[i];

      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }

      switch (c) {
        case '"':
          inString = true;
        case '{':
          if (depth == 0) start = i;
          depth++;
        case '}':
          depth--;
          if (depth == 0 && start >= 0) {
            yield text.substring(start, i + 1);
            start = -1;
          } else if (depth < 0) {
            depth = 0; // stray closer in the damage; resynchronise
          }
      }
    }

    // An object that was still open when the file ended is truncated and
    // unrecoverable. Yielding it lets the caller count it rather than lose it
    // silently.
    if (depth > 0 && start >= 0) yield text.substring(start);
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

  /// Always null: memory cannot be corrupt in the way a file can.
  @override
  WsOutboxLoadIssue? get lastLoadIssue => null;

  @override
  Future<List<Map<String, dynamic>>> load() async =>
      _items.map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Future<void> save(List<Map<String, dynamic>> items) async =>
      _items = items.map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Future<void> clear() async => _items = [];
}
