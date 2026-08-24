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

// ═══ Badge for the app bar ═══════════════════════════════════════════════════

/// Shows nothing when the queue is empty and everything is synced, an amber
/// count when work is waiting, and a red count when something failed.
class WsSyncBadge extends StatefulWidget {
  const WsSyncBadge({super.key});

  @override
  State<WsSyncBadge> createState() => _WsSyncBadgeState();
}

class _WsSyncBadgeState extends State<WsSyncBadge> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    // Rebuild whenever the queue changes. The outbox owns the truth; this
    // widget never caches a count of its own, because a stale badge that says
    // "0 pending" over a queue with three items is the failure mode here.
    _sub = WsOutboxService.instanceOrNull?.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
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

class _WsSyncScreenState extends State<WsSyncScreen> {
  StreamSubscription<void>? _sub;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _sub = WsOutboxService.instanceOrNull?.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    final messenger = ScaffoldMessenger.of(context);
    final report = await WsOutboxService.sync();
    if (!mounted) return;
    setState(() => _syncing = false);
    messenger.showSnackBar(SnackBar(
      content: Text(report.stoppedOn != null
          ? 'Stopped at "${report.stoppedOn!.label}" — still offline?'
          : '${report.posted} sent, ${report.failed} failed.'),
    ));
  }

  Future<void> _retry(WsOutboxItem item) async {
    final box = WsOutboxService.instanceOrNull;
    if (box == null) return;
    final messenger = ScaffoldMessenger.of(context);

    // BEFORE re-posting, ASK THE SERVER whether it already has it. A read,
    // never a write. After a long outage the server may already agree with us,
    // and reconciling is both faster and safer than another post.
    final reconciled = await WsOutboxService.reconcile(item.clientUuid);
    if (reconciled) {
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('Already on the server — marked as synced.'),
      ));
      return;
    }

    await box.retry(item.clientUuid);
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
          ..sort((a, b) => b.seq.compareTo(a.seq)));

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
