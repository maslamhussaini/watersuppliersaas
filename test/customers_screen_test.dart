// =============================================================================
// test/customers_screen_test.dart
//
// Phase 2A — the Customers screen must never look broken.
//
// ─── THE TWO DEFECTS ─────────────────────────────────────────────────────────
//
// 1. AN EMPTY LIST SAID NOTHING.
//
//    The dashboard holds its tabs in an IndexedStack, so this screen is kept
//    alive: leaving the tab and coming back preserves the search text — which
//    is correct, it is the user's typing — and the list is still filtered by
//    it. The list rendered ListView(itemCount: 0), a blank rectangle, so an
//    active filter was indistinguishable from a broken screen. That is exactly
//    what was reported: "customers appear the first time, not the second".
//
// 2. A FAILED LOAD SPUN FOREVER.
//
//        setState(() => _loading = true);
//        final list = await WsDataService.fetchCustomers();   // no try/catch
//
//    fetchCustomers reads vw_ws_customerbalance and has no offline path, so
//    offline it throws, the throw escapes as an unhandled async error, and
//    _loading is never set back to false.
//
// ─── NOT IN SCOPE ────────────────────────────────────────────────────────────
//
// There is NO cache-fallback test here, because cache fallback is deliberately
// not implemented: the cached projection carries no balance, so serving it to
// this screen would silently misclassify the Due/Settled chips. A test that
// implied otherwise would be worse than no test.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/models/ws_models.dart';
import 'package:watersuppliersaas/screens/customers_screen.dart';
import 'package:watersuppliersaas/services/ws_connectivity.dart';

WsCustomer customer(int id, String name) => WsCustomer(
      customerId: id,
      orgId: 1,
      areaId: 5,
      customerName: name,
      bottleBalance: 0,
      createdDate: DateTime(2026, 1, 1),
      isActive: true,
    );

void main() {
  final saved = WsCustomersScreen.fetch;
  tearDown(() => WsCustomersScreen.fetch = saved);

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(home: WsCustomersScreen()));
    await t.pumpAndSettle();
  }

  Future<void> search(WidgetTester t, String q) async {
    await t.enterText(find.byType(TextField).first, q);
    await t.pumpAndSettle();
  }

  // ═══ 1. THE NORMAL CASE ═══════════════════════════════════════════════════

  testWidgets('an existing list renders', (t) async {
    WsCustomersScreen.fetch = () async =>
        [customer(1, 'Hotel ABC'), customer(2, 'Zain Store')];
    await open(t);

    expect(find.text('Hotel ABC'), findsOneWidget);
    expect(find.text('Zain Store'), findsOneWidget);
    expect(find.text('No customers found'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  // ═══ 2. A SEARCH THAT MATCHES NOTHING ═════════════════════════════════════

  testWidgets('zero matches explains itself and names the query', (t) async {
    WsCustomersScreen.fetch = () async => [customer(1, 'Hotel ABC')];
    await open(t);

    await search(t, 'QA Customer');

    expect(find.text('No customers found'), findsOneWidget);
    expect(find.text('No customers match "QA Customer".'), findsOneWidget,
        reason: 'quoting the query is what makes a PRESERVED search obvious — '
            'it may have been typed before a tab switch');
    expect(find.text('Hotel ABC'), findsNothing);
  });

  testWidgets('an organization with no customers reads differently',
      (t) async {
    WsCustomersScreen.fetch = () async => [];
    await open(t);

    expect(find.text('No customers found'), findsOneWidget);
    expect(find.text('No customers have been added yet.'), findsOneWidget,
        reason: 'a genuinely empty org must not be blamed on a search');
    expect(find.text('Clear Search'), findsNothing,
        reason: 'there is nothing to clear');
  });

  // ═══ 3. CLEAR SEARCH RESTORES THE LIST ════════════════════════════════════

  testWidgets('Clear Search brings the list back', (t) async {
    WsCustomersScreen.fetch = () async =>
        [customer(1, 'Hotel ABC'), customer(2, 'Zain Store')];
    await open(t);

    await search(t, 'nothing matches this');
    expect(find.text('Hotel ABC'), findsNothing);

    await t.tap(find.text('Clear Search'));
    await t.pumpAndSettle();

    expect(find.text('Hotel ABC'), findsOneWidget);
    expect(find.text('Zain Store'), findsOneWidget);
    expect(find.text('No customers found'), findsNothing);
  });

  // ═══ 4. A FAILED LOAD MUST NOT SPIN FOREVER ═══════════════════════════════

  testWidgets('a failed first load stops loading and says why', (t) async {
    WsCustomersScreen.fetch =
        () async => throw Exception('Failed to fetch');
    await open(t);

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'THE DEFECT: _loading stayed true forever and the screen '
            'showed a spinner that could never resolve');
    expect(find.text('Could not load customers'), findsOneWidget);
    expect(find.textContaining('Failed to fetch'), findsOneWidget,
        reason: 'the exception is surfaced, not swallowed');
  });

  // ═══ 5. RETRY ═════════════════════════════════════════════════════════════

  testWidgets('Retry is offered and works', (t) async {
    var fail = true;
    WsCustomersScreen.fetch = () async {
      if (fail) throw Exception('Failed to fetch');
      return [customer(1, 'Hotel ABC')];
    };
    await open(t);
    expect(find.text('Retry'), findsOneWidget);

    fail = false;
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();

    expect(find.text('Hotel ABC'), findsOneWidget);
    expect(find.text('Could not load customers'), findsNothing);
  });

  // ═══ 6. A FAILED REFRESH KEEPS WHAT IT HAD ════════════════════════════════

  testWidgets('a failed refresh keeps the list and admits the failure',
      (t) async {
    var fail = false;
    WsCustomersScreen.fetch = () async {
      if (fail) throw Exception('Failed to fetch');
      return [customer(1, 'Hotel ABC')];
    };
    await open(t);
    expect(find.text('Hotel ABC'), findsOneWidget);

    // Pull to refresh, offline.
    fail = true;
    await t.fling(find.text('Hotel ABC'), const Offset(0, 320), 1000);
    await t.pumpAndSettle();

    expect(find.text('Hotel ABC'), findsOneWidget,
        reason: 'discarding a good list because a later refresh failed would '
            'destroy data the driver can still legitimately read');
    expect(find.textContaining('could not refresh'), findsOneWidget,
        reason: 'otherwise stale figures silently read as current');
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  // ═══ 7. OFFLINE IS NOT A MALFUNCTION ══════════════════════════════════════
  //
  // fetchCustomers now throws WsOfflineSkip immediately when the device is
  // offline, rather than spending ~7s on postgrest's GET retry ladder to reach
  // the same failure. It deliberately does NOT fall back to WsCustomerCache:
  // that projection has no outstandingdue, so every customer would render with
  // due == 0 — the Due filter empty, the Settled filter showing everyone. A
  // driver would be told every customer has paid.
  //
  // So the rule is: keep the REAL balances that were last loaded, and say
  // plainly why they are not current.

  group('offline', () {
    testWidgets('keeps the real balances and blames the connection, not itself',
        (t) async {
      var offline = false;
      WsCustomersScreen.fetch = () async {
        if (offline) throw const WsOfflineSkip();
        return [customer(1, 'Hotel ABC'), customer(2, 'Zain Store')];
      };
      await open(t);
      expect(find.text('Hotel ABC'), findsOneWidget);

      offline = true;
      await t.fling(find.text('Hotel ABC'), const Offset(0, 320), 1000);
      await t.pumpAndSettle();

      expect(find.text('Showing the last loaded list — device is offline.'),
          findsOneWidget,
          reason: 'the old wording surfaced a raw ClientException, which reads '
              'as a malfunction rather than "you have no signal"');
      expect(find.textContaining('ClientException'), findsNothing);
      expect(find.text('Hotel ABC'), findsOneWidget,
          reason: 'THE POINT: these are real balances from a real load. They '
              'stay, rather than being replaced by a cached projection that '
              'has no balance at all');
      expect(find.text('Zain Store'), findsOneWidget);
    });

    testWidgets('a cold start offline says so, and offers Retry', (t) async {
      WsCustomersScreen.fetch = () async => throw const WsOfflineSkip();
      await open(t);

      expect(find.text('Device is offline'), findsOneWidget);
      expect(find.textContaining('no connection to load it now'), findsOneWidget,
          reason: 'nothing was ever loaded, so there is no list to preserve — '
              'and this must not be confused with "no customers exist"');
      expect(find.text('No customers have been added yet.'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a genuine failure still reads as a failure', (t) async {
      WsCustomersScreen.fetch =
          () async => throw Exception('Failed to fetch');
      await open(t);

      expect(find.text('Could not load customers'), findsOneWidget,
          reason: 'only WsOfflineSkip is offline — a real error must not be '
              'excused as a connectivity problem');
      expect(find.text('Device is offline'), findsNothing);
      expect(find.textContaining('Failed to fetch'), findsOneWidget);
    });

    testWidgets('coming back online clears the offline message', (t) async {
      var offline = true;
      WsCustomersScreen.fetch = () async {
        if (offline) throw const WsOfflineSkip();
        return [customer(1, 'Hotel ABC')];
      };
      await open(t);
      expect(find.text('Device is offline'), findsOneWidget);

      offline = false;
      await t.tap(find.text('Retry'));
      await t.pumpAndSettle();

      expect(find.text('Hotel ABC'), findsOneWidget);
      expect(find.text('Device is offline'), findsNothing);
      expect(find.textContaining('device is offline'), findsNothing);
    });
  });
}
