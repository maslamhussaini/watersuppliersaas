# APPLY.md — credentials from .env

## ⚠ NOT ANALYZER-VERIFIED
No Flutter SDK here. All ten changed files pass a real brace/paren/bracket
balance check (comment- and string-aware), and every identifier was checked
against your codebase — but that is not a compiler.
**Run `flutter analyze` before `flutter run`.**

## Setup — once

```
copy .env.example .env
```

Then edit `.env`:

```
SUPABASE_URL=https://your-project-ref.supabase.co
SUPABASE_ANON_KEY=eyJhbGciOi...
```

Then plain `flutter run -d windows` (or `-d chrome`). No flags.

**The build fails if `.env` is missing.** That is deliberate — a missing config
file should stop you at the build, not produce an app that starts and silently
shows nothing.

`.env` is in `.gitignore`.

## Precedence

| | |
|---|---|
| 1. `--dart-define` | build-time, wins when supplied (CI, staging) |
| 2. `.env` | runtime, the normal path |
| 3. neither | app refuses to start and names what is missing |

So staging still works without editing anything:
`flutter build web --release --dart-define=SUPABASE_URL=https://staging...`

## ⚠ On web, .env is public

flutter_dotenv reads `.env` through `rootBundle`, so it must be a declared
Flutter asset — and a web build copies every asset into `build/web/assets`,
where anyone can download it.

That is fine for the **anon key**, and only the anon key. It already ships
inside every client bundle; anyone can pull it out of the compiled JavaScript in
a minute. It is not a secret. Row level security is what protects your data.

**Never put in `.env`:** the service_role key, a database password, or any
third-party API secret. On web you would be publishing them. The app refuses to
start if it detects a service_role key, but that check cannot catch every kind
of secret. Real secrets belong behind a Supabase Edge Function.

## Failure modes, all of them explicit

| Condition | Result |
|---|---|
| `.env` missing | Build fails (asset not found) |
| `.env` present, key missing | Setup screen: "SUPABASE_ANON_KEY is missing from .env" |
| Still the placeholder values | Setup screen naming the placeholders |
| service_role key detected | **Refuses to start** |
| Values fine, connection fails | Setup screen with the underlying error |

No demo fallback in any of them. The old behaviour — start anyway, look normal,
show nothing — cost you several rounds of debugging.
