// =============================================================================
// test/offline_read_guards_test.dart
//
// Offline guards on the remaining READ operations:
//   fetchOrg, fetchOpeningStock, fetchCustomerOpenings, fetchVendorOpenings,
//   fetchPurchases, fetchVendorPayments
//
// Each previously spent ~7s offline waiting out postgrest's GET retry ladder
// (1s + 2s + 4s) to reach a failure that was certain from the start. The guard
// only changes WHEN the failure arrives, never what it is.
//
// ─── READS ONLY ──────────────────────────────────────────────────────────────
//
// Purchases and Vendor Payments are guarded for READING. Creating either
// offline is deliberately NOT touched: that needs durable enqueue plus a
// server-side idempotency short-circuit like ws_record_delivery's, and without
// the second part a retry after a timeout could double-post — which for a
// vendor payment is real money. Out of scope by instruction, and rightly.
//
// ─── WHY THESE GUARDS ARE TESTABLE ───────────────────────────────────────────
//
// Each sits BEFORE `if (!supabaseClientInitialized)`. Guards placed after that
// line are unreachable from a VM test — the method returns first — so they can
// only be verified by inspection. A probe confirmed all six are reached here.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/models/ws_models.dart';
import 'package:watersuppliersaas/services/supabase_service.dart';
import 'package:watersuppliersaas/services/ws_connectivity.dart';

/// Every guarded read, with the screen a tester would look at.
final reads = <String, Future<Object?> Function()>{
  'fetchOrg (Dashboard header)': WsDataService.fetchOrg,
  'fetchOpeningStock (Opening Balances)': WsDataService.fetchOpeningStock,
  'fetchCustomerOpenings (Opening Balances, Reports)':
      WsDataService.fetchCustomerOpenings,
  'fetchVendorOpenings (Opening Balances, Reports)':
      WsDataService.fetchVendorOpenings,
  'fetchPurchases (Purchases)': WsDataService.fetchPurchases,
  'fetchVendorPayments (Vendor Payments)': WsDataService.fetchVendorPayments,
};

void main() {
  setUp(WsConnectivity.reset);
  tearDown(WsConnectivity.reset);

  // ═══ OFFLINE ══════════════════════════════════════════════════════════════

  group('offline', () {
    for (final entry in reads.entries) {
      test('${entry.key} throws WsOfflineSkip instead of waiting', () async {
        WsConnectivity.isOnline = () => false;

        await expectLater(entry.value(), throwsA(isA<WsOfflineSkip>()),
            reason: 'THE FIX: ~7s of retry-ladder sleeping removed. The type '
                'is also the proof no request was made — reaching the client '
                'in a VM test would throw StateError, not WsOfflineSkip');
      });
    }

    test('the guard is what stops it, and is read once per call', () async {
      var asked = 0;
      WsConnectivity.isOnline = () {
        asked++;
        return false;
      };

      await expectLater(
          WsDataService.fetchPurchases(), throwsA(isA<WsOfflineSkip>()));
      expect(asked, 1);

      await expectLater(
          WsDataService.fetchVendorPayments(), throwsA(isA<WsOfflineSkip>()));
      expect(asked, 2,
          reason: 'read fresh each time — a reconnect takes effect on the '
              'next call, with no cached flag in between');
    });

    test('the message reads as connectivity, not as a malfunction', () async {
      WsConnectivity.isOnline = () => false;
      try {
        await WsDataService.fetchOpeningStock();
        fail('should have thrown');
      } catch (e) {
        expect('$e', contains('offline'),
            reason: 'the Opening Balances screen prints the exception in its '
                'error state, so this text is what a user reads — and it must '
                'not look like the financial data is broken');
      }
    });
  });

  // ═══ ONLINE — UNCHANGED ═══════════════════════════════════════════════════

  group('online', () {
    test('the guard does not fire; the normal path is taken', () async {
      WsConnectivity.isOnline = () => true;

      // The normal VM path reaches `if (!supabaseClientInitialized)` and
      // returns its empty/default value. That is an EMPTY SUCCESS, not an
      // error — precisely the distinction each screen relies on to show
      // "Nothing yet" rather than "Could not load". A WsOfflineSkip here would
      // route a reachable server to an error screen.
      expect(await WsDataService.fetchOpeningStock(), isEmpty);
      expect(await WsDataService.fetchCustomerOpenings(), isEmpty);
      expect(await WsDataService.fetchVendorOpenings(), isEmpty);
      expect(await WsDataService.fetchPurchases(), isEmpty);
      expect(await WsDataService.fetchVendorPayments(), isEmpty);
    });

    test('return types and shapes are unchanged', () async {
      WsConnectivity.isOnline = () => true;

      expect(await WsDataService.fetchPurchases(),
          isA<List<Map<String, dynamic>>>());
      expect(await WsDataService.fetchOrg(), anyOf(isNull, isA<WsOrganization>()),
          reason: 'fetchOrg is the one non-list read here; its nullable '
              'contract must survive');
    });

    test('online is the default when connectivity cannot be determined',
        () async {
      // No override: the VM stub returns true, reproducing previous behaviour
      // rather than silently failing every read.
      expect(WsConnectivity.isOnline(), isTrue);
      await expectLater(WsDataService.fetchPurchases(), completes);
    });
  });

  // ═══ TRANSITION ═══════════════════════════════════════════════════════════

  test('coming back online makes the very next read work', () async {
    var online = false;
    WsConnectivity.isOnline = () => online;

    await expectLater(
        WsDataService.fetchVendorPayments(), throwsA(isA<WsOfflineSkip>()));

    online = true;
    await expectLater(WsDataService.fetchVendorPayments(), completes,
        reason: 'Retry must work the moment signal returns');
  });

  // ═══ THE FINANCIAL READS ARE READS ONLY ═══════════════════════════════════

  test('guarding a read did not touch the write path', () async {
    // saveRow is how master data — including purchases and vendor payments —
    // is written. It must NOT have acquired an offline guard: an unguarded
    // write still fails honestly, whereas a guarded one could look like a
    // silent no-op to a user who thinks money moved.
    WsConnectivity.isOnline = () => false;

    // Offline, saveRow runs past where a guard would be and fails further in
    // (StateError: no active organization). Throwing something OTHER than
    // WsOfflineSkip is the proof that no guard was added to the write path.
    await expectLater(
      WsDataService.saveRow('ws_tblroutes', 'routeid', null, {'routename': 'x'}),
      throwsA(isNot(isA<WsOfflineSkip>())),
      reason: 'a guarded write could read as a silent no-op to someone who '
          'believes money moved',
    );
  });
}
