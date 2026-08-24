// =============================================================================
// test/csv_import_test.dart
// The preview half of CSV customer import — parsing, validation and planning.
//
// Pure Dart: the planner takes existing customers as data, so every rule can be
// checked without a database. The write half is proved separately against real
// Postgres in test_harness/bin/csv_import_write.dart.
//
// The rule under the most scrutiny here is the one that can quietly destroy a
// customer list: A BLANK CELL MEANS UNCHANGED. Never zero, never null, never
// delete.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/import/ws_csv_import.dart';

// ─── fixtures ─────────────────────────────────────────────────────────────────

const areas = [
  WsImportArea(1, 'Gulshan'),
  WsImportArea(2, 'Clifton'),
];

const existing = [
  WsImportCustomer(
    customerId: 10,
    customerName: 'Hotel ABC',
    phone: '0300-1234567',
    areaId: 1,
    address: 'Old Address',
    depositAmount: 100,
    openingBalance: 500,
    openingQty: 20,
  ),
  WsImportCustomer(
    customerId: 11,
    customerName: 'Restaurant XYZ',
    phone: '0321-9999999',
    areaId: 2,
    address: 'Clifton Road',
  ),
  // Same name in two different areas — the reason name-only matching has to be
  // treated as ambiguous.
  WsImportCustomer(customerId: 12, customerName: 'Twin Cafe', areaId: 1),
  WsImportCustomer(customerId: 13, customerName: 'Twin Cafe', areaId: 2),
];

var _n = 0;
WsCsvImportPlanner planner() {
  _n = 0;
  return WsCsvImportPlanner(
    existing: existing,
    areas: areas,
    newUuid: () => 'uuid-${++_n}',
  );
}

WsPlannedRow rowFor(WsImportPlan p, String name) =>
    p.rows.firstWhere((r) => r.name == name);

void main() {
  // ═══ PARSER ═══════════════════════════════════════════════════════════════

  group('the parser', () {
    test('handles quotes, embedded commas and newlines', () {
      final rows = wsParseCsv(
          'name,address\n"Hotel, The","Line one\nLine two"\nPlain,Simple\n');
      expect(rows.length, 3);
      expect(rows[1][0], 'Hotel, The');
      expect(rows[1][1], 'Line one\nLine two');
      expect(rows[2], ['Plain', 'Simple']);
    });

    test('handles escaped quotes and CRLF', () {
      final rows = wsParseCsv('name\r\n"He said ""hi"""\r\n');
      expect(rows[1][0], 'He said "hi"');
    });

    test('strips the byte-order mark Excel leaves behind', () {
      final rows = wsParseCsv('﻿name,phone\nA,1\n');
      expect(rows.first.first, 'name',
          reason: 'a BOM would make the first header match nothing');
    });

    test('ignores trailing blank lines', () {
      expect(wsParseCsv('name\nA\n\n\n').length, 2);
    });
  });

  group('phone normalisation', () {
    test('different formats of one number are the same number', () {
      expect(wsNormalisePhone('0300-1234567'), wsNormalisePhone('0300 1234567'));
      expect(wsNormalisePhone('+92 300 1234567'), '3001234567');
    });
  });

  // ═══ HEADERS ══════════════════════════════════════════════════════════════

  group('headers', () {
    test('a file with no name column is rejected outright', () {
      final p = planner().plan('phone,address\n123,x\n');
      expect(p.hasErrors, isTrue);
      expect(p.fileErrors.first, contains('No customer name column'));
    });

    test('an empty file is rejected', () {
      expect(planner().plan('').hasErrors, isTrue);
    });

    test('a header with no rows is rejected', () {
      expect(planner().plan('name,phone\n').hasErrors, isTrue);
    });

    test('aliases and odd casing are accepted', () {
      final p = planner()
          .plan('Customer Name,Mobile,Zone\nNew Person,0311-1112223,Gulshan\n');
      expect(p.hasErrors, isFalse);
      expect(p.creates.length, 1);
      expect(p.creates.single.values['areaid'], 1);
    });
  });

  // ═══ NEW CUSTOMERS ════════════════════════════════════════════════════════

  test('valid new customer', () {
    final p = planner().plan(
        'name,phone,area,address,openingbalance,openingqty\n'
        'New Person,0311-1112223,Gulshan,New Street,250,5\n');

    expect(p.hasErrors, isFalse);
    expect(p.creates.length, 1);
    final r = p.creates.single;
    expect(r.action, WsImportAction.create);
    expect(r.customerId, isNull);
    expect(r.values['phone'], '0311-1112223');
    expect(r.values['areaid'], 1);
    expect(r.values['openingbalance'], 250.0);
    expect(r.values['openingqty'], 5);
    expect(r.clientUuid, isNotEmpty,
        reason: 'every created row needs its own idempotency key');
  });

  test('each row gets a distinct key', () {
    final p = planner().plan('name\nOne\nTwo\nThree\n');
    expect(p.rows.map((r) => r.clientUuid).toSet().length, 3);
  });

  // ═══ MATCHING ═════════════════════════════════════════════════════════════

  test('phone match wins', () {
    final p = planner()
        .plan('name,phone,address\nCompletely Different Name,03001234567,New\n');
    final r = p.rows.single;
    expect(r.action, WsImportAction.update);
    expect(r.customerId, 10);
    expect(r.matchedBy, 'phone');
  });

  test('name + area fallback when there is no phone', () {
    final p = planner().plan('name,area,address\nHotel ABC,Gulshan,New Road\n');
    final r = p.rows.single;
    expect(r.action, WsImportAction.update);
    expect(r.customerId, 10);
    expect(r.matchedBy, 'name + area');
  });

  test('name + area distinguishes two customers with the same name', () {
    final p = planner().plan('name,area,address\nTwin Cafe,Clifton,Road 2\n');
    expect(p.rows.single.customerId, 13);
  });

  test('ambiguous match is an error, not a guess', () {
    final p = planner().plan('name,address\nTwin Cafe,Somewhere\n');
    final r = p.rows.single;
    expect(r.action, WsImportAction.error);
    expect(r.errors.single, contains('Matches 2 existing customers'));
    expect(p.hasErrors, isTrue);
  });

  test('an unmatched name creates rather than guessing', () {
    final p = planner().plan('name,area\nBrand New Cafe,Gulshan\n');
    expect(p.creates.single.name, 'Brand New Cafe');
  });

  // ═══ DUPLICATES WITHIN THE FILE ═══════════════════════════════════════════

  test('two rows with the same phone are both errors', () {
    final p = planner().plan(
        'name,phone\nPerson One,0311-5550001\nPerson Two,03115550001\n');
    expect(p.errored.length, 1, reason: 'the second row names the first');
    expect(p.errored.single.errors.single, contains('Same phone number as line 2'));
    expect(p.hasErrors, isTrue);
  });

  test('two rows with the same name and area are errors', () {
    final p = planner()
        .plan('name,area\nDouble Entry,Gulshan\nDouble Entry,Gulshan\n');
    expect(p.errored.single.errors.single, contains('Same name and area'));
  });

  test('the same name in different areas is fine', () {
    final p = planner()
        .plan('name,area\nFresh Cafe,Gulshan\nFresh Cafe,Clifton\n');
    expect(p.hasErrors, isFalse);
    expect(p.creates.length, 2);
  });

  // ═══ THE BLANK RULE ═══════════════════════════════════════════════════════

  group('a blank cell means unchanged', () {
    // The exact scenario from the specification.
    late WsImportPlan plan;
    setUp(() {
      plan = planner().plan(
          'name,phone,address,openingbalance,openingqty\n'
          'Hotel ABC,,New Address,,\n');
    });

    test('only the supplied field is proposed', () {
      final r = rowFor(plan, 'Hotel ABC');
      expect(r.action, WsImportAction.update);
      expect(r.changes.map((c) => c.field), ['Address']);
    });

    test('a blank phone does not clear the phone', () {
      final r = rowFor(plan, 'Hotel ABC');
      expect(r.values.containsKey('phone'), isFalse);
    });

    test('a blank opening balance does not zero it', () {
      final r = rowFor(plan, 'Hotel ABC');
      expect(r.values.containsKey('openingbalance'), isFalse);
      expect(r.currentOpeningBalance, 500,
          reason: 'the applier re-sends this untouched half');
    });

    test('a blank opening quantity does not zero the bottles', () {
      final r = rowFor(plan, 'Hotel ABC');
      expect(r.values.containsKey('openingqty'), isFalse);
      expect(r.currentOpeningQty, 20);
    });

    test('an explicit zero IS a change — blank and 0 are different', () {
      final p = planner()
          .plan('name,openingbalance\nHotel ABC,0\n');
      final r = p.rows.single;
      expect(r.values['openingbalance'], 0.0);
      expect(r.changes.single.field, 'Opening balance');
      expect(r.changes.single.to, '0');
    });

    test('a column absent from the header is never touched', () {
      final p = planner().plan('name,address\nHotel ABC,New Address\n');
      final r = p.rows.single;
      expect(r.values.keys, ['address']);
    });
  });

  // ═══ NO-OP ROWS ═══════════════════════════════════════════════════════════

  test('identical values are unchanged, not an update', () {
    final p = planner()
        .plan('name,phone,address\nHotel ABC,0300-1234567,Old Address\n');
    final r = p.rows.single;
    expect(r.action, WsImportAction.unchanged);
    expect(r.changes, isEmpty);
    expect(p.hasWork, isFalse);
  });

  // ═══ VALIDATION ═══════════════════════════════════════════════════════════

  group('validation', () {
    test('a missing name is an error', () {
      final p = planner().plan('name,phone\n,0311-0000001\n');
      expect(p.errored.single.errors.single, contains('name is required'));
    });

    test('an unusable phone is an error', () {
      final p = planner().plan('name,phone\nShort Phone,123\n');
      expect(p.errored.single.errors.single, contains('not a usable phone'));
    });

    test('a non-numeric amount is an error', () {
      final p = planner().plan('name,openingbalance\nBad Money,abc\n');
      expect(p.errored.single.errors.single, contains('not a number'));
    });

    test('a negative amount is an error', () {
      final p = planner().plan('name,deposit\nNegative,-5\n');
      expect(p.errored.single.errors.single, contains('cannot be negative'));
    });

    test('a fractional bottle count is an error', () {
      final p = planner().plan('name,openingqty\nHalf Bottle,2.5\n');
      expect(p.errored.single.errors.single, contains('whole number'));
    });

    test('an unknown area is an error, never silently created', () {
      final p = planner().plan('name,area\nGhost,Atlantis\n');
      expect(p.errored.single.errors.single, contains('does not exist'));
    });

    test('thousands separators are accepted', () {
      final p = planner().plan('name,openingbalance\nBig Money,"12,500"\n');
      expect(p.hasErrors, isFalse);
      expect(p.creates.single.values['openingbalance'], 12500.0);
    });
  });

  // ═══ THE BATCH GATE ═══════════════════════════════════════════════════════

  test('a mixed batch is blocked in its entirety', () {
    final p = planner().plan('name,phone,area\n'
        'Good One,0311-7770001,Gulshan\n'
        'Bad One,123,Gulshan\n'
        'Good Two,0311-7770002,Clifton\n');

    expect(p.creates.length, 2, reason: 'the valid rows are still planned');
    expect(p.errored.length, 1);
    expect(p.hasErrors, isTrue,
        reason: 'THE GATE: the applier refuses a plan while this is true');
  });

  test('the summary reports every category', () {
    final p = planner().plan('name,phone,address,area\n'
        'Brand New,0311-8880001,Somewhere,Gulshan\n'
        'Hotel ABC,,Changed Address,\n'
        'Restaurant XYZ,,Clifton Road,\n'
        'Twin Cafe,,x,\n');
    expect(p.creates.length, 1);
    expect(p.updates.length, 1);
    expect(p.unchanged.length, 1);
    expect(p.errored.length, 1);
    expect(p.summary, contains('1 new'));
    expect(p.summary, contains('1 to update'));
  });
}
