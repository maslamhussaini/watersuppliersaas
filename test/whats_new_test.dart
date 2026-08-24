// =============================================================================
// test/whats_new_test.dart
//
// Release notes: when they appear, when they must not, and what they show.
//
// The store is injected, so every case runs without touching a device — and
// the file-backed store is exercised separately against a real temp directory,
// since "works in memory" is not the same claim as "survives a restart".
// =============================================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/screens/whats_new_screen.dart';
import 'package:watersuppliersaas/services/whats_new.dart';

final _releases = [
  WsRelease(
    version: '1.4.0',
    build: 40,
    date: DateTime(2026, 8, 14),
    title: 'Newest release',
    category: 'Daily work',
    changes: ['The newest thing'],
  ),
  WsRelease(
    version: '1.3.0',
    build: 30,
    date: DateTime(2026, 8, 13),
    title: 'Middle release',
    changes: ['A middling thing'],
    actionRequired: 'Check your opening balances.',
  ),
  WsRelease(
    version: '1.2.0',
    build: 20,
    date: DateTime(2026, 8, 12),
    title: 'Older release',
    changes: ['An older thing'],
  ),
];

WsWhatsNew serviceWith(String? lastSeen, {String current = '1.4.0'}) =>
    WsWhatsNew(
      store: WsSeenMemoryStore(lastSeen),
      releases: _releases,
      currentVersion: current,
    );

void main() {
  // ═══ VERSION COMPARISON ═══════════════════════════════════════════════════

  group('version comparison', () {
    test('orders by number, not by string', () {
      expect(wsCompareVersions('1.9.0', '1.10.0'), lessThan(0),
          reason: 'string ordering would put 1.10.0 first and quietly stop '
              'showing notes at the tenth release');
      expect(wsCompareVersions('1.10.0', '1.9.0'), greaterThan(0));
    });

    test('equal versions compare equal', () {
      expect(wsCompareVersions('1.4.0', '1.4.0'), 0);
      expect(wsCompareVersions('1.4', '1.4.0'), 0,
          reason: 'a missing segment is zero');
    });

    test('handles build suffixes', () {
      expect(wsCompareVersions('1.4.0+40', '1.4.0'), 0);
      expect(wsCompareVersions('1.4.1', '1.4.0+99'), greaterThan(0));
    });

    test('major beats minor beats patch', () {
      expect(wsCompareVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(wsCompareVersions('1.3.0', '1.2.9'), greaterThan(0));
    });
  });

  // ═══ WHEN TO SHOW ═════════════════════════════════════════════════════════

  group('deciding what is unseen', () {
    test('a new version shows the releases since the last one seen', () async {
      final s = serviceWith('1.2.0');
      final unseen = await s.unseen();
      expect(unseen.map((r) => r.version), ['1.4.0', '1.3.0']);
      expect(await s.shouldShow(), isTrue);
    });

    test('the same version shows nothing', () async {
      final s = serviceWith('1.4.0');
      expect(await s.unseen(), isEmpty);
      expect(await s.shouldShow(), isFalse);
    });

    test('a single new release shows only that one', () async {
      final s = serviceWith('1.3.0');
      expect((await s.unseen()).map((r) => r.version), ['1.4.0']);
    });

    test('multiple releases come back newest first', () async {
      final s = serviceWith('1.1.0');
      expect((await s.unseen()).map((r) => r.version),
          ['1.4.0', '1.3.0', '1.2.0']);
    });

    test('a version ahead of the notes shows nothing', () async {
      final s = serviceWith('9.0.0');
      expect(await s.unseen(), isEmpty,
          reason: 'a downgrade must not replay the whole changelog');
    });
  });

  // ═══ FIRST INSTALL ════════════════════════════════════════════════════════

  group('first installation', () {
    test('shows nothing at all', () async {
      final s = serviceWith(null);
      expect(await s.unseen(), isEmpty,
          reason: 'the whole app is new; four releases of history is noise');
    });

    test('and records the current version so the NEXT upgrade shows', () async {
      final store = WsSeenMemoryStore();
      final s = WsWhatsNew(
          store: store, releases: _releases, currentVersion: '1.4.0');

      await s.unseen();
      expect(await store.read(), '1.4.0');

      // Now ship a newer build against the same stored value.
      final upgraded = WsWhatsNew(
          store: store, releases: _releases, currentVersion: '1.5.0');
      final notes = [
        WsRelease(
            version: '1.5.0',
            build: 50,
            date: DateTime(2026, 9, 1),
            title: 'Later',
            changes: ['x']),
        ..._releases,
      ];
      final next = WsWhatsNew(
          store: store, releases: notes, currentVersion: '1.5.0');
      expect((await next.unseen()).map((r) => r.version), ['1.5.0']);
      expect(upgraded.currentVersion, '1.5.0');
    });
  });

  // ═══ MARK AS SEEN ═════════════════════════════════════════════════════════

  group('marking as seen', () {
    test('stops it showing again', () async {
      final store = WsSeenMemoryStore('1.2.0');
      final s = WsWhatsNew(
          store: store, releases: _releases, currentVersion: '1.4.0');

      expect(await s.shouldShow(), isTrue);
      await s.markSeen();
      expect(await s.shouldShow(), isFalse);
      expect(await store.read(), '1.4.0');
    });

    test('records the CURRENT version, not the newest note', () async {
      final store = WsSeenMemoryStore('1.0.0');
      // A build running 1.3.0 while notes for 1.4.0 already exist in the file.
      final s = WsWhatsNew(
          store: store, releases: _releases, currentVersion: '1.3.0');
      await s.markSeen();
      expect(await store.read(), '1.3.0',
          reason: 'when they upgrade to 1.4.0 they should still see its notes');
    });
  });

  // ═══ THE STORE, ON A REAL FILE ════════════════════════════════════════════

  group('the file store', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('ws_seen'));
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('nothing stored reads as never seen', () async {
      final store = WsSeenFileStore('${dir.path}/seen.json');
      expect(await store.read(), isNull);
    });

    test('a written version survives a fresh instance — a restart', () async {
      final path = '${dir.path}/seen.json';
      await WsSeenFileStore(path).write('1.4.0');
      expect(await WsSeenFileStore(path).read(), '1.4.0');
    });

    test('a corrupt file reads as never seen rather than throwing', () async {
      final path = '${dir.path}/seen.json';
      await File(path).writeAsString('{ this is not json');
      expect(await WsSeenFileStore(path).read(), isNull,
          reason: 'showing the notes once too often is the harmless direction');
    });

    test('a file with the wrong shape reads as never seen', () async {
      final path = '${dir.path}/seen.json';
      await File(path).writeAsString('{"somethingElse": 1}');
      expect(await WsSeenFileStore(path).read(), isNull);
    });

    test('offline is the only mode — nothing here touches a network', () async {
      // The notes are compiled in, so the list is available with no connection
      // and no database.
      final s = WsWhatsNew(store: WsSeenFileStore('${dir.path}/seen.json'));
      expect(s.all(), isNotEmpty);
      expect(s.currentVersion, wsCurrentVersion);
    });
  });

  // ═══ THE SHIPPED NOTES ════════════════════════════════════════════════════

  group('the shipped release notes', () {
    test('the current version has notes', () {
      expect(wsReleaseNotes.any((r) => r.version == wsCurrentVersion), isTrue,
          reason: 'a build whose own version has no entry would show nothing '
              'to anyone upgrading to it');
    });

    test('are ordered newest first', () {
      for (var i = 1; i < wsReleaseNotes.length; i++) {
        expect(
            wsCompareVersions(
                wsReleaseNotes[i - 1].version, wsReleaseNotes[i].version),
            greaterThan(0));
      }
    });

    test('every release says something', () {
      for (final r in wsReleaseNotes) {
        expect(r.title.trim(), isNotEmpty);
        expect(r.changes, isNotEmpty, reason: 'v${r.version}');
      }
    });

    test('versions are unique', () {
      final seen = wsReleaseNotes.map((r) => r.version).toSet();
      expect(seen.length, wsReleaseNotes.length);
    });
  });

  // ═══ THE SCREEN ═══════════════════════════════════════════════════════════

  group('the screen', () {
    testWidgets('groups changes by release', (t) async {
      await t.pumpWidget(MaterialApp(
          home: WsWhatsNewScreen(releases: _releases, isUpgrade: true)));
      await t.pumpAndSettle();

      expect(find.text('Newest release'), findsOneWidget);
      expect(find.text('Middle release'), findsOneWidget);
      expect(find.text('Older release'), findsOneWidget);
      expect(find.text('v1.4.0'), findsOneWidget);
      expect(find.text('The newest thing'), findsOneWidget);
    });

    testWidgets('says how many updates there are', (t) async {
      await t.pumpWidget(MaterialApp(
          home: WsWhatsNewScreen(releases: _releases, isUpgrade: true)));
      await t.pumpAndSettle();
      expect(find.text('3 updates since you were last here'), findsOneWidget);
    });

    testWidgets('uses the singular for one release', (t) async {
      await t.pumpWidget(MaterialApp(
          home: WsWhatsNewScreen(
              releases: [_releases.first], isUpgrade: true)));
      await t.pumpAndSettle();
      expect(find.text('One update since you were last here'), findsOneWidget);
    });

    testWidgets('shows an action-required note prominently', (t) async {
      await t.pumpWidget(MaterialApp(
          home: WsWhatsNewScreen(releases: _releases, isUpgrade: true)));
      await t.pumpAndSettle();
      expect(find.text('Check your opening balances.'), findsOneWidget);
    });

    testWidgets('the full history has no upgrade wording', (t) async {
      await t.pumpWidget(
          MaterialApp(home: WsWhatsNewScreen(releases: _releases)));
      await t.pumpAndSettle();
      expect(find.text('Release notes'), findsOneWidget);
      expect(find.textContaining('since you were last here'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('an empty list does not crash', (t) async {
      await t.pumpWidget(const MaterialApp(
          home: WsWhatsNewScreen(releases: [])));
      await t.pumpAndSettle();
      expect(find.text('No release notes yet.'), findsOneWidget);
    });

    testWidgets('the button closes it', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<bool>(
                  builder: (_) =>
                      WsWhatsNewScreen(releases: _releases, isUpgrade: true),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Got it'), findsOneWidget);

      await t.tap(find.text('Got it'));
      await t.pumpAndSettle();
      expect(find.text('open'), findsOneWidget, reason: 'back on the host');
    });
  });
}
