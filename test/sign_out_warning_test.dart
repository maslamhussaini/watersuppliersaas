// =============================================================================
// test/sign_out_warning_test.dart
// The sign-out warning: what it says, and that nothing can skip it.
//
// Two halves.
//
// The first is a plain unit test of wsSignOutWarning(), which is pure — two
// ints in, a sentence or null out. No widget pumping, no BuildContext, no
// Supabase, no outbox. That is the whole reason the copy decision lives in a
// free function rather than inside the dialog.
//
// The second is a SOURCE AUDIT, in the style of auth_service_surface_test.dart.
// The rule it protects is a negative about the whole of lib/: no screen may
// call AuthService.signOut() directly, because doing so silently skips the
// warning. A behavioural test cannot express that — the danger is a call that
// does not exist yet. So the source is read and the rule asserted against it.
//
// The allowlist has exactly two entries, and both are deliberate:
//
//   lib/screens/ws_sign_out.dart   the helper. It owns the primitive call.
//   lib/main.dart                  the auth-gate error screen's escape hatch,
//                                  intentionally exempt: it is the only way out
//                                  of a broken gate state, _errorScreen has no
//                                  BuildContext, and the Sync Queue screen is
//                                  unreachable from there anyway.
//
// main.dart's exemption is asserted POSITIVELY rather than just permitted. An
// intentional omission recorded only in a comment is the kind a later audit
// "fixes"; one recorded as a failing test is not.
// =============================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/screens/ws_sign_out.dart';

/// Source with comments stripped, so a tombstone mentioning a removed name is
/// not mistaken for the declaration coming back. Same helper as
/// auth_service_surface_test.dart.
String _codeOf(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: '$path not found — run from the package root');
  return file
      .readAsLinesSync()
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}

/// Every Dart file under lib/, as forward-slash paths relative to the package
/// root. Separators are normalised because this repository is checked out on
/// Windows and Directory.listSync yields backslashes there.
List<String> _libFiles() {
  final dir = Directory('lib');
  expect(dir.existsSync(), isTrue,
      reason: 'lib/ not found — run from the package root');
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path.replaceAll(r'\', '/'))
      .where((p) => p.endsWith('.dart'))
      .toList()
    ..sort();
}

void main() {
  // ═══ THE COPY ═════════════════════════════════════════════════════════════

  group('wsSignOutWarning', () {
    test('nothing queued means no dialog at all', () {
      expect(wsSignOutWarning(pending: 0, failed: 0), isNull);
    });

    test('one pending item', () {
      expect(
          wsSignOutWarning(pending: 1, failed: 0),
          "This device has 1 item that hasn't been sent yet. Signing out will "
          'not delete it — it stays on this device until it can be sent.');
    });

    test('several pending items', () {
      expect(
          wsSignOutWarning(pending: 3, failed: 0),
          "This device has 3 items that haven't been sent yet. Signing out "
          'will not delete them — they stay on this device until they can be '
          'sent.');
    });

    test('one failed item — stopped, not waiting', () {
      expect(
          wsSignOutWarning(pending: 0, failed: 1),
          'This device has 1 item that needs attention before it can be sent. '
          'Signing out will not delete it — it stays on this device.',
          reason: 'a failed item never says "until it can be sent": the drain '
              'skips it and only a manual Retry moves it');
    });

    test('several failed items', () {
      expect(
          wsSignOutWarning(pending: 0, failed: 4),
          'This device has 4 items that need attention before they can be '
          'sent. Signing out will not delete them — they stay on this device.');
    });

    test('mixed names the failed subset, and totals both', () {
      expect(
          wsSignOutWarning(pending: 2, failed: 3),
          "This device has 5 items that haven't been sent yet, and 3 of them "
          'need attention before they can be sent. Signing out will not '
          'delete them — they stay on this device.');
    });

    test('mixed with a single failed item keeps its grammar', () {
      // The likeliest grammar bug in the whole file: "1 of them need".
      expect(
          wsSignOutWarning(pending: 1, failed: 1),
          "This device has 2 items that haven't been sent yet, and 1 of them "
          'needs attention before it can be sent. Signing out will not delete '
          'them — they stay on this device.');
    });

    test('no variant produces broken grammar', () {
      const cases = [
        [1, 0], [3, 0], [0, 1], [0, 4], [2, 3], [1, 1], [1, 5], [5, 1],
      ];
      for (final c in cases) {
        final s = wsSignOutWarning(pending: c[0], failed: c[1])!;
        for (final bad in [
          '1 items',
          '1 need ',
          '1 of them need ',
          '1 item that have',
          'them — it stays',
        ]) {
          expect(s, isNot(contains(bad)),
              reason: 'pending=${c[0]} failed=${c[1]} produced: $s');
        }
      }
    });

    test('never claims ownership, a sender, or automatic recovery', () {
      const cases = [
        [1, 0], [3, 0], [0, 1], [0, 4], [2, 3], [1, 1],
      ];
      for (final c in cases) {
        final s = wsSignOutWarning(pending: c[0], failed: c[1])!;
        for (final forbidden in [
          'You have',
          'your ',
          'signs in again',
          'will be sent',
          'automatically',
          'deleted',
        ]) {
          expect(s.toLowerCase(), isNot(contains(forbidden.toLowerCase())),
              reason: 'another user may own these items, and nothing may '
                  'promise who sends them or when — got: $s');
        }
        expect(s, contains('This device has'));
        expect(s, contains('will not delete'));
      }
    });
  });

  // ═══ NOTHING MAY SKIP THE WARNING ═════════════════════════════════════════

  group('AuthService.signOut has exactly two permitted homes', () {
    const helper = 'lib/screens/ws_sign_out.dart';
    const gateExemption = 'lib/main.dart';
    const allowed = {helper, gateExemption};

    test('no other file in lib/ calls it directly', () {
      final offenders = <String>[];
      for (final path in _libFiles()) {
        if (allowed.contains(path)) continue;
        if (_codeOf(path).contains('AuthService.signOut')) offenders.add(path);
      }
      expect(offenders, isEmpty,
          reason: 'these call AuthService.signOut directly and therefore skip '
              'the unsent-work warning: ${offenders.join(", ")}. Route them '
              'through wsConfirmSignOut() in $helper instead.');
    });

    test('the helper does own the primitive call', () {
      expect(_codeOf(helper), contains('AuthService.signOut'),
          reason: 'if this moves out, the allowlist above stops protecting '
              'anything');
    });

    test('main.dart keeps its intentional direct call', () {
      expect(_codeOf(gateExemption), contains('AuthService.signOut'),
          reason: 'the auth-gate error screen is DELIBERATELY exempt — it is '
              'the only escape from a broken gate, _errorScreen takes no '
              'BuildContext, and the Sync Queue screen is unreachable from '
              'there. Removing this is a product change, not a cleanup');
    });
  });

  group('both normal sign-out screens go through the helper', () {
    const screens = [
      'lib/screens/account_screen.dart',
      'lib/screens/organization_selector_screen.dart',
    ];

    test('they call wsConfirmSignOut', () {
      for (final s in screens) {
        expect(_codeOf(s), contains('wsConfirmSignOut'), reason: s);
      }
    });

    test('and none of them calls AuthService.signOut directly', () {
      for (final s in screens) {
        expect(_codeOf(s), isNot(contains('AuthService.signOut')), reason: s);
      }
    });
  });
}
