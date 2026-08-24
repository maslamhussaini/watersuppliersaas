// =============================================================================
// lib/screens/organization_screen.dart
// The organization's own profile: name, contact details, document prefixes.
//
// This is the one record every other record hangs off, and until now there was
// no way to edit it from the app — the name on every printed delivery card was
// whatever was typed at registration, permanently.
//
// WHAT IS NOT EDITABLE HERE, AND WHY
//   orgid        identity; RLS keys off it
//   owneruserid  identity; a form field that reassigns tenant ownership is a
//                privilege-escalation bug wearing a text input
//   publicid     external reference, stable by contract
// The service filters the patch to an allow-list, so adding a field to this
// screen is not enough to make it writable. That is deliberate.
// =============================================================================

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/supabase_service.dart';
import '../theme/ws_responsive.dart';
import '../theme/ws_theme.dart';

class WsOrganizationScreen extends StatefulWidget {
  const WsOrganizationScreen({super.key});

  @override
  State<WsOrganizationScreen> createState() => _WsOrganizationScreenState();
}

class _WsOrganizationScreenState extends State<WsOrganizationScreen> {
  final _formKey = GlobalKey<FormState>();

  /// column -> controller. Keyed by database column so the patch builds itself.
  final Map<String, TextEditingController> _ctl = {};

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _notice;

  bool get _canEdit => AuthService.permissions.has('org.manage');

  static const _fields = <_OrgField>[
    _OrgField('orgname', 'Organization name', required: true),
    _OrgField('businessname', 'Business / trading name',
        helper: 'Printed on delivery cards and receipts if set'),
    _OrgField('ownername', 'Owner name'),
    _OrgField('phone', 'Phone', keyboard: TextInputType.phone),
    _OrgField('email', 'Email', keyboard: TextInputType.emailAddress),
    _OrgField('address', 'Address', lines: 3),
    _OrgField('currencysymbol', 'Currency symbol', hint: 'Rs'),
    _OrgField('invoiceprefix', 'Invoice prefix', hint: 'INV-'),
    _OrgField('receiptprefix', 'Receipt prefix', hint: 'RCPT-'),
    _OrgField('deliveryprefix', 'Delivery prefix', hint: 'DLV-'),
  ];

  @override
  void initState() {
    super.initState();
    for (final f in _fields) {
      _ctl[f.column] = TextEditingController();
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; _notice = null; });
    try {
      final row = await WsDataService.fetchOrgRow();
      if (!mounted) return;
      if (row != null) {
        for (final f in _fields) {
          _ctl[f.column]!.text = '${row[f.column] ?? ''}';
        }
      }
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e'.replaceFirst('PostgrestException(message: ', '');
      });
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() { _saving = true; _error = null; _notice = null; });
    try {
      await WsDataService.updateOrganization({
        for (final f in _fields) f.column: _ctl[f.column]!.text.trim(),
      });
      if (!mounted) return;
      setState(() { _saving = false; _notice = 'Saved.'; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e'
            .replaceFirst('PostgrestException(message: ', '')
            .replaceFirst('new row violates row-level security policy',
                'You do not have permission to change the organization.');
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Organization'),
      flexibleSpace: const WsGradientBar(),
      actions: [
        IconButton(
          tooltip: 'Reload',
          icon: const Icon(Icons.refresh),
          onPressed: _loading ? null : _load,
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            padding: WsBreakpoints.pagePadding(context),
            child: WsMaxWidth(
              maxWidth: 560,
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_canEdit) _readOnlyBanner(),
                    for (final f in _fields) ...[
                      TextFormField(
                        controller: _ctl[f.column],
                        enabled: _canEdit && !_saving,
                        keyboardType: f.keyboard,
                        maxLines: f.lines,
                        decoration: InputDecoration(
                          labelText: f.label + (f.required ? ' *' : ''),
                          hintText: f.hint,
                          helperText: f.helper,
                          helperMaxLines: 2,
                        ),
                        validator: (v) {
                          final t = (v ?? '').trim();
                          if (f.required && t.isEmpty) {
                            return '${f.label} is required';
                          }
                          if (f.column == 'email' &&
                              t.isNotEmpty &&
                              (!t.contains('@') || !t.contains('.'))) {
                            return 'That does not look like an email address';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_error != null) _banner(_error!, WsColors.red),
                    if (_notice != null) _banner(_notice!, WsColors.green),
                    const SizedBox(height: 8),
                    if (_canEdit)
                      SizedBox(
                        height: 46,
                        child: ElevatedButton(
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Save Organization'),
                        ),
                      ),
                    const SizedBox(height: 28),
                    const Text(
                      'Document prefixes affect NEW documents only. Numbers '
                      'already issued keep the prefix they were created with, '
                      'so your existing receipts stay findable.',
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

  Widget _readOnlyBanner() => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: WsColors.amber.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: WsColors.amber.withValues(alpha: 0.35)),
    ),
    child: const Text(
      'You can view these details but not change them. Editing the '
      'organization needs the org.manage permission.',
      style: TextStyle(fontSize: 12, height: 1.4),
    ),
  );

  Widget _banner(String text, Color color) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 12)),
  );
}

class _OrgField {
  final String column;
  final String label;
  final bool required;
  final String? hint;
  final String? helper;
  final int lines;
  final TextInputType? keyboard;

  const _OrgField(
    this.column,
    this.label, {
    this.required = false,
    this.hint,
    this.helper,
    this.lines = 1,
    this.keyboard,
  });
}
