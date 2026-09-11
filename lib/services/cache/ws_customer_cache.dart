// =============================================================================
// lib/services/cache/ws_customer_cache.dart
// Customers on the device, so New Delivery can be completed without a network.
//
// ─── WHY THIS IS NOT JUST ANOTHER WsMasterCache ENTRY ────────────────────────
//
// Staff and products are a handful of rows and fit in one key. Customers are
// thousands — the lookup field exists precisely because a CSV import produces
// them — so this needs sharding, a ceiling, and above all an ALL-OR-NOTHING
// read.
//
// ─── THE FAILURE THIS DESIGN EXISTS TO PREVENT ───────────────────────────────
//
// A PARTIAL CACHE READ AS COMPLETE.
//
// If a quota error lands at shard 31 of 50, a naive reader serves two thirds of
// the customers and a driver concludes the missing one does not exist. That is
// far worse than an empty field, because an empty field is obviously broken and
// a short list is not.
//
// So the cache is transaction-like from the reader's point of view:
//
//   1. write every shard of a NEW generation
//   2. write the manifest last, naming that generation and its shard count
//   3. only then delete the previous generation's shards
//
// The manifest is the commit. A reader that finds no manifest, a manifest it
// cannot parse, or a shard count that disagrees with the shards actually
// present treats the WHOLE cache as absent. There is no partial answer.
//
// Generations are why a refresh cannot damage what is already there: the new
// shards are written under new keys, so a failure part-way through leaves the
// old manifest still pointing at the old, complete generation.
//
// ─── OWNERSHIP ───────────────────────────────────────────────────────────────
//
// Every shard and the manifest carry authUserId and orgId. A mismatch on either
// means "no cache", the same rule WsSessionSnapshot, WsStoreSnapshot and
// WsMasterCache already apply.
//
// ─── SEARCH ──────────────────────────────────────────────────────────────────
//
// This file deliberately does NOT gate, sanitise, or build WsLookupResult. Those
// live in lookup_service.dart and are reused from there, because two sanitisers
// drift and drift here means offline finds a customer online does not. This
// receives an already-sanitised query and returns rows; the caller shapes them.
// =============================================================================

import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;

import '../storage/ws_key_value_store.dart';
import '../storage/ws_kv_default.dart';

/// The ten fields New Delivery and the picker actually need.
///
/// Not WsCustomer: that carries nineteen, and the four the delivery screen
/// reads plus the three the picker displays are all that justify the storage.
class WsCustomerRow {
  final int customerId;
  final String customerName;
  final String? customerCode;
  final String? phone;
  final int? storeId;
  final int? areaId;
  final String? areaName;
  final double? areaRate;
  final double? rateOverride;
  final int bottleBalance;

  const WsCustomerRow({
    required this.customerId,
    required this.customerName,
    this.customerCode,
    this.phone,
    this.storeId,
    this.areaId,
    this.areaName,
    this.areaRate,
    this.rateOverride,
    this.bottleBalance = 0,
  });

  /// The same precedence WsCustomer.effectiveRate applies. Approximate by
  /// design — it cannot see customer-group or effective-date pricing, which is
  /// why the server prices the line authoritatively at post time.
  double get effectiveRate => rateOverride ?? areaRate ?? 0;

  static double? _d(Object? v) =>
      v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
  static int? _i(Object? v) =>
      v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));

  /// Reads the REAL column names, so a cached row and a server row agree.
  ///
  /// The area rate is `rateperbottle` — ws_tblareas.rateperbottle, embedded by
  /// populateCustomerCache and flattened onto the row. There has never been a
  /// column called `arearate`; that is only the Dart field name, and reading it
  /// here is what made every cached rate null until the browser surfaced it.
  /// WsCustomer.fromJson has always read `rateperbottle` for the same field.
  static WsCustomerRow? fromJson(Map<String, dynamic> j) {
    final id = _i(j['customerid']);
    if (id == null) return null; // A row with no id cannot be selected.
    return WsCustomerRow(
      customerId: id,
      customerName: '${j['customername'] ?? ''}',
      customerCode: j['customercode'] == null ? null : '${j['customercode']}',
      phone: j['phone'] == null ? null : '${j['phone']}',
      // ws_tblcustomers.storeid, added by migration 015. The balance view does
      // not carry it, which is why the population source is the table.
      storeId: _i(j['storeid']),
      areaId: _i(j['areaid']),
      areaName: j['areaname'] == null ? null : '${j['areaname']}',
      areaRate: _d(j['rateperbottle']),
      rateOverride: _d(j['rateoverride']),
      bottleBalance: _i(j['bottlebalance']) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'customerid': customerId,
        'customername': customerName,
        'customercode': customerCode,
        'phone': phone,
        'storeid': storeId,
        'areaid': areaId,
        'areaname': areaName,
        'rateperbottle': areaRate,
        'rateoverride': rateOverride,
        'bottlebalance': bottleBalance,
      };
}

/// Why offline customer search is not available, or null when it is.
///
/// Surfaced so the degradation is never silent: a driver who believes offline
/// search works and finds nothing will conclude the customer does not exist.
final ValueNotifier<String?> wsOfflineCustomerSearchUnavailable =
    ValueNotifier(null);

class WsCustomerCache {
  WsCustomerCache._();

  static const manifestKey = 'cache.customers.manifest';
  static const shardPrefix = 'cache.customers.shard.';

  /// Records per shard. ~75–90 KB per key at ten fields.
  static const shardSize = 500;

  /// Above this the cache is not built at all. 25,000 x ~180 bytes is roughly
  /// 4.5 MB, and localStorage gives about 5 MB TOTAL — shared with the outbox,
  /// which must never be starved by a cache.
  static const maxCustomers = 25000;

  /// Customers are the expensive refresh — a full projection download — so this
  /// is hours where staff and products are minutes.
  static const staleAfter = Duration(hours: 6);

  /// ─── IN-MEMORY MEMO ───────────────────────────────────────────────────
  ///
  /// The PARSED rows for one identity + generation. Holds only what load()
  /// already returns, so it changes no format and no rule — it removes a
  /// repeated parse, nothing else.
  ///
  /// Deliberately NOT a map keyed by identity: one entry means signing in as
  /// another driver evicts the previous one rather than accumulating a second
  /// tenant's customers in memory on a shared tablet.
  static String? _memoIdentity;
  static List<WsCustomerRow>? _memoRows;

  static String _memoKey(String uid, int orgId, int generation) =>
      '$uid|$orgId|$generation';

  /// Drops the memo. Called wherever the stored cache changes or goes away.
  ///
  /// Public because sign-out has to be able to reach it: WsMasterCache.clear()
  /// delegates here, and a shared device must not keep one driver's customers
  /// parsed in memory for the next. Also visible to tests.
  static void forgetMemo() {
    _memoIdentity = null;
    _memoRows = null;
  }

  /// Injectable for tests; storage failures are otherwise unprovokable.
  static Future<WsKeyValueStore> Function() storage =
      wsOpenDefaultKeyValueStore;

  // ── Manifest ──────────────────────────────────────────────────────────────

  static Map<String, dynamic>? _parseManifest(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final m = Map<String, dynamic>.from(decoded);
      if (m['authUserId'] is! String) return null;
      if ((m['orgId'] as num?) == null) return null;
      if ((m['generation'] as num?) == null) return null;
      if ((m['shardCount'] as num?) == null) return null;
      if (DateTime.tryParse('${m['cachedAt']}') == null) return null;
      return m;
    } catch (_) {
      return null;
    }
  }

  static String _shardKey(int generation, int index) =>
      '$shardPrefix$generation.$index';

  // ── Reading ───────────────────────────────────────────────────────────────

  /// Every cached customer, or null when there is no COMPLETE cache.
  ///
  /// Null covers all of: nothing stored, no manifest, an unparseable manifest,
  /// a manifest for another user or organization, a missing shard, a corrupt
  /// shard, and a shard count that disagrees with the manifest. The caller's
  /// response to every one of them is the same — behave as online-only.
  static Future<List<WsCustomerRow>?> load({
    required String uid,
    required int orgId,
  }) async {
    try {
      final kv = await storage();
      final m = _parseManifest(await kv.read(manifestKey));
      if (m == null) return null;

      // OWNERSHIP, before anything is read.
      if (m['authUserId'] != uid) return null;
      if ((m['orgId'] as num).toInt() != orgId) return null;

      final generation = (m['generation'] as num).toInt();
      final shardCount = (m['shardCount'] as num).toInt();
      if (shardCount < 0) return null;

      // ─── THE PARSED ROWS, REMEMBERED ──────────────────────────────────────
      //
      // Everything above this line still runs on EVERY call: the manifest is
      // re-read and the ownership checks are re-applied against the uid and
      // orgId the caller passed. Only the shard reading and JSON parsing are
      // skipped. The manifest stays the single authority on whether a cache
      // exists and whose it is — the memo can never resurrect a cache the
      // manifest says is gone, nor hand one user's rows to another.
      //
      // WHY THIS EXISTS: load() is called once per keystroke by the offline
      // customer search, and again on selection. At the 25,000 ceiling each
      // call meant 50 shard reads, 50 jsonDecodes and 25,000 object
      // constructions — repeated for every letter typed.
      //
      // The GENERATION is the key, and it is not a new concept: replace()
      // already writes each snapshot under a fresh generation and commits the
      // manifest last. So a new snapshot changes the key by construction, and
      // a stale memo cannot survive a write even if someone forgets to clear
      // it. forgetMemo() on replace/clear is belt as well as braces.
      final key = _memoKey(uid, orgId, generation);
      final memo = _memoRows;
      if (memo != null && _memoIdentity == key) {
        return memo;
      }

      final rows = <WsCustomerRow>[];
      for (var i = 0; i < shardCount; i++) {
        final raw = await kv.read(_shardKey(generation, i));
        // A MISSING SHARD IS NOT A SMALLER CACHE. It is no cache.
        if (raw == null || raw.isEmpty) return null;

        final decoded = jsonDecode(raw);
        if (decoded is! List) return null;

        for (final r in decoded) {
          if (r is! Map) return null; // Corrupt shard, not a skippable row.
          final row = WsCustomerRow.fromJson(Map<String, dynamic>.from(r));
          if (row == null) return null;
          rows.add(row);
        }
      }

      final expected = (m['rowCount'] as num?)?.toInt();
      if (expected != null && expected != rows.length) return null;

      // Remembered only AFTER every completeness check has passed, so a
      // partial or corrupt read can never be memoised as a good cache.
      //
      // Unmodifiable: callers get the same List instance on every hit, and one
      // caller sorting or trimming it in place would silently corrupt the next
      // reader's view. searchIn already copies before sorting; this makes that
      // a guarantee rather than a convention.
      final result = List<WsCustomerRow>.unmodifiable(rows);
      _memoIdentity = key;
      _memoRows = result;
      return result;
    } catch (e) {
      debugPrint('customer cache: unreadable, treating as absent — $e');
      return null;
    }
  }

  /// True when there is no complete cache, or it is older than [staleAfter].
  static Future<bool> isStale({
    required String uid,
    required int orgId,
    DateTime? now,
  }) async {
    try {
      final kv = await storage();
      final m = _parseManifest(await kv.read(manifestKey));
      if (m == null) return true;
      if (m['authUserId'] != uid) return true;
      if ((m['orgId'] as num).toInt() != orgId) return true;

      final at = DateTime.parse('${m['cachedAt']}');
      return (now ?? DateTime.now()).difference(at) > staleAfter;
    } catch (_) {
      return true;
    }
  }

  // ── Writing ───────────────────────────────────────────────────────────────

  /// Replaces the cache with [rows], or refuses and leaves the old one intact.
  ///
  /// Returns true only when a complete new generation was committed.
  ///
  /// THE OLD CACHE IS NEVER DESTROYED BEFORE THE NEW ONE IS READY. New shards
  /// go under a new generation, the manifest is rewritten last, and only then
  /// are the previous generation's shards removed. A quota failure part-way
  /// through leaves the old manifest still pointing at a complete generation.
  static Future<bool> replace({
    required String uid,
    required int orgId,
    required List<Map<String, dynamic>> rows,
    DateTime? at,
  }) async {
    // The stored cache is about to change under every reader. The new
    // generation would key the memo out anyway, but this does not rely on
    // that: an abandoned write must not leave a memo describing a snapshot
    // that was never committed.
    forgetMemo();

    // THE CEILING. Never a partial cache: the first 25,000 of 40,000 customers
    // would make offline search confidently wrong.
    if (rows.length > maxCustomers) {
      await clear();
      wsOfflineCustomerSearchUnavailable.value =
          'This organization has more than $maxCustomers customers, so customer '
          'search is online only.';
      debugPrint('customer cache: ${rows.length} customers exceeds the '
          '$maxCustomers ceiling — not cached');
      return false;
    }

    final kv = await storage();
    final previous = _parseManifest(await kv.read(manifestKey));
    final previousGen = (previous?['generation'] as num?)?.toInt();

    // Monotonic, and never colliding with the generation still in use.
    var generation = DateTime.now().millisecondsSinceEpoch;
    if (previousGen != null && generation <= previousGen) {
      generation = previousGen + 1;
    }

    final written = <String>[];
    try {
      var index = 0;
      for (var start = 0; start < rows.length; start += shardSize) {
        final end =
            (start + shardSize) > rows.length ? rows.length : start + shardSize;
        final key = _shardKey(generation, index);
        await kv.write(key, jsonEncode(rows.sublist(start, end)));
        written.add(key);
        index++;
      }

      // THE COMMIT. Until this line lands, the old cache is what readers see.
      await kv.write(
        manifestKey,
        jsonEncode({
          'authUserId': uid,
          'orgId': orgId,
          'generation': generation,
          'shardCount': index,
          'rowCount': rows.length,
          'cachedAt': (at ?? DateTime.now()).toIso8601String(),
        }),
      );
    } catch (e) {
      // QUOTA, OR STORAGE REFUSING. Roll the new generation back and leave the
      // old cache exactly as it was — a good stale cache beats none.
      for (final key in written) {
        try {
          await kv.remove(key);
        } catch (_) {
          // Best effort; an orphan shard is unreachable without a manifest
          // naming its generation, so it is inert.
        }
      }
      wsOfflineCustomerSearchUnavailable.value =
          'Customer data could not be saved for offline use, so customer '
          'search is online only.';
      debugPrint('customer cache: population abandoned — $e');
      return false;
    }

    // Only now is the previous generation unreachable, so it can go.
    if (previousGen != null && previousGen != generation) {
      await _removeGeneration(kv, previousGen);
    }

    wsOfflineCustomerSearchUnavailable.value = null;
    return true;
  }

  static Future<void> _removeGeneration(WsKeyValueStore kv, int generation) async {
    try {
      final prefix = '$shardPrefix$generation.';
      for (final key in await kv.keys()) {
        if (key.startsWith(prefix)) await kv.remove(key);
      }
    } catch (e) {
      debugPrint('customer cache: could not remove generation $generation — $e');
    }
  }

  /// Removes the manifest and every shard of every generation. Sign-out.
  ///
  /// The manifest goes FIRST: from that moment there is no readable cache, even
  /// if removing the shards is interrupted.
  static Future<void> clear() async {
    // FIRST, and outside the try: if removing the keys throws half way, the
    // in-memory copy must still be gone. A memo that outlived the storage it
    // describes is the one failure mode that could serve a signed-out user's
    // customers.
    forgetMemo();
    try {
      final kv = await storage();
      await kv.remove(manifestKey);
      for (final key in await kv.keys()) {
        if (key.startsWith(shardPrefix)) await kv.remove(key);
      }
    } catch (e) {
      debugPrint('customer cache: could not clear — $e');
    }
  }

  // ── Searching ─────────────────────────────────────────────────────────────

  /// Rows matching [sanitisedQuery], in the order and quantity the server would
  /// have returned.
  ///
  /// [sanitisedQuery] has ALREADY been through wsSanitiseSearch and wsSearchable
  /// in lookup_service.dart. This does not re-implement either: one sanitiser,
  /// one gate, so offline and online cannot disagree about what a query means.
  ///
  /// ─── ORDER IS DESCENDING, AND ORDER DECIDES MEMBERSHIP ───────────────────
  ///
  /// The online query is `.order('customername')`, and in postgrest 2.8.0 that
  /// method signs as `order(String column, {bool ascending = false, ...})` —
  /// the default is DESCENDING, not ascending as the SQL keyword would suggest.
  /// A live request confirms it: `order=customername.desc.nullslast`.
  ///
  /// This sorted ascending and was wrong. The correction is not cosmetic:
  /// BECAUSE THE ONLINE QUERY APPLIES limit(20), reversing the sort changes
  /// WHICH ROWS COME BACK, not merely their order. With more than twenty
  /// matches, ascending returns the first twenty alphabetically and descending
  /// the last twenty — two disjoint sets. A driver would find a customer online
  /// and not offline.
  ///
  /// An earlier version of this comment claimed ordering could only affect
  /// order and never membership. That was wrong, and it is corrected here
  /// rather than quietly deleted.
  ///
  /// ─── FIDELITY, STATED HONESTLY ───────────────────────────────────────────
  ///
  /// `ilike '%q%'` is matched with a lowercased `contains`, and the sort with a
  /// case-insensitive compare. Two known divergences remain:
  ///
  ///   · Postgres orders by the column's collation; Dart compares UTF-16 code
  ///     units. Case-insensitive comparison brings this close to the usual
  ///     en_US.UTF-8 behaviour but not to every locale's.
  ///   · `ilike` and toLowerCase() disagree on a few non-ASCII cases, Turkish
  ///     dotless i being the standard example.
  ///
  /// Both are narrow, but by the same argument as above they can shift a row
  /// across the twentieth position and therefore across the limit. They are
  /// small in practice, not harmless in principle.
  static List<WsCustomerRow> searchIn(
    List<WsCustomerRow> rows,
    String sanitisedQuery, {
    int? storeId,
    bool includeAllStores = false,
    bool isMultiStore = false,
    required int limit,
  }) {
    final q = sanitisedQuery.toLowerCase();

    bool matches(WsCustomerRow c) {
      // The same three columns the server ORs over, and only those.
      if (c.customerName.toLowerCase().contains(q)) return true;
      if ((c.phone ?? '').toLowerCase().contains(q)) return true;
      if ((c.customerCode ?? '').toLowerCase().contains(q)) return true;
      return false;
    }

    // The same three conditions as the online branch filter — omitting any of
    // them would show a driver customers from a branch they are not working in.
    final applyStore = !includeAllStores && storeId != null && isMultiStore;

    final out = rows
        .where((c) => matches(c) && (!applyStore || c.storeId == storeId))
        .toList()
      // DESCENDING — b before a. Matches order=customername.desc.nullslast.
      ..sort((a, b) =>
          b.customerName.toLowerCase().compareTo(a.customerName.toLowerCase()));

    return out.length <= limit ? out : out.sublist(0, limit);
  }
}
