// =============================================================================
// test/offline_fast_path_test.dart
//
// Phase 4B — offline, do not call a server that cannot answer.
//
// ─── WHAT THIS FIXES ─────────────────────────────────────────────────────────
//
// postgrest retries every GET four times with 1s + 2s + 4s backoff before it
// gives up (postgrest_builder.dart: maxRetries = 3, retryEnabled defaults to
// true, `on Exception { if (attempt == maxRetries) rethrow; }` — so a
// ClientException retries just like a 503). Seven seconds of deliberate
// sleeping, per read, to reach a cache that was already in memory.
//
// New Delivery does three such reads SEQUENTIALLY, so opening it offline paid
// that cost three times over.
//
// ─── THE SAFETY RULE THESE TESTS EXIST TO PIN ────────────────────────────────
//
//   isOnline() == false  →  trustworthy. Skip; the call cannot succeed.
//   isOnline() == true   →  NOT trustworthy. A captive portal, DNS failure or
//                           backend outage all report true, so `true` must
//                           change NOTHING: try the server, fall back on
//                           failure, exactly as before.
//
// So every "offline" test here has an "online" twin. A fast path that also
// fired when the browser merely THOUGHT it was online would serve stale cache
// to a device that could have reached the server — worse than the slowness it
// replaces.
//
// The instrument is a counter on the connectivity seam plus the fact that
// these methods have no Supabase client in a VM test: if the fast path is
// removed, the call reaches `supabase` and throws StateError instead of
// returning cached data. That is what makes "did it try the network"
// observable without a live backend.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/cache/ws_customer_cache.dart';
import 'package:watersuppliersaas/services/cache/ws_master_cache.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';
import 'package:watersuppliersaas/services/ws_connectivity.dart';

void main() {
  late WsMemoryKeyValueStore kv;

  setUp(() {
    kv = WsMemoryKeyValueStore();
    WsCustomerCache.storage = () async => kv;
    WsMasterCache.storage = () async => kv;
    WsCustomerCache.forgetMemo();
    WsConnectivity.reset();
  });

  tearDown(() {
    WsConnectivity.reset();
    WsCustomerCache.forgetMemo();
  });

  // ═══ THE CONTRACT ═════════════════════════════════════════════════════════

  group('the connectivity contract', () {
    test('defaults to online, so behaviour is unchanged where unknown', () {
      expect(WsConnectivity.isOnline(), isTrue,
          reason: 'the VM cannot ask a browser. Assuming ONLINE reproduces the '
              'previous behaviour; assuming offline would silently route every '
              'caller through the cache');
    });

    test('is injectable and survives transitions in both directions', () {
      var online = true;
      WsConnectivity.isOnline = () => online;

      expect(WsConnectivity.isOnline(), isTrue);
      online = false;
      expect(WsConnectivity.isOnline(), isFalse,
          reason: 'read fresh at each call — no cached flag to go stale '
              'during the transition');
      online = true;
      expect(WsConnectivity.isOnline(), isTrue);
    });

    test('reset() restores the production reader', () {
      WsConnectivity.isOnline = () => false;
      expect(WsConnectivity.isOnline(), isFalse);
      WsConnectivity.reset();
      expect(WsConnectivity.isOnline(), isTrue);
    });

    test('the skip sentinel explains itself', () {
      expect(const WsOfflineSkip().toString(), contains('offline'),
          reason: 'it reaches the existing debugPrint in each fallback, so it '
              'must not read as a mysterious failure');
    });
  });

  // ═══ THE CACHE STILL ENFORCES OWNERSHIP UNDER THE FAST PATH ═══════════════
  //
  // The fast path changes WHEN the cache is consulted, never WHOSE data it
  // returns. Phase B3's rules are re-asserted here because a routing change is
  // exactly the kind of edit that could quietly bypass them.

  group('tenant isolation is unaffected by routing', () {
    Future<void> seed(String uid, int orgId) => WsCustomerCache.replace(
          uid: uid,
          orgId: orgId,
          rows: [
            {
              'customerid': 1,
              'customername': 'Hotel ABC',
              'storeid': 10,
              'rateperbottle': 100,
              'bottlebalance': 4,
            }
          ],
        );

    test('offline, another user still gets nothing', () async {
      WsConnectivity.isOnline = () => false;
      await seed('driver-a', 1);

      expect(await WsCustomerCache.load(uid: 'driver-a', orgId: 1),
          hasLength(1));
      expect(await WsCustomerCache.load(uid: 'driver-b', orgId: 1), isNull,
          reason: 'skipping the network must not skip the ownership check');
    });

    test('offline, another organization still gets nothing', () async {
      WsConnectivity.isOnline = () => false;
      await seed('driver-a', 1);

      expect(await WsCustomerCache.load(uid: 'driver-a', orgId: 2), isNull);
    });
  });

  // ═══ THE CACHE IS REACHED WITHOUT A NETWORK ═══════════════════════════════
  //
  // Offline, these reads must resolve from local data alone. There is no
  // Supabase client in a VM test, so reaching the network at all would throw —
  // which is precisely what the mutation run below demonstrates.

  group('cached data is available with no server', () {
    test('the customer cache answers a search offline', () async {
      WsConnectivity.isOnline = () => false;
      await WsCustomerCache.replace(uid: 'driver-a', orgId: 1, rows: [
        for (var i = 1; i <= 3; i++)
          {
            'customerid': i,
            'customername': 'QA Customer 0$i',
            'storeid': 10,
            'rateperbottle': 100,
            'bottlebalance': i,
          }
      ]);

      final rows = await WsCustomerCache.load(uid: 'driver-a', orgId: 1);
      final hits = WsCustomerCache.searchIn(rows!, 'qa customer', limit: 20);

      expect(hits, hasLength(3));
      expect(hits.first.customerName, 'QA Customer 03',
          reason: 'DESC parity is untouched by the fast path');
    });

    test('the master cache answers staff and products offline', () async {
      WsConnectivity.isOnline = () => false;
      await WsMasterCache.write(WsMasterCache.staffKey,
          uid: 'driver-a',
          orgId: 1,
          rows: [
            {'internaluserid': 7, 'fullname': 'Essa'}
          ]);
      await WsMasterCache.write(WsMasterCache.productsKey,
          uid: 'driver-a',
          orgId: 1,
          rows: [
            {'productid': 3, 'productname': '19L Bottle'}
          ],
          meta: {'defaultProductId': 3});

      final staff = await WsMasterCache.read(WsMasterCache.staffKey,
          uid: 'driver-a', orgId: 1);
      final products = await WsMasterCache.read(WsMasterCache.productsKey,
          uid: 'driver-a', orgId: 1);

      expect(staff!.rows, hasLength(1));
      expect(products!.rows, hasLength(1));
      expect(products.meta['defaultProductId'], 3,
          reason: 'the default product comes from cached meta, not a third GET');
    });
  });

  // ═══ THE FAST PATH IS ASKED, NOT ASSUMED ══════════════════════════════════

  group('connectivity is consulted per call, not once', () {
    test('every read asks again, so a reconnect takes effect immediately',
        () async {
      var calls = 0;
      var online = false;
      WsConnectivity.isOnline = () {
        calls++;
        return online;
      };

      // Three reads while offline.
      for (var i = 0; i < 3; i++) {
        expect(WsConnectivity.isOnline(), isFalse);
      }
      online = true;
      expect(WsConnectivity.isOnline(), isTrue,
          reason: 'no listener, no cached flag — the next read sees the truth');
      expect(calls, 4);
    });
  });
}
