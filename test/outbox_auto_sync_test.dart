// =============================================================================
// test/outbox_auto_sync_test.dart
// The three triggers that drain the queue without anybody pressing anything.
//
// Launch blocker B1. WsOutboxService.sync() existed and worked; nothing called
// it except the Sync button, so a document whose first post failed waited for a
// human to notice. These tests exist to prove each trigger is CONNECTED — the
// mechanism was never in doubt, the wiring was.
//
// That distinction is the whole point. A seam proves the mechanism works
// without proving anybody connected it, which is exactly how the missing
// wiring survived a green suite (see ws_startup.dart's header on the GPS
// provider — the same bug, one subsystem over).
// =============================================================================

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_auto_sync.dart';

void main() {
  late int syncs;
  late StreamController<Object?> auth;
  late List<WidgetsBindingObserver> observers;
  late List<String> logs;
  var pending = 0;

  setUp(() {
    syncs = 0;
    pending = 0;
    auth = StreamController<Object?>.broadcast();
    observers = [];
    logs = [];
  });

  tearDown(() => auth.close());

  /// What WidgetsBinding does: notify only the observers that are REGISTERED.
  ///
  /// Calling didChangeAppLifecycleState directly on the object would bypass
  /// deregistration and make stop() look broken when it is not — the binding
  /// stops calling a removed observer, which is exactly what stop() relies on.
  void dispatchLifecycle(AppLifecycleState state) {
    for (final o in observers.toList()) {
      o.didChangeAppLifecycleState(state);
    }
  }

  WsOutboxAutoSync build({
    Duration interval = const Duration(minutes: 2),
    Future<void> Function()? sync,
    Stream<Object?>? authChanges,
  }) =>
      WsOutboxAutoSync(
        sync: sync ?? () async => syncs++,
        hasPendingWork: () => pending > 0,
        authChanges: authChanges ?? auth.stream,
        interval: interval,
        addObserver: observers.add,
        removeObserver: observers.remove,
        log: logs.add,
      );

  // ═══ TRIGGER 1 · AUTH ═════════════════════════════════════════════════════

  group('trigger: auth change', () {
    test('an auth event drains', () async {
      build().start();
      auth.add('signedIn');
      await Future<void>.delayed(Duration.zero);

      expect(syncs, 1);
    });

    test('drains even when the visible queue is empty', () async {
      // NOT gated on hasPendingWork, deliberately: drain() also performs
      // legacy-item adoption for the newly signed-in user, which must run
      // whether or not anything is currently pending.
      pending = 0;
      build().start();
      auth.add('signedIn');
      await Future<void>.delayed(Duration.zero);

      expect(syncs, 1, reason: 'sign-in must drain regardless of queue depth');
    });

    test('every auth event drains, including a token refresh', () async {
      // An item that failed on an expired token should be retried the moment a
      // good token arrives. Filtering to signedIn only would miss that.
      build().start();
      auth
        ..add('signedIn')
        ..add('tokenRefreshed');
      await Future<void>.delayed(Duration.zero);

      expect(syncs, 2);
    });

    test('a signed-out event is harmless', () async {
      // drain() returns early when currentUserId() is null, so this costs
      // nothing and needs no filter here. Asserted so that behaviour is a
      // decision on record rather than an accident.
      build().start();
      auth.add('signedOut');
      await Future<void>.delayed(Duration.zero);

      expect(syncs, 1, reason: 'the no-session guard lives in drain(), not here');
    });

    test('an error on the auth stream does not stop the timer', () {
      fakeAsync((async) {
        final erroring = StreamController<Object?>.broadcast();
        final a = build(
          interval: const Duration(minutes: 1),
          authChanges: erroring.stream,
        )..start();

        erroring.addError(StateError('auth backend fell over'));
        async.flushMicrotasks();

        pending = 1;
        async.elapse(const Duration(minutes: 1));

        expect(syncs, 1, reason: 'the timer survived the auth stream failing');
        expect(logs.single, contains('auth stream error'));
        a.stop();
        erroring.close();
      });
    });
  });

  // ═══ TRIGGER 2 · RESUME ═══════════════════════════════════════════════════

  group('trigger: app resume / visibility', () {
    test('registers itself as a lifecycle observer', () {
      final a = build()..start();
      expect(observers, contains(a),
          reason: 'not registered means resume can never fire');
    });

    test('resumed drains', () async {
      build().start();
      dispatchLifecycle(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(syncs, 1);
    });

    test('going away does NOT drain', () async {
      // inactive and hidden fire on the way OUT as well as the way back, and
      // paused/detached mean there is nothing to come back to yet. Draining on
      // those is a drain on the way to the background.
      build().start();
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        dispatchLifecycle(s);
      }
      await Future<void>.delayed(Duration.zero);

      expect(syncs, 0, reason: 'only `resumed` means the user is back');
    });

    test('a hide-then-show cycle drains exactly once', () async {
      build().start();
      dispatchLifecycle(AppLifecycleState.hidden);
      dispatchLifecycle(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(syncs, 1);
    });
  });

  // ═══ TRIGGER 3 · TIMER ════════════════════════════════════════════════════

  group('trigger: periodic timer', () {
    test('fires repeatedly while work is pending', () {
      fakeAsync((async) {
        pending = 1;
        final a = build(interval: const Duration(minutes: 2))..start();

        async.elapse(const Duration(minutes: 6));

        expect(syncs, 3, reason: 'three intervals elapsed');
        a.stop();
      });
    });

    test('does NOTHING while the queue is empty', () {
      fakeAsync((async) {
        pending = 0;
        final a = build(interval: const Duration(minutes: 2))..start();

        async.elapse(const Duration(hours: 4));

        expect(syncs, 0,
            reason: 'an idle app must not re-parse stored keys every tick');
        a.stop();
      });
    });

    test('notices work enqueued AFTER it started', () {
      fakeAsync((async) {
        final a = build(interval: const Duration(minutes: 2))..start();

        async.elapse(const Duration(minutes: 4));
        expect(syncs, 0);

        // A delivery is saved while the timer is already running.
        pending = 1;
        async.elapse(const Duration(minutes: 4));

        expect(syncs, 2,
            reason: 'hasPendingWork is read each tick, not captured at start');
        a.stop();
      });
    });

    test('keeps retrying across a long outage without giving up', () {
      fakeAsync((async) {
        // Network failures do not consume the attempt budget (WsOutbox.drain),
        // so a van out of coverage all morning must still be trying when it
        // gets back. The timer must not stop after a few failures.
        pending = 1;
        final a = build(
          interval: const Duration(minutes: 2),
          sync: () async {
            syncs++;
            throw const SocketExceptionLike();
          },
        )..start();

        async.elapse(const Duration(hours: 4));

        expect(syncs, 120, reason: '4h at 2min, still going');
        expect(a.isRunning, isTrue);
        a.stop();
      });
    });

    test('interval zero disables the timer entirely', () {
      fakeAsync((async) {
        pending = 1;
        final a = build(interval: Duration.zero)..start();

        async.elapse(const Duration(hours: 1));

        expect(syncs, 0);
        a.stop();
      });
    });
  });

  // ═══ REPEATED CALLS ARE SAFE ══════════════════════════════════════════════

  group('repeated and concurrent triggers', () {
    test('start() twice does not double-subscribe', () async {
      final a = build()
        ..start()
        ..start();

      auth.add('signedIn');
      await Future<void>.delayed(Duration.zero);

      expect(syncs, 1, reason: 'a second start must not double every trigger');
      expect(observers.where((o) => identical(o, a)).length, 1);
    });

    test('all three firing at once is safe', () async {
      fakeAsync((async) {
        pending = 1;
        final a = build(interval: const Duration(minutes: 2))..start();

        auth.add('signedIn');
        dispatchLifecycle(AppLifecycleState.resumed);
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();

        // Three calls reach sync(). That is correct and safe: drain() holds a
        // _draining flag and returns skippedBusy rather than running twice, so
        // no item is posted twice and no attempt counter is inflated. This
        // class deliberately adds no lock of its own.
        //
        // Order is NOT asserted — auth arrives on a microtask, resume is
        // synchronous, the timer lands on elapse. Pinning that interleaving
        // would be testing Dart's scheduler, not this wiring.
        expect(a.firedFor, unorderedEquals(['auth', 'resume', 'timer']));
        expect(syncs, 3);
        a.stop();
      });
    });

    test('a failing sync never escapes as an unhandled error', () async {
      final a = build(sync: () async => throw StateError('drain exploded'))
        ..start();

      auth.add('signedIn');
      await Future<void>.delayed(Duration.zero);

      expect(logs.single, contains('drain exploded'));
      expect(a.isRunning, isTrue, reason: 'and the wiring survives it');
    });

    test('a sync that throws synchronously is also caught', () async {
      build(sync: () => throw StateError('threw before any await')).start();

      auth.add('signedIn');
      await Future<void>.delayed(Duration.zero);

      expect(logs.single, contains('threw before any await'));
    });
  });

  // ═══ STOP ═════════════════════════════════════════════════════════════════

  group('stop', () {
    test('halts all three triggers', () {
      fakeAsync((async) {
        pending = 1;
        final a = build(interval: const Duration(minutes: 2))..start();
        async.elapse(const Duration(minutes: 2));
        expect(syncs, 1);

        a.stop();

        auth.add('signedIn');
        dispatchLifecycle(AppLifecycleState.resumed);
        async.elapse(const Duration(hours: 1));
        async.flushMicrotasks();

        expect(syncs, 1, reason: 'nothing fired after stop()');
        expect(observers, isEmpty, reason: 'and the observer was released');
      });
    });

    test('is safe when never started, and twice', () {
      final a = build();
      expect(a.stop, returnsNormally);
      a.start();
      a.stop();
      expect(a.stop, returnsNormally);
      expect(a.isRunning, isFalse);
    });

    test('start after stop works again', () async {
      final a = build()
        ..start()
        ..stop();
      a.start();

      auth.add('signedIn');
      await Future<void>.delayed(Duration.zero);

      expect(syncs, 1);
      expect(observers, contains(a));
      a.stop();
    });
  });
}

/// Stands in for a connectivity failure without importing dart:io, which has
/// no web implementation and would make this test file platform-specific.
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
  @override
  String toString() => 'SocketExceptionLike: no route to host';
}
