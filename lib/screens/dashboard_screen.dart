// =============================================================================
// lib/screens/dashboard_screen.dart
// Main shell: bottom navigation + Dashboard tab
// =============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ws_models.dart';
import '../services/supabase_service.dart';
import '../services/auth_service.dart';
import '../theme/ws_theme.dart';
import 'customers_screen.dart';
import 'delivery_screen.dart';

class WsDashboardScreen extends StatefulWidget {
  const WsDashboardScreen({super.key});
  @override State<WsDashboardScreen> createState() => _WsDashboardScreenState();
}

class _WsDashboardScreenState extends State<WsDashboardScreen> {
  int _tab = 0;

  final _tabs = const [
    _DashboardTab(),
    WsCustomersScreen(),
    WsAreasScreen(),
    WsBottleHealthScreen(),
    WsPaymentsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: _tabs),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.people_outline),
              activeIcon: Icon(Icons.people), label: 'Customers'),
          BottomNavigationBarItem(icon: Icon(Icons.map_outlined),
              activeIcon: Icon(Icons.map), label: 'Areas'),
          BottomNavigationBarItem(icon: Icon(Icons.water_drop_outlined),
              activeIcon: Icon(Icons.water_drop), label: 'Bottles'),
          BottomNavigationBarItem(icon: Icon(Icons.payment_outlined),
              activeIcon: Icon(Icons.payment), label: 'Payments'),
        ],
      ),
      floatingActionButton: _tab == 0 ? FloatingActionButton.extended(
        onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const WsDeliveryScreen())),
        icon: const Icon(Icons.add),
        label: const Text('New Delivery'),
      ) : null,
    );
  }
}

// ─── Dashboard Tab ─────────────────────────────────────────────────────────────

class _DashboardTab extends StatefulWidget {
  const _DashboardTab();
  @override State<_DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<_DashboardTab> {
  WsDashboardStats? _stats;
  List<WsDelivery>  _recent = [];
  bool _loading = true;
  final _money = NumberFormat('#,##0', 'en_US');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final stats  = await WsDataService.fetchDashboardStats();
      final recent = await WsDataService.fetchDeliveries();
      setState(() {
        _stats  = stats;
        _recent = recent.take(5).toList();
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _showKpiDetail(String title, Widget child) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: .55,
        maxChildSize: .9,
        minChildSize: .3,
        expand: false,
        builder: (_, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Center(child: Container(
                width: 36, height: 4,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.water_drop, color: Colors.white),
            SizedBox(width: 8),
            Text('WaterFlow', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.notifications, color: WsColors.amberLight), onPressed: () {}),
          IconButton(icon: const Icon(Icons.person, color: WsColors.purple),
              onPressed: () async { await AuthService.signOut(); }),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 100),
          children: [
            // ── Greeting ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Good morning,',
                    style: TextStyle(color: WsColors.text2, fontSize: 13)),
                const Text('Tanveer Ahmed 👋',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                Text('Kent Water · ${DateFormat('dd MMM yyyy').format(DateTime.now())}',
                    style: const TextStyle(fontSize: 11, color: WsColors.text3)),
              ]),
            ),

            const WsSectionHeader('Performance Overview'),

            // ── KPI Grid ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _stats == null ? const SizedBox() : GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.4,
                children: [
                  WsKpiCard(
                    icon: '🫙', value: '${_stats!.bottlesInHand}',
                    label: 'Bottles In Hand (with customers)',
                    trend: '↑ 3 this week', accentColor: WsColors.primary,
                    onTap: () => _showKpiDetail('🫙 Bottles In Hand',
                        _BottlesInHandDetail(count: _stats!.bottlesInHand)),
                  ),
                  WsKpiCard(
                    icon: '🚛', value: '${_stats!.bottlesDeliveredMonth}',
                    label: 'Bottles Delivered (this month)',
                    trend: 'This month', accentColor: WsColors.green,
                    onTap: () => _showKpiDetail('🚛 Delivered This Month',
                        _DeliveredDetail(deliveries: _recent)),
                  ),
                  WsKpiCard(
                    icon: '📦', value: '${_stats!.emptyBottlesReturned}',
                    label: 'Empty Bottles Returned',
                    trend: 'Awaiting refill', accentColor: WsColors.amber,
                    onTap: () => _showKpiDetail('📦 Empty Bottles',
                        const _EmptyBottlesDetail()),
                  ),
                  WsKpiCard(
                    icon: '💧', value: '${_stats!.filledInStock}',
                    label: 'Filled Bottles In Stock',
                    trend: 'Ready to deliver', accentColor: WsColors.teal,
                    onTap: () => _showKpiDetail('💧 Filled In Stock',
                        const _FilledDetail()),
                  ),
                  WsKpiCard(
                    icon: '💰',
                    value: 'Rs ${_money.format(_stats!.totalReceivable)}',
                    label: 'Payment Receivable',
                    trend: '${_stats!.totalCustomers} customers',
                    accentColor: WsColors.red,
                    onTap: () => _showKpiDetail('💰 Payment Receivable',
                        const _ReceivableDetail()),
                  ),
                  WsKpiCard(
                    icon: '🔍', value: '${_stats!.bottlesNeedAttention}',
                    label: 'Bottles Need Attention',
                    trend: 'Tap to inspect', accentColor: WsColors.purple,
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const WsBottleHealthScreen())),
                  ),
                ],
              ),
            ),

            const WsSectionHeader('Recent Deliveries'),

            ..._recent.map((d) => ListTile(
              leading: CircleAvatar(
                backgroundColor: WsColors.primary,
                child: Text((d.customerName ?? '?')[0],
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              title: Text(d.customerName ?? 'Customer #${d.customerId}'),
              subtitle: Text(
                  '${d.bottlesDelivered} delivered · ${d.bottlesReturned} returned · ${DateFormat('dd MMM').format(d.deliveryDate)}'),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Rs ${_money.format(d.amountCharged)}',
                      style: const TextStyle(fontWeight: FontWeight.w700, color: WsColors.red)),
                  WsBadge(label: 'Charged',
                      bg: WsColors.redLight, fg: WsColors.red),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }
}

// ─── KPI Detail Widgets (shown in bottom sheet) ───────────────────────────────

class _BottlesInHandDetail extends StatelessWidget {
  final int count;
  const _BottlesInHandDetail({required this.count});
  @override Widget build(BuildContext context) => Column(
    children: [
      Text('$count bottles currently with customers',
          style: const TextStyle(color: WsColors.text2)),
      const SizedBox(height: 14),
      const Text('Tap Customers tab to see per-customer breakdown.',
          style: TextStyle(fontSize: 12, color: WsColors.text3)),
    ],
  );
}

class _DeliveredDetail extends StatelessWidget {
  final List<WsDelivery> deliveries;
  const _DeliveredDetail({required this.deliveries});
  @override Widget build(BuildContext context) => Column(
    children: deliveries.map((d) => ListTile(
      dense: true,
      title: Text(d.customerName ?? '—'),
      subtitle: Text(DateFormat('dd MMM yyyy').format(d.deliveryDate)),
      trailing: Text('${d.bottlesDelivered} btl',
          style: const TextStyle(fontWeight: FontWeight.w600, color: WsColors.primary)),
    )).toList(),
  );
}

class _EmptyBottlesDetail extends StatelessWidget {
  const _EmptyBottlesDetail();
  @override Widget build(BuildContext context) => const Text(
      'Empty bottles are those returned by customers and awaiting refill. '
      'Go to the Bottles tab to manage their condition.',
      style: TextStyle(color: WsColors.text2, height: 1.6));
}

class _FilledDetail extends StatelessWidget {
  const _FilledDetail();
  @override Widget build(BuildContext context) => const Text(
      'Filled bottles are in stock and ready to deliver. '
      'Update the count from the Bottles tab after each refill batch.',
      style: TextStyle(color: WsColors.text2, height: 1.6));
}

class _ReceivableDetail extends StatelessWidget {
  const _ReceivableDetail();
  @override Widget build(BuildContext context) => const Text(
      'Total outstanding amount owed by all active customers. '
      'Go to the Payments tab for individual breakdowns.',
      style: TextStyle(color: WsColors.text2, height: 1.6));
}