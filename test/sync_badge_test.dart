// =============================================================================
// test/sync_badge_test.dart
//
// The badge must repaint when the queue changes — including when the change
// arrives mid-frame.
//
// ─── THE BUG ─────────────────────────────────────────────────────────────────
//
//     _sub = box.changes.listen((_) { if (mounted) setState(() {}); });
//
// `mounted` guards a DISPOSED widget. It does not guard the other failure:
// setState called while a frame is already being built, which throws
// "setState() or markNeedsBuild() called during build".
//
// That is reachable on the ordinary success path. A save calls
// navigator.pop(true) while the drain is still running, so the `synced`
// notification lands exactly as the screen underneath rebuilds. The listener
// callback has no error handling, so the throw escapes to the zone as an
// uncaught error — and the rebuild it was meant to do never happens. The badge
// then keeps the pre-sync count over a fully synced queue.
//
// ─── WHAT THESE TESTS DO AND DO NOT PROVE ────────────────────────────────────
//
// HONEST LIMITATION, recorded because it changes what this file is worth.
//
// A mutation check was run: the safe rebuild below was replaced with the naive
// `setState(() {})` and the suite STILL PASSED. So these tests do not
// reproduce the production defect, and they would not catch its return.
//
// That is evidence against the hypothesis, not just a weak test. `_changes` is
// a `StreamController.broadcast()` with the default `sync: false`, so an event
// is delivered on a microtask — and microtasks cannot interleave into Flutter's
// synchronous build phase. A stream-driven setState therefore has little
// opportunity to land mid-build, and "setState called during build" may not be
// what the live Uncaught Error was at all.
//
// What this file DOES establish:
//   · the badge tracks the queue and clears when the item syncs (the reported
//     stale-badge symptom would be caught here);
//   · deferring a rebuild does not lose the update;
//   · a notification after dispose is ignored.
//
// The mixin in sync_screen.dart is therefore DEFENSIVE hardening, not a proven
// fix for the observed exception. The catchError guards added to the drain
// paths are what will identify the real cause: the next occurrence logs a named
// failure instead of a bare, undiagnosable "Uncaught Error".
//
// The badge itself is driven by WsOutboxService (static, needs Supabase), so
// these tests exercise the same listen/rebuild contract against a real
// WsOutbox and a widget that uses the identical pattern.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_store.dart';

/// The production pattern from `_WsQueueRebuild` in sync_screen.dart.
class _Badge extends StatefulWidget {
  final WsOutbox box;
  final List<String> logs;

  /// Forces a notification to arrive while this widget is building, which is
  /// what a pop-then-sync produces in the real app.
  final bool notifyDuringBuild;

  const _Badge(this.box, this.logs, {this.notifyDuringBuild = false});

  @override
  State<_Badge> createState() => _BadgeState();
}

class _BadgeState extends State<_Badge> {
  StreamSubscription<void>? _sub;
  int builds = 0;

  @override
  void initState() {
    super.initState();
    _sub = widget.box.changes.listen(
      (_) => _rebuildSafely(),
      onError: (Object e) => widget.logs.add('stream error — $e'),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _rebuildSafely() {
    if (!mounted) return;
    try {
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      } else {
        setState(() {});
      }
    } catch (e) {
      widget.logs.add('rebuild failed — $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    if (widget.notifyDuringBuild && builds == 1) {
      // A queue change landing mid-build. Before the fix this threw.
      _rebuildSafely();
    }
    final failed = widget.box.failedCount;
    final pending = widget.box.pendingCount;
    final count = failed > 0 ? failed : pending;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(count == 0 ? 'clear' : '$count', key: const Key('badge')),
    );
  }
}

void main() {
  late WsOutbox box;
  late List<String> logs;

  setUp(() {
    logs = [];
  });

  Future<WsOutboxItem> queue(String uuid) => box.enqueue(
        clientUuid: uuid,
        rpc: 'ws_record_delivery',
        args: {'p_customerid': 1, 'p_delivered': 2},
        label: '2 out — Hotel ABC',
      );

  String badge(WidgetTester t) =>
      t.widget<Text>(find.byKey(const Key('badge'))).data!;

  // ═══ 5 · pending → 0 WHEN THE ITEM SYNCS ══════════════════════════════════

  testWidgets('5. the badge goes to clear once the item is synced', (t) async {
    var succeed = false;
    box = WsOutbox(
      store: WsOutboxMemoryStore(),
      poster: (_) async => succeed
          ? const WsPostResult.success(documentId: 1)
          : const WsPostResult.network('offline'),
    );
    await box.load();
    await queue('a');

    await t.pumpWidget(_Badge(box, logs));
    await t.pumpAndSettle();
    expect(badge(t), '1', reason: 'one item waiting');

    succeed = true;
    await box.drain();
    await t.pumpAndSettle();

    expect(badge(t), 'clear',
        reason: 'THE STALE BADGE: it kept showing 1 over a synced queue, '
            'because the rebuild that would have cleared it threw');
    expect(logs, isEmpty);
  });

  testWidgets('a failed item shows its own count', (t) async {
    box = WsOutbox(
      store: WsOutboxMemoryStore(),
      poster: (_) async => const WsPostResult.permanent('refused'),
    );
    await box.load();
    await queue('a');

    await t.pumpWidget(_Badge(box, logs));
    await box.drain();
    await t.pumpAndSettle();

    expect(badge(t), '1');
    expect(box.failedCount, 1);
  });

  // ═══ 4 · A NOTIFICATION DURING BUILD MUST NOT THROW ═══════════════════════

  // NOTE: this does NOT reproduce the production defect — see the header. It
  // pins the deferral path's behaviour, nothing stronger.
  testWidgets('4. the deferral path rebuilds without throwing', (t) async {
    box = WsOutbox(
      store: WsOutboxMemoryStore(),
      poster: (_) async => const WsPostResult.network('offline'),
    );
    await box.load();
    await queue('a');

    await t.pumpWidget(_Badge(box, logs, notifyDuringBuild: true));
    await t.pumpAndSettle();

    expect(takenException(t), isNull);
    expect(logs, isEmpty, reason: 'deferred cleanly — nothing to report');
    expect(badge(t), '1');
  });

  testWidgets('and the deferred rebuild still shows the CURRENT state',
      (t) async {
    // Deferring must not mean losing the update.
    box = WsOutbox(
      store: WsOutboxMemoryStore(),
      poster: (_) async => const WsPostResult.success(documentId: 2),
    );
    await box.load();
    await queue('a');

    await t.pumpWidget(_Badge(box, logs, notifyDuringBuild: true));
    await t.pumpAndSettle();
    expect(badge(t), '1');

    await box.drain();
    await t.pumpAndSettle();

    expect(badge(t), 'clear');
    expect(takenException(t), isNull);
  });

  // ═══ A DISPOSED WIDGET IS STILL SAFE ══════════════════════════════════════

  testWidgets('a notification after dispose is ignored', (t) async {
    box = WsOutbox(
      store: WsOutboxMemoryStore(),
      poster: (_) async => const WsPostResult.network('offline'),
    );
    await box.load();

    await t.pumpWidget(_Badge(box, logs));
    await t.pumpWidget(const SizedBox());
    await queue('a'); // notifies a widget that no longer exists
    await t.pumpAndSettle();

    expect(takenException(t), isNull);
    expect(logs, isEmpty);
  });
}

/// The exception the framework captured this frame, if any.
Object? takenException(WidgetTester t) => t.takeException();
