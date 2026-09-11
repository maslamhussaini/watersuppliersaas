// =============================================================================
// lib/services/cache/ws_master_cache.dart
// Staff and products, kept on the device so New Delivery can open offline.
//
// ─── SCOPE ───────────────────────────────────────────────────────────────────
//
// Phase B2 ONLY: staff and products. Customers are B3 and are deliberately not
// here — they need sharding and a ceiling, and mixing them in would make this
// file the thing it exists to avoid.
//
// Areas are NOT cached at all: New Delivery uses areaName only as picker
// subtitle text, which travels inside the customer projection. A separate area
// cache would be work with no consumer.
//
// Pricing is NOT cached. ws_resolve_price sees customer-group and effective-date
// rules no client projection can reproduce, and the server prices the line at
// post time regardless. Offline the screen keeps its existing effectiveRate
// approximation — unchanged by this file.
//
// ─── WHAT THIS IS ────────────────────────────────────────────────────────────
//
// A fallback, never a preferred source. Every read goes to the server first;
// the cache answers only when the server could not. Whenever the server
// answers, it overwrites what is stored.
//
// ─── OWNERSHIP ───────────────────────────────────────────────────────────────
//
// Every entry is bound to the authenticated uid AND the organization, following
// exactly the rule WsSessionSnapshot and WsStoreSnapshot already apply. Two
// drivers on one tablet must never see each other's staff list, and a user in
// several organizations must never see one org's products while another is
// active.
//
// Reuses the existing WsKeyValueStore seam. No new dependency, no new storage
// mechanism.
// =============================================================================

import 'dart:convert';

import '../storage/ws_key_value_store.dart';
import '../storage/ws_kv_default.dart';
import 'ws_customer_cache.dart';

/// Rows plus who they belong to and when they were taken.
///
/// One shape for both caches: staff and products differ only in their payload,
/// so a second envelope would be duplication. [meta] carries the small extras a
/// particular cache needs — today only the default product id.
class WsCacheEnvelope {
  final String authUserId;
  final int orgId;
  final DateTime cachedAt;
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic> meta;

  const WsCacheEnvelope({
    required this.authUserId,
    required this.orgId,
    required this.cachedAt,
    required this.rows,
    this.meta = const {},
  });

  Map<String, dynamic> toJson() => {
        'authUserId': authUserId,
        'orgId': orgId,
        'cachedAt': cachedAt.toIso8601String(),
        'rows': rows,
        'meta': meta,
      };

  /// Throws [FormatException] on anything it cannot trust. Strict on purpose:
  /// a half-understood cache would populate a picker with nonsense.
  factory WsCacheEnvelope.fromJson(Map<String, dynamic> j) {
    final uid = j['authUserId'];
    if (uid is! String || uid.isEmpty) {
      throw const FormatException('cache entry has no authUserId');
    }
    final orgId = (j['orgId'] as num?)?.toInt();
    if (orgId == null) {
      throw const FormatException('cache entry has no orgId');
    }
    final cachedAt = DateTime.tryParse('${j['cachedAt']}');
    if (cachedAt == null) {
      throw const FormatException('cache entry has no cachedAt');
    }
    final raw = j['rows'];
    if (raw is! List) {
      throw const FormatException('cache entry has no rows');
    }

    return WsCacheEnvelope(
      authUserId: uid,
      orgId: orgId,
      cachedAt: cachedAt,
      // One unreadable row must not cost the rest — the same per-row isolation
      // the store snapshot applies to branches.
      rows: [
        for (final r in raw)
          if (r is Map) Map<String, dynamic>.from(r),
      ],
      meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }
}

/// Staff and product caches.
class WsMasterCache {
  WsMasterCache._();

  static const staffKey = 'cache.staff';
  static const productsKey = 'cache.products';

  /// After this, a refresh is worth making. Not an expiry: a stale cache is
  /// still used offline, because stale data beats none.
  static const staleAfter = Duration(minutes: 15);

  /// Injectable so tests drive both halves without a platform channel, and so
  /// storage can be made to fail on demand.
  static Future<WsKeyValueStore> Function() storage =
      wsOpenDefaultKeyValueStore;

  // ── Writing ───────────────────────────────────────────────────────────────

  /// Best-effort. A cache write must NEVER fail an operation that otherwise
  /// worked — the caller already has its answer from the server.
  static Future<void> write(
    String key, {
    required String uid,
    required int orgId,
    required List<Map<String, dynamic>> rows,
    Map<String, dynamic> meta = const {},
    DateTime? at,
  }) async {
    try {
      final kv = await storage();
      await kv.write(
        key,
        jsonEncode(WsCacheEnvelope(
          authUserId: uid,
          orgId: orgId,
          cachedAt: at ?? DateTime.now(),
          rows: rows,
          meta: meta,
        ).toJson()),
      );
    } catch (_) {
      // Quota exhausted, storage disabled, or a platform refusal. The outbox
      // shares this storage, and losing a delivery to a cache write would be
      // an appalling trade.
    }
  }

  // ── Reading ───────────────────────────────────────────────────────────────

  /// The entry for [uid] within [orgId], or null.
  ///
  /// Never throws. Nothing stored, stored for someone else, stored for another
  /// organization, or unreadable all mean the same thing to the caller: there
  /// is no cache, behave as before.
  static Future<WsCacheEnvelope?> read(
    String key, {
    required String uid,
    required int orgId,
  }) async {
    try {
      final kv = await storage();
      final raw = await kv.read(key);
      if (raw == null || raw.isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;

      final env = WsCacheEnvelope.fromJson(Map<String, dynamic>.from(decoded));

      // THE SHARED-DEVICE AND MULTI-TENANT RULES, in one place.
      if (env.authUserId != uid) return null;
      if (env.orgId != orgId) return null;

      return env;
    } catch (_) {
      return null;
    }
  }

  /// True when [key] is missing or older than [staleAfter] for this user/org.
  ///
  /// Drives the refresh trigger. A missing entry counts as stale, which is what
  /// makes the first online refresh happen at all.
  static Future<bool> isStale(
    String key, {
    required String uid,
    required int orgId,
    DateTime? now,
  }) async {
    final env = await read(key, uid: uid, orgId: orgId);
    if (env == null) return true;
    return (now ?? DateTime.now()).difference(env.cachedAt) > staleAfter;
  }

  // ── Clearing ──────────────────────────────────────────────────────────────

  /// Called on sign-out. A shared device must not keep one driver's staff list
  /// and product prices for the next.
  static Future<void> clear() async {
    try {
      final kv = await storage();
      await kv.remove(staffKey);
      await kv.remove(productsKey);
      // Customers live in their own sharded cache with a manifest; clearing it
      // is that file's job, not a list of keys duplicated here.
      await WsCustomerCache.clear();
    } catch (_) {
      // Best-effort, for the same reason as write().
    }
  }
}
