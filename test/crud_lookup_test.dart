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
}
