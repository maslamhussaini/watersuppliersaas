// =============================================================================
// test/fetch_rows_offline_test.dart
//
// The offline guard on fetchRows — the shared loader behind every
// WsCrudScreen: bottle types, product prices, customer groups, routes,
// vendors, products, and the dropdowns fetchOptions fills.
//
// ─── WHAT IT FIXES ───────────────────────────────────────────────────────────
//
// Offline each of those screens spent ~7s waiting out postgrest's GET retry
// ladder (1s + 2s + 4s, maxRetries = 3, retryEnabled defaults true) before
// reaching a failure that was certain from the start.
//
// It does NOT fix the screens' error handling, because that was never broken.
// WsCrudScreen's FutureBuilder already has a hasError branch with Retry,
// distinct from its "Nothing yet" empty state (ws_crud.dart:310–338). An
// earlier audit of mine claimed otherwise; reading the consumer disproved it.
//
// ─── WHY THIS FILE CAN EXIST AT ALL ──────────────────────────────────────────
//
// Every previous guard in this effort sits AFTER `if (!supabaseClientInitialized)
// return ...`, which in a VM test returns before the guard is reached — so those
// guards could only be verified by inspection. This one is placed FIRST, so a
// test can actually drive it. That placement is also the more honest one on its
// own merits: being offline is a fact about the device, not about whether a
// client is configured.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/supabase_service.dart';
import 'package:watersuppliersaas/services/ws_connectivity.dart';

/// The tables this loader serves. Named individually so a regression points at
/// the screen a tester would notice, not at an abstraction.
const tables = <String, String>{
  'ws_tblbottletypes': 'Bottle Types',
  'ws_tblproductprices': 'Product Prices',
  'ws_tblcustomergroups': 'Customer Groups',
  'ws_tblroutes': 'Routes',
  'ws_tblvendors': 'Vendors',
  'ws_tblproducts': 'Products',
};

void main() {
  setUp(WsConnectivity.reset);
  tearDown(WsConnectivity.reset);

  // ═══ OFFLINE ══════════════════════════════════════════════════════════════

  group('offline', () {
    for (final entry in tables.entries) {
      test('${entry.value} throws WsOfflineSkip instead of waiting', () async {
        WsConnectivity.isOnline = () => false;

        await expectLater(
          WsDataService.fetchRows(entry.key),
          throwsA(isA<WsOfflineSkip>()),
          reason: 'THE FIX: this used to spend ~7s on the retry ladder to '
              'arrive at the same failure',
        );
      });
    }

    test('the guard is consulted, and it is what stops the call', () async {
      var asked = 0;
      WsConnectivity.isOnline = () {
        asked++;
        return false;
      };

      await expectLater(
          WsDataService.fetchRows('ws_tblroutes'), throwsA(isA<WsOfflineSkip>()));

      expect(asked, 1,
          reason: 'exactly once per call — read fresh, so a reconnect takes '
              'effect on the next attempt with no cached flag to go stale');
    });

    test('no Supabase client is touched', () async {
      WsConnectivity.isOnline = () => false;

      // There is no initialised Supabase client in a VM test. Reaching the
      // query would therefore throw StateError('Supabase is not initialized'),
      // NOT WsOfflineSkip. So the exception TYPE is the proof that the request
      // was never attempted — this assertion is the whole test.
      await expectLater(
        WsDataService.fetchRows('ws_tblbottletypes'),
        throwsA(isA<WsOfflineSkip>()),
        reason: 'a StateError here would mean the guard was bypassed and the '
            'client was reached',
      );
    });

    test('every argument shape is guarded, not just the default', () async {
      WsConnectivity.isOnline = () => false;

      // fetchOptions calls through with explicit columns and ordering; the
      // guard must not depend on the caller's arguments.
      await expectLater(
        WsDataService.fetchRows('ws_tblroutes',
            orderBy: 'routename', ascending: false, activeOnly: false,
            columns: 'routeid, routename'),
        throwsA(isA<WsOfflineSkip>()),
      );
    });

    test('the sentinel reads as a connectivity problem, not a malfunction',
        () async {
      WsConnectivity.isOnline = () => false;
      try {
        await WsDataService.fetchRows('ws_tblroutes');
        fail('should have thrown');
      } catch (e) {
        expect('$e', contains('offline'),
            reason: 'WsCrudScreen prints the exception under "Could not load", '
                'so its text is what the user actually reads');
      }
    });
  });

  // ═══ ONLINE — UNCHANGED ═══════════════════════════════════════════════════

  group('online', () {
    test('the guard does NOT short-circuit; the normal path is taken',
        () async {
      WsConnectivity.isOnline = () => true;

      // The normal path in a VM test reaches `if (!supabaseClientInitialized)`
      // and returns [] — an EMPTY SUCCESS, not an error. That is precisely the
      // distinction the screen relies on: "Nothing yet" versus "Could not
      // load". Getting WsOfflineSkip here would mean the guard fires when the
      // device is online, which would route a reachable server to an error
      // screen.
      final rows = await WsDataService.fetchRows('ws_tblroutes');

      expect(rows, isEmpty);
      expect(rows, isA<List<Map<String, dynamic>>>(),
          reason: 'the returned row structure is unchanged');
    });

    test('an empty success stays distinguishable from a failure', () async {
      WsConnectivity.isOnline = () => true;
      final rows = await WsDataService.fetchRows('ws_tblcustomergroups');

      expect(rows, isEmpty,
          reason: 'empty means "no records" and must reach the screen as DATA, '
              'so it renders "Nothing yet" rather than "Could not load"');
    });

    test('online is the default when connectivity cannot be determined',
        () async {
      // No override: the VM stub returns true. Assuming online reproduces the
      // previous behaviour rather than silently failing every read.
      expect(WsConnectivity.isOnline(), isTrue);
      await expectLater(WsDataService.fetchRows('ws_tblroutes'), completes);
    });
  });

  // ═══ TRANSITIONS ══════════════════════════════════════════════════════════

  test('coming back online makes the very next call work again', () async {
    var online = false;
    WsConnectivity.isOnline = () => online;

    await expectLater(
        WsDataService.fetchRows('ws_tblroutes'), throwsA(isA<WsOfflineSkip>()));

    online = true;
    await expectLater(WsDataService.fetchRows('ws_tblroutes'), completes,
        reason: 'Retry on the error screen must work the moment signal '
            'returns — there is no listener or cached flag in between');
  });
}
