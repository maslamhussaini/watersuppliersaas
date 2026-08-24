// =============================================================================
// lib/services/import/ws_csv_import_ops.dart
// The three writes the CSV applier performs, behind an interface.
//
// ─── WHY THIS EXISTS ─────────────────────────────────────────────────────────
//
// WsCsvImportService.apply() reached straight for the Supabase client, so it
// could not be run in a plain Dart test process. The harness worked around that
// by REIMPLEMENTING the apply loop (test_harness/bin/csv_import_write.dart) —
// which means the production applier has never been executed by any test. Every
// interesting property of it is currently unverified: what happens when the
// customer write succeeds and the opening write fails, what a lost response
// does, whether a partially applied import can be resumed, what the counters
// report.
//
// This is the same seam the project already uses for WsAuthClient: a pure
// interface with no vendor import, one adapter that is the only file allowed to
// know about Supabase, and a deps bundle resolved the way WsAuthGateDeps is —
// `deps ?? production()` at the point of use, so call sites need no change.
//
// ─── WHAT THIS IS NOT ────────────────────────────────────────────────────────
//
// Not a Supabase abstraction. Three operations, because apply() performs
// exactly three writes. loadContext()'s three READS are deliberately NOT here:
// the planner takes `existing` and `areas` as constructor arguments, so a test
// builds them directly and never needs the reads.
//
// Nothing here changes behaviour. Ordering, counters, the untyped per-row catch
// and the partial-apply outcome are all unchanged — see the notes on each
// method. In particular a successful customer write followed by a throwing
// opening write must still leave the customer committed. That is the behaviour
// under test; it is not a bug being fixed here.
// =============================================================================

/// The writes. One implementation talks to Supabase; tests supply their own.
///
/// Every value crossing this boundary is a plain Dart type. No PostgREST
/// builder, no exception class, no response envelope. The applier already named
/// no Supabase type — its per-row handler is an untyped `catch (e)` that
/// stringifies with `'$e'` — so an implementation may throw anything, and the
/// error text reaching WsImportOutcome.failures is produced exactly as before.
abstract class WsCsvImportOps {
  /// ws_record_customer. Returns the customer id.
  ///
  /// Idempotent on [clientUuid] in production: a replay after a lost response
  /// returns the customer already created rather than a second one, and returns
  /// BEFORE the insert — so the plan-limit trigger from migration 019 is not
  /// consulted on a replay. A fake that models this must therefore keep a
  /// customer table keyed by clientUuid, not merely a log of calls.
  ///
  /// [values] is the planner's own row map, passed through untouched so the
  /// adapter can build the RPC payload exactly as it always did.
  Future<int> recordCustomer({
    required int orgId,
    required String name,
    required String clientUuid,
    required int? storeId,
    required Map<String, dynamic> values,
  });

  /// The plain table update on ws_tblcustomers.
  ///
  /// Called only when the patch is non-empty — that guard stays in the applier,
  /// because `updated++` currently fires whether or not the patch had anything
  /// in it, and moving the guard would change what the counter reports.
  ///
  /// storeid is deliberately absent from [patch]: an existing customer keeps
  /// the branch it already belongs to.
  Future<void> updateCustomer({
    required int orgId,
    required int customerId,
    required Map<String, dynamic> patch,
  });

  /// ws_set_customer_opening — money and bottles in one call.
  ///
  /// Convergent rather than incremental: it states an absolute target, so
  /// repeating it with the same input is safe. The authoritative proof of that
  /// is at SQL level (test_harness/bin/customer_opening.dart); what the applier
  /// tests add is that the applier can now be driven down the lost-response
  /// path at all.
  Future<void> setCustomerOpening({
    required int customerId,
    required Object? openingDue,
    required Object? openingQty,
  });
}

/// What apply() needs from the outside world.
///
/// The three scalars are functions rather than values because apply() captures
/// them itself, once, before the first row is written — the discipline the
/// delivery screen uses, so a branch switch mid-import cannot split a file
/// across two branches. Keeping them callable preserves the capture point.
class WsCsvImportDeps {
  final WsCsvImportOps ops;

  /// Mirrors `supabaseClientInitialized`.
  final bool Function() isConnected;

  /// Mirrors `WsTenantService.currentOrgId`.
  final Future<int?> Function() currentOrgId;

  /// Mirrors `WsStoreService.currentStoreId`.
  final int? Function() currentStoreId;

  const WsCsvImportDeps({
    required this.ops,
    required this.isConnected,
    required this.currentOrgId,
    required this.currentStoreId,
  });
}
