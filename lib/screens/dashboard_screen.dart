// =============================================================================
// lib/screens/dashboard_screen.dart
// Main shell: bottom navigation + Dashboard tab
// =============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ws_models.dart';
import '../services/supabase_service.dart';
import '../services/auth_service.dart';
import '../theme/ws_responsive.dart';
import '../theme/ws_theme.dart';
import 'customers_screen.dart';
import 'delivery_screen.dart';
import 'master_data_screens.dart';
import 'account_screen.dart';
import 'store_picker.dart';
import 'whats_new_screen.dart';
import 'sync_screen.dart';
import 'reports_screen.dart';

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
    WsReportsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: _tabs),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        // Six items exceed BottomNavigationBar's shifting-by-default threshold
        // of three; without this the labels of unselected tabs disappear and
        // the icons jump around on every tap.
        type: BottomNavigationBarType.fixed,
        selectedFontSize: 11,
        unselectedFontSize: 11,
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
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart_outlined),
              activeIcon: Icon(Icons.bar_chart), label: 'Reports'),
        ],
      ),
      // Gated on delivery.manage. RLS rejects the write regardless, so this is
      // about not offering an action that can only end in an error — an
      // accountant or read-only user has no business seeing this button.
      floatingActionButton:
          (_tab == 0 && AuthService.permissions.canRecordDelivery)
              ? FloatingActionButton.extended(
                  // The shell holds the tabs; the home tab owns _load(), so
                  // refreshing from here would need a key or a listenable.
                  // Left as a plain push rather than reaching across state.
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const WsDeliveryScreen()),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('New Delivery'),
                )
              : null,
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
  WsOrganization? _org;
  WsInternalUser? _me;
  String? _error;
  List<WsDelivery>  _recent = [];
  bool _loading = true;
  final _money = NumberFormat('#,##0', 'en_US');

  @override
  void initState() {
    super.initState();
    _load();

    // After the first frame, so there is a Navigator to push onto and the
    // dashboard is already drawn behind it — landing straight on release notes
    // with nothing underneath reads like an error screen.
    //
    // Shows nothing on a fresh install and nothing when the version has not
    // changed; see WsWhatsNew.unseen().
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) wsShowWhatsNewIfNeeded(context);
    });
  }

  /// Time-of-day greeting. The old one said "Good morning," at every hour.
  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning,';
    if (h < 17) return 'Good afternoon,';
    return 'Good evening,';
  }

  String _displayName() {
    final name = _me?.fullName.trim() ?? '';
    if (name.isNotEmpty) return name;
    final email = AuthService.currentUser?.email ?? '';
    if (email.contains('@')) return email.split('@').first;
    return 'there';
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final stats  = await WsDataService.fetchDashboardStats();
      final recent = await WsDataService.fetchDeliveries();
      final org    = await WsDataService.fetchOrg();
      // Who is signed in. ws_tblinternalusers.fullname is the staff profile for
      // this auth user in this organization.
      final me     = await WsDataService.fetchCurrentInternalUser();
      if (!mounted) return;
      setState(() {
        _stats  = stats;
        _recent = recent.take(5).toList();
        _org    = org;
        _me     = me;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Was a bare `catch (_)` that left the screen blank with no explanation —
      // indistinguishable from "you have no data yet".
      setState(() { _loading = false; _error = '$e'; });
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
        centerTitle: false,
        flexibleSpace: const WsGradientBar(),
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.water_drop, color: Colors.white),
            SizedBox(width: 8),
            Text('WaterFlow', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          // Which branch you are working in. Renders nothing at all for a
          // single-branch organization, which is most of them.
          WsStorePicker(onChanged: _load),
          // Queue state, next: if a delivery has not reached the server the
          // user needs to know before anything else on this bar matters.
          // Renders nothing when there is nothing waiting.
          const WsSyncBadge(),
          // Was a bare sign-out icon. Sign out now lives inside the account
          // menu, next to who you are and what plan you are on — which is
          // where a user looks for it.
          WsAccountButton(
            me: _me,
            org: _org,
            onChanged: _load,
          ),
          // Products, bottle types, prices, vendors, purchases, vendor
          // payments, staff, routes and customer groups. Nine tables that had
          // no way in from the app until now.
          IconButton(
              tooltip: 'Setup',
              icon: const Icon(Icons.settings_outlined),
              // AWAITED, then reload. The organization can be renamed in
              // there, and this header shows its name — without the await the
              // dashboard keeps the old one until the app restarts.
              onPressed: () async {
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const WsSetupScreen()));
                if (!mounted) return;
                _load();
              }),
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
                Text(_greeting(),
                    style: const TextStyle(color: WsColors.text2, fontSize: 13)),
                // Was the literal string 'Tanveer Ahmed' — a demo name shown to
                // every user of every tenant. Reads ws_tblinternalusers.fullname
                // for the signed-in account, falling back to the email local
                // part while that row loads.
                Text('${_displayName()} 👋',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                // Was hardcoded to "Kent Water" — one tenant's name shown to
                // every tenant, in a multi-tenant product.
                Text(
                  '${_org?.displayName ?? 'Loading…'} · '
                  '${DateFormat('dd MMM yyyy').format(DateTime.now())}',
                  style: const TextStyle(fontSize: 11, color: WsColors.text3),
                ),
              ]),
            ),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: WsColors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: WsColors.red.withValues(alpha: 0.4)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.error_outline, color: WsColors.red, size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Could not load dashboard: $_error',
                        style: const TextStyle(fontSize: 12, color: WsColors.red))),
                  ]),
                ),
              ),

            // vw_ws_reconciliation compares the journal against the customer and
            // vendor ledgers. It must always be empty. Because entries post in
            // the same transaction as the document, a non-zero count means a
            // posting rule is wrong — not that a background job is behind — so
            // it belongs in front of whoever runs the business, not in a log.
            if ((_stats?.reconciliationIssues ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: WsColors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: WsColors.amber),
                  ),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_rounded, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Accounts do not reconcile (${_stats!.reconciliationIssues} '
                        'discrepancy${_stats!.reconciliationIssues == 1 ? '' : 'ies'}). '
                        'Ledger totals and the journal disagree — treat reports as '
                        'unreliable until this is resolved.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ]),
                ),
              ),

            const WsSectionHeader('Performance Overview'),

            // ── KPI Grid ──────────────────────────────────────────────
            Padding(
              padding: WsBreakpoints.pagePadding(context),
              child: _stats == null ? const SizedBox() : GridView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                // GridView.count cannot express a fixed row height — it only
                // takes childAspectRatio — so this uses the delegate directly.
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  // Columns follow the window: 2 on a phone, 3 on a tablet,
                  // 4 on a desktop. Two columns left most of a desktop empty.
                  crossAxisCount: WsBreakpoints.gridColumns(context),
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  // A FIXED height, not childAspectRatio. Aspect ratio ties
                  // the card's height to its width, so every window resize
                  // changes the space the text has — which is what overflowed
                  // it by 13 px. The content needs about 120; 140 leaves room
                  // for a larger system font scale.
                  // Sized from the card, not from a number typed here. A literal
                  // is how the previous 140 stayed behind when the card grew,
                  // and the text-scale factor keeps it honest for users who
                  // have enlarged the system font.
                  mainAxisExtent: WsStatCard.preferredHeight *
                      MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.5),
                ),
                children: [
                  WsStatCard(
                    icon: Icons.water_drop_outlined, value: '${_stats!.bottlesInHand}',
                    title: 'Bottles In Hand (with customers)',
                    // Was '↑ 3 this week' — a hardcoded literal, not a
                    // measurement. Nothing computes week-over-week change, so
                    // there is nothing honest to put here.
                    footnote: 'With customers now',
                    color: WsColors.primary,
                    onTap: () => _showKpiDetail('🫙 Bottles In Hand',
                        _BottlesInHandDetail(count: _stats!.bottlesInHand)),
                  ),
                  WsStatCard(
                    icon: Icons.local_shipping_outlined, value: '${_stats!.bottlesDeliveredMonth}',
                    title: 'Bottles Delivered (this month)',
                    footnote: 'This month', color: WsColors.green,
                    onTap: () => _showKpiDetail('🚛 Delivered This Month',
                        _DeliveredDetail(deliveries: _recent)),
                  ),
                  WsStatCard(
                    icon: Icons.inbox_outlined, value: '${_stats!.emptyBottlesReturned}',
                    title: 'Empty Bottles Returned',
                    footnote: 'Awaiting refill', color: WsColors.amber,
                    onTap: () => _showKpiDetail('📦 Empty Bottles',
                        const _EmptyBottlesDetail()),
                  ),
                  // A NEGATIVE stock figure is not a rendering fault — it is
                  // the truth about the data. vw_ws_bottleposition computes
                  // instock as (bottles bought into stock − bottles now with
                  // customers), so −3 means three bottles were delivered that
                  // were never recorded as purchased. Labelling that "Ready to
                  // deliver" in calm teal would hide a real bookkeeping gap,
                  // so it reads red and says what to do about it.
                  WsStatCard(
                    icon: Icons.opacity, value: '${_stats!.filledInStock}',
                    title: 'Filled Bottles In Stock',
                    footnote: _stats!.filledInStock < 0
                        ? 'Record your purchases'
                        : 'Ready to deliver',
                    color: _stats!.filledInStock < 0
                        ? WsColors.red
                        : WsColors.teal,
                    onTap: () => _showKpiDetail('💧 Filled In Stock',
                        _FilledDetail(inStock: _stats!.filledInStock)),
                  ),
                  WsStatCard(
                    icon: Icons.account_balance_wallet_outlined,
                    value: 'Rs ${_money.format(_stats!.totalReceivable)}',
                    title: 'Payment Receivable',
                    footnote: '${_stats!.totalCustomers} customers',
                    color: WsColors.red,
                    onTap: () => _showKpiDetail('💰 Payment Receivable',
                        const _ReceivableDetail()),
                  ),
                  WsStatCard(
                    icon: Icons.search, value: '${_stats!.bottlesNeedAttention}',
                    title: 'Bottles Need Attention',
                    footnote: 'Tap to inspect', color: WsColors.purple,
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
  final int inStock;
  const _FilledDetail({required this.inStock});

  @override Widget build(BuildContext context) => Text(
      inStock < 0
          // The old copy said "update the count from the Bottles tab", which
          // does not exist as an action: stock is derived from the bottle
          // ledger, never typed in. Purchases are what move it.
          ? 'This is negative because ${-inStock} more bottle'
              '${inStock == -1 ? ' has' : 's have'} been delivered to '
              'customers than were ever recorded as purchased into stock.\n\n'
              'Stock is not a number you type in — it is derived from the '
              'bottle ledger. Record the purchases under Setup › Purchases '
              'and this corrects itself.'
          : 'Filled bottles held in stock and ready to deliver.\n\n'
              'This is derived from the bottle ledger: bottles purchased into '
              'stock, less bottles currently out with customers.',
      style: const TextStyle(color: WsColors.text2, height: 1.6));
}

class _ReceivableDetail extends StatelessWidget {
  const _ReceivableDetail();
  @override Widget build(BuildContext context) => const Text(
      'Total outstanding amount owed by all active customers. '
      'Go to the Payments tab for individual breakdowns.',
      style: TextStyle(color: WsColors.text2, height: 1.6));
}