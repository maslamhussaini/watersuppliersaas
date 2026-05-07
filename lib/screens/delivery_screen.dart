// =============================================================================
// lib/screens/delivery_screen.dart
// =============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ws_models.dart';
import '../services/supabase_service.dart';
import '../theme/ws_theme.dart';
import '../main.dart';

class WsDeliveryScreen extends StatefulWidget {
  final WsCustomer? preselectedCustomer;
  const WsDeliveryScreen({super.key, this.preselectedCustomer});
  @override State<WsDeliveryScreen> createState() => _WsDeliveryScreenState();
}

class _WsDeliveryScreenState extends State<WsDeliveryScreen> {
  final _form       = GlobalKey<FormState>();
  final _delivered  = TextEditingController(text: '0');
  final _returned   = TextEditingController(text: '0');
  final _payment    = TextEditingController(text: '0');
  final _notes      = TextEditingController();

  List<WsCustomer>      _customers = [];
  List<WsInternalUser>  _staff     = [];
  WsCustomer?           _selCustomer;
  WsInternalUser?       _selStaff;
  WsPaymentMethod       _payMethod = WsPaymentMethod.cash;
  DateTime              _date      = DateTime.now();
  bool                  _loading   = false;

  int  get _deliveredInt => int.tryParse(_delivered.text) ?? 0;
  int  get _returnedInt  => int.tryParse(_returned.text)  ?? 0;
  int  get _newBalance   => (_selCustomer?.bottleBalance ?? 0) + _deliveredInt - _returnedInt;
  double get _rate       => _selCustomer?.effectiveRate ?? 0;
  double get _charged    => _deliveredInt * _rate;

  @override void initState() {
    super.initState();
    _load();
    _delivered.addListener(() => setState(() {}));
    _returned.addListener(()  => setState(() {}));
  }

  Future<void> _load() async {
    final custs = await WsDataService.fetchCustomers();
    setState(() {
      _customers   = custs;
      _selCustomer = widget.preselectedCustomer ??
          (custs.isNotEmpty ? custs.first : null);
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _selCustomer == null) return;
    setState(() => _loading = true);
    try {
      final delivery = WsDelivery(
        deliveryId:       0,
        orgId:            _selCustomer!.orgId,
        customerId:       _selCustomer!.customerId,
        deliveredById:    _selStaff?.internalUserId,
        deliveryDate:     _date,
        bottlesDelivered: _deliveredInt,
        bottlesReturned:  _returnedInt,
        bottleBalance:    _newBalance,  // trigger will recompute
        rateApplied:      _rate,
        amountCharged:    _charged,
        notes:            _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      );
      await WsDataService.insertDelivery(delivery);

      // Optional inline payment
      final payAmt = double.tryParse(_payment.text) ?? 0;
      if (payAmt > 0) {
        await WsDataService.insertPayment(WsPayment(
          paymentId:      0,
          orgId:          _selCustomer!.orgId,
          customerId:     _selCustomer!.customerId,
          receivedById:   _selStaff?.internalUserId,
          paymentDate:    _date,
          amountReceived: payAmt,
          paymentMethod:  _payMethod,
        ));
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Delivery saved'), backgroundColor: WsColors.green),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: WsColors.red),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _autoCard() => Container(
    margin: const EdgeInsets.only(top: 4),
    decoration: BoxDecoration(
      color: WsColors.primaryLight,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: WsColors.primary.withOpacity(.3)),
    ),
    padding: const EdgeInsets.all(12),
    child: Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Bottle Balance (auto)', style: TextStyle(color: WsColors.primaryDark, fontSize: 12)),
        Text('${_selCustomer?.bottleBalance ?? 0} → $_newBalance',
            style: const TextStyle(fontWeight: FontWeight.w700, color: WsColors.primaryDark, fontSize: 16)),
      ]),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Amount Charged (auto)', style: TextStyle(color: WsColors.primaryDark, fontSize: 12)),
        Text('Rs ${NumberFormat('#,##0').format(_charged)}',
            style: const TextStyle(fontWeight: FontWeight.w700, color: WsColors.primaryDark, fontSize: 16)),
      ]),
    ]),
  );

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
        title: const Text('Record Delivery'),
    ),
    body: Form(
      key: _form,
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 40), children: [
        // ── Customer & Date ──────────────────────────────────────────────
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          const Text('Customer & Date', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text('Customer', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          if (_customers.isNotEmpty)
            DropdownButtonFormField<WsCustomer>(
              value: _selCustomer,
              decoration: const InputDecoration(hintText: 'Select customer'),
              items: _customers.map((c) => DropdownMenuItem(
                  value: c, child: Text('${c.customerName} — ${c.areaName ?? 'Unknown'}'))).toList(),
              onChanged: (c) => setState(() => _selCustomer = c),
            ),
          const SizedBox(height: 16),
          const Text('Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          InkWell(
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2020),
                lastDate: DateTime.now(),
              );
              if (d != null) setState(() => _date = d);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(DateFormat('dd/MM/yyyy').format(_date), style: const TextStyle(fontSize: 16)),
                  const Icon(Icons.calendar_today, size: 20, color: WsColors.text2),
                ],
              ),
            ),
          ),
          // Need to add Delivered By since it's in the screenshot
          const SizedBox(height: 16),
          const Text('Delivered By', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: 'Tanveer Ahmed (Admin)',
            decoration: const InputDecoration(hintText: 'Select staff'),
            items: const [DropdownMenuItem(value: 'Tanveer Ahmed (Admin)', child: Text('Tanveer Ahmed (Admin)'))],
            onChanged: (v) {},
          ),
        ]))),

        // ── Bottle Movement ───────────────────────────────────────────────
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          const Text('Bottle Movement', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          const Text('🚛 Bottles Delivered (Full → Customer)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          TextFormField(
            controller: _delivered,
            decoration: const InputDecoration(hintText: '0'),
            keyboardType: TextInputType.number,
            validator: (v) => int.tryParse(v ?? '') == null ? 'Enter a number' : null,
          ),
          const SizedBox(height: 16),
          const Text('📦 Bottles Returned (Empty ← Customer)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          TextFormField(
            controller: _returned,
            decoration: const InputDecoration(hintText: '0'),
            keyboardType: TextInputType.number,
            validator: (v) => int.tryParse(v ?? '') == null ? 'Enter a number' : null,
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFE1F5FE),
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Bottle Balance (auto)', style: TextStyle(color: WsColors.primaryDark, fontSize: 13, fontWeight: FontWeight.w500)),
                Text('${_selCustomer?.bottleBalance ?? 0} → $_newBalance',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: WsColors.primaryDark, fontSize: 16)),
              ]),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Amount Charged (auto)', style: TextStyle(color: WsColors.primaryDark, fontSize: 13, fontWeight: FontWeight.w500)),
                Text('Rs ${NumberFormat('#,##0').format(_charged)}',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: WsColors.primaryDark, fontSize: 16)),
              ]),
            ]),
          ),
        ]))),

        // ── Optional Payment ──────────────────────────────────────────────
        Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Payment (optional)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _payment,
              decoration: const InputDecoration(
                  labelText: 'Amount Received', prefixText: 'Rs '),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<WsPaymentMethod>(
              value: _payMethod,
              decoration: const InputDecoration(labelText: 'Payment Method'),
              items: WsPaymentMethod.values.map((m) => DropdownMenuItem(
                  value: m, child: Text('${m.emoji} ${m.label}'))).toList(),
              onChanged: (m) => setState(() => _payMethod = m!),
            ),
          ],
        ))),

        // ── Notes ─────────────────────────────────────────────────────────
        Card(child: Padding(padding: const EdgeInsets.all(14), child:
          TextFormField(
            controller: _notes,
            decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                prefixIcon: Icon(Icons.note_outlined)),
            maxLines: 2,
          ),
        )),

        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _loading ? null : _save,
          child: _loading
              ? const SizedBox(height: 20, width: 20,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('Save Delivery ✓'),
        ),
      ]),
    ),
  );
}

