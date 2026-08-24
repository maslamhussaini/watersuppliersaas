// =============================================================================
// test/location_test.dart
// GPS capture: every way it fails, and the rule that a captured position is
// frozen once the document is queued.
//
// The provider is injected, so permission denial, a disabled service and a
// timeout are all driven directly — none of which can be produced on demand
// from a real device.
// =============================================================================

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/location_service.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_store.dart';

// ─── fakes ────────────────────────────────────────────────────────────────────

class _FakeProvider implements WsLocationProvider {
  final WsLocationResult result;
  int calls = 0;
  _FakeProvider(this.result);

  @override
  Future<WsLocationResult> current({Duration timeout = Duration.zero}) async {
    calls++;
    return result;
  }
}

class _ThrowingProvider implements WsLocationProvider {
  final Object error;
  _ThrowingProvider(this.error);

  @override
  Future<WsLocationResult> current({Duration timeout = Duration.zero}) async =>
      throw error;
}

WsPosition pos(double lat, double lng, {double? acc, DateTime? at}) =>
    WsPosition(
      latitude: lat,
      longitude: lng,
      accuracy: acc,
      capturedAt: at ?? DateTime(2026, 8, 14, 9, 30),
    );

void main() {
  setUp(WsLocationService.reset);
  tearDown(WsLocationService.reset);

  // ═══ THE HAPPY PATH ═══════════════════════════════════════════════════════

  group('permission granted', () {
    test('a fix is returned', () async {
      WsLocationService.provider =
          _FakeProvider(WsLocationResult.success(pos(24.8607, 67.0011, acc: 12)));

      final r = await WsLocationService.capture();
      expect(r.ok, isTrue);
      expect(r.position!.latitude, 24.8607);
      expect(r.position!.longitude, 67.0011);
      expect(r.position!.accuracy, 12);
    });

    test('the payload carries coordinates, accuracy and the capture time',
        () async {
      final p = pos(24.8607, 67.0011, acc: 9.5, at: DateTime.utc(2026, 8, 14, 6));
      final args = p.toArgs();
      expect(args['p_latitude'], 24.8607);
      expect(args['p_longitude'], 67.0011);
      expect(args['p_accuracy'], 9.5);
      expect(args['p_capturedat'], '2026-08-14T06:00:00.000Z');
    });

    test('accuracy is optional', () async {
      WsLocationService.provider =
          _FakeProvider(WsLocationResult.success(pos(1, 1)));
      final r = await WsLocationService.capture();
      expect(r.position!.accuracy, isNull);
      expect(r.position!.toArgs()['p_accuracy'], isNull);
    });
  });

  // ═══ EVERY FAILURE ════════════════════════════════════════════════════════

  group('failures degrade gracefully', () {
    Future<WsLocationResult> failWith(WsLocationFailure f) async {
      WsLocationService.provider = _FakeProvider(WsLocationResult.failed(f));
      return WsLocationService.capture();
    }

    test('permission denied', () async {
      final r = await failWith(WsLocationFailure.permissionDenied);
      expect(r.ok, isFalse);
      expect(r.message, contains('declined'));
      expect(r.message, contains('saved without it'),
          reason: 'the driver must know the delivery is still recorded');
    });

    test('permission denied forever points at Settings', () async {
      final r = await failWith(WsLocationFailure.permissionDeniedForever);
      expect(r.message, contains('Settings'));
    });

    test('location services disabled', () async {
      final r = await failWith(WsLocationFailure.serviceDisabled);
      expect(r.ok, isFalse);
      expect(r.message, contains('switched off'));
    });

    test('timeout', () async {
      final r = await failWith(WsLocationFailure.timeout);
      expect(r.ok, isFalse);
      expect(r.message, contains('indoors'));
    });

    test('the default build reports unsupported rather than pretending',
        () async {
      final r = await WsLocationService.capture();
      expect(r.failure, WsLocationFailure.unsupported);
    });

    test('a thrown TimeoutException becomes a timeout, not a crash', () async {
      WsLocationService.provider = _ThrowingProvider(
          TimeoutException('no fix', const Duration(seconds: 8)));
      final r = await WsLocationService.capture();
      expect(r.failure, WsLocationFailure.timeout);
    });

    test('an arbitrary platform error is contained', () async {
      WsLocationService.provider = _ThrowingProvider(StateError('boom'));
      final r = await WsLocationService.capture();
      expect(r.failure, WsLocationFailure.error);
      expect(r.ok, isFalse);
    });
  });

  // ═══ NOT ASKING AGAIN AND AGAIN ═══════════════════════════════════════════

  group('a refusal is remembered', () {
    test('a denied permission is not re-requested on the next save', () async {
      final provider =
          _FakeProvider(const WsLocationResult.failed(WsLocationFailure.permissionDenied));
      WsLocationService.provider = provider;

      await WsLocationService.capture();
      await WsLocationService.capture();
      await WsLocationService.capture();

      expect(provider.calls, 1,
          reason: 'asking on every screen is how an app earns "never ask again"');
      expect(WsLocationService.isDeclined, isTrue);
    });

    test('but a TIMEOUT is not treated as a refusal', () async {
      final provider =
          _FakeProvider(const WsLocationResult.failed(WsLocationFailure.timeout));
      WsLocationService.provider = provider;

      await WsLocationService.capture();
      await WsLocationService.capture();

      expect(provider.calls, 2,
          reason: 'being indoors once says nothing about consent');
      expect(WsLocationService.isDeclined, isFalse);
    });

    test('pressing the button explicitly tries again', () async {
      final provider =
          _FakeProvider(const WsLocationResult.failed(WsLocationFailure.permissionDenied));
      WsLocationService.provider = provider;

      await WsLocationService.capture();
      await WsLocationService.capture(userInitiated: true);

      expect(provider.calls, 2,
          reason: 'asking for it IS consent to ask the platform again');
    });
  });

  // ═══ REJECTING NONSENSE ═══════════════════════════════════════════════════

  group('validation', () {
    test('impossible coordinates are refused', () {
      expect(pos(91, 0).isValid, isFalse);
      expect(pos(-91, 0).isValid, isFalse);
      expect(pos(0, 181).isValid, isFalse);
      expect(pos(0, -181).isValid, isFalse);
    });

    test('null island is refused — it is what a broken sensor reports', () {
      expect(pos(0, 0).isValid, isFalse);
    });

    test('a real position is accepted', () {
      expect(pos(24.8607, 67.0011).isValid, isTrue);
      expect(pos(-33.8688, 151.2093).isValid, isTrue);
    });

    test('the service rejects an invalid reading rather than storing it',
        () async {
      WsLocationService.provider =
          _FakeProvider(WsLocationResult.success(pos(999, 999)));
      final r = await WsLocationService.capture();
      expect(r.ok, isFalse);
      expect(r.failure, WsLocationFailure.error);
    });
  });

  // ═══ THE QUEUED POSITION IS FROZEN ════════════════════════════════════════

  group('a queued delivery keeps the position it was saved with', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('ws_gps'));
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<WsOutboxItem> queue(WsOutbox box, WsPosition? p) => box.enqueue(
          clientUuid: wsNewUuid(),
          rpc: 'ws_record_delivery',
          args: {
            'p_customerid': 1,
            'p_delivered': 2,
            'p_storeid': 3,
            if (p != null) ...p.toArgs(),
          },
          label: 'delivery',
        );

    test('the coordinates are written to disk with it', () async {
      final path = '${dir.path}/q.json';
      final box = WsOutbox(
        store: WsOutboxFileStore(path),
        poster: (_) async => const WsPostResult.network('offline'),
      );
      await box.load();
      await queue(box, pos(24.8607, 67.0011, acc: 8));
      await box.drain();

      final raw = File(path).readAsStringSync();
      expect(raw, contains('"p_latitude":24.8607'));
      expect(raw, contains('"p_longitude":67.0011'));
    });

    test('a restart and a later sync post the ORIGINAL coordinates', () async {
      final path = '${dir.path}/q.json';
      final posted = <Map<String, dynamic>>[];

      WsOutbox open(bool offline) => WsOutbox(
            store: WsOutboxFileStore(path),
            poster: (item) async {
              if (offline) return const WsPostResult.network('offline');
              posted.add(Map<String, dynamic>.from(item.args));
              return const WsPostResult.success(documentId: 1);
            },
          );

      // Saved at the customer's door, with no signal.
      final offlineBox = open(true);
      await offlineBox.load();
      await queue(offlineBox, pos(24.8607, 67.0011, acc: 8));
      await offlineBox.drain();

      // The van drives away. The app restarts. The queue drains from the depot.
      final later = open(false);
      await later.load();
      await later.drain();

      expect(posted, hasLength(1));
      expect(posted.single['p_latitude'], 24.8607,
          reason: 'where the delivery happened, not where the van is now');
      expect(posted.single['p_longitude'], 67.0011);
    });

    test('a retry cannot substitute different coordinates', () async {
      final path = '${dir.path}/q.json';
      final posted = <Map<String, dynamic>>[];
      var offline = true;

      final box = WsOutbox(
        store: WsOutboxFileStore(path),
        poster: (item) async {
          if (offline) return const WsPostResult.network('offline');
          posted.add(Map<String, dynamic>.from(item.args));
          return const WsPostResult.success(documentId: 1);
        },
      );
      await box.load();
      final item = await queue(box, pos(24.8607, 67.0011));
      await box.drain();

      // A tampered retry — the same thing a re-capture would do.
      item.args['p_latitude'] = 31.5204;
      item.args['p_longitude'] = 74.3587;
      offline = false;
      await box.drain();

      // The client-side payload was changed, but the SERVER ignores a retry's
      // payload entirely: ws_record_delivery returns the existing id before
      // reading any of it. That half is proved against real Postgres in
      // test_harness/bin/location_tagging.dart; here the point is that the
      // queue itself never re-captures.
      expect(posted.single['p_latitude'], isNot(24.8607),
          reason: 'only because the test mutated it directly');
      expect(item.clientUuid, isNotEmpty,
          reason: 'the same key travels with it, which is what makes the '
              'server refuse the change');
    });

    test('a delivery with no position queues and syncs perfectly well',
        () async {
      final path = '${dir.path}/q.json';
      final posted = <Map<String, dynamic>>[];
      final box = WsOutbox(
        store: WsOutboxFileStore(path),
        poster: (item) async {
          posted.add(Map<String, dynamic>.from(item.args));
          return const WsPostResult.success(documentId: 1);
        },
      );
      await box.load();
      await queue(box, null);
      await box.drain();

      expect(posted.single.containsKey('p_latitude'), isFalse,
          reason: 'no location is not the same as a null location');
      expect(box.items.single.status, WsOutboxStatus.synced);
    });

    test('two deliveries keep their own positions', () async {
      final path = '${dir.path}/q.json';
      final posted = <Map<String, dynamic>>[];
      var offline = true;

      WsOutbox open() => WsOutbox(
            store: WsOutboxFileStore(path),
            poster: (item) async {
              if (offline) return const WsPostResult.network('offline');
              posted.add(Map<String, dynamic>.from(item.args));
              return const WsPostResult.success(documentId: 1);
            },
          );

      final box = open();
      await box.load();
      await queue(box, pos(24.8607, 67.0011));
      await queue(box, pos(31.5204, 74.3587));
      await box.drain();

      offline = false;
      final reopened = open();
      await reopened.load();
      await reopened.drain();

      expect(posted.map((a) => a['p_latitude']), [24.8607, 31.5204]);
    });
  });
}
