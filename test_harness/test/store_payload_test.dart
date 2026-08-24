// =============================================================================
// test/store_payload_test.dart
//
// One rule, locked in: THE QUEUED PAYLOAD DECIDES THE BRANCH.
//
//     select Store A → save → queued with storeid=A
//     → user switches to Store B → queue drains → posts to A
//
// The store is captured once, at save time, exactly like the clientuuid. If
// anything in the sync path ever reads "the store the user is looking at now",
// a driver who changes branch before syncing silently moves yesterday's
// deliveries into the wrong books — and because both branches belong to the
// same organization, vw_ws_reconciliation would still be 0 and nothing would
// flag it.
//
// Pure Dart: no Flutter binding, no database.
// =============================================================================

import 'dart:io';

import 'package:test/test.dart';
import '../lib/ws_outbox.dart';
import '../lib/ws_outbox_store.dart';

const storeA = 11;
const storeB = 22;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ws_store_payload');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// What the UI currently has selected. The poster below must never read it.
  var uiSelectedStore = storeA;

  Future<WsOutboxItem> queueDelivery(WsOutbox box, int storeId) => box.enqueue(
        clientUuid: wsNewUuid(),
        rpc: 'ws_record_delivery',
        args: {
          'p_customerid': 1,
          'p_delivered': 2,
          'p_clientuuid': 'k',
          'p_storeid': storeId, // captured at SAVE time
        },
        label: '2 out — Hotel ABC',
      );

  test('the store is written into the payload at save time', () async {
    final path = '${dir.path}/q.json';
    final box = WsOutbox(
      store: WsOutboxFileStore(path),
      poster: (_) async => const WsPostResult.network('offline'),
    );
    await box.load();

    uiSelectedStore = storeA;
    final item = await queueDelivery(box, uiSelectedStore);
    await box.drain();

    expect(item.args['p_storeid'], storeA);
    expect(File(path).readAsStringSync(), contains('"p_storeid":$storeA'),
        reason: 'it must be on disk, not only in memory');
  });

  test('switching branch does not move a queued document', () async {
    final path = '${dir.path}/q.json';
    final posted = <int?>[];

    WsOutbox open(bool offline) => WsOutbox(
          store: WsOutboxFileStore(path),
          poster: (item) async {
            if (offline) return const WsPostResult.network('offline');
            // FROM THE ITEM. Reading uiSelectedStore here instead is exactly
            // the bug this test exists to catch.
            posted.add(item.args['p_storeid'] as int?);
            return const WsPostResult.success(documentId: 1);
          },
        );

    // Saved while store A is selected, with no connection.
    uiSelectedStore = storeA;
    final offlineBox = open(true);
    await offlineBox.load();
    final item = await queueDelivery(offlineBox, uiSelectedStore);
    await offlineBox.drain();
    expect(item.status, WsOutboxStatus.pending);

    // The user switches branch. The app restarts. The queue drains.
    uiSelectedStore = storeB;
    final afterRestart = open(false);
    await afterRestart.load();
    await afterRestart.drain();

    expect(posted, [storeA],
        reason: 'posted to the branch it was created in, not the current one');
    expect(afterRestart.items.single.status, WsOutboxStatus.synced);
    expect(afterRestart.items.single.args['p_storeid'], storeA,
        reason: 'and the stored payload was never rewritten');
  });

  test('a restart preserves the branch even after many failed attempts',
      () async {
    final path = '${dir.path}/q.json';
    var offline = true;
    final seen = <int?>[];

    WsOutbox open() => WsOutbox(
          store: WsOutboxFileStore(path),
          poster: (item) async {
            seen.add(item.args['p_storeid'] as int?);
            return offline
                ? const WsPostResult.network('offline')
                : const WsPostResult.success(documentId: 7);
          },
        );

    final box = open();
    await box.load();
    await queueDelivery(box, storeA);

    for (var i = 0; i < 5; i++) {
      await box.drain();
    }
    uiSelectedStore = storeB;

    final reopened = open();
    await reopened.load();
    offline = false;
    await reopened.drain();

    expect(seen.toSet(), {storeA},
        reason: 'every attempt, before and after the restart, carried store A');
    expect(reopened.items.single.status, WsOutboxStatus.synced);
  });

  test('each queued document keeps its own branch', () async {
    final path = '${dir.path}/q.json';
    var offline = true;
    final posted = <int?>[];

    WsOutbox open() => WsOutbox(
          store: WsOutboxFileStore(path),
          poster: (item) async {
            if (offline) return const WsPostResult.network('offline');
            posted.add(item.args['p_storeid'] as int?);
            return const WsPostResult.success(documentId: 1);
          },
        );

    final box = open();
    await box.load();
    // Two saves in two different branches, both offline.
    await queueDelivery(box, storeA);
    await queueDelivery(box, storeB);
    await box.drain();

    offline = false;
    final reopened = open();
    await reopened.load();
    await reopened.drain();

    expect(posted, [storeA, storeB],
        reason: 'in creation order, each with the branch it was saved in');
  });
}
