// =============================================================================
// test/csv_import_apply_test.dart
// The REAL production applier, executed.
//
// ─── WHY THIS FILE EXISTS ────────────────────────────────────────────────────
//
// WsCsvImportService.apply() had never been run by any test. The integration
// harness (test_harness/bin/csv_import_write.dart) reimplements the apply loop
// rather than importing it, because the real one needed a Supabase client — so
// everything interesting about it was correct-by-inspection only. That is the
// state that has hidden three defects in this project already.
//
// The REAL apply() is called here, with the REAL planner feeding it. Only the
// three writes are faked, through the seam.
//
// These tests CHARACTERISE current behaviour. Where the behaviour looks odd —
// see the counter group at the bottom — the test records what it does rather
// than asserting what it ought to do. Changing it is a separate decision.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/import/ws_csv_import.dart';
import 'package:watersuppliersaas/services/import/ws_csv_import_apply.dart';

import 'support/fake_csv_import_ops.dart';

void main() {
  final areas = [const WsImportArea(7, 'Gulshan')];

  var seq = 0;
  String uuid() => 'uuid-${++seq}';

  WsImportPlan planFor(String csv, List<WsImportCustomer> existing) =>
      WsCsvImportPlanner(existing: existing, areas: areas, newUuid: uuid)
          .plan(csv);

  /// The fake's committed customers, as the planner wants to see them.
  List<WsImportCustomer> contextOf(FakeCsvImportOps fake) => fake
      .customers.values
      .map((c) => WsImportCustomer(
            customerId: c.customerId,
            customerName: c.name,
            phone: c.fields['phone'] as String?,
            areaId: c.fields['areaid'] as int?,
            address: c.fields['address'] as String?,
            openingBalance: c.openingDue.toDouble(),
            openingQty: c.openingQty.toInt(),
          ))
      .toList();

  const threeRows = 'name,phone,area,openingbalance,openingqty\n'
      'Alpha Store,0300-1111111,Gulshan,1000,5\n'
      'Beta Store,0300-2222222,Gulshan,2000,3\n'
      'Gamma Store,0300-3333333,Gulshan,3000,1\n';

  setUp(() => seq = 0);

  // ═══ 1. CUSTOMER SUCCEEDS, OPENING FAILS ══════════════════════════════════

  group('a customer written, then its opening balance refused', () {
    test('the customer stays committed and the loop carries on', () async {
      final fake = FakeCsvImportOps()..throwBeforeOpening.add('Beta Store');
      final plan = planFor(threeRows, const []);

      final out = await WsCsvImportService.apply(plan, deps: fake.deps());

      expect(fake.byName('Beta Store'), isNotNull,
          reason: 'the customer write already committed — the failure came '
              'afterwards, and nothing rolls it back');
      expect(fake.byName('Beta Store')!.openingDue, 0,
          reason: 'the opening never posted');

      expect(fake.calls, contains('record:Beta Store'));
      expect(fake.calls.any((c) => c.startsWith('opening:Beta Store')), isTrue,
          reason: 'it must have been ATTEMPTED, not skipped');

      expect(out.failures.length, 1);
      expect(out.failures.single, contains('Beta Store'));

      expect(fake.byName('Gamma Store'), isNotNull,
          reason: 'a failed row must not abandon the rows behind it');
      expect(fake.byName('Gamma Store')!.openingDue, 3000);
      expect(out.created, 3, reason: 'all three customer writes succeeded');
    });

    test('this is a partial import — some rows applied, some not', () async {
      final fake = FakeCsvImportOps()..throwBeforeOpening.add('Alpha Store');
      final plan = planFor(threeRows, const []);
      final out = await WsCsvImportService.apply(plan, deps: fake.deps());

      expect(out.clean, isFalse);
      expect(fake.customers.length, 3);
      expect(fake.byName('Alpha Store')!.openingDue, 0);
      expect(fake.byName('Beta Store')!.openingDue, 2000);
    });
  });

  // ═══ 2. LOST RESPONSE AFTER THE CUSTOMER COMMITTED ════════════════════════

  group('lost response after the customer write committed', () {
    test('the row exists even though the applier saw an exception', () async {
      final fake = FakeCsvImportOps()..loseAfterRecord.add('Alpha Store');
      final plan = planFor(threeRows, const []);

      final out = await WsCsvImportService.apply(plan, deps: fake.deps());

      expect(fake.byName('Alpha Store'), isNotNull,
          reason: 'THE SERVER COMMITTED. A double that threw before writing '
              'would be modelling a rejection, which is a different bug');
      expect(out.failures.single, contains('Alpha Store'));
      expect(out.created, 2, reason: 'the throw pre-empted created++');
      expect(fake.byName('Alpha Store')!.openingDue, 0,
          reason: 'control left the row before the opening call');
    });

    test('replaying the same plan observes the existing customer', () async {
      final fake = FakeCsvImportOps()..loseAfterRecord.add('Alpha Store');
      final plan = planFor(threeRows, const []);

      await WsCsvImportService.apply(plan, deps: fake.deps());
      final idAfterFirst = fake.byName('Alpha Store')!.customerId;

      // The lost response is over; the same plan goes again.
      fake.loseAfterRecord.clear();
      final out2 = await WsCsvImportService.apply(plan, deps: fake.deps());

      expect(fake.customers.length, 3, reason: 'NO duplicate customer');
      expect(fake.byName('Alpha Store')!.customerId, idAfterFirst,
          reason: 'the clientuuid resolved to the row already created');
      expect(fake.calls, contains('record:Alpha Store:replay->$idAfterFirst'));
      expect(out2.failures, isEmpty);
      expect(fake.byName('Alpha Store')!.openingDue, 1000,
          reason: 'the retry completed the opening the first attempt missed');
    });
  });

  // ═══ 3. LOST RESPONSE AFTER THE OPENING COMMITTED ═════════════════════════

  test('a lost response after the opening committed does not double-apply',
      () async {
    final fake = FakeCsvImportOps()..loseAfterOpening.add('Alpha Store');
    final plan = planFor(threeRows, const []);

    final out = await WsCsvImportService.apply(plan, deps: fake.deps());
    expect(out.failures.single, contains('Alpha Store'),
        reason: 'reported as failed even though it fully succeeded');
    expect(fake.byName('Alpha Store')!.openingDue, 1000);

    fake.loseAfterOpening.clear();
    await WsCsvImportService.apply(plan, deps: fake.deps());

    expect(fake.byName('Alpha Store')!.openingDue, 1000,
        reason: 'convergent, not incremental — 2000 would mean double-posting. '
            'The authoritative proof of that is at SQL level in '
            'test_harness/bin/customer_opening.dart; what this shows is that '
            'the applier can now be driven down the path at all');
    expect(fake.byName('Alpha Store')!.openingQty, 5);
    expect(fake.customers.length, 3);
  });

  // ═══ 4. PARTIAL APPLY, THEN RESUME THROUGH THE REAL PLANNER ═══════════════

  test('a partial import is completed by re-planning and applying again',
      () async {
    final fake = FakeCsvImportOps()..throwBeforeOpening.add('Beta Store');

    final plan1 = planFor(threeRows, const []);
    final out1 = await WsCsvImportService.apply(plan1, deps: fake.deps());
    expect(out1.failures.length, 1);
    expect(fake.byName('Beta Store')!.openingDue, 0);

    // Re-plan from what is actually in the database now — the resume path a
    // user takes by re-uploading the same file.
    fake.throwBeforeOpening.clear();
    final plan2 = planFor(threeRows, contextOf(fake));

    expect(plan2.creates, isEmpty,
        reason: 'every row already exists — none may be created again');
    final beta = plan2.rows.firstWhere((r) => r.name == 'Beta Store');
    expect(beta.action, WsImportAction.update,
        reason: 'the created-but-unposted row is a resume case');
    expect(beta.changes.any((c) => c.field == 'Opening balance'), isTrue);

    final out2 = await WsCsvImportService.apply(plan2, deps: fake.deps());

    expect(out2.failures, isEmpty);
    expect(out2.created, 0, reason: 'nothing was recreated');
    expect(fake.customers.length, 3, reason: 'no duplicates');
    expect(fake.byName('Beta Store')!.openingDue, 2000,
        reason: 'the gap is closed');
    expect(fake.byName('Alpha Store')!.openingDue, 1000);
    expect(fake.byName('Gamma Store')!.openingDue, 3000);
  });

  // ═══ 5. A PLAN LIMIT PART-WAY THROUGH THE LOOP ════════════════════════════

  test('a plan-limit failure mid-loop leaves the rest resumable', () async {
    // Two seats. The third row cannot be created.
    final fake = FakeCsvImportOps(maxActiveCustomers: 2);
    final plan = planFor(threeRows, const []);

    final out = await WsCsvImportService.apply(plan, deps: fake.deps());

    expect(fake.customers.length, 2, reason: 'the rows before the cap stand');
    expect(fake.byName('Alpha Store')!.openingDue, 1000);
    expect(fake.byName('Beta Store')!.openingDue, 2000);
    expect(fake.byName('Gamma Store'), isNull);

    expect(out.failures.length, 1);
    expect(out.failures.single, contains('P0001'));
    expect(out.failures.single, contains('Gamma Store'));
    expect(out.created, 2);

    // A seat is freed and the same file goes again.
    fake.maxActiveCustomers = 3;
    final plan2 = planFor(threeRows, contextOf(fake));
    final out2 = await WsCsvImportService.apply(plan2, deps: fake.deps());

    expect(out2.failures, isEmpty);
    expect(fake.customers.length, 3);
    expect(fake.byName('Gamma Store')!.openingDue, 3000);
    expect(out2.created, 1, reason: 'only the row that was missing');
  });

  test('every row after the cap fails, one failure line each', () async {
    final fake = FakeCsvImportOps(maxActiveCustomers: 1);
    final plan = planFor(threeRows, const []);
    final out = await WsCsvImportService.apply(plan, deps: fake.deps());

    expect(fake.customers.length, 1);
    expect(out.failures.length, 2,
        reason: 'the loop does not stop at the first terminal error — it '
            'attempts every remaining row and reports each. Recorded here as '
            'current behaviour, not endorsed');
    expect(out.created, 1);
  });

  // ═══ 6. COUNTER SEMANTICS, AS THEY CURRENTLY ARE ══════════════════════════

  group('counters (characterisation — not assertions about what is right)', () {
    test('a plain create counts once', () async {
      final fake = FakeCsvImportOps();
      final out = await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());
      expect(out.created, 3);
      expect(out.updated, 0);
    });

    test('an existing customer with real changes counts as updated', () async {
      final fake = FakeCsvImportOps();
      await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());

      const changed = 'name,phone,area,address\n'
          'Alpha Store,0300-1111111,Gulshan,New Road\n';
      final out = await WsCsvImportService.apply(
          planFor(changed, contextOf(fake)), deps: fake.deps());

      expect(out.updated, 1);
      expect(out.created, 0);
      expect(fake.byName('Alpha Store')!.fields['address'], 'New Road');
    });

    test('a clientuuid REPLAY still increments created', () async {
      final fake = FakeCsvImportOps();
      final plan = planFor(threeRows, const []);

      final first = await WsCsvImportService.apply(plan, deps: fake.deps());
      final second = await WsCsvImportService.apply(plan, deps: fake.deps());

      expect(fake.customers.length, 3, reason: 'no duplicate rows were made');
      expect(first.created, 3);
      expect(second.created, 3,
          reason: 'CURRENT BEHAVIOUR: created++ fires on the RPC returning an '
              'id, and the applier cannot tell a fresh insert from a replay. '
              'The second run reports 3 created while creating nothing. '
              'Recorded, not corrected — that is a separate decision');
    });

    test('an unchanged row is skipped entirely, counted as unchanged',
        () async {
      final fake = FakeCsvImportOps();
      await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());

      final plan2 = planFor(threeRows, contextOf(fake));
      final before = fake.calls.length;
      final out = await WsCsvImportService.apply(plan2, deps: fake.deps());

      expect(out.unchanged, 3);
      expect(out.created, 0);
      expect(out.updated, 0);
      expect(fake.calls.length, before,
          reason: 'no write was attempted at all');
    });

    test('an empty patch still counts as updated', () async {
      // Reachable when the planner marks a row changed on a field the applier
      // does not patch. openingbalance is exactly that: it is a change, but it
      // travels through setCustomerOpening, never through the patch map.
      final fake = FakeCsvImportOps();
      await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());

      const moneyOnly = 'name,openingbalance\nAlpha Store,4321\n';
      final out = await WsCsvImportService.apply(
          planFor(moneyOnly, contextOf(fake)), deps: fake.deps());

      expect(out.updated, 1,
          reason: 'CURRENT BEHAVIOUR: updated++ is outside the '
              'patch.isNotEmpty guard, so it counts a row whose table update '
              'never ran');
      expect(fake.calls.any((c) => c.startsWith('update:Alpha Store')), isFalse,
          reason: 'no table update was issued');
      expect(fake.byName('Alpha Store')!.openingDue, 4321,
          reason: 'the money still moved, through setCustomerOpening');
    });
  });
}
