// =============================================================================
// test/delivery_product_test.dart
//
// Product on New Delivery — Scenario 9.
//
// ─── WHAT WAS ACTUALLY WRONG ─────────────────────────────────────────────────
//
// ws_record_delivery has accepted p_productid since migration 018, and BOTH
// client paths — WsDataService.recordDelivery and WsOutboxService.recordDelivery
// — already declared and forwarded it. The screen simply never passed one, so
// every delivery arrived with p_productid null and the server fell back to the
// organization's default bottle-type product.
//
// For a single-product distributor that is correct and invisible. For anyone
// selling 19L and 500ml at different prices it is a silent billing fault: every
// line resolves against the default product's price, because ws.resolve_price
// prices PER PRODUCT.
//
// So no migration and no outbox change was needed. What needed proving is that
// the selected product behaves like the other save-time captures — the store,
// the clientuuid, the GPS fix — which is what most of this file tests.
//
// Pure Dart: no Flutter binding, no database, no Supabase.
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/screens/delivery_screen.dart'
    show wsPreselectedProductId, wsProductSelectionValid;
import 'package:watersuppliersaas/services/outbox/ws_outbox.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_store.dart';

/// 19L returnable — the organization's default bottle type.
const productDefault = 101;

/// 500ml case — priced differently. The reason this feature exists.
const productSmall = 202;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ws_delivery_product');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// Mirrors the args map built by WsOutboxService.recordDelivery.
  Future<WsOutboxItem> queueDelivery(
    WsOutbox box, {
    required int? productId,
    String? uuid,
    int delivered = 2,
  }) =>
      box.enqueue(
        clientUuid: uuid ?? wsNewUuid(),
        rpc: 'ws_record_delivery',
        args: {
          'p_customerid': 1,
          'p_delivered': delivered,
          'p_returned': 0,
          'p_productid': productId, // captured at SAVE time
          'p_amountpaid': 0,
          'p_storeid': 7,
          'p_clientuuid': uuid ?? 'k',
        },
        label: '$delivered out — Hotel ABC',
      );

  WsOutbox offlineBox(String path) => WsOutbox(
        store: WsOutboxFileStore(path),
        poster: (_) async => const WsPostResult.network('offline'),
      );

  // ═══ 1 · THE PAYLOAD CARRIES THE PRODUCT ══════════════════════════════════

  test('1. productId is included in the queued delivery payload', () async {
    final box = offlineBox('${dir.path}/q.json');
    await box.load();

    final item = await queueDelivery(box, productId: productSmall);

    expect(item.args['p_productid'], productSmall);
  });

  // ═══ 2 · AND IT IS ON DISK ════════════════════════════════════════════════

  test('2. the queued payload is persisted to disk', () async {
    final path = '${dir.path}/q.json';
    final box = offlineBox(path);
    await box.load();

    await queueDelivery(box, productId: productSmall);
    await box.drain();

    expect(File(path).readAsStringSync(), contains('"p_productid":$productSmall'),
        reason: 'in memory is not durable — a reload must still know the '
            'product that was actually delivered');
  });

  // ═══ 3 · A RETRY POSTS THE SAME PRODUCT ═══════════════════════════════════

  test('3. retry with the same clientUuid preserves the same productId',
      () async {
    final path = '${dir.path}/q.json';
    final seen = <Object?>[];
    var attempt = 0;

    final box = WsOutbox(
      store: WsOutboxFileStore(path),
      poster: (item) async {
        seen.add(item.args['p_productid']);
        // Fail the first four times, then accept.
        return ++attempt < 5
            ? const WsPostResult.network('offline')
            : const WsPostResult.success(documentId: 9);
      },
    );
    await box.load();

    await queueDelivery(box, productId: productSmall, uuid: 'fixed-uuid');
    for (var i = 0; i < 5; i++) {
      await box.drain();
    }

    expect(seen, hasLength(5));
    expect(seen.toSet(), {productSmall},
        reason: 'the server ignores a retry payload once the clientuuid '
            'matches, so a payload that drifted between attempts would make '
            'the stored item and the posted document disagree silently');
    expect(box.items.single.status, WsOutboxStatus.synced);
  });

  // ═══ 4 · EACH DOCUMENT KEEPS ITS OWN ══════════════════════════════════════

  test('4. two queued deliveries retain their individual productIds', () async {
    final path = '${dir.path}/q.json';
    final posted = <Object?>[];

    final box = WsOutbox(
      store: WsOutboxFileStore(path),
      poster: (item) async {
        posted.add(item.args['p_productid']);
        return const WsPostResult.success(documentId: 1);
      },
    );
    await box.load();

    await queueDelivery(box, productId: productDefault, uuid: 'a');
    await queueDelivery(box, productId: productSmall, uuid: 'b');
    await box.drain();

    expect(posted, [productDefault, productSmall],
        reason: 'FIFO, and each carries what it was saved with');
  });

  // ═══ 5 · NULL IS STILL LEGITIMATE ═════════════════════════════════════════

  test('5. a null productId preserves the server-default path', () async {
    final path = '${dir.path}/q.json';
    Object? postedProduct = 'not called';
    var containsKey = false;

    final box = WsOutbox(
      store: WsOutboxFileStore(path),
      poster: (item) async {
        containsKey = item.args.containsKey('p_productid');
        postedProduct = item.args['p_productid'];
        return const WsPostResult.success(documentId: 1);
      },
    );
    await box.load();

    await queueDelivery(box, productId: null);
    await box.drain();

    expect(containsKey, isTrue,
        reason: 'the key must be SENT as null, not omitted — that is what '
            'makes ws_record_delivery resolve its own default');
    expect(postedProduct, isNull);
  });

  test('5b. a null productId survives a reload as null, not as missing',
      () async {
    final path = '${dir.path}/q.json';
    final box = offlineBox(path);
    await box.load();
    await queueDelivery(box, productId: null);
    await box.drain();

    final reopened = offlineBox(path);
    await reopened.load();

    expect(reopened.items.single.args.containsKey('p_productid'), isTrue);
    expect(reopened.items.single.args['p_productid'], isNull);
  });

  // ═══ 6 · THE UI CANNOT REACH BACK INTO A QUEUED DOCUMENT ══════════════════

  test('6. changing the product selection after queueing cannot mutate it',
      () async {
    final path = '${dir.path}/q.json';

    // What the driver has on screen right now. The poster must never read it.
    var uiSelectedProduct = productDefault;

    final posted = <Object?>[];
    final box = WsOutbox(
      store: WsOutboxFileStore(path),
      poster: (item) {
        posted.add(item.args['p_productid']);
        return Future.value(const WsPostResult.network('offline'));
      },
    );
    await box.load();

    final item = await queueDelivery(box, productId: uiSelectedProduct);
    await box.drain();

    // Driver switches the picker to something else and records nothing.
    uiSelectedProduct = productSmall;

    // A later drain — the auto-sync timer, say — must still post the original.
    final reopened = WsOutbox(
      store: WsOutboxFileStore(path),
      poster: (i) async {
        posted.add(i.args['p_productid']);
        return const WsPostResult.success(documentId: 5);
      },
    );
    await reopened.load();
    await reopened.drain();

    expect(item.args['p_productid'], productDefault);
    expect(posted.toSet(), {productDefault},
        reason: 'the queued payload decides the product, exactly as it decides '
            'the branch and the GPS fix');
    expect(
      jsonDecode(File(path).readAsStringSync())[0]['args']['p_productid'],
      productDefault,
    );
  });

  // ═══ 7 · PRESELECTION ═════════════════════════════════════════════════════

  group('7. default-product preselection', () {
    List<Map<String, dynamic>> rows(List<int> ids) =>
        [for (final id in ids) {'productid': id, 'productname': 'P$id'}];

    test('picks the organization default when it is in the list', () {
      expect(
        wsPreselectedProductId(rows([productSmall, productDefault]),
            productDefault),
        productDefault,
        reason: 'an untouched save must post what the server would have '
            'resolved on its own — the pre-picker behaviour',
      );
    });

    test('ignores a default that is no longer in the list', () {
      // fetchProducts filters isactive; fetchDefaultProductId could still name
      // a product deactivated since. Pinning the field to an id with no
      // matching item renders as blank-but-set.
      expect(wsPreselectedProductId(rows([productSmall, 303]), productDefault),
          isNull);
    });

    test('single-product auto-select outranks a stale default', () {
      // Caught by writing the test above wrongly: with ONE product and a
      // default that is not in the list, the single-product rule still wins.
      // That is correct — one choice is not a choice — but it is a precedence
      // decision, so it is pinned here rather than left implicit.
      expect(wsPreselectedProductId(rows([productSmall]), productDefault),
          productSmall);
    });

    test('auto-selects when there is exactly one product', () {
      expect(wsPreselectedProductId(rows([productSmall]), null), productSmall);
    });

    test('selects nothing when several exist and none is default', () {
      expect(wsPreselectedProductId(rows([productSmall, productDefault]), null),
          isNull,
          reason: 'defaulting to whichever sorted first is the bug the customer '
              'dropdown used to have');
    });

    test('an empty list selects nothing', () {
      expect(wsPreselectedProductId(const [], productDefault), isNull);
      expect(wsPreselectedProductId(const [], null), isNull);
    });
  });

  // ═══ 8 · NO PRODUCTS MUST NOT BLOCK A DELIVERY ════════════════════════════

  group('8. validation', () {
    test('an empty product list does not block saving', () {
      expect(wsProductSelectionValid(const [], null), isTrue,
          reason: 'an organization mid-setup has no products; blocking Save '
              'would turn a missing picker into being unable to record a '
              'delivery at all, and the server still resolves its default');
    });

    test('with products configured, one must be chosen', () {
      final products = [
        {'productid': productSmall, 'productname': 'A'},
        {'productid': productDefault, 'productname': 'B'},
      ];
      expect(wsProductSelectionValid(products, null), isFalse);
      expect(wsProductSelectionValid(products, productSmall), isTrue);
    });
  });
}
