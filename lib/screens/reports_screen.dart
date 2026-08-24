// =============================================================================
// lib/screens/reports_screen.dart
// Seven reports, one screen: pick a report, pick a period, export.
//
// Each report is a description — a title, a loader, and a set of columns —
// and everything else (the date bar, the table, CSV, PDF, share, the empty
// state) is shared. Adding an eighth is one entry in _reports.
//
// ON THE RUNNING BALANCE IN A WINDOWED LEDGER
// The ledger views compute `balance` over a customer's whole history. Window
// the result to March and the first row's balance still includes February,
// which is what a statement should do — but it means the debits and credits
// shown do not add up to the closing balance. The screen says so rather than
// letting the reader assume the arithmetic is broken.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../reports/ws_report_export.dart';
import '../services/auth_service.dart';
import '../services/supabase_service.dart';
import '../services/tenant_service.dart';
import '../theme/ws_responsive.dart';
import '../theme/ws_theme.dart';

final _money = NumberFormat('#,##0.##');
final _dmy = DateFormat('dd MMM yyyy');
final _dmyShort = DateFormat('dd MMM');

String _s(Object? v) => v == null ? '' : '$v';
double _n(Object? v) =>
    v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);

String _date(Object? v) {
  if (v == null) return '';
  final d = DateTime.tryParse('$v');
  return d == null ? '$v' : _dmyShort.format(d);
}

/// Whether a report needs a party chosen (a ledger) and/or a date window.
enum _Needs { dates, party, both, neither }

class _ReportDef {
  final String name;
  final String blurb;
  final IconData icon;
  final _Needs needs;

  /// 'customer' or 'vendor' — which list the party picker shows.
  final String? partyKind;

  final List<WsReportColumn> columns;

  /// Columns to total, by header.
  final List<String> totalOf;

  final Future<List<Map<String, dynamic>>> Function(
      DateTime from, DateTime to, int? partyId) load;

  const _ReportDef({
    required this.name,
    required this.blurb,
    required this.icon,
    required this.needs,
    required this.columns,
    required this.load,
    this.partyKind,
    this.totalOf = const [],
  });
}

class WsReportsScreen extends StatefulWidget {
  const WsReportsScreen({super.key});

  @override
  State<WsReportsScreen> createState() => _WsReportsScreenState();
}

class _WsReportsScreenState extends State<WsReportsScreen> {
  late _ReportDef _report = _reports.first;

  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime.now();

  int? _partyId;
  String? _partyName;
  List<Map<String, dynamic>> _parties = [];

  List<Map<String, dynamic>> _rows = [];
  bool _loading = false;
  bool _busy = false;
  String? _error;
  String _orgName = '';

  bool get _canView =>
      AuthService.permissions.any(['reports.view', 'reports.all', 'org.manage']);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _refreshOrgName();
    _run();
  }

  /// Re-read the organization name.
  ///
  /// Called before every export, NOT just in initState. This screen lives in
  /// an IndexedStack, so it is built once and kept alive — edit the
  /// organization in Setup, come back, and initState never runs again. The
  /// exported PDF would keep the name the app started with.
  Future<void> _refreshOrgName() async {
    // currentOrganization is a GETTER, not a method — no parentheses.
    final org = await WsTenantService.currentOrganization;
    if (!mounted) return;
    // displayName prefers the trading name, which is what the Organization
    // form promises gets printed.
    setState(() => _orgName = org?.displayName ?? '');
  }

  // ── Report catalogue ───────────────────────────────────────────────────────

  late final List<_ReportDef> _reports = [
    _ReportDef(
      name: 'Daily Deliveries',
      blurb: 'Every delivery in the period, with bottles and amount charged',
      icon: Icons.local_shipping_outlined,
      needs: _Needs.dates,
      totalOf: const ['Out', 'In', 'Amount'],
      columns: [
        WsReportColumn('Date', (r) => _date(r['deliverydate']), flex: 2),
        WsReportColumn('Ref', (r) => _s(r['referenceno']), flex: 2),
        WsReportColumn('Customer', (r) => _s(r['customername']), flex: 4),
        WsReportColumn('Out', (r) => _s(r['bottlesdelivered']),
            numeric: true, flex: 1),
        WsReportColumn('In', (r) => _s(r['bottlesreturned']),
            numeric: true, flex: 1),
        WsReportColumn('Bal', (r) => _s(r['bottlebalance']),
            numeric: true, flex: 1),
        WsReportColumn('Rate', (r) => _money.format(_n(r['rateapplied'])),
            numeric: true, flex: 2),
        WsReportColumn('Amount', (r) => _money.format(_n(r['amountcharged'])),
            numeric: true, flex: 2),
      ],
      load: (f, t, _) => WsDataService.fetchDeliveryReport(from: f, to: t),
    ),
    _ReportDef(
      name: 'Daily Receipts',
      blurb: 'Money collected from customers',
      icon: Icons.payments_outlined,
      needs: _Needs.dates,
      totalOf: const ['Amount'],
      columns: [
        WsReportColumn('Date', (r) => _date(r['paymentdate']), flex: 2),
        WsReportColumn('Receipt', (r) => _s(r['receiptno']), flex: 2),
        WsReportColumn('Customer', (r) => _s(r['customername']), flex: 4),
        WsReportColumn('Method', (r) => _s(r['paymentmethod']), flex: 2),
        WsReportColumn('Reference', (r) => _s(r['referenceno']), flex: 3),
        WsReportColumn('Amount', (r) => _money.format(_n(r['amountreceived'])),
            numeric: true, flex: 2),
      ],
      load: (f, t, _) => WsDataService.fetchPaymentReport(from: f, to: t),
    ),
    _ReportDef(
      name: 'Vendor Payments',
      blurb: 'Money paid out to suppliers',
      icon: Icons.outbond_outlined,
      needs: _Needs.dates,
      totalOf: const ['Amount'],
      columns: [
        WsReportColumn('Date', (r) => _date(r['paiddate']), flex: 2),
        WsReportColumn('Voucher', (r) => _s(r['voucherno']), flex: 2),
        WsReportColumn('Vendor', (r) => _s(r['vendorname']), flex: 4),
        WsReportColumn('Reference', (r) => _s(r['referenceno']), flex: 3),
        WsReportColumn('Amount', (r) => _money.format(_n(r['amountpaid'])),
            numeric: true, flex: 2),
      ],
      load: (f, t, _) => WsDataService.fetchVendorPaymentReport(from: f, to: t),
    ),
    _ReportDef(
      name: 'Customer Ledger',
      blurb: 'One customer: charges, receipts and running balance',
      icon: Icons.person_outline,
      needs: _Needs.both,
      partyKind: 'customer',
      totalOf: const ['Debit', 'Credit'],
      columns: [
        WsReportColumn('Date', (r) => _date(r['txndate']), flex: 2),
        WsReportColumn('Description', (r) => _s(r['description']), flex: 5),
        WsReportColumn('Reference', (r) => _s(r['referenceno']), flex: 3),
        WsReportColumn('Debit', (r) => _money.format(_n(r['debit'])),
            numeric: true, flex: 2),
        WsReportColumn('Credit', (r) => _money.format(_n(r['credit'])),
            numeric: true, flex: 2),
        WsReportColumn('Balance', (r) => _money.format(_n(r['balance'])),
            numeric: true, flex: 2),
      ],
      load: (f, t, id) async => id == null
          ? <Map<String, dynamic>>[]
          : (await WsDataService.fetchCustomerLedgerRange(id, from: f, to: t))
              .map((e) => {
                    'txndate': e.date.toIso8601String(),
                    'description': e.description,
                    'referenceno': e.referenceNo,
                    'debit': e.debit,
                    'credit': e.credit,
                    'balance': e.balance,
                  })
              .toList(),
    ),
    _ReportDef(
      name: 'Vendor Ledger',
      blurb: 'One vendor: bills, payments and running balance',
      icon: Icons.local_shipping_outlined,
      needs: _Needs.both,
      partyKind: 'vendor',
      totalOf: const ['Debit', 'Credit'],
      columns: [
        WsReportColumn('Date', (r) => _date(r['txndate']), flex: 2),
        WsReportColumn('Description', (r) => _s(r['description']), flex: 5),
        WsReportColumn('Reference', (r) => _s(r['referenceno']), flex: 3),
        WsReportColumn('Debit', (r) => _money.format(_n(r['debit'])),
            numeric: true, flex: 2),
        WsReportColumn('Credit', (r) => _money.format(_n(r['credit'])),
            numeric: true, flex: 2),
        WsReportColumn('Balance', (r) => _money.format(_n(r['balance'])),
            numeric: true, flex: 2),
      ],
      load: (f, t, id) async => id == null
          ? <Map<String, dynamic>>[]
          : (await WsDataService.fetchVendorLedgerRange(id, from: f, to: t))
              .map((e) => {
                    'txndate': e.date.toIso8601String(),
                    'description': e.description,
                    'referenceno': e.referenceNo,
                    'debit': e.debit,
                    'credit': e.credit,
                    'balance': e.balance,
                  })
              .toList(),
    ),
    _ReportDef(
      name: 'Bottle Ledger',
      blurb: 'Every bottle movement, in and out',
      icon: Icons.water_drop_outlined,
      needs: _Needs.dates,
      totalOf: const ['Qty'],
      columns: [
        WsReportColumn('Date', (r) => _date(r['txndate']), flex: 2),
        WsReportColumn('Type', (r) => _s(r['txntype']), flex: 2),
        WsReportColumn('Customer',
            (r) => _s(r['customername']).isEmpty ? '(stock)' : _s(r['customername']),
            flex: 4),
        WsReportColumn('Bottle', (r) => _s(r['bottlename']), flex: 3),
        WsReportColumn('Qty', (r) => _s(r['qty']), numeric: true, flex: 1),
        WsReportColumn('After', (r) => _s(r['balanceafter']),
            numeric: true, flex: 2),
      ],
      load: (f, t, _) => WsDataService.fetchBottleLedgerRange(from: f, to: t),
    ),
    _ReportDef(
      name: 'Total Receivable',
      blurb: 'Who owes you money, right now',
      icon: Icons.account_balance_wallet_outlined,
      // A position, not a period: windowing it by date would be meaningless.
      needs: _Needs.neither,
      totalOf: const ['Outstanding'],
      columns: [
        WsReportColumn('Customer', (r) => _s(r['customername']), flex: 5),
        WsReportColumn('Phone', (r) => _s(r['phone']), flex: 3),
        WsReportColumn('Area', (r) => _s(r['areaname']), flex: 3),
        WsReportColumn('Bottles', (r) => _s(r['bottlebalance']),
            numeric: true, flex: 2),
        WsReportColumn('Outstanding',
            (r) => _money.format(_n(r['outstandingdue'])), numeric: true, flex: 3),
      ],
      load: (_, _, _) => WsDataService.fetchReceivableSummary(),
    ),
  ];

  // ── Loading ────────────────────────────────────────────────────────────────

  Future<void> _run() async {
    if (!_canView) return;
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await _report.load(_from, _to, _partyId);
      if (!mounted) return;
      setState(() { _rows = rows; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _rows = [];
        _error = '$e'.replaceFirst('PostgrestException(message: ', '');
      });
    }
  }

  Future<void> _pickReport(_ReportDef def) async {
    setState(() {
      _report = def;
      _rows = [];
      _error = null;
      if (def.partyKind == null) { _partyId = null; _partyName = null; }
    });
    if (def.partyKind != null) {
      await _loadParties(def.partyKind!);
      if (!mounted) return;
      // A ledger with nobody chosen has nothing to show, so ask immediately
      // rather than presenting an empty table that looks like a bug.
      if (_partyId == null) { await _pickParty(); return; }
    }
    _run();
  }

  Future<void> _loadParties(String kind) async {
    final list = kind == 'customer'
        ? await WsDataService.fetchCustomerOpenings()
        : await WsDataService.fetchVendorOpenings();
    if (!mounted) return;
    setState(() => _parties = list);
  }

  Future<void> _pickParty() async {
    if (_parties.isEmpty) await _loadParties(_report.partyKind!);
    if (!mounted) return;

    final idKey = _report.partyKind == 'customer' ? 'customerid' : 'vendorid';
    final nameKey = _report.partyKind == 'customer' ? 'customername' : 'vendorname';

    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _PartyPicker(
        title: 'Choose ${_report.partyKind}',
        items: _parties,
        nameKey: nameKey,
      ),
    );

    if (chosen != null && mounted) {
      setState(() {
        _partyId = (chosen[idKey] as num).toInt();
        _partyName = '${chosen[nameKey]}';
      });
      _run();
    }
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (picked != null && mounted) {
      setState(() { _from = picked.start; _to = picked.end; });
      _run();
    }
  }

  void _quickRange(String which) {
    final now = DateTime.now();
    late DateTime f, t;
    switch (which) {
      case 'today':
        f = DateTime(now.year, now.month, now.day);
        t = f;
      case 'week':
        f = now.subtract(Duration(days: now.weekday - 1));
        f = DateTime(f.year, f.month, f.day);
        t = now;
      case 'month':
        f = DateTime(now.year, now.month, 1);
        t = now;
      default:
        // Last month, in full: day 0 of this month is the last day of the one
        // before, which avoids hardcoding 28/30/31.
        f = DateTime(now.year, now.month - 1, 1);
        t = DateTime(now.year, now.month, 0);
    }
    setState(() { _from = f; _to = t; });
    _run();
  }

  // ── Export ─────────────────────────────────────────────────────────────────

  WsReport _snapshot() {
    final totals = <String, String>{};
    for (final header in _report.totalOf) {
      final col = _report.columns.firstWhere((c) => c.header == header,
          orElse: () => _report.columns.first);
      if (col.header != header) continue;
      // Sum the RAW values, not the formatted strings — parsing "1,250" back
      // out of a thousands-separated string is how totals drift.
      var sum = 0.0;
      for (final r in _rows) {
        sum += _n(_rawFor(header, r));
      }
      totals[header] = _money.format(sum);
    }

    return WsReport(
      title: _report.name,
      subtitle: _subtitle(),
      columns: _report.columns,
      rows: _rows,
      totals: totals,
    );
  }

  /// Maps a column header back to the raw field it came from, for totalling.
  Object? _rawFor(String header, Map<String, dynamic> r) {
    switch (header) {
      case 'Out':         return r['bottlesdelivered'];
      case 'In':          return r['bottlesreturned'];
      case 'Qty':         return r['qty'];
      case 'Amount':      return r['amountcharged'] ?? r['amountreceived'] ?? r['amountpaid'];
      case 'Debit':       return r['debit'];
      case 'Credit':      return r['credit'];
      case 'Outstanding': return r['outstandingdue'];
      default:            return null;
    }
  }

  String _subtitle() {
    final parts = <String>[];
    if (_partyName != null) parts.add(_partyName!);
    if (_report.needs != _Needs.neither && _report.needs != _Needs.party) {
      parts.add('${_dmy.format(_from)} to ${_dmy.format(_to)}');
    } else if (_report.needs == _Needs.neither) {
      parts.add('As at ${_dmy.format(DateTime.now())}');
    }
    parts.add('${_rows.length} row${_rows.length == 1 ? '' : 's'}');
    return parts.join('  ·  ');
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: WsColors.red),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_canView) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reports')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'You do not have permission to view reports.',
              textAlign: TextAlign.center,
              style: TextStyle(color: WsColors.text2),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        flexibleSpace: const WsGradientBar(),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _run,
          ),
        ],
      ),
      body: Column(children: [
        _reportBar(),
        if (_report.needs != _Needs.neither) _dateBar(),
        if (_report.partyKind != null) _partyBar(),
        if (_error != null)
          Container(
            width: double.infinity,
            color: WsColors.red.withValues(alpha: 0.08),
            padding: const EdgeInsets.all(12),
            child: Text(_error!,
                style: const TextStyle(color: WsColors.red, fontSize: 12)),
          ),
        Expanded(child: _body()),
        _exportBar(),
      ]),
    );
  }

  Widget _reportBar() => SizedBox(
    height: 46,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      itemCount: _reports.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (_, i) {
        final d = _reports[i];
        final on = d.name == _report.name;
        return ChoiceChip(
          label: Text(d.name),
          selected: on,
          onSelected: (_) => _pickReport(d),
          showCheckmark: false,
          selectedColor: WsColors.primary,
          labelStyle: TextStyle(
            color: on ? Colors.white : WsColors.primary,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        );
      },
    ),
  );

  Widget _dateBar() => Material(
    color: WsColors.primarySurface,
    child: Column(children: [
      InkWell(
        onTap: _pickRange,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Row(children: [
            const Icon(Icons.date_range, size: 18, color: WsColors.primaryDark),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${_dmy.format(_from)}  →  ${_dmy.format(_to)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: WsColors.primaryDark),
              ),
            ),
            const Text('Change',
                style: TextStyle(fontSize: 12, color: WsColors.primaryDark)),
          ]),
        ),
      ),
      SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            for (final q in const [
              ['today', 'Today'],
              ['week', 'This week'],
              ['month', 'This month'],
              ['lastmonth', 'Last month'],
            ])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  label: Text(q[1], style: const TextStyle(fontSize: 11)),
                  onPressed: () => _quickRange(q[0]),
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 4),
    ]),
  );

  Widget _partyBar() => Material(
    color: Colors.white,
    child: ListTile(
      dense: true,
      leading: Icon(
          _report.partyKind == 'customer'
              ? Icons.person_outline
              : Icons.local_shipping_outlined,
          size: 20),
      title: Text(_partyName ?? 'Choose a ${_report.partyKind}',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _partyName == null ? WsColors.text3 : WsColors.text2)),
      trailing: const Icon(Icons.chevron_right),
      onTap: _pickParty,
    ),
  );

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_report.partyKind != null && _partyId == null) {
      return _hint(Icons.touch_app_outlined,
          'Choose a ${_report.partyKind} to see their ledger.');
    }
    if (_rows.isEmpty) {
      return _hint(Icons.inbox_outlined, 'Nothing in this period.');
    }

    // Horizontal scroll because eight columns do not fit a phone, and a table
    // squeezed to fit is a table nobody can read.
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minWidth: MediaQuery.sizeOf(context).width -
                  (WsBreakpoints.isMobile(context) ? 0 : 32)),
          child: SingleChildScrollView(
            child: DataTable(
              headingRowHeight: 38,
              dataRowMinHeight: 34,
              dataRowMaxHeight: 44,
              columnSpacing: 22,
              columns: _report.columns
                  .map((c) => DataColumn(
                        numeric: c.numeric,
                        label: Text(c.header,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w700)),
                      ))
                  .toList(),
              rows: _rows
                  .map((r) => DataRow(
                        cells: _report.columns
                            .map((c) => DataCell(Text(c.value(r),
                                style: const TextStyle(fontSize: 12))))
                            .toList(),
                      ))
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hint(IconData icon, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 40, color: WsColors.text3),
        const SizedBox(height: 12),
        Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: WsColors.text2)),
      ]),
    ),
  );

  Widget _exportBar() {
    final enabled = !_busy && _rows.isNotEmpty;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Colors.black12)),
        ),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: enabled
                  ? () => _guard(() async {
                        final ok = await WsExport.shareCsv(_snapshot());
                        if (!ok && mounted) {
                          // Honest about the platform rather than silently
                          // doing nothing.
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'Sharing a CSV needs Android or iOS. On '
                                  'desktop, use PDF → Save as.'),
                            ),
                          );
                        }
                      })
                  : null,
              icon: const Icon(Icons.table_view_outlined, size: 18),
              label: const Text('CSV'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: enabled
                  ? () => _guard(() async {
                        await _refreshOrgName();
                        await WsExport.printPdf(_snapshot(), orgName: _orgName);
                      })
                  : null,
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
              label: const Text('PDF'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: enabled
                  ? () => _guard(() async {
                        await _refreshOrgName();
                        await WsExport.sharePdf(_snapshot(), orgName: _orgName);
                      })
                  : null,
              icon: Icon(
                  WsExport.canShare ? Icons.share_outlined : Icons.print_outlined,
                  size: 18),
              // On desktop this opens the print/save dialog, so calling it
              // "Share" there would be a lie.
              label: Text(WsExport.canShare ? 'Share' : 'Print'),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─── Party picker with a search box ───────────────────────────────────────────

class _PartyPicker extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> items;
  final String nameKey;

  const _PartyPicker({
    required this.title,
    required this.items,
    required this.nameKey,
  });

  @override
  State<_PartyPicker> createState() => _PartyPickerState();
}

class _PartyPickerState extends State<_PartyPicker> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _q.isEmpty
        ? widget.items
        : widget.items
            .where((m) =>
                '${m[widget.nameKey]}'.toLowerCase().contains(_q.toLowerCase()))
            .toList();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(children: [
          const SizedBox(height: 12),
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                hintText: widget.title,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('No match'))
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (_, i) => ListTile(
                      title: Text('${filtered[i][widget.nameKey]}'),
                      onTap: () => Navigator.pop(context, filtered[i]),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}
