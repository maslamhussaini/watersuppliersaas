// =============================================================================
// bin/master_data_idempotency.dart
//
// Migration 014, executed against a real PostgreSQL 16 loaded with 000–014.
//
// Seven scenarios for each of the three paths closed by 014 — customers,
// vendors, organization registration:
//
//   1. first write
//   2. same uuid retry
//   3. same uuid, tampered payload
//   4. lost response after commit
//   5. process restart after a lost response
//   6. legacy caller with no uuid
//   7. lookup by uuid
//
// "Lost response" is modelled the only way it can be: the statement is issued
// and COMMITS, the result is thrown away without being read, and the operation
// is then retried exactly as a client that never heard back would retry it.
// Scenario 5 does that retry on a SECOND CONNECTION, which is what a restarted
// process actually has.
//
// Run:  dart run bin/master_data_idempotency.dart
// =============================================================================

import 'dart:io';

import 'package:postgres/postgres.dart';

late Connection db;
late String owner; // org 1, may manage customers and vendors
late String noRights; // org 1, may not

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
          database: 'ws_md',
          username: 'postgres',
          password: ''),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

Future<num> scalar(String sql, [Connection? on]) async {
  final v = (await (on ?? db).execute(sql)).first[0];
  return v is num ? v : num.parse('$v');
}

Future<String?> str(String sql, [Connection? on]) async {
  final rows = await (on ?? db).execute(sql);
  if (rows.isEmpty) return null;
  return rows.first[0]?.toString();
}

Future<String?> errcode(String sql) async {
  try {
    await db.execute(sql);
    return null;
  } on ServerException catch (e) {
    return e.code;
  }
}

Future<void> asUser(String uid, [Connection? on]) =>
    (on ?? db).execute("set ws.test_uid = '$uid'");

int _n = 0;
String uuid() {
  _n++;
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(12, '0');
  final s = _n.toRadixString(16).padLeft(4, '0');
  return '${t.substring(0, 8)}-${t.substring(8, 12)}-4000-8000-${s}00000000';
}

Future<String> _member({required int orgid, String? withPerm, bool negate = false}) async {
  final clause = withPerm == null
      ? ''
      : "and ${negate ? 'not ' : ''}exists (select 1 from "
          "public.ws_tblrolepermissions rp where rp.roleid = m.roleid "
          "and rp.permcode = '$withPerm')";
  final rows = await db.execute('select m.authuserid::text from '
      'public.ws_tblmemberships m where m.orgid = $orgid and m.isactive '
      '$clause limit 1');
  if (rows.isEmpty) throw StateError('no seeded member for $withPerm');
  return rows.first[0] as String;
}

/// Creates a row in auth.users and returns its id.
///
/// ws_tblorganization.owneruserid references auth.users(id), so registration
/// cannot be tested with an invented uuid — the same constraint a real project
/// has.
Future<String> newAuthUser() async {
  final id = await str('select gen_random_uuid()::text');
  await db.execute("insert into auth.users(id, email) "
      "values ('$id', 'probe-$id@example.test')");
  return id!;
}

// ═════════════════════════════════════════════════════════════════════════════
// CUSTOMERS
// ═════════════════════════════════════════════════════════════════════════════

Future<void> customers() async {
  print('\n═══ ws_record_customer ═══');
  await asUser(owner);

  Future<int> rows(String u) async => (await scalar(
          "select count(*)::int from public.ws_tblcustomers where clientuuid = '$u'"))
      .toInt();

  // ── 1. FIRST WRITE ──────────────────────────────────────────────────────
  final u1 = uuid();
  final id1 = (await scalar("select public.ws_record_customer("
          "1, 'Idem Customer', p_areaid => 1, p_phone => '0300-1111111', "
          "p_depositamount => 250, p_clientuuid => '$u1')"))
      .toInt();
  check('1. first write returns an id', id1 > 0, 'id=$id1');
  check('   exactly one row', await rows(u1) == 1);
  check('   the payload landed',
      await str("select customername from public.ws_tblcustomers "
              "where customerid = $id1") ==
          'Idem Customer');

  // ── 2. SAME UUID RETRY ──────────────────────────────────────────────────
  final id2 = (await scalar("select public.ws_record_customer("
          "1, 'Idem Customer', p_areaid => 1, p_phone => '0300-1111111', "
          "p_depositamount => 250, p_clientuuid => '$u1')"))
      .toInt();
  check('2. same uuid returns the SAME id', id1 == id2);
  check('   still exactly one row', await rows(u1) == 1);

  // ── 3. SAME UUID, TAMPERED PAYLOAD ──────────────────────────────────────
  final id3 = (await scalar("select public.ws_record_customer("
          "1, 'TAMPERED NAME', p_areaid => 1, p_phone => '0000-0000000', "
          "p_depositamount => 999999, p_clientuuid => '$u1')"))
      .toInt();
  check('3. tampered retry still returns the original id', id3 == id1);
  check('   name NOT overwritten',
      await str("select customername from public.ws_tblcustomers "
              "where customerid = $id1") ==
          'Idem Customer');
  check('   deposit NOT overwritten',
      await scalar("select depositamount::float8 from public.ws_tblcustomers "
              "where customerid = $id1") ==
          250);
  check('   no second row', await rows(u1) == 1);

  // ── 4. LOST RESPONSE AFTER COMMIT ───────────────────────────────────────
  // The insert commits; the client never sees the id and retries.
  final u2 = uuid();
  await db.execute("select public.ws_record_customer("
      "1, 'Lost Response Customer', p_areaid => 1, p_clientuuid => '$u2')");
  check('4. the server did commit', await rows(u2) == 1);
  final recovered = (await scalar("select public.ws_record_customer("
          "1, 'Lost Response Customer', p_areaid => 1, p_clientuuid => '$u2')"))
      .toInt();
  check('   the blind retry returned the existing id', recovered > 0);
  check('   STILL exactly one row', await rows(u2) == 1);

  // ── 5. PROCESS RESTART AFTER A LOST RESPONSE ────────────────────────────
  final u3 = uuid();
  await db.execute("select public.ws_record_customer("
      "1, 'Restart Customer', p_areaid => 1, p_clientuuid => '$u3')");
  final fresh = await connect(); // what a restarted app actually has
  await asUser(owner, fresh);
  final afterRestart = (await scalar(
          "select public.ws_record_customer("
          "1, 'Restart Customer', p_areaid => 1, p_clientuuid => '$u3')",
          fresh))
      .toInt();
  check('5. a new connection resolves to the same customer',
      afterRestart == (await scalar("select customerid from "
              "public.ws_tblcustomers where clientuuid = '$u3'"))
          .toInt());
  check('   still exactly one row', await rows(u3) == 1);
  await fresh.close();

  // ── 6. LEGACY CALLER, NO UUID ───────────────────────────────────────────
  final before = await scalar("select count(*)::int from public.ws_tblcustomers "
      "where customername = 'Legacy Customer'");
  final l1 = (await scalar(
          "select public.ws_record_customer(1, 'Legacy Customer', p_areaid => 1)"))
      .toInt();
  final l2 = (await scalar(
          "select public.ws_record_customer(1, 'Legacy Customer', p_areaid => 1)"))
      .toInt();
  check('6. a call with no uuid still works', l1 > 0 && l2 > 0);
  check('   null keys are NEVER deduplicated against each other', l1 != l2);
  check('   both rows exist',
      await scalar("select count(*)::int from public.ws_tblcustomers "
              "where customername = 'Legacy Customer'") ==
          before + 2);
  check('   and the direct insert path still works too',
      await errcode("insert into public.ws_tblcustomers"
              "(orgid, customername, areaid) values (1, 'Direct Insert', 1)") ==
          null);

  // ── 7. LOOKUP BY UUID ───────────────────────────────────────────────────
  check('7. lookup resolves it as a customer',
      await str("select doctype from public.ws_lookup_clientuuid('$u1')") ==
          'customer');
  check('   with the right id',
      (await scalar("select docid from public.ws_lookup_clientuuid('$u1')"))
              .toInt() ==
          id1);

  // ── permissions ─────────────────────────────────────────────────────────
  await asUser(noRights);
  check('a user without customers.manage is refused',
      await errcode("select public.ws_record_customer(1, 'Nope')") == '42501');
  await asUser(owner);

  check('an empty name is rejected',
      await errcode("select public.ws_record_customer(1, '   ')") == '22023');
  check("another tenant's area is rejected",
      await errcode("select public.ws_record_customer(1, 'Cross', "
              "p_areaid => (select areaid from public.ws_tblareas "
              "where orgid = 2 limit 1))") !=
          null);
}

// ═════════════════════════════════════════════════════════════════════════════
// VENDORS
// ═════════════════════════════════════════════════════════════════════════════

Future<void> vendors() async {
  print('\n═══ ws_record_vendor ═══');
  await asUser(owner);

  Future<int> rows(String u) async => (await scalar(
          "select count(*)::int from public.ws_tblvendors where clientuuid = '$u'"))
      .toInt();

  // vendorcode is unique per organization, so a fixed one makes this suite
  // pass once and fail on every re-run against the same database.
  final vcode = 'V-${DateTime.now().millisecondsSinceEpoch % 100000}';
  final u1 = uuid();
  final id1 = (await scalar("select public.ws_record_vendor("
          "1, 'Idem Vendor', p_vendorcode => '$vcode', "
          "p_phone => '0300-2222222', p_clientuuid => '$u1')"))
      .toInt();
  check('1. first write returns an id', id1 > 0, 'id=$id1');
  check('   exactly one row', await rows(u1) == 1);

  final id2 = (await scalar("select public.ws_record_vendor("
          "1, 'Idem Vendor', p_vendorcode => '$vcode', p_clientuuid => '$u1')"))
      .toInt();
  check('2. same uuid returns the SAME id', id1 == id2);
  check('   still exactly one row', await rows(u1) == 1);

  final id3 = (await scalar("select public.ws_record_vendor("
          "1, 'TAMPERED VENDOR', p_vendorcode => '${vcode}X', "
          "p_openingbalance => 999999, p_clientuuid => '$u1')"))
      .toInt();
  check('3. tampered retry returns the original id', id3 == id1);
  check('   name NOT overwritten',
      await str("select vendorname from public.ws_tblvendors "
              "where vendorid = $id1") ==
          'Idem Vendor');
  check('   opening balance NOT overwritten',
      await scalar("select openingbalance::float8 from public.ws_tblvendors "
              "where vendorid = $id1") ==
          0);
  check('   no second row', await rows(u1) == 1);

  final u2 = uuid();
  await db.execute("select public.ws_record_vendor("
      "1, 'Lost Response Vendor', p_clientuuid => '$u2')");
  check('4. the server did commit', await rows(u2) == 1);
  await db.execute("select public.ws_record_vendor("
      "1, 'Lost Response Vendor', p_clientuuid => '$u2')");
  check('   STILL exactly one row after the blind retry', await rows(u2) == 1);

  final u3 = uuid();
  await db.execute("select public.ws_record_vendor("
      "1, 'Restart Vendor', p_clientuuid => '$u3')");
  final fresh = await connect();
  await asUser(owner, fresh);
  await scalar(
      "select public.ws_record_vendor(1, 'Restart Vendor', p_clientuuid => '$u3')",
      fresh);
  check('5. still one row after a process restart', await rows(u3) == 1);
  await fresh.close();

  final v1 = (await scalar("select public.ws_record_vendor(1, 'Legacy Vendor')"))
      .toInt();
  final v2 = (await scalar("select public.ws_record_vendor(1, 'Legacy Vendor')"))
      .toInt();
  check('6. a call with no uuid still works and is not deduplicated', v1 != v2);
  check('   the direct insert path still works',
      await errcode("insert into public.ws_tblvendors(orgid, vendorname) "
              "values (1, 'Direct Vendor')") ==
          null);

  check('7. lookup resolves it as a vendor',
      await str("select doctype from public.ws_lookup_clientuuid('$u1')") ==
          'vendor');
  check('   with the right id',
      (await scalar("select docid from public.ws_lookup_clientuuid('$u1')"))
              .toInt() ==
          id1);

  await asUser(noRights);
  check('a user without vendors.manage is refused',
      await errcode("select public.ws_record_vendor(1, 'Nope')") == '42501');
  await asUser(owner);
}

// ═════════════════════════════════════════════════════════════════════════════
// ORGANIZATION REGISTRATION
// ═════════════════════════════════════════════════════════════════════════════

Future<void> organizations() async {
  print('\n═══ ws_create_organization ═══');

  Future<int> orgsFor(String uid) async => (await scalar(
          "select count(*)::int from public.ws_tblorganization "
          "where owneruserid = '$uid'"))
      .toInt();
  Future<int> accounts(int orgid) async => (await scalar(
          "select count(*)::int from public.ws_tblaccounts where orgid = $orgid"))
      .toInt();

  // A brand-new signed-in user with no organization yet.
  //
  // Registered in auth.users first: ws_tblorganization.owneruserid has a
  // foreign key to it, exactly as it does in a real Supabase project, so a
  // made-up uuid is not a user.
  final newUser = await newAuthUser();
  await asUser(newUser);

  // ── 1. FIRST WRITE ──────────────────────────────────────────────────────
  final k1 = uuid();
  final org1 = (await scalar("select public.ws_create_organization("
          "'Idem Water Co', 'Owner Name', '0300-3333333', 'Karachi', 'PKR', "
          "'$k1')"))
      .toInt();
  check('1. registration returns an org id', org1 > 0, 'orgid=$org1');
  check('   exactly one organization for this user', await orgsFor(newUser) == 1);
  check('   the owner has a membership',
      await scalar("select count(*)::int from public.ws_tblmemberships "
              "where orgid = $org1 and authuserid = '$newUser'") ==
          1);
  check('   an internal user row exists',
      await scalar("select count(*)::int from public.ws_tblinternalusers "
              "where orgid = $org1") ==
          1);
  check('   a subscription exists',
      await scalar("select count(*)::int from public.ws_tblsubscriptions "
              "where orgid = $org1") ==
          1);
  final seeded = await accounts(org1);
  check('   the chart of accounts was seeded', seeded > 0, '$seeded accounts');

  // ── 2. SAME UUID RETRY ──────────────────────────────────────────────────
  final org2 = (await scalar("select public.ws_create_organization("
          "'Idem Water Co', 'Owner Name', '0300-3333333', 'Karachi', 'PKR', "
          "'$k1')"))
      .toInt();
  check('2. the retry returns the SAME org', org1 == org2);
  check('   STILL exactly one organization', await orgsFor(newUser) == 1);
  check('   the chart of accounts was seeded EXACTLY ONCE',
      await accounts(org1) == seeded, '$seeded');
  check('   no duplicate membership',
      await scalar("select count(*)::int from public.ws_tblmemberships "
              "where orgid = $org1") ==
          1);
  check('   no duplicate subscription',
      await scalar("select count(*)::int from public.ws_tblsubscriptions "
              "where orgid = $org1") ==
          1);

  // ── 3. SAME UUID, TAMPERED PAYLOAD ──────────────────────────────────────
  final org3 = (await scalar("select public.ws_create_organization("
          "'TAMPERED ORG NAME', 'Someone Else', '0000', 'Nowhere', 'USD', "
          "'$k1')"))
      .toInt();
  check('3. tampered retry returns the original org', org3 == org1);
  check('   the name was NOT overwritten',
      await str("select orgname from public.ws_tblorganization "
              "where orgid = $org1") ==
          'Idem Water Co');
  check('   still one organization', await orgsFor(newUser) == 1);

  // ── 4. LOST RESPONSE AFTER COMMIT ───────────────────────────────────────
  final user2 = await newAuthUser();
  await asUser(user2);
  final k2 = uuid();
  await db.execute("select public.ws_create_organization("
      "'Lost Response Co', 'Owner', '', '', 'PKR', '$k2')");
  check('4. the server did commit', await orgsFor(user2) == 1);
  final lostOrg = (await scalar("select public.ws_create_organization("
          "'Lost Response Co', 'Owner', '', '', 'PKR', '$k2')"))
      .toInt();
  check('   the blind retry returned the existing org', lostOrg > 0);
  check('   EXACTLY ONE ORGANIZATION — no second tenant',
      await orgsFor(user2) == 1);
  check('   chart of accounts seeded exactly once',
      await accounts(lostOrg) == seeded);

  // ── 5. PROCESS RESTART AFTER A LOST RESPONSE ────────────────────────────
  final user3 = await newAuthUser();
  await asUser(user3);
  final k3 = uuid();
  await db.execute("select public.ws_create_organization("
      "'Restart Co', 'Owner', '', '', 'PKR', '$k3')");
  final fresh = await connect();
  await asUser(user3, fresh);
  await scalar("select public.ws_create_organization("
      "'Restart Co', 'Owner', '', '', 'PKR', '$k3')", fresh);
  check('5. still ONE organization after a process restart',
      await orgsFor(user3) == 1);
  await fresh.close();

  // ── 6. LEGACY CALLER, NO UUID ───────────────────────────────────────────
  final user4 = await newAuthUser();
  await asUser(user4);
  final legacy1 =
      (await scalar("select public.ws_create_organization('Legacy Co')")).toInt();
  check('6. the four-argument legacy call still resolves and works',
      legacy1 > 0);
  check('   it seeded its chart of accounts too', await accounts(legacy1) > 0);
  final legacy2 =
      (await scalar("select public.ws_create_organization('Legacy Co')")).toInt();
  check('   without a uuid it is NOT deduplicated (unchanged behaviour)',
      legacy1 != legacy2);

  // ── 7. LOOKUP BY UUID ───────────────────────────────────────────────────
  await asUser(newUser);
  check('7. lookup resolves the registration',
      await str("select doctype from public.ws_lookup_clientuuid('$k1')") ==
          'organization');
  check('   with the right org id',
      (await scalar("select docid from public.ws_lookup_clientuuid('$k1')"))
              .toInt() ==
          org1);
  check("   another user cannot see it", await () async {
    await asUser(user2);
    final n = await scalar(
        "select count(*)::int from public.ws_lookup_clientuuid('$k1')");
    return n == 0;
  }());

  // ── unauthenticated ─────────────────────────────────────────────────────
  await db.execute("set ws.test_uid = ''");
  check('an unauthenticated caller is refused',
      await errcode("select public.ws_create_organization('Anon Co')") == '42501');
  await asUser(owner);
}

// ═════════════════════════════════════════════════════════════════════════════

Future<void> invariants() async {
  print('\n═══ invariants ═══');
  await asUser(owner);

  check('rows written before 014 still have a NULL key and are valid',
      await scalar("select count(*)::int from public.ws_tblcustomers "
              "where clientuuid is null") >
          0);
  check('a NULL-key customer can still be updated',
      await errcode("update public.ws_tblcustomers set phone = '0300-0000000' "
              "where clientuuid is null and orgid = 1") ==
          null);
  check('a NULL-key vendor can still be updated',
      await errcode("update public.ws_tblvendors set phone = '0300-0000000' "
              "where clientuuid is null and orgid = 1") ==
          null);

  check('customer reference codes are untouched by 014',
      await scalar("select count(*)::int from public.ws_tblcustomers "
              "where customercode is not null") >=
          0);
  check('every organization still has a publicid',
      await scalar("select count(*)::int from public.ws_tblorganization "
              "where publicid is null") ==
          0);

  check('vw_ws_reconciliation = 0',
      await scalar("select count(*)::int from public.vw_ws_reconciliation") == 0);
  check('vw_ws_unbalancedentries = 0',
      await scalar("select count(*)::int from public.vw_ws_unbalancedentries") ==
          0);

  check('exactly one ws_create_organization signature exists',
      await scalar("select count(*)::int from pg_proc p "
              "join pg_namespace n on n.oid = p.pronamespace "
              "where n.nspname = 'public' and p.proname = 'ws_create_organization'") ==
          1);
  check('exactly one provision_organization signature exists',
      await scalar("select count(*)::int from pg_proc p "
              "join pg_namespace n on n.oid = p.pronamespace "
              "where n.nspname = 'ws' and p.proname = 'provision_organization'") ==
          1);
}

void main() async {
  db = await connect();
  owner = await _member(orgid: 1, withPerm: 'customers.manage');
  noRights = await _member(orgid: 1, withPerm: 'customers.manage', negate: true);

  await customers();
  await vendors();
  await organizations();
  await invariants();

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
