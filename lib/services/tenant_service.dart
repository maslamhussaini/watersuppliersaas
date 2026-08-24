// =============================================================================
// lib/services/tenant_service.dart
// Which organization is the user currently working in.
//
// IMPORTANT — THIS IS NOT A SECURITY BOUNDARY
// _selectedOrgId is a UI preference. It used to be the ONLY thing standing
// between one tenant and another's data, which is not a control at all: the
// anon key is public, so anyone could call the REST API directly and omit the
// filter. Isolation now lives in row level security. If this class returns the
// wrong id, the user sees an empty screen rather than someone else's customers.
//
// Membership resolution reads ws_tblmemberships — one table, one query. The
// previous version unioned ws_tblinternalusers and ws_tblcustomers, which is
// also what the RLS policies would then have had to consult, producing the
// classic "infinite recursion detected in policy" error.
// =============================================================================

import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/ws_models.dart';
import 'auth_service.dart';
import 'store_service.dart';
import 'demo_service.dart';

bool get _supabaseClientInitialized {
  try {
    Supabase.instance.client;
    return true;
  } catch (_) {
    return false;
  }
}

class WsTenantService {
  static WsOrganization? _cachedOrg;
  static int? _selectedOrgId;

  static int? get selectedOrgId => _selectedOrgId;

  static Future<WsOrganization?> get currentOrganization async {
    if (_cachedOrg != null) return _cachedOrg;

    if (!_supabaseClientInitialized) {
      _cachedOrg = DemoStore().currentOrganization();
      return _cachedOrg;
    }

    if (_selectedOrgId != null) {
      final row = await Supabase.instance.client
          .from('ws_tblorganization')
          .select()
          .eq('orgid', _selectedOrgId!)
          .maybeSingle();
      if (row != null) {
        _cachedOrg = WsOrganization.fromJson(row);
        return _cachedOrg;
      }
      // Selection is stale — membership revoked, or the organization was
      // deleted. Re-resolve instead of leaving the app wedged on a dead id.
      _selectedOrgId = null;
    }

    final orgs = await organizationsForCurrentUser();
    if (orgs.length == 1) {
      selectOrganization(orgs.first.orgId);
      _cachedOrg = orgs.first;
      return _cachedOrg;
    }

    // Zero or several: the caller shows the organization selector.
    return null;
  }

  static Future<int?> get currentOrgId async {
    if (_selectedOrgId != null) return _selectedOrgId;
    final org = await currentOrganization;
    return org?.orgId;
  }

  /// Organizations this user is an active member of.
  ///
  /// Single query against ws_tblmemberships with an embedded organization read.
  /// RLS restricts the rows to the caller's own memberships, so filtering by uid
  /// here is for clarity, not correctness.
  static Future<List<WsOrganization>> organizationsForCurrentUser() async {
    if (!_supabaseClientInitialized) {
      return DemoStore().organizationsForCurrentUser();
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return [];

    final rows = await Supabase.instance.client
        .from('ws_tblmemberships')
        .select('orgid, ws_tblorganization(*)')
        .eq('authuserid', user.id)
        .eq('isactive', true);

    final orgs = <int, WsOrganization>{};
    for (final row in rows) {
      final embedded = row['ws_tblorganization'];
      if (embedded is Map<String, dynamic>) {
        final org = WsOrganization.fromJson(embedded);
        orgs[org.orgId] = org;
      }
    }

    final list = orgs.values.toList()
      ..sort(
        (a, b) => a.orgName.toLowerCase().compareTo(b.orgName.toLowerCase()),
      );
    return list;
  }

  static void selectOrganization(int orgId) {
    _selectedOrgId = orgId;
    _cachedOrg = null;
    // Permissions are per-organization. Not clearing them here would let a user
    // who is an owner in org A keep owner-level UI after switching to org B,
    // where they may only be a driver. RLS would still refuse the writes, but
    // the UI would be offering buttons that always fail.
    AuthService.clearPermissions();
    // Branches are per-organization too. Keeping the old list would offer one
    // tenant's depots while another tenant is selected — RLS would refuse the
    // writes, but only after the user had filled in a form.
    WsStoreService.reset();
    if (!_supabaseClientInitialized) {
      DemoStore().selectOrganization(orgId);
    }
  }

  static void clearSelection() {
    _selectedOrgId = null;
    _cachedOrg = null;
    AuthService.clearPermissions();
    WsStoreService.reset();
    if (!_supabaseClientInitialized) {
      DemoStore().clearSelection();
    }
  }

  static void clearCache() {
    _cachedOrg = null;
  }
}
