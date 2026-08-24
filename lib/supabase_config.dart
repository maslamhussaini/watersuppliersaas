// =============================================================================
// lib/supabase_config.dart
// Credentials come from the .env file in the project root.
//
// Create `.env` (copy .env.example):
//
//     SUPABASE_URL=https://your-project-ref.supabase.co
//     SUPABASE_ANON_KEY=eyJhbGciOi...
//
// Then plain `flutter run` connects. No flags.
//
// ─── PRECEDENCE ───────────────────────────────────────────────────────────────
//   1. --dart-define        build-time, wins when supplied (CI, staging)
//   2. .env                 runtime, the normal path
//   3. neither              the app refuses to start and says so
//
// ─── ONE THING YOU MUST UNDERSTAND ────────────────────────────────────────────
// flutter_dotenv reads .env through rootBundle, which means .env has to be
// declared as a Flutter ASSET (see pubspec.yaml). On a WEB build every asset is
// copied into build/web/assets and is downloadable by anyone who visits the
// site. Your .env is therefore public on web.
//
// That is acceptable for the anon key and ONLY the anon key. It is public by
// design — it already ships inside every client bundle, and anyone can read it
// out of the compiled JavaScript in about a minute. What actually protects your
// data is the row level security in migration 008: the database refuses to
// return another tenant's rows regardless of who is asking.
//
// It is NOT acceptable for anything else. Never put a service_role key, a
// database password, or a third-party API secret in this file — on web you are
// publishing it. The check below refuses to start on a service_role key, but it
// cannot catch every kind of secret you might paste in.
//
// If you later need real secrets in the app, they belong behind a Supabase Edge
// Function, not in .env.
// =============================================================================

import 'package:flutter_dotenv/flutter_dotenv.dart';

class WsConfig {
  const WsConfig._();

  // Build-time overrides. Empty unless --dart-define is passed.
  static const _defineUrl = String.fromEnvironment('SUPABASE_URL');
  static const _defineAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const _defineRedirect = String.fromEnvironment('SUPABASE_REDIRECT_URL');

  /// Where confirmation and password-reset links land.
  ///
  /// This was hard-coded in two places in auth_service.dart — the sign-up
  /// confirmation link and the password-reset link — which meant a staging
  /// deploy silently mailed its users back to production.
  ///
  /// The fallback is the previous literal, so leaving SUPABASE_REDIRECT_URL
  /// unset reproduces the old behaviour exactly.
  ///
  /// Whatever this resolves to must also be listed under Authentication → URL
  /// Configuration in the Supabase dashboard, or the link in the email is
  /// rejected on arrival.
  static const _fallbackRedirect = 'https://watersuppliersaas.vercel.app/';

  static bool _loaded = false;
  static String _envError = '';

  /// Reads .env. Call once from main() before touching [url] or [anonKey].
  ///
  /// A missing .env is not thrown — it is recorded, so main() can show a setup
  /// screen naming the file instead of dying with a stack trace.
  static Future<void> load() async {
    try {
      await dotenv.load(fileName: '.env');
      _loaded = true;
    } catch (e) {
      _loaded = false;
      _envError = '$e';
    }
  }

  static String _read(String key, String fromDefine) {
    if (fromDefine.isNotEmpty) return fromDefine;
    if (!_loaded) return '';
    return dotenv.env[key]?.trim() ?? '';
  }

  static String get url => _read('SUPABASE_URL', _defineUrl);
  static String get anonKey => _read('SUPABASE_ANON_KEY', _defineAnonKey);

  /// See [_fallbackRedirect]. Never empty: an empty redirect would make
  /// Supabase fall back to the project's Site URL, which is a different
  /// behaviour again and not the one this replaced.
  static String get redirectUrl {
    final configured = _read('SUPABASE_REDIRECT_URL', _defineRedirect);
    return configured.isEmpty ? _fallbackRedirect : configured;
  }

  /// True once both values are present and the URL looks like a URL. Catches
  /// the placeholder text from .env.example before it produces a confusing
  /// failure three screens later.
  static bool get isConfigured =>
      url.isNotEmpty &&
      anonKey.isNotEmpty &&
      url.startsWith('http') &&
      !url.contains('your-project-ref') &&
      !anonKey.contains('your-anon-key');

  /// A service_role JWT carries "service_role" in its payload. Cheap to check,
  /// and the consequence of missing it is total: that key bypasses RLS, so a
  /// web build carrying one hands every tenant's data to any visitor.
  static bool get looksLikeServiceRoleKey => anonKey.contains('service_role');

  /// Why configuration failed, for the setup screen.
  static String get diagnosis {
    if (!_loaded && _defineUrl.isEmpty) {
      return 'No .env file found in the project root.\n\n'
          'Copy .env.example to .env and fill in your Supabase URL and anon '
          'key.\n\n$_envError';
    }
    if (url.isEmpty) return 'SUPABASE_URL is missing from .env';
    if (anonKey.isEmpty) return 'SUPABASE_ANON_KEY is missing from .env';
    if (!url.startsWith('http')) {
      return 'SUPABASE_URL does not look like a URL: $url';
    }
    return 'The values in .env are still the placeholders from .env.example.';
  }
}
