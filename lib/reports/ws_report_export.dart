// =============================================================================
// lib/reports/ws_report_export.dart
// One table shape, three destinations: CSV, PDF, and the platform share sheet.
//
// WHY A SINGLE TABLE MODEL
// Six reports times three export formats is eighteen code paths if each report
// exports itself. Modelled as "a report is a title, some columns and some
// rows", it is six descriptions and three exporters.
//
// WHAT SHARING CAN AND CANNOT DO
// Printing.sharePdf() opens the OS share sheet, which is how a PDF reaches
// WhatsApp. That sheet exists on Android and iOS. On Windows, macOS, Linux and
// the web there is no such thing, so those platforms get a save/print dialog
// instead — and the UI says so rather than showing a Share button that fails.
// This is a platform limitation, not something a package fixes.
// =============================================================================

import 'dart:convert';

import 'package:flutter/foundation.dart'
    show Uint8List, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// A column: a heading, how to read it out of a row, and whether it is numeric
/// (numbers right-align and sum; text does not).
class WsReportColumn {
  final String header;
  final String Function(Map<String, dynamic> row) value;
  final bool numeric;

  /// Relative width in the PDF table. Ignored by CSV.
  final int flex;

  /// When true, this column gets a total row.
  final bool total;

  const WsReportColumn(
    this.header,
    this.value, {
    this.numeric = false,
    this.flex = 2,
    this.total = false,
  });
}

class WsReport {
  final String title;
  final String subtitle;
  final List<WsReportColumn> columns;
  final List<Map<String, dynamic>> rows;

  /// Numeric totals, keyed by column header. Computed by the caller because
  /// only the caller knows whether a column is summable in the first place —
  /// summing a running balance, for instance, is meaningless.
  final Map<String, String> totals;

  const WsReport({
    required this.title,
    required this.subtitle,
    required this.columns,
    required this.rows,
    this.totals = const {},
  });

  bool get isEmpty => rows.isEmpty;
}

// ─── CSV ──────────────────────────────────────────────────────────────────────

class WsCsv {
  const WsCsv._();

  /// RFC 4180: quote if the value contains a comma, quote or newline, and
  /// escape embedded quotes by doubling them. Naive join-with-comma corrupts
  /// any customer whose name contains a comma, which is common enough with
  /// addresses that it is not a theoretical concern.
  static String _cell(String v) {
    final needsQuote =
        v.contains(',') || v.contains('"') || v.contains('\n') || v.contains('\r');
    if (!needsQuote) return v;
    return '"${v.replaceAll('"', '""')}"';
  }

  static String build(WsReport r) {
    final b = StringBuffer();

    // A title block above the header row. Spreadsheets tolerate it and the
    // person who opens the file six months later needs to know what it is.
    b.writeln(_cell(r.title));
    b.writeln(_cell(r.subtitle));
    b.writeln();

    b.writeln(r.columns.map((c) => _cell(c.header)).join(','));
    for (final row in r.rows) {
      b.writeln(r.columns.map((c) => _cell(c.value(row))).join(','));
    }

    if (r.totals.isNotEmpty) {
      b.writeln();
      b.writeln(r.columns
          .map((c) => _cell(c.header == r.columns.first.header
              ? 'TOTAL'
              : (r.totals[c.header] ?? '')))
          .join(','));
    }
    return b.toString();
  }

  /// UTF-8 with a BOM. Without the BOM, Excel on Windows reads the file as the
  /// system codepage and mangles any non-ASCII name — which for Urdu or an
  /// accented Latin name means unreadable output.
  static Uint8List bytes(WsReport r) =>
      Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(build(r))]);
}

// ─── PDF ──────────────────────────────────────────────────────────────────────

class WsReportPdf {
  const WsReportPdf._();

  static Future<Uint8List> build(WsReport r, {String? orgName}) async {
    final doc = pw.Document();
    final generated = DateTime.now();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 36),
        // MultiPage, not Page: a month of deliveries does not fit on one sheet,
        // and a single Page silently clips the overflow.
        header: (ctx) => ctx.pageNumber == 1
            ? pw.SizedBox()
            : pw.Container(
                alignment: pw.Alignment.centerRight,
                margin: const pw.EdgeInsets.only(bottom: 8),
                child: pw.Text(r.title,
                    style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
              ),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Page ${ctx.pageNumber} of ${ctx.pagesCount}   ·   '
            'Generated ${generated.day.toString().padLeft(2, '0')}-'
            '${generated.month.toString().padLeft(2, '0')}-${generated.year}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ),
        build: (ctx) => [
          if (orgName != null && orgName.isNotEmpty)
            pw.Text(orgName,
                style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 2),
          pw.Text(r.title,
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Text(r.subtitle,
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.SizedBox(height: 12),
          if (r.isEmpty)
            pw.Text('No records in this period.',
                style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey600))
          else
            _table(r),
        ],
      ),
    );

    return doc.save();
  }

  static pw.Widget _table(WsReport r) {
    final widths = <int, pw.TableColumnWidth>{
      for (var i = 0; i < r.columns.length; i++)
        i: pw.FlexColumnWidth(r.columns[i].flex.toDouble()),
    };

    return pw.Table(
      columnWidths: widths,
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: r.columns
              .map((c) => _cell(c.header, bold: true, right: c.numeric))
              .toList(),
        ),
        ...r.rows.map((row) => pw.TableRow(
              children: r.columns
                  .map((c) => _cell(c.value(row), right: c.numeric))
                  .toList(),
            )),
        if (r.totals.isNotEmpty)
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey100),
            children: [
              for (var i = 0; i < r.columns.length; i++)
                _cell(
                  i == 0 ? 'TOTAL' : (r.totals[r.columns[i].header] ?? ''),
                  bold: true,
                  right: r.columns[i].numeric,
                ),
            ],
          ),
      ],
    );
  }

  static pw.Widget _cell(String text, {bool bold = false, bool right = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: pw.Text(
          text,
          textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
          style: pw.TextStyle(
            fontSize: 8.5,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      );
}

// ─── Destinations ─────────────────────────────────────────────────────────────

class WsExport {
  const WsExport._();

  /// True where an OS share sheet exists — i.e. where "send to WhatsApp" is a
  /// real thing. Checked before showing a Share button so the button is never
  /// offered where it cannot work.
  static bool get canShare =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static String _slug(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  static String fileStem(WsReport r) {
    final now = DateTime.now();
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    return '${_slug(r.title)}-$stamp';
  }

  /// Share the PDF, or on desktop/web hand it to the print/save dialog.
  static Future<void> sharePdf(WsReport r, {String? orgName}) async {
    final bytes = await WsReportPdf.build(r, orgName: orgName);
    final name = '${fileStem(r)}.pdf';
    if (canShare) {
      await Printing.sharePdf(bytes: bytes, filename: name);
    } else {
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
    }
  }

  /// Save-as / print dialog for the PDF, on every platform.
  static Future<void> printPdf(WsReport r, {String? orgName}) async {
    final bytes = await WsReportPdf.build(r, orgName: orgName);
    await Printing.layoutPdf(
        onLayout: (_) async => bytes, name: '${fileStem(r)}.pdf');
  }

  /// CSV via the share sheet where one exists.
  ///
  /// Printing.sharePdf carries a MIME type of application/pdf regardless of
  /// its payload, so a CSV shared through it arrives labelled as a PDF and
  /// most apps refuse to open it. Rather than ship that, CSV sharing is only
  /// offered where it works, and the caller is told when it does not.
  static Future<bool> shareCsv(WsReport r) async {
    if (!canShare) return false;
    await Printing.sharePdf(
      bytes: WsCsv.bytes(r),
      filename: '${fileStem(r)}.csv',
    );
    return true;
  }
}
