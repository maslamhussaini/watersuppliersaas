// =============================================================================
// test/lookup_test.dart
// Searchable lookup fields — the client half.
//
// The search function is injected, so a fake "server" here holds a table and
// applies the same rules the database does: case-insensitive contains across
// name/phone/code, ordered, LIMIT n. That lets every behaviour be driven
// without a network, while the DB-side properties — store isolation, RLS,
// LIMIT actually reaching Postgres — are proved separately in
// test_harness/bin/lookup_search.dart.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/lookup_service.dart';
import 'package:watersuppliersaas/widgets/ws_lookup_field.dart';

// ─── a fake server ────────────────────────────────────────────────────────────

class _Row {
  final int id;
  final String name;
  final String phone;
  final String code;
  const _Row(this.id, this.name, this.phone, this.code);
}

const _table = [
  _Row(1, 'Hotel ABC', '0300-1234567', 'C-001'),
  _Row(2, 'Hotel ABCD Annexe', '0300-7654321', 'C-002'),
  _Row(3, 'Restaurant XYZ', '0321-9999999', 'C-003'),
  _Row(4, 'Corner Shop', '', 'C-004'),
  // Two customers with the same name — the subtitle is what tells them apart.
  _Row(5, 'Twin Cafe', '0333-1111111', 'C-005'),
  _Row(6, 'Twin Cafe', '0333-2222222', 'C-006'),
];

int queryCount = 0;
List<String> queriesSeen = [];

Future<List<WsLookupResult>> fakeSearch(String raw) async {
  queryCount++;
  queriesSeen.add(raw);
  final q = wsSanitiseSearch(raw).toLowerCase();
  if (q.length < wsLookupMinChars) return const [];

  final hits = _table.where((r) =>
      r.name.toLowerCase().contains(q) ||
      r.phone.toLowerCase().contains(q) ||
      r.code.toLowerCase().contains(q));

  return hits
      .take(wsLookupLimit)
      .map((r) => WsLookupResult(
            id: r.id,
            label: r.name,
            subtitle: [r.code, r.phone].where((s) => s.isNotEmpty).join(' · '),
          ))
      .toList();
}

/// A server with more rows than the limit, to prove the picker says so.
Future<List<WsLookupResult>> floodSearch(String raw) async {
  queryCount++;
  return List.generate(
      wsLookupLimit,
      (i) => WsLookupResult(
          id: 1000 + i, label: 'Customer $i', subtitle: 'C-$i'));
}

// ─── harness ──────────────────────────────────────────────────────────────────

WsLookupResult? selected;

Widget host({
  WsLookupSearch? search,
  WsLookupResult? initial,
}) {
  selected = initial;
  return MaterialApp(
    home: StatefulBuilder(
      builder: (context, setState) => Scaffold(
        body: WsLookupField(
          label: 'Customer',
          value: selected,
          search: search ?? fakeSearch,
          debounce: const Duration(milliseconds: 10),
          onSelected: (r) => setState(() => selected = r),
        ),
      ),
    ),
  );
}

/// Finds a RESULT ROW, not just the text.
///
/// find.text alone also matches the search box, which contains whatever was
/// just typed — so searching for "Restaurant XYZ" and asserting one match
/// fails with two. Scoping to the tile is what makes the assertion mean
/// "the list offered this".
Finder resultTile(String label) => find.widgetWithText(ListTile, label);

Future<void> openAndType(WidgetTester tester, String text) async {
  await tester.tap(find.byType(WsLookupField));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(milliseconds: 40)); // past the debounce
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    queryCount = 0;
    queriesSeen = [];
    selected = null;
  });

  // ═══ SANITISING ═══════════════════════════════════════════════════════════

  group('query sanitising', () {
    test('strips the characters that would break a PostgREST or-filter', () {
      expect(wsSanitiseSearch('Smith, J. (Ltd)'), 'Smith J. Ltd');
      expect(wsSanitiseSearch('50%'), '50');
      expect(wsSanitiseSearch('a_b'), 'a b');
    });

    test('collapses whitespace', () {
      expect(wsSanitiseSearch('  Hotel    ABC  '), 'Hotel ABC');
    });

    test('a short or empty query is not searchable', () {
      expect(wsSearchable(''), isFalse);
      expect(wsSearchable('  '), isFalse);
      expect(wsSearchable('a'), isFalse);
      expect(wsSearchable('ab'), isTrue);
      expect(wsSearchable('%'), isFalse,
          reason: 'a lone wildcard sanitises away to nothing');
    });
  });

  // ═══ DEBOUNCE ═════════════════════════════════════════════════════════════

  group('debouncing', () {
    test('a burst of keystrokes produces one query', () async {
      final d = WsSearchDebouncer(delay: const Duration(milliseconds: 20));
      var calls = 0;
      for (final term in ['H', 'Ho', 'Hot', 'Hote', 'Hotel']) {
        d.run<String>(() async {
          calls++;
          return term;
        }, (_) {});
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, 1);
    });

    test('a superseded result is discarded even if it arrives late', () async {
      final d = WsSearchDebouncer(delay: const Duration(milliseconds: 5));
      final delivered = <String>[];

      d.run<String>(() async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return 'slow "Hot"';
      }, delivered.add);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      d.run<String>(() async => 'fast "Hotel"', delivered.add);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(delivered, ['fast "Hotel"'],
          reason: 'out-of-order answers must not overwrite the newest');
    });

    test('cancel abandons a pending query', () async {
      final d = WsSearchDebouncer(delay: const Duration(milliseconds: 20));
      var calls = 0;
      d.run<int>(() async => ++calls, (_) {});
      d.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 0);
    });
  });

  // ═══ SEARCHING ════════════════════════════════════════════════════════════

  group('searching', () {
    testWidgets('exact name', (t) async {
      await t.pumpWidget(host());
      await openAndType(t, 'Restaurant XYZ');
      expect(resultTile('Restaurant XYZ'), findsOneWidget);
      expect(resultTile('Hotel ABC'), findsNothing);
    });

    testWidgets('partial name matches several', (t) async {
      await t.pumpWidget(host());
      await openAndType(t, 'Hotel');
      expect(resultTile('Hotel ABC'), findsOneWidget);
      expect(resultTile('Hotel ABCD Annexe'), findsOneWidget);
    });

    testWidgets('by phone', (t) async {
      await t.pumpWidget(host());
      await openAndType(t, '7654321');
      expect(resultTile('Hotel ABCD Annexe'), findsOneWidget);
      expect(resultTile('Hotel ABC'), findsNothing);
    });

    testWidgets('by customer code', (t) async {
      await t.pumpWidget(host());
      await openAndType(t, 'C-003');
      expect(resultTile('Restaurant XYZ'), findsOneWidget);
    });

    testWidgets('is case-insensitive', (t) async {
      await t.pumpWidget(host());
      await openAndType(t, 'hOtEl aBc');
      expect(resultTile('Hotel ABC'), findsOneWidget);
    });

    testWidgets('no results says so', (t) async {
      await t.pumpWidget(host());
      await openAndType(t, 'Nobody At All');
      expect(find.text('Nothing matched that.'), findsOneWidget);
    });

    testWidgets('duplicate names are told apart by the subtitle', (t) async {
      await t.pumpWidget(host());
      await openAndType(t, 'Twin Cafe');
      expect(resultTile('Twin Cafe'), findsNWidgets(2));
      expect(find.text('C-005 · 0333-1111111'), findsOneWidget);
      expect(find.text('C-006 · 0333-2222222'), findsOneWidget);
    });

    testWidgets('a full page warns there may be more', (t) async {
      await t.pumpWidget(host(search: floodSearch));
      await openAndType(t, 'Customer');

      // The notice is the last item in a scrolling list, so it is not built
      // until it comes into view — the same reason a user has to scroll to
      // read it.
      await t.scrollUntilVisible(
        find.textContaining('Showing the first $wsLookupLimit'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(
          find.textContaining('Showing the first $wsLookupLimit'), findsOneWidget);
    });
  });

  // ═══ NOT QUERYING ═════════════════════════════════════════════════════════

  group('the empty search', () {
    testWidgets('opening the picker queries nothing', (t) async {
      await t.pumpWidget(host());
      await t.tap(find.byType(WsLookupField));
      await t.pumpAndSettle();
      expect(queryCount, 0,
          reason: 'an unbounded query on open is the thing being replaced');
      expect(find.textContaining('Type at least'), findsOneWidget);
    });

    testWidgets('one character still queries nothing', (t) async {
      await t.pumpWidget(host());
      await openAndType(t, 'H');
      expect(queryCount, 0);
    });

    testWidgets('clearing the box stops querying and clears results', (t) async {
      await t.pumpWidget(host());
      await openAndType(t, 'Hotel');
      expect(resultTile('Hotel ABC'), findsOneWidget);

      await t.enterText(find.byType(TextField), '');
      await t.pump(const Duration(milliseconds: 40));
      await t.pumpAndSettle();
      expect(resultTile('Hotel ABC'), findsNothing);
      expect(find.textContaining('Type at least'), findsOneWidget);
    });
  });

  // ═══ SELECTION ════════════════════════════════════════════════════════════

  group('selection', () {
    testWidgets('picking a result selects it and closes the sheet', (t) async {
      await t.pumpWidget(host());
      await openAndType(t, 'Restaurant');
      await t.tap(resultTile('Restaurant XYZ'));
      await t.pumpAndSettle();

      expect(selected?.id, 3);
      expect(find.byType(TextField), findsNothing, reason: 'the sheet closed');
      expect(find.text('Restaurant XYZ'), findsOneWidget,
          reason: 'and the field shows it');
    });

    testWidgets('an existing selection survives editing', (t) async {
      const existing =
          WsLookupResult(id: 99, label: 'Already Chosen', subtitle: 'C-099');
      await t.pumpWidget(host(initial: existing));
      expect(find.text('Already Chosen'), findsOneWidget);

      // Open, search for something else, then dismiss without choosing.
      await openAndType(t, 'Hotel');
      Navigator.of(t.element(resultTile('Hotel ABC'))).pop();
      await t.pumpAndSettle();

      expect(selected?.id, 99,
          reason: 'a dismissed sheet must never clear the selection');
      expect(find.text('Already Chosen'), findsOneWidget);
    });

    testWidgets('a selection not in the results is still displayed', (t) async {
      const existing = WsLookupResult(
          id: 12345, label: 'Archived Customer', subtitle: 'C-999');
      await t.pumpWidget(host(initial: existing));
      expect(find.text('Archived Customer'), findsOneWidget,
          reason: 'editing a record whose customer no longer matches a search '
              'must not lose the customer');
    });

    testWidgets('the current selection is ticked in the list', (t) async {
      const existing =
          WsLookupResult(id: 1, label: 'Hotel ABC', subtitle: 'C-001');
      await t.pumpWidget(host(initial: existing));
      await openAndType(t, 'Hotel');
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('choosing a different record replaces the selection', (t) async {
      const existing =
          WsLookupResult(id: 1, label: 'Hotel ABC', subtitle: 'C-001');
      await t.pumpWidget(host(initial: existing));
      await openAndType(t, 'Restaurant');
      await t.tap(resultTile('Restaurant XYZ'));
      await t.pumpAndSettle();
      expect(selected?.id, 3);
    });
  });

  // ═══ FAILURE ══════════════════════════════════════════════════════════════

  testWidgets('a failing search reports rather than showing an empty list',
      (t) async {
    await t.pumpWidget(host(search: (_) async => throw 'network is down'));
    await openAndType(t, 'Hotel');
    expect(find.textContaining('network is down'), findsOneWidget);
    expect(find.text('Nothing matched that.'), findsNothing,
        reason: 'a failure must not look like an empty result');
  });
}
