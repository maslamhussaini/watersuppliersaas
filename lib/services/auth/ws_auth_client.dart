// =============================================================================
// lib/services/auth/ws_auth_client.dart
// The auth seam. No supabase import lives in this file.
//
// ─── WHY A SEAM ──────────────────────────────────────────────────────────────
//
// The rule this phase exists to protect is a NEGATIVE one: registration must
// never call signInWithOtp(), because signInWithOtp(phone:) with the default
// shouldCreateUser: true creates a SECOND auth user keyed on the phone number.
// The owner would then hold two accounts, and the organization would be
// provisioned against whichever one happened to own the session — the same
// duplicate-identity failure migration 014 exists to prevent, one layer up
// where clientuuid cannot see it.
//
// A negative asserted against source text ("no file greps for signInWithOtp")
// passes today and quietly stops meaning anything the moment somebody adds the
// call in a new file. So signInWithPhoneOtp IS declared here, deliberately, and
// the fake in test/phone_verification_test.dart counts how many times it was
// invoked. The assertion is then an OBSERVATION of behaviour rather than a
// claim about text, and it fails when the behaviour changes.
//
// The split mirrors location_service.dart / location_geolocator.dart: every
// rule lives on this side and needs no network to exercise, and the adapter in
// ws_auth_supabase.dart contains no policy at all.
//
// ─── ON CHANNELS ─────────────────────────────────────────────────────────────
//
// Read [WsOtpChannel] before assuming the channel argument does what it looks
// like it does on the phone-change path. It does not, and that is a property of
// gotrue 2.26.0 rather than of this code.
// =============================================================================

/// Which transport an OTP should travel over.
///
/// ─── WHAT THIS CAN AND CANNOT DO ────────────────────────────────────────────
///
/// gotrue 2.26.0 accepts a channel on exactly ONE call: signInWithOtp(). It is
/// absent from both updateUser() and resend():
///
///     resend({String? email, String? phone, required OtpType type,
///             String? emailRedirectTo, String? captchaToken})
///
/// The phone-CHANGE OTP this app sends is produced by updateUser(phone:) and
/// re-sent by resend(type: phoneChange). Neither accepts a channel, so both go
/// out over whatever the Supabase project is configured to use.
///
/// That leaves exactly one place a channel could be honoured, and it is the one
/// call registration is forbidden to make.
///
/// ─── SO IT IS NOT ON THE WIRE METHODS ────────────────────────────────────────
///
/// [WsAuthClient.resendPhoneChangeOtp] deliberately does NOT take this enum.
/// An argument that is accepted and then dropped reads, at the call site, like
/// a capability — and the first person to pass `whatsapp`, watch an SMS
/// arrive, and go looking for the bug would look in the wrong layer. The
/// signature now says what is true: the delivery channel for a phone change is
/// SERVER-CONTROLLED and this app cannot influence it per-request.
///
/// The enum survives as application-level INTENT on [WsPhoneVerification], for
/// wording ("we sent a WhatsApp message") and as the one place to change when
/// gotrue carries it. It must never become a user-facing switch while the
/// server decides, because the switch would not do anything.
///
/// Moving the project to WhatsApp is a Supabase-side change — Twilio or Twilio
/// Verify are the only providers that carry it.
enum WsOtpChannel {
  sms,
  whatsapp;

  String get wireName => name;
}

/// The subset of an auth user this app reasons about.
///
/// Deliberately not gotrue's User: that type would drag the supabase import
/// across the seam and make every one of these rules need a network stub.
class WsAuthUser {
  final String id;
  final String? email;
  final String? phone;

  /// Non-null once the phone has been confirmed.
  ///
  /// THIS IS THE phone_autoconfirm DETECTOR. When that project setting is on,
  /// a phone change is confirmed without an OTP ever being sent, and this field
  /// comes back populated from updateUser() itself. Without checking it the
  /// verification screen would sit waiting for a code that was never sent, and
  /// the "verified" flag would mean nothing.
  final DateTime? phoneConfirmedAt;

  final DateTime? emailConfirmedAt;

  const WsAuthUser({
    required this.id,
    this.email,
    this.phone,
    this.phoneConfirmedAt,
    this.emailConfirmedAt,
  });

  bool get isPhoneConfirmed => phoneConfirmedAt != null;
  bool get isEmailConfirmed => emailConfirmedAt != null;
}

/// An auth failure, flattened so the pure layer can classify it without
/// importing gotrue's AuthException.
class WsAuthException implements Exception {
  final String message;

  /// gotrue's error code where it supplies one — 'otp_expired',
  /// 'over_sms_send_rate_limit', 'phone_provider_disabled' and so on.
  final String? code;

  final int? statusCode;

  const WsAuthException(this.message, {this.code, this.statusCode});

  @override
  String toString() => 'WsAuthException($code/$statusCode): $message';
}

/// Every auth operation this app performs. Implemented once against Supabase
/// and once as a recording fake in the tests.
abstract class WsAuthClient {
  /// True when a session exists. After signUp this is the single fact that
  /// decides whether a phone can be attached at all: updateUser() throws
  /// AuthSessionMissingException without one.
  bool get hasSession;

  WsAuthUser? get currentUser;

  Future<WsAuthUser?> signUpWithEmail({
    required String email,
    required String password,
    String? redirectTo,
  });

  /// updateUser(UserAttributes(phone: ...)). Requires a session. Sends the
  /// phone-change OTP as a side effect — unless phone_autoconfirm is on, in
  /// which case it confirms immediately and sends nothing.
  Future<WsAuthUser?> updatePhone(String phone);

  /// verifyOTP(phone:, token:, type: OtpType.phoneChange).
  Future<WsAuthUser?> verifyPhoneChangeOtp({
    required String phone,
    required String token,
  });

  /// resend(phone:, type: OtpType.phoneChange).
  ///
  /// No channel parameter, and that is the honest signature: gotrue's resend()
  /// does not accept one, so the transport is whatever the project is set to.
  /// See [WsOtpChannel].
  Future<void> resendPhoneChangeOtp({required String phone});

  /// ─── DO NOT CALL THIS DURING REGISTRATION ────────────────────────────────
  ///
  /// Declared so that "registration never calls it" is a testable observation
  /// rather than an unenforceable comment. There is currently NO production
  /// caller, and [WsPhoneVerification] must never become one.
  ///
  /// With shouldCreateUser: true this creates a new auth user keyed on the
  /// phone number. That is legitimate only for a future phone-first SIGN-IN
  /// feature on an already-verified number, never for attaching a phone to an
  /// account that already exists.
  Future<WsAuthUser?> signInWithPhoneOtp({
    required String phone,
    required WsOtpChannel channel,
    required bool shouldCreateUser,
  });
}

// ─── PHONE NUMBERS ────────────────────────────────────────────────────────────

/// Normalises a number towards E.164, which is the only format the SMS
/// providers accept.
///
/// Strips spaces, dashes, brackets and dots, and turns a leading 00 into +.
/// Deliberately does NOT guess a country code: inferring +92 because the app
/// happens to be used in Pakistan would silently send a customer's OTP to a
/// different country's number the first time someone types a local format.
String wsNormalisePhone(String input) {
  var s = input.trim().replaceAll(RegExp(r'[\s\-\(\)\.]'), '');
  if (s.startsWith('00')) s = '+${s.substring(2)}';
  return s;
}

/// E.164: a plus, a non-zero country digit, then 7 to 14 more digits.
bool wsIsValidPhone(String input) =>
    RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(wsNormalisePhone(input));
