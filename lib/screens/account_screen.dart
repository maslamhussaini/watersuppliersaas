// =============================================================================
// lib/screens/account_screen.dart
// The account menu behind the avatar, plus the profile and plan screens.
//
// Modelled on OrderMate's account popover: who you are, which organization and
// store you are in, your subscription, an upgrade call to action, and sign
// out — all reachable from one tap on the app bar.
//
// WHAT IS REAL AND WHAT IS NOT
//
// The plan shown here is REAL. ws_tblplans and ws_tblsubscriptions were
// created by migration 002 and had simply never been read by the app, so
// every organization has been sitting on a plan with real limits
// (maxcustomers, maxusers, feature flags) that nobody could see.
//
// The UPGRADE button is NOT real. There is no payment provider, so it opens a
// comparison sheet and says plainly that upgrading is a manual arrangement.
// A button that takes money it cannot take is worse than no button.
//
// AND NOTHING HERE ENFORCES A LIMIT. The usage bars are informational. A cap
// that actually holds has to be a Postgres trigger — the anon key is public
// and the REST API answers curl, so a Dart check stops nobody.
// =============================================================================

import 'package:flutter/material.dart';

import '../models/ws_models.dart';
import '../services/auth_service.dart';
import '../services/supabase_service.dart';
import '../services/tenant_service.dart';
import '../theme/ws_responsive.dart';
import '../services/whats_new.dart';
import '../theme/ws_theme.dart';
import 'whats_new_screen.dart';
import 'ws_sign_out.dart';

String _initials(String name, String email) {
  final n = name.trim();
  if (n.isNotEmpty) {
    final parts = n.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return (parts.first.characters.first + parts[1].characters.first)
          .toUpperCase();
    }
    return parts.first.characters.first.toUpperCase();
  }
  return email.isEmpty ? '?' : email.characters.first.toUpperCase();
}

/// Colour for a subscription status. 'trialing' is amber rather than green:
/// a trial is a clock running down, and it should not look settled.
Color _statusColor(String status) => switch (status) {
      'active' => WsColors.green,
      'trialing' => WsColors.amber,
      'past_due' => WsColors.red,
      _ => WsColors.text3,
    };

String _statusLabel(String status) => switch (status) {
      'active' => 'Active',
      'trialing' => 'Trial',
      'past_due' => 'Payment overdue',
      'canceled' => 'Cancelled',
      'expired' => 'Expired',
      _ => status,
    };

// ═══ The avatar button ═══════════════════════════════════════════════════════

/// Drop into `AppBar.actions`. Shows the user's initials and opens the menu.
class WsAccountButton extends StatelessWidget {
  final WsInternalUser? me;
  final WsOrganization? org;

  /// Called after anything that may have changed the profile, so the host
  /// screen can reload the name it displays.
  final VoidCallback? onChanged;

  const WsAccountButton({super.key, this.me, this.org, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final email = AuthService.currentUser?.email ?? '';
    return IconButton(
      tooltip: 'Account',
      onPressed: () async {
        await showWsAccountMenu(context, me: me, org: org);
        onChanged?.call();
      },
      icon: CircleAvatar(
        radius: 15,
        backgroundColor: Colors.white24,
        child: Text(
          _initials(me?.fullName ?? '', email),
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// Opens the account panel: a dropdown under the avatar on a wide window, a
/// bottom sheet on a phone. OrderMate uses a popover; on a 400 px screen a
/// popover of this height is a sheet in all but name.
Future<void> showWsAccountMenu(
  BuildContext context, {
  WsInternalUser? me,
  WsOrganization? org,
}) {
  final panel = _AccountPanel(me: me, org: org);

  if (WsBreakpoints.isMobile(context)) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => panel,
    );
  }
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (_) => Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 56, right: 12),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Card(
              elevation: 8,
              clipBehavior: Clip.antiAlias,
              child: panel,
            ),
          ),
        ),
      ),
    ),
  );
}

// ═══ The panel ═══════════════════════════════════════════════════════════════

class _AccountPanel extends StatefulWidget {
  final WsInternalUser? me;
  final WsOrganization? org;
  const _AccountPanel({this.me, this.org});

  @override
  State<_AccountPanel> createState() => _AccountPanelState();
}

class _AccountPanelState extends State<_AccountPanel> {
  Map<String, dynamic>? _sub;
  WsInternalUser? _me;
  WsOrganization? _org;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _me = widget.me;
    _org = widget.org;
    _load();
  }

  Future<void> _load() async {
    // The caller may already have these; fetch only what is missing, so
    // opening the menu on the dashboard costs one query rather than three.
    final sub = await WsDataService.fetchSubscription();
    final me = _me ?? await WsDataService.fetchCurrentInternalUser();
    final org = _org ?? await WsTenantService.currentOrganization;
    if (!mounted) return;
    setState(() {
      _sub = sub;
      _me = me;
      _org = org;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final email = AuthService.currentUser?.email ?? '';
    final name = _me?.fullName.trim().isNotEmpty == true
        ? _me!.fullName
        : (email.contains('@') ? email.split('@').first : 'Signed in');

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (WsBreakpoints.isMobile(context)) ...[
            const SizedBox(height: 12),
            Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2))),
          ],

          // ── Identity ────────────────────────────────────────────────────
          ListTile(
            leading: CircleAvatar(
              backgroundColor: WsColors.primarySurface,
              child: Text(
                _initials(_me?.fullName ?? '', email),
                style: const TextStyle(
                    color: WsColors.primaryDark, fontWeight: FontWeight.w700),
              ),
            ),
            title: Text(name,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(email, style: const TextStyle(fontSize: 12)),
          ),
          const Divider(height: 1),

          // ── Context ─────────────────────────────────────────────────────
          _row(
            Icons.business_outlined,
            _org?.displayName ?? 'No organization',
            'Organization',
          ),
          _row(
            Icons.badge_outlined,
            // roleCode is the real code from the database; WsUserRole
            // collapses six roles into two for routing and would show
            // "staff" for an accountant.
            _roleLabel(_me?.roleCode),
            'Your role',
          ),
          const Divider(height: 1),

          // ── Subscription ────────────────────────────────────────────────
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                  child: SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            _subscriptionBlock(),

          const Divider(height: 1),

          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined, size: 20),
            title: const Text("What's new"),
            subtitle: const Text('Version $wsCurrentVersion',
                style: TextStyle(fontSize: 12)),
            onTap: () async {
              final nav = Navigator.of(context);
              nav.pop();
              final service = WsWhatsNew.instanceOrNull;
              await nav.push(MaterialPageRoute(
                  builder: (_) => WsWhatsNewScreen(
                        releases: service?.all() ?? wsReleaseNotes,
                      )));
              // Opening the full history counts as having seen it, so the
              // upgrade prompt does not appear afterwards for notes the user
              // has just read.
              await service?.markSeen();
            },
          ),
          ListTile(
            leading: const Icon(Icons.person_outline, size: 20),
            title: const Text('Edit profile'),
            onTap: () async {
              final nav = Navigator.of(context);
              nav.pop();
              await nav.push(MaterialPageRoute(
                  builder: (_) => const WsProfileScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout, size: 20, color: WsColors.red),
            title: const Text('Sign out',
                style: TextStyle(color: WsColors.red)),
            onTap: () async {
              // Captured before the await, as before. The sheet is a route
              // above home, so it has to close BEFORE the gate rebuilds into
              // the login screen — hence pop as beforeSignOut rather than
              // after. Cancel leaves the sheet open.
              final nav = Navigator.of(context);
              await wsConfirmSignOut(context, beforeSignOut: nav.pop);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  String _roleLabel(String? code) => switch (code) {
        'owner' => 'Owner',
        'admin' => 'Administrator',
        'accountant' => 'Accountant',
        'sales' => 'Sales',
        'delivery' => 'Delivery',
        'readonly' => 'Read only',
        null => '—',
        _ => code,
      };

  Widget _row(IconData icon, String title, String caption) => ListTile(
        dense: true,
        leading: Icon(icon, size: 20, color: WsColors.text2),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(caption, style: const TextStyle(fontSize: 11)),
      );

  Widget _subscriptionBlock() {
    final s = _sub;

    // No live subscription row at all. Says so rather than implying Free,
    // because those are different situations: one is a plan, the other is
    // missing data that somebody may need to fix.
    if (s == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Text(
          'No active subscription on record for this organization.',
          style: TextStyle(fontSize: 12, color: WsColors.text2),
        ),
      );
    }

    final planName = '${s['planname'] ?? s['plancode'] ?? 'Unknown'}';
    final status = '${s['status'] ?? ''}';
    final color = _statusColor(status);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.workspace_premium_outlined, size: 18, color: color),
            const SizedBox(width: 8),
            Text(planName,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(_statusLabel(status),
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
          if (status == 'trialing' && s['trialenddate'] != null) ...[
            const SizedBox(height: 4),
            Text(_trialLine('${s['trialenddate']}'),
                style: const TextStyle(fontSize: 11, color: WsColors.text2)),
          ],
          const SizedBox(height: 10),
          _usage('Customers', s['usedcustomers'], s['maxcustomers']),
          const SizedBox(height: 6),
          _usage('Users', s['usedusers'], s['maxusers']),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 38,
            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                showWsPlansSheet(context, currentPlan: '${s['plancode']}');
              },
              icon: const Icon(Icons.arrow_upward, size: 16),
              label: const Text('Compare plans'),
              style: ElevatedButton.styleFrom(
                backgroundColor: WsColors.amber,
                foregroundColor: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _trialLine(String iso) {
    final end = DateTime.tryParse(iso);
    if (end == null) return 'Trial ends $iso';
    final days = end.difference(DateTime.now()).inDays;
    if (days < 0) return 'Trial ended';
    if (days == 0) return 'Trial ends today';
    return 'Trial ends in $days day${days == 1 ? '' : 's'}';
  }

  /// One usage line. A null limit means unlimited, which is a plan feature
  /// rather than missing data — so it says "Unlimited" and draws no bar.
  Widget _usage(String label, Object? used, Object? limit) {
    final u = used is num ? used.toInt() : 0;
    if (limit == null) {
      return Row(children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: WsColors.text2))),
        Text('$u  ·  Unlimited',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ]);
    }

    final max = limit is num ? limit.toInt() : 0;
    final ratio = max <= 0 ? 0.0 : (u / max).clamp(0.0, 1.0);
    final over = max > 0 && u >= max;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
              child: Text(label,
                  style:
                      const TextStyle(fontSize: 12, color: WsColors.text2))),
          Text('$u of $max',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: over ? WsColors.red : WsColors.text1)),
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 5,
            backgroundColor: WsColors.border,
            valueColor: AlwaysStoppedAnimation(
                over ? WsColors.red : WsColors.primary),
          ),
        ),
      ],
    );
  }
}

// ═══ Plan comparison ═════════════════════════════════════════════════════════

Future<void> showWsPlansSheet(BuildContext context,
        {String? currentPlan}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _PlansSheet(currentPlan: currentPlan),
    );

class _PlansSheet extends StatefulWidget {
  final String? currentPlan;
  const _PlansSheet({this.currentPlan});

  @override
  State<_PlansSheet> createState() => _PlansSheetState();
}

class _PlansSheetState extends State<_PlansSheet> {
  List<Map<String, dynamic>> _plans = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await WsDataService.fetchPlans();
    if (!mounted) return;
    setState(() { _plans = p; _loading = false; });
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(children: [
          const SizedBox(height: 12),
          Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 14),
          const Text('Plans',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              // Honest about the state of things. There is no payment
              // provider wired up, and a button that pretends otherwise
              // wastes the user's time at the worst possible moment.
              'Online payment is not set up yet — contact us to change plan.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: WsColors.text2),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: _plans.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _planCard(_plans[i]),
                  ),
          ),
        ]),
      );

  Widget _planCard(Map<String, dynamic> p) {
    final code = '${p['plancode']}';
    final isCurrent = code == widget.currentPlan;
    final price = (p['monthlyprice'] as num?)?.toDouble() ?? 0;

    return Card(
      elevation: isCurrent ? 4 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isCurrent ? WsColors.primary : WsColors.border,
          width: isCurrent ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('${p['planname']}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (isCurrent)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: WsColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('CURRENT',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: WsColors.primary)),
                ),
            ]),
            const SizedBox(height: 6),
            Text(
              // Enterprise is priced at 0 in the seed data, which means "talk
              // to us", not "free". Printing "Rs 0/month" beside Free would
              // make the most expensive plan look like the cheapest.
              price == 0
                  ? (code == 'free' ? 'Free' : 'Contact us')
                  : 'Rs ${price.toStringAsFixed(0)} / month',
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: WsColors.primary),
            ),
            const SizedBox(height: 10),
            _limit('Customers', p['maxcustomers']),
            _limit('Users', p['maxusers']),
            _feature('Accounting and ledgers', p['allowaccounting'] == true),
            _feature('Routes and drivers', p['allowroutes'] == true),
            _feature('API access', p['allowapi'] == true),
          ],
        ),
      ),
    );
  }

  Widget _limit(String label, Object? v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          const Icon(Icons.check, size: 15, color: WsColors.green),
          const SizedBox(width: 8),
          Text('$label: ${v == null ? 'Unlimited' : v}',
              style: const TextStyle(fontSize: 12)),
        ]),
      );

  Widget _feature(String label, bool on) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Icon(on ? Icons.check : Icons.remove,
              size: 15, color: on ? WsColors.green : WsColors.textHint),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: on ? WsColors.text1 : WsColors.text3)),
        ]),
      );
}

// ═══ Profile ═════════════════════════════════════════════════════════════════

class WsProfileScreen extends StatefulWidget {
  const WsProfileScreen({super.key});

  @override
  State<WsProfileScreen> createState() => _WsProfileScreenState();
}

class _WsProfileScreenState extends State<WsProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _notice;
  WsInternalUser? _me;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final me = await WsDataService.fetchCurrentInternalUser();
      if (!mounted) return;
      _name.text = me?.fullName ?? '';
      _phone.text = me?.phone ?? '';
      setState(() { _me = me; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = '$e'; });
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() { _saving = true; _error = null; _notice = null; });
    try {
      await WsDataService.updateMyProfile(
        fullName: _name.text.trim(),
        phone: _phone.text,
      );
      if (!mounted) return;
      setState(() { _saving = false; _notice = 'Profile saved.'; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e'.replaceFirst('PostgrestException(message: ', '');
      });
    }
  }

  Future<void> _resetPassword() async {
    final email = AuthService.currentUser?.email;
    if (email == null || email.isEmpty) return;
    setState(() { _error = null; _notice = null; });
    try {
      await AuthService.sendPasswordReset(email);
      if (!mounted) return;
      setState(() =>
          _notice = 'A password reset link is on its way to $email.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = AuthService.currentUser?.email ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        flexibleSpace: const WsGradientBar(),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: WsBreakpoints.pagePadding(context),
              child: WsMaxWidth(
                maxWidth: 480,
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      Center(
                        child: CircleAvatar(
                          radius: 36,
                          backgroundColor: WsColors.primarySurface,
                          child: Text(
                            _initials(_me?.fullName ?? '', email),
                            style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: WsColors.primaryDark),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      const WsFormSection('Your details', first: true),
                      TextFormField(
                        controller: _name,
                        decoration:
                            const InputDecoration(labelText: 'Full name *'),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Enter your name'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(labelText: 'Phone'),
                      ),

                      const WsFormSection('Sign-in'),
                      // Email is the login identity and changing it needs
                      // re-verification through GoTrue, so it is shown but not
                      // editable here rather than offered and then refused.
                      TextFormField(
                        initialValue: email,
                        enabled: false,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          helperText: 'Your sign-in address cannot be changed '
                              'here.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _resetPassword,
                        icon: const Icon(Icons.lock_reset, size: 18),
                        label: const Text('Send password reset email'),
                      ),

                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        _banner(_error!, WsColors.red),
                      ],
                      if (_notice != null) ...[
                        const SizedBox(height: 14),
                        _banner(_notice!, WsColors.green),
                      ],

                      const SizedBox(height: 22),
                      SizedBox(
                        height: 46,
                        child: ElevatedButton(
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Text('Save Profile'),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Your role is set by an administrator under '
                        'Setup › Staff, so it is not editable here.',
                        style: TextStyle(
                            fontSize: 11, height: 1.5, color: WsColors.text3),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _banner(String text, Color color) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 12)),
      );
}
