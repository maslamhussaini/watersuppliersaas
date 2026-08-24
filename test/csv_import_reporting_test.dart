// =============================================================================
// test/csv_import_reporting_test.dart
// What the import tells the user afterwards.
//
// ─── WHY THIS FILE EXISTS ────────────────────────────────────────────────────
//
// The recovery mechanism was already proven safe: a customer cannot be
// duplicated, an opening balance cannot be double-posted, and re-uploading the
// same file finishes what did not save. None of that reached the user. The card
// said "Import finished with problems — 3 created, 0 updated, 0 unchanged,
// 37 failed" and then printed 37 raw PostgrestExceptions, so the reasonable
// reading was "this failed, and I do not know what is in my database now."
//
// These tests are about WORDING ONLY. Every counter, every failure string and
// every database operation is unchanged — the last group asserts exactly that.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/import/ws_csv_import.dart';
import 'package:watersuppliersaas/services/import/ws_csv_import_apply.dart';

import 'support/fake_csv_import_ops.dart';

void main() {
  final areas = [const WsImportArea(7, 'Gulshan')];
  var seq = 0;
  String uuid() => 'uuid-${++seq}';
  setUp(() => seq = 0);

  WsImportPlan planFor(String csv, List<WsImportCustomer> existing) =>
      WsCsvImportPlanner(existing: existing, areas: areas, newUuid: uuid)
          .plan(csv);

  const threeRows = 'name,phone,area,openingbalance,openingqty\n'
      'Alpha Store,0300-1111111,Gulshan,1000,5\n'
      'Beta Store,0300-2222222,Gulshan,2000,3\n'
      'Gamma Store,0300-3333333,Gulshan,3000,1\n';

  /// The exact text the production applier's real P0001 refusal carries, as
  /// PostgrestException renders it. Migration 019 raises the message; the
  /// number in it is the plan's, never hard-coded on this side.
  const realPostgrestP0001 =
      'Line 12 (Bulk 17-3): PostgrestException(message: plan limit reached: '
      'the free plan allows 50 active customers (currently 50), code: P0001, '
      'details: Bad Request, hint: Deactivate a customer, or upgrade the plan.)';

  // ═══ A. A CLEAN IMPORT ════════════════════════════════════════════════════

  group('A. a successful import', () {
    test('reports what was saved, and claims nothing about atomicity',
        () async {
      final fake = FakeCsvImportOps();
      final out = await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());

      expect(out.clean, isTrue);
      expect(out.summary, '3 rows saved (3 new, 0 updated)');

      expect(out.summary, isNot(contains('failed')));
      expect(out.retryAdvice, isNull,
          reason: 'nothing to retry, so no advice to give');
      expect(out.planLimitMessage, isNull);
    });

    test('unchanged rows are named as already up to date', () async {
      final fake = FakeCsvImportOps();
      await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());

      final existing = fake.customers.values
          .map((c) => WsImportCustomer(
                customerId: c.customerId,
                customerName: c.name,
                phone: c.fields['phone'] as String?,
                areaId: c.fields['areaid'] as int?,
                openingBalance: c.openingDue.toDouble(),
                openingQty: c.openingQty.toInt(),
              ))
          .toList();

      final out = await WsCsvImportService.apply(
          planFor(threeRows, existing), deps: fake.deps());
      expect(out.summary, '0 rows saved (0 new, 0 updated) · '
          '3 already up to date');
    });
  });

  // ═══ B. A PARTIAL IMPORT ══════════════════════════════════════════════════

  group('B. a partial import', () {
    late WsImportOutcome out;

    setUp(() async {
      final fake = FakeCsvImportOps()..throwBeforeOpening.add('Beta Store');
      out = await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());
    });

    test('says work WAS saved, not that the import failed', () {
      expect(out.saved, 3);
      expect(out.summary, startsWith('3 rows saved'));
      expect(out.summary, contains('1 row not saved'));
    });

    test('says the failures out loud too', () {
      expect(out.failed, 1);
      expect(out.clean, isFalse);
      expect(out.failures.single, contains('Beta Store'));
    });

    test('tells the user that re-uploading is safe', () {
      expect(out.retryAdvice, isNotNull);
      expect(out.retryAdvice, contains('same file again'));
      expect(out.retryAdvice, contains('not duplicate'));
    });

    test('never claims a rollback, and never claims atomicity', () {
      final all = '${out.summary} ${out.retryAdvice}';
      for (final forbidden in [
        'rolled back',
        'nothing was written',
        'nothing was saved',
        'atomic',
        'cancelled',
      ]) {
        expect(all.toLowerCase(), isNot(contains(forbidden)),
            reason: 'three rows ARE saved — saying otherwise would send the '
                'user looking for an undo that does not exist');
      }
    });
  });

  // ═══ C. THE PLAN LIMIT ════════════════════════════════════════════════════

  group('C. a plan-limit refusal', () {
    test('is recognised from a real PostgrestException rendering', () {
      const o = WsImportOutcome(
          created: 11, updated: 0, failures: [realPostgrestP0001]);

      expect(o.hitPlanLimit, isTrue);
      expect(o.planLimitMessage, isNotNull);
    });

    test('is said in words, with the number taken from the database message',
        () {
      const o = WsImportOutcome(
          created: 11, updated: 0, failures: [realPostgrestP0001]);

      expect(o.planLimitMessage, 'Your free plan allows 50 active customers. '
          'Remove a customer you no longer serve, or upgrade the plan, '
          'then upload the file again.');
      expect(o.planLimitMessage, isNot(contains('PostgrestException')));
      expect(o.planLimitMessage, isNot(contains('P0001')));
    });

    test('the number is NOT hard-coded — a different plan reads differently',
        () {
      const o = WsImportOutcome(failures: [
        'Line 9 (X): PostgrestException(message: plan limit reached: the basic '
            'plan allows 500 active customers (currently 500), code: P0001, '
            'details: Bad Request, hint: Upgrade.)'
      ]);
      expect(o.planLimitMessage, startsWith('Your basic plan allows 500 '
          'active customers.'));
    });

    test('the raw exception is still kept for diagnostics', () {
      const o = WsImportOutcome(failures: [realPostgrestP0001]);
      expect(o.failures.single, contains('PostgrestException'));
      expect(o.failures.single, contains('P0001'));
    });

    test('an ordinary failure is not mistaken for a plan limit', () {
      const o = WsImportOutcome(failures: [
        'Line 3 (Y): PostgrestException(message: permission denied: '
            'customers.manage, code: 42501, details: null, hint: null)'
      ]);
      expect(o.hitPlanLimit, isFalse);
      expect(o.planLimitMessage, isNull);
      expect(o.retryAdvice, isNotNull, reason: 'retry advice is not limited '
          'to plan-limit failures');
    });

    test('reached through the real applier, end to end', () async {
      final fake = FakeCsvImportOps(maxActiveCustomers: 2);
      final out = await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());

      expect(out.hitPlanLimit, isTrue);
      expect(out.planLimitMessage, contains('active customers'));
      expect(out.summary, startsWith('2 rows saved'));
    });
  });

  // ═══ D. NOTHING UNDERNEATH CHANGED ════════════════════════════════════════

  group('D. counters and behaviour are untouched', () {
    test('created, updated, unchanged and failures are as before', () async {
      final fake = FakeCsvImportOps()..throwBeforeOpening.add('Gamma Store');
      final out = await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());

      expect(out.created, 3, reason: 'still one per successful customer RPC');
      expect(out.updated, 0);
      expect(out.unchanged, 0);
      expect(out.failures.length, 1);
      expect(out.failures.single, startsWith('Line 4 (Gamma Store): '),
          reason: 'the failure string format is unchanged');
    });

    test('saved is derived, not a new counter', () async {
      final fake = FakeCsvImportOps();
      final out = await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());
      expect(out.saved, out.created + out.updated);
      expect(out.failed, out.failures.length);
    });

    test('the loop still continues after a row fails', () async {
      final fake = FakeCsvImportOps()..throwBeforeOpening.add('Alpha Store');
      await WsCsvImportService.apply(
          planFor(threeRows, const []), deps: fake.deps());

      expect(fake.customers.length, 3,
          reason: 'control flow untouched by this task');
      expect(fake.byName('Gamma Store')!.openingDue, 3000);
    });

    test('a validation error is still refused outright', () async {
      final fake = FakeCsvImportOps();
      final bad = planFor(
          'name,phone,area\nZeta,0300-9999999,Nowhere\n', const []);
      expect(bad.hasErrors, isTrue);

      await expectLater(
          () => WsCsvImportService.apply(bad, deps: fake.deps()),
          throwsA(isA<StateError>()));
      expect(fake.customers, isEmpty,
          reason: 'the whole-file validation gate is unchanged');
    });
  });
}
