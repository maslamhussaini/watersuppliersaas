// =============================================================================
// lib/screens/whats_new_screen.dart
// What changed, grouped by release.
//
// Two ways in: shown once automatically after an upgrade, and always available
// from the account menu. The automatic one marks itself seen when dismissed —
// including by the back button, because a user who has read enough and swiped
// away has still seen it and should not be shown the same thing tomorrow.
// =============================================================================

import 'package:flutter/material.dart';

import '../services/whats_new.dart';
import '../theme/ws_responsive.dart';
import '../theme/ws_theme.dart';

class WsWhatsNewScreen extends StatelessWidget {
  /// The releases to show. Passing only the unseen ones makes this the
  /// "what changed since you were last here" view; passing everything makes it
  /// the full history.
  final List<WsRelease> releases;

  /// Whether these are the highlights of an upgrade, which changes the wording
  /// and the button.
  final bool isUpgrade;

  const WsWhatsNewScreen({
    super.key,
    required this.releases,
    this.isUpgrade = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isUpgrade ? "What's new" : 'Release notes'),
        flexibleSpace: const WsGradientBar(),
      ),
      body: WsMaxWidth(
        maxWidth: 720,
        child: releases.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('No release notes yet.',
                      style: TextStyle(color: WsColors.text2)),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                itemCount: releases.length + (isUpgrade ? 1 : 0),
                itemBuilder: (context, i) {
                  if (isUpgrade && i == 0) return _intro(context);
                  return _releaseCard(releases[isUpgrade ? i - 1 : i]);
                },
              ),
      ),
      bottomNavigationBar: releases.isEmpty
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(isUpgrade ? 'Got it' : 'Close'),
              ),
            ),
    );
  }

  Widget _intro(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            releases.length == 1
                ? 'One update since you were last here'
                : '${releases.length} updates since you were last here',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            'Everything below is already active — there is nothing to install.',
            style: TextStyle(color: WsColors.text2),
          ),
        ]),
      );

  Widget _releaseCard(WsRelease r) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(r.title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: WsColors.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('v${r.version}',
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: WsColors.primary)),
              ),
            ]),
            const SizedBox(height: 3),
            Row(children: [
              Text(_formatDate(r.date),
                  style:
                      const TextStyle(fontSize: 12, color: WsColors.text2)),
              if (r.category != null) ...[
                const Text('  ·  ',
                    style: TextStyle(fontSize: 12, color: WsColors.text2)),
                Text(r.category!,
                    style: const TextStyle(
                        fontSize: 12,
                        color: WsColors.text2,
                        fontWeight: FontWeight.w600)),
              ],
            ]),
            const SizedBox(height: 12),
            for (final change in r.changes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child:
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 5, right: 9),
                    child: Icon(Icons.circle, size: 6, color: WsColors.primary),
                  ),
                  Expanded(
                      child: Text(change,
                          style: const TextStyle(height: 1.4, fontSize: 13.5))),
                ]),
              ),
            if (r.actionRequired != null) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: WsColors.amber.withValues(alpha: 0.10),
                  border: Border(
                      left: BorderSide(color: WsColors.amber, width: 3)),
                ),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline,
                          size: 16, color: WsColors.amber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(r.actionRequired!,
                            style: const TextStyle(
                                fontSize: 12.5, height: 1.35)),
                      ),
                    ]),
              ),
            ],
          ]),
        ),
      );

  static String _formatDate(DateTime d) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

/// Shows the upgrade highlights if there are any, then marks them seen.
///
/// Marking happens whichever way the screen is left — button, back gesture or
/// system back — because a user who dismissed it has seen it, and showing the
/// same notes again on the next launch is the fastest way to make a welcome
/// feature annoying.
Future<void> wsShowWhatsNewIfNeeded(BuildContext context) async {
  final service = WsWhatsNew.instanceOrNull;
  if (service == null) return;

  final unseen = await service.unseen();
  if (unseen.isEmpty || !context.mounted) return;

  await Navigator.of(context).push(MaterialPageRoute<bool>(
    builder: (_) => WsWhatsNewScreen(releases: unseen, isUpgrade: true),
  ));
  await service.markSeen();
}
