// =============================================================================
// lib/services/auth/ws_session_snapshot.dart
// Enough of the last successful sign-in to open the app without a network.
//
// ─── THE PROBLEM THIS SOLVES ─────────────────────────────────────────────────
//
// WsAuthGate gates the entire application behind two live PostgREST queries:
// currentOrganization() and resolveRole(). With no connection the first hangs
// until the HTTP timeout — the "stuck on loading" report — and then fails,
// producing "Could not load your organization". The user never reaches any
// screen, so nothing offline-first below that point is reachable either.
//
// Neither call is asking anything that changes minute to minute. Which
// organization you belong to and what role you hold were true last time and are
// almost certainly true now. So they are written down, and used only when the
// server cannot be asked.
//
// ─── WHAT THIS IS NOT ────────────────────────────────────────────────────────
//
// NOT an authentication bypass. The snapshot is consulted only AFTER Supabase
// has restored a session and produced a uid; with no session the login screen
// appears exactly as before. It cannot create a session, extend one, or revive
// an expired one.
//
// NOT a way to pick an organization. [readFor] takes the authenticated uid and
// returns null unless the stored snapshot was written for THAT uid. On a shared
// device the previous driver's organization and permissions are unreachable,
// which is the same rule the outbox already applies to queued documents.
//
// NOT authoritative. Whenever the server answers, the server wins and the
// snapshot is overwritten. This is a fallback, never a cache consulted first.
//
// NOT a security boundary. RLS is, and is untouched. Permission codes here only
// decide which buttons render; every write is still checked server-side, so a
// tampered snapshot grants a menu item and nothing behind it.
//
// ─── STORAGE ─────────────────────────────────────────────────────────────────
//
// Reuses the existing WsKeyValueStore seam — the same abstraction behind the
// outbox, What's New and the registration attempt — under `ws.session.snapshot`.
// No new storage mechanism, no new platform dependency, and it inherits the
// web/file implementations already tested.
// =============================================================================

import 'dart:convert';

import '../../models/ws_models.dart';
import '../storage/ws_key_value_store.dart';

/// The minimum WsAuthGate needs to route a user without asking the server.
class WsSessionSnapshot {
  /// WHOSE snapshot this is. The whole safety of the mechanism rests on this
  /// being compared against the live session's uid before anything is used.
  final String authUserId;

  /// The organization row as PostgREST returned it, so it rebuilds through
  /// WsOrganization.fromJson — the identical code path the online route uses,
  /// rather than a second parser that could drift from it.
  final Map<String, dynamic> organization;

  final WsUserRole role;
  final List<String> permissionCodes;
  final DateTime savedAt;

  const WsSessionSnapshot({
    required this.authUserId,
    required this.organization,
    required this.role,
    required this.permissionCodes,
    required this.savedAt,
  });

  /// Builds a snapshot from what the online path has just resolved.
  ///
  /// The organization is flattened to the SAME snake_case keys
  /// WsOrganization.fromJson reads, so the value round-trips through the
  /// existing parser instead of a second one that could drift from it.
  factory WsSessionSnapshot.of({
    required String authUserId,
    required WsOrganization org,
    required WsUserRole role,
    required WsPermissions permissions,
    DateTime? at,
  }) =>
      WsSessionSnapshot(
        authUserId: authUserId,
        organization: {
          'orgid': org.orgId,
          'owneruserid': org.authUserId,
          'orgname': org.orgName,
          'businessname': org.businessName,
          'ownername': org.ownerName,
          'phone': org.phone,
          'address': org.address,
          'isactive': org.isActive,
          'currencysymbol': org.currencySymbol,
          'receiptprefix': org.receiptPrefix,
          'logourl': org.logoUrl,
          'cardsettings': org.cardSettings,
        },
        role: role,
        permissionCodes: permissions.codes.toList()..sort(),
        savedAt: at ?? DateTime.now(),
      );

  int? get orgId => (organization['orgid'] as num?)?.toInt();

  /// The stored organization, rebuilt.
  ///
  /// RARELY NULL, and not the validation it looks like: WsOrganization.fromJson
  /// is lenient — _reqStr, _reqInt and _reqBool all fall back to defaults
  /// rather than throwing — so a map stripped to just an orgid rebuilds with
  /// empty strings. The check that actually rejects a bad payload is the
  /// explicit orgid test in [WsSessionSnapshot.fromJson]. This guard only
  /// catches input the parser genuinely cannot walk.
  WsOrganization? get organizationOrNull {
    try {
      return WsOrganization.fromJson(organization);
    } catch (_) {
      return null;
    }
  }

  WsPermissions get permissions => WsPermissions(permissionCodes.toSet());

  Map<String, dynamic> toJson() => {
        'authUserId': authUserId,
        'organization': organization,
        'role': role.name,
        'permissionCodes': permissionCodes,
        'savedAt': savedAt.toIso8601String(),
      };

  /// Throws [FormatException] on anything it cannot trust. Deliberately strict:
  /// a half-understood snapshot is worse than none, because none falls back to
  /// the existing online path while a half-understood one routes on guesses.
  factory WsSessionSnapshot.fromJson(Map<String, dynamic> j) {
    final uid = j['authUserId'];
    if (uid is! String || uid.isEmpty) {
      throw const FormatException('session snapshot has no authUserId');
    }

    final org = j['organization'];
    if (org is! Map) {
      throw const FormatException('session snapshot has no organization');
    }
    final orgMap = Map<String, dynamic>.from(org);
    if ((orgMap['orgid'] as num?) == null) {
      throw const FormatException('session snapshot organization has no orgid');
    }

    final roleName = '${j['role']}';
    final role = WsUserRole.values.where((r) => r.name == roleName).firstOrNull;
    if (role == null) {
      throw FormatException('session snapshot has an unknown role: $roleName');
    }

    final saved = DateTime.tryParse('${j['savedAt']}');
    if (saved == null) {
      throw const FormatException('session snapshot has no savedAt');
    }

    return WsSessionSnapshot(
      authUserId: uid,
      organization: orgMap,
      role: role,
      permissionCodes: [
        for (final c in (j['permissionCodes'] as List? ?? const []))
          if (c is String) c,
      ],
      savedAt: saved,
    );
  }
}

/// Reads and writes the snapshot. One key, last-write-wins.
class WsSessionSnapshotStore {
  static const storageKey = 'session.snapshot';

  final WsKeyValueStore kv;

  const WsSessionSnapshotStore(this.kv);

  /// The snapshot for [uid], or null.
  ///
  /// Returns null — never throws — for every failure: nothing stored, stored
  /// for somebody else, or unreadable. The caller's response to all three is
  /// identical, which is to fall through to the online path.
  Future<WsSessionSnapshot?> readFor(String uid) async {
    final snap = await _read();
    if (snap == null) return null;

    // THE SHARED-DEVICE RULE. Two drivers use one tablet; the second must never
    // inherit the first's organization, role or permissions.
    if (snap.authUserId != uid) return null;

    // An organization that will not rebuild is not usable, and pretending
    // otherwise would route somebody into an app with a broken tenant.
    if (snap.organizationOrNull == null) return null;

    return snap;
  }

  Future<WsSessionSnapshot?> _read() async {
    final raw = await kv.read(storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return WsSessionSnapshot.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // Corrupt or written by an older shape. Silently unusable rather than
      // fatal: the online path still works and will overwrite it.
      return null;
    }
  }

  Future<void> write(WsSessionSnapshot snapshot) =>
      kv.write(storageKey, jsonEncode(snapshot.toJson()));

  /// Called on sign-out so a shared device does not keep the last user's
  /// organization sitting in storage.
  Future<void> clear() => kv.remove(storageKey);
}
