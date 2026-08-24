// =============================================================================
// lib/services/auth/ws_registration_attempt_store.dart
// One registration attempt, durable enough to survive a browser reload.
//
// ─── WHAT THIS IS PROTECTING ─────────────────────────────────────────────────
//
//     ONE registration attempt = ONE clientuuid
//
// across a wrong code, a resend, a rate limit, a session expiry, a route
// change, a widget rebuild, a browser reload and an app restart.
//
// Before this existed the key lived in a State field in register_screen.dart,
// and a SECOND one lived in organization_selector_screen.dart. That was safe
// only because provisioning happened synchronously inside one submit. Phase 2
// puts an out-of-band SMS in the middle, so the attempt now spans minutes and
// at least one opportunity for the user to close the tab — and a fresh key on
// the way back would provision a second organization that migration 014 could
// never recognise as a duplicate.
//
// ─── WHAT IS DELIBERATELY NOT HERE ───────────────────────────────────────────
//
//   the password         — never leaves the form
//   the access token     — Supabase owns session persistence; duplicating it
//   the refresh token      would create a second copy to leak
//   the OTP code         — writing down the thing that proves possession of the
//                          phone would defeat the point of asking for it
//
// [toJson] is the whole persisted surface, and a test asserts that none of the
// four ever appears in it.
// =============================================================================

import 'dart:convert';

import '../storage/ws_key_value_store.dart';

class WsRegistrationAttempt {
  /// THE KEY. Generated once, by WsRegistrationFlow, and carried unchanged to
  /// ws_create_organization however many attempts it takes.
  final String clientUuid;

  /// Empty until signUp returns a user.
  final String authUserId;

  final String email;
  final String phone;

  /// WsRegistrationState.name — stored as a string so an unknown value from a
  /// newer build degrades to "start again" instead of throwing on parse.
  final String state;

  /// WsPhoneAssurance.name. Persisted so a resumed attempt cannot silently
  /// upgrade serverAsserted to otpProven by forgetting which one it had.
  final String assurance;

  /// The business details already collected, so a resume does not re-ask.
  final String orgName;
  final String ownerName;
  final String orgPhone;
  final String address;

  final DateTime startedAt;

  /// Set once provisioning succeeds. Present so a lost response on the retry
  /// resolves to the same organization instead of making another.
  final int? organizationId;

  const WsRegistrationAttempt({
    required this.clientUuid,
    required this.state,
    this.authUserId = '',
    this.email = '',
    this.phone = '',
    this.assurance = 'none',
    this.orgName = '',
    this.ownerName = '',
    this.orgPhone = '',
    this.address = '',
    required this.startedAt,
    this.organizationId,
  });

  WsRegistrationAttempt copyWith({
    String? authUserId,
    String? phone,
    String? state,
    String? assurance,
    String? orgName,
    String? ownerName,
    String? orgPhone,
    String? address,
    int? organizationId,
  }) =>
      WsRegistrationAttempt(
        // NOT copyable. There is no code path that replaces the key of an
        // existing attempt, and offering one would be offering the bug.
        clientUuid: clientUuid,
        startedAt: startedAt,
        email: email,
        authUserId: authUserId ?? this.authUserId,
        phone: phone ?? this.phone,
        state: state ?? this.state,
        assurance: assurance ?? this.assurance,
        orgName: orgName ?? this.orgName,
        ownerName: ownerName ?? this.ownerName,
        orgPhone: orgPhone ?? this.orgPhone,
        address: address ?? this.address,
        organizationId: organizationId ?? this.organizationId,
      );

  Map<String, dynamic> toJson() => {
        'clientUuid': clientUuid,
        'authUserId': authUserId,
        'email': email,
        'phone': phone,
        'state': state,
        'assurance': assurance,
        'orgName': orgName,
        'ownerName': ownerName,
        'orgPhone': orgPhone,
        'address': address,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (organizationId != null) 'organizationId': organizationId,
      };

  /// Returns null rather than throwing on anything unrecognisable. A stored
  /// attempt is a convenience; a crash loop on startup because of one is not a
  /// trade worth making.
  static WsRegistrationAttempt? fromJson(Object? decoded) {
    if (decoded is! Map) return null;

    final uuid = decoded['clientUuid'];
    final started = DateTime.tryParse('${decoded['startedAt']}');
    // Without these two there is nothing worth resuming.
    if (uuid is! String || uuid.isEmpty || started == null) return null;

    String s(String k) => decoded[k] is String ? decoded[k] as String : '';

    return WsRegistrationAttempt(
      clientUuid: uuid,
      authUserId: s('authUserId'),
      email: s('email'),
      phone: s('phone'),
      state: s('state').isEmpty ? 'notStarted' : s('state'),
      assurance: s('assurance').isEmpty ? 'none' : s('assurance'),
      orgName: s('orgName'),
      ownerName: s('ownerName'),
      orgPhone: s('orgPhone'),
      address: s('address'),
      startedAt: started,
      organizationId:
          decoded['organizationId'] is int ? decoded['organizationId'] as int : null,
    );
  }

  /// An attempt nobody came back to. Stale state that silently resumes days
  /// later is more confusing than a clean start.
  bool isExpired({Duration maxAge = const Duration(hours: 24), DateTime? now}) =>
      (now ?? DateTime.now().toUtc())
          .difference(startedAt.toUtc()) >
      maxAge;
}

class WsRegistrationAttemptStore {
  static const storageKey = 'registration.attempt';

  final WsKeyValueStore kv;
  final Duration maxAge;

  const WsRegistrationAttemptStore(
    this.kv, {
    this.maxAge = const Duration(hours: 24),
  });

  /// The pending attempt, or null when there is none, it cannot be read, or it
  /// is too old. An expired attempt is cleared as a side effect so it does not
  /// have to be re-decided on every launch.
  Future<WsRegistrationAttempt?> load({DateTime? now}) async {
    final raw = await kv.read(storageKey);
    if (raw == null || raw.isEmpty) return null;

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // Corrupt. Reported by returning null, and removed so the next launch is
      // clean — there is nothing here worth salvaging byte by byte.
      await clear();
      return null;
    }

    final attempt = WsRegistrationAttempt.fromJson(decoded);
    if (attempt == null) {
      await clear();
      return null;
    }
    if (attempt.isExpired(maxAge: maxAge, now: now)) {
      await clear();
      return null;
    }
    return attempt;
  }

  Future<void> save(WsRegistrationAttempt attempt) =>
      kv.write(storageKey, jsonEncode(attempt.toJson()));

  /// Called after successful provisioning, or when the user abandons. Both are
  /// the same operation: this attempt is over and must not be resumed.
  Future<void> clear() => kv.remove(storageKey);
}
