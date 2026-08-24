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

import '../main.dart' show supabase, supabaseClientInitialized;
import 'tenant_service.dart';

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

    final rows = await supabase.rpc('ws_my_stores', params: {'p_orgid': orgId});
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
    return _stores;
  }

  /// Switch branch. Refuses a store the server did not offer, because the only
  /// list worth trusting is the one RLS produced.
  static bool select(int storeId) {
    if (!_stores.any((s) => s.storeId == storeId)) return false;
    _selected = storeId;
    return true;
  }

  /// Called when the organization changes, so one tenant's branches can never
  /// be offered while another is selected.
  static void reset() {
    _stores = const [];
    _selected = null;
  }
}
