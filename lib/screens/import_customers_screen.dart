// =============================================================================
// lib/screens/import_customers_screen.dart
// Bulk customer import: paste → preview → confirm.
//
// ─── THE PREVIEW IS THE FEATURE ──────────────────────────────────────────────
//
// Importing updates existing customers, which means a stale spreadsheet can
// overwrite data somebody has been maintaining by hand. The protection is not
// a warning dialog — it is showing, per row, WHICH FIELDS CHANGE FROM WHAT TO
// WHAT before anything is written. An accidental overwrite is then visible
// while it is still preventable.
//
// ─── WHY PASTE AND NOT A FILE PICKER ─────────────────────────────────────────
//
// A file picker needs a plugin with per-platform permissions and native
// configuration that cannot be verified here. Pasting works identically on
// every platform today, including web, with nothing to configure — and the
// parser is the same either way, so wiring a picker in later is a one-line
// change to this screen and nothing else.
// =============================================================================

import 'package:flutter/material.dart';

import '../services/import/ws_csv_import.dart';
import '../services/import/ws_csv_import_apply.dart';
import '../services/store_service.dart';
import '../theme/ws_responsive.dart';
import '../theme/ws_theme.dart';

class WsImportCustomersScreen extends StatefulWidget {
  const WsImportCustomersScreen({super.key});

  @override
  State<WsImportCustomersScreen> createState() =>
      _WsImportCustomersScreenState();
}

class _WsImportCustomersScreenState extends State<WsImportCustomersScreen> {
  final _csv = TextEditingController();

  WsImportPlan? _plan;
  bool _busy = false;
  String? _error;
  WsImportOutcome? _done;

  @override
  void dispose() {
    _csv.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      final ctx = await WsCsvImportService.loadContext();
      final plan = WsCsvImportPlanner(
        existing: ctx.customers,
        areas: ctx.areas,
      ).plan(_csv.text);
      if (!mounted) return;
      setState(() => _plan = plan);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final plan = _plan;
    if (plan == null || plan.hasErrors) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await WsCsvImportService.apply(plan);
      if (!mounted) return;
      setState(() {
        _done = outcome;
        // The plan is spent: its keys have been used. Clearing it stops a
        // second tap re-running a preview that no longer describes reality.
        _plan = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final branch = WsStoreService.currentStore;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Customers'),
        flexibleSpace: const WsGradientBar(),
      ),
      body: WsMaxWidth(
        maxWidth: 900,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_done != null) _outcomeCard(_done!),
            if (_error != null) _errorCard(_error!),

            if (plan == null) ...[
              _instructions(branch),
              const SizedBox(height: 12),
              TextField(
                controller: _csv,
                maxLines: 12,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'name,phone,area,address,openingbalance,openingqty\n'
                      'Hotel ABC,0300-1234567,Gulshan,12 Main Road,500,20',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _preview,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.fact_check_outlined),
                label: const Text('Check the file'),
              ),
            ] else ...[
              _summaryCard(plan),
              const SizedBox(height: 10),
              ..._sections(plan),
              const SizedBox(height: 16),
              Row(children: [
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _plan = null),
                  child: const Text('Back'),
                ),
                const Spacer(),
                FilledButton.icon(
                  // THE GATE. A file with any error cannot be imported at all.
                  onPressed: (_busy || plan.hasErrors || !plan.hasWork)
                      ? null
                      : _apply,
                  icon: const Icon(Icons.upload_outlined),
                  label: Text(plan.hasErrors
                      ? 'Fix the errors first'
                      : 'Import ${plan.creates.length + plan.updates.length} '
                          'row${plan.creates.length + plan.updates.length == 1 ? '' : 's'}'),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  // ── pieces ────────────────────────────────────────────────────────────────

  Widget _instructions(WsStore? branch) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Paste your customer list',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 8),
            const Text(
              'The first line must be a header. Only "name" is required — every '
              'other column is optional.\n\n'
              'Recognised columns: name, phone, area, address, code, contact, '
              'email, rate, deposit, openingbalance, openingqty.',
              style: TextStyle(color: WsColors.text2, height: 1.4),
            ),
            const SizedBox(height: 10),
            _note(Icons.edit_off_outlined,
                'A blank cell leaves the existing value alone. It never clears '
                'a phone number, an address or a balance.'),
            _note(Icons.link,
                'Rows are matched to existing customers by phone first, then by '
                'name and area. Matched customers are updated.'),
            if (branch != null)
              _note(Icons.storefront_outlined,
                  'New customers will be added to ${branch.storeName}. '
                  'Existing customers stay in the branch they are already in.'),
          ]),
        ),
      );

  Widget _note(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: WsColors.primary),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: const TextStyle(fontSize: 12.5, height: 1.35))),
        ]),
      );

  Widget _summaryCard(WsImportPlan plan) => Card(
        color: plan.hasErrors
            ? WsColors.red.withValues(alpha: 0.06)
            : WsColors.green.withValues(alpha: 0.06),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(
                plan.hasErrors
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                color: plan.hasErrors ? WsColors.red : WsColors.green,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  plan.hasErrors
                      ? 'This file cannot be imported yet'
                      : 'Ready to import',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text(plan.summary, style: const TextStyle(color: WsColors.text2)),
            if (plan.hasErrors) ...[
              const SizedBox(height: 6),
              const Text(
                'Nothing will be written until every row is valid — a '
                'half-finished import is harder to undo than a rejected one.',
                style: TextStyle(fontSize: 12.5, color: WsColors.text2),
              ),
            ],
          ]),
        ),
      );

  List<Widget> _sections(WsImportPlan plan) => [
        if (plan.fileErrors.isNotEmpty)
          _section('Problem with the file', WsColors.red, [
            for (final e in plan.fileErrors) Text(e),
          ]),
        if (plan.errored.isNotEmpty)
          _section('Rows with errors (${plan.errored.length})', WsColors.red, [
            for (final r in plan.errored)
              _rowTile('Line ${r.lineNumber}: ${r.name}',
                  r.errors.join('  •  '), WsColors.red),
          ]),
        if (plan.creates.isNotEmpty)
          _section('New customers (${plan.creates.length})', WsColors.green, [
            for (final r in plan.creates)
              _rowTile(r.name, _describeNew(r), WsColors.green),
          ]),
        if (plan.updates.isNotEmpty)
          _section('Will be updated (${plan.updates.length})', WsColors.amber, [
            for (final r in plan.updates)
              _rowTile(
                '${r.name}  ·  matched by ${r.matchedBy}',
                r.changes.map((c) => '${c.field}: '
                    '${c.from.isEmpty ? '(empty)' : c.from} → ${c.to}').join('\n'),
                WsColors.amber,
              ),
          ]),
        if (plan.unchanged.isNotEmpty)
          _section('Already up to date (${plan.unchanged.length})',
              WsColors.text2, [
            Text(plan.unchanged.map((r) => r.name).join(', '),
                style: const TextStyle(color: WsColors.text2, fontSize: 12.5)),
          ]),
      ];

  String _describeNew(WsPlannedRow r) {
    final bits = <String>[];
    if (r.values['phone'] != null) bits.add('${r.values['phone']}');
    if (r.values['address'] != null) bits.add('${r.values['address']}');
    if (r.values['openingbalance'] != null) {
      bits.add('opening ${r.values['openingbalance']}');
    }
    if (r.values['openingqty'] != null) {
      bits.add('${r.values['openingqty']} bottles');
    }
    return bits.isEmpty ? 'No other details supplied' : bits.join('  ·  ');
  }

  Widget _section(String title, Color colour, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(fontWeight: FontWeight.w700, color: colour)),
              const SizedBox(height: 8),
              ...children,
            ]),
          ),
        ),
      );

  Widget _rowTile(String title, String detail, Color colour) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: colour, width: 3)),
          color: Colors.black.withValues(alpha: 0.02),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(detail,
                style: const TextStyle(fontSize: 12.5, color: WsColors.text2)),
          ],
        ]),
      );

  Widget _outcomeCard(WsImportOutcome o) => Card(
        color: o.clean
            ? WsColors.green.withValues(alpha: 0.08)
            : WsColors.amber.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // NOT "failed". Some rows are saved either way, and the old
            // heading sent people looking for an undo that does not exist.
            Text(
                o.clean
                    ? 'Import finished'
                    : 'Import finished — some rows were not saved',
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 4),
            Text(o.summary),

            // The reason, once, in plain words — ahead of the technical lines.
            if (o.planLimitMessage != null) ...[
              const SizedBox(height: 8),
              Text(o.planLimitMessage!,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ],

            // What to do next. This is the whole point of the card: the
            // recovery mechanism already works, and nothing used to say so.
            if (o.retryAdvice != null) ...[
              const SizedBox(height: 8),
              Text(o.retryAdvice!,
                  style:
                      const TextStyle(fontSize: 12.5, color: WsColors.text2)),
            ],

            // Kept verbatim for diagnostics, below the human explanation.
            for (final f in o.failures) ...[
              const SizedBox(height: 4),
              Text(f, style: const TextStyle(fontSize: 12, color: WsColors.red)),
            ],
          ]),
        ),
      );

  Widget _errorCard(String message) => Card(
        color: WsColors.red.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const Icon(Icons.error_outline, color: WsColors.red),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ]),
        ),
      );
}
