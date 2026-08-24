// =============================================================================
// lib/services/import/ws_csv_import_apply.dart
// Executing an import plan.
//
// ─── NO NEW WRITE PATH ───────────────────────────────────────────────────────
//
// Every write here goes through machinery that already exists and is already
// tested:
//
//   new customer    → ws_record_customer   (014: clientuuid, 015: storeid)
//   changed fields  → the ordinary customer UPDATE
//   opening money   → ws_set_customer_opening  (017: journal-backed, delta)
//   opening bottles → ws_set_customer_opening  (009: bottle-ledger delta)
//
// A bulk importer is exactly the wrong place to invent a faster way to write a
// customer. Five hundred rows through an untested path is five hundred chances
// to produce the class of damage migrations 014 to 017 exist to prevent.
//
// ─── ORDER, AND WHY ──────────────────────────────────────────────────────────
//
// Fields first, opening balances second. ws_set_customer_opening writes the
// opening column itself and fires the 017 trigger; doing it before the general
// field update would mean the update wrote a stale opening value straight back
// over it.
//
// ─── WHAT THIS DOES NOT DO ───────────────────────────────────────────────────
//
// It does not bypass RLS — every call is a normal authenticated RPC, so a user
// restricted to one branch imports into that branch and nowhere else. It does
// not touch the outbox: an import is a deliberate foreground action against a
// file the user is looking at, not a delivery recorded in a basement, and
// queueing five hundred rows for later would make the preview a lie.
// =============================================================================

import '../../main.dart' show supabase, supabaseClientInitialized;
// store_service is no longer imported here: the branch is captured through
// WsCsvImportDeps.currentStoreId, and the adapter is what reads it now.
// tenant_service remains, because loadContext() still resolves the org itself.
import '../tenant_service.dart';
import 'ws_csv_import.dart';
import 'ws_csv_import_ops.dart';
import 'ws_csv_import_ops_supabase.dart';

class WsImportOutcome {
  final int created;
  final int updated;
  final int unchanged;

  /// Rows that failed DURING the write, after passing validation — a customer
  /// deleted by someone else mid-import, a permission revoked, a dropped
  /// connection. Reported per row rather than swallowed.
  final List<String> failures;

  const WsImportOutcome({
    this.created = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.failures = const [],
  });

  bool get clean => failures.isEmpty;

  // ── PRESENTATION ──────────────────────────────────────────────────────────
  //
  // Everything below is DERIVED from the counters above. None of it changes
  // what they mean or how they are computed — see the notes on created/updated
  // in apply(). The problem being solved is that the old summary read
  // "3 created, 0 updated, 0 unchanged, 37 failed", which tells a user that
  // something went wrong but not the two things they actually need to know:
  // that three rows are now saved, and that re-uploading the file is safe.

  /// Rows this import wrote something for.
  int get saved => created + updated;

  int get failed => failures.length;

  String get summary {
    final parts = <String>[
      '${saved == 1 ? '1 row' : '$saved rows'} saved '
          '($created new, $updated updated)',
    ];
    if (unchanged > 0) parts.add('$unchanged already up to date');
    if (failed > 0) {
      parts.add('${failed == 1 ? '1 row' : '$failed rows'} not saved');
    }
    return parts.join(' · ');
  }

  /// Shown when something did not save. Deliberately does NOT say the import
  /// was rolled back or that nothing was written — neither is true. What is
  /// true, and proven by test and harness, is that a second attempt converges:
  /// ws_record_customer resolves the clientuuid to the row already created,
  /// ws_set_customer_opening states an absolute figure rather than an
  /// increment, and the planner re-reads live state so an already-saved row
  /// comes back as "already up to date".
  String? get retryAdvice => failures.isEmpty
      ? null
      : 'The rows that saved are already stored. You can upload the same file '
          'again to finish the rest — it will not duplicate anyone.';

  /// The plan-limit refusal raised by migration 019, if one is among the
  /// failures.
  ///
  /// Recognised from the failure text rather than from a typed exception,
  /// because [failures] holds strings and this is a presentation concern. No
  /// error-classification framework is introduced here, and no limit is
  /// hard-coded: the number comes from the message the database raised.
  static final _planLimit = RegExp(r'plan limit reached: [^,)]*\)');

  bool get hitPlanLimit =>
      failures.any((f) => f.contains('P0001') && f.contains('plan limit'));

  /// A sentence to show instead of the raw PostgrestException. Null when no
  /// plan-limit failure occurred. The technical text stays in [failures].
  String? get planLimitMessage {
    if (!hitPlanLimit) return null;
    for (final f in failures) {
      final m = _planLimit.firstMatch(f);
      if (m != null) {
        // 'plan limit reached: the free plan allows 50 active customers
        //  (currently 50)' -> 'Your free plan allows 50 active customers.'
        final raw = m.group(0)!.replaceFirst('plan limit reached: ', '');
        final upTo = raw.indexOf(' (currently');
        final headline = upTo == -1 ? raw : raw.substring(0, upTo);
        return 'Your ${headline.replaceFirst('the ', '')}. '
            'Remove a customer you no longer serve, or upgrade the plan, '
            'then upload the file again.';
      }
    }
    return null;
  }
}

class WsCsvImportService {
  WsCsvImportService._();

  /// Everything the planner needs about current state, read through the normal
  /// views so RLS and the store dimension apply.
  static Future<({List<WsImportCustomer> customers, List<WsImportArea> areas})>
      loadContext() async {
    if (!supabaseClientInitialized) {
      return (customers: <WsImportCustomer>[], areas: <WsImportArea>[]);
    }
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) {
      return (customers: <WsImportCustomer>[], areas: <WsImportArea>[]);
    }

    final areaRows = await supabase
        .from('ws_tblareas')
        .select('areaid, areaname')
        .eq('orgid', orgId)
        .eq('isactive', true);

    final custRows = await supabase
        .from('ws_tblcustomers')
        .select('customerid, customername, phone, areaid, address, '
            'contactperson, email, customercode, rateoverride, '
            'depositamount, openingbalance')
        .eq('orgid', orgId)
        .eq('isactive', true);

    // Opening BOTTLE quantities live in the bottle ledger, not on the customer
    // row, so the preview would show a wrong "from" value without this.
    final openingQty = <int, int>{};
    final bottleRows = await supabase
        .from('ws_tblbottletransactions')
        .select('customerid, qty')
        .eq('orgid', orgId)
        .eq('txntype', 'opening');
    for (final r in (bottleRows as List)) {
      final cid = (r['customerid'] as num?)?.toInt();
      if (cid == null) continue;
      openingQty[cid] = (openingQty[cid] ?? 0) + ((r['qty'] as num?)?.toInt() ?? 0);
    }

    return (
      customers: (custRows as List).map((r) {
        final id = (r['customerid'] as num).toInt();
        return WsImportCustomer(
          customerId: id,
          customerName: '${r['customername'] ?? ''}',
          phone: r['phone'] as String?,
          areaId: (r['areaid'] as num?)?.toInt(),
          address: r['address'] as String?,
          contactPerson: r['contactperson'] as String?,
          email: r['email'] as String?,
          customerCode: r['customercode'] as String?,
          rateOverride: (r['rateoverride'] as num?)?.toDouble(),
          depositAmount: (r['depositamount'] as num?)?.toDouble() ?? 0,
          openingBalance: (r['openingbalance'] as num?)?.toDouble() ?? 0,
          openingQty: openingQty[id] ?? 0,
        );
      }).toList(),
      areas: (areaRows as List)
          .map((r) => WsImportArea(
              (r['areaid'] as num).toInt(), '${r['areaname'] ?? ''}'))
          .toList(),
    );
  }

  /// Execute a plan.
  ///
  /// The guard below is about VALIDATION errors only: a plan the planner marked
  /// as faulty is refused outright, so a file with a bad area name or a
  /// duplicate row writes nothing at all. That is the whole of the "a batch
  /// with any error writes nothing" rule in ws_csv_import.dart's header, and it
  /// is enforced here and nowhere else.
  ///
  /// RUNTIME write failures are a different thing entirely and are NOT covered
  /// by that rule. Each row is applied through its own requests, so a row can
  /// fail after earlier rows have committed. Those are caught per row, recorded
  /// in [WsImportOutcome.failures], and the loop continues — recovery is by
  /// re-uploading the file, not by rollback. There is no transaction spanning
  /// the import and none can be added from a REST client.
  /// [deps] exists so this method can be executed by a test. Production passes
  /// nothing and gets the Supabase adapter, the same way WsAuthGate resolves
  /// WsAuthGateDeps. No call site changes.
  static Future<WsImportOutcome> apply(
    WsImportPlan plan, {
    WsCsvImportDeps? deps,
  }) async {
    final d = deps ?? wsProductionCsvImportDeps();

    if (plan.hasErrors) {
      throw StateError(
          'This file has errors. Nothing was imported. Fix the rows listed in '
          'the preview and try again.');
    }
    if (!d.isConnected()) {
      throw StateError('Not connected.');
    }

    final orgId = await d.currentOrgId();
    if (orgId == null) throw StateError('No active organization.');

    // Captured ONCE, before any row is written — the same discipline the
    // delivery screen uses. A branch switch mid-import cannot split a file
    // across two branches.
    final storeId = d.currentStoreId();

    var created = 0, updated = 0;
    final failures = <String>[];

    for (final row in plan.rows) {
      if (row.action == WsImportAction.unchanged ||
          row.action == WsImportAction.error) {
        continue;
      }

      try {
        var customerId = row.customerId;

        if (row.action == WsImportAction.create) {
          // ws_record_customer is idempotent on clientuuid, so re-confirming
          // the same plan returns the customer already created instead of a
          // second one. The RPC payload — including the opening balances that
          // are deliberately NOT sent here — now lives in the adapter.
          customerId = await d.ops.recordCustomer(
            orgId: orgId,
            name: row.name,
            clientUuid: row.clientUuid,
            storeId: storeId,
            values: row.values,
          );
          created++;
        } else {
          // ── UPDATE: only the fields the file actually supplied ────────
          final patch = <String, dynamic>{};
          if (row.values.containsKey('phone')) {
            patch['phone'] = row.values['phone'];
          }
          if (row.values.containsKey('areaid')) {
            patch['areaid'] = row.values['areaid'];
          }
          if (row.values.containsKey('address')) {
            patch['address'] = row.values['address'];
          }
          if (row.values.containsKey('contact')) {
            patch['contactperson'] = row.values['contact'];
          }
          if (row.values.containsKey('email')) {
            patch['email'] = row.values['email'];
          }
          if (row.values.containsKey('code')) {
            patch['customercode'] = row.values['code'];
          }
          if (row.values.containsKey('rate')) {
            patch['rateoverride'] = row.values['rate'];
          }
          if (row.values.containsKey('deposit')) {
            patch['depositamount'] = row.values['deposit'];
          }

          // storeid is deliberately absent: an existing customer keeps the
          // branch it already belongs to. Importing while standing in another
          // depot must not silently move people between branches.
          if (patch.isNotEmpty) {
            await d.ops.updateCustomer(
              orgId: orgId,
              customerId: customerId!,
              patch: patch,
            );
          }
          updated++;
        }

        // ── OPENING BALANCES, money and bottles together ────────────────
        //
        // One call, because ws_set_customer_opening owns both and calling it
        // twice with half the information each time would clear whichever half
        // was omitted.
        final hasMoney = row.values.containsKey('openingbalance');
        final hasQty = row.values.containsKey('openingqty');
        if (hasMoney || hasQty) {
          // A BLANK COLUMN MUST NOT RESET THE OTHER HALF. The row carries the
          // customer's current values, so whichever the file omitted is sent
          // back unchanged. For a newly created customer both are 0, which is
          // what they actually are.
          await d.ops.setCustomerOpening(
            customerId: customerId!,
            openingDue: hasMoney
                ? row.values['openingbalance']
                : row.currentOpeningBalance,
            openingQty:
                hasQty ? row.values['openingqty'] : row.currentOpeningQty,
          );
        }
      } catch (e) {
        failures.add('Line ${row.lineNumber} (${row.name}): $e');
      }
    }

    return WsImportOutcome(
      created: created,
      updated: updated,
      unchanged: plan.unchanged.length,
      failures: failures,
    );
  }

}
