// =============================================================================
// lib/services/auth/ws_auth_supabase.dart
// The real auth client, and the only file in this feature that touches gotrue.
//
// There is NO policy here. Every decision about what a result means lives in
// ws_phone_verification.dart, which has no supabase import and therefore needs
// no network to test. This file translates, and nothing else.
//
// Note what it does NOT do: signInWithPhoneOtp is implemented because the
// interface declares it (so the test can prove registration never reaches it),
// but no production code path calls it. See the warning on WsAuthClient.
// =============================================================================

import 'package:supabase_flutter/supabase_flutter.dart';

import 'ws_auth_client.dart';

class WsSupabaseAuthClient implements WsAuthClient {
  final GoTrueClient _auth;

  WsSupabaseAuthClient(this._auth);

  @override
  bool get hasSession => _auth.currentSession != null;

  @override
  WsAuthUser? get currentUser => _map(_auth.currentUser);

  @override
  Future<WsAuthUser?> signUpWithEmail({
    required String email,
    required String password,
    String? redirectTo,
  }) =>
      _guard(() async {
        // Email only. signUp() asserts email XOR phone — passing both trips an
        // assertion in gotrue, which is why the phone is attached afterwards
        // with updateUser() rather than here.
        final res = await _auth.signUp(
          email: email,
          password: password,
          emailRedirectTo: redirectTo,
        );
        return _map(res.user);
      });

  @override
  Future<WsAuthUser?> updatePhone(String phone) => _guard(() async {
        final res = await _auth.updateUser(UserAttributes(phone: phone));
        return _map(res.user);
      });

  @override
  Future<WsAuthUser?> verifyPhoneChangeOtp({
    required String phone,
    required String token,
  }) =>
      _guard(() async {
        final res = await _auth.verifyOTP(
          phone: phone,
          token: token,
          // phoneChange, NOT sms. OtpType.sms verifies a phone SIGN-IN, which
          // is a different grant against a different user record.
          type: OtpType.phoneChange,
        );
        return _map(res.user);
      });

  @override
  Future<void> resendPhoneChangeOtp({required String phone}) =>
      _guard(() async {
        // No channel argument to drop on the floor: gotrue's resend() has no
        // such parameter, and the interface no longer pretends otherwise.
        await _auth.resend(phone: phone, type: OtpType.phoneChange);
      });

  @override
  Future<WsAuthUser?> signInWithPhoneOtp({
    required String phone,
    required WsOtpChannel channel,
    required bool shouldCreateUser,
  }) =>
      _guard(() async {
        await _auth.signInWithOtp(
          phone: phone,
          channel: channel == WsOtpChannel.whatsapp
              ? OtpChannel.whatsapp
              : OtpChannel.sms,
          shouldCreateUser: shouldCreateUser,
        );
        return _map(_auth.currentUser);
      });

  // ─── translation ───────────────────────────────────────────────────────────

  WsAuthUser? _map(User? u) => u == null
      ? null
      : WsAuthUser(
          id: u.id,
          email: u.email,
          phone: (u.phone?.isEmpty ?? true) ? null : u.phone,
          // Strings on the wire. A value that will not parse is treated as
          // absent rather than as confirmed — the safe direction, because the
          // alternative is provisioning against an unverified number.
          phoneConfirmedAt: _parse(u.phoneConfirmedAt),
          emailConfirmedAt: _parse(u.emailConfirmedAt),
        );

  static DateTime? _parse(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  /// Flattens gotrue's AuthException so the pure layer can classify a failure
  /// without importing supabase.
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on AuthException catch (e) {
      throw WsAuthException(
        e.message,
        code: e.code,
        statusCode: int.tryParse(e.statusCode ?? ''),
      );
    }
  }
}
