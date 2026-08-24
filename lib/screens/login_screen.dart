// =============================================================================
// lib/screens/login_screen.dart
//
// WHAT CHANGED AND WHY
//
// 1. "Customer Portal" was `onPressed: () {}` — a button that did nothing at
//    all. It is gone, not renamed to something that also does nothing.
//
// 2. There is now ONE Login button, and that is deliberate. Two buttons implied
//    two sign-in paths, but there is only one: supabase.auth.signInWithPassword.
//    The destination is decided AFTER sign-in by AuthService.resolveRole(),
//    which reads the caller's membership — a portal membership goes to the
//    customer portal, a staff membership to the dashboard. Asking the user to
//    choose invited them to pick wrong, and the answer was already known.
//
// 3. Forgot password, which did not exist. Supabase reports success whether or
//    not the address is registered, so the confirmation is worded "if that
//    address is registered" — saying "sent" would let a stranger use this form
//    to discover who has an account.
//
// 4. Responsive. The form previously filled the whole window width; on a
//    desktop browser a single text field ran the width of the monitor. Content
//    is now capped at 420 px and centred, and above 900 px the layout becomes
//    two columns with the brand panel beside the form instead of above it.
//
// 5. The "Demo QA: admin@kentwater.pk / admin123" line is gone, along with
//    demo mode itself. The app now connects to Supabase at startup or refuses
//    to start and names the file to fix.
// =============================================================================

import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../theme/ws_responsive.dart';
import '../theme/ws_theme.dart';
import 'register_screen.dart';

class WsLoginScreen extends StatefulWidget {
  const WsLoginScreen({super.key});
  @override
  State<WsLoginScreen> createState() => _WsLoginScreenState();
}

class _WsLoginScreenState extends State<WsLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });

    final navigator = Navigator.of(context);
    try {
      await AuthService.signIn(_email.text.trim(), _password.text);
      if (!mounted) return;
      navigator.pushNamedAndRemoveUntil('/home', (_) => false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendly(e);
      });
    }
  }

  /// Supabase errors are accurate and unhelpful. Translate the common ones.
  String _friendly(Object e) {
    final raw = e.toString();
    if (raw.contains('Invalid login credentials')) {
      return 'Wrong email or password.';
    }
    if (raw.contains('Email not confirmed')) {
      return 'Your email is not confirmed yet. Check your inbox for the '
          'confirmation link, then sign in.';
    }
    if (raw.contains('SocketException') ||
        raw.contains('Failed host lookup') ||
        raw.contains('ClientException')) {
      return 'Cannot reach the server. Check your internet connection.';
    }
    return raw.replaceFirst('Exception: ', '');
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter your email address first, then tap '
          'Forgot password.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });

    try {
      await AuthService.sendPasswordReset(email);
      if (!mounted) return;
      setState(() {
        _loading = false;
        // Deliberately not "we sent you an email" — see the header note.
        _notice = 'If $email is registered, a reset link is on its way. '
            'Check your inbox and spam folder.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendly(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Side-by-side once there is room for it; stacked on anything narrower.
    final wide = MediaQuery.sizeOf(context).width >= 900;

    return Scaffold(
      backgroundColor: WsColors.primary,
      body: SafeArea(
        bottom: false,
        child: wide
            ? Row(
                children: [
                  Expanded(child: _brand(compact: false)),
                  Expanded(
                    child: Container(
                      color: Colors.white,
                      alignment: Alignment.center,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(32),
                        child: WsMaxWidth(maxWidth: 420, child: _form()),
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  Expanded(flex: 4, child: _brand(compact: true)),
                  Expanded(
                    flex: 6,
                    child: Container(
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(32),
                        ),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                        child: WsMaxWidth(maxWidth: 420, child: _form()),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _brand({required bool compact}) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: EdgeInsets.all(compact ? 16 : 22),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.1),
          ),
          child: Icon(
            Icons.water_drop,
            size: compact ? 52 : 72,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'WaterFlow',
          style: TextStyle(
            color: Colors.white,
            fontSize: compact ? 30 : 40,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Water Supplier Management',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );

  Widget _form() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Welcome back',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        const Text(
          'Sign in to continue',
          style: TextStyle(color: WsColors.text3, fontSize: 14),
        ),

        const SizedBox(height: 26),
        _label('Email'),
        const SizedBox(height: 8),
        TextFormField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(hintText: 'you@example.com'),
          validator: (v) {
            final t = (v ?? '').trim();
            if (t.isEmpty) return 'Enter your email';
            if (!t.contains('@') || !t.contains('.')) {
              return 'That does not look like an email address';
            }
            return null;
          },
        ),

        const SizedBox(height: 18),
        _label('Password'),
        const SizedBox(height: 8),
        TextFormField(
          controller: _password,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.done,
          // Enter submits, rather than making the user reach for the button.
          onFieldSubmitted: (_) => _loading ? null : _login(),
          decoration: InputDecoration(
            hintText: '••••••••',
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password',
              icon: Icon(
                _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                size: 20,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          validator: (v) =>
              (v == null || v.isEmpty) ? 'Enter your password' : null,
        ),

        // Small, right-aligned. Deliberately understated: it is a recovery
        // path, not a primary action.
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _loading ? null : _forgotPassword,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Forgot password?',
              style: TextStyle(fontSize: 12, color: WsColors.primary),
            ),
          ),
        ),

        if (_error != null) ...[
          const SizedBox(height: 10),
          _banner(icon: Icons.error_outline, color: WsColors.red, text: _error!),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 10),
          _banner(
            icon: Icons.mark_email_read_outlined,
            color: WsColors.green,
            text: _notice!,
          ),
        ],

        const SizedBox(height: 18),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: _loading ? null : _login,
            style: ElevatedButton.styleFrom(
              backgroundColor: WsColors.primary,
              foregroundColor: Colors.white,
            ),
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Login',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
          ),
        ),

        const SizedBox(height: 20),
        Center(
          child: TextButton(
            onPressed: _loading
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const WsRegisterScreen()),
                  ),
            child: RichText(
              text: const TextSpan(
                text: 'No account? ',
                style: TextStyle(color: WsColors.text3, fontSize: 13),
                children: [
                  TextSpan(
                    text: 'Register your business',
                    style: TextStyle(
                      color: WsColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: WsColors.text2,
    ),
  );

  Widget _banner({
    required IconData icon,
    required Color color,
    required String text,
  }) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
        ),
      ],
    ),
  );
}
