// =============================================================================
// bin/store_branch.dart
//
// Migration 015, executed against a real PostgreSQL 16 loaded with 000–015.
//
// Two things are being proven, and they are different:
//
//   1. DOCUMENTS LAND IN THE STORE THEY WERE GIVEN — including when the queue
//      drains long after the user switched branches. Tested through the REAL
//      WsOutbox, because the guarantee lives in "the payload is authoritative"
//      and that is a property of the queue, not of SQL.
//
//   2. A USER RESTRICTED TO ONE BRANCH CANNOT REACH ANOTHER. Tested under
//      `set role authenticated`, because as superuser Postgres skips row level
//      security entirely and every isolation test would pass for the wrong
//      reason.
//
// Run:  dart run bin/store_branch.dart
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

import '../lib/ws_outbox.dart';
import '../lib/ws_outbox_store.dart';

late Connection db;
late String owner; // org 1 owner — sees every branch
late String driverA; // assigned to store A only
late String driverB; // assigned to store B only
late int storeA;
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
          database: 'ws_store',
          username: 'postgres',
          password: ''),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

Future<num> scalar(String sql, [Connection? on]) async {
  final v = (await (on ?? db).execute(sql)).first[0];
  return v is num ? v : num.parse('$v');
}

Future<String?> errcode(String sql, [Connection? on]) async {
  try {
    await (on ?? db).execute(sql);
    return null;
  } on ServerException catch (e) {
    return e.code;
  }
}

Future<void> asUser(String uid, [Connection? on]) =>
    (on ?? db).execute("set ws.test_uid = '$uid'");

/// Runs [sql] as the `authenticated` role, which is the only way row level
/// security is actually in force — superusers bypass every policy.
Future<List<List<dynamic>>> asAuthenticated(String uid, String sql) async {
  await db.execute('begin');
  try {
    await db.execute("set local ws.test_uid = '$uid'");
    await db.execute('set local role authenticated');
    final r = await db.execute(sql);
    return r.map((row) => row.toList()).toList();
  } finally {
    await db.execute('rollback');
  }
}

/// Same, but returns the SQLSTATE of a write that RLS refused.
Future<String?> writeAsAuthenticated(String uid, String sql) async {
  await db.execute('begin');
  try {
    await db.execute("set local ws.test_uid = '$uid'");
    await db.execute('set local role authenticated');
    await db.execute(sql);
    return null;
  } on ServerException catch (e) {
    return e.code;
  } finally {
    await db.execute('rollback');
  }
}

Future<String> newAuthUser() async {
  final id = (await db.execute('select gen_random_uuid()::text')).first[0] as String;
  await db.execute("insert into auth.users(id, email) "
      "values ('$id', 'store-$id@example.test')");
  return id;
}

// ═════════════════════════════════════════════════════════════════════════════

Future<void> setup() async {
  print('\n═══ setup: two branches in one organization ═══');

  // Supabase grants `authenticated` USAGE on the auth schema; the local shim
  // in 000_adopt_existing_schema.sql does not.
  //
  // WITHOUT THIS EVERY ISOLATION TEST BELOW PASSES FOR THE WRONG REASON. Any
  // policy path that reaches auth.uid() raises "permission denied for schema
  // auth" — also SQLSTATE 42501 — so a write is refused whatever store it
  // names, and "driver A cannot write into store B" looks green while proving
  // nothing at all.
  await db.execute('grant usage on schema auth to authenticated');
  await db.execute('grant execute on all functions in schema auth to authenticated');

  owner = (await db.execute("select m.authuserid::text from "
          "public.ws_tblmemberships m "
          "join public.ws_tblrolepermissions rp on rp.roleid = m.roleid "
          "where m.orgid = $orgId and rp.permcode = 'org.manage' limit 1"))
      .first[0] as String;
  await asUser(owner);

  storeA = (await scalar(
          "select storeid from public.ws_tblstores where orgid = $orgId and isdefault"))
      .toInt();
  check('the organization already had a default store after 015', storeA > 0,
      'storeA=$storeA');

  // Unique per run: storecode is unique per organization, so a fixed code
  // makes the suite pass once and fail on every re-run against the same
  // database — a self-inflicted flake, not a product bug.
  final code = 'NORTH-${DateTime.now().millisecondsSinceEpoch}';
  storeB = (await scalar("select public.ws_record_store("
          "$orgId, 'North Depot', p_storecode => '$code', "
          "p_clientuuid => gen_random_uuid())"))
      .toInt();
  check('a second store can be created', storeB > 0, 'storeB=$storeB');
  check('creating it did not steal the default flag',
      await scalar("select storeid from public.ws_tblstores "
              "where orgid = $orgId and isdefault") ==
          storeA);

  // Two drivers, each confined to one branch.
  final roleId = (await scalar("select roleid from public.ws_tblroles "
          "where orgid = $orgId and rolecode = 'delivery'"))
      .toInt();
  for (final which in ['A', 'B']) {
    final uid = await newAuthUser();
    await db.execute("insert into public.ws_tblmemberships(orgid, authuserid, roleid) "
        "values ($orgId, '$uid', $roleId)");
    await db.execute("select public.ws_set_store_access("
        "${which == 'A' ? storeA : storeB}, '$uid', true)");
    if (which == 'A') {
      driverA = uid;
    } else {
      driverB = uid;
    }
  }
  check('driver A is assigned to store A only',
      await scalar("select count(*)::int from public.ws_tblstoremembers "
              "where authuserid = '$driverA'") ==
          1);
}

// ═════════════════════════════════════════════════════════════════════════════
// DOCUMENTS LAND IN THE STORE THEY WERE GIVEN
// ═════════════════════════════════════════════════════════════════════════════

Future<void> posting() async {
  print('\n═══ every document type lands in the store it was given ═══');
  await asUser(owner);
  final today = DateTime.now().toIso8601String().split('T').first;

  Future<int> storeOf(String table, String col, int id) async =>
      (await scalar("select storeid from public.$table where $col = $id")).toInt();

  // delivery
  final d = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_deliverydate => '$today', p_delivered => 3, "
          "p_returned => 1, p_productid => 1, p_amountpaid => 120, "
          "p_clientuuid => gen_random_uuid(), p_storeid => $storeB)"))
      .toInt();
  check('delivery → store B', await storeOf('ws_tbldeliveries', 'deliveryid', d) == storeB);
  check('the cash taken with it went to store B too',
      await scalar("select storeid from public.ws_tblpayments "
              "where deliveryid = $d") ==
          storeB,
      'the payment inside a delivery must not fall back to the default');
  check('and so did the bottle movement',
      await scalar("select count(*)::int from public.ws_tblbottletransactions "
              "where deliveryid = $d and storeid = $storeB") >=
          1);

  // standalone payment
  final p = (await scalar("select public.ws_record_payment("
          "p_customerid => 1, p_amount => 90, p_paymentdate => '$today', "
          "p_clientuuid => gen_random_uuid(), p_storeid => $storeB)"))
      .toInt();
  check('customer payment → store B',
      await storeOf('ws_tblpayments', 'paymentid', p) == storeB);

  // purchase
  final pu = (await scalar("select public.ws_record_purchase("
          "p_vendorid => 1, "
          "p_lines => '[{\"productid\":1,\"quantity\":5,\"unitcost\":20}]'::jsonb, "
          "p_purchasedate => '$today', p_clientuuid => gen_random_uuid(), "
          "p_storeid => $storeB)"))
      .toInt();
  check('purchase → store B',
      await storeOf('ws_tblpurchases', 'purchaseid', pu) == storeB);

  // vendor payment
  final vp = (await scalar("select public.ws_record_vendor_payment("
          "p_vendorid => 1, p_amount => 60, p_paiddate => '$today', "
          "p_clientuuid => gen_random_uuid(), p_storeid => $storeB)"))
      .toInt();
  check('vendor payment → store B',
      await storeOf('ws_tblvendorpayments', 'vendorpaymentid', vp) == storeB);

  // omitted store = the default, which is how every single-branch org behaves
  final legacy = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_delivered => 1, p_productid => 1, "
          "p_clientuuid => gen_random_uuid())"))
      .toInt();
  check('a caller that passes NO store lands in the default (unchanged behaviour)',
      await storeOf('ws_tbldeliveries', 'deliveryid', legacy) == storeA);

  // a legacy direct insert, filled in by the trigger
  await db.execute("insert into public.ws_tbldeliveries(orgid, customerid, deliverydate) "
      "values ($orgId, 1, '$today')");
  check('a direct insert with no store is filled in, never null',
      await scalar("select count(*)::int from public.ws_tbldeliveries "
              "where storeid is null") ==
          0);

  // cross-tenant store
  final otherStore = (await scalar(
          "select storeid from public.ws_tblstores where orgid <> $orgId limit 1"))
      .toInt();
  check("another tenant's store is rejected",
      await errcode("select public.ws_record_delivery(p_customerid => 1, "
              "p_delivered => 1, p_productid => 1, p_storeid => $otherStore)") ==
          '22023');
}

// ═════════════════════════════════════════════════════════════════════════════
// ISOLATION — under RLS, as a real authenticated user
// ═════════════════════════════════════════════════════════════════════════════

Future<void> isolation() async {
  print('\n═══ a driver confined to one branch ═══');
  await asUser(owner);
  final today = DateTime.now().toIso8601String().split('T').first;

  // One delivery in each branch, so there is something to fail to see.
  final inA = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_delivered => 1, p_productid => 1, "
          "p_deliverydate => '$today', p_clientuuid => gen_random_uuid(), "
          "p_storeid => $storeA)"))
      .toInt();
  final inB = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_delivered => 1, p_productid => 1, "
          "p_deliverydate => '$today', p_clientuuid => gen_random_uuid(), "
          "p_storeid => $storeB)"))
      .toInt();

  final seenByA = await asAuthenticated(driverA,
      'select deliveryid from public.ws_tbldeliveries '
      'where deliveryid in ($inA, $inB)');
  final idsA = seenByA.map((r) => r[0]).toList();
  check('driver A sees the delivery in store A', idsA.contains(inA));
  check('driver A CANNOT see the delivery in store B', !idsA.contains(inB),
      'saw $idsA');

  final seenByB = await asAuthenticated(driverB,
      'select deliveryid from public.ws_tbldeliveries '
      'where deliveryid in ($inA, $inB)');
  final idsB = seenByB.map((r) => r[0]).toList();
  check('driver B sees only store B', idsB.contains(inB) && !idsB.contains(inA));

  final seenByOwner = await asAuthenticated(owner,
      'select deliveryid from public.ws_tbldeliveries '
      'where deliveryid in ($inA, $inB)');
  check('the owner sees both branches', seenByOwner.length == 2);

  // Writing into a branch they are not assigned to.
  final refused = await writeAsAuthenticated(driverA,
      "insert into public.ws_tbldeliveries(orgid, customerid, deliverydate, storeid) "
      "values ($orgId, 1, '$today', $storeB)");
  check('driver A CANNOT write into store B', refused != null,
      refused ?? 'the insert succeeded');

  final allowed = await writeAsAuthenticated(driverA,
      "insert into public.ws_tbldeliveries(orgid, customerid, deliverydate, storeid) "
      "values ($orgId, 1, '$today', $storeA)");
  check('driver A CAN write into store A', allowed == null, allowed ?? '');

  // Through the RPC, which authorises before it writes.
  await asUser(driverA);
  check('the RPC refuses a store the caller may not use',
      await errcode("select public.ws_record_delivery(p_customerid => 1, "
              "p_delivered => 1, p_productid => 1, p_storeid => $storeB)") ==
          '42501');
  await asUser(owner);

  // Switching: a user assigned to both.
  await db.execute("select public.ws_set_store_access($storeB, '$driverA', true)");
  final both = await asAuthenticated(driverA,
      'select storeid from public.ws_my_stores($orgId)');
  check('a user assigned to both branches can switch between them',
      both.length == 2, '${both.length} stores');

  await db.execute("select public.ws_set_store_access($storeB, '$driverA', false)");
  final backToOne = await asAuthenticated(driverA,
      'select storeid from public.ws_my_stores($orgId)');
  check('revoking access removes it again', backToOne.length == 1);

  // The rule that keeps every pre-015 user working.
  final unassigned = await newAuthUser();
  final roleId = (await scalar("select roleid from public.ws_tblroles "
          "where orgid = $orgId and rolecode = 'delivery'"))
      .toInt();
  await db.execute("insert into public.ws_tblmemberships(orgid, authuserid, roleid) "
      "values ($orgId, '$unassigned', $roleId)");
  final unassignedSees = await asAuthenticated(unassigned,
      'select storeid from public.ws_my_stores($orgId)');
  // Compared against the org's ACTUAL store count rather than a literal 2, so
  // the assertion survives a re-run that has added more branches.
  final allStores = (await scalar('select count(*)::int from public.ws_tblstores '
          'where orgid = $orgId and isactive'))
      .toInt();
  check('a user with NO assignment still reaches every branch (upgrade safety)',
      unassignedSees.length == allStores,
      'sees ${unassignedSees.length} of $allStores');
}

// ═════════════════════════════════════════════════════════════════════════════
// THE QUEUED STORE IS AUTHORITATIVE
// ═════════════════════════════════════════════════════════════════════════════

Future<void> outboxKeepsItsStore() async {
  print('\n═══ a queued document keeps the branch it was created in ═══');
  final dir = await Directory.systemTemp.createTemp('ws_store');
  final today = DateTime.now().toIso8601String().split('T').first;

  var offline = true;
  // The "currently selected store" in the UI. The whole point is that the
  // poster NEVER reads this.
  var uiSelectedStore = storeB;

  Future<WsPostResult> post(WsOutboxItem item) async {
    if (offline) return const WsPostResult.network('SocketException');
    try {
      await db.execute("set ws.test_uid = '$owner'");
      final a = item.args;
      final r = await db.execute(
        Sql.named('select public.ws_record_delivery('
            'p_customerid => @c, p_deliverydate => @d::date, '
            'p_delivered => @dl, p_returned => @rt, p_productid => @p, '
            'p_amountpaid => @ap, p_clientuuid => @u, '
            // FROM THE STORED PAYLOAD. Reading uiSelectedStore here instead is
            // exactly the bug this test exists to catch.
            'p_storeid => @s) as id'),
        parameters: {
          'c': a['p_customerid'],
          'd': a['p_deliverydate'],
          'dl': a['p_delivered'],
          'rt': a['p_returned'],
          'p': a['p_productid'],
          'ap': a['p_amountpaid'],
          'u': a['p_clientuuid'],
          's': a['p_storeid'],
        },
      );
      return WsPostResult.success(documentId: r.first[0] as int);
    } on ServerException catch (e) {
      return WsPostResult.permanent(e.message, code: e.code);
    }
  }

  final box = WsOutbox(
      store: WsOutboxFileStore('${dir.path}/q.json'), poster: post);
  await box.load();

  // Saved while store A is selected, offline.
  uiSelectedStore = storeA;
  final key = wsNewUuid();
  await box.enqueue(
    clientUuid: key,
    rpc: 'ws_record_delivery',
    args: {
      'p_customerid': 1,
      'p_deliverydate': today,
      'p_delivered': 4,
      'p_returned': 2,
      'p_productid': 1,
      'p_amountpaid': 50,
      'p_clientuuid': key,
      'p_storeid': uiSelectedStore, // captured at SAVE time
    },
    label: 'queued in store A',
  );
  await box.drain();
  check('it is queued, not posted', box.byUuid(key)!.status == WsOutboxStatus.pending);
  check('the store is on disk with it',
      File('${dir.path}/q.json').readAsStringSync().contains('"p_storeid":$storeA'));

  // The user switches branch, and the app restarts for good measure.
  uiSelectedStore = storeB;
  final afterRestart = WsOutbox(
      store: WsOutboxFileStore('${dir.path}/q.json'), poster: post);
  await afterRestart.load();
  check('the queued payload still names store A after a restart',
      afterRestart.byUuid(key)!.args['p_storeid'] == storeA);

  offline = false;
  await afterRestart.drain();
  final item = afterRestart.byUuid(key)!;
  check('it syncs', item.status == WsOutboxStatus.synced);

  final landed = (await scalar("select storeid from public.ws_tbldeliveries "
          "where clientuuid = '$key'"))
      .toInt();
  check('THE DOCUMENT LANDED IN STORE A, not the store now selected',
      landed == storeA, 'landed=$landed uiSelected=$uiSelectedStore');
  check('exactly one delivery', await scalar(
          "select count(*)::int from public.ws_tbldeliveries where clientuuid = '$key'") ==
      1);
  check('its payment went to store A as well',
      await scalar("select storeid from public.ws_tblpayments "
              "where clientuuid = '$key'") ==
          storeA);

  // Idempotency still holds, and a retry cannot re-point the document.
  item.status = WsOutboxStatus.pending;
  item.args['p_storeid'] = storeB; // a tampered retry
  await afterRestart.drain();
  check('a retry under the same key still returns one document',
      await scalar(
              "select count(*)::int from public.ws_tbldeliveries where clientuuid = '$key'") ==
          1);
  check('and CANNOT move it to another branch',
      (await scalar("select storeid from public.ws_tbldeliveries "
              "where clientuuid = '$key'"))
              .toInt() ==
          storeA);

  await dir.delete(recursive: true);
}

// ═════════════════════════════════════════════════════════════════════════════

Future<void> invariants() async {
  print('\n═══ invariants ═══');
  await asUser(owner);
  for (final t in [
    'ws_tblcustomers',
    'ws_tbldeliveries',
    'ws_tblpayments',
    'ws_tblpurchases',
    'ws_tblvendorpayments',
    'ws_tblbottletransactions'
  ]) {
    check('$t has no row without a store',
        await scalar("select count(*)::int from public.$t where storeid is null") ==
            0);
  }
  check('vw_ws_reconciliation = 0',
      await scalar('select count(*)::int from public.vw_ws_reconciliation') == 0);
  check('vw_ws_unbalancedentries = 0',
      await scalar('select count(*)::int from public.vw_ws_unbalancedentries') == 0);
  check('the trial balance still balances',
      await scalar('select coalesce(sum(totaldebit - totalcredit),0)::float8 '
              'from vw_ws_trialbalance where orgid = $orgId') ==
          0);
  check('exactly one signature of each posting RPC',
      await scalar("select count(*)::int from pg_proc p "
              "join pg_namespace n on n.oid = p.pronamespace "
              "where n.nspname = 'public' and p.proname in "
              "('ws_record_delivery','ws_record_payment','ws_record_purchase',"
              "'ws_record_vendor_payment','ws_record_customer')") ==
          5);
}

void main() async {
  db = await connect();
  await setup();
  await posting();
  await isolation();
  await outboxKeepsItsStore();
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
