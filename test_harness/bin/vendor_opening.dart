// =============================================================================
// bin/vendor_opening.dart
//
// Migration 016 — VOB-1 .. VOB-8, executed against a real PostgreSQL 16.
//
// The figure being checked everywhere is the AP MOVEMENT, read from the
// general ledger, not from ws_tblvendors.openingbalance. The column is the
// thing that was lying; asserting against it would prove nothing.
//
// Run:  dart run bin/vendor_opening.dart
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
          database: 'ws_vob',
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

/// What the general ledger says this vendor's opening payable is.
Future<double> posted(int vendorId) =>
    d('select ws.vendor_opening_posted($orgId, $vendorId)::float8');

/// What the vendor record displays.
Future<double> column_(int vendorId) => d(
    'select coalesce(openingbalance,0)::float8 from public.ws_tblvendors '
    'where vendorid = $vendorId');

/// How many opening journal entries exist for this vendor.
Future<int> entries(int vendorId) async => (await scalar(
        "select count(*)::int from public.ws_tbljournalentries "
        "where orgid = $orgId and sourcetype = 'opening' and sourceid = -$vendorId"))
    .toInt();

/// The organization's whole AP control balance — the number an adjustment has
/// to move by exactly.
Future<double> apTotal() => d(
    "select coalesce(sum(jd.credit - jd.debit),0)::float8 "
    "from public.ws_tbljournalentrydetails jd "
    "join public.ws_tblaccounts a on a.accountid = jd.accountid "
    "where jd.orgid = $orgId and a.controlfor = 'ap'");

Future<int> recon() async =>
    (await scalar('select count(*)::int from public.vw_ws_reconciliation')).toInt();

Future<int> unbalanced() async => (await scalar(
        'select count(*)::int from public.vw_ws_unbalancedentries'))
    .toInt();

int _seq = 0;
Future<int> newVendor({double opening = 0}) async {
  _seq++;
  return (await scalar("select public.ws_record_vendor($orgId, "
          "'VOB Vendor $_seq ${DateTime.now().microsecondsSinceEpoch}', "
          "p_openingbalance => $opening, "
          "p_clientuuid => gen_random_uuid())"))
      .toInt();
}

// ═════════════════════════════════════════════════════════════════════════════

Future<void> main_() async {
  // VOB-1 ───────────────────────────────────────────────────────────────────
  print('\n═══ VOB-1  new vendor, opening = 0 ═══');
  final v1 = await newVendor(opening: 0);
  check('no opening journal entry', await entries(v1) == 0);
  check('posted opening is 0', await posted(v1) == 0);
  check('reconciliation = 0', await recon() == 0);

  // VOB-2 ───────────────────────────────────────────────────────────────────
  print('\n═══ VOB-2  opening = 1000 ═══');
  final apBefore = await apTotal();
  final v2 = await newVendor(opening: 1000);
  check('exactly one vendor opening journal', await entries(v2) == 1);
  check('the ledger carries 1000', await posted(v2) == 1000);
  check('the vendor record agrees', await column_(v2) == 1000);
  check('AP moved by exactly +1000', await apTotal() - apBefore == 1000);
  check('reconciliation = 0', await recon() == 0);
  check('no unbalanced entries', await unbalanced() == 0);

  // VOB-3 ───────────────────────────────────────────────────────────────────
  print('\n═══ VOB-3  save 1000 again ═══');
  final apAt1000 = await apTotal();
  await db.execute('select public.ws_set_vendor_opening($v2, 1000)');
  check('still exactly ONE journal entry', await entries(v2) == 1);
  check('payable still 1000', await posted(v2) == 1000);
  check('AP did not move', await apTotal() == apAt1000);
  check('reconciliation = 0', await recon() == 0);

  // VOB-4 ───────────────────────────────────────────────────────────────────
  print('\n═══ VOB-4  1000 → 600 ═══');
  await db.execute('select public.ws_set_vendor_opening($v2, 600)');
  check('AP adjusted by exactly -400', await apTotal() - apAt1000 == -400);
  check('payable is 600', await posted(v2) == 600);
  check('the vendor record agrees', await column_(v2) == 600);
  check('still one entry, restated not appended', await entries(v2) == 1);
  check('reconciliation = 0', await recon() == 0);

  // VOB-5 ───────────────────────────────────────────────────────────────────
  print('\n═══ VOB-5  600 → 0 ═══');
  final apAt600 = await apTotal();
  await db.execute('select public.ws_set_vendor_opening($v2, 0)');
  check('AP reversed by exactly -600', await apTotal() - apAt600 == -600);
  check('nothing left posted', await posted(v2) == 0);
  check('THE ENTRY IS GONE, not left standing', await entries(v2) == 0,
      'this is the bug 016 exists to fix');
  check('the vendor record agrees', await column_(v2) == 0);
  check('reconciliation = 0', await recon() == 0);

  // VOB-6 ───────────────────────────────────────────────────────────────────
  print('\n═══ VOB-6  retry after a lost response ═══');
  final v6 = await newVendor(opening: 0);
  final apBefore6 = await apTotal();

  // The call commits; the client never hears back and calls again. Then a
  // third time from a brand new connection, as a restarted app would.
  await db.execute('select public.ws_set_vendor_opening($v6, 750)');
  await db.execute('select public.ws_set_vendor_opening($v6, 750)');
  final fresh = await connect();
  await fresh.execute("set ws.test_uid = '$owner'");
  await fresh.execute('select public.ws_set_vendor_opening($v6, 750)');
  await fresh.close();

  check('exactly ONE adjustment, three calls later', await entries(v6) == 1);
  check('AP moved by 750 once, not 2250', await apTotal() - apBefore6 == 750);
  check('payable is 750', await posted(v6) == 750);
  check('reconciliation = 0', await recon() == 0);

  // VOB-7 ───────────────────────────────────────────────────────────────────
  //
  // AS SPECIFIED THIS ASKED FOR SOMETHING THE SCHEMA DOES NOT HAVE.
  //
  // "vendor remains associated with the correct store" presumes vendors carry
  // a storeid. They do not: migration 015 deliberately left vendors, products
  // and areas organization-wide — a business with two depots buys from one set
  // of suppliers — and put storeid only on customers and on documents. Only
  // ws_tblvendorpayments is store-scoped on the vendor side.
  //
  // So the property actually worth proving in a multi-branch organization is:
  // the opening balance is an organization-level fact that the store dimension
  // neither splits nor disturbs, while the store-scoped documents against that
  // same vendor still land in the branch they were posted to.
  print('\n═══ VOB-7  multi-branch organization ═══');
  final storeB = (await scalar("select storeid from public.ws_tblstores "
          "where orgid = $orgId and not isdefault limit 1"))
      .toInt();
  final storeDefault = (await scalar("select storeid from public.ws_tblstores "
          "where orgid = $orgId and isdefault"))
      .toInt();

  final apBefore7 = await apTotal();
  final v7 = await newVendor(opening: 400);
  check('the opening posted once', await entries(v7) == 1);
  check('AP moved by exactly +400', await apTotal() - apBefore7 == 400);
  check('the opening entry carries no store dimension — it is org-level',
      await scalar("select count(*)::int from information_schema.columns "
              "where table_name = 'ws_tbljournalentries' "
              "and column_name = 'storeid'") ==
          0);

  // A store-scoped document against the same vendor.
  await db.execute("select public.ws_record_vendor_payment("
      "p_vendorid => $v7, p_amount => 150, p_storeid => $storeB, "
      "p_clientuuid => gen_random_uuid())");
  check('a vendor payment still lands in the branch it was posted to',
      await scalar("select storeid from public.ws_tblvendorpayments "
              "where vendorid = $v7 order by vendorpaymentid desc limit 1") ==
          storeB,
      'not the default store $storeDefault');

  await db.execute('select public.ws_set_vendor_opening($v7, 250)');
  check('the ledger followed the change', await posted(v7) == 250);
  check('the branch payment was untouched by it',
      await scalar("select count(*)::int from public.ws_tblvendorpayments "
              "where vendorid = $v7 and storeid = $storeB") ==
          1);
  check('accounting remains balanced', await recon() == 0);
  check('no unbalanced entries', await unbalanced() == 0);

  // VOB-8 ───────────────────────────────────────────────────────────────────
  // The backfill's whole job: fix the vendors that disagree, touch the ones
  // that agree. Both damaged states are recreated here deliberately, then the
  // reconciliation loop from 016 is run again over the top.
  print('\n═══ VOB-8  existing data, and re-running the backfill ═══');

  // Both vendors are created FIRST, with the trigger live, so vStale really
  // does get a posted entry. Creating it while the trigger was disabled — as
  // an earlier version of this test did — left it with no entry at all, and
  // "column 0, entry 0" is a consistent state, not the damaged one.
  final vRaw = await newVendor(opening: 0);
  final vStale = await newVendor(opening: 500);
  check('vStale starts correctly posted', await posted(vStale) == 500);

  // Now reproduce the two pre-016 damage patterns behind the trigger's back.
  await db.execute('alter table public.ws_tblvendors disable trigger '
      'trg_vendor_opening_sync');
  // (a) damaged the OLD way: column written raw, no journal
  await db.execute('update public.ws_tblvendors set openingbalance = 900 '
      'where vendorid = $vRaw');
  // (b) damaged the other way: entry left standing, column cleared
  await db.execute('update public.ws_tblvendors set openingbalance = 0 '
      'where vendorid = $vStale');
  await db.execute('alter table public.ws_tblvendors enable trigger '
      'trg_vendor_opening_sync');

  check('the raw-write vendor is out of step', await posted(vRaw) == 0);
  check('the stale-entry vendor is out of step', await posted(vStale) == 500);
  check('reconciliation is broken, as it was before 016', await recon() > 0);

  // Run 016's reconciliation loop again.
  await db.execute('''
    do \$\$
    declare r record; v_posted numeric;
    begin
      for r in select vendorid, orgid, coalesce(openingbalance,0) as opening
               from public.ws_tblvendors
      loop
        v_posted := ws.vendor_opening_posted(r.orgid, r.vendorid);
        if v_posted is distinct from r.opening then
          perform ws.sync_vendor_opening(r.orgid, r.vendorid, r.opening,
                                         current_date);
        end if;
      end loop;
    end \$\$;''');

  check('the raw-write vendor now has its entry', await posted(vRaw) == 900);
  check('and only one', await entries(vRaw) == 1);
  check('the stale entry was removed', await posted(vStale) == 0);
  check('leaving no entry behind', await entries(vStale) == 0);
  check('the already-correct vendor was NOT double posted',
      await posted(v6) == 750, 'still 750, not 1500');
  check('reconciliation is back to 0', await recon() == 0);

  // And running it a third time changes nothing — the property that makes the
  // migration safe to re-run.
  final apAfterBackfill = await apTotal();
  await db.execute('''
    do \$\$
    declare r record; v_posted numeric;
    begin
      for r in select vendorid, orgid, coalesce(openingbalance,0) as opening
               from public.ws_tblvendors
      loop
        v_posted := ws.vendor_opening_posted(r.orgid, r.vendorid);
        if v_posted is distinct from r.opening then
          perform ws.sync_vendor_opening(r.orgid, r.vendorid, r.opening,
                                         current_date);
        end if;
      end loop;
    end \$\$;''');
  check('a second backfill pass moves nothing', await apTotal() == apAfterBackfill);
  check('reconciliation still 0', await recon() == 0);

  // ── the raw path can no longer break anything ───────────────────────────
  print('\n═══ the form\'s raw update is now safe too ═══');
  final vForm = await newVendor(opening: 0);
  final apBeforeForm = await apTotal();
  await db.execute('update public.ws_tblvendors set openingbalance = 320 '
      'where vendorid = $vForm');
  check('a plain UPDATE posts the entry via the trigger',
      await posted(vForm) == 320);
  check('AP moved by exactly +320', await apTotal() - apBeforeForm == 320);
  check('reconciliation = 0 — the original defect is closed', await recon() == 0);

  await db.execute('update public.ws_tblvendors set openingbalance = 0 '
      'where vendorid = $vForm');
  check('and clearing it via a plain UPDATE reverses it',
      await posted(vForm) == 0 && await entries(vForm) == 0);
  check('reconciliation = 0', await recon() == 0);

  // ── vendor payments and purchases are untouched ─────────────────────────
  print('\n═══ normal vendor activity is unchanged ═══');
  final apBeforeOps = await apTotal();
  final pu = (await scalar("select public.ws_record_purchase(p_vendorid => $v6, "
          "p_lines => '[{\"productid\":1,\"quantity\":2,\"unitcost\":50}]'::jsonb, "
          "p_clientuuid => gen_random_uuid())"))
      .toInt();
  check('a purchase still posts', pu > 0);
  check('AP rose by the purchase total', await apTotal() - apBeforeOps == 100);
  final apAfterPurchase = await apTotal();
  await db.execute("select public.ws_record_vendor_payment("
      "p_vendorid => $v6, p_amount => 40, p_clientuuid => gen_random_uuid())");
  check('a vendor payment still posts', await apTotal() - apAfterPurchase == -40);
  check("the vendor's opening balance was not disturbed", await posted(v6) == 750);
  check('reconciliation = 0', await recon() == 0);
  check('no unbalanced entries', await unbalanced() == 0);
}

void main() async {
  db = await connect();
  owner = (await db.execute("select m.authuserid::text from "
          "public.ws_tblmemberships m "
          "join public.ws_tblrolepermissions rp on rp.roleid = m.roleid "
          "where m.orgid = $orgId and rp.permcode = 'vendors.manage' limit 1"))
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
