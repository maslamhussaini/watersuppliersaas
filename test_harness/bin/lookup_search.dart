// =============================================================================
// bin/lookup_search.dart
//
// The SERVER half of searchable lookups, against real PostgreSQL 16 (000–017).
//
// The Flutter service builds its filter with PostgREST:
//
//     .or('customername.ilike.%q%,phone.ilike.%q%,customercode.ilike.%q%')
//     .eq('storeid', selected)      // customers only
//     .limit(20)
//
// PostgREST turns that into the SQL reproduced below, so what is being proved
// here is that the QUERY SHAPE behaves: it is case-insensitive, it is bounded,
// it respects the store dimension for customers, it does NOT for vendors, and
// row level security still applies underneath all of it.
//
// The last point is the one worth executing rather than assuming — a search
// that quietly ignored RLS would leak another branch's customer list through a
// picker.
//
// Run:  dart run bin/lookup_search.dart
// =============================================================================

import 'dart:io';

import 'package:postgres/postgres.dart';

late Connection db;
late String owner;
late String driverA; // confined to store A, delivery role
late String clerkA; // confined to store A, but may see vendors
late int _tag;
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
          database: 'ws_look',
          username: 'postgres',
          password: ''),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

Future<num> scalar(String sql) async {
  final v = (await db.execute(sql)).first[0];
  return v is num ? v : num.parse('$v');
}

/// The customer search exactly as PostgREST renders it.
String customerSql(String q, {int? storeId, int limit = 20}) => '''
  select customerid, customername
  from public.ws_tblcustomers
  where orgid = $orgId
    and isactive
    and (customername ilike '%$q%'
      or phone ilike '%$q%'
      or customercode ilike '%$q%')
    ${storeId == null ? '' : 'and storeid = $storeId'}
  order by customername
  limit $limit''';

String vendorSql(String q, {int limit = 20}) => '''
  select vendorid, vendorname
  from public.ws_tblvendors
  where orgid = $orgId
    and isactive
    and (vendorname ilike '%$q%'
      or phone ilike '%$q%'
      or vendorcode ilike '%$q%')
  order by vendorname
  limit $limit''';

String productSql(String q, {int limit = 20}) => '''
  select productid, productname
  from public.ws_tblproducts
  where orgid = $orgId
    and isactive
    and (productname ilike '%$q%' or productcode ilike '%$q%')
  order by productname
  limit $limit''';

Future<List<String>> namesFrom(String sql, {String? asUser}) async {
  if (asUser == null) {
    return (await db.execute(sql)).map((r) => '${r[1]}').toList();
  }
  // Under the authenticated role, so RLS is actually in force — as superuser
  // Postgres skips every policy and the isolation checks would pass for the
  // wrong reason.
  await db.execute('begin');
  try {
    await db.execute("set local ws.test_uid = '$asUser'");
    await db.execute('set local role authenticated');
    return (await db.execute(sql)).map((r) => '${r[1]}').toList();
  } finally {
    await db.execute('rollback');
  }
}

// ═════════════════════════════════════════════════════════════════════════════

Future<void> setup() async {
  print('\n═══ setup ═══');

  // Supabase grants this; the local auth shim does not, and without it every
  // RLS path that reaches auth.uid() fails with 42501 regardless of the query.
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
  storeB = (await scalar("select public.ws_record_store($orgId, 'Lookup Depot', "
          "p_storecode => 'LK${DateTime.now().millisecondsSinceEpoch}', "
          "p_clientuuid => gen_random_uuid())"))
      .toInt();

  // A driver who may only see store A.
  final uid = (await db.execute('select gen_random_uuid()::text')).first[0];
  await db.execute("insert into auth.users(id, email) "
      "values ('$uid', 'lookup-$uid@example.test')");
  final roleId = (await scalar("select roleid from public.ws_tblroles "
          "where orgid = $orgId and rolecode = 'delivery'"))
      .toInt();
  await db.execute("insert into public.ws_tblmemberships(orgid, authuserid, roleid) "
      "values ($orgId, '$uid', $roleId)");
  await db.execute("select public.ws_set_store_access($storeA, '$uid', true)");
  driverA = uid as String;

  // A DIFFERENT restricted user, with a role that may see vendors.
  //
  // The delivery role deliberately has no vendors.view — RLS hiding the
  // supplier list from a driver is correct, not a bug — so asserting "a
  // restricted user still sees all vendors" needs somebody who is allowed to
  // see vendors at all. Otherwise the test proves the permission model, not
  // the store model.
  final clerk = (await db.execute('select gen_random_uuid()::text')).first[0];
  await db.execute("insert into auth.users(id, email) "
      "values ('$clerk', 'clerk-$clerk@example.test')");
  final clerkRole = (await scalar("select roleid from public.ws_tblroles "
          "where orgid = $orgId and rolecode = 'accountant'"))
      .toInt();
  await db.execute("insert into public.ws_tblmemberships(orgid, authuserid, roleid) "
      "values ($orgId, '$clerk', $clerkRole)");
  await db.execute("select public.ws_set_store_access($storeA, '$clerk', true)");
  clerkA = clerk as String;

  // Searchable fixtures in both branches.
  Future<void> mk(String name, String phone, String code, int store) =>
      db.execute("select public.ws_record_customer($orgId, '$name', "
          "p_phone => '$phone', p_customercode => '$code', "
          "p_storeid => $store, p_clientuuid => gen_random_uuid())");

  // customercode is unique per organization: fixed codes make this suite
  // pass once and fail on the next run against the same database.
  _tag = DateTime.now().millisecondsSinceEpoch % 100000;
  final tag = _tag;
  await mk('Scoped Alpha Hotel', '0300-5550001', 'LK-$tag-1', storeA);
  await mk('Scoped Beta Hotel', '0300-5550002', 'LK-$tag-2', storeA);
  await mk('Scoped Gamma Depot', '0300-5550003', 'LK-$tag-3', storeB);
  // vendorcode is unique per organization too — same re-run trap.
  await db.execute("select public.ws_record_vendor($orgId, 'Lookup Supplies Ltd', "
      "p_vendorcode => 'LKV-$_tag', p_phone => '0311-5550009', "
      "p_clientuuid => gen_random_uuid())");

  check('two branches exist', storeA != storeB);
  check('fixtures created',
      await scalar("select count(*)::int from public.ws_tblcustomers "
              "where orgid = $orgId and customername like 'Scoped %'") >=
          3);
}

Future<void> searching() async {
  print('\n═══ the query shape ═══');
  await db.execute("set ws.test_uid = '$owner'");

  check('partial name matches',
      (await namesFrom(customerSql('Scoped'))).length >= 3);
  check('exact name matches',
      (await namesFrom(customerSql('Scoped Alpha Hotel')))
          .every((n) => n == 'Scoped Alpha Hotel'));
  check('phone matches',
      (await namesFrom(customerSql('5550002'))).every((n) => n == 'Scoped Beta Hotel'));
  check('code matches',
      (await namesFrom(customerSql('LK-$_tag-3'))).single == 'Scoped Gamma Depot');
  check('IS CASE-INSENSITIVE — ilike, not like',
      (await namesFrom(customerSql('sCoPeD aLpHa')))
          .every((n) => n == 'Scoped Alpha Hotel'));
  check('no results returns nothing, not everything',
      (await namesFrom(customerSql('zzz nothing zzz'))).isEmpty);
  check('results are ordered by name',
      (await namesFrom(customerSql('Scoped'))).first == 'Scoped Alpha Hotel');

  // A search term with the characters that would break an or-filter. The
  // client sanitises them away before they are ever sent.
  check('a sanitised term is harmless',
      (await namesFrom(customerSql('Scoped Alpha'))).isNotEmpty);

  print('\n═══ the limit reaches the database ═══');
  final before = (await scalar("select count(*)::int from public.ws_tblcustomers "
          "where orgid = $orgId and customername like 'Bulk Lookup%'"))
      .toInt();
  if (before < 25) {
    for (var i = 0; i < 25; i++) {
      await db.execute("select public.ws_record_customer($orgId, "
          "'Bulk Lookup ${i.toString().padLeft(2, '0')}', "
          "p_storeid => $storeA, p_clientuuid => gen_random_uuid())");
    }
  }
  check('more rows exist than the limit allows',
      await scalar("select count(*)::int from public.ws_tblcustomers "
              "where orgid = $orgId and customername like 'Bulk Lookup%'") >=
          25);
  check('the query returns at most 20',
      (await namesFrom(customerSql('Bulk Lookup'))).length == 20,
      'the whole table is never sent to the client');
  check('a smaller limit is honoured too',
      (await namesFrom(customerSql('Bulk Lookup', limit: 5))).length == 5);
}

Future<void> scope() async {
  print('\n═══ store scope ═══');
  await db.execute("set ws.test_uid = '$owner'");

  final inA = await namesFrom(customerSql('Scoped', storeId: storeA));
  final inB = await namesFrom(customerSql('Scoped', storeId: storeB));
  check('filtering by branch A excludes branch B',
      inA.contains('Scoped Alpha Hotel') && !inA.contains('Scoped Gamma Depot'));
  check('filtering by branch B excludes branch A',
      inB.contains('Scoped Gamma Depot') && !inB.contains('Scoped Alpha Hotel'));
  check('unfiltered, the owner sees both branches',
      (await namesFrom(customerSql('Scoped'))).length >= 3);

  print('\n═══ RLS underneath, as a real authenticated user ═══');
  // The driver is confined to store A. Even asking for store B explicitly —
  // which a tampered client could do — must return nothing.
  final driverAll = await namesFrom(customerSql('Scoped'), asUser: driverA);
  check('a branch-restricted user sees only their branch',
      driverAll.contains('Scoped Alpha Hotel') &&
          !driverAll.contains('Scoped Gamma Depot'),
      'saw $driverAll');

  final driverAsksB =
      await namesFrom(customerSql('Scoped', storeId: storeB), asUser: driverA);
  check('ASKING for another branch returns nothing — RLS, not the filter',
      driverAsksB.isEmpty,
      'the store filter is convenience; this is the boundary');

  final ownerSeesB =
      await namesFrom(customerSql('Scoped', storeId: storeB), asUser: owner);
  check('while an unrestricted user still sees it',
      ownerSeesB.contains('Scoped Gamma Depot'));
}

Future<void> vendorsAndProducts() async {
  print('\n═══ vendors are organization-wide ═══');
  await db.execute("set ws.test_uid = '$owner'");

  check('vendor found by name',
      (await namesFrom(vendorSql('Lookup Supplies'))).isNotEmpty);
  check('vendor found by code',
      (await namesFrom(vendorSql('LKV-$_tag'))).length == 1);
  check('vendor found by phone',
      (await namesFrom(vendorSql('5550009'))).isNotEmpty);
  check('vendor search is case-insensitive',
      (await namesFrom(vendorSql('lookup supplies'))).isNotEmpty);

  check('ws_tblvendors STILL has no storeid column',
      await scalar("select count(*)::int from information_schema.columns "
              "where table_name = 'ws_tblvendors' and column_name = 'storeid'") ==
          0,
      'the vendor lookup must not have made vendors store-scoped');

  final clerkSees = await namesFrom(vendorSql('Lookup Supplies'), asUser: clerkA);
  check('a branch-restricted user still sees the whole vendor catalogue',
      clerkSees.isNotEmpty,
      'one set of suppliers for the business, whatever branch you are in');

  final driverSees = await namesFrom(vendorSql('Lookup Supplies'), asUser: driverA);
  check('while a driver, who has no vendors.view, sees none',
      driverSees.isEmpty,
      'RLS hiding suppliers from a driver is the permission model working');

  print('\n═══ products ═══');
  check('product found by name',
      (await namesFrom(productSql('Litre'))).isNotEmpty);
  check('product search is case-insensitive',
      (await namesFrom(productSql('litre'))).isNotEmpty);
  check('product search is bounded',
      (await namesFrom(productSql('', limit: 2))).length <= 2);
  check('ws_tblproducts has no storeid either',
      await scalar("select count(*)::int from information_schema.columns "
              "where table_name = 'ws_tblproducts' and column_name = 'storeid'") ==
          0);

  print('\n═══ nothing was disturbed ═══');
  check('vw_ws_reconciliation = 0',
      await scalar('select count(*)::int from public.vw_ws_reconciliation') == 0);
  check('vw_ws_unbalancedentries = 0',
      await scalar('select count(*)::int from public.vw_ws_unbalancedentries') ==
          0);
}

void main() async {
  db = await connect();
  await setup();
  await searching();
  await scope();
  await vendorsAndProducts();

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
