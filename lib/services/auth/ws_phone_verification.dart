// =============================================================================
// lib/services/auth/ws_phone_verification.dart
// The registration sequence, and every rule about it.
//
// ─── THE SEQUENCE, AND WHY IT IS THIS ONE ────────────────────────────────────
//
//     signUp(email, password)
//            ↓                       ← a session exists only if the project has
//     updateUser(phone)                 email confirmation OFF
//            ↓
//     phoneChange OTP
//            ↓
//     verifyOTP(type: phoneChange)
//            ↓
//     caller provisions the organization
//
// Three facts force this shape, each verified against gotrue 2.26.0 rather than
// assumed:
//
//   1. signUp() asserts email XOR phone. One call cannot create a user holding
//      both, so the phone must be attached afterwards.
//   2. linkIdentity() takes an OAuthProvider. There is no phone identity
//      linking, so updateUser() is the only route.
//   3. updateUser() reads currentSession?.accessToken and throws
//      AuthSessionMissingException when it is null. The session must therefore
//      exist BEFORE the OTP, not after it.
//
// The tempting alternative — signInWithOtp(phone:) during registration — would
// create a SECOND auth user keyed on the phone, leaving the owner with two
// accounts and the organization attached to whichever held the session. That is
// the duplicate-identity failure migration 014 prevents for organizations,
// reappearing one layer up where clientuuid cannot see it. This class must
// never call it; test/phone_verification_test.dart asserts that it does not.
//
// ─── SAFE WITHOUT KNOWING THE PROJECT CONFIGURATION ──────────────────────────
//
// Nothing here assumes mailer_autoconfirm, phone_autoconfirm or a configured
// SMS provider. Each is detected from what the server actually returns:
//
//   mailer_autoconfirm  → whether signUp() produced a session
//   phone_autoconfirm   → whether updatePhone() came back already confirmed
//   no SMS provider     → the WsAuthException the send raises, classified below
//
// That is deliberate. Those settings can be changed in the dashboard after this
// ships, so treating them as runtime facts is correct and treating them as
// build-time assumptions would not be.
// =============================================================================

import 'ws_auth_client.dart';

/// Where a registration has got to.
enum WsRegistrationState {
  /// Nothing has happened yet.
  notStarted,

  /// signUp() returned a user but NO session, so the project requires email
  /// confirmation. A phone cannot be attached yet — updateUser() would throw.
  /// Phone verification has to wait until after the first real sign-in, which
  /// is a different product flow and is not decided here.
  emailConfirmationPending,

  /// There is no session where one is required. Distinct from
  /// [emailConfirmationPending]: that is the project's policy on a fresh
  /// sign-up, this is a session that is absent or has expired underneath a
  /// resumed attempt.
  sessionMissing,

  /// The phone is attached and an OTP is on its way.
  phoneOtpSent,

  /// phone_autoconfirm is ON: Supabase marked the number confirmed WITHOUT
  /// sending a code.
  ///
  /// ─── THIS IS NOT PROOF OF OWNERSHIP ──────────────────────────────────────
  ///
  /// Nobody received anything at that number. All that happened is that an
  /// administrative toggle in the Supabase dashboard said not to bother
  /// checking. Treating it as equivalent to [phoneOtpVerified] would turn a
  /// project setting into an anti-abuse guarantee, and the setting can be
  /// changed by anyone with dashboard access, at any time, without a deploy.
  ///
  /// See [WsPhoneAssurance]. Registration may still proceed — otherwise nobody
  /// could register while the toggle is on — but anything that depends on the
  /// number being REAL must require [WsPhoneAssurance.otpProven] specifically.
  phoneAlreadyConfirmed,

  /// A code was sent to the number and came back. The only state in which
  /// somebody demonstrably received a message at that number.
  phoneOtpVerified,
}

/// How much the phone number is actually worth as evidence.
///
/// Kept separate from [WsRegistrationState] because the question "can we
/// continue?" and the question "did someone prove they hold this number?" have
/// different answers, and collapsing them is the mistake this enum exists to
/// prevent.
enum WsPhoneAssurance {
  /// No confirmation of any kind.
  none,

  /// The server says confirmed, but no code was ever delivered — the
  /// phone_autoconfirm case. Good enough to let someone finish signing up.
  /// NOT good enough to gate anything that costs money or grants quota.
  serverAsserted,

  /// A code was delivered to the number and returned. Real evidence.
  otpProven,
}

class WsRegistrationOutcome {
  final WsRegistrationState state;
  final WsAuthUser? user;

  const WsRegistrationOutcome(this.state, {this.user});

  /// Whether the flow may continue to provisioning.
  ///
  /// Deliberately TRUE for [WsRegistrationState.phoneAlreadyConfirmed]: if
  /// phone_autoconfirm is on, refusing here would make registration impossible
  /// rather than secure.
  bool get canProvisionOrganization =>
      state == WsRegistrationState.phoneOtpVerified ||
      state == WsRegistrationState.phoneAlreadyConfirmed;

  /// What the phone number is worth as evidence. Read this — not
  /// [canProvisionOrganization] — before granting quota, trial credit, or
  /// anything else an abuser would want.
  WsPhoneAssurance get assurance {
    switch (state) {
      case WsRegistrationState.phoneOtpVerified:
        return WsPhoneAssurance.otpProven;
      case WsRegistrationState.phoneAlreadyConfirmed:
        return WsPhoneAssurance.serverAsserted;
      case WsRegistrationState.notStarted:
      case WsRegistrationState.emailConfirmationPending:
      case WsRegistrationState.sessionMissing:
      case WsRegistrationState.phoneOtpSent:
        return WsPhoneAssurance.none;
    }
  }

  /// True only when somebody demonstrably received a message at that number.
  bool get isPhoneOwnershipProven =>
      assurance == WsPhoneAssurance.otpProven;

  /// What to actually say. Phrased around what the person can DO next.
  String get message {
    switch (state) {
      case WsRegistrationState.notStarted:
        return '';
      case WsRegistrationState.emailConfirmationPending:
        return 'Check your email and confirm your address, then sign in to '
            'finish setting up your business.';
      case WsRegistrationState.sessionMissing:
        return 'Your sign-in expired. Sign in again to finish setting up your '
            'business.';
      case WsRegistrationState.phoneOtpSent:
        return 'We sent a code to ${user?.phone ?? 'your phone'}.';
      case WsRegistrationState.phoneAlreadyConfirmed:
        return 'Your phone number was confirmed automatically.';
      case WsRegistrationState.phoneOtpVerified:
        return 'Phone number verified.';
    }
  }
}

/// Why an OTP step failed, in the terms a person can act on.
enum WsOtpError {
  expired,
  incorrect,
  rateLimited,
  phoneProviderUnavailable,
  phoneAlreadyInUse,
  sessionMissing,
  invalidNumber,
  unknown;

  String get message {
    switch (this) {
      case WsOtpError.expired:
        return 'That code has expired. Ask for a new one.';
      // Covers BOTH possibilities on purpose. GoTrue answers a wrong code and a
      // timed-out code with the same sentence — "Token has expired or is
      // invalid" — so claiming "that code is wrong" would send someone who
      // simply took too long back to re-typing a code that can never work.
      case WsOtpError.incorrect:
        return 'That code is wrong or has expired. Check it, or ask for a new '
            'one.';
      case WsOtpError.rateLimited:
        return 'Too many attempts. Wait a minute before asking for another '
            'code.';
      case WsOtpError.phoneProviderUnavailable:
        return 'Phone verification is not available right now. You can '
            'continue and verify your number later.';
      case WsOtpError.phoneAlreadyInUse:
        return 'That number is already registered to another account.';
      case WsOtpError.sessionMissing:
        return 'Your sign-in expired. Sign in again to verify your number.';
      case WsOtpError.invalidNumber:
        return 'That does not look like a valid phone number. Include the '
            'country code, for example +923001234567.';
      case WsOtpError.unknown:
        return 'Could not verify the number. Try again.';
    }
  }
}

/// Maps a flattened auth failure onto something actionable.
///
/// Matches on gotrue's error CODE first because that is stable, and falls back
/// to the message only for cases that predate codes. String matching on a
/// human-readable message is a last resort, not the mechanism.
WsOtpError wsClassifyOtpError(Object error) {
  if (error is! WsAuthException) return WsOtpError.unknown;

  switch (error.code) {
    case 'otp_expired':
      return WsOtpError.expired;
    case 'otp_disabled':
    case 'phone_provider_disabled':
    case 'sms_send_failed':
      return WsOtpError.phoneProviderUnavailable;
    case 'over_sms_send_rate_limit':
    case 'over_request_rate_limit':
    case 'over_email_send_rate_limit':
      return WsOtpError.rateLimited;
    case 'phone_exists':
    case 'user_already_exists':
      return WsOtpError.phoneAlreadyInUse;
    case 'session_not_found':
    case 'no_authorization':
      return WsOtpError.sessionMissing;
    case 'validation_failed':
      return WsOtpError.invalidNumber;
  }

  if (error.statusCode == 429) return WsOtpError.rateLimited;

  final m = error.message.toLowerCase();

  // ORDER MATTERS. GoTrue's reply to a wrong code is the combined sentence
  // "Token has expired or is invalid", which contains the word 'expired' and
  // would otherwise be reported as a timeout. The two are genuinely
  // indistinguishable without an error code, so the ambiguous form maps to the
  // value whose message covers both rather than guessing one.
  if (m.contains('expired') && m.contains('invalid')) {
    return WsOtpError.incorrect;
  }
  if (m.contains('expired')) return WsOtpError.expired;
  if (m.contains('invalid') && m.contains('token')) return WsOtpError.incorrect;
  if (m.contains('session')) return WsOtpError.sessionMissing;
  if (error.statusCode == 403 || error.statusCode == 401) {
    return WsOtpError.incorrect;
  }
  return WsOtpError.unknown;
}

// ─── the sequence ─────────────────────────────────────────────────────────────

class WsPhoneVerification {
  final WsAuthClient client;

  /// APPLICATION-LEVEL INTENT ONLY — see [WsOtpChannel].
  ///
  /// The server decides how a phone-change OTP is actually delivered; neither
  /// updateUser() nor resend() accepts a channel, so this value is never put on
  /// the wire. It exists to keep the wording honest ("we sent a WhatsApp
  /// message" vs "we sent a text") and to give the eventual switch one place to
  /// live.
  ///
  /// Do NOT surface this as a user-facing toggle. A control that claims to
  /// choose the transport while the server ignores it is worse than no control.
  final WsOtpChannel channel;

  const WsPhoneVerification(this.client, {this.channel = WsOtpChannel.sms});

  /// Step one. Creates the auth user, then attaches the phone IF a session came
  /// back with it.
  ///
  /// Returns [WsRegistrationState.emailConfirmationPending] rather than
  /// throwing when there is no session. That is not a failure — it is the
  /// project telling us it requires email confirmation, and the caller's job is
  /// to say so, not to retry.
  Future<WsRegistrationOutcome> startRegistration({
    required String email,
    required String password,
    required String phone,
    String? redirectTo,
  }) async {
    // Rejected before signUp, not after: a bad number would otherwise leave a
    // half-registered auth user behind for a mistake we could see coming.
    final normalised = _requireValidPhone(phone);

    final user = await client.signUpWithEmail(
      email: email.trim(),
      password: password,
      redirectTo: redirectTo,
    );

    if (!client.hasSession) {
      return WsRegistrationOutcome(
        WsRegistrationState.emailConfirmationPending,
        user: user,
      );
    }

    return attachPhone(normalised);
  }

  /// Attaches the phone to the CURRENT user and triggers the phone-change OTP.
  ///
  /// Separate from [startRegistration] because the retry path needs it on its
  /// own: someone who closed the app between signUp and the code has a session
  /// and no confirmed phone, and must be able to resume without registering a
  /// second time.
  Future<WsRegistrationOutcome> attachPhone(String phone) async {
    final normalised = _requireValidPhone(phone);

    if (!client.hasSession) {
      throw const WsAuthException(
        'A session is required to attach a phone number.',
        code: 'session_not_found',
      );
    }

    final user = await client.updatePhone(normalised);

    // phone_autoconfirm ON: confirmed on the spot, no OTP sent, nothing to
    // wait for. Detected rather than assumed, because the setting can be
    // changed in the dashboard long after this ships.
    if (user != null && user.isPhoneConfirmed && user.phone == normalised) {
      return WsRegistrationOutcome(
        WsRegistrationState.phoneAlreadyConfirmed,
        user: user,
      );
    }

    return WsRegistrationOutcome(
      WsRegistrationState.phoneOtpSent,
      user: user ?? client.currentUser,
    );
  }

  /// Step two. Verifies the code.
  ///
  /// Succeeds only when the server reports the phone as confirmed. A response
  /// that comes back unconfirmed is treated as a failure rather than quietly
  /// passing: this result is the provisioning gate, and defaulting it open
  /// would defeat the whole sequence.
  Future<WsRegistrationOutcome> confirmPhone({
    required String phone,
    required String token,
  }) async {
    final normalised = _requireValidPhone(phone);
    final code = token.trim();

    if (code.isEmpty) {
      throw const WsAuthException('Enter the code.', code: 'validation_failed');
    }

    final user = await client.verifyPhoneChangeOtp(
      phone: normalised,
      token: code,
    );

    if (user == null || !user.isPhoneConfirmed) {
      throw const WsAuthException(
        'The number was not confirmed.',
        code: 'otp_not_confirmed',
      );
    }

    return WsRegistrationOutcome(
      WsRegistrationState.phoneOtpVerified,
      user: user,
    );
  }

  /// Asks for another code.
  ///
  /// No local cooldown timer. Supabase owns the resend interval and returns 429
  /// past it; duplicating that here would mean two clocks disagreeing, and the
  /// client's would be the wrong one.
  /// The channel is deliberately not passed: the API cannot carry it and the
  /// server owns the decision.
  Future<void> resendCode(String phone) =>
      client.resendPhoneChangeOtp(phone: _requireValidPhone(phone));

  String _requireValidPhone(String phone) {
    if (!wsIsValidPhone(phone)) {
      throw const WsAuthException(
        'Enter the number in international format, for example +923001234567.',
        code: 'validation_failed',
      );
    }
    return wsNormalisePhone(phone);
  }
}
