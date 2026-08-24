// =============================================================================
// bin/outbox_matrix.dart
//
// The 11-scenario matrix, run through the REAL WsOutbox (lib/ws_outbox.dart is
// a byte copy of the app's) against a REAL PostgreSQL 16 loaded with
// migrations 000–013.
//
// Nothing here is mocked except the transport. The poster below talks to
// Postgres directly instead of through Supabase, and can be told to behave
// like a dead network, a lost response, or a rejecting server. Everything
// else — queue state, persistence, crash recovery, ordering, retry budget —
// is the production code path.
//
// Run:  dart run bin/outbox_matrix.dart
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

import '../lib/ws_outbox.dart';
import '../lib/ws_outbox_store.dart';

// RESOLVED AT RUNTIME, never hardcoded: seed.sql mints fresh UUIDs on every
// load, so a pasted id survives exactly until the next rebuild and then fails
// as "permission denied" — which looks like a product bug and is not one.
late String uid; // an org-1 user who may post
late String noRights; // an org-1 user who may not

late Connection db;

// ── Transport faults, switchable from the test body ─────────────────────────
bool offline = false; // no network at all
bool loseResponse = false; // server commits, client never hears back
bool rejectPermanently = false; // server refuses (permission denied)

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

Future<num> scalar(String sql) async {
  final v = (await db.execute(sql)).first[0];
  if (v is num) return v;
  return num.parse('$v');
}

// ── The poster ──────────────────────────────────────────────────────────────
//
// Mirrors the classification in ws_outbox_supabase.dart: network → retryable,
// a decision the database made → permanent.

Future<WsPostResult> post(WsOutboxItem item) async {
  if (offline) {
    return const WsPostResult.network(
        'SocketException: Failed host lookup');
  }
  try {
    // rejectPermanently is applied by impersonating a user with no rights,
    // so the refusal comes from the real permission check rather than from a
    // flag inside the test.
    await db.execute("set ws.test_uid = '"
        "${rejectPermanently ? noRights : uid}'");

    final a = item.args;
    late Result r;
    switch (item.rpc) {
      case 'ws_record_delivery':
        r = await db.execute(
          Sql.named('select public.ws_record_delivery('
              'p_customerid => @c, p_deliverydate => @d::date, '
              'p_delivered => @dl, p_returned => @rt, p_productid => @p, '
              'p_amountpaid => @ap, p_paymentmethod => @pm, '
              'p_clientuuid => @u) as id'),
          parameters: {
            'c': a['p_customerid'],
            'd': a['p_deliverydate'],
            'dl': a['p_delivered'],
            'rt': a['p_returned'],
            'p': a['p_productid'],
            'ap': a['p_amountpaid'],
            'pm': a['p_paymentmethod'],
            'u': a['p_clientuuid'],
          },
        );
      case 'ws_record_payment':
        r = await db.execute(
          Sql.named('select public.ws_record_payment('
              'p_customerid => @c, p_amount => @amt, '
              'p_paymentdate => @d::date, p_paymentmethod => @pm, '
              'p_referenceno => @ref, p_notes => @n, '
              'p_clientuuid => @u) as id'),
          parameters: {
            'c': a['p_customerid'],
            'amt': a['p_amount'],
            'd': a['p_paymentdate'],
            'pm': a['p_paymentmethod'],
            'ref': a['p_referenceno'],
            'n': a['p_notes'],
            'u': a['p_clientuuid'],
          },
        );
      case 'ws_record_purchase':
        r = await db.execute(
          Sql.named('select public.ws_record_purchase('
              'p_vendorid => @v, p_lines => @l::jsonb, '
              'p_purchasedate => @d::date, p_billno => @b, p_notes => @n, '
              'p_clientuuid => @u) as id'),
          parameters: {
            'v': a['p_vendorid'],
            'l': jsonEncode(a['p_lines']),
            'd': a['p_purchasedate'],
            'b': a['p_billno'],
            'n': a['p_notes'],
            'u': a['p_clientuuid'],
          },
        );
      case 'ws_record_vendor_payment':
        r = await db.execute(
          Sql.named('select public.ws_record_vendor_payment('
              'p_vendorid => @v, p_amount => @amt, p_paiddate => @d::date, '
              'p_purchaseid => @pu, p_referenceno => @ref, p_notes => @n, '
              'p_clientuuid => @u) as id'),
          parameters: {
            'v': a['p_vendorid'],
            'amt': a['p_amount'],
            'd': a['p_paiddate'],
            'pu': a['p_purchaseid'],
            'ref': a['p_referenceno'],
            'n': a['p_notes'],
            'u': a['p_clientuuid'],
          },
        );
      default:
        return const WsPostResult.permanent('unknown rpc');
    }

    // THE INTERESTING ONE. The statement above has already COMMITTED. We
    // throw the answer away, exactly as a dropped connection would.
    if (loseResponse) {
      return const WsPostResult.network('TimeoutException after 25s');
    }

    final id = r.first[0];
    return WsPostResult.success(documentId: id is int ? id : null);
  } on ServerException catch (e) {
    const permanentCodes = {'42501', 'P0002', '23514', '23503', '22023'};
    if (permanentCodes.contains(e.code)) {
      return WsPostResult.permanent(e.message, code: e.code);
    }
    if (e.code == '23505') {
      return WsPostResult.retryable(e.message, code: e.code);
    }
    return WsPostResult.retryable(e.message, code: e.code);
  } catch (e) {
    return WsPostResult.retryable('$e');
  }
}

// ── One operation under test ────────────────────────────────────────────────

class Op {
  final String name;
  final String rpc;
  final String table;
  final String idCol;

  /// Fresh args for a given key. [variant] lets a scenario send a DIFFERENT
  /// payload under the SAME key.
  final Map<String, dynamic> Function(String uuid, int variant) args;

  /// The field a modified payload would change, read back from the server.
  final String amountExpr;

  Op(this.name, this.rpc, this.table, this.idCol, this.args, this.amountExpr);
}

Future<void> runMatrix(Op op, String storePath) async {
  print('\n═══ ${op.name.toUpperCase()} '
      '${'═' * (60 - op.name.length)}');

  offline = false;
  loseResponse = false;
  rejectPermanently = false;

  WsOutbox open() => WsOutbox(
        store: WsOutboxFileStore(storePath),
        poster: post,
        maxAutoAttempts: 8,
      );

  Future<int> rows(String u) async => (await scalar(
          "select count(*)::int from public.${op.table} where clientuuid = '$u'"))
      .toInt();

  var box = open();
  await box.load();

  // ── 1. ONLINE SAVE ──────────────────────────────────────────────────────
  print('  1. online save');
  final u1 = wsNewUuid();
  await box.enqueue(
      clientUuid: u1, rpc: op.rpc, args: op.args(u1, 1), label: 'online');
  await box.drain();
  check('reaches synced', box.byUuid(u1)!.status == WsOutboxStatus.synced);
  check('server has exactly one document', await rows(u1) == 1);
  check('document id captured', box.byUuid(u1)!.documentId != null,
      'id=${box.byUuid(u1)!.documentId}');

  // ── 2. OFFLINE SAVE ─────────────────────────────────────────────────────
  print('  2. offline save');
  offline = true;
  final u2 = wsNewUuid();
  await box.enqueue(
      clientUuid: u2, rpc: op.rpc, args: op.args(u2, 1), label: 'offline');
  await box.drain();
  check('stays pending, not lost', box.byUuid(u2)!.status == WsOutboxStatus.pending);
  check('nothing written to the server', await rows(u2) == 0);

  // A LONG OUTAGE MUST NOT FAIL A GOOD DOCUMENT. maxAutoAttempts is 8 here;
  // drain far past it and the item must still be waiting, not red.
  for (var i = 0; i < 15; i++) {
    await box.drain();
  }
  check('still pending after 15 offline drains',
      box.byUuid(u2)!.status == WsOutboxStatus.pending,
      'attempts=${box.byUuid(u2)!.attempts} '
      'budgeted=${box.byUuid(u2)!.budgetedAttempts}');
  check('no network attempt consumed the budget',
      box.byUuid(u2)!.budgetedAttempts == 0);
  check('and it is flagged as a network wait',
      box.byUuid(u2)!.lastWasNetwork);
  check('the record is on disk',
      File(storePath).readAsStringSync().contains(u2));

  // ── 3. APP RESTART WITH A PENDING ITEM ──────────────────────────────────
  print('  3. app restart while pending');
  box = open(); // a brand new WsOutbox reading the same file — a cold start
  await box.load();
  check('pending item survives restart',
      box.byUuid(u2)?.status == WsOutboxStatus.pending);
  check('payload survives intact',
      box.byUuid(u2)?.rpc == op.rpc && box.byUuid(u2)!.args.isNotEmpty);

  // ── 4. CONNECTION RESTORED → AUTOMATIC SYNC ─────────────────────────────
  print('  4. connection restored');
  offline = false;
  await box.drain();
  check('drains automatically', box.byUuid(u2)!.status == WsOutboxStatus.synced);
  check('exactly one document', await rows(u2) == 1);

  // ── 5. SAME UUID RETRY ──────────────────────────────────────────────────
  print('  5. same uuid, posted again');
  final firstId = box.byUuid(u1)!.documentId;
  box.byUuid(u1)!.status = WsOutboxStatus.pending; // force a real re-post
  await box.drain();
  check('still exactly one document', await rows(u1) == 1);
  check('same document id returned', box.byUuid(u1)!.documentId == firstId,
      '$firstId');

  // ── 6. SAME UUID, MODIFIED PAYLOAD ──────────────────────────────────────
  print('  6. same uuid, DIFFERENT payload (first write must win)');
  final amountBefore =
      await scalar("select ${op.amountExpr} from public.${op.table} "
          "where clientuuid = '$u1'");
  final it = box.byUuid(u1)!;
  it.args
    ..clear()
    ..addAll(op.args(u1, 2)); // variant 2 = different amount
  it.status = WsOutboxStatus.pending;
  await box.drain();
  final amountAfter =
      await scalar("select ${op.amountExpr} from public.${op.table} "
          "where clientuuid = '$u1'");
  check('server ignored the altered payload', amountBefore == amountAfter,
      'was $amountBefore, now $amountAfter');
  check('no second document created', await rows(u1) == 1);

  // ── 7. PERMANENT FAILURE ────────────────────────────────────────────────
  print('  7. permanent failure');
  rejectPermanently = true;
  final u3 = wsNewUuid();
  await box.enqueue(
      clientUuid: u3, rpc: op.rpc, args: op.args(u3, 1), label: 'rejected');
  await box.drain();
  check('marked failed, not pending',
      box.byUuid(u3)!.status == WsOutboxStatus.failed);
  check('error is preserved for diagnosis',
      (box.byUuid(u3)!.lastError ?? '').isNotEmpty,
      box.byUuid(u3)!.lastCode ?? '');
  check('nothing written to the server', await rows(u3) == 0);

  final attemptsAfterFail = box.byUuid(u3)!.attempts;
  await box.drain();
  check('does NOT auto-retry a permanent failure',
      box.byUuid(u3)!.attempts == attemptsAfterFail);

  // ── 8. MANUAL RETRY ─────────────────────────────────────────────────────
  print('  8. manual retry after the cause is fixed');
  rejectPermanently = false;
  final retried = await box.retry(u3);
  check('retry() accepts a failed item', retried);
  check('retry resets it to pending',
      box.byUuid(u3)!.status == WsOutboxStatus.pending);
  await box.drain();
  check('now posts successfully',
      box.byUuid(u3)!.status == WsOutboxStatus.synced);
  check('exactly one document', await rows(u3) == 1);

  // ── 9. FIFO ─────────────────────────────────────────────────────────────
  print('  9. FIFO — a retryable failure blocks what is behind it');
  offline = true;
  final a = wsNewUuid(), b = wsNewUuid(), c = wsNewUuid();
  for (final u in [a, b, c]) {
    await box.enqueue(
        clientUuid: u, rpc: op.rpc, args: op.args(u, 1), label: 'fifo');
  }
  await box.drain();
  check('first item attempted', box.byUuid(a)!.attempts >= 1);
  check('second item NOT attempted', box.byUuid(b)!.attempts == 0);
  check('third item NOT attempted', box.byUuid(c)!.attempts == 0);

  offline = false;
  final order = <String>[];
  final ordered = WsOutbox(
    store: WsOutboxFileStore(storePath),
    poster: (i) async {
      order.add(i.clientUuid);
      return post(i);
    },
  );
  await ordered.load();
  await ordered.drain();
  check('posted in creation order',
      order.indexOf(a) < order.indexOf(b) && order.indexOf(b) < order.indexOf(c),
      'order=${order.length}');
  check('all three landed once each',
      await rows(a) == 1 && await rows(b) == 1 && await rows(c) == 1);

  // ── 10. LOST RESPONSE AFTER SERVER COMMIT ───────────────────────────────
  print('  10. lost response AFTER the server committed');
  box = open();
  await box.load();
  final u4 = wsNewUuid();
  await box.enqueue(
      clientUuid: u4, rpc: op.rpc, args: op.args(u4, 1), label: 'lost');
  loseResponse = true;
  await box.drain();
  check('client believes it failed',
      box.byUuid(u4)!.status == WsOutboxStatus.pending);
  check('but the server DID commit', await rows(u4) == 1);
  check('a lost response did not consume the budget',
      box.byUuid(u4)!.budgetedAttempts == 0);

  loseResponse = false;
  await box.drain();
  check('retry resolves to synced',
      box.byUuid(u4)!.status == WsOutboxStatus.synced);
  check('STILL exactly one document — no duplicate', await rows(u4) == 1);

  // and the same thing across a process death, which is the worse version
  final u5 = wsNewUuid();
  await box.enqueue(
      clientUuid: u5, rpc: op.rpc, args: op.args(u5, 1), label: 'lost+crash');
  loseResponse = true;
  await box.drain();
  loseResponse = false;
  final afterCrash = open(); // process died, cold start
  await afterCrash.load();
  await afterCrash.drain();
  check('crash + lost response still yields one document',
      await rows(u5) == 1);
  check('and the item ends synced',
      afterCrash.byUuid(u5)!.status == WsOutboxStatus.synced);

  // ── 11. RECONCILIATION ──────────────────────────────────────────────────
  print('  11. books still balance');
  check('vw_ws_reconciliation is empty',
      await scalar('select count(*)::int from public.vw_ws_reconciliation') == 0);
  // A DELIVERY KEY LEGITIMATELY RETURNS TWO ROWS: ws_record_delivery stamps
  // the same clientuuid on the payment it creates when cash changed hands. So
  // the assertion is that the row of the RIGHT TYPE is there and resolvable —
  // which is exactly what reconcile() must select on.
  final doctype = const {
    'ws_record_delivery': 'delivery',
    'ws_record_payment': 'payment',
    'ws_record_purchase': 'purchase',
    'ws_record_vendor_payment': 'vendorpayment',
  }[op.rpc];
  check('ws_lookup_clientuuid resolves the right doctype',
      (await scalar("select count(*)::int from public.ws_lookup_clientuuid('$u4') "
              "where doctype = '$doctype'")) ==
          1);
  final serverId = (await scalar(
          "select docid from public.ws_lookup_clientuuid('$u4') "
          "where doctype = '$doctype'"))
      .toInt();
  check('and its id matches what the queue recorded',
      box.byUuid(u4)!.documentId == serverId,
      'queue=${box.byUuid(u4)!.documentId} server=$serverId');
}

// ── Entry point ─────────────────────────────────────────────────────────────

/// An active org-1 member who does ([granted]) or does not have [perm].
Future<String> _userWith(String perm, bool granted) async {
  final rows = await db.execute('''
    select m.authuserid::text
    from public.ws_tblmemberships m
    where m.orgid = 1 and m.isactive
      and ${granted ? '' : 'not '}exists (
        select 1 from public.ws_tblrolepermissions rp
        where rp.roleid = m.roleid and rp.permcode = '$perm')
    limit 1''');
  if (rows.isEmpty) {
    throw StateError('no org-1 user ${granted ? "with" : "without"} $perm — '
        'is seed.sql loaded?');
  }
  return rows.first[0] as String;
}

void main() async {
  db = await Connection.open(
    Endpoint(
        host: 'localhost',
        port: 5433,
        database: 'ws4',
        username: 'postgres',
        password: ''),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );
  uid = await _userWith('delivery.manage', true);
  noRights = await _userWith('delivery.manage', false);
  await db.execute("set ws.test_uid = '$uid'");

  final dir = await Directory.systemTemp.createTemp('ws_matrix');
  final today = DateTime.now().toIso8601String().split('T').first;

  final ops = <Op>[
    Op(
      'delivery',
      'ws_record_delivery',
      'ws_tbldeliveries',
      'deliveryid',
      (u, v) => {
        'p_customerid': 1,
        'p_deliverydate': today,
        'p_delivered': v == 1 ? 2 : 99,
        'p_returned': 1,
        'p_productid': 1,
        'p_amountpaid': v == 1 ? 100.0 : 9999.0,
        'p_paymentmethod': 'cash',
        'p_clientuuid': u,
      },
      'bottlesdelivered::float8',
    ),
    Op(
      'customer payment',
      'ws_record_payment',
      'ws_tblpayments',
      'paymentid',
      (u, v) => {
        'p_customerid': 1,
        'p_amount': v == 1 ? 250.0 : 9999.0,
        'p_paymentdate': today,
        'p_paymentmethod': 'cash',
        'p_referenceno': null,
        'p_notes': 'matrix',
        'p_clientuuid': u,
      },
      'amountreceived::float8',
    ),
    Op(
      'purchase',
      'ws_record_purchase',
      'ws_tblpurchases',
      'purchaseid',
      (u, v) => {
        'p_vendorid': 1,
        'p_lines': [
          {
            'productid': 1,
            'quantity': v == 1 ? 10 : 999,
            'unitcost': v == 1 ? 30 : 999,
          }
        ],
        'p_purchasedate': today,
        'p_billno': null,
        'p_notes': 'matrix',
        'p_clientuuid': u,
      },
      'totalamount::float8',
    ),
    Op(
      'vendor payment',
      'ws_record_vendor_payment',
      'ws_tblvendorpayments',
      'vendorpaymentid',
      (u, v) => {
        'p_vendorid': 1,
        'p_amount': v == 1 ? 500.0 : 9999.0,
        'p_paiddate': today,
        'p_purchaseid': null,
        'p_referenceno': null,
        'p_notes': 'matrix',
        'p_clientuuid': u,
      },
      'amountpaid::float8',
    ),
  ];

  for (final op in ops) {
    await runMatrix(op, '${dir.path}/${op.rpc}.json');
  }

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
  await dir.delete(recursive: true);
  exit(fail == 0 ? 0 : 1);
}
