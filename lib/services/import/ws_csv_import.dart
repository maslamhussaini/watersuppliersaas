// =============================================================================
// lib/services/import/ws_csv_import.dart
// Reading a customer list out of a spreadsheet, and deciding what it means.
//
// ─── THIS FILE WRITES NOTHING ────────────────────────────────────────────────
//
// It parses, validates and PLANS. The plan is shown to the user, and only then
// does ws_csv_import_apply.dart execute it. Pure Dart — no Supabase, no Flutter
// — which is what makes every rule below testable without a database.
//
// ─── THE RULE THAT MATTERS MOST ──────────────────────────────────────────────
//
// A BLANK CELL MEANS "LEAVE IT ALONE". Never zero, never null, never delete.
//
// A spreadsheet exported from anywhere will be full of empty cells for fields
// the person never filled in. If blank meant "set to empty", one import would
// wipe the phone numbers, addresses and opening balances of every customer it
// touched — silently, because each individual write would look perfectly
// valid. So a value is only ever proposed when the column exists AND the cell
// has content, and [WsCsvCell] keeps that distinction rather than collapsing it
// to an empty string.
//
// ─── AND THE ONE BEHIND IT ───────────────────────────────────────────────────
//
// A BATCH WITH ANY VALIDATION ERROR WRITES NOTHING. A file with a misspelled
// area or two rows claiming the same customer is rejected whole, rather than
// applied up to the first bad line and abandoned there. Validation is therefore
// whole-file and up front, and the applier refuses a plan that has errors in
// it.
//
// That rule is about the PLAN. It says nothing about a write that fails once a
// valid plan is already running, and the two must not be confused: rows are
// applied through separate requests with no transaction around them, so a
// runtime failure can leave earlier rows committed.
//
// This paragraph used to add that a partly applied file "cannot simply be
// re-run, because the first 46 are now duplicates-in-waiting". That was true
// when it was written and is not true now. Migration 014 made ws_record_customer
// idempotent on clientuuid, 017 made ws_set_customer_opening state an absolute
// figure rather than an increment, and the matching below re-reads live state —
// so re-uploading the same file finishes the rows that did not save and creates
// no duplicates. It is verified in test/csv_import_apply_test.dart and in
// test_harness/bin/csv_import_write.dart.
// =============================================================================

import 'dart:math';

// ─── Canonical columns ────────────────────────────────────────────────────────

/// Header names are matched loosely: case, spaces, underscores and a few
/// obvious synonyms. People export "Customer Name", "customer_name" and "NAME"
/// from the same three systems and none of them is wrong.
const Map<String, List<String>> wsCsvColumnAliases = {
  'name': ['name', 'customername', 'customer', 'customerfullname', 'fullname'],
  'phone': ['phone', 'mobile', 'contactnumber', 'phonenumber', 'cell'],
  'area': ['area', 'areaname', 'zone', 'sector'],
  'address': ['address', 'streetaddress', 'location'],
  'code': ['code', 'customercode', 'accountcode', 'accountno'],
  'contact': ['contact', 'contactperson', 'contactname'],
  'email': ['email', 'emailaddress'],
  'rate': ['rate', 'rateoverride', 'rateperbottle', 'price', 'unitprice'],
  'deposit': ['deposit', 'depositamount', 'securitydeposit'],
  'openingbalance': [
    'openingbalance',
    'opening',
    'openingdue',
    'balance',
    'previousbalance',
    'duebalance',
  ],
  'openingqty': [
    'openingqty',
    'openingbottles',
    'bottles',
    'bottlebalance',
    'openingbottleqty',
  ],
};

String _canonical(String header) {
  final k = header.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  for (final entry in wsCsvColumnAliases.entries) {
    if (entry.value.contains(k)) return entry.key;
  }
  return '';
}

/// Digits only. Two people writing 0300-1234567 and +92 300 1234567 mean the
/// same number, and an import that treats them as different customers has
/// failed at its only job.
String wsNormalisePhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  // Strip a leading country code so local and international forms match.
  if (digits.length > 10 && digits.startsWith('92')) return digits.substring(2);
  if (digits.length > 10 && digits.startsWith('0')) return digits;
  return digits;
}

String _normaliseName(String raw) =>
    raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

// ─── A cell that knows whether it was filled in ───────────────────────────────

class WsCsvCell {
  /// True when the column exists AND the cell has non-whitespace content.
  final bool present;
  final String value;

  const WsCsvCell(this.present, this.value);
  static const absent = WsCsvCell(false, '');

  bool get isBlank => !present;
}

// ─── Parsing ──────────────────────────────────────────────────────────────────

/// RFC 4180-ish reader: quoted fields, escaped quotes (""), embedded commas and
/// newlines, and CRLF. Hand-written on purpose — one dependency-free function
/// that can be unit-tested beats a package for a format this small.
List<List<String>> wsParseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var i = 0;

  // A byte-order mark survives every round trip through Excel and turns the
  // first header into "﻿name", which then matches nothing.
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) i = 1;

  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    // Skip the blank lines spreadsheets leave at the end of a file.
    if (row.length > 1 || row.first.trim().isNotEmpty) rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final c = text[i];

    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
      } else {
        field.write(c);
      }
      i++;
      continue;
    }

    switch (c) {
      case '"':
        inQuotes = true;
      case ',':
        endField();
      case '\r':
        break; // handled by \n
      case '\n':
        endRow();
      default:
        field.write(c);
    }
    i++;
  }

  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

// ─── What the planner needs to know about what already exists ─────────────────

class WsImportCustomer {
  final int customerId;
  final String customerName;
  final String? phone;
  final int? areaId;
  final String? address;
  final String? contactPerson;
  final String? email;
  final String? customerCode;
  final double? rateOverride;
  final double depositAmount;
  final double openingBalance;

  /// Bottles already posted as this customer's opening quantity. Read from the
  /// bottle ledger, not from a column, because that is where it lives.
  final int openingQty;

  const WsImportCustomer({
    required this.customerId,
    required this.customerName,
    this.phone,
    this.areaId,
    this.address,
    this.contactPerson,
    this.email,
    this.customerCode,
    this.rateOverride,
    this.depositAmount = 0,
    this.openingBalance = 0,
    this.openingQty = 0,
  });
}

class WsImportArea {
  final int areaId;
  final String areaName;
  const WsImportArea(this.areaId, this.areaName);
}

// ─── The plan ─────────────────────────────────────────────────────────────────

enum WsImportAction { create, update, unchanged, error }

class WsFieldChange {
  final String field;
  final String from;
  final String to;
  const WsFieldChange(this.field, this.from, this.to);

  @override
  String toString() => '$field: $from → $to';
}

class WsPlannedRow {
  final int lineNumber;
  final String name;

  WsImportAction action;
  int? customerId;

  /// 'phone' or 'name + area' — shown in the preview so a surprising match is
  /// visible before it is applied.
  String matchedBy;

  final List<WsFieldChange> changes;
  final List<String> errors;

  /// Values to send, already parsed. Only keys that were PRESENT in the file.
  final Map<String, Object?> values;

  /// One key per row, fixed when the plan is built, so confirming the same plan
  /// twice cannot create two customers.
  final String clientUuid;

  /// The matched customer's CURRENT opening balances, recorded whether or not
  /// they are changing.
  ///
  /// ws_set_customer_opening takes money and bottles together and writes both.
  /// If a file supplies one column and not the other, the applier has to send
  /// the existing value for the missing half — otherwise the omitted half is
  /// set to zero, which is precisely the "blank means delete" behaviour this
  /// importer must never have. Deriving it from the change list is not enough:
  /// an unchanged half produces no change entry at all.
  double currentOpeningBalance;
  int currentOpeningQty;

  WsPlannedRow({
    required this.lineNumber,
    required this.name,
    required this.clientUuid,
    this.action = WsImportAction.unchanged,
    this.customerId,
    this.matchedBy = '',
    this.currentOpeningBalance = 0,
    this.currentOpeningQty = 0,
    List<WsFieldChange>? changes,
    List<String>? errors,
    Map<String, Object?>? values,
  })  : changes = changes ?? [],
        errors = errors ?? [],
        values = values ?? {};

  bool get hasErrors => errors.isNotEmpty;
}

class WsImportPlan {
  final List<WsPlannedRow> rows;
  final List<String> fileErrors;

  const WsImportPlan(this.rows, {this.fileErrors = const []});

  List<WsPlannedRow> get creates =>
      rows.where((r) => r.action == WsImportAction.create).toList();
  List<WsPlannedRow> get updates =>
      rows.where((r) => r.action == WsImportAction.update).toList();
  List<WsPlannedRow> get unchanged =>
      rows.where((r) => r.action == WsImportAction.unchanged).toList();
  List<WsPlannedRow> get errored =>
      rows.where((r) => r.action == WsImportAction.error).toList();

  /// THE GATE. Nothing is written while this is true.
  bool get hasErrors => fileErrors.isNotEmpty || errored.isNotEmpty;

  bool get hasWork => creates.isNotEmpty || updates.isNotEmpty;

  String get summary => fileErrors.isNotEmpty
      ? fileErrors.first
      : '${creates.length} new, ${updates.length} to update, '
          '${unchanged.length} unchanged, ${errored.length} with errors';
}

// ─── The planner ──────────────────────────────────────────────────────────────

class WsCsvImportPlanner {
  final List<WsImportCustomer> existing;
  final List<WsImportArea> areas;

  /// Injected so tests are deterministic; production passes wsNewUuid.
  final String Function() newUuid;

  WsCsvImportPlanner({
    required this.existing,
    required this.areas,
    String Function()? newUuid,
  }) : newUuid = newUuid ?? _defaultUuid;

  static final _rng = Random.secure();
  static String _defaultUuid() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int s, int e) =>
        b.sublist(s, e).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
  }

  WsImportPlan plan(String csvText) {
    final table = wsParseCsv(csvText);
    if (table.isEmpty) {
      return const WsImportPlan([], fileErrors: ['The file is empty.']);
    }

    // ── header ──────────────────────────────────────────────────────────
    final header = table.first.map(_canonical).toList();
    if (!header.contains('name')) {
      return WsImportPlan(const [], fileErrors: [
        'No customer name column found. Expected a header containing one of: '
            '${wsCsvColumnAliases['name']!.join(', ')}.'
      ]);
    }

    final dataRows = table.skip(1).toList();
    if (dataRows.isEmpty) {
      return const WsImportPlan([],
          fileErrors: ['The file has a header but no rows.']);
    }

    final byPhone = <String, List<WsImportCustomer>>{};
    final byNameArea = <String, List<WsImportCustomer>>{};
    for (final c in existing) {
      final p = wsNormalisePhone(c.phone ?? '');
      if (p.isNotEmpty) (byPhone[p] ??= []).add(c);
      (byNameArea['${_normaliseName(c.customerName)}|${c.areaId ?? ''}'] ??= [])
          .add(c);
    }

    final areaByName = <String, WsImportArea>{
      for (final a in areas) _normaliseName(a.areaName): a
    };

    // Duplicate detection WITHIN the file, so two rows cannot both claim the
    // same customer and quietly fight over it.
    final seenPhone = <String, int>{};
    final seenNameArea = <String, int>{};

    final planned = <WsPlannedRow>[];

    for (var r = 0; r < dataRows.length; r++) {
      final line = r + 2; // 1-based, and the header is line 1
      final cells = dataRows[r];

      WsCsvCell cell(String column) {
        final idx = header.indexOf(column);
        if (idx < 0 || idx >= cells.length) return WsCsvCell.absent;
        final v = cells[idx].trim();
        return WsCsvCell(v.isNotEmpty, v);
      }

      final nameCell = cell('name');
      final row = WsPlannedRow(
        lineNumber: line,
        name: nameCell.value,
        clientUuid: newUuid(),
      );

      if (!nameCell.present) {
        row.errors.add('Customer name is required.');
        row.action = WsImportAction.error;
        planned.add(row);
        continue;
      }

      // ── parse and validate every supplied field ───────────────────────
      final phoneCell = cell('phone');
      String normPhone = '';
      if (phoneCell.present) {
        normPhone = wsNormalisePhone(phoneCell.value);
        if (normPhone.length < 7 || normPhone.length > 15) {
          row.errors.add('"${phoneCell.value}" is not a usable phone number.');
        } else {
          row.values['phone'] = phoneCell.value;
        }
      }

      int? areaId;
      final areaCell = cell('area');
      if (areaCell.present) {
        final a = areaByName[_normaliseName(areaCell.value)];
        if (a == null) {
          row.errors.add('Area "${areaCell.value}" does not exist. '
              'Create it first, or correct the spelling.');
        } else {
          areaId = a.areaId;
          row.values['areaid'] = a.areaId;
        }
      }

      void number(String column, String label, {bool integer = false}) {
        final c = cell(column);
        if (!c.present) return; // BLANK MEANS UNCHANGED
        final parsed = num.tryParse(c.value.replaceAll(',', ''));
        if (parsed == null) {
          row.errors.add('$label "${c.value}" is not a number.');
        } else if (parsed < 0) {
          row.errors.add('$label cannot be negative.');
        } else if (integer && parsed != parsed.roundToDouble()) {
          row.errors.add('$label must be a whole number.');
        } else {
          row.values[column] = integer ? parsed.toInt() : parsed.toDouble();
        }
      }

      number('rate', 'Rate');
      number('deposit', 'Deposit');
      number('openingbalance', 'Opening balance');
      number('openingqty', 'Opening bottles', integer: true);

      for (final f in ['address', 'code', 'contact', 'email']) {
        final c = cell(f);
        if (c.present) row.values[f] = c.value;
      }

      // ── duplicates within the file ────────────────────────────────────
      if (normPhone.isNotEmpty) {
        final prev = seenPhone[normPhone];
        if (prev != null) {
          row.errors.add('Same phone number as line $prev.');
        } else {
          seenPhone[normPhone] = line;
        }
      }
      final nameAreaKey = '${_normaliseName(nameCell.value)}|${areaId ?? ''}';
      final prevNA = seenNameArea[nameAreaKey];
      if (prevNA != null) {
        row.errors.add('Same name and area as line $prevNA.');
      } else {
        seenNameArea[nameAreaKey] = line;
      }

      // ── match against what already exists ─────────────────────────────
      List<WsImportCustomer> candidates = const [];
      var how = '';

      if (normPhone.isNotEmpty && byPhone.containsKey(normPhone)) {
        candidates = byPhone[normPhone]!;
        how = 'phone';
      } else {
        // Fallback: name + area. With no area in the file, fall back to name
        // alone — but only when it is unambiguous.
        if (areaId != null) {
          candidates = byNameArea[nameAreaKey] ?? const [];
          how = 'name + area';
        } else {
          candidates = existing
              .where((c) =>
                  _normaliseName(c.customerName) ==
                  _normaliseName(nameCell.value))
              .toList();
          how = 'name';
        }
      }

      if (candidates.length > 1) {
        row.errors.add(
            'Matches ${candidates.length} existing customers by $how. '
            'Add an area or phone column to tell them apart.');
      }

      if (row.hasErrors) {
        row.action = WsImportAction.error;
        planned.add(row);
        continue;
      }

      if (candidates.isEmpty) {
        row.action = WsImportAction.create;
        row.matchedBy = '';
        planned.add(row);
        continue;
      }

      // ── an update: work out what would actually change ────────────────
      final c = candidates.single;
      row.customerId = c.customerId;
      row.matchedBy = how;
      // Recorded unconditionally — the applier needs the untouched half when
      // the file supplies only one of money/bottles.
      row.currentOpeningBalance = c.openingBalance;
      row.currentOpeningQty = c.openingQty;

      void diff(String key, String label, String currentText, String nextText) {
        if (currentText != nextText) {
          row.changes.add(WsFieldChange(label, currentText, nextText));
        } else {
          // Identical values are not changes, and listing them would bury the
          // real ones in a preview of three hundred rows.
          row.values.remove(key);
        }
      }

      String money(num? v) => (v ?? 0) == 0 ? '0' : '${v ?? 0}';

      if (row.values.containsKey('phone')) {
        diff('phone', 'Phone', c.phone ?? '', row.values['phone'] as String);
      }
      if (row.values.containsKey('areaid')) {
        final from = areas
            .where((a) => a.areaId == c.areaId)
            .map((a) => a.areaName)
            .join();
        final to = areas
            .where((a) => a.areaId == row.values['areaid'])
            .map((a) => a.areaName)
            .join();
        diff('areaid', 'Area', from, to);
      }
      if (row.values.containsKey('address')) {
        diff('address', 'Address', c.address ?? '',
            row.values['address'] as String);
      }
      if (row.values.containsKey('contact')) {
        diff('contact', 'Contact person', c.contactPerson ?? '',
            row.values['contact'] as String);
      }
      if (row.values.containsKey('email')) {
        diff('email', 'Email', c.email ?? '', row.values['email'] as String);
      }
      if (row.values.containsKey('code')) {
        diff('code', 'Code', c.customerCode ?? '',
            row.values['code'] as String);
      }
      if (row.values.containsKey('rate')) {
        diff('rate', 'Rate', money(c.rateOverride),
            money(row.values['rate'] as double));
      }
      if (row.values.containsKey('deposit')) {
        diff('deposit', 'Deposit', money(c.depositAmount),
            money(row.values['deposit'] as double));
      }
      if (row.values.containsKey('openingbalance')) {
        diff('openingbalance', 'Opening balance', money(c.openingBalance),
            money(row.values['openingbalance'] as double));
      }
      if (row.values.containsKey('openingqty')) {
        diff('openingqty', 'Opening bottles', '${c.openingQty}',
            '${row.values['openingqty']}');
      }

      row.action = row.changes.isEmpty
          ? WsImportAction.unchanged
          : WsImportAction.update;
      planned.add(row);
    }

    return WsImportPlan(planned);
  }
}
