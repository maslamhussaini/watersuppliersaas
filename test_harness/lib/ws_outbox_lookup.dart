// =============================================================================
// lib/services/outbox/ws_outbox_lookup.dart
// Choosing the right row out of a ws_lookup_clientuuid() result.
//
// ─── WHY THIS IS ITS OWN FILE ────────────────────────────────────────────────
//
// It is pure Dart with no Supabase and no Flutter, so it can be tested. The
// logic it holds is small but it is the difference between reconcile() marking
// the correct document synced and marking it synced with the WRONG id, and
// that is not something to leave untested inside a file that needs a live
// Supabase client to import.
//
// ─── THE PROBLEM IT SOLVES ───────────────────────────────────────────────────
//
// ONE KEY CAN RETURN TWO ROWS.
//
// ws_record_delivery stamps its clientuuid on the delivery AND — when the
// customer paid cash at the door — on the payment it creates in the same
// transaction. So looking up a delivery key returns:
//
//     doctype  | docid
//     ---------+------
//     delivery |   34
//     payment  |   17
//
// Taking the first row means trusting the order of a UNION ALL, which SQL does
// not guarantee and Postgres does not promise to keep stable across plans. On
// the day it comes back the other way round, a delivery in the queue gets
// stamped with a payment's id and every later trace of that document leads
// somewhere wrong.
// =============================================================================

/// What ws_lookup_clientuuid() reports for each posting RPC.
///
/// Must match the union branches in migration 013.
const Map<String, String> wsDoctypeForRpc = {
  'ws_record_delivery': 'delivery',
  'ws_record_payment': 'payment',
  'ws_record_purchase': 'purchase',
  'ws_record_vendor_payment': 'vendorpayment',
};

/// The row [rpc] actually produced, or null if it is not there.
///
/// Null means the operation did NOT land, whatever else shares the key — so
/// the caller must leave the item queued rather than mark it synced.
Map<String, dynamic>? wsPickLookupRow(
  List<Map<String, dynamic>> rows,
  String rpc,
) {
  final want = wsDoctypeForRpc[rpc];

  // An RPC this file has not been taught about. Refuse rather than guess:
  // a wrong id here is worse than an unreconciled item, which is merely
  // retried and resolved by the server's own idempotency.
  if (want == null) return null;

  for (final row in rows) {
    if (row['doctype'] == want) return row;
  }
  return null;
}

/// The server id for [rpc] within a lookup result, or null.
int? wsPickLookupDocId(List<Map<String, dynamic>> rows, String rpc) {
  final row = wsPickLookupRow(rows, rpc);
  return (row?['docid'] as num?)?.toInt();
}
