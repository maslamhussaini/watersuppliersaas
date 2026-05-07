// =============================================================================
// lib/models/ws_models.dart
// All WaterFlow data models
// =============================================================================

// ─── Enums ────────────────────────────────────────────────────────────────────

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
}

// ─── Organization ─────────────────────────────────────────────────────────────

class WsOrganization {
  final int    orgId;
  final String authUserId;
  final String orgName;
  final String ownerName;
  final String phone;
  final String address;
  final bool   isActive;

  const WsOrganization({
    required this.orgId,
    required this.authUserId,
    required this.orgName,
    required this.ownerName,
    required this.phone,
    required this.address,
    this.isActive = true,
  });

  factory WsOrganization.fromJson(Map<String, dynamic> j) => WsOrganization(
    orgId:     j['orgid'] ?? j['OrgID'],
    authUserId:j['authuserid'] ?? j['AuthUserID'],
    orgName:   j['orgname'] ?? j['OrgName'],
    ownerName: j['ownername'] ?? j['OwnerName'] ?? '',
    phone:     j['phone'] ?? j['Phone']    ?? '',
    address:   j['address'] ?? j['Address']  ?? '',
    isActive:  j['isactive'] ?? j['IsActive'] ?? true,
  );
}

// ─── Internal User ────────────────────────────────────────────────────────────

class WsInternalUser {
  final int        internalUserId;
  final int        orgId;
  final String     authUserId;
  final String     fullName;
  final WsUserRole role;
  final String?    phone;
  final bool       isActive;

  const WsInternalUser({
    required this.internalUserId,
    required this.orgId,
    required this.authUserId,
    required this.fullName,
    required this.role,
    this.phone,
    this.isActive = true,
  });

  factory WsInternalUser.fromJson(Map<String, dynamic> j) => WsInternalUser(
    internalUserId: j['internaluserid'] ?? j['InternalUserID'],
    orgId:          j['orgid'] ?? j['OrgID'],
    authUserId:     j['authuserid'] ?? j['AuthUserID'],
    fullName:       j['fullname'] ?? j['FullName'],
    role:           (j['role'] ?? j['Role']) == 'admin' ? WsUserRole.admin : WsUserRole.staff,
    phone:          j['phone'] ?? j['Phone'],
    isActive:       j['isactive'] ?? j['IsActive'] ?? true,
  );
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
    areaId:        j['areaid'] ?? j['AreaID'],
    orgId:         j['orgid'] ?? j['OrgID'],
    areaName:      j['areaname'] ?? j['AreaName'],
    ratePerBottle: (j['rateperbottle'] ?? j['RatePerBottle'] as num).toDouble(),
    deliveryDays:  j['deliverydays'] ?? j['DeliveryDays'],
    isActive:      j['isactive'] ?? j['IsActive'] ?? true,
  );

  Map<String, dynamic> toInsert() => {
    'orgid':         orgId,
    'areaname':      areaName,
    'rateperbottle': ratePerBottle,
    'deliverydays':  deliveryDays,
    'isactive':      isActive,
  };
}

// ─── Customer ─────────────────────────────────────────────────────────────────

class WsCustomer {
  final int     customerId;
  final int     orgId;
  final String? authUserId;      // null = no portal access
  final int     areaId;
  final String  customerName;
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
  final double? outstandingDue;  // from vw_ws_CustomerBalance

  double get effectiveRate => rateOverride ?? areaRate ?? 0;

  const WsCustomer({
    required this.customerId,
    required this.orgId,
    this.authUserId,
    required this.areaId,
    required this.customerName,
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
  });

  factory WsCustomer.fromJson(Map<String, dynamic> j) {
    // If rate override exists, safely parse it
    final ro = j['rateoverride'] ?? j['RateOverride'];
    final dp = j['depositamount'] ?? j['DepositAmount'] ?? 0;
    
    // joined fields from vw_ws_CustomerBalance or ws_tblAreas might be lowercase or pascal based on view/join
    final arName = j['areaname'] ?? j['AreaName'];
    final aRate  = j['rateperbottle'] ?? j['RatePerBottle'];
    final outDue = j['outstandingdue'] ?? j['OutstandingDue'];

    return WsCustomer(
      customerId:    j['customerid'] ?? j['CustomerID'],
      orgId:         j['orgid'] ?? j['OrgID'],
      authUserId:    j['authuserid'] ?? j['AuthUserID'],
      areaId:        j['areaid'] ?? j['AreaID'],
      customerName:  j['customername'] ?? j['CustomerName'],
      address:       j['address'] ?? j['Address'],
      phone:         j['phone'] ?? j['Phone'],
      rateOverride:  ro != null ? (ro as num).toDouble() : null,
      depositAmount: (dp as num).toDouble(),
      bottleBalance: j['bottlebalance'] ?? j['BottleBalance'] ?? 0,
      isActive:      j['isactive'] ?? j['IsActive'] ?? true,
      createdDate:   DateTime.parse(j['createddate'] ?? j['CreatedDate'] ?? DateTime.now().toIso8601String()),
      areaName:      arName,
      areaRate:      aRate != null ? (aRate as num).toDouble() : null,
      outstandingDue:outDue != null ? (outDue as num).toDouble() : null,
    );
  }

  Map<String, dynamic> toInsert() => {
    'orgid':          orgId,
    'areaid':         areaId,
    'customername':   customerName,
    'address':        address,
    'phone':          phone,
    'rateoverride':   rateOverride,
    'depositamount':  depositAmount,
    'isactive':       isActive,
  };
}

// ─── Delivery ─────────────────────────────────────────────────────────────────

class WsDelivery {
  final int      deliveryId;
  final int      orgId;
  final int      customerId;
  final int?     deliveredById;
  final DateTime deliveryDate;
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
    deliveryId:       j['deliveryid'] ?? j['DeliveryID'],
    orgId:            j['orgid'] ?? j['OrgID'],
    customerId:       j['customerid'] ?? j['CustomerID'],
    deliveredById:    j['deliveredbyid'] ?? j['DeliveredByID'],
    deliveryDate:     DateTime.parse(j['deliverydate'] ?? j['DeliveryDate']),
    bottlesDelivered: j['bottlesdelivered'] ?? j['BottlesDelivered'],
    bottlesReturned:  j['bottlesreturned'] ?? j['BottlesReturned'],
    bottleBalance:    j['bottlebalance'] ?? j['BottleBalance'],
    rateApplied:      (j['rateapplied'] ?? j['RateApplied'] as num).toDouble(),
    amountCharged:    (j['amountcharged'] ?? j['AmountCharged'] as num).toDouble(),
    notes:            j['notes'] ?? j['Notes'],
    customerName:     j['customername'] ?? j['CustomerName'],
    deliveredByName:  j['deliveredbyname'] ?? j['DeliveredByName'],
  );

  Map<String, dynamic> toInsert() => {
    'orgid':            orgId,
    'customerid':       customerId,
    'deliveredbyid':    deliveredById,
    'deliverydate':     deliveryDate.toIso8601String().split('T').first,
    'bottlesdelivered': bottlesDelivered,
    'bottlesreturned':  bottlesReturned,
    'notes':            notes,
    // BottleBalance, RateApplied, AmountCharged are auto-computed by trigger
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
    this.referenceNo,
    this.notes,
    this.customerName,
    this.receivedByName,
  });

  factory WsPayment.fromJson(Map<String, dynamic> j) {
    WsPaymentMethod method;
    switch ((j['paymentmethod'] ?? j['PaymentMethod'] ?? 'cash').toLowerCase()) {
      case 'easypaisa': method = WsPaymentMethod.easypaisa; break;
      case 'jazzcash':  method = WsPaymentMethod.jazzcash;  break;
      case 'bank':      method = WsPaymentMethod.bank;      break;
      case 'other':     method = WsPaymentMethod.other;     break;
      default:          method = WsPaymentMethod.cash;
    }
    return WsPayment(
      paymentId:      j['paymentid'] ?? j['PaymentID'],
      orgId:          j['orgid'] ?? j['OrgID'],
      customerId:     j['customerid'] ?? j['CustomerID'],
      deliveryId:     j['deliveryid'] ?? j['DeliveryID'],
      receivedById:   j['receivedbyid'] ?? j['ReceivedByID'],
      paymentDate:    DateTime.parse(j['paymentdate'] ?? j['PaymentDate']),
      amountReceived: (j['amountreceived'] ?? j['AmountReceived'] as num).toDouble(),
      paymentMethod:  method,
      referenceNo:    j['referenceno'] ?? j['ReferenceNo'],
      notes:          j['notes'] ?? j['Notes'],
      customerName:   j['customername'] ?? j['CustomerName'],
      receivedByName: j['receivedbyname'] ?? j['ReceivedByName'],
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
  };
}

// ─── Bottle Inventory Snapshot ────────────────────────────────────────────────

class WsBottleSnapshot {
  final int      inventoryId;
  final int      orgId;
  final DateTime snapshotDate;
  final int      totalBottles;
  final int      bottlesWithCustomers;
  final int      bottlesInStock;
  final int      bottlesLost;
  final String?  notes;

  // computed from ws_tblCustomers
  final int? perfect;
  final int? needsCleaning;
  final int? damaged;
  final int? emptyReturned;

  double get healthScore =>
      totalBottles > 0 ? ((perfect ?? 0) / totalBottles * 100) : 0;

  const WsBottleSnapshot({
    required this.inventoryId,
    required this.orgId,
    required this.snapshotDate,
    required this.totalBottles,
    required this.bottlesWithCustomers,
    required this.bottlesInStock,
    required this.bottlesLost,
    this.notes,
    this.perfect,
    this.needsCleaning,
    this.damaged,
    this.emptyReturned,
  });

  factory WsBottleSnapshot.fromJson(Map<String, dynamic> j) => WsBottleSnapshot(
    inventoryId:          j['inventoryid'] ?? j['InventoryID'],
    orgId:                j['orgid'] ?? j['OrgID'],
    snapshotDate:         DateTime.parse(j['snapshotdate'] ?? j['SnapshotDate']),
    totalBottles:         j['totalbottles'] ?? j['TotalBottles']            ?? 0,
    bottlesWithCustomers: j['bottleswithcustomers'] ?? j['BottlesWithCustomers']    ?? 0,
    bottlesInStock:       j['bottlesinstock'] ?? j['BottlesInStock']          ?? 0,
    bottlesLost:          j['bottleslost'] ?? j['BottlesLost']             ?? 0,
    notes:                j['notes'] ?? j['Notes'],
  );
}

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

  const WsDashboardStats({
    required this.bottlesInHand,
    required this.bottlesDeliveredMonth,
    required this.emptyBottlesReturned,
    required this.filledInStock,
    required this.totalReceivable,
    required this.bottlesNeedAttention,
    required this.totalCustomers,
    required this.activeCustomers,
  });
}