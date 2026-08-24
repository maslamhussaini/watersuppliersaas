// =============================================================================
// lib/screens/organization_selector_screen.dart
//
// Pick an organization, or create one.
//
// WHY THE "CREATE" HALF EXISTS NOW
// This screen used to list organizations and, when there were none, print
// "No organizations found for this user." — a dead end. That is not a rare edge
// case, it is the NORMAL state for anyone who signs up while Supabase has email
// confirmation enabled:
//
//   1. signUp() succeeds and creates the auth user
//   2. no session is returned, because the email is not confirmed yet
//   3. ws_create_organization requires an authenticated caller, so it is skipped
//   4. the user confirms their email and signs in — now authenticated, but with
//      no organization and no membership
//
// Every RLS policy resolves through ws_tblmemberships, so that user can see
// nothing and had no way to fix it from inside the app. This screen is where
// they land, and it now finishes the job registration had to defer.
// =============================================================================

import 'package:flutter/material.dart';
import '../models/ws_models.dart';
import '../services/auth_service.dart';
import '../services/tenant_service.dart';
import '../theme/ws_theme.dart';
import 'ws_sign_out.dart';

class WsOrganizationSelectorScreen extends StatefulWidget {
  const WsOrganizationSelectorScreen({super.key});

  @override
  State<WsOrganizationSelectorScreen> createState() =>
      _WsOrganizationSelectorScreenState();
}

class _WsOrganizationSelectorScreenState
    extends State<WsOrganizationSelectorScreen> {
  late Future<List<WsOrganization>> _orgsFuture;

  @override
  void initState() {
    super.initState();
    _orgsFuture = WsTenantService.organizationsForCurrentUser();
  }

  void _reload() {
    setState(() {
      _orgsFuture = WsTenantService.organizationsForCurrentUser();
    });
  }

  Future<void> _openCreateSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _CreateOrganizationSheet(),
    );

    if (created == true && mounted) {
      // selectOrganization() already ran inside the RPC wrapper, so the auth
      // gate routes straight to the dashboard on rebuild.
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Organization'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            // Not awaited, exactly as before: onPressed is a VoidCallback and
            // the future was already discarded here. Nothing to pop — the auth
            // gate handles the transition.
            onPressed: () {
              wsConfirmSignOut(context);
            },
          ),
        ],
      ),
      body: FutureBuilder<List<WsOrganization>>(
        future: _orgsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return _message(
              icon: Icons.error_outline,
              color: WsColors.red,
              title: 'Could not load your organizations',
              body: '${snapshot.error}',
              actionLabel: 'Retry',
              onAction: _reload,
            );
          }

          final orgs = snapshot.data ?? const <WsOrganization>[];

          if (orgs.isEmpty) {
            return _message(
              icon: Icons.business_outlined,
              color: WsColors.primary,
              title: 'No organization yet',
              body:
                  'Your account exists but is not linked to a business.\n'
                  'If you have just confirmed your email this is expected — '
                  'set up your business to continue.',
              actionLabel: 'Create Organization',
              onAction: _openCreateSheet,
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: orgs.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              if (index == orgs.length) {
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton.icon(
                    onPressed: _openCreateSheet,
                    icon: const Icon(Icons.add),
                    label: const Text('Create another organization'),
                  ),
                );
              }

              final org = orgs[index];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: WsColors.primary,
                    child: Text(
                      org.orgName.isEmpty ? '?' : org.orgName[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  title: Text(org.orgName),
                  subtitle: Text(
                    org.address.isEmpty ? org.ownerName : org.address,
                  ),
                  trailing: const Icon(Icons.arrow_forward),
                  onTap: () {
                    WsTenantService.selectOrganization(org.orgId);
                    Navigator.of(context).pushReplacementNamed('/home');
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _message({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    required String actionLabel,
    required VoidCallback onAction,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: color),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: WsColors.text2, height: 1.5),
          ),
          const SizedBox(height: 22),
          ElevatedButton.icon(
            onPressed: onAction,
            icon: const Icon(Icons.add_business_outlined),
            label: Text(actionLabel),
          ),
        ],
      ),
    ),
  );
}

// ─── Create organization ──────────────────────────────────────────────────────

class _CreateOrganizationSheet extends StatefulWidget {
  const _CreateOrganizationSheet();

  @override
  State<_CreateOrganizationSheet> createState() =>
      _CreateOrganizationSheetState();
}

class _CreateOrganizationSheetState extends State<_CreateOrganizationSheet> {
  final _form = GlobalKey<FormState>();
  final _orgName = TextEditingController();
  final _ownerName = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  bool _saving = false;

  /// THIS SCREEN NO LONGER MINTS A KEY.
  ///
  /// It used to hold its own `wsNewUuid()`, independent of the one
  /// register_screen held. That was harmless only while this screen ran solely
  /// for users whose provisioning had never been attempted. Now that
  /// registration can be interrupted mid-OTP, someone arriving here may have an
  /// attempt whose RPC ALREADY COMMITTED — and a fresh key would build a second
  /// organization instead of resolving to the first.
  ///
  /// So: resume the persisted attempt if there is one, and only start a new
  /// attempt when there genuinely is not (an existing user deliberately adding
  /// another organization).
  String? _error;

  @override
  void dispose() {
    _orgName.dispose();
    _ownerName.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    final navigator = Navigator.of(context);
    try {
      // Resume FIRST. A persisted attempt's key must never be replaced here.
      final pending = await AuthService.resumeRegistration();
      if (pending != null) {
        await AuthService.provisionForRegistration(pending);
        if (!mounted) return;
        navigator.pop(true);
        return;
      }
      // One RPC. It creates the organization, the seven default roles with
      // their permission sets, the OWNER MEMBERSHIP (without which RLS shows
      // this user nothing at all), the staff record, a trial subscription and
      // the chart of accounts — in a single transaction.
      // No pending attempt: a genuinely new organization for someone who
      // already has one.
      //
      // beginAdditionalOrganization WRITES THE KEY TO STORAGE BEFORE RETURNING,
      // and provisioning goes through the same flow every other path uses. The
      // previous version minted a key in memory and called the RPC directly,
      // so a commit whose response was lost left nothing to resume and the
      // retry created a second organization — the exact failure migration 014
      // exists to prevent.
      final fresh = await AuthService.beginAdditionalOrganization(
        orgName: _orgName.text.trim(),
        ownerName: _ownerName.text.trim(),
        orgPhone: _phone.text.trim(),
        address: _address.text.trim(),
      );
      await AuthService.provisionForRegistration(fresh);
      if (!mounted) return;
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Set up your business',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _orgName,
              decoration: const InputDecoration(
                labelText: 'Business name *',
                hintText: 'e.g. Kent Mineral Water',
              ),
              textCapitalization: TextCapitalization.words,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _ownerName,
              decoration: const InputDecoration(labelText: 'Owner name'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phone,
              decoration: const InputDecoration(labelText: 'Phone'),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _address,
              decoration: const InputDecoration(labelText: 'Address'),
              maxLines: 2,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: WsColors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: WsColors.red, fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create Organization'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
