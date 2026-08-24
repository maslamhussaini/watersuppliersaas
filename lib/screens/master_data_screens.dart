// =============================================================================
// lib/screens/master_data_screens.dart
// The nine entities that had no forms, declared against the WsCrudScreen engine.
//
//   Set 1  Products · Bottle types · Product prices
//   Set 2  Vendors · Purchases · Vendor payments
//   Set 3  Staff (role assignment)
//   Set 4  Routes · Customer groups
//
// Each screen is a description, not an implementation. The list, the form, the
// validation, the save path and the responsive behaviour all live in
// ws_crud.dart. Adding a tenth entity is another twenty lines here.
//
// WRITES ARE PERMISSION-GATED, and the codes match the RLS policies in
// migration 008 exactly. If they ever disagree the UI is the one that is wrong:
// the database refuses regardless, so a mismatch shows the user a button that
// always errors.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/lookup_service.dart';
import '../services/store_service.dart';
import '../services/supabase_service.dart';
import '../theme/ws_theme.dart';
import '../services/outbox/ws_outbox.dart';
import '../services/outbox/ws_outbox_supabase.dart';
import 'opening_balances_screen.dart';
import 'organization_screen.dart';
import 'ws_crud.dart';

final _money = NumberFormat('#,##0.##');
final _date = DateFormat('dd MMM yyyy');

String _s(Object? v) => v == null ? '' : '$v';

/// Postgres hands back dates as 'YYYY-MM-DD' strings. Printing those raw is why
/// the lists read "2026-08-01" instead of "01 Aug 2026" — this was the unused
/// _date formatter the analyzer flagged, which was a real display bug wearing a
/// lint's clothing.
String _fmtDate(Object? v) {
  if (v == null) return '';
  final parsed = DateTime.tryParse('$v');
  return parsed == null ? '$v' : _date.format(parsed);
}
double _n(Object? v) =>
    v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);


/// Reports the QUEUE STATE of a document saved through WsCrudScreen.
///
/// The form pops as soon as onSave returns, so the only place to tell the user
/// "this is saved on the device but not on the server yet" is a snackbar from
/// the screen underneath. Silence here would make a queued document look
/// exactly like a posted one — the failure that matters most in a delivery and
/// accounting app.
///
/// Mirrors the wording used by the delivery screen so the three paths cannot
/// drift apart:
///   synced  → "<thing> saved"            (green)
///   pending → "Saved on this device — waiting to sync"   (amber)
///   failed  → "<thing> failed — <error>" (red)
void _reportQueueState(
  BuildContext context,
  WsOutboxItem item,
  String noun,
) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;

  switch (item.status) {
    case WsOutboxStatus.synced:
      messenger.showSnackBar(SnackBar(
        content: Text('$noun saved'),
        backgroundColor: WsColors.green,
      ));
    case WsOutboxStatus.failed:
      messenger.showSnackBar(SnackBar(
        content: Text('$noun failed — ${item.lastError ?? 'unknown error'}'),
        backgroundColor: WsColors.red,
        duration: const Duration(seconds: 6),
      ));
    case WsOutboxStatus.pending:
    case WsOutboxStatus.syncing:
      messenger.showSnackBar(const SnackBar(
        content: Text('Saved on this device — waiting to sync'),
        backgroundColor: WsColors.amber,
      ));
  }
}

// ═══ SET 1 ═══ Products, bottle types, pricing ════════════════════════════════

/// Returnable assets. A bottle type is the physical thing that comes back; a
/// product is what you invoice. They are separate because two products can
/// circulate on one bottle, and a case of 500ml has no returnable at all.
class WsBottleTypesScreen extends StatelessWidget {
  const WsBottleTypesScreen({super.key});

  @override
  Widget build(BuildContext context) => WsCrudScreen(
    title: 'Product Type',
    icon: Icons.water_drop_outlined,
    writePermission: 'products.manage',
    emptyHint: 'Add the returnable containers you circulate, e.g. 19 Litre bottle.',
    load: () => WsDataService.fetchRows('ws_tblbottletypes', orderBy: 'bottlename'),
    pkColumn: 'bottletypeid',
    rowBuilder: (r) => WsRowView(
      title: _s(r['bottlename']),
      subtitle:
          '${_s(r['bottlecode'])}'
          '${r['capacitylitres'] != null ? ' · ${_n(r['capacitylitres'])} L' : ''}'
          '${r['isdefault'] == true ? ' · default' : ''}',
      trailing: 'Rs ${_money.format(_n(r['depositamount']))}',
    ),
    fields: const [
      WsField('bottlecode', 'Code', required: true, hint: 'BT19'),
      WsField('bottlename', 'Name', required: true, hint: '19 Litre Returnable'),
      WsField('capacitylitres', 'Capacity (litres)', type: WsFieldType.number),
      WsField(
        'depositamount',
        'Deposit',
        type: WsFieldType.money,
        helper: 'Refundable amount held per bottle',
      ),
      WsField(
        'isdefault',
        'Default product type',
        type: WsFieldType.toggle,
        helper: 'The delivery card shows this type in its Bottle Balance column',
      ),
    ],
    onSave: (pk, v) =>
        WsDataService.saveRow('ws_tblbottletypes', 'bottletypeid', pk, v),
    onDeactivate: (pk) =>
        WsDataService.deactivateRow('ws_tblbottletypes', 'bottletypeid', pk),
  );
}

class WsProductsScreen extends StatelessWidget {
  const WsProductsScreen({super.key});

  @override
  Widget build(BuildContext context) => WsCrudScreen(
    title: 'Product',
    icon: Icons.inventory_2_outlined,
    writePermission: 'products.manage',
    emptyHint: 'Add what you sell. A returnable product must name a product type.',
    load: () => WsDataService.fetchRows('ws_tblproducts', orderBy: 'productname'),
    pkColumn: 'productid',
    rowBuilder: (r) => WsRowView(
      title: _s(r['productname']),
      subtitle:
          '${_s(r['productcode'])} · ${_s(r['unitlabel'])}'
          '${r['bottletypeid'] == null ? ' · non-returnable' : ' · returnable'}',
      trailing: 'Rs ${_money.format(_n(r['saleprice']))}',
    ),
    fields: [
      const WsField('productcode', 'Code', required: true, hint: 'W19'),
      const WsField('productname', 'Name', required: true),
      const WsField('unitlabel', 'Unit', hint: 'Bottle', initial: 'Bottle'),
      const WsField('sizelabel', 'Size label', hint: '19L'),
      const WsField('capacitylitres', 'Capacity (litres)', type: WsFieldType.number),
      WsField(
        'bottletypeid',
        'Product type',
        type: WsFieldType.dropdown,
        helper: 'Leave empty for something that is not returned, e.g. a case',
        options: () => WsDataService.fetchOptions(
          'ws_tblbottletypes',
          'bottletypeid',
          'bottlename',
        ),
      ),
      const WsField(
        'bottlesperunit',
        'Bottles per unit',
        type: WsFieldType.integer,
        initial: 1,
        // The schema enforces this pairing: a product either names a bottle
        // type and moves at least one, or names neither. Saving a mismatch
        // returns ck_product_bottle_consistency rather than corrupting stock.
        helper: 'Set 0 when there is no product type',
      ),
      const WsField('saleprice', 'Default sale price', type: WsFieldType.money),
      const WsField('purchaseprice', 'Purchase cost', type: WsFieldType.money),
    ],
    onSave: (pk, v) => WsDataService.saveRow('ws_tblproducts', 'productid', pk, v),
    onDeactivate: (pk) =>
        WsDataService.deactivateRow('ws_tblproducts', 'productid', pk),
  );
}

/// Customer / group / area pricing with effective dates.
///
/// Until now this table could only be edited in SQL, which meant the whole
/// dynamic-pricing feature was unreachable from the app.
class WsProductPricesScreen extends StatelessWidget {
  const WsProductPricesScreen({super.key});

  @override
  Widget build(BuildContext context) => WsCrudScreen(
    title: 'Price',
    icon: Icons.sell_outlined,
    writePermission: 'products.manage',
    emptyHint:
        'Set prices per customer, per group or per area. Leave all three empty '
        'for the organization default.',
    load: () => WsDataService.fetchRows(
      'ws_tblproductprices',
      orderBy: 'effectivefrom',
      ascending: false,
      activeOnly: false,
    ),
    pkColumn: 'priceid',
    rowBuilder: (r) {
      final scope = r['customerid'] != null
          ? 'Customer #${r['customerid']}'
          : r['groupid'] != null
              ? 'Group #${r['groupid']}'
              : r['areaid'] != null
                  ? 'Area #${r['areaid']}'
                  : 'Organization default';
      return WsRowView(
        title: scope,
        subtitle:
            'Product #${r['productid']} · from ${_fmtDate(r['effectivefrom'])}'
            '${r['effectiveto'] != null ? ' to ${_fmtDate(r['effectiveto'])}' : ''}',
        trailing: 'Rs ${_money.format(_n(r['price']))}',
      );
    },
    fields: [
      WsField(
        'productid',
        'Product',
        type: WsFieldType.dropdown,
        required: true,
        options: () => WsDataService.fetchOptions(
          'ws_tblproducts',
          'productid',
          'productname',
        ),
      ),
      const WsField('price', 'Price', type: WsFieldType.money, required: true),
      // ── Scope: at most one of the three ───────────────────────────────────
      // ck_price_single_scope allows exactly zero or one of these per row, and
      // resolve_price() reads them customer > group > area > organization
      // default. They share an exclusiveGroup, so picking one clears the other
      // two and the form can no longer build a row the database will reject.
      // Leave all three on "— none —" for the organization-wide price.
      WsField(
        'customerid',
        'For one customer',
        type: WsFieldType.dropdown,
        exclusiveGroup: 'scope',
        helper: 'Choosing a scope clears the other two. Leave all empty for '
            'the organization default price.',
        options: () => WsDataService.fetchOptions(
          'ws_tblcustomers',
          'customerid',
          'customername',
        ),
      ),
      WsField(
        'groupid',
        'For a customer group',
        type: WsFieldType.dropdown,
        exclusiveGroup: 'scope',
        options: () => WsDataService.fetchOptions(
          'ws_tblcustomergroups',
          'groupid',
          'groupname',
        ),
      ),
      WsField(
        'areaid',
        'For an area',
        type: WsFieldType.dropdown,
        exclusiveGroup: 'scope',
        options: () =>
            WsDataService.fetchOptions('ws_tblareas', 'areaid', 'areaname'),
      ),
      WsField(
        'effectivefrom',
        'Effective from',
        type: WsFieldType.date,
        initial: DateTime.now(),
      ),
    ],
    onSave: (pk, v) =>
        WsDataService.saveRow('ws_tblproductprices', 'priceid', pk, v),
  );
}

// ═══ SET 2 ═══ Vendors, purchases, vendor payments ════════════════════════════

/// Stateful for one reason only: ONE idempotency key per Save action.
///
/// A vendor created twice splits payables in half — purchases before the retry
/// sit against one row, payments after it against the other — and
/// vw_ws_reconciliation still reports 0, because both are summed into the same
/// AP total. Holding the key in state means a Save retried after a timeout is
/// recognised by the server as the same vendor.
class WsVendorsScreen extends StatefulWidget {
  const WsVendorsScreen({super.key});

  @override
  State<WsVendorsScreen> createState() => _WsVendorsScreenState();
}

class _WsVendorsScreenState extends State<WsVendorsScreen> {
  /// Regenerated only after a successful save, so the next vendor is a new
  /// record rather than resolving to the previous one.
  String _clientUuid = wsNewUuid();

  @override
  Widget build(BuildContext context) => WsCrudScreen(
    title: 'Vendor',
    icon: Icons.local_shipping_outlined,
    writePermission: 'vendors.manage',
    emptyHint: 'Who you buy bottles, caps and filters from.',
    load: () => WsDataService.fetchRows('ws_tblvendors', orderBy: 'vendorname'),
    pkColumn: 'vendorid',
    rowBuilder: (r) => WsRowView(
      title: _s(r['vendorname']),
      subtitle: [
        _s(r['vendorcode']),
        _s(r['contactperson']),
        _s(r['phone']),
      ].where((x) => x.isNotEmpty).join(' · '),
    ),
    fields: const [
      WsField('vendorcode', 'Code', hint: 'V-001'),
      WsField('vendorname', 'Vendor name', required: true),
      WsField('contactperson', 'Contact person'),
      WsField('phone', 'Phone'),
      WsField('email', 'Email'),
      WsField('address', 'Address', type: WsFieldType.multiline),
      WsField(
        'openingbalance',
        'Opening balance owed',
        type: WsFieldType.money,
        helper: 'What you already owed them when you started using this app',
      ),
    ],
    onSave: (pk, v) async {
      await WsDataService.saveVendor(
        pkValue: pk,
        values: v,
        clientUuid: _clientUuid,
      );
      // Spent only on success, and only for a create — an update ignores the
      // key entirely. A throw above leaves it intact so the next Save is a
      // retry of this vendor, not a second one.
      if (pk == null) _clientUuid = wsNewUuid();
    },
    onDeactivate: (pk) =>
        WsDataService.deactivateRow('ws_tblvendors', 'vendorid', pk),
  );
}

/// Purchases are documents, not master data: recorded once, never edited.
/// Editing one would have to re-post its journal entry and re-run the bottle
/// movements, so corrections are made with a new document instead.
/// Stateful for exactly one reason: to hold ONE idempotency key per visit to
/// this screen, so a Save retried after a timeout reuses it. A key generated
/// inside onSave would be fresh on every attempt, which to the server is a
/// different purchase — the duplicate migration 012 prevents.
class WsPurchasesScreen extends StatefulWidget {
  const WsPurchasesScreen({super.key});

  @override
  State<WsPurchasesScreen> createState() => _WsPurchasesScreenState();
}

class _WsPurchasesScreenState extends State<WsPurchasesScreen> {
  /// Regenerated after each successful save so the NEXT purchase is a new
  /// document rather than resolving to the previous one.
  String _clientUuid = wsNewUuid();

  @override
  Widget build(BuildContext context) => WsCrudScreen(
    title: 'Purchase',
    icon: Icons.receipt_long_outlined,
    writePermission: 'purchases.manage',
    emptyHint: 'Record what you buy in. Bottles bought here enter your stock.',
    load: WsDataService.fetchPurchases,
    rowBuilder: (r) {
      final v = r['ws_tblvendors'];
      final name = v is Map ? _s(v['vendorname']) : 'Vendor #${r['vendorid']}';
      return WsRowView(
        title: name,
        subtitle:
            '${_s(r['referenceno'])}'
            '${r['billno'] != null ? ' · bill ${_s(r['billno'])}' : ''} · '
            '${_fmtDate(r['purchasedate'])}',
        trailing: 'Rs ${_money.format(_n(r['totalamount']))}',
      );
    },
    fields: [
      // Searchable, and ORGANIZATION-WIDE. Vendors carry no storeid (015) —
      // one business, one set of suppliers — so this must never be narrowed by
      // the selected branch.
      WsField(
        'vendorid',
        'Vendor',
        type: WsFieldType.lookup,
        required: true,
        search: WsLookupService.vendors,
        resolve: WsLookupService.vendorById,
      ),
      WsField(
        'purchasedate',
        'Date',
        type: WsFieldType.date,
        initial: DateTime.now(),
      ),
      // Also organization-wide: one catalogue, whatever branch you are in.
      WsField(
        'productid',
        'Item',
        type: WsFieldType.lookup,
        required: true,
        search: WsLookupService.products,
        resolve: WsLookupService.productById,
      ),
      const WsField(
        'quantity',
        'Quantity',
        type: WsFieldType.number,
        required: true,
      ),
      const WsField('unitcost', 'Cost each', type: WsFieldType.money, required: true),
      const WsField('billno', 'Bill number'),
      const WsField('notes', 'Notes', type: WsFieldType.multiline),
    ],
    onSave: (pk, v) async {
      // DURABLE FIRST. The purchase is written to the on-device queue before
      // any network call, then posted immediately. Online this is the same RPC
      // with the same arguments as before; offline it survives on disk and
      // syncs later instead of being lost with a red error.
      final storeId = WsStoreService.currentStoreId;
      if (storeId == null) {
        throw StateError('No store selected — cannot record a purchase.');
      }

      final outbox = WsOutboxService.instanceOrNull;

      if (outbox == null) {
        // Queue unavailable. Fall back to the direct path rather than refuse
        // to record the purchase. It still carries the key, so it is still
        // safe to retry.
        await WsDataService.recordPurchase(
          vendorId: v['vendorid'] as int,
          date: DateTime.tryParse('${v['purchasedate']}') ?? DateTime.now(),
          productId: v['productid'] as int,
          quantity: _n(v['quantity']),
          unitCost: _n(v['unitcost']),
          billNo: v['billno'] as String?,
          notes: v['notes'] as String?,
          clientUuid: _clientUuid,
          storeId: storeId,
        );
        _clientUuid = wsNewUuid();
        return;
      }

      final item = await WsOutboxService.recordPurchase(
        clientUuid: _clientUuid,
        storeId: storeId,
        vendorId: v['vendorid'] as int,
        vendorName: 'vendor #${v['vendorid']}',
        purchaseDate:
            DateTime.tryParse('${v['purchasedate']}') ?? DateTime.now(),
        lines: [
          {
            'productid': v['productid'] as int,
            'quantity': _n(v['quantity']),
            'unitcost': _n(v['unitcost']),
          },
        ],
        billNo: v['billno'] as String?,
        notes: v['notes'] as String?,
      );

      // context.mounted, not State.mounted: `context` here is the parameter
      // to build(), so guarding the CONTEXT being used is both the narrower
      // check and the one the analyzer can verify. Same element either way —
      // and _reportQueueState still bails on a null ScaffoldMessenger.
      if (context.mounted) _reportQueueState(context, item, 'Purchase');

      // Only after the document is safely QUEUED. A failed enqueue throws
      // above and keeps the key, so pressing Save again is a retry of the same
      // purchase rather than a second one.
      _clientUuid = wsNewUuid();
    },
  );
}

/// Stateful for the same single reason as Purchases: ONE idempotency key per
/// visit, so a Save retried after a timeout reuses it and the vendor is not
/// paid twice.
class WsVendorPaymentsScreen extends StatefulWidget {
  const WsVendorPaymentsScreen({super.key});

  @override
  State<WsVendorPaymentsScreen> createState() =>
      _WsVendorPaymentsScreenState();
}

class _WsVendorPaymentsScreenState extends State<WsVendorPaymentsScreen> {
  /// Regenerated only after a SUCCESSFUL save, so the next payment is a new
  /// document rather than resolving to the previous one.
  String _clientUuid = wsNewUuid();

  @override
  Widget build(BuildContext context) => WsCrudScreen(
    title: 'Vendor Payment',
    icon: Icons.payments_outlined,
    writePermission: 'purchases.manage',
    emptyHint: 'Money paid out to suppliers.',
    load: WsDataService.fetchVendorPayments,
    rowBuilder: (r) {
      final v = r['ws_tblvendors'];
      final name = v is Map ? _s(v['vendorname']) : 'Vendor #${r['vendorid']}';
      return WsRowView(
        title: name,
        subtitle: '${_s(r['voucherno'])} · ${_fmtDate(r['paiddate'])}',
        trailing: 'Rs ${_money.format(_n(r['amountpaid']))}',
        trailingColor: WsColors.red,
      );
    },
    fields: [
      // Searchable, and ORGANIZATION-WIDE. Vendors carry no storeid (015) —
      // one business, one set of suppliers — so this must never be narrowed by
      // the selected branch.
      WsField(
        'vendorid',
        'Vendor',
        type: WsFieldType.lookup,
        required: true,
        search: WsLookupService.vendors,
        resolve: WsLookupService.vendorById,
      ),
      WsField('paiddate', 'Date', type: WsFieldType.date, initial: DateTime.now()),
      const WsField(
        'amountpaid',
        'Amount',
        type: WsFieldType.money,
        required: true,
      ),
      const WsField('notes', 'Notes', type: WsFieldType.multiline),
    ],
    onSave: (pk, v) async {
      final storeId = WsStoreService.currentStoreId;
      if (storeId == null) {
        throw StateError('No store selected — cannot record a vendor payment.');
      }

      final outbox = WsOutboxService.instanceOrNull;

      if (outbox == null) {
        await WsDataService.recordVendorPayment(
          storeId: storeId,
          vendorId: v['vendorid'] as int,
          date: DateTime.tryParse('${v['paiddate']}') ?? DateTime.now(),
          amount: _n(v['amountpaid']),
          notes: v['notes'] as String?,
          clientUuid: _clientUuid,
        );
        _clientUuid = wsNewUuid();
        return;
      }

      final item = await WsOutboxService.recordVendorPayment(
        clientUuid: _clientUuid,
        storeId: storeId,
        vendorId: v['vendorid'] as int,
        vendorName: 'vendor #${v['vendorid']}',
        amount: _n(v['amountpaid']),
        paidDate: DateTime.tryParse('${v['paiddate']}') ?? DateTime.now(),
        notes: v['notes'] as String?,
      );

      // context.mounted, not State.mounted: `context` here is the parameter
      // to build(), so guarding the CONTEXT being used is both the narrower
      // check and the one the analyzer can verify. Same element either way —
      // and _reportQueueState still bails on a null ScaffoldMessenger.
      if (context.mounted) _reportQueueState(context, item, 'Vendor payment');
      _clientUuid = wsNewUuid();
    },
  );
}

// ═══ SET 3 ═══ Staff ══════════════════════════════════════════════════════════

/// Existing staff and their roles.
///
/// This screen deliberately cannot CREATE a user. Creating a login is a
/// Supabase Auth operation — invite them from Authentication → Users, or have
/// them register — and doing it from the client would need the service_role
/// key, which bypasses RLS entirely and must never ship in an app.
class WsStaffScreen extends StatefulWidget {
  const WsStaffScreen({super.key});

  @override
  State<WsStaffScreen> createState() => _WsStaffScreenState();
}

class _WsStaffScreenState extends State<WsStaffScreen> {
  @override
  Widget build(BuildContext context) => WsCrudScreen(
    title: 'Staff',
    icon: Icons.badge_outlined,
    writePermission: 'users.manage',
    // Accounts are created in Supabase Auth, not here — so no Add button.
    canCreate: false,
    emptyHint:
        'Invite people from Supabase → Authentication → Users, or have them '
        'register. They appear here once they belong to this organization.',
    load: () async {
      final staff = await WsDataService.fetchStaff();
      return staff
          .map(
            (u) => {
              'internaluserid': u.internalUserId,
              'authuserid': u.authUserId,
              'fullname': u.fullName,
              'role': u.roleCode,
              'phone': u.phone,
            },
          )
          .toList();
    },
    pkColumn: 'internaluserid',
    rowBuilder: (r) => WsRowView(
      title: _s(r['fullname']),
      subtitle: _s(r['phone']).isEmpty ? 'No phone' : _s(r['phone']),
      trailing: _s(r['role']),
      trailingColor: WsColors.primary,
    ),
    fields: [
      const WsField('fullname', 'Full name', required: true),
      const WsField('phone', 'Phone'),
      WsField(
        'roleid',
        'Role',
        type: WsFieldType.dropdown,
        required: true,
        helper: 'Decides what they can do. Enforced by the database, not the app.',
        options: () async {
          final roles = await WsDataService.fetchRoles();
          return roles
              .map((r) => {'id': r['roleid'], 'label': '${r['rolename']}'})
              .toList();
        },
      ),
    ],
    onSave: (pk, v) async {
      if (pk == null) {
        // Unreachable now that canCreate is false; kept as a guard so a future
        // edit that re-enables the Add button fails loudly instead of writing
        // a half-formed staff row with no auth user behind it.
        throw Exception(
          'Staff accounts are created in Supabase Authentication, not here. '
          'Invite the person, then set their role on this screen.',
        );
      }
      // Name and phone are profile data on ws_tblinternalusers.
      await WsDataService.saveRow('ws_tblinternalusers', 'internaluserid', pk, {
        'fullname': v['fullname'],
        'phone': v['phone'],
      });

      // The role has to move on ws_tblmemberships, which is what RLS reads.
      final roleId = v['roleid'];
      if (roleId is int) {
        final roles = await WsDataService.fetchRoles();
        final match = roles.where((r) => r['roleid'] == roleId).toList();
        if (match.isNotEmpty) {
          final staff = await WsDataService.fetchStaff();
          final me = staff.where((s) => s.internalUserId == pk).toList();
          if (me.isNotEmpty) {
            await WsDataService.updateStaffRole(
              internalUserId: pk as int,
              authUserId: me.first.authUserId,
              roleId: roleId,
              roleCode: '${match.first['rolecode']}',
            );
          }
        }
      }
    },
  );
}

// ═══ SET 4 ═══ Routes and customer groups ═════════════════════════════════════

class WsRoutesScreen extends StatelessWidget {
  const WsRoutesScreen({super.key});

  @override
  Widget build(BuildContext context) => WsCrudScreen(
    title: 'Route',
    icon: Icons.route_outlined,
    writePermission: 'delivery.manage',
    emptyHint: 'Group customers into delivery rounds.',
    load: () => WsDataService.fetchRows('ws_tblroutes', orderBy: 'routename'),
    pkColumn: 'routeid',
    rowBuilder: (r) => WsRowView(
      title: _s(r['routename']),
      subtitle: [
        _s(r['routecode']),
        _s(r['vehicleno']),
      ].where((x) => x.isNotEmpty).join(' · '),
    ),
    fields: [
      const WsField('routecode', 'Code', required: true, hint: 'R-01'),
      const WsField('routename', 'Route name', required: true),
      WsField(
        'areaid',
        'Area',
        type: WsFieldType.dropdown,
        options: () =>
            WsDataService.fetchOptions('ws_tblareas', 'areaid', 'areaname'),
      ),
      WsField(
        'driverid',
        'Driver',
        type: WsFieldType.dropdown,
        options: () async {
          final staff = await WsDataService.fetchStaff();
          return staff
              .map((s) => {'id': s.internalUserId, 'label': s.fullName})
              .toList();
        },
      ),
      const WsField('vehicleno', 'Vehicle number'),
    ],
    onSave: (pk, v) => WsDataService.saveRow('ws_tblroutes', 'routeid', pk, v),
    onDeactivate: (pk) =>
        WsDataService.deactivateRow('ws_tblroutes', 'routeid', pk),
  );
}

class WsCustomerGroupsScreen extends StatelessWidget {
  const WsCustomerGroupsScreen({super.key});

  @override
  Widget build(BuildContext context) => WsCrudScreen(
    title: 'Customer Group',
    icon: Icons.group_work_outlined,
    writePermission: 'customers.manage',
    emptyHint:
        'Pricing tiers, e.g. Hotels or Offices. A group price beats the area '
        'price and loses to a price set on the customer.',
    load: () =>
        WsDataService.fetchRows('ws_tblcustomergroups', orderBy: 'groupname'),
    pkColumn: 'groupid',
    rowBuilder: (r) => WsRowView(title: _s(r['groupname'])),
    fields: const [WsField('groupname', 'Group name', required: true)],
    onSave: (pk, v) =>
        WsDataService.saveRow('ws_tblcustomergroups', 'groupid', pk, v),
    onDeactivate: (pk) =>
        WsDataService.deactivateRow('ws_tblcustomergroups', 'groupid', pk),
  );
}

// ═══ Hub ══════════════════════════════════════════════════════════════════════

/// Entry point for everything above. Responsive: a list on a phone, a grid on
/// wider screens.
class WsSetupScreen extends StatelessWidget {
  const WsSetupScreen({super.key});

  static const _items = <_SetupItem>[
    // First, deliberately. Every figure the app reports is derived from the
    // ledgers, so until the opening position is posted the reports are
    // arithmetically correct and factually wrong.
    _SetupItem('Organization', Icons.business_outlined,
        'Your business name, contact details and document prefixes'),
    _SetupItem('Opening Balances', Icons.flag_outlined,
        'Stock, customer dues, vendor dues at go-live'),
    _SetupItem('Products', Icons.inventory_2_outlined, 'What you sell'),
    // Label only. The table is still ws_tblbottletypes and the code still
    // says bottleTypeId everywhere, because renaming a column that six views,
    // four triggers and the delivery card all read is a migration, not a
    // rename — and this is a wording change.
    _SetupItem('Product Types', Icons.water_drop_outlined,
        'Returnable containers you get back'),
    _SetupItem('Prices', Icons.sell_outlined, 'Per customer, group or area'),
    _SetupItem('Vendors', Icons.local_shipping_outlined, 'Who you buy from'),
    _SetupItem('Purchases', Icons.receipt_long_outlined, 'Stock bought in'),
    _SetupItem('Vendor Payments', Icons.payments_outlined, 'Money paid out'),
    _SetupItem('Staff', Icons.badge_outlined, 'People and their roles'),
    _SetupItem('Routes', Icons.route_outlined, 'Delivery rounds'),
    _SetupItem('Customer Groups', Icons.group_work_outlined, 'Pricing tiers'),
  ];

  Widget _screenFor(String name) {
    switch (name) {
      case 'Organization':
        return const WsOrganizationScreen();
      case 'Opening Balances':
        return const WsOpeningBalancesScreen();
      case 'Products':
        return const WsProductsScreen();
      case 'Product Types':
        return const WsBottleTypesScreen();
      case 'Prices':
        return const WsProductPricesScreen();
      case 'Vendors':
        return const WsVendorsScreen();
      case 'Purchases':
        return const WsPurchasesScreen();
      case 'Vendor Payments':
        return const WsVendorPaymentsScreen();
      case 'Staff':
        return const WsStaffScreen();
      case 'Routes':
        return const WsRoutesScreen();
      default:
        return const WsCustomerGroupsScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1024 ? 3 : (width >= 600 ? 2 : 1);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Setup'),
        flexibleSpace: const WsGradientBar(),
      ),
      body: SafeArea(
        child: GridView(
          padding: const EdgeInsets.all(14),
          // Fixed tile height rather than an aspect ratio, for the same reason
          // as the KPI cards: the contents are two lines of text plus padding,
          // a constant, so tying the height to the window width guarantees a
          // width at which it overflows.
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: 76,
          ),
          children: _items
              .map(
                (it) => Card(
                  margin: EdgeInsets.zero,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => _screenFor(it.name)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Icon(it.icon, color: WsColors.primary, size: 26),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  it.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  it.subtitle,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: WsColors.text3,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right,
                            color: WsColors.text3,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _SetupItem {
  final String name;
  final IconData icon;
  final String subtitle;
  const _SetupItem(this.name, this.icon, this.subtitle);
}
