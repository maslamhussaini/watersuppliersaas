// =============================================================================
// bin/plan_limits.dart
//
// Migration 019 — ws_tblplans.maxcustomers enforced against a real PostgreSQL
// 16, through every path that can raise an organization's active customer
// count.
//
// The point of this harness is that the limit is NOT enforced by the RPC. It is
// enforced by a trigger, so the direct-insert path that bypasses
// ws_record_customer has to be refused identically. PL-2 is the case that would
// have shipped broken under an RPC guard.
//
// The multi-row case (PL-14) deliberately does not assert a predetermined
// outcome. It records what PostgreSQL actually does with a five-row
// INSERT ... SELECT that crosses the cap, and asserts only the invariant that
// matters: the organization never ends up over its limit.
//
// Run:  dart run bin/plan_limits.dart
// =============================================================================
import 'dart:io';

import 'package:postgres/postgres.dart';

late Connection db;
late String owner;

const orgA = 1; // Kent Mineral Water
const orgB = 2; // AquaPure Distributors
const freeMax = 50;

/// ─── WHY EVERY FIXTURE NAME IS TAGGED ────────────────────────────────────────
///
/// ws_plan is long-lived. Nothing in test_harness/ drops, truncates or rebuilds
/// a database, and this harness must not either — so rows from previous runs are
/// still there. The first version of this file selected fixtures by plain name
/// ('fill-1', 'Retried save'), and after a few runs ws_plan held 27 rows called
/// 'fill-7'. An UPDATE meant for one row hit 27, and the count arithmetic that
/// every cap assertion depends on collapsed: 54 passed, 6 failed on re-run.
///
/// Stamped once per run, applied to every name this harness creates, so a
/// name-based lookup is unique WITHIN the run without deleting anything from
/// previous ones.
late String runTag;

/// The name this run uses for [base].
String fx(String base) => '$base [$runTag]';

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
          database: 'ws_plan',
          username: 'postgres',
          password: ''),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

Future<num> scalar(String sql, [Connection? on]) async {
  final v = (await (on ?? db).execute(sql)).first[0];
  return v is num ? v : num.parse('$v');
}

Future<String> textOf(String sql) async =>
    '${(await db.execute(sql)).first[0]}';

/// Runs [sql] and returns the SQLSTATE it raised, or null if it succeeded.
Future<String?> errcode(String sql, [Connection? on]) async {
  try {
    await (on ?? db).execute(sql);
    return null;
  } on ServerException catch (e) {
    return e.code;
  }
}

/// Runs [sql] and returns the raised message, or null if it succeeded.
Future<String?> errmsg(String sql) async {
  try {
    await db.execute(sql);
    return null;
  } on ServerException catch (e) {
    return e.message;
  }
}

// ── the number under test ───────────────────────────────────────────────────

Future<int> active(int org) async => (await scalar(
        'select count(*) from public.ws_tblcustomers '
        'where orgid = $org and isactive'))
    .toInt();

Future<int> total(int org) async => (await scalar(
        'select count(*) from public.ws_tblcustomers where orgid = $org'))
    .toInt();

// ── fixtures ────────────────────────────────────────────────────────────────

Future<void> setPlan(int org, String plan, String status) => db.execute(
    "update public.ws_tblsubscriptions set plancode = '$plan', "
    "status = '$status' where orgid = $org");

Future<void> dropSubscription(int org) => db.execute(
    "update public.ws_tblsubscriptions set status = 'canceled' "
    "where orgid = $org");

/// Deactivates everything, so a section starts from a known count.
Future<void> clearActive(int org) => db.execute(
    'update public.ws_tblcustomers set isactive = false where orgid = $org');

Future<int> storeOf(int org) async =>
    (await scalar('select storeid from public.ws_tblstores '
            'where orgid = $org and isdefault limit 1'))
        .toInt();

/// The production CREATE path: ws_record_customer, unmodified by 019.
///
/// [clientUuid] defaults to a server-generated one, so every CREATE in this
/// harness is a genuinely new record. A literal must only ever be passed for a
/// deliberate REPLAY of a uuid minted earlier in the same run.
Future<int> viaRpc(int org, String name, {String? clientUuid}) async {
  final cu = clientUuid == null ? 'gen_random_uuid()' : "'$clientUuid'::uuid";
  return (await scalar("select public.ws_record_customer("
          "p_orgid => $org, p_customername => '${fx(name)}', "
          'p_clientuuid => $cu)'))
      .toInt();
}

Future<String?> viaRpcErr(int org, String name, {String? clientUuid}) {
  final cu = clientUuid == null ? 'gen_random_uuid()' : "'$clientUuid'::uuid";
  return errcode('select public.ws_record_customer('
      "p_orgid => $org, p_customername => '${fx(name)}', "
      'p_clientuuid => $cu)');
}

/// The path an RPC-level guard would not see: straight at the table, which is
/// what the public anon key can do through PostgREST.
String directInsertSql(int org, String name, int store,
        {bool isactive = true}) =>
    'insert into public.ws_tblcustomers (orgid, customername, storeid, isactive) '
    "values ($org, '${fx(name)}', $store, $isactive)";

/// Fills an organization to [n] active customers, lifting the cap while it
/// does so. Used to build the grandfathered fixture, which is only reachable
/// in production by downgrading a plan.
Future<void> fillTo(int org, int n) async {
  await setPlan(org, 'pro', 'active');
  await clearActive(org);
  final store = await storeOf(org);
  await db.execute('insert into public.ws_tblcustomers '
      '(orgid, customername, storeid) '
      "select $org, '${fx('fill')}-' || g, $store "
      'from generate_series(1, $n) g');
}

// ═════════════════════════════════════════════════════════════════════════════

Future<void> run() async {
  final storeA = await storeOf(orgA);
  final storeB = await storeOf(orgB);

  // PL-1 ─────────────────────────────────────────────────────────────────────
  print('\n═══ PL-1  the boundary: 49 → 50 → 51 ═══');
  await fillTo(orgA, 49);
  await setPlan(orgA, 'free', 'trialing');
  check('fixture is at 49 active', await active(orgA) == 49);

  final fiftieth = await viaRpc(orgA, 'The 50th');
  check('the 50th is accepted — the cap is inclusive', fiftieth > 0);
  check('now at 50', await active(orgA) == 50);

  final over = await viaRpcErr(orgA, 'The 51st');
  check('the 51st raises P0001', over == 'P0001', 'got ${over ?? "no error"}');
  check('still 50 — nothing was written', await active(orgA) == 50);

  final msg = await errmsg("select public.ws_record_customer("
      "p_orgid => $orgA, p_customername => 'msg probe', "
      "p_clientuuid => gen_random_uuid())");
  check('the message names the plan and the number',
      msg != null && msg.contains('free') && msg.contains('50'),
      '${msg ?? ""}');

  // PL-2 ─────────────────────────────────────────────────────────────────────
  print('\n═══ PL-2  a direct table insert cannot bypass the limit ═══');
  // This is the case an RPC-level guard would have missed entirely.
  final direct = await errcode(directInsertSql(orgA, 'PostgREST bypass', storeA));
  check('a raw INSERT is refused identically', direct == 'P0001',
      'got ${direct ?? "no error"}');
  check('still 50', await active(orgA) == 50);

  // An inactive row is not a seat, so it must still be insertable at the cap.
  final inactiveAtCap = await errcode(
      directInsertSql(orgA, 'inactive at cap', storeA, isactive: false));
  check('an INSERT with isactive = false is allowed at the cap',
      inactiveAtCap == null, 'the WHEN clause never enters the function');
  check('and it did not consume a seat', await active(orgA) == 50);

  // PL-3 ─────────────────────────────────────────────────────────────────────
  print('\n═══ PL-3  the CSV import path ═══');
  // ws_csv_import_apply.dart:168 calls the same RPC, carrying storeid and a
  // clientuuid. Same function, so the same refusal.
  final csv = await errcode("select public.ws_record_customer("
      "p_orgid => $orgA, p_customername => 'CSV row', "
      "p_storeid => $storeA, p_phone => '03001234567', "
      "p_clientuuid => gen_random_uuid())");
  check('an import row is refused at the cap', csv == 'P0001',
      'got ${csv ?? "no error"}');
  check('still 50', await active(orgA) == 50);

  // PL-4 ─────────────────────────────────────────────────────────────────────
  print('\n═══ PL-4  a retried save at the cap is NOT refused ═══');
  // The regression that matters most. ws_record_customer returns on a
  // clientuuid hit BEFORE the insert, so a lost response replayed at the cap
  // must return the existing id rather than raise a limit error for a seat it
  // already occupies.
  await clearActive(orgA);
  await fillTo(orgA, 49);
  await setPlan(orgA, 'free', 'trialing');

  // Minted ONCE, here, for this run only — then replayed unchanged.
  //
  // This was a hard-coded literal, and that is what broke the harness on its
  // second run: ws_record_customer's clientuuid short-circuit found the row the
  // FIRST run had created, returned it, and the 50th customer was never made.
  // A literal is exactly the payload of a replay, so it must never be the
  // payload of a create.
  final retryUuid = await textOf('select gen_random_uuid()');
  final firstId = await viaRpc(orgA, 'Retried save', clientUuid: retryUuid);
  check('the 50th was created', await active(orgA) == 50);

  final retryErr = await viaRpcErr(orgA, 'Retried save', clientUuid: retryUuid);
  check('the retry does NOT raise, even though the org is now at the cap',
      retryErr == null, 'got ${retryErr ?? ""}');

  final secondId = await viaRpc(orgA, 'Retried save', clientUuid: retryUuid);
  check('and it returns the SAME customerid', secondId == firstId);
  check('no second row was made', await active(orgA) == 50);

  // A third time from a brand new connection, as a restarted app would.
  final fresh = await connect();
  await fresh.execute("set ws.test_uid = '$owner'");
  final thirdId = (await scalar(
          "select public.ws_record_customer(p_orgid => $orgA, "
          "p_customername => '${fx('Retried save')}', "
          "p_clientuuid => '$retryUuid'::uuid)",
          fresh))
      .toInt();
  check('and again across a reconnect', thirdId == firstId);
  await fresh.close();
  check('still 50', await active(orgA) == 50);

  // PL-5 ─────────────────────────────────────────────────────────────────────
  print('\n═══ PL-5  soft-delete then create ═══');
  await db.execute('update public.ws_tblcustomers set isactive = false '
      "where orgid = $orgA and customername = '${fx('Retried save')}'");
  check('deactivating at the cap is allowed', await active(orgA) == 49);

  final afterDelete = await viaRpcErr(orgA, 'Took the freed seat');
  check('the freed seat can be taken', afterDelete == null,
      'got ${afterDelete ?? ""}');
  check('back at 50', await active(orgA) == 50);

  // PL-6 ─────────────────────────────────────────────────────────────────────
  print('\n═══ PL-6  reactivation is guarded ═══');
  // Unreachable from the app — no restore path exists — but reachable from
  // PostgREST with the public anon key, which is why it is a trigger.
  final reactivateAtCap = await errcode(
      'update public.ws_tblcustomers set isactive = true '
      "where orgid = $orgA and customername = '${fx('Retried save')}'");
  check('false → true at the cap raises P0001', reactivateAtCap == 'P0001',
      'got ${reactivateAtCap ?? "no error"}');
  check('still 50', await active(orgA) == 50);

  await db.execute('update public.ws_tblcustomers set isactive = false '
      "where orgid = $orgA and customername = '${fx('Took the freed seat')}'");
  check('now at 49', await active(orgA) == 49);

  final reactivateUnder = await errcode(
      'update public.ws_tblcustomers set isactive = true '
      "where orgid = $orgA and customername = '${fx('Retried save')}'");
  check('false → true under the cap is allowed', reactivateUnder == null,
      'got ${reactivateUnder ?? ""}');
  check('back at 50', await active(orgA) == 50);

  // PL-7 ─────────────────────────────────────────────────────────────────────
  print('\n═══ PL-7  ordinary edits at the cap ═══');
  // WsCustomer.toInsert() always carries isactive, so every save in the product
  // is a true → true update. It must not be refused, and must not even enter
  // the function.
  // Must be a row that is genuinely ACTIVE, or this stops being a true → true
  // test and becomes a reactivation. Picked from the table rather than assumed
  // from an earlier section's leftovers.
  final activeId = (await scalar(
          'select customerid from public.ws_tblcustomers '
          'where orgid = $orgA and isactive order by customerid limit 1'))
      .toInt();

  final rename = await errcode(
      "update public.ws_tblcustomers set customername = '${fx('Renamed at cap')}' "
      'where customerid = $activeId');
  check('renaming at the cap succeeds', rename == null, 'got ${rename ?? ""}');

  final trueToTrue = await errcode(
      "update public.ws_tblcustomers set customername = '${fx('Edited again')}', "
      "phone = '03009876543', isactive = true "
      'where customerid = $activeId');
  check('a true → true save carrying isactive succeeds', trueToTrue == null,
      'the WHEN clause short-circuits before the count');

  final bulkEdit = await errcode(
      "update public.ws_tblcustomers set isactive = true where orgid = $orgA "
      'and isactive');
  check('setting isactive = true across ALL 50 active rows succeeds',
      bulkEdit == null, 'no row transitions, so no check runs');
  check('still 50', await active(orgA) == 50);

  // PL-8 ─────────────────────────────────────────────────────────────────────
  print('\n═══ PL-8  a grandfathered over-limit organization ═══');
  // Reached in production by downgrading: 60 customers on pro, then free.
  await fillTo(orgA, 60);
  await setPlan(orgA, 'free', 'trialing');
  check('60 active on a 50-customer plan', await active(orgA) == 60);

  final grandEdit = await errcode(
      "update public.ws_tblcustomers set phone = '03001112222' "
      "where orgid = $orgA and customername = '${fx('fill')}-1'");
  check('existing rows remain editable', grandEdit == null);

  final grandDelete = await errcode(
      'update public.ws_tblcustomers set isactive = false '
      "where orgid = $orgA and customername = '${fx('fill')}-2'");
  check('and deactivatable', grandDelete == null);
  check('now 59 — still over the limit', await active(orgA) == 59);

  final grandInsert = await viaRpcErr(orgA, 'One too many');
  check('but a new active customer is refused', grandInsert == 'P0001',
      'got ${grandInsert ?? "no error"}');

  final grandReactivate = await errcode(
      'update public.ws_tblcustomers set isactive = true '
      "where orgid = $orgA and customername = '${fx('fill')}-2'");
  check('and so is reactivating the one just removed',
      grandReactivate == 'P0001', 'got ${grandReactivate ?? "no error"}');
  check('nothing was destroyed by the migration', await total(orgA) >= 60);

  // PL-9 ─────────────────────────────────────────────────────────────────────
  print('\n═══ PL-9  pro is unlimited ═══');
  await setPlan(orgA, 'pro', 'active');
  final proErr = await viaRpcErr(orgA, 'Pro customer');
  check('null maxcustomers accepts a 60th and beyond', proErr == null,
      'got ${proErr ?? ""}');
  check('past 50 with no refusal', await active(orgA) > 50);

  // PL-10 ────────────────────────────────────────────────────────────────────
  print('\n═══ PL-10  no live subscription falls back to Free ═══');
  await fillTo(orgA, 50);
  await dropSubscription(orgA);
  check('no live subscription row', await scalar(
          'select count(*) from public.ws_tblsubscriptions '
          "where orgid = $orgA and status in "
          "('trialing','active','past_due')") ==
      0);

  final noSub = await viaRpcErr(orgA, 'Lapsed org customer');
  check('capped at the Free limit, not unlimited', noSub == 'P0001',
      'got ${noSub ?? "no error"}');

  await db.execute('update public.ws_tblcustomers set isactive = false '
      "where orgid = $orgA and customername = '${fx('fill')}-1'");
  final noSubUnder = await viaRpcErr(orgA, 'Lapsed org, under cap');
  check('and NOT blocked outright — it still works under the cap',
      noSubUnder == null, 'got ${noSubUnder ?? ""}');
  check('at 50', await active(orgA) == 50);

  // PL-11 ────────────────────────────────────────────────────────────────────
  print('\n═══ PL-11  past_due keeps the plan\'s normal limits ═══');
  await fillTo(orgA, 49);
  await setPlan(orgA, 'free', 'past_due');
  final pastDueUnder = await viaRpcErr(orgA, 'past_due 50th');
  check('the 50th is still allowed on past_due', pastDueUnder == null,
      'got ${pastDueUnder ?? ""}');
  final pastDueOver = await viaRpcErr(orgA, 'past_due 51st');
  check('and the 51st is still refused', pastDueOver == 'P0001',
      'got ${pastDueOver ?? "no error"}');

  await fillTo(orgA, 60);
  await setPlan(orgA, 'basic', 'past_due');
  final basicPastDue = await viaRpcErr(orgA, 'basic past_due');
  check('a past_due basic org keeps the BASIC limit of 500, not Free\'s 50',
      basicPastDue == null, 'got ${basicPastDue ?? ""}');

  // PL-12 ────────────────────────────────────────────────────────────────────
  print('\n═══ PL-12  two sessions racing at 49 ═══');
  await fillTo(orgA, 49);
  await setPlan(orgA, 'free', 'trialing');

  final c1 = await connect();
  final c2 = await connect();
  for (final c in [c1, c2]) {
    await c.execute("set ws.test_uid = '$owner'");
  }

  await c1.execute('begin');
  await c2.execute('begin');

  await c1.execute(directInsertSql(orgA, 'race A', storeA));

  // c2 must block on the advisory lock rather than read a stale count of 49.
  final raced = errcode(directInsertSql(orgA, 'race B', storeA), c2);
  await Future<void>.delayed(const Duration(milliseconds: 300));

  final duringRace = await active(orgA);
  check('the second session is still blocked, not committed', duringRace == 49,
      'uncommitted work is invisible to a third connection');

  await c1.execute('commit');
  final raceErr = await raced;
  check('the loser is refused rather than admitted', raceErr == 'P0001',
      'got ${raceErr ?? "no error"}');
  await c2.execute('rollback');
  await c1.close();
  await c2.close();

  check('exactly 50 — never 51', await active(orgA) == 50);

  // PL-13 ────────────────────────────────────────────────────────────────────
  print('\n═══ PL-13  one tenant\'s cap is not another\'s ═══');
  await clearActive(orgB);
  await setPlan(orgB, 'free', 'trialing');

  // ws_record_customer checks customers.manage against ws.test_uid, so org B's
  // RPC has to run as one of org B's own members.
  final ownerB = (await db.execute('select m.authuserid::text from '
          'public.ws_tblmemberships m '
          'join public.ws_tblrolepermissions rp on rp.roleid = m.roleid '
          "where m.orgid = $orgB and rp.permcode = 'customers.manage' limit 1"))
      .first[0] as String;
  await db.execute("set ws.test_uid = '$ownerB'");

  final bErr = await viaRpcErr(orgB, 'Org B customer');
  check('org B can create while org A sits at its cap', bErr == null,
      'got ${bErr ?? ""}');
  check('org A is unchanged', await active(orgA) == 50);
  check('org B counts only its own', await active(orgB) == 1);

  final bDirect =
      await errcode(directInsertSql(orgB, 'Org B direct', storeB));
  check('and org B is unaffected by org A being full', bDirect == null);

  await db.execute("set ws.test_uid = '$owner'");

  // PL-14 ────────────────────────────────────────────────────────────────────
  print('\n═══ PL-14  multi-row INSERT ... SELECT crossing the cap ═══');
  // No assumption is made about how a row-level BEFORE INSERT trigger observes
  // rows inserted earlier in the SAME statement. The observed behaviour is
  // recorded; the assertion is only on the invariant.
  await fillTo(orgA, 48);
  await setPlan(orgA, 'free', 'trialing');
  final before14 = await active(orgA);
  check('fixture is at 48 active', before14 == 48);

  final multi = await errcode('insert into public.ws_tblcustomers '
      '(orgid, customername, storeid) '
      "select $orgA, '${fx('multi')}-' || g, $storeA from generate_series(1, 5) g");
  final after14 = await active(orgA);

  print('    ──────────────────────────────────────────────────────────────');
  print('    OBSERVED: five-row INSERT ... SELECT starting from 48 active,');
  print('              cap 50.');
  print('      result        : ${multi == null ? "accepted" : "rejected ($multi)"}');
  print('      active before : $before14');
  print('      active after  : $after14');
  print('      rows added    : ${after14 - before14}');
  if (multi != null) {
    print('      → the statement was refused and rolled back whole. The');
    print('        trigger therefore SEES rows inserted earlier in the same');
    print('        command: row 3 counted rows 1 and 2 and hit the cap.');
  } else {
    print('      → the statement was accepted. The trigger does NOT see');
    print('        earlier rows of the same command, and the cap can be');
    print('        overshot by a single multi-row statement.');
  }
  print('    ──────────────────────────────────────────────────────────────');

  check('THE INVARIANT: a multi-row statement never leaves the org over its cap',
      after14 <= freeMax, 'ended at $after14 with a limit of $freeMax');
  check('the outcome is all-or-nothing, never a partial batch',
      after14 == before14 || after14 == before14 + 5,
      'ended at $after14 from $before14');

  // PL-15 ────────────────────────────────────────────────────────────────────
  print('\n═══ PL-15  the trigger does not disturb anything else ═══');
  await fillTo(orgA, 10);
  await setPlan(orgA, 'free', 'trialing');

  final custId = await viaRpc(orgA, 'Ops customer');
  final openErr = await errcode(
      'select public.ws_set_customer_opening($custId, 500)');
  check('customer opening balances still post', openErr == null,
      'got ${openErr ?? ""}');

  final recon = await scalar('select count(*) from vw_ws_reconciliation '
      'where abs(coalesce(difference, 0)) > 0.005');
  check('reconciliation is still 0 across every organization', recon == 0);

  // The same view the other harnesses check, rather than a hand-rolled query.
  final unbalanced =
      await scalar('select count(*)::int from public.vw_ws_unbalancedentries');
  check('no unbalanced journal entries', unbalanced == 0);

  final delivered = (await scalar('select public.ws_record_delivery('
          'p_customerid => $custId, p_delivered => 2, p_returned => 0, '
          'p_productid => 1, p_amountpaid => 0, '
          'p_clientuuid => gen_random_uuid())'))
      .toInt();
  check('deliveries still post against a customer', delivered > 0);
}

void main() async {
  db = await connect();

  // Digits only, so it can never need quoting inside the SQL these fixtures
  // build. Microsecond resolution is enough: two runs cannot start in the same
  // microsecond, and the tag only has to be unique across runs, not globally.
  runTag = 'r${DateTime.now().microsecondsSinceEpoch}';
  print('run tag: $runTag');

  owner = (await db.execute("select m.authuserid::text from "
          'public.ws_tblmemberships m '
          'join public.ws_tblrolepermissions rp on rp.roleid = m.roleid '
          "where m.orgid = $orgA and rp.permcode = 'customers.manage' limit 1"))
      .first[0] as String;
  await db.execute("set ws.test_uid = '$owner'");

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
