// =============================================================================
// lib/services/import/ws_csv_import_ops_supabase.dart
// The only file in the import path allowed to know about Supabase.
//
// Every call below is the one that used to sit inline in
// WsCsvImportService.apply(), moved without alteration: same RPC names, same
// parameter keys in the same order, same `.eq()` chain, same `?? 0` on the
// deposit. If a payload here differs from what apply() sent before this seam
// existed, that is a defect in this file — not a design choice.
//
// Deliberately absent: the three loadContext() reads, any transaction, any
// typed error wrapper. Exceptions propagate raw, exactly as they did, and are
// caught and stringified by apply()'s existing per-row handler.
// =============================================================================

import '../../main.dart' show supabase, supabaseClientInitialized;
import '../store_service.dart';
import '../tenant_service.dart';
import 'ws_csv_import_ops.dart';

class WsSupabaseCsvImportOps implements WsCsvImportOps {
  const WsSupabaseCsvImportOps();

  @override
  Future<int> recordCustomer({
    required int orgId,
    required String name,
    required String clientUuid,
    required int? storeId,
    required Map<String, dynamic> values,
  }) async {
    // ws_record_customer is idempotent on clientuuid, so re-confirming the same
    // plan returns the customer already created instead of a second one.
    final result = await supabase.rpc('ws_record_customer', params: {
      'p_orgid': orgId,
      'p_customername': name,
      'p_areaid': values['areaid'],
      'p_customercode': values['code'],
      'p_contactperson': values['contact'],
      'p_phone': values['phone'],
      'p_email': values['email'],
      'p_address': values['address'],
      'p_rateoverride': values['rate'],
      'p_depositamount': values['deposit'] ?? 0,
      // Opening balances are NOT passed here. They go through
      // ws_set_customer_opening so that money and bottles are posted by the one
      // mechanism that keeps the ledger in step.
      'p_clientuuid': clientUuid,
      'p_storeid': storeId,
    });
    return (result as num).toInt();
  }

  @override
  Future<void> updateCustomer({
    required int orgId,
    required int customerId,
    required Map<String, dynamic> patch,
  }) async {
    await supabase
        .from('ws_tblcustomers')
        .update(patch)
        .eq('customerid', customerId)
        .eq('orgid', orgId);
  }

  @override
  Future<void> setCustomerOpening({
    required int customerId,
    required Object? openingDue,
    required Object? openingQty,
  }) async {
    await supabase.rpc('ws_set_customer_opening', params: {
      'p_customerid': customerId,
      'p_openingdue': openingDue,
      'p_openingqty': openingQty,
    });
  }
}

/// The bundle apply() falls back to when no deps are supplied.
///
/// Same three sources apply() read directly before the seam: the initialised
/// flag, the tenant service and the store service.
WsCsvImportDeps wsProductionCsvImportDeps() => WsCsvImportDeps(
      ops: const WsSupabaseCsvImportOps(),
      isConnected: () => supabaseClientInitialized,
      currentOrgId: () => WsTenantService.currentOrgId,
      currentStoreId: () => WsStoreService.currentStoreId,
    );
