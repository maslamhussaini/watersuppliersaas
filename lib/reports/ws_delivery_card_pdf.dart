// =============================================================================
// lib/reports/ws_delivery_card_pdf.dart
// The printed delivery card — a digital copy of the customer's paper card.
//
// REPLACES lib/ws_customer_ledger_pdf.dart AND lib/ws_bottle_ledger_pdf.dart
//
// Those two files did not compile. Between them the analyzer reported 25 errors:
//
//   * ws_bottle_ledger_pdf.dart imported `_ShareOption` from the other file with
//     a `show` clause. A leading underscore makes a declaration library-private;
//     naming it in an import is a hard error, not a warning.
//   * Both used a hand-maintained `show` list on package:flutter/material.dart
//     that omitted identifiers they went on to use — Uint8List,
//     FractionallySizedBox, RoundedRectangleBorder, Radius, AppBar.
//   * `Printing.pickPrinter(context: null)` passes null to a non-nullable
//     BuildContext.
//   * `await` appeared inside a non-async closure.
//   * Both redefined WsOrganization and WsBottleCondition, colliding with
//     lib/models/ws_models.dart.
//   * Neither file was imported anywhere, so none of this ever surfaced at run
//     time — the feature simply did not exist.
//
// WEB COMPATIBILITY
// The old code wrote the PDF to disk with dart:io File and path_provider. Neither
// works in a browser, and vercel.json shows this app deploys to web. This version
// keeps the document in memory as Uint8List and hands it to Printing /
// the printing package, which is implemented on every target.
//
// The layout is driven by ws_tblorganization.cardsettings, so page size and
// column selection are per-tenant data rather than compiled-in constants.
// =============================================================================

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/ws_models.dart';

final _dateFmt = DateFormat('dd MMM yyyy');
final _dayFmt = DateFormat('dd-MM');
final _moneyFmt = NumberFormat('#,##0');

/// Builds the delivery-card PDF from [WsDeliveryCardRow]s produced by
/// `vw_ws_deliverycard`, so the printed figures are the same ones the ledger
/// and dashboard show. Nothing is recomputed here.
class WsDeliveryCardPdf {
  final WsOrganization org;
  final WsCustomer customer;
  final List<WsDeliveryCardRow> rows;
  final DateTime? periodFrom;
  final DateTime? periodTo;

  /// Bottle balances per type. Rendered as a footnote when the customer holds
  /// more than one kind of bottle — the card's single balance column shows the
  /// organization's default type only.
  final List<WsBottleBalance> bottleBalances;

  WsDeliveryCardPdf({
    required this.org,
    required this.customer,
    required this.rows,
    this.periodFrom,
    this.periodTo,
    this.bottleBalances = const [],
  });

  int get totalDelivered => rows.fold(0, (s, r) => s + r.deliveryBottles);
  int get totalReceived => rows.fold(0, (s, r) => s + r.receivedBottles);
  double get totalAmount => rows.fold(0.0, (s, r) => s + r.totalAmount);
  double get totalPaid => rows.fold(0.0, (s, r) => s + r.amountReceived);

  /// Closing balance as at the last row. Taken from the view's running total
  /// rather than recomputed from the visible rows, which would be wrong for any
  /// date-filtered card that does not start at the customer's first delivery.
  double get closingBalance => rows.isEmpty ? 0 : rows.last.runningBalance;
  int get closingBottles => rows.isEmpty ? 0 : rows.last.bottleBalance;

  Map<String, dynamic> get _settings => org.cardSettings ?? const {};

  PdfPageFormat get pageFormat {
    switch ('${_settings['pagesize'] ?? 'A5'}'.toUpperCase()) {
      case 'A4':
        return PdfPageFormat.a4;
      case 'A6':
        return PdfPageFormat.a6;
      case 'ROLL80':
      case 'THERMAL':
        return PdfPageFormat.roll80;
      case 'A5':
      default:
        return PdfPageFormat.a5;
    }
  }

  bool get _showSignature => _settings['showsignature'] != false;
  bool get _showDeposit => _settings['showdeposit'] != false;

  static const _ink = PdfColor.fromInt(0xFF1A1C1E);
  static const _muted = PdfColor.fromInt(0xFF5F6368);
  static const _line = PdfColor.fromInt(0xFFBFC7CC);
  static const _headerBg = PdfColor.fromInt(0xFFE3F2FD);
  static const _zebra = PdfColor.fromInt(0xFFF6F8FA);
  static const _accent = PdfColor.fromInt(0xFF0B6BCB);
  static const _due = PdfColor.fromInt(0xFFB3261E);

  String _money(double v) => '${org.currencySymbol} ${_moneyFmt.format(v)}';

  Future<Uint8List> build() async {
    final doc = pw.Document(
      title: 'Delivery Card — ${customer.customerName}',
      author: org.displayName,
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        margin: const pw.EdgeInsets.all(18),
        header: (ctx) => ctx.pageNumber == 1 ? _header() : _continuation(),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 6),
          child: pw.Text(
            'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            style: pw.TextStyle(fontSize: 7, color: _muted),
          ),
        ),
        build: (ctx) => [
          _customerBlock(),
          pw.SizedBox(height: 10),
          _table(),
          pw.SizedBox(height: 10),
          _totals(),
          if (bottleBalances.length > 1) ...[
            pw.SizedBox(height: 8),
            _bottleBreakdown(),
          ],
          if (_showSignature) ...[
            pw.SizedBox(height: 22),
            _signatures(),
          ],
        ],
      ),
    );

    return doc.save();
  }

  pw.Widget _header() => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  org.displayName.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 15,
                    fontWeight: pw.FontWeight.bold,
                    color: _accent,
                  ),
                ),
                if (org.address.isNotEmpty)
                  pw.Text(
                    org.address,
                    style: pw.TextStyle(fontSize: 7.5, color: _muted),
                  ),
                if (org.phone.isNotEmpty)
                  pw.Text(
                    'Phone: ${org.phone}',
                    style: pw.TextStyle(fontSize: 7.5, color: _muted),
                  ),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                'DELIVERY CARD',
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: _ink,
                ),
              ),
              pw.Text(
                _periodLabel(),
                style: pw.TextStyle(fontSize: 7.5, color: _muted),
              ),
            ],
          ),
        ],
      ),
      pw.Divider(color: _line, thickness: 0.8, height: 12),
    ],
  );

  pw.Widget _continuation() => pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 6),
    child: pw.Text(
      '${org.displayName} — ${customer.customerName} (continued)',
      style: pw.TextStyle(fontSize: 8, color: _muted),
    ),
  );

  String _periodLabel() {
    if (periodFrom == null && periodTo == null) return 'All activity';
    final from = periodFrom != null ? _dateFmt.format(periodFrom!) : 'start';
    final to = periodTo != null ? _dateFmt.format(periodTo!) : 'today';
    return '$from  to  $to';
  }

  pw.Widget _customerBlock() {
    final cells = <List<String>>[
      ['Customer', customer.customerName],
      if (customer.customerCode != null && customer.customerCode!.isNotEmpty)
        ['Code', customer.customerCode!],
      if (customer.phone != null && customer.phone!.isNotEmpty)
        ['Phone', customer.phone!],
      if (customer.address != null && customer.address!.isNotEmpty)
        ['Address', customer.address!],
      if (customer.areaName != null) ['Area', customer.areaName!],
      if (_showDeposit && customer.depositAmount > 0)
        ['Deposit held', _money(customer.depositAmount)],
    ];

    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        color: _zebra,
        borderRadius: pw.BorderRadius.circular(4),
        border: pw.Border.all(color: _line, width: 0.5),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: cells
            .map(
              (c) => pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 1),
                child: pw.Row(
                  children: [
                    pw.SizedBox(
                      width: 70,
                      child: pw.Text(
                        c[0],
                        style: pw.TextStyle(fontSize: 8, color: _muted),
                      ),
                    ),
                    pw.Expanded(
                      child: pw.Text(
                        c[1],
                        style: pw.TextStyle(
                          fontSize: 8.5,
                          fontWeight: pw.FontWeight.bold,
                          color: _ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  pw.Widget _table() {
    // Column order and visibility come from cardsettings so a tenant can print
    // a card that matches the one their customers already recognise.
    final configured = (_settings['columns'] as List?)?.cast<String>() ??
        const ['date', 'delivered', 'received', 'balance', 'amount', 'paid'];

    const labels = {
      'date': 'Date',
      'delivered': 'Delivery\nBottles',
      'received': 'Received\nBottles',
      'balance': 'Bottle\nBalance',
      'amount': 'Total\nAmount',
      'paid': 'Amount\nReceived',
      'due': 'Balance\nDue',
    };

    final columns = configured.where(labels.containsKey).toList();

    String cell(WsDeliveryCardRow r, String key) {
      switch (key) {
        case 'date':
          return _dayFmt.format(r.entryDate);
        case 'delivered':
          return r.deliveryBottles == 0 ? '—' : '${r.deliveryBottles}';
        case 'received':
          return r.receivedBottles == 0 ? '—' : '${r.receivedBottles}';
        case 'balance':
          return '${r.bottleBalance}';
        case 'amount':
          return r.totalAmount == 0 ? '—' : _moneyFmt.format(r.totalAmount);
        case 'paid':
          return r.amountReceived == 0 ? '—' : _moneyFmt.format(r.amountReceived);
        case 'due':
          return _moneyFmt.format(r.runningBalance);
        default:
          return '';
      }
    }

    pw.Widget headerCell(String key) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 3),
      alignment: key == 'date' ? pw.Alignment.centerLeft : pw.Alignment.centerRight,
      child: pw.Text(
        labels[key]!,
        textAlign: key == 'date' ? pw.TextAlign.left : pw.TextAlign.right,
        style: pw.TextStyle(
          fontSize: 7.5,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
    );

    pw.Widget dataCell(WsDeliveryCardRow r, String key) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 3),
      alignment: key == 'date' ? pw.Alignment.centerLeft : pw.Alignment.centerRight,
      child: pw.Text(
        cell(r, key),
        style: pw.TextStyle(fontSize: 8, color: _ink),
      ),
    );

    if (rows.isEmpty) {
      return pw.Container(
        padding: const pw.EdgeInsets.all(16),
        alignment: pw.Alignment.center,
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.5)),
        child: pw.Text(
          'No deliveries or payments in this period.',
          style: pw.TextStyle(fontSize: 9, color: _muted),
        ),
      );
    }

    return pw.Table(
      border: pw.TableBorder.all(color: _line, width: 0.5),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _headerBg),
          children: columns.map(headerCell).toList(),
        ),
        for (var i = 0; i < rows.length; i++)
          pw.TableRow(
            decoration: pw.BoxDecoration(
              color: i.isEven ? PdfColors.white : _zebra,
            ),
            children: columns.map((k) => dataCell(rows[i], k)).toList(),
          ),
      ],
    );
  }

  pw.Widget _totals() {
    pw.Widget line(String label, String value, {bool bold = false, PdfColor? color}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                label,
                style: pw.TextStyle(
                  fontSize: 8.5,
                  color: color ?? _muted,
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                ),
              ),
              pw.Text(
                value,
                style: pw.TextStyle(
                  fontSize: bold ? 10 : 8.5,
                  color: color ?? _ink,
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                ),
              ),
            ],
          ),
        );

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              line('Bottles delivered', '$totalDelivered'),
              line('Bottles received', '$totalReceived'),
              line('Bottles with customer', '$closingBottles', bold: true),
            ],
          ),
        ),
        pw.SizedBox(width: 16),
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              color: _zebra,
              borderRadius: pw.BorderRadius.circular(4),
              border: pw.Border.all(color: _line, width: 0.5),
            ),
            child: pw.Column(
              children: [
                line('Total charged', _money(totalAmount)),
                line('Total received', _money(totalPaid)),
                pw.Divider(color: _line, thickness: 0.5, height: 8),
                line(
                  closingBalance >= 0 ? 'Balance due' : 'Advance held',
                  _money(closingBalance.abs()),
                  bold: true,
                  color: closingBalance > 0 ? _due : _accent,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  pw.Widget _bottleBreakdown() => pw.Container(
    padding: const pw.EdgeInsets.all(6),
    decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.5)),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Bottles held by type',
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
            color: _ink,
          ),
        ),
        pw.SizedBox(height: 3),
        // The Bottle Balance column above tracks the default type only, which is
        // what the paper card has room for. This note keeps the other types
        // visible instead of quietly dropping them.
        ...bottleBalances.map(
          (b) => pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                '${b.bottleName}${b.isDefault ? ' (shown above)' : ''}',
                style: pw.TextStyle(fontSize: 8, color: _muted),
              ),
              pw.Text(
                '${b.balance}',
                style: pw.TextStyle(
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                  color: _ink,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  pw.Widget _signatures() => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      for (final label in ['Customer signature', 'Delivered by'])
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Container(width: 120, height: 0.6, color: _line),
            pw.SizedBox(height: 3),
            pw.Text(label, style: pw.TextStyle(fontSize: 7.5, color: _muted)),
          ],
        ),
    ],
  );
}

// ─── Sharing ──────────────────────────────────────────────────────────────────

/// Share and print helpers that work on mobile, desktop AND web.
///
/// The original implementation wrote to a temporary directory with dart:io and
/// path_provider, so every action threw an unsupported-platform error in a
/// browser. Passing bytes avoids the filesystem entirely.
///
/// SHARING GOES THROUGH `printing`, NOT `share_plus`.
/// share_plus rewrote its API between 7.x and 12.x — `Share.shareXFiles(...)`
/// became `SharePlus.instance.share(ShareParams(...))` — so code written against
/// one fails to compile against the other, and a project whose pubspec is a
/// version behind gets "Undefined name 'SharePlus'". `printing` is already a
/// dependency here for the preview and print dialog, and its sharePdf() covers
/// the same ground on every platform. One dependency fewer, and no API to skew.
class WsPdfShare {
  const WsPdfShare._();

  static String fileName(WsCustomer customer, {String prefix = 'DeliveryCard'}) {
    final safe = customer.customerName
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final stamp = DateFormat('yyyyMMdd').format(DateTime.now());
    return '${prefix}_${safe.isEmpty ? 'customer' : safe}_$stamp.pdf';
  }

  /// Opens the OS share sheet. On web this triggers a download; on Windows and
  /// Linux it falls back to a save dialog, which is the sane desktop behaviour.
  static Future<void> share({
    required Uint8List bytes,
    required String name,
    String? text,
  }) async {
    await Printing.sharePdf(
      bytes: bytes,
      filename: name,
      subject: text,
    );
  }

  /// Native print dialog / preview.
  static Future<void> print({
    required Uint8List bytes,
    required String name,
  }) async {
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
  }
}

// ─── Preview screen ───────────────────────────────────────────────────────────

/// Shows the card with print and share actions.
///
/// PdfPreview builds the document lazily and rebuilds it when the page format
/// changes, so there is no need to generate bytes before navigating here.
class WsDeliveryCardScreen extends StatelessWidget {
  final WsDeliveryCardPdf card;

  const WsDeliveryCardScreen({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final name = WsPdfShare.fileName(card.customer);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Delivery Card'),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: () async {
              final bytes = await card.build();
              await WsPdfShare.share(
                bytes: bytes,
                name: name,
                text:
                    'Delivery card for ${card.customer.customerName} — '
                    '${card.org.displayName}',
              );
            },
          ),
          IconButton(
            tooltip: 'Print',
            icon: const Icon(Icons.print_outlined),
            onPressed: () async {
              final bytes = await card.build();
              await WsPdfShare.print(bytes: bytes, name: name);
            },
          ),
        ],
      ),
      body: PdfPreview(
        build: (_) => card.build(),
        initialPageFormat: card.pageFormat,
        canDebug: false,
        allowPrinting: true,
        allowSharing: true,
        pdfFileName: name,
      ),
    );
  }
}
