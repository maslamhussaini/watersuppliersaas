// =============================================================================
// lib/screens/customers_screen.dart
// =============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ws_models.dart';
import '../services/supabase_service.dart';
import '../theme/ws_theme.dart';

class WsCustomersScreen extends StatefulWidget {
  const WsCustomersScreen({super.key});
  @override State<WsCustomersScreen> createState() => _WsCustomersScreenState();
}

class _WsCustomersScreenState extends State<WsCustomersScreen> {
  List<WsCustomer> _all = [], _filtered = [];
  String  _search = '';
  String  _filter = 'all';
  bool    _loading = true;
  final   _money = NumberFormat('#,##0', 'en_US');

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await WsDataService.fetchCustomers();
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
        money: _money,
      ),
    );
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
      appBar: AppBar(title: const Text('Customers')),
      body: Column(
        children: [
          // ── Search bar ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))],
              ),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search customers...',
                  prefixIcon: const Icon(Icons.search, color: WsColors.purple),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  suffixIcon: _search.isNotEmpty
                      ? IconButton(icon: const Icon(Icons.clear),
                      onPressed: () { setState(() => _search = ''); _applyFilter(); })
                      : null,
                ),
                onChanged: (v) { _search = v; _applyFilter(); },
              ),
            ),
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
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 72, color: Colors.black12),
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
  final VoidCallback onEdit, onDelete;
  final NumberFormat money;
  const _CustomerDetailSheet({required this.customer, required this.onEdit,
    required this.onDelete, required this.money});

  @override Widget build(BuildContext context) {
    final due = customer.outstandingDue ?? 0;
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
          Row(children: [
            Expanded(child: ElevatedButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit),
                label: const Text('Edit'))),
            const SizedBox(width: 10),
            if (customer.isActive)
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
      await WsDataService.upsertCustomer(c);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: WsColors.red));
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
              value: _selectedArea,
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

class _CardSection extends StatelessWidget {
  final String title;
  const _CardSection(this.title);
  @override Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
    child: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
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
  bool _loading = true;
  final _money = NumberFormat('#,##0', 'en_US');

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() => _loading = true);
    final a = await WsDataService.fetchAreas();
    setState(() { _areas = a; _loading = false; });
  }

  void _showAreaForm([WsArea? existing]) {
    final nameCtl  = TextEditingController(text: existing?.areaName  ?? '');
    final rateCtl  = TextEditingController(text: existing?.ratePerBottle.toStringAsFixed(0) ?? '');
    final daysCtl  = TextEditingController(text: existing?.deliveryDays ?? '');
    final formKey  = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16,
            MediaQuery.of(context).viewInsets.bottom + 32),
        child: Form(key: formKey, child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 14),
            Text(existing == null ? 'Add Area' : 'Edit Area',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            TextFormField(controller: nameCtl,
                decoration: const InputDecoration(labelText: 'Area Name *'),
                validator: (v) => v!.isEmpty ? 'Required' : null),
            const SizedBox(height: 12),
            TextFormField(controller: rateCtl,
                decoration: const InputDecoration(labelText: 'Rate per Bottle (Rs) *', prefixText: 'Rs '),
                keyboardType: TextInputType.number,
                validator: (v) => (double.tryParse(v ?? '') == null) ? 'Enter valid rate' : null),
            const SizedBox(height: 12),
            TextFormField(controller: daysCtl,
                decoration: const InputDecoration(labelText: 'Delivery Days (e.g. Mon,Wed,Fri)')),
            const SizedBox(height: 20),
            SizedBox(width: double.infinity, child: ElevatedButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                await WsDataService.upsertArea(WsArea(
                  areaId: existing?.areaId ?? 0,
                  orgId:  existing?.orgId  ?? 0,
                  areaName:      nameCtl.text.trim(),
                  ratePerBottle: double.parse(rateCtl.text.trim()),
                  deliveryDays:  daysCtl.text.trim().isEmpty ? null : daysCtl.text.trim(),
                ));
                if (context.mounted) { Navigator.pop(context); _load(); }
              },
              child: const Text('Save Area'),
            )),
          ],
        )),
      ),
    );
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
                      for (final item in [
                        ['Total Bottles', '150', WsColors.primary],
                        ['In Stock', '45', WsColors.teal],
                        ['With Custs', '26', WsColors.amber],
                        ['Lost/Dmg', '8', WsColors.red],
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
                      color: WsColors.primaryLight, borderRadius: BorderRadius.circular(10)),
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
                      color: WsColors.primaryLight, borderRadius: BorderRadius.circular(8)),
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

// =============================================================================
// lib/screens/bottle_health_screen.dart
// =============================================================================

class WsBottleHealthScreen extends StatefulWidget {
  const WsBottleHealthScreen({super.key});
  @override State<WsBottleHealthScreen> createState() => _WsBottleHealthScreenState();
}

class _WsBottleHealthScreenState extends State<WsBottleHealthScreen> {
  WsBottleSnapshot? _snap;
  bool _loading = true;

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() => _loading = true);
    final s = await WsDataService.fetchLatestSnapshot();
    setState(() { _snap = s; _loading = false; });
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
    final s = _snap;
    final total  = s?.totalBottles ?? 1;
    final perf   = s?.perfect        ?? 0;
    final clean  = s?.needsCleaning  ?? 0;
    final dmg    = s?.damaged        ?? 0;
    final empty  = s?.emptyReturned  ?? 0;
    final score  = s?.healthScore    ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bottle Health'),
        actions: [
          IconButton(icon: const Icon(Icons.home, color: WsColors.amber), onPressed: () {}),
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
                Text('Based on ${s?.totalBottles ?? 0} total bottles · Last checked 30 April',
                    style: const TextStyle(fontSize: 12, color: WsColors.text3)),
              ],
            )),
          ),

          // ── KPI cards ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: GridView.count(
              crossAxisCount: 2, shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.4,
              children: [
                WsKpiCard(icon: '✅', value: '$perf', label: 'Perfect Condition',
                    trend: '${(perf/total*100).toStringAsFixed(0)}% of stock',
                    accentColor: WsColors.green,
                    onTap: () => _showConditionDetail('✅ Perfect Condition', WsColors.green,
                        'These bottles are in good working condition — filled and cleared for delivery.')),
                WsKpiCard(icon: '🧹', value: '$clean', label: 'Needs Cleaning',
                    trend: 'Schedule wash', accentColor: WsColors.amber,
                    onTap: () => _showConditionDetail('🧹 Needs Cleaning', WsColors.amber,
                        'These $clean bottles require cleaning before refilling. Do not deliver until cleaned.')),
                WsKpiCard(icon: '⚠️', value: '$dmg', label: 'Damaged',
                    trend: 'Write off / repair', accentColor: WsColors.red,
                    onTap: () => _showConditionDetail('⚠️ Damaged', WsColors.red,
                        '$dmg bottles have cracks, leaks, or broken caps. Mark for write-off or send for repair.')),
                WsKpiCard(icon: '📦', value: '$empty', label: 'Empty (Returned)',
                    trend: 'Awaiting refill', accentColor: WsColors.primary,
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

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() => _loading = true);
    final p = await WsDataService.fetchPayments();
    setState(() { _payments = p; _loading = false; });
  }

  List<WsPayment> get _filtered => _methodFilter == null
      ? _payments
      : _payments.where((p) => p.paymentMethod == _methodFilter).toList();

  double get _totalReceived => _filtered.fold(0, (s, p) => s + p.amountReceived);

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
      actions: [
        IconButton(icon: const Icon(Icons.add), onPressed: () {}),
      ],
    ),
    body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── KPIs ──────────────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Row(children: [
          Expanded(child: WsKpiCard(icon: '',
              value: '8,000', label: 'Total Receivable (Rs)', accentColor: WsColors.red)),
          const SizedBox(width: 10),
          Expanded(child: WsKpiCard(icon: '',
              value: '52,640', label: 'Collected This Month', accentColor: WsColors.green)),
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
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text('MARCH 2024', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: WsColors.text3)),
      ),
      Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          itemCount: _filtered.length,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 72, color: Colors.black12),
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
                    '${DateFormat('yyyy-MM-dd').format(p.paymentDate)} · ${p.paymentMethod.label} · by ${p.receivedByName ?? 'Tanveer'}',
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
      onPressed: () {}, child: const Icon(Icons.add),
    ),
  );
}