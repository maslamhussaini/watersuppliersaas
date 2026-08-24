// =============================================================================
// lib/screens/ws_sign_out.dart
// Signing out when the device still holds work that has not been sent.
//
// ─── WHY THIS EXISTS ─────────────────────────────────────────────────────────
//
// The outbox is durable and survives sign-out — nothing is deleted, and the
// ownership guard means a queued document is never posted under somebody else's
// session. But none of that was ever said to the user. A driver could sign out
// with a day of offline deliveries queued and see no indication at all, because
// the only place the queue is visible is the Sync Queue screen, which sits
// behind the auth gate.
//
// So this is a warning, not a mechanism. It changes nothing about what is
// stored, posted, owned or retried.
//
// ─── WHAT THE COUNT MEANS ────────────────────────────────────────────────────
//
// DEVICE-SCOPED, deliberately. pendingCount and failedCount are not filtered by
// owner, so on a shared tablet the number can include a previous driver's work.
// That is the intended reading: this device holds unsent work. A user-scoped
// count would be more flattering but can report ZERO while real work is queued,
// because an item with no owner is unowned until _adoptLegacy runs at drain
// time — and signing out does not drain. Under-reporting defeats the entire
// point of the warning; over-attributing does not.
//
// FAILED items are counted alongside pending ones. They are the ones that most
// need saying out loud: the drain skips them entirely, they are never pruned at
// any age, and they move only when a human presses Retry on the Sync Queue
// screen — which is unreachable once signed out.
//
// Quarantined records (WsOutbox.loadIssue) are NOT counted. They are
// unrecoverable rather than unsent, a sign-out prompt cannot help, and the Sync
// Queue screen already surfaces them with the file name.
//
// ─── WORDING RULES THIS FILE OBEYS ───────────────────────────────────────────
//
//   · never "you have"     — the items may not be this user's
//   · never names who will send them, or when — another user's items wait for
//     that user, so "they will send when someone signs in again" would be false
//   · failed variants omit "until it can be sent" — a failed item is not
//     waiting, it is stopped
//   · "will not delete" is literally true: AuthService.signOut() clears
//     permissions and the tenant selection and nothing else
// =============================================================================

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/outbox/ws_outbox_supabase.dart';

/// The sentence to show before signing out, or null when there is nothing to
/// say and sign-out should proceed straight away.
///
/// Pure: no context, no Supabase, no outbox, no I/O. [pending] is
/// pending + syncing, [failed] is failed. The two are disjoint, so the total is
/// their sum.
///
/// Negative inputs are not defended against. Both callers derive from `.length`
/// and the project keeps no clamping convention; anything <= 0 falls through
/// the zero branch naturally.
String? wsSignOutWarning({
  required int pending,
  required int failed,
}) {
  final total = pending + failed;
  if (total <= 0) return null;

  // FAILED ONLY. No "waiting", no "until it can be sent" — these are stopped,
  // not queued, and only a manual Retry moves them.
  if (pending <= 0) {
    return failed == 1
        ? 'This device has 1 item that needs attention before it can be '
            'sent. Signing out will not delete it — it stays on this device.'
        : 'This device has $failed items that need attention before they can '
            'be sent. Signing out will not delete them — they stay on this '
            'device.';
  }

  // PENDING ONLY.
  if (failed <= 0) {
    return pending == 1
        ? "This device has 1 item that hasn't been sent yet. Signing out will "
            'not delete it — it stays on this device until it can be sent.'
        : "This device has $pending items that haven't been sent yet. Signing "
            'out will not delete them — they stay on this device until they '
            'can be sent.';
  }

  // MIXED. The failed subset is named rather than folded into the total: it is
  // the number that decides whether to cancel and go fix something first, and
  // the Sync Queue screen is unreachable after signing out.
  return "This device has $total items that haven't been sent yet, and "
      '$failed of them ${failed == 1 ? 'needs' : 'need'} attention before '
      '${failed == 1 ? 'it' : 'they'} can be sent. Signing out will not '
      'delete them — they stay on this device.';
}

/// Confirms, then signs out.
///
/// [beforeSignOut] runs ONLY on confirmation, immediately before the sign-out
/// itself. The account sheet passes `nav.pop` to it: the sheet is a route above
/// the app's home, so signing out first would rebuild the gate into the login
/// screen and leave the sheet floating over it. Popping has to happen first,
/// and the caller is the only one that knows what to pop — which is why this is
/// a callback rather than navigation done here.
///
/// Errors from [AuthService.signOut] are deliberately NOT caught. No existing
/// caller handles them, and swallowing one here would hide a real failure while
/// silently changing behaviour.
///
/// This function owns the only call to AuthService.signOut outside main.dart —
/// see test/sign_out_warning_test.dart, which enforces that so a future screen
/// cannot quietly skip the warning.
Future<void> wsConfirmSignOut(
  BuildContext context, {
  VoidCallback? beforeSignOut,
}) async {
  final box = WsOutboxService.instanceOrNull;
  final pending = box?.pendingCount ?? 0;
  final failed = box?.failedCount ?? 0;

  final warning = wsSignOutWarning(pending: pending, failed: failed);

  // Nothing queued — or no queue at all, which is what a null box means. Either
  // way there is nothing to warn about, so do not interrupt.
  if (warning == null) {
    beforeSignOut?.call();
    await AuthService.signOut();
    return;
  }

  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Sign out?'),
      content: Text(warning),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out')),
      ],
    ),
  );

  if (yes != true) return; // Cancel, or dismissed. Nothing is touched.

  beforeSignOut?.call();
  await AuthService.signOut();
}
