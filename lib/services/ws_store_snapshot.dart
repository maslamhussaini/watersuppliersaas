// =============================================================================
// lib/services/ws_store_snapshot.dart
// Which branch this device is working in, remembered across a cold start.
//
// ─── THE BLOCKER THIS EXISTS FOR ─────────────────────────────────────────────
//
// delivery_screen._save() refuses to record anything without a store:
//
//     final storeId = WsStoreService.currentStoreId;
//     if (storeId == null) {
//       throw StateError('No store selected — cannot record a delivery.');
//     }
//
// That check is right — a document with no store falls back to the
// organization default on the server, which is correct for a single-branch
// business and wrong for everyone else.
//
// But WsStoreService._selected is a static in-memory field, populated only by
// load(), which calls the ws_my_stores RPC. On a cold OFFLINE start it is null,
// so Save throws before the delivery ever reaches the outbox. Caching customers
// and products would not have helped: this fails first, inside _save itself.
//
// ─── WHY THE STORE LIST IS STORED, NOT JUST THE ID ───────────────────────────
//
// select() refuses any store the server did not offer, isMultiStore decides
// whether a picker appears at all, and currentStore resolves the name. Keeping
// only the selected id would restore a number that select() would then reject
// and the picker could not describe.
//
// ─── WHAT THIS IS NOT ────────────────────────────────────────────────────────
//
// NOT authorization. ws_my_stores applies ws.can_access_store() server-side and
// remains the only list worth trusting; this replays that server answer, it
// does not compute one. RLS is untouched, and ws.resolve_store still raises
// 22023 for a store outside the caller's organization — so a tampered snapshot
// buys a rejected delivery, not a cross-tenant write.
//
// NOT shared. Bound to the authenticated uid AND the organization, following
// exactly the rule WsSessionSnapshot.readFor already applies: two drivers on
// one tablet must never inherit each other's branch.
//
// NOT authoritative. Whenever ws_my_stores answers, the server wins and this is
// overwritten.
//
// Reuses the existing WsKeyValueStore seam — the same abstraction behind the
// outbox, What's New, the registration attempt and the session snapshot. No new
// storage mechanism and no new dependency.
// =============================================================================

import 'dart:convert';

import 'storage/ws_key_value_store.dart';
import 'store_service.dart';

/// The branches this user may work in, and which one is selected.
class WsStoreSnapshot {
  /// WHOSE snapshot this is. Checked against the live session before use.
  final String authUserId;

  /// WHICH ORGANIZATION. A user can belong to several; branches from one must
  /// never be offered while another is active.
  final int orgId;

  /// The rows as ws_my_stores returned them, so they rebuild through
  /// WsStore.fromJson — the same parser the online path uses, rather than a
  /// second one that could drift from it.
  final List<Map<String, dynamic>> stores;

  final int? selectedStoreId;
  final DateTime savedAt;

  const WsStoreSnapshot({
    required this.authUserId,
    required this.orgId,
    required this.stores,
    required this.selectedStoreId,
    required this.savedAt,
  });

  factory WsStoreSnapshot.of({
    required String authUserId,
    required int orgId,
    required List<WsStore> stores,
    required int? selectedStoreId,
    DateTime? at,
  }) =>
      WsStoreSnapshot(
        authUserId: authUserId,
        orgId: orgId,
        stores: [
          for (final s in stores)
            {
              'storeid': s.storeId,
              'storecode': s.storeCode,
              'storename': s.storeName,
              'isdefault': s.isDefault,
            },
        ],
        selectedStoreId: selectedStoreId,
        savedAt: at ?? DateTime.now(),
      );

  /// Rebuilt stores, skipping any row that will not parse rather than failing
  /// the whole snapshot — one bad row must not cost a driver the other branches.
  List<WsStore> get storeList {
    final out = <WsStore>[];
    for (final row in stores) {
      try {
        out.add(WsStore.fromJson(row));
      } catch (_) {
        // Unreadable row, skipped.
      }
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'authUserId': authUserId,
        'orgId': orgId,
        'stores': stores,
        'selectedStoreId': selectedStoreId,
        'savedAt': savedAt.toIso8601String(),
      };

  /// Throws [FormatException] on anything it cannot trust. Strict on purpose: a
  /// half-understood snapshot would stamp documents with a branch nobody chose.
  factory WsStoreSnapshot.fromJson(Map<String, dynamic> j) {
    final uid = j['authUserId'];
    if (uid is! String || uid.isEmpty) {
      throw const FormatException('store snapshot has no authUserId');
    }

    final orgId = (j['orgId'] as num?)?.toInt();
    if (orgId == null) {
      throw const FormatException('store snapshot has no orgId');
    }

    final raw = j['stores'];
    if (raw is! List) {
      throw const FormatException('store snapshot has no stores');
    }

    final saved = DateTime.tryParse('${j['savedAt']}');
    if (saved == null) {
      throw const FormatException('store snapshot has no savedAt');
    }

    return WsStoreSnapshot(
      authUserId: uid,
      orgId: orgId,
      stores: [
        for (final r in raw)
          if (r is Map) Map<String, dynamic>.from(r),
      ],
      selectedStoreId: (j['selectedStoreId'] as num?)?.toInt(),
      savedAt: saved,
    );
  }
}

/// Reads and writes the snapshot. One key, last-write-wins.
class WsStoreSnapshotStore {
  static const storageKey = 'store.snapshot';

  final WsKeyValueStore kv;

  const WsStoreSnapshotStore(this.kv);

  /// The snapshot for [uid] within [orgId], or null.
  ///
  /// Returns null — never throws — for every failure: nothing stored, stored
  /// for another user or another organization, or unreadable. The caller's
  /// response to all four is the same: behave exactly as before, with no store.
  Future<WsStoreSnapshot?> readFor(String uid, int orgId) async {
    final snap = await _read();
    if (snap == null) return null;

    // THE SHARED-DEVICE RULE, and the multi-tenant rule, in one place.
    if (snap.authUserId != uid) return null;
    if (snap.orgId != orgId) return null;

    // A snapshot with no readable branch cannot satisfy select(), so it is
    // indistinguishable from having none.
    if (snap.storeList.isEmpty) return null;

    return snap;
  }

  Future<WsStoreSnapshot?> _read() async {
    // The read is INSIDE the try, not outside it.
    //
    // Caught by its own test: with the decode alone guarded, a storage backend
    // that throws — a full quota, a browser with storage disabled — propagated
    // straight out of readFor and broke the "never throws" contract two lines
    // above. Unreadable storage and unreadable content are the same answer to
    // the caller: there is no snapshot.
    try {
      final raw = await kv.read(storageKey);
      if (raw == null || raw.isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return WsStoreSnapshot.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // Corrupt, an older shape, or storage that will not answer. Unusable
      // rather than fatal: the online path still works and will overwrite it.
      return null;
    }
  }

  Future<void> write(WsStoreSnapshot snapshot) =>
      kv.write(storageKey, jsonEncode(snapshot.toJson()));

  /// Called on sign-out so a shared device does not keep the last driver's
  /// branch selected for the next one.
  Future<void> clear() => kv.remove(storageKey);
}
