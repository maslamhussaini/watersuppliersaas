-- =============================================================================
-- 001_extensions_and_helpers.sql
-- WaterFlow / Mineral Water Distribution SaaS
--
-- Foundation: extensions, the `ws` helper schema, and the non-recursive
-- tenant-resolution functions that every RLS policy depends on.
--
-- WHY A SEPARATE SCHEMA FOR HELPERS
-- Supabase exposes the `public` schema through PostgREST. Anything in `public`
-- is callable by any authenticated client. The SECURITY DEFINER functions below
-- bypass RLS by design; exposing them over HTTP would let a client enumerate
-- another tenant's org ids. They live in `ws` (not exposed) instead.
-- =============================================================================

-- gen_random_uuid() is core since Postgres 13, so no extension is required.
-- pgcrypto is created only when the build provides it (Supabase does); nothing
-- in this schema depends on it, so a minimal Postgres image still migrates.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pgcrypto') then
    create extension if not exists "pgcrypto";
  end if;
end
$$;

-- NOTE: the citext extension is deliberately NOT used. Email and code columns
-- are plain text with unique indexes on lower(), which behaves identically for
-- lookups, keeps the schema portable to any Postgres build, and avoids an
-- extension dependency in tables that RLS policies read on every request.

-- Supabase ships the anon / authenticated / service_role roles. Create them when
-- absent so these migrations also apply to a bare Postgres instance for CI.
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated','service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin noinherit', r);
    end if;
  end loop;
end
$$;

create schema if not exists ws;

revoke all on schema ws from public;
revoke all on schema ws from anon, authenticated;
grant usage on schema ws to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Local shim so these migrations can be applied to a plain Postgres instance
-- (CI, local dev, `docker run postgres`) as well as to Supabase.
-- On Supabase, auth.uid() already exists and this block is a no-op.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'auth') then
    create schema auth;

    -- NOTE: no DEFAULT on id, deliberately. Real Supabase auth.users has none —
    -- the id is supplied by GoTrue. A shim with `default gen_random_uuid()`
    -- silently hides that, and any script inserting a user without an explicit
    -- id passes locally and fails on Supabase with:
    --   null value in column "id" of relation "users" violates not-null constraint
    create table auth.users (
      id            uuid primary key,
      email         text unique,
      created_at    timestamptz not null default now()
    );

    -- Test harness sets ws.test_uid; production Supabase never reaches here.
    execute $fn$
      create function auth.uid() returns uuid
      language sql stable as $body$
        select nullif(current_setting('ws.test_uid', true), '')::uuid
      $body$;
    $fn$;
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- ws.current_uid()
-- Single indirection point for "who is calling". Wrapping auth.uid() means the
-- RLS policies never reference Supabase internals directly, so the same
-- policies work under the test harness.
-- -----------------------------------------------------------------------------
create or replace function ws.current_uid()
returns uuid
language sql
stable
set search_path = ws, auth, pg_catalog
as $$
  select auth.uid()
$$;

-- -----------------------------------------------------------------------------
-- Generic updated_at maintenance.
-- -----------------------------------------------------------------------------
create or replace function ws.tg_touch_updated_at()
returns trigger
language plpgsql
set search_path = ws, pg_catalog
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

-- -----------------------------------------------------------------------------
-- ws.assert_same_org(a, b, context)
-- Guards against the classic multi-tenant bug: a row in org A referencing a
-- parent row in org B. Foreign keys alone cannot express this; we call this
-- from validation triggers on every child table that carries a denormalised
-- orgid.
-- -----------------------------------------------------------------------------
create or replace function ws.assert_same_org(a bigint, b bigint, ctx text)
returns void
language plpgsql
immutable
set search_path = ws, pg_catalog
as $$
begin
  if a is null or b is null then
    raise exception 'ws.assert_same_org: null orgid in %', ctx
      using errcode = '23514';
  end if;
  if a <> b then
    raise exception 'cross-tenant reference in %: orgid % vs %', ctx, a, b
      using errcode = '23514';
  end if;
end
$$;

comment on schema ws is
  'Private helper schema. Never expose via PostgREST: contains SECURITY DEFINER '
  'functions that intentionally bypass row level security.';
