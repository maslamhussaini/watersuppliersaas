// =============================================================================
// test/models_test.dart
// Regression tests for the parsing bugs that were shipping silently.
//
// Every test here fails against the previous ws_models.dart. They exist because
// each of these bugs produced a plausible-looking wrong number rather than an
// exception, so nothing surfaced them at run time.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/models/ws_models.dart';

void main() {
  group('PostgREST key casing', () {
    test('admin role survives the round trip', () {
      // PostgREST returns 'role', not 'Role'. The old code read j['Role'],
      // which was always null, so `== "admin"` was always false and every
      // admin was silently demoted to staff.
      final admin = WsInternalUser.fromJson({
        'internaluserid': 1,
        'orgid': 1,
        'authuserid': 'uuid-1',
        'fullname': 'Kamran Khan',
        'role': 'admin',
      });
      expect(admin.role, WsUserRole.admin);
      expect(admin.roleCode, 'admin');
    });

    test('owner is treated as admin for routing', () {
      final owner = WsInternalUser.fromJson({
        'internaluserid': 1,
        'orgid': 1,
        'authuserid': 'uuid-1',
        'fullname': 'Owner',
        'role': 'owner',
      });
      expect(owner.role, WsUserRole.admin);
    });

    test('delivery driver is staff, not admin', () {
      final driver = WsInternalUser.fromJson({
        'internaluserid': 2,
        'orgid': 1,
        'authuserid': 'uuid-2',
        'fullname': 'Ali Raza',
        'role': 'delivery',
      });
      expect(driver.role, WsUserRole.staff);
      expect(driver.roleCode, 'delivery');
    });
  });

  group('null-aware precedence', () {
    // `(j['a'] ?? j['B'] as num).toDouble()` parses as `j['a'] ?? (j['B'] as
    // num)`. With both keys absent that is `null as num`, which throws.
    test('WsArea tolerates a missing rate instead of throwing', () {
      expect(
        () => WsArea.fromJson({'areaid': 1, 'orgid': 1, 'areaname': 'Gulberg'}),
        returnsNormally,
      );
      final a = WsArea.fromJson({'areaid': 1, 'orgid': 1, 'areaname': 'X'});
      expect(a.ratePerBottle, 0);
    });

    test('WsDelivery tolerates missing amounts', () {
      expect(
        () => WsDelivery.fromJson({
          'deliveryid': 1,
          'orgid': 1,
          'customerid': 1,
          'deliverydate': '2026-07-01',
        }),
        returnsNormally,
      );
    });

    test('WsPayment tolerates a missing amount', () {
      expect(
        () => WsPayment.fromJson({
          'paymentid': 1,
          'orgid': 1,
          'customerid': 1,
          'paymentdate': '2026-07-01',
        }),
        returnsNormally,
      );
    });

    test('numeric columns arriving as strings still parse', () {
      // numeric(12,2) can come back as a JSON string depending on the driver.
      final a = WsArea.fromJson({
        'areaid': 1,
        'orgid': 1,
        'areaname': 'X',
        'rateperbottle': '250.00',
      });
      expect(a.ratePerBottle, 250.0);
    });
  });

  group('payment methods', () {
    test('known codes map correctly', () {
      expect(WsPaymentMethodX.fromCode('easypaisa'), WsPaymentMethod.easypaisa);
      expect(WsPaymentMethodX.fromCode('JazzCash'), WsPaymentMethod.jazzcash);
      expect(WsPaymentMethodX.fromCode('bank'), WsPaymentMethod.bank);
    });

    test('an unknown tenant wallet is "other", never "cash"', () {
      // Defaulting an unrecognised method to cash would overstate the cash
      // drawer and understate the wallet at day-end reconciliation.
      expect(WsPaymentMethodX.fromCode('sadapay'), WsPaymentMethod.other);
    });
  });

  group('customer write payloads', () {
    final c = WsCustomer(
      customerId: 42,
      orgId: 1,
      areaId: 3,
      customerName: 'Hotel ABC',
      createdDate: DateTime(2026, 7, 1),
      bottleBalance: 6,
    );

    test('toInsert omits the primary key', () {
      expect(c.toInsert().containsKey('customerid'), isFalse);
    });

    test('toUpdate carries the primary key', () {
      // Passing toInsert() to .upsert() gave PostgREST no conflict target, so
      // every edit inserted a duplicate customer instead of updating one.
      expect(c.toUpdate()['customerid'], 42);
    });

    test('bottlebalance is never written from the client', () {
      // It is a trigger-maintained cache of the default bottle type. A client
      // write would be overwritten by the next delivery anyway.
      expect(c.toInsert().containsKey('bottlebalance'), isFalse);
      expect(c.toUpdate().containsKey('bottlebalance'), isFalse);
    });
  });

  group('delivery write payload', () {
    test('derived columns are not sent', () {
      final d = WsDelivery(
        deliveryId: 0,
        orgId: 1,
        customerId: 1,
        deliveryDate: DateTime(2026, 7, 1),
        bottlesDelivered: 4,
        bottlesReturned: 3,
        bottleBalance: 5,
        rateApplied: 250,
        amountCharged: 1000,
      );
      final payload = d.toInsert();
      for (final key in [
        'bottlebalance',
        'rateapplied',
        'amountcharged',
        'bottlesdelivered',
        'bottlesreturned',
      ]) {
        expect(
          payload.containsKey(key),
          isFalse,
          reason: '$key is computed by trigger and discarded by the seal trigger',
        );
      }
    });
  });

  group('delivery card', () {
    // The three rows from the physical card: opening balance 4, rate Rs 250.
    final rows = [
      WsDeliveryCardRow.fromJson({
        'entrydate': '2026-07-01',
        'deliverybottles': 4,
        'receivedbottles': 3,
        'bottlebalance': 5,
        'totalamount': 1000,
        'amountreceived': 1000,
        'runningbalance': 0,
      }),
      WsDeliveryCardRow.fromJson({
        'entrydate': '2026-07-02',
        'deliverybottles': 5,
        'receivedbottles': 3,
        'bottlebalance': 7,
        'totalamount': 1250,
        'amountreceived': 0,
        'runningbalance': 1250,
      }),
      WsDeliveryCardRow.fromJson({
        'entrydate': '2026-07-03',
        'deliverybottles': 3,
        'receivedbottles': 4,
        'bottlebalance': 6,
        'totalamount': 750,
        'amountreceived': 750,
        'runningbalance': 1250,
      }),
    ];

    test('parses the card rows', () {
      expect(rows.map((r) => r.bottleBalance).toList(), [5, 7, 6]);
      expect(rows.last.runningBalance, 1250);
    });

    test('bottle maths matches the paper card', () {
      // 4 opening + 12 delivered - 10 received = 6
      final delivered = rows.fold(0, (s, r) => s + r.deliveryBottles);
      final received = rows.fold(0, (s, r) => s + r.receivedBottles);
      expect(delivered, 12);
      expect(received, 10);
      expect(4 + delivered - received, rows.last.bottleBalance);
    });

    test('money maths matches the paper card', () {
      final charged = rows.fold(0.0, (s, r) => s + r.totalAmount);
      final paid = rows.fold(0.0, (s, r) => s + r.amountReceived);
      expect(charged - paid, 1250.0);
      expect(rows.last.runningBalance, charged - paid);
    });
  });

  group('permissions', () {
    test('a driver cannot edit pricing', () {
      const driver = WsPermissions({
        'customers.view',
        'products.view',
        'delivery.view',
        'delivery.manage',
        'reports.view',
      });
      expect(driver.canRecordDelivery, isTrue);
      expect(driver.canEditProducts, isFalse);
      expect(driver.canViewAccounting, isFalse);
      expect(driver.canManageUsers, isFalse);
    });

    test('an empty permission set grants nothing', () {
      // The default before loadPermissions() completes. It must be closed, not
      // open, or the UI flashes controls the server will reject.
      const none = WsPermissions.none();
      expect(none.canViewCustomers, isFalse);
      expect(none.canRecordDelivery, isFalse);
    });
  });

  _extra();

  group('dashboard stats', () {
    test('reads vw_ws_dashboard keys in lowercase', () {
      // The old client folded three queries reading r['OutstandingDue'] and
      // friends. Those keys never exist, so every tile showed zero.
      final s = WsDashboardStats.fromJson({
        'orgid': 1,
        'todaysales': 125000,
        'todaycollections': 80000,
        'todaydeliveries': 12,
        'receivables': 450000,
        'payables': 30000,
        'totalcustomers': 3,
        'bottlesout': 2340,
        'bottlesinstock': 660,
        'reconciliationissues': 0,
      });
      expect(s.todaySales, 125000);
      expect(s.totalReceivable, 450000);
      expect(s.bottlesInHand, 2340);
      expect(s.totalCustomers, 3);
      expect(s.isReconciled, isTrue);
    });

    test('reconciliation drift is surfaced, not hidden', () {
      final s = WsDashboardStats.fromJson({
        'orgid': 1,
        'reconciliationissues': 2,
      });
      expect(s.isReconciled, isFalse);
    });
  });
}

// ── Added with the delivery-card wiring and the bottle-position switch ────────

void _extra() {
  group('bottle position (replaces the snapshot table)', () {
    test('totals and health derive from the ledger', () {
      const p = WsBottlePosition(
        withCustomers: 2340,
        inStock: 660,
        lost: 30,
        damaged: 10,
      );
      expect(p.total, 3000);
      // 3000 accounted for out of 3040 ever handled.
      expect(p.healthScore.toStringAsFixed(1), '98.7');
    });

    test('an empty organization does not divide by zero', () {
      const p = WsBottlePosition(
        withCustomers: 0, inStock: 0, lost: 0, damaged: 0,
      );
      expect(p.total, 0);
      expect(p.healthScore, 0);
    });
  });

  group('delivery card bundle', () {
    final org = const WsOrganization(
      orgId: 1, authUserId: 'u', orgName: 'Kent Water',
      ownerName: 'K', phone: '', address: '',
    );
    final cust = WsCustomer(
      customerId: 1, orgId: 1, areaId: 1, customerName: 'Hotel ABC',
      createdDate: DateTime(2026, 7, 1), bottleBalance: 6,
    );

    test('isEmpty is true when there is nothing to print', () {
      final d = WsDeliveryCardData(org: org, customer: cust, rows: const []);
      expect(d.isEmpty, isTrue);
    });

    test('isEmpty is false once there are rows', () {
      final d = WsDeliveryCardData(org: org, customer: cust, rows: [
        WsDeliveryCardRow.fromJson({
          'entrydate': '2026-07-01', 'deliverybottles': 4, 'receivedbottles': 3,
          'bottlebalance': 5, 'totalamount': 1000, 'amountreceived': 1000,
          'runningbalance': 0,
        }),
      ]);
      expect(d.isEmpty, isFalse);
    });
  });

  group('organization card settings', () {
    test('cardsettings drives the printed layout, per tenant', () {
      final o = WsOrganization.fromJson({
        'orgid': 1, 'orgname': 'Kent Water', 'currencysymbol': 'Rs',
        'cardsettings': {
          'pagesize': 'A4',
          'showsignature': false,
          'columns': ['date', 'delivered', 'received', 'balance'],
        },
      });
      expect(o.cardSettings?['pagesize'], 'A4');
      expect(o.cardSettings?['showsignature'], false);
      expect((o.cardSettings?['columns'] as List).length, 4);
    });

    test('a tenant with no settings still gets defaults', () {
      final o = WsOrganization.fromJson({'orgid': 1, 'orgname': 'X'});
      expect(o.cardSettings, isNull);
      expect(o.currencySymbol, 'Rs');
    });
  });
}
