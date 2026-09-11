// =============================================================================
// lib/services/outbox/ws_outbox_supabase.dart
// The only place the outbox meets Supabase.
//
// ws_outbox.dart is pure Dart on purpose. Everything platform- or
// backend-specific lives here: where the file goes, how an RPC is called, and
// — the part that actually matters — how a failure is CLASSIFIED.
//
// ─── NOTHING EXISTING CHANGES ────────────────────────────────────────────────
//
// WsDataService.recordDelivery() and friends are untouched and still post
// directly. This file adds a parallel path. A screen opts in by calling
// WsOutboxService.recordDelivery(); one that does not is unaffected.
//
// ─── CLASSIFICATION IS THE WHOLE JOB ─────────────────────────────────────────
//
// Retryable vs permanent is the one judgement the queue cannot make for
// itself, and getting it wrong is expensive in both directions:
//
//   · A permanent error treated as retryable blocks every document behind it
//     and burns the retry budget on something that will never work.
//   · A retryable error treated as permanent strands a valid document in
//     Failed until a human notices.
//
// The rule used here: anything that is about the NETWORK is retryable;
// anything the DATABASE decided is permanent. A database that answered at all
// will answer the same way next time — with one exception, noted below.
// =============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../storage/ws_kv_default.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// `supabase` and `supabaseClientInitialized` are top-level getters in main.dart,
// not members of WsDataService. supabase_service.dart imports main.dart for the
// same reason, so the (permitted, getter-only) cycle is already established.
import '../../main.dart'
    show supabase, supabaseClient, supabaseClientInitialized;
import '../cache/ws_customer_cache.dart';
import '../cache/ws_master_cache.dart';
import '../location_service.dart';
import '../supabase_service.dart';
import '../tenant_service.dart';
import 'ws_outbox.dart';
import 'ws_outbox_auto_sync.dart';
import 'ws_outbox_lookup.dart';
import 'ws_outbox_store.dart';

class WsOutboxService {
  WsOutboxService._();

  static WsOutbox? _box;
  static WsOutbox? get instanceOrNull => _box;

  /// Call once from main(), after Supabase.initialize().
  static Future<WsOutbox> init() async {
    if (_box != null) return _box!;

    // Storage is chosen behind the seam — see ws_kv_default.dart. This used to
    // call getApplicationSupportDirectory() directly, which has no web
    // implementation and therefore threw on the only platform this project
    // ships to, leaving the queue uninitialised.
    final box = WsOutbox(
      store: await wsOpenDefaultOutboxStore(),
      poster: _post,
      // WHO IS SIGNED IN, read fresh on every enqueue and every drain.
      //
      // Returns null before sign-in and after sign-out, which is exactly what
      // the drain needs to defer rather than post somebody else's document
      // under the current session. supabaseClientInitialized guards the cold
      // path where Supabase.initialize has not completed.
      currentUserId: () => supabaseClientInitialized
          ? supabase.auth.currentSession?.user.id
          : null,
    );
    await box.load();
    _box = box;

    // Anything stranded by the last run goes out now. Failing is fine — it
    // stays queued.
    //
    // Still fire-and-forget, unlike the enqueue paths: nobody is reading a
    // status here, and startup must not wait on the network. But the throw is
    // no longer allowed to escape — an unguarded unawaited() surfaces as a
    // bare "Uncaught Error" with no Dart context in a release build, which is
    // indistinguishable from a crash and impossible to diagnose.
    unawaited(box.drain().catchError((Object e) {
      debugPrint('outbox: startup drain failed — $e');
      return const WsDrainReport();
    }));
    return box;
  }

  // ── Queueing an operation ────────────────────────────────────────────────
  //
  // ENQUEUE FIRST, ALWAYS — online or not. A document that exists only inside
  // an in-flight HTTP request exists nowhere if the process dies. Writing it
  // to disk first costs a few milliseconds and makes the save durable before
  // anything can go wrong.

  /// How long a save waits for the post before reporting. See [_settle].
  static const settleWindow = Duration(seconds: 3);

  /// Post, and give it a BOUNDED chance to finish before the caller reports.
  ///
  /// ─── WHY THIS IS NOT `unawaited(box.drain())` ANY MORE ───────────────────
  ///
  /// Every caller does `final item = await record...()` and then switches on
  /// `item.status`. With a fire-and-forget drain that read happened while the
  /// status was still `pending`, because drain() awaits a persist and an HTTP
  /// round trip before it can be anything else. So an ONLINE save that
  /// succeeded a few hundred milliseconds later still told the driver
  /// "Saved on this device — waiting to sync".
  ///
  /// The comment above that switch says the message must match reality. It
  /// did not: it sampled reality before reality existed.
  ///
  /// ─── WHAT IS DELIBERATELY UNCHANGED ──────────────────────────────────────
  ///
  /// Enqueue-before-post still happens; the document is durable before this is
  /// called. The drain algorithm, WsPostResult classification, the retry
  /// budget, the network-vs-budgeted distinction and every status transition
  /// are untouched — this only decides how long the CALLER waits before
  /// reporting.
  ///
  /// The wait is bounded, so offline is not punished: drain() fails fast with
  /// no connection, and if the network merely hangs the caller is released
  /// after [settleWindow] and truthfully reports the item as still queued. The
  /// drain carries on in the background either way, so nothing is abandoned.
  ///
  /// catchError is attached to the drain BEFORE the timeout, not after. A
  /// throw arriving once the timeout has already fired would otherwise land on
  /// a future nobody is holding — which is exactly how a successful sync could
  /// still produce an uncaught error.
  static Future<void> _settle(WsOutbox box) async {
    final draining = box.drain().catchError((Object e) {
      debugPrint('outbox: drain failed — $e');
      return const WsDrainReport();
    });
    await draining.timeout(
      settleWindow,
      onTimeout: () => const WsDrainReport(),
    );
  }

  static Future<WsOutboxItem> recordDelivery({
    required String clientUuid,
    required int storeId,
    /// Where the driver was when they saved. Null when location was
    /// unavailable or declined — never a reason to refuse the delivery.
    WsPosition? position,
    required int customerId,
    required String customerName,
    DateTime? deliveryDate,
    int delivered = 0,
    int returned = 0,
    int? productId,
    double amountPaid = 0,
    String paymentMethod = 'cash',
    int? deliveredById,
    int? routeId,
    String? notes,
  }) async {
    final box = _box;
    if (box == null) throw StateError('WsOutboxService.init() not called');

    final item = await box.enqueue(
      clientUuid: clientUuid,
      rpc: 'ws_record_delivery',
      args: {
        'p_customerid': customerId,
        'p_deliverydate': _d(deliveryDate ?? DateTime.now()),
        'p_delivered': delivered,
        'p_returned': returned,
        'p_productid': productId,
        'p_amountpaid': amountPaid,
        'p_paymentmethod': paymentMethod,
        'p_deliveredbyid': deliveredById,
        'p_routeid': routeId,
        'p_notes': notes,
        'p_clientuuid': clientUuid,
        // CAPTURED HERE, ONCE. Stored in the payload and replayed unchanged,
        // so a delivery queued in one branch still posts to that branch after
        // the user has switched to another. The sync path must never resolve
        // this from the currently selected store.
        'p_storeid': storeId,
        // FROZEN AT SAVE TIME, for the same reason as the store and the key.
        // A delivery queued in one street and synced from another must report
        // where it happened, so the sync path replays these and never re-reads
        // the GPS.
        if (position != null) ...position.toArgs(),
      },
      label: '$delivered out / $returned in — $customerName',
    );

    await _settle(box);
    return item;
  }

  static Future<WsOutboxItem> recordPayment({
    required String clientUuid,
    required int storeId,
    required int customerId,
    required String customerName,
    required double amount,
    DateTime? paymentDate,
    String paymentMethod = 'cash',
    String? referenceNo,
    String? notes,
  }) async {
    final box = _box;
    if (box == null) throw StateError('WsOutboxService.init() not called');

    final item = await box.enqueue(
      clientUuid: clientUuid,
      rpc: 'ws_record_payment',
      args: {
        'p_customerid': customerId,
        'p_amount': amount,
        'p_paymentdate': _d(paymentDate ?? DateTime.now()),
        'p_paymentmethod': paymentMethod,
        'p_referenceno': referenceNo,
        'p_notes': notes,
        'p_clientuuid': clientUuid,
        'p_storeid': storeId,   // see recordDelivery
      },
      label: 'Payment $amount — $customerName',
    );

    await _settle(box);
    return item;
  }

  /// Money paid OUT to a vendor.
  ///
  /// Same shape as the others: enqueue first, then drain. The RPC
  /// (migration 013) is idempotent, so the retry a lost response triggers
  /// returns the original vendorpaymentid rather than paying twice.
  static Future<WsOutboxItem> recordVendorPayment({
    required String clientUuid,
    required int storeId,
    required int vendorId,
    required String vendorName,
    required double amount,
    DateTime? paidDate,
    int? purchaseId,
    String? referenceNo,
    String? notes,
  }) async {
    final box = _box;
    if (box == null) throw StateError('WsOutboxService.init() not called');

    final item = await box.enqueue(
      clientUuid: clientUuid,
      rpc: 'ws_record_vendor_payment',
      args: {
        'p_vendorid': vendorId,
        'p_amount': amount,
        'p_paiddate': _d(paidDate ?? DateTime.now()),
        'p_purchaseid': purchaseId,
        'p_referenceno': referenceNo,
        'p_notes': notes,
        'p_clientuuid': clientUuid,
        'p_storeid': storeId,   // see recordDelivery
      },
      label: 'Paid $amount — $vendorName',
    );

    await _settle(box);
    return item;
  }

  /// A purchase: header plus every line, posted atomically by the RPC.
  ///
  /// [lines] is stored VERBATIM in the queue and replayed unchanged, so a
  /// retry sends byte-identical JSON. That matters because the server ignores
  /// a retry's payload — if the queue mutated it between attempts the stored
  /// item and the posted document would silently disagree.
  static Future<WsOutboxItem> recordPurchase({
    required String clientUuid,
    required int storeId,
    required int vendorId,
    required String vendorName,
    required List<Map<String, dynamic>> lines,
    DateTime? purchaseDate,
    String? billNo,
    String? notes,
  }) async {
    final box = _box;
    if (box == null) throw StateError('WsOutboxService.init() not called');
    if (lines.isEmpty) {
      // Refused before it reaches the queue. A purchase with no lines cannot
      // ever post (the RPC rejects it), so queuing one would create an item
      // that fails forever and blocks nothing but itself.
      throw ArgumentError('A purchase must have at least one line.');
    }

    final item = await box.enqueue(
      clientUuid: clientUuid,
      rpc: 'ws_record_purchase',
      args: {
        'p_vendorid': vendorId,
        'p_lines': lines,
        'p_purchasedate': _d(purchaseDate ?? DateTime.now()),
        'p_billno': billNo,
        'p_notes': notes,
        'p_clientuuid': clientUuid,
        'p_storeid': storeId,   // see recordDelivery
      },
      label: '${lines.length} line${lines.length == 1 ? '' : 's'} — $vendorName',
    );

    await _settle(box);
    return item;
  }

  static String _d(DateTime v) => v.toIso8601String().split('T').first;

  // ── Posting one item ─────────────────────────────────────────────────────

  static Future<WsPostResult> _post(WsOutboxItem item) async {
    if (!supabaseClientInitialized) {
      // Treated as a transport failure, not a server one: there is no backend
      // to have an opinion yet. Marking these failed would put every queued
      // document in the red list because of a configuration problem that has
      // nothing to do with them.
      return const WsPostResult.network('Supabase is not configured');
    }
    try {
      final result = await supabase
          .rpc(item.rpc, params: item.args)
          .timeout(const Duration(seconds: 25));
      final id = result is num ? result.toInt() : null;
      return WsPostResult.success(documentId: id);
    } catch (e) {
      // ONE catch, delegating to a classifier that can be called directly.
      // The chain below preserves the previous `on X catch` ORDER exactly;
      // only reachability changed, so that the rules can be tested without a
      // live Supabase client. See classifyPostError.
      return classifyPostError(e);
    }
  }

  /// Maps a thrown error onto the outcome that decides an item's fate.
  ///
  /// Visible for testing because this is the whole safety argument of the
  /// queue: NETWORK means "never reached a server, keep it pending forever",
  /// and anything else spends a slice of the attempt budget that ends in
  /// Failed. Getting one line of it wrong strands real deliveries, which is
  /// exactly what happened, so it must be reachable by a test rather than
  /// only by a browser and a disconnected cable.
  @visibleForTesting
  static WsPostResult classifyPostError(Object e) {
    if (e is PostgrestException) {
      return _classifyPostgrest(e);
    }
    if (e is AuthException) {
      // ─── A FAILED REFRESH IS NOT AN EXPIRED SESSION ────────────────────
      //
      // When the access token needs refreshing, the SDK calls
      //     /auth/v1/token?grant_type=refresh_token
      // BEFORE the RPC. Offline, that call never leaves the browser, and
      // gotrue turns the transport error into AuthRetryableFetchException —
      // see gotrue fetch.dart, `if (error is! Response) throw
      // AuthRetryableFetchException(...)`. "is not a Response" is precisely
      // "no server ever answered".
      //
      // This clause used to catch that as a plain AuthException and report
      // "Sign-in expired", which is a SERVER-produced verdict and therefore
      // consumes the attempt budget. Eight offline drains later the delivery
      // sat in Failed — and because `pending` excludes failed items,
      // hasPendingWork() then returned false and no timer, auth event or
      // resume could ever pick it up again. A delivery made out of coverage
      // walked itself into a state only a human could escape, which is the
      // exact outcome the network-classification rule in ws_outbox.dart
      // exists to prevent.
      //
      // The generic catch below already classifies `ClientException` as
      // network correctly — this clause simply intercepted it first.
      //
      // The TYPE is the test, not the message: a genuinely rejected refresh
      // token comes back as a real HTTP response and becomes
      // AuthApiException with a 4xx status, so it still falls through to the
      // "Sign-in expired" case below, where it belongs.
      if (e is AuthRetryableFetchException) {
        return WsPostResult.network(
            'Sign-in refresh could not reach the server: ${e.message}');
      }

      // A genuine auth failure. Retryable, not permanent: the SDK refreshes
      // tokens, and the next drain after a sign-in succeeds.
      return WsPostResult.retryable('Sign-in expired: ${e.message}');
    }
    if (e is TimeoutException) {
      // THE DANGEROUS ONE. The request may well have been applied. Retry is
      // correct and safe — migration 010 makes the second attempt a read.
      //
      // Classed as NETWORK: a timeout is the signature failure of a bad
      // connection, and it must not push a real delivery into Failed.
      return WsPostResult.network('Timed out: $e');
    }
    {
      final s = '$e';
      if (s.contains('SocketException') ||
          s.contains('Failed host lookup') ||
          s.contains('ClientException') ||
          s.contains('Connection closed') ||
          s.contains('Connection reset') ||
          s.contains('Connection refused') ||
          s.contains('Network is unreachable') ||
          s.contains('NetworkException') ||
          s.contains('HandshakeException')) {
        // Never reached a server. Stays pending for as long as it takes.
        return WsPostResult.network('Network: $s');
      }
      // Unrecognised. Retryable rather than permanent: an unknown error that
      // is actually transient costs one more attempt, while an unknown error
      // wrongly marked permanent strands a real document.
      //
      // It DOES consume the budget, deliberately — an unknown error repeating
      // forever is something a person should end up looking at.
      return WsPostResult.retryable(s);
    }
  }

  static WsPostResult _classifyPostgrest(PostgrestException e) {
    final code = e.code ?? '';
    final status = int.tryParse('${e.code}');

    // 23505 — unique violation, which here means the clientuuid index fired.
    // That is a RACE, not a failure: two attempts overlapped and the other one
    // won. The next attempt hits the idempotency check inside the function and
    // returns the existing id, so this is retryable rather than permanent.
    if (code == '23505') {
      return WsPostResult.retryable(
          'Already being posted (duplicate key) — will resolve on retry',
          code: code);
    }

    // Genuine server-side faults. The database was reached but broke.
    if (status != null && status >= 500) {
      return WsPostResult.retryable(e.message, statusCode: status, code: code);
    }

    // Everything else is a decision the database made deliberately and will
    // make again: permission denied, customer not found, a check constraint,
    // a bad foreign key. Retrying cannot change the answer.
    //
    //   42501 permission denied      P0002 not found
    //   23514 check violation        23503 foreign key
    //   22023 invalid parameter
    return WsPostResult.permanent(
      e.message,
      statusCode: status,
      code: code.isEmpty ? null : code,
    );
  }

  // ── Diagnosis ────────────────────────────────────────────────────────────

  /// Did this operation actually reach the server?
  ///
  /// A READ. Answers the question a stuck item raises without another write,
  /// which is the whole reason ws_lookup_clientuuid() exists.
  static Future<List<Map<String, dynamic>>> lookup(String clientUuid) async {
    if (!supabaseClientInitialized) return [];
    final rows = await supabase
        .rpc('ws_lookup_clientuuid', params: {'p_clientuuid': clientUuid});
    if (rows is List) return rows.cast<Map<String, dynamic>>();
    return [];
  }

  /// Reconcile a Failed item against the server.
  ///
  /// If the document turns out to exist, the item is marked synced instead of
  /// being posted again. Useful after a long outage where the queue and the
  /// server may already agree.
  static Future<bool> reconcile(String clientUuid) async {
    final box = _box;
    if (box == null) return false;
    final item = box.byUuid(clientUuid);
    if (item == null) return false;

    final found = await lookup(clientUuid);
    if (found.isEmpty) return false;

    // Match the row to what this item actually posted. If the expected type is
    // absent the operation did NOT land, whatever else shares the key, so the
    // item stays queued rather than being falsely marked synced.
    // See ws_outbox_lookup.dart — that logic is tested in isolation.
    final row = wsPickLookupRow(found, item.rpc);
    if (row == null) return false;

    item.status = WsOutboxStatus.synced;
    item.documentId = (row['docid'] as num?)?.toInt();
    item.syncedAt = DateTime.now();
    item.lastError = null;
    await box.store.save(box.items.map((e) => e.toJson()).toList());
    return true;
  }

  /// Try the queue again. Safe to call from a Retry button, on resume, or on
  /// a timer.
  static Future<WsDrainReport> sync() async =>
      _box?.drain() ?? const WsDrainReport();

  // ── Automatic draining ───────────────────────────────────────────────────

  static WsOutboxAutoSync? _autoSync;

  /// The running auto-sync, or null. Exposed so startup diagnostics and tests
  /// can assert the wiring exists rather than assuming it.
  static WsOutboxAutoSync? get autoSyncOrNull => _autoSync;

  /// Starts automatic draining: on sign-in, on resume, and on a timer.
  ///
  /// Launch blocker B1. Before this, [sync] was reachable only from the Sync
  /// button, so a document whose first post failed waited for a human.
  ///
  /// Adds no sync machinery — every trigger calls [sync], which is already
  /// safe to call repeatedly because drain() refuses to run twice at once.
  /// Idempotent: calling it again returns the running instance.
  static WsOutboxAutoSync startAutoSync({
    Stream<Object?>? authChanges,
    Duration interval = const Duration(minutes: 2),
  }) {
    final existing = _autoSync;
    if (existing != null && existing.isRunning) return existing;

    final auto = WsOutboxAutoSync(
      // Drain the queue, then refresh the master-data caches if they have gone
      // stale.
      //
      // REUSES THE EXISTING TRIGGERS rather than adding a second scheduler:
      // auth change, app resume and the periodic tick already fire at exactly
      // the moments connectivity is worth re-testing, and WsOutboxAutoSync
      // already guards this callback against throwing.
      //
      // Note the timer tick is gated on hasPendingWork, so on a completely idle
      // app the refresh rides on auth change and resume rather than the timer.
      // That is deliberate — an idle app must not re-parse stored keys and
      // re-query Supabase every two minutes — and the staleness window makes
      // the difference immaterial.
      sync: () async {
        await sync();
        await refreshMasterDataIfStale();
      },
      // Reads the live queue each tick rather than capturing a count, so the
      // timer notices work enqueued after it started.
      hasPendingWork: () => (_box?.pendingCount ?? 0) > 0,
      authChanges:
          authChanges ?? supabaseClient?.auth.onAuthStateChange,
      interval: interval,
      log: debugPrint,
    );
    auto.start();
    return _autoSync = auto;
  }

  /// Refetches staff and products when the cache has aged past
  /// [WsMasterCache.staleAfter], so an offline New Delivery opens with data
  /// that is recent rather than whatever was there at sign-in.
  ///
  /// Calls the ordinary fetchers, which already write the cache on success.
  /// Nothing here knows about serialisation, and there is no second refresh
  /// path to keep in step with the first.
  ///
  /// Never throws: offline this is expected to fail, and it is called from a
  /// background trigger that nobody is awaiting.
  static Future<void> refreshMasterDataIfStale() async {
    try {
      if (!supabaseClientInitialized) return;
      final uid = supabaseClient?.auth.currentSession?.user.id;
      if (uid == null) return;
      final orgId = await WsTenantService.currentOrgId;
      if (orgId == null) return;

      if (await WsMasterCache.isStale(WsMasterCache.staffKey,
          uid: uid, orgId: orgId)) {
        await WsDataService.fetchStaff();
      }
      if (await WsMasterCache.isStale(WsMasterCache.productsKey,
          uid: uid, orgId: orgId)) {
        await WsDataService.fetchProducts();
        await WsDataService.fetchDefaultProductId();
      }
      // Customers last: it is the expensive one, and a six-hour window rather
      // than fifteen minutes keeps an ordinary session from repeatedly pulling
      // thousands of rows.
      if (await WsCustomerCache.isStale(uid: uid, orgId: orgId)) {
        await WsDataService.populateCustomerCache();
      }
    } catch (e) {
      debugPrint('master data: refresh skipped — $e');
    }
  }

  /// Stops automatic draining. Nothing is lost — the queue is durable and the
  /// next start picks it up.
  static void stopAutoSync() {
    _autoSync?.stop();
    _autoSync = null;
  }

  // ── Storage health ───────────────────────────────────────────────────────

  /// Non-null when the queue file could not be read cleanly at startup.
  ///
  /// EXISTS SO THE FAILURE CANNOT BE SILENT. Before this, a corrupt queue file
  /// was quarantined and load() returned an empty list, which is
  /// indistinguishable from "you had nothing pending" — the user was told
  /// their work had synced when it had not. Anything showing queue state must
  /// check this and say so.
  static WsOutboxLoadIssue? get loadIssue => _box?.loadIssue;

  /// Dismiss the warning once the user has actually been shown it.
  static void acknowledgeLoadIssue() => _box?.acknowledgeLoadIssue();
}
