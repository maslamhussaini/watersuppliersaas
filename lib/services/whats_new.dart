// =============================================================================
// lib/services/whats_new.dart
// Release notes, and deciding when to show them.
//
// ─── DELIBERATELY LOCAL AND STATIC ───────────────────────────────────────────
//
// The notes ship inside the build as Dart constants. No table, no RPC, no
// fetch. That means the feature works on a driver's phone with no signal, it
// cannot get out of step with the binary it is describing, and it adds nothing
// to the list of things that can fail to synchronise.
//
// A server-driven changelog is a different feature with a different problem —
// notes for a version the device has not installed yet — and it is not worth
// that until there is a reason.
//
// ─── NO NEW DEPENDENCY ───────────────────────────────────────────────────────
//
// "Last seen" is one string. It is kept in a small JSON file through the same
// path_provider mechanism the outbox already uses, behind an interface so tests
// can substitute memory. Adding shared_preferences for a single key would mean
// another plugin with per-platform native configuration that nothing here can
// verify.
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'storage/ws_key_value_store.dart';
import 'storage/ws_kv_default.dart';

// ─── The notes ────────────────────────────────────────────────────────────────

/// What this build calls itself.
///
/// The single source of truth for the running version, and the value compared
/// against what the user last saw. It lives beside the notes so the two cannot
/// drift: adding a release without bumping this is immediately obvious.
const String wsCurrentVersion = '1.4.0';

class WsRelease {
  final String version;
  final int build;
  final DateTime date;
  final String title;

  /// One line per change. Kept as a list rather than a paragraph so the screen
  /// can lay them out and a reader can skim.
  final List<String> changes;

  /// Optional grouping, e.g. 'Reliability', 'Data'.
  final String? category;

  /// Anything the user must DO — a migration to run, a setting to check.
  /// Rendered prominently, because it is the only part that is not optional
  /// reading.
  final String? actionRequired;

  const WsRelease({
    required this.version,
    required this.build,
    required this.date,
    required this.title,
    required this.changes,
    this.category,
    this.actionRequired,
  });
}

/// Newest first. The order here is the order shown.
final List<WsRelease> wsReleaseNotes = [
  WsRelease(
    version: '1.4.0',
    build: 40,
    date: DateTime(2026, 8, 14),
    title: 'Find customers instantly',
    category: 'Daily work',
    changes: [
      'Customer fields on the delivery and payment screens are now searchable — '
          'type a name, phone number or code instead of scrolling a list.',
      'Search runs on the server, so it stays fast whether you have twenty '
          'customers or twenty thousand.',
      'The delivery screen no longer loads your whole customer list when it '
          'opens, so it starts faster on a slow connection.',
    ],
  ),
  WsRelease(
    version: '1.3.0',
    build: 30,
    date: DateTime(2026, 8, 13),
    title: 'Import your customer list',
    category: 'Data',
    changes: [
      'Paste a spreadsheet to add or update customers in bulk.',
      'Every import is checked first and shows exactly what will change, '
          'customer by customer, before anything is saved.',
      'A blank cell never clears an existing value — it is left alone.',
      'A file with any error imports nothing at all, so you can fix it and '
          'try again cleanly.',
    ],
    actionRequired: 'Opening balances in an import post to your accounts the '
        'same way as entering them by hand. Check the preview before '
        'confirming a file that contains them.',
  ),
  WsRelease(
    version: '1.2.0',
    build: 20,
    date: DateTime(2026, 8, 12),
    title: 'Multiple branches',
    category: 'Setup',
    changes: [
      'Run more than one depot from the same account, each with its own '
          'deliveries, payments and customers.',
      'Staff can be limited to the branches they work in.',
      'A branch selector appears in the toolbar once you create a second '
          'branch — if you have one shop, nothing changes.',
      'Documents recorded offline keep the branch they were created in, even '
          'if you switch branches before they sync.',
    ],
  ),
  WsRelease(
    version: '1.1.0',
    build: 10,
    date: DateTime(2026, 8, 11),
    title: 'Deliveries that survive a bad signal',
    category: 'Reliability',
    changes: [
      'Deliveries, payments and purchases are saved on your device first and '
          'sync when there is a connection.',
      'A delivery recorded twice because the app lost the reply now counts '
          'once — the server recognises the repeat.',
      'The sync screen shows exactly what is waiting and what failed, with the '
          'reason.',
      'Losing signal mid-round no longer marks good deliveries as failed.',
    ],
  ),
];

// ─── Version comparison ───────────────────────────────────────────────────────

/// Compares dotted numeric versions: negative when [a] is older.
///
/// Segment by segment as NUMBERS, because a string comparison puts 1.10.0
/// before 1.9.0 — which would silently stop showing release notes at the tenth
/// release and look like the feature had simply stopped working.
int wsCompareVersions(String a, String b) {
  List<int> parts(String v) => v
      // BUILD METADATA IS NOT PRECEDENCE. Flutter writes versions as
      // "1.4.0+40"; semver says everything from the '+' is ignored when
      // ordering. Without this, 1.4.0+40 sorts ABOVE 1.4.0 and a user on the
      // same release would be shown its notes a second time.
      .split('+')
      .first
      .split(RegExp(r'[.\-]'))
      .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();

  final pa = parts(a);
  final pb = parts(b);
  final len = pa.length > pb.length ? pa.length : pb.length;

  for (var i = 0; i < len; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

// ─── Where "last seen" lives ──────────────────────────────────────────────────

abstract class WsSeenStore {
  Future<String?> read();
  Future<void> write(String version);
  Future<void> clear();
}

class WsSeenFileStore implements WsSeenStore {
  final File file;
  WsSeenFileStore(String path) : file = File(path);

  @override
  Future<String?> read() async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['lastSeenVersion'] is String) {
        return decoded['lastSeenVersion'] as String;
      }
      return null;
    } catch (_) {
      // A corrupt or unreadable preference is not worth an error. Treating it
      // as "never seen" shows the notes once too often, which is the harmless
      // direction to fail in.
      return null;
    }
  }

  @override
  Future<void> write(String version) async {
    final dir = file.parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'lastSeenVersion': version,
      'seenAt': DateTime.now().toIso8601String(),
    }));
  }

  @override
  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

class WsSeenMemoryStore implements WsSeenStore {
  String? _value;
  WsSeenMemoryStore([this._value]);

  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String version) async => _value = version;
  @override
  Future<void> clear() async => _value = null;
}

// ─── The service ──────────────────────────────────────────────────────────────

class WsWhatsNew {
  final List<WsRelease> releases;
  final String currentVersion;
  final WsSeenStore store;

  WsWhatsNew({
    required this.store,
    List<WsRelease>? releases,
    String? currentVersion,
  })  : releases = releases ?? wsReleaseNotes,
        currentVersion = currentVersion ?? wsCurrentVersion;

  // ── production singleton ────────────────────────────────────────────────
  static WsWhatsNew? _instance;
  static WsWhatsNew? get instanceOrNull => _instance;

  static Future<WsWhatsNew> init() async {
    if (_instance != null) return _instance!;
    // Through the shared key/value seam, so this works on web. It used to call
    // getApplicationSupportDirectory() directly, which has no web
    // implementation and raised on the only platform this project ships to.
    _instance = WsWhatsNew(store: WsSeenKvStore(await wsOpenDefaultKeyValueStore()));
    return _instance!;
  }

  /// Releases newer than what the user has already seen, newest first.
  Future<List<WsRelease>> unseen() async {
    final lastSeen = await store.read();

    // FIRST INSTALL SHOWS NOTHING.
    //
    // Nothing is "new" to somebody who has never used the old version — the
    // whole app is new. Presenting four releases of history before they have
    // recorded a single delivery is noise, so the current version is marked
    // seen silently and the notes wait for the next upgrade.
    if (lastSeen == null) {
      await store.write(currentVersion);
      return const [];
    }

    return releases
        .where((r) => wsCompareVersions(r.version, lastSeen) > 0)
        .toList();
  }

  /// Whether to interrupt the user on startup.
  Future<bool> shouldShow() async => (await unseen()).isNotEmpty;

  /// Called once the user has actually seen the notes.
  Future<void> markSeen() => store.write(currentVersion);

  /// Every release, for the always-available menu entry.
  List<WsRelease> all() => List.unmodifiable(releases);
}

/// WsSeenStore over the shared key/value seam.
///
/// The interface is unchanged, so every existing What's New test still drives
/// the same three methods; only where the bytes land is different.
class WsSeenKvStore implements WsSeenStore {
  static const storageKey = 'whatsNew.lastSeen';

  final WsKeyValueStore kv;
  const WsSeenKvStore(this.kv);

  @override
  Future<String?> read() async {
    final v = await kv.read(storageKey);
    return (v == null || v.isEmpty) ? null : v;
  }

  @override
  Future<void> write(String version) => kv.write(storageKey, version);

  @override
  Future<void> clear() => kv.remove(storageKey);
}
