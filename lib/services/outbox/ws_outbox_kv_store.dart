// =============================================================================
// lib/services/outbox/ws_outbox_kv_store.dart
// WsOutboxStore over the shared key/value seam, for platforms without a file
// system — which is to say, for web, the only platform this project ships to.
//
// ─── WHAT IS AND IS NOT DIFFERENT ────────────────────────────────────────────
//
// This is a STORAGE swap. The queue engine above it is untouched: FIFO order,
// the retry budget, the network-vs-budgeted distinction, clientuuid replay and
// acknowledgement all live in ws_outbox.dart and never learn where the bytes
// went. The serialization is the same JSON list of the same item maps, so a
// queue written by one implementation is readable by the other.
//
// What is different is salvage, and deliberately so.
//
// WsOutboxFileStore recovers from a TORN WRITE: a leftover .tmp renamed back
// over the target, and a brace scanner that pulls whole top-level records out
// of a truncated file. Those exist because a process can die between opening a
// file and finishing it, leaving real byte-level wreckage.
//
// shared_preferences cannot produce that state. A set() either lands whole or
// does not land, and on web it is localStorage, which is likewise all-or-
// nothing per key. A brace scanner here would be machinery that can never run,
// asserting a guarantee about torn writes that this backend does not need.
//
// What DOES survive is the reporting contract. A value that will not parse is
// still reported through lastLoadIssue rather than silently dropped, because
// the outbox's rule is that a queue which loses documents must say so out loud.
// The unreadable payload is moved aside, never deleted, exactly as the file
// store quarantines rather than discards.
// =============================================================================

import 'dart:convert';

import '../storage/ws_key_value_store.dart';
import 'ws_outbox_store.dart';

class WsOutboxKvStore implements WsOutboxStore {
  static const storageKey = 'outbox.queue';

  /// Where an unreadable queue is moved. NEVER deleted — a corrupt queue may
  /// be the only remaining record of a delivery somebody made.
  static const quarantineKey = 'outbox.queue.corrupt';

  final WsKeyValueStore kv;

  WsOutboxLoadIssue? _lastLoadIssue;

  WsOutboxKvStore(this.kv);

  @override
  WsOutboxLoadIssue? get lastLoadIssue => _lastLoadIssue;

  @override
  Future<List<Map<String, dynamic>>> load() async {
    _lastLoadIssue = null;

    final raw = await kv.read(storageKey);
    if (raw == null || raw.isEmpty) return [];

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      return _quarantine(raw, 'The stored queue is not valid JSON: $e');
    }

    if (decoded is! List) {
      return _quarantine(raw,
          'The stored queue is a ${decoded.runtimeType}, not a list.');
    }

    // Per-record tolerance, mirroring the file store: one bad record does not
    // cost the whole queue. Anything that is not a map is counted as lost and
    // reported rather than passed up as if it had never existed.
    final items = <Map<String, dynamic>>[];
    var unrecoverable = 0;
    for (final entry in decoded) {
      if (entry is Map) {
        items.add(Map<String, dynamic>.from(entry));
      } else {
        unrecoverable++;
      }
    }

    if (unrecoverable > 0) {
      await kv.write(quarantineKey, raw);
      _lastLoadIssue = WsOutboxLoadIssue(
        quarantinePath: quarantineKey,
        salvaged: items.length,
        unrecoverable: unrecoverable,
        detail: '$unrecoverable queued record(s) were not readable and have '
            'been set aside under "$quarantineKey".',
      );
    }

    return items;
  }

  Future<List<Map<String, dynamic>>> _quarantine(
    String raw,
    String detail,
  ) async {
    await kv.write(quarantineKey, raw);
    _lastLoadIssue = WsOutboxLoadIssue(
      quarantinePath: quarantineKey,
      salvaged: 0,
      unrecoverable: -1, // count unknown: nothing could be parsed at all
      detail: '$detail The unreadable copy has been kept under '
          '"$quarantineKey".',
    );
    return [];
  }

  @override
  Future<void> save(List<Map<String, dynamic>> items) =>
      kv.write(storageKey, jsonEncode(items));

  @override
  Future<void> clear() => kv.remove(storageKey);
}
