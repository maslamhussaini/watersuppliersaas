import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart';
import '../models/ws_models.dart';
import 'auth_service.dart';

class WsDataService {
  // ── Organization ──────────────────────────────────────────────────────────

  static Future<WsOrganization?> fetchOrg() async {
    final row = await supabase
        .from('ws_tblOrganization')
        .select()
        .maybeSingle();
    return row != null ? WsOrganization.fromJson(row) : null;
  }

  static Future<void> createOrg(WsOrganization org) async {
    await supabase.from('ws_tblOrganization').insert({
      'AuthUserID': AuthService.currentUser!.id,
      'OrgName':    org.orgName,
      'OwnerName':  org.ownerName,
      'Phone':      org.phone,
      'Address':    org.address,
    });
  }

  // ── Internal User ─────────────────────────────────────────────────────────

  static Future<WsInternalUser?> fetchCurrentInternalUser() async {
    final row = await supabase
        .from('ws_tblInternalUsers')
        .select()
        .eq('AuthUserID', AuthService.currentUser!.id)
        .maybeSingle();
    return row != null ? WsInternalUser.fromJson(row) : null;
  }

  // ── Areas ─────────────────────────────────────────────────────────────────

  static Future<List<WsArea>> fetchAreas() async {
    final rows = await supabase
        .from('ws_tblAreas')
        .select()
        .eq('IsActive', true)
        .order('AreaName');
    return rows.map((r) => WsArea.fromJson(r)).toList();
  }

  static Future<void> upsertArea(WsArea area) async {
    await supabase.from('ws_tblAreas').upsert(area.toInsert());
  }

  static Future<void> deleteArea(int areaId) async {
    await supabase.from('ws_tblAreas')
        .update({'IsActive': false})
        .eq('AreaID', areaId);
  }

  // ── Customers ─────────────────────────────────────────────────────────────

  /// Fetches customers joined with area name + outstanding balance view
  static Future<List<WsCustomer>> fetchCustomers() async {
    final rows = await supabase
        .from('vw_ws_CustomerBalance')
        .select()
        .order('CustomerName');
    return rows.map((r) => WsCustomer.fromJson(r)).toList();
  }

  static Future<WsCustomer?> fetchCustomerById(int id) async {
    final row = await supabase
        .from('ws_tblCustomers')
        .select('*, ws_tblAreas(AreaName, RatePerBottle)')
        .eq('CustomerID', id)
        .maybeSingle();
    if (row == null) return null;
    final flat = <String, dynamic>{...row, ...?row['ws_tblAreas'] as Map<String, dynamic>?};
    return WsCustomer.fromJson(flat);
  }

  static Future<void> upsertCustomer(WsCustomer c) async {
    await supabase.from('ws_tblCustomers').upsert(c.toInsert());
  }

  static Future<void> deleteCustomer(int customerId) async {
    await supabase.from('ws_tblCustomers')
        .update({'IsActive': false})
        .eq('CustomerID', customerId);
  }

  // ── Deliveries ────────────────────────────────────────────────────────────

  static Future<List<WsDelivery>> fetchDeliveries({
    int? customerId,
    DateTime? from,
    DateTime? to,
  }) async {
    var q = supabase
        .from('ws_tblDeliveries')
        .select('*, ws_tblCustomers(CustomerName), ws_tblInternalUsers(FullName)');

    if (customerId != null) q = q.eq('CustomerID', customerId) as dynamic;
    if (from != null) q = q.gte('DeliveryDate', from.toIso8601String().split('T').first) as dynamic;
    if (to   != null) q = q.lte('DeliveryDate', to.toIso8601String().split('T').first)   as dynamic;

    final rows = await (q as dynamic).order('DeliveryDate', ascending: false);
    return rows.map<WsDelivery>((r) {
      final flat = <String, dynamic>{
        ...r,
        'CustomerName':   r['ws_tblCustomers']?['CustomerName'],
        'DeliveredByName':r['ws_tblInternalUsers']?['FullName'],
      };
      return WsDelivery.fromJson(flat);
    }).toList();
  }

  static Future<void> insertDelivery(WsDelivery d) async {
    await supabase.from('ws_tblDeliveries').insert(d.toInsert());
  }

  // ── Payments ──────────────────────────────────────────────────────────────

  static Future<List<WsPayment>> fetchPayments({
    int? customerId,
    DateTime? from,
    DateTime? to,
  }) async {
    var q = supabase
        .from('ws_tblPayments')
        .select('*, ws_tblCustomers(CustomerName), ws_tblInternalUsers(FullName)');

    if (customerId != null) q = q.eq('CustomerID', customerId) as dynamic;

    final rows = await (q as dynamic).order('PaymentDate', ascending: false);
    return rows.map<WsPayment>((r) {
      final flat = <String, dynamic>{
        ...r,
        'CustomerName':   r['ws_tblCustomers']?['CustomerName'],
        'ReceivedByName': r['ws_tblInternalUsers']?['FullName'],
      };
      return WsPayment.fromJson(flat);
    }).toList();
  }

  static Future<void> insertPayment(WsPayment p) async {
    await supabase.from('ws_tblPayments').insert(p.toInsert());
  }

  // ── Bottle Inventory ──────────────────────────────────────────────────────

  static Future<WsBottleSnapshot?> fetchLatestSnapshot() async {
    final row = await supabase
        .from('ws_tblBottleInventory')
        .select()
        .order('SnapshotDate', ascending: false)
        .limit(1)
        .maybeSingle();
    return row != null ? WsBottleSnapshot.fromJson(row) : null;
  }

  static Future<void> insertSnapshot(WsBottleSnapshot s) async {
    await supabase.from('ws_tblBottleInventory').insert({
      'OrgID':                s.orgId,
      'SnapshotDate':         s.snapshotDate.toIso8601String().split('T').first,
      'TotalBottles':         s.totalBottles,
      'BottlesWithCustomers': s.bottlesWithCustomers,
      'BottlesInStock':       s.bottlesInStock,
      'BottlesLost':          s.bottlesLost,
      'Notes':                s.notes,
    });
  }

  // ── Dashboard Stats ───────────────────────────────────────────────────────

  static Future<WsDashboardStats> fetchDashboardStats() async {
    // Sum of bottle balances = bottles in hand (with customers)
    final custRows = await supabase
        .from('ws_tblCustomers')
        .select('BottleBalance')
        .eq('IsActive', true);

    final bottlesInHand = (custRows as List)
        .fold<int>(0, (sum, r) => sum + (r['BottleBalance'] as int? ?? 0));

    // Delivered this month
    final now  = DateTime.now();
    final from = DateTime(now.year, now.month, 1).toIso8601String().split('T').first;
    final delRows = await supabase
        .from('ws_tblDeliveries')
        .select('BottlesDelivered, BottlesReturned')
        .gte('DeliveryDate', from);

    final deliveredMonth = (delRows as List)
        .fold<int>(0, (sum, r) => sum + (r['BottlesDelivered'] as int? ?? 0));
    final emptyReturned  = (delRows)
        .fold<int>(0, (sum, r) => sum + (r['BottlesReturned']  as int? ?? 0));

    // Outstanding
    final balRows = await supabase.from('vw_ws_CustomerBalance').select('OutstandingDue');
    final totalReceivable = (balRows as List)
        .fold<double>(0, (sum, r) => sum + ((r['OutstandingDue'] as num? ?? 0).toDouble()));

    // Latest snapshot
    final snap = await fetchLatestSnapshot();

    return WsDashboardStats(
      bottlesInHand:         bottlesInHand,
      bottlesDeliveredMonth: deliveredMonth,
      emptyBottlesReturned:  emptyReturned,
      filledInStock:         snap?.bottlesInStock ?? 0,
      totalReceivable:       totalReceivable,
      bottlesNeedAttention:  (snap?.needsCleaning ?? 0) + (snap?.damaged ?? 0),
      totalCustomers:        custRows.length,
      activeCustomers:       custRows.length,
    );
  }
}