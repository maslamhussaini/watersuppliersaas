// =============================================================================
// lib/screens/customers_screen.dart
// =============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ws_models.dart';
import '../services/auth_service.dart';
import '../reports/ws_delivery_card_pdf.dart';
import '../services/outbox/ws_outbox.dart';
import '../services/outbox/ws_outbox_supabase.dart';
import '../services/lookup_service.dart';
import '../services/store_service.dart';
import '../widgets/ws_lookup_field.dart';
import 'import_customers_screen.dart';
import '../services/supabase_service.dart';
import '../theme/ws_responsive.dart';
import '../theme/ws_theme.dart';

class WsCustomersScreen extends StatefulWidget {
  const WsCustomersScreen({super.key});
  @override State<WsCustomersScreen> createState() => _WsCustomersScreenState();
}

class _WsCustomersScreenState extends State<WsCustomersScreen> {
  List<WsCustomer> _all = [], _filtered = [];
  final   _searchCtl = TextEditingController();
  String  _search = '';
  String  _filter = 'all';
  bool    _loading = true;
  final   _money = NumberFormat('#,##0', 'en_US');

  @override void initState() { super.initState(); _load(); }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await WsDataService.fetchCustomers();
    if (!mounted) return;
    setState(() { _all = list; _applyFilter(); _loading = false; });
  }

  void _applyFilter() {
    setState(() {
      _filtered = _all.where((c) {
        final matchSearch = _search.isEmpty ||
            c.customerName.toLowerCase().contains(_search.toLowerCase()) ||
            (c.phone ?? '').contains(_search);
        final matchFilter = _filter == 'all' ||
            (_filter == 'due'      && (c.outstandingDue ?? 0) > 0) ||
            (_filter == 'settled'  && (c.outstandingDue ?? 0) <= 0) ||
            (_filter == 'active'   && c.isActive);
        return matchSearch && matchFilter;
      }).toList();
    });
  }

  void _showDetail(WsCustomer c) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _CustomerDetailSheet(
        customer: c,
        onEdit:   () { Navigator.pop(context);
          Navigator.push(context, MaterialPageRoute(
              builder: (_) => WsCustomerFormScreen(customer: c))).then((_) => _load()); },
        onDelete: () async {
          Navigator.pop(context);
          final yes = await wsShowDeleteDialog(context,
              title: 'Delete Customer?',
              content:  'Remove ${c.customerName} and all linked records. This cannot be undone.');
          if (yes == true) { await WsDataService.deleteCustomer(c.customerId); _load(); }
        },
        onDeliveryCard: () => _openDeliveryCard(c),
        money: _money,
      ),
    );
  }

  /// Opens the printed delivery card — the digital copy of the customer's paper
  /// card. The PDF module existed but nothing navigated to it, so the feature
  /// shipped as unreachable code.
  Future<void> _openDeliveryCard(WsCustomer c) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    navigator.pop();   // close the detail sheet

    messenger.showSnackBar(const SnackBar(
      content: Text('Preparing delivery card…'),
      duration: Duration(seconds: 1),
    ));

    try {
      final data = await WsDataService.fetchDeliveryCardData(customer: c);
      if (!mounted) return;

      if (data == null) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Could not load the organization details for the card.'),
          backgroundColor: WsColors.red,
        ));
        return;
      }
      if (data.isEmpty) {
        messenger.showSnackBar(SnackBar(
          content: Text('No deliveries or payments recorded for ${c.customerName} yet.'),
        ));
        return;
      }

      navigator.push(MaterialPageRoute(
        builder: (_) => WsDeliveryCardScreen(
          card: WsDeliveryCardPdf(
            org: data.org,
            customer: data.customer,
            rows: data.rows,
            bottleBalances: data.bottleBalances,
            periodFrom: data.periodFrom,
            periodTo: data.periodTo,
          ),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: WsColors.red),
      );
    }
  }

  Color _getFilterColor(String f) {
    switch (f) {
      case 'active': return WsColors.primaryLight;
      case 'due': return WsColors.amber;
      case 'settled': return WsColors.green;
      default: return WsColors.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Customers'),
        flexibleSpace: const WsGradientBar(),
        actions: [
          IconButton(
            tooltip: 'Import from a spreadsheet',
            icon: const Icon(Icons.upload_file_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const WsImportCustomersScreen()),
            ).then((_) => _load()),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Search bar ────────────────────────────────────────────────
          // The bespoke one that used to live here had a purple magnifier and
          // its own shadow; this is the shared OrderMate pill so every list in
          // the app searches the same way.
          WsSearchField(
            controller: _searchCtl,
            hint: 'Search by name or phone…',
            onChanged: (v) { _search = v; _applyFilter(); },
          ),
          // ── Filter chips ──────────────────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              for (final f in [['all','All (${_all.length})'],['active','Active'],
                ['due','Due'],['settled','Settled']])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(f[1]),
                    selected: _filter == f[0],
                    onSelected: (_) { _filter = f[0]; _applyFilter(); },
                    selectedColor: WsColors.primary,
                    backgroundColor: Colors.white,
                    showCheckmark: false,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(color: _filter == f[0] ? Colors.transparent : _getFilterColor(f[0])),
                    ),
                    labelStyle: TextStyle(
                      color: _filter == f[0] ? Colors.white : _getFilterColor(f[0]),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ]),
          ),
          // ── List ──────────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                itemCount: _filtered.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 72, color: Colors.black12),
                itemBuilder: (_, i) {
                  final c = _filtered[i];
                  final due = c.outstandingDue ?? 0;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    onTap: () => _showDetail(c),
                    leading: CircleAvatar(
                      radius: 24,
                      backgroundColor: _getFilterColor(due > 0 ? 'due' : 'settled'),
                      child: Text(c.customerName[0],
                          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
                    ),
                    title: Text(c.customerName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                          '📍 ${c.areaName ?? '—'}  ·  🫙 ${c.bottleBalance} bottles  ·  ${c.effectiveRate.toStringAsFixed(0)}/btl',
                          style: const TextStyle(fontSize: 12, color: WsColors.text3)),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('Rs ${_money.format(due)}',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: due > 0 ? WsColors.red : WsColors.green)),
                        const SizedBox(height: 4),
                        if (!c.isActive)
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.lock, size: 12, color: WsColors.amber),
                              SizedBox(width: 2),
                              Text('locked', style: TextStyle(color: WsColors.amber, fontSize: 10, fontWeight: FontWeight.w600)),
                            ],
                          )
                        else
                          WsBadge(
                              label: due > 0 ? 'Due' : 'Settled',
                              bg: due > 0 ? WsColors.redLight : WsColors.greenLight,
                              fg: due > 0 ? WsColors.red     : WsColors.green),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: WsColors.primary,
        foregroundColor: Colors.white,
        onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const WsCustomerFormScreen()))
            .then((_) => _load()),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _CustomerDetailSheet extends StatelessWidget {
  final WsCustomer customer;
  final VoidCallback onEdit, onDelete, onDeliveryCard;
  final NumberFormat money;
  const _CustomerDetailSheet({required this.customer, required this.onEdit,
    required this.onDelete, required this.onDeliveryCard, required this.money});

  @override Widget build(BuildContext context) {
    final due = customer.outstandingDue ?? 0;
    final canManage = AuthService.permissions.canEditCustomers;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 14),
          Row(children: [
            CircleAvatar(
              radius: 26, backgroundColor: WsColors.primary,
              child: Text(customer.customerName[0],
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(customer.customerName,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              Text('${customer.areaName ?? '—'} · ${customer.phone ?? '—'}',
                  style: const TextStyle(color: WsColors.text2, fontSize: 12)),
            ])),
            if (!customer.isActive) const Icon(Icons.lock, color: WsColors.text3),
          ]),
          const SizedBox(height: 16),
          _row('Bottles with customer', '${customer.bottleBalance}'),
          _row('Rate per bottle',       'Rs ${customer.effectiveRate.toStringAsFixed(0)}'),
          _row('Outstanding due',       'Rs ${money.format(due)}',
              color: due > 0 ? WsColors.red : WsColors.green),
          _row('Deposit',               'Rs ${money.format(customer.depositAmount)}'),
          const SizedBox(height: 16),
          // Reading the card needs no special permission — a driver on a round
          // should be able to show a customer their own history.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onDeliveryCard,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Delivery Card (PDF)'),
            ),
          ),
          const SizedBox(height: 10),
          // Editing is gated on customers.manage. RLS refuses the write either
          // way; this stops the UI offering a button that always fails.
          if (!canManage)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('You have read-only access to customers.',
                  style: TextStyle(color: WsColors.text3, fontSize: 12)),
            ),
          Row(children: [
            Expanded(child: ElevatedButton.icon(
                onPressed: canManage ? onEdit : null,
                icon: const Icon(Icons.edit),
                label: const Text('Edit'))),
            const SizedBox(width: 10),
            if (customer.isActive && canManage)
              Expanded(child: OutlinedButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, color: WsColors.red),
                  label: const Text('Delete', style: TextStyle(color: WsColors.red)),
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: WsColors.red))))
            else
              Expanded(child: OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.lock),
                  label: const Text('Locked'))),
          ]),
        ],
      ),
    );
  }

  Widget _row(String k, String v, {Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(k, style: const TextStyle(color: WsColors.text2)),
      Text(v, style: TextStyle(fontWeight: FontWeight.w600,
          color: color ?? WsColors.text1)),
    ]),
  );
}

// =============================================================================
// lib/screens/customer_form_screen.dart
// =============================================================================

class WsCustomerFormScreen extends StatefulWidget {
  final WsCustomer? customer;
  const WsCustomerFormScreen({super.key, this.customer});
  @override State<WsCustomerFormScreen> createState() => _WsCustomerFormState();
}

class _WsCustomerFormState extends State<WsCustomerFormScreen> {
  final _form    = GlobalKey<FormState>();
  final _name    = TextEditingController();
  final _phone   = TextEditingController();
  final _address = TextEditingController();
  final _rate    = TextEditingController();
  final _deposit = TextEditingController();
  final _email   = TextEditingController();
  List<WsArea> _areas = [];
  WsArea?      _selectedArea;
  bool _loading = false;

  /// One key per Save action, held in state so a retry after a timeout carries
  /// the same value. Regenerated only after a save completes — the same
  /// lifecycle the four transactional screens use.
  String _clientUuid = wsNewUuid();

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _rate.dispose();
    _deposit.dispose();
    _email.dispose();
    super.dispose();
  }

  @override void initState() {
    super.initState();
    _loadAreas();
    if (widget.customer != null) {
      final c = widget.customer!;
      _name.text    = c.customerName;
      _phone.text   = c.phone    ?? '';
      _address.text = c.address  ?? '';
      _rate.text    = c.rateOverride?.toStringAsFixed(0) ?? '';
      _deposit.text = c.depositAmount.toStringAsFixed(0);
    }
  }

  Future<void> _loadAreas() async {
    final areas = await WsDataService.fetchAreas();
    setState(() {
      _areas = areas;
      if (widget.customer != null) {
        _selectedArea = areas.firstWhere(
            (a) => a.areaId == widget.customer!.areaId,
            orElse: () => areas.first);
      } else if (areas.isNotEmpty) {
        _selectedArea = areas.first;
      }
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _selectedArea == null) return;
    setState(() => _loading = true);
    try {
      final c = WsCustomer(
        customerId:    widget.customer?.customerId ?? 0,
        orgId:         widget.customer?.orgId      ?? 0,
        areaId:        _selectedArea!.areaId,
        customerName:  _name.text.trim(),
        phone:         _phone.text.trim().isEmpty   ? null : _phone.text.trim(),
        address:       _address.text.trim().isEmpty ? null : _address.text.trim(),
        rateOverride:  _rate.text.trim().isEmpty    ? null : double.tryParse(_rate.text.trim()),
        depositAmount: double.tryParse(_deposit.text.trim()) ?? 0,
        bottleBalance: widget.customer?.bottleBalance ?? 0,
        createdDate:   widget.customer?.createdDate ?? DateTime.now(),
      );
      await WsDataService.upsertCustomer(c, clientUuid: _clientUuid);
      // Spent only on success. If the call above threw — including the timeout
      // that may already have created the customer — the key is left alone, so
      // tapping Save again is a RETRY of this customer rather than a second
      // one. Ignored entirely on the update path, which is already idempotent.
      _clientUuid = wsNewUuid();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: WsColors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
        title: Text(widget.customer == null ? 'Add Customer' : 'Edit Customer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _loading ? null : _save,
          )
        ]),
    body: Form(
      key: _form,
      child: ListView(padding: const EdgeInsets.all(14), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          const Text('Personal Info', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text('Full Name', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          TextFormField(controller: _name,
              decoration: const InputDecoration(hintText: 'Customer name'),
              validator: (v) => v!.isEmpty ? 'Required' : null),
          const SizedBox(height: 12),
          const Text('Phone', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          TextFormField(controller: _phone,
              decoration: const InputDecoration(hintText: '03XX-XXXXXXX'),
              keyboardType: TextInputType.phone),
          const SizedBox(height: 12),
          const Text('Address', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          TextFormField(controller: _address,
              decoration: const InputDecoration(hintText: 'House / Street / Area'), maxLines: 2),
        ]))),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          const Text('Delivery Settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text('Area', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          if (_areas.isEmpty)
            const Text('Loading areas…', style: TextStyle(color: WsColors.text3))
          else
            DropdownButtonFormField<WsArea>(
              initialValue: _selectedArea,
              items: _areas.map((a) => DropdownMenuItem(
                  value: a,
                  child: Text('${a.areaName} — Rs ${a.ratePerBottle.toStringAsFixed(0)}/bottle'))).toList(),
              onChanged: (a) => setState(() => _selectedArea = a),
            ),
          const SizedBox(height: 12),
          const Text('Rate Override (optional)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          TextFormField(controller: _rate,
              decoration: const InputDecoration(
                  hintText: 'Leave blank to use area rate'),
              keyboardType: TextInputType.number),
          const SizedBox(height: 12),
          const Text('Deposit Amount', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          TextFormField(controller: _deposit,
              decoration: const InputDecoration(hintText: '0'),
              keyboardType: TextInputType.number),
        ]))),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Portal Access (Optional)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            const Text('Customer Email', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
            const SizedBox(height: 6),
            TextFormField(controller: _email,
                decoration: const InputDecoration(hintText: 'customer@email.com'),
                keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 8),
            const Text('Customer will receive an invite to view their own delivery card on the app.',
                style: TextStyle(fontSize: 12, color: WsColors.text3)),
          ],
        ))),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _loading ? null : _save,
          child: _loading
              ? const SizedBox(height: 20, width: 20,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('Save Customer'),
        ),
      ]),
    ),
  );
}


// =============================================================================
// lib/screens/areas_screen.dart
// =============================================================================

class WsAreasScreen extends StatefulWidget {
  const WsAreasScreen({super.key});
  @override State<WsAreasScreen> createState() => _WsAreasScreenState();
}

class _WsAreasScreenState extends State<WsAreasScreen> {
  List<WsArea> _areas = [];

  /// Feeds the INVENTORY OVERVIEW card at the top of this screen. Nullable
  /// because the view can fail independently of the areas list — a bottle
  /// count that cannot be read shows 0, it does not blank the whole screen.
  WsBottlePosition? _pos;

  bool _loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() => _loading = true);
    final a = await WsDataService.fetchAreas();
    WsBottlePosition? p;
    try {
      p = await WsDataService.fetchBottlePositionTotals();
    } catch (_) {
      p = null;
    }
    if (!mounted) return;
    setState(() { _areas = a; _pos = p; _loading = false; });
  }

  /// The sheet owns its own controllers — see [_WsAreaFormSheet].
  Future<void> _showAreaForm([WsArea? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _WsAreaFormSheet(existing: existing),
    );
    if (saved == true && mounted) _load();
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Areas & Rates'),
      actions: [
        IconButton(icon: const Icon(Icons.add), onPressed: () => _showAreaForm()),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          // ── Inventory overview card ──────────────────────────────────
          Card(
            margin: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('INVENTORY OVERVIEW', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: WsColors.text3)),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // These four were hardcoded to 150 / 45 / 26 / 8 —
                      // invented numbers presented as your live inventory. They
                      // now come from vw_ws_bottleposition, derived from the
                      // append-only bottle ledger.
                      // Read off _pos directly rather than through locals:
                      // build() here is an arrow expression, so there is
                      // nowhere to declare them.
                      for (final item in [
                        [
                          'Total Bottles',
                          '${(_pos?.total ?? 0) + (_pos?.lost ?? 0) + (_pos?.damaged ?? 0)}',
                          WsColors.primary,
                        ],
                        ['In Stock', '${_pos?.inStock ?? 0}', WsColors.teal],
                        ['With Custs', '${_pos?.withCustomers ?? 0}', WsColors.amber],
                        ['Lost/Dmg', '${(_pos?.lost ?? 0) + (_pos?.damaged ?? 0)}', WsColors.red],
                      ])
                        Column(children: [
                          Text(item[1] as String,
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700,
                                  color: item[2] as Color)),
                          Text(item[0] as String,
                              style: const TextStyle(fontSize: 11, color: WsColors.text2)),
                        ]),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const WsSectionHeader('Delivery Areas'),
          ..._areas.map((a) => Card(
            child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
              Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                      color: WsColors.primarySurface, borderRadius: BorderRadius.circular(10)),
                  child: Center(child: Text(a.areaName[0],
                      style: const TextStyle(fontWeight: FontWeight.w700, color: WsColors.primaryDark, fontSize: 18))),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.areaName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  Text('Rs ${a.ratePerBottle.toStringAsFixed(0)}/bottle · ${a.customerCount ?? 0} customers',
                      style: const TextStyle(fontSize: 12, color: WsColors.text2)),
                ])),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                      color: WsColors.primarySurface, borderRadius: BorderRadius.circular(8)),
                  child: Text('Rs ${a.ratePerBottle.toStringAsFixed(0)}',
                      style: const TextStyle(color: WsColors.primaryDark, fontWeight: FontWeight.w700, fontSize: 12)),
                ),
              ]),
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _areaStat('W/ Custs', '${a.bottlesWithCustomers ?? 0}', WsColors.primary),
                  _areaStat('Delivered', '${a.deliveredThisMonth ?? 0}', WsColors.green),
                  _areaStat('Customers', '${a.customerCount ?? 0}', WsColors.teal),
                ],
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: OutlinedButton.icon(
                    onPressed: () => _showAreaForm(a),
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Edit'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(
                    onPressed: () async {
                      final yes = await wsShowDeleteDialog(context,
                          title: 'Delete Area?',
                          content:  'Remove "${a.areaName}"? Customers in this area will need reassignment.');
                      if (yes == true) { await WsDataService.deleteArea(a.areaId); _load(); }
                    },
                    icon: const Icon(Icons.delete_outline, size: 16, color: WsColors.red),
                    label: const Text('Delete', style: TextStyle(color: WsColors.red)),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: WsColors.red)))),
              ]),
            ])),
          )),
        ],
      ),
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: () => _showAreaForm(),
      child: const Icon(Icons.add),
    ),
  );

  Widget _areaStat(String label, String value, Color color) => Column(children: [
    Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
    Text(label, style: const TextStyle(fontSize: 10, color: WsColors.text2)),
  ]);
}

/// The Add / Edit Area sheet, as a widget that owns its own state.
///
/// It was previously built inline inside _showAreaForm, with the controllers
/// created before showModalBottomSheet and disposed after it returned. That is
/// wrong in a way that only shows up at runtime: the future returned by
/// showModalBottomSheet completes when the route is POPPED, not when it has
/// finished animating off screen. The TextFields were therefore still mounted
/// and still listening when their controllers were disposed, which tears down
/// the sheet's element tree in the wrong order and trips
///   'package:flutter/src/widgets/framework.dart': Failed assertion:
///   '_dependents.isEmpty': is not true
/// as the InheritedWidgets those fields depend on unmount with live
/// dependents still registered.
///
/// A State object disposes at exactly the right moment, after the route is
/// gone, which is the whole reason the lifecycle exists. There is no correct
/// place to put a manual dispose() here, so the manual version is deleted.
class _WsAreaFormSheet extends StatefulWidget {
  final WsArea? existing;
  const _WsAreaFormSheet({this.existing});

  @override
  State<_WsAreaFormSheet> createState() => _WsAreaFormSheetState();
}

class _WsAreaFormSheetState extends State<_WsAreaFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _rate;
  late final TextEditingController _days;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.areaName ?? '');
    _rate = TextEditingController(text: e?.ratePerBottle.toStringAsFixed(0) ?? '');
    _days = TextEditingController(text: e?.deliveryDays ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _rate.dispose();
    _days.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    // Guards against a double tap creating two areas — the old inline version
    // had no such guard and the button stayed live for the whole round trip.
    setState(() { _saving = true; _error = null; });

    final navigator = Navigator.of(context);
    try {
      await WsDataService.upsertArea(WsArea(
        areaId: widget.existing?.areaId ?? 0,
        orgId:  widget.existing?.orgId  ?? 0,
        areaName:      _name.text.trim(),
        ratePerBottle: double.parse(_rate.text.trim()),
        deliveryDays:  _days.text.trim().isEmpty ? null : _days.text.trim(),
      ));
      if (!mounted) return;
      navigator.pop(true);          // caller reloads the list
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e'.replaceFirst('PostgrestException(message: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    // This context is the sheet's own, so the keyboard inset is measured
    // against the sheet rather than the screen behind it.
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
        Text(widget.existing == null ? 'Add Area' : 'Edit Area',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        TextFormField(controller: _name,
            decoration: const InputDecoration(labelText: 'Area Name *'),
            textInputAction: TextInputAction.next,
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
        const SizedBox(height: 12),
        TextFormField(controller: _rate,
            decoration: const InputDecoration(
                labelText: 'Rate per Bottle (Rs) *', prefixText: 'Rs '),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            validator: (v) {
              final n = double.tryParse((v ?? '').trim());
              if (n == null) return 'Enter valid rate';
              if (n < 0) return 'Cannot be negative';
              return null;
            }),
        const SizedBox(height: 12),
        TextFormField(controller: _days,
            decoration: const InputDecoration(
                labelText: 'Delivery Days (e.g. Mon,Wed,Fri)'),
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _saving ? null : _save()),
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
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(height: 18, width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save Area'),
        )),
      ],
    )),
  );
}

// =============================================================================
// lib/screens/bottle_health_screen.dart
// =============================================================================

class WsBottleHealthScreen extends StatefulWidget {
  const WsBottleHealthScreen({super.key});
  @override State<WsBottleHealthScreen> createState() => _WsBottleHealthScreenState();
}

class _WsBottleHealthScreenState extends State<WsBottleHealthScreen> {
  // Was WsBottleSnapshot from ws_tblbottleinventory — a table that had to be
  // populated by hand and which nothing in the app ever wrote to, so every tile
  // on this screen showed zero regardless of how many bottles were in
  // circulation. vw_ws_bottleposition derives the same numbers from the
  // append-only bottle ledger, so it is correct by construction.
  WsBottlePosition? _pos;
  bool _loading = true;

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await WsDataService.fetchBottlePositionTotals();
      if (!mounted) return;
      setState(() { _pos = p; _loading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _showConditionDetail(String title, Color color, String message) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 14),
          Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 10),
          Text(message, style: const TextStyle(color: WsColors.text2, height: 1.6)),
        ]),
      ),
    );
  }

  @override Widget build(BuildContext context) {
    final s = _pos;
    // "Perfect" now means accounted for: with a customer or in stock. Condition
    // grading (needs cleaning / damaged) is not tracked per bottle anywhere in
    // the schema, so the old tiles were reporting a number that had no source.
    // Lost and damaged come from the bottle ledger's txntype.
    final total  = (s?.total ?? 0) + (s?.lost ?? 0) + (s?.damaged ?? 0);
    final perf   = s?.total         ?? 0;
    final clean  = s?.inStock       ?? 0;
    final dmg    = s?.damaged       ?? 0;
    final empty  = s?.withCustomers ?? 0;
    final score  = s?.healthScore   ?? 0;
    final lost   = s?.lost          ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bottle Health'),
        // Was a home icon with an empty callback. Refresh is what this screen
        // actually needs, and it works.
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
          : RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.only(bottom: 20), children: [
          // ── Health score card ────────────────────────────────────────
          Card(
            margin: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: Padding(padding: const EdgeInsets.all(16), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Overall Health Score',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 12),
                Text('${score.toStringAsFixed(0)}%',
                    style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold,
                        color: score >= 80 ? WsColors.green
                            : score >= 60 ? WsColors.amber : WsColors.red)),
                const SizedBox(height: 8),
                WsHealthBar(value: score / 100,
                    color: score >= 80 ? WsColors.green
                        : score >= 60 ? WsColors.amber : WsColors.red,
                    height: 16),
                const SizedBox(height: 12),
                // The old caption said "Last checked 30 April" — a hardcoded
                // date next to a figure from a table nobody updated. These
                // numbers are derived live from the bottle ledger.
                Text(
                  lost + dmg == 0
                      ? 'Based on $total bottles · all accounted for'
                      : 'Based on $total bottles · $lost lost, $dmg damaged',
                  style: const TextStyle(fontSize: 12, color: WsColors.text3),
                ),
              ],
            )),
          ),

          // ── KPI cards ────────────────────────────────────────────────
          Padding(
            padding: WsBreakpoints.pagePadding(context),
            // Same fix as the dashboard: fixed row height, responsive column
            // count. These are the same WsKpiCard, so they overflowed the same
            // 13 px at the same window width.
            child: GridView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: WsBreakpoints.gridColumns(context),
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                // Sized from the card, not from a number typed here. A literal
                  // is how the previous 140 stayed behind when the card grew,
                  // and the text-scale factor keeps it honest for users who
                  // have enlarged the system font.
                  mainAxisExtent: WsStatCard.preferredHeight *
                      MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.5),
              ),
              children: [
                WsStatCard(icon: Icons.check_circle_outline, value: '$perf', title: 'Perfect Condition',
                    // total is 0 for a new organization, and 0/0 in Dart is
                    // NaN, not an error — the card read "NaN% of stock".
                    footnote: total == 0
                        ? 'No bottles yet'
                        : '${(perf / total * 100).toStringAsFixed(0)}% of stock',
                    color: WsColors.green,
                    onTap: () => _showConditionDetail('✅ Perfect Condition', WsColors.green,
                        'These bottles are in good working condition — filled and cleared for delivery.')),
                WsStatCard(icon: Icons.cleaning_services_outlined, value: '$clean', title: 'Needs Cleaning',
                    footnote: 'Schedule wash', color: WsColors.amber,
                    onTap: () => _showConditionDetail('🧹 Needs Cleaning', WsColors.amber,
                        'These $clean bottles require cleaning before refilling. Do not deliver until cleaned.')),
                WsStatCard(icon: Icons.warning_amber_outlined, value: '$dmg', title: 'Damaged',
                    footnote: 'Write off / repair', color: WsColors.red,
                    onTap: () => _showConditionDetail('⚠️ Damaged', WsColors.red,
                        '$dmg bottles have cracks, leaks, or broken caps. Mark for write-off or send for repair.')),
                WsStatCard(icon: Icons.inbox_outlined, value: '$empty', title: 'Empty (Returned)',
                    footnote: 'Awaiting refill', color: WsColors.primary,
                    onTap: () => _showConditionDetail('📦 Empty (Returned)', WsColors.primary,
                        '$empty empty bottles have been collected from customers and are awaiting refill.')),
              ],
            ),
          ),

          const WsSectionHeader('CONDITION BREAKDOWN'),

          // ── Progress bars ─────────────────────────────────────────────
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 14),
            child: Padding(padding: const EdgeInsets.all(16), child: Column(
              children: [
                for (final row in [
                  ['Perfect',        perf,  WsColors.green],
                  ['Needs Cleaning', clean, WsColors.amber],
                  ['Damaged',        dmg,   WsColors.red],
                  ['Empty (Returned)', empty, WsColors.primary],
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text(row[0] as String,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        Text('${row[1]}',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: row[2] as Color)),
                      ]),
                      const SizedBox(height: 8),
                      WsHealthBar(value: total > 0 ? (row[1] as int)/total : 0,
                          color: row[2] as Color, height: 12),
                    ]),
                  ),
              ],
            )),
          ),
        ]),
      ),
    );
  }
}

// =============================================================================
// lib/screens/payments_screen.dart
// =============================================================================

class WsPaymentsScreen extends StatefulWidget {
  const WsPaymentsScreen({super.key});
  @override State<WsPaymentsScreen> createState() => _WsPaymentsScreenState();
}

class _WsPaymentsScreenState extends State<WsPaymentsScreen> {
  List<WsPayment> _payments = [];
  bool _loading = true;
  WsPaymentMethod? _methodFilter;
  final _money = NumberFormat('#,##0', 'en_US');

  WsDashboardStats? _stats;

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() => _loading = true);
    final p = await WsDataService.fetchPayments();
    WsDashboardStats? s;
    try {
      s = await WsDataService.fetchDashboardStats();
    } catch (_) {
      s = null;
    }
    if (!mounted) return;
    setState(() { _payments = p; _stats = s; _loading = false; });
  }

  List<WsPayment> get _filtered => _methodFilter == null
      ? _payments
      : _payments.where((p) => p.paymentMethod == _methodFilter).toList();

  /// Sum of payments dated in the current calendar month. Previously the card
  /// showed the literal string '52,640' — and 'Total Receivable' showed
  /// '8,000' — regardless of the data. Both were invented.
  double get _collectedThisMonth {
    final now = DateTime.now();
    return _payments
        .where((p) =>
            p.paymentDate.year == now.year && p.paymentDate.month == now.month)
        .fold<double>(0, (sum, p) => sum + p.amountReceived);
  }

  Future<void> _addPayment() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const _WsPaymentFormSheet(),
    );
    if (saved == true && mounted) _load();
  }

  Color _methodColor(WsPaymentMethod m) => {
    WsPaymentMethod.cash:      WsColors.green,
    WsPaymentMethod.easypaisa: WsColors.primary,
    WsPaymentMethod.jazzcash:  WsColors.purple,
    WsPaymentMethod.bank:      WsColors.teal,
    WsPaymentMethod.other:     WsColors.text2,
  }[m]!;

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Payments'),
      // The AppBar '+' and the FAB were BOTH `onPressed: () {}` — two dead
      // buttons offering the same non-action. One live button is enough.
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: _load,
        ),
      ],
    ),
    body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── KPIs ──────────────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: WsStatCard(icon: Icons.account_balance_wallet_outlined,
              value: 'Rs ${_money.format(_stats?.totalReceivable ?? 0)}',
              title: 'Total Receivable',
              footnote: '${_stats?.totalCustomers ?? 0} customers',
              color: WsColors.red)),
          const SizedBox(width: 10),
          Expanded(child: WsStatCard(icon: Icons.check_circle_outline,
              value: 'Rs ${_money.format(_collectedThisMonth)}',
              title: 'Collected This Month',
              footnote: DateFormat('MMMM yyyy').format(DateTime.now()),
              color: WsColors.green)),
        ]),
      ),
      // ── Method filter chips ───────────────────────────────────────────
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          FilterChip(
            label: const Text('All'),
            selected: _methodFilter == null,
            onSelected: (_) => setState(() => _methodFilter = null),
            selectedColor: WsColors.primary,
            backgroundColor: Colors.white,
            showCheckmark: false,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: _methodFilter == null ? Colors.transparent : WsColors.primary),
            ),
            labelStyle: TextStyle(
              color: _methodFilter == null ? Colors.white : WsColors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          for (final m in [WsPaymentMethod.cash, WsPaymentMethod.easypaisa, WsPaymentMethod.jazzcash])
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FilterChip(
                label: Text(m.label),
                selected: _methodFilter == m,
                onSelected: (_) => setState(() => _methodFilter = m),
                selectedColor: _methodColor(m),
                backgroundColor: Colors.white,
                showCheckmark: false,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: _methodFilter == m ? Colors.transparent : _methodColor(m)),
                ),
                labelStyle: TextStyle(
                  color: _methodFilter == m ? Colors.white : _methodColor(m),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        // Was the literal 'MARCH 2024'.
        child: Text(
            '${_filtered.length} PAYMENT${_filtered.length == 1 ? '' : 'S'}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: WsColors.text3)),
      ),
      Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _filtered.isEmpty
          // Without this the screen was simply blank, which reads as a broken
          // screen rather than an empty one.
          ? RefreshIndicator(
              onRefresh: _load,
              child: ListView(children: [
                SizedBox(height: MediaQuery.sizeOf(context).height * 0.15),
                const Icon(Icons.receipt_long_outlined,
                    size: 44, color: WsColors.text3),
                const SizedBox(height: 12),
                Text(
                  _methodFilter == null
                      ? 'No payments recorded yet.'
                      : 'No ${_methodFilter!.label} payments.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: WsColors.text2),
                ),
                const SizedBox(height: 6),
                const Text('Tap + to record one.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: WsColors.text3)),
              ]),
            )
          : RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          itemCount: _filtered.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 72, color: Colors.black12),
          itemBuilder: (_, i) {
            final p = _filtered[i];
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: _methodColor(p.paymentMethod),
                child: Text(p.paymentMethod.emoji,
                    style: const TextStyle(fontSize: 20, inherit: false)),
              ),
              title: Text(p.customerName ?? 'Customer #${p.customerId}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    '${DateFormat('yyyy-MM-dd').format(p.paymentDate)} · ${p.paymentMethod.label} · by ${p.receivedByName ?? 'unknown'}',
                    style: const TextStyle(fontSize: 12, color: WsColors.text3)
                ),
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('+Rs ${_money.format(p.amountReceived)}',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: WsColors.green)),
                  const SizedBox(height: 4),
                  if (p.referenceNo != null)
                    Text(p.referenceNo!, style: const TextStyle(fontSize: 10, color: WsColors.text3))
                  else
                    const Text('—', style: TextStyle(fontSize: 10, color: WsColors.text3)),
                ],
              ),
            );
          },
        ),
      )),
    ]),
    floatingActionButton: FloatingActionButton(
      backgroundColor: WsColors.primary,
      foregroundColor: Colors.white,
      onPressed: _addPayment,
      child: const Icon(Icons.add),
    ),
  );
}

/// Record a payment.
///
/// WsDataService.insertPayment() already existed and was called from nowhere:
/// both Add buttons on this screen were empty callbacks, so a payment could be
/// read but never entered. This is that missing form.
///
/// receiptno is deliberately not collected — ws.next_docnumber() assigns it
/// server-side so numbering stays gapless per tenant.
class _WsPaymentFormSheet extends StatefulWidget {
  const _WsPaymentFormSheet();

  @override
  State<_WsPaymentFormSheet> createState() => _WsPaymentFormSheetState();
}

class _WsPaymentFormSheetState extends State<_WsPaymentFormSheet> {
  final _formKey = GlobalKey<FormState>();

  /// ONE identity for this payment, for as long as the form is open.
  ///
  /// Deliberately a field, not a local in _save(): if the first attempt times
  /// out and the user taps Save again, that is a RETRY of the same intended
  /// payment and must carry the same key. A fresh key per attempt is, to the
  /// server, a different payment — which is the duplicate receipt we are
  /// preventing.
  ///
  /// Correcting a field after a permanent failure and saving again also reuses
  /// it, which is correct: nothing was written, so the key is still unused.
  late final String _clientUuid = wsNewUuid();
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _notes = TextEditingController();

  List<WsCustomer> _customers = [];
  int? _customerId;

  /// The chosen customer, held separately from the result list so it survives
  /// searching, empty results and a dismissed picker.
  WsLookupResult? _selectedCustomer;
  String? _customerError;
  WsPaymentMethod _method = WsPaymentMethod.cash;
  DateTime _date = DateTime.now();

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCustomers();
  }

  Future<void> _loadCustomers() async {
    try {
      final c = await WsDataService.fetchCustomers();
      if (!mounted) return;
      setState(() { _customers = c; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = '$e'; });
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// Display name for the selected customer, for the outbox label.
  String _customerName() {
    for (final c in _customers) {
      if (c.customerId == _customerId) return c.customerName;
    }
    return 'customer';
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_customerId == null) {
      setState(() {
        _error = 'Choose a customer.';
        _customerError = 'Choose a customer';
      });
      return;
    }
    setState(() { _saving = true; _error = null; });

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // DURABLE FIRST, then post — the same shape as deliveries and purchases.
      // Offline the payment survives on disk and syncs later instead of being
      // lost behind a red error.
      final storeId = WsStoreService.currentStoreId;
      if (storeId == null) {
        throw StateError('No store selected — cannot record a payment.');
      }

      final outbox = WsOutboxService.instanceOrNull;
      if (outbox != null) {
        final item = await WsOutboxService.recordPayment(
          clientUuid: _clientUuid,
          storeId: storeId,
          customerId: _customerId!,
          // Label only. Built without constructing a fallback WsCustomer —
          // that constructor has several required fields and inventing values
          // for them just to name a queue row is asking for trouble.
          customerName: _customerName(),
          amount: double.parse(_amount.text.trim()),
          paymentDate: _date,
          paymentMethod: _method.name,
          referenceNo: _reference.text.trim().isEmpty ? null : _reference.text.trim(),
          notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        );

        if (!mounted) return;

        // The message must match reality. A queued payment reported in green
        // is how a receipt gets handed over for money the server never saw.
        switch (item.status) {
          case WsOutboxStatus.synced:
            messenger.showSnackBar(const SnackBar(
              content: Text('Payment saved'),
              backgroundColor: WsColors.green));
          case WsOutboxStatus.failed:
            messenger.showSnackBar(SnackBar(
              content: Text('Payment failed — ${item.lastError ?? 'unknown error'}'),
              backgroundColor: WsColors.red,
              duration: const Duration(seconds: 6)));
          case WsOutboxStatus.pending:
          case WsOutboxStatus.syncing:
            messenger.showSnackBar(const SnackBar(
              content: Text('Saved on this device — waiting to sync'),
              backgroundColor: WsColors.amber));
        }
        navigator.pop(true);
        return;
      }

      // Queue unavailable: direct path, still carrying the key.
      await WsDataService.insertPayment(
        clientUuid: _clientUuid,
        storeId: storeId,
        WsPayment(
        paymentId: 0,
        orgId: 0,               // set server-side from the caller's membership
        customerId: _customerId!,
        paymentDate: _date,
        amountReceived: double.parse(_amount.text.trim()),
        paymentMethod: _method,
        referenceNo: _reference.text.trim().isEmpty ? null : _reference.text.trim(),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      ));
      if (!mounted) return;
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e'.replaceFirst('PostgrestException(message: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
        16, 12, 16, MediaQuery.of(context).viewInsets.bottom + 32),
    child: _loading
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()))
        : Form(key: _formKey, child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(child: Container(width: 36, height: 4,
            decoration: BoxDecoration(color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 14),
        const Text('Record Payment',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        // Searchable rather than a dropdown of every customer: the query and
        // its LIMIT both run on the server, so this behaves the same with
        // twelve customers and with four thousand.
        WsLookupField(
          label: 'Customer *',
          icon: Icons.person_search_outlined,
          value: _selectedCustomer,
          search: WsLookupService.customers,
          errorText: _customerError,
          onSelected: (r) => setState(() {
            _selectedCustomer = r;
            _customerId = r.id;
            _customerError = null;
          }),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _amount,
          decoration: const InputDecoration(
              labelText: 'Amount Received *', prefixText: 'Rs '),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          validator: (v) {
            final n = double.tryParse((v ?? '').trim());
            if (n == null) return 'Enter an amount';
            if (n <= 0) return 'Must be more than zero';
            return null;
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<WsPaymentMethod>(
          initialValue: _method,
          decoration: const InputDecoration(labelText: 'Method'),
          items: WsPaymentMethod.values
              .map((m) => DropdownMenuItem(value: m, child: Text(m.label)))
              .toList(),
          onChanged: (v) => setState(() => _method = v ?? WsPaymentMethod.cash),
        ),
        const SizedBox(height: 12),
        InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _date,
              firstDate: DateTime(2015),
              lastDate: DateTime.now(),
            );
            if (picked != null) setState(() => _date = picked);
          },
          child: InputDecorator(
            decoration: const InputDecoration(labelText: 'Payment Date'),
            child: Text(DateFormat('dd MMM yyyy').format(_date)),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _reference,
          decoration: const InputDecoration(
              labelText: 'Reference No (optional)',
              hintText: 'Transaction ID for Easypaisa / bank'),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _notes,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Notes (optional)'),
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
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(height: 18, width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save Payment'),
        )),
      ],
    )),
  );
}