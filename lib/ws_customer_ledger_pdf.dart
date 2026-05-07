// =============================================================================
// ws_customer_ledger_pdf.dart
// WaterFlow — Customer Ledger PDF Generator
//
// Dependencies (pubspec.yaml):
//   pdf: ^3.10.8
//   printing: ^5.12.0
//   share_plus: ^7.2.2
//   path_provider: ^2.1.2
//   intl: ^0.19.0
// =============================================================================

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

// ─── Data Models ─────────────────────────────────────────────────────────────

class WsCustomer {
  final int customerId;
  final String customerName;
  final String address;
  final String phone;
  final String areaName;
  final double ratePerBottle;
  final double? rateOverride;
  final double depositAmount;
  final int bottleBalance;

  double get effectiveRate => rateOverride ?? ratePerBottle;

  const WsCustomer({
    required this.customerId,
    required this.customerName,
    required this.address,
    required this.phone,
    required this.areaName,
    required this.ratePerBottle,
    this.rateOverride,
    this.depositAmount = 0,
    required this.bottleBalance,
  });
}

class WsDeliveryRow {
  final DateTime deliveryDate;
  final int bottlesDelivered;
  final int bottlesReturned;
  final int bottleBalance;
  final double rateApplied;
  final double amountCharged;
  final double amountReceived;
  final double runningBalance; // cumulative outstanding
  final String deliveredBy;
  final String? notes;

  const WsDeliveryRow({
    required this.deliveryDate,
    required this.bottlesDelivered,
    required this.bottlesReturned,
    required this.bottleBalance,
    required this.rateApplied,
    required this.amountCharged,
    required this.amountReceived,
    required this.runningBalance,
    required this.deliveredBy,
    this.notes,
  });
}

class WsPaymentRow {
  final DateTime paymentDate;
  final double amountReceived;
  final String paymentMethod;
  final String receivedBy;
  final String? referenceNo;

  const WsPaymentRow({
    required this.paymentDate,
    required this.amountReceived,
    required this.paymentMethod,
    required this.receivedBy,
    this.referenceNo,
  });
}

class WsOrganization {
  final String orgName;
  final String ownerName;
  final String phone;
  final String address;

  const WsOrganization({
    required this.orgName,
    required this.ownerName,
    required this.phone,
    required this.address,
  });
}

// ─── PDF Colors ───────────────────────────────────────────────────────────────

const _blue     = PdfColor.fromInt(0xFF0288D1);
const _darkBlue = PdfColor.fromInt(0xFF01579B);
const _lightBlue= PdfColor.fromInt(0xFFE1F5FE);
const _teal     = PdfColor.fromInt(0xFF00838F);
const _red      = PdfColor.fromInt(0xFFB3261E);
const _redLight = PdfColor.fromInt(0xFFFFEBEE);
const _green    = PdfColor.fromInt(0xFF2E7D32);
const _greenLight=PdfColor.fromInt(0xFFE8F5E9);
const _amber    = PdfColor.fromInt(0xFFE65100);
const _amberLight=PdfColor.fromInt(0xFFFFF3E0);
const _grey1    = PdfColor.fromInt(0xFF1A1C1E);
const _grey2    = PdfColor.fromInt(0xFF44474F);
const _grey3    = PdfColor.fromInt(0xFF74777F);
const _greyBg   = PdfColor.fromInt(0xFFF5F5F5);
const _border   = PdfColor.fromInt(0xFFDEE2E6);
const _white    = PdfColors.white;

// ─── Formatters ───────────────────────────────────────────────────────────────

final _dateFmt  = DateFormat('dd MMM yyyy');
final _shortFmt = DateFormat('dd-MM');
final _moneyFmt = NumberFormat('#,##0.00', 'en_US');
final _intFmt   = NumberFormat('#,##0', 'en_US');

String _rs(double v) => 'Rs ${_moneyFmt.format(v)}';

// ─── Main Generator ───────────────────────────────────────────────────────────

class WsCustomerLedgerPdf {
  final WsOrganization org;
  final WsCustomer customer;
  final List<WsDeliveryRow> deliveries;
  final List<WsPaymentRow> payments;
  final DateTime reportDate;
  final DateTime? periodFrom;
  final DateTime? periodTo;

  WsCustomerLedgerPdf({
    required this.org,
    required this.customer,
    required this.deliveries,
    required this.payments,
    DateTime? reportDate,
    this.periodFrom,
    this.periodTo,
  }) : reportDate = reportDate ?? DateTime.now();

  // ── Computed Totals ──────────────────────────────────────────────────────

  double get totalCharged   => deliveries.fold(0, (s, d) => s + d.amountCharged);
  double get totalReceived  => payments.fold(0, (s, p) => s + p.amountReceived);
  double get outstandingDue => totalCharged - totalReceived;
  int    get totalDelivered => deliveries.fold(0, (s, d) => s + d.bottlesDelivered);
  int    get totalReturned  => deliveries.fold(0, (s, d) => s + d.bottlesReturned);

  // ── Build PDF ────────────────────────────────────────────────────────────

  Future<Uint8List> buildPdf() async {
    final doc = pw.Document(
      title: 'Customer Ledger — ${customer.customerName}',
      author: org.orgName,
    );

    final font       = await PdfGoogleFonts.robotoRegular();
    final fontBold   = await PdfGoogleFonts.robotoBold();
    final fontMedium = await PdfGoogleFonts.robotoMedium();
    final fontMono   = await PdfGoogleFonts.robotoMonoRegular();

    final tf = pw.ThemeData.withFont(
      base: font,
      bold: fontBold,
    );

    doc.addPage(
      pw.MultiPage(
        theme: tf,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 28),
        header: (ctx) => _buildHeader(ctx, fontBold, fontMedium),
        footer: (ctx) => _buildFooter(ctx, font),
        build: (ctx) => [
          _customerInfoCard(fontBold, fontMedium, font),
          pw.SizedBox(height: 14),
          _summaryKpiRow(fontBold, fontMedium),
          pw.SizedBox(height: 18),
          _sectionTitle('Delivery & Payment Ledger', fontBold),
          pw.SizedBox(height: 8),
          _deliveryTable(fontBold, fontMedium, font, fontMono),
          pw.SizedBox(height: 18),
          _sectionTitle('Payment History', fontBold),
          pw.SizedBox(height: 8),
          _paymentTable(fontBold, fontMedium, font),
          pw.SizedBox(height: 18),
          _outstandingBox(fontBold, fontMedium),
          pw.SizedBox(height: 24),
          _signatureRow(fontMedium, font),
        ],
      ),
    );

    return doc.save();
  }

  // ── Header ────────────────────────────────────────────────────────────────

  pw.Widget _buildHeader(pw.Context ctx, pw.Font bold, pw.Font medium) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        color: _darkBlue,
        borderRadius: pw.BorderRadius.only(
          topLeft: pw.Radius.circular(8),
          topRight: pw.Radius.circular(8),
        ),
      ),
      padding: const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                '💧 ${org.orgName}',
                style: pw.TextStyle(font: bold, fontSize: 16, color: _white),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                '${org.phone}  |  ${org.address}',
                style: pw.TextStyle(font: medium, fontSize: 9, color: PdfColor.fromInt(0xFFB3E5FC)),
              ),
            ],
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                'CUSTOMER LEDGER',
                style: pw.TextStyle(font: bold, fontSize: 13, color: _white, letterSpacing: 1.5),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                'Generated: ${_dateFmt.format(reportDate)}',
                style: pw.TextStyle(font: medium, fontSize: 9, color: PdfColor.fromInt(0xFFB3E5FC)),
              ),
              if (periodFrom != null && periodTo != null)
                pw.Text(
                  'Period: ${_dateFmt.format(periodFrom!)} – ${_dateFmt.format(periodTo!)}',
                  style: pw.TextStyle(font: medium, fontSize: 9, color: PdfColor.fromInt(0xFFB3E5FC)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Footer ────────────────────────────────────────────────────────────────

  pw.Widget _buildFooter(pw.Context ctx, pw.Font font) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _border, width: .5)),
      ),
      padding: const pw.EdgeInsets.only(top: 6),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            '${org.orgName} — Confidential',
            style: pw.TextStyle(font: font, fontSize: 8, color: _grey3),
          ),
          pw.Text(
            'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            style: pw.TextStyle(font: font, fontSize: 8, color: _grey3),
          ),
        ],
      ),
    );
  }

  // ── Customer Info Card ────────────────────────────────────────────────────

  pw.Widget _customerInfoCard(pw.Font bold, pw.Font medium, pw.Font font) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        color: _lightBlue,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        border: const pw.Border.fromBorderSide(pw.BorderSide(color: _blue, width: .8)),
      ),
      padding: const pw.EdgeInsets.all(14),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(customer.customerName,
                    style: pw.TextStyle(font: bold, fontSize: 15, color: _darkBlue)),
                pw.SizedBox(height: 4),
                _infoRow('📍 Address', customer.address, font, medium),
                _infoRow('📞 Phone',   customer.phone,   font, medium),
                _infoRow('🗺️ Area',    customer.areaName, font, medium),
              ],
            ),
          ),
          pw.SizedBox(width: 20),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              _infoRow('Rate/Bottle', _rs(customer.effectiveRate), font, medium),
              if (customer.rateOverride != null)
                pw.Text('(Override)', style: pw.TextStyle(font: font, fontSize: 8, color: _amber)),
              _infoRow('Deposit', _rs(customer.depositAmount), font, medium),
              _infoRow('Acct ID', '#${customer.customerId.toString().padLeft(4, '0')}', font, medium),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _infoRow(String label, String value, pw.Font font, pw.Font medium) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 3),
      child: pw.Row(
        children: [
          pw.Text('$label: ', style: pw.TextStyle(font: medium, fontSize: 9, color: _grey2)),
          pw.Text(value,       style: pw.TextStyle(font: font,   fontSize: 9, color: _grey1)),
        ],
      ),
    );
  }

  // ── KPI Summary Row ───────────────────────────────────────────────────────

  pw.Widget _summaryKpiRow(pw.Font bold, pw.Font medium) {
    return pw.Row(
      children: [
        _kpiBox('Total Delivered', '$totalDelivered btl', _blue,      bold, medium),
        pw.SizedBox(width: 8),
        _kpiBox('Total Returned',  '$totalReturned btl',  _teal,      bold, medium),
        pw.SizedBox(width: 8),
        _kpiBox('Bottle Balance',  '${customer.bottleBalance} btl', _amber, bold, medium),
        pw.SizedBox(width: 8),
        _kpiBox('Total Charged',   _rs(totalCharged),     _grey2,     bold, medium),
        pw.SizedBox(width: 8),
        _kpiBox('Total Received',  _rs(totalReceived),    _green,     bold, medium),
        pw.SizedBox(width: 8),
        _kpiBox('Outstanding',     _rs(outstandingDue),
            outstandingDue > 0 ? _red : _green, bold, medium,
            highlight: true),
      ],
    );
  }

  pw.Widget _kpiBox(String label, String value, PdfColor color,
      pw.Font bold, pw.Font medium, {bool highlight = false}) {
    return pw.Expanded(
      child: pw.Container(
        decoration: pw.BoxDecoration(
          color: highlight && outstandingDue > 0 ? _redLight : _greyBg,
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          border: pw.Border.fromBorderSide(
            pw.BorderSide(color: color, width: highlight ? 1.5 : .5),
          ),
        ),
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(label, style: pw.TextStyle(font: medium, fontSize: 7.5, color: _grey3)),
            pw.SizedBox(height: 3),
            pw.Text(value, style: pw.TextStyle(font: bold, fontSize: 9.5, color: color)),
          ],
        ),
      ),
    );
  }

  // ── Section Title ─────────────────────────────────────────────────────────

  pw.Widget _sectionTitle(String title, pw.Font bold) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _blue, width: 1.5)),
      ),
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Text(title,
          style: pw.TextStyle(font: bold, fontSize: 12, color: _darkBlue)),
    );
  }

  // ── Delivery Table ────────────────────────────────────────────────────────

  pw.Widget _deliveryTable(pw.Font bold, pw.Font medium, pw.Font font, pw.Font mono) {
    const headers = ['Date', 'Delivered', 'Returned', 'Btl Balance', 'Rate', 'Charged', 'Received', 'Outstanding', 'By'];
    final colWidths = [50.0, 48.0, 48.0, 52.0, 36.0, 52.0, 52.0, 60.0, 50.0];

    pw.Widget cell(String text, pw.Font f, {
      PdfColor color = _grey1,
      pw.Alignment align = pw.Alignment.centerLeft,
      double fontSize = 8.5,
      PdfColor? bg,
    }) {
      return pw.Container(
        color: bg,
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
        alignment: align,
        child: pw.Text(text, style: pw.TextStyle(font: f, fontSize: fontSize, color: color)),
      );
    }

    return pw.Table(
      columnWidths: {
        for (int i = 0; i < colWidths.length; i++)
          i: pw.FixedColumnWidth(colWidths[i]),
      },
      border: pw.TableBorder.all(color: _border, width: .4),
      children: [
        // Header row
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _darkBlue),
          children: headers.map((h) => pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 6),
            child: pw.Text(h, style: pw.TextStyle(
              font: bold, fontSize: 8, color: _white)),
          )).toList(),
        ),
        // Data rows
        ...deliveries.asMap().entries.map((entry) {
          final i = entry.key;
          final d = entry.value;
          final even = i.isEven;
          final bg = even ? _white : _greyBg;
          final overdue = d.runningBalance > 0;

          return pw.TableRow(
            decoration: pw.BoxDecoration(color: bg),
            children: [
              cell(_shortFmt.format(d.deliveryDate), font),
              cell('${d.bottlesDelivered}', font, align: pw.Alignment.center),
              cell('${d.bottlesReturned}', font, align: pw.Alignment.center),
              cell('${d.bottleBalance}', medium,
                  align: pw.Alignment.center, color: _blue),
              cell(_rs(d.rateApplied), font, fontSize: 7.5),
              cell(_rs(d.amountCharged), medium,
                  align: pw.Alignment.centerRight),
              cell(d.amountReceived > 0 ? _rs(d.amountReceived) : '—', font,
                  align: pw.Alignment.centerRight,
                  color: d.amountReceived > 0 ? _green : _grey3),
              cell(_rs(d.runningBalance), medium,
                  align: pw.Alignment.centerRight,
                  color: overdue ? _red : _green,
                  bg: overdue ? _redLight : _greenLight),
              cell(d.deliveredBy, font, fontSize: 7.5, color: _grey2),
            ],
          );
        }),
        // Totals row
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _lightBlue),
          children: [
            pw.Padding(
              padding: const pw.EdgeInsets.all(5),
              child: pw.Text('TOTAL', style: pw.TextStyle(font: bold, fontSize: 8.5, color: _darkBlue)),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.all(5),
              child: pw.Text('$totalDelivered',
                  style: pw.TextStyle(font: bold, fontSize: 8.5, color: _darkBlue),
                  textAlign: pw.TextAlign.center),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.all(5),
              child: pw.Text('$totalReturned',
                  style: pw.TextStyle(font: bold, fontSize: 8.5, color: _darkBlue),
                  textAlign: pw.TextAlign.center),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.all(5),
              child: pw.Text('${customer.bottleBalance}',
                  style: pw.TextStyle(font: bold, fontSize: 8.5, color: _blue),
                  textAlign: pw.TextAlign.center),
            ),
            pw.SizedBox(),
            pw.Padding(
              padding: const pw.EdgeInsets.all(5),
              child: pw.Text(_rs(totalCharged),
                  style: pw.TextStyle(font: bold, fontSize: 8.5, color: _darkBlue),
                  textAlign: pw.TextAlign.right),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.all(5),
              child: pw.Text(_rs(totalReceived),
                  style: pw.TextStyle(font: bold, fontSize: 8.5, color: _green),
                  textAlign: pw.TextAlign.right),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.all(5),
              child: pw.Text(_rs(outstandingDue),
                  style: pw.TextStyle(font: bold, fontSize: 8.5,
                      color: outstandingDue > 0 ? _red : _green),
                  textAlign: pw.TextAlign.right),
            ),
            pw.SizedBox(),
          ],
        ),
      ],
    );
  }

  // ── Payment Table ─────────────────────────────────────────────────────────

  pw.Widget _paymentTable(pw.Font bold, pw.Font medium, pw.Font font) {
    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(70),
        1: pw.FixedColumnWidth(80),
        2: pw.FixedColumnWidth(80),
        3: pw.FixedColumnWidth(60),
        4: pw.FlexColumnWidth(),
      },
      border: pw.TableBorder.all(color: _border, width: .4),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _teal),
          children: ['Date', 'Method', 'Received By', 'Reference', 'Amount']
              .map((h) => pw.Padding(
                padding: const pw.EdgeInsets.all(5),
                child: pw.Text(h, style: pw.TextStyle(font: bold, fontSize: 8, color: _white)),
              )).toList(),
        ),
        ...payments.asMap().entries.map((e) {
          final p = e.value;
          final bg = e.key.isEven ? _white : _greyBg;
          return pw.TableRow(
            decoration: pw.BoxDecoration(color: bg),
            children: [
              pw.Padding(padding: const pw.EdgeInsets.all(5),
                  child: pw.Text(_dateFmt.format(p.paymentDate),
                      style: pw.TextStyle(font: font, fontSize: 8))),
              pw.Padding(padding: const pw.EdgeInsets.all(5),
                  child: pw.Text(p.paymentMethod,
                      style: pw.TextStyle(font: medium, fontSize: 8))),
              pw.Padding(padding: const pw.EdgeInsets.all(5),
                  child: pw.Text(p.receivedBy,
                      style: pw.TextStyle(font: font, fontSize: 8))),
              pw.Padding(padding: const pw.EdgeInsets.all(5),
                  child: pw.Text(p.referenceNo ?? '—',
                      style: pw.TextStyle(font: font, fontSize: 7.5, color: _grey3))),
              pw.Padding(
                padding: const pw.EdgeInsets.all(5),
                child: pw.Text(_rs(p.amountReceived),
                    style: pw.TextStyle(font: bold, fontSize: 9, color: _green),
                    textAlign: pw.TextAlign.right),
              ),
            ],
          );
        }),
        // Totals
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _greenLight),
          children: [
            pw.Padding(padding: const pw.EdgeInsets.all(5),
                child: pw.Text('TOTAL', style: pw.TextStyle(font: bold, fontSize: 8.5, color: _green))),
            pw.SizedBox(), pw.SizedBox(), pw.SizedBox(),
            pw.Padding(
              padding: const pw.EdgeInsets.all(5),
              child: pw.Text(_rs(totalReceived),
                  style: pw.TextStyle(font: bold, fontSize: 9.5, color: _green),
                  textAlign: pw.TextAlign.right),
            ),
          ],
        ),
      ],
    );
  }

  // ── Outstanding Box ───────────────────────────────────────────────────────

  pw.Widget _outstandingBox(pw.Font bold, pw.Font medium) {
    final overdue = outstandingDue > 0;
    return pw.Container(
      decoration: pw.BoxDecoration(
        color: overdue ? _redLight : _greenLight,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        border: pw.Border.fromBorderSide(
          pw.BorderSide(color: overdue ? _red : _green, width: 1.5),
        ),
      ),
      padding: const pw.EdgeInsets.all(14),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Net Outstanding Balance',
                  style: pw.TextStyle(font: medium, fontSize: 10,
                      color: overdue ? _red : _green)),
              pw.SizedBox(height: 2),
              pw.Text(
                overdue
                    ? 'Amount due from customer as of ${_dateFmt.format(reportDate)}'
                    : 'Account is fully settled ✓',
                style: pw.TextStyle(font: medium, fontSize: 8, color: _grey3),
              ),
            ],
          ),
          pw.Text(_rs(outstandingDue.abs()),
              style: pw.TextStyle(font: bold, fontSize: 20,
                  color: overdue ? _red : _green)),
        ],
      ),
    );
  }

  // ── Signature Row ─────────────────────────────────────────────────────────

  pw.Widget _signatureRow(pw.Font medium, pw.Font font) {
    pw.Widget sigBox(String label) => pw.Expanded(
      child: pw.Column(
        children: [
          pw.Container(height: 40),
          pw.Divider(color: _grey3, thickness: .5),
          pw.SizedBox(height: 3),
          pw.Text(label, style: pw.TextStyle(font: medium, fontSize: 8, color: _grey2)),
        ],
      ),
    );
    return pw.Row(
      children: [
        sigBox('Customer Signature'),
        pw.SizedBox(width: 40),
        sigBox('Authorized Signature (${org.orgName})'),
      ],
    );
  }
}

// ─── Share Service ────────────────────────────────────────────────────────────

class WsPdfShareService {
  /// Generate customer ledger PDF bytes and save to temp file.
  static Future<File> saveCustomerLedger(WsCustomerLedgerPdf generator) async {
    final bytes = await generator.buildPdf();
    final dir   = await getTemporaryDirectory();
    final safe  = generator.customer.customerName.replaceAll(RegExp(r'[^\w]'), '_');
    final date  = DateFormat('yyyyMMdd').format(DateTime.now());
    final file  = File('${dir.path}/CustomerLedger_${safe}_$date.pdf');
    await file.writeAsBytes(bytes);
    return file;
  }

  /// Share via system share sheet (WhatsApp, email, drive, etc.)
  static Future<void> shareFile({
    required File file,
    required String customerName,
    String? subject,
    String? text,
    Rect? sharePositionOrigin,  // for iPad
  }) async {
    final result = await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/pdf')],
      subject: subject ?? 'Customer Ledger — $customerName',
      text: text ?? 'Please find attached the water delivery ledger for $customerName.',
      sharePositionOrigin: sharePositionOrigin,
    );
    debugPrint('Share result: ${result.status}');
  }

  /// Direct WhatsApp share (Android deeplink, falls back to share sheet)
  static Future<void> shareWhatsApp({
    required File file,
    required String phoneNumber, // format: 92XXXXXXXXXX (country code, no +)
    required String customerName,
  }) async {
    // WhatsApp doesn't support direct file share via URL scheme on all versions.
    // Best practice: use Share.shareXFiles and let user pick WhatsApp,
    // OR use whatsapp_share2 package for direct message.
    await shareFile(file: file, customerName: customerName,
        text: 'Assalam-o-Alaikum! Please find your water delivery ledger attached. — ${file.path.split('/').last}');
  }

  /// Open PDF in system viewer
  static Future<void> printOrPreview(Uint8List pdfBytes, String title) async {
    await Printing.layoutPdf(
      onLayout: (_) async => pdfBytes,
      name: title,
    );
  }

  /// Print directly to a printer
  static Future<void> printDirect(Uint8List pdfBytes) async {
    await Printing.directPrintPdf(
      printer: await Printing.pickPrinter(context: null) ?? const Printer(url: ''),
      onLayout: (_) async => pdfBytes,
    );
  }
}

// ─── Flutter UI Widget ────────────────────────────────────────────────────────

class WsCustomerLedgerScreen extends StatelessWidget {
  final WsOrganization org;
  final WsCustomer customer;
  final List<WsDeliveryRow> deliveries;
  final List<WsPaymentRow> payments;

  const WsCustomerLedgerScreen({
    super.key,
    required this.org,
    required this.customer,
    required this.deliveries,
    required this.payments,
  });

  Future<void> _generateAndShare(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      messenger.showSnackBar(const SnackBar(
        content: Text('⏳ Generating PDF…'),
        duration: Duration(seconds: 2),
      ));

      final generator = WsCustomerLedgerPdf(
        org: org,
        customer: customer,
        deliveries: deliveries,
        payments: payments,
      );

      final file = await WsPdfShareService.saveCustomerLedger(generator);

      if (!context.mounted) return;

      // Show action bottom sheet
      await showModalBottomSheet(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => WsShareSheet(file: file, customerName: customer.customerName,
            pdfBytes: await generator.buildPdf()),
      );

    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('❌ Error: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final gen = WsCustomerLedgerPdf(
        org: org, customer: customer,
        deliveries: deliveries, payments: payments);

    return Scaffold(
      appBar: AppBar(
        title: Text('Ledger — ${customer.customerName}'),
        backgroundColor: const Color(0xFF01579B),
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.print), onPressed: () async {
            final bytes = await gen.buildPdf();
            await WsPdfShareService.printOrPreview(bytes, 'Customer Ledger');
          }),
          IconButton(icon: const Icon(Icons.share), onPressed: () => _generateAndShare(context)),
        ],
      ),
      body: PdfPreview(
        build: (_) => gen.buildPdf(),
        allowPrinting: true,
        allowSharing: true,
        initialPageFormat: PdfPageFormat.a4,
        pdfFileName: 'CustomerLedger_${customer.customerName}.pdf',
      ),
    );
  }
}

// ─── Share Bottom Sheet ───────────────────────────────────────────────────────

class WsShareSheet extends StatelessWidget {
  final File file;
  final String customerName;
  final Uint8List pdfBytes;

  const WsShareSheet({
    super.key,
    required this.file,
    required this.customerName,
    required this.pdfBytes,
  });

  @override
  Widget build(BuildContext context) {
    final options = [
      _ShareOption('WhatsApp',   '💬', const Color(0xFF25D366), () async {
        Navigator.pop(context);
        await WsPdfShareService.shareWhatsApp(file: file, customerName: customerName, phoneNumber: '');
      }),
      _ShareOption('Email',      '📧', const Color(0xFF0288D1), () async {
        Navigator.pop(context);
        await WsPdfShareService.shareFile(file: file, customerName: customerName,
            subject: 'Water Delivery Ledger — $customerName');
      }),
      _ShareOption('Google Drive','📁', const Color(0xFF4285F4), () async {
        Navigator.pop(context);
        await WsPdfShareService.shareFile(file: file, customerName: customerName);
      }),
      _ShareOption('Print',      '🖨️', const Color(0xFF01579B), () async {
        Navigator.pop(context);
        await WsPdfShareService.printOrPreview(pdfBytes, 'Customer Ledger — $customerName');
      }),
      _ShareOption('Save / Other','📤', const Color(0xFF44474F), () async {
        Navigator.pop(context);
        await WsPdfShareService.shareFile(file: file, customerName: customerName);
      }),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 36, height: 4, decoration: BoxDecoration(
              color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 14),
          Text('Share Ledger — $customerName',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 4),
          Text(file.path.split('/').last,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 5,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: options.map((o) => GestureDetector(
              onTap: o.onTap,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color: o.color.withOpacity(.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: o.color.withOpacity(.3)),
                  ),
                  child: Center(child: Text(o.icon, style: const TextStyle(fontSize: 22))),
                ),
                const SizedBox(height: 4),
                Text(o.label, style: const TextStyle(fontSize: 9.5),
                    textAlign: TextAlign.center, maxLines: 2),
              ]),
            )).toList(),
          ),
        ],
      ),
    );
  }
}

class _ShareOption {
  final String label, icon;
  final Color color;
  final VoidCallback onTap;
  _ShareOption(this.label, this.icon, this.color, this.onTap);
}

// ─── Sample Data Helper (for testing) ─────────────────────────────────────────

WsCustomerLedgerPdf sampleCustomerLedger() {
  const org = WsOrganization(
    orgName: 'Kent Water — House of Purity',
    ownerName: 'Tanveer Ahmed',
    phone: '0312-2029171',
    address: 'Karachi, Sindh',
  );

  const customer = WsCustomer(
    customerId: 1,
    customerName: 'Ahmed Khan',
    address: 'House 12, Street 4, Karachi West',
    phone: '0312-1234567',
    areaName: 'Karachi West',
    ratePerBottle: 80,
    bottleBalance: 5,
  );

  final deliveries = [
    WsDeliveryRow(deliveryDate: DateTime(2024,1,1),  bottlesDelivered:4,  bottlesReturned:4,  bottleBalance:26, rateApplied:80, amountCharged:2640, amountReceived:2640, runningBalance:0,    deliveredBy:'Tanveer'),
    WsDeliveryRow(deliveryDate: DateTime(2024,1,10), bottlesDelivered:4,  bottlesReturned:4,  bottleBalance:4,  rateApplied:80, amountCharged:320,  amountReceived:0,    runningBalance:320,  deliveredBy:'Arab'),
    WsDeliveryRow(deliveryDate: DateTime(2024,2,3),  bottlesDelivered:4,  bottlesReturned:4,  bottleBalance:4,  rateApplied:80, amountCharged:320,  amountReceived:0,    runningBalance:640,  deliveredBy:'Tanveer'),
    WsDeliveryRow(deliveryDate: DateTime(2024,3,1),  bottlesDelivered:5,  bottlesReturned:3,  bottleBalance:5,  rateApplied:80, amountCharged:400,  amountReceived:2000, runningBalance:400,  deliveredBy:'Arab'),
    WsDeliveryRow(deliveryDate: DateTime(2024,3,16), bottlesDelivered:5,  bottlesReturned:5,  bottleBalance:5,  rateApplied:80, amountCharged:400,  amountReceived:0,    runningBalance:800,  deliveredBy:'Tanveer'),
    WsDeliveryRow(deliveryDate: DateTime(2024,3,25), bottlesDelivered:2,  bottlesReturned:2,  bottleBalance:5,  rateApplied:80, amountCharged:160,  amountReceived:0,    runningBalance:960,  deliveredBy:'Arab'),
  ];

  final payments = [
    WsPaymentRow(paymentDate: DateTime(2024,1,1),  amountReceived:2640, paymentMethod:'Cash',      receivedBy:'Tanveer', referenceNo: null),
    WsPaymentRow(paymentDate: DateTime(2024,3,1),  amountReceived:2000, paymentMethod:'Easypaisa', receivedBy:'Arab',    referenceNo:'EP-4821'),
  ];

  return WsCustomerLedgerPdf(org: org, customer: customer, deliveries: deliveries, payments: payments);
}
