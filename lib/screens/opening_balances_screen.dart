// =============================================================================
// lib/screens/opening_balances_screen.dart
// Opening balances: stock on hand, customer dues, vendor dues.
//
// WHAT AN OPENING BALANCE IS HERE
//
// Not a number stored in a column. Every balance this app shows is DERIVED —
// customer money from the journal, bottle counts from the append-only bottle
// ledger. So an opening balance is posted as a dated journal entry against
// Opening Balance Equity, and a dated 'opening' row in the bottle ledger. See
// migrations/009_opening_balances.sql for the reasoning.
//
// The practical consequence for this screen: every save is an RPC, and every
// RPC sets a TARGET rather than adding to a running total. Typing 50 twice
// leaves 50, not 100. Changing 50 to 30 posts a -20 correction rather than
// rewriting history, because the bottle ledger cannot be edited.
//
// This is also the screen that fixes a dashboard reading "-3 filled bottles in
// stock": three were delivered out of a stock that was never recorded as
// existing.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/auth_service.dart';
import '../services/supabase_service.dart';
import '../theme/ws_responsive.dart';
import '../theme/ws_theme.dart';

final _money = NumberFormat('#,##0.##');
final _dateFmt = DateFormat('dd MMM yyyy');

double _n(Object? v) =>
    v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);
int _i(Object? v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

class WsOpeningBalancesScreen extends StatefulWidget {
  const WsOpeningBalancesScreen({super.key});

  @override
  State<WsOpeningBalancesScreen> createState() => _WsOpeningBalancesScreenState();
}

class _WsOpeningBalancesScreenState extends State<WsOpeningBalancesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  /// The date every opening posts against. One date for the whole exercise,
  /// because opening balances describe a single moment — the day you started
  /// using this system. Per-row dates would let the ledger disagree with
  /// itself about when the business began.
  DateTime _asOf = DateTime(DateTime.now().year, DateTime.now().month, 1);

  List<Map<String, dynamic>> _stock = [];
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _vendors = [];
  bool _loading = true;
  String? _error;

  // These MATCH the permission each RPC checks server-side:
  //   ws_set_opening_stock     → products.manage
  //   ws_set_customer_opening  → customers.manage
  //   ws_set_vendor_opening    → vendors.manage
  // Gating the whole screen on org.manage instead would be wrong in both
  // directions — hiding an action the database would allow, and offering one
  // it will refuse.
  bool get _canEditStock     => AuthService.permissions.has('products.manage');
  bool get _canEditCustomers => AuthService.permissions.has('customers.manage');
  bool get _canEditVendors   => AuthService.permissions.has('vendors.manage');

  /// The as-at date applies to all three, so any one of them unlocks it.
  bool get _canEdit => _canEditStock || _canEditCustomers || _canEditVendors;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        WsDataService.fetchOpeningStock(),
        WsDataService.fetchCustomerOpenings(),
        WsDataService.fetchVendorOpenings(),
      ]);
      if (!mounted) return;
      setState(() {
        _stock = results[0];
        _customers = results[1];
        _vendors = results[2];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e'.replaceFirst('PostgrestException(message: ', '');
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _asOf,
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
      helpText: 'Opening balances as at',
    );
    if (picked != null && mounted) setState(() => _asOf = picked);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Opening Balances'),
      flexibleSpace: const WsGradientBar(),
      bottom: TabBar(
        controller: _tabs,
        isScrollable: WsBreakpoints.isMobile(context),
        tabs: const [
          Tab(text: 'Stock'),
          Tab(text: 'Customers'),
          Tab(text: 'Vendors'),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: _load,
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : Column(children: [
            _asOfBar(),
            if (_error != null) _errorBar(),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [_stockTab(), _customersTab(), _vendorsTab()],
              ),
            ),
          ]),
  );

  Widget _asOfBar() => Material(
    color: WsColors.primarySurface,
    child: InkWell(
      onTap: _canEdit ? _pickDate : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          const Icon(Icons.event_outlined, size: 18, color: WsColors.primaryDark),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'As at ${_dateFmt.format(_asOf)}',
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: WsColors.primaryDark),
            ),
          ),
          if (_canEdit)
            const Text('Change',
                style: TextStyle(fontSize: 12, color: WsColors.primaryDark)),
        ]),
      ),
    ),
  );

  Widget _errorBar() => Container(
    width: double.infinity,
    color: WsColors.red.withValues(alpha: 0.08),
    padding: const EdgeInsets.all(12),
    child: Text(_error!,
        style: const TextStyle(color: WsColors.red, fontSize: 12)),
  );

  // ── Stock ──────────────────────────────────────────────────────────────────

  Widget _stockTab() {
    if (_stock.isEmpty) {
      return _empty(
        Icons.water_drop_outlined,
        'No product types yet.',
        'Add them under Setup › Product Types first.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _note(
            'How many bottles you owned on ${_dateFmt.format(_asOf)} and had '
            'NOT given to a customer. Bottles already with customers belong on '
            'the Customers tab, not here — counting them twice is the usual '
            'way this goes wrong.',
          ),
          ..._stock.map((r) {
            final qty = _i(r['openingqty']);
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: WsColors.primarySurface,
                child: Text('${r['bottlecode'] ?? '?'}'.characters.take(2).toString(),
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: WsColors.primaryDark)),
              ),
              title: Text('${r['bottlename']}'),
              subtitle: Text(qty == 0
                  ? 'Not set'
                  : '$qty bottles · from ${r['openingdate'] ?? _dateFmt.format(_asOf)}'),
              trailing: Text('$qty',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: qty == 0 ? WsColors.text3 : WsColors.primary)),
              onTap: _canEditStock ? () => _editStock(r) : null,
            );
          }),
        ],
      ),
    );
  }

  Future<void> _editStock(Map<String, dynamic> row) async {
    final saved = await _sheet(
      title: '${row['bottlename']}',
      fields: [
        _NumField('qty', 'Bottles on hand', initial: '${_i(row['openingqty'])}',
            integer: true),
        _NumField('cost', 'Cost per bottle (optional)', initial: '',
            helper: 'Leave blank to record the count without valuing it'),
      ],
      onSave: (v) => WsDataService.setOpeningStock(
        bottleTypeId: _i(row['bottletypeid']),
        qty: _i(v['qty']),
        unitCost: _n(v['cost']),
        asOf: _asOf,
      ),
    );
    if (saved == true) _load();
  }

  // ── Customers ──────────────────────────────────────────────────────────────

  Widget _customersTab() {
    if (_customers.isEmpty) {
      return _empty(Icons.people_outline, 'No customers yet.',
          'Add customers first, then set what they owed you.');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _note(
            'What each customer owed you on ${_dateFmt.format(_asOf)}, and how '
            'many of your bottles they were already holding. Both post against '
            'Opening Balance Equity, so your accounts stay balanced.',
          ),
          ..._customers.map((r) {
            final due = _n(r['openingbalance']);
            return ListTile(
              title: Text('${r['customername']}'),
              subtitle: Text(due == 0 ? 'Not set' : 'Opening due'),
              trailing: Text('Rs ${_money.format(due)}',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: due == 0 ? WsColors.text3 : WsColors.red)),
              onTap: _canEditCustomers ? () => _editCustomer(r) : null,
            );
          }),
        ],
      ),
    );
  }

  Future<void> _editCustomer(Map<String, dynamic> row) async {
    final saved = await _sheet(
      title: '${row['customername']}',
      fields: [
        _NumField('due', 'Amount they owed you', prefix: 'Rs ',
            initial: _n(row['openingbalance']) == 0
                ? ''
                : '${_n(row['openingbalance'])}'),
        _NumField('bottles', 'Bottles they were holding', initial: '',
            integer: true,
            helper: 'Of your default product type. Leave blank for none.'),
      ],
      onSave: (v) => WsDataService.setCustomerOpening(
        customerId: _i(row['customerid']),
        openingDue: _n(v['due']),
        openingBottles: _i(v['bottles']),
        asOf: _asOf,
      ),
    );
    if (saved == true) _load();
  }

  // ── Vendors ────────────────────────────────────────────────────────────────

  Widget _vendorsTab() {
    if (_vendors.isEmpty) {
      return _empty(Icons.local_shipping_outlined, 'No vendors yet.',
          'Add vendors under Setup › Vendors first.');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _note('What you owed each vendor on ${_dateFmt.format(_asOf)}.'),
          ..._vendors.map((r) {
            final due = _n(r['openingbalance']);
            return ListTile(
              title: Text('${r['vendorname']}'),
              subtitle: Text(due == 0 ? 'Not set' : 'Opening payable'),
              trailing: Text('Rs ${_money.format(due)}',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: due == 0 ? WsColors.text3 : WsColors.amber)),
              onTap: _canEditVendors ? () => _editVendor(r) : null,
            );
          }),
        ],
      ),
    );
  }

  Future<void> _editVendor(Map<String, dynamic> row) async {
    final saved = await _sheet(
      title: '${row['vendorname']}',
      fields: [
        _NumField('due', 'Amount you owed them', prefix: 'Rs ',
            initial: _n(row['openingbalance']) == 0
                ? ''
                : '${_n(row['openingbalance'])}'),
      ],
      onSave: (v) => WsDataService.setVendorOpening(
        vendorId: _i(row['vendorid']),
        opening: _n(v['due']),
        asOf: _asOf,
      ),
    );
    if (saved == true) _load();
  }

  // ── Shared bits ────────────────────────────────────────────────────────────

  Future<bool?> _sheet({
    required String title,
    required List<_NumField> fields,
    required Future<void> Function(Map<String, String>) onSave,
  }) => showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => _OpeningSheet(
      title: title,
      subtitle: 'As at ${_dateFmt.format(_asOf)}',
      fields: fields,
      onSave: onSave,
    ),
  );

  Widget _note(String text) => Container(
    margin: const EdgeInsets.fromLTRB(14, 14, 14, 6),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: WsColors.primarySurface,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text,
        style: const TextStyle(fontSize: 12, height: 1.5, color: WsColors.text2)),
  );

  Widget _empty(IconData icon, String title, String hint) => ListView(
    children: [
      SizedBox(height: MediaQuery.sizeOf(context).height * 0.12),
      Icon(icon, size: 44, color: WsColors.text3),
      const SizedBox(height: 12),
      Text(title,
          textAlign: TextAlign.center,
          style: const TextStyle(color: WsColors.text2)),
      const SizedBox(height: 6),
      Text(hint,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: WsColors.text3)),
    ],
  );
}

// ─── One numeric field description ────────────────────────────────────────────

class _NumField {
  final String key;
  final String label;
  final String initial;
  final String? helper;
  final String? prefix;
  final bool integer;

  const _NumField(
    this.key,
    this.label, {
    this.initial = '',
    this.helper,
    this.prefix,
    this.integer = false,
  });
}

/// A StatefulWidget so the controllers are disposed by the framework after the
/// route is gone. Creating them outside and disposing after `await
/// showModalBottomSheet` looks equivalent and is not: that future completes
/// when the route is popped, while the fields are still mounted and animating.
class _OpeningSheet extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<_NumField> fields;
  final Future<void> Function(Map<String, String>) onSave;

  const _OpeningSheet({
    required this.title,
    required this.subtitle,
    required this.fields,
    required this.onSave,
  });

  @override
  State<_OpeningSheet> createState() => _OpeningSheetState();
}

class _OpeningSheetState extends State<_OpeningSheet> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _ctl = {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      _ctl[f.key] = TextEditingController(text: f.initial);
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() { _saving = true; _error = null; });

    final navigator = Navigator.of(context);
    try {
      await widget.onSave(
          {for (final e in _ctl.entries) e.key: e.value.text.trim()});
      if (!mounted) return;
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e'
            .replaceFirst('PostgrestException(message: ', '')
            .replaceFirst('permission denied: ', 'You do not have permission: ');
      });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
        16, 12, 16, MediaQuery.of(context).viewInsets.bottom + 32),
    child: Form(key: _formKey, child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(child: Container(width: 36, height: 4,
            decoration: BoxDecoration(color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 14),
        Text(widget.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        Text(widget.subtitle,
            style: const TextStyle(fontSize: 12, color: WsColors.text3)),
        const SizedBox(height: 14),
        for (final f in widget.fields) ...[
          TextFormField(
            controller: _ctl[f.key],
            keyboardType: TextInputType.numberWithOptions(decimal: !f.integer),
            decoration: InputDecoration(
              labelText: f.label,
              prefixText: f.prefix,
              helperText: f.helper,
              helperMaxLines: 2,
            ),
            validator: (v) {
              final t = (v ?? '').trim();
              if (t.isEmpty) return null;        // blank means zero
              final n = double.tryParse(t);
              if (n == null) return 'Enter a number';
              if (n < 0) return 'Cannot be negative';
              if (f.integer && n != n.roundToDouble()) {
                return 'Whole bottles only';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
        ],
        // Says plainly what the idempotency rule means, because "set" versus
        // "add" is the one thing a user can get badly wrong here.
        const Text(
          'Saving REPLACES the opening figure — it does not add to it. '
          'Entering the same number twice is safe.',
          style: TextStyle(fontSize: 11, color: WsColors.text3, height: 1.4),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: WsColors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8)),
            child: Text(_error!,
                style: const TextStyle(color: WsColors.red, fontSize: 12)),
          ),
        ],
        const SizedBox(height: 18),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(height: 18, width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save Opening Balance'),
        )),
      ],
    )),
  );
}
