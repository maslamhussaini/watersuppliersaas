// =============================================================================
// test/outbox_ownership_test.dart
// A queued document belongs to whoever created it.
//
// ─── THE FAILURE THIS PREVENTS ───────────────────────────────────────────────
//
// The queue is durable and survives sign-out. Before this, driver A could queue
// deliveries offline, sign out, and driver B sign in on the same tablet — and
// A's deliveries would post under B's session. The server derives orgid from
// the customer, so a DIFFERENT organization is blocked by RLS; two staff in the
// SAME organization is the ordinary shared-tablet case, and the documents
// landed in the ledger attributed to the wrong person.
//
// The owner is captured at Save time and is payload-authoritative, exactly like
// clientUuid, storeid and the GPS fix.
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_kv_store.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';

void main() {
  late WsMemoryKeyValueStore kv;
  String? signedIn;

  setUp(() {
    kv = WsMemoryKeyValueStore();
    signedIn = null;
  });

  /// A fresh outbox over the SAME backing store — an app restart.
  WsOutbox open({
    WsPostResult Function(WsOutboxItem)? post,
    List<String>? postedUuids,
    bool ownership = true,
  }) =>
      WsOutbox(
        store: WsOutboxKvStore(kv),
        currentUserId: ownership ? () => signedIn : null,
        poster: (item) async {
          postedUuids?.add(item.clientUuid);
          return post?.call(item) ?? const WsPostResult.success(documentId: 1);
        },
      );

  Future<WsOutboxItem> queue(
    WsOutbox box, {
    String? uuid,
    String rpc = 'ws_record_delivery',
    String label = 'delivery',
  }) =>
      box.enqueue(
        clientUuid: uuid ?? wsNewUuid(),
        rpc: rpc,
        args: {'p_customerid': 1, 'p_delivered': 2, 'p_storeid': 3},
        label: label,
      );

  /// The stored JSON, as a browser reload would find it.
  Future<List<Map<String, dynamic>>> stored() async {
    final raw = await kv.read('outbox.queue');
    if (raw == null) return [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  // ═══ CAPTURE ══════════════════════════════════════════════════════════════

  group('the owner is captured at Save time', () {
    test('1. a new item records the signed-in user', () async {
      signedIn = 'user-A';
      final box = open();
      await box.load();
      final item = await queue(box);

      expect(item.authUserId, 'user-A');
    });

    test('it is captured at ENQUEUE, not at sync', () async {
      signedIn = 'user-A';
      final box = open();
      await box.load();
      final item = await queue(box);

      // The session changes before the document ever goes out.
      signedIn = 'user-B';

      expect(item.authUserId, 'user-A',
          reason: 'the session that CREATED the document is the truthful one');
    });

    test('it is persisted in the JSON', () async {
      signedIn = 'user-A';
      final box = open();
      await box.load();
      await queue(box, uuid: 'k1');
      await box.drain();

      final rows = await stored();
      expect(rows.single['authUserId'], 'user-A');
    });

    test('11. all four RPC types preserve the owner', () async {
      signedIn = 'user-A';
      final box = open();
      await box.load();

      for (final rpc in const [
        'ws_record_delivery',
        'ws_record_payment',
        'ws_record_vendor_payment',
        'ws_record_purchase',
      ]) {
        final item = await queue(box, rpc: rpc, label: rpc);
        expect(item.authUserId, 'user-A', reason: '$rpc lost the owner');
      }

      await box.drain();
      final rows = await stored();
      expect(rows.map((r) => r['authUserId']).toSet(), {'user-A'});
      expect(rows, hasLength(4));
    });
  });

  // ═══ ISOLATION ════════════════════════════════════════════════════════════

  group('only the owner can drain it', () {
    test('2. user A drains A\'s item', () async {
      signedIn = 'user-A';
      final posted = <String>[];
      final box = open(postedUuids: posted);
      await box.load();
      await queue(box, uuid: 'k1');

      await box.drain();

      expect(posted, ['k1']);
      expect(box.items.single.status, WsOutboxStatus.synced);
    });

    test('3. USER B CANNOT DRAIN A\'S ITEM', () async {
      signedIn = 'user-A';
      final first = open();
      await first.load();
      await queue(first, uuid: 'k1');

      // A signs out; B signs in on the same device; the app restarts.
      signedIn = 'user-B';
      final posted = <String>[];
      final second = open(postedUuids: posted);
      await second.load();

      await second.drain();

      expect(posted, isEmpty,
          reason: "A's delivery must not post under B's session");
    });

    test('4. B\'s drain leaves the item completely unchanged', () async {
      signedIn = 'user-A';
      final first = open();
      await first.load();
      final original = await queue(first, uuid: 'k1');
      final createdAt = original.createdAt;

      signedIn = 'user-B';
      final second = open();
      await second.load();
      await second.drain();

      final item = second.items.single;
      expect(item.status, WsOutboxStatus.pending, reason: 'not marked failed');
      expect(item.attempts, 0, reason: 'no attempt was made');
      expect(item.budgetedAttempts, 0, reason: 'no retry budget consumed');
      expect(item.lastError, isNull);
      expect(item.authUserId, 'user-A');
      expect(item.createdAt, createdAt);
      expect(second.items, hasLength(1), reason: 'NEVER deleted');
    });

    test('5. A can come back later and drain it', () async {
      signedIn = 'user-A';
      final first = open();
      await first.load();
      await queue(first, uuid: 'k1');

      // B has a turn and posts nothing.
      signedIn = 'user-B';
      final second = open();
      await second.load();
      await second.drain();

      // A signs back in.
      signedIn = 'user-A';
      final posted = <String>[];
      final third = open(postedUuids: posted);
      await third.load();
      await third.drain();

      expect(posted, ['k1']);
      expect(third.items.single.status, WsOutboxStatus.synced);
    });

    test('a mixed queue drains only the current user\'s items', () async {
      signedIn = 'user-A';
      final a = open();
      await a.load();
      await queue(a, uuid: 'a1');

      signedIn = 'user-B';
      final b = open();
      await b.load();
      await queue(b, uuid: 'b1');

      final posted = <String>[];
      final drainer = open(postedUuids: posted);
      await drainer.load();
      await drainer.drain();

      expect(posted, ['b1'], reason: 'B is signed in');
      final byUuid = {
        for (final i in drainer.items) i.clientUuid: i.status,
      };
      expect(byUuid['a1'], WsOutboxStatus.pending);
      expect(byUuid['b1'], WsOutboxStatus.synced);
    });

    test('10. an existing owner is NEVER overwritten', () async {
      signedIn = 'user-A';
      final first = open();
      await first.load();
      await queue(first, uuid: 'k1');

      signedIn = 'user-B';
      final second = open();
      await second.load();
      await second.drain(); // adoption pass runs here

      expect(second.items.single.authUserId, 'user-A',
          reason: 'adoption touches nulls only — never a reassignment');
      expect((await stored()).single['authUserId'], 'user-A');
    });
  });

  // ═══ LEGACY ADOPTION ══════════════════════════════════════════════════════

  group('legacy items with no owner', () {
    /// A queue file written before ownership existed: no authUserId key at all.
    Future<void> seedLegacy(List<String> uuids) async {
      await kv.write(
        'outbox.queue',
        jsonEncode([
          for (var i = 0; i < uuids.length; i++)
            {
              'seq': i + 1,
              'clientUuid': uuids[i],
              'rpc': 'ws_record_delivery',
              'args': {'p_customerid': 1},
              'label': 'delivery',
              'createdAt': DateTime.utc(2026, 8, 1).toIso8601String(),
              'status': 'pending',
              'attempts': 0,
            }
        ]),
      );
    }

    test('4b. fromJson tolerates a file with no owner field', () async {
      await seedLegacy(['old-1']);
      final box = open();
      await box.load();

      expect(box.items.single.authUserId, isNull);
      expect(box.items.single.clientUuid, 'old-1',
          reason: 'the rest of the record still reads correctly');
    });

    test('6. the first authenticated user adopts it', () async {
      await seedLegacy(['old-1']);
      signedIn = 'user-A';
      final posted = <String>[];
      final box = open(postedUuids: posted);
      await box.load();

      await box.drain();

      expect(box.items.single.authUserId, 'user-A');
      expect(posted, ['old-1'], reason: 'and then it drains normally');
    });

    test('7. the adoption survives a reload', () async {
      await seedLegacy(['old-1']);
      signedIn = 'user-A';
      final box = open(post: (_) => const WsPostResult.network('offline'));
      await box.load();
      await box.drain();

      // Restart. The adoption must be on disk, not just in memory.
      final reopened = open();
      await reopened.load();

      expect(reopened.items.single.authUserId, 'user-A');
      expect((await stored()).single['authUserId'], 'user-A');
    });

    test('8. MANY legacy items are all adopted by the SAME user', () async {
      await seedLegacy(['old-1', 'old-2', 'old-3']);
      signedIn = 'user-A';
      final box = open(post: (_) => const WsPostResult.network('offline'));
      await box.load();

      await box.drain();

      expect(box.items.map((i) => i.authUserId).toSet(), {'user-A'},
          reason: 'one pass, one owner — never split across two users who each '
              'drained part of the queue');
    });

    test('the adoption is persisted BEFORE anything posts', () async {
      await seedLegacy(['old-1']);
      signedIn = 'user-A';

      String? ownerOnDiskWhenPosting;
      final box = WsOutbox(
        store: WsOutboxKvStore(kv),
        currentUserId: () => signedIn,
        poster: (item) async {
          final raw = await kv.read('outbox.queue');
          final rows = (jsonDecode(raw!) as List).cast<Map<String, dynamic>>();
          ownerOnDiskWhenPosting = rows.first['authUserId'] as String?;
          return const WsPostResult.success(documentId: 1);
        },
      );
      await box.load();
      await box.drain();

      expect(ownerOnDiskWhenPosting, 'user-A',
          reason: 'a crash between adopting and posting must not leave the '
              'queue unowned');
    });

    test('9. NO SESSION means no adoption and no drain', () async {
      await seedLegacy(['old-1']);
      signedIn = null;
      final posted = <String>[];
      final box = open(postedUuids: posted);
      await box.load();

      await box.drain();

      expect(posted, isEmpty);
      expect(box.items.single.authUserId, isNull,
          reason: 'never adopted by a null/empty owner');
      expect((await stored()).single['authUserId'], isNull);
      expect(box.items.single.attempts, 0);
    });

    test('a later sign-in then adopts and drains them', () async {
      await seedLegacy(['old-1']);
      signedIn = null;
      final cold = open();
      await cold.load();
      await cold.drain(); // startup, before the auth gate resolves

      signedIn = 'user-A';
      final posted = <String>[];
      final warm = open(postedUuids: posted);
      await warm.load();
      await warm.drain();

      expect(posted, ['old-1']);
      expect(warm.items.single.authUserId, 'user-A');
    });
  });

  // ═══ LOST RESPONSE, WITH OWNERSHIP ════════════════════════════════════════

  test('a committed-but-lost response is retried by A, never by B', () async {
    // A enqueues → the RPC commits → the reply is lost → the item stays.
    signedIn = 'user-A';
    final seen = <String>[];
    var serverRows = 0;

    final a = WsOutbox(
      store: WsOutboxKvStore(kv),
      currentUserId: () => signedIn,
      poster: (item) async {
        seen.add(item.clientUuid);
        serverRows++; // ws_record_delivery commits
        return const WsPostResult.network('connection dropped after commit');
      },
    );
    await a.load();
    await queue(a, uuid: 'shared-key');
    await a.drain();

    expect(a.items.single.status, WsOutboxStatus.pending,
        reason: 'still queued — the reply never arrived');

    // B signs in on the same tablet and drains.
    signedIn = 'user-B';
    final b = open(postedUuids: seen);
    await b.load();
    await b.drain();

    expect(seen, ['shared-key'],
        reason: "B must not retry A's document");
    expect(serverRows, 1);

    // A returns and retries.
    signedIn = 'user-A';
    final retry = WsOutbox(
      store: WsOutboxKvStore(kv),
      currentUserId: () => signedIn,
      poster: (item) async {
        seen.add(item.clientUuid);
        // Migration 014: same clientuuid, so the existing row is returned.
        return const WsPostResult.success(documentId: 7);
      },
    );
    await retry.load();
    await retry.drain();

    expect(seen, ['shared-key', 'shared-key'],
        reason: 'ONE key across both attempts, both by A');
    expect(seen.toSet(), hasLength(1));
    expect(serverRows, 1, reason: 'no duplicate document');
    expect(retry.items.single.documentId, 7);
  });

  // ═══ NOTHING ELSE CHANGED ═════════════════════════════════════════════════

  group('12. existing behaviour is untouched', () {
    test('with NO provider the queue behaves exactly as before', () async {
      final posted = <String>[];
      final box = open(ownership: false, postedUuids: posted);
      await box.load();
      await queue(box, uuid: 'k1');

      await box.drain();

      expect(posted, ['k1'],
          reason: 'no provider means ownership is not in use — this is what '
              'every pre-existing suite and the Postgres matrix rely on');
      expect(box.items.single.authUserId, isNull);
    });

    test('FIFO order is preserved among one owner\'s items', () async {
      signedIn = 'user-A';
      final posted = <String>[];
      final box = open(postedUuids: posted);
      await box.load();
      for (final k in ['a', 'b', 'c']) {
        await queue(box, uuid: k);
      }

      await box.drain();

      expect(posted, ['a', 'b', 'c']);
    });

    test('the retry budget still only counts server refusals', () async {
      signedIn = 'user-A';
      final box = open(post: (_) => const WsPostResult.network('offline'));
      await box.load();
      await queue(box, uuid: 'k1');

      await box.drain();
      await box.drain();

      expect(box.items.single.budgetedAttempts, 0,
          reason: 'network failures never consume the budget');
      expect(box.items.single.attempts, 2);
    });

    test('a skipped foreign item does not consume ITS retry budget', () async {
      signedIn = 'user-A';
      final a = open();
      await a.load();
      await queue(a, uuid: 'a1');

      signedIn = 'user-B';
      final b = open();
      await b.load();
      for (var i = 0; i < 20; i++) {
        await b.drain();
      }

      final foreign = b.items.firstWhere((i) => i.clientUuid == 'a1');
      expect(foreign.attempts, 0);
      expect(foreign.budgetedAttempts, 0);
      expect(foreign.status, WsOutboxStatus.pending,
          reason: 'twenty drains by the wrong user must not exhaust A\'s '
              'retries or fail the document');
    });
  });

  // ═══ THE SERIALIZED SHAPE ═════════════════════════════════════════════════

  test('the JSON carries authUserId for new items and null for legacy',
      () async {
    signedIn = 'user-A';
    final box = open(post: (_) => const WsPostResult.network('offline'));
    await box.load();
    await queue(box, uuid: 'new-1');
    await box.drain();

    final rows = await stored();
    expect(rows.single.containsKey('authUserId'), isTrue);
    expect(rows.single['authUserId'], 'user-A');

    // And a file written without the key still loads.
    final legacy = jsonDecode(jsonEncode(rows.single)) as Map<String, dynamic>
      ..remove('authUserId');
    expect(WsOutboxItem.fromJson(legacy).authUserId, isNull);
  });

  // ═══ THE UI BOUNDARY ══════════════════════════════════════════════════════
  //
  // The drain has always been owner-aware. WsSyncScreen was not: it rendered
  // box.items raw, so on a shared tablet one driver could read another's
  // customer names and amounts out of the labels — and permanently discard
  // their unsent deliveries, because discard() matched on clientUuid alone.
  //
  // The rule is deliberately NOT `authUserId == uid`. A null owner is work that
  // _adoptLegacy will claim for whoever drains next; hiding it would make live
  // work invisible to everyone, which is worse than showing it to the wrong
  // person.

  group('what a signed-in user may SEE', () {
    test("another user's item is not visible", () async {
      final box = open();
      signedIn = 'user-A';
      await queue(box, uuid: 'a-1', label: 'Payment 500 — Ahmed');

      signedIn = 'user-B';
      final seen = box.visibleToCurrentUser;

      expect(seen, isEmpty,
          reason: "the label carries a customer name and an amount — that is "
              "the exposure, not just an untidy list");
      expect(box.items.length, 1, reason: 'still queued, just not shown');
    });

    test('a null-owner item stays visible', () async {
      final box = open();
      signedIn = null; // no session: enqueue records no owner
      await queue(box, uuid: 'legacy-1');

      signedIn = 'user-A';
      expect(box.visibleToCurrentUser.map((e) => e.clientUuid), ['legacy-1'],
          reason: 'unowned work is about to be adopted by whoever drains '
              'next; hiding it would make live work invisible to everyone');
    });

    test("the user's own items are visible", () async {
      final box = open();
      signedIn = 'user-A';
      await queue(box, uuid: 'a-1');
      await queue(box, uuid: 'a-2');

      expect(box.visibleToCurrentUser.length, 2);
    });

    test('no session shows nothing at all', () async {
      final box = open();
      signedIn = 'user-A';
      await queue(box, uuid: 'a-1');

      signedIn = null;
      expect(box.visibleToCurrentUser, isEmpty,
          reason: 'fails closed — an empty list is recoverable, a wrongly '
              'permitted discard is not');
    });

    test('mixed queue shows own and unowned, never the other user', () async {
      final box = open();
      signedIn = null;
      await queue(box, uuid: 'legacy-1');
      signedIn = 'user-B';
      await queue(box, uuid: 'b-1');
      signedIn = 'user-A';
      await queue(box, uuid: 'a-1');

      expect(box.visibleToCurrentUser.map((e) => e.clientUuid).toSet(),
          {'legacy-1', 'a-1'});
    });

    test('with ownership NOT in use, everything is visible', () async {
      final box = open(ownership: false);
      await queue(box, uuid: 'x-1');
      await queue(box, uuid: 'x-2');

      expect(box.visibleToCurrentUser.length, 2,
          reason: 'a null PROVIDER means ownership is not in use, which is '
              'not the same as a provider returning null');
    });
  });

  // ═══ THE DATA-LOSS GUARD ══════════════════════════════════════════════════

  group('discard is authorised, not just hidden', () {
    test("refuses another user's item, and does not remove it", () async {
      final box = open();
      signedIn = 'user-A';
      await queue(box, uuid: 'a-1');

      signedIn = 'user-B';
      expect(await box.discard('a-1'), isFalse);

      expect(box.items.length, 1, reason: 'THE DATA-LOSS CASE: discard has no '
          'tombstone and no undo. A refused one must leave the item present');
      expect((await stored()).length, 1, reason: 'and persisted');
    });

    test('allows the owner', () async {
      final box = open();
      signedIn = 'user-A';
      await queue(box, uuid: 'a-1');

      expect(await box.discard('a-1'), isTrue);
      expect(box.items, isEmpty);
    });

    test('allows a null-owner item', () async {
      final box = open();
      signedIn = null;
      await queue(box, uuid: 'legacy-1');

      signedIn = 'user-A';
      expect(await box.discard('legacy-1'), isTrue);
    });

    test('refuses when there is no session', () async {
      final box = open();
      signedIn = 'user-A';
      await queue(box, uuid: 'a-1');

      signedIn = null;
      expect(await box.discard('a-1'), isFalse);
      expect(box.items.length, 1);
    });
  });

  group('retry is authorised, not just hidden', () {
    /// Queues an item and drives it to Failed through a permanent refusal.
    Future<WsOutbox> withFailedItem(String owner, String uuid) async {
      final box = open(post: (_) => const WsPostResult.permanent('refused'));
      signedIn = owner;
      await queue(box, uuid: uuid);
      await box.drain();
      expect(box.byUuid(uuid)!.status, WsOutboxStatus.failed);
      return box;
    }

    test("refuses another user's failed item, changing NOTHING", () async {
      final box = await withFailedItem('user-A', 'a-1');
      final before = box.byUuid('a-1')!;
      final attempts = before.attempts;
      final budgeted = before.budgetedAttempts;

      signedIn = 'user-B';
      expect(await box.retry('a-1'), isFalse);

      final after = box.byUuid('a-1')!;
      expect(after.status, WsOutboxStatus.failed,
          reason: 'a refused retry must not strip another driver\'s failure '
              'state out of their own triage list');
      expect(after.attempts, attempts);
      expect(after.budgetedAttempts, budgeted);
    });

    test('allows the owner', () async {
      final box = await withFailedItem('user-A', 'a-1');
      expect(await box.retry('a-1'), isTrue);
      expect(box.byUuid('a-1')!.status, WsOutboxStatus.pending);
      expect(box.byUuid('a-1')!.attempts, 0);
    });

    test('allows a null-owner failed item', () async {
      final box = open(post: (_) => const WsPostResult.permanent('refused'));
      signedIn = null;
      await queue(box, uuid: 'legacy-1');
      // No session, so the drain defers — fail it through a signed-in drain,
      // which adopts it first.
      signedIn = 'user-A';
      await box.drain();
      expect(box.byUuid('legacy-1')!.status, WsOutboxStatus.failed);

      expect(await box.retry('legacy-1'), isTrue);
    });

    test('refuses when there is no session', () async {
      final box = await withFailedItem('user-A', 'a-1');
      signedIn = null;
      expect(await box.retry('a-1'), isFalse);
      expect(box.byUuid('a-1')!.status, WsOutboxStatus.failed);
    });
  });

  tearDown(() async {
    // No temp files are used, but keep the contract explicit.
    expect(Directory.systemTemp.existsSync(), isTrue);
  });
}
