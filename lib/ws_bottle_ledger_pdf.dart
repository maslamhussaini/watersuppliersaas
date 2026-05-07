// =============================================================================
// ws_bottle_ledger_pdf.dart
// WaterFlow — Bottle Inventory / Ledger PDF Generator
//
// Same dependencies as ws_customer_ledger_pdf.dart
// =============================================================================

import 'dart:io';
import 'package:flutter/material.dart' show BuildContext, Color, Colors,
    Column, Container, CrossAxisAlignment, EdgeInsets, Expanded, FontWeight,
    GestureDetector, GridView, Icon, IconButton, Icons, MainAxisAlignment,
    MainAxisSize, ModalBottomSheetRoute, Navigator, Padding, Row, Scaffold,
    ScaffoldMessenger, ScaffoldMessengerState, SnackBar, SnackBarContent,
    StatelessWidget, Text, TextStyle, VoidCallback, Widget, debugPrint,
    showModalBottomSheet, BorderRadius, Border, BoxDecoration;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'ws_customer_ledger_pdf.dart'
    show WsOrganization, WsPdfShareService, _ShareOption;

// ─── Models ───────────────────────────────────────────────────────────────────

enum WsBottleCondition { perfect, needsCleaning, damaged, lost }

extension WsBottleConditionExt on WsBottleCondition {
  String get label {
    switch (this) {
      case WsBottleCondition.perfect:       return 'Perfect';
      case WsBottleCondition.needsCleaning: return 'Needs Cleaning';
      case WsBottleCondition.damaged:       return 'Damaged';
      case WsBottleCondition.lost:          return 'Lost';
    }
  }
  String get emoji {
    switch (this) {
      case WsBottleCondition.perfect:       return '✅';
      case WsBottleCondition.needsCleaning: return '🧹';
      case WsBottleCondition.damaged:       return '⚠️';
      case WsBottleCondition.lost:          return '❌';
    }
  }
  PdfColor get color {
    switch (this) {
      case WsBottleCondition.perfect:       return const PdfColor.fromInt(0xFF2E7D32);
      case WsBottleCondition.needsCleaning: return const PdfColor.fromInt(0xFFE65100);
      case WsBottleCondition.damaged:       return const PdfColor.fromInt(0xFFB3261E);
      case WsBottleCondition.lost:          return const PdfColor.fromInt(0xFF74777F);
    }
  }
  PdfColor get lightColor {
    switch (this) {
      case WsBottleCondition.perfect:       return const PdfColor.fromInt(0xFFE8F5E9);
      case WsBottleCondition.needsCleaning: return const PdfColor.fromInt(0xFFFFF3E0);
      case WsBottleCondition.damaged:       return const PdfColor.fromInt(0xFFFFEBEE);
      case WsBottleCondition.lost:          return const PdfColor.fromInt(0xFFF5F5F5);
    }
  }
}

class WsBottle {
  final String bottleCode;         // e.g. BT-0042
  final WsBottleCondition condition;
  final bool isFilled;
  final bool isWithCustomer;
  final String? customerName;
  final DateTime? lastDeliveryDate;
  final DateTime? lastReturnDate;
  final String? notes;

  const WsBottle({
    required this.bottleCode,
    required this.condition,
    required this.isFilled,
    required this.isWithCustomer,
    this.customerName,
    this.lastDeliveryDate,
    this.lastReturnDate,
    this.notes,
  });

  String get statusLabel {
    if (isWithCustomer) return 'With Customer';
    if (isFilled)       return 'Filled (Ready)';
    return 'Empty (Returned)';
  }
}

class WsBottleLedgerEntry {
  final DateTime date;
  final String action;      // 'Delivered' | 'Returned' | 'Filled' | 'Cleaned' | 'Written Off'
  final int filledCount;
  final int emptyCount;
  final int deliveredCount;
  final int returnedCount;
  final int cleanedCount;
  final int damagedCount;
  final int lostCount;
  final int stockFilled;    // running stock of filled bottles
  final int stockEmpty;     // running stock of empty bottles
  final int withCustomers;  // running total with customers
  final String by;
  final String? notes;

  const WsBottleLedgerEntry({
    required this.date,
    required this.action,
    this.filledCount    = 0,
    this.emptyCount     = 0,
    this.deliveredCount = 0,
    this.returnedCount  = 0,
    this.cleanedCount   = 0,
    this.damagedCount   = 0,
    this.lostCount      = 0,
    required this.stockFilled,
    required this.stockEmpty,
    required this.withCustomers,
    required this.by,
    this.notes,
  });
}

class WsBottleInventorySnapshot {
  final DateTime snapshotDate;
  final int totalBottles;
  final int bottlesWithCustomers;
  final int bottlesInStock;        // filled
  final int bottlesEmptyInStock;   // empty awaiting refill
  final int bottlesPerfect;
  final int bottlesNeedsCleaning;
  final int bottlesDamaged;
  final int bottlesLost;

  const WsBottleInventorySnapshot({
    required this.snapshotDate,
    required this.totalBottles,
    required this.bottlesWithCustomers,
    required this.bottlesInStock,
    required this.bottlesEmptyInStock,
    required this.bottlesPerfect,
    required this.bottlesNeedsCleaning,
    required this.bottlesDamaged,
    required this.bottlesLost,
  });

  double get healthScore {
    if (totalBottles == 0) return 0;
    return bottlesPerfect / totalBottles * 100;
  }
}

// ─── PDF Colors (same palette) ────────────────────────────────────────────────

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
const _purple   = PdfColor.fromInt(0xFF6A1B9A);
const _purpleLight=PdfColor.fromInt(0xFFF3E5F5);
const _grey1    = PdfColor.fromInt(0xFF1A1C1E);
const _grey2    = PdfColor.fromInt(0xFF44474F);
const _grey3    = PdfColor.fromInt(0xFF74777F);
const _greyBg   = PdfColor.fromInt(0xFFF5F5F5);
const _border   = PdfColor.fromInt(0xFFDEE2E6);
const _white    = PdfColors.white;

final _dateFmt  = DateFormat('dd MMM yyyy');
final _shortFmt = DateFormat('dd-MM');
String _rs(double v) => NumberFormat('#,##0', 'en_US').format(v);

// ─── Main Generator ───────────────────────────────────────────────────────────

class WsBottleLedgerPdf {
  final WsOrganization org;
  final WsBottleInventorySnapshot snapshot;
  final List<WsBottleLedgerEntry> ledger;
  final List<WsBottle> bottles;          // individual bottle list
  final DateTime reportDate;
  final DateTime? periodFrom;
  final DateTime? periodTo;

  WsBottleLedgerPdf({
    required this.org,
    required this.snapshot,
    required this.ledger,
    required this.bottles,
    DateTime? reportDate,
    this.periodFrom,
    this.periodTo,
  }) : reportDate = reportDate ?? DateTime.now();

  // ── Build ─────────────────────────────────────────────────────────────────

  Future<Uint8List> buildPdf() async {
    final doc = pw.Document(
        title: 'Bottle Ledger — ${org.orgName}',
        author: org.orgName);

    final font       = await PdfGoogleFonts.robotoRegular();
    final fontBold   = await PdfGoogleFonts.robotoBold();
    final fontMedium = await PdfGoogleFonts.robotoMedium();

    final tf = pw.ThemeData.withFont(base: font, bold: fontBold);

    doc.addPage(pw.MultiPage(
      theme: tf,
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 28),
      header: (ctx) => _header(ctx, fontBold, fontMedium),
      footer: (ctx) => _footer(ctx, font),
      build: (ctx) => [
        _healthCard(fontBold, fontMedium, font),
        pw.SizedBox(height: 14),
        _kpiGrid(fontBold, fontMedium),
        pw.SizedBox(height: 18),
        _conditionBreakdown(fontBold, fontMedium, font),
        pw.SizedBox(height: 18),
        _sectionTitle('Movement Ledger', fontBold),
        pw.SizedBox(height: 8),
        _ledgerTable(fontBold, fontMedium, font),
        pw.SizedBox(height: 18),
        _sectionTitle('Bottle Register (Individual)', fontBold),
        pw.SizedBox(height: 8),
        _bottleRegisterTable(fontBold, fontMedium, font),
      ],
    ));

    return doc.save();
  }

  // ── Header ────────────────────────────────────────────────────────────────

  pw.Widget _header(pw.Context ctx, pw.Font bold, pw.Font medium) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        color: _darkBlue,
        borderRadius: pw.BorderRadius.only(
          topLeft: pw.Radius.circular(8), topRight: pw.Radius.circular(8)),
      ),
      padding: const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('💧 ${org.orgName}',
                style: pw.TextStyle(font: bold, fontSize: 16, color: _white)),
            pw.SizedBox(height: 2),
            pw.Text('${org.phone}  |  ${org.address}',
                style: pw.TextStyle(font: medium, fontSize: 9,
                    color: const PdfColor.fromInt(0xFFB3E5FC))),
          ]),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('BOTTLE LEDGER',
                style: pw.TextStyle(font: bold, fontSize: 13, color: _white, letterSpacing: 1.5)),
            pw.SizedBox(height: 2),
            pw.Text('Generated: ${_dateFmt.format(reportDate)}',
                style: pw.TextStyle(font: medium, fontSize: 9,
                    color: const PdfColor.fromInt(0xFFB3E5FC))),
            if (periodFrom != null && periodTo != null)
              pw.Text('Period: ${_dateFmt.format(periodFrom!)} – ${_dateFmt.format(periodTo!)}',
                  style: pw.TextStyle(font: medium, fontSize: 9,
                      color: const PdfColor.fromInt(0xFFB3E5FC))),
          ]),
        ],
      ),
    );
  }

  pw.Widget _footer(pw.Context ctx, pw.Font font) => pw.Container(
    decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _border, width: .5))),
    padding: const pw.EdgeInsets.only(top: 6),
    child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text('${org.orgName} — Bottle Ledger — Confidential',
          style: pw.TextStyle(font: font, fontSize: 8, color: _grey3)),
      pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
          style: pw.TextStyle(font: font, fontSize: 8, color: _grey3)),
    ]),
  );

  // ── Health Card ───────────────────────────────────────────────────────────

  pw.Widget _healthCard(pw.Font bold, pw.Font medium, pw.Font font) {
    final score = snapshot.healthScore;
    final color = score >= 80 ? _green : score >= 60 ? _amber : _red;

    return pw.Container(
      decoration: pw.BoxDecoration(
        color: _lightBlue,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        border: const pw.Border.fromBorderSide(pw.BorderSide(color: _blue, width: .8)),
      ),
      padding: const pw.EdgeInsets.all(14),
      child: pw.Row(
        children: [
          pw.Expanded(child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Overall Bottle Health Score',
                  style: pw.TextStyle(font: bold, fontSize: 13, color: _darkBlue)),
              pw.SizedBox(height: 6),
              pw.Row(children: [
                pw.Text('${score.toStringAsFixed(0)}%',
                    style: pw.TextStyle(font: bold, fontSize: 28, color: color)),
                pw.SizedBox(width: 10),
                pw.Expanded(child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Container(
                      height: 10,
                      decoration: pw.BoxDecoration(
                        color: const PdfColor.fromInt(0xFFE0E0E0),
                        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
                      ),
                      child: pw.FractionallySizedBox(
                        widthFactor: score / 100,
                        child: pw.Container(
                          decoration: pw.BoxDecoration(color: color,
                              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5))),
                        ),
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text('Based on ${snapshot.totalBottles} total bottles · ${_dateFmt.format(snapshot.snapshotDate)}',
                        style: pw.TextStyle(font: font, fontSize: 8, color: _grey3)),
                  ],
                )),
              ]),
            ],
          )),
          pw.SizedBox(width: 20),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('Total Bottles', style: pw.TextStyle(font: medium, fontSize: 9, color: _grey2)),
            pw.Text('${snapshot.totalBottles}',
                style: pw.TextStyle(font: bold, fontSize: 22, color: _darkBlue)),
            pw.SizedBox(height: 4),
            pw.Text('Snapshot: ${_dateFmt.format(snapshot.snapshotDate)}',
                style: pw.TextStyle(font: font, fontSize: 8, color: _grey3)),
          ]),
        ],
      ),
    );
  }

  // ── KPI Grid ──────────────────────────────────────────────────────────────

  pw.Widget _kpiGrid(pw.Font bold, pw.Font medium) {
    final items = [
      _KpiItem('With Customers',  '${snapshot.bottlesWithCustomers}', _blue),
      _KpiItem('Filled (Stock)',  '${snapshot.bottlesInStock}',       _teal),
      _KpiItem('Empty (Returned)','${snapshot.bottlesEmptyInStock}',  _amber),
      _KpiItem('Perfect Cond.',   '${snapshot.bottlesPerfect}',       _green),
      _KpiItem('Needs Cleaning',  '${snapshot.bottlesNeedsCleaning}', _amber),
      _KpiItem('Damaged',         '${snapshot.bottlesDamaged}',       _red),
      _KpiItem('Lost',            '${snapshot.bottlesLost}',          _grey3),
    ];

    return pw.Row(
      children: items.map((k) => pw.Expanded(
        child: pw.Container(
          margin: const pw.EdgeInsets.symmetric(horizontal: 2),
          decoration: pw.BoxDecoration(
            color: _greyBg,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
            border: pw.Border.fromBorderSide(pw.BorderSide(color: k.color, width: .6)),
          ),
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(k.label, style: pw.TextStyle(font: medium, fontSize: 7, color: _grey3)),
            pw.SizedBox(height: 3),
            pw.Text(k.value, style: pw.TextStyle(font: bold, fontSize: 11, color: k.color)),
          ]),
        ),
      )).toList(),
    );
  }

  // ── Condition Breakdown ───────────────────────────────────────────────────

  pw.Widget _conditionBreakdown(pw.Font bold, pw.Font medium, pw.Font font) {
    final rows = [
      _CondRow(WsBottleCondition.perfect,       snapshot.bottlesPerfect),
      _CondRow(WsBottleCondition.needsCleaning, snapshot.bottlesNeedsCleaning),
      _CondRow(WsBottleCondition.damaged,       snapshot.bottlesDamaged),
      _CondRow(WsBottleCondition.lost,          snapshot.bottlesLost),
    ];

    return pw.Container(
      decoration: pw.BoxDecoration(
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        border: const pw.Border.fromBorderSide(pw.BorderSide(color: _border, width: .5)),
      ),
      padding: const pw.EdgeInsets.all(14),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('Condition Breakdown', style: pw.TextStyle(font: bold, fontSize: 11, color: _darkBlue)),
          pw.SizedBox(height: 10),
          ...rows.map((r) => pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 8),
            child: pw.Row(children: [
              pw.SizedBox(width: 130,
                  child: pw.Text('${r.cond.emoji} ${r.cond.label}',
                      style: pw.TextStyle(font: medium, fontSize: 9, color: _grey1))),
              pw.Expanded(child: pw.Stack(children: [
                pw.Container(height: 10, decoration: pw.BoxDecoration(
                    color: const PdfColor.fromInt(0xFFE0E0E0),
                    borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)))),
                pw.FractionallySizedBox(
                  widthFactor: snapshot.totalBottles > 0 ? r.count / snapshot.totalBottles : 0,
                  child: pw.Container(height: 10, decoration: pw.BoxDecoration(
                      color: r.cond.color,
                      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)))),
                ),
              ])),
              pw.SizedBox(width: 8),
              pw.SizedBox(width: 30,
                  child: pw.Text('${r.count}',
                      style: pw.TextStyle(font: bold, fontSize: 9, color: r.cond.color),
                      textAlign: pw.TextAlign.right)),
              pw.SizedBox(width: 6),
              pw.SizedBox(width: 36,
                  child: pw.Text(
                    snapshot.totalBottles > 0
                        ? '${(r.count / snapshot.totalBottles * 100).toStringAsFixed(0)}%'
                        : '0%',
                    style: pw.TextStyle(font: font, fontSize: 8, color: _grey3),
                    textAlign: pw.TextAlign.right,
                  )),
            ]),
          )),
        ],
      ),
    );
  }

  // ── Section Title ─────────────────────────────────────────────────────────

  pw.Widget _sectionTitle(String title, pw.Font bold) => pw.Container(
    decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _teal, width: 1.5))),
    padding: const pw.EdgeInsets.only(bottom: 4),
    child: pw.Text(title, style: pw.TextStyle(font: bold, fontSize: 12, color: _darkBlue)),
  );

  // ── Movement Ledger Table ─────────────────────────────────────────────────

  pw.Widget _ledgerTable(pw.Font bold, pw.Font medium, pw.Font font) {
    final headers = [
      'Date', 'Action', 'Filled', 'Empty', 'Delivered', 'Returned',
      'Cleaned', 'Damaged', 'Lost', 'Stock Filled', 'Stock Empty', 'W/ Custs', 'By'
    ];

    pw.Widget hCell(String t) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 5),
      child: pw.Text(t, style: pw.TextStyle(font: bold, fontSize: 7, color: _white)),
    );

    pw.Widget dCell(String t, {PdfColor color = _grey1, pw.TextAlign align = pw.TextAlign.left, PdfColor? bg}) =>
        pw.Container(
          color: bg,
          padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 5),
          child: pw.Text(t, style: pw.TextStyle(font: font, fontSize: 7.5, color: color),
              textAlign: align),
        );

    pw.Widget numCell(int v, pw.Font f, {PdfColor color = _grey1, PdfColor? bg}) =>
        pw.Container(
          color: bg,
          padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 5),
          alignment: pw.Alignment.center,
          child: pw.Text(v == 0 ? '—' : '$v',
              style: pw.TextStyle(font: v == 0 ? font : f, fontSize: 7.5,
                  color: v == 0 ? _grey3 : color)),
        );

    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(42), 1: pw.FixedColumnWidth(50),
        2: pw.FixedColumnWidth(28), 3: pw.FixedColumnWidth(28),
        4: pw.FixedColumnWidth(36), 5: pw.FixedColumnWidth(36),
        6: pw.FixedColumnWidth(30), 7: pw.FixedColumnWidth(30),
        8: pw.FixedColumnWidth(22), 9: pw.FixedColumnWidth(40),
        10: pw.FixedColumnWidth(40),11: pw.FixedColumnWidth(36),
        12: pw.FlexColumnWidth(),
      },
      border: pw.TableBorder.all(color: _border, width: .35),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _teal),
          children: headers.map(hCell).toList(),
        ),
        ...ledger.asMap().entries.map((entry) {
          final i = entry.key;
          final r = entry.value;
          final bg = i.isEven ? _white : _greyBg;
          return pw.TableRow(
            decoration: pw.BoxDecoration(color: bg),
            children: [
              dCell(_shortFmt.format(r.date)),
              dCell(r.action, color: _blue),
              numCell(r.filledCount, medium, color: _teal),
              numCell(r.emptyCount, medium, color: _amber),
              numCell(r.deliveredCount, medium, color: _blue),
              numCell(r.returnedCount, medium, color: _purple),
              numCell(r.cleanedCount, medium, color: _green),
              numCell(r.damagedCount, medium,
                  color: _red, bg: r.damagedCount > 0 ? _redLight : null),
              numCell(r.lostCount, medium,
                  color: _red, bg: r.lostCount > 0 ? _redLight : null),
              numCell(r.stockFilled, medium, color: _teal),
              numCell(r.stockEmpty, medium, color: _amber),
              numCell(r.withCustomers, medium, color: _darkBlue),
              dCell(r.by, color: _grey2),
            ],
          );
        }),
      ],
    );
  }

  // ── Bottle Register ───────────────────────────────────────────────────────

  pw.Widget _bottleRegisterTable(pw.Font bold, pw.Font medium, pw.Font font) {
    final headers = ['Code', 'Condition', 'Filled?', 'Location', 'Customer', 'Last Delivery', 'Last Return', 'Notes'];

    pw.Widget hCell(String t) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: pw.Text(t, style: pw.TextStyle(font: bold, fontSize: 7.5, color: _white)),
    );

    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(44), 1: pw.FixedColumnWidth(60),
        2: pw.FixedColumnWidth(32), 3: pw.FixedColumnWidth(55),
        4: pw.FixedColumnWidth(60), 5: pw.FixedColumnWidth(50),
        6: pw.FixedColumnWidth(50), 7: pw.FlexColumnWidth(),
      },
      border: pw.TableBorder.all(color: _border, width: .35),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _darkBlue),
          children: headers.map(hCell).toList(),
        ),
        ...bottles.asMap().entries.map((entry) {
          final i = entry.key;
          final b = entry.value;
          final bg = i.isEven ? _white : _greyBg;

          pw.Widget cell(String t, {PdfColor? color, double size = 7.5}) =>
              pw.Container(
                color: b.condition == WsBottleCondition.damaged ? _redLight
                    : b.condition == WsBottleCondition.needsCleaning ? _amberLight : bg,
                padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                child: pw.Text(t, style: pw.TextStyle(
                    font: font, fontSize: size,
                    color: color ?? (b.condition == WsBottleCondition.damaged ? _red
                        : b.condition == WsBottleCondition.needsCleaning ? _amber : _grey1))),
              );

          return pw.TableRow(children: [
            pw.Container(
              color: bg,
              padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: pw.Text(b.bottleCode,
                  style: pw.TextStyle(font: medium, fontSize: 7.5, color: _darkBlue)),
            ),
            pw.Container(
              color: b.condition.lightColor,
              padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: pw.Text('${b.condition.emoji} ${b.condition.label}',
                  style: pw.TextStyle(font: medium, fontSize: 7.5, color: b.condition.color)),
            ),
            cell(b.isFilled ? 'Yes' : 'No',
                color: b.isFilled ? _green : _amber),
            cell(b.isWithCustomer ? 'Customer' : 'In Stock'),
            cell(b.customerName ?? '—'),
            cell(b.lastDeliveryDate != null ? _shortFmt.format(b.lastDeliveryDate!) : '—'),
            cell(b.lastReturnDate   != null ? _shortFmt.format(b.lastReturnDate!)   : '—'),
            cell(b.notes ?? '—', color: _grey3),
          ]);
        }),
      ],
    );
  }
}

class _KpiItem { final String label, value; final PdfColor color;
  const _KpiItem(this.label, this.value, this.color); }
class _CondRow { final WsBottleCondition cond; final int count;
  const _CondRow(this.cond, this.count); }

// ─── Flutter UI ───────────────────────────────────────────────────────────────

class WsBottleLedgerScreen extends StatelessWidget {
  final WsOrganization org;
  final WsBottleInventorySnapshot snapshot;
  final List<WsBottleLedgerEntry> ledger;
  final List<WsBottle> bottles;

  const WsBottleLedgerScreen({
    super.key,
    required this.org, required this.snapshot,
    required this.ledger, required this.bottles,
  });

  Future<void> _share(BuildContext context) async {
    final gen = WsBottleLedgerPdf(
        org: org, snapshot: snapshot, ledger: ledger, bottles: bottles);
    final bytes = await gen.buildPdf();
    final dir   = await getTemporaryDirectory();
    final date  = DateFormat('yyyyMMdd').format(DateTime.now());
    final file  = File('${dir.path}/BottleLedger_$date.pdf');
    await file.writeAsBytes(bytes);

    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => WsShareSheet(
          file: file, customerName: 'Bottle Ledger', pdfBytes: bytes),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gen = WsBottleLedgerPdf(
        org: org, snapshot: snapshot, ledger: ledger, bottles: bottles);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bottle Ledger'),
        backgroundColor: const Color(0xFF00838F),
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.print), onPressed: () async {
            final bytes = await gen.buildPdf();
            await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'Bottle Ledger');
          }),
          IconButton(icon: const Icon(Icons.share), onPressed: () => _share(context)),
        ],
      ),
      body: PdfPreview(
        build: (_) => gen.buildPdf(),
        allowPrinting: true,
        allowSharing: true,
        initialPageFormat: PdfPageFormat.a4,
        pdfFileName: 'BottleLedger.pdf',
      ),
    );
  }
}

// ─── Re-export Share Sheet from customer ledger file ─────────────────────────
// (WsShareSheet is defined in ws_customer_ledger_pdf.dart and shared by both)

// ─── Sample Data ─────────────────────────────────────────────────────────────

WsBottleLedgerPdf sampleBottleLedger(WsOrganization org) {
  const snapshot = WsBottleInventorySnapshot(
    snapshotDate: DateTime(2024, 4, 30),  // ignore const warning in real code
    totalBottles: 150, bottlesWithCustomers: 26, bottlesInStock: 45,
    bottlesEmptyInStock: 18, bottlesPerfect: 123,
    bottlesNeedsCleaning: 19, bottlesDamaged: 8, bottlesLost: 0,
  );

  final ledger = [
    const WsBottleLedgerEntry(date: DateTime(2024,3,1),  action:'Delivered',  deliveredCount:5,  returnedCount:3,  stockFilled:42, stockEmpty:18, withCustomers:26, by:'Arab'),
    const WsBottleLedgerEntry(date: DateTime(2024,3,5),  action:'Filled',     filledCount:20, stockFilled:62, stockEmpty:0,  withCustomers:26, by:'Tanveer'),
    const WsBottleLedgerEntry(date: DateTime(2024,3,7),  action:'Delivered',  deliveredCount:5,  returnedCount:5,  stockFilled:57, stockEmpty:5,  withCustomers:26, by:'Arab'),
    const WsBottleLedgerEntry(date: DateTime(2024,3,10), action:'Returned',   returnedCount:8, stockFilled:45, stockEmpty:13, withCustomers:18, by:'Tanveer'),
    const WsBottleLedgerEntry(date: DateTime(2024,3,12), action:'Cleaned',    cleanedCount:5, stockFilled:45, stockEmpty:18, withCustomers:26, by:'Tanveer'),
    const WsBottleLedgerEntry(date: DateTime(2024,3,15), action:'Damaged',    damagedCount:2, stockFilled:43, stockEmpty:18, withCustomers:26, by:'Arab'),
    const WsBottleLedgerEntry(date: DateTime(2024,4,1),  action:'Delivered',  deliveredCount:5,  returnedCount:5, stockFilled:38, stockEmpty:18, withCustomers:26, by:'Arab'),
    const WsBottleLedgerEntry(date: DateTime(2024,4,16), action:'Delivered',  deliveredCount:5,  returnedCount:5, stockFilled:33, stockEmpty:18, withCustomers:26, by:'Tanveer'),
    const WsBottleLedgerEntry(date: DateTime(2024,4,25), action:'Filled',     filledCount:15, stockFilled:48, stockEmpty:3,  withCustomers:26, by:'Tanveer'),
    const WsBottleLedgerEntry(date: DateTime(2024,4,30), action:'Snapshot',   stockFilled:45, stockEmpty:18, withCustomers:26, by:'System'),
  ];

  final bottles = [
    const WsBottle(bottleCode:'BT-001', condition:WsBottleCondition.perfect,       isFilled:true,  isWithCustomer:true,  customerName:'Ahmed Khan',   lastDeliveryDate:DateTime(2024,3,1)),
    const WsBottle(bottleCode:'BT-002', condition:WsBottleCondition.perfect,       isFilled:true,  isWithCustomer:true,  customerName:'Hassan Raza',  lastDeliveryDate:DateTime(2024,3,7)),
    const WsBottle(bottleCode:'BT-003', condition:WsBottleCondition.needsCleaning, isFilled:false, isWithCustomer:false, lastReturnDate:DateTime(2024,3,10), notes:'Algae on cap'),
    const WsBottle(bottleCode:'BT-004', condition:WsBottleCondition.damaged,       isFilled:false, isWithCustomer:false, notes:'Cracked base'),
    const WsBottle(bottleCode:'BT-005', condition:WsBottleCondition.perfect,       isFilled:true,  isWithCustomer:false),
    const WsBottle(bottleCode:'BT-006', condition:WsBottleCondition.needsCleaning, isFilled:false, isWithCustomer:false, notes:'Stained inside'),
    const WsBottle(bottleCode:'BT-007', condition:WsBottleCondition.perfect,       isFilled:true,  isWithCustomer:true,  customerName:'Zara Siddiqui',lastDeliveryDate:DateTime(2024,4,1)),
    const WsBottle(bottleCode:'BT-008', condition:WsBottleCondition.damaged,       isFilled:false, isWithCustomer:false, notes:'Cap crack'),
    const WsBottle(bottleCode:'BT-009', condition:WsBottleCondition.perfect,       isFilled:true,  isWithCustomer:false),
    const WsBottle(bottleCode:'BT-010', condition:WsBottleCondition.perfect,       isFilled:false, isWithCustomer:false, notes:'Empty — queued for fill'),
  ];

  return WsBottleLedgerPdf(org: org, snapshot: snapshot, ledger: ledger, bottles: bottles);
}
