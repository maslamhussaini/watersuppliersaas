// =============================================================================
// test/outbox_auth_transport_test.dart
//
// Phase 3A — a failed token refresh is a NETWORK failure, not a dead session.
//
// ─── THE DEFECT ──────────────────────────────────────────────────────────────
//
// Before an RPC, the SDK refreshes the access token:
//     /auth/v1/token?grant_type=refresh_token
// Offline that request never leaves the browser, and gotrue converts the
// transport error into AuthRetryableFetchException (fetch.dart: `if (error is!
// Response) throw AuthRetryableFetchException(...)` — "not a Response" is
// precisely "no server ever answered").
//
// The classifier caught that as a plain AuthException and reported
// "Sign-in expired" — a SERVER-produced verdict, which consumes the attempt
// budget. Eight offline drains later the delivery sat in Failed, and because
// `pending` excludes failed items, hasPendingWork() returned false and NO
// timer, auth event or resume could reach it again. A delivery made out of
// coverage walked itself into a state only a human could escape.
//
// That is the exact outcome ws_outbox.dart's network rule exists to prevent:
// "no number of attempts makes it more wrong".
//
// ─── WHAT THESE TESTS PIN ────────────────────────────────────────────────────
//
// The type is the test, not the message. A genuinely rejected refresh token
// comes back as a real HTTP response and becomes AuthApiException, which must
// still be "Sign-in expired". Both directions are asserted, because a fix that
// swallowed real auth failures would be worse than the bug.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_store.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox_supabase.dart';

void main() {
  // ═══ 1. THE TRANSPORT FAILURE ═════════════════════════════════════════════

  group('a refresh that never reached the server', () {
    test('AuthRetryableFetchException is NETWORK', () {
      // The real message the browser produced, verbatim from the field report.
      final r = WsOutboxService.classifyPostError(
        AuthRetryableFetchException(
          message: 'ClientException: Failed to fetch, '
              'uri=https://example.supabase.co/auth/v1/token'
              '?grant_type=refresh_token',
        ),
      );

      expect(r.isNetwork, isTrue,
          reason: 'THE DEFECT: this was reported as "Sign-in expired", which '
              'spends the attempt budget and ends in Failed');
      expect(r.outcome, WsPostOutcome.retryable,
          reason: 'network IS a retryable outcome — isNetwork is the flag '
              'that exempts it from the budget, not a separate outcome');
      expect(r.error, contains('could not reach the server'));
      expect(r.error, isNot(contains('Sign-in expired')));
    });

    test('the subclass is caught, not the message', () {
      // No 'ClientException' text at all: a fix that string-matched would
      // misclassify this, and the type check is what makes it robust.
      final r = WsOutboxService.classifyPostError(
        AuthRetryableFetchException(message: 'connection closed abruptly'),
      );
      expect(r.isNetwork, isTrue);
    });
  });

  // ═══ 2. A GENUINE AUTH FAILURE IS UNCHANGED ═══════════════════════════════

  group('a session the server actually rejected', () {
    test('AuthApiException stays "Sign-in expired" and spends the budget', () {
      // What a REVOKED refresh token produces: the server answered, so gotrue
      // builds an AuthApiException with a status rather than a retryable one.
      final r = WsOutboxService.classifyPostError(
        AuthApiException('Invalid Refresh Token: Already Used',
            statusCode: '400'),
      );

      expect(r.isNetwork, isFalse,
          reason: 'a real rejection MUST still reach Failed — treating it as '
              'network would retry a dead session forever in silence');
      expect(r.outcome, WsPostOutcome.retryable);
      expect(r.error, contains('Sign-in expired'));
    });

    test('a plain AuthException also stays "Sign-in expired"', () {
      final r = WsOutboxService.classifyPostError(
        const AuthException('session missing'),
      );
      expect(r.isNetwork, isFalse);
      expect(r.error, contains('Sign-in expired'));
    });
  });

  // ═══ 3. THE BUDGET, AND 4. PENDING ELIGIBILITY ════════════════════════════
  //
  // Driven through the real WsOutbox, because the point of the fix is not the
  // label on the result — it is what the queue DOES with it.

  group('what the queue does with each classification', () {
    late WsOutbox box;
    late Object toThrow;

    Future<void> build() async {
      box = WsOutbox(
        store: WsOutboxMemoryStore(),
        poster: (_) async => WsOutboxService.classifyPostError(toThrow),
        currentUserId: () => 'driver-a',
      );
      await box.load();
      await box.enqueue(
        clientUuid: 'e008f247-1344-4ba8-910b-203d2f275f16',
        rpc: 'ws_record_delivery',
        args: const {'p_delivered': 5, 'p_returned': 3},
        label: 'QA Customer 04',
      );
    }

    test('a transport failure never spends the budget, however many drains',
        () async {
      toThrow = AuthRetryableFetchException(
          message: 'ClientException: Failed to fetch');
      await build();

      // More drains than maxAutoAttempts (8). Under the defect this is exactly
      // how the reported item reached "8 attempts / Needs attention".
      for (var i = 0; i < 12; i++) {
        await box.drain();
      }

      final it = box.byUuid('e008f247-1344-4ba8-910b-203d2f275f16')!;
      expect(it.status, WsOutboxStatus.pending,
          reason: 'offline is not the delivery\'s fault');
      expect(it.budgetedAttempts, 0,
          reason: 'THE BUDGET IS THE BUG: 8 of these turned it into Failed');
      expect(box.pendingCount, 1,
          reason: 'pendingCount > 0 is what keeps hasPendingWork() true, so '
              'the EXISTING 2-minute timer can still reach it when the '
              'network returns — no new mechanism required');
      expect(box.failedCount, 0);
    });

    test('a genuine auth rejection still reaches Failed', () async {
      toThrow = AuthApiException('Invalid Refresh Token', statusCode: '400');
      await build();

      for (var i = 0; i < 12; i++) {
        await box.drain();
      }

      final it = box.byUuid('e008f247-1344-4ba8-910b-203d2f275f16')!;
      expect(it.status, WsOutboxStatus.failed,
          reason: 'the budget must still work — this fix narrows one clause, '
              'it does not disable failure');
      expect(box.pendingCount, 0);
    });
  });

  // ═══ 5. IDENTITY AND IDEMPOTENCY ARE UNTOUCHED ════════════════════════════

  test('the clientUuid and args survive every reclassified attempt', () async {
    const uuid = 'e008f247-1344-4ba8-910b-203d2f275f16';
    const args = {'p_customerid': 46, 'p_delivered': 5, 'p_returned': 3};

    final box = WsOutbox(
      store: WsOutboxMemoryStore(),
      poster: (_) async => WsOutboxService.classifyPostError(
          AuthRetryableFetchException(message: 'ClientException: Failed')),
      currentUserId: () => 'driver-a',
    );
    await box.load();
    await box.enqueue(
        clientUuid: uuid,
        rpc: 'ws_record_delivery',
        args: args,
        label: 'QA Customer 04');

    for (var i = 0; i < 5; i++) {
      await box.drain();
    }

    final it = box.byUuid(uuid)!;
    expect(it.clientUuid, uuid,
        reason: 'idempotency rests entirely on this key being replayed '
            'unchanged — ws_record_delivery returns the existing id for it');
    expect(it.args, args, reason: 'the payload is replayed, never rebuilt');
    expect(it.rpc, 'ws_record_delivery');
  });
}
