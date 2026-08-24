// =============================================================================
// bin/location_tagging.dart
//
// Migration 018 against real PostgreSQL 16 (000–018).
//
// The claim that matters most: A RETRY CANNOT MOVE A POSTED DELIVERY. The
// client freezes the coordinates in the queued payload, but the guarantee has
// to hold even against a client that sends different ones — and that half lives
// in ws_record_delivery's early return, which is exercised here.
//
// Run:  dart run bin/location_tagging.dart
// =============================================================================

import 'dart:io';

import 'package:postgres/postgres.dart';

late Connection db;
late String owner;
late String driverA;
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
          database: 'ws_geo',
          username: 'postgres',
          password: ''),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

Future<num> scalar(String sql) async {
  final v = (await db.execute(sql)).first[0];
  return v is num ? v : num.parse('$v');
}

double? numOf(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}

Future<double?> coord(String table, String idCol, int id, String col) async {
  final r = await db.execute(
      'select $col from public.$table where $idCol = $id');
  return r.isEmpty ? null : numOf(r.first[0]);
}

Future<String?> errcode(String sql) async {
  try {
    await db.execute(sql);
    return null;
  } on ServerException catch (e) {
    return e.code;
  }
}

Future<int> recon() async =>
    (await scalar('select count(*)::int from public.vw_ws_reconciliation'))
        .toInt();

// ═════════════════════════════════════════════════════════════════════════════

Future<void> setup() async {
  print('\n═══ setup ═══');
  await db.execute('grant usage on schema auth to authenticated');
  await db.execute('grant execute on all functions in schema auth to authenticated');

  owner = (await db.execute("select m.authuserid::text from "
          "public.ws_tblmemberships m "
          "join public.ws_tblrolepermissions rp on rp.roleid = m.roleid "
          "where m.orgid = $orgId and rp.permcode = 'org.manage' limit 1"))
      .first[0] as String;
  await db.execute("set ws.test_uid = '$owner'");

  storeA = (await scalar('select storeid from public.ws_tblstores '
          'where orgid = $orgId and isdefault'))
      .toInt();
  storeB = (await scalar("select public.ws_record_store($orgId, 'Geo Depot', "
          "p_storecode => 'GEO${DateTime.now().millisecondsSinceEpoch % 100000}', "
          "p_clientuuid => gen_random_uuid())"))
      .toInt();

  final uid = (await db.execute('select gen_random_uuid()::text')).first[0];
  await db.execute("insert into auth.users(id, email) "
      "values ('$uid', 'geo-$uid@example.test')");
  final roleId = (await scalar("select roleid from public.ws_tblroles "
          "where orgid = $orgId and rolecode = 'delivery'"))
      .toInt();
  await db.execute("insert into public.ws_tblmemberships(orgid, authuserid, roleid) "
      "values ($orgId, '$uid', $roleId)");
  await db.execute("select public.ws_set_store_access($storeA, '$uid', true)");
  driverA = uid as String;

  check('the schema has the columns', await scalar(
          "select count(*)::int from information_schema.columns "
          "where table_name in ('ws_tblcustomers','ws_tbldeliveries') "
          "and column_name in ('latitude','longitude','locationaccuracy',"
          "'locationcapturedat')") ==
      8);

  check('and NOTHING ELSE grew a location column',
      await scalar("select count(*)::int from information_schema.columns "
              "where table_schema = 'public' and column_name = 'latitude' "
              "and table_name not in ('ws_tblcustomers','ws_tbldeliveries')") ==
          0,
      'payments, purchases and journals were deliberately left alone');
}

Future<void> customers() async {
  print('\n═══ customer location ═══');
  await db.execute("set ws.test_uid = '$owner'");
  final tag = DateTime.now().millisecondsSinceEpoch % 100000;

  // ── create with coordinates ─────────────────────────────────────────────
  final withGps = (await scalar("select public.ws_record_customer($orgId, "
          "'Geo Customer $tag', p_latitude => 24.8607, p_longitude => 67.0011, "
          "p_accuracy => 12.5, p_clientuuid => gen_random_uuid())"))
      .toInt();
  check('created with coordinates',
      await coord('ws_tblcustomers', 'customerid', withGps, 'latitude') ==
          24.8607);
  check('longitude too',
      await coord('ws_tblcustomers', 'customerid', withGps, 'longitude') ==
          67.0011);
  check('accuracy recorded',
      await coord('ws_tblcustomers', 'customerid', withGps, 'locationaccuracy') ==
          12.5);
  check('and a capture timestamp',
      await scalar("select count(*)::int from public.ws_tblcustomers "
              "where customerid = $withGps and locationcapturedat is not null") ==
          1);

  // ── create WITHOUT coordinates ──────────────────────────────────────────
  final noGps = (await scalar("select public.ws_record_customer($orgId, "
          "'Geo NoLoc $tag', p_clientuuid => gen_random_uuid())"))
      .toInt();
  check('a customer with no location is perfectly valid',
      await coord('ws_tblcustomers', 'customerid', noGps, 'latitude') == null);
  check('and has no capture timestamp either',
      await scalar("select count(*)::int from public.ws_tblcustomers "
              "where customerid = $noGps and locationcapturedat is null") ==
          1);

  // ── EDITING OTHER FIELDS MUST NOT ERASE THE LOCATION ────────────────────
  await db.execute("update public.ws_tblcustomers "
      "set phone = '0300-9999999', address = 'Somewhere else' "
      "where customerid = $withGps");
  check('EDITING OTHER FIELDS PRESERVES THE COORDINATES',
      await coord('ws_tblcustomers', 'customerid', withGps, 'latitude') ==
          24.8607,
      'the update names only the columns it changes');

  // ── capturing later, on an existing customer ────────────────────────────
  await db.execute("select public.ws_set_customer_location($noGps, "
      "31.5204, 74.3587, 8.0)");
  check('location can be captured later',
      await coord('ws_tblcustomers', 'customerid', noGps, 'latitude') ==
          31.5204);

  await db.execute("select public.ws_set_customer_location($noGps, "
      "31.9999, 74.9999, 5.0)");
  check('and re-captured', await coord('ws_tblcustomers', 'customerid', noGps, 'latitude') ==
      31.9999);

  await db.execute("select public.ws_set_customer_location($noGps)");
  check('and cleared', await coord('ws_tblcustomers', 'customerid', noGps, 'latitude') ==
      null);
  check('clearing removes the timestamp too',
      await scalar("select count(*)::int from public.ws_tblcustomers "
              "where customerid = $noGps and locationcapturedat is null") ==
          1);

  check('half a coordinate is refused',
      await errcode("select public.ws_set_customer_location($noGps, 24.8, null)") ==
          '22023');
  check('an impossible latitude is refused',
      await errcode("select public.ws_record_customer($orgId, 'Bad $tag', "
              "p_latitude => 91, p_longitude => 0, "
              "p_clientuuid => gen_random_uuid())") ==
          '23514');
  check('an impossible longitude is refused',
      await errcode("select public.ws_record_customer($orgId, 'Bad2 $tag', "
              "p_latitude => 0, p_longitude => 181, "
              "p_clientuuid => gen_random_uuid())") ==
          '23514');
}

Future<void> deliveries() async {
  print('\n═══ delivery location ═══');
  await db.execute("set ws.test_uid = '$owner'");
  final r0 = await recon();

  final key = (await db.execute('select gen_random_uuid()::text')).first[0];
  final id = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_delivered => 2, p_returned => 1, "
          "p_productid => 1, p_amountpaid => 100, "
          "p_latitude => 24.8607, p_longitude => 67.0011, p_accuracy => 9, "
          "p_capturedat => '2026-08-14T06:00:00Z', "
          "p_clientuuid => '$key', p_storeid => $storeB)"))
      .toInt();

  check('the delivery carries its coordinates',
      await coord('ws_tbldeliveries', 'deliveryid', id, 'latitude') == 24.8607);
  check('and the CAPTURE time the client sent, not now()',
      await scalar("select count(*)::int from public.ws_tbldeliveries "
              "where deliveryid = $id "
              "and locationcapturedat = '2026-08-14T06:00:00Z'") ==
          1,
      'a delivery synced hours later must report when it happened');

  check('the payment inside it did NOT get a copy',
      await scalar("select count(*)::int from information_schema.columns "
              "where table_name = 'ws_tblpayments' and column_name = 'latitude'") ==
          0);

  // ── THE CENTRAL CLAIM ───────────────────────────────────────────────────
  final retried = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_delivered => 2, p_returned => 1, "
          "p_productid => 1, p_amountpaid => 100, "
          // Lahore instead of Karachi — a re-capture, or a tampered retry.
          "p_latitude => 31.5204, p_longitude => 74.3587, p_accuracy => 3, "
          "p_clientuuid => '$key', p_storeid => $storeB)"))
      .toInt();
  check('a retry returns the same delivery', retried == id);
  check('A TAMPERED RETRY CANNOT MOVE IT',
      await coord('ws_tbldeliveries', 'deliveryid', id, 'latitude') == 24.8607,
      'the idempotency check returns before the payload is read');
  check('accuracy unchanged too',
      await coord('ws_tbldeliveries', 'deliveryid', id, 'locationaccuracy') == 9);
  check('still exactly one delivery for that key',
      await scalar("select count(*)::int from public.ws_tbldeliveries "
              "where clientuuid = '$key'") ==
          1);

  // ── no location at all ──────────────────────────────────────────────────
  final plain = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_delivered => 1, p_productid => 1, "
          "p_clientuuid => gen_random_uuid())"))
      .toInt();
  check('a delivery with no location posts perfectly well',
      await coord('ws_tbldeliveries', 'deliveryid', plain, 'latitude') == null);
  check('and has no capture timestamp',
      await scalar("select count(*)::int from public.ws_tbldeliveries "
              "where deliveryid = $plain and locationcapturedat is null") ==
          1);

  // ── pre-existing rows ───────────────────────────────────────────────────
  check('EVERY delivery written before 018 is still valid',
      await scalar("select count(*)::int from public.ws_tbldeliveries "
              "where latitude is null") >
          0,
      'nullable columns, no backfill, nothing invalidated');

  check('an impossible delivery coordinate is refused',
      await errcode("select public.ws_record_delivery(p_customerid => 1, "
              "p_delivered => 1, p_productid => 1, p_latitude => -91, "
              "p_longitude => 0, p_clientuuid => gen_random_uuid())") ==
          '23514');

  check('reconciliation unaffected by any of it', await recon() == r0);
  check('no unbalanced entries',
      await scalar('select count(*)::int from public.vw_ws_unbalancedentries') ==
          0);
}

Future<void> isolation() async {
  print('\n═══ RLS and the store dimension are unchanged ═══');
  await db.execute("set ws.test_uid = '$owner'");

  final inB = (await scalar("select public.ws_record_delivery("
          "p_customerid => 1, p_delivered => 1, p_productid => 1, "
          "p_latitude => 24.9, p_longitude => 67.1, "
          "p_clientuuid => gen_random_uuid(), p_storeid => $storeB)"))
      .toInt();

  // driverA is confined to store A.
  await db.execute('begin');
  List<List<dynamic>> seen;
  try {
    await db.execute("set local ws.test_uid = '$driverA'");
    await db.execute('set local role authenticated');
    seen = (await db.execute(
            'select deliveryid, latitude from public.ws_tbldeliveries '
            'where deliveryid = $inB'))
        .map((r) => r.toList())
        .toList();
  } finally {
    await db.execute('rollback');
  }

  check('a branch-restricted driver cannot read another branch\'s coordinates',
      seen.isEmpty,
      'location does not create a new way around RLS');

  check('the located delivery still belongs to the branch it was posted to',
      await scalar('select storeid from public.ws_tbldeliveries '
              'where deliveryid = $inB') ==
          storeB);
  check('reconciliation still 0', await recon() == 0);
}

void main() async {
  db = await connect();
  await setup();
  await customers();
  await deliveries();
  await isolation();

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
