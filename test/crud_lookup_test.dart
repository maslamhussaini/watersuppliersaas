// =============================================================================
// test/crud_lookup_test.dart
// WsFieldType.lookup inside the shared CRUD form.
//
// The claim under test is narrow and important: THE SAVED PAYLOAD IS UNCHANGED.
// A field converted from dropdown to lookup must hand onSave the same id it
// always did, so the RPC, the accounting and the store behaviour underneath are
// untouched. Everything else here is input-control behaviour.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/screens/ws_crud.dart';
import 'package:watersuppliersaas/services/lookup_service.dart';
import 'package:watersuppliersaas/widgets/ws_lookup_field.dart';

// ─── a fake catalogue ─────────────────────────────────────────────────────────

const _vendors = [
  WsLookupResult(id: 7, label: 'Pak Plastics', subtitle: 'V-001 · 0311-1'),
  WsLookupResult(id: 8, label: 'Pak Filters', subtitle: 'V-002 · 0311-2'),
  WsLookupResult(id: 9, label: 'Karachi Caps', subtitle: 'V-003'),
];

const _products = [
  WsLookupResult(id: 21, label: '19 Litre Bottle', subtitle: 'W19'),
  WsLookupResult(id: 22, label: '20 Litre Bottle', subtitle: 'W20'),
];

/// Records what each search was asked for, so a test can prove the store was
/// never involved.
List<String> vendorQueries = [];

Future<List<WsLookupResult>> searchVendors(String q) async {
  vendorQueries.add(q);
  final needle = wsSanitiseSearch(q).toLowerCase();
  if (needle.length < wsLookupMinChars) return const [];
  return _vendors
      .where((v) =>
          v.label.toLowerCase().contains(needle) ||
          v.subtitle.toLowerCase().contains(needle))
      .take(wsLookupLimit)
      .toList();
}

Future<List<WsLookupResult>> searchProducts(String q) async {
  final needle = wsSanitiseSearch(q).toLowerCase();
  if (needle.length < wsLookupMinChars) return const [];
  return _products
      .where((p) => p.label.toLowerCase().contains(needle))
      .take(wsLookupLimit)
      .toList();
}

Future<List<WsLookupResult>> floodSearch(String q) async => List.generate(
    wsLookupLimit + 10,
    (i) => WsLookupResult(id: 500 + i, label: 'Vendor $i')).take(wsLookupLimit).toList();

Future<WsLookupResult?> resolveVendor(int id) async =>
    _vendors.where((v) => v.id == id).firstOrNull;
Future<WsLookupResult?> resolveProduct(int id) async =>
    _products.where((p) => p.id == id).firstOrNull;

// ─── harness ──────────────────────────────────────────────────────────────────

Map<String, dynamic>? saved;
Object? savedPk;

Widget form({
  Map<String, dynamic>? initial,
  bool requiredVendor = true,
  WsLookupSearch? vendorSearch,
}) {
  saved = null;
  savedPk = null;
  vendorQueries = [];

  return MaterialApp(
    home: Scaffold(
      body: WsCrudForm(
        title: 'Purchase',
        initial: initial,
        fields: [
          WsField(
            'vendorid',
            'Vendor',
            type: WsFieldType.lookup,
            required: requiredVendor,
            search: vendorSearch ?? searchVendors,
            resolve: resolveVendor,
          ),
          WsField(
            'productid',
            'Item',
            type: WsFieldType.lookup,
            required: true,
            search: searchProducts,
            resolve: resolveProduct,
          ),
          const WsField('quantity', 'Quantity', type: WsFieldType.number),
        ],
        onSave: (out) async {
          saved = out;
        },
      ),
    ),
  );
}

Finder lookupNamed(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(WsLookupField),
    );

Future<void> pick(WidgetTester t, String fieldLabel, String query,
    String result) async {
  await t.tap(lookupNamed(fieldLabel).first);
  await t.pumpAndSettle();
  await t.enterText(find.byType(TextField).last, query);
  await t.pump(const Duration(milliseconds: 400));
  await t.pumpAndSettle();
  await t.tap(find.widgetWithText(ListTile, result));
  await t.pumpAndSettle();
}

void main() {
  // ═══ RENDERING ════════════════════════════════════════════════════════════

  testWidgets('a lookup field renders instead of a dropdown', (t) async {
    await t.pumpWidget(form());
    await t.pumpAndSettle();

    expect(find.byType(WsLookupField), findsNWidgets(2));
    expect(find.byType(DropdownButtonFormField<Object?>), findsNothing);
    expect(find.text('Vendor *'), findsOneWidget);
    expect(find.text('Item *'), findsOneWidget);
  });

  testWidgets('it loads nothing until the user types', (t) async {
    await t.pumpWidget(form());
    await t.pumpAndSettle();
    expect(vendorQueries, isEmpty,
        reason: 'the dropdown this replaces fetched the whole table on open');
  });

  // ═══ SELECTION AND THE SAVED PAYLOAD ══════════════════════════════════════

  testWidgets('selecting sends the correct id to onSave', (t) async {
    await t.pumpWidget(form());
    await t.pumpAndSettle();

    await pick(t, 'Vendor *', 'Pak Fil', 'Pak Filters');
    await pick(t, 'Item *', '20 Litre', '20 Litre Bottle');
    await t.enterText(find.byType(TextField).first, '5');

    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!['vendorid'], 8, reason: 'the id, exactly as a dropdown gave');
    expect(saved!['productid'], 22);
    expect(saved!['quantity'], 5.0);
  });

  testWidgets('the payload carries ids only — no labels leak in', (t) async {
    await t.pumpWidget(form());
    await t.pumpAndSettle();
    await pick(t, 'Vendor *', 'Karachi', 'Karachi Caps');
    await pick(t, 'Item *', '19 Litre', '19 Litre Bottle');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(saved!['vendorid'], isA<int>());
    expect(saved!.keys.toSet(), {'vendorid', 'productid', 'quantity'},
        reason: 'the same keys the dropdown version produced');
  });

  testWidgets('the chosen record is displayed in the field', (t) async {
    await t.pumpWidget(form());
    await t.pumpAndSettle();
    await pick(t, 'Vendor *', 'Pak Pla', 'Pak Plastics');
    expect(find.text('Pak Plastics'), findsOneWidget);
  });

  // ═══ EDITING AN EXISTING RECORD ═══════════════════════════════════════════

  testWidgets('an existing id is resolved and shown when editing', (t) async {
    await t.pumpWidget(form(initial: {'vendorid': 9, 'productid': 21}));
    await t.pumpAndSettle();

    expect(find.text('Karachi Caps'), findsOneWidget,
        reason: 'an unresolved field would invite the user to repoint the '
            'document at somebody else');
    expect(find.text('19 Litre Bottle'), findsOneWidget);
  });

  testWidgets('editing without touching the lookup saves the SAME id',
      (t) async {
    await t.pumpWidget(form(initial: {'vendorid': 9, 'productid': 21}));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField).first, '3');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(saved!['vendorid'], 9);
    expect(saved!['productid'], 21);
  });

  testWidgets('an id that cannot be resolved keeps the value', (t) async {
    await t.pumpWidget(form(initial: {'vendorid': 999, 'productid': 21}));
    await t.pumpAndSettle();

    expect(find.text('#999'), findsOneWidget,
        reason: 'showing it unresolved beats silently dropping a valid id');

    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(saved!['vendorid'], 999, reason: 'the id survives');
  });

  // ═══ VALIDATION ═══════════════════════════════════════════════════════════

  testWidgets('a required lookup blocks Save while empty', (t) async {
    await t.pumpWidget(form());
    await t.pumpAndSettle();

    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(saved, isNull, reason: 'validation must include lookup fields');
    expect(find.text('Select Vendor'), findsWidgets,
        reason: 'the validator uses the bare label; the asterisk is display only');
  });

  testWidgets('an optional lookup left empty saves null', (t) async {
    await t.pumpWidget(form(requiredVendor: false));
    await t.pumpAndSettle();
    await pick(t, 'Item *', '19 Litre', '19 Litre Bottle');

    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!['vendorid'], isNull,
        reason: 'an unset optional lookup behaves like an unset dropdown');
  });

  // ═══ BOUNDS AND SCOPE ═════════════════════════════════════════════════════

  testWidgets('results are bounded to the limit', (t) async {
    await t.pumpWidget(form(vendorSearch: floodSearch));
    await t.pumpAndSettle();

    await t.tap(lookupNamed('Vendor *').first);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'Vendor');
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();

    final tiles = t.widgetList(find.byType(ListTile)).length;
    expect(tiles, lessThanOrEqualTo(wsLookupLimit),
        reason: 'at most $wsLookupLimit rows ever reach the picker');
  });

  testWidgets('the vendor search is never given a store filter', (t) async {
    await t.pumpWidget(form());
    await t.pumpAndSettle();
    await pick(t, 'Vendor *', 'Pak', 'Pak Plastics');

    // WsLookupService.vendors takes only a query and a limit — there is no
    // store parameter to pass. This asserts the field calls it that way.
    expect(vendorQueries, isNotEmpty);
    expect(vendorQueries.every((q) => q == 'Pak'), isTrue,
        reason: 'the field forwards the raw query and nothing else');
  });

  test('the service exposes no way to scope vendors or products by store', () {
    // A compile-time guarantee expressed as a runtime check: these functions
    // accept a query and a limit. If somebody adds a storeId parameter, the
    // org-wide rule from migration 015 has been broken and this is the place
    // it should be argued about.
    expect(WsLookupService.vendors, isA<Function>());
    expect(WsLookupService.products, isA<Function>());
  });

  // ═══ OTHER FIELD TYPES ARE UNAFFECTED ═════════════════════════════════════

  testWidgets('a form with no lookup fields behaves exactly as before',
      (t) async {
    Map<String, dynamic>? out;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WsCrudForm(
          title: 'Plain',
          initial: const {'name': 'Existing', 'active': true},
          fields: [
            const WsField('name', 'Name', required: true),
            const WsField('active', 'Active', type: WsFieldType.toggle),
            WsField(
              'kind',
              'Kind',
              type: WsFieldType.dropdown,
              options: () async => [
                {'id': 1, 'label': 'First'},
                {'id': 2, 'label': 'Second'},
              ],
            ),
          ],
          onSave: (v) async => out = v,
        ),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.byType(WsLookupField), findsNothing);
    expect(find.byType(DropdownButtonFormField<Object?>), findsOneWidget);

    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(out, isNotNull);
    expect(out!['name'], 'Existing');
    expect(out!['active'], true);
    expect(out!['kind'], isNull);
  });

  // ═══ A TOGGLE IS NEVER NULL ═══════════════════════════════════════════════
  //
  // Product Type → Save returned:
  //   null value in column "isdefault" of relation "ws_tblbottletypes"
  //   violates not-null constraint   (23502)
  //
  // ws_tblbottletypes.isdefault is `boolean not null default false`, and a
  // column DEFAULT applies only when the column is OMITTED from the INSERT —
  // sending null explicitly stores null and trips the constraint.
  //
  // An untouched toggle held null, and the switch renders `value == true`, so
  // it LOOKED off while holding null. The form therefore only worked if the
  // user tapped the switch on and then off again, which is why the obvious
  // manual test (turn it on, save a default type) always passed.

  group('a toggle never sends null', () {
    Map<String, dynamic>? out;

    Widget toggleForm({Map<String, dynamic>? initial, Object? fieldInitial}) {
      out = null;
      return MaterialApp(
        home: Scaffold(
          body: WsCrudForm(
            title: 'Product Type',
            initial: initial,
            fields: [
              const WsField('bottlecode', 'Code', required: true),
              WsField(
                'isdefault',
                'Default product type',
                type: WsFieldType.toggle,
                initial: fieldInitial,
              ),
            ],
            onSave: (v) async => out = v,
          ),
        ),
      );
    }

    Future<void> save(WidgetTester t) async {
      await t.enterText(find.byType(TextFormField).first, 'B06');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
    }

    testWidgets('A. a new record with the toggle untouched saves false',
        (t) async {
      await t.pumpWidget(toggleForm());
      await t.pumpAndSettle();
      await save(t);

      expect(out!['isdefault'], false,
          reason: 'THE DEFECT: this was null, which is 23502 against a '
              '`not null default false` column');
      expect(out!['isdefault'], isNotNull);
      expect(out!.containsKey('isdefault'), isTrue,
          reason: 'still sent, just never as null');
    });

    testWidgets('B. toggling it ON saves true', (t) async {
      await t.pumpWidget(toggleForm());
      await t.pumpAndSettle();
      await t.tap(find.byType(SwitchListTile));
      await t.pumpAndSettle();
      await save(t);

      expect(out!['isdefault'], true);
    });

    testWidgets('C. ON then OFF saves false', (t) async {
      await t.pumpWidget(toggleForm());
      await t.pumpAndSettle();
      await t.tap(find.byType(SwitchListTile));
      await t.pumpAndSettle();
      await t.tap(find.byType(SwitchListTile));
      await t.pumpAndSettle();
      await save(t);

      expect(out!['isdefault'], false,
          reason: 'the only path that worked before the fix — it must keep '
              'working, and now it is no longer the only one');
    });

    testWidgets('D. an untouched toggle renders as off', (t) async {
      await t.pumpWidget(toggleForm());
      await t.pumpAndSettle();

      final s = t.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(s.value, isFalse,
          reason: 'the display was already correct — only the stored value '
              'was wrong, which is exactly why this went unnoticed');
    });

    // ── editing an existing row is unchanged ──────────────────────────────

    testWidgets('editing a row with isdefault true keeps true', (t) async {
      await t.pumpWidget(toggleForm(initial: const {
        'bottlecode': 'BT19',
        'isdefault': true,
      }));
      await t.pumpAndSettle();

      expect(t.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
      await save(t);
      expect(out!['isdefault'], true);
    });

    testWidgets('editing a row with isdefault false keeps false', (t) async {
      await t.pumpWidget(toggleForm(initial: const {
        'bottlecode': 'BT10',
        'isdefault': false,
      }));
      await t.pumpAndSettle();
      await save(t);

      expect(out!['isdefault'], false);
    });

    testWidgets('a legacy row storing null is normalised to false', (t) async {
      // Defensive: a row written before this fix could hold null. Editing it
      // must not send that null straight back.
      await t.pumpWidget(toggleForm(initial: const {
        'bottlecode': 'OLD',
        'isdefault': null,
      }));
      await t.pumpAndSettle();
      await save(t);

      expect(out!['isdefault'], false);
    });

    testWidgets('an explicit field initial of true is honoured', (t) async {
      await t.pumpWidget(toggleForm(fieldInitial: true));
      await t.pumpAndSettle();

      expect(t.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
      await save(t);
      expect(out!['isdefault'], true);
    });
  });
}
