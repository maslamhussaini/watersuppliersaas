# WaterFlow AI Agent Guide

## Purpose
This repository is a Flutter client app that uses Supabase as its backend. The primary focus for AI agents should be Supabase integration, auth/tenant state, and demo-mode fallbacks.

## Supabase setup
- Supabase is initialized in `lib/main.dart` using `flutter_dotenv`.
- Required environment variables are:
  - `SUPABASE_URL`
  - `SUPABASE_ANON_KEY`
- The app can boot in demo mode when Supabase is not configured, so check `supabaseClientInitialized` before assuming backend connectivity.
- The `.env` file is included as an asset in `pubspec.yaml` and should be treated as local configuration.

## Key files
- `lib/main.dart` — app entrypoint, Supabase initialization, auth gate, demo fallback.
- `lib/services/supabase_service.dart` — primary data access service for organizations, areas, customers, deliveries, payments, and inventory.
- `lib/services/auth_service.dart` — Supabase auth and user role resolution logic.
- `lib/services/tenant_service.dart` — tenant/organization selection and caching.
- `lib/screens/*` — UI screens depend on the services above rather than using Supabase directly.

## Important conventions
- Access Supabase through helpers and services, not direct UI calls.
- Use `supabaseClientInitialized` to detect whether Supabase is configured.
- `SupabaseClient? get supabaseClient` returns null when not initialized; `SupabaseClient get supabase` throws if uninitialized.
- When Supabase is unavailable, service methods often fall back to `DemoStore()` behavior.
- Role resolution is based on:
  - `ws_tblInternalUsers` for admin/staff roles
  - `ws_tblCustomers` for customer role
  - otherwise default to staff.

## Supabase-related data model patterns
- Main tables and views referenced in code:
  - `ws_tblOrganization`
  - `ws_tblInternalUsers`
  - `ws_tblAreas`
  - `ws_tblCustomers`
  - `ws_tblDeliveries`
  - `ws_tblPayments`
  - `ws_tblBottleInventory`
  - `vw_ws_CustomerBalance`
- Many queries use nested joins and then flatten nested row fields into top-level JSON maps.
- `maybeSingle()` is used when a row may or may not exist.
- `upsert` is used to create/update entities in Supabase.

## Build and run
- Standard commands:
  - `flutter pub get`
  - `flutter run`
  - `flutter build web --release`
- Build script: `build.sh` clones Flutter, installs dependencies, and builds web release.

## Notes for AI agents
- Do not assume this is a backend repo; it is a Flutter client app.
- Prefer refactoring Supabase access inside services rather than changing UI screens directly.
- Keep Supabase environment secrets local and avoid hardcoding keys in repository files.
- Link to existing code rather than duplicating implementation detail when explaining behavior.
