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

import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// `supabase` and `supabaseClientInitialized` are top-level getters in main.dart,
// not members of WsDataService. supabase_service.dart imports main.dart for the
// same reason, so the (permitted, getter-only) cycle is already established.
import '../../main.dart' show supabase, supabaseClientInitialized;
import 'ws_outbox.dart';
import 'ws_outbox_store.dart';

class WsOutboxService {
  WsOutboxService._();

  static WsOutbox? _box;
  static WsOutbox? get instanceOrNull => _box;

  /// Call once from main(), after Supabase.initialize().
  static Future<WsOutbox> init() async {
    if (_box != null) return _box!;

    final dir = await getApplicationSupportDirectory();
    final box = WsOutbox(
      store: WsOutboxFileStore('${dir.path}/ws_outbox.json'),
      poster: _post,
    );
    await box.load();
    _box = box;

    // Anything stranded by the last run goes out now. Failing is fine — it
    // stays queued.
    unawaited(box.drain());
    return box;
  }

  // ── Queueing an operation ────────────────────────────────────────────────
  //
  // ENQUEUE FIRST, ALWAYS — online or not. A document that exists only inside
  // an in-flight HTTP request exists nowhere if the process dies. Writing it
  // to disk first costs a few milliseconds and makes the save durable before
  // anything can go wrong.

  static Future<WsOutboxItem> recordDelivery({
    required String clientUuid,
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
      },
      label: '$delivered out / $returned in — $customerName',
    );

    unawaited(box.drain());
    return item;
  }

  static Future<WsOutboxItem> recordPayment({
    required String clientUuid,
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
      },
      label: 'Payment $amount — $customerName',
    );

    unawaited(box.drain());
    return item;
  }

  /// Money paid OUT to a vendor.
  ///
  /// Same shape as the others: enqueue first, then drain. The RPC
  /// (migration 013) is idempotent, so the retry a lost response triggers
  /// returns the original vendorpaymentid rather than paying twice.
  static Future<WsOutboxItem> recordVendorPayment({
    required String clientUuid,
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
      },
      label: 'Paid $amount — $vendorName',
    );

    unawaited(box.drain());
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
      },
      label: '${lines.length} line${lines.length == 1 ? '' : 's'} — $vendorName',
    );

    unawaited(box.drain());
    return item;
  }

  static String _d(DateTime v) => v.toIso8601String().split('T').first;

  // ── Posting one item ─────────────────────────────────────────────────────

  static Future<WsPostResult> _post(WsOutboxItem item) async {
    if (!supabaseClientInitialized) {
      return const WsPostResult.retryable('Supabase is not configured');
    }
    try {
      final result = await supabase
          .rpc(item.rpc, params: item.args)
          .timeout(const Duration(seconds: 25));
      final id = result is num ? result.toInt() : null;
      return WsPostResult.success(documentId: id);
    } on PostgrestException catch (e) {
      return _classifyPostgrest(e);
    } on AuthException catch (e) {
      // The session expired while the item sat in the queue. Retryable: the
      // SDK refreshes tokens, and the next drain after a sign-in succeeds.
      return WsPostResult.retryable('Sign-in expired: ${e.message}');
    } on TimeoutException catch (e) {
      // THE DANGEROUS ONE. The request may well have been applied. Retry is
      // correct and safe — migration 010 makes the second attempt a read.
      return WsPostResult.retryable('Timed out: $e');
    } catch (e) {
      final s = '$e';
      if (s.contains('SocketException') ||
          s.contains('Failed host lookup') ||
          s.contains('ClientException') ||
          s.contains('Connection closed') ||
          s.contains('Connection reset') ||
          s.contains('NetworkException')) {
        return WsPostResult.retryable('Network: $s');
      }
      // Unrecognised. Retryable rather than permanent: an unknown error that
      // is actually transient costs one more attempt, while an unknown error
      // wrongly marked permanent strands a real document.
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

  /// The document type ws_lookup_clientuuid reports for each RPC.
  ///
  /// Needed because ONE KEY CAN RETURN TWO ROWS. ws_record_delivery stamps its
  /// clientuuid on both the delivery and — when p_amountpaid > 0 — the payment
  /// it creates in the same transaction, so looking up a delivery key returns
  /// a 'delivery' row AND a 'payment' row. Taking found.first would rely on
  /// the order of a UNION ALL, which SQL does not guarantee, and could stamp a
  /// delivery item with a payment's id.
  static const _doctypeForRpc = {
    'ws_record_delivery': 'delivery',
    'ws_record_payment': 'payment',
    'ws_record_purchase': 'purchase',
    'ws_record_vendor_payment': 'vendorpayment',
  };

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
    final want = _doctypeForRpc[item.rpc];
    final row = want == null
        ? found.first
        : found.cast<Map<String, dynamic>?>().firstWhere(
              (r) => r?['doctype'] == want,
              orElse: () => null,
            );
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
}
