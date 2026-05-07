import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ws_models.dart';
import '../services/supabase_service.dart';
import '../services/auth_service.dart';
import '../theme/ws_theme.dart';
import '../main.dart';

class WsCustomerPortalScreen extends StatefulWidget {
  const WsCustomerPortalScreen({super.key});
  @override State<WsCustomerPortalScreen> createState() => _WsCustomerPortalScreenState();
}

class _WsCustomerPortalScreenState extends State<WsCustomerPortalScreen> {
  WsCustomer?      _customer;
  List<WsDelivery> _deliveries = [];
  List<WsPayment>  _payments   = [];
  bool _loading = true;
  final _money = NumberFormat('#,##0', 'en_US');

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Fetch customer row linked to current auth user
      final uid = AuthService.currentUser!.id;
      final row = await supabase
          .from('ws_tblCustomers')
          .select('*, ws_tblAreas(AreaName, RatePerBottle)')
          .eq('AuthUserID', uid)
          .maybeSingle();

      if (row == null) { setState(() => _loading = false); return; }
      final c = WsCustomer.fromJson({...row, ...?row['ws_tblAreas'] as Map?});

      final dels = await WsDataService.fetchDeliveries(customerId: c.customerId);
      final pays = await WsDataService.fetchPayments(customerId:  c.customerId);

      double totalCharged  = dels.fold(0, (s, d) => s + d.amountCharged);
      double totalReceived = pays.fold(0, (s, p) => s + p.amountReceived);

      setState(() {
        _customer   = WsCustomer(
          customerId:    c.customerId,
          orgId:         c.orgId,
          areaId:        c.areaId,
          customerName:  c.customerName,
          address:       c.address,
          phone:         c.phone,
          rateOverride:  c.rateOverride,
          depositAmount: c.depositAmount,
          bottleBalance: c.bottleBalance,
          isActive:      c.isActive,
          createdDate:   c.createdDate,
          areaName:      c.areaName,
          areaRate:      c.areaRate,
          outstandingDue:totalCharged - totalReceived,
        );
        _deliveries = dels;
        _payments   = pays;
        _loading    = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _showDetail(String title, Widget child) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: .6, maxChildSize: .9, minChildSize: .3, expand: false,
        builder: (_, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Center(child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  @override Widget build(BuildContext context) {
    final c   = _customer;
    final due = c?.outstandingDue ?? 0;
    final totalPaid = _payments.fold(0.0, (s, p) => s + p.amountReceived);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Account'),
        actions: [
          IconButton(icon: const Icon(Icons.notifications, color: WsColors.amberLight), onPressed: () {}),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : c == null
          ? const Center(child: Text('Account not found.\nContact your supplier.',
          textAlign: TextAlign.center))
          : RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 20),
          children: [
            // ── Profile card ─────────────────────────────────────────
            Card(
              margin: const EdgeInsets.fromLTRB(14, 14, 14, 6),
              child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: WsColors.primary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(child: Text(c.customerName[0],
                      style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700))),
                ),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.customerName,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text('${c.areaName ?? '—'} · Rs ${c.effectiveRate.toStringAsFixed(0)}/bottle',
                      style: const TextStyle(color: WsColors.text2, fontSize: 13)),
                  const SizedBox(height: 8),
                  WsBadge(
                      label: due > 0 ? 'Rs ${_money.format(due)} Due' : 'Settled',
                      bg: due > 0 ? WsColors.redLight.withOpacity(0.5)  : WsColors.greenLight,
                      fg: due > 0 ? WsColors.red       : WsColors.green),
                ])),
              ])),
            ),

            const WsSectionHeader('My Summary'),

            // ── Customer KPI cards ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Expanded(
                    child: WsKpiCard(
                      icon: '💧', value: '${c.bottleBalance}',
                      label: 'Filled Bottles With Me',
                      trend: 'Tap for history', accentColor: WsColors.teal,
                      onTap: () => _showDetail('💧 Delivery History',
                          _DeliveryHistoryDetail(deliveries: _deliveries, money: _money)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: WsKpiCard(
                      icon: '📦', value: '${c.bottleBalance > 0 ? c.bottleBalance : 0}',
                      label: 'Empty Bottles To Return',
                      trend: 'Please return', accentColor: WsColors.amber,
                      onTap: () => _showDetail('📦 Bottles Status',
                          _BottleStatusDetail(balance: c.bottleBalance)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            
            // Full width cards
            _buildFullWidthCard(
              context: context,
              icon: '💰',
              value: 'Rs ${_money.format(due.abs())}',
              label: 'Total Payable Amount',
              trend: '',
              accentColor: due > 0 ? WsColors.red : WsColors.green,
              onTap: () => _showDetail('💰 My Balance',
                  _BalanceDetail(deliveries: _deliveries, totalDue: due, money: _money)),
            ),
            
            const SizedBox(height: 10),
            _buildFullWidthCard(
              context: context,
              icon: '📋',
              value: '${_payments.length}',
              label: 'Payments Made - Rs ${_money.format(totalPaid)} Total',
              trend: 'View full history',
              accentColor: WsColors.purple,
              onTap: () => _showDetail('📋 Payment History',
                  _PaymentHistoryDetail(payments: _payments, money: _money)),
            ),

            const WsSectionHeader('Recent Deliveries'),

            ..._deliveries.take(5).map((d) => ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: const CircleAvatar(
                  radius: 24,
                  backgroundColor: WsColors.teal,
                  child: Text('🚛', style: TextStyle(fontSize: 20, inherit: false))),
              title: Text(DateFormat('d MMMM yyyy').format(d.deliveryDate), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    '+${d.bottlesDelivered} delivered · ${d.bottlesReturned} returned · Balance: ${d.bottleBalance}',
                    style: const TextStyle(fontSize: 12, color: WsColors.text3)),
              ),
              trailing: Text('Rs ${_money.format(d.amountCharged)}',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: WsColors.red, fontSize: 16)),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildFullWidthCard({
    required BuildContext context,
    required String icon,
    required String value,
    required String label,
    required String trend,
    required Color accentColor,
    VoidCallback? onTap,
  }) {
    final card = Card(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: 20,
            top: 20,
            bottom: 20,
            child: Opacity(
              opacity: 0.1,
              child: Text(icon, style: const TextStyle(fontSize: 60)),
            ),
          ),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: accentColor),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(icon, style: const TextStyle(fontSize: 24)),
                        const SizedBox(height: 8),
                        Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: accentColor)),
                        const SizedBox(height: 4),
                        Text(label, style: const TextStyle(fontSize: 12, color: WsColors.text3)),
                        if (trend.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(trend, style: TextStyle(fontSize: 12, color: accentColor, fontWeight: FontWeight.w600)),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return onTap != null ? InkWell(onTap: onTap, child: card) : card;
  }
}

// ─── Customer Portal Detail Widgets ──────────────────────────────────────────

class _DeliveryHistoryDetail extends StatelessWidget {
  final List<WsDelivery> deliveries;
  final NumberFormat money;
  const _DeliveryHistoryDetail({required this.deliveries, required this.money});

  @override Widget build(BuildContext context) => Column(
    children: deliveries.map((d) => ListTile(
      dense: true,
      title: Text(DateFormat('dd MMM yyyy').format(d.deliveryDate)),
      subtitle: Text('+${d.bottlesDelivered} del · ${d.bottlesReturned} ret · Bal: ${d.bottleBalance}'),
      trailing: Text('Rs ${money.format(d.amountCharged)}',
          style: const TextStyle(fontWeight: FontWeight.w600, color: WsColors.primary)),
    )).toList(),
  );
}

class _BottleStatusDetail extends StatelessWidget {
  final int balance;
  const _BottleStatusDetail({required this.balance});
  @override Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ListTile(dense: true, leading: const Text('💧'),
          title: const Text('Filled bottles with you'), trailing: Text('$balance')),
      if (balance > 0)
        Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: WsColors.amberLight, borderRadius: BorderRadius.circular(10)),
          child: const Text('Please return empty bottles on your next delivery visit.',
              style: TextStyle(color: WsColors.amber, fontSize: 13)),
        ),
    ],
  );
}

class _BalanceDetail extends StatelessWidget {
  final List<WsDelivery> deliveries;
  final double totalDue;
  final NumberFormat money;
  const _BalanceDetail({required this.deliveries, required this.totalDue, required this.money});
  @override Widget build(BuildContext context) => Column(children: [
    Center(child: Column(children: [
      Text('Rs ${money.format(totalDue.abs())}',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700,
              color: totalDue > 0 ? WsColors.red : WsColors.green)),
      Text(totalDue > 0 ? 'Outstanding due' : 'Fully settled',
          style: const TextStyle(color: WsColors.text2)),
    ])),
    const Divider(height: 24),
    ...deliveries.where((d) => d.amountCharged > 0).map((d) => ListTile(
      dense: true,
      title: Text(DateFormat('dd MMM').format(d.deliveryDate)),
      subtitle: Text('${d.bottlesDelivered} bottles × Rs ${d.rateApplied.toStringAsFixed(0)}'),
      trailing: Text('Rs ${money.format(d.amountCharged)}',
          style: const TextStyle(fontWeight: FontWeight.w600, color: WsColors.red)),
    )),
  ]);
}

class _PaymentHistoryDetail extends StatelessWidget {
  final List<WsPayment> payments;
  final NumberFormat money;
  const _PaymentHistoryDetail({required this.payments, required this.money});
  @override Widget build(BuildContext context) => Column(
    children: [
      ...payments.map((p) => ListTile(
        dense: true,
        leading: Text(p.paymentMethod.emoji,
            style: const TextStyle(fontSize: 22, inherit: false)),
        title: Text(DateFormat('dd MMM yyyy').format(p.paymentDate)),
        subtitle: Text('${p.paymentMethod.label} · ${p.referenceNo ?? '—'}'),
        trailing: Text('+Rs ${money.format(p.amountReceived)}',
            style: const TextStyle(fontWeight: FontWeight.w600, color: WsColors.green)),
      )),
    ],
  );
}
