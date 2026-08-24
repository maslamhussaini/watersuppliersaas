// =============================================================================
// test/startup_test.dart
// One subsystem failing must never take the others down with it.
//
// This is the test that would have caught the original bug. It could not have
// been written against the old code, because the three initialisers shared one
// try/catch and one closure — there was nothing to inject and nothing to
// observe. That is the lesson worth keeping: a seam proves the wiring WORKS,
// never that anyone DID the wiring.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/location_service.dart';
import 'package:watersuppliersaas/services/ws_startup.dart';

void main() {
  final logged = <String>[];

  setUp(() {
    logged.clear();
    WsLocationService.reset();
  });
  tearDown(WsLocationService.reset);

  Future<WsStartupReport> start({
    bool outboxFails = false,
    bool whatsNewFails = false,
    bool locationFails = false,
    List<String>? order,
  }) =>
      wsStartSubsystems(
        initOutbox: () async {
          order?.add('outbox');
          if (outboxFails) throw StateError('no path_provider on web');
        },
        initWhatsNew: () async {
          order?.add('whatsNew');
          if (whatsNewFails) throw StateError('cannot read seen file');
        },
        initLocation: () {
          order?.add('location');
          if (locationFails) throw StateError('plugin missing');
        },
        log: logged.add,
      );

  // ═══ INDEPENDENCE ═════════════════════════════════════════════════════════

  group('a failure never blocks what comes after it', () {
    test('outbox failure does not prevent What\'s New or GPS', () async {
      final order = <String>[];
      final report = await start(outboxFails: true, order: order);

      expect(order, ['outbox', 'whatsNew', 'location'],
          reason: 'THE ORIGINAL BUG: these shared one try/catch, so the first '
              'throw skipped the rest');
      expect(report.failed(WsSubsystem.outbox), isTrue);
      expect(report.failed(WsSubsystem.whatsNew), isFalse);
      expect(report.failed(WsSubsystem.location), isFalse);
    });

    test('What\'s New failure does not prevent the GPS provider', () async {
      final order = <String>[];
      final report = await start(whatsNewFails: true, order: order);

      expect(order, contains('location'));
      expect(report.failed(WsSubsystem.location), isFalse);
    });

    test('GPS failure does not prevent anything, and does not throw', () async {
      final report = await start(locationFails: true);

      expect(report.failed(WsSubsystem.location), isTrue);
      expect(report.failed(WsSubsystem.outbox), isFalse);
      expect(report.failed(WsSubsystem.whatsNew), isFalse);
    });

    test('all three failing still returns, so authentication is reachable',
        () async {
      final report = await start(
        outboxFails: true,
        whatsNewFails: true,
        locationFails: true,
      );

      expect(report.allOk, isFalse);
      expect(report.failures, hasLength(3),
          reason: 'startup must complete regardless — none of these three is '
              'required to sign in');
    });
  });

  // ═══ DIAGNOSTICS ══════════════════════════════════════════════════════════

  group('failures are surfaced, not swallowed', () {
    test('each failure is reported once, naming the consequence', () async {
      await start(outboxFails: true);

      expect(logged, hasLength(1));
      expect(logged.single, contains('outbox'));
      expect(logged.single, contains('will not be queued'),
          reason: 'a log line that does not say what the user loses is noise');
    });

    test('the old message claimed disk persistence that web does not have',
        () async {
      await start(outboxFails: true);

      expect(logged.single, isNot(contains('still on disk')),
          reason: 'the previous text asserted queued items were safe on disk '
              'on a platform with no disk');
    });

    test('a clean start says so and reports nothing', () async {
      final report = await start();

      expect(report.allOk, isTrue);
      expect(logged, isEmpty);
      expect(report.toString(), contains('all subsystems ready'));
    });

    test('the report names which subsystems are down', () async {
      final report = await start(outboxFails: true, locationFails: true);

      expect(report.toString(), contains('outbox'));
      expect(report.toString(), contains('location'));
      expect(report.toString(), isNot(contains('whatsNew')));
    });
  });

  // ═══ THE REAL PROVIDER GETS INSTALLED ═════════════════════════════════════

  group('the GPS provider is actually installed', () {
    test('the default provider reports unsupported until something wires it',
        () async {
      final result = await WsLocationService.capture();
      expect(result.failure, WsLocationFailure.unsupported,
          reason: 'this is what the app did on web for every capture, because '
              'the assignment sat behind a throwing call');
    });

    test('startup replaces it', () async {
      var installed = false;
      await wsStartSubsystems(
        initOutbox: () async {},
        initWhatsNew: () async {},
        initLocation: () => installed = true,
        log: logged.add,
      );

      expect(installed, isTrue);
    });

    test('and still replaces it when the outbox has already failed', () async {
      var installed = false;
      await wsStartSubsystems(
        initOutbox: () async => throw StateError('no web implementation'),
        initWhatsNew: () async {},
        initLocation: () => installed = true,
        log: logged.add,
      );

      expect(installed, isTrue,
          reason: 'the whole point: on web the outbox DOES fail, and GPS must '
              'still come up');
    });
  });

  // ═══ NO HARD DEPENDENCY ON path_provider ══════════════════════════════════

  test('startup completes with every storage-backed subsystem unavailable',
      () async {
    // The behavioural form of "web initialization does not depend on
    // path_provider": both storage-backed subsystems raise exactly as they do
    // on web, and startup still finishes.
    final report = await start(outboxFails: true, whatsNewFails: true);

    expect(report.failed(WsSubsystem.location), isFalse);
    expect(() => report.allOk, returnsNormally);
  });
}
