// =============================================================================
// lib/services/lookup_service.dart
// Searching for a customer, vendor or product from inside a form.
//
// ─── THE SEARCH HAPPENS IN THE DATABASE ──────────────────────────────────────
//
// Not this:
//
//     final all = await fetchAllCustomers();      // 4,000 rows over the wire
//     final hits = all.where((c) => ...);          // filtered on a phone
//
// but a bounded query: the filter and the LIMIT both go to the server, and at
// most [wsLookupLimit] rows ever come back. That distinction is invisible with
// the twelve customers a new account has and decisive with the thousands a CSV
// import produces — which is exactly why it is being built now rather than
// after someone complains.
//
// ─── SCOPE IS NOT THIS FILE'S DECISION ───────────────────────────────────────
//
// Every query below is an ordinary authenticated request, so RLS applies:
// migration 015 already decides which branches a user can see. The store filter
// added to the CUSTOMER search is a convenience — it narrows results to the
// branch you are working in — and not a security boundary. A user who tampered
// with it would still see only what RLS allows.
//
// VENDORS AND PRODUCTS ARE ORGANIZATION-WIDE and must stay that way. Migration
// 015 deliberately left them unscoped: a business with two depots buys from one
// set of suppliers and sells one catalogue. Adding a store filter here would
// quietly reintroduce a distinction the schema does not have.
// =============================================================================

import 'dart:async';

import '../main.dart' show supabase, supabaseClientInitialized;
import 'store_service.dart';
import 'tenant_service.dart';

/// How many rows a lookup will ever return. Small on purpose: a picker showing
/// forty results is a picker nobody reads, and the answer to "too many matches"
/// is a better search term, not a longer list.
const int wsLookupLimit = 20;

/// Below this, searching is not worth a round trip — one letter matches most of
/// the table and the user is still typing.
const int wsLookupMinChars = 2;

/// Makes a user's typing safe to put inside a PostgREST `or=(...)` filter.
///
/// PostgREST parses that filter as a comma-separated list wrapped in
/// parentheses, so a customer called "Smith, J. (Ltd)" would otherwise be read
/// as extra conditions and either error or — worse — change what the filter
/// means. `%` and `_` are stripped for the same reason: they are ilike
/// wildcards, and a search for "50%" should look for a percent sign, not match
/// everything.
String wsSanitiseSearch(String raw) => raw
    .trim()
    .replaceAll(RegExp(r'[,()%_*\\]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// True when a query is worth sending.
bool wsSearchable(String raw) =>
    wsSanitiseSearch(raw).length >= wsLookupMinChars;

// ─── Debounce ─────────────────────────────────────────────────────────────────

/// Collapses a burst of keystrokes into one query.
///
/// Without this, typing "Hotel ABC" fires nine requests, eight of whose answers
/// are already stale by the time they arrive — and on a phone connection they
/// can arrive OUT OF ORDER, so the list ends up showing the results for "Hot".
/// [run] therefore also drops any result that is no longer the latest request.
class WsSearchDebouncer {
  final Duration delay;
  Timer? _timer;
  int _generation = 0;

  WsSearchDebouncer({this.delay = const Duration(milliseconds: 300)});

  /// Runs [action] after [delay], cancelling any pending call. [onResult] is
  /// invoked only if no newer request has started in the meantime.
  void run<T>(Future<T> Function() action, void Function(T) onResult,
      {void Function(Object)? onError}) {
    _timer?.cancel();
    final generation = ++_generation;

    _timer = Timer(delay, () async {
      try {
        final result = await action();
        if (generation != _generation) return; // superseded
        onResult(result);
      } catch (e) {
        if (generation != _generation) return;
        if (onError != null) onError(e);
      }
    });
  }

  /// Abandons anything pending — including results already in flight.
  void cancel() {
    _timer?.cancel();
    _generation++;
  }

  void dispose() => cancel();
}

// ─── Results ──────────────────────────────────────────────────────────────────

class WsLookupResult {
  final int id;
  final String label;

  /// The second line in the picker: the phone, the code, the product type.
  /// Also what makes two customers with the same name distinguishable.
  final String subtitle;

  const WsLookupResult({
    required this.id,
    required this.label,
    this.subtitle = '',
  });

  @override
  bool operator ==(Object other) => other is WsLookupResult && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

// ─── Queries ──────────────────────────────────────────────────────────────────

class WsLookupService {
  WsLookupService._();

  static String _or(String q, List<String> columns) =>
      columns.map((c) => '$c.ilike.%$q%').join(',');

  /// Customers, narrowed to the branch in use when the organization has more
  /// than one.
  ///
  /// [includeAllStores] exists for screens that legitimately span branches —
  /// reports, for instance. Transaction forms leave it false so a driver in one
  /// depot is offered that depot's customers.
  static Future<List<WsLookupResult>> customers(
    String query, {
    int limit = wsLookupLimit,
    bool includeAllStores = false,
  }) async {
    if (!supabaseClientInitialized || !wsSearchable(query)) return const [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return const [];

    final q = wsSanitiseSearch(query);
    var request = supabase
        .from('ws_tblcustomers')
        .select('customerid, customername, phone, customercode, storeid')
        .eq('orgid', orgId)
        .eq('isactive', true)
        .or(_or(q, ['customername', 'phone', 'customercode']));

    final storeId = WsStoreService.currentStoreId;
    if (!includeAllStores && storeId != null && WsStoreService.isMultiStore) {
      request = request.eq('storeid', storeId);
    }

    final rows = await request.order('customername').limit(limit);

    return (rows as List).map((r) {
      final phone = '${r['phone'] ?? ''}';
      final code = '${r['customercode'] ?? ''}';
      return WsLookupResult(
        id: (r['customerid'] as num).toInt(),
        label: '${r['customername'] ?? ''}',
        subtitle: [code, phone].where((s) => s.isNotEmpty).join(' · '),
      );
    }).toList();
  }

  /// Vendors. ORGANIZATION-WIDE — no store filter, deliberately. See the file
  /// header.
  static Future<List<WsLookupResult>> vendors(
    String query, {
    int limit = wsLookupLimit,
  }) async {
    if (!supabaseClientInitialized || !wsSearchable(query)) return const [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return const [];

    final q = wsSanitiseSearch(query);
    final rows = await supabase
        .from('ws_tblvendors')
        .select('vendorid, vendorname, phone, vendorcode')
        .eq('orgid', orgId)
        .eq('isactive', true)
        .or(_or(q, ['vendorname', 'phone', 'vendorcode']))
        .order('vendorname')
        .limit(limit);

    return (rows as List).map((r) {
      final phone = '${r['phone'] ?? ''}';
      final code = '${r['vendorcode'] ?? ''}';
      return WsLookupResult(
        id: (r['vendorid'] as num).toInt(),
        label: '${r['vendorname'] ?? ''}',
        subtitle: [code, phone].where((s) => s.isNotEmpty).join(' · '),
      );
    }).toList();
  }

  /// Products, also organization-wide, with the bottle type as the subtitle
  /// since "19 Litre" and "20 Litre" are otherwise easy to confuse.
  static Future<List<WsLookupResult>> products(
    String query, {
    int limit = wsLookupLimit,
  }) async {
    if (!supabaseClientInitialized || !wsSearchable(query)) return const [];
    final orgId = await WsTenantService.currentOrgId;
    if (orgId == null) return const [];

    final q = wsSanitiseSearch(query);
    final rows = await supabase
        .from('ws_tblproducts')
        .select('productid, productname, productcode, '
            'ws_tblbottletypes(bottlename)')
        .eq('orgid', orgId)
        .eq('isactive', true)
        .or(_or(q, ['productname', 'productcode']))
        .order('productname')
        .limit(limit);

    return (rows as List).map((r) {
      final type = r['ws_tblbottletypes'];
      final typeName = type is Map ? '${type['bottlename'] ?? ''}' : '';
      final code = '${r['productcode'] ?? ''}';
      return WsLookupResult(
        id: (r['productid'] as num).toInt(),
        label: '${r['productname'] ?? ''}',
        subtitle: [code, typeName].where((s) => s.isNotEmpty).join(' · '),
      );
    }).toList();
  }

  /// Re-read one vendor by id. See [customerById].
  static Future<WsLookupResult?> vendorById(int id) async {
    if (!supabaseClientInitialized) return null;
    final row = await supabase
        .from('ws_tblvendors')
        .select('vendorid, vendorname, phone, vendorcode')
        .eq('vendorid', id)
        .maybeSingle();
    if (row == null) return null;
    final phone = '${row['phone'] ?? ''}';
    final code = '${row['vendorcode'] ?? ''}';
    return WsLookupResult(
      id: (row['vendorid'] as num).toInt(),
      label: '${row['vendorname'] ?? ''}',
      subtitle: [code, phone].where((s) => s.isNotEmpty).join(' · '),
    );
  }

  /// Re-read one product by id. See [customerById].
  static Future<WsLookupResult?> productById(int id) async {
    if (!supabaseClientInitialized) return null;
    final row = await supabase
        .from('ws_tblproducts')
        .select('productid, productname, productcode')
        .eq('productid', id)
        .maybeSingle();
    if (row == null) return null;
    final code = '${row['productcode'] ?? ''}';
    return WsLookupResult(
      id: (row['productid'] as num).toInt(),
      label: '${row['productname'] ?? ''}',
      subtitle: code,
    );
  }

  /// Re-read one row by id, so a form opened on an existing record can show its
  /// current selection without searching for it.
  ///
  /// WITHOUT THIS, editing a record whose customer no longer matches the search
  /// term would display an empty picker and silently invite the user to pick
  /// somebody else.
  static Future<WsLookupResult?> customerById(int id) async {
    if (!supabaseClientInitialized) return null;
    final row = await supabase
        .from('ws_tblcustomers')
        .select('customerid, customername, phone, customercode')
        .eq('customerid', id)
        .maybeSingle();
    if (row == null) return null;
    final phone = '${row['phone'] ?? ''}';
    final code = '${row['customercode'] ?? ''}';
    return WsLookupResult(
      id: (row['customerid'] as num).toInt(),
      label: '${row['customername'] ?? ''}',
      subtitle: [code, phone].where((s) => s.isNotEmpty).join(' · '),
    );
  }
}
