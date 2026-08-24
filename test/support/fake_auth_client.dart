// =============================================================================
// test/support/fake_auth_client.dart
// A recording auth client, shared by the verification and flow suites so the
// two cannot drift apart in what they believe the server does.
//
// It exists to drive the three project settings we refuse to assume:
//
//   sessionAfterSignUp  → mailer_autoconfirm
//   autoconfirmPhone    → phone_autoconfirm
//   updatePhoneError    → no SMS provider configured
//
// and to COUNT signInWithPhoneOtp, which must stay at zero.
// =============================================================================

import 'package:watersuppliersaas/services/auth/ws_auth_client.dart';

class FakeAuthClient implements WsAuthClient {
  /// Every call, in order.
  final List<String> calls = [];

  /// Counted separately because "never" is the whole point.
  int signInWithOtpCalls = 0;

  final List<String> phonesSet = [];
  final List<String> tokensTried = [];
  int resendCount = 0;
  String? redirectSeen;
  int signUpCount = 0;

  /// mailer_autoconfirm: does signUp() come back with a session?
  bool sessionAfterSignUp;

  /// phone_autoconfirm: is the phone confirmed without an OTP?
  bool autoconfirmPhone;

  /// The code the fake regards as correct. Anything else is rejected the way
  /// gotrue rejects a wrong code: 403 with the combined message.
  final String goodToken = '123456';

  Object? updatePhoneError;
  Object? verifyError;
  Object? resendError;
  Object? signUpError;

  /// Simulates a server reporting success while leaving the phone unconfirmed.
  bool confirmOnVerify;

  bool _session;
  String? _phone;
  DateTime? _phoneConfirmedAt;

  FakeAuthClient({
    this.sessionAfterSignUp = true,
    this.autoconfirmPhone = false,
    this.updatePhoneError,
    this.verifyError,
    this.resendError,
    this.signUpError,
    this.confirmOnVerify = true,
    bool startSignedIn = false,
  }) : _session = startSignedIn;

  /// Simulates the session going away underneath a half-finished attempt.
  void expireSession() => _session = false;

  @override
  bool get hasSession => _session;

  @override
  WsAuthUser? get currentUser => _session
      ? WsAuthUser(
          id: 'user-1',
          email: 'owner@example.com',
          phone: _phone,
          phoneConfirmedAt: _phoneConfirmedAt,
        )
      : null;

  @override
  Future<WsAuthUser?> signUpWithEmail({
    required String email,
    required String password,
    String? redirectTo,
  }) async {
    calls.add('signUp');
    signUpCount++;
    redirectSeen = redirectTo;
    if (signUpError != null) throw signUpError!;
    _session = sessionAfterSignUp;
    return WsAuthUser(id: 'user-1', email: email);
  }

  @override
  Future<WsAuthUser?> updatePhone(String phone) async {
    calls.add('updatePhone');
    if (updatePhoneError != null) throw updatePhoneError!;
    phonesSet.add(phone);
    _phone = phone;
    if (autoconfirmPhone) _phoneConfirmedAt = DateTime.utc(2026, 8, 14);
    return currentUser;
  }

  @override
  Future<WsAuthUser?> verifyPhoneChangeOtp({
    required String phone,
    required String token,
  }) async {
    calls.add('verifyPhoneChangeOtp');
    tokensTried.add(token);
    if (verifyError != null) throw verifyError!;
    if (token != goodToken) {
      // GoTrue's actual wording, which does not distinguish wrong from expired.
      throw const WsAuthException(
        'Token has expired or is invalid',
        statusCode: 403,
      );
    }
    if (confirmOnVerify) _phoneConfirmedAt = DateTime.utc(2026, 8, 14);
    return currentUser;
  }

  @override
  Future<void> resendPhoneChangeOtp({required String phone}) async {
    calls.add('resend');
    resendCount++;
    if (resendError != null) throw resendError!;
  }

  @override
  Future<WsAuthUser?> signInWithPhoneOtp({
    required String phone,
    required WsOtpChannel channel,
    required bool shouldCreateUser,
  }) async {
    calls.add('signInWithOtp');
    signInWithOtpCalls++;
    return currentUser;
  }
}
