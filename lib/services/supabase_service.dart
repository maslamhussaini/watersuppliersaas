// =============================================================================
// lib/services/supabase_service.dart
// Data access for organizations, master data, deliveries, payments, reports.
//
// TENANT SCOPING IS NO LONGER THIS FILE'S JOB
// Every .eq('orgid', orgId) below is a performance hint, not a security control.
// Row level security (database/migrations/008_rls_policies.sql) enforces
// isolation server-side. Before that migration these filters WERE the only
// protection, and since the Supabase anon key ships inside the web bundle, any
// caller could simply omit them.
//
// KEY CASING
// PostgREST returns column names exactly as stored — lowercase for this schema.
// Reads go through the model factories, which try lowercase first. Code that
// read PascalCase keys directly (`r['BottleBalance']`) always got null; those
// call sites are gone.
// =============================================================================

import '../main.dart';
import '../models/ws_models.dart';
import 'location_service.dart';
import 'store_service.dart';
import 'auth_service.dart';
import 'demo_service.dart';
import 'tenant_service.dart';

class WsDataService {
  /// Resolves the active organization or throws a message the UI can show.
  static Future<int> _requireOrgId() async {
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) {
      throw StateError('No active organization selected');
    }
    return orgId;
  }

  static String _d(DateTime v) => v.toIso8601String().split('T').first;

  // ── Organization ──────────────────────────────────────────────────────────

  static Future<WsOrganization?> fetchOrg() async {
    if (!supabaseClientInitialized) {
      return DemoStore().currentOrganization();
    }
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return null;

    final row = await supabase
        .from('ws_tblorganization')
        .select()
        .eq('orgid', orgId)
        .maybeSingle();
    return row != null ? WsOrganization.fromJson(row) : null;
  }

  /// Creates an organization with default roles, permissions, chart of accounts
  /// and a trial subscription, in one transaction.
  ///
  /// The previous implementation inserted the org from the client and then
  /// inserted the membership row separately. If the second insert failed, the
  /// organization existed with no members — invisible even to the user who had
  /// just created it, and unrepairable from the app.
  static Future<int> createOrg(WsOrganization org, {String? clientUuid}) async {
    if (!supabaseClientInitialized) {
      DemoStore().registerOrganization(
        email: org.authUserId,
        password: 'demo',
        orgName: org.orgName,
        ownerName: org.ownerName,
        phone: org.phone,
        address: org.address,
      );
      return DemoStore().selectedOrgId ?? 0;
    }

    // ONE KEY PER REGISTRATION ATTEMPT.
    //
    // Without it, a response lost after the transaction committed left the
    // caller believing registration had failed, and the retry provisioned a
    // SECOND tenant — the user then owned two identically named organizations,
    // one of which had all their data and one of which had none.
    //
    // The guarantee lives in the database (migration 014), not here: the
    // function returns the organization already provisioned under this key.
    final result = await supabase.rpc(
      'ws_create_organization',
      params: {
        'p_orgname': org.orgName,
        'p_ownername': org.ownerName,
        'p_phone': org.phone,
        'p_address': org.address,
        'p_clientuuid': clientUuid,
      },
    );
    final orgId = (result as num).toInt();

    // The chart of accounts is NOT seeded here any more.
    //
    // Migration 011 made ws.provision_organization seed it inside the same
    // transaction. This second round trip was therefore redundant, and worse
    // than redundant: it was a second place the network could fail after the
    // tenant already existed, which is precisely how the duplicate-org retry
    // got triggered.

    WsTenantService.selectOrganization(orgId);
    return orgId;
  }

  // ── Internal User ─────────────────────────────────────────────────────────

  static Future<WsInternalUser?> fetchCurrentInternalUser() async {
    if (!supabaseClientInitialized) return null;
    final user = AuthService.currentUser;
    if (user == null) return null;

    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return null;

    final row = await supabase
        .from('ws_tblinternalusers')
        .select()
        .eq('authuserid', user.id)
        .eq('orgid', orgId)
        .maybeSingle();
    return row != null ? WsInternalUser.fromJson(row) : null;
  }

  static Future<List<WsInternalUser>> fetchStaff() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    final rows = await supabase
        .from('ws_tblinternalusers')
        .select()
        .eq('orgid', orgId)
        .eq('isactive', true)
        .order('fullname');
    return rows
        .map<WsInternalUser>((r) => WsInternalUser.fromJson(r))
        .toList();
  }

  // ── Areas ─────────────────────────────────────────────────────────────────

  static Future<List<WsArea>> fetchAreas() async {
    if (!supabaseClientInitialized) {
      return DemoStore().areasForCurrentOrg();
    }
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('ws_tblareas')
        .select()
        .eq('orgid', orgId)
        .eq('isactive', true)
        .order('areaname');
    return rows.map<WsArea>((r) => WsArea.fromJson(r)).toList();
  }

  /// Inserts when [WsArea.areaId] is 0, updates otherwise.
  ///
  /// This used to call .upsert(area.toInsert()). toInsert() omits the primary
  /// key, so PostgREST had no conflict target to match on and every edit
  /// inserted a duplicate area instead of updating the existing one.
  static Future<void> upsertArea(WsArea area) async {
    final orgId = await _requireOrgId();

    if (area.areaId == 0) {
      await supabase.from('ws_tblareas').insert({
        ...area.toInsert(),
        'orgid': orgId,
      });
    } else {
      await supabase
          .from('ws_tblareas')
          .update(area.toInsert())
          .eq('areaid', area.areaId)
          .eq('orgid', orgId);
    }
  }

  static Future<void> deleteArea(int areaId) async {
    final orgId = await _requireOrgId();
    await supabase
        .from('ws_tblareas')
        .update({'isactive': false})
        .eq('areaid', areaId)
        .eq('orgid', orgId);
  }

  // ── Customers ─────────────────────────────────────────────────────────────

  static Future<List<WsCustomer>> fetchCustomers() async {
    if (!supabaseClientInitialized) {
      return DemoStore().customersForCurrentOrg();
    }
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('vw_ws_customerbalance')
        .select()
        .eq('orgid', orgId)
        .eq('isactive', true)
        .order('customername');
    return rows.map<WsCustomer>((r) => WsCustomer.fromJson(r)).toList();
  }

  static Future<WsCustomer?> fetchCustomerById(int id) async {
    if (!supabaseClientInitialized) {
      return DemoStore()
          .customersForCurrentOrg()
          .where((c) => c.customerId == id)
          .firstOrNull;
    }
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return null;
    // Read the view so outstandingdue and deposit value come back too.
    final row = await supabase
        .from('vw_ws_customerbalance')
        .select()
        .eq('customerid', id)
        .eq('orgid', orgId)
        .maybeSingle();
    return row != null ? WsCustomer.fromJson(row) : null;
  }

  /// Portal lookup: which customer record belongs to this auth user.
  /// RLS already restricts the portal user to its own row, so no orgid filter
  /// is needed and none should be assumed.
  static Future<WsCustomer?> fetchCustomerForAuthUser(String authUserId) async {
    if (!supabaseClientInitialized) {
      return DemoStore().customersForCurrentOrg().firstOrNull;
    }
    final row = await supabase
        .from('vw_ws_customerbalance')
        .select()
        .eq('authuserid', authUserId)
        .limit(1)
        .maybeSingle();
    return row != null ? WsCustomer.fromJson(row) : null;
  }

  /// Inserts when [WsCustomer.customerId] is 0, updates otherwise.
  /// See [upsertArea] for why .upsert() was wrong here.
  ///
  /// The CREATE path goes through ws_record_customer (migration 014) so that a
  /// save retried after a lost response returns the customer already created
  /// instead of making a second one.
  ///
  /// That matters more than it looks. bottlebalance, depositamount and
  /// outstanding due are all keyed on customerid, so a duplicate splits one
  /// person's ledger in half — and vw_ws_reconciliation still reports 0,
  /// because both halves are counted in the same totals. The check that guards
  /// the books cannot see this, which is exactly why the key has to.
  ///
  /// UPDATE is unchanged: writing the same fields twice is already idempotent.
  static Future<void> upsertCustomer(WsCustomer c, {String? clientUuid}) async {
    if (!supabaseClientInitialized) {
      DemoStore().upsertCustomer(c);
      return;
    }
    final orgId = await _requireOrgId();

    if (c.customerId == 0) {
      await supabase.rpc('ws_record_customer', params: {
        'p_storeid': WsStoreService.currentStoreId,
        'p_orgid': orgId,
        'p_customername': c.customerName,
        'p_areaid': c.areaId,
        'p_customercode': c.customerCode,
        'p_contactperson': c.contactPerson,
        'p_phone': c.phone,
        'p_address': c.address,
        'p_rateoverride': c.rateOverride,
        'p_depositamount': c.depositAmount,
        'p_clientuuid': clientUuid,
      });
    } else {
      await supabase
          .from('ws_tblcustomers')
          .update(c.toInsert())
          .eq('customerid', c.customerId)
          .eq('orgid', orgId);
    }
  }

  static Future<void> deleteCustomer(int customerId) async {
    if (!supabaseClientInitialized) {
      DemoStore().deleteCustomer(customerId);
      return;
    }
    final orgId = await _requireOrgId();
    await supabase
        .from('ws_tblcustomers')
        .update({'isactive': false})
        .eq('customerid', customerId)
        .eq('orgid', orgId);
  }

  /// Opening money and bottle balances, posted as real transactions so the
  /// customer ledger ties to the journal.
  static Future<void> setCustomerOpening({
    required int customerId,
    double openingDue = 0,
    int? bottleTypeId,
    int openingBottles = 0,
    DateTime? asOf,
  }) async {
    if (!supabaseClientInitialized) return;
    await supabase.rpc('ws_set_customer_opening', params: {
      'p_customerid': customerId,
      'p_openingdue': openingDue,
      'p_bottletypeid': bottleTypeId,
      'p_openingqty': openingBottles,
      'p_asof': _d(asOf ?? DateTime.now()),
    });
  }

  // ── Products and pricing ──────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchProducts() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('ws_tblproducts')
        .select()
        .eq('orgid', orgId)
        .eq('isactive', true)
        .order('productname');
    return rows.cast<Map<String, dynamic>>();
  }

  /// Authoritative price for a customer, resolved server-side.
  ///
  /// Precedence is customer > customer group > area > organization default,
  /// each with an effective-date window. WsCustomer.effectiveRate is a display
  /// approximation that cannot see groups or date windows — never bill from it.
  static Future<double> resolvePrice({
    required int productId,
    required int customerId,
    DateTime? on,
  }) async {
    if (!supabaseClientInitialized) return 0;
    final orgId = await _requireOrgId();
    final v = await supabase.rpc('ws_resolve_price', params: {
      'p_orgid': orgId,
      'p_productid': productId,
      'p_customerid': customerId,
      'p_on': _d(on ?? DateTime.now()),
    });
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  /// The organization's default returnable product — the one the delivery card
  /// counts bottles for.
  static Future<int?> fetchDefaultProductId() async {
    if (!supabaseClientInitialized) return null;
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return null;
    final row = await supabase
        .from('ws_tblproducts')
        .select('productid, ws_tblbottletypes!inner(isdefault)')
        .eq('orgid', orgId)
        .eq('isactive', true)
        .eq('ws_tblbottletypes.isdefault', true)
        .order('productid')
        .limit(1)
        .maybeSingle();
    if (row == null) return null;
    return (row['productid'] as num).toInt();
  }

  /// Price this customer will actually be billed for one default bottle.
  ///
  /// The delivery screen used to preview WsCustomer.effectiveRate, which is
  /// rateOverride ?? areaRate. That ignores customer-group pricing and
  /// effective-date windows, so a customer in a discounted group saw one figure
  /// on screen and was charged another on the invoice.
  static Future<double> resolveDefaultRate(int customerId, {DateTime? on}) async {
    final productId = await fetchDefaultProductId();
    if (productId == null) return 0;
    return resolvePrice(productId: productId, customerId: customerId, on: on);
  }

  // ── Deliveries ────────────────────────────────────────────────────────────

  static Future<List<WsDelivery>> fetchDeliveries({
    int? customerId,
    DateTime? from,
    DateTime? to,
    int limit = 200,
  }) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    // Filters are chained without the `as dynamic` casts the previous version
    // needed: each filter returns the same builder type, so reassignment is
    // type-safe provided .order() is applied last.
    var query = supabase
        .from('ws_tbldeliveries')
        .select(
          '*, ws_tblcustomers(customername), ws_tblinternalusers(fullname)',
        )
        .eq('orgid', orgId)
        .eq('isvoid', false);

    if (customerId != null) query = query.eq('customerid', customerId);
    if (from != null) query = query.gte('deliverydate', _d(from));
    if (to != null) query = query.lte('deliverydate', _d(to));

    final rows =
        await query.order('deliverydate', ascending: false).limit(limit);

    return rows.map<WsDelivery>((r) {
      final row = Map<String, dynamic>.from(r);
      final cust = row['ws_tblcustomers'] as Map<String, dynamic>?;
      final staff = row['ws_tblinternalusers'] as Map<String, dynamic>?;
      row['customername'] = cust?['customername'];
      row['deliveredbyname'] = staff?['fullname'];
      return WsDelivery.fromJson(row);
    }).toList();
  }

  /// Records a delivery, its line item, the bottle movements and any cash
  /// collected — atomically, in one server-side transaction.
  ///
  /// Replaces the previous insertDelivery() followed by insertPayment(). If the
  /// payment insert failed there, the delivery was already committed: the
  /// customer was billed and the cash they handed over was never recorded.
  ///
  /// Returns the new delivery id.
  static Future<int> recordDelivery({
    int? storeId,
    WsPosition? position,
    required int customerId,
    required DateTime date,
    required int delivered,
    required int returned,
    int? productId,
    double amountPaid = 0,
    String paymentMethod = 'cash',
    int? deliveredById,
    int? routeId,
    String? notes,

    /// Idempotency key. OPTIONAL so every existing caller compiles unchanged;
    /// p_clientuuid is likewise defaulted on the RPC (migration 010), so
    /// omitting it posts exactly as before.
    ///
    /// Supply it and the call becomes safe to repeat: if the server committed
    /// and the response was lost, the retry returns the ORIGINAL delivery id
    /// and writes nothing. Generate it ONCE per user action — never per
    /// attempt — or the guarantee is worthless.
    String? clientUuid,
  }) async {
    if (!supabaseClientInitialized) {
      throw StateError('Recording a delivery requires a Supabase connection');
    }
    final id = await supabase.rpc('ws_record_delivery', params: {
      // Null is legitimate: the server resolves the organization's default
      // store, which is exactly right for a single-branch business.
      'p_storeid': storeId,
      // Also legitimately null — a delivery is never blocked on a fix.
      if (position != null) ...position.toArgs(),
      'p_customerid': customerId,
      'p_deliverydate': _d(date),
      'p_delivered': delivered,
      'p_returned': returned,
      'p_productid': productId,
      'p_amountpaid': amountPaid,
      'p_paymentmethod': paymentMethod,
      'p_deliveredbyid': deliveredById,
      'p_routeid': routeId,
      'p_notes': notes,
      'p_clientuuid': clientUuid,
    });
    return (id as num).toInt();
  }

  // ── Payments ──────────────────────────────────────────────────────────────

  static Future<List<WsPayment>> fetchPayments({
    int? customerId,
    DateTime? from,
    DateTime? to,
    int limit = 200,
  }) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    var query = supabase
        .from('ws_tblpayments')
        .select(
          '*, ws_tblcustomers(customername), ws_tblinternalusers(fullname)',
        )
        .eq('orgid', orgId)
        .eq('isvoid', false);

    if (customerId != null) query = query.eq('customerid', customerId);
    if (from != null) query = query.gte('paymentdate', _d(from));
    if (to != null) query = query.lte('paymentdate', _d(to));

    final rows =
        await query.order('paymentdate', ascending: false).limit(limit);

    return rows.map<WsPayment>((r) {
      final row = Map<String, dynamic>.from(r);
      final cust = row['ws_tblcustomers'] as Map<String, dynamic>?;
      final staff = row['ws_tblinternalusers'] as Map<String, dynamic>?;
      row['customername'] = cust?['customername'];
      row['receivedbyname'] = staff?['fullname'];
      return WsPayment.fromJson(row);
    }).toList();
  }

  /// Records a customer payment.
  ///
  /// GOES THROUGH ws_record_payment, NOT a direct insert.
  ///
  /// The direct insert this replaces could not be made idempotent: a timeout
  /// after the row committed, followed by the user tapping Save again,
  /// produced a second receipt AND a second journal entry against the
  /// customer's ledger. The RPC (migration 010) checks the idempotency key
  /// before writing anything, so the second call is a read that returns the
  /// original paymentid.
  ///
  /// [clientUuid] is optional so existing callers compile and behave exactly as
  /// before; p_clientuuid is likewise defaulted on the RPC. Supply it — one per
  /// user Save action, reused by every retry — to get the guarantee.
  ///
  /// Returns the server's paymentid. The old signature returned void; nothing
  /// depended on that, and the id is what a caller needs to correlate the
  /// payment with its outbox entry.
  ///
  /// receiptno is still assigned server-side by ws.next_docnumber(), and no
  /// accounting is performed here — the journal entry is posted by the same
  /// in-transaction trigger as before.
  static Future<int> insertPayment(WsPayment p,
      {String? clientUuid, int? storeId}) async {
    // _requireOrgId still runs: it fails fast with a message the UI can show
    // when no organization is selected, rather than letting the RPC raise.
    await _requireOrgId();

    final id = await supabase.rpc('ws_record_payment', params: {
      'p_storeid': storeId,
      'p_customerid': p.customerId,
      'p_amount': p.amountReceived,
      'p_paymentdate': _d(p.paymentDate),
      'p_paymentmethod': p.paymentMethod.name,
      'p_referenceno': p.referenceNo,
      'p_notes': p.notes,
      'p_clientuuid': clientUuid,
    });
    return (id as num).toInt();
  }

  // ── Bottles ───────────────────────────────────────────────────────────────

  /// Per-bottle-type balances for one customer. A customer holding a 19L and a
  /// 20L bottle produces two rows; WsCustomer.bottleBalance only ever shows the
  /// default type.
  static Future<List<WsBottleBalance>> fetchBottleBalances(
    int customerId,
  ) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('vw_ws_customerbottlebalance')
        .select()
        .eq('orgid', orgId)
        .eq('customerid', customerId)
        .order('isdefault', ascending: false);
    return rows
        .map<WsBottleBalance>((r) => WsBottleBalance.fromJson(r))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> fetchBottlePosition() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('vw_ws_bottleposition')
        .select()
        .eq('orgid', orgId);
    return rows.cast<Map<String, dynamic>>();
  }

  /// Organization-wide bottle position, derived from the bottle ledger.
  ///
  /// Replaces the manual snapshot table on the bottle screen: those figures were
  /// only as fresh as the last time somebody remembered to take a snapshot, and
  /// nothing in the app ever took one.
  static Future<WsBottlePosition> fetchBottlePositionTotals() async {
    final rows = await fetchBottlePosition();
    var withCustomers = 0, inStock = 0, lost = 0, damaged = 0;
    for (final r in rows) {
      withCustomers += (r['withcustomers'] as num?)?.toInt() ?? 0;
      inStock       += (r['instock'] as num?)?.toInt() ?? 0;
      lost          += (r['lost'] as num?)?.toInt() ?? 0;
      damaged       += (r['damaged'] as num?)?.toInt() ?? 0;
    }
    return WsBottlePosition(
      withCustomers: withCustomers,
      inStock: inStock,
      lost: lost,
      damaged: damaged,
      byType: rows,
    );
  }

  // fetchLatestSnapshot() and insertSnapshot() were removed here.
  //
  // They read and wrote ws_tblbottleinventory, a snapshot table somebody had to
  // populate by hand. Nothing in the app ever called insertSnapshot, so the
  // table stayed empty and every bottle figure derived from it read zero — the
  // bug already described in customers_screen.dart.
  //
  // vw_ws_bottleposition replaced it: the same numbers, derived from the
  // append-only bottle ledger, correct by construction rather than by somebody
  // remembering. fetchBottlePosition() above is the live path.
  //
  // The table itself is untouched — this removes only the dead client code.

  // ── Generic master-data CRUD ──────────────────────────────────────────────
  //
  // Nine entities needed create/edit screens: products, bottle types, product
  // prices, vendors, purchases, vendor payments, staff, routes and customer
  // groups. Nine bespoke service classes would be nine places to repeat the
  // same orgid handling and the same insert-vs-update mistake that duplicated
  // customer rows earlier.
  //
  // These work on Map<String, dynamic> deliberately. Typed models earn their
  // keep where there is behaviour attached — WsCustomer.effectiveRate,
  // WsDeliveryCardRow's card maths. For a form that reads six columns and
  // writes them back, a model is transcription with no payoff.

  /// Rows for a master table in the current organization.
  static Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    String orderBy = 'createddate',
    bool ascending = true,
    bool activeOnly = true,
    String columns = '*',
  }) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    var q = supabase.from(table).select(columns).eq('orgid', orgId);
    if (activeOnly) q = q.eq('isactive', true);
    final rows = await q.order(orderBy, ascending: ascending);
    return rows.cast<Map<String, dynamic>>();
  }

  /// Insert when [pkValue] is null, update otherwise.
  ///
  /// The same shape as upsertCustomer, for the same reason: PostgREST .upsert()
  /// with no primary key in the payload has no conflict target and silently
  /// inserts a duplicate instead of updating.
  static Future<void> saveRow(
    String table,
    String pkColumn,
    Object? pkValue,
    Map<String, dynamic> values,
  ) async {
    final orgId = await _requireOrgId();
    final payload = Map<String, dynamic>.from(values)..remove(pkColumn);

    if (pkValue == null) {
      await supabase.from(table).insert({...payload, 'orgid': orgId});
    } else {
      await supabase
          .from(table)
          .update(payload)
          .eq(pkColumn, pkValue)
          .eq('orgid', orgId);
    }
  }

  /// Create or update a vendor.
  ///
  /// The CREATE path goes through ws_record_vendor (migration 014) for the
  /// same reason as customers: a duplicate vendor splits payables across two
  /// rows, and reconciliation cannot detect it.
  ///
  /// [openingBalance] is passed through exactly as the generic saveRow path
  /// passed it, and it IS journalled. Migration 016 added trg_vendor_opening_sync,
  /// an AFTER INSERT OR UPDATE OF openingbalance trigger on ws_tblvendors, so the
  /// insert performed by ws_record_vendor and the raw UPDATE performed by the
  /// saveRow branch below both reach ws.sync_vendor_opening and post the same
  /// entry that ws_set_vendor_opening produces. That function is now a validated
  /// wrapper that writes the column and lets the trigger do the accounting; it is
  /// no longer the only path that posts. sync_vendor_opening restates the entry
  /// rather than adding a second one, so editing the balance does not double-post.
  ///
  /// Proven by execution in test_harness/bin/vendor_opening.dart, which drives
  /// this raw-update path directly.
  static Future<void> saveVendor({
    required Object? pkValue,
    required Map<String, dynamic> values,
    String? clientUuid,
  }) async {
    final orgId = await _requireOrgId();

    if (pkValue != null) {
      // Unchanged: an update writes the same fields to the same row.
      await saveRow('ws_tblvendors', 'vendorid', pkValue, values);
      return;
    }

    await supabase.rpc('ws_record_vendor', params: {
      'p_orgid': orgId,
      'p_vendorname': values['vendorname'],
      'p_vendorcode': values['vendorcode'],
      'p_contactperson': values['contactperson'],
      'p_phone': values['phone'],
      'p_email': values['email'],
      'p_address': values['address'],
      'p_openingbalance': values['openingbalance'] ?? 0,
      'p_clientuuid': clientUuid,
    });
  }

  /// Soft delete. Nothing in this schema hard-deletes master data: a product
  /// with deliveries against it must not vanish, or historical documents lose
  /// their line items.
  static Future<void> deactivateRow(
    String table,
    String pkColumn,
    Object pkValue,
  ) async {
    final orgId = await _requireOrgId();
    await supabase
        .from(table)
        .update({'isactive': false})
        .eq(pkColumn, pkValue)
        .eq('orgid', orgId);
  }

  /// Options for a dropdown: [{'id': .., 'label': ..}].
  static Future<List<Map<String, dynamic>>> fetchOptions(
    String table,
    String idColumn,
    String labelColumn, {
    bool activeOnly = true,
  }) async {
    final rows = await fetchRows(
      table,
      orderBy: labelColumn,
      activeOnly: activeOnly,
      columns: '$idColumn, $labelColumn',
    );
    return rows
        .map((r) => {'id': r[idColumn], 'label': '${r[labelColumn] ?? ''}'})
        .toList();
  }

  // ── Purchases ─────────────────────────────────────────────────────────────

  /// Header + one line, in the order the triggers expect.
  ///
  /// The line insert is what fires ws.post_purchase(), which writes the journal
  /// entry, and ws.recalc_purchase(), which sets totalamount. Inserting only a
  /// header would leave a purchase worth zero and no accounting behind it.
  /// Records a purchase: header and ALL its lines, in ONE transaction.
  ///
  /// REPLACES A TWO-INSERT SEQUENCE THAT COULD LEAVE A HALF-DOCUMENT.
  ///
  /// Every consequence of a purchase — the line amount, the header total, the
  /// journal entry, the bottles into stock — is produced by triggers on the
  /// DETAIL row, not the header. The previous implementation inserted the
  /// header, then the line, as two round trips. Losing the connection between
  /// them left a purchase with totalamount 0, no journal entry and no stock,
  /// looking like a real record in the list. See migration 012.
  ///
  /// [lines] is a list of {productid, quantity, unitcost?, notes?}. Omitting
  /// unitcost lets the server default it from ws_tblproducts.purchaseprice —
  /// existing behaviour, still computed server-side.
  ///
  /// [clientUuid] is optional so any existing caller compiles unchanged, and
  /// p_clientuuid is defaulted on the RPC. Supply it — ONE per user Save
  /// action, reused by every retry — to make the call safe to repeat.
  ///
  /// No purchase arithmetic happens here. Line amounts, the header total, the
  /// journal entry and the stock movement are all still produced by the
  /// database triggers that already existed.
  static Future<int> recordPurchaseLines({
    int? storeId,
    required int vendorId,
    required DateTime date,
    required List<Map<String, dynamic>> lines,
    String? billNo,
    String? notes,
    String? clientUuid,
  }) async {
    if (!supabaseClientInitialized) {
      throw StateError('Recording a purchase requires a Supabase connection');
    }
    if (lines.isEmpty) {
      // The server rejects this too (a purchase with no lines is exactly the
      // corrupt state 012 prevents). Failing here as well turns a round trip
      // into an immediate, clearer message.
      throw ArgumentError('A purchase must have at least one line.');
    }
    // _requireOrgId still runs so "no organization selected" fails fast with a
    // message the UI can show, rather than surfacing as an RPC error.
    await _requireOrgId();

    final id = await supabase.rpc('ws_record_purchase', params: {
      'p_storeid': storeId,
      'p_vendorid': vendorId,
      'p_lines': lines,
      'p_purchasedate': _d(date),
      'p_billno': billNo,
      'p_notes': notes,
      'p_clientuuid': clientUuid,
    });
    return (id as num).toInt();
  }

  /// Single-line convenience, preserving the original call shape.
  ///
  /// The Purchases form still collects exactly one item, so this keeps that
  /// call site unchanged while everything underneath becomes atomic and
  /// idempotent. Multi-line callers use recordPurchaseLines directly.
  static Future<int> recordPurchase({
    required int vendorId,
    required DateTime date,
    required int productId,
    required double quantity,
    required double unitCost,
    String? billNo,
    String? notes,
    String? clientUuid,
    int? storeId,
  }) =>
      recordPurchaseLines(
        vendorId: vendorId,
        date: date,
        lines: [
          {
            'productid': productId,
            'quantity': quantity,
            'unitcost': unitCost,
          },
        ],
        billNo: billNo,
        notes: notes,
        clientUuid: clientUuid,
        storeId: storeId,
      );

  static Future<List<Map<String, dynamic>>> fetchPurchases() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('ws_tblpurchases')
        .select('*, ws_tblvendors(vendorname)')
        .eq('orgid', orgId)
        .eq('isvoid', false)
        .order('purchasedate', ascending: false)
        .limit(200);
    return rows.cast<Map<String, dynamic>>();
  }

  /// Records a payment to a vendor.
  ///
  /// GOES THROUGH ws_record_vendor_payment, NOT a direct insert.
  ///
  /// The direct insert this replaces could not be made idempotent: a timeout
  /// after the row committed, followed by the user pressing Save again, paid
  /// the vendor twice — a second voucher, a second journal entry, and a payable
  /// understated by the duplicate amount. The RPC (migration 013) checks the
  /// idempotency key before writing, so a retry is a read that returns the
  /// original vendorpaymentid.
  ///
  /// UNCHANGED BEHAVIOUR:
  ///   · methodid stays NULL — the previous insert never set it, and
  ///     ws.post_vendor_payment already falls back to the cash control account,
  ///     so the journal entry is correct either way. Adding a method would be a
  ///     business change, not an idempotency one.
  ///   · voucherno is still assigned server-side by ws.next_docnumber() via the
  ///     BEFORE trigger, so numbering stays gapless and per-tenant.
  ///   · No accounting happens here. AP debit / cash credit is posted by the
  ///     same AFTER trigger as before.
  ///
  /// [clientUuid] is optional so existing callers compile unchanged, and
  /// p_clientuuid is defaulted on the RPC.
  ///
  /// Returns the server's vendorpaymentid. The old signature returned void;
  /// nothing depended on that, and the id is what lets the outbox correlate the
  /// operation with its queue entry.
  static Future<int> recordVendorPayment({
    int? storeId,
    required int vendorId,
    required DateTime date,
    required double amount,
    int? purchaseId,
    String? referenceNo,
    String? notes,
    String? clientUuid,
  }) async {
    if (!supabaseClientInitialized) {
      throw StateError('Recording a vendor payment requires a Supabase connection');
    }
    // Still runs so "no organization selected" fails fast with a message the UI
    // can show, rather than surfacing as a raw RPC error.
    await _requireOrgId();

    final id = await supabase.rpc('ws_record_vendor_payment', params: {
      'p_storeid': storeId,
      'p_vendorid': vendorId,
      'p_amount': amount,
      'p_paiddate': _d(date),
      'p_purchaseid': purchaseId,
      'p_referenceno': referenceNo,
      'p_notes': notes,
      'p_clientuuid': clientUuid,
    });
    return (id as num).toInt();
  }

  static Future<List<Map<String, dynamic>>> fetchVendorPayments() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('ws_tblvendorpayments')
        .select('*, ws_tblvendors(vendorname)')
        .eq('orgid', orgId)
        .eq('isvoid', false)
        .order('paiddate', ascending: false)
        .limit(200);
    return rows.cast<Map<String, dynamic>>();
  }

  // ── Staff ─────────────────────────────────────────────────────────────────

  /// Roles available in this organization, for the staff form.
  static Future<List<Map<String, dynamic>>> fetchRoles() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('ws_tblroles')
        .select('roleid, rolecode, rolename, isportal')
        .eq('orgid', orgId)
        .eq('isportal', false)
        .order('rolename');
    return rows.cast<Map<String, dynamic>>();
  }

  /// Changes a staff member's role.
  ///
  /// Writes ws_tblmemberships.roleid — that is what RLS reads. The role text on
  /// ws_tblinternalusers is a display label kept in step; updating only the
  /// label would change what the UI shows without changing any permission,
  /// which is the worst of both.
  static Future<void> updateStaffRole({
    required int internalUserId,
    required String authUserId,
    required int roleId,
    required String roleCode,
  }) async {
    final orgId = await _requireOrgId();

    await supabase
        .from('ws_tblmemberships')
        .update({'roleid': roleId})
        .eq('orgid', orgId)
        .eq('authuserid', authUserId);

    await supabase
        .from('ws_tblinternalusers')
        .update({'role': roleCode})
        .eq('internaluserid', internalUserId)
        .eq('orgid', orgId);
  }

  // ── Reports ───────────────────────────────────────────────────────────────

  /// Rows for the printed delivery card, straight from vw_ws_deliverycard.
  static Future<List<WsDeliveryCardRow>> fetchDeliveryCard({
    required int customerId,
    DateTime? from,
    DateTime? to,
  }) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    var query = supabase
        .from('vw_ws_deliverycard')
        .select()
        .eq('orgid', orgId)
        .eq('customerid', customerId);

    if (from != null) query = query.gte('entrydate', _d(from));
    if (to != null) query = query.lte('entrydate', _d(to));

    final rows = await query.order('entrydate');
    return rows
        .map<WsDeliveryCardRow>((r) => WsDeliveryCardRow.fromJson(r))
        .toList();
  }

  /// Everything the printed delivery card needs, fetched together.
  ///
  /// Returns null when the organization cannot be read, so the caller shows a
  /// message rather than rendering a card with a blank letterhead.
  static Future<WsDeliveryCardData?> fetchDeliveryCardData({
    required WsCustomer customer,
    DateTime? from,
    DateTime? to,
  }) async {
    final org = await fetchOrg();
    if (org == null) return null;

    final rows = await fetchDeliveryCard(
      customerId: customer.customerId,
      from: from,
      to: to,
    );
    final balances = await fetchBottleBalances(customer.customerId);

    return WsDeliveryCardData(
      org: org,
      customer: customer,
      rows: rows,
      bottleBalances: balances,
      periodFrom: from,
      periodTo: to,
    );
  }

  static Future<List<WsLedgerRow>> fetchCustomerLedger(int customerId) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('vw_ws_customerledger')
        .select()
        .eq('orgid', orgId)
        .eq('customerid', customerId)
        .order('txndate')
        .order('sortkey');
    return rows.map<WsLedgerRow>((r) => WsLedgerRow.fromJson(r)).toList();
  }

  // ── Dashboard ─────────────────────────────────────────────────────────────

  /// One query against vw_ws_dashboard.
  ///
  /// The previous implementation ran three full-table scans and folded them
  /// client-side reading `r['BottleBalance']`, `r['BottlesDelivered']`,
  /// `r['BottlesReturned']` and `r['OutstandingDue']`. PostgREST returns those
  /// keys in lowercase, so all four reads were null and every figure on the
  /// dashboard rendered as zero regardless of the underlying data.
  static Future<WsDashboardStats> fetchDashboardStats() async {
    if (!supabaseClientInitialized) {
      final customers = DemoStore().customersForCurrentOrg();
      return WsDashboardStats(
        bottlesInHand: customers.fold(0, (s, c) => s + c.bottleBalance),
        bottlesDeliveredMonth: 0,
        emptyBottlesReturned: 0,
        filledInStock: 0,
        totalReceivable:
            customers.fold(0.0, (s, c) => s + (c.outstandingDue ?? 0)),
        bottlesNeedAttention: 0,
        totalCustomers: customers.length,
        activeCustomers: customers.where((c) => c.isActive).length,
      );
    }

    final orgId = await _requireOrgId();
    final row = await supabase
        .from('vw_ws_dashboard')
        .select()
        .eq('orgid', orgId)
        .maybeSingle();

    if (row == null) {
      return const WsDashboardStats(
        bottlesInHand: 0,
        bottlesDeliveredMonth: 0,
        emptyBottlesReturned: 0,
        filledInStock: 0,
        totalReceivable: 0,
        bottlesNeedAttention: 0,
        totalCustomers: 0,
        activeCustomers: 0,
      );
    }

    return WsDashboardStats.fromJson(row);
  }

  /// Journal-versus-subsidiary drift. Must always be empty.
  ///
  /// Because journal entries post in the same transaction as the source
  /// document, a non-empty result means a posting rule is wrong — not that a
  /// background job is behind. Surface it; do not retry it.
  static Future<List<Map<String, dynamic>>> fetchReconciliationIssues() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('vw_ws_reconciliation')
        .select()
        .eq('orgid', orgId);
    return rows.cast<Map<String, dynamic>>();
  }

  // ── Opening balances ───────────────────────────────────────────────────────
  //
  // All three go through RPCs, never a direct table write. An opening balance
  // is a dated journal entry plus a bottle-ledger row, posted in one
  // transaction; writing the tables from here would post half of it.
  //
  // All three are idempotent — they set a TARGET and the function posts the
  // difference. Re-entering the same figure changes nothing, and correcting
  // 5 to 3 posts -2 rather than editing history. That matters because the
  // bottle ledger is append-only.

  // setCustomerOpening() already exists further up this file, next to the
  // other customer calls. It is not repeated here.

  /// Opening money owed TO a vendor.
  static Future<void> setVendorOpening({
    required int vendorId,
    double opening = 0,
    DateTime? asOf,
  }) async {
    if (!supabaseClientInitialized) return;
    await supabase.rpc('ws_set_vendor_opening', params: {
      'p_vendorid': vendorId,
      'p_opening': opening,
      'p_asof': _d(asOf ?? DateTime.now()),
    });
  }

  /// Bottles on hand at go-live, per bottle type. [unitCost] is optional: give
  /// it and the value is capitalised into Inventory, leave it zero and only
  /// the count moves.
  static Future<void> setOpeningStock({
    required int bottleTypeId,
    int qty = 0,
    double unitCost = 0,
    DateTime? asOf,
  }) async {
    if (!supabaseClientInitialized) return;
    await supabase.rpc('ws_set_opening_stock', params: {
      'p_bottletypeid': bottleTypeId,
      'p_qty': qty,
      'p_unitcost': unitCost,
      'p_asof': _d(asOf ?? DateTime.now()),
    });
  }

  /// What has already been entered as opening stock, so the form can show it
  /// rather than making the user guess whether zero means unset or zero.
  static Future<List<Map<String, dynamic>>> fetchOpeningStock() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('vw_ws_openingstock')
        .select()
        .eq('orgid', orgId)
        .order('bottlename');
    return rows.cast<Map<String, dynamic>>();
  }

  // ── Subscription and plan ──────────────────────────────────────────────────
  //
  // ws_tblplans and ws_tblsubscriptions were created by migration 002 and had
  // never been read by the app, so every organization has been on a plan
  // nobody could see. The plan carries real limits — maxcustomers, maxusers,
  // and feature flags for accounting, routes and API.
  //
  // IMPORTANT: nothing here ENFORCES a limit. This is display only. A cap that
  // matters has to be a Postgres trigger, because the anon key is public and
  // the REST API is reachable with curl; a Dart check is a suggestion.

  /// The organization's current plan and subscription, plus how much of the
  /// plan is actually in use.
  static Future<Map<String, dynamic>?> fetchSubscription() async {
    if (!supabaseClientInitialized) return null;
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return null;

    // A partial unique index allows only one live subscription per org, but
    // cancelled and expired rows accumulate. Filtering to the live statuses is
    // what makes maybeSingle() safe here.
    final sub = await supabase
        .from('ws_tblsubscriptions')
        .select('*, ws_tblplans(*)')
        .eq('orgid', orgId)
        .inFilter('status', ['trialing', 'active', 'past_due'])
        .maybeSingle();

    if (sub == null) return null;

    final row = Map<String, dynamic>.from(sub);
    final plan = row['ws_tblplans'] as Map<String, dynamic>?;
    if (plan != null) row.addAll(plan);

    // Usage, so the plan card can say "12 of 50" rather than just naming a
    // number the user has no way to compare against.
    row['usedcustomers'] = await _countRows('ws_tblcustomers', orgId);
    row['usedusers'] = await _countRows('ws_tblinternalusers', orgId);
    return row;
  }

  static Future<int> _countRows(String table, int orgId) async {
    try {
      // Deliberately NOT PostgrestFilterBuilder.count(). That arrived in a
      // later postgrest-dart than some supabase_flutter 2.x releases resolve
      // to, and this project has already lost a build to exactly that kind of
      // version assumption (publishableKey, SharePlus). Selecting one narrow
      // column and taking .length works on every 2.x, and these tables hold
      // tens of rows on the plans where the number is shown at all.
      final rows = await supabase
          .from(table)
          .select('orgid')
          .eq('orgid', orgId)
          .eq('isactive', true);
      return rows.length;
    } catch (_) {
      // A usage count is decoration on this screen. Failing it must not take
      // the whole account menu down with it.
      return 0;
    }
  }

  /// Every plan on offer, cheapest first. Used by the upgrade sheet.
  static Future<List<Map<String, dynamic>>> fetchPlans() async {
    if (!supabaseClientInitialized) return [];
    final rows = await supabase
        .from('ws_tblplans')
        .select()
        .order('sortorder');
    return rows.cast<Map<String, dynamic>>();
  }

  // ── The signed-in user's own profile ───────────────────────────────────────

  /// Updates the caller's own staff record. Name and phone only.
  ///
  /// Deliberately cannot change roleid — that lives on ws_tblmemberships and
  /// is changed under Setup › Staff by someone with users.manage. A self-serve
  /// profile form that edits your own role is a privilege escalation.
  static Future<void> updateMyProfile({
    required String fullName,
    String? phone,
  }) async {
    final orgId = await _requireOrgId();
    final user = AuthService.currentUser;
    if (user == null) throw Exception('Not signed in.');

    await supabase
        .from('ws_tblinternalusers')
        .update({
          'fullname': fullName,
          'phone': (phone == null || phone.trim().isEmpty) ? null : phone.trim(),
        })
        .eq('orgid', orgId)
        .eq('authuserid', user.id);
  }

  // ── Organization profile ───────────────────────────────────────────────────

  /// The full organization row, including the columns WsOrganization does not
  /// model (business name, email, prefixes). The Organization screen edits
  /// these, so it needs the raw row rather than the trimmed-down object.
  static Future<Map<String, dynamic>?> fetchOrgRow() async {
    if (!supabaseClientInitialized) return null;
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return null;
    final row = await supabase
        .from('ws_tblorganization')
        .select()
        .eq('orgid', orgId)
        .maybeSingle();
    return row;
  }

  /// Update the organization profile.
  ///
  /// orgid, owneruserid and publicid are deliberately NOT updatable from here:
  /// the first two are identity, and RLS keys off them. Passing them through
  /// would let a form field reassign ownership of a tenant.
  static Future<void> updateOrganization(Map<String, dynamic> values) async {
    final orgId = await _requireOrgId();

    const editable = {
      'orgname', 'businessname', 'ownername', 'email', 'phone', 'address',
      'currencysymbol', 'invoiceprefix', 'receiptprefix', 'deliveryprefix',
    };
    final patch = <String, dynamic>{
      for (final e in values.entries)
        if (editable.contains(e.key)) e.key: e.value,
    };
    if (patch.isEmpty) return;

    await supabase
        .from('ws_tblorganization')
        .update(patch)
        .eq('orgid', orgId);

    // THE CACHE MUST BE DROPPED HERE.
    //
    // WsTenantService holds _cachedOrg for the life of the process and returns
    // it before touching the network. Without this line the update lands in
    // Postgres and every reader in the app keeps handing out the old row —
    // which is why a renamed organization still printed its old name at the
    // top of an exported PDF. The write succeeded; the readers were stale.
    WsTenantService.clearCache();
  }

  // ── Reports ────────────────────────────────────────────────────────────────
  //
  // Every one of these returns rows straight from a view, filtered by date on
  // the SERVER. Pulling everything and filtering in Dart would work today with
  // three deliveries and stop working at ten thousand — and would quietly
  // download other months over a phone connection.
  //
  // The date bounds are inclusive on both ends, which is what "from 1st to
  // 31st" means to the person reading the report, and is why `to` uses lte
  // rather than lt.

  /// Customer money ledger for one customer, optionally windowed.
  ///
  /// NOTE ON THE RUNNING BALANCE: the `balance` column is computed by the view
  /// across that customer's WHOLE history, so when a window is applied the
  /// first row's balance already includes everything before it. That is the
  /// correct behaviour for a statement — the opening balance is carried in —
  /// but it means you cannot sum the debits and credits of a windowed result
  /// and expect to arrive at the closing balance.
  static Future<List<WsLedgerRow>> fetchCustomerLedgerRange(
    int customerId, {
    DateTime? from,
    DateTime? to,
  }) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    var q = supabase
        .from('vw_ws_customerledger')
        .select()
        .eq('orgid', orgId)
        .eq('customerid', customerId);
    if (from != null) q = q.gte('txndate', _d(from));
    if (to != null) q = q.lte('txndate', _d(to));

    final rows = await q.order('txndate').order('sortkey');
    return rows.map<WsLedgerRow>((r) => WsLedgerRow.fromJson(r)).toList();
  }

  /// Vendor money ledger. Balance is credit-positive: a positive number means
  /// you owe them, which is the opposite sign convention to the customer
  /// ledger and is deliberate.
  static Future<List<WsLedgerRow>> fetchVendorLedgerRange(
    int vendorId, {
    DateTime? from,
    DateTime? to,
  }) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    var q = supabase
        .from('vw_ws_vendorledger')
        .select()
        .eq('orgid', orgId)
        .eq('vendorid', vendorId);
    if (from != null) q = q.gte('txndate', _d(from));
    if (to != null) q = q.lte('txndate', _d(to));

    final rows = await q.order('txndate').order('sortkey');
    return rows.map<WsLedgerRow>((r) => WsLedgerRow.fromJson(r)).toList();
  }

  /// Bottle movements across the organization, windowed.
  static Future<List<Map<String, dynamic>>> fetchBottleLedgerRange({
    DateTime? from,
    DateTime? to,
    int? customerId,
  }) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    var q = supabase.from('vw_ws_bottleledger').select().eq('orgid', orgId);
    if (customerId != null) q = q.eq('customerid', customerId);
    if (from != null) q = q.gte('txndate', _d(from));
    if (to != null) q = q.lte('txndate', _d(to));

    final rows = await q.order('txndate', ascending: false).limit(2000);
    return rows.cast<Map<String, dynamic>>();
  }

  /// Deliveries in a window — the daily delivery report.
  static Future<List<Map<String, dynamic>>> fetchDeliveryReport({
    required DateTime from,
    required DateTime to,
    int? routeId,
  }) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    var q = supabase
        .from('ws_tbldeliveries')
        // No 'amountreceived' here: deliveries do not carry one. Cash taken at
        // the door is a row in ws_tblpayments linked by deliveryid, which is
        // what lets a customer pay later, or pay on a no-delivery visit.
        .select('deliveryid, referenceno, deliverydate, customerid, '
            'bottlesdelivered, bottlesreturned, bottlebalance, rateapplied, '
            'amountcharged, routeid, '
            'ws_tblcustomers(customername)')
        .eq('orgid', orgId)
        .eq('isvoid', false)
        .gte('deliverydate', _d(from))
        .lte('deliverydate', _d(to));
    if (routeId != null) q = q.eq('routeid', routeId);

    final rows = await q.order('deliverydate').limit(5000);
    return rows.map<Map<String, dynamic>>((r) {
      final row = Map<String, dynamic>.from(r);
      final c = row['ws_tblcustomers'] as Map<String, dynamic>?;
      row['customername'] = c?['customername'];
      return row;
    }).toList();
  }

  /// Payments received in a window — the daily receipts report.
  static Future<List<Map<String, dynamic>>> fetchPaymentReport({
    required DateTime from,
    required DateTime to,
  }) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    final rows = await supabase
        .from('ws_tblpayments')
        .select('paymentid, receiptno, paymentdate, customerid, '
            'amountreceived, paymentmethod, referenceno, '
            'ws_tblcustomers(customername)')
        .eq('orgid', orgId)
        .eq('isvoid', false)
        .gte('paymentdate', _d(from))
        .lte('paymentdate', _d(to))
        .order('paymentdate')
        .limit(5000);

    return rows.map<Map<String, dynamic>>((r) {
      final row = Map<String, dynamic>.from(r);
      final c = row['ws_tblcustomers'] as Map<String, dynamic>?;
      row['customername'] = c?['customername'];
      return row;
    }).toList();
  }

  /// Money paid OUT to vendors in a window.
  static Future<List<Map<String, dynamic>>> fetchVendorPaymentReport({
    required DateTime from,
    required DateTime to,
  }) async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];

    // ws_tblvendorpayments names its columns differently to ws_tblpayments:
    // paiddate not paymentdate, amountpaid not amountreceived, and the method
    // is a methodid FK rather than an inline code.
    final rows = await supabase
        .from('ws_tblvendorpayments')
        .select('vendorpaymentid, paiddate, vendorid, amountpaid, '
            'voucherno, referenceno, ws_tblvendors(vendorname)')
        .eq('orgid', orgId)
        .eq('isvoid', false)
        .gte('paiddate', _d(from))
        .lte('paiddate', _d(to))
        .order('paiddate')
        .limit(5000);

    return rows.map<Map<String, dynamic>>((r) {
      final row = Map<String, dynamic>.from(r);
      final v = row['ws_tblvendors'] as Map<String, dynamic>?;
      row['vendorname'] = v?['vendorname'];
      return row;
    }).toList();
  }

  /// Everyone who owes you money, largest first. No date window: a receivable
  /// is a position as of now, not an activity over a period.
  static Future<List<Map<String, dynamic>>> fetchReceivableSummary() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('vw_ws_customerbalance')
        .select()
        .eq('orgid', orgId)
        .order('outstandingdue', ascending: false);
    return rows.cast<Map<String, dynamic>>();
  }

  /// Everyone you owe.
  static Future<List<Map<String, dynamic>>> fetchPayableSummary() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('ws_tblvendors')
        .select('vendorid, vendorname, phone, openingbalance')
        .eq('orgid', orgId)
        .eq('isactive', true)
        .order('vendorname');
    return rows.cast<Map<String, dynamic>>();
  }

  /// Customers with their currently recorded opening figures.
  static Future<List<Map<String, dynamic>>> fetchCustomerOpenings() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('ws_tblcustomers')
        .select('customerid, customername, openingbalance')
        .eq('orgid', orgId)
        .eq('isactive', true)
        .order('customername');
    return rows.cast<Map<String, dynamic>>();
  }

  /// Vendors with their currently recorded opening figures.
  static Future<List<Map<String, dynamic>>> fetchVendorOpenings() async {
    if (!supabaseClientInitialized) return [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return [];
    final rows = await supabase
        .from('ws_tblvendors')
        .select('vendorid, vendorname, openingbalance')
        .eq('orgid', orgId)
        .eq('isactive', true)
        .order('vendorname');
    return rows.cast<Map<String, dynamic>>();
  }
}

extension _FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
