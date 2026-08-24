// =============================================================================
// lib/models/ws_models.dart
// All WaterFlow data models
// =============================================================================

// ─── JSON coercion helpers ────────────────────────────────────────────────────
//
// PostgREST returns column names in the exact case they are stored, which for
// this schema is lowercase. It also returns `numeric` columns as JSON numbers
// but `bigint` as int and occasionally as String depending on the driver path,
// so every numeric read goes through these instead of a bare cast.
//
// The original code used `(j['a'] ?? j['B'] as num).toDouble()`. Dart binds `as`
// tighter than `??`, so that parses as `j['a'] ?? (j['B'] as num)` — the cast
// applies to the fallback only, and when both keys are missing it throws a
// TypeError on `null as num` instead of yielding null. Fixed by these helpers.

/// First non-null value among [keys].
Object? _pick(Map<String, dynamic> j, List<String> keys) {
  for (final k in keys) {
    final v = j[k];
    if (v != null) return v;
  }
  return null;
}

double? _optDouble(Map<String, dynamic> j, List<String> keys) {
  final v = _pick(j, keys);
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

double _reqDouble(Map<String, dynamic> j, List<String> keys, [double fallback = 0]) =>
    _optDouble(j, keys) ?? fallback;

int? _optInt(Map<String, dynamic> j, List<String> keys) {
  final v = _pick(j, keys);
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

int _reqInt(Map<String, dynamic> j, List<String> keys, [int fallback = 0]) =>
    _optInt(j, keys) ?? fallback;

String? _optStr(Map<String, dynamic> j, List<String> keys) {
  final v = _pick(j, keys);
  return v?.toString();
}

String _reqStr(Map<String, dynamic> j, List<String> keys, [String fallback = '']) =>
    _optStr(j, keys) ?? fallback;

bool _reqBool(Map<String, dynamic> j, List<String> keys, [bool fallback = true]) {
  final v = _pick(j, keys);
  if (v == null) return fallback;
  if (v is bool) return v;
  final s = v.toString().toLowerCase();
  return s == 'true' || s == 't' || s == '1';
}

DateTime? _optDate(Map<String, dynamic> j, List<String> keys) {
  final v = _optStr(j, keys);
  if (v == null) return null;
  return DateTime.tryParse(v);
}

// ─── Enums ────────────────────────────────────────────────────────────────────

/// Coarse role, kept only for routing (staff dashboard vs customer portal) and
/// for the demo store. It cannot express the six roles the system supports —
/// use [WsPermissions] for anything that gates a feature.
enum WsUserRole { admin, staff, customer }

enum WsBottleCondition { perfect, needsCleaning, damaged, lost }

enum WsPaymentMethod { cash, easypaisa, jazzcash, bank, other }

extension WsBottleConditionX on WsBottleCondition {
  String get label => const {
    WsBottleCondition.perfect:       'Perfect',
    WsBottleCondition.needsCleaning: 'Needs Cleaning',
    WsBottleCondition.damaged:       'Damaged',
    WsBottleCondition.lost:          'Lost',
  }[this]!;

  String get emoji => const {
    WsBottleCondition.perfect:       '✅',
    WsBottleCondition.needsCleaning: '🧹',
    WsBottleCondition.damaged:       '⚠️',
    WsBottleCondition.lost:          '❌',
  }[this]!;
}

extension WsPaymentMethodX on WsPaymentMethod {
  String get label => const {
    WsPaymentMethod.cash:       'Cash',
    WsPaymentMethod.easypaisa:  'Easypaisa',
    WsPaymentMethod.jazzcash:   'JazzCash',
    WsPaymentMethod.bank:       'Bank Transfer',
    WsPaymentMethod.other:      'Other',
  }[this]!;

  String get emoji => const {
    WsPaymentMethod.cash:       '💵',
    WsPaymentMethod.easypaisa:  '📱',
    WsPaymentMethod.jazzcash:   '💜',
    WsPaymentMethod.bank:       '🏦',
    WsPaymentMethod.other:      '💳',
  }[this]!;

  /// Maps the `methodcode` stored in ws_tblpaymentmethods. Unknown codes fall
  /// back to `other` rather than silently becoming `cash`, so a tenant-defined
  /// wallet is never mis-reported as a cash collection.
  static WsPaymentMethod fromCode(String code) {
    switch (code.toLowerCase()) {
      case 'cash':      return WsPaymentMethod.cash;
      case 'easypaisa': return WsPaymentMethod.easypaisa;
      case 'jazzcash':  return WsPaymentMethod.jazzcash;
      case 'bank':      return WsPaymentMethod.bank;
      default:          return WsPaymentMethod.other;
    }
  }
}

// ─── Organization ─────────────────────────────────────────────────────────────

class WsOrganization {
  final int    orgId;
  /// Owner's auth uid. Retained for display and billing only — it is NOT an
  /// access-control field. Membership decides who can see what.
  final String authUserId;
  final String orgName;

  /// Trading name. Falls back to orgName when blank — see [displayName].
  final String businessName;

  final String ownerName;
  final String phone;
  final String address;
  final bool   isActive;
  final String currencySymbol;
  final String receiptPrefix;
  final String? logoUrl;
  /// Per-tenant delivery-card layout from ws_tblorganization.cardsettings.
  final Map<String, dynamic>? cardSettings;

  const WsOrganization({
    required this.orgId,
    required this.authUserId,
    required this.orgName,
    this.businessName = '',
    required this.ownerName,
    required this.phone,
    required this.address,
    this.isActive = true,
    this.currencySymbol = 'Rs',
    this.receiptPrefix = 'RCPT-',
    this.logoUrl,
    this.cardSettings,
  });

  /// What to PRINT. The Organization form tells the user the trading name is
  /// "printed on delivery cards and receipts if set", so something has to
  /// honour that — otherwise the field is a lie with a text input attached.
  String get displayName =>
      businessName.trim().isNotEmpty ? businessName.trim() : orgName;

  factory WsOrganization.fromJson(Map<String, dynamic> j) => WsOrganization(
    orgId:      _reqInt(j, ['orgid', 'OrgID']),
    authUserId: _reqStr(j, ['owneruserid', 'authuserid', 'AuthUserID']),
    orgName:    _reqStr(j, ['orgname', 'OrgName']),
    businessName: _reqStr(j, ['businessname'], ''),
    ownerName:  _reqStr(j, ['ownername', 'OwnerName']),
    phone:      _reqStr(j, ['phone', 'Phone']),
    address:    _reqStr(j, ['address', 'Address']),
    isActive:   _reqBool(j, ['isactive', 'IsActive']),
    currencySymbol: _reqStr(j, ['currencysymbol'], 'Rs'),
    receiptPrefix:  _reqStr(j, ['receiptprefix'], 'RCPT-'),
    logoUrl:        _optStr(j, ['logourl']),
    cardSettings:   (_pick(j, ['cardsettings']) as Map?)?.cast<String, dynamic>(),
  );
}

// ─── Internal User ────────────────────────────────────────────────────────────

class WsInternalUser {
  final int        internalUserId;
  final int        orgId;
  final String     authUserId;
  final String     fullName;
  final WsUserRole role;
  /// Raw role code from the database ('owner', 'admin', 'accountant', 'sales',
  /// 'delivery', 'readonly'). [role] collapses these to two values for routing.
  final String     roleCode;
  final String?    phone;
  final bool       isActive;

  const WsInternalUser({
    required this.internalUserId,
    required this.orgId,
    required this.authUserId,
    required this.fullName,
    required this.role,
    this.roleCode = 'staff',
    this.phone,
    this.isActive = true,
  });

  factory WsInternalUser.fromJson(Map<String, dynamic> j) {
    // PostgREST returns 'role', never 'Role'. Reading the PascalCase key made
    // this expression always false, silently demoting every admin to staff.
    final roleCode = _reqStr(j, ['role', 'Role'], 'staff').toLowerCase();
    return WsInternalUser(
      internalUserId: _reqInt(j, ['internaluserid', 'InternalUserID']),
      orgId:          _reqInt(j, ['orgid', 'OrgID']),
      authUserId:     _reqStr(j, ['authuserid', 'AuthUserID']),
      fullName:       _reqStr(j, ['fullname', 'FullName']),
      roleCode:       roleCode,
      role:           (roleCode == 'admin' || roleCode == 'owner')
                          ? WsUserRole.admin
                          : WsUserRole.staff,
      phone:          _optStr(j, ['phone', 'Phone']),
      isActive:       _reqBool(j, ['isactive', 'IsActive']),
    );
  }
}

// ─── Area ─────────────────────────────────────────────────────────────────────

class WsArea {
  final int    areaId;
  final int    orgId;
  final String areaName;
  final double ratePerBottle;
  final String? deliveryDays;
  final bool   isActive;

  // computed (joined)
  final int?    customerCount;
  final int?    bottlesWithCustomers;
  final int?    deliveredThisMonth;

  const WsArea({
    required this.areaId,
    required this.orgId,
    required this.areaName,
    required this.ratePerBottle,
    this.deliveryDays,
    this.isActive = true,
    this.customerCount,
    this.bottlesWithCustomers,
    this.deliveredThisMonth,
  });

  factory WsArea.fromJson(Map<String, dynamic> j) => WsArea(
    areaId:        _reqInt(j, ['areaid', 'AreaID']),
    orgId:         _reqInt(j, ['orgid', 'OrgID']),
    areaName:      _reqStr(j, ['areaname', 'AreaName']),
    ratePerBottle: _reqDouble(j, ['rateperbottle', 'RatePerBottle']),
    deliveryDays:  _optStr(j, ['deliverydays', 'DeliveryDays']),
    isActive:      _reqBool(j, ['isactive', 'IsActive']),
  );

  Map<String, dynamic> toInsert() => {
    'orgid':         orgId,
    'areaname':      areaName,
    'rateperbottle': ratePerBottle,
    'deliverydays':  deliveryDays,
    'isactive':      isActive,
  };

  /// Same as [toInsert] plus the primary key, for updates. See the note on
  /// WsCustomer.toUpdate() — upserting without a key duplicates rows.
  Map<String, dynamic> toUpdate() => {
    ...toInsert(),
    'areaid': areaId,
  };
}

// ─── Customer ─────────────────────────────────────────────────────────────────

class WsCustomer {
  final int     customerId;
  final int     orgId;
  final String? authUserId;      // null = no portal access
  final int     areaId;
  final String? customerCode;
  final String  customerName;
  final String? contactPerson;
  final String? address;
  final String? phone;
  final double? rateOverride;    // null = use area rate
  final double  depositAmount;
  final int     bottleBalance;
  final bool    isActive;
  final DateTime createdDate;

  // joined
  final String? areaName;
  final double? areaRate;
  final double? outstandingDue;  // from vw_ws_customerbalance
  /// Refundable value of the bottles this customer currently holds, summed
  /// across every bottle type. Null when read from a source that omits it.
  final double? bottleDepositValue;

  /// Display-only estimate. The authoritative price comes from
  /// ws_resolve_price() on the server, which also honours customer groups and
  /// effective-date windows that this expression cannot see.
  double get effectiveRate => rateOverride ?? areaRate ?? 0;

  const WsCustomer({
    required this.customerId,
    required this.orgId,
    this.authUserId,
    required this.areaId,
    this.customerCode,
    required this.customerName,
    this.contactPerson,
    this.address,
    this.phone,
    this.rateOverride,
    this.depositAmount = 0,
    required this.bottleBalance,
    this.isActive = true,
    required this.createdDate,
    this.areaName,
    this.areaRate,
    this.outstandingDue,
    this.bottleDepositValue,
  });

  factory WsCustomer.fromJson(Map<String, dynamic> j) => WsCustomer(
    customerId:    _reqInt(j, ['customerid', 'CustomerID']),
    orgId:         _reqInt(j, ['orgid', 'OrgID']),
    authUserId:    _optStr(j, ['authuserid', 'AuthUserID']),
    areaId:        _reqInt(j, ['areaid', 'AreaID']),
    customerCode:  _optStr(j, ['customercode']),
    customerName:  _reqStr(j, ['customername', 'CustomerName']),
    contactPerson: _optStr(j, ['contactperson']),
    address:       _optStr(j, ['address', 'Address']),
    phone:         _optStr(j, ['phone', 'Phone']),
    rateOverride:  _optDouble(j, ['rateoverride', 'RateOverride']),
    depositAmount: _reqDouble(j, ['depositamount', 'DepositAmount']),
    bottleBalance: _reqInt(j, ['bottlebalance', 'BottleBalance']),
    isActive:      _reqBool(j, ['isactive', 'IsActive']),
    createdDate:   _optDate(j, ['createddate', 'CreatedDate']) ?? DateTime.now(),
    // Joined from ws_tblareas or flattened out of vw_ws_customerbalance.
    areaName:      _optStr(j, ['areaname', 'AreaName']),
    areaRate:      _optDouble(j, ['rateperbottle', 'RatePerBottle']),
    outstandingDue: _optDouble(j, ['outstandingdue', 'OutstandingDue']),
    bottleDepositValue: _optDouble(j, ['bottledepositvalue']),
  );

  /// Column map for a NEW customer. Deliberately omits customerid so the
  /// database assigns it.
  Map<String, dynamic> toInsert() => {
    'orgid':          orgId,
    'areaid':         areaId,
    'customercode':   customerCode,
    'customername':   customerName,
    'contactperson':  contactPerson,
    'address':        address,
    'phone':          phone,
    'rateoverride':   rateOverride,
    'depositamount':  depositAmount,
    'isactive':       isActive,
    // bottlebalance is a trigger-maintained cache of the default bottle type.
    // Writing it from the client would be overwritten on the next delivery.
  };

  /// Column map for an EXISTING customer. Includes the primary key.
  ///
  /// The previous code passed toInsert() to .upsert(). With no key in the
  /// payload and no conflict target, PostgREST had nothing to match on, so
  /// every edit inserted a duplicate row instead of updating.
  Map<String, dynamic> toUpdate() => {
    ...toInsert(),
    'customerid': customerId,
  };
}

// ─── Delivery ─────────────────────────────────────────────────────────────────

class WsDelivery {
  final int      deliveryId;
  final int      orgId;
  final int      customerId;
  final int?     deliveredById;
  final DateTime deliveryDate;
  final String?  referenceNo;
  final int      bottlesDelivered;
  final int      bottlesReturned;
  final int      bottleBalance;
  final double   rateApplied;
  final double   amountCharged;
  final String?  notes;

  // joined
  final String?  customerName;
  final String?  deliveredByName;
  final double?  amountReceived;   // payment linked
  final double?  runningBalance;

  const WsDelivery({
    required this.deliveryId,
    required this.orgId,
    required this.customerId,
    this.deliveredById,
    required this.deliveryDate,
    this.referenceNo,
    required this.bottlesDelivered,
    required this.bottlesReturned,
    required this.bottleBalance,
    required this.rateApplied,
    required this.amountCharged,
    this.notes,
    this.customerName,
    this.deliveredByName,
    this.amountReceived,
    this.runningBalance,
  });

  factory WsDelivery.fromJson(Map<String, dynamic> j) => WsDelivery(
    deliveryId:       _reqInt(j, ['deliveryid', 'DeliveryID']),
    orgId:            _reqInt(j, ['orgid', 'OrgID']),
    customerId:       _reqInt(j, ['customerid', 'CustomerID']),
    deliveredById:    _optInt(j, ['deliveredbyid', 'DeliveredByID']),
    deliveryDate:     _optDate(j, ['deliverydate', 'DeliveryDate']) ?? DateTime.now(),
    referenceNo:      _optStr(j, ['referenceno']),
    bottlesDelivered: _reqInt(j, ['bottlesdelivered', 'BottlesDelivered']),
    bottlesReturned:  _reqInt(j, ['bottlesreturned', 'BottlesReturned']),
    bottleBalance:    _reqInt(j, ['bottlebalance', 'BottleBalance']),
    rateApplied:      _reqDouble(j, ['rateapplied', 'RateApplied']),
    amountCharged:    _reqDouble(j, ['amountcharged', 'AmountCharged']),
    notes:            _optStr(j, ['notes', 'Notes']),
    customerName:     _optStr(j, ['customername', 'CustomerName']),
    deliveredByName:  _optStr(j, ['deliveredbyname', 'DeliveredByName']),
    amountReceived:   _optDouble(j, ['amountreceived', 'AmountReceived']),
  );

  /// Header-only insert. Bottle counts now live on ws_tbldeliverydetails and
  /// every derived column (bottlebalance, rateapplied, amountcharged) is
  /// computed by trigger and discarded if the client sends it.
  ///
  /// Prefer WsDataService.recordDelivery(), which calls the ws_record_delivery
  /// RPC so the delivery, its lines, the bottle movements and any payment all
  /// commit or roll back together.
  Map<String, dynamic> toInsert() => {
    'orgid':            orgId,
    'customerid':       customerId,
    'deliveredbyid':    deliveredById,
    'deliverydate':     deliveryDate.toIso8601String().split('T').first,
    'notes':            notes,
  };
}

// ─── Payment ──────────────────────────────────────────────────────────────────

class WsPayment {
  final int              paymentId;
  final int              orgId;
  final int              customerId;
  final int?             deliveryId;
  final int?             receivedById;
  final DateTime         paymentDate;
  final double           amountReceived;
  final WsPaymentMethod  paymentMethod;
  final String?          receiptNo;
  final String?          referenceNo;
  final String?          notes;

  // joined
  final String? customerName;
  final String? receivedByName;

  const WsPayment({
    required this.paymentId,
    required this.orgId,
    required this.customerId,
    this.deliveryId,
    this.receivedById,
    required this.paymentDate,
    required this.amountReceived,
    required this.paymentMethod,
    this.receiptNo,
    this.referenceNo,
    this.notes,
    this.customerName,
    this.receivedByName,
  });

  factory WsPayment.fromJson(Map<String, dynamic> j) {
    final code = _reqStr(j, ['paymentmethod', 'PaymentMethod'], 'cash').toLowerCase();
    return WsPayment(
      paymentId:      _reqInt(j, ['paymentid', 'PaymentID']),
      orgId:          _reqInt(j, ['orgid', 'OrgID']),
      customerId:     _reqInt(j, ['customerid', 'CustomerID']),
      deliveryId:     _optInt(j, ['deliveryid', 'DeliveryID']),
      receivedById:   _optInt(j, ['receivedbyid', 'ReceivedByID']),
      paymentDate:    _optDate(j, ['paymentdate', 'PaymentDate']) ?? DateTime.now(),
      amountReceived: _reqDouble(j, ['amountreceived', 'AmountReceived']),
      paymentMethod:  WsPaymentMethodX.fromCode(code),
      receiptNo:      _optStr(j, ['receiptno']),
      referenceNo:    _optStr(j, ['referenceno', 'ReferenceNo']),
      notes:          _optStr(j, ['notes', 'Notes']),
      customerName:   _optStr(j, ['customername', 'CustomerName']),
      receivedByName: _optStr(j, ['receivedbyname', 'ReceivedByName']),
    );
  }

  Map<String, dynamic> toInsert() => {
    'orgid':          orgId,
    'customerid':     customerId,
    'deliveryid':     deliveryId,
    'receivedbyid':   receivedById,
    'paymentdate':    paymentDate.toIso8601String().split('T').first,
    'amountreceived': amountReceived,
    'paymentmethod':  paymentMethod.name,
    'referenceno':    referenceNo,
    'notes':          notes,
    // receiptno is assigned by ws.next_docnumber() so numbering stays gapless
    // and per-tenant; sending one from the client would race.
  };
}

// ─── Bottle Inventory Snapshot ────────────────────────────────────────────────
//
// WsBottleSnapshot was removed with the two service methods that were its only
// users. It mapped ws_tblbottleinventory — a hand-populated snapshot table that
// nothing in the app ever wrote to, so everything derived from it read zero.
//
// WsBottlePosition, built from vw_ws_bottleposition, replaced it: the same
// figures derived from the append-only bottle ledger. The database table is
// untouched; only the client model went.

// ─── Dashboard KPIs ───────────────────────────────────────────────────────────

class WsDashboardStats {
  final int    bottlesInHand;         // with customers
  final int    bottlesDeliveredMonth;
  final int    emptyBottlesReturned;
  final int    filledInStock;
  final double totalReceivable;
  final int    bottlesNeedAttention;  // cleaning + damaged
  final int    totalCustomers;
  final int    activeCustomers;

  // From vw_ws_dashboard.
  final double todaySales;
  final double todayCollections;
  final int    todayDeliveries;
  final double payables;
  /// Rows in vw_ws_reconciliation. Anything above zero means the journal and
  /// the subsidiary ledgers disagree, so the reports cannot be trusted. Show it
  /// on the dashboard rather than logging it somewhere nobody reads.
  final int    reconciliationIssues;

  const WsDashboardStats({
    required this.bottlesInHand,
    required this.bottlesDeliveredMonth,
    required this.emptyBottlesReturned,
    required this.filledInStock,
    required this.totalReceivable,
    required this.bottlesNeedAttention,
    required this.totalCustomers,
    required this.activeCustomers,
    this.todaySales = 0,
    this.todayCollections = 0,
    this.todayDeliveries = 0,
    this.payables = 0,
    this.reconciliationIssues = 0,
  });

  factory WsDashboardStats.fromJson(Map<String, dynamic> j) => WsDashboardStats(
    bottlesInHand:         _reqInt(j, ['bottlesout']),
    bottlesDeliveredMonth: _reqInt(j, ['bottlesdeliveredmonth']),
    emptyBottlesReturned:  _reqInt(j, ['emptybottlesreturned']),
    filledInStock:         _reqInt(j, ['bottlesinstock']),
    totalReceivable:       _reqDouble(j, ['receivables']),
    bottlesNeedAttention:  _reqInt(j, ['bottlesneedattention']),
    totalCustomers:        _reqInt(j, ['totalcustomers']),
    activeCustomers:       _reqInt(j, ['totalcustomers']),
    todaySales:            _reqDouble(j, ['todaysales']),
    todayCollections:      _reqDouble(j, ['todaycollections']),
    todayDeliveries:       _reqInt(j, ['todaydeliveries']),
    payables:              _reqDouble(j, ['payables']),
    reconciliationIssues:  _reqInt(j, ['reconciliationissues']),
  );

  bool get isReconciled => reconciliationIssues == 0;
}

// ─── Permissions ──────────────────────────────────────────────────────────────
//
// Replaces role checks in the UI. The old three-value WsUserRole enum could not
// express the six roles the system defines (owner, admin, accountant, sales,
// delivery, read-only), so any widget that said `if (role == admin)` was either
// too permissive or too strict for four of them.
//
// This is a UI convenience only. The database enforces the same permissions in
// RLS via ws.has_perm(); hiding a button does not protect a table.

class WsPermissions {
  final Set<String> codes;

  const WsPermissions(this.codes);

  const WsPermissions.none() : codes = const {};

  bool has(String code) => codes.contains(code);
  bool any(List<String> anyOf) => anyOf.any(codes.contains);

  bool get canViewCustomers  => has('customers.view');
  bool get canEditCustomers  => has('customers.manage');
  bool get canViewVendors    => has('vendors.view');
  bool get canEditVendors    => has('vendors.manage');
  bool get canEditProducts   => has('products.manage');
  bool get canRecordDelivery => has('delivery.manage');
  bool get canRecordPayment  => has('payments.manage');
  bool get canViewAccounting => has('accounting.view');
  bool get canManageUsers    => has('users.manage');
  bool get canManageOrg      => has('org.manage');

  @override
  String toString() => 'WsPermissions(${codes.length} codes)';
}

// ─── Bottle balance, per customer per bottle type ─────────────────────────────
//
// A customer can hold a 19L and a 20L bottle at the same time. The single
// WsCustomer.bottleBalance integer cannot represent that; it now caches the
// default bottle type only.

class WsBottleBalance {
  final int    customerId;
  final int    bottleTypeId;
  final String bottleCode;
  final String bottleName;
  final bool   isDefault;
  final int    balance;
  final double depositValue;

  const WsBottleBalance({
    required this.customerId,
    required this.bottleTypeId,
    required this.bottleCode,
    required this.bottleName,
    required this.isDefault,
    required this.balance,
    this.depositValue = 0,
  });

  factory WsBottleBalance.fromJson(Map<String, dynamic> j) => WsBottleBalance(
    customerId:   _reqInt(j, ['customerid']),
    bottleTypeId: _reqInt(j, ['bottletypeid']),
    bottleCode:   _reqStr(j, ['bottlecode']),
    bottleName:   _reqStr(j, ['bottlename']),
    isDefault:    _reqBool(j, ['isdefault'], false),
    balance:      _reqInt(j, ['balance']),
    depositValue: _reqDouble(j, ['depositvalue']),
  );
}

// ─── Delivery card row (vw_ws_deliverycard) ───────────────────────────────────
//
// One row per date, matching the columns on the physical card:
// Date | Delivery Bottles | Received Bottles | Bottle Balance
//      | Total Amount | Amount Received

class WsDeliveryCardRow {
  final DateTime entryDate;
  final int      deliveryBottles;
  final int      receivedBottles;
  final int      bottleBalance;
  final double   totalAmount;
  final double   amountReceived;
  final double   runningBalance;
  final String?  referenceNo;

  const WsDeliveryCardRow({
    required this.entryDate,
    required this.deliveryBottles,
    required this.receivedBottles,
    required this.bottleBalance,
    required this.totalAmount,
    required this.amountReceived,
    required this.runningBalance,
    this.referenceNo,
  });

  factory WsDeliveryCardRow.fromJson(Map<String, dynamic> j) => WsDeliveryCardRow(
    entryDate:       _optDate(j, ['entrydate']) ?? DateTime.now(),
    deliveryBottles: _reqInt(j, ['deliverybottles']),
    receivedBottles: _reqInt(j, ['receivedbottles']),
    bottleBalance:   _reqInt(j, ['bottlebalance']),
    totalAmount:     _reqDouble(j, ['totalamount']),
    amountReceived:  _reqDouble(j, ['amountreceived']),
    runningBalance:  _reqDouble(j, ['runningbalance']),
    referenceNo:     _optStr(j, ['referenceno']),
  );
}

// ─── Customer ledger row (vw_ws_customerledger) ───────────────────────────────

class WsLedgerRow {
  final DateTime date;
  final int      sortKey;
  final String   description;
  final String?  referenceNo;
  final double   debit;
  final double   credit;
  final double   balance;

  const WsLedgerRow({
    required this.date,
    required this.sortKey,
    required this.description,
    this.referenceNo,
    required this.debit,
    required this.credit,
    required this.balance,
  });

  factory WsLedgerRow.fromJson(Map<String, dynamic> j) => WsLedgerRow(
    date:        _optDate(j, ['txndate']) ?? DateTime.now(),
    // sortkey disambiguates a delivery and its payment on the same date.
    // Without it "the closing balance" is whichever row the sort happened to
    // put last.
    sortKey:     _reqInt(j, ['sortkey']),
    description: _reqStr(j, ['description']),
    referenceNo: _optStr(j, ['referenceno']),
    debit:       _reqDouble(j, ['debit']),
    credit:      _reqDouble(j, ['credit']),
    balance:     _reqDouble(j, ['balance']),
  );
}

// ─── Delivery card bundle ─────────────────────────────────────────────────────
//
// Everything the printed card needs, fetched together so the PDF builder never
// issues its own queries. A report that fetches while rendering produces a
// document whose sections were read at different moments.

class WsDeliveryCardData {
  final WsOrganization org;
  final WsCustomer customer;
  final List<WsDeliveryCardRow> rows;
  final List<WsBottleBalance> bottleBalances;
  final DateTime? periodFrom;
  final DateTime? periodTo;

  const WsDeliveryCardData({
    required this.org,
    required this.customer,
    required this.rows,
    this.bottleBalances = const [],
    this.periodFrom,
    this.periodTo,
  });

  bool get isEmpty => rows.isEmpty;
}

// ─── Bottle position (vw_ws_bottleposition) ───────────────────────────────────
//
// Derived from the bottle ledger. Replaces ws_tblbottleinventory, which only
// held whatever someone last chose to snapshot — and nothing in the app ever
// took a snapshot, so it was permanently empty and every tile read zero.

class WsBottlePosition {
  final int withCustomers;
  final int inStock;
  final int lost;
  final int damaged;
  /// One row per bottle type, straight from the view.
  final List<Map<String, dynamic>> byType;

  const WsBottlePosition({
    required this.withCustomers,
    required this.inStock,
    required this.lost,
    required this.damaged,
    this.byType = const [],
  });

  int get total => withCustomers + inStock;

  /// Share of bottles accounted for — i.e. not lost or damaged.
  double get healthScore {
    final t = total + lost + damaged;
    return t > 0 ? (total / t) * 100 : 0;
  }
}
