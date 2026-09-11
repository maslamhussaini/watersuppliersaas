// =============================================================================
// lib/screens/sync_screen.dart
// The queue, made visible: a badge, a list, an error, a Retry button.
//
// ─── THE RULE THIS SCREEN EXISTS TO ENFORCE ──────────────────────────────────
//
// A queued delivery must NEVER look like a posted one, and a failed delivery
// must never look like either. The most dangerous version of offline support
// is the one that says "Saved!" and quietly drops the document — the driver
// has already walked away.
//
// So:
//   Pending   amber   "waiting to sync"     — saved here, not on the server yet
//   Syncing   blue    "sending…"
//   Synced    green   shows the SERVER document number
//   Failed    red     shows the error and needs a human
//
// The badge is only shown when there is something to say. A permanent green
// tick trains people to ignore it.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';

import '../services/outbox/ws_outbox.dart';
import '../services/outbox/ws_outbox_supabase.dart';
import '../theme/ws_responsive.dart';
import '../theme/ws_theme.dart';

final _stamp = DateFormat('dd MMM, HH:mm');

Color wsSyncColor(WsOutboxStatus s) => switch (s) {
      WsOutboxStatus.pending => WsColors.amber,
      WsOutboxStatus.syncing => WsColors.primaryLight,
      WsOutboxStatus.synced => WsColors.green,
      WsOutboxStatus.failed => WsColors.red,
    };

IconData wsSyncIcon(WsOutboxStatus s) => switch (s) {
      WsOutboxStatus.pending => Icons.schedule,
      WsOutboxStatus.syncing => Icons.sync,
      WsOutboxStatus.synced => Icons.cloud_done_outlined,
      WsOutboxStatus.failed => Icons.error_outline,
    };

String wsSyncLabel(WsOutboxStatus s) => switch (s) {
      WsOutboxStatus.pending => 'Waiting to sync',
      WsOutboxStatus.syncing => 'Sending…',
      WsOutboxStatus.synced => 'Synced',
      WsOutboxStatus.failed => 'Needs attention',
    };

// ═══ Rebuilding safely when the queue changes ════════════════════════════════

/// Subscribes to [WsOutbox.changes] and rebuilds, without ever throwing.
///
/// ─── THE BUG THIS EXISTS FOR ─────────────────────────────────────────────────
///
/// Both widgets below used to do this directly:
///
///     _sub = box.changes.listen((_) { if (mounted) setState(() {}); });
///
/// `mounted` guards a DISPOSED widget. It does not guard the other way a
/// setState fails: being called while a frame is already being built, which
/// throws "setState() or markNeedsBuild() called during build".
///
/// That is reachable on the ordinary success path. A save calls
/// navigator.pop(true) while the drain is still running, so the `synced`
/// notification lands exactly as the screen underneath is rebuilding. A
/// listener callback has no error handling of its own, so the throw escapes to
/// the zone as an uncaught error — and, worse, the rebuild it was supposed to
/// perform never happens. The badge then keeps showing the pre-sync count over
/// a queue that is fully synced, which is precisely the stale badge that was
/// reported.
///
/// So: if a frame is in flight, defer to just after it. Otherwise rebuild now.
/// Errors are logged rather than swallowed — a UI that cannot repaint is worth
/// knowing about, but it must never take the app down with it.
mixin _WsQueueRebuild<T extends StatefulWidget> on State<T> {
  StreamSubscription<void>? _queueSub;

  /// Names this listener in any log line, so two identical messages from two
  /// widgets remain distinguishable.
  String get debugWho;

  void startListeningToQueue() {
    _queueSub = WsOutboxService.instanceOrNull?.changes.listen(
      (_) => _rebuildSafely(),
      // Guards an error ON the stream. A throw INSIDE the callback is handled
      // by the try/catch below — onError does not see those.
      onError: (Object e) => debugPrint('$debugWho: queue stream error — $e'),
    );
  }

  void stopListeningToQueue() {
    _queueSub?.cancel();
    _queueSub = null;
  }

  void _rebuildSafely() {
    if (!mounted) return;
    try {
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        // A frame is being built right now; setState would throw. Repaint on
        // the very next frame instead — the queue state is already correct, so
        // nothing is lost by showing it one frame later.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      } else {
        setState(() {});
      }
    } catch (e) {
      debugPrint('$debugWho: rebuild after a queue change failed — $e');
    }
  }
}

// ═══ Badge for the app bar ═══════════════════════════════════════════════════

/// Shows nothing when the queue is empty and everything is synced, an amber
/// count when work is waiting, and a red count when something failed.
class WsSyncBadge extends StatefulWidget {
  const WsSyncBadge({super.key});

  @override
  State<WsSyncBadge> createState() => _WsSyncBadgeState();
}

class _WsSyncBadgeState extends State<WsSyncBadge>
    with _WsQueueRebuild<WsSyncBadge> {
  @override
  String get debugWho => 'sync badge';

  @override
  void initState() {
    super.initState();
    // Rebuild whenever the queue changes. The outbox owns the truth; this
    // widget never caches a count of its own, because a stale badge that says
    // "0 pending" over a queue with three items is the failure mode here.
    startListeningToQueue();
  }

  @override
  void dispose() {
    stopListeningToQueue();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = WsOutboxService.instanceOrNull;
    if (box == null) return const SizedBox.shrink();

    final failed = box.failedCount;
    final pending = box.pendingCount;
    if (failed == 0 && pending == 0) return const SizedBox.shrink();

    final color = failed > 0 ? WsColors.red : WsColors.amber;
    final count = failed > 0 ? failed : pending;

    return IconButton(
      tooltip: failed > 0
          ? '$failed item${failed == 1 ? '' : 's'} need attention'
          : '$pending item${pending == 1 ? '' : 's'} waiting to sync',
      onPressed: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const WsSyncScreen())),
      icon: Stack(clipBehavior: Clip.none, children: [
        Icon(failed > 0 ? Icons.cloud_off : Icons.cloud_upload_outlined),
        Positioned(
          right: -4,
          top: -4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white, width: 1),
            ),
            constraints: const BoxConstraints(minWidth: 15),
            child: Text('$count',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }
}

// ═══ Inline chip, for a delivery row ═════════════════════════════════════════

class WsSyncChip extends StatelessWidget {
  final WsOutboxStatus status;
  final String? documentNumber;

  const WsSyncChip({super.key, required this.status, this.documentNumber});

  @override
  Widget build(BuildContext context) {
    final c = wsSyncColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(wsSyncIcon(status), size: 12, color: c),
        const SizedBox(width: 5),
        Text(
          status == WsOutboxStatus.synced && documentNumber != null
              ? documentNumber!
              : wsSyncLabel(status),
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: c),
        ),
      ]),
    );
  }
}

// ═══ The queue screen ════════════════════════════════════════════════════════

class WsSyncScreen extends StatefulWidget {
  const WsSyncScreen({super.key});

  @override
  State<WsSyncScreen> createState() => _WsSyncScreenState();
}

class _WsSyncScreenState extends State<WsSyncScreen>
    with _WsQueueRebuild<WsSyncScreen> {
  bool _syncing = false;

  @override
  String get debugWho => 'sync queue';

  @override
  void initState() {
    super.initState();
    startListeningToQueue();
  }

  @override
  void dispose() {
    stopListeningToQueue();
    super.dispose();
  }

  /// ─── WHY THIS IS WRAPPED ─────────────────────────────────────────────────
  ///
  /// This is invoked from `onPressed:`, which takes a VoidCallback. An async
  /// function called there is FIRE AND FORGET: nobody holds the returned
  /// future, so a throw from WsOutboxService.sync() becomes an unhandled async
  /// error — a bare "Uncaught Error" with no Dart context in a release build.
  ///
  /// That is the same defect that was just closed on the five drain call sites
  /// in ws_outbox_supabase.dart. Guarding those and leaving the Sync button
  /// unguarded would mean the one path a user takes *when something is already
  /// wrong* is the one that fails silently.
  ///
  /// The button also spins. Without a `finally` a throw would leave _syncing
  /// true forever, so the control disables itself permanently and the only way
  /// to sync again is to reopen the screen.
  ///
  /// Nothing about the sync itself changes here: no status transitions, no
  /// retry budget, no idempotency, no algorithm. Only what happens to an
  /// exception that previously had nowhere to go.
  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final report = await WsOutboxService.sync();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(report.stoppedOn != null
            ? 'Stopped at "${report.stoppedOn!.label}" — still offline?'
            : '${report.posted} sent, ${report.failed} failed.'),
      ));
    } catch (e) {
      // Reported twice on purpose: to the log for diagnosis, and to the user,
      // who pressed a button and is owed an answer. Never swallowed — a Sync
      // that quietly does nothing is indistinguishable from one that worked.
      debugPrint('sync_screen: manual sync failed — $e');
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Could not sync: $e'),
        backgroundColor: WsColors.red,
        duration: const Duration(seconds: 6),
      ));
    } finally {
      // The queue is untouched by any of this — nothing was lost, and the next
      // drain picks it up. Only the spinner needs resetting.
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// Wrapped for the same reason as [_syncNow] — invoked from a button, so an
  /// exception has nobody to return to.
  ///
  /// The reconcile step makes this MORE exposed than a plain retry, not less:
  /// it is a network read that can fail on its own, before anything has been
  /// re-posted. An unhandled throw there would leave a Failed item looking
  /// untouched with no explanation.
  ///
  /// Retry classification and the outbox's own logic are unchanged; this only
  /// decides what the user is told when the attempt cannot even be made.
  Future<void> _retry(WsOutboxItem item) async {
    final box = WsOutboxService.instanceOrNull;
    if (box == null) return;
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _syncing = true);
    try {
      // BEFORE re-posting, ASK THE SERVER whether it already has it. A read,
      // never a write. After a long outage the server may already agree with
      // us, and reconciling is both faster and safer than another post.
      final reconciled = await WsOutboxService.reconcile(item.clientUuid);
      if (reconciled) {
        if (!mounted) return;
        messenger.showSnackBar(const SnackBar(
          content: Text('Already on the server — marked as synced.'),
        ));
        return;
      }

      await box.retry(item.clientUuid);
    } catch (e) {
      debugPrint('sync_screen: retry failed — $e');
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Could not retry: $e'),
        backgroundColor: WsColors.red,
        duration: const Duration(seconds: 6),
      ));
      return;
    } finally {
      if (mounted) setState(() => _syncing = false);
    }

    // OUTSIDE the try: _syncNow owns its own error handling, and nesting it
    // here would report a sync failure as a retry failure.
    await _syncNow();
  }

  Future<void> _discard(WsOutboxItem item) async {
    final box = WsOutboxService.instanceOrNull;
    if (box == null) return;

    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this document?'),
        content: Text(
          '"${item.label}" will be deleted from this device and never sent.\n\n'
          'Only do this if the delivery did not actually happen — there is no '
          'way to get it back.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard',
                style: TextStyle(color: WsColors.red)),
          ),
        ],
      ),
    );
    if (yes == true) await box.discard(item.clientUuid);
  }

  @override
  Widget build(BuildContext context) {
    final box = WsOutboxService.instanceOrNull;
    // OWNER-SCOPED. This used to render box.items raw, which on a shared
    // tablet showed one driver another driver's customer names and amounts —
    // and let them discard that work permanently. visibleTo() applies the same
    // rule the drain uses: nothing without a session, and unowned items stay
    // visible because _adoptLegacy will claim them on the next drain.
    //
    // The sign-out warning's counts are deliberately NOT scoped this way; that
    // is a separate, settled decision.
    final items = box == null
        ? <WsOutboxItem>[]
        : (box.visibleToCurrentUser.toList()
          ..sort((a, b) => wsOutboxOrder(b, a)));   // newest first, total order

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Queue'),
        flexibleSpace: const WsGradientBar(),
        actions: [
          IconButton(
            tooltip: 'Sync now',
            icon: _syncing
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.sync),
            onPressed: _syncing ? null : _syncNow,
          ),
        ],
      ),
      // The banner sits ABOVE the empty state on purpose. A damaged queue file
      // that salvaged nothing shows an empty list, and "Nothing waiting to
      // sync" on its own is exactly the false reassurance this warning exists
      // to prevent.
      body: Column(children: [
        _corruptBanner(),
        Expanded(
          child: items.isEmpty
              ? const WsEmptyState(
                  icon: Icons.cloud_done_outlined,
                  message: 'Nothing waiting to sync.',
                  hint: 'Deliveries recorded offline appear here until they '
                      'reach the server.',
                )
              : WsMaxWidth(
                  maxWidth: 720,
                  child: ListView.separated(
                    padding: WsBreakpoints.pagePadding(context),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _tile(items[i]),
                  ),
                ),
        ),
      ]),
    );
  }

  /// Shown when the queue file could not be read at startup.
  ///
  /// Names the file, because the whole point of keeping the corrupt bytes is
  /// that somebody can go and get them.
  Widget _corruptBanner() {
    final issue = WsOutboxService.loadIssue;
    if (issue == null) return const SizedBox.shrink();

    final lost = issue.unrecoverable;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: WsColors.red.withValues(alpha: 0.08),
        border: Border.all(color: WsColors.red),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.warning_amber_rounded, color: WsColors.red, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              lost == 0
                  ? 'The sync queue file was damaged and repaired.'
                  : 'The sync queue file was damaged. '
                      '$lost record${lost == 1 ? '' : 's'} could not be read.',
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: WsColors.red),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          '${issue.salvaged} recovered and still queued. The original file was '
          'kept — do not delete it if anything is missing:',
          style: const TextStyle(fontSize: 12, color: WsColors.text2),
        ),
        const SizedBox(height: 4),
        SelectableText(
          issue.quarantinePath,
          style: const TextStyle(
              fontSize: 11, fontFamily: 'monospace', color: WsColors.text2),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () {
              WsOutboxService.acknowledgeLoadIssue();
              setState(() {});
            },
            child: const Text('Dismiss'),
          ),
        ),
      ]),
    );
  }

  Widget _tile(WsOutboxItem item) {
    final c = wsSyncColor(item.status);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(wsSyncIcon(item.status), size: 18, color: c),
            const SizedBox(width: 10),
            Expanded(
              child: Text(item.label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            WsSyncChip(
              status: item.status,
              documentNumber:
                  item.documentId == null ? null : '#${item.documentId}',
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            'Created ${_stamp.format(item.createdAt)}'
            '${item.attempts > 0 ? ' · ${item.attempts} attempt'
                '${item.attempts == 1 ? '' : 's'}' : ''}'
            '${item.syncedAt != null ? ' · sent ${_stamp.format(item.syncedAt!)}' : ''}',
            style: const TextStyle(fontSize: 11, color: WsColors.text2),
          ),

          // The idempotency key, on screen. This is what ties a row here to a
          // row in Postgres and a line in the logs, and it is the first thing
          // anyone will ask for when a document goes missing.
          const SizedBox(height: 4),
          SelectableText(
            item.clientUuid,
            style: const TextStyle(
                fontSize: 10, color: WsColors.text3, fontFamily: 'monospace'),
          ),

          if (item.lastError != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: WsColors.red.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${item.lastCode != null ? '[${item.lastCode}] ' : ''}'
                '${item.lastError}',
                style: const TextStyle(fontSize: 11, color: WsColors.red),
              ),
            ),
          ],

          if (item.status == WsOutboxStatus.failed) ...[
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: () => _discard(item),
                child: const Text('Discard',
                    style: TextStyle(color: WsColors.text2, fontSize: 13)),
              ),
              const SizedBox(width: 4),
              ElevatedButton.icon(
                onPressed: () => _retry(item),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    visualDensity: VisualDensity.compact),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}
