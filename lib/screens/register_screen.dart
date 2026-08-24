// =============================================================================
// lib/screens/register_screen.dart
// Registration as a three-step wizard: You → Your business → Confirm.
//
// WHY A WIZARD AND NOT ONE LONG FORM
// The previous screen asked for seven fields in one column with no validation
// and no way to tell which of them mattered. Registration is also the one form
// in the app a user fills in exactly once, under the least context — so it
// pays to ask a few things at a time and say why.
//
// EACH STEP VALIDATES BEFORE IT ADVANCES. A wizard that lets you reach the end
// with a bad email and then fails on submit is worse than a long form, because
// it hides the offending field behind a Back button.
//
// ON EMAIL CONFIRMATION
// If the Supabase project has "Confirm email" enabled, signUp returns no
// session, so the organization-creating RPC cannot run as the new user. The
// final step says so rather than dropping the user on a dashboard that has no
// organization — which is exactly the state three of your users ended up in.
// =============================================================================

import 'package:flutter/material.dart';

import '../services/auth/ws_auth_client.dart';
import '../services/auth/ws_phone_verification.dart';
import '../services/auth/ws_registration_flow.dart';
import '../services/auth_service.dart';
import '../theme/ws_responsive.dart';
import '../theme/ws_theme.dart';

/// The three things this screen needs from the outside world.
///
/// A SEAM, NOT A SERVICE LOCATOR. It exists because AuthService reaches
/// main.dart's `supabase` getter, which needs a live client — so without this
/// the screen could not be pumped at all, and the widget tests had to assert on
/// the contract instead of the widgets. That gap is what let a wiring mistake
/// inside build() go unnoticed.
///
/// Production passes nothing and gets [WsRegistrationDeps.production].
class WsRegistrationDeps {
  final Future<WsRegistrationFlow?> Function() resume;
  final Future<WsRegistrationFlow> Function({
    required String email,
    required String orgName,
    required String ownerName,
    required String orgPhone,
    required String address,
  }) begin;
  final Future<int> Function(WsRegistrationFlow) provision;

  const WsRegistrationDeps({
    required this.resume,
    required this.begin,
    required this.provision,
  });

  factory WsRegistrationDeps.production() => WsRegistrationDeps(
        resume: () => AuthService.resumeRegistration(),
        begin: ({
          required String email,
          required String orgName,
          required String ownerName,
          required String orgPhone,
          required String address,
        }) =>
            AuthService.beginRegistration(
          email: email,
          orgName: orgName,
          ownerName: ownerName,
          orgPhone: orgPhone,
          address: address,
        ),
        provision: AuthService.provisionForRegistration,
      );
}

class WsRegisterScreen extends StatefulWidget {
  /// Null in production. Injected by widget tests.
  final WsRegistrationDeps? deps;

  const WsRegisterScreen({super.key, this.deps});
  @override
  State<WsRegisterScreen> createState() => _WsRegisterScreenState();
}

class _WsRegisterScreenState extends State<WsRegisterScreen> {
  static const _steps = 3;
  int _step = 0;

  // One form key per step, so validation is scoped to the fields on screen.
  final _keys = List.generate(_steps, (_) => GlobalKey<FormState>());

  final _fullName = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  /// THE SCREEN NO LONGER OWNS THE KEY.
  ///
  /// It used to hold `String _clientUuid = wsNewUuid()` in this State, which
  /// was safe only while registration was one synchronous submit. With an OTP
  /// in the middle the attempt now spans an out-of-band SMS, and State does not
  /// survive a browser reload — so a returning user got a fresh key and
  /// provisioned a SECOND organization that migration 014 could not recognise
  /// as a duplicate.
  ///
  /// WsRegistrationFlow owns it now, and persists it. Null until initState has
  /// resumed or begun an attempt.
  WsRegistrationFlow? _flow;
  bool _restoring = true;

  /// True when the attempt store could not be read.
  ///
  /// The form STAYS USABLE — refusing to register because a cache is unreadable
  /// would be worse than the problem. But it must not silently pretend the
  /// attempt is being saved: if this session is interrupted the user has to
  /// start again, and they deserve to know that before they start waiting for
  /// an SMS.
  bool _persistenceUnavailable = false;

  late final WsRegistrationDeps _deps =
      widget.deps ?? WsRegistrationDeps.production();

  final _code = TextEditingController();

  final _orgName = TextEditingController();
  final _orgAddress = TextEditingController();
  final _orgPhone = TextEditingController();

  bool _obscure = true;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  /// Resume before starting. A reload lands here with the attempt already on
  /// disk, and beginning a new one would mint a second key.
  Future<void> _restore() async {
    try {
      final existing = await _deps.resume();
      if (!mounted) return;
      if (existing != null) {
        setState(() {
          _flow = existing;
          _email.text = existing.email;
          _orgName.text = existing.orgName;
          _ownerFrom(existing);
          _phone.text = existing.phone ?? '';
          _restoring = false;
        });

        // A RESUMED ATTEMPT MAY ALREADY BE PAST THE GATE. Someone whose
        // provisioning failed — or whose response was lost — comes back in
        // phoneOtpVerified with nothing left to do but retry. Without this the
        // screen rendered its progress spinner and sat there forever, because
        // provisioning was only reachable from submit and verify.
        //
        // Found by the widget test, not by reading: every service-level test
        // called provisionOrganization explicitly, so none of them noticed that
        // no UI path did.
        await _provisionIfReady();
        return;
      }
    } catch (_) {
      // Storage unavailable: registration still works, it just cannot be
      // resumed. Recorded rather than swallowed — see _persistenceUnavailable.
      if (mounted) setState(() => _persistenceUnavailable = true);
    }
    if (mounted) setState(() => _restoring = false);
  }

  void _ownerFrom(WsRegistrationFlow f) {
    _fullName.text = f.ownerName;
    _orgPhone.text = f.orgPhone;
    _orgAddress.text = f.address;
  }

  @override
  void dispose() {
    _code.dispose();
    for (final c in [
      _fullName, _phone, _email, _password, _confirm,
      _orgName, _orgAddress, _orgPhone,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _next() {
    if (!(_keys[_step].currentState?.validate() ?? false)) return;
    setState(() { _error = null; _step++; });
  }

  void _back() => setState(() { _error = null; _step--; });

  Future<void> _submit() async {
    setState(() { _loading = true; _error = null; });
    try {
      final flow = _flow ??= await _deps.begin(
        email: _email.text.trim(),
        orgName: _orgName.text.trim(),
        ownerName: _fullName.text.trim(),
        // The business phone if given, otherwise the personal one. Unchanged
        // from before: this is the ORGANISATION's contact number and is not
        // the identity phone being verified.
        orgPhone: _orgPhone.text.trim().isEmpty
            ? _phone.text.trim()
            : _orgPhone.text.trim(),
        address: _orgAddress.text.trim(),
      );

      await flow.start(
        email: _email.text.trim(),
        password: _password.text,
        phone: _phone.text.trim(),
      );

      if (!mounted) return;
      setState(() => _loading = false);
      await _provisionIfReady();
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = _friendly(e); });
    }
  }

  Future<void> _verify() async {
    final flow = _flow;
    if (flow == null) return;
    setState(() { _loading = true; _error = null; });
    await flow.submitCode(_code.text.trim());
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = flow.lastError?.message;
    });
    await _provisionIfReady();
  }

  Future<void> _resend() async {
    final flow = _flow;
    if (flow == null) return;
    setState(() { _loading = true; _error = null; });
    await flow.resendCode();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = flow.lastError?.message;
    });
  }

  /// Provisions ONLY when the state machine says the gate is open. The screen
  /// never decides this for itself — phoneAlreadyConfirmed and phoneOtpVerified
  /// both qualify, and they are not equally strong evidence.
  Future<void> _provisionIfReady() async {
    final flow = _flow;
    if (flow == null || !flow.canProvisionOrganization) return;

    setState(() { _loading = true; _error = null; });
    try {
      await _deps.provision(flow);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Account created.')));
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
    } catch (e) {
      if (!mounted) return;
      // The attempt is deliberately still on disk — the RPC may have committed
      // and the retry has to resolve to the same organization.
      setState(() { _loading = false; _error = _friendly(e); });
    }
  }

  String _friendly(Object e) {
    final raw = e.toString();
    if (raw.contains('User already registered') ||
        raw.contains('already registered')) {
      return 'That email already has an account. Sign in instead, or use '
          'Forgot password.';
    }
    if (raw.contains('Password should be at least')) {
      return 'Password is too short — use at least 6 characters.';
    }
    if (raw.contains('SocketException') ||
        raw.contains('Failed host lookup') ||
        raw.contains('ClientException')) {
      return 'Cannot reach the server. Check your internet connection.';
    }
    return raw.replaceFirst('Exception: ', '');
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;

    // Resuming reads from storage, so the first frame must not show an empty
    // form that the restore then overwrites under the user's fingers.
    if (_restoring) {
      return const Scaffold(
        backgroundColor: WsColors.primary,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return Scaffold(
      backgroundColor: WsColors.primary,
      body: SafeArea(
        bottom: false,
        child: wide
            ? Row(children: [
                Expanded(child: _brand()),
                Expanded(
                  child: Container(
                    color: Colors.white,
                    alignment: Alignment.center,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(32),
                      child: WsMaxWidth(
                          maxWidth: 460, child: _statePanel() ?? _wizard()),
                    ),
                  ),
                ),
              ])
            : Column(children: [
                SizedBox(height: 96, child: _brand(compact: true)),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(28)),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
                      child: WsMaxWidth(
                          maxWidth: 460, child: _statePanel() ?? _wizard()),
                    ),
                  ),
                ),
              ]),
      ),
    );
  }

  Widget _brand({bool compact = false}) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.water_drop,
            size: compact ? 34 : 68, color: Colors.white),
        SizedBox(height: compact ? 6 : 14),
        Text(
          'WaterFlow',
          style: TextStyle(
            color: Colors.white,
            fontSize: compact ? 20 : 34,
            fontWeight: FontWeight.bold,
          ),
        ),
        if (!compact) ...[
          const SizedBox(height: 6),
          const Text('Set up your business in three steps',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ],
    ),
  );

  // ── Wizard shell ───────────────────────────────────────────────────────────

  /// Every state the machine can be in has a screen. Falling through to /home
  /// is what the old code did when signUp returned no session: it announced
  /// "Account created", pushed the dashboard, and the auth gate bounced the
  /// user back to login with no explanation of the email waiting for them.
  Widget? _statePanel() {
    final flow = _flow;
    if (flow == null) return null;

    switch (flow.state) {
      case WsRegistrationState.notStarted:
        return null;

      case WsRegistrationState.emailConfirmationPending:
        return _notice(
          Icons.mark_email_unread_outlined,
          'Confirm your email',
          'Your account exists but your business has NOT been created yet.\n\n'
          'Click the link we sent to ${_email.text.trim()}, then sign in — '
          'we will pick up exactly where you left off.',
          'Back to sign in',
          () => Navigator.of(context).pop(),
        );

      case WsRegistrationState.sessionMissing:
        return _notice(
          Icons.lock_clock_outlined,
          'Your session expired',
          'Sign in again and your registration will continue from here. '
          'Nothing you entered has been lost.',
          'Sign in',
          () => Navigator.of(context).pop(),
        );

      case WsRegistrationState.phoneOtpSent:
        return _otpStep();

      // Both of these are handled by _provisionIfReady, which runs as soon as
      // the state is reached. Showing a spinner is honest: work is in flight.
      case WsRegistrationState.phoneAlreadyConfirmed:
      case WsRegistrationState.phoneOtpVerified:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        );
    }
  }

  Widget _notice(IconData icon, String title, String body, String action,
          VoidCallback onAction) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 12),
        Icon(icon, size: 44, color: WsColors.primary),
        const SizedBox(height: 14),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Text(body,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 13, height: 1.5, color: WsColors.text2)),
        const SizedBox(height: 22),
        SizedBox(
          height: 46,
          child: ElevatedButton(onPressed: onAction, child: Text(action)),
        ),
      ]);

  Widget _otpStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const WsFormSection('Verify your phone', first: true),
          Text(
            'Enter the code we sent to ${_flow?.phone ?? 'your phone'}.',
            style: const TextStyle(
                fontSize: 12, height: 1.5, color: WsColors.text2),
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _code,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            decoration: const InputDecoration(labelText: 'Verification code *'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                style: const TextStyle(fontSize: 12, color: WsColors.red)),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 46,
            child: ElevatedButton(
              onPressed: _loading ? null : _verify,
              child: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Verify'),
            ),
          ),
          const SizedBox(height: 8),
          // No SMS/WhatsApp selector: the channel is server-controlled and a
          // toggle here would not change what is sent.
          TextButton(
            onPressed: _loading ? null : _resend,
            child: const Text('Send a new code'),
          ),
        ],
      );

  Widget _wizard() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_persistenceUnavailable) ...[
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: WsColors.amber.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            'This browser cannot save your progress, so finish signing up in '
            'one go — if you close this tab you will need to start again.',
            style: TextStyle(fontSize: 11, height: 1.4),
          ),
        ),
        const SizedBox(height: 14),
      ],
      _progress(),
      const SizedBox(height: 20),
      Form(
        key: _keys[_step],
        child: switch (_step) {
          0 => _stepYou(),
          1 => _stepBusiness(),
          _ => _stepConfirm(),
        },
      ),
      if (_error != null) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: WsColors.red.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: WsColors.red.withValues(alpha: 0.3)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.error_outline, size: 18, color: WsColors.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_error!,
                  style: const TextStyle(fontSize: 12, height: 1.4)),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 22),
      Row(children: [
        if (_step > 0)
          Expanded(
            child: OutlinedButton(
              onPressed: _loading ? null : _back,
              child: const Text('Back'),
            ),
          ),
        if (_step > 0) const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 46,
            child: ElevatedButton(
              onPressed: _loading
                  ? null
                  : (_step == _steps - 1 ? _submit : _next),
              child: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_step == _steps - 1 ? 'Create account' : 'Continue'),
            ),
          ),
        ),
      ]),
      const SizedBox(height: 14),
      Center(
        child: TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Already have an account? Sign in',
              style: TextStyle(fontSize: 13)),
        ),
      ),
    ],
  );

  Widget _progress() {
    const labels = ['You', 'Business', 'Confirm'];
    return Column(children: [
      Row(children: [
        for (var i = 0; i < _steps; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                color: i <= _step ? WsColors.primary : WsColors.border,
              ),
            ),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i <= _step ? WsColors.primary : WsColors.border,
            ),
            child: Center(
              child: i < _step
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: i <= _step ? Colors.white : WsColors.text2,
                      ),
                    ),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < _steps; i++)
            Text(
              labels[i],
              style: TextStyle(
                fontSize: 11,
                fontWeight: i == _step ? FontWeight.w700 : FontWeight.w400,
                color: i <= _step ? WsColors.primary : WsColors.text3,
              ),
            ),
        ],
      ),
    ]);
  }

  // ── Step 1 ────────────────────────────────────────────────────────────────

  Widget _stepYou() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const WsFormSection('About you', first: true),
      TextFormField(
        controller: _fullName,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Your full name *'),
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: _phone,
        keyboardType: TextInputType.phone,
        decoration: const InputDecoration(
          labelText: 'Your phone *',
          helperText: 'We send a verification code here. Include the country '
              'code, e.g. +923001234567.',
        ),
        // REQUIRED NOW, and validated here rather than by the SMS provider —
        // an unverifiable number would strand the account halfway through
        // registration with an auth user and no organization.
        validator: (v) {
          final t = (v ?? '').trim();
          if (t.isEmpty) return 'Enter your phone number';
          if (!wsIsValidPhone(t)) {
            return 'Include the country code, e.g. +923001234567';
          }
          return null;
        },
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        decoration: const InputDecoration(
          labelText: 'Email *',
          helperText: 'You will sign in with this address.',
        ),
        validator: (v) {
          final t = (v ?? '').trim();
          if (t.isEmpty) return 'Enter your email';
          if (!t.contains('@') || !t.contains('.')) {
            return 'That does not look like an email address';
          }
          return null;
        },
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: _password,
        obscureText: _obscure,
        decoration: InputDecoration(
          labelText: 'Password *',
          helperText: 'At least 6 characters.',
          suffixIcon: IconButton(
            tooltip: _obscure ? 'Show' : 'Hide',
            icon: Icon(
                _obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
        validator: (v) => (v == null || v.length < 6)
            ? 'Use at least 6 characters'
            : null,
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: _confirm,
        obscureText: _obscure,
        decoration: const InputDecoration(labelText: 'Confirm password *'),
        // Caught here rather than by Supabase, which has no idea you typed it
        // twice and would happily create the account with the typo.
        validator: (v) =>
            v != _password.text ? 'Passwords do not match' : null,
      ),
    ],
  );

  // ── Step 2 ────────────────────────────────────────────────────────────────

  Widget _stepBusiness() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const WsFormSection('Your business', first: true),
      TextFormField(
        controller: _orgName,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Business name *',
          helperText: 'Printed on delivery cards and receipts.',
        ),
        validator: (v) => (v == null || v.trim().isEmpty)
            ? 'Enter your business name'
            : null,
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: _orgPhone,
        keyboardType: TextInputType.phone,
        decoration: const InputDecoration(
          labelText: 'Business phone',
          helperText: 'Leave blank to use your own number.',
        ),
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: _orgAddress,
        maxLines: 3,
        decoration: const InputDecoration(labelText: 'Business address'),
      ),
      const SizedBox(height: 12),
      const Text(
        'A chart of accounts, default roles and a trial subscription are '
        'created with your business. You can change all of it later under '
        'Setup.',
        style: TextStyle(fontSize: 11, height: 1.5, color: WsColors.text3),
      ),
    ],
  );

  // ── Step 3 ────────────────────────────────────────────────────────────────

  Widget _stepConfirm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const WsFormSection('Check and confirm', first: true),
      _summary('Name', _fullName.text.trim()),
      _summary('Email', _email.text.trim()),
      _summary('Phone', _phone.text.trim()),
      const Divider(height: 24),
      _summary('Business', _orgName.text.trim()),
      _summary(
        'Business phone',
        _orgPhone.text.trim().isEmpty
            ? '${_phone.text.trim()} (yours)'
            : _orgPhone.text.trim(),
      ),
      _summary('Address', _orgAddress.text.trim()),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: WsColors.primarySurface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'If your project requires email confirmation, you will need to click '
          'the link we send before your business can be created. Sign in again '
          'afterwards and it will finish setting up.',
          style: TextStyle(fontSize: 11, height: 1.5, color: WsColors.text2),
        ),
      ),
    ],
  );

  Widget _summary(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 120,
        child: Text(label,
            style: const TextStyle(fontSize: 12, color: WsColors.text2)),
      ),
      Expanded(
        child: Text(
          value.isEmpty ? '—' : value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: value.isEmpty ? WsColors.text3 : WsColors.text1,
          ),
        ),
      ),
    ]),
  );
}
