// Audit probes: behaviours I claim in the report, executed rather than asserted
// from reading. Uses production defaults (maxAutoAttempts: 8).
import 'dart:io';
import '../lib/ws_outbox.dart';
import '../lib/ws_outbox_store.dart';

void main() async {
  final dir = await Directory.systemTemp.createTemp('audit');

  // ── PROBE 1: does a purely offline item eventually land in Failed? ──────
  var offline = true;
  final box = WsOutbox(
    store: WsOutboxFileStore('${dir.path}/a.json'),
    poster: (i) async => offline
        ? const WsPostResult.retryable('SocketException')
        : const WsPostResult.success(documentId: 1),
  ); // production defaults
  await box.load();
  final u = wsNewUuid();
  await box.enqueue(clientUuid: u, rpc: 'ws_record_delivery', args: {}, label: 'x');

  var drains = 0;
  while (box.byUuid(u)!.status != WsOutboxStatus.failed && drains < 20) {
    await box.drain();
    drains++;
  }
  print('PROBE 1  offline-only item became "${box.byUuid(u)!.status.name}" '
      'after $drains drains (attempts=${box.byUuid(u)!.attempts})');
  print('         lastError: ${box.byUuid(u)!.lastError}');
  print('         → a good delivery, failing only because there is no network,');
  print('           ends up in the red Failed list and stops trying.');

  // and it is still recoverable, not lost
  offline = false;
  await box.drain();
  print('         after reconnect + drain, without a manual retry: '
      '"${box.byUuid(u)!.status.name}"');
  await box.retry(u);
  await box.drain();
  print('         after manual retry: "${box.byUuid(u)!.status.name}"');

  // ── PROBE 2: corrupt queue file ────────────────────────────────────────
  final f = File('${dir.path}/b.json');
  final box2 = WsOutbox(
      store: WsOutboxFileStore(f.path),
      poster: (i) async => const WsPostResult.retryable('offline'));
  await box2.load();
  await box2.enqueue(
      clientUuid: wsNewUuid(), rpc: 'ws_record_delivery', args: {}, label: 'p1');
  await box2.enqueue(
      clientUuid: wsNewUuid(), rpc: 'ws_record_delivery', args: {}, label: 'p2');
  await box2.drain();
  print('\nPROBE 2  queued ${box2.items.length} pending items, file '
      '${await f.length()} bytes');

  await f.writeAsString('{ this is not json');
  final box3 = WsOutbox(
      store: WsOutboxFileStore(f.path),
      poster: (i) async => const WsPostResult.success());
  await box3.load();
  final quarantined = dir
      .listSync()
      .where((e) => e.path.contains('.corrupt.'))
      .length;
  print('         after corruption: queue has ${box3.items.length} items, '
      '$quarantined file(s) quarantined on disk');
  print('         → the bytes are preserved, but load() returns normally and');
  print('           NOTHING tells the user their pending work vanished.');

  // ── PROBE 3: is a pending item ever pruned? ────────────────────────────
  final box4 = WsOutbox(
    store: WsOutboxFileStore('${dir.path}/c.json'),
    poster: (i) async => const WsPostResult.retryable('offline'),
    keepSynced: 0,
    keepSyncedFor: Duration.zero,
  );
  await box4.load();
  final keep = wsNewUuid();
  await box4.enqueue(
      clientUuid: keep, rpc: 'ws_record_delivery', args: {}, label: 'keep');
  for (var i = 0; i < 5; i++) {
    await box4.drain();
  }
  print('\nPROBE 3  with the most aggressive pruning settings possible, the '
      'pending item is ${box4.byUuid(keep) == null ? "GONE" : "still present"}');

  await dir.delete(recursive: true);
}
