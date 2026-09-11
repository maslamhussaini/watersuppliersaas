// =============================================================================
// test/offline_banner_test.dart
//
// The two degradations that must never be silent.
//
// ─── WHY BOTH, AND WHY SEPARATELY ────────────────────────────────────────────
//
// They are independent, and neither implies the other:
//
//   · wsUsingOfflineSession — the app is running on the saved session snapshot
//     because the server could not be reached.
//   · wsOfflineCustomerSearchUnavailable — customer search is online only. This
//     can be true while the app is perfectly ONLINE, because an organization
//     over the 25,000 ceiling is refused a cache during an ordinary refresh.
//
// A driver who does not know offline customer search is unavailable will search,
// find nothing, and conclude the customer does not exist. That is the failure
// this banner exists to prevent, and it is why the ceiling message is not
// folded into the offline message.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/main.dart';
import 'package:watersuppliersaas/services/cache/ws_customer_cache.dart';

void main() {
  setUp(() {
    wsUsingOfflineSession.value = false;
    wsOfflineCustomerSearchUnavailable.value = null;
  });

  tearDown(() {
    wsUsingOfflineSession.value = false;
    wsOfflineCustomerSearchUnavailable.value = null;
  });

  Future<void> pump(WidgetTester t) => t.pumpWidget(const MaterialApp(
        home: WsOfflineSessionBanner(
          child: Scaffold(body: Text('dashboard')),
        ),
      ));

  Finder strips() => find.byIcon(Icons.cloud_off);

  testWidgets('online and cached: nothing is shown', (t) async {
    await pump(t);

    expect(strips(), findsNothing);
    expect(find.text('dashboard'), findsOneWidget,
        reason: 'the ordinary case must gain no wrapper at all');
  });

  testWidgets('offline session shows its own message', (t) async {
    wsUsingOfflineSession.value = true;
    await pump(t);

    expect(strips(), findsOneWidget);
    expect(find.textContaining('account details saved on this device'),
        findsOneWidget);
    expect(find.text('dashboard'), findsOneWidget,
        reason: 'the app stays usable underneath');
  });

  testWidgets('the customer-cache reason is shown even while ONLINE',
      (t) async {
    // The ceiling case: 25,001 customers refuses the cache during a perfectly
    // successful online refresh.
    wsOfflineCustomerSearchUnavailable.value =
        'This organization has more than 25000 customers, so customer search '
        'is online only.';
    await pump(t);

    expect(strips(), findsOneWidget);
    expect(find.textContaining('online only'), findsOneWidget);
    expect(find.textContaining('account details saved'), findsNothing,
        reason: 'the session is fine — saying otherwise would be false');
  });

  testWidgets('both conditions show both messages, not a merged one',
      (t) async {
    wsUsingOfflineSession.value = true;
    wsOfflineCustomerSearchUnavailable.value =
        'Customer data could not be saved for offline use, so customer search '
        'is online only.';
    await pump(t);

    expect(strips(), findsNWidgets(2));
    expect(find.textContaining('account details saved'), findsOneWidget);
    expect(find.textContaining('online only'), findsOneWidget);
  });

  testWidgets('it reacts to a change after the first build', (t) async {
    await pump(t);
    expect(strips(), findsNothing);

    wsOfflineCustomerSearchUnavailable.value = 'search is online only.';
    await t.pumpAndSettle();

    expect(strips(), findsOneWidget,
        reason: 'the ceiling is discovered during a refresh, long after the '
            'dashboard first built');
  });

  testWidgets('it clears when the condition resolves', (t) async {
    wsUsingOfflineSession.value = true;
    wsOfflineCustomerSearchUnavailable.value = 'search is online only.';
    await pump(t);
    expect(strips(), findsNWidgets(2));

    // A successful refresh: back online, and the cache was accepted.
    wsUsingOfflineSession.value = false;
    wsOfflineCustomerSearchUnavailable.value = null;
    await t.pumpAndSettle();

    expect(strips(), findsNothing,
        reason: 'a banner that never goes away is one people stop reading');
    expect(find.text('dashboard'), findsOneWidget);
  });
}
