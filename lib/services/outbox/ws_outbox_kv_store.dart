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
import 'ws_outbox.dart' show wsNewUuid;
import 'ws_outbox_store.dart';

/// ─── ONE KEY PER INSTANCE ───────────────────────────────────────────────────
///
/// Two browser tabs at one origin share a single localStorage. Each runs its
/// own WsOutbox with its own in-memory snapshot, taken once at startup, and
/// every save used to overwrite the SAME key wholesale. A tab that had been
/// open a while therefore blasted its stale view over whatever the other tab
/// had written — silently destroying unsent deliveries. That was Defect #7,
/// found in real-browser E2E, and it defeated durability, ownership and the
/// sign-out warning at once, because none of them help if the file is replaced.
///
/// Read-merge-write was considered and rejected: it narrows the window from
/// hours to microseconds but leaves a genuine lost-update race, and
/// localStorage offers no atomic compare-and-swap to close it.
///
/// So each instance OWNS a key and writes only that key:
///
///   `outbox.instance.<uuid>`   this instance, written by nobody else
///   outbox.queue               legacy, adopted once then removed
///   outbox.queue.corrupt       existing quarantine, untouched
///
/// Loading reads every instance key and merges by clientUuid. Since no
/// instance ever writes another's key, a lost update is not narrowed — it is
/// structurally impossible.
///
/// `outbox.instance.` deliberately avoids the `outbox.queue.` prefix, because
/// `outbox.queue.corrupt` already lives there and a glob would sweep it up.
class WsOutboxKvStore implements WsOutboxStore {
  /// Legacy single-key queue. Read on first load, then adopted and removed.
  static const storageKey = 'outbox.queue';

  /// Where an unreadable queue is moved. NEVER deleted — a corrupt queue may
  /// be the only remaining record of a delivery somebody made.
  static const quarantineKey = 'outbox.queue.corrupt';

  static const instancePrefix = 'outbox.instance.';

  final WsKeyValueStore kv;

  /// This instance's key. Minted once at construction and never reused, so a
  /// reload is a new instance with a new key — see the GC rules on load().
  final String instanceId;

  WsOutboxLoadIssue? _lastLoadIssue;

  WsOutboxKvStore(this.kv, {String? instanceId})
      : instanceId = instanceId ?? wsNewUuid();

  String get instanceKey => '$instancePrefix$instanceId';

  @override
  WsOutboxLoadIssue? get lastLoadIssue => _lastLoadIssue;

  @override
  Future<List<Map<String, dynamic>>> load() async {
    _lastLoadIssue = null;

    final merged = <String, Map<String, dynamic>>{};

    // Counted loss and UNCOUNTABLE loss are different facts and are tracked
    // separately. `unrecoverable: -1` is a sentinel meaning "records were lost
    // and there is no structure left to count them", so it must never be added
    // into a running total: two unreadable keys would sum to -2, and a third
    // would reach 0 — which reads as "nothing was lost", the one thing known to
    // be false. See the sentinel test in outbox_storage_test.dart.
    var counted = 0;
    var uncountable = false;
    final quarantined = <String>[];
    final details = <String>[];

    // ── every instance key, each read in isolation ───────────────────────────
    // One unreadable key must not cost the others. That per-key isolation is
    // something the old single-key design could not offer.
    final all = await kv.keys();
    for (final key in all.where((k) => k.startsWith(instancePrefix))) {
      if (key.endsWith('.corrupt')) continue;
      final r = await _readKey(key);
      if (r.lost < 0) {
        uncountable = true;
      } else {
        counted += r.lost;
      }
      if (r.quarantined) quarantined.add(key);
      if (r.detail != null) details.add(r.detail!);
      for (final item in r.items) {
        _mergeInto(merged, item);
      }
    }

    // ── legacy single-key queue, adopted once ────────────────────────────────
    final legacyRaw = await kv.read(storageKey);
    var adoptLegacy = false;
    if (legacyRaw != null && legacyRaw.isNotEmpty) {
      final r = await _readKey(storageKey);
      if (r.lost < 0) {
        uncountable = true;
      } else {
        counted += r.lost;
      }
      if (r.quarantined) quarantined.add(storageKey);
      if (r.detail != null) details.add(r.detail!);
      for (final item in r.items) {
        _mergeInto(merged, item);
      }
      adoptLegacy = true;
    }

    final items = merged.values.toList();

    // WRITE BEFORE DELETE. If anything goes wrong between these two lines the
    // legacy key survives and is adopted again next time — the merge collapses
    // duplicate clientUuids, so re-running costs nothing.
    if (adoptLegacy) {
      await kv.write(instanceKey, jsonEncode(items));
      await kv.remove(storageKey);
    }

    if (counted > 0 || uncountable || quarantined.isNotEmpty) {
      // The per-key diagnosis is the useful part — "not valid JSON" and "not a
      // list" tell whoever reads the log what actually happened. Aggregating
      // them into a bare count would throw that away, so the specific reason
      // is carried through and only prefixed with scope when several keys
      // failed at once.
      final detail = details.length == 1
          ? details.single
          : '${details.length} stored queues could not be read in full. '
              '${details.join(' ')}';

      _lastLoadIssue = WsOutboxLoadIssue(
        quarantinePath: quarantined.isEmpty
            ? quarantineKey
            : '${quarantined.first}.corrupt',
        salvaged: items.length,
        // Any uncountable loss makes the TOTAL uncountable: a real count from
        // one key cannot describe a total that includes an unknown from
        // another. Understating loss is the failure this sentinel prevents.
        unrecoverable: uncountable ? -1 : counted,
        detail: detail,
      );
    }

    return items;
  }

  /// Later status wins, and `synced` always wins because it is terminal and
  /// carries the documentId. Among unsynced records the more recently attempted
  /// one is kept, which resolves retry (pending) beating an older failed copy.
  void _mergeInto(
    Map<String, Map<String, dynamic>> into,
    Map<String, dynamic> item,
  ) {
    // Dedupe ONLY on a real clientUuid. A record without one has no identity to
    // match on, so it is kept under a private key instead of being folded in.
    // Interpolating a missing value gives the string "null" for every such
    // record, which would make them all collide and silently eat one another —
    // deduplication turning into data loss, which is the opposite of the point.
    // '#' cannot occur in a UUID (hex digits and dashes only), so an
    // unidentified record can never collide with a real clientUuid, and the
    // index keeps each one distinct from its unidentified neighbours. These
    // keys are internal to this merge and never leave the method.
    final raw = item['clientUuid'];
    if (raw is! String || raw.isEmpty) {
      into['unidentified#${into.length}'] = item;
      return;
    }

    final existing = into[raw];
    if (existing == null) {
      into[raw] = item;
      return;
    }
    into[raw] = _preferred(existing, item);
  }

  Map<String, dynamic> _preferred(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    if (a['status'] == 'synced' && b['status'] != 'synced') return a;
    if (b['status'] == 'synced' && a['status'] != 'synced') return b;

    DateTime when(Map<String, dynamic> m) =>
        DateTime.tryParse('${m['lastAttemptAt'] ?? ''}') ??
        DateTime.tryParse('${m['createdAt'] ?? ''}') ??
        DateTime.fromMillisecondsSinceEpoch(0);

    final winner = when(b).isAfter(when(a)) ? b : a;
    // Attempt counters are the union of what every instance observed.
    int biggest(String field) {
      final x = (a[field] as num?)?.toInt() ?? 0;
      final y = (b[field] as num?)?.toInt() ?? 0;
      return x > y ? x : y;
    }

    return {
      ...winner,
      'attempts': biggest('attempts'),
      'budgetedAttempts': biggest('budgetedAttempts'),
    };
  }

  Future<_KeyRead> _readKey(String key) async {
    final raw = await kv.read(key);
    if (raw == null || raw.isEmpty) return const _KeyRead([], 0, false, null);

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      await kv.write('$key.corrupt', raw);
      // -1, not 0. Nothing parsed, so there is no structure left to walk and
      // the number of lost records genuinely cannot be counted. Reporting 0
      // would read as "nothing was lost".
      return const _KeyRead([], -1, true,
          'The stored queue was not valid JSON and could not be read. It has '
          'been set aside rather than deleted.');
    }
    if (decoded is! List) {
      await kv.write('$key.corrupt', raw);
      return const _KeyRead([], -1, true,
          'The stored queue was valid JSON but not a list of records, so no '
          'queue could be recovered from it. It has been set aside rather '
          'than deleted.');
    }

    final items = <Map<String, dynamic>>[];
    var lost = 0;
    for (final entry in decoded) {
      if (entry is Map) {
        items.add(Map<String, dynamic>.from(entry));
      } else {
        lost++;
      }
    }
    if (lost == 0) return _KeyRead(items, 0, false, null);

    // The list itself parsed, so the wreckage CAN be walked and the count is
    // real rather than the sentinel.
    await kv.write('$key.corrupt', raw);
    return _KeyRead(
      items,
      lost,
      true,
      '$lost queued record(s) were not readable and have been set aside. '
      '${items.length} recovered.',
    );
  }

  /// ONLY this instance's key is ever written. This single line is the fix.
  @override
  Future<void> save(List<Map<String, dynamic>> items) =>
      kv.write(instanceKey, jsonEncode(items));

  @override
  Future<void> clear() => kv.remove(instanceKey);

  /// Removes instance keys that are finished with.
  ///
  /// A key qualifies ONLY when every record in it is `synced` AND every record
  /// is older than [keepSyncedFor]. A key holding anything pending, syncing or
  /// failed is never touched, and neither is this instance's own key.
  ///
  /// Safe even against a live instance: deleting its key loses nothing, because
  /// its next save() rewrites the whole snapshot. And an abandoned tab's pending
  /// items are still read, merged and drained by whoever is live — they end up
  /// synced in the live key, at which point the stale key ages out.
  @override
  Future<int> collectGarbage(Duration keepSyncedFor) async {
    final cutoff = DateTime.now().subtract(keepSyncedFor);
    var removed = 0;

    for (final key in (await kv.keys())
        .where((k) => k.startsWith(instancePrefix) && !k.endsWith('.corrupt'))) {
      if (key == instanceKey) continue;

      final r = await _readKey(key);
      if (r.quarantined) continue;
      if (r.items.isEmpty) {
        await kv.remove(key);
        removed++;
        continue;
      }

      final disposable = r.items.every((m) {
        if (m['status'] != 'synced') return false;
        final t = DateTime.tryParse('${m['syncedAt'] ?? m['createdAt'] ?? ''}');
        return t != null && t.isBefore(cutoff);
      });
      if (disposable) {
        await kv.remove(key);
        removed++;
      }
    }
    return removed;
  }
}

/// The outcome of reading ONE key. Per-key rather than per-store, because a
/// single unreadable key must not cost the others.
class _KeyRead {
  final List<Map<String, dynamic>> items;

  /// Records lost from this key. `-1` is the sentinel for "lost an unknown
  /// number" — see [_readKey]. Never sum these; check for the sentinel first.
  final int lost;
  final bool quarantined;

  /// What went wrong, in words, or null when nothing did.
  final String? detail;

  const _KeyRead(this.items, this.lost, this.quarantined, this.detail);
}
