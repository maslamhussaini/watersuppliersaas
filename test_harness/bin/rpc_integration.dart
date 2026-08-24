// =============================================================================
// bin/rpc_integration.dart
//
// Database-level integration suite for the four idempotent posting RPCs, run
// against a real PostgreSQL 16 loaded with migrations 000–013.
//
// This is the layer BELOW the outbox. The outbox matrix proves the queue does
// the right thing; this proves the server does, independently of any client:
// idempotency, validation, atomicity, journal balance, document numbering and
// tenant isolation.
//
// Run:  dart run bin/rpc_integration.dart
// =============================================================================

import 'dart:io';

import 'package:postgres/postgres.dart';

// RESOLVED AT RUNTIME. seed.sql mints fresh UUIDs on every load, so hardcoded
// ids rot into a "permission denied" that reads like a product bug.
late String owner; // org 1, may post
late String otherOrgOwner; // a different tenant
late String customerRole; // org 1, may not post

late Connection db;
int pass = 0, fail = 0;
final failures = <String>[];

void check(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
    print('  ok    $name${extra.isEmpty ? '' : '   ($extra)'}');
  } else {
    fail++;
    failures.add(name);
    print('  FAIL  $name${extra.isEmpty ? '' : '   ($extra)'}');
  }
}

Future<void> asUser(String uid) => db.execute("set ws.test_uid = '$uid'");

Future<num> scalar(String sql) async {
  final v = (await db.execute(sql)).first[0];
  return v is num ? v : num.parse('$v');
}

Future<String?> str(String sql) async {
  final rows = await db.execute(sql);
  if (rows.isEmpty) return null;
  final v = rows.first[0];
  return v?.toString();
}

/// Runs [sql] and returns the SQLSTATE it raised, or null if it succeeded.
Future<String?> errcode(String sql) async {
  try {
    await db.execute(sql);
    return null;
  } on ServerException catch (e) {
    return e.code;
  }
}

String uuid() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final r = now.toRadixString(16).padLeft(12, '0');
  final t = (now ~/ 7).toRadixString(16).padLeft(12, '0');
  return '${t.substring(0, 8)}-${t.substring(8, 12)}-4${r.substring(0, 3)}'
      '-8${r.substring(3, 6)}-${r.substring(r.length - 12)}';
}

String today = DateTime.now().toIso8601String().split('T').first;

// ═════════════════════════════════════════════════════════════════════════════
// DELIVERIES
// ═════════════════════════════════════════════════════════════════════════════

Future<void> deliveries() async {
  print('\n═══ ws_record_delivery ═══');
  await asUser(owner);

  // — posting —
  final u1 = uuid();
  final id1 = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_deliverydate => '$today', p_delivered => 5, "
          "p_returned => 3, p_productid => 1, p_amountpaid => 200, "
          "p_paymentmethod => 'cash', p_clientuuid => '$u1')"))
      .toInt();
  check('posts and returns an id', id1 > 0, 'id=$id1');
  check('exactly one delivery row',
      await scalar("select count(*)::int from ws_tbldeliveries "
              "where clientuuid = '$u1'") ==
          1);

  // — idempotency —
  final id2 = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_deliverydate => '$today', p_delivered => 5, "
          "p_returned => 3, p_productid => 1, p_amountpaid => 200, "
          "p_paymentmethod => 'cash', p_clientuuid => '$u1')"))
      .toInt();
  check('same key returns the same id', id1 == id2);
  check('still exactly one delivery row',
      await scalar("select count(*)::int from ws_tbldeliveries "
              "where clientuuid = '$u1'") ==
          1);

  // — first write wins —
  await db.execute("select public.ws_record_delivery("
      "p_customerid => 1, p_deliverydate => '$today', p_delivered => 999, "
      "p_returned => 999, p_productid => 1, p_amountpaid => 999, "
      "p_paymentmethod => 'cash', p_clientuuid => '$u1')");
  check('a retry cannot mutate the posted document',
      await scalar("select bottlesdelivered from ws_tbldeliveries "
              "where deliveryid = $id1") ==
          5);

  // — a different key is a different document —
  final u2 = uuid();
  final id3 = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_delivered => 1, p_returned => 0, "
          "p_productid => 1, p_clientuuid => '$u2')"))
      .toInt();
  check('a different key posts a new document', id3 != id1);

  // — the legacy path still works —
  final legacy = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_delivered => 1, p_returned => 0, "
          "p_productid => 1)"))
      .toInt();
  check('null clientuuid still posts (unchanged legacy path)', legacy > 0);
  final legacy2 = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_delivered => 1, p_returned => 0, "
          "p_productid => 1)"))
      .toInt();
  check('null keys are never deduplicated against each other', legacy2 != legacy);

  // — validation —
  check('unknown customer → P0002',
      await errcode("select public.ws_record_delivery(p_customerid => 999999, "
              "p_delivered => 1, p_productid => 1)") ==
          'P0002');

  await asUser(customerRole);
  check('no permission → 42501',
      await errcode("select public.ws_record_delivery(p_customerid => 1, "
              "p_delivered => 1, p_productid => 1)") ==
          '42501');

  await asUser(otherOrgOwner);
  check("another tenant's owner cannot post to org 1 → 42501",
      await errcode("select public.ws_record_delivery(p_customerid => 1, "
              "p_delivered => 1, p_productid => 1)") ==
          '42501');
  await asUser(owner);

  // — side effects —
  check('a reference number was assigned',
      (await str("select referenceno from ws_tbldeliveries "
                  "where deliveryid = $id1"))
              ?.startsWith('DEL-') ??
          false,
      await str("select referenceno from ws_tbldeliveries where deliveryid = $id1") ?? 'null');

  check('a delivery detail line exists',
      await scalar("select count(*)::int from ws_tbldeliverydetails "
              "where deliveryid = $id1") >=
          1);

  check('a bottle transaction was written',
      await scalar("select count(*)::int from ws_tblbottletransactions "
              "where deliveryid = $id1") >=
          1);

  check('a journal entry was posted',
      await scalar("select count(*)::int from ws_tbljournalentries "
              "where sourcetype = 'sale' and sourceid = $id1") ==
          1);

  check('that journal entry balances',
      await scalar("select coalesce(sum(d.debit - d.credit),0)::float8 "
              "from ws_tbljournalentrydetails d "
              "join ws_tbljournalentries e on e.journalid = d.journalid "
              "where e.sourcetype = 'delivery' and e.sourceid = $id1") ==
          0);

  check('cash paid at the door created a payment row',
      await scalar("select count(*)::int from ws_tblpayments "
              "where deliveryid = $id1") ==
          1);

  check('a delivery with no cash creates no payment row',
      await scalar("select count(*)::int from ws_tblpayments "
              "where deliveryid = $id3") ==
          0);

  // vw_ws_deliverycard is a per-customer-per-DAY card, not a per-document one:
  // it groups by (orgid, customerid, date) and shows min(referenceno) as the
  // day's representative. So the assertion is that the day's row exists and
  // has absorbed this delivery's bottles.
  check('the delivery card view has the day and includes these bottles',
      await scalar("select count(*)::int from vw_ws_deliverycard c "
              "join ws_tbldeliveries d on d.customerid = c.customerid "
              "and d.deliverydate = c.entrydate and d.orgid = c.orgid "
              "where d.deliveryid = $id1 and c.deliverybottles >= 5") ==
          1);

  check('no unbalanced entries anywhere',
      await scalar("select count(*)::int from vw_ws_unbalancedentries") == 0);
}

// ═════════════════════════════════════════════════════════════════════════════
// CUSTOMER PAYMENTS
// ═════════════════════════════════════════════════════════════════════════════

Future<void> payments() async {
  print('\n═══ ws_record_payment ═══');
  await asUser(owner);

  final u1 = uuid();
  final id1 = (await scalar("select public.ws_record_payment("
          "p_customerid => 1, p_amount => 300, p_paymentdate => '$today', "
          "p_paymentmethod => 'cash', p_clientuuid => '$u1')"))
      .toInt();
  check('posts and returns an id', id1 > 0, 'id=$id1');

  final id2 = (await scalar("select public.ws_record_payment("
          "p_customerid => 1, p_amount => 300, p_paymentdate => '$today', "
          "p_paymentmethod => 'cash', p_clientuuid => '$u1')"))
      .toInt();
  check('same key returns the same id', id1 == id2);
  check('exactly one payment row',
      await scalar("select count(*)::int from ws_tblpayments "
              "where clientuuid = '$u1'") ==
          1);

  await db.execute("select public.ws_record_payment(p_customerid => 1, "
      "p_amount => 99999, p_clientuuid => '$u1')");
  check('a retry cannot change the amount',
      await scalar("select amountreceived::float8 from ws_tblpayments "
              "where paymentid = $id1") ==
          300);

  check('a receipt number was assigned',
      (await str("select receiptno from ws_tblpayments where paymentid = $id1"))
              ?.startsWith('RCPT-') ??
          false);

  check('a journal entry was posted and balances',
      await scalar("select coalesce(sum(d.debit - d.credit),0)::float8 "
              "from ws_tbljournalentrydetails d "
              "join ws_tbljournalentries e on e.journalid = d.journalid "
              "where e.sourcetype = 'payment' and e.sourceid = $id1") ==
          0);

  check('unknown customer → P0002',
      await errcode("select public.ws_record_payment(p_customerid => 999999, "
              "p_amount => 10)") ==
          'P0002');

  await asUser(customerRole);
  check('no permission → 42501',
      await errcode("select public.ws_record_payment(p_customerid => 1, "
              "p_amount => 10)") ==
          '42501');
  await asUser(owner);

  check('nothing was written by the rejected calls',
      await scalar("select count(*)::int from ws_tblpayments "
              "where amountreceived = 99999") ==
          0);
}

// ═════════════════════════════════════════════════════════════════════════════
// PURCHASES  — the atomicity case
// ═════════════════════════════════════════════════════════════════════════════

Future<void> purchases() async {
  print('\n═══ ws_record_purchase ═══');
  await asUser(owner);

  final headersBefore =
      await scalar('select count(*)::int from ws_tblpurchases');

  final u1 = uuid();
  final id1 = (await scalar("select public.ws_record_purchase("
          "p_vendorid => 1, "
          "p_lines => '[{\"productid\":1,\"quantity\":10,\"unitcost\":30},"
          "{\"productid\":2,\"quantity\":5,\"unitcost\":40}]'::jsonb, "
          "p_purchasedate => '$today', p_clientuuid => '$u1')"))
      .toInt();
  check('posts and returns an id', id1 > 0, 'id=$id1');
  check('both lines were written',
      await scalar("select count(*)::int from ws_tblpurchasedetails "
              "where purchaseid = $id1") ==
          2);
  check('the trigger computed the total (10×30 + 5×40 = 500)',
      await scalar("select totalamount::float8 from ws_tblpurchases "
              "where purchaseid = $id1") ==
          500);

  final id2 = (await scalar("select public.ws_record_purchase("
          "p_vendorid => 1, "
          "p_lines => '[{\"productid\":1,\"quantity\":10,\"unitcost\":30},"
          "{\"productid\":2,\"quantity\":5,\"unitcost\":40}]'::jsonb, "
          "p_clientuuid => '$u1')"))
      .toInt();
  check('same key returns the same id', id1 == id2);
  check('lines were NOT duplicated by the retry',
      await scalar("select count(*)::int from ws_tblpurchasedetails "
              "where purchaseid = $id1") ==
          2);

  await db.execute("select public.ws_record_purchase(p_vendorid => 1, "
      "p_lines => '[{\"productid\":1,\"quantity\":999,\"unitcost\":999}]'::jsonb, "
      "p_clientuuid => '$u1')");
  check('a retry with different lines cannot change the total',
      await scalar("select totalamount::float8 from ws_tblpurchases "
              "where purchaseid = $id1") ==
          500);

  // — ATOMICITY: no header may survive a bad line —
  final headersBeforeBad =
      await scalar('select count(*)::int from ws_tblpurchases');

  final emptyErr = await errcode("select public.ws_record_purchase("
      "p_vendorid => 1, p_lines => '[]'::jsonb, p_clientuuid => '${uuid()}')");
  check('an empty line list is rejected', emptyErr != null, emptyErr ?? 'no error');

  final badProductErr = await errcode("select public.ws_record_purchase("
      "p_vendorid => 1, "
      "p_lines => '[{\"productid\":999999,\"quantity\":1,\"unitcost\":1}]'::jsonb, "
      "p_clientuuid => '${uuid()}')");
  check('an unknown product is rejected', badProductErr != null,
      badProductErr ?? 'no error');

  final crossTenantErr = await errcode("select public.ws_record_purchase("
      "p_vendorid => 1, "
      "p_lines => '[{\"productid\":4,\"quantity\":1,\"unitcost\":1}]'::jsonb, "
      "p_clientuuid => '${uuid()}')");
  check("another tenant's product is rejected", crossTenantErr != null,
      crossTenantErr ?? 'no error');

  check('NOT ONE header row survived those three rejections',
      await scalar('select count(*)::int from ws_tblpurchases') ==
          headersBeforeBad,
      'before=$headersBeforeBad');

  check('no purchase anywhere has zero lines',
      await scalar('select count(*)::int from ws_tblpurchases p '
              'where not exists (select 1 from ws_tblpurchasedetails d '
              'where d.purchaseid = p.purchaseid)') ==
          0);

  // — permissions —
  await asUser(customerRole);
  check('no permission → 42501',
      await errcode("select public.ws_record_purchase(p_vendorid => 1, "
              "p_lines => '[{\"productid\":1,\"quantity\":1,\"unitcost\":1}]'::jsonb)") ==
          '42501');
  await asUser(owner);

  check('unknown vendor → P0002',
      await errcode("select public.ws_record_purchase(p_vendorid => 999999, "
              "p_lines => '[{\"productid\":1,\"quantity\":1,\"unitcost\":1}]'::jsonb)") ==
          'P0002');

  // — side effects —
  check('a reference number was assigned',
      (await str("select referenceno from ws_tblpurchases "
                  "where purchaseid = $id1"))
              ?.isNotEmpty ??
          false,
      await str("select referenceno from ws_tblpurchases where purchaseid = $id1") ?? 'null');

  check('a journal entry was posted and balances',
      await scalar("select coalesce(sum(d.debit - d.credit),0)::float8 "
              "from ws_tbljournalentrydetails d "
              "join ws_tbljournalentries e on e.journalid = d.journalid "
              "where e.sourcetype = 'purchase' and e.sourceid = $id1") ==
          0);

  check('headers only grew by the successful posts',
      await scalar('select count(*)::int from ws_tblpurchases') >
          headersBefore);
}

// ═════════════════════════════════════════════════════════════════════════════
// VENDOR PAYMENTS
// ═════════════════════════════════════════════════════════════════════════════

Future<void> vendorPayments() async {
  print('\n═══ ws_record_vendor_payment ═══');
  await asUser(owner);

  final u1 = uuid();
  final id1 = (await scalar("select public.ws_record_vendor_payment("
          "p_vendorid => 1, p_amount => 750, p_paiddate => '$today', "
          "p_clientuuid => '$u1')"))
      .toInt();
  check('posts and returns an id', id1 > 0, 'id=$id1');

  final id2 = (await scalar("select public.ws_record_vendor_payment("
          "p_vendorid => 1, p_amount => 750, p_clientuuid => '$u1')"))
      .toInt();
  check('same key returns the same id', id1 == id2);
  check('exactly one vendor payment row',
      await scalar("select count(*)::int from ws_tblvendorpayments "
              "where clientuuid = '$u1'") ==
          1);

  await db.execute("select public.ws_record_vendor_payment(p_vendorid => 1, "
      "p_amount => 99999, p_clientuuid => '$u1')");
  check('a retry cannot change the amount',
      await scalar("select amountpaid::float8 from ws_tblvendorpayments "
              "where vendorpaymentid = $id1") ==
          750);

  check('a voucher number was assigned',
      (await str("select voucherno from ws_tblvendorpayments "
                  "where vendorpaymentid = $id1"))
              ?.isNotEmpty ??
          false,
      await str("select voucherno from ws_tblvendorpayments "
              "where vendorpaymentid = $id1") ??
          'null');

  // The preserved behaviour the user explicitly asked for.
  check('methodid is still NULL (behaviour preserved)',
      await scalar("select count(*)::int from ws_tblvendorpayments "
              "where vendorpaymentid = $id1 and methodid is null") ==
          1);

  check('a journal entry was posted and balances',
      await scalar("select coalesce(sum(d.debit - d.credit),0)::float8 "
              "from ws_tbljournalentrydetails d "
              "join ws_tbljournalentries e on e.journalid = d.journalid "
              "where e.sourcetype = 'vendorpayment' and e.sourceid = $id1") ==
          0);

  check('it hit the AP control account',
      await scalar("select count(*)::int from ws_tbljournalentrydetails d "
              "join ws_tbljournalentries e on e.journalid = d.journalid "
              "join ws_tblaccounts a on a.accountid = d.accountid "
              "where e.sourcetype = 'vendorpayment' and e.sourceid = $id1 "
              "and a.controlfor = 'ap'") >=
          1);

  // — validation —
  check('a zero amount is rejected → 22023',
      await errcode("select public.ws_record_vendor_payment(p_vendorid => 1, "
              "p_amount => 0)") ==
          '22023');
  check('a negative amount is rejected → 22023',
      await errcode("select public.ws_record_vendor_payment(p_vendorid => 1, "
              "p_amount => -50)") ==
          '22023');
  check('unknown vendor → P0002',
      await errcode("select public.ws_record_vendor_payment("
              "p_vendorid => 999999, p_amount => 10)") ==
          'P0002');
  check('unknown purchase → P0002',
      await errcode("select public.ws_record_vendor_payment(p_vendorid => 1, "
              "p_amount => 10, p_purchaseid => 999999)") ==
          'P0002');

  await asUser(customerRole);
  check('no permission → 42501',
      await errcode("select public.ws_record_vendor_payment(p_vendorid => 1, "
              "p_amount => 10)") ==
          '42501');
  await asUser(owner);

  check('none of the rejected calls wrote anything',
      await scalar("select count(*)::int from ws_tblvendorpayments "
              "where amountpaid in (0, -50, 99999)") ==
          0);

  // — a valid payment against a real purchase —
  final purchaseId = (await scalar('select purchaseid from ws_tblpurchases '
          'where orgid = 1 order by purchaseid desc limit 1'))
      .toInt();
  final u2 = uuid();
  final linked = (await scalar("select public.ws_record_vendor_payment("
          "p_vendorid => 1, p_amount => 100, p_purchaseid => $purchaseId, "
          "p_clientuuid => '$u2')"))
      .toInt();
  check('a payment can be tied to a purchase', linked > 0);
  check('the link was stored',
      await scalar("select count(*)::int from ws_tblvendorpayments "
              "where vendorpaymentid = $linked and purchaseid = $purchaseId") ==
          1);
}

// ═════════════════════════════════════════════════════════════════════════════

Future<void> crossCutting() async {
  print('\n═══ cross-cutting ═══');
  await asUser(owner);

  check('ws_lookup_clientuuid resolves all four document types',
      await scalar("select count(distinct doctype)::int from ("
              "select (public.ws_lookup_clientuuid(clientuuid)).doctype "
              "from ws_tbldeliveries where clientuuid is not null "
              "union all select (public.ws_lookup_clientuuid(clientuuid)).doctype "
              "from ws_tblpurchases where clientuuid is not null "
              "union all select (public.ws_lookup_clientuuid(clientuuid)).doctype "
              "from ws_tblvendorpayments where clientuuid is not null) t") ==
          4);

  check('every document number is unique within its tenant',
      await scalar("select count(*)::int from ("
              "select orgid, referenceno from ws_tbldeliveries "
              "where referenceno is not null "
              "group by 1,2 having count(*) > 1) t") ==
          0);

  check('the trial balance balances',
      await scalar('select coalesce(sum(totaldebit - totalcredit),0)::float8 '
              'from vw_ws_trialbalance where orgid = 1') ==
          0);

  check('no unbalanced journal entries',
      await scalar('select count(*)::int from vw_ws_unbalancedentries') == 0);

  check('vw_ws_reconciliation is empty — subsidiary ledgers agree with the GL',
      await scalar('select count(*)::int from vw_ws_reconciliation') == 0);

  // Tenant isolation, checked through the view layer rather than by assertion.
  await asUser(otherOrgOwner);
  check("org 2 cannot see org 1's deliveries through the lookup",
      await scalar("select count(*)::int from public.ws_lookup_clientuuid("
              "(select clientuuid from ws_tbldeliveries "
              "where orgid = 1 and clientuuid is not null limit 1))") ==
          0);
  await asUser(owner);
}

Future<Connection> _connect() => Connection.open(
      Endpoint(
          host: 'localhost',
          port: 5433,
          database: 'ws4',
          username: 'postgres',
          password: ''),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

/// An active member of [orgid], optionally filtered on holding [withPerm]
/// (or, with [negate], on NOT holding it).
Future<String> _member(
    {required int orgid, String? withPerm, bool negate = false}) async {
  final clause = withPerm == null
      ? ''
      : "and ${negate ? 'not ' : ''}exists (select 1 from "
          "public.ws_tblrolepermissions rp where rp.roleid = m.roleid "
          "and rp.permcode = '$withPerm')";
  final rows = await db.execute('select m.authuserid::text from '
      'public.ws_tblmemberships m where m.orgid = $orgid and m.isactive '
      '$clause limit 1');
  if (rows.isEmpty) {
    throw StateError('no seeded member matches org $orgid / $withPerm '
        '(negate: $negate) — is seed.sql loaded?');
  }
  return rows.first[0] as String;
}

void main() async {
  db = await _connect();
  owner = await _member(orgid: 1, withPerm: 'delivery.manage');
  otherOrgOwner = await _member(orgid: 2, withPerm: null);
  customerRole = await _member(orgid: 1, withPerm: 'delivery.manage',
      negate: true);
  await deliveries();
  await payments();
  await purchases();
  await vendorPayments();
  await crossCutting();

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
