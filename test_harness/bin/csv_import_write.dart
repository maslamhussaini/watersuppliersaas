// =============================================================================
// bin/csv_import_write.dart
//
// The WRITE half of CSV customer import, executed against real PostgreSQL 16
// loaded with 000–017.
//
// The planner is the app's own file (lib/ws_csv_import.dart is a byte copy), so
// what is being tested is the real decision-making. Only the execution step is
// reimplemented here, calling the same RPCs the Flutter applier calls —
// ws_record_customer and ws_set_customer_opening — because the applier itself
// needs a Supabase client that does not exist in a plain Dart process.
//
// What matters is that the accounting comes out right: a bulk write of opening
// balances has to leave the ledger exactly as a hundred individual saves would.
//
// Run:  dart run bin/csv_import_write.dart
// =============================================================================

import 'dart:io';

import 'package:postgres/postgres.dart';

import '../lib/ws_csv_import.dart';

late Connection db;
late String owner;
late int storeDefault;
late int storeB;
const orgId = 1;

int pass = 0, fail = 0;
final failures = <String>[];

void check(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
    print('    ok    $name${extra.isEmpty ? '' : '   ($extra)'}');
  } else {
    fail++;
    failures.add(name);
    print('    FAIL  $name${extra.isEmpty ? '' : '   ($extra)'}');
  }
}

Future<Connection> connect() => Connection.open(
      Endpoint(
          host: 'localhost',
          port: 5433,
          database: 'ws_csv',
          username: 'postgres',
          password: ''),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

Future<num> scalar(String sql) async {
  final v = (await db.execute(sql)).first[0];
  return v is num ? v : num.parse('$v');
}

Future<double> d(String sql) async => (await scalar(sql)).toDouble();
Future<String?> str(String sql) async {
  final r = await db.execute(sql);
  return r.isEmpty ? null : r.first[0]?.toString();
}

Future<int> recon() async =>
    (await scalar('select count(*)::int from public.vw_ws_reconciliation'))
        .toInt();
Future<int> unbalanced() async => (await scalar(
        'select count(*)::int from public.vw_ws_unbalancedentries'))
    .toInt();

Future<double> arTotal() => d(
    "select coalesce(sum(jd.debit - jd.credit),0)::float8 "
    "from public.ws_tbljournalentrydetails jd "
    "join public.ws_tblaccounts a on a.accountid = jd.accountid "
    "where jd.orgid = $orgId and a.controlfor = 'ar'");

// ── a deterministic starting state, without deleting anything ───────────────
//
// This harness creates 42 ACTIVE customers per run — one 'CSV New', one
// 'CSV Repeat' and the 40-row bulk import — and never used to release any of
// them. That was invisible until migration 019 capped a free organization at 50
// active customers: run 1 left ws_csv at 45, run 2 reached 50 partway through
// its bulk import and the whole harness died on P0001.
//
// The fix is a baseline, not a rebuild. Nothing is deleted and nothing is
// truncated.
//
// WHAT IS PRESERVED: the three seeded customers (Ahmed Household, Hotel ABC,
// Restaurant XYZ). They carry no digits in their names, they are the planner's
// standing match candidates, and the contract this harness asserts is
// 3 seed + 2 + 40 = 45 active.
//
// WHAT IS RELEASED: rows this harness itself left behind on earlier runs,
// identified by the prefix it stamps them with plus the microsecond run stamp
// embedded in the name. Deactivating them is what a clean database would have
// looked like — they also stop polluting the planner's candidate list, which
// only ever loads isactive customers.
//
// Verified before this was written, rather than assumed:
//   · no assertion references a seeded customer by name;
//   · arTotal() reads ws_tbljournalentrydetails joined to the AR control
//     account — no customer isactive filter — and every AR assertion is a
//     DELTA, so releasing rows cannot move it;
//   · vw_ws_reconciliation carries no isactive predicate, and recon() is
//     compared against r0 captured inside run(), after this step.
Future<int> releasePreviousRunFixtures() async {
  final r = await db.execute(
      'update public.ws_tblcustomers set isactive = false '
      'where orgid = $orgId and isactive '
      r"  and customername ~ '^(CSV|Bulk) .*[0-9]{13,}' "
      'returning customerid');
  return r.length;
}

/// The non-default branch this harness needs, owned by this harness.
///
/// Three assertions depend on a store that is not the default: that an import
/// lands in the SELECTED branch, and that a later update does not move it. The
/// harness used to read `where not isdefault limit 1` and take whatever another
/// harness happened to have left in the database — on a database built from
/// migrations + seed alone there is no such row and main() died with
/// `Bad state: No element` before a single check ran.
///
/// Keyed on a storecode of its own so it is found again on the next run instead
/// of accumulating, and created if absent.
Future<int> ensureFixtureBranch() async {
  const code = 'CSVFIX';
  final existing = await db.execute(
      'select storeid from public.ws_tblstores '
      "where orgid = $orgId and storecode = '$code'");
  if (existing.isNotEmpty) return num.parse('${existing.first[0]}').toInt();

  return (await scalar(
          'insert into public.ws_tblstores '
          '(orgid, storecode, storename, isdefault) '
          "values ($orgId, '$code', 'CSV harness branch', false) "
          'returning storeid'))
      .toInt();
}

Future<int> bottlesFor(int customerId) async => (await scalar(
        "select coalesce(sum(qty),0)::int from public.ws_tblbottletransactions "
        "where orgid = $orgId and customerid = $customerId "
        "and txntype = 'opening'"))
    .toInt();

/// The postgres driver hands back `numeric` as a String, so a blind cast to
/// num throws. Every money column below goes through here.
double? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}

// ── loading the planner's view of the world, the way the app does ───────────

Future<({List<WsImportCustomer> customers, List<WsImportArea> areas})>
    context_() async {
  final areaRows = await db.execute(
      'select areaid, areaname from public.ws_tblareas '
      'where orgid = $orgId and isactive');
  final custRows = await db.execute(
      'select customerid, customername, phone, areaid, address, contactperson, '
      'email, customercode, rateoverride, depositamount, openingbalance '
      'from public.ws_tblcustomers where orgid = $orgId and isactive');

  final qty = <int, int>{};
  for (final r in await db.execute(
      "select customerid, qty from public.ws_tblbottletransactions "
      "where orgid = $orgId and txntype = 'opening' and customerid is not null")) {
    final id = (r[0] as num).toInt();
    qty[id] = (qty[id] ?? 0) + (r[1] as num).toInt();
  }

  return (
    customers: custRows.map((r) {
      final id = (r[0] as num).toInt();
      return WsImportCustomer(
        customerId: id,
        customerName: '${r[1]}',
        phone: r[2] as String?,
        areaId: (r[3] as num?)?.toInt(),
        address: r[4] as String?,
        contactPerson: r[5] as String?,
        email: r[6] as String?,
        customerCode: r[7] as String?,
        rateOverride: _num(r[8]),
        depositAmount: _num(r[9]) ?? 0,
        openingBalance: _num(r[10]) ?? 0,
        openingQty: qty[id] ?? 0,
      );
    }).toList(),
    areas: areaRows
        .map((r) => WsImportArea((r[0] as num).toInt(), '${r[1]}'))
        .toList(),
  );
}

/// The same sequence the Flutter applier performs, against the same RPCs.
Future<({int created, int updated})> applyPlan(WsImportPlan plan,
    {int? storeId}) async {
  if (plan.hasErrors) {
    throw StateError('refused: the plan has errors');
  }
  var created = 0, updated = 0;

  for (final row in plan.rows) {
    if (row.action == WsImportAction.unchanged ||
        row.action == WsImportAction.error) {
      continue;
    }

    int customerId;
    if (row.action == WsImportAction.create) {
      final r = await db.execute(Sql.named(
          'select public.ws_record_customer('
          'p_orgid => @o, p_customername => @n, p_areaid => @a, '
          'p_customercode => @c, p_contactperson => @ct, p_phone => @p, '
          'p_email => @e, p_address => @ad, p_rateoverride => @rt, '
          'p_depositamount => @dp, p_clientuuid => @u, p_storeid => @s) as id'),
          parameters: {
            'o': orgId,
            'n': row.name,
            'a': row.values['areaid'],
            'c': row.values['code'],
            'ct': row.values['contact'],
            'p': row.values['phone'],
            'e': row.values['email'],
            'ad': row.values['address'],
            'rt': row.values['rate'],
            'dp': row.values['deposit'] ?? 0,
            'u': row.clientUuid,
            's': storeId,
          });
      customerId = (r.first[0] as num).toInt();
      created++;
    } else {
      customerId = row.customerId!;
      final sets = <String>[];
      final params = <String, dynamic>{'id': customerId};
      void put(String key, String col, [String cast = '']) {
        if (row.values.containsKey(key)) {
          sets.add('$col = @$key$cast');
          params[key] = row.values[key];
        }
      }

      put('phone', 'phone');
      put('areaid', 'areaid');
      put('address', 'address');
      put('contact', 'contactperson');
      put('email', 'email');
      put('code', 'customercode');
      put('rate', 'rateoverride');
      put('deposit', 'depositamount');

      if (sets.isNotEmpty) {
        await db.execute(
            Sql.named('update public.ws_tblcustomers set ${sets.join(', ')} '
                'where customerid = @id and orgid = $orgId'),
            parameters: params);
      }
      updated++;
    }

    final hasMoney = row.values.containsKey('openingbalance');
    final hasQty = row.values.containsKey('openingqty');
    if (hasMoney || hasQty) {
      await db.execute(
          Sql.named('select public.ws_set_customer_opening('
              'p_customerid => @c, p_openingdue => @m, p_openingqty => @q)'),
          parameters: {
            'c': customerId,
            'm': hasMoney
                ? row.values['openingbalance']
                : row.currentOpeningBalance,
            'q': hasQty ? row.values['openingqty'] : row.currentOpeningQty,
          });
    }
  }
  return (created: created, updated: updated);
}

Future<WsImportPlan> planFor(String csv) async {
  final ctx = await context_();
  return WsCsvImportPlanner(existing: ctx.customers, areas: ctx.areas)
      .plan(csv);
}

// ═════════════════════════════════════════════════════════════════════════════

Future<void> run() async {
  final areaName = (await str(
      'select areaname from public.ws_tblareas where orgid = $orgId limit 1'))!;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  // A phone number has to look like one — the validator rejects a 16-digit
  // timestamp, correctly. Seven digits, unique per run.
  final ph = (stamp % 10000000).toString().padLeft(7, '0');

  // ── new customer lands in the selected branch ────────────────────────────
  print('\n═══ a new customer takes the selected branch ═══');
  final r0 = await recon();
  final plan1 = await planFor('name,phone,area,address,openingbalance,openingqty\n'
      'CSV New $stamp,0311-$ph,$areaName,First Street,1000,7\n');
  if (plan1.hasErrors) {
    for (final r in plan1.errored) {
      print('      row ${r.lineNumber} "${r.name}": ${r.errors.join('; ')}');
    }
  }
  check('the plan is clean', !plan1.hasErrors, plan1.summary);
  check('it is a create', plan1.creates.length == 1);

  final out1 = await applyPlan(plan1, storeId: storeB);
  check('one customer created', out1.created == 1);

  final newId = (await scalar("select customerid from public.ws_tblcustomers "
          "where customername = 'CSV New $stamp'"))
      .toInt();
  check('it went to the selected branch, not the default',
      await scalar('select storeid from public.ws_tblcustomers '
              'where customerid = $newId') ==
          storeB,
      'default is $storeDefault');
  check('the opening balance posted to AR',
      await d('select ws.customer_opening_posted($orgId, $newId)::float8') ==
          1000);
  check('the opening bottles reached the bottle ledger',
      await bottlesFor(newId) == 7);
  check('reconciliation still 0', await recon() == r0);
  check('no unbalanced entries', await unbalanced() == 0);

  // ── existing customer updated, branch untouched ──────────────────────────
  print('\n═══ an existing customer is updated without moving branch ═══');
  final arBefore = await arTotal();
  final plan2 = await planFor('name,phone,address\n'
      'CSV New $stamp,0311-$ph,Second Street\n');
  check('matched by phone', plan2.updates.single.matchedBy == 'phone');
  check('only the address is changing',
      plan2.updates.single.changes.map((c) => c.field).join(',') == 'Address');

  await applyPlan(plan2, storeId: storeDefault);
  check('the address changed',
      await str('select address from public.ws_tblcustomers '
              'where customerid = $newId') ==
          'Second Street');
  check('THE BRANCH DID NOT MOVE, even though another was selected',
      await scalar('select storeid from public.ws_tblcustomers '
              'where customerid = $newId') ==
          storeB);
  check('AR did not move — no opening column in the file',
      await arTotal() == arBefore);
  check('the bottle ledger did not move', await bottlesFor(newId) == 7);
  check('reconciliation still 0', await recon() == r0);

  // ── THE BLANK RULE, end to end ───────────────────────────────────────────
  print('\n═══ blank cells never zero anything ═══');
  final plan3 = await planFor(
      'name,phone,address,openingbalance,openingqty\n'
      'CSV New $stamp,,Third Street,,\n');
  check('the plan proposes only the address',
      plan3.updates.single.changes.map((c) => c.field).join(',') == 'Address');
  check('the planner carried the current opening balance forward',
      plan3.updates.single.currentOpeningBalance == 1000);
  check('and the current bottle count', plan3.updates.single.currentOpeningQty == 7);

  await applyPlan(plan3, storeId: storeB);
  check('the opening balance survived a blank cell',
      await d('select ws.customer_opening_posted($orgId, $newId)::float8') ==
          1000);
  check('THE BOTTLES SURVIVED A BLANK CELL', await bottlesFor(newId) == 7,
      'a blank must never mean zero');
  check('the phone survived a blank cell',
      (await str('select phone from public.ws_tblcustomers '
              'where customerid = $newId'))!
          .isNotEmpty);
  check('reconciliation still 0', await recon() == r0);

  // ── one half supplied, the other blank ───────────────────────────────────
  print('\n═══ supplying money but not bottles ═══');
  final plan4 = await planFor('name,phone,openingbalance\n'
      'CSV New $stamp,0311-$ph,600\n');
  await applyPlan(plan4, storeId: storeB);
  check('AR was adjusted to the new figure',
      await d('select ws.customer_opening_posted($orgId, $newId)::float8') ==
          600);
  check('the bottles were NOT wiped by the omitted column',
      await bottlesFor(newId) == 7,
      'the exact failure the applier re-sends currentOpeningQty to prevent');
  check('reconciliation still 0', await recon() == r0);

  // ── repeated import ─────────────────────────────────────────────────────
  print('\n═══ importing the same file twice ═══');
  final csvRepeat = 'name,phone,area,address\n'
      'CSV Repeat $stamp,0322-$ph,$areaName,Repeat Road\n';
  final firstPlan = await planFor(csvRepeat);
  await applyPlan(firstPlan, storeId: storeB);
  final countAfterFirst = (await scalar(
          "select count(*)::int from public.ws_tblcustomers "
          "where customername = 'CSV Repeat $stamp'"))
      .toInt();

  // A completely fresh plan, as re-picking the file would produce: new keys,
  // but the phone now matches an existing customer.
  final secondPlan = await planFor(csvRepeat);
  check('the second run plans an update, not a create',
      secondPlan.creates.isEmpty);
  check('and finds nothing to change',
      secondPlan.updates.isEmpty && secondPlan.unchanged.length == 1);
  await applyPlan(secondPlan, storeId: storeB);
  check('no duplicate customer',
      await scalar("select count(*)::int from public.ws_tblcustomers "
              "where customername = 'CSV Repeat $stamp'") ==
          countAfterFirst);

  // Re-confirming the SAME plan is protected by the clientuuid instead.
  await applyPlan(firstPlan, storeId: storeB);
  check('re-confirming the same plan is idempotent too',
      await scalar("select count(*)::int from public.ws_tblcustomers "
              "where customername = 'CSV Repeat $stamp'") ==
          countAfterFirst,
      'ws_record_customer resolves the key from 014');
  check('reconciliation still 0', await recon() == r0);

  // ── a batch with errors writes nothing ──────────────────────────────────
  print('\n═══ a batch with any error writes nothing ═══');
  final before = (await scalar(
          'select count(*)::int from public.ws_tblcustomers where orgid = $orgId'))
      .toInt();
  final arBeforeBad = await arTotal();
  final badPlan = await planFor('name,phone,area,openingbalance\n'
      'CSV Good A $stamp,0333-$ph,$areaName,100\n'
      'CSV Bad $stamp,123,$areaName,100\n'
      'CSV Good B $stamp,0334-$ph,$areaName,100\n');
  check('the plan reports the error', badPlan.hasErrors);
  check('and still shows the good rows in the preview',
      badPlan.creates.length == 2);

  var refused = false;
  try {
    await applyPlan(badPlan, storeId: storeB);
  } on StateError {
    refused = true;
  }
  check('the applier REFUSED the batch', refused);
  check('not one row was written',
      await scalar('select count(*)::int from public.ws_tblcustomers '
              'where orgid = $orgId') ==
          before);
  check('AR untouched', await arTotal() == arBeforeBad);
  check('reconciliation still 0', await recon() == r0);

  // ── bulk ────────────────────────────────────────────────────────────────
  print('\n═══ a realistic bulk import ═══');
  final sb = StringBuffer('name,phone,area,openingbalance,openingqty\n');
  for (var i = 0; i < 40; i++) {
    sb.writeln('Bulk $stamp-$i,03${(45 + i).toString().padLeft(2, '0')}-$ph,$areaName,${100 + i},${i % 5}');
  }
  final arBeforeBulk = await arTotal();
  final bulkPlan = await planFor(sb.toString());
  check('40 rows planned as creates', bulkPlan.creates.length == 40);
  final outBulk = await applyPlan(bulkPlan, storeId: storeB);
  check('40 customers created', outBulk.created == 40);

  final expectedAr = List.generate(40, (i) => 100 + i).reduce((a, b) => a + b);
  check('AR rose by exactly the sum of the opening balances',
      await arTotal() - arBeforeBulk == expectedAr, '$expectedAr');
  check('reconciliation STILL 0 after a bulk write', await recon() == r0);
  check('no unbalanced entries', await unbalanced() == 0);
}

void main() async {
  db = await connect();
  owner = (await db.execute("select m.authuserid::text from "
          "public.ws_tblmemberships m "
          "join public.ws_tblrolepermissions rp on rp.roleid = m.roleid "
          "where m.orgid = $orgId and rp.permcode = 'customers.manage' limit 1"))
      .first[0] as String;
  await db.execute("set ws.test_uid = '$owner'");

  storeDefault = (await scalar(
          'select storeid from public.ws_tblstores '
          'where orgid = $orgId and isdefault'))
      .toInt();
  storeB = await ensureFixtureBranch();

  final released = await releasePreviousRunFixtures();
  final baseline = (await scalar('select count(*) from public.ws_tblcustomers '
          'where orgid = $orgId and isactive'))
      .toInt();
  print('baseline: released $released fixture customer(s) from earlier runs; '
      '$baseline active before this run  (needs <= 8 for 2 + 40 more)');

  await run();

  print('\n${'═' * 64}');
  print('  $pass passed, $fail failed');
  if (failures.isNotEmpty) {
    print('  failing checks:');
    for (final f in failures) {
      print('    · $f');
    }
  }
  print('${'═' * 64}');

  await db.close();
  exit(fail == 0 ? 0 : 1);
}
