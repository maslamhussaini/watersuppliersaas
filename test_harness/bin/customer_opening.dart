// =============================================================================
// bin/customer_opening.dart
//
// Migration 017 — the customer equivalent of the 016 matrix, executed against a
// real PostgreSQL 16.
//
//   0 -> 1000       journal +1000
//   1000 -> 1000    no additional journal
//   1000 -> 600     adjustment -400
//   600 -> 0        opening entry removed
//   retry           no duplicate
//   raw write       automatically synchronised
//   backfill        repairs mismatches
//   backfill again  changes nothing
//
// Everything is measured against the AR CONTROL BALANCE in the general ledger,
// never against ws_tblcustomers.openingbalance — the column is the thing that
// was lying.
//
// Run:  dart run bin/customer_opening.dart
// =============================================================================
import 'dart:io';

import 'package:postgres/postgres.dart';

late Connection db;
late String owner;
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
          database: 'ws_cob',
          username: 'postgres',
          password: ''),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

Future<num> scalar(String sql, [Connection? on]) async {
  final v = (await (on ?? db).execute(sql)).first[0];
  return v is num ? v : num.parse('$v');
}

Future<double> d(String sql) async => (await scalar(sql)).toDouble();

// ── the three numbers that must agree ───────────────────────────────────────

/// What the general ledger says this customer's opening receivable is.
Future<double> posted(int customerId) =>
    d('select ws.customer_opening_posted($orgId, $customerId)::float8');

/// What the customer record displays.
Future<double> column_(int customerId) => d(
    'select coalesce(openingbalance,0)::float8 from public.ws_tblcustomers '
    'where customerid = $customerId');

/// How many opening journal entries exist for this customer.
///
/// sourceid is the customerid itself — customers occupy the POSITIVE keyspace
/// and vendors the negative one, since both share sourcetype 'opening'.
Future<int> entries(int customerId) async => (await scalar(
        "select count(*)::int from public.ws_tbljournalentries "
        "where orgid = $orgId and sourcetype = 'opening' "
        "and sourceid = $customerId"))
    .toInt();

/// The organization's whole AR control balance — the number an adjustment has
/// to move by exactly.
Future<double> arTotal() => d(
    "select coalesce(sum(jd.debit - jd.credit),0)::float8 "
    "from public.ws_tbljournalentrydetails jd "
    "join public.ws_tblaccounts a on a.accountid = jd.accountid "
    "where jd.orgid = $orgId and a.controlfor = 'ar'");

Future<int> recon() async =>
    (await scalar('select count(*)::int from public.vw_ws_reconciliation')).toInt();

Future<int> unbalanced() async => (await scalar(
        'select count(*)::int from public.vw_ws_unbalancedentries'))
    .toInt();

int _seq = 0;
Future<int> newCustomer({double opening = 0}) async {
  _seq++;
  return (await scalar("select public.ws_record_customer($orgId, "
          "'COB Customer $_seq ${DateTime.now().microsecondsSinceEpoch}', "
          "p_openingbalance => $opening, "
          "p_clientuuid => gen_random_uuid())"))
      .toInt();
}

// ═════════════════════════════════════════════════════════════════════════════

Future<void> main_() async {
  // COB-1 ───────────────────────────────────────────────────────────────────
  print('\n═══ COB-1  new customer, opening = 0 ═══');
  final v1 = await newCustomer(opening: 0);
  check('no opening journal entry', await entries(v1) == 0);
  check('posted opening is 0', await posted(v1) == 0);
  check('reconciliation = 0', await recon() == 0);

  // COB-2 ───────────────────────────────────────────────────────────────────
  print('\n═══ COB-2  opening = 1000 ═══');
  final arBefore = await arTotal();
  final v2 = await newCustomer(opening: 1000);
  check('exactly one customer opening journal', await entries(v2) == 1);
  check('the ledger carries 1000', await posted(v2) == 1000);
  check('the customer record agrees', await column_(v2) == 1000);
  check('AR moved by exactly +1000', await arTotal() - arBefore == 1000);
  check('reconciliation = 0', await recon() == 0);
  check('no unbalanced entries', await unbalanced() == 0);

  // COB-3 ───────────────────────────────────────────────────────────────────
  print('\n═══ COB-3  save 1000 again ═══');
  final arAt1000 = await arTotal();
  await db.execute('select public.ws_set_customer_opening($v2, 1000)');
  check('still exactly ONE journal entry', await entries(v2) == 1);
  check('receivable still 1000', await posted(v2) == 1000);
  check('AR did not move', await arTotal() == arAt1000);
  check('reconciliation = 0', await recon() == 0);

  // COB-4 ───────────────────────────────────────────────────────────────────
  print('\n═══ COB-4  1000 → 600 ═══');
  await db.execute('select public.ws_set_customer_opening($v2, 600)');
  check('AR adjusted by exactly -400', await arTotal() - arAt1000 == -400);
  check('receivable is 600', await posted(v2) == 600);
  check('the customer record agrees', await column_(v2) == 600);
  check('still one entry, restated not appended', await entries(v2) == 1);
  check('reconciliation = 0', await recon() == 0);

  // COB-5 ───────────────────────────────────────────────────────────────────
  print('\n═══ COB-5  600 → 0 ═══');
  final arAt600 = await arTotal();
  await db.execute('select public.ws_set_customer_opening($v2, 0)');
  check('AR reversed by exactly -600', await arTotal() - arAt600 == -600);
  check('nothing left posted', await posted(v2) == 0);
  check('THE ENTRY IS GONE, not left standing', await entries(v2) == 0,
      'the branch 009 already had, now reachable from every write path');
  check('the customer record agrees', await column_(v2) == 0);
  check('reconciliation = 0', await recon() == 0);

  // COB-6 ───────────────────────────────────────────────────────────────────
  print('\n═══ COB-6  retry after a lost response ═══');
  final v6 = await newCustomer(opening: 0);
  final arBefore6 = await arTotal();

  // The call commits; the client never hears back and calls again. Then a
  // third time from a brand new connection, as a restarted app would.
  await db.execute('select public.ws_set_customer_opening($v6, 750)');
  await db.execute('select public.ws_set_customer_opening($v6, 750)');
  final fresh = await connect();
  await fresh.execute("set ws.test_uid = '$owner'");
  await fresh.execute('select public.ws_set_customer_opening($v6, 750)');
  await fresh.close();

  check('exactly ONE adjustment, three calls later', await entries(v6) == 1);
  check('AR moved by 750 once, not 2250', await arTotal() - arBefore6 == 750);
  check('receivable is 750', await posted(v6) == 750);
  check('reconciliation = 0', await recon() == 0);

  // COB-7 ───────────────────────────────────────────────────────────────────
  //
  // Stronger than the vendor equivalent could be. Vendors are organization-wide
  // in 015, so VOB-7 could only check that the store dimension left the opening
  // alone. CUSTOMERS DO CARRY A storeid, so here there is a real interaction to
  // prove: changing an opening balance must not disturb the customer's branch,
  // and the store dimension must not split the opening entry, which is
  // organization-level like every other journal entry.
  print('\n═══ COB-7  multi-branch organization ═══');
  final storeB = (await scalar("select storeid from public.ws_tblstores "
          "where orgid = $orgId and not isdefault limit 1"))
      .toInt();

  final arBefore7 = await arTotal();
  final v7 = await newCustomer(opening: 400);
  final homeStore =
      (await scalar('select storeid from public.ws_tblcustomers '
              'where customerid = $v7'))
          .toInt();
  check('the customer was filed in a branch', homeStore > 0, 'store $homeStore');
  check('the opening posted once', await entries(v7) == 1);
  check('AR moved by exactly +400', await arTotal() - arBefore7 == 400);
  check('the opening entry carries no store dimension — it is org-level',
      await scalar("select count(*)::int from information_schema.columns "
              "where table_name = 'ws_tbljournalentries' "
              "and column_name = 'storeid'") ==
          0);

  // Changing the opening balance must not move the customer between branches.
  await db.execute('select public.ws_set_customer_opening($v7, 250)');
  check('the ledger followed the change', await posted(v7) == 250);
  check('the customer stayed in its branch',
      await scalar('select storeid from public.ws_tblcustomers '
              'where customerid = $v7') ==
          homeStore);

  // And a store-scoped document against that customer still lands where it was
  // posted, not where the customer happens to live.
  await db.execute("select public.ws_record_payment("
      "p_customerid => $v7, p_amount => 150, p_storeid => $storeB, "
      "p_clientuuid => gen_random_uuid())");
  check('a payment lands in the branch it was posted to',
      await scalar("select storeid from public.ws_tblpayments "
              "where customerid = $v7 order by paymentid desc limit 1") ==
          storeB);
  check("the customer's own branch is unchanged by that",
      await scalar('select storeid from public.ws_tblcustomers '
              'where customerid = $v7') ==
          homeStore);
  check('accounting remains balanced', await recon() == 0);
  check('no unbalanced entries', await unbalanced() == 0);

  // COB-8 ───────────────────────────────────────────────────────────────────
  // The backfill's whole job: fix the customers that disagree, touch the ones
  // that agree. Both damaged states are recreated here deliberately, then the
  // reconciliation loop from 016 is run again over the top.
  print('\n═══ COB-8  existing data, and re-running the backfill ═══');

  // Both customers are created FIRST, with the trigger live, so cStale really
  // does get a posted entry. Creating it while the trigger was disabled — as
  // an earlier version of this test did — left it with no entry at all, and
  // "column 0, entry 0" is a consistent state, not the damaged one.
  final cRaw = await newCustomer(opening: 0);
  final cStale = await newCustomer(opening: 500);
  check('cStale starts correctly posted', await posted(cStale) == 500);

  // Now reproduce the two pre-016 damage patterns behind the trigger's back.
  await db.execute('alter table public.ws_tblcustomers disable trigger '
      'trg_customer_opening_sync');
  // (a) damaged the OLD way: column written raw, no journal
  await db.execute('update public.ws_tblcustomers set openingbalance = 900 '
      'where customerid = $cRaw');
  // (b) damaged the other way: entry left standing, column cleared
  await db.execute('update public.ws_tblcustomers set openingbalance = 0 '
      'where customerid = $cStale');
  await db.execute('alter table public.ws_tblcustomers enable trigger '
      'trg_customer_opening_sync');

  check('the raw-write customer is out of step', await posted(cRaw) == 0);
  check('the stale-entry customer is out of step', await posted(cStale) == 500);
  check('reconciliation is broken, as it was before 017', await recon() > 0);

  // Run 016's reconciliation loop again.
  await db.execute('''
    do \$\$
    declare r record; v_posted numeric;
    begin
      for r in select customerid, orgid, coalesce(openingbalance,0) as opening
               from public.ws_tblcustomers
      loop
        v_posted := ws.customer_opening_posted(r.orgid, r.customerid);
        if v_posted is distinct from r.opening then
          perform ws.sync_customer_opening(r.orgid, r.customerid, r.opening,
                                         current_date);
        end if;
      end loop;
    end \$\$;''');

  check('the raw-write customer now has its entry', await posted(cRaw) == 900);
  check('and only one', await entries(cRaw) == 1);
  check('the stale entry was removed', await posted(cStale) == 0);
  check('leaving no entry behind', await entries(cStale) == 0);
  check('the already-correct customer was NOT double posted',
      await posted(v6) == 750, 'still 750, not 1500');
  check('reconciliation is back to 0', await recon() == 0);

  // And running it a third time changes nothing — the property that makes the
  // migration safe to re-run.
  final arAfterBackfill = await arTotal();
  await db.execute('''
    do \$\$
    declare r record; v_posted numeric;
    begin
      for r in select customerid, orgid, coalesce(openingbalance,0) as opening
               from public.ws_tblcustomers
      loop
        v_posted := ws.customer_opening_posted(r.orgid, r.customerid);
        if v_posted is distinct from r.opening then
          perform ws.sync_customer_opening(r.orgid, r.customerid, r.opening,
                                         current_date);
        end if;
      end loop;
    end \$\$;''');
  check('a second backfill pass moves nothing', await arTotal() == arAfterBackfill);
  check('reconciliation still 0', await recon() == 0);

  // ── the raw path can no longer break anything ───────────────────────────
  print('\n═══ the form\'s raw update is now safe too ═══');
  final vForm = await newCustomer(opening: 0);
  final arBeforeForm = await arTotal();
  await db.execute('update public.ws_tblcustomers set openingbalance = 320 '
      'where customerid = $vForm');
  check('a plain UPDATE posts the entry via the trigger',
      await posted(vForm) == 320);
  check('AR moved by exactly +320', await arTotal() - arBeforeForm == 320);
  check('reconciliation = 0 — the original defect is closed', await recon() == 0);

  await db.execute('update public.ws_tblcustomers set openingbalance = 0 '
      'where customerid = $vForm');
  check('and clearing it via a plain UPDATE reverses it',
      await posted(vForm) == 0 && await entries(vForm) == 0);
  check('reconciliation = 0', await recon() == 0);

  // ── customer payments and purchases are untouched ─────────────────────────
  print('\n═══ normal customer activity is unchanged ═══');
  final arBeforeOps = await arTotal();

  // A delivery bills the customer; its cash reduces the receivable. Neither
  // may touch the opening balance.
  final delivered = (await scalar("select public.ws_record_delivery("
          "p_customerid => $v6, p_delivered => 2, p_returned => 0, "
          "p_productid => 1, p_amountpaid => 0, "
          "p_clientuuid => gen_random_uuid())"))
      .toInt();
  check('a delivery still posts', delivered > 0);
  check('AR rose by the amount charged',
      await arTotal() - arBeforeOps ==
          await d("select coalesce(amountcharged,0)::float8 "
              "from public.ws_tbldeliveries where deliveryid = $delivered"));

  final arAfterDelivery = await arTotal();
  await db.execute("select public.ws_record_payment("
      "p_customerid => $v6, p_amount => 40, p_clientuuid => gen_random_uuid())");
  check('a customer payment still posts', await arTotal() - arAfterDelivery == -40);
  check("the customer's opening balance was not disturbed", await posted(v6) == 750);
  check('reconciliation = 0', await recon() == 0);
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

  await main_();

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
