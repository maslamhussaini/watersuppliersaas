// =============================================================================
// lib/services/store_service.dart
// Which branch the user is working in.
//
// ─── THIS IS A UI PREFERENCE, NOT A SECURITY BOUNDARY ────────────────────────
//
// The selected store decides what a NEW document is stamped with and what the
// lists are filtered to. It does not decide what the user is allowed to see —
// that is RLS, enforced by ws.can_access_store() in migration 015, and it holds
// whether or not this class is behaving.
//
// ─── AND IT IS NOT WHERE A QUEUED DOCUMENT'S STORE COMES FROM ────────────────
//
// A document takes its store at SAVE time, from here, once. After that the
// value lives in the outbox payload and nothing re-reads it:
//
//     select Store A → save → payload carries storeid=A → queued
//     → user switches to Store B → queue drains → posts to A
//
// If the sync path ever called currentStoreId, a driver who changed branch
// before a sync would silently move yesterday's deliveries. Nothing in
// ws_outbox_supabase.dart calls into this file, and it must stay that way.
// =============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../main.dart' show supabase, supabaseClientInitialized;
import 'storage/ws_key_value_store.dart';
import 'storage/ws_kv_default.dart';
import 'tenant_service.dart';
import 'ws_store_snapshot.dart';

class WsStore {
  final int storeId;
  final String storeCode;
  final String storeName;
  final bool isDefault;

  const WsStore({
    required this.storeId,
    required this.storeCode,
    required this.storeName,
    this.isDefault = false,
  });

  factory WsStore.fromJson(Map<String, dynamic> j) => WsStore(
        storeId: (j['storeid'] as num).toInt(),
        storeCode: '${j['storecode'] ?? ''}',
        storeName: '${j['storename'] ?? 'Store'}',
        isDefault: j['isdefault'] == true,
      );
}

class WsStoreService {
  WsStoreService._();

  static List<WsStore> _stores = const [];
  static int? _selected;

  /// The stores this user may work in. Empty until [load] has run.
  static List<WsStore> get stores => List.unmodifiable(_stores);

  /// True when the organization actually has more than one branch. A
  /// single-branch business should never be shown a picker.
  static bool get isMultiStore => _stores.length > 1;

  /// The store new documents are stamped with.
  ///
  /// Callers must treat a null return as "not ready yet" and not post — a
  /// document with no store would fall back to the organization default on the
  /// server, which is right for a single-branch org and wrong for everyone
  /// else.
  static int? get currentStoreId => _selected;

  static WsStore? get currentStore {
    for (final s in _stores) {
      if (s.storeId == _selected) return s;
    }
    return null;
  }

  /// Loads the permitted stores for the current organization.
  ///
  /// Uses ws_my_stores(), which applies ws.can_access_store() server-side, so
  /// the list is what the user may reach — not everything the organization
  /// owns filtered afterwards in Dart.
  static Future<List<WsStore>> load({bool force = false}) async {
    if (_stores.isNotEmpty && !force) return _stores;
    if (!supabaseClientInitialized) return _stores;

    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return _stores;

    // Object?, not List: the `rows is! List` guard below is pre-existing and
    // must keep working. Typing this as List would make that check dead code.
    final Object? rows;
    try {
      rows = await supabase.rpc('ws_my_stores', params: {'p_orgid': orgId});
    } catch (e) {
      // OFFLINE. Fall back to the branches the server last offered.
      //
      // Without this, _selected stays null on a cold offline start and
      // delivery_screen._save() throws "No store selected" before the delivery
      // reaches the outbox — the durable queue never gets a chance to do its
      // job. See ws_store_snapshot.dart.
      //
      // Only a THROW falls back. Every early return above is a real answer
      // ("already loaded", "no client", "no organization") and must not be
      // overridden by a snapshot.
      final restored = await _restoreFromSnapshot(orgId);
      if (restored) {
        debugPrint('stores: server unreachable, using saved branches — $e');
        return _stores;
      }
      rethrow;
    }

    if (rows is! List) return _stores;

    _stores = rows
        .cast<Map<String, dynamic>>()
        .map(WsStore.fromJson)
        .toList(growable: false);

    // Keep an existing choice if it is still permitted — losing the selected
    // branch on every refresh would be maddening — otherwise fall back to the
    // default store.
    final stillValid = _stores.any((s) => s.storeId == _selected);
    if (!stillValid) {
      _selected = _stores.isEmpty
          ? null
          : _stores
              .firstWhere((s) => s.isDefault, orElse: () => _stores.first)
              .storeId;
    }

    // THE SERVER ANSWERED, SO THE SERVER WINS. Overwrite whatever was saved.
    await _persistSnapshot(orgId);
    return _stores;
  }

  // ── Offline snapshot ──────────────────────────────────────────────────────
  //
  // Injectable so tests can drive both halves without a platform channel, and
  // so a test can make storage fail on demand — the one behaviour that cannot
  // be provoked otherwise.
  static Future<WsKeyValueStore> Function() snapshotStorage =
      wsOpenDefaultKeyValueStore;

  /// Best-effort. A storage failure must never fail a load that otherwise
  /// worked: the branches are in memory and usable for this session either way.
  static Future<void> _persistSnapshot(int orgId) async {
    try {
      final uid = supabase.auth.currentSession?.user.id;
      if (uid == null) return;
      await WsStoreSnapshotStore(await snapshotStorage()).write(
        WsStoreSnapshot.of(
          authUserId: uid,
          orgId: orgId,
          stores: _stores,
          selectedStoreId: _selected,
        ),
      );
    } catch (e) {
      debugPrint('stores: could not save the branch snapshot — $e');
    }
  }

  /// Repopulates [_stores] and [_selected] from the snapshot.
  ///
  /// Returns false — leaving state untouched — when there is nothing stored,
  /// when it belongs to another user or organization, or when it is unreadable.
  /// Never invents a branch.
  static Future<bool> _restoreFromSnapshot(int orgId) async {
    try {
      final uid = supabase.auth.currentSession?.user.id;
      // NO SESSION, NO RESTORE. The snapshot cannot create one, and without a
      // uid there is nothing to match it against.
      if (uid == null) return false;

      final snap =
          await WsStoreSnapshotStore(await snapshotStorage()).readFor(uid, orgId);
      if (snap == null) return false;

      final restored = snap.storeList;
      if (restored.isEmpty) return false;

      _stores = List.unmodifiable(restored);

      // Honour the saved choice only if it is still one of the saved branches,
      // mirroring the online rule above rather than trusting the stored id.
      final saved = snap.selectedStoreId;
      _selected = restored.any((s) => s.storeId == saved)
          ? saved
          : restored
              .firstWhere((s) => s.isDefault, orElse: () => restored.first)
              .storeId;
      return true;
    } catch (e) {
      debugPrint('stores: could not read the branch snapshot — $e');
      return false;
    }
  }

  /// Removes the saved branches. Called on sign-out.
  static Future<void> clearSnapshot() async {
    try {
      await WsStoreSnapshotStore(await snapshotStorage()).clear();
    } catch (e) {
      debugPrint('stores: could not clear the branch snapshot — $e');
    }
  }

  /// Switch branch. Refuses a store the server did not offer, because the only
  /// list worth trusting is the one RLS produced.
  static bool select(int storeId) {
    if (!_stores.any((s) => s.storeId == storeId)) return false;
    _selected = storeId;

    // Remember the choice, so a driver who picks a branch and then goes offline
    // still stamps documents with it after a reload. Fire and forget: the
    // selection has already taken effect in memory, and a storage failure must
    // not make the picker appear to have done nothing.
    unawaited(_persistSelection());
    return true;
  }

  static Future<void> _persistSelection() async {
    final orgId = await WsTenantService.currentOrgId;
    if (orgId != null) await _persistSnapshot(orgId);
  }

  /// Called when the organization changes, so one tenant's branches can never
  /// be offered while another is selected.
  static void reset() {
    _stores = const [];
    _selected = null;
  }
}
