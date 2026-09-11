// =============================================================================
// lib/services/outbox/ws_outbox_auto_sync.dart
// The three moments that make the queue drain itself.
//
// ─── THE DEFECT THIS EXISTS FOR ──────────────────────────────────────────────
//
// WsOutboxService.sync() was reachable from exactly one place: the Sync button
// on sync_screen.dart. The only other drain was the opportunistic one fired
// immediately after each enqueue. So when that single post failed — driver out
// of coverage, token expired — the document sat in the queue until a human
// thought to open the Sync Queue and press a button.
//
// Nothing was ever lost: the queue is durable, ownership-scoped, and survives
// sign-out. But a delivery the business has not been told about is a delivery
// the business cannot bill for, and "we noticed on Thursday" is not a sync
// strategy. That was launch blocker B1.
//
// ─── WHAT THIS IS NOT ────────────────────────────────────────────────────────
//
// This is WIRING, not a second sync engine. It owns no queue state, decides
// nothing about retries, and cannot post anything itself. Every call goes
// through the existing WsOutboxService.sync() → WsOutbox.drain(), so ordering,
// the network-vs-budgeted distinction, the attempt budget, ownership filtering
// and clientuuid idempotency all behave exactly as they already did.
//
// Concurrency was already handled before this file existed: drain() holds a
// _draining flag and returns WsDrainReport(skippedBusy: true) rather than
// running twice. Three triggers firing at once is therefore one drain and two
// cheap no-ops, which is why this class needs no lock of its own.
//
// ─── WHY THESE THREE ─────────────────────────────────────────────────────────
//
// auth change   A drain with no session does nothing — drain() returns early
//               when currentUserId() is null, deliberately, so a cold start
//               cannot post one driver's work under the next driver's session.
//               Sign-in is therefore the FIRST moment a queued item can legally
//               be sent. Token refresh matters for the same reason inverted: an
//               item that failed on an expired token should be retried the
//               moment a good one arrives.
//
// resume        On web this is the tab becoming visible again. A driver who
//               left the tab backgrounded in a dead zone and reopened it in
//               coverage gets a drain without touching anything.
//
// timer         The backstop for the case neither event covers: the tab stayed
//               open and focused the whole time and the connection came back on
//               its own. Nothing else would ever notice.
//
// ─── ON THE ABSENCE OF BACKOFF ───────────────────────────────────────────────
//
// The queue has an attempt BUDGET, not a time-based backoff, and network
// failures deliberately do not consume it (see WsOutbox.drain) — a van out of
// coverage all morning must not exhaust its retries and land the day's work in
// Failed. That is the right behaviour and this class does not change it.
//
// The consequence is that a fixed-interval timer would keep attempting while
// offline, inflating `attempts` — a diagnostic a human reads — without ever
// failing the item. So the timer asks [hasPendingWork] first and does nothing
// when the queue is empty, which is the overwhelmingly common case. That also
// keeps drain()'s _prune()/collectGarbage() pass off the main thread on an idle
// app, rather than re-parsing every stored key every couple of minutes.
//
// The event-driven triggers do NOT take that shortcut: sign-in also performs
// legacy-item adoption inside drain(), which must run even when the visible
// queue looks empty.
// =============================================================================

import 'dart:async';

import 'package:flutter/widgets.dart';

/// Drives [sync] from auth changes, app resume, and a periodic timer.
///
/// Every dependency is injectable. None of these three triggers can be provoked
/// from a unit test otherwise, which is precisely how the missing wiring
/// survived a green suite the first time — a seam proves the mechanism works
/// without proving anybody connected it.
class WsOutboxAutoSync with WidgetsBindingObserver {
  /// The existing drain. Returns whatever it likes; the result is ignored,
  /// because a background retry has nobody to report to.
  final Future<void> Function() sync;

  /// Auth events. Typed as `Object?` on purpose: this file must not import
  /// Supabase, or it could not be tested without one.
  final Stream<Object?>? authChanges;

  /// How often the backstop fires. Two minutes: frequent enough that a driver
  /// back in coverage syncs without noticing, slow enough that `attempts` stays
  /// a meaningful number to a human reading it.
  final Duration interval;

  /// Whether the timer has any reason to run. See the header note on backoff.
  final bool Function() hasPendingWork;

  final void Function(WidgetsBindingObserver observer) addObserver;
  final void Function(WidgetsBindingObserver observer) removeObserver;
  final void Function(String message)? log;

  StreamSubscription<Object?>? _authSub;
  Timer? _timer;
  bool _started = false;

  /// Which triggers have fired, in order. For tests and diagnostics — a count
  /// alone cannot tell "the timer fired three times" from "each trigger fired
  /// once", and those are different bugs.
  final List<String> firedFor = [];

  WsOutboxAutoSync({
    required this.sync,
    required this.hasPendingWork,
    this.authChanges,
    this.interval = const Duration(minutes: 2),
    void Function(WidgetsBindingObserver)? addObserver,
    void Function(WidgetsBindingObserver)? removeObserver,
    this.log,
  })  : addObserver =
            addObserver ?? ((o) => WidgetsBinding.instance.addObserver(o)),
        removeObserver =
            removeObserver ?? ((o) => WidgetsBinding.instance.removeObserver(o));

  bool get isRunning => _started;

  /// Idempotent. Calling it twice must not double-subscribe, or every trigger
  /// would fire two drains and the second would only ever see skippedBusy.
  void start() {
    if (_started) return;
    _started = true;

    _authSub = authChanges?.listen(
      (_) => _fire('auth'),
      // An auth stream that errors must not take the timer down with it.
      onError: (Object e) => log?.call('auto-sync: auth stream error — $e'),
    );

    addObserver(this);

    if (interval > Duration.zero) {
      _timer = Timer.periodic(interval, (_) {
        // The ONLY trigger that checks first. See the header.
        if (!hasPendingWork()) return;
        _fire('timer');
      });
    }
  }

  /// Releases everything. Safe to call when never started, and twice.
  void stop() {
    if (!_started) return;
    _started = false;

    _timer?.cancel();
    _timer = null;

    unawaited(_authSub?.cancel());
    _authSub = null;

    removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // resumed ONLY. `inactive` and `hidden` fire on the way out as well as the
    // way back, and `paused`/`detached` mean there is nothing to come back to
    // yet — draining on those would be a drain on the way to the background.
    if (state == AppLifecycleState.resumed) _fire('resume');
  }

  /// Fire and forget, and never throw.
  ///
  /// A background retry has no user waiting on it, so a failure here must not
  /// surface as an unhandled error in the zone and take down the app that the
  /// queue exists to protect. drain() classifies its own failures and records
  /// them on the item; anything reaching here is a bug in the wiring, so it is
  /// logged rather than swallowed.
  void _fire(String reason) {
    firedFor.add(reason);
    unawaited(
      Future<void>.sync(sync).catchError(
        (Object e) => log?.call('auto-sync: $reason drain failed — $e'),
      ),
    );
  }
}
