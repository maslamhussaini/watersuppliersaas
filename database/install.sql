-- =============================================================================
-- install.sql  —  THE WHOLE SCHEMA, IN ONE FILE, IN THE RIGHT ORDER
--
-- Use this instead of running migrations/000..013 by hand.
--
-- WHY THIS FILE EXISTS
-- Running the migrations one at a time in the Supabase SQL editor turned out to
-- be the problem, not the schema. If any file fails and the next one is run
-- anyway, every later file reports a missing table that an earlier file should
-- have created. That produced these, which look like nine problems and are one:
--
--   ERROR: column "owneruserid" does not exist              (002 aborted)
--   ERROR: function ws.is_member(bigint) does not exist     (002 never finished)
--   ERROR: relation "public.ws_tblpermissions" does not exist    (008 ran anyway)
--   ERROR: relation "public.ws_tblbottletypes" does not exist    (007 ran anyway)
--   ERROR: relation "public.ws_tblvendors" does not exist        (003 had aborted)
--
-- ws_tblpermissions is created by 002 and only REFERENCED by 008.
-- ws_tblbottletypes is created by 003 and only REFERENCED by 005, 007 and 008.
-- So those last two messages mean 002 and 003 have still not completed.
--
-- HOW TO RUN
--
--   Supabase SQL editor:  paste this entire file and run it ONCE.
--     The editor wraps a script in a single transaction, so it either all
--     applies or none of it does. There is no half-migrated state to reason
--     about and no ordering to get wrong.
--
--   psql:  psql "$DATABASE_URL" -1 -v ON_ERROR_STOP=1 -f database/install.sql
--     The -1 flag is what makes it atomic. Without it psql commits each
--     statement separately and you are back to partial application.
--
-- SAFE TO RE-RUN. Every statement is idempotent: create-if-not-exists,
-- create-or-replace, drop-policy-if-exists, add-column-if-not-exists, and
-- constraints guarded by a catalogue check. No data is deleted.
--
-- AFTERWARDS run database/preflight.sql. Every row should read OK.
-- =============================================================================













-- #############################################################################
-- ## SECTION 000 — 000_adopt_existing_schema.sql
-- #############################################################################

-- =============================================================================
-- 000_adopt_existing_schema.sql
-- RUN THIS FIRST if your database already contains the original app's tables.
--
-- WHY THIS FILE EXISTS
-- Migrations 001-008 use `create table if not exists`. On an empty database that
-- is fine. On YOUR database it is actively harmful: ws_tblorganization already
-- existed, so the create was skipped, the new columns were never added, and the
-- first statement that referenced one failed:
--
--   ERROR: 42703: column "owneruserid" does not exist
--
-- That aborted 002 partway, so ws.is_member() was never created, which is why
-- 003 then reported:
--
--   ERROR: 42883: function ws.is_member(bigint) does not exist
--
-- and every later file failed on tables that the aborted files should have
-- created. One skipped CREATE at the top produced every error you saw.
--
-- This migration brings the seven legacy tables up to the shape the rest of the
-- schema expects. It is additive and idempotent: it only ever ADDS columns, and
-- running it twice changes nothing. No data is deleted.
--
-- ORDER:  000 → 001 → 002 → 003 → 004 → 005 → 006 → 007 → 008
-- =============================================================================

-- Everything runs in one transaction: if any part fails you are left exactly
-- where you started rather than half-migrated.
-- (begin removed: install.sql is one transaction)

-- ─── Legacy tables from the original app ─────────────────────────────────────
--   ws_tblorganization, ws_tblinternalusers, ws_tblareas, ws_tblcustomers,
--   ws_tbldeliveries, ws_tblpayments, ws_tblbottleinventory
--   plus the view vw_ws_customerbalance

-- Step 1. Normalise column casing.
-- Supabase's table editor quotes identifiers, so a column created as "OrgID" is
-- genuinely different from orgid. The old Dart read `j['orgid'] ?? j['OrgID']`
-- defensively, which means both spellings existed in the wild. SQL cannot be
-- defensive that way, so fold any mixed-case column to lowercase.
do $$
declare
  r record;
begin
  for r in
    select c.table_name, c.column_name
    from information_schema.columns c
    join pg_class t on t.relname = c.table_name
                   and t.relnamespace = 'public'::regnamespace
    where c.table_schema = 'public'
      and c.table_name like 'ws\_tbl%'
      and c.column_name <> lower(c.column_name)
  loop
    -- Only rename when the lowercase name is free, otherwise both exist and a
    -- human has to decide which one holds the real data.
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public'
        and table_name = r.table_name
        and column_name = lower(r.column_name)
    ) then
      execute format('alter table public.%I rename column %I to %I',
                     r.table_name, r.column_name, lower(r.column_name));
      raise notice 'renamed %.% -> %', r.table_name, r.column_name, lower(r.column_name);
    else
      raise warning
        'table % has both "%" and "%" — resolve manually before continuing',
        r.table_name, r.column_name, lower(r.column_name);
    end if;
  end loop;
end
$$;

-- Step 2. Add every column the new schema expects.
-- `add column if not exists` is a no-op when the column is already there, so
-- this is safe on a fresh database too. Every added column is nullable or has a
-- default: adding a NOT NULL column without one to a populated table fails, and
-- these tables have live rows in them.
do $$
declare
  spec record;
begin
  for spec in
    select * from (values
      -- table, column, type + default
      ('ws_tblorganization', 'publicid',       'uuid not null default gen_random_uuid()'),
      ('ws_tblorganization', 'businessname',   'text'),
      ('ws_tblorganization', 'owneruserid',    'uuid'),
      ('ws_tblorganization', 'email',          'text'),
      ('ws_tblorganization', 'logourl',        'text'),
      ('ws_tblorganization', 'currency',       'text not null default ''PKR'''),
      ('ws_tblorganization', 'currencysymbol', 'text not null default ''Rs'''),
      ('ws_tblorganization', 'dateformat',     'text not null default ''dd-MM-yyyy'''),
      ('ws_tblorganization', 'timezone',       'text not null default ''Asia/Karachi'''),
      ('ws_tblorganization', 'invoiceprefix',  'text not null default ''INV-'''),
      ('ws_tblorganization', 'receiptprefix',  'text not null default ''RCPT-'''),
      ('ws_tblorganization', 'deliveryprefix', 'text not null default ''DEL-'''),
      ('ws_tblorganization', 'cardsettings',   'jsonb not null default ''{"pagesize":"A5","showdeposit":true,"showsignature":true,"columns":["date","delivered","received","balance","amount","paid"]}''::jsonb'),
      ('ws_tblorganization', 'authuserid',     'uuid'),
      ('ws_tblorganization', 'ownername',      'text not null default '''''),
      ('ws_tblorganization', 'phone',          'text not null default '''''),
      ('ws_tblorganization', 'address',        'text not null default '''''),
      ('ws_tblorganization', 'isactive',       'boolean not null default true'),
      ('ws_tblorganization', 'createddate',    'timestamptz not null default now()'),
      ('ws_tblorganization', 'updated_at',     'timestamptz not null default now()'),

      ('ws_tblinternalusers', 'membershipid', 'bigint'),
      ('ws_tblinternalusers', 'role',         'text not null default ''staff'''),
      ('ws_tblinternalusers', 'phone',        'text'),
      ('ws_tblinternalusers', 'isactive',     'boolean not null default true'),
      ('ws_tblinternalusers', 'createddate',  'timestamptz not null default now()'),
      ('ws_tblinternalusers', 'updated_at',   'timestamptz not null default now()'),

      ('ws_tblareas', 'rateperbottle', 'numeric(12,2) not null default 0'),
      ('ws_tblareas', 'deliverydays',  'text'),
      ('ws_tblareas', 'isactive',      'boolean not null default true'),
      ('ws_tblareas', 'createddate',   'timestamptz not null default now()'),
      ('ws_tblareas', 'updated_at',    'timestamptz not null default now()'),

      ('ws_tblcustomers', 'customercode',   'text'),
      ('ws_tblcustomers', 'contactperson',  'text'),
      ('ws_tblcustomers', 'email',          'text'),
      ('ws_tblcustomers', 'routeid',        'bigint'),
      ('ws_tblcustomers', 'groupid',        'bigint'),
      ('ws_tblcustomers', 'creditlimit',    'numeric(12,2)'),
      ('ws_tblcustomers', 'openingbalance', 'numeric(12,2) not null default 0'),
      ('ws_tblcustomers', 'depositamount',  'numeric(12,2) not null default 0'),
      ('ws_tblcustomers', 'bottlebalance',  'int not null default 0'),
      ('ws_tblcustomers', 'rateoverride',   'numeric(12,2)'),
      ('ws_tblcustomers', 'isactive',       'boolean not null default true'),
      ('ws_tblcustomers', 'createddate',    'timestamptz not null default now()'),
      ('ws_tblcustomers', 'updated_at',     'timestamptz not null default now()'),

      ('ws_tbldeliveries', 'routeid',          'bigint'),
      ('ws_tbldeliveries', 'referenceno',      'text'),
      ('ws_tbldeliveries', 'bottlesdelivered', 'int not null default 0'),
      ('ws_tbldeliveries', 'bottlesreturned',  'int not null default 0'),
      ('ws_tbldeliveries', 'bottlebalance',    'int not null default 0'),
      ('ws_tbldeliveries', 'rateapplied',      'numeric(12,2) not null default 0'),
      ('ws_tbldeliveries', 'amountcharged',    'numeric(14,2) not null default 0'),
      ('ws_tbldeliveries', 'isvoid',           'boolean not null default false'),
      ('ws_tbldeliveries', 'createdby',        'uuid'),
      ('ws_tbldeliveries', 'createddate',      'timestamptz not null default now()'),
      ('ws_tbldeliveries', 'updated_at',       'timestamptz not null default now()'),
      ('ws_tbldeliveries', 'notes',            'text'),

      ('ws_tblpayments', 'methodid',      'bigint'),
      ('ws_tblpayments', 'receiptno',     'text'),
      ('ws_tblpayments', 'referenceno',   'text'),
      ('ws_tblpayments', 'paymentmethod', 'text not null default ''cash'''),
      ('ws_tblpayments', 'isvoid',        'boolean not null default false'),
      ('ws_tblpayments', 'createdby',     'uuid'),
      ('ws_tblpayments', 'createddate',   'timestamptz not null default now()'),
      ('ws_tblpayments', 'notes',         'text'),

      ('ws_tblbottleinventory', 'notes', 'text')
    ) as v(tbl, col, def)
  loop
    -- Skip tables that do not exist yet; 002/003/005 will create them properly.
    if exists (select 1 from pg_class
               where relname = spec.tbl and relnamespace = 'public'::regnamespace
                 and relkind = 'r') then
      execute format('alter table public.%I add column if not exists %I %s',
                     spec.tbl, spec.col, spec.def);
    end if;
  end loop;
end
$$;

-- Step 3. Backfill owneruserid from the legacy authuserid column.
-- Access control does not read either of these — ws_tblmemberships does — but
-- "who owns this organization" should survive the upgrade.
do $$
begin
  if exists (select 1 from pg_class
             where relname = 'ws_tblorganization'
               and relnamespace = 'public'::regnamespace) then
    update public.ws_tblorganization
       set owneruserid = authuserid
     where owneruserid is null and authuserid is not null;
  end if;
end
$$;

-- Step 4. Add the uniqueness the new schema relies on.
-- ws_create_organization() and the seed both use (orgid, customercode); without
-- the constraint, duplicate codes slip in and the delivery card can match the
-- wrong customer.
do $$
declare
  spec record;
begin
  for spec in
    select * from (values
      ('ws_tblorganization',  'ux_ws_org_publicid',        'publicid'),
      ('ws_tblareas',         'ux_ws_areas_org_name',      'orgid, areaname'),
      ('ws_tblcustomers',     'ux_ws_customers_org_code',  'orgid, customercode'),
      ('ws_tblcustomers',     'ux_ws_customers_org_user',  'orgid, authuserid'),
      ('ws_tblinternalusers', 'ux_ws_internal_org_user',   'orgid, authuserid'),
      ('ws_tbldeliveries',    'ux_ws_deliveries_org_ref',  'orgid, referenceno'),
      ('ws_tblpayments',      'ux_ws_payments_org_receipt','orgid, receiptno')
    ) as v(tbl, idx, cols)
  loop
    if exists (select 1 from pg_class
               where relname = spec.tbl and relnamespace = 'public'::regnamespace
                 and relkind = 'r')
       and not exists (select 1 from pg_class where relname = spec.idx) then
      begin
        execute format('create unique index %I on public.%I (%s)',
                       spec.idx, spec.tbl, spec.cols);
      exception when unique_violation then
        -- Pre-existing duplicates. Report rather than abort: the rest of the
        -- schema still installs, and you can clean the data afterwards.
        raise warning
          'could not create % on % — existing duplicate rows. Deduplicate, then: create unique index %I on public.%I (%s);',
          spec.idx, spec.tbl, spec.idx, spec.tbl, spec.cols;
      end;
    end if;
  end loop;
end
$$;

-- Step 4b. Drop legacy CHECK constraints whose allowed values the new schema
-- widens.
--
-- `create table if not exists` skips an existing table, so its OLD constraints
-- survive alongside the new columns. The original app constrained
-- ws_tblinternalusers.role to ('admin','staff'); the new schema has six roles,
-- so simply creating an organization fails with
--
--   new row for relation "ws_tblinternalusers" violates check constraint
--   "ws_tblinternalusers_role_check"
--
-- Same story for ws_tblpayments.paymentmethod, which was a fixed list and is now
-- tenant-defined (ws_tblpaymentmethods.methodcode) so a business can add its own
-- wallet.
--
-- ONLY constraints on those two columns are touched, and each drop is announced.
-- A blanket "drop every check on the legacy tables" would silently remove
-- business rules you added deliberately.
do $$
declare
  r record;
begin
  for r in
    select con.conname, cls.relname as tbl, pg_get_constraintdef(con.oid) as def
    from pg_constraint con
    join pg_class cls on cls.oid = con.conrelid
    where con.contype = 'c'
      and cls.relnamespace = 'public'::regnamespace
      and (
        (cls.relname = 'ws_tblinternalusers'
           and pg_get_constraintdef(con.oid) ilike '%role%')
        or
        (cls.relname = 'ws_tblpayments'
           and pg_get_constraintdef(con.oid) ilike '%paymentmethod%')
      )
  loop
    execute format('alter table public.%I drop constraint %I', r.tbl, r.conname);
    raise notice 'dropped legacy constraint %.% : %', r.tbl, r.conname, r.def;
  end loop;
end
$$;

-- Step 5. Drop the legacy view — ONLY if it really is the legacy one.
--
-- 007 uses `create or replace view`, which fails when the new column list is
-- not a superset of the old one in the same order. The original
-- vw_ws_customerbalance was `select c.*, ...`, so it does not line up and has
-- to be dropped first.
--
-- BUT a bare `drop ... cascade` here is destructive on an ALREADY-MIGRATED
-- database. vw_ws_reconciliation and vw_ws_dashboard both select from
-- vw_ws_customerbalance, so CASCADE takes all three out. Re-running 000 on its
-- own — which the file itself advertises as safe and idempotent — silently
-- deleted three views and produced:
--
--   PGRST205: Could not find the table 'public.vw_ws_dashboard' in the schema cache
--   PGRST205: Could not find the table 'public.vw_ws_customerbalance' in the schema cache
--
-- So: detect which version is present. `bottledepositvalue` exists only in the
-- new view, so its presence means 007 has already run and there is nothing to
-- drop.
do $$
begin
  if not exists (
    select 1 from pg_class c
    where c.relname = 'vw_ws_customerbalance'
      and c.relnamespace = 'public'::regnamespace
      and c.relkind = 'v'
  ) then
    raise notice 'vw_ws_customerbalance does not exist — nothing to drop.';

  elsif exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'vw_ws_customerbalance'
      and column_name = 'bottledepositvalue'
  ) then
    -- Already the new view. Dropping it would take vw_ws_dashboard and
    -- vw_ws_reconciliation with it.
    raise notice
      'vw_ws_customerbalance is already the migrated version — leaving it alone.';

  else
    raise notice 'Dropping the legacy vw_ws_customerbalance (007 recreates it).';
    drop view public.vw_ws_customerbalance cascade;
  end if;
end
$$;

-- (commit removed: install.sql is one transaction)

-- ─── What changed ────────────────────────────────────────────────────────────
-- Run database/preflight.sql afterwards to confirm every expected object now
-- exists before moving on to 001.


-- #############################################################################
-- ## SECTION 001 — 001_extensions_and_helpers.sql
-- #############################################################################

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


-- #############################################################################
-- ## SECTION 002 — 002_tenancy_and_rbac.sql
-- #############################################################################

-- =============================================================================
-- 002_tenancy_and_rbac.sql
-- Organizations, membership, roles, permissions, subscriptions.
--
-- DESIGN NOTE — WHY A DEDICATED MEMBERSHIP TABLE
-- The current Flutter code resolves "which orgs can I see" by querying
-- ws_tblinternalusers UNION ws_tblcustomers. If RLS policies on those two
-- tables also had to consult those same two tables, Postgres would recurse and
-- error with "infinite recursion detected in policy".
--
-- ws_tblmemberships breaks that cycle. It is the ONE table RLS consults, it is
-- read through a SECURITY DEFINER function, and its own policy is a plain
-- `authuserid = current_uid()` self-check that touches no other table.
-- Staff records (ws_tblinternalusers) and portal links (ws_tblcustomers) hang
-- off it and are kept in sync by triggers.
--
-- DESIGN NOTE — ws_tblorganization.authuserid
-- The existing column implies exactly one owner per organization, which
-- contradicts the requirement that a user can own multiple organizations and
-- that an organization has multiple users. It is retained as `owneruserid` for
-- backwards compatibility and for "who to bill", but it is NOT used for access
-- control. Authorization reads ws_tblmemberships only.
-- =============================================================================

-- ─── Organizations ───────────────────────────────────────────────────────────

create table if not exists public.ws_tblorganization (
  orgid             bigint generated by default as identity primary key,
  publicid          uuid        not null default gen_random_uuid() unique,
  orgname           text        not null,
  businessname      text,
  owneruserid       uuid        references auth.users(id) on delete set null,
  ownername         text        not null default '',
  email             text,
  phone             text        not null default '',
  address           text        not null default '',
  logourl           text,
  currency          text        not null default 'PKR',
  currencysymbol    text        not null default 'Rs',
  dateformat        text        not null default 'dd-MM-yyyy',
  timezone          text        not null default 'Asia/Karachi',
  invoiceprefix     text        not null default 'INV-',
  receiptprefix     text        not null default 'RCPT-',
  deliveryprefix    text        not null default 'DEL-',
  -- Report layout is per-organization and data-driven, not compiled in.
  cardsettings      jsonb       not null default '{
    "pagesize": "A5",
    "showdeposit": true,
    "showsignature": true,
    "columns": ["date","delivered","received","balance","amount","paid"]
  }'::jsonb,
  isactive          boolean     not null default true,
  createddate       timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- Legacy alias: existing Dart reads/writes `authuserid` on this table.
-- A generated column cannot be written to, so this is a plain column kept in
-- step with owneruserid by trigger. Remove once the client is updated.
alter table public.ws_tblorganization
  add column if not exists authuserid uuid;

create or replace function ws.tg_org_sync_owner()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
begin
  if new.owneruserid is null and new.authuserid is not null then
    new.owneruserid := new.authuserid;
  end if;
  new.authuserid := new.owneruserid;
  new.updated_at := now();
  return new;
end
$$;

drop trigger if exists trg_org_sync_owner on public.ws_tblorganization;
create trigger trg_org_sync_owner
  before insert or update on public.ws_tblorganization
  for each row execute function ws.tg_org_sync_owner();

create index if not exists ix_org_owner on public.ws_tblorganization(owneruserid);

-- ─── Permissions catalogue (global, not tenant-scoped) ───────────────────────

create table if not exists public.ws_tblpermissions (
  permcode    text primary key,
  module      text not null,
  label       text not null,
  sortorder   int  not null default 0
);

insert into public.ws_tblpermissions (permcode, module, label, sortorder) values
  ('org.view',        'Organization', 'View organization settings', 10),
  ('org.manage',      'Organization', 'Change organization settings', 11),
  ('users.view',      'Users',        'View users',                  20),
  ('users.manage',    'Users',        'Invite and edit users',       21),
  ('customers.view',  'Customers',    'View customers',              30),
  ('customers.manage','Customers',    'Create and edit customers',   31),
  ('vendors.view',    'Vendors',      'View vendors',                40),
  ('vendors.manage',  'Vendors',      'Create and edit vendors',     41),
  ('products.view',   'Products',     'View products and pricing',   50),
  ('products.manage', 'Products',     'Edit products and pricing',   51),
  ('delivery.view',   'Deliveries',   'View deliveries',             60),
  ('delivery.manage', 'Deliveries',   'Record deliveries',           61),
  ('payments.view',   'Payments',     'View payments',               70),
  ('payments.manage', 'Payments',     'Record payments',             71),
  ('purchases.view',  'Purchases',    'View purchases',              80),
  ('purchases.manage','Purchases',    'Record purchases',            81),
  ('accounting.view', 'Accounting',   'View ledgers and journals',   90),
  ('accounting.manage','Accounting',  'Post manual journal entries', 91),
  ('reports.view',    'Reports',      'Run reports',                100),
  ('reports.all',     'Reports',      'Run all reports',            101)
on conflict (permcode) do nothing;

-- ─── Roles (per organization, so tenants can define their own) ───────────────

create table if not exists public.ws_tblroles (
  roleid      bigint generated by default as identity primary key,
  orgid       bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  rolecode    text   not null,
  rolename    text   not null,
  issystem    boolean not null default false,   -- system roles cannot be deleted
  isportal    boolean not null default false,   -- true = customer portal role
  createddate timestamptz not null default now(),
  unique (orgid, rolecode)
);

create table if not exists public.ws_tblrolepermissions (
  roleid   bigint not null references public.ws_tblroles(roleid) on delete cascade,
  permcode text   not null references public.ws_tblpermissions(permcode) on delete cascade,
  primary key (roleid, permcode)
);

-- ─── Membership: the single source of truth for access control ───────────────

create table if not exists public.ws_tblmemberships (
  membershipid bigint generated by default as identity primary key,
  orgid        bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  authuserid   uuid   not null references auth.users(id) on delete cascade,
  roleid       bigint not null references public.ws_tblroles(roleid) on delete restrict,
  -- Set when this membership is a customer-portal login rather than staff.
  -- Populated by trigger from ws_tblcustomers; scopes portal row visibility.
  customerid   bigint,
  isactive     boolean not null default true,
  createddate  timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (orgid, authuserid)
);

create index if not exists ix_membership_user on public.ws_tblmemberships(authuserid) where isactive;
create index if not exists ix_membership_org  on public.ws_tblmemberships(orgid)      where isactive;

drop trigger if exists trg_membership_touch on public.ws_tblmemberships;
create trigger trg_membership_touch
  before update on public.ws_tblmemberships
  for each row execute function ws.tg_touch_updated_at();

-- ─── Non-recursive tenant resolution (the core of RLS) ───────────────────────

-- SECURITY DEFINER: reads ws_tblmemberships with RLS bypassed. This is safe
-- because the WHERE clause is pinned to the caller's own uid; a caller cannot
-- influence which rows come back.
create or replace function ws.member_org_ids()
returns setof bigint
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select m.orgid
  from public.ws_tblmemberships m
  where m.authuserid = ws.current_uid()
    and m.isactive
$$;

create or replace function ws.is_member(p_orgid bigint)
returns boolean
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select exists (
    select 1 from public.ws_tblmemberships m
    where m.authuserid = ws.current_uid()
      and m.orgid = p_orgid
      and m.isactive
  )
$$;

-- Returns the customerid this user is scoped to in the given org, or NULL for
-- staff. Portal RLS policies use this: staff see all customers, a portal user
-- sees only rows where customerid = ws.portal_customer_id(orgid).
create or replace function ws.portal_customer_id(p_orgid bigint)
returns bigint
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select m.customerid
  from public.ws_tblmemberships m
  where m.authuserid = ws.current_uid()
    and m.orgid = p_orgid
    and m.isactive
  limit 1
$$;

-- Permission check. Replaces the hardcoded admin/staff/customer enum in
-- lib/models/ws_models.dart: permissions are data, not a Dart switch.
create or replace function ws.has_perm(p_orgid bigint, p_perm text)
returns boolean
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select exists (
    select 1
    from public.ws_tblmemberships m
    join public.ws_tblrolepermissions rp on rp.roleid = m.roleid
    where m.authuserid = ws.current_uid()
      and m.orgid = p_orgid
      and m.isactive
      and rp.permcode = p_perm
  )
$$;

-- ─── Internal (staff) users — profile data only, not authorization ──────────

create table if not exists public.ws_tblinternalusers (
  internaluserid bigint generated by default as identity primary key,
  orgid          bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  authuserid     uuid   references auth.users(id) on delete set null,
  membershipid   bigint references public.ws_tblmemberships(membershipid) on delete set null,
  fullname       text   not null,
  phone          text,
  -- Denormalised role code for display and for the legacy Dart read path.
  -- Authorization must use ws.has_perm(), never this column.
  role           text   not null default 'staff',
  isactive       boolean not null default true,
  createddate    timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (orgid, authuserid)
);

create index if not exists ix_internalusers_org on public.ws_tblinternalusers(orgid);

drop trigger if exists trg_internalusers_touch on public.ws_tblinternalusers;
create trigger trg_internalusers_touch
  before update on public.ws_tblinternalusers
  for each row execute function ws.tg_touch_updated_at();

-- ─── Subscriptions and plan limits ──────────────────────────────────────────

create table if not exists public.ws_tblplans (
  plancode        text primary key,
  planname        text not null,
  monthlyprice    numeric(12,2) not null default 0,
  maxcustomers    int,      -- null = unlimited
  maxusers        int,
  allowaccounting boolean not null default false,
  allowroutes     boolean not null default false,
  allowapi        boolean not null default false,
  sortorder       int not null default 0
);

insert into public.ws_tblplans
  (plancode, planname, monthlyprice, maxcustomers, maxusers, allowaccounting, allowroutes, allowapi, sortorder)
values
  ('free',       'Free',          0,    50,   1, false, false, false, 1),
  ('basic',      'Basic',      1500,   500,   5, true,  true,  false, 2),
  ('pro',        'Professional',4000,  null, null, true,  true,  true,  3),
  ('enterprise', 'Enterprise',    0,   null, null, true,  true,  true,  4)
on conflict (plancode) do nothing;

create table if not exists public.ws_tblsubscriptions (
  subscriptionid bigint generated by default as identity primary key,
  orgid          bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  plancode       text   not null references public.ws_tblplans(plancode),
  status         text   not null default 'trialing'
                 check (status in ('trialing','active','past_due','canceled','expired')),
  trialstartdate date,
  trialenddate   date,
  periodstart    date,
  periodend      date,
  createddate    timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create unique index if not exists ux_subscription_active_per_org
  on public.ws_tblsubscriptions(orgid)
  where status in ('trialing','active','past_due');

create table if not exists public.ws_tblsubscriptionpayments (
  subpaymentid   bigint generated by default as identity primary key,
  subscriptionid bigint not null references public.ws_tblsubscriptions(subscriptionid) on delete cascade,
  orgid          bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  amount         numeric(12,2) not null check (amount >= 0),
  paiddate       date not null default current_date,
  gatewayref     text,
  createddate    timestamptz not null default now()
);

-- ─── Provisioning: create an org with sane defaults in one transaction ───────
-- Called from the client with the new org's details. Replaces the current
-- multi-step client-side sequence in AuthService.registerOrganization(), which
-- can leave an organization with no membership row if the second insert fails.

-- ws.ensure_org_roles(orgid)
-- Creates the seven default roles and their permission sets for an
-- organization that does not have them yet. Idempotent.
--
-- Extracted from provision_organization() so that organizations which already
-- existed before this schema was installed can be given roles too. Without it
-- there is no way to bootstrap a pre-existing tenant: every RLS policy resolves
-- through a membership, a membership needs a role, and roles were only ever
-- created as a side effect of creating a brand new organization.
create or replace function ws.ensure_org_roles(p_orgid bigint)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $ensure$
declare
  v_orgid bigint := p_orgid;
begin
  insert into public.ws_tblroles (orgid, rolecode, rolename, issystem, isportal) values
    (v_orgid, 'owner',      'Owner',      true,  false),
    (v_orgid, 'admin',      'Admin',      true,  false),
    (v_orgid, 'accountant', 'Accountant', true,  false),
    (v_orgid, 'sales',      'Sales',      true,  false),
    (v_orgid, 'delivery',   'Delivery',   true,  false),
    (v_orgid, 'readonly',   'Read Only',  true,  false),
    (v_orgid, 'customer',   'Customer',   true,  true)
  on conflict (orgid, rolecode) do nothing;

  -- Owner gets every permission that exists, so adding a new permission later
  -- does not silently lock the owner out of their own organization.

  -- owner: everything
  insert into public.ws_tblrolepermissions (roleid, permcode)
  select r.roleid, p.permcode
  from public.ws_tblroles r cross join public.ws_tblpermissions p
  where r.orgid = v_orgid and r.rolecode = 'owner'
  on conflict (roleid, permcode) do nothing;

  -- admin: everything except billing-level org changes are still allowed here;
  -- differentiate later if you add an org.billing permission.
  insert into public.ws_tblrolepermissions (roleid, permcode)
  select r.roleid, p.permcode
  from public.ws_tblroles r cross join public.ws_tblpermissions p
  where r.orgid = v_orgid and r.rolecode = 'admin'
  on conflict (roleid, permcode) do nothing;

  insert into public.ws_tblrolepermissions (roleid, permcode)
  select r.roleid, x.permcode
  from public.ws_tblroles r
  cross join (values
    ('customers.view'),('customers.manage'),
    ('vendors.view'),('vendors.manage'),
    ('products.view'),
    ('delivery.view'),
    ('payments.view'),('payments.manage'),
    ('purchases.view'),('purchases.manage'),
    ('accounting.view'),('accounting.manage'),
    ('reports.view'),('reports.all')
  ) as x(permcode)
  where r.orgid = v_orgid and r.rolecode = 'accountant'
  on conflict (roleid, permcode) do nothing;

  insert into public.ws_tblrolepermissions (roleid, permcode)
  select r.roleid, x.permcode
  from public.ws_tblroles r
  cross join (values
    ('customers.view'),('customers.manage'),
    ('products.view'),
    ('delivery.view'),('delivery.manage'),
    ('payments.view'),('payments.manage'),
    ('reports.view')
  ) as x(permcode)
  where r.orgid = v_orgid and r.rolecode = 'sales'
  on conflict (roleid, permcode) do nothing;

  insert into public.ws_tblrolepermissions (roleid, permcode)
  select r.roleid, x.permcode
  from public.ws_tblroles r
  cross join (values
    ('customers.view'),
    ('products.view'),
    ('delivery.view'),('delivery.manage'),
    ('reports.view')
  ) as x(permcode)
  where r.orgid = v_orgid and r.rolecode = 'delivery'
  on conflict (roleid, permcode) do nothing;

  insert into public.ws_tblrolepermissions (roleid, permcode)
  select r.roleid, x.permcode
  from public.ws_tblroles r
  cross join (values
    ('customers.view'),('vendors.view'),('products.view'),
    ('delivery.view'),('payments.view'),('purchases.view'),
    ('accounting.view'),('reports.view')
  ) as x(permcode)
  where r.orgid = v_orgid and r.rolecode = 'readonly'
  on conflict (roleid, permcode) do nothing;

  -- portal role: read-only on its own rows. Row scoping is done by RLS via
  -- ws.portal_customer_id(), not by these permission codes.
  insert into public.ws_tblrolepermissions (roleid, permcode)
  select r.roleid, x.permcode
  from public.ws_tblroles r
  cross join (values ('delivery.view'),('payments.view')) as x(permcode)
  where r.orgid = v_orgid and r.rolecode = 'customer'
  on conflict (roleid, permcode) do nothing;
end
$ensure$;

-- ws.provision_organization() takes the owner uid explicitly so that seeds,
-- imports and admin tooling can create an organization on someone's behalf.
-- It lives in the private `ws` schema and is NOT reachable over PostgREST.
-- The public wrapper below is the only client-callable entry point and always
-- passes the caller's own uid.
create or replace function ws.provision_organization(
  p_uid       uuid,
  p_orgname   text,
  p_ownername text default '',
  p_phone     text default '',
  p_address   text default '',
  p_currency  text default 'PKR'
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_uid    uuid := p_uid;
  v_orgid  bigint;
  v_roleid bigint;
begin
  if v_uid is null then
    raise exception 'provision_organization: no owner uid supplied'
      using errcode = '42501';
  end if;

  insert into public.ws_tblorganization
    (orgname, businessname, owneruserid, ownername, phone, address, currency)
  values
    (p_orgname, p_orgname, v_uid, p_ownername, p_phone, p_address, p_currency)
  returning orgid into v_orgid;

  perform ws.ensure_org_roles(v_orgid);

  select roleid into v_roleid
  from public.ws_tblroles
  where orgid = v_orgid and rolecode = 'owner';

  insert into public.ws_tblmemberships (orgid, authuserid, roleid)
  values (v_orgid, v_uid, v_roleid);

  insert into public.ws_tblinternalusers (orgid, authuserid, fullname, role, phone, membershipid)
  select v_orgid, v_uid, coalesce(nullif(p_ownername,''), 'Owner'), 'owner', p_phone, m.membershipid
  from public.ws_tblmemberships m
  where m.orgid = v_orgid and m.authuserid = v_uid;

  insert into public.ws_tblsubscriptions
    (orgid, plancode, status, trialstartdate, trialenddate, periodstart, periodend)
  values
    (v_orgid, 'free', 'trialing', current_date, current_date + 14,
     current_date, current_date + 14);

  return v_orgid;
end
$$;

create or replace function public.ws_create_organization(
  p_orgname   text,
  p_ownername text default '',
  p_phone     text default '',
  p_address   text default '',
  p_currency  text default 'PKR'
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare v_uid uuid := ws.current_uid();
begin
  if v_uid is null then
    raise exception 'ws_create_organization: not authenticated' using errcode = '42501';
  end if;
  return ws.provision_organization(v_uid, p_orgname, p_ownername, p_phone, p_address, p_currency);
end
$$;

revoke all on function ws.provision_organization(uuid,text,text,text,text,text) from public;
revoke all on function public.ws_create_organization(text,text,text,text,text) from public;
grant execute on function public.ws_create_organization(text,text,text,text,text) to authenticated;


-- #############################################################################
-- ## SECTION 003 — 003_master_data.sql
-- #############################################################################

-- =============================================================================
-- 003_master_data.sql
-- Areas, routes, bottle types, products, dynamic pricing, customers, vendors.
--
-- DESIGN NOTE — WHY BOTTLE TYPE IS SEPARATE FROM PRODUCT
-- A product is what you sell and invoice ("19 Litre Mineral Water", Rs 250).
-- A bottle type is the returnable physical asset that moves with it. They are
-- not the same cardinality: two products (Water 19L, Water 19L Premium) can
-- circulate on the same 19L bottle, and a 500ml case is a product with no
-- returnable at all. Collapsing them is the change that forces a migration
-- later, so they are split now.
--
-- DESIGN NOTE — PRICE RESOLUTION
-- Precedence is customer > customer group > area > product default, each with an
-- effective date window. ws.resolve_price() is the single implementation; the
-- delivery trigger and any quoting UI must both call it so they cannot disagree.
-- =============================================================================

-- ─── Areas ───────────────────────────────────────────────────────────────────

create table if not exists public.ws_tblareas (
  areaid        bigint generated by default as identity primary key,
  orgid         bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  areaname      text   not null,
  -- Retained for backwards compatibility with the current Flutter code, which
  -- reads area.rateperbottle. New code should rely on ws_tblproductprices;
  -- migration 003 seeds an area-scoped price row from this value.
  rateperbottle numeric(12,2) not null default 0 check (rateperbottle >= 0),
  deliverydays  text,
  isactive      boolean not null default true,
  createddate   timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (orgid, areaname)
);

-- ─── Routes, vehicles, drivers ───────────────────────────────────────────────

create table if not exists public.ws_tblroutes (
  routeid     bigint generated by default as identity primary key,
  orgid       bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  routecode   text   not null,
  routename   text   not null,
  areaid      bigint references public.ws_tblareas(areaid) on delete set null,
  driverid    bigint references public.ws_tblinternalusers(internaluserid) on delete set null,
  vehicleno   text,
  isactive    boolean not null default true,
  createddate timestamptz not null default now(),
  unique (orgid, routecode)
);

-- ─── Bottle types (returnable assets) ────────────────────────────────────────

create table if not exists public.ws_tblbottletypes (
  bottletypeid   bigint generated by default as identity primary key,
  orgid          bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  bottlecode     text   not null,
  bottlename     text   not null,
  capacitylitres numeric(8,2),
  depositamount  numeric(12,2) not null default 0 check (depositamount >= 0),
  isdefault      boolean not null default false,
  isactive       boolean not null default true,
  createddate    timestamptz not null default now(),
  unique (orgid, bottlecode)
);

-- Exactly one default bottle type per org. The paper delivery card has a single
-- balance column, so the PDF renders the default type unless asked otherwise.
create unique index if not exists ux_bottletype_default_per_org
  on public.ws_tblbottletypes(orgid) where isdefault;

-- ─── Products ────────────────────────────────────────────────────────────────

create table if not exists public.ws_tblproducts (
  productid      bigint generated by default as identity primary key,
  orgid          bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  productcode    text   not null,
  productname    text   not null,
  producttype    text   not null default 'water'
                 check (producttype in ('water','bottle','cap','filter','packaging','service','other')),
  unitlabel      text   not null default 'Bottle',
  sizelabel      text,
  capacitylitres numeric(8,2),
  -- Returnable link. NOT NULL only when the product moves a bottle.
  bottletypeid   bigint references public.ws_tblbottletypes(bottletypeid) on delete restrict,
  bottlesperunit int    not null default 1 check (bottlesperunit >= 0),
  saleprice      numeric(12,2) not null default 0 check (saleprice >= 0),
  purchaseprice  numeric(12,2) not null default 0 check (purchaseprice >= 0),
  trackinventory boolean not null default true,
  isactive       boolean not null default true,
  createddate    timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (orgid, productcode),
  -- A product that claims to move bottles must say which type.
  constraint ck_product_bottle_consistency check (
    (bottletypeid is null and bottlesperunit = 0)
    or (bottletypeid is not null and bottlesperunit >= 1)
  )
);

-- ─── Customer groups (a pricing tier, e.g. Hotel / Office / Home) ────────────

create table if not exists public.ws_tblcustomergroups (
  groupid     bigint generated by default as identity primary key,
  orgid       bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  groupname   text   not null,
  isactive    boolean not null default true,
  createddate timestamptz not null default now(),
  unique (orgid, groupname)
);

-- ─── Customers ───────────────────────────────────────────────────────────────

create table if not exists public.ws_tblcustomers (
  customerid           bigint generated by default as identity primary key,
  orgid                bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  customercode         text,
  customername         text   not null,
  contactperson        text,
  phone                text,
  email                text,
  address              text,
  areaid               bigint references public.ws_tblareas(areaid) on delete set null,
  routeid              bigint references public.ws_tblroutes(routeid) on delete set null,
  groupid              bigint references public.ws_tblcustomergroups(groupid) on delete set null,
  -- Portal login. NULL = this customer has no app access.
  authuserid           uuid   references auth.users(id) on delete set null,
  creditlimit          numeric(12,2),
  depositamount        numeric(12,2) not null default 0 check (depositamount >= 0),
  openingbalance       numeric(12,2) not null default 0,
  -- Legacy single-number bottle balance. Kept so the current Flutter build does
  -- not break, but it is now a DERIVED cache maintained by the bottle trigger
  -- for the DEFAULT bottle type only. Authoritative per-type balances live in
  -- ws_tblcustomerbottlebalances. Do not write to this column.
  bottlebalance        int    not null default 0,
  -- Legacy flat rate override for the default product. Superseded by
  -- ws_tblproductprices; still honoured by ws.resolve_price() as a fallback.
  rateoverride         numeric(12,2),
  isactive             boolean not null default true,
  createddate          timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (orgid, customercode),
  unique (orgid, authuserid)
);

create index if not exists ix_customers_org_active on public.ws_tblcustomers(orgid) where isactive;
create index if not exists ix_customers_area on public.ws_tblcustomers(areaid);
create index if not exists ix_customers_authuser on public.ws_tblcustomers(authuserid) where authuserid is not null;

create table if not exists public.ws_tblcustomeraddresses (
  addressid    bigint generated by default as identity primary key,
  orgid        bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  customerid   bigint not null references public.ws_tblcustomers(customerid) on delete cascade,
  label        text,
  address      text not null,
  isprimary    boolean not null default false,
  createddate  timestamptz not null default now()
);

-- Keep the membership row in step with the customer's portal link, so RLS
-- scoping cannot drift from the customer record.
create or replace function ws.tg_customer_sync_membership()
returns trigger
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_roleid bigint;
begin
  if new.authuserid is not null then
    select roleid into v_roleid
    from public.ws_tblroles
    where orgid = new.orgid and rolecode = 'customer';

    if v_roleid is not null then
      insert into public.ws_tblmemberships (orgid, authuserid, roleid, customerid)
      values (new.orgid, new.authuserid, v_roleid, new.customerid)
      on conflict (orgid, authuserid)
      do update set customerid = excluded.customerid, isactive = true;
    end if;
  end if;

  -- Portal access revoked: deactivate the membership rather than delete it, so
  -- history and audit trails survive.
  if tg_op = 'UPDATE'
     and old.authuserid is not null
     and (new.authuserid is null or new.authuserid <> old.authuserid) then
    update public.ws_tblmemberships
      set isactive = false
    where orgid = old.orgid
      and authuserid = old.authuserid
      and customerid = old.customerid;
  end if;

  return null;
end
$$;

drop trigger if exists trg_customer_sync_membership on public.ws_tblcustomers;
create trigger trg_customer_sync_membership
  after insert or update of authuserid on public.ws_tblcustomers
  for each row execute function ws.tg_customer_sync_membership();

-- ─── Vendors ─────────────────────────────────────────────────────────────────

create table if not exists public.ws_tblvendors (
  vendorid       bigint generated by default as identity primary key,
  orgid          bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  vendorcode     text,
  vendorname     text   not null,
  contactperson  text,
  phone          text,
  email          text,
  address        text,
  openingbalance numeric(12,2) not null default 0,
  isactive       boolean not null default true,
  createddate    timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (orgid, vendorcode)
);

create index if not exists ix_vendors_org_active on public.ws_tblvendors(orgid) where isactive;

-- ─── Payment methods (per-org, so tenants can add their own wallets) ─────────

create table if not exists public.ws_tblpaymentmethods (
  methodid    bigint generated by default as identity primary key,
  orgid       bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  methodcode  text   not null,
  methodname  text   not null,
  -- Which cash/bank account this method settles into. Set in migration 004.
  accountid   bigint,
  isactive    boolean not null default true,
  sortorder   int not null default 0,
  unique (orgid, methodcode)
);

-- ─── Dynamic pricing ─────────────────────────────────────────────────────────

create table if not exists public.ws_tblproductprices (
  priceid       bigint generated by default as identity primary key,
  orgid         bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  productid     bigint not null references public.ws_tblproducts(productid) on delete cascade,
  -- Scope: exactly one of customerid / groupid / areaid may be set.
  -- All three NULL = the organization-wide default for this product.
  customerid    bigint references public.ws_tblcustomers(customerid) on delete cascade,
  groupid       bigint references public.ws_tblcustomergroups(groupid) on delete cascade,
  areaid        bigint references public.ws_tblareas(areaid) on delete cascade,
  price         numeric(12,2) not null check (price >= 0),
  effectivefrom date not null default current_date,
  effectiveto   date,
  createddate   timestamptz not null default now(),
  constraint ck_price_single_scope check (
    (customerid is not null)::int + (groupid is not null)::int + (areaid is not null)::int <= 1
  ),
  constraint ck_price_date_order check (effectiveto is null or effectiveto >= effectivefrom)
);

create index if not exists ix_price_lookup
  on public.ws_tblproductprices(orgid, productid, effectivefrom desc);
create index if not exists ix_price_customer on public.ws_tblproductprices(customerid) where customerid is not null;

-- Overlapping windows for the same scope make pricing non-deterministic.
-- These partial unique indexes forbid two open-ended rows per scope; date-range
-- overlap beyond that is caught by the validation trigger below.
create or replace function ws.tg_price_no_overlap()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
begin
  if exists (
    select 1 from public.ws_tblproductprices p
    where p.orgid = new.orgid
      and p.productid = new.productid
      and p.priceid <> coalesce(new.priceid, -1)
      and p.customerid is not distinct from new.customerid
      and p.groupid    is not distinct from new.groupid
      and p.areaid     is not distinct from new.areaid
      and daterange(p.effectivefrom, p.effectiveto, '[]')
          && daterange(new.effectivefrom, new.effectiveto, '[]')
  ) then
    raise exception
      'overlapping price window for product % in this scope (from % to %)',
      new.productid, new.effectivefrom, coalesce(new.effectiveto::text, 'open')
      using errcode = '23505';
  end if;
  return new;
end
$$;

drop trigger if exists trg_price_no_overlap on public.ws_tblproductprices;
create trigger trg_price_no_overlap
  before insert or update on public.ws_tblproductprices
  for each row execute function ws.tg_price_no_overlap();

-- -----------------------------------------------------------------------------
-- ws.resolve_price(orgid, productid, customerid, date)
-- The single source of truth for "what does this customer pay today".
-- Precedence: customer > customer group > area > org default > legacy area
-- rateperbottle / customer rateoverride > product.saleprice.
-- -----------------------------------------------------------------------------
create or replace function ws.resolve_price(
  p_orgid      bigint,
  p_productid  bigint,
  p_customerid bigint,
  p_on         date default current_date
)
returns numeric
language plpgsql
stable
set search_path = ws, public, pg_catalog
as $$
declare
  v_areaid           bigint;
  v_groupid          bigint;
  v_price            numeric(12,2);
  v_legacy           numeric(12,2);
  v_isdefaultbottle  boolean;
begin
  select c.areaid, c.groupid, c.rateoverride
    into v_areaid, v_groupid, v_legacy
  from public.ws_tblcustomers c
  where c.customerid = p_customerid and c.orgid = p_orgid;

  select p.price into v_price
  from public.ws_tblproductprices p
  where p.orgid = p_orgid
    and p.productid = p_productid
    and p_on between p.effectivefrom and coalesce(p.effectiveto, 'infinity'::date)
    and (
         p.customerid = p_customerid
      or (p.customerid is null and p.groupid = v_groupid)
      or (p.customerid is null and p.groupid is null and p.areaid = v_areaid)
      or (p.customerid is null and p.groupid is null and p.areaid is null)
    )
  order by
    (p.customerid is not null) desc,
    (p.groupid    is not null) desc,
    (p.areaid     is not null) desc,
    p.effectivefrom desc
  limit 1;

  if v_price is not null then
    return v_price;
  end if;

  -- Legacy fallbacks (customer.rateoverride, area.rateperbottle) exist so an org
  -- that has not migrated its pricing still bills correctly. They describe a
  -- per-BOTTLE rate, so they must apply ONLY to the default returnable product.
  -- Applying them to everything would bill a case of 500ml at the 19L water
  -- rate — which is precisely what the first test run caught.
  select (p.bottletypeid is not null and b.isdefault) into v_isdefaultbottle
  from public.ws_tblproducts p
  left join public.ws_tblbottletypes b on b.bottletypeid = p.bottletypeid
  where p.productid = p_productid;

  if coalesce(v_isdefaultbottle, false) then
    if v_legacy is not null then
      return v_legacy;
    end if;

    select a.rateperbottle into v_price
    from public.ws_tblareas a where a.areaid = v_areaid and a.rateperbottle > 0;
    if v_price is not null then
      return v_price;
    end if;
  end if;

  select pr.saleprice into v_price
  from public.ws_tblproducts pr where pr.productid = p_productid;

  return coalesce(v_price, 0);
end
$$;

-- Exposed read-only wrapper so the UI can preview a price without duplicating
-- the precedence logic in Dart.
create or replace function public.ws_resolve_price(
  p_orgid bigint, p_productid bigint, p_customerid bigint, p_on date default current_date
)
returns numeric
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select case
    when ws.is_member(p_orgid) then ws.resolve_price(p_orgid, p_productid, p_customerid, p_on)
    else null
  end
$$;

revoke all on function public.ws_resolve_price(bigint,bigint,bigint,date) from public;
grant execute on function public.ws_resolve_price(bigint,bigint,bigint,date) to authenticated;

-- ─── updated_at triggers ─────────────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array[
    'ws_tblareas','ws_tblproducts','ws_tblcustomers','ws_tblvendors'
  ] loop
    execute format('drop trigger if exists trg_touch_%1$s on public.%1$s', t);
    execute format(
      'create trigger trg_touch_%1$s before update on public.%1$s
       for each row execute function ws.tg_touch_updated_at()', t);
  end loop;
end
$$;


-- #############################################################################
-- ## SECTION 004 — 004_accounting_core.sql
-- #############################################################################

-- =============================================================================
-- 004_accounting_core.sql
-- Chart of accounts, journal entries, and in-transaction posting.
--
-- YOU CHOSE "BOTH, JOURNAL DERIVED". READ THIS BEFORE GOING FURTHER.
--
-- The risk you accepted is drift: the subsidiary tables say the customer owes
-- 5,500 and the AR control account says 5,200, and nobody notices for months.
-- A background poster (cron job, queue worker, edge function) makes that risk
-- permanent, because any crash between "insert sale" and "post journal" leaves
-- the two out of step and there is no bound on how long it stays that way.
--
-- So this schema does NOT use a background poster. Journal entries are written
-- by AFTER triggers in the same database transaction as the source row. Either
-- both exist or neither does — the failure mode is eliminated structurally
-- rather than monitored.
--
-- Two consequences you should know about:
--   1. A posting-rule bug now aborts the delivery insert instead of silently
--      producing a wrong report. That is deliberate. Loud beats wrong.
--   2. Backdating still needs care: vw_ws_trialbalance is period-filtered, so a
--      sale posted late lands in the period of its document date, not today.
--
-- vw_ws_reconciliation (migration 007) compares the AR/AP control accounts
-- against the subsidiary sums. It should always return zero rows. Put it on the
-- dashboard; a non-empty result means a posting rule is wrong.
-- =============================================================================

-- ─── Chart of accounts ───────────────────────────────────────────────────────

create table if not exists public.ws_tblaccounts (
  accountid    bigint generated by default as identity primary key,
  orgid        bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  accountcode  text   not null,
  accountname  text   not null,
  accounttype  text   not null
               check (accounttype in ('asset','liability','equity','income','expense')),
  parentid     bigint references public.ws_tblaccounts(accountid) on delete set null,
  -- Control accounts are posted to by triggers only and are reconciled against
  -- their subsidiary ledger. Manual journal entries against them are rejected.
  controlfor   text
               check (controlfor in ('ar','ap','cash','bank','inventory','bottledeposit')),
  isactive     boolean not null default true,
  createddate  timestamptz not null default now(),
  unique (orgid, accountcode)
);

create unique index if not exists ux_account_control_per_org
  on public.ws_tblaccounts(orgid, controlfor)
  where controlfor is not null and controlfor not in ('cash','bank');

create index if not exists ix_accounts_org on public.ws_tblaccounts(orgid);

-- Normal balance side: +1 means debits increase the account.
create or replace function ws.account_sign(p_type text)
returns int
language sql
immutable
set search_path = pg_catalog
as $$
  select case when p_type in ('asset','expense') then 1 else -1 end
$$;

-- ─── Journal ─────────────────────────────────────────────────────────────────

create table if not exists public.ws_tbljournalentries (
  journalid    bigint generated by default as identity primary key,
  orgid        bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  entrydate    date   not null default current_date,
  entryno      text,
  -- What produced this entry. 'manual' is the only value a human may insert.
  sourcetype   text   not null
               check (sourcetype in ('manual','sale','customerpayment','purchase','vendorpayment','bottleadjustment','opening')),
  sourceid     bigint,
  memo         text,
  isposted     boolean not null default true,
  createdby    uuid   references auth.users(id) on delete set null,
  createddate  timestamptz not null default now(),
  unique (orgid, sourcetype, sourceid)
);

create index if not exists ix_journal_org_date on public.ws_tbljournalentries(orgid, entrydate);

create table if not exists public.ws_tbljournalentrydetails (
  detailid   bigint generated by default as identity primary key,
  journalid   bigint not null references public.ws_tbljournalentries(journalid) on delete cascade,
  orgid       bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  accountid   bigint not null references public.ws_tblaccounts(accountid) on delete restrict,
  -- Subsidiary keys: let the journal be sliced per customer/vendor without a
  -- separate ledger table. This is what makes reconciliation cheap.
  customerid  bigint references public.ws_tblcustomers(customerid) on delete set null,
  vendorid    bigint references public.ws_tblvendors(vendorid) on delete set null,
  debit       numeric(14,2) not null default 0 check (debit  >= 0),
  credit      numeric(14,2) not null default 0 check (credit >= 0),
  description text,
  constraint ck_detail_one_side check (
    (debit > 0 and credit = 0) or (credit > 0 and debit = 0) or (debit = 0 and credit = 0)
  )
);

create index if not exists ix_jdetail_journal  on public.ws_tbljournalentrydetails(journalid);
create index if not exists ix_jdetail_account  on public.ws_tbljournalentrydetails(orgid, accountid);
create index if not exists ix_jdetail_customer on public.ws_tbljournalentrydetails(orgid, customerid) where customerid is not null;
create index if not exists ix_jdetail_vendor   on public.ws_tbljournalentrydetails(orgid, vendorid)   where vendorid is not null;

-- Cross-tenant guard: a detail line must belong to the same org as its header
-- and its account.
create or replace function ws.tg_jdetail_validate()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_header_org bigint;
  v_acct_org   bigint;
begin
  select orgid into v_header_org from public.ws_tbljournalentries where journalid = new.journalid;
  select orgid into v_acct_org   from public.ws_tblaccounts       where accountid = new.accountid;

  perform ws.assert_same_org(new.orgid, v_header_org, 'journal detail vs entry');
  perform ws.assert_same_org(new.orgid, v_acct_org,   'journal detail vs account');
  return new;
end
$$;

drop trigger if exists trg_jdetail_validate on public.ws_tbljournalentrydetails;
create trigger trg_jdetail_validate
  before insert or update on public.ws_tbljournalentrydetails
  for each row execute function ws.tg_jdetail_validate();

-- -----------------------------------------------------------------------------
-- Balanced-entry enforcement.
-- A DEFERRABLE constraint trigger runs at COMMIT, so an entry can be built up
-- line by line and still be checked. Without DEFERRABLE the first line would
-- always fail, which is why naive implementations end up with no check at all.
-- -----------------------------------------------------------------------------
create or replace function ws.tg_journal_must_balance()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_journalid bigint := coalesce(new.journalid, old.journalid);
  v_diff      numeric(14,2);
  v_lines     int;
begin
  select coalesce(sum(debit),0) - coalesce(sum(credit),0), count(*)
    into v_diff, v_lines
  from public.ws_tbljournalentrydetails
  where journalid = v_journalid;

  -- Header deleted (cascade): nothing to check.
  if not exists (select 1 from public.ws_tbljournalentries where journalid = v_journalid) then
    return null;
  end if;

  if v_lines = 0 then
    raise exception 'journal entry % has no lines', v_journalid using errcode = '23514';
  end if;

  if v_diff <> 0 then
    raise exception 'journal entry % is unbalanced by %', v_journalid, v_diff
      using errcode = '23514';
  end if;

  return null;
end
$$;

drop trigger if exists trg_journal_must_balance on public.ws_tbljournalentrydetails;
create constraint trigger trg_journal_must_balance
  after insert or update or delete on public.ws_tbljournalentrydetails
  deferrable initially deferred
  for each row execute function ws.tg_journal_must_balance();

-- Manual entries may not touch AR/AP control accounts: those are owned by the
-- subsidiary ledgers, and a hand-posted line there is exactly how drift starts.
create or replace function ws.tg_journal_guard_control()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_source text;
  v_control text;
begin
  select sourcetype into v_source from public.ws_tbljournalentries where journalid = new.journalid;
  select controlfor into v_control from public.ws_tblaccounts    where accountid = new.accountid;

  if v_source = 'manual' and v_control in ('ar','ap') then
    raise exception
      'account % is the % control account; post a sale/payment document instead of a manual journal',
      new.accountid, v_control
      using errcode = '42501';
  end if;
  return new;
end
$$;

drop trigger if exists trg_journal_guard_control on public.ws_tbljournalentrydetails;
create trigger trg_journal_guard_control
  before insert on public.ws_tbljournalentrydetails
  for each row execute function ws.tg_journal_guard_control();

-- ─── Posting helpers used by the operations triggers ─────────────────────────

create or replace function ws.account_by_code(p_orgid bigint, p_code text)
returns bigint
language plpgsql
stable
set search_path = ws, public, pg_catalog
as $$
declare v_id bigint;
begin
  select accountid into v_id
  from public.ws_tblaccounts
  where orgid = p_orgid and accountcode = p_code and isactive;

  if v_id is null then
    raise exception
      'chart of accounts is missing account % for org % — run ws_seed_chart_of_accounts()',
      p_code, p_orgid
      using errcode = '23503';
  end if;
  return v_id;
end
$$;

create or replace function ws.account_by_control(p_orgid bigint, p_control text)
returns bigint
language plpgsql
stable
set search_path = ws, public, pg_catalog
as $$
declare v_id bigint;
begin
  select accountid into v_id
  from public.ws_tblaccounts
  where orgid = p_orgid and controlfor = p_control and isactive
  order by accountid
  limit 1;

  if v_id is null then
    raise exception 'no % control account configured for org %', p_control, p_orgid
      using errcode = '23503';
  end if;
  return v_id;
end
$$;

-- Creates (or replaces) the journal entry for a source document. Idempotent on
-- (orgid, sourcetype, sourceid): re-posting an edited document rewrites its
-- lines rather than duplicating them.
create or replace function ws.journal_upsert_header(
  p_orgid      bigint,
  p_sourcetype text,
  p_sourceid   bigint,
  p_date       date,
  p_memo       text
)
returns bigint
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare v_journalid bigint;
begin
  insert into public.ws_tbljournalentries (orgid, sourcetype, sourceid, entrydate, memo, createdby)
  values (p_orgid, p_sourcetype, p_sourceid, p_date, p_memo, ws.current_uid())
  on conflict (orgid, sourcetype, sourceid)
  do update set entrydate = excluded.entrydate, memo = excluded.memo
  returning journalid into v_journalid;

  delete from public.ws_tbljournalentrydetails where journalid = v_journalid;
  return v_journalid;
end
$$;

create or replace function ws.journal_line(
  p_journalid  bigint,
  p_orgid      bigint,
  p_accountid  bigint,
  p_debit      numeric,
  p_credit     numeric,
  p_customerid bigint default null,
  p_vendorid   bigint default null,
  p_desc       text   default null
)
returns void
language plpgsql
set search_path = ws, public, pg_catalog
as $$
begin
  if coalesce(p_debit,0) = 0 and coalesce(p_credit,0) = 0 then
    return;   -- skip zero lines rather than clutter the ledger
  end if;
  insert into public.ws_tbljournalentrydetails
    (journalid, orgid, accountid, customerid, vendorid, debit, credit, description)
  values
    (p_journalid, p_orgid, p_accountid, p_customerid, p_vendorid,
     coalesce(p_debit,0), coalesce(p_credit,0), p_desc);
end
$$;

-- ─── Default chart of accounts ───────────────────────────────────────────────

create or replace function ws.seed_chart_of_accounts(p_orgid bigint)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
begin
  insert into public.ws_tblaccounts (orgid, accountcode, accountname, accounttype, controlfor) values
    (p_orgid, '1000', 'Cash in Hand',              'asset',     'cash'),
    (p_orgid, '1010', 'Bank Account',              'asset',     'bank'),
    (p_orgid, '1100', 'Accounts Receivable',       'asset',     'ar'),
    (p_orgid, '1200', 'Inventory',                 'asset',     'inventory'),
    (p_orgid, '1300', 'Bottles in Circulation',    'asset',     null),
    (p_orgid, '2000', 'Accounts Payable',          'liability', 'ap'),
    (p_orgid, '2100', 'Bottle Deposits Held',      'liability', 'bottledeposit'),
    (p_orgid, '3000', 'Owner Equity',              'equity',    null),
    (p_orgid, '3900', 'Opening Balance Equity',    'equity',    null),
    (p_orgid, '4000', 'Water Sales',               'income',    null),
    (p_orgid, '4100', 'Other Income',              'income',    null),
    (p_orgid, '5000', 'Cost of Goods Sold',        'expense',   null),
    (p_orgid, '5100', 'Bottle Loss and Damage',    'expense',   null),
    (p_orgid, '5200', 'Delivery and Fuel',         'expense',   null),
    (p_orgid, '5900', 'Other Expenses',            'expense',   null)
  on conflict (orgid, accountcode) do nothing;

  -- Point the default payment methods at their settlement accounts.
  insert into public.ws_tblpaymentmethods (orgid, methodcode, methodname, accountid, sortorder)
  select p_orgid, x.code, x.name, ws.account_by_code(p_orgid, x.acct), x.ord
  from (values
    ('cash',      'Cash',          '1000', 1),
    ('easypaisa', 'Easypaisa',     '1010', 2),
    ('jazzcash',  'JazzCash',      '1010', 3),
    ('bank',      'Bank Transfer', '1010', 4),
    ('other',     'Other',         '1000', 5)
  ) as x(code, name, acct, ord)
  on conflict (orgid, methodcode) do nothing;
end
$$;

create or replace function public.ws_seed_chart_of_accounts(p_orgid bigint)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
begin
  if not ws.is_member(p_orgid) then
    raise exception 'not a member of org %', p_orgid using errcode = '42501';
  end if;
  perform ws.seed_chart_of_accounts(p_orgid);
end
$$;

revoke all on function ws.seed_chart_of_accounts(bigint) from public;
revoke all on function public.ws_seed_chart_of_accounts(bigint) from public;
grant execute on function public.ws_seed_chart_of_accounts(bigint) to authenticated;

-- `add constraint` has no IF NOT EXISTS in Postgres, so a bare ALTER makes this
-- whole file fail on a second run with "constraint already exists" — and these
-- files WILL be re-run while a migration is being sorted out.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'fk_paymentmethod_account'
      and conrelid = 'public.ws_tblpaymentmethods'::regclass
  ) then
    alter table public.ws_tblpaymentmethods
      add constraint fk_paymentmethod_account
      foreign key (accountid) references public.ws_tblaccounts(accountid)
      on delete set null;
  end if;
end
$$;


-- #############################################################################
-- ## SECTION 005 — 005_operations_and_triggers.sql
-- #############################################################################

-- =============================================================================
-- 005_operations_and_triggers.sql
-- Deliveries, bottle movements, customer payments, document numbering.
--
-- DESIGN NOTE — WHY THE HEADER KEEPS AGGREGATE COLUMNS
-- ws_tbldeliveries has both normalised line items (ws_tbldeliverydetails) and
-- cached totals (bottlesdelivered, bottlesreturned, amountcharged). The cache is
-- not laziness: the paper card, the daily route sheet and the customer ledger
-- all read one row per delivery, and the existing Flutter code already reads
-- these columns. They are maintained by trigger and are never client-writable.
--
-- DESIGN NOTE — BOTTLE BALANCE IS DERIVED, NOT STORED
-- ws_tblbottletransactions is append-only and is the only truth. Two caches are
-- maintained from it by trigger:
--   ws_tblcustomerbottlebalances  (per customer per bottle type — authoritative cache)
--   ws_tblcustomers.bottlebalance (default bottle type only — legacy, for the
--                                  current Flutter build; do not write to it)
-- Recompute either from history at any time with ws_rebuild_bottle_balances().
-- =============================================================================

-- ─── Document number sequences ───────────────────────────────────────────────

create table if not exists public.ws_tbldocumentsequences (
  orgid     bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  doctype   text   not null check (doctype in ('delivery','invoice','receipt','purchase','vendorpayment','journal')),
  prefix    text   not null default '',
  nextno    bigint not null default 1,
  padwidth  int    not null default 6,
  primary key (orgid, doctype)
);

-- UPDATE ... RETURNING takes a row lock, so concurrent delivery inserts cannot
-- receive the same number. A plain sequence would be gapless-unsafe per tenant.
create or replace function ws.next_docnumber(p_orgid bigint, p_doctype text)
returns text
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_prefix text;
  v_no     bigint;
  v_pad    int;
begin
  insert into public.ws_tbldocumentsequences (orgid, doctype, prefix)
  values (p_orgid, p_doctype, '')
  on conflict (orgid, doctype) do nothing;

  update public.ws_tbldocumentsequences
     set nextno = nextno + 1
   where orgid = p_orgid and doctype = p_doctype
  returning prefix, nextno - 1, padwidth into v_prefix, v_no, v_pad;

  if v_prefix = '' then
    select case p_doctype
             when 'delivery' then deliveryprefix
             when 'invoice'  then invoiceprefix
             when 'receipt'  then receiptprefix
             else upper(left(p_doctype, 3)) || '-'
           end
      into v_prefix
    from public.ws_tblorganization where orgid = p_orgid;
  end if;

  return coalesce(v_prefix,'') || lpad(v_no::text, v_pad, '0');
end
$$;

-- ─── Bottle balance cache ────────────────────────────────────────────────────

create table if not exists public.ws_tblcustomerbottlebalances (
  orgid        bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  customerid   bigint not null references public.ws_tblcustomers(customerid) on delete cascade,
  bottletypeid bigint not null references public.ws_tblbottletypes(bottletypeid) on delete cascade,
  balance      int    not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (customerid, bottletypeid)
);

create index if not exists ix_bottlebal_org on public.ws_tblcustomerbottlebalances(orgid);

-- ─── Bottle inventory snapshots (LEGACY) ─────────────────────────────────────
-- Superseded by vw_ws_bottleposition, which derives the same figures from the
-- bottle ledger instead of relying on someone remembering to take a snapshot.
-- Created here because the original app's Dart still reads it
-- (WsDataService.fetchLatestSnapshot / insertSnapshot), and without a definition
-- a FRESH install would 404 on that call while an upgraded install would not —
-- the worst kind of environment-dependent bug.
--
-- Migration 008 enables RLS on every ws_tbl% table. A table with RLS enabled and
-- no policy returns zero rows to everyone, so it needs explicit policies there
-- too; see the master-data policy loop.
create table if not exists public.ws_tblbottleinventory (
  inventoryid          bigint generated by default as identity primary key,
  orgid                bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  snapshotdate         date   not null default current_date,
  totalbottles         int    not null default 0,
  bottleswithcustomers int    not null default 0,
  bottlesinstock       int    not null default 0,
  bottleslost          int    not null default 0,
  notes                text,
  createddate          timestamptz not null default now()
);

create index if not exists ix_bottleinventory_org
  on public.ws_tblbottleinventory(orgid, snapshotdate desc);

-- ─── Deliveries ──────────────────────────────────────────────────────────────

create table if not exists public.ws_tbldeliveries (
  deliveryid       bigint generated by default as identity primary key,
  orgid            bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  customerid       bigint not null references public.ws_tblcustomers(customerid) on delete restrict,
  routeid          bigint references public.ws_tblroutes(routeid) on delete set null,
  deliveredbyid    bigint references public.ws_tblinternalusers(internaluserid) on delete set null,
  deliverydate     date   not null default current_date,
  referenceno      text,
  notes            text,

  -- Trigger-maintained caches. Client writes are ignored (see tg_delivery_seal).
  bottlesdelivered int           not null default 0,
  bottlesreturned  int           not null default 0,
  bottlebalance    int           not null default 0,   -- default bottle type, after this delivery
  rateapplied      numeric(12,2) not null default 0,   -- default product's resolved rate
  amountcharged    numeric(14,2) not null default 0,

  isvoid           boolean not null default false,
  createdby        uuid   references auth.users(id) on delete set null,
  createddate      timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (orgid, referenceno)
);

create index if not exists ix_deliveries_org_date  on public.ws_tbldeliveries(orgid, deliverydate desc);
create index if not exists ix_deliveries_customer  on public.ws_tbldeliveries(orgid, customerid, deliverydate);
create index if not exists ix_deliveries_route     on public.ws_tbldeliveries(routeid, deliverydate);

create table if not exists public.ws_tbldeliverydetails (
  deliverydetailid bigint generated by default as identity primary key,
  deliveryid       bigint not null references public.ws_tbldeliveries(deliveryid) on delete cascade,
  orgid            bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  productid        bigint not null references public.ws_tblproducts(productid) on delete restrict,
  deliveredqty     numeric(12,2) not null default 0 check (deliveredqty >= 0),
  returnedqty      numeric(12,2) not null default 0 check (returnedqty  >= 0),
  unitprice        numeric(12,2) not null default 0 check (unitprice    >= 0),
  amount           numeric(14,2) not null default 0,
  notes            text
);

create index if not exists ix_deliverydetails_delivery on public.ws_tbldeliverydetails(deliveryid);

-- ─── Bottle transactions (append-only history) ───────────────────────────────

create table if not exists public.ws_tblbottletransactions (
  bottletxnid   bigint generated by default as identity primary key,
  orgid         bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  customerid    bigint references public.ws_tblcustomers(customerid) on delete restrict,
  bottletypeid  bigint not null references public.ws_tblbottletypes(bottletypeid) on delete restrict,
  deliveryid    bigint references public.ws_tbldeliveries(deliveryid) on delete cascade,
  txndate       date   not null default current_date,
  txntype       text   not null
                check (txntype in ('opening','delivery','return','damaged','lost','adjustment')),
  -- Signed movement from the ORGANIZATION's point of view of what the customer
  -- holds: positive = customer now holds more bottles.
  qty           int    not null,
  balancebefore int    not null,
  balanceafter  int    not null,
  notes         text,
  createdby     uuid   references auth.users(id) on delete set null,
  createddate   timestamptz not null default now(),
  constraint ck_bottletxn_math check (balanceafter = balancebefore + qty)
);

create index if not exists ix_bottletxn_customer
  on public.ws_tblbottletransactions(orgid, customerid, bottletypeid, txndate, bottletxnid);
create index if not exists ix_bottletxn_delivery on public.ws_tblbottletransactions(deliveryid);

-- Append-only. Corrections are made with a compensating 'adjustment' row so the
-- audit trail survives; this is the whole point of a transaction-based design.
create or replace function ws.tg_bottletxn_append_only()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
begin
  raise exception
    'ws_tblbottletransactions is append-only; insert a compensating adjustment row instead of %',
    lower(tg_op)
    using errcode = '42501';
end
$$;

drop trigger if exists trg_bottletxn_append_only on public.ws_tblbottletransactions;
create trigger trg_bottletxn_append_only
  before update or delete on public.ws_tblbottletransactions
  for each row execute function ws.tg_bottletxn_append_only();

-- Fill balancebefore/balanceafter and hold a per-(customer, bottle type) lock so
-- two concurrent deliveries to the same customer cannot interleave and compute
-- the same "before" value.
create or replace function ws.tg_bottletxn_compute_balance()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_before int;
  v_org    bigint;
begin
  if new.customerid is null then
    -- Stock-side movement (e.g. bottles bought from a vendor): no customer balance.
    new.balancebefore := 0;
    new.balanceafter  := new.qty;
    return new;
  end if;

  select orgid into v_org from public.ws_tblcustomers where customerid = new.customerid;
  perform ws.assert_same_org(new.orgid, v_org, 'bottle transaction vs customer');

  select orgid into v_org from public.ws_tblbottletypes where bottletypeid = new.bottletypeid;
  perform ws.assert_same_org(new.orgid, v_org, 'bottle transaction vs bottle type');

  perform pg_advisory_xact_lock(
    hashtextextended(new.customerid::text || ':' || new.bottletypeid::text, 0)
  );

  select coalesce(balance, 0) into v_before
  from public.ws_tblcustomerbottlebalances
  where customerid = new.customerid and bottletypeid = new.bottletypeid;

  new.balancebefore := coalesce(v_before, 0);
  new.balanceafter  := new.balancebefore + new.qty;
  return new;
end
$$;

drop trigger if exists trg_bottletxn_compute on public.ws_tblbottletransactions;
create trigger trg_bottletxn_compute
  before insert on public.ws_tblbottletransactions
  for each row execute function ws.tg_bottletxn_compute_balance();

-- Maintain the two caches.
create or replace function ws.tg_bottletxn_apply_cache()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_isdefault boolean;
begin
  if new.customerid is null then
    return null;
  end if;

  insert into public.ws_tblcustomerbottlebalances (orgid, customerid, bottletypeid, balance)
  values (new.orgid, new.customerid, new.bottletypeid, new.balanceafter)
  on conflict (customerid, bottletypeid)
  do update set balance = new.balanceafter, updated_at = now();

  select isdefault into v_isdefault
  from public.ws_tblbottletypes where bottletypeid = new.bottletypeid;

  if coalesce(v_isdefault, false) then
    update public.ws_tblcustomers
       set bottlebalance = new.balanceafter
     where customerid = new.customerid;
  end if;

  return null;
end
$$;

drop trigger if exists trg_bottletxn_cache on public.ws_tblbottletransactions;
create trigger trg_bottletxn_cache
  after insert on public.ws_tblbottletransactions
  for each row execute function ws.tg_bottletxn_apply_cache();

-- ─── Customer payments ───────────────────────────────────────────────────────
-- Balance-forward, not invoice-allocated. The paper card works this way: money
-- reduces the running balance, it is not matched to a specific delivery. Adding
-- allocation later means a ws_tblpaymentallocations child table; nothing here
-- has to change. Do not add it before a customer actually asks for per-invoice
-- aging, because it doubles the reconciliation surface.

create table if not exists public.ws_tblpayments (
  paymentid      bigint generated by default as identity primary key,
  orgid          bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  customerid     bigint not null references public.ws_tblcustomers(customerid) on delete restrict,
  deliveryid     bigint references public.ws_tbldeliveries(deliveryid) on delete set null,
  receivedbyid   bigint references public.ws_tblinternalusers(internaluserid) on delete set null,
  methodid       bigint references public.ws_tblpaymentmethods(methodid) on delete set null,
  paymentdate    date   not null default current_date,
  amountreceived numeric(14,2) not null check (amountreceived > 0),
  -- Legacy text column the current Flutter code writes (paymentmethod.name).
  paymentmethod  text   not null default 'cash',
  receiptno      text,
  referenceno    text,
  notes          text,
  isvoid         boolean not null default false,
  createdby      uuid   references auth.users(id) on delete set null,
  createddate    timestamptz not null default now(),
  unique (orgid, receiptno)
);

create index if not exists ix_payments_org_date on public.ws_tblpayments(orgid, paymentdate desc);
create index if not exists ix_payments_customer on public.ws_tblpayments(orgid, customerid, paymentdate);

-- ─── Delivery total recalculation ────────────────────────────────────────────

-- ws.internal_recalc is the flag that lets recalc_delivery() write the derived
-- columns that tg_delivery_seal() otherwise pins. Without it the seal trigger
-- silently reverts every recalculation and the card reads all zeros — which is
-- exactly the failure this project already had in a different form.
create or replace function ws.recalc_delivery(p_deliveryid bigint)
returns void
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_org        bigint;
  v_customer   bigint;
  v_date       date;
  v_defbtid    bigint;
  v_delivered  int;
  v_returned   int;
  v_amount     numeric(14,2);
  v_rate       numeric(12,2);
  v_balance    int;
begin
  select orgid, customerid, deliverydate
    into v_org, v_customer, v_date
  from public.ws_tbldeliveries where deliveryid = p_deliveryid;

  if v_org is null then
    return;
  end if;

  select bottletypeid into v_defbtid
  from public.ws_tblbottletypes where orgid = v_org and isdefault;

  -- Bottle counts are attributed to the DEFAULT bottle type for the card view;
  -- per-type detail is available from ws_tblbottletransactions.
  select
    coalesce(sum(d.deliveredqty * p.bottlesperunit)::int, 0),
    coalesce(sum(d.returnedqty  * p.bottlesperunit)::int, 0),
    coalesce(sum(d.amount), 0)
  into v_delivered, v_returned, v_amount
  from public.ws_tbldeliverydetails d
  join public.ws_tblproducts p on p.productid = d.productid
  where d.deliveryid = p_deliveryid
    and p.bottletypeid is not distinct from v_defbtid;

  -- Amount must include non-returnable lines too.
  select coalesce(sum(amount), 0) into v_amount
  from public.ws_tbldeliverydetails where deliveryid = p_deliveryid;

  select d.unitprice into v_rate
  from public.ws_tbldeliverydetails d
  join public.ws_tblproducts p on p.productid = d.productid
  where d.deliveryid = p_deliveryid and p.bottletypeid is not distinct from v_defbtid
  order by d.deliverydetailid
  limit 1;

  select coalesce(balance, 0) into v_balance
  from public.ws_tblcustomerbottlebalances
  where customerid = v_customer and bottletypeid = v_defbtid;

  perform set_config('ws.internal_recalc', '1', true);

  update public.ws_tbldeliveries
     set bottlesdelivered = v_delivered,
         bottlesreturned  = v_returned,
         amountcharged    = v_amount,
         rateapplied      = coalesce(v_rate, 0),
         bottlebalance    = coalesce(v_balance, 0),
         updated_at       = now()
   where deliveryid = p_deliveryid;

  perform set_config('ws.internal_recalc', '', true);
end
$$;

-- Line items: price defaults from ws.resolve_price(), amount is always derived.
create or replace function ws.tg_deliverydetail_prepare()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_org      bigint;
  v_customer bigint;
  v_date     date;
  v_prodorg  bigint;
begin
  select orgid, customerid, deliverydate
    into v_org, v_customer, v_date
  from public.ws_tbldeliveries where deliveryid = new.deliveryid;

  new.orgid := v_org;

  select orgid into v_prodorg from public.ws_tblproducts where productid = new.productid;
  perform ws.assert_same_org(v_org, v_prodorg, 'delivery detail vs product');

  if new.unitprice is null or new.unitprice = 0 then
    new.unitprice := ws.resolve_price(v_org, new.productid, v_customer, v_date);
  end if;

  new.amount := round(new.deliveredqty * new.unitprice, 2);
  return new;
end
$$;

drop trigger if exists trg_deliverydetail_prepare on public.ws_tbldeliverydetails;
create trigger trg_deliverydetail_prepare
  before insert or update on public.ws_tbldeliverydetails
  for each row execute function ws.tg_deliverydetail_prepare();

-- Move bottles for the line, then refresh header totals and re-post the journal.
create or replace function ws.tg_deliverydetail_after()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  r record;
  v_org        bigint;
  v_customer   bigint;
  v_date       date;
  v_bottletype bigint;
  v_per        int;
  v_out        int;
  v_in         int;
begin
  r := coalesce(new, old);

  select d.orgid, d.customerid, d.deliverydate
    into v_org, v_customer, v_date
  from public.ws_tbldeliveries d where d.deliveryid = r.deliveryid;

  if v_org is null then
    return null;   -- header being deleted; cascade will clean up
  end if;

  select p.bottletypeid, p.bottlesperunit into v_bottletype, v_per
  from public.ws_tblproducts p where p.productid = r.productid;

  if tg_op = 'INSERT' and v_bottletype is not null and v_per > 0 then
    v_out := (new.deliveredqty * v_per)::int;
    v_in  := (new.returnedqty  * v_per)::int;

    if v_out <> 0 then
      insert into public.ws_tblbottletransactions
        (orgid, customerid, bottletypeid, deliveryid, txndate, txntype, qty, balancebefore, balanceafter, createdby)
      values (v_org, v_customer, v_bottletype, r.deliveryid, v_date, 'delivery', v_out, 0, 0, ws.current_uid());
    end if;

    if v_in <> 0 then
      insert into public.ws_tblbottletransactions
        (orgid, customerid, bottletypeid, deliveryid, txndate, txntype, qty, balancebefore, balanceafter, createdby)
      values (v_org, v_customer, v_bottletype, r.deliveryid, v_date, 'return', -v_in, 0, 0, ws.current_uid());
    end if;
  end if;

  perform ws.recalc_delivery(r.deliveryid);
  perform ws.post_delivery(r.deliveryid);
  return null;
end
$$;

drop trigger if exists trg_deliverydetail_after on public.ws_tbldeliverydetails;
create trigger trg_deliverydetail_after
  after insert or update or delete on public.ws_tbldeliverydetails
  for each row execute function ws.tg_deliverydetail_after();

-- Header: assign a reference number, block client writes to derived columns.
create or replace function ws.tg_delivery_seal()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_custorg bigint;
begin
  if tg_op = 'INSERT' then
    select orgid into v_custorg from public.ws_tblcustomers where customerid = new.customerid;
    perform ws.assert_same_org(new.orgid, v_custorg, 'delivery vs customer');

    if new.referenceno is null then
      new.referenceno := ws.next_docnumber(new.orgid, 'delivery');
    end if;
    new.createdby := coalesce(new.createdby, ws.current_uid());
    -- Derived columns start at zero regardless of what the client sent.
    new.bottlesdelivered := 0;
    new.bottlesreturned  := 0;
    new.bottlebalance    := 0;
    new.rateapplied      := 0;
    new.amountcharged    := 0;
  elsif coalesce(current_setting('ws.internal_recalc', true), '') <> '1' then
    -- Preserve derived columns on client updates; only recalc_delivery may
    -- change them, and it announces itself with ws.internal_recalc.
    new.bottlesdelivered := old.bottlesdelivered;
    new.bottlesreturned  := old.bottlesreturned;
    new.bottlebalance    := old.bottlebalance;
    new.rateapplied      := old.rateapplied;
    new.amountcharged    := old.amountcharged;
    new.updated_at       := now();
  end if;
  return new;
end
$$;

drop trigger if exists trg_delivery_seal on public.ws_tbldeliveries;
create trigger trg_delivery_seal
  before insert or update on public.ws_tbldeliveries
  for each row execute function ws.tg_delivery_seal();

-- ─── Journal posting: sale ───────────────────────────────────────────────────
-- Runs inside the caller's transaction. Debit AR, credit Sales.

create or replace function ws.post_delivery(p_deliveryid bigint)
returns void
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_org      bigint;
  v_customer bigint;
  v_date     date;
  v_amount   numeric(14,2);
  v_void     boolean;
  v_ref      text;
  v_j        bigint;
begin
  select orgid, customerid, deliverydate, amountcharged, isvoid, referenceno
    into v_org, v_customer, v_date, v_amount, v_void, v_ref
  from public.ws_tbldeliveries where deliveryid = p_deliveryid;

  if v_org is null then
    return;
  end if;

  if v_void or coalesce(v_amount, 0) = 0 then
    delete from public.ws_tbljournalentries
    where orgid = v_org and sourcetype = 'sale' and sourceid = p_deliveryid;
    return;
  end if;

  v_j := ws.journal_upsert_header(v_org, 'sale', p_deliveryid, v_date,
                                  'Delivery ' || coalesce(v_ref, p_deliveryid::text));

  perform ws.journal_line(v_j, v_org, ws.account_by_control(v_org, 'ar'),
                          v_amount, 0, v_customer, null, 'Water delivery');
  perform ws.journal_line(v_j, v_org, ws.account_by_code(v_org, '4000'),
                          0, v_amount, v_customer, null, 'Water sales');
end
$$;

create or replace function ws.tg_delivery_after()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
begin
  perform ws.post_delivery(new.deliveryid);
  return null;
end
$$;

drop trigger if exists trg_delivery_after on public.ws_tbldeliveries;
create trigger trg_delivery_after
  after update of isvoid, deliverydate on public.ws_tbldeliveries
  for each row execute function ws.tg_delivery_after();

-- ─── Journal posting: customer payment ───────────────────────────────────────
-- Debit Cash/Bank (per payment method), credit AR.

create or replace function ws.post_customer_payment(p_paymentid bigint)
returns void
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_org      bigint;
  v_customer bigint;
  v_date     date;
  v_amount   numeric(14,2);
  v_void     boolean;
  v_methodid bigint;
  v_method   text;
  v_acct     bigint;
  v_receipt  text;
  v_j        bigint;
begin
  select orgid, customerid, paymentdate, amountreceived, isvoid, methodid, paymentmethod, receiptno
    into v_org, v_customer, v_date, v_amount, v_void, v_methodid, v_method, v_receipt
  from public.ws_tblpayments where paymentid = p_paymentid;

  if v_org is null then
    return;
  end if;

  if v_void then
    delete from public.ws_tbljournalentries
    where orgid = v_org and sourcetype = 'customerpayment' and sourceid = p_paymentid;
    return;
  end if;

  -- Settlement account: explicit method, else the legacy text column, else cash.
  select accountid into v_acct
  from public.ws_tblpaymentmethods
  where (methodid = v_methodid)
     or (v_methodid is null and orgid = v_org and methodcode = coalesce(v_method,'cash'))
  order by (methodid = v_methodid) desc
  limit 1;

  v_acct := coalesce(v_acct, ws.account_by_control(v_org, 'cash'));

  v_j := ws.journal_upsert_header(v_org, 'customerpayment', p_paymentid, v_date,
                                  'Receipt ' || coalesce(v_receipt, p_paymentid::text));

  perform ws.journal_line(v_j, v_org, v_acct, v_amount, 0, v_customer, null, 'Cash received');
  perform ws.journal_line(v_j, v_org, ws.account_by_control(v_org, 'ar'),
                          0, v_amount, v_customer, null, 'Customer payment');
end
$$;

create or replace function ws.tg_payment_before()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare v_custorg bigint;
begin
  if tg_op = 'INSERT' then
    select orgid into v_custorg from public.ws_tblcustomers where customerid = new.customerid;
    perform ws.assert_same_org(new.orgid, v_custorg, 'payment vs customer');
    if new.receiptno is null then
      new.receiptno := ws.next_docnumber(new.orgid, 'receipt');
    end if;
    new.createdby := coalesce(new.createdby, ws.current_uid());
  end if;
  return new;
end
$$;

drop trigger if exists trg_payment_before on public.ws_tblpayments;
create trigger trg_payment_before
  before insert or update on public.ws_tblpayments
  for each row execute function ws.tg_payment_before();

create or replace function ws.tg_payment_after()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
begin
  perform ws.post_customer_payment(new.paymentid);
  return null;
end
$$;

drop trigger if exists trg_payment_after on public.ws_tblpayments;
create trigger trg_payment_after
  after insert or update on public.ws_tblpayments
  for each row execute function ws.tg_payment_after();

-- ─── Opening balances ────────────────────────────────────────────────────────
-- A customer's opening money balance and opening bottle balance must both enter
-- the system as transactions, otherwise the ledger does not tie to the journal.

create or replace function public.ws_set_customer_opening(
  p_customerid   bigint,
  p_openingdue   numeric default 0,
  p_bottletypeid bigint  default null,
  p_openingqty   int     default 0,
  p_asof         date    default current_date
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org bigint;
  v_bt  bigint;
  v_j   bigint;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'customers.manage') then
    raise exception 'permission denied: customers.manage' using errcode = '42501';
  end if;

  update public.ws_tblcustomers set openingbalance = p_openingdue where customerid = p_customerid;

  if coalesce(p_openingdue, 0) <> 0 then
    v_j := ws.journal_upsert_header(v_org, 'opening', p_customerid, p_asof,
             'Opening balance for customer ' || p_customerid);
    perform ws.journal_line(v_j, v_org, ws.account_by_control(v_org, 'ar'),
                            p_openingdue, 0, p_customerid, null, 'Opening receivable');
    perform ws.journal_line(v_j, v_org, ws.account_by_code(v_org, '3900'),
                            0, p_openingdue, p_customerid, null, 'Opening balance equity');
  end if;

  v_bt := coalesce(p_bottletypeid,
                   (select bottletypeid from public.ws_tblbottletypes where orgid = v_org and isdefault));

  if v_bt is not null and coalesce(p_openingqty, 0) <> 0 then
    insert into public.ws_tblbottletransactions
      (orgid, customerid, bottletypeid, txndate, txntype, qty, balancebefore, balanceafter, notes, createdby)
    values
      (v_org, p_customerid, v_bt, p_asof, 'opening', p_openingqty, 0, 0, 'Opening bottle balance', ws.current_uid());
  end if;
end
$$;

revoke all on function public.ws_set_customer_opening(bigint,numeric,bigint,int,date) from public;
grant execute on function public.ws_set_customer_opening(bigint,numeric,bigint,int,date) to authenticated;

-- ─── The one call the delivery screen needs ──────────────────────────────────
-- Mirrors the paper card exactly: delivered, received, and money taken, in one
-- atomic transaction. Replaces the current two-step client sequence in
-- delivery_screen.dart, where the payment insert can fail after the delivery
-- has already been committed.

create or replace function public.ws_record_delivery(
  p_customerid    bigint,
  p_deliverydate  date    default current_date,
  p_delivered     int     default 0,
  p_returned      int     default 0,
  p_productid     bigint  default null,
  p_amountpaid    numeric default 0,
  p_paymentmethod text    default 'cash',
  p_deliveredbyid bigint  default null,
  p_routeid       bigint  default null,
  p_notes         text    default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org        bigint;
  v_product    bigint;
  v_deliveryid bigint;
  v_methodid   bigint;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'delivery.manage') then
    raise exception 'permission denied: delivery.manage' using errcode = '42501';
  end if;

  -- Default product = the cheapest-to-guess correct thing: the org's returnable
  -- water product on the default bottle type.
  v_product := p_productid;
  if v_product is null then
    select p.productid into v_product
    from public.ws_tblproducts p
    join public.ws_tblbottletypes b on b.bottletypeid = p.bottletypeid
    where p.orgid = v_org and p.isactive and b.isdefault
    order by p.productid
    limit 1;
  end if;

  if v_product is null then
    raise exception 'org % has no returnable product configured on its default bottle type', v_org
      using errcode = 'P0002';
  end if;

  insert into public.ws_tbldeliveries
    (orgid, customerid, routeid, deliveredbyid, deliverydate, notes)
  values
    (v_org, p_customerid, p_routeid, p_deliveredbyid, p_deliverydate, p_notes)
  returning deliveryid into v_deliveryid;

  insert into public.ws_tbldeliverydetails
    (deliveryid, orgid, productid, deliveredqty, returnedqty)
  values
    (v_deliveryid, v_org, v_product, p_delivered, p_returned);

  if coalesce(p_amountpaid, 0) > 0 then
    select methodid into v_methodid
    from public.ws_tblpaymentmethods
    where orgid = v_org and methodcode = coalesce(p_paymentmethod, 'cash');

    insert into public.ws_tblpayments
      (orgid, customerid, deliveryid, receivedbyid, methodid, paymentdate,
       amountreceived, paymentmethod)
    values
      (v_org, p_customerid, v_deliveryid, p_deliveredbyid, v_methodid, p_deliverydate,
       p_amountpaid, coalesce(p_paymentmethod, 'cash'));
  end if;

  return v_deliveryid;
end
$$;

revoke all on function public.ws_record_delivery(bigint,date,int,int,bigint,numeric,text,bigint,bigint,text) from public;
grant execute on function public.ws_record_delivery(bigint,date,int,int,bigint,numeric,text,bigint,bigint,text) to authenticated;

-- ─── Cache rebuild (run after a bulk import or to prove the cache is honest) ──

create or replace function public.ws_rebuild_bottle_balances(p_orgid bigint)
returns int
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare v_rows int;
begin
  if not ws.has_perm(p_orgid, 'org.manage') then
    raise exception 'permission denied: org.manage' using errcode = '42501';
  end if;

  with truth as (
    select orgid, customerid, bottletypeid, sum(qty)::int as balance
    from public.ws_tblbottletransactions
    where orgid = p_orgid and customerid is not null
    group by orgid, customerid, bottletypeid
  )
  insert into public.ws_tblcustomerbottlebalances (orgid, customerid, bottletypeid, balance)
  select orgid, customerid, bottletypeid, balance from truth
  on conflict (customerid, bottletypeid)
  do update set balance = excluded.balance, updated_at = now();

  get diagnostics v_rows = row_count;

  update public.ws_tblcustomers c
     set bottlebalance = coalesce(b.balance, 0)
  from public.ws_tblbottletypes t
  left join public.ws_tblcustomerbottlebalances b
         on b.bottletypeid = t.bottletypeid and b.customerid = c.customerid
  where t.orgid = p_orgid and t.isdefault and c.orgid = p_orgid;

  return v_rows;
end
$$;

revoke all on function public.ws_rebuild_bottle_balances(bigint) from public;
grant execute on function public.ws_rebuild_bottle_balances(bigint) to authenticated;


-- #############################################################################
-- ## SECTION 006 — 006_vendor_operations.sql
-- #############################################################################

-- =============================================================================
-- 006_vendor_operations.sql
-- Purchases and vendor payments, with the same in-transaction posting rules.
-- =============================================================================

create table if not exists public.ws_tblpurchases (
  purchaseid   bigint generated by default as identity primary key,
  orgid        bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  vendorid     bigint not null references public.ws_tblvendors(vendorid) on delete restrict,
  purchasedate date   not null default current_date,
  billno       text,
  referenceno  text,
  notes        text,
  totalamount  numeric(14,2) not null default 0,   -- trigger-maintained
  isvoid       boolean not null default false,
  createdby    uuid   references auth.users(id) on delete set null,
  createddate  timestamptz not null default now(),
  unique (orgid, referenceno)
);

create index if not exists ix_purchases_org_date on public.ws_tblpurchases(orgid, purchasedate desc);
create index if not exists ix_purchases_vendor   on public.ws_tblpurchases(orgid, vendorid, purchasedate);

create table if not exists public.ws_tblpurchasedetails (
  purchasedetailid bigint generated by default as identity primary key,
  purchaseid       bigint not null references public.ws_tblpurchases(purchaseid) on delete cascade,
  orgid            bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  productid        bigint not null references public.ws_tblproducts(productid) on delete restrict,
  quantity         numeric(12,2) not null check (quantity > 0),
  unitcost         numeric(12,2) not null default 0 check (unitcost >= 0),
  amount           numeric(14,2) not null default 0,
  notes            text
);

create index if not exists ix_purchasedetails_purchase on public.ws_tblpurchasedetails(purchaseid);

create table if not exists public.ws_tblvendorpayments (
  vendorpaymentid bigint generated by default as identity primary key,
  orgid           bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  vendorid        bigint not null references public.ws_tblvendors(vendorid) on delete restrict,
  purchaseid      bigint references public.ws_tblpurchases(purchaseid) on delete set null,
  methodid        bigint references public.ws_tblpaymentmethods(methodid) on delete set null,
  paiddate        date   not null default current_date,
  amountpaid      numeric(14,2) not null check (amountpaid > 0),
  voucherno       text,
  referenceno     text,
  notes           text,
  isvoid          boolean not null default false,
  createdby       uuid   references auth.users(id) on delete set null,
  createddate     timestamptz not null default now(),
  unique (orgid, voucherno)
);

create index if not exists ix_vendorpayments_vendor on public.ws_tblvendorpayments(orgid, vendorid, paiddate);

-- ─── Purchase line preparation and stock-side bottle movement ────────────────

create or replace function ws.tg_purchasedetail_prepare()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_org     bigint;
  v_prodorg bigint;
begin
  select orgid into v_org from public.ws_tblpurchases where purchaseid = new.purchaseid;
  new.orgid := v_org;

  select orgid into v_prodorg from public.ws_tblproducts where productid = new.productid;
  perform ws.assert_same_org(v_org, v_prodorg, 'purchase detail vs product');

  if new.unitcost is null or new.unitcost = 0 then
    select purchaseprice into new.unitcost
    from public.ws_tblproducts where productid = new.productid;
  end if;

  new.amount := round(new.quantity * coalesce(new.unitcost, 0), 2);
  return new;
end
$$;

drop trigger if exists trg_purchasedetail_prepare on public.ws_tblpurchasedetails;
create trigger trg_purchasedetail_prepare
  before insert or update on public.ws_tblpurchasedetails
  for each row execute function ws.tg_purchasedetail_prepare();

create or replace function ws.recalc_purchase(p_purchaseid bigint)
returns void
language plpgsql
set search_path = ws, public, pg_catalog
as $$
begin
  perform set_config('ws.internal_recalc', '1', true);

  update public.ws_tblpurchases p
     set totalamount = coalesce((
           select sum(d.amount) from public.ws_tblpurchasedetails d
           where d.purchaseid = p_purchaseid
         ), 0)
   where p.purchaseid = p_purchaseid;

  perform set_config('ws.internal_recalc', '', true);
end
$$;

-- Buying empty bottles increases the stock side, not any customer's balance.
-- Recorded with customerid = NULL so the bottle ledger stays complete.
create or replace function ws.tg_purchasedetail_after()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  r            record;
  v_org        bigint;
  v_date       date;
  v_bottletype bigint;
  v_per        int;
begin
  r := coalesce(new, old);

  select orgid, purchasedate into v_org, v_date
  from public.ws_tblpurchases where purchaseid = r.purchaseid;

  if v_org is null then
    return null;
  end if;

  if tg_op = 'INSERT' then
    select bottletypeid, bottlesperunit into v_bottletype, v_per
    from public.ws_tblproducts where productid = r.productid;

    if v_bottletype is not null and v_per > 0 then
      insert into public.ws_tblbottletransactions
        (orgid, customerid, bottletypeid, txndate, txntype, qty, balancebefore, balanceafter, notes, createdby)
      values
        (v_org, null, v_bottletype, v_date, 'adjustment',
         (new.quantity * v_per)::int, 0, 0, 'Bottles purchased into stock', ws.current_uid());
    end if;
  end if;

  perform ws.recalc_purchase(r.purchaseid);
  perform ws.post_purchase(r.purchaseid);
  return null;
end
$$;

drop trigger if exists trg_purchasedetail_after on public.ws_tblpurchasedetails;
create trigger trg_purchasedetail_after
  after insert or update or delete on public.ws_tblpurchasedetails
  for each row execute function ws.tg_purchasedetail_after();

-- ─── Journal posting: purchase (Inventory DR / AP CR) ────────────────────────

create or replace function ws.post_purchase(p_purchaseid bigint)
returns void
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_org    bigint;
  v_vendor bigint;
  v_date   date;
  v_amount numeric(14,2);
  v_void   boolean;
  v_ref    text;
  v_j      bigint;
begin
  select orgid, vendorid, purchasedate, totalamount, isvoid, coalesce(billno, referenceno)
    into v_org, v_vendor, v_date, v_amount, v_void, v_ref
  from public.ws_tblpurchases where purchaseid = p_purchaseid;

  if v_org is null then
    return;
  end if;

  if v_void or coalesce(v_amount, 0) = 0 then
    delete from public.ws_tbljournalentries
    where orgid = v_org and sourcetype = 'purchase' and sourceid = p_purchaseid;
    return;
  end if;

  v_j := ws.journal_upsert_header(v_org, 'purchase', p_purchaseid, v_date,
                                  'Purchase ' || coalesce(v_ref, p_purchaseid::text));

  perform ws.journal_line(v_j, v_org, ws.account_by_control(v_org, 'inventory'),
                          v_amount, 0, null, v_vendor, 'Inventory purchased');
  perform ws.journal_line(v_j, v_org, ws.account_by_control(v_org, 'ap'),
                          0, v_amount, null, v_vendor, 'Vendor payable');
end
$$;

create or replace function ws.tg_purchase_before()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare v_vorg bigint;
begin
  if tg_op = 'INSERT' then
    select orgid into v_vorg from public.ws_tblvendors where vendorid = new.vendorid;
    perform ws.assert_same_org(new.orgid, v_vorg, 'purchase vs vendor');
    if new.referenceno is null then
      new.referenceno := ws.next_docnumber(new.orgid, 'purchase');
    end if;
    new.createdby := coalesce(new.createdby, ws.current_uid());
    new.totalamount := 0;
  elsif coalesce(current_setting('ws.internal_recalc', true), '') <> '1' then
    new.totalamount := old.totalamount;
  end if;
  return new;
end
$$;

drop trigger if exists trg_purchase_before on public.ws_tblpurchases;
create trigger trg_purchase_before
  before insert or update on public.ws_tblpurchases
  for each row execute function ws.tg_purchase_before();

create or replace function ws.tg_purchase_after()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
begin
  perform ws.post_purchase(new.purchaseid);
  return null;
end
$$;

drop trigger if exists trg_purchase_after on public.ws_tblpurchases;
create trigger trg_purchase_after
  after update of isvoid, purchasedate on public.ws_tblpurchases
  for each row execute function ws.tg_purchase_after();

-- ─── Journal posting: vendor payment (AP DR / Cash CR) ───────────────────────

create or replace function ws.post_vendor_payment(p_vendorpaymentid bigint)
returns void
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare
  v_org    bigint;
  v_vendor bigint;
  v_date   date;
  v_amount numeric(14,2);
  v_void   boolean;
  v_method bigint;
  v_acct   bigint;
  v_ref    text;
  v_j      bigint;
begin
  select orgid, vendorid, paiddate, amountpaid, isvoid, methodid, coalesce(voucherno, referenceno)
    into v_org, v_vendor, v_date, v_amount, v_void, v_method, v_ref
  from public.ws_tblvendorpayments where vendorpaymentid = p_vendorpaymentid;

  if v_org is null then
    return;
  end if;

  if v_void then
    delete from public.ws_tbljournalentries
    where orgid = v_org and sourcetype = 'vendorpayment' and sourceid = p_vendorpaymentid;
    return;
  end if;

  select accountid into v_acct from public.ws_tblpaymentmethods where methodid = v_method;
  v_acct := coalesce(v_acct, ws.account_by_control(v_org, 'cash'));

  v_j := ws.journal_upsert_header(v_org, 'vendorpayment', p_vendorpaymentid, v_date,
                                  'Vendor payment ' || coalesce(v_ref, p_vendorpaymentid::text));

  perform ws.journal_line(v_j, v_org, ws.account_by_control(v_org, 'ap'),
                          v_amount, 0, null, v_vendor, 'Paid to vendor');
  perform ws.journal_line(v_j, v_org, v_acct, 0, v_amount, null, v_vendor, 'Cash paid out');
end
$$;

create or replace function ws.tg_vendorpayment_before()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
declare v_vorg bigint;
begin
  if tg_op = 'INSERT' then
    select orgid into v_vorg from public.ws_tblvendors where vendorid = new.vendorid;
    perform ws.assert_same_org(new.orgid, v_vorg, 'vendor payment vs vendor');
    if new.voucherno is null then
      new.voucherno := ws.next_docnumber(new.orgid, 'vendorpayment');
    end if;
    new.createdby := coalesce(new.createdby, ws.current_uid());
  end if;
  return new;
end
$$;

drop trigger if exists trg_vendorpayment_before on public.ws_tblvendorpayments;
create trigger trg_vendorpayment_before
  before insert or update on public.ws_tblvendorpayments
  for each row execute function ws.tg_vendorpayment_before();

create or replace function ws.tg_vendorpayment_after()
returns trigger
language plpgsql
set search_path = ws, public, pg_catalog
as $$
begin
  perform ws.post_vendor_payment(new.vendorpaymentid);
  return null;
end
$$;

drop trigger if exists trg_vendorpayment_after on public.ws_tblvendorpayments;
create trigger trg_vendorpayment_after
  after insert or update on public.ws_tblvendorpayments
  for each row execute function ws.tg_vendorpayment_after();

-- ─── Vendor opening balance ──────────────────────────────────────────────────

create or replace function public.ws_set_vendor_opening(
  p_vendorid bigint,
  p_opening  numeric default 0,
  p_asof     date default current_date
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org bigint;
  v_j   bigint;
begin
  select orgid into v_org from public.ws_tblvendors where vendorid = p_vendorid;
  if v_org is null then
    raise exception 'vendor % not found', p_vendorid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'vendors.manage') then
    raise exception 'permission denied: vendors.manage' using errcode = '42501';
  end if;

  update public.ws_tblvendors set openingbalance = p_opening where vendorid = p_vendorid;

  if coalesce(p_opening, 0) <> 0 then
    -- Negative sourceid keyspace keeps vendor openings from colliding with the
    -- customer openings that share sourcetype 'opening'.
    v_j := ws.journal_upsert_header(v_org, 'opening', -p_vendorid, p_asof,
             'Opening balance for vendor ' || p_vendorid);
    perform ws.journal_line(v_j, v_org, ws.account_by_code(v_org, '3900'),
                            p_opening, 0, null, p_vendorid, 'Opening balance equity');
    perform ws.journal_line(v_j, v_org, ws.account_by_control(v_org, 'ap'),
                            0, p_opening, null, p_vendorid, 'Opening payable');
  end if;
end
$$;

revoke all on function public.ws_set_vendor_opening(bigint,numeric,date) from public;
grant execute on function public.ws_set_vendor_opening(bigint,numeric,date) to authenticated;


-- #############################################################################
-- ## SECTION 007 — 007_views.sql
-- #############################################################################

-- =============================================================================
-- 007_views.sql
-- Ledgers, balances, the delivery card, trial balance, reconciliation.
--
-- CRITICAL — security_invoker = true ON EVERY VIEW
-- By default a Postgres view executes with the privileges of its OWNER, which
-- means row level security on the underlying tables is BYPASSED. A view over
-- ws_tblcustomers without security_invoker would happily hand every tenant's
-- customer list to any authenticated caller — the exact leak RLS was added to
-- prevent, reintroduced by the reporting layer.
--
-- Requires Postgres 15+. Supabase is 15+. Verify after any restore:
--   select relname from pg_class
--   where relkind = 'v' and relnamespace = 'public'::regnamespace
--     and not coalesce((reloptions::text like '%security_invoker=true%'), false);
--   -- must return zero rows
-- =============================================================================

-- ─── Customer balance (compatibility view for the existing Flutter code) ─────
-- The current client reads `vw_ws_customerbalance` and expects the customer
-- columns plus areaname, rateperbottle and outstandingdue. Preserved verbatim,
-- with per-type bottle data added.

create or replace view public.vw_ws_customerbalance
with (security_invoker = true) as
with money as (
  select
    d.orgid,
    d.customerid,
    coalesce(sum(d.amountcharged), 0) as totalcharged
  from public.ws_tbldeliveries d
  where not d.isvoid
  group by d.orgid, d.customerid
),
paid as (
  select
    p.orgid,
    p.customerid,
    coalesce(sum(p.amountreceived), 0) as totalreceived
  from public.ws_tblpayments p
  where not p.isvoid
  group by p.orgid, p.customerid
)
select
  c.customerid,
  c.orgid,
  c.customercode,
  c.customername,
  c.contactperson,
  c.phone,
  c.email,
  c.address,
  c.areaid,
  c.routeid,
  c.groupid,
  c.authuserid,
  c.creditlimit,
  c.depositamount,
  c.openingbalance,
  c.rateoverride,
  c.bottlebalance,
  c.isactive,
  c.createddate,
  a.areaname,
  a.rateperbottle,
  coalesce(m.totalcharged, 0)                                   as totalcharged,
  coalesce(pd.totalreceived, 0)                                 as totalreceived,
  -- The formula from the spec: opening + sales - payments.
  round(c.openingbalance
        + coalesce(m.totalcharged, 0)
        - coalesce(pd.totalreceived, 0), 2)                     as outstandingdue,
  coalesce((
    select sum(b.balance) from public.ws_tblcustomerbottlebalances b
    where b.customerid = c.customerid
  ), 0)                                                          as bottlesallteypes,
  coalesce((
    select sum(b.balance * bt.depositamount)
    from public.ws_tblcustomerbottlebalances b
    join public.ws_tblbottletypes bt on bt.bottletypeid = b.bottletypeid
    where b.customerid = c.customerid
  ), 0)                                                          as bottledepositvalue
from public.ws_tblcustomers c
left join public.ws_tblareas a on a.areaid = c.areaid
left join money  m  on m.customerid  = c.customerid
left join paid   pd on pd.customerid = c.customerid;

-- ─── Bottle balance per customer per type ────────────────────────────────────

create or replace view public.vw_ws_customerbottlebalance
with (security_invoker = true) as
select
  b.orgid,
  b.customerid,
  c.customername,
  b.bottletypeid,
  t.bottlecode,
  t.bottlename,
  t.isdefault,
  b.balance,
  b.balance * t.depositamount as depositvalue,
  b.updated_at
from public.ws_tblcustomerbottlebalances b
join public.ws_tblcustomers   c on c.customerid   = b.customerid
join public.ws_tblbottletypes t on t.bottletypeid = b.bottletypeid;

-- ─── Bottle ledger (full movement history, per customer per type) ────────────

create or replace view public.vw_ws_bottleledger
with (security_invoker = true) as
select
  bt.bottletxnid,
  bt.orgid,
  bt.customerid,
  c.customername,
  bt.bottletypeid,
  t.bottlecode,
  t.bottlename,
  bt.txndate,
  bt.txntype,
  bt.qty,
  bt.balancebefore,
  bt.balanceafter,
  bt.deliveryid,
  d.referenceno,
  bt.notes
from public.ws_tblbottletransactions bt
left join public.ws_tblcustomers   c on c.customerid   = bt.customerid
join      public.ws_tblbottletypes t on t.bottletypeid = bt.bottletypeid
left join public.ws_tbldeliveries  d on d.deliveryid   = bt.deliveryid;

-- ─── Organization-wide bottle position ───────────────────────────────────────

create or replace view public.vw_ws_bottleposition
with (security_invoker = true) as
select
  t.orgid,
  t.bottletypeid,
  t.bottlecode,
  t.bottlename,
  coalesce(sum(case when bt.customerid is not null then bt.qty else 0 end), 0)::int as withcustomers,
  coalesce(sum(case when bt.customerid is null     then bt.qty else 0 end), 0)::int as purchasedintostock,
  coalesce(sum(case when bt.txntype = 'lost'    then -bt.qty else 0 end), 0)::int   as lost,
  coalesce(sum(case when bt.txntype = 'damaged' then -bt.qty else 0 end), 0)::int   as damaged,
  (coalesce(sum(case when bt.customerid is null then bt.qty else 0 end), 0)
   - coalesce(sum(case when bt.customerid is not null then bt.qty else 0 end), 0))::int as instock
from public.ws_tblbottletypes t
left join public.ws_tblbottletransactions bt on bt.bottletypeid = t.bottletypeid
group by t.orgid, t.bottletypeid, t.bottlecode, t.bottlename;

-- ─── Customer money ledger (debit / credit / running balance) ────────────────

create or replace view public.vw_ws_customerledger
with (security_invoker = true) as
with lines as (
  -- Opening balance as the first line so the running total ties to the card.
  select
    c.orgid,
    c.customerid,
    c.createddate::date            as txndate,
    0::bigint                      as sortkey,
    'Opening Balance'::text        as description,
    null::text                     as referenceno,
    c.openingbalance               as debit,
    0::numeric                     as credit
  from public.ws_tblcustomers c
  where c.openingbalance <> 0

  union all

  select
    d.orgid,
    d.customerid,
    d.deliverydate,
    1::bigint,
    'Delivery: ' || d.bottlesdelivered || ' out / ' || d.bottlesreturned || ' in',
    d.referenceno,
    d.amountcharged,
    0::numeric
  from public.ws_tbldeliveries d
  where not d.isvoid and d.amountcharged <> 0

  union all

  select
    p.orgid,
    p.customerid,
    p.paymentdate,
    2::bigint,
    'Payment (' || coalesce(p.paymentmethod, 'cash') || ')',
    p.receiptno,
    0::numeric,
    p.amountreceived
  from public.ws_tblpayments p
  where not p.isvoid
)
select
  l.orgid,
  l.customerid,
  l.txndate,
  -- Exposed so callers can reproduce the view's own ordering. Without it, two
  -- lines on the same date (a delivery and its payment) have no defined order
  -- and "the closing balance" is ambiguous.
  l.sortkey,
  l.description,
  l.referenceno,
  l.debit,
  l.credit,
  sum(l.debit - l.credit) over (
    partition by l.customerid
    order by l.txndate, l.sortkey
    rows between unbounded preceding and current row
  ) as balance
from lines l;

-- ─── Vendor ledger ───────────────────────────────────────────────────────────

create or replace view public.vw_ws_vendorledger
with (security_invoker = true) as
with lines as (
  select
    v.orgid, v.vendorid, v.createddate::date as txndate, 0::bigint as sortkey,
    'Opening Balance'::text as description, null::text as referenceno,
    0::numeric as debit, v.openingbalance as credit
  from public.ws_tblvendors v
  where v.openingbalance <> 0

  union all

  select
    p.orgid, p.vendorid, p.purchasedate, 1::bigint,
    'Purchase', coalesce(p.billno, p.referenceno),
    0::numeric, p.totalamount
  from public.ws_tblpurchases p
  where not p.isvoid and p.totalamount <> 0

  union all

  select
    vp.orgid, vp.vendorid, vp.paiddate, 2::bigint,
    'Payment', vp.voucherno,
    vp.amountpaid, 0::numeric
  from public.ws_tblvendorpayments vp
  where not vp.isvoid
)
select
  l.orgid,
  l.vendorid,
  l.txndate,
  l.sortkey,
  l.description,
  l.referenceno,
  l.debit,
  l.credit,
  -- Payables are a credit balance: positive = we owe the vendor.
  sum(l.credit - l.debit) over (
    partition by l.vendorid
    order by l.txndate, l.sortkey
    rows between unbounded preceding and current row
  ) as balance
from lines l;

-- ─── THE DELIVERY CARD ───────────────────────────────────────────────────────
-- One row per delivery date per customer, matching the physical card columns:
--   Date | Delivery Bottles | Received Bottles | Bottle Balance
--        | Total Amount | Amount Received
-- Payments not tied to a delivery still appear, so cash collected on a
-- no-delivery visit is not silently dropped from the card.

create or replace view public.vw_ws_deliverycard
with (security_invoker = true) as
with days as (
  select orgid, customerid, deliverydate as cardate from public.ws_tbldeliveries where not isvoid
  union
  select orgid, customerid, paymentdate  as cardate from public.ws_tblpayments   where not isvoid
),
del as (
  select
    orgid, customerid, deliverydate,
    sum(bottlesdelivered)::int as delivered,
    sum(bottlesreturned)::int  as received,
    sum(amountcharged)         as amount,
    max(bottlebalance)         as balance_snapshot,
    min(referenceno)           as referenceno
  from public.ws_tbldeliveries
  where not isvoid
  group by orgid, customerid, deliverydate
),
pay as (
  select orgid, customerid, paymentdate, sum(amountreceived) as received_amount
  from public.ws_tblpayments
  where not isvoid
  group by orgid, customerid, paymentdate
)
select
  dy.orgid,
  dy.customerid,
  c.customername,
  dy.cardate                                         as entrydate,
  coalesce(d.delivered, 0)                           as deliverybottles,
  coalesce(d.received, 0)                            as receivedbottles,
  -- Running bottle balance recomputed from history rather than trusting the
  -- per-row snapshot, so a backdated delivery still produces a correct card.
  coalesce((
    select sum(bt.qty)::int
    from public.ws_tblbottletransactions bt
    join public.ws_tblbottletypes t on t.bottletypeid = bt.bottletypeid and t.isdefault
    where bt.customerid = dy.customerid and bt.txndate <= dy.cardate
  ), 0)                                              as bottlebalance,
  coalesce(d.amount, 0)                              as totalamount,
  coalesce(p.received_amount, 0)                     as amountreceived,
  -- Running money balance as at this date.
  round(c.openingbalance
    + coalesce((select sum(x.amountcharged) from public.ws_tbldeliveries x
                where x.customerid = dy.customerid and not x.isvoid
                  and x.deliverydate <= dy.cardate), 0)
    - coalesce((select sum(y.amountreceived) from public.ws_tblpayments y
                where y.customerid = dy.customerid and not y.isvoid
                  and y.paymentdate <= dy.cardate), 0), 2) as runningbalance,
  d.referenceno
from days dy
join public.ws_tblcustomers c on c.customerid = dy.customerid
left join del d on d.customerid = dy.customerid and d.deliverydate = dy.cardate
left join pay p on p.customerid = dy.customerid and p.paymentdate  = dy.cardate;

-- ─── Today's delivery list (route sheet) ─────────────────────────────────────

create or replace view public.vw_ws_todaydeliveries
with (security_invoker = true) as
select
  d.orgid,
  d.deliveryid,
  d.referenceno,
  d.deliverydate,
  d.customerid,
  c.customername,
  c.phone,
  c.address,
  a.areaname,
  r.routename,
  u.fullname as deliveredby,
  d.bottlesdelivered,
  d.bottlesreturned,
  d.bottlebalance,
  d.rateapplied,
  d.amountcharged,
  coalesce((
    select sum(p.amountreceived) from public.ws_tblpayments p
    where p.deliveryid = d.deliveryid and not p.isvoid
  ), 0) as amountreceived
from public.ws_tbldeliveries d
join      public.ws_tblcustomers      c on c.customerid     = d.customerid
left join public.ws_tblareas          a on a.areaid         = c.areaid
left join public.ws_tblroutes         r on r.routeid        = d.routeid
left join public.ws_tblinternalusers  u on u.internaluserid = d.deliveredbyid
where not d.isvoid;

-- ─── Trial balance ───────────────────────────────────────────────────────────

create or replace view public.vw_ws_trialbalance
with (security_invoker = true) as
select
  a.orgid,
  a.accountid,
  a.accountcode,
  a.accountname,
  a.accounttype,
  a.controlfor,
  coalesce(sum(jd.debit),  0) as totaldebit,
  coalesce(sum(jd.credit), 0) as totalcredit,
  coalesce(sum(jd.debit), 0) - coalesce(sum(jd.credit), 0) as netdebit,
  (coalesce(sum(jd.debit), 0) - coalesce(sum(jd.credit), 0))
    * ws.account_sign(a.accounttype) as balance
from public.ws_tblaccounts a
left join public.ws_tbljournalentrydetails jd on jd.accountid = a.accountid
group by a.orgid, a.accountid, a.accountcode, a.accountname, a.accounttype, a.controlfor;

-- ─── General ledger ──────────────────────────────────────────────────────────

create or replace view public.vw_ws_generalledger
with (security_invoker = true) as
select
  j.orgid,
  j.journalid,
  j.entrydate,
  j.sourcetype,
  j.sourceid,
  j.memo,
  a.accountcode,
  a.accountname,
  a.accounttype,
  jd.customerid,
  jd.vendorid,
  jd.debit,
  jd.credit,
  jd.description
from public.ws_tbljournalentries j
join public.ws_tbljournalentrydetails jd on jd.journalid = j.journalid
join public.ws_tblaccounts a on a.accountid = jd.accountid;

-- ─── RECONCILIATION — the safety net for the journal-derived design ──────────
-- Compares each control account's journal balance against the subsidiary sum.
-- MUST return zero rows. Any row means a posting rule is wrong and the reports
-- and the ledgers now disagree. Put this on the admin dashboard.

create or replace view public.vw_ws_reconciliation
with (security_invoker = true) as
with ar_journal as (
  select jd.orgid, coalesce(sum(jd.debit - jd.credit), 0) as journalbalance
  from public.ws_tbljournalentrydetails jd
  join public.ws_tblaccounts a on a.accountid = jd.accountid and a.controlfor = 'ar'
  group by jd.orgid
),
ar_subsidiary as (
  select orgid, coalesce(sum(outstandingdue), 0) as subsidiarybalance
  from public.vw_ws_customerbalance
  group by orgid
),
ap_journal as (
  select jd.orgid, coalesce(sum(jd.credit - jd.debit), 0) as journalbalance
  from public.ws_tbljournalentrydetails jd
  join public.ws_tblaccounts a on a.accountid = jd.accountid and a.controlfor = 'ap'
  group by jd.orgid
),
ap_subsidiary as (
  select
    v.orgid,
    coalesce(sum(v.openingbalance), 0)
      + coalesce((select sum(p.totalamount) from public.ws_tblpurchases p
                  where p.orgid = v.orgid and not p.isvoid), 0)
      - coalesce((select sum(vp.amountpaid) from public.ws_tblvendorpayments vp
                  where vp.orgid = v.orgid and not vp.isvoid), 0) as subsidiarybalance
  from public.ws_tblvendors v
  group by v.orgid
),
bottle_cache as (
  select orgid, customerid, bottletypeid, balance from public.ws_tblcustomerbottlebalances
),
bottle_truth as (
  select orgid, customerid, bottletypeid, sum(qty)::int as balance
  from public.ws_tblbottletransactions
  where customerid is not null
  group by orgid, customerid, bottletypeid
)
select 'ar'::text as area, j.orgid,
       j.journalbalance, s.subsidiarybalance,
       round(j.journalbalance - s.subsidiarybalance, 2) as difference,
       null::bigint as customerid, null::bigint as bottletypeid
from ar_journal j
join ar_subsidiary s on s.orgid = j.orgid
where round(j.journalbalance - s.subsidiarybalance, 2) <> 0

union all

select 'ap', j.orgid, j.journalbalance, s.subsidiarybalance,
       round(j.journalbalance - s.subsidiarybalance, 2),
       null, null
from ap_journal j
join ap_subsidiary s on s.orgid = j.orgid
where round(j.journalbalance - s.subsidiarybalance, 2) <> 0

union all

select 'bottles', coalesce(c.orgid, t.orgid),
       coalesce(c.balance, 0)::numeric, coalesce(t.balance, 0)::numeric,
       (coalesce(c.balance, 0) - coalesce(t.balance, 0))::numeric,
       coalesce(c.customerid, t.customerid), coalesce(c.bottletypeid, t.bottletypeid)
from bottle_cache c
full outer join bottle_truth t
  on t.customerid = c.customerid and t.bottletypeid = c.bottletypeid
where coalesce(c.balance, 0) <> coalesce(t.balance, 0);

-- Unbalanced journal entries. Also must be empty; the deferred constraint
-- trigger should make this impossible, so a row here means the trigger was
-- disabled or a restore bypassed it.
create or replace view public.vw_ws_unbalancedentries
with (security_invoker = true) as
select
  j.orgid,
  j.journalid,
  j.entrydate,
  j.sourcetype,
  j.sourceid,
  sum(jd.debit)  as totaldebit,
  sum(jd.credit) as totalcredit,
  sum(jd.debit) - sum(jd.credit) as difference
from public.ws_tbljournalentries j
left join public.ws_tbljournalentrydetails jd on jd.journalid = j.journalid
group by j.orgid, j.journalid, j.entrydate, j.sourcetype, j.sourceid
having coalesce(sum(jd.debit), 0) - coalesce(sum(jd.credit), 0) <> 0
    or count(jd.detailid) = 0;

-- ─── Dashboard ───────────────────────────────────────────────────────────────

create or replace view public.vw_ws_dashboard
with (security_invoker = true) as
select
  o.orgid,
  (select coalesce(sum(d.amountcharged), 0) from public.ws_tbldeliveries d
   where d.orgid = o.orgid and not d.isvoid and d.deliverydate = current_date)      as todaysales,
  (select coalesce(sum(p.amountreceived), 0) from public.ws_tblpayments p
   where p.orgid = o.orgid and not p.isvoid and p.paymentdate = current_date)       as todaycollections,
  (select count(*) from public.ws_tbldeliveries d
   where d.orgid = o.orgid and not d.isvoid and d.deliverydate = current_date)      as todaydeliveries,
  (select coalesce(sum(v.outstandingdue), 0) from public.vw_ws_customerbalance v
   where v.orgid = o.orgid)                                                        as receivables,
  (select coalesce(sum(s.subsidiary), 0) from (
      select coalesce(sum(vn.openingbalance), 0)
             + coalesce((select sum(p.totalamount) from public.ws_tblpurchases p
                         where p.orgid = o.orgid and not p.isvoid), 0)
             - coalesce((select sum(vp.amountpaid) from public.ws_tblvendorpayments vp
                         where vp.orgid = o.orgid and not vp.isvoid), 0) as subsidiary
      from public.ws_tblvendors vn where vn.orgid = o.orgid
   ) s)                                                                            as payables,
  (select count(*) from public.ws_tblcustomers c
   where c.orgid = o.orgid and c.isactive)                                         as totalcustomers,
  (select coalesce(sum(b.balance), 0) from public.ws_tblcustomerbottlebalances b
   where b.orgid = o.orgid)                                                        as bottlesout,
  (select coalesce(sum(bp.instock), 0) from public.vw_ws_bottleposition bp
   where bp.orgid = o.orgid)                                                       as bottlesinstock,
  (select count(*) from public.vw_ws_reconciliation r
   where r.orgid = o.orgid)                                                        as reconciliationissues
from public.ws_tblorganization o;

-- ─── Grants: views inherit RLS via security_invoker, so SELECT is safe ────────
grant select on
  public.vw_ws_customerbalance,
  public.vw_ws_customerbottlebalance,
  public.vw_ws_bottleledger,
  public.vw_ws_bottleposition,
  public.vw_ws_customerledger,
  public.vw_ws_vendorledger,
  public.vw_ws_deliverycard,
  public.vw_ws_todaydeliveries,
  public.vw_ws_trialbalance,
  public.vw_ws_generalledger,
  public.vw_ws_reconciliation,
  public.vw_ws_unbalancedentries,
  public.vw_ws_dashboard
to authenticated;


-- #############################################################################
-- ## SECTION 008 — 008_rls_policies.sql
-- #############################################################################

-- =============================================================================
-- 008_rls_policies.sql
-- Row level security. THIS IS THE FILE THAT MAKES THE APPLICATION MULTI-TENANT.
--
-- WHAT WAS ACTUALLY WRONG BEFORE
-- Tenant isolation lived entirely in Dart: WsTenantService held _selectedOrgId
-- in a static field and every query appended .eq('orgid', orgId). The Supabase
-- anon key ships inside the Flutter web bundle, so it is public by definition.
-- Anyone could take that key, call the REST endpoint directly, and read
-- ws_tblcustomers with no orgid filter at all — every tenant's customer list,
-- phone numbers, addresses and outstanding balances. The client-side filter was
-- decoration.
--
-- After this migration the database refuses those reads regardless of what the
-- client sends. The Dart .eq('orgid', ...) calls become a performance hint, not
-- a security control.
--
-- STRUCTURE
--   * SELECT is gated on membership: ws.is_member(orgid).
--   * Writes are gated on a permission code: ws.has_perm(orgid, '...').
--   * Portal (customer) logins are additionally scoped to their own customerid,
--     so one customer of an org cannot read another customer of the same org.
--   * `anon` gets nothing. Reference tables are the only exception.
-- =============================================================================

-- ─── Baseline grants: strip anon, give authenticated table-level DML only ────
-- Table-level GRANT is necessary but not sufficient; RLS still decides rows.

do $$
declare t text;
begin
  for t in
    select tablename from pg_tables
    where schemaname = 'public' and tablename like 'ws\_tbl%'
  loop
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    -- Belt and braces: the table owner would otherwise bypass its own policies,
    -- which silently breaks tests run as the owner and hides policy mistakes.
    execute format('alter table public.%I force row level security', t);
  end loop;
end
$$;

-- Reference data that is intentionally global and read-only.
alter table public.ws_tblpermissions disable row level security;
alter table public.ws_tblplans       disable row level security;
grant select on public.ws_tblpermissions, public.ws_tblplans to authenticated, anon;

-- ─── Helper: does the current caller hold a portal (customer) membership? ────

create or replace function ws.is_portal(p_orgid bigint)
returns boolean
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select coalesce((
    select m.customerid is not null
    from public.ws_tblmemberships m
    where m.authuserid = ws.current_uid()
      and m.orgid = p_orgid
      and m.isactive
    limit 1
  ), false)
$$;

-- =============================================================================
-- Tenancy tables
-- =============================================================================

-- ws_tblorganization: visible to members. Creation goes through
-- ws_create_organization() (SECURITY DEFINER), so there is no INSERT policy —
-- a client cannot conjure an organization it is not a member of.
drop policy if exists org_select on public.ws_tblorganization;
create policy org_select on public.ws_tblorganization
  for select to authenticated
  using (ws.is_member(orgid));

drop policy if exists org_update on public.ws_tblorganization;
create policy org_update on public.ws_tblorganization
  for update to authenticated
  using (ws.has_perm(orgid, 'org.manage'))
  with check (ws.has_perm(orgid, 'org.manage'));

-- ws_tblmemberships: the RLS root. Its policy touches NO other table, which is
-- what keeps ws.member_org_ids() from recursing.
drop policy if exists membership_select_self on public.ws_tblmemberships;
create policy membership_select_self on public.ws_tblmemberships
  for select to authenticated
  using (authuserid = ws.current_uid());

-- Seeing co-workers requires users.view. Evaluated through the SECURITY DEFINER
-- helper, so this second policy also avoids self-reference.
drop policy if exists membership_select_org on public.ws_tblmemberships;
create policy membership_select_org on public.ws_tblmemberships
  for select to authenticated
  using (ws.has_perm(orgid, 'users.view'));

drop policy if exists membership_write on public.ws_tblmemberships;
create policy membership_write on public.ws_tblmemberships
  for all to authenticated
  using (ws.has_perm(orgid, 'users.manage'))
  with check (ws.has_perm(orgid, 'users.manage'));

-- ws_tblroles / ws_tblrolepermissions
drop policy if exists roles_select on public.ws_tblroles;
create policy roles_select on public.ws_tblroles
  for select to authenticated using (ws.is_member(orgid));

drop policy if exists roles_write on public.ws_tblroles;
create policy roles_write on public.ws_tblroles
  for all to authenticated
  using (ws.has_perm(orgid, 'users.manage') and not issystem)
  with check (ws.has_perm(orgid, 'users.manage') and not issystem);

drop policy if exists roleperm_select on public.ws_tblrolepermissions;
create policy roleperm_select on public.ws_tblrolepermissions
  for select to authenticated
  using (exists (
    select 1 from public.ws_tblroles r
    where r.roleid = ws_tblrolepermissions.roleid and ws.is_member(r.orgid)
  ));

drop policy if exists roleperm_write on public.ws_tblrolepermissions;
create policy roleperm_write on public.ws_tblrolepermissions
  for all to authenticated
  using (exists (
    select 1 from public.ws_tblroles r
    where r.roleid = ws_tblrolepermissions.roleid and ws.has_perm(r.orgid, 'users.manage')
  ))
  with check (exists (
    select 1 from public.ws_tblroles r
    where r.roleid = ws_tblrolepermissions.roleid and ws.has_perm(r.orgid, 'users.manage')
  ));

-- ws_tblinternalusers: portal customers must not enumerate staff.
drop policy if exists internalusers_select on public.ws_tblinternalusers;
create policy internalusers_select on public.ws_tblinternalusers
  for select to authenticated
  using (ws.is_member(orgid) and not ws.is_portal(orgid));

drop policy if exists internalusers_write on public.ws_tblinternalusers;
create policy internalusers_write on public.ws_tblinternalusers
  for all to authenticated
  using (ws.has_perm(orgid, 'users.manage'))
  with check (ws.has_perm(orgid, 'users.manage'));

-- Subscriptions
drop policy if exists subs_select on public.ws_tblsubscriptions;
create policy subs_select on public.ws_tblsubscriptions
  for select to authenticated using (ws.has_perm(orgid, 'org.view'));

drop policy if exists subs_write on public.ws_tblsubscriptions;
create policy subs_write on public.ws_tblsubscriptions
  for all to authenticated
  using (ws.has_perm(orgid, 'org.manage'))
  with check (ws.has_perm(orgid, 'org.manage'));

drop policy if exists subpay_select on public.ws_tblsubscriptionpayments;
create policy subpay_select on public.ws_tblsubscriptionpayments
  for select to authenticated using (ws.has_perm(orgid, 'org.view'));

-- =============================================================================
-- Master data
-- =============================================================================

do $$
declare
  spec record;
begin
  for spec in
    select * from (values
      ('ws_tblareas',           'products.view',  'products.manage'),
      ('ws_tblroutes',          'delivery.view',  'delivery.manage'),
      ('ws_tblbottletypes',     'products.view',  'products.manage'),
      ('ws_tblproducts',        'products.view',  'products.manage'),
      ('ws_tblcustomergroups',  'customers.view', 'customers.manage'),
      ('ws_tblproductprices',   'products.view',  'products.manage'),
      ('ws_tblpaymentmethods',  'payments.view',  'org.manage'),
      ('ws_tblvendors',         'vendors.view',   'vendors.manage'),
      ('ws_tblpurchases',       'purchases.view', 'purchases.manage'),
      ('ws_tblpurchasedetails', 'purchases.view', 'purchases.manage'),
      ('ws_tblvendorpayments',  'purchases.view', 'purchases.manage'),
      ('ws_tblaccounts',        'accounting.view','accounting.manage'),
      ('ws_tbldocumentsequences','delivery.view', 'org.manage'),
      -- Legacy snapshot table. Without a policy here, 008's blanket
      -- `enable row level security` would make it silently unreadable.
      ('ws_tblbottleinventory', 'delivery.view',  'delivery.manage')
    ) as v(tbl, readperm, writeperm)
  loop
    execute format('drop policy if exists %1$s_select on public.%1$s', spec.tbl);
    -- Master data is readable by any member holding the read permission.
    -- Portal customers are excluded from vendor and accounting data entirely.
    execute format($p$
      create policy %1$s_select on public.%1$s
        for select to authenticated
        using (ws.is_member(orgid) and ws.has_perm(orgid, %2$L))
    $p$, spec.tbl, spec.readperm);

    execute format('drop policy if exists %1$s_write on public.%1$s', spec.tbl);
    execute format($p$
      create policy %1$s_write on public.%1$s
        for all to authenticated
        using (ws.has_perm(orgid, %2$L))
        with check (ws.has_perm(orgid, %2$L))
    $p$, spec.tbl, spec.writeperm);
  end loop;
end
$$;

-- Products and areas are needed by the portal to render its own history, so
-- grant portal logins a narrow read on the two harmless ones.
drop policy if exists products_portal_select on public.ws_tblproducts;
create policy products_portal_select on public.ws_tblproducts
  for select to authenticated
  using (ws.is_portal(orgid) and ws.is_member(orgid));

drop policy if exists bottletypes_portal_select on public.ws_tblbottletypes;
create policy bottletypes_portal_select on public.ws_tblbottletypes
  for select to authenticated
  using (ws.is_portal(orgid) and ws.is_member(orgid));

-- =============================================================================
-- Customers — staff see all, portal sees only itself
-- =============================================================================

drop policy if exists customers_select on public.ws_tblcustomers;
create policy customers_select on public.ws_tblcustomers
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (
      ws.has_perm(orgid, 'customers.view')
      or customerid = ws.portal_customer_id(orgid)
    )
    and (
      not ws.is_portal(orgid)
      or customerid = ws.portal_customer_id(orgid)
    )
  );

drop policy if exists customers_write on public.ws_tblcustomers;
create policy customers_write on public.ws_tblcustomers
  for all to authenticated
  using (ws.has_perm(orgid, 'customers.manage') and not ws.is_portal(orgid))
  with check (ws.has_perm(orgid, 'customers.manage') and not ws.is_portal(orgid));

drop policy if exists custaddr_select on public.ws_tblcustomeraddresses;
create policy custaddr_select on public.ws_tblcustomeraddresses
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or (not ws.is_portal(orgid) and ws.has_perm(orgid, 'customers.view')))
  );

drop policy if exists custaddr_write on public.ws_tblcustomeraddresses;
create policy custaddr_write on public.ws_tblcustomeraddresses
  for all to authenticated
  using (ws.has_perm(orgid, 'customers.manage') and not ws.is_portal(orgid))
  with check (ws.has_perm(orgid, 'customers.manage') and not ws.is_portal(orgid));

-- =============================================================================
-- Operations — same staff/portal split
-- =============================================================================

drop policy if exists deliveries_select on public.ws_tbldeliveries;
create policy deliveries_select on public.ws_tbldeliveries
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or (not ws.is_portal(orgid) and ws.has_perm(orgid, 'delivery.view')))
  );

drop policy if exists deliveries_write on public.ws_tbldeliveries;
create policy deliveries_write on public.ws_tbldeliveries
  for all to authenticated
  using (ws.has_perm(orgid, 'delivery.manage') and not ws.is_portal(orgid))
  with check (ws.has_perm(orgid, 'delivery.manage') and not ws.is_portal(orgid));

drop policy if exists deliverydetails_select on public.ws_tbldeliverydetails;
create policy deliverydetails_select on public.ws_tbldeliverydetails
  for select to authenticated
  using (exists (
    select 1 from public.ws_tbldeliveries d
    where d.deliveryid = ws_tbldeliverydetails.deliveryid
      and ws.is_member(d.orgid)
      and (d.customerid = ws.portal_customer_id(d.orgid)
           or (not ws.is_portal(d.orgid) and ws.has_perm(d.orgid, 'delivery.view')))
  ));

drop policy if exists deliverydetails_write on public.ws_tbldeliverydetails;
create policy deliverydetails_write on public.ws_tbldeliverydetails
  for all to authenticated
  using (ws.has_perm(orgid, 'delivery.manage') and not ws.is_portal(orgid))
  with check (ws.has_perm(orgid, 'delivery.manage') and not ws.is_portal(orgid));

drop policy if exists payments_select on public.ws_tblpayments;
create policy payments_select on public.ws_tblpayments
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or (not ws.is_portal(orgid) and ws.has_perm(orgid, 'payments.view')))
  );

drop policy if exists payments_write on public.ws_tblpayments;
create policy payments_write on public.ws_tblpayments
  for all to authenticated
  using (ws.has_perm(orgid, 'payments.manage') and not ws.is_portal(orgid))
  with check (ws.has_perm(orgid, 'payments.manage') and not ws.is_portal(orgid));

drop policy if exists bottletxn_select on public.ws_tblbottletransactions;
create policy bottletxn_select on public.ws_tblbottletransactions
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or (not ws.is_portal(orgid) and ws.has_perm(orgid, 'delivery.view')))
  );

-- Inserts happen through triggers and SECURITY DEFINER functions. A direct
-- client insert is allowed only with delivery.manage, for manual adjustments.
drop policy if exists bottletxn_insert on public.ws_tblbottletransactions;
create policy bottletxn_insert on public.ws_tblbottletransactions
  for insert to authenticated
  with check (ws.has_perm(orgid, 'delivery.manage') and not ws.is_portal(orgid));

drop policy if exists bottlebal_select on public.ws_tblcustomerbottlebalances;
create policy bottlebal_select on public.ws_tblcustomerbottlebalances
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or (not ws.is_portal(orgid) and ws.has_perm(orgid, 'customers.view')))
  );

-- The cache is trigger-owned. No client write policy at all: without a
-- permissive policy for INSERT/UPDATE, RLS denies them, while the trigger
-- functions run as SECURITY DEFINER owners and are unaffected.

-- =============================================================================
-- Accounting — never visible to portal logins
-- =============================================================================

drop policy if exists journal_select on public.ws_tbljournalentries;
create policy journal_select on public.ws_tbljournalentries
  for select to authenticated
  using (ws.has_perm(orgid, 'accounting.view') and not ws.is_portal(orgid));

drop policy if exists journal_write on public.ws_tbljournalentries;
create policy journal_write on public.ws_tbljournalentries
  for all to authenticated
  using (ws.has_perm(orgid, 'accounting.manage') and sourcetype = 'manual')
  with check (ws.has_perm(orgid, 'accounting.manage') and sourcetype = 'manual');

drop policy if exists jdetail_select on public.ws_tbljournalentrydetails;
create policy jdetail_select on public.ws_tbljournalentrydetails
  for select to authenticated
  using (ws.has_perm(orgid, 'accounting.view') and not ws.is_portal(orgid));

drop policy if exists jdetail_write on public.ws_tbljournalentrydetails;
create policy jdetail_write on public.ws_tbljournalentrydetails
  for all to authenticated
  using (exists (
    select 1 from public.ws_tbljournalentries j
    where j.journalid = ws_tbljournalentrydetails.journalid
      and j.sourcetype = 'manual'
      and ws.has_perm(j.orgid, 'accounting.manage')
  ))
  with check (exists (
    select 1 from public.ws_tbljournalentries j
    where j.journalid = ws_tbljournalentrydetails.journalid
      and j.sourcetype = 'manual'
      and ws.has_perm(j.orgid, 'accounting.manage')
  ));

-- =============================================================================
-- Trigger functions must run with the privileges needed to maintain caches and
-- post journals even when the calling user has no direct write policy on those
-- tables. FORCE RLS applies to the table owner too, so these are marked
-- SECURITY DEFINER and owned by the migration role.
-- =============================================================================

alter function ws.tg_bottletxn_apply_cache()   security definer;
alter function ws.tg_bottletxn_compute_balance() security definer;
alter function ws.recalc_delivery(bigint)      security definer;
alter function ws.recalc_purchase(bigint)      security definer;
alter function ws.post_delivery(bigint)        security definer;
alter function ws.post_customer_payment(bigint) security definer;
alter function ws.post_purchase(bigint)        security definer;
alter function ws.post_vendor_payment(bigint)  security definer;
alter function ws.journal_upsert_header(bigint,text,bigint,date,text) security definer;
alter function ws.journal_line(bigint,bigint,bigint,numeric,numeric,bigint,bigint,text) security definer;
alter function ws.next_docnumber(bigint,text)  security definer;
alter function ws.tg_deliverydetail_after()    security definer;
alter function ws.tg_deliverydetail_prepare()  security definer;
alter function ws.tg_delivery_after()          security definer;
alter function ws.tg_purchasedetail_after()    security definer;
alter function ws.tg_purchase_after()          security definer;
alter function ws.tg_vendorpayment_after()     security definer;
alter function ws.tg_payment_after()           security definer;

-- =============================================================================
-- Audit log
-- =============================================================================

create table if not exists public.ws_tblauditlogs (
  auditid     bigint generated by default as identity primary key,
  orgid       bigint references public.ws_tblorganization(orgid) on delete cascade,
  authuserid  uuid,
  tablename   text not null,
  recordid    text,
  action      text not null check (action in ('insert','update','delete')),
  changes     jsonb,
  occurred_at timestamptz not null default now()
);

create index if not exists ix_audit_org_time on public.ws_tblauditlogs(orgid, occurred_at desc);

alter table public.ws_tblauditlogs enable row level security;
alter table public.ws_tblauditlogs force row level security;
revoke all on public.ws_tblauditlogs from anon;
grant select on public.ws_tblauditlogs to authenticated;

drop policy if exists audit_select on public.ws_tblauditlogs;
create policy audit_select on public.ws_tblauditlogs
  for select to authenticated
  using (ws.has_perm(orgid, 'org.manage'));

create or replace function ws.tg_audit()
returns trigger
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org bigint;
  v_id  text;
begin
  v_org := case tg_op when 'DELETE' then (to_jsonb(old)->>'orgid')::bigint
                      else (to_jsonb(new)->>'orgid')::bigint end;
  v_id  := case tg_op when 'DELETE' then to_jsonb(old)->>(tg_argv[0])
                      else to_jsonb(new)->>(tg_argv[0]) end;

  insert into public.ws_tblauditlogs (orgid, authuserid, tablename, recordid, action, changes)
  values (
    v_org, ws.current_uid(), tg_table_name, v_id, lower(tg_op),
    case tg_op
      when 'INSERT' then jsonb_build_object('new', to_jsonb(new))
      when 'DELETE' then jsonb_build_object('old', to_jsonb(old))
      else jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new))
    end
  );
  return null;
end
$$;

-- Audit the tables where a silent change is expensive: money and pricing.
do $$
declare
  spec record;
begin
  for spec in
    select * from (values
      ('ws_tblcustomers',      'customerid'),
      ('ws_tblpayments',       'paymentid'),
      ('ws_tbldeliveries',     'deliveryid'),
      ('ws_tblproductprices',  'priceid'),
      ('ws_tblvendorpayments', 'vendorpaymentid'),
      ('ws_tblmemberships',    'membershipid')
    ) as v(tbl, pk)
  loop
    execute format('drop trigger if exists trg_audit_%1$s on public.%1$s', spec.tbl);
    execute format(
      'create trigger trg_audit_%1$s after insert or update or delete on public.%1$s
       for each row execute function ws.tg_audit(%2$L)', spec.tbl, spec.pk);
  end loop;
end
$$;


-- =============================================================================
-- ## SECTION 009 — 009_opening_balances.sql
-- =============================================================================

-- =============================================================================
-- 009_opening_balances.sql
-- Opening balances: customers, vendors, and stock on hand.
--
-- WHY THIS IS NOT A SET OF "BALANCE" COLUMNS
--
-- Nothing in this schema stores a balance. Customer money comes from
-- vw_ws_customerledger, which sums journal lines; bottle positions come from
-- vw_ws_bottleposition, which sums the append-only bottle ledger. Adding an
-- "opening balance" FIELD that reports then add on top would create a second
-- source of truth, and vw_ws_reconciliation — which must always return zero
-- rows — would immediately start returning rows.
--
-- So an opening balance is posted as what it actually is: a dated journal
-- entry against Opening Balance Equity (3900), and a dated 'opening' row in
-- the bottle ledger. Both were anticipated by the original design —
-- sourcetype 'opening' and txntype 'opening' are already in the CHECK
-- constraints — and after posting, the derived views simply show the right
-- numbers with no special cases anywhere.
--
-- WHAT THIS MIGRATION CHANGES
--
--   1. ws_set_customer_opening() is made idempotent. It was not: the journal
--      side upserts on (orgid, sourcetype, sourceid), but the BOTTLE side ran
--      a bare INSERT, so calling it twice with 5 bottles left the customer
--      holding 10. Since the bottle ledger is append-only and must stay that
--      way, the fix is to post the DIFFERENCE between the intended opening and
--      whatever has already been posted as opening. Re-running with the same
--      number is then a no-op, and correcting 5 to 3 posts -2.
--
--   2. ws_set_opening_stock() is added. There was no way to record stock on
--      hand at go-live at all, which is why the dashboard reads -3 filled
--      bottles: three were delivered out of a stock that was never recorded
--      as existing. Same delta rule, same reason.
--
--   3. sourcetype gains 'openingstock'. Customer openings key their journal on
--      +customerid and vendor openings on -vendorid; stock has neither, so it
--      needs its own sourcetype rather than a third slice of an integer
--      keyspace that is already doing two jobs.
--
-- Safe to re-run.
-- =============================================================================

-- ─── 1. sourcetype: allow 'openingstock' ─────────────────────────────────────

do $mig$
begin
  alter table public.ws_tbljournalentries
    drop constraint if exists ws_tbljournalentries_sourcetype_check;

  alter table public.ws_tbljournalentries
    add constraint ws_tbljournalentries_sourcetype_check
    check (sourcetype in ('manual','sale','customerpayment','purchase',
                          'vendorpayment','bottleadjustment','opening',
                          'openingstock'));
end
$mig$;

-- ─── 2. How many bottles have already been posted as 'opening'? ──────────────
-- One helper, used by both functions below, so the delta rule cannot drift
-- between them.

create or replace function ws.opening_bottles_posted(
  p_orgid        bigint,
  p_bottletypeid bigint,
  p_customerid   bigint   -- null = the organization's own stock
)
returns int
language sql
stable
set search_path = ws, public, pg_catalog
as $$
  select coalesce(sum(qty), 0)::int
  from public.ws_tblbottletransactions
  where orgid = p_orgid
    and bottletypeid = p_bottletypeid
    and txntype = 'opening'
    and (
      (p_customerid is null and customerid is null) or
      (p_customerid is not null and customerid = p_customerid)
    );
$$;

-- ─── 3. Customer opening balance, now idempotent ─────────────────────────────

create or replace function public.ws_set_customer_opening(
  p_customerid   bigint,
  p_openingdue   numeric default 0,
  p_bottletypeid bigint  default null,
  p_openingqty   int     default 0,
  p_asof         date    default current_date
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org     bigint;
  v_bt      bigint;
  v_j       bigint;
  v_posted  int;
  v_delta   int;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'customers.manage') then
    raise exception 'permission denied: customers.manage' using errcode = '42501';
  end if;

  update public.ws_tblcustomers set openingbalance = p_openingdue
  where customerid = p_customerid;

  -- Money. journal_upsert_header deletes and rewrites this entry's lines, so
  -- this half was always safe to re-run.
  if coalesce(p_openingdue, 0) <> 0 then
    v_j := ws.journal_upsert_header(v_org, 'opening', p_customerid, p_asof,
             'Opening balance for customer ' || p_customerid);
    perform ws.journal_line(v_j, v_org, ws.account_by_control(v_org, 'ar'),
                            p_openingdue, 0, p_customerid, null, 'Opening receivable');
    perform ws.journal_line(v_j, v_org, ws.account_by_code(v_org, '3900'),
                            0, p_openingdue, p_customerid, null, 'Opening balance equity');
  else
    -- Clearing the figure has to clear the entry too, or the ledger keeps a
    -- balance the customer record says is zero.
    delete from public.ws_tbljournalentrydetails
    where journalid in (
      select journalid from public.ws_tbljournalentries
      where orgid = v_org and sourcetype = 'opening' and sourceid = p_customerid
    );
    delete from public.ws_tbljournalentries
    where orgid = v_org and sourcetype = 'opening' and sourceid = p_customerid;
  end if;

  -- Bottles. THIS is the half that was not idempotent.
  v_bt := coalesce(p_bottletypeid,
                   (select bottletypeid from public.ws_tblbottletypes
                    where orgid = v_org and isdefault));

  if v_bt is not null then
    v_posted := ws.opening_bottles_posted(v_org, v_bt, p_customerid);
    v_delta  := coalesce(p_openingqty, 0) - v_posted;

    if v_delta <> 0 then
      insert into public.ws_tblbottletransactions
        (orgid, customerid, bottletypeid, txndate, txntype, qty,
         balancebefore, balanceafter, notes, createdby)
      values
        (v_org, p_customerid, v_bt, p_asof, 'opening', v_delta, 0, 0,
         case when v_posted = 0
              then 'Opening bottle balance'
              else format('Opening bottle balance corrected from %s to %s',
                          v_posted, coalesce(p_openingqty, 0))
         end,
         ws.current_uid());
      -- balancebefore/balanceafter are placeholders: ws.tg_bottletxn_compute_balance
      -- overwrites them BEFORE INSERT, under an advisory lock.
    end if;
  end if;
end
$$;

revoke all on function public.ws_set_customer_opening(bigint,numeric,bigint,int,date) from public;
grant execute on function public.ws_set_customer_opening(bigint,numeric,bigint,int,date) to authenticated;

-- ─── 4. Opening stock on hand ────────────────────────────────────────────────
-- Bottles the business owns and has NOT given to a customer. customerid is
-- null, which is what vw_ws_bottleposition counts as "in stock".
--
-- p_unitcost is optional. Supply it and the value is capitalised into
-- Inventory (1200) against Opening Balance Equity (3900); leave it at zero and
-- only the bottle ledger moves. Quantity is tracked either way — the money is
-- a separate question from the count, and plenty of small operations do not
-- know what their existing stock cost.

create or replace function public.ws_set_opening_stock(
  p_bottletypeid bigint,
  p_qty          int     default 0,
  p_unitcost     numeric default 0,
  p_asof         date    default current_date
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org    bigint;
  v_j      bigint;
  v_posted int;
  v_delta  int;
  v_value  numeric;
begin
  select orgid into v_org from public.ws_tblbottletypes where bottletypeid = p_bottletypeid;
  if v_org is null then
    raise exception 'bottle type % not found', p_bottletypeid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'products.manage') then
    raise exception 'permission denied: products.manage' using errcode = '42501';
  end if;
  if coalesce(p_qty, 0) < 0 then
    raise exception 'opening stock cannot be negative (got %)', p_qty
      using errcode = '22023';
  end if;

  v_posted := ws.opening_bottles_posted(v_org, p_bottletypeid, null);
  v_delta  := coalesce(p_qty, 0) - v_posted;

  if v_delta <> 0 then
    insert into public.ws_tblbottletransactions
      (orgid, customerid, bottletypeid, txndate, txntype, qty,
       balancebefore, balanceafter, notes, createdby)
    values
      (v_org, null, p_bottletypeid, p_asof, 'opening', v_delta, 0, 0,
       case when v_posted = 0
            then 'Opening stock on hand'
            else format('Opening stock corrected from %s to %s', v_posted, p_qty)
       end,
       ws.current_uid());
  end if;

  -- Value it, if a cost was given. Upserts on (orgid, 'openingstock',
  -- bottletypeid), so re-running replaces the valuation rather than stacking.
  v_value := coalesce(p_qty, 0) * coalesce(p_unitcost, 0);

  if v_value <> 0 then
    v_j := ws.journal_upsert_header(v_org, 'openingstock', p_bottletypeid, p_asof,
             'Opening stock value for bottle type ' || p_bottletypeid);
    perform ws.journal_line(v_j, v_org, ws.account_by_control(v_org, 'inventory'),
                            v_value, 0, null, null, 'Opening stock on hand');
    perform ws.journal_line(v_j, v_org, ws.account_by_code(v_org, '3900'),
                            0, v_value, null, null, 'Opening balance equity');
  else
    delete from public.ws_tbljournalentrydetails
    where journalid in (
      select journalid from public.ws_tbljournalentries
      where orgid = v_org and sourcetype = 'openingstock' and sourceid = p_bottletypeid
    );
    delete from public.ws_tbljournalentries
    where orgid = v_org and sourcetype = 'openingstock' and sourceid = p_bottletypeid;
  end if;
end
$$;

revoke all on function public.ws_set_opening_stock(bigint,int,numeric,date) from public;
grant execute on function public.ws_set_opening_stock(bigint,int,numeric,date) to authenticated;

-- ─── 5. What has been entered so far ─────────────────────────────────────────
-- The setup screen needs to show current values, otherwise the user cannot
-- tell an unset opening from one that is genuinely zero — and would re-enter
-- figures that are already posted.

create or replace view public.vw_ws_openingstock
with (security_invoker = true) as
select
  t.orgid,
  t.bottletypeid,
  t.bottlecode,
  t.bottlename,
  coalesce(sum(bt.qty) filter (where bt.txntype = 'opening'
                                 and bt.customerid is null), 0)::int as openingqty,
  min(bt.txndate) filter (where bt.txntype = 'opening'
                            and bt.customerid is null)               as openingdate
from public.ws_tblbottletypes t
left join public.ws_tblbottletransactions bt
       on bt.bottletypeid = t.bottletypeid
group by t.orgid, t.bottletypeid, t.bottlecode, t.bottlename;

grant select on public.vw_ws_openingstock to authenticated;

-- =============================================================================
-- Verification (read-only, safe to run):
--
--   select * from public.vw_ws_openingstock;
--   select * from public.vw_ws_bottleposition;
--   select count(*) from public.vw_ws_reconciliation;   -- must be 0
--
-- Re-run safety:
--
--   select public.ws_set_opening_stock(1, 50, 0, '2026-01-01');
--   select public.ws_set_opening_stock(1, 50, 0, '2026-01-01');
--   -- openingqty is 50, not 100.
-- =============================================================================


-- =============================================================================
-- ## SECTION 010 — 010_idempotent_posting.sql
-- =============================================================================

-- =============================================================================
-- 010_idempotent_posting.sql
-- Makes posting a document SAFE TO RETRY. This is the foundation the offline
-- queue stands on; nothing else in the offline work is safe without it.
--
-- ─── THE PROBLEM RETRY CREATES ───────────────────────────────────────────────
--
-- A queued delivery is posted over a bad connection. The request reaches
-- Postgres, the transaction commits, and the response is lost on the way back.
-- The client sees a timeout, marks the item Failed, and retries.
--
-- Without this migration that retry inserts a SECOND delivery: a second set of
-- bottle movements, a second journal entry, a second charge on the customer's
-- ledger. Worse, it is invisible — both rows look legitimate, and the only
-- evidence is a customer who was billed twice.
--
-- No amount of client-side care fixes this. The client cannot know whether a
-- request it never got an answer to was applied. A flag written before the
-- call over-reports failures; a flag written after loses the record if the
-- process dies mid-flight. The guarantee has to be enforced where the write
-- lands.
--
-- ─── THE FIX ─────────────────────────────────────────────────────────────────
--
-- The CLIENT generates a UUID for the document at the moment the user saves it
-- — offline, on the device, before any network exists. That UUID travels with
-- every retry of that same document.
--
-- Postgres holds a UNIQUE constraint on (orgid, clientuuid). The posting
-- function looks the UUID up first: if a document already carries it, the
-- function returns the EXISTING id and writes nothing. Retry as many times as
-- you like; the second call is a read.
--
-- This is idempotency by key, and it is the same thing Stripe's
-- Idempotency-Key header does, for the same reason.
--
-- ─── WHAT THIS MIGRATION DOES NOT DO ─────────────────────────────────────────
--
-- It does not add offline storage, a queue, or any client behaviour. It is
-- deliberately useful on its own: even the current online-only app stops being
-- able to double-post when a user taps Save twice on a slow connection.
--
-- Safe to re-run.
-- =============================================================================

-- ─── 1. The idempotency key ──────────────────────────────────────────────────

alter table public.ws_tbldeliveries
  add column if not exists clientuuid uuid;

alter table public.ws_tblpayments
  add column if not exists clientuuid uuid;

comment on column public.ws_tbldeliveries.clientuuid is
  'Client-generated idempotency key. Set by the device when the document is '
  'created (possibly offline). Retries carry the same value so a re-post is a '
  'no-op rather than a duplicate.';

comment on column public.ws_tblpayments.clientuuid is
  'Client-generated idempotency key. See ws_tbldeliveries.clientuuid.';

-- PARTIAL unique indexes: null clientuuid means "posted directly, not from a
-- queue", and there may be any number of those. Only non-null keys are
-- constrained, so this cannot break existing rows.
create unique index if not exists ux_delivery_clientuuid
  on public.ws_tbldeliveries(orgid, clientuuid)
  where clientuuid is not null;

create unique index if not exists ux_payment_clientuuid
  on public.ws_tblpayments(orgid, clientuuid)
  where clientuuid is not null;

-- ─── 2. Idempotent delivery posting ──────────────────────────────────────────
--
-- NOTE ON THE SIGNATURE: p_clientuuid is added as a trailing parameter WITH A
-- DEFAULT, so every existing caller — the current delivery screen included —
-- keeps working untouched and simply posts without a key.

create or replace function public.ws_record_delivery(
  p_customerid    bigint,
  p_deliverydate  date    default current_date,
  p_delivered     int     default 0,
  p_returned      int     default 0,
  p_productid     bigint  default null,
  p_amountpaid    numeric default 0,
  p_paymentmethod text    default 'cash',
  p_deliveredbyid bigint  default null,
  p_routeid       bigint  default null,
  p_notes         text    default null,
  p_clientuuid    uuid    default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org        bigint;
  v_product    bigint;
  v_deliveryid bigint;
  v_methodid   bigint;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'delivery.manage') then
    raise exception 'permission denied: delivery.manage' using errcode = '42501';
  end if;

  -- ── THE IDEMPOTENCY CHECK ──────────────────────────────────────────────
  -- Before anything is written. A retry of a call that already succeeded
  -- returns the original id and touches nothing.
  if p_clientuuid is not null then
    select deliveryid into v_deliveryid
    from public.ws_tbldeliveries
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_deliveryid is not null then
      return v_deliveryid;
    end if;
  end if;

  -- Default product = the org's returnable water product on the default
  -- bottle type.
  v_product := p_productid;
  if v_product is null then
    select p.productid into v_product
    from public.ws_tblproducts p
    join public.ws_tblbottletypes b on b.bottletypeid = p.bottletypeid
    where p.orgid = v_org and p.isactive and b.isdefault
    order by p.productid
    limit 1;
  end if;

  if v_product is null then
    raise exception 'org % has no returnable product configured on its default bottle type', v_org
      using errcode = 'P0002';
  end if;

  insert into public.ws_tbldeliveries
    (orgid, customerid, routeid, deliveredbyid, deliverydate, notes, clientuuid)
  values
    (v_org, p_customerid, p_routeid, p_deliveredbyid, p_deliverydate, p_notes,
     p_clientuuid)
  returning deliveryid into v_deliveryid;

  insert into public.ws_tbldeliverydetails
    (deliveryid, orgid, productid, deliveredqty, returnedqty)
  values
    (v_deliveryid, v_org, v_product, p_delivered, p_returned);

  if coalesce(p_amountpaid, 0) > 0 then
    select methodid into v_methodid
    from public.ws_tblpaymentmethods
    where orgid = v_org and methodcode = coalesce(p_paymentmethod, 'cash');

    insert into public.ws_tblpayments
      (orgid, customerid, deliveryid, receivedbyid, methodid, paymentdate,
       amountreceived, paymentmethod, clientuuid)
    values
      (v_org, p_customerid, v_deliveryid, p_deliveredbyid, v_methodid, p_deliverydate,
       p_amountpaid, coalesce(p_paymentmethod, 'cash'),
       -- The payment inside a delivery is part of the SAME document, so it
       -- shares the delivery's key rather than needing one of its own. The
       -- unique index is per table, so there is no collision with a standalone
       -- payment that happens to be posted with the same key.
       p_clientuuid);
  end if;

  return v_deliveryid;
end
$$;

revoke all on function public.ws_record_delivery(bigint,date,int,int,bigint,numeric,text,bigint,bigint,text,uuid) from public;
grant execute on function public.ws_record_delivery(bigint,date,int,int,bigint,numeric,text,bigint,bigint,text,uuid) to authenticated;

-- The previous 10-argument signature still exists as a separate function until
-- Postgres is told otherwise, and an overloaded pair is how "function is not
-- unique" errors start. Drop the old one now that the new one covers it.
drop function if exists public.ws_record_delivery(bigint,date,int,int,bigint,numeric,text,bigint,bigint,text);

-- ─── 3. Idempotent standalone payment ────────────────────────────────────────
-- Payments not attached to a delivery are inserted directly by the app, so
-- they need a posting function of their own to get the same guarantee.

create or replace function public.ws_record_payment(
  p_customerid    bigint,
  p_amount        numeric,
  p_paymentdate   date    default current_date,
  p_paymentmethod text    default 'cash',
  p_referenceno   text    default null,
  p_notes         text    default null,
  p_clientuuid    uuid    default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org       bigint;
  v_paymentid bigint;
  v_methodid  bigint;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'payments.manage') then
    raise exception 'permission denied: payments.manage' using errcode = '42501';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'payment amount must be greater than zero' using errcode = '22023';
  end if;

  if p_clientuuid is not null then
    select paymentid into v_paymentid
    from public.ws_tblpayments
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_paymentid is not null then
      return v_paymentid;
    end if;
  end if;

  select methodid into v_methodid
  from public.ws_tblpaymentmethods
  where orgid = v_org and methodcode = coalesce(p_paymentmethod, 'cash');

  insert into public.ws_tblpayments
    (orgid, customerid, methodid, paymentdate, amountreceived, paymentmethod,
     referenceno, notes, clientuuid)
  values
    (v_org, p_customerid, v_methodid, p_paymentdate, p_amount,
     coalesce(p_paymentmethod, 'cash'), p_referenceno, p_notes, p_clientuuid)
  returning paymentid into v_paymentid;

  return v_paymentid;
end
$$;

revoke all on function public.ws_record_payment(bigint,numeric,date,text,text,text,uuid) from public;
grant execute on function public.ws_record_payment(bigint,numeric,date,text,text,text,uuid) to authenticated;

-- ─── 4. Look up what a key posted to ─────────────────────────────────────────
--
-- For DIAGNOSING a failed sync without risking a re-post. When an item is
-- stuck in Failed, this answers the only question that matters — did it
-- actually land? — with a read rather than another write.

create or replace function public.ws_lookup_clientuuid(p_clientuuid uuid)
returns table (doctype text, docid bigint, docnumber text, docdate date)
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select 'delivery'::text, d.deliveryid, d.referenceno, d.deliverydate
  from public.ws_tbldeliveries d
  where d.clientuuid = p_clientuuid
    and ws.is_member(d.orgid)
  union all
  select 'payment'::text, p.paymentid, p.receiptno, p.paymentdate
  from public.ws_tblpayments p
  where p.clientuuid = p_clientuuid
    and ws.is_member(p.orgid);
$$;

revoke all on function public.ws_lookup_clientuuid(uuid) from public;
grant execute on function public.ws_lookup_clientuuid(uuid) to authenticated;

-- =============================================================================
-- VERIFICATION — run these; the second call must NOT create a second delivery.
--
--   select public.ws_record_delivery(
--     p_customerid   => 1,
--     p_delivered    => 5,
--     p_returned     => 3,
--     p_amountpaid   => 450,
--     p_clientuuid   => '11111111-1111-1111-1111-111111111111'
--   );
--   -- run the EXACT same statement again: same id returned.
--
--   select count(*) from public.ws_tbldeliveries
--   where clientuuid = '11111111-1111-1111-1111-111111111111';
--   -- must be 1
--
--   select * from public.ws_lookup_clientuuid(
--     '11111111-1111-1111-1111-111111111111');
--
--   select count(*) from public.vw_ws_reconciliation;   -- must still be 0
-- =============================================================================


-- =============================================================================
-- ## SECTION 011 — 011_provision_seeds_accounts.sql
-- =============================================================================

-- =============================================================================
-- 011_provision_seeds_accounts.sql
-- Makes creating an organization ACTUALLY complete.
--
-- ─── THE BUG ─────────────────────────────────────────────────────────────────
--
-- ws.provision_organization() creates the organization, its roles, the owner's
-- membership, the internal user row and a trial subscription — and does NOT
-- seed the chart of accounts. That is done by a SEPARATE RPC which the Flutter
-- app calls immediately afterwards (auth_service.dart calls
-- 'ws_seed_chart_of_accounts' as a second round trip).
--
-- So provisioning is two network calls with no transaction around them. If the
-- second one does not happen — connection dropped, app killed, the user closes
-- the screen, or the email-confirmation flow means the first call ran in a
-- different session — the organization exists and looks fine, and then:
--
--     ERROR: no ar control account configured for org N
--
-- on the FIRST DELIVERY the user ever tries to record. Customers can be added,
-- products can be added, and then the core function of the app fails with a
-- message about accounting that means nothing to the person reading it.
--
-- This is the same shape as the earlier bug where an organization could be
-- created with no members: a multi-step provision that is not atomic, where a
-- failure between the steps leaves a half-built tenant.
--
-- Found by running the migrations on a clean Postgres and calling
-- ws_create_organization() the way the database exposes it, rather than the
-- way the Dart client happens to call it.
--
-- ─── THE FIX ─────────────────────────────────────────────────────────────────
--
-- provision_organization() seeds the chart of accounts itself, inside the same
-- transaction as everything else it creates. Either the whole tenant exists or
-- none of it does.
--
-- The app's second RPC is left in place and becomes a harmless no-op:
-- seed_chart_of_accounts() inserts ON CONFLICT DO NOTHING, so calling it again
-- changes nothing. No Dart change is required for this migration to take
-- effect, and no existing organization is affected.
--
-- Safe to re-run. Also repairs any organization already in this broken state.
-- =============================================================================

-- ─── 1. Fold the seed into provisioning ──────────────────────────────────────

do $mig$
declare
  v_src text;
begin
  select prosrc into v_src
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'ws' and p.proname = 'provision_organization';

  if v_src is null then
    raise exception 'ws.provision_organization not found — run install.sql first';
  end if;

  if v_src like '%seed_chart_of_accounts%' then
    raise notice '011: provision_organization already seeds the chart of accounts.';
  else
    raise notice '011: provision_organization does NOT seed the chart of accounts — patching.';
  end if;
end
$mig$;

-- Rewritten with the seed included. The body is otherwise unchanged from 002:
-- organization, roles, membership, internal user, subscription — then accounts.
create or replace function ws.provision_organization(
  p_uid       uuid,
  p_orgname   text,
  p_ownername text default '',
  p_phone     text default '',
  p_address   text default '',
  p_currency  text default 'PKR'
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_orgid  bigint;
  v_roleid bigint;
  v_msid   bigint;
begin
  if p_uid is null then
    raise exception 'provision_organization: no user' using errcode = '42501';
  end if;

  insert into public.ws_tblorganization
    (orgname, businessname, owneruserid, ownername, phone, address, currency)
  values
    (p_orgname, p_orgname, p_uid, p_ownername, p_phone, p_address, p_currency)
  returning orgid into v_orgid;

  perform ws.ensure_org_roles(v_orgid);

  select roleid into v_roleid
  from public.ws_tblroles
  where orgid = v_orgid and rolecode = 'owner';

  insert into public.ws_tblmemberships (orgid, authuserid, roleid)
  values (v_orgid, p_uid, v_roleid)
  returning membershipid into v_msid;

  insert into public.ws_tblinternalusers
    (orgid, authuserid, fullname, role, phone, membershipid)
  values
    (v_orgid, p_uid, coalesce(nullif(p_ownername, ''), 'Owner'), 'owner',
     nullif(p_phone, ''), v_msid);

  insert into public.ws_tblsubscriptions
    (orgid, plancode, status, trialstartdate, trialenddate, periodstart, periodend)
  values
    (v_orgid, 'free', 'trialing', current_date, current_date + 30,
     current_date, current_date + 30);

  -- ── THE MISSING STEP ──────────────────────────────────────────────────
  -- Without this the organization cannot record a delivery, because
  -- ws.post_delivery() resolves the 'ar' control account and finds nothing.
  -- Inside the same transaction, so a failure here rolls the tenant back
  -- rather than leaving one that half works.
  perform ws.seed_chart_of_accounts(v_orgid);

  return v_orgid;
end
$$;

-- ─── 2. Repair organizations already created without accounts ────────────────

do $mig$
declare
  r record;
  v_fixed int := 0;
begin
  for r in
    select o.orgid, o.orgname
    from public.ws_tblorganization o
    where not exists (
      select 1 from public.ws_tblaccounts a
      where a.orgid = o.orgid and a.controlfor = 'ar'
    )
  loop
    perform ws.seed_chart_of_accounts(r.orgid);
    v_fixed := v_fixed + 1;
    raise notice '011: seeded chart of accounts for org % (%)', r.orgid, r.orgname;
  end loop;

  if v_fixed = 0 then
    raise notice '011: every organization already has a chart of accounts.';
  else
    raise notice '011: repaired % organization(s).', v_fixed;
  end if;
end
$mig$;

-- =============================================================================
-- VERIFICATION
--
--   -- Every org must have an AR control account:
--   select o.orgid, o.orgname,
--          (select count(*) from public.ws_tblaccounts a
--           where a.orgid = o.orgid and a.controlfor = 'ar') as ar_accounts
--   from public.ws_tblorganization o;
--   -- ar_accounts must be 1 for every row.
--
--   -- And a NEW organization must be able to record a delivery with no
--   -- follow-up call:
--   select public.ws_create_organization('Test Co','Owner','0300','Karachi');
-- =============================================================================


-- =============================================================================
-- ## SECTION 012 — 012_atomic_idempotent_purchase.sql
-- =============================================================================

-- =============================================================================
-- 012_atomic_idempotent_purchase.sql
-- Makes recording a purchase ATOMIC and SAFE TO RETRY.
--
-- ─── TWO DEFECTS, ONE FIX ────────────────────────────────────────────────────
--
-- The Flutter client currently records a purchase as two separate round trips:
--
--     1. INSERT ws_tblpurchases      (the header)
--     2. INSERT ws_tblpurchasedetails (one line)
--
-- 1. NOT ATOMIC. Every consequence of a purchase — the line amount, the header
--    total, the journal entry, the bottles into stock — is produced by triggers
--    on the DETAIL row, not the header. So if step 2 never happens the database
--    is left holding a purchase with:
--
--       totalamount = 0        no journal entry        no stock movement
--
--    and nothing anywhere says so. The vendor ledger under-states what is owed
--    and inventory under-counts, silently. That is worse than an error: an
--    error gets noticed.
--
-- 2. NOT IDEMPOTENT. If step 1 commits and the response is lost, the retry
--    creates a SECOND purchase — the same failure migrations 010 and 011 fixed
--    for deliveries and payments.
--
-- ─── THE FIX ─────────────────────────────────────────────────────────────────
--
-- One function, therefore one transaction. It checks the idempotency key
-- BEFORE writing, inserts the header, then inserts every line. The existing
-- AFTER trigger fires per line inside that same transaction, so recalc, the
-- journal entry and the stock movement either all land or none do.
--
-- A header with no lines becomes unrepresentable: the function raises on an
-- empty p_lines before it writes anything.
--
-- ─── WHAT IS DELIBERATELY NOT CHANGED ────────────────────────────────────────
--
--   · ws.post_purchase              — journal logic untouched
--   · ws.recalc_purchase            — header total untouched
--   · ws.tg_purchasedetail_prepare  — unitcost default and line amount untouched
--   · ws.tg_purchasedetail_after    — stock movement untouched
--   · referenceno                   — still assigned by the BEFORE trigger on
--                                     the header via ws.next_docnumber()
--   · the existing two-insert client path — still works, unchanged
--
-- No accounting logic is reimplemented here. This function only creates rows in
-- the right order, in one transaction, once.
--
-- PURELY ADDITIVE: one nullable column, one partial index, one new function.
-- No data migration. Safe to re-run.
-- =============================================================================

-- ─── 1. Idempotency key ──────────────────────────────────────────────────────

alter table public.ws_tblpurchases
  add column if not exists clientuuid uuid;

comment on column public.ws_tblpurchases.clientuuid is
  'Client-generated idempotency key. Retries carry the same value so a re-post '
  'returns the existing purchaseid rather than creating a duplicate.';

-- PARTIAL: null means "recorded by the older direct path", and there may be any
-- number of those. Only non-null keys are constrained, so no existing row can
-- violate this.
create unique index if not exists ux_purchase_clientuuid
  on public.ws_tblpurchases(orgid, clientuuid)
  where clientuuid is not null;

-- ─── 2. The atomic, idempotent recorder ──────────────────────────────────────
--
-- p_lines is jsonb:
--
--   '[{"productid": 1, "quantity": 10, "unitcost": 45, "notes": null},
--     {"productid": 2, "quantity":  5}]'
--
-- unitcost and notes are optional per line. Omitting unitcost lets
-- tg_purchasedetail_prepare fall back to ws_tblproducts.purchaseprice, which is
-- the existing behaviour and is preserved exactly.

create or replace function public.ws_record_purchase(
  p_vendorid     bigint,
  p_lines        jsonb,
  p_purchasedate date default current_date,
  p_billno       text default null,
  p_notes        text default null,
  p_clientuuid   uuid default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org        bigint;
  v_purchaseid bigint;
  v_line       jsonb;
  v_count      int := 0;
  v_qty        numeric;
  v_cost       numeric;
  v_productid  bigint;
begin
  select orgid into v_org from public.ws_tblvendors where vendorid = p_vendorid;
  if v_org is null then
    raise exception 'vendor % not found', p_vendorid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'purchases.manage') then
    raise exception 'permission denied: purchases.manage' using errcode = '42501';
  end if;

  -- ── IDEMPOTENCY CHECK, before anything is written ──────────────────────
  -- A retry of a call that already succeeded returns the original id and
  -- touches nothing. The payload of the retry is deliberately ignored: the
  -- first write wins, so a corrupted or edited retry cannot rewrite a posted
  -- document.
  if p_clientuuid is not null then
    select purchaseid into v_purchaseid
    from public.ws_tblpurchases
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_purchaseid is not null then
      return v_purchaseid;
    end if;
  end if;

  -- ── REJECT AN EMPTY DOCUMENT ───────────────────────────────────────────
  -- Checked BEFORE the header insert. A purchase with no lines is the exact
  -- corrupt state this migration exists to prevent: it would produce
  -- totalamount 0, no journal entry and no stock, while looking like a real
  -- record in the list.
  if p_lines is null
     or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'a purchase must have at least one line'
      using errcode = '22023';
  end if;

  -- Validate EVERY line before writing any of them, so a bad third line does
  -- not leave the first two posted. Cheap, and it makes the failure mode
  -- "nothing happened" rather than "half happened".
  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    if v_line->>'productid' is null then
      raise exception 'every purchase line needs a productid'
        using errcode = '22023';
    end if;

    v_productid := (v_line->>'productid')::bigint;
    v_qty := coalesce((v_line->>'quantity')::numeric, 0);

    if v_qty <= 0 then
      raise exception 'line for product %: quantity must be greater than zero',
        v_productid using errcode = '22023';
    end if;

    -- Cross-tenant guard. assert_same_org runs in the detail trigger too, but
    -- catching it here means the header is never created for a doomed line.
    perform ws.assert_same_org(
      v_org,
      (select orgid from public.ws_tblproducts where productid = v_productid),
      'purchase line vs product');
  end loop;

  -- ── HEADER ─────────────────────────────────────────────────────────────
  -- referenceno is NOT supplied: the BEFORE trigger on this table assigns it
  -- from ws.next_docnumber(orgid, 'purchase') so numbering stays gapless and
  -- per-tenant. A client-supplied number would race.
  insert into public.ws_tblpurchases
    (orgid, vendorid, purchasedate, billno, notes, clientuuid, createdby)
  values
    (v_org, p_vendorid, p_purchasedate, p_billno, p_notes, p_clientuuid,
     ws.current_uid())
  returning purchaseid into v_purchaseid;

  -- ── LINES ──────────────────────────────────────────────────────────────
  -- Same transaction. Each insert fires tg_purchasedetail_prepare (unitcost
  -- default, line amount) and tg_purchasedetail_after (recalc header total,
  -- post the journal entry, move bottles into stock).
  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_cost := (v_line->>'unitcost')::numeric;   -- null is fine; trigger defaults it

    insert into public.ws_tblpurchasedetails
      (purchaseid, orgid, productid, quantity, unitcost, notes)
    values
      (v_purchaseid,
       v_org,
       (v_line->>'productid')::bigint,
       (v_line->>'quantity')::numeric,
       coalesce(v_cost, 0),
       v_line->>'notes');

    v_count := v_count + 1;
  end loop;

  -- Belt and braces. If this ever fires, the loop above silently wrote
  -- nothing and we would rather roll back than return a header id for an
  -- empty purchase.
  if v_count = 0 then
    raise exception 'no purchase lines were written' using errcode = '22023';
  end if;

  return v_purchaseid;
end
$$;

revoke all on function public.ws_record_purchase(bigint,jsonb,date,text,text,uuid) from public;
grant execute on function public.ws_record_purchase(bigint,jsonb,date,text,text,uuid) to authenticated;

-- ─── 3. Extend the diagnostic lookup to purchases ────────────────────────────
-- Same read-only "did this actually land?" question, now covering all three
-- document types. Still a READ: safe to call against a stuck queue item.

create or replace function public.ws_lookup_clientuuid(p_clientuuid uuid)
returns table (doctype text, docid bigint, docnumber text, docdate date)
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select 'delivery'::text, d.deliveryid, d.referenceno, d.deliverydate
  from public.ws_tbldeliveries d
  where d.clientuuid = p_clientuuid
    and ws.is_member(d.orgid)
  union all
  select 'payment'::text, p.paymentid, p.receiptno, p.paymentdate
  from public.ws_tblpayments p
  where p.clientuuid = p_clientuuid
    and ws.is_member(p.orgid)
  union all
  select 'purchase'::text, pu.purchaseid, pu.referenceno, pu.purchasedate
  from public.ws_tblpurchases pu
  where pu.clientuuid = p_clientuuid
    and ws.is_member(pu.orgid);
$$;

revoke all on function public.ws_lookup_clientuuid(uuid) from public;
grant execute on function public.ws_lookup_clientuuid(uuid) to authenticated;

-- =============================================================================
-- VERIFICATION
--
--   -- single line (what the current UI sends)
--   select public.ws_record_purchase(
--     p_vendorid   => 1,
--     p_lines      => '[{"productid":1,"quantity":10,"unitcost":45}]'::jsonb,
--     p_clientuuid => '88888888-8888-8888-8888-888888888888');
--
--   -- run it again: same id, no second document
--
--   -- multi-line
--   select public.ws_record_purchase(
--     p_vendorid => 1,
--     p_lines    => '[{"productid":1,"quantity":10,"unitcost":45},
--                     {"productid":1,"quantity":5,"unitcost":50}]'::jsonb);
--
--   -- empty must RAISE, and must leave no header behind
--   select public.ws_record_purchase(p_vendorid => 1, p_lines => '[]'::jsonb);
--
--   select count(*) from public.vw_ws_reconciliation;   -- must be 0
-- =============================================================================


-- =============================================================================
-- ## SECTION 013 — 013_idempotent_vendor_payment.sql
-- =============================================================================

-- =============================================================================
-- 013_idempotent_vendor_payment.sql
-- Makes paying a vendor SAFE TO RETRY. The last money write that could not be.
--
-- ─── THE PROBLEM ─────────────────────────────────────────────────────────────
--
-- The client inserts straight into ws_tblvendorpayments. If that insert commits
-- and the response is lost, the retry pays the vendor a second time: a second
-- voucher, a second journal entry, and a payable understated by the duplicate
-- amount. Same failure as deliveries (010), payments (010) and purchases (012);
-- this is the last table without the fix.
--
-- Unlike purchases there is no atomicity problem here — a vendor payment is a
-- single row, and its journal entry is posted by an AFTER trigger in the same
-- transaction. Only idempotency is missing.
--
-- ─── methodid IS DELIBERATELY LEFT NULL ──────────────────────────────────────
--
-- The current client does not set methodid, so every vendor payment recorded so
-- far has a null one. This migration PRESERVES that exactly: no method
-- parameter, no defaulting, no behaviour change.
--
-- That is safe because ws.post_vendor_payment already handles it:
--
--     select accountid into v_acct from ws_tblpaymentmethods where methodid = v_method;
--     v_acct := coalesce(v_acct, ws.account_by_control(v_org, 'cash'));
--
-- A null method falls back to the cash control account, so the journal entry is
-- still correct and balanced. Adding a method parameter would be a business
-- change; this migration is strictly an idempotency change.
--
-- ─── WHAT IS NOT CHANGED ─────────────────────────────────────────────────────
--
--   · ws.post_vendor_payment      — journal logic untouched
--   · ws.tg_vendorpayment_before  — voucherno still from ws.next_docnumber()
--   · ws.tg_vendorpayment_after   — posting trigger untouched
--   · the existing direct-insert client path — still works, unchanged
--
-- PURELY ADDITIVE: one nullable column, one partial index, one new function,
-- plus a fourth branch on the lookup. No data migration. Safe to re-run.
-- =============================================================================

-- ─── 1. Idempotency key ──────────────────────────────────────────────────────

alter table public.ws_tblvendorpayments
  add column if not exists clientuuid uuid;

comment on column public.ws_tblvendorpayments.clientuuid is
  'Client-generated idempotency key. Retries carry the same value so a re-post '
  'returns the existing vendorpaymentid rather than paying the vendor twice.';

-- PARTIAL: rows recorded by the older direct path have a null key, and there
-- may be any number of those. Only non-null keys are constrained.
create unique index if not exists ux_vendorpayment_clientuuid
  on public.ws_tblvendorpayments(orgid, clientuuid)
  where clientuuid is not null;

-- ─── 2. The idempotent recorder ──────────────────────────────────────────────

create or replace function public.ws_record_vendor_payment(
  p_vendorid    bigint,
  p_amount      numeric,
  p_paiddate    date    default current_date,
  p_purchaseid  bigint  default null,
  p_referenceno text    default null,
  p_notes       text    default null,
  p_clientuuid  uuid    default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org      bigint;
  v_paymentid bigint;
  v_porg     bigint;
begin
  select orgid into v_org from public.ws_tblvendors where vendorid = p_vendorid;
  if v_org is null then
    raise exception 'vendor % not found', p_vendorid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'purchases.manage') then
    raise exception 'permission denied: purchases.manage' using errcode = '42501';
  end if;

  -- ── IDEMPOTENCY CHECK, before anything is written ──────────────────────
  -- First write wins. A retry returns the original id and ignores its own
  -- payload, so a corrupted or edited retry cannot change a posted payment.
  if p_clientuuid is not null then
    select vendorpaymentid into v_paymentid
    from public.ws_tblvendorpayments
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_paymentid is not null then
      return v_paymentid;
    end if;
  end if;

  -- ── VALIDATE BEFORE WRITING ────────────────────────────────────────────
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'vendor payment amount must be greater than zero'
      using errcode = '22023';
  end if;

  -- A payment can be tied to a specific purchase. If one is named it must
  -- belong to the same tenant; catching it here beats a foreign-key error
  -- that says nothing about which tenant owns what.
  if p_purchaseid is not null then
    select orgid into v_porg from public.ws_tblpurchases
    where purchaseid = p_purchaseid;

    if v_porg is null then
      raise exception 'purchase % not found', p_purchaseid using errcode = 'P0002';
    end if;
    perform ws.assert_same_org(v_org, v_porg, 'vendor payment vs purchase');
  end if;

  -- ── WRITE ──────────────────────────────────────────────────────────────
  -- methodid is NOT supplied: see the header. voucherno is NOT supplied
  -- either — tg_vendorpayment_before assigns it from ws.next_docnumber() so
  -- numbering stays gapless and per-tenant.
  --
  -- The AFTER trigger posts the journal entry (AP debit / cash credit) inside
  -- this same transaction.
  insert into public.ws_tblvendorpayments
    (orgid, vendorid, purchaseid, paiddate, amountpaid, referenceno, notes,
     clientuuid, createdby)
  values
    (v_org, p_vendorid, p_purchaseid, p_paiddate, p_amount, p_referenceno,
     p_notes, p_clientuuid, ws.current_uid())
  returning vendorpaymentid into v_paymentid;

  return v_paymentid;
end
$$;

revoke all on function public.ws_record_vendor_payment(bigint,numeric,date,bigint,text,text,uuid) from public;
grant execute on function public.ws_record_vendor_payment(bigint,numeric,date,bigint,text,text,uuid) to authenticated;

-- ─── 3. Extend the diagnostic lookup ─────────────────────────────────────────
-- All four document types now resolvable from one key. Still a READ, so it is
-- safe to call against a stuck queue item.

create or replace function public.ws_lookup_clientuuid(p_clientuuid uuid)
returns table (doctype text, docid bigint, docnumber text, docdate date)
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select 'delivery'::text, d.deliveryid, d.referenceno, d.deliverydate
  from public.ws_tbldeliveries d
  where d.clientuuid = p_clientuuid
    and ws.is_member(d.orgid)
  union all
  select 'payment'::text, p.paymentid, p.receiptno, p.paymentdate
  from public.ws_tblpayments p
  where p.clientuuid = p_clientuuid
    and ws.is_member(p.orgid)
  union all
  select 'purchase'::text, pu.purchaseid, pu.referenceno, pu.purchasedate
  from public.ws_tblpurchases pu
  where pu.clientuuid = p_clientuuid
    and ws.is_member(pu.orgid)
  union all
  select 'vendorpayment'::text, vp.vendorpaymentid, vp.voucherno, vp.paiddate
  from public.ws_tblvendorpayments vp
  where vp.clientuuid = p_clientuuid
    and ws.is_member(vp.orgid);
$$;

revoke all on function public.ws_lookup_clientuuid(uuid) from public;
grant execute on function public.ws_lookup_clientuuid(uuid) to authenticated;

-- =============================================================================
-- VERIFICATION
--
--   select public.ws_record_vendor_payment(
--     p_vendorid   => 1, p_amount => 500,
--     p_clientuuid => 'aaaaaaaa-1111-2222-3333-444444444444');
--   -- run again: same id, no second voucher
--
--   select count(*) from public.ws_tblvendorpayments
--    where clientuuid = 'aaaaaaaa-1111-2222-3333-444444444444';   -- must be 1
--
--   select * from public.ws_lookup_clientuuid(
--     'aaaaaaaa-1111-2222-3333-444444444444');
--
--   select count(*) from public.vw_ws_reconciliation;             -- must be 0
-- =============================================================================


-- =============================================================================
-- ## SECTION 014 — 014_idempotent_master_data.sql
-- =============================================================================

-- =============================================================================
-- 014_idempotent_master_data.sql
-- Closes the last three duplicate-on-retry paths: customers, vendors, and
-- organization registration.
--
-- ─── WHY THESE THREE ARE NOT "JUST MASTER DATA" ──────────────────────────────
--
-- A duplicate customer is a SPLIT LEDGER. bottlebalance, depositamount,
-- openingbalance and outstanding due are all keyed on customerid. If a save
-- times out after committing and the user taps Save again, the deliveries
-- recorded before the retry hang off one row and everything after hangs off
-- the other. The customer's bottle count is wrong, their statement is wrong,
-- and — the part that matters most — vw_ws_reconciliation STILL RETURNS 0,
-- because both halves are summed into the same totals. The one automated check
-- that guards the books cannot see this class of damage. The same argument
-- applies to vendors and payables.
--
-- A duplicate organization is worse in a different way: the user lands in a
-- tenant with no data, or picks between two identical names forever.
--
-- ─── THE MECHANISM IS THE ONE ALREADY PROVEN ─────────────────────────────────
--
-- Identical to migrations 010/012/013: a client-generated uuid, a PARTIAL
-- unique index that ignores the rows written before this existed, and an
-- early-return inside a SECURITY DEFINER function so a retry is a READ.
--
-- FIRST WRITE WINS. A retry returns the original id and ignores its own
-- payload, so a tampered or half-edited second attempt cannot mutate a record
-- that already exists.
--
-- Deliberately NOT used as the key: customercode, vendorcode, customername,
-- vendorname. Those are nullable or user-editable. An idempotency key must be
-- meaningless, mandatory and generated by the client — the moment it doubles
-- as business data, the user can change it and break the guarantee.
--
-- ─── WHAT IS NOT CHANGED ─────────────────────────────────────────────────────
--
--   · No business logic. The RPCs insert exactly the columns the client
--     already inserted, in the same way.
--   · No accounting. None of these three tables posts a journal entry on
--     insert, and this migration does not add one.
--   · No document numbering. customercode / vendorcode / publicid keep their
--     existing behaviour; publicid still comes from its column default.
--   · The direct-insert paths still work. clientuuid is nullable and the index
--     is partial, so every existing row and every legacy caller stays valid.
--   · ws.seed_chart_of_accounts is untouched and still idempotent.
--
-- PURELY ADDITIVE: three nullable columns, three partial indexes, two new
-- functions, two functions gaining one defaulted parameter, one lookup
-- extended. No data migration. Safe to re-run.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. CUSTOMERS
-- ═════════════════════════════════════════════════════════════════════════════

alter table public.ws_tblcustomers
  add column if not exists clientuuid uuid;

comment on column public.ws_tblcustomers.clientuuid is
  'Client-generated idempotency key for the create path. A retry after a lost '
  'response returns the existing customerid instead of splitting the '
  'customer''s ledger across two rows.';

-- PARTIAL: every customer created before this migration has a null key, and
-- there may be any number of those.
create unique index if not exists ux_customer_clientuuid
  on public.ws_tblcustomers(orgid, clientuuid)
  where clientuuid is not null;


create or replace function public.ws_record_customer(
  p_orgid         bigint,
  p_customername  text,
  p_areaid        bigint  default null,
  p_customercode  text    default null,
  p_contactperson text    default null,
  p_phone         text    default null,
  p_email         text    default null,
  p_address       text    default null,
  p_rateoverride  numeric default null,
  p_depositamount numeric default 0,
  p_routeid       bigint  default null,
  p_groupid       bigint  default null,
  p_openingbalance numeric default 0,
  p_clientuuid    uuid    default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_customerid bigint;
  v_areaorg    bigint;
begin
  if not ws.has_perm(p_orgid, 'customers.manage') then
    raise exception 'permission denied: customers.manage' using errcode = '42501';
  end if;

  -- ── IDEMPOTENCY CHECK, BEFORE ANYTHING IS WRITTEN ──────────────────────
  -- A retry lands here and leaves as a read. Note it returns WITHOUT looking
  -- at the rest of the payload: first write wins, so a second attempt that
  -- carries edited fields cannot overwrite the record that already exists.
  if p_clientuuid is not null then
    select customerid into v_customerid
    from public.ws_tblcustomers
    where orgid = p_orgid and clientuuid = p_clientuuid;

    if v_customerid is not null then
      return v_customerid;
    end if;
  end if;

  -- ── VALIDATE ───────────────────────────────────────────────────────────
  if coalesce(trim(p_customername), '') = '' then
    raise exception 'customer name is required' using errcode = '22023';
  end if;

  -- An area belonging to another tenant would otherwise be accepted and only
  -- surface later as a customer whose rate cannot be resolved.
  if p_areaid is not null then
    select orgid into v_areaorg from public.ws_tblareas where areaid = p_areaid;
    if v_areaorg is null then
      raise exception 'area % not found', p_areaid using errcode = 'P0002';
    end if;
    perform ws.assert_same_org(p_orgid, v_areaorg, 'customer vs area');
  end if;

  -- ── WRITE ──────────────────────────────────────────────────────────────
  -- The same columns the client insert wrote, nothing more. bottlebalance is
  -- deliberately absent: it is a trigger-maintained cache.
  insert into public.ws_tblcustomers
    (orgid, customername, customercode, areaid, routeid, groupid,
     contactperson, phone, email, address, rateoverride, depositamount,
     openingbalance, clientuuid)
  values
    (p_orgid, p_customername, p_customercode, p_areaid, p_routeid, p_groupid,
     p_contactperson, p_phone, p_email, p_address, p_rateoverride,
     coalesce(p_depositamount, 0), coalesce(p_openingbalance, 0), p_clientuuid)
  returning customerid into v_customerid;

  return v_customerid;
end
$$;

revoke all on function public.ws_record_customer(
  bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,
  numeric,uuid) from public;
grant execute on function public.ws_record_customer(
  bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,
  numeric,uuid) to authenticated;


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. VENDORS
-- ═════════════════════════════════════════════════════════════════════════════

alter table public.ws_tblvendors
  add column if not exists clientuuid uuid;

comment on column public.ws_tblvendors.clientuuid is
  'Client-generated idempotency key for the create path. Prevents a retry '
  'after a lost response from splitting payables across two vendor rows.';

create unique index if not exists ux_vendor_clientuuid
  on public.ws_tblvendors(orgid, clientuuid)
  where clientuuid is not null;


create or replace function public.ws_record_vendor(
  p_orgid          bigint,
  p_vendorname     text,
  p_vendorcode     text    default null,
  p_contactperson  text    default null,
  p_phone          text    default null,
  p_email          text    default null,
  p_address        text    default null,
  p_openingbalance numeric default 0,
  p_clientuuid     uuid    default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_vendorid bigint;
begin
  if not ws.has_perm(p_orgid, 'vendors.manage') then
    raise exception 'permission denied: vendors.manage' using errcode = '42501';
  end if;

  -- First write wins. See ws_record_customer.
  if p_clientuuid is not null then
    select vendorid into v_vendorid
    from public.ws_tblvendors
    where orgid = p_orgid and clientuuid = p_clientuuid;

    if v_vendorid is not null then
      return v_vendorid;
    end if;
  end if;

  if coalesce(trim(p_vendorname), '') = '' then
    raise exception 'vendor name is required' using errcode = '22023';
  end if;

  -- p_openingbalance is written RAW, exactly as the client insert wrote it.
  --
  -- That is deliberate preservation, not endorsement: a non-zero opening
  -- balance set this way has no matching journal entry, so the AP subsidiary
  -- and the general ledger disagree. That behaviour predates this migration
  -- and ws.set_vendor_opening() is the path that posts the entry. Changing it
  -- here would be an accounting change, which is out of scope for a migration
  -- about idempotency.
  insert into public.ws_tblvendors
    (orgid, vendorname, vendorcode, contactperson, phone, email, address,
     openingbalance, clientuuid)
  values
    (p_orgid, p_vendorname, p_vendorcode, p_contactperson, p_phone, p_email,
     p_address, coalesce(p_openingbalance, 0), p_clientuuid)
  returning vendorid into v_vendorid;

  return v_vendorid;
end
$$;

revoke all on function public.ws_record_vendor(
  bigint,text,text,text,text,text,text,numeric,uuid) from public;
grant execute on function public.ws_record_vendor(
  bigint,text,text,text,text,text,text,numeric,uuid) to authenticated;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. ORGANIZATION REGISTRATION
-- ═════════════════════════════════════════════════════════════════════════════

alter table public.ws_tblorganization
  add column if not exists clientuuid uuid;

comment on column public.ws_tblorganization.clientuuid is
  'Client-generated idempotency key for one registration attempt. A retry '
  'after a lost response returns the organization already provisioned rather '
  'than creating a second empty tenant.';

-- SCOPED TO THE OWNER, not global. A key is unguessable in practice, but
-- scoping it means one user''s key can never collide with another''s and block
-- a legitimate registration.
create unique index if not exists ux_organization_clientuuid
  on public.ws_tblorganization(owneruserid, clientuuid)
  where clientuuid is not null;


-- ─── The old signatures must GO, not sit alongside the new ones ──────────────
--
-- Adding a defaulted parameter creates an OVERLOAD. A six-argument call would
-- then match both the old six-arg function exactly and the new seven-arg one
-- by default, and Postgres refuses with "function is not unique". Migration
-- 010 hit exactly this with ws_record_delivery. Dropping first means one
-- function exists and every existing caller — seed.sql, fix_user_without_org
-- .sql, the app — keeps resolving to it.

drop function if exists ws.provision_organization(uuid,text,text,text,text,text);
drop function if exists public.ws_create_organization(text,text,text,text,text);


create or replace function ws.provision_organization(
  p_uid        uuid,
  p_orgname    text,
  p_ownername  text default '',
  p_phone      text default '',
  p_address    text default '',
  p_currency   text default 'PKR',
  p_clientuuid uuid default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_orgid  bigint;
  v_roleid bigint;
  v_msid   bigint;
begin
  if p_uid is null then
    raise exception 'provision_organization: no owner uid supplied'
      using errcode = '42501';
  end if;

  -- ── IDEMPOTENCY CHECK ──────────────────────────────────────────────────
  -- THE WHOLE REGISTRATION IS ONE OPERATION. Everything below — org, roles,
  -- membership, internal user, subscription, chart of accounts — happens in a
  -- single transaction, so this one check protects all of it. A retry returns
  -- the organization that already exists and provisions nothing twice.
  if p_clientuuid is not null then
    select orgid into v_orgid
    from public.ws_tblorganization
    where owneruserid = p_uid and clientuuid = p_clientuuid;

    if v_orgid is not null then
      return v_orgid;
    end if;
  end if;

  insert into public.ws_tblorganization
    (orgname, businessname, owneruserid, ownername, phone, address, currency,
     clientuuid)
  values
    (p_orgname, p_orgname, p_uid, p_ownername, p_phone, p_address, p_currency,
     p_clientuuid)
  returning orgid into v_orgid;

  perform ws.ensure_org_roles(v_orgid);

  select roleid into v_roleid
  from public.ws_tblroles
  where orgid = v_orgid and rolecode = 'owner';

  insert into public.ws_tblmemberships (orgid, authuserid, roleid)
  values (v_orgid, p_uid, v_roleid)
  returning membershipid into v_msid;

  insert into public.ws_tblinternalusers
    (orgid, authuserid, fullname, role, phone, membershipid)
  values
    (v_orgid, p_uid, coalesce(nullif(p_ownername, ''), 'Owner'), 'owner',
     nullif(p_phone, ''), v_msid);

  insert into public.ws_tblsubscriptions
    (orgid, plancode, status, trialstartdate, trialenddate, periodstart, periodend)
  values
    (v_orgid, 'free', 'trialing', current_date, current_date + 30,
     current_date, current_date + 30);

  -- Seeded HERE, inside the same transaction, since migration 011. The client
  -- no longer calls ws_seed_chart_of_accounts as a second round trip — that
  -- second call was the window where a dropped connection left the caller
  -- believing registration had failed while the tenant existed.
  perform ws.seed_chart_of_accounts(v_orgid);

  return v_orgid;
end
$$;

revoke all on function ws.provision_organization(uuid,text,text,text,text,text,uuid) from public;


create or replace function public.ws_create_organization(
  p_orgname    text,
  p_ownername  text default '',
  p_phone      text default '',
  p_address    text default '',
  p_currency   text default 'PKR',
  p_clientuuid uuid default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare v_uid uuid := ws.current_uid();
begin
  if v_uid is null then
    raise exception 'ws_create_organization: not authenticated'
      using errcode = '42501';
  end if;
  return ws.provision_organization(
    v_uid, p_orgname, p_ownername, p_phone, p_address, p_currency,
    p_clientuuid);
end
$$;

revoke all on function public.ws_create_organization(text,text,text,text,text,uuid) from public;
grant execute on function public.ws_create_organization(text,text,text,text,text,uuid) to authenticated;


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. ONE LOOKUP FOR EVERY KEY
-- ═════════════════════════════════════════════════════════════════════════════
-- Still a READ, so it stays safe to call against an operation whose outcome is
-- unknown. Seven document types now resolve from one key.
--
-- Organizations are matched on ownership rather than ws.is_member(), because
-- the question being asked is "did MY registration land?" and the answer must
-- be available even if membership somehow did not complete.

create or replace function public.ws_lookup_clientuuid(p_clientuuid uuid)
returns table (doctype text, docid bigint, docnumber text, docdate date)
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select 'delivery'::text, d.deliveryid, d.referenceno, d.deliverydate
  from public.ws_tbldeliveries d
  where d.clientuuid = p_clientuuid and ws.is_member(d.orgid)
  union all
  select 'payment'::text, p.paymentid, p.receiptno, p.paymentdate
  from public.ws_tblpayments p
  where p.clientuuid = p_clientuuid and ws.is_member(p.orgid)
  union all
  select 'purchase'::text, pu.purchaseid, pu.referenceno, pu.purchasedate
  from public.ws_tblpurchases pu
  where pu.clientuuid = p_clientuuid and ws.is_member(pu.orgid)
  union all
  select 'vendorpayment'::text, vp.vendorpaymentid, vp.voucherno, vp.paiddate
  from public.ws_tblvendorpayments vp
  where vp.clientuuid = p_clientuuid and ws.is_member(vp.orgid)
  union all
  select 'customer'::text, c.customerid, c.customercode, c.createddate::date
  from public.ws_tblcustomers c
  where c.clientuuid = p_clientuuid and ws.is_member(c.orgid)
  union all
  select 'vendor'::text, v.vendorid, v.vendorcode, v.createddate::date
  from public.ws_tblvendors v
  where v.clientuuid = p_clientuuid and ws.is_member(v.orgid)
  union all
  select 'organization'::text, o.orgid, o.orgname, o.createddate::date
  from public.ws_tblorganization o
  where o.clientuuid = p_clientuuid and o.owneruserid = ws.current_uid();
$$;

revoke all on function public.ws_lookup_clientuuid(uuid) from public;
grant execute on function public.ws_lookup_clientuuid(uuid) to authenticated;


-- =============================================================================
-- VERIFICATION
--
--   -- same key twice = one customer, original id both times
--   select public.ws_record_customer(1, 'Test', p_clientuuid =>
--          'aaaaaaaa-0000-0000-0000-000000000001');
--   select public.ws_record_customer(1, 'TAMPERED', p_clientuuid =>
--          'aaaaaaaa-0000-0000-0000-000000000001');
--   select count(*) from public.ws_tblcustomers
--    where clientuuid = 'aaaaaaaa-0000-0000-0000-000000000001';   -- must be 1
--   select customername from public.ws_tblcustomers
--    where clientuuid = 'aaaaaaaa-0000-0000-0000-000000000001';   -- 'Test'
--
--   -- legacy caller, no key, still works and is never deduplicated
--   select public.ws_record_customer(1, 'Legacy A');
--   select public.ws_record_customer(1, 'Legacy A');              -- two rows
--
--   select count(*) from public.vw_ws_reconciliation;             -- must be 0
--   select count(*) from public.vw_ws_unbalancedentries;          -- must be 0
-- =============================================================================


-- =============================================================================
-- ## SECTION 015 — 015_stores_and_branches.sql
-- =============================================================================

-- =============================================================================
-- 015_stores_and_branches.sql
-- Multi-branch, at the database level.
--
-- ─── THE SHAPE OF THE FEATURE ────────────────────────────────────────────────
--
-- An organization has one or more STORES. Every document belongs to exactly
-- one. A user may be restricted to a subset of them, and that restriction is
-- enforced by RLS — not by a filter in the client, which is a display
-- preference, not a security boundary.
--
-- ─── EXISTING ORGANIZATIONS MUST NOT NOTICE ──────────────────────────────────
--
-- Every organization that exists when this runs gets one store, 'MAIN', marked
-- default, and every existing row is backfilled to it. A single-store business
-- never sees a store picker, never passes a store id, and behaves exactly as
-- before. Multi-branch is opt-in by creating a second store.
--
-- Three mechanisms make that true:
--
--   1. storeid is filled by a BEFORE INSERT trigger when the caller omits it,
--      so every legacy insert path keeps working untouched.
--   2. A user with NO explicit store assignment can reach every store in their
--      organization. Restriction begins the moment someone is assigned.
--   3. p_storeid on the RPCs defaults to null, which resolves to the org's
--      default store.
--
-- ─── STORE IS CAPTURED AT SAVE TIME, NOT AT SYNC TIME ────────────────────────
--
-- This is the whole point of putting it in the payload:
--
--     select Store A → save → clientuuid + storeid=A → queued
--     → user switches to Store B → queue drains → document still posts to A
--
-- The server takes the store from the ARGUMENTS it was given. It never asks
-- which store the user is looking at now, and there is no session state it
-- could ask. A document queued yesterday in a branch the driver has since left
-- lands where it was created.
--
-- ─── WHAT THIS MIGRATION DELIBERATELY DOES NOT DO ────────────────────────────
--
-- THE GENERAL LEDGER STAYS AT ORGANIZATION LEVEL. Journal entries, control
-- accounts, the trial balance and vw_ws_reconciliation are unchanged and
-- remain per-organization. Store is an OPERATIONAL dimension on documents:
-- which branch delivered, which branch took the cash.
--
-- Per-branch profit and loss is a different feature. It needs control accounts
-- per store, a reconciliation view per store, and decisions about how
-- inter-branch transfers are posted. Bolting it onto this migration would mean
-- every failure in testing could be either a multi-branch bug or an accounting
-- bug, and telling them apart is exactly what makes that combination
-- expensive. If per-branch P&L is wanted it belongs in its own migration.
--
-- Products, vendors, areas and the chart of accounts stay organization-wide: a
-- shared catalogue is what a single business with two depots actually has.
-- Customers DO carry a store, because deliveries follow customers.
--
-- ADDITIVE: two new tables, six nullable-then-backfilled columns, six
-- triggers, five helper functions, policies rewritten to add one conjunct, and
-- the four posting RPCs gaining one defaulted parameter. Safe to re-run.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. THE TABLES
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists public.ws_tblstores (
  storeid     bigint generated always as identity primary key,
  orgid       bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  storecode   text   not null,
  storename   text   not null,
  address     text,
  phone       text,
  isdefault   boolean not null default false,
  isactive    boolean not null default true,
  clientuuid  uuid,
  createddate timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (orgid, storecode)
);

comment on table public.ws_tblstores is
  'A branch or depot. Every organization has at least one; single-branch '
  'businesses have exactly one and never see it.';

-- EXACTLY ONE DEFAULT PER ORGANIZATION. The default is what an omitted
-- p_storeid resolves to, so two of them would make posting non-deterministic.
create unique index if not exists ux_store_default_per_org
  on public.ws_tblstores(orgid) where isdefault;

create unique index if not exists ux_store_clientuuid
  on public.ws_tblstores(orgid, clientuuid) where clientuuid is not null;


create table if not exists public.ws_tblstoremembers (
  storememberid bigint generated always as identity primary key,
  orgid         bigint not null references public.ws_tblorganization(orgid) on delete cascade,
  storeid       bigint not null references public.ws_tblstores(storeid) on delete cascade,
  authuserid    uuid   not null,
  isactive      boolean not null default true,
  createddate   timestamptz not null default now(),
  unique (storeid, authuserid)
);

comment on table public.ws_tblstoremembers is
  'Which stores a user may see. A user with NO rows here can reach every '
  'store in their organization — that is what keeps every existing user '
  'working after this migration. Restriction starts when the first row is '
  'added for them.';

create index if not exists ix_storemember_user
  on public.ws_tblstoremembers(orgid, authuserid) where isactive;


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. HELPERS
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function ws.default_storeid(p_orgid bigint)
returns bigint
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select storeid from public.ws_tblstores
  where orgid = p_orgid and isdefault and isactive
  limit 1;
$$;


-- May the caller see this store?
--
-- SECURITY DEFINER and reads ws_tblstoremembers directly, because it is called
-- from inside RLS policies — a policy that depended on another policy would
-- recurse.
create or replace function ws.can_access_store(p_storeid bigint)
returns boolean
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select case
    -- Rows written before this migration, in the window before the backfill.
    -- Nothing to check, and refusing them would hide real data.
    when p_storeid is null then true
    else exists (
      select 1
      from public.ws_tblstores s
      where s.storeid = p_storeid
        and ws.is_member(s.orgid)
        and (
          -- A portal customer is already restricted to their own rows by every
          -- policy that calls this; a store check would add nothing and could
          -- hide their own history.
          ws.is_portal(s.orgid)

          -- Whoever administers the organization sees all of it.
          or ws.has_perm(s.orgid, 'org.manage')

          -- UNASSIGNED MEANS EVERYWHERE. Every user who existed before this
          -- migration has no assignments, so nobody loses access on upgrade.
          or not exists (
            select 1 from public.ws_tblstoremembers m
            where m.orgid = s.orgid
              and m.authuserid = ws.current_uid()
              and m.isactive)

          -- Assigned: only where they are assigned.
          or exists (
            select 1 from public.ws_tblstoremembers m
            where m.storeid = s.storeid
              and m.authuserid = ws.current_uid()
              and m.isactive)
        ))
  end;
$$;


-- Resolve and AUTHORISE the store for a write.
--
-- Every posting RPC calls this. It is the single place that decides which
-- store a document lands in, which is why the answer can never come from
-- session state or from "whatever the user is looking at".
create or replace function ws.resolve_store(p_orgid bigint, p_storeid bigint)
returns bigint
language plpgsql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_storeid bigint;
  v_owner   bigint;
begin
  v_storeid := coalesce(p_storeid, ws.default_storeid(p_orgid));

  if v_storeid is null then
    raise exception 'organization % has no default store', p_orgid
      using errcode = 'P0002';
  end if;

  select orgid into v_owner from public.ws_tblstores where storeid = v_storeid;
  if v_owner is null then
    raise exception 'store % not found', v_storeid using errcode = 'P0002';
  end if;

  -- A store id from another tenant is a cross-tenant write attempt, not a
  -- typo, and must never be treated as one.
  if v_owner <> p_orgid then
    raise exception 'store % does not belong to organization %',
      v_storeid, p_orgid using errcode = '22023';
  end if;

  if not ws.can_access_store(v_storeid) then
    raise exception 'permission denied: store %', v_storeid
      using errcode = '42501';
  end if;

  return v_storeid;
end
$$;


-- Fills storeid when the caller omitted it, so that EVERY existing insert path
-- — direct inserts, posting triggers, older clients — keeps working.
--
-- Derivation before default: a payment created inside a delivery belongs to
-- the delivery's store, not to whatever the organization's default happens to
-- be. Getting that wrong would scatter a branch's cash across the books.
create or replace function ws.tg_default_storeid()
returns trigger
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
begin
  if new.storeid is not null then
    return new;
  end if;

  if tg_table_name = 'ws_tblpayments' then
    if new.deliveryid is not null then
      select storeid into new.storeid
      from public.ws_tbldeliveries where deliveryid = new.deliveryid;
    end if;
    if new.storeid is null and new.customerid is not null then
      select storeid into new.storeid
      from public.ws_tblcustomers where customerid = new.customerid;
    end if;

  elsif tg_table_name = 'ws_tblbottletransactions' then
    if new.deliveryid is not null then
      select storeid into new.storeid
      from public.ws_tbldeliveries where deliveryid = new.deliveryid;
    end if;
    if new.storeid is null and new.customerid is not null then
      select storeid into new.storeid
      from public.ws_tblcustomers where customerid = new.customerid;
    end if;

  elsif tg_table_name = 'ws_tbldeliveries' then
    -- NESTED, not folded into the elsif condition. plpgsql resolves a record
    -- field reference wherever it appears in a condition it evaluates, and
    -- this trigger is attached to ws_tblpurchases too — which has no
    -- customerid. `tg_table_name = '...' and new.customerid is not null`
    -- therefore fails on purchases before the table name is ever compared.
    if new.customerid is not null then
      select storeid into new.storeid
      from public.ws_tblcustomers where customerid = new.customerid;
    end if;
  end if;

  new.storeid := coalesce(new.storeid, ws.default_storeid(new.orgid));
  return new;
end
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. ONE STORE FOR EVERY ORGANIZATION THAT ALREADY EXISTS
-- ═════════════════════════════════════════════════════════════════════════════

insert into public.ws_tblstores (orgid, storecode, storename, isdefault)
select o.orgid, 'MAIN', coalesce(nullif(o.orgname, ''), 'Main Store'), true
from public.ws_tblorganization o
where not exists (
  select 1 from public.ws_tblstores s where s.orgid = o.orgid);

-- An organization that somehow has stores but none marked default would make
-- ws.default_storeid() return null and every omitted p_storeid fail.
update public.ws_tblstores s
set isdefault = true
where s.isdefault = false
  and not exists (
    select 1 from public.ws_tblstores d
    where d.orgid = s.orgid and d.isdefault)
  and s.storeid = (
    select min(storeid) from public.ws_tblstores x where x.orgid = s.orgid);


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. storeid ON THE TABLES THAT CARRY IT
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare
  t text;
begin
  foreach t in array array[
    'ws_tblcustomers', 'ws_tbldeliveries', 'ws_tblpayments',
    'ws_tblpurchases', 'ws_tblvendorpayments', 'ws_tblbottletransactions'
  ]
  loop
    -- column
    execute format(
      'alter table public.%I add column if not exists storeid bigint '
      'references public.ws_tblstores(storeid)', t);

    -- trigger BEFORE the backfill, so anything written while this migration
    -- runs is already correct
    execute format('drop trigger if exists trg_default_storeid on public.%I', t);
    execute format(
      'create trigger trg_default_storeid before insert on public.%I '
      'for each row execute function ws.tg_default_storeid()', t);

    -- backfill every existing row to its organization''s default store
    --
    -- ws_tblbottletransactions is APPEND-ONLY: a trigger rejects every update,
    -- because a bottle ledger that can be edited after the fact is not a
    -- ledger. Backfilling a new column is the one legitimate exception, so the
    -- guard is lifted for exactly this statement and put straight back. It is
    -- not weakened, and no row''s quantities are touched.
    if t = 'ws_tblbottletransactions' then
      alter table public.ws_tblbottletransactions
        disable trigger trg_bottletxn_append_only;
    end if;

    execute format(
      'update public.%I x set storeid = ws.default_storeid(x.orgid) '
      'where x.storeid is null', t);

    if t = 'ws_tblbottletransactions' then
      alter table public.ws_tblbottletransactions
        enable trigger trg_bottletxn_append_only;
    end if;

    -- and only now make it mandatory. BEFORE triggers run before NOT NULL is
    -- checked, so a caller that omits it is still filled in rather than
    -- rejected.
    execute format('alter table public.%I alter column storeid set not null', t);

    execute format(
      'create index if not exists ix_%s_store on public.%I(orgid, storeid)',
      replace(t, 'ws_tbl', ''), t);
  end loop;
end
$$;

comment on column public.ws_tbldeliveries.storeid is
  'The branch this delivery belongs to. Captured when the document is saved — '
  'including offline — and never re-derived at sync time.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. NEW ORGANIZATIONS GET A STORE AS PART OF PROVISIONING
-- ═════════════════════════════════════════════════════════════════════════════
-- Same signature as migration 014, so this replaces rather than overloads.
-- The only change is the store insert, placed before seed_chart_of_accounts so
-- the whole tenant still appears in one transaction.

create or replace function ws.provision_organization(
  p_uid        uuid,
  p_orgname    text,
  p_ownername  text default '',
  p_phone      text default '',
  p_address    text default '',
  p_currency   text default 'PKR',
  p_clientuuid uuid default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_orgid  bigint;
  v_roleid bigint;
  v_msid   bigint;
begin
  if p_uid is null then
    raise exception 'provision_organization: no owner uid supplied'
      using errcode = '42501';
  end if;

  -- Idempotency (migration 014): the whole registration is one operation.
  if p_clientuuid is not null then
    select orgid into v_orgid
    from public.ws_tblorganization
    where owneruserid = p_uid and clientuuid = p_clientuuid;

    if v_orgid is not null then
      return v_orgid;
    end if;
  end if;

  insert into public.ws_tblorganization
    (orgname, businessname, owneruserid, ownername, phone, address, currency,
     clientuuid)
  values
    (p_orgname, p_orgname, p_uid, p_ownername, p_phone, p_address, p_currency,
     p_clientuuid)
  returning orgid into v_orgid;

  -- The default branch. A business with one shop never interacts with this;
  -- it exists so that every document has somewhere to belong.
  insert into public.ws_tblstores (orgid, storecode, storename, isdefault)
  values (v_orgid, 'MAIN', coalesce(nullif(p_orgname, ''), 'Main Store'), true);

  perform ws.ensure_org_roles(v_orgid);

  select roleid into v_roleid
  from public.ws_tblroles
  where orgid = v_orgid and rolecode = 'owner';

  insert into public.ws_tblmemberships (orgid, authuserid, roleid)
  values (v_orgid, p_uid, v_roleid)
  returning membershipid into v_msid;

  insert into public.ws_tblinternalusers
    (orgid, authuserid, fullname, role, phone, membershipid)
  values
    (v_orgid, p_uid, coalesce(nullif(p_ownername, ''), 'Owner'), 'owner',
     nullif(p_phone, ''), v_msid);

  insert into public.ws_tblsubscriptions
    (orgid, plancode, status, trialstartdate, trialenddate, periodstart, periodend)
  values
    (v_orgid, 'free', 'trialing', current_date, current_date + 30,
     current_date, current_date + 30);

  perform ws.seed_chart_of_accounts(v_orgid);

  return v_orgid;
end
$$;

revoke all on function ws.provision_organization(uuid,text,text,text,text,text,uuid) from public;


-- ═════════════════════════════════════════════════════════════════════════════
-- 6. MANAGING STORES AND THEIR MEMBERS
-- ═════════════════════════════════════════════════════════════════════════════

-- Idempotent for the same reason customers and vendors are (migration 014):
-- creating a branch is a user Save action and a lost response must not create
-- two of them.
create or replace function public.ws_record_store(
  p_orgid      bigint,
  p_storename  text,
  p_storecode  text default null,
  p_address    text default null,
  p_phone      text default null,
  p_isdefault  boolean default false,
  p_clientuuid uuid default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_storeid bigint;
  v_code    text;
begin
  if not ws.has_perm(p_orgid, 'org.manage') then
    raise exception 'permission denied: org.manage' using errcode = '42501';
  end if;

  if p_clientuuid is not null then
    select storeid into v_storeid
    from public.ws_tblstores
    where orgid = p_orgid and clientuuid = p_clientuuid;

    if v_storeid is not null then
      return v_storeid;
    end if;
  end if;

  if coalesce(trim(p_storename), '') = '' then
    raise exception 'store name is required' using errcode = '22023';
  end if;

  v_code := coalesce(nullif(trim(p_storecode), ''),
                     'ST-' || lpad((
                       select count(*) + 1 from public.ws_tblstores
                       where orgid = p_orgid)::text, 3, '0'));

  -- Promoting a new default has to demote the old one, or the unique index
  -- fires and the caller sees a constraint name instead of a branch.
  if p_isdefault then
    update public.ws_tblstores set isdefault = false
    where orgid = p_orgid and isdefault;
  end if;

  insert into public.ws_tblstores
    (orgid, storecode, storename, address, phone, isdefault, clientuuid)
  values
    (p_orgid, v_code, p_storename, p_address, p_phone,
     coalesce(p_isdefault, false), p_clientuuid)
  returning storeid into v_storeid;

  return v_storeid;
end
$$;

revoke all on function public.ws_record_store(bigint,text,text,text,text,boolean,uuid) from public;
grant execute on function public.ws_record_store(bigint,text,text,text,text,boolean,uuid) to authenticated;


create or replace function public.ws_set_store_access(
  p_storeid   bigint,
  p_authuserid uuid,
  p_allowed   boolean default true
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare v_org bigint;
begin
  select orgid into v_org from public.ws_tblstores where storeid = p_storeid;
  if v_org is null then
    raise exception 'store % not found', p_storeid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'users.manage') then
    raise exception 'permission denied: users.manage' using errcode = '42501';
  end if;

  -- The person must already belong to the organization. Granting a branch to
  -- a stranger would otherwise create access with no membership behind it.
  if not exists (select 1 from public.ws_tblmemberships
                 where orgid = v_org and authuserid = p_authuserid and isactive) then
    raise exception 'user is not a member of organization %', v_org
      using errcode = 'P0002';
  end if;

  insert into public.ws_tblstoremembers (orgid, storeid, authuserid, isactive)
  values (v_org, p_storeid, p_authuserid, coalesce(p_allowed, true))
  on conflict (storeid, authuserid)
  do update set isactive = excluded.isactive;
end
$$;

revoke all on function public.ws_set_store_access(bigint,uuid,boolean) from public;
grant execute on function public.ws_set_store_access(bigint,uuid,boolean) to authenticated;


-- The stores this user may work in, for the picker.
create or replace function public.ws_my_stores(p_orgid bigint)
returns table (storeid bigint, storecode text, storename text, isdefault boolean)
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select s.storeid, s.storecode, s.storename, s.isdefault
  from public.ws_tblstores s
  where s.orgid = p_orgid
    and s.isactive
    and ws.is_member(s.orgid)
    and ws.can_access_store(s.storeid)
  order by s.isdefault desc, s.storename;
$$;

revoke all on function public.ws_my_stores(bigint) from public;
grant execute on function public.ws_my_stores(bigint) to authenticated;


-- ═════════════════════════════════════════════════════════════════════════════
-- 7. ROW LEVEL SECURITY
-- ═════════════════════════════════════════════════════════════════════════════

alter table public.ws_tblstores        enable row level security;
alter table public.ws_tblstoremembers  enable row level security;

drop policy if exists stores_select on public.ws_tblstores;
create policy stores_select on public.ws_tblstores
  for select using (ws.is_member(orgid) and ws.can_access_store(storeid));

drop policy if exists stores_write on public.ws_tblstores;
create policy stores_write on public.ws_tblstores
  for all using (ws.has_perm(orgid, 'org.manage'))
  with check (ws.has_perm(orgid, 'org.manage'));

drop policy if exists storemembers_select on public.ws_tblstoremembers;
create policy storemembers_select on public.ws_tblstoremembers
  for select using (
    ws.is_member(orgid)
    and (authuserid = ws.current_uid() or ws.has_perm(orgid, 'users.manage')));

drop policy if exists storemembers_write on public.ws_tblstoremembers;
create policy storemembers_write on public.ws_tblstoremembers
  for all using (ws.has_perm(orgid, 'users.manage'))
  with check (ws.has_perm(orgid, 'users.manage'));

grant select on public.ws_tblstores to authenticated;
grant select on public.ws_tblstoremembers to authenticated;


-- ─── The existing policies, plus one conjunct ────────────────────────────────
--
-- Each is the policy that was there before AND ws.can_access_store(storeid).
-- Nothing else about them changes: the same permissions, the same portal
-- carve-outs. THIS is where multi-branch is actually enforced — a client-side
-- filter would be a display preference that any request could ignore.

drop policy if exists deliveries_select on public.ws_tbldeliveries;
create policy deliveries_select on public.ws_tbldeliveries
  for select using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or ((not ws.is_portal(orgid)) and ws.has_perm(orgid, 'delivery.view')))
    and ws.can_access_store(storeid));

drop policy if exists deliveries_write on public.ws_tbldeliveries;
create policy deliveries_write on public.ws_tbldeliveries
  for all using (
    ws.has_perm(orgid, 'delivery.manage') and (not ws.is_portal(orgid))
    and ws.can_access_store(storeid))
  with check (
    ws.has_perm(orgid, 'delivery.manage') and (not ws.is_portal(orgid))
    and ws.can_access_store(storeid));

drop policy if exists payments_select on public.ws_tblpayments;
create policy payments_select on public.ws_tblpayments
  for select using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or ((not ws.is_portal(orgid)) and ws.has_perm(orgid, 'payments.view')))
    and ws.can_access_store(storeid));

drop policy if exists payments_write on public.ws_tblpayments;
create policy payments_write on public.ws_tblpayments
  for all using (
    ws.has_perm(orgid, 'payments.manage') and (not ws.is_portal(orgid))
    and ws.can_access_store(storeid))
  with check (
    ws.has_perm(orgid, 'payments.manage') and (not ws.is_portal(orgid))
    and ws.can_access_store(storeid));

drop policy if exists ws_tblpurchases_select on public.ws_tblpurchases;
create policy ws_tblpurchases_select on public.ws_tblpurchases
  for select using (
    ws.is_member(orgid) and ws.has_perm(orgid, 'purchases.view')
    and ws.can_access_store(storeid));

drop policy if exists ws_tblpurchases_write on public.ws_tblpurchases;
create policy ws_tblpurchases_write on public.ws_tblpurchases
  for all using (
    ws.has_perm(orgid, 'purchases.manage') and ws.can_access_store(storeid))
  with check (
    ws.has_perm(orgid, 'purchases.manage') and ws.can_access_store(storeid));

drop policy if exists ws_tblvendorpayments_select on public.ws_tblvendorpayments;
create policy ws_tblvendorpayments_select on public.ws_tblvendorpayments
  for select using (
    ws.is_member(orgid) and ws.has_perm(orgid, 'purchases.view')
    and ws.can_access_store(storeid));

drop policy if exists ws_tblvendorpayments_write on public.ws_tblvendorpayments;
create policy ws_tblvendorpayments_write on public.ws_tblvendorpayments
  for all using (
    ws.has_perm(orgid, 'purchases.manage') and ws.can_access_store(storeid))
  with check (
    ws.has_perm(orgid, 'purchases.manage') and ws.can_access_store(storeid));

drop policy if exists customers_select on public.ws_tblcustomers;
create policy customers_select on public.ws_tblcustomers
  for select using (
    ws.is_member(orgid)
    and (ws.has_perm(orgid, 'customers.view')
         or customerid = ws.portal_customer_id(orgid))
    and ((not ws.is_portal(orgid)) or customerid = ws.portal_customer_id(orgid))
    and ws.can_access_store(storeid));

drop policy if exists customers_write on public.ws_tblcustomers;
create policy customers_write on public.ws_tblcustomers
  for all using (
    ws.has_perm(orgid, 'customers.manage') and (not ws.is_portal(orgid))
    and ws.can_access_store(storeid))
  with check (
    ws.has_perm(orgid, 'customers.manage') and (not ws.is_portal(orgid))
    and ws.can_access_store(storeid));

drop policy if exists bottletxn_select on public.ws_tblbottletransactions;
create policy bottletxn_select on public.ws_tblbottletransactions
  for select using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or ((not ws.is_portal(orgid)) and ws.has_perm(orgid, 'delivery.view')))
    and ws.can_access_store(storeid));

drop policy if exists bottletxn_insert on public.ws_tblbottletransactions;
create policy bottletxn_insert on public.ws_tblbottletransactions
  for insert with check (
    ws.has_perm(orgid, 'delivery.manage') and (not ws.is_portal(orgid))
    and ws.can_access_store(storeid));


-- ═════════════════════════════════════════════════════════════════════════════
-- 8. THE FOUR POSTING RPCs
-- ═════════════════════════════════════════════════════════════════════════════
-- Each gains p_storeid, defaulted to null so every existing caller keeps
-- working and lands in the default store.
--
-- The old signatures are DROPPED first. A defaulted parameter creates an
-- overload, and a call with the old argument count would match both — the
-- "function is not unique" trap from migrations 010 and 014.

drop function if exists public.ws_record_delivery(bigint,date,integer,integer,bigint,numeric,text,bigint,bigint,text,uuid);
drop function if exists public.ws_record_payment(bigint,numeric,date,text,text,text,uuid);
drop function if exists public.ws_record_purchase(bigint,jsonb,date,text,text,uuid);
drop function if exists public.ws_record_vendor_payment(bigint,numeric,date,bigint,text,text,uuid);


create or replace function public.ws_record_delivery(
  p_customerid    bigint,
  p_deliverydate  date    default current_date,
  p_delivered     int     default 0,
  p_returned      int     default 0,
  p_productid     bigint  default null,
  p_amountpaid    numeric default 0,
  p_paymentmethod text    default 'cash',
  p_deliveredbyid bigint  default null,
  p_routeid       bigint  default null,
  p_notes         text    default null,
  p_clientuuid    uuid    default null,
  p_storeid       bigint  default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org        bigint;
  v_product    bigint;
  v_deliveryid bigint;
  v_methodid   bigint;
  v_storeid    bigint;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'delivery.manage') then
    raise exception 'permission denied: delivery.manage' using errcode = '42501';
  end if;

  -- ── THE IDEMPOTENCY CHECK ──────────────────────────────────────────────
  -- Before anything is written, and before the store is resolved: a retry of
  -- a delivery that already posted returns the original id and must not be
  -- re-pointed at whatever store the caller is in now.
  if p_clientuuid is not null then
    select deliveryid into v_deliveryid
    from public.ws_tbldeliveries
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_deliveryid is not null then
      return v_deliveryid;
    end if;
  end if;

  -- Comes from the ARGUMENTS, never from session state. A document queued in
  -- one branch and synced after the user switched to another still lands in
  -- the branch it was created in.
  v_storeid := ws.resolve_store(v_org, p_storeid);

  v_product := p_productid;
  if v_product is null then
    select p.productid into v_product
    from public.ws_tblproducts p
    join public.ws_tblbottletypes b on b.bottletypeid = p.bottletypeid
    where p.orgid = v_org and p.isactive and b.isdefault
    order by p.productid
    limit 1;
  end if;

  if v_product is null then
    raise exception 'org % has no returnable product configured on its default bottle type', v_org
      using errcode = 'P0002';
  end if;

  insert into public.ws_tbldeliveries
    (orgid, customerid, routeid, deliveredbyid, deliverydate, notes, clientuuid,
     storeid)
  values
    (v_org, p_customerid, p_routeid, p_deliveredbyid, p_deliverydate, p_notes,
     p_clientuuid, v_storeid)
  returning deliveryid into v_deliveryid;

  insert into public.ws_tbldeliverydetails
    (deliveryid, orgid, productid, deliveredqty, returnedqty)
  values
    (v_deliveryid, v_org, v_product, p_delivered, p_returned);

  if coalesce(p_amountpaid, 0) > 0 then
    select methodid into v_methodid
    from public.ws_tblpaymentmethods
    where orgid = v_org and methodcode = coalesce(p_paymentmethod, 'cash');

    insert into public.ws_tblpayments
      (orgid, customerid, deliveryid, receivedbyid, methodid, paymentdate,
       amountreceived, paymentmethod, clientuuid, storeid)
    values
      (v_org, p_customerid, v_deliveryid, p_deliveredbyid, v_methodid, p_deliverydate,
       p_amountpaid, coalesce(p_paymentmethod, 'cash'),
       -- The payment inside a delivery is part of the SAME document, so it
       -- shares the delivery's key rather than needing one of its own. The
       -- unique index is per table, so there is no collision with a standalone
       -- payment that happens to be posted with the same key.
       p_clientuuid,
       -- and the same store, for the same reason.
       v_storeid);
  end if;

  return v_deliveryid;
end
$$;

revoke all on function public.ws_record_delivery(bigint,date,integer,integer,bigint,numeric,text,bigint,bigint,text,uuid,bigint) from public;
grant execute on function public.ws_record_delivery(bigint,date,integer,integer,bigint,numeric,text,bigint,bigint,text,uuid,bigint) to authenticated;


create or replace function public.ws_record_payment(
  p_customerid    bigint,
  p_amount        numeric,
  p_paymentdate   date    default current_date,
  p_paymentmethod text    default 'cash',
  p_referenceno   text    default null,
  p_notes         text    default null,
  p_clientuuid    uuid    default null,
  p_storeid       bigint  default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org       bigint;
  v_paymentid bigint;
  v_methodid  bigint;
  v_storeid   bigint;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'payments.manage') then
    raise exception 'permission denied: payments.manage' using errcode = '42501';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'payment amount must be greater than zero' using errcode = '22023';
  end if;

  if p_clientuuid is not null then
    select paymentid into v_paymentid
    from public.ws_tblpayments
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_paymentid is not null then
      return v_paymentid;
    end if;
  end if;

  v_storeid := ws.resolve_store(v_org, p_storeid);

  select methodid into v_methodid
  from public.ws_tblpaymentmethods
  where orgid = v_org and methodcode = coalesce(p_paymentmethod, 'cash');

  insert into public.ws_tblpayments
    (orgid, customerid, methodid, paymentdate, amountreceived, paymentmethod,
     referenceno, notes, clientuuid, storeid)
  values
    (v_org, p_customerid, v_methodid, p_paymentdate, p_amount,
     coalesce(p_paymentmethod, 'cash'), p_referenceno, p_notes, p_clientuuid,
     v_storeid)
  returning paymentid into v_paymentid;

  return v_paymentid;
end
$$;

revoke all on function public.ws_record_payment(bigint,numeric,date,text,text,text,uuid,bigint) from public;
grant execute on function public.ws_record_payment(bigint,numeric,date,text,text,text,uuid,bigint) to authenticated;


create or replace function public.ws_record_purchase(
  p_vendorid     bigint,
  p_lines        jsonb,
  p_purchasedate date default current_date,
  p_billno       text default null,
  p_notes        text default null,
  p_clientuuid   uuid default null,
  p_storeid      bigint default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org        bigint;
  v_purchaseid bigint;
  v_line       jsonb;
  v_count      int := 0;
  v_qty        numeric;
  v_cost       numeric;
  v_productid  bigint;
  v_storeid    bigint;
begin
  select orgid into v_org from public.ws_tblvendors where vendorid = p_vendorid;
  if v_org is null then
    raise exception 'vendor % not found', p_vendorid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'purchases.manage') then
    raise exception 'permission denied: purchases.manage' using errcode = '42501';
  end if;

  -- ── IDEMPOTENCY CHECK, before anything is written ──────────────────────
  if p_clientuuid is not null then
    select purchaseid into v_purchaseid
    from public.ws_tblpurchases
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_purchaseid is not null then
      return v_purchaseid;
    end if;
  end if;

  -- ── REJECT AN EMPTY DOCUMENT ───────────────────────────────────────────
  if p_lines is null
     or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'a purchase must have at least one line'
      using errcode = '22023';
  end if;

  -- Validate EVERY line before writing any of them, so a bad third line does
  -- not leave the first two posted.
  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    if v_line->>'productid' is null then
      raise exception 'every purchase line needs a productid'
        using errcode = '22023';
    end if;

    v_productid := (v_line->>'productid')::bigint;
    v_qty := coalesce((v_line->>'quantity')::numeric, 0);

    if v_qty <= 0 then
      raise exception 'line for product %: quantity must be greater than zero',
        v_productid using errcode = '22023';
    end if;

    perform ws.assert_same_org(
      v_org,
      (select orgid from public.ws_tblproducts where productid = v_productid),
      'purchase line vs product');
  end loop;

  -- Resolved after validation, before the header: a purchase that is going to
  -- be rejected should not also report a store problem.
  v_storeid := ws.resolve_store(v_org, p_storeid);

  insert into public.ws_tblpurchases
    (orgid, vendorid, purchasedate, billno, notes, clientuuid, createdby, storeid)
  values
    (v_org, p_vendorid, p_purchasedate, p_billno, p_notes, p_clientuuid,
     ws.current_uid(), v_storeid)
  returning purchaseid into v_purchaseid;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_cost := (v_line->>'unitcost')::numeric;   -- null is fine; trigger defaults it

    insert into public.ws_tblpurchasedetails
      (purchaseid, orgid, productid, quantity, unitcost, notes)
    values
      (v_purchaseid,
       v_org,
       (v_line->>'productid')::bigint,
       (v_line->>'quantity')::numeric,
       coalesce(v_cost, 0),
       v_line->>'notes');

    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'no purchase lines were written' using errcode = '22023';
  end if;

  return v_purchaseid;
end
$$;

revoke all on function public.ws_record_purchase(bigint,jsonb,date,text,text,uuid,bigint) from public;
grant execute on function public.ws_record_purchase(bigint,jsonb,date,text,text,uuid,bigint) to authenticated;


create or replace function public.ws_record_vendor_payment(
  p_vendorid    bigint,
  p_amount      numeric,
  p_paiddate    date    default current_date,
  p_purchaseid  bigint  default null,
  p_referenceno text    default null,
  p_notes       text    default null,
  p_clientuuid  uuid    default null,
  p_storeid     bigint  default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org       bigint;
  v_paymentid bigint;
  v_porg      bigint;
  v_storeid   bigint;
begin
  select orgid into v_org from public.ws_tblvendors where vendorid = p_vendorid;
  if v_org is null then
    raise exception 'vendor % not found', p_vendorid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'purchases.manage') then
    raise exception 'permission denied: purchases.manage' using errcode = '42501';
  end if;

  if p_clientuuid is not null then
    select vendorpaymentid into v_paymentid
    from public.ws_tblvendorpayments
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_paymentid is not null then
      return v_paymentid;
    end if;
  end if;

  if coalesce(p_amount, 0) <= 0 then
    raise exception 'vendor payment amount must be greater than zero'
      using errcode = '22023';
  end if;

  if p_purchaseid is not null then
    select orgid into v_porg from public.ws_tblpurchases
    where purchaseid = p_purchaseid;

    if v_porg is null then
      raise exception 'purchase % not found', p_purchaseid using errcode = 'P0002';
    end if;
    perform ws.assert_same_org(v_org, v_porg, 'vendor payment vs purchase');
  end if;

  v_storeid := ws.resolve_store(v_org, p_storeid);

  insert into public.ws_tblvendorpayments
    (orgid, vendorid, purchaseid, paiddate, amountpaid, referenceno, notes,
     clientuuid, createdby, storeid)
  values
    (v_org, p_vendorid, p_purchaseid, p_paiddate, p_amount, p_referenceno,
     p_notes, p_clientuuid, ws.current_uid(), v_storeid)
  returning vendorpaymentid into v_paymentid;

  return v_paymentid;
end
$$;

revoke all on function public.ws_record_vendor_payment(bigint,numeric,date,bigint,text,text,uuid,bigint) from public;
grant execute on function public.ws_record_vendor_payment(bigint,numeric,date,bigint,text,text,uuid,bigint) to authenticated;


-- ─── Customers gain a store too ──────────────────────────────────────────────
-- Same signature shape as migration 014 plus p_storeid at the end, so the old
-- signature is dropped for the usual overload reason.

drop function if exists public.ws_record_customer(bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,numeric,uuid);

create or replace function public.ws_record_customer(
  p_orgid         bigint,
  p_customername  text,
  p_areaid        bigint  default null,
  p_customercode  text    default null,
  p_contactperson text    default null,
  p_phone         text    default null,
  p_email         text    default null,
  p_address       text    default null,
  p_rateoverride  numeric default null,
  p_depositamount numeric default 0,
  p_routeid       bigint  default null,
  p_groupid       bigint  default null,
  p_openingbalance numeric default 0,
  p_clientuuid    uuid    default null,
  p_storeid       bigint  default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_customerid bigint;
  v_areaorg    bigint;
  v_storeid    bigint;
begin
  if not ws.has_perm(p_orgid, 'customers.manage') then
    raise exception 'permission denied: customers.manage' using errcode = '42501';
  end if;

  if p_clientuuid is not null then
    select customerid into v_customerid
    from public.ws_tblcustomers
    where orgid = p_orgid and clientuuid = p_clientuuid;

    if v_customerid is not null then
      return v_customerid;
    end if;
  end if;

  if coalesce(trim(p_customername), '') = '' then
    raise exception 'customer name is required' using errcode = '22023';
  end if;

  if p_areaid is not null then
    select orgid into v_areaorg from public.ws_tblareas where areaid = p_areaid;
    if v_areaorg is null then
      raise exception 'area % not found', p_areaid using errcode = 'P0002';
    end if;
    perform ws.assert_same_org(p_orgid, v_areaorg, 'customer vs area');
  end if;

  v_storeid := ws.resolve_store(p_orgid, p_storeid);

  insert into public.ws_tblcustomers
    (orgid, customername, customercode, areaid, routeid, groupid,
     contactperson, phone, email, address, rateoverride, depositamount,
     openingbalance, clientuuid, storeid)
  values
    (p_orgid, p_customername, p_customercode, p_areaid, p_routeid, p_groupid,
     p_contactperson, p_phone, p_email, p_address, p_rateoverride,
     coalesce(p_depositamount, 0), coalesce(p_openingbalance, 0), p_clientuuid,
     v_storeid)
  returning customerid into v_customerid;

  return v_customerid;
end
$$;

revoke all on function public.ws_record_customer(
  bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,
  numeric,uuid,bigint) from public;
grant execute on function public.ws_record_customer(
  bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,
  numeric,uuid,bigint) to authenticated;


-- =============================================================================
-- VERIFICATION
--
--   select * from public.ws_my_stores(1);
--
--   -- a document lands in the store it was given, not the default
--   select public.ws_record_delivery(p_customerid => 1, p_delivered => 2,
--          p_storeid => <store B>, p_clientuuid => gen_random_uuid());
--   select storeid from public.ws_tbldeliveries order by deliveryid desc limit 1;
--
--   -- every row has a store
--   select count(*) from public.ws_tbldeliveries where storeid is null;  -- 0
--
--   select count(*) from public.vw_ws_reconciliation;                    -- 0
-- =============================================================================


-- =============================================================================
-- ## SECTION 016 — 016_vendor_opening_balance.sql
-- =============================================================================

-- =============================================================================
-- 016_vendor_opening_balance.sql
-- Makes the vendor opening balance an ACCOUNTING fact instead of a loose number.
--
-- ─── WHAT WAS ACTUALLY WRONG (three things, not one) ─────────────────────────
--
-- Both of these were confirmed by running them, not by reading:
--
--   1. THE RAW WRITE. The vendor form writes ws_tblvendors.openingbalance
--      directly, through saveRow and ws_record_vendor. vw_ws_reconciliation
--      computes the AP subsidiary as sum(openingbalance) + purchases −
--      payments, and the GL side from journal lines on the AP control account.
--      A column written with no journal entry therefore moves one side and not
--      the other: reconciliation went 0 → 1 the moment a vendor was saved with
--      an opening balance.
--
--   2. CLEARING IT DID NOT CLEAR THE ENTRY. ws_set_vendor_opening posted a
--      journal entry when the amount was non-zero, but its `if <> 0` had no
--      else branch. Setting 1000 and then 0 left the column at 0 and a 1000
--      payable in the general ledger. ws_set_customer_opening (migration 009)
--      has always deleted the entry in that case; the vendor twin never did.
--
--   3. So the two sources could disagree in EITHER direction, and which one
--      was right depended on which code path last touched the vendor.
--
-- ─── THE FIX: ONE WRITER, REACHED BY EVERY PATH ──────────────────────────────
--
-- The journal is the source of truth and ws_tblvendors.openingbalance is a
-- display copy of it. They cannot drift, because the column no longer posts
-- anything by itself — a TRIGGER does, and the trigger fires whichever way the
-- column is written: the RPC, the form's generic update, a direct SQL insert,
-- or a future code path nobody has written yet.
--
-- That is deliberately stronger than fixing ws_set_vendor_opening alone. Fixing
-- the function would leave saveRow's raw update still able to reintroduce
-- exactly the bug this migration exists to remove.
--
-- ─── DELTA BEHAVIOUR ─────────────────────────────────────────────────────────
--
--        0 → 1000   posts an opening entry of 1000        (AP +1000)
--     1000 → 1000   does nothing at all, no second entry  (AP  +0)
--     1000 →  600   restates the entry to 600             (AP  −400)
--      600 →    0   deletes the entry                     (AP  −600)
--
-- The restatement is how migration 009 already does customers:
-- ws.journal_upsert_header() upserts the header and deletes its lines, so
-- re-posting REPLACES rather than appends. There is one opening entry per
-- vendor, forever, and the movement it causes is exactly the delta. An
-- append-only variant would produce the same balance through a longer trail;
-- restating keeps vendor openings consistent with customer openings, which
-- matters more than the shape of the audit trail for a figure that exists to
-- record where the books started.
--
-- ─── WHAT IS NOT TOUCHED ─────────────────────────────────────────────────────
--
--   · Vendor payments and purchases. Unchanged, and their tests still pass.
--   · The store dimension from 015. Opening entries are organization-level
--     like every other journal entry; the vendor keeps its storeid and this
--     migration does not read or write it.
--   · Customer opening balances.
--   · ws_record_vendor's signature and idempotency.
--
-- ADDITIVE apart from the corrected behaviour: one helper, one trigger, a
-- rewritten ws_set_vendor_opening, and a one-time reconciliation of existing
-- data. Safe to re-run.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. WHAT IS CURRENTLY POSTED
-- ═════════════════════════════════════════════════════════════════════════════
-- Read from the AP control account rather than from the vendor column, because
-- the whole point is that the column may be lying.

create or replace function ws.vendor_opening_posted(
  p_orgid    bigint,
  p_vendorid bigint
)
returns numeric
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select coalesce(sum(d.credit - d.debit), 0)
  from public.ws_tbljournalentrydetails d
  join public.ws_tbljournalentries e on e.journalid = d.journalid
  join public.ws_tblaccounts a on a.accountid = d.accountid
  where e.orgid = p_orgid
    and e.sourcetype = 'opening'
    and e.sourceid = -p_vendorid      -- negative keyspace: see below
    and a.controlfor = 'ap';
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. THE ONLY THING THAT POSTS A VENDOR OPENING BALANCE
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function ws.sync_vendor_opening(
  p_orgid    bigint,
  p_vendorid bigint,
  p_amount   numeric,
  p_asof     date default current_date
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_amount numeric := coalesce(p_amount, 0);
  v_j      bigint;
begin
  if v_amount <> 0 then
    -- Vendor openings live in the NEGATIVE sourceid keyspace so they cannot
    -- collide with customer openings, which share sourcetype 'opening'.
    -- journal_upsert_header upserts on (orgid, sourcetype, sourceid) and then
    -- deletes the existing lines, so this restates rather than appends: one
    -- entry per vendor whatever happens.
    v_j := ws.journal_upsert_header(
             p_orgid, 'opening', -p_vendorid, p_asof,
             'Opening balance for vendor ' || p_vendorid);

    perform ws.journal_line(v_j, p_orgid, ws.account_by_code(p_orgid, '3900'),
                            v_amount, 0, null, p_vendorid,
                            'Opening balance equity');
    perform ws.journal_line(v_j, p_orgid, ws.account_by_control(p_orgid, 'ap'),
                            0, v_amount, null, p_vendorid, 'Opening payable');
  else
    -- ZERO MEANS GONE. This is the branch the old function was missing: it
    -- cleared the column and left the payable standing in the general ledger.
    delete from public.ws_tbljournalentrydetails
    where journalid in (
      select journalid from public.ws_tbljournalentries
      where orgid = p_orgid and sourcetype = 'opening' and sourceid = -p_vendorid
    );
    delete from public.ws_tbljournalentries
    where orgid = p_orgid and sourcetype = 'opening' and sourceid = -p_vendorid;
  end if;
end
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. THE TRIGGER THAT MAKES DRIFT IMPOSSIBLE
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Fires only when the figure actually CHANGES. Saving a vendor again with the
-- same opening balance touches no journal at all — which is what makes a
-- retried Save, or a lost response followed by a retry, produce exactly one
-- entry rather than a second one.

create or replace function ws.tg_vendor_opening_sync()
returns trigger
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(new.openingbalance, 0) <> 0 then
      perform ws.sync_vendor_opening(new.orgid, new.vendorid,
                                     new.openingbalance, current_date);
    end if;
  elsif coalesce(new.openingbalance, 0)
        is distinct from coalesce(old.openingbalance, 0) then
    perform ws.sync_vendor_opening(new.orgid, new.vendorid,
                                   new.openingbalance, current_date);
  end if;
  return null;   -- AFTER trigger; the row is already written
end
$$;

drop trigger if exists trg_vendor_opening_sync on public.ws_tblvendors;
create trigger trg_vendor_opening_sync
  after insert or update of openingbalance on public.ws_tblvendors
  for each row execute function ws.tg_vendor_opening_sync();


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. ws_set_vendor_opening BECOMES A THIN, VALIDATED WRAPPER
-- ═════════════════════════════════════════════════════════════════════════════
-- It no longer posts anything itself. It checks permission, writes the column,
-- and the trigger does the accounting — so this function and the vendor form
-- and a raw UPDATE all produce identical books.
--
-- Same signature, so this replaces rather than overloads and every existing
-- caller keeps working.

create or replace function public.ws_set_vendor_opening(
  p_vendorid bigint,
  p_opening  numeric default 0,
  p_asof     date default current_date
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org     bigint;
  v_current numeric;
begin
  select orgid, coalesce(openingbalance, 0)
    into v_org, v_current
  from public.ws_tblvendors where vendorid = p_vendorid;

  if v_org is null then
    raise exception 'vendor % not found', p_vendorid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'vendors.manage') then
    raise exception 'permission denied: vendors.manage' using errcode = '42501';
  end if;

  -- IDEMPOTENT BY VALUE. Saving the same figure again is a no-op: the update
  -- below would not change the column, so the trigger would not fire, but
  -- returning early makes that explicit rather than incidental.
  if v_current = coalesce(p_opening, 0)
     and ws.vendor_opening_posted(v_org, p_vendorid) = coalesce(p_opening, 0) then
    return;
  end if;

  update public.ws_tblvendors
  set openingbalance = coalesce(p_opening, 0)
  where vendorid = p_vendorid;

  -- Belt and braces for the case where the column already held the right
  -- figure but the ledger did not — the exact state migrations before this one
  -- could leave behind. The update above would not have fired the trigger.
  if v_current = coalesce(p_opening, 0) then
    perform ws.sync_vendor_opening(v_org, p_vendorid, coalesce(p_opening, 0),
                                   p_asof);
  end if;
end
$$;

revoke all on function public.ws_set_vendor_opening(bigint,numeric,date) from public;
grant execute on function public.ws_set_vendor_opening(bigint,numeric,date) to authenticated;


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. RECONCILE THE DATA THAT ALREADY EXISTS
-- ═════════════════════════════════════════════════════════════════════════════
--
-- THE DANGEROUS STEP, and the reason this is delta-based rather than a blanket
-- re-post. Existing vendors are in one of three states:
--
--   · opening set through ws_set_vendor_opening → column AND entry agree.
--     Re-posting would DOUBLE the payable. These must be left alone.
--   · opening written raw by the form → column set, no entry. Needs the entry.
--   · opening cleared to 0 after being set → column 0, entry still standing.
--     Needs the entry removed.
--
-- Comparing what is posted against the column tells the three apart, so only
-- the vendors that actually disagree are touched. The column is taken as the
-- intended figure, because it is what the user last entered and what every
-- screen has been showing them.

do $$
declare
  r        record;
  v_posted numeric;
  v_fixed  int := 0;
begin
  for r in
    select vendorid, orgid, coalesce(openingbalance, 0) as opening
    from public.ws_tblvendors
  loop
    v_posted := ws.vendor_opening_posted(r.orgid, r.vendorid);

    if v_posted is distinct from r.opening then
      perform ws.sync_vendor_opening(r.orgid, r.vendorid, r.opening,
                                     current_date);
      v_fixed := v_fixed + 1;
    end if;
  end loop;

  if v_fixed > 0 then
    raise notice '016: reconciled % vendor opening balance(s) with the ledger',
      v_fixed;
  end if;
end
$$;


-- =============================================================================
-- VERIFICATION
--
--   select public.ws_set_vendor_opening(1, 1000);
--   select ws.vendor_opening_posted(1, 1);              -- 1000
--   select public.ws_set_vendor_opening(1, 1000);       -- no second entry
--   select count(*) from public.ws_tbljournalentries
--    where sourcetype = 'opening' and sourceid = -1;    -- 1
--
--   select public.ws_set_vendor_opening(1, 600);
--   select ws.vendor_opening_posted(1, 1);              -- 600  (AP moved -400)
--
--   select public.ws_set_vendor_opening(1, 0);
--   select ws.vendor_opening_posted(1, 1);              -- 0
--   select count(*) from public.ws_tbljournalentries
--    where sourcetype = 'opening' and sourceid = -1;    -- 0
--
--   select count(*) from public.vw_ws_reconciliation;   -- 0 throughout
--   select count(*) from public.vw_ws_unbalancedentries;-- 0 throughout
-- =============================================================================


-- =============================================================================
-- ## SECTION 017 — 017_customer_opening_balance.sql
-- =============================================================================

-- =============================================================================
-- 017_customer_opening_balance.sql
-- The customer half of the fix migration 016 made for vendors.
--
-- ─── WHAT WAS WRONG, AND HOW IT GOT THERE ────────────────────────────────────
--
-- ws_record_customer (migration 014 — mine) accepts p_openingbalance and writes
-- it straight to the column. vw_ws_customerbalance computes outstandingdue as
--
--     openingbalance + charges - payments
--
-- so the AR subsidiary moves while the general ledger does not, and
-- vw_ws_reconciliation goes from 0 to 1. Confirmed by running it: a customer
-- created with p_openingbalance => 5000 produced an AR opening journal of 0.
--
-- The 014 tests never caught it because every one of them passed
-- p_openingbalance => 0. The parameter existed, was never exercised, and was
-- wrong.
--
-- ─── HOW THIS DIFFERS FROM 016 ───────────────────────────────────────────────
--
-- Two differences, both of which change what needs doing:
--
--   1. ws_set_customer_opening ALREADY deletes the journal entry when the
--      amount is zero. The vendor twin did not, and that was 016's second bug.
--      There is no equivalent defect here, and this migration does not invent
--      one to fix.
--
--   2. ws_set_customer_opening also manages OPENING BOTTLE QUANTITIES, which
--      have nothing to do with money and are already delta-based and correct.
--      That half is reproduced verbatim below. It is the reason this migration
--      rewrites the function rather than reducing it to a one-line wrapper.
--
-- So the only thing being fixed is the direct-write path — but it is fixed the
-- same way, because the same reasoning applies: a trigger owns the posting, so
-- every route to the column produces the same books.
--
-- ─── DELTA BEHAVIOUR (identical to 016) ──────────────────────────────────────
--
--        0 → 1000   posts an opening entry of 1000        (AR +1000)
--     1000 → 1000   does nothing at all, no second entry  (AR  +0)
--     1000 →  600   restates the entry to 600             (AR  -400)
--      600 →    0   deletes the entry                     (AR  -600)
--
-- ─── NOT TOUCHED ─────────────────────────────────────────────────────────────
--
--   · Opening bottle balances — copied through unchanged.
--   · Deliveries, payments, customer CRUD, and editing unrelated fields: an
--     UPDATE that does not change openingbalance does not fire the trigger.
--   · The store dimension from 015. Opening entries are organization-level and
--     this migration neither reads nor writes storeid.
--   · Vendor opening balances (016).
--   · Any import or CSV code. None exists yet, deliberately.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. WHAT IS CURRENTLY POSTED
-- ═════════════════════════════════════════════════════════════════════════════
-- AR is a debit balance, so the posted opening is debit − credit — the mirror
-- of ws.vendor_opening_posted, which reads credit − debit against AP.
--
-- Customer openings use the POSITIVE sourceid keyspace; vendor openings use the
-- negative one. Both share sourcetype 'opening' and must not collide.

create or replace function ws.customer_opening_posted(
  p_orgid      bigint,
  p_customerid bigint
)
returns numeric
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select coalesce(sum(d.debit - d.credit), 0)
  from public.ws_tbljournalentrydetails d
  join public.ws_tbljournalentries e on e.journalid = d.journalid
  join public.ws_tblaccounts a on a.accountid = d.accountid
  where e.orgid = p_orgid
    and e.sourcetype = 'opening'
    and e.sourceid = p_customerid
    and a.controlfor = 'ar';
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. THE ONLY THING THAT POSTS A CUSTOMER OPENING BALANCE
-- ═════════════════════════════════════════════════════════════════════════════
-- Lifted from ws_set_customer_opening's money block so that exactly one piece
-- of code produces these entries. Same accounts, same order, same signs.

create or replace function ws.sync_customer_opening(
  p_orgid      bigint,
  p_customerid bigint,
  p_amount     numeric,
  p_asof       date default current_date
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_amount numeric := coalesce(p_amount, 0);
  v_j      bigint;
begin
  if v_amount <> 0 then
    -- journal_upsert_header upserts on (orgid, sourcetype, sourceid) and then
    -- deletes the existing lines, so this RESTATES rather than appends: one
    -- opening entry per customer, and the movement it causes is the delta.
    v_j := ws.journal_upsert_header(
             p_orgid, 'opening', p_customerid, p_asof,
             'Opening balance for customer ' || p_customerid);

    perform ws.journal_line(v_j, p_orgid, ws.account_by_control(p_orgid, 'ar'),
                            v_amount, 0, p_customerid, null,
                            'Opening receivable');
    perform ws.journal_line(v_j, p_orgid, ws.account_by_code(p_orgid, '3900'),
                            0, v_amount, p_customerid, null,
                            'Opening balance equity');
  else
    -- Clearing the figure clears the entry. This branch already existed in
    -- migration 009 and is preserved exactly.
    delete from public.ws_tbljournalentrydetails
    where journalid in (
      select journalid from public.ws_tbljournalentries
      where orgid = p_orgid and sourcetype = 'opening' and sourceid = p_customerid
    );
    delete from public.ws_tbljournalentries
    where orgid = p_orgid and sourcetype = 'opening' and sourceid = p_customerid;
  end if;
end
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. THE TRIGGER
-- ═════════════════════════════════════════════════════════════════════════════
--
-- `update of openingbalance` plus the is-distinct-from guard means editing a
-- customer's phone, address, rate or area does not touch the ledger — which is
-- the behaviour the CRUD form depends on, since it writes every field back on
-- every save.

create or replace function ws.tg_customer_opening_sync()
returns trigger
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(new.openingbalance, 0) <> 0 then
      perform ws.sync_customer_opening(new.orgid, new.customerid,
                                       new.openingbalance, current_date);
    end if;
  elsif coalesce(new.openingbalance, 0)
        is distinct from coalesce(old.openingbalance, 0) then
    perform ws.sync_customer_opening(new.orgid, new.customerid,
                                     new.openingbalance, current_date);
  end if;
  return null;   -- AFTER trigger; the row is already written
end
$$;

drop trigger if exists trg_customer_opening_sync on public.ws_tblcustomers;
create trigger trg_customer_opening_sync
  after insert or update of openingbalance on public.ws_tblcustomers
  for each row execute function ws.tg_customer_opening_sync();


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. ws_set_customer_opening — MONEY DELEGATED, BOTTLES UNCHANGED
-- ═════════════════════════════════════════════════════════════════════════════
-- Same signature, so this replaces rather than overloads and every existing
-- caller keeps working. The money half no longer posts anything directly: it
-- writes the column and the trigger does the accounting, so this function, the
-- customer form and a raw UPDATE all produce identical books.

create or replace function public.ws_set_customer_opening(
  p_customerid   bigint,
  p_openingdue   numeric default 0,
  p_bottletypeid bigint  default null,
  p_openingqty   int     default 0,
  p_asof         date    default current_date
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org     bigint;
  v_bt      bigint;
  v_posted  int;
  v_delta   int;
  v_current numeric;
begin
  select orgid, coalesce(openingbalance, 0)
    into v_org, v_current
  from public.ws_tblcustomers where customerid = p_customerid;

  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'customers.manage') then
    raise exception 'permission denied: customers.manage' using errcode = '42501';
  end if;

  -- ── MONEY ──────────────────────────────────────────────────────────────
  update public.ws_tblcustomers
  set openingbalance = coalesce(p_openingdue, 0)
  where customerid = p_customerid;

  -- Covers the case where the column already held the right figure but the
  -- ledger did not — the exact state a pre-017 direct write leaves behind. The
  -- update above would not have changed the column, so the trigger would not
  -- have fired.
  if v_current = coalesce(p_openingdue, 0) then
    perform ws.sync_customer_opening(v_org, p_customerid,
                                     coalesce(p_openingdue, 0), p_asof);
  end if;

  -- ── BOTTLES ────────────────────────────────────────────────────────────
  -- Reproduced from migration 009 without modification. Nothing about opening
  -- bottle quantities was wrong, and this migration is about money.
  v_bt := coalesce(p_bottletypeid,
                   (select bottletypeid from public.ws_tblbottletypes
                    where orgid = v_org and isdefault));

  if v_bt is not null then
    v_posted := ws.opening_bottles_posted(v_org, v_bt, p_customerid);
    v_delta  := coalesce(p_openingqty, 0) - v_posted;

    if v_delta <> 0 then
      insert into public.ws_tblbottletransactions
        (orgid, customerid, bottletypeid, txndate, txntype, qty,
         balancebefore, balanceafter, notes, createdby)
      values
        (v_org, p_customerid, v_bt, p_asof, 'opening', v_delta, 0, 0,
         case when v_posted = 0
              then 'Opening bottle balance'
              else format('Opening bottle balance corrected from %s to %s',
                          v_posted, coalesce(p_openingqty, 0))
         end,
         ws.current_uid());
      -- balancebefore/balanceafter are placeholders: ws.tg_bottletxn_compute_balance
      -- overwrites them BEFORE INSERT, under an advisory lock.
    end if;
  end if;
end
$$;

revoke all on function public.ws_set_customer_opening(bigint,numeric,bigint,integer,date) from public;
grant execute on function public.ws_set_customer_opening(bigint,numeric,bigint,integer,date) to authenticated;


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. RECONCILE EXISTING DATA
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Delta-based for the same reason as 016: customers whose opening balance was
-- set through ws_set_customer_opening already have a matching entry, and
-- re-posting them would DOUBLE the receivable. Only the ones that disagree are
-- touched, and the column is taken as the intended figure — it is what the user
-- last entered and what every screen has been showing them.
--
-- That rule was checked, not assumed: the CRUD form pre-populates every field
-- from the loaded row, so editing an unrelated field writes the same opening
-- balance back and changes nothing.

do $$
declare
  r        record;
  v_posted numeric;
  v_fixed  int := 0;
begin
  for r in
    select customerid, orgid, coalesce(openingbalance, 0) as opening
    from public.ws_tblcustomers
  loop
    v_posted := ws.customer_opening_posted(r.orgid, r.customerid);

    if v_posted is distinct from r.opening then
      perform ws.sync_customer_opening(r.orgid, r.customerid, r.opening,
                                       current_date);
      v_fixed := v_fixed + 1;
    end if;
  end loop;

  if v_fixed > 0 then
    raise notice '017: reconciled % customer opening balance(s) with the ledger',
      v_fixed;
  end if;
end
$$;


-- =============================================================================
-- VERIFICATION
--
--   select public.ws_set_customer_opening(1, 1000);
--   select ws.customer_opening_posted(1, 1);            -- 1000
--   select public.ws_set_customer_opening(1, 1000);     -- no second entry
--   select public.ws_set_customer_opening(1, 600);      -- AR moves -400
--   select public.ws_set_customer_opening(1, 0);        -- entry removed
--
--   -- the path that caused all this:
--   select public.ws_record_customer(1, 'X', p_openingbalance => 750,
--          p_clientuuid => gen_random_uuid());
--   select count(*) from public.vw_ws_reconciliation;   -- must be 0
--   select count(*) from public.vw_ws_unbalancedentries;-- must be 0
-- =============================================================================


-- =============================================================================
-- ## SECTION 018 — 018_location_tagging.sql
-- =============================================================================

-- =============================================================================
-- 018_location_tagging.sql
-- Where a customer is, and where a delivery was made.
--
-- ─── ONLY TWO TABLES ─────────────────────────────────────────────────────────
--
-- ws_tblcustomers  — so a driver can find the door.
-- ws_tbldeliveries — so "delivered" has evidence behind it.
--
-- NOT payments, purchases, vendor payments, bottle transactions or journal
-- entries. Adding coordinates to every table because GPS is being introduced
-- would put a column nobody reads on rows nobody geolocates, and each one is
-- another place privacy has to be reasoned about. A payment recorded at the
-- counter has no location question to answer; if one appears later it can have
-- its own migration and its own argument.
--
-- ─── PLAIN NUMERIC, NOT POSTGIS ──────────────────────────────────────────────
--
-- The extension is not available here, and this feature needs to store a point
-- and show it on a map — not index proximity, compute distance or route. Two
-- numerics do that with no extension, no new operator classes and no migration
-- risk. If radius search on thousands of customers is ever wanted, that is when
-- PostGIS earns its place.
--
-- ─── NOTHING BECOMES INVALID ─────────────────────────────────────────────────
--
-- Every column is NULLABLE and no existing row is touched. A customer with no
-- coordinates is a customer whose location was never captured, which is the
-- normal state for every row that exists today and for every one saved by a
-- user who declines the permission. GPS is never required to save anything.
--
-- The CHECK constraints reject impossible coordinates but accept NULL, so they
-- validate new data without invalidating old.
--
-- ADDITIVE: eight nullable columns, four checks, two RPCs gaining three
-- defaulted parameters. Safe to re-run.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. COLUMNS
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare t text;
begin
  foreach t in array array['ws_tblcustomers', 'ws_tbldeliveries']
  loop
    execute format(
      'alter table public.%I '
      '  add column if not exists latitude numeric(9,6), '
      '  add column if not exists longitude numeric(9,6), '
      '  add column if not exists locationaccuracy numeric(7,2), '
      '  add column if not exists locationcapturedat timestamptz', t);

    -- Range checks. NOT NULL is deliberately absent: these accept a row with
    -- no location at all, and only reject a location that cannot exist.
    execute format(
      'alter table public.%I drop constraint if exists ck_%s_latitude', t,
      replace(t, 'ws_tbl', ''));
    execute format(
      'alter table public.%I add constraint ck_%s_latitude '
      'check (latitude is null or (latitude >= -90 and latitude <= 90))',
      t, replace(t, 'ws_tbl', ''));

    execute format(
      'alter table public.%I drop constraint if exists ck_%s_longitude', t,
      replace(t, 'ws_tbl', ''));
    execute format(
      'alter table public.%I add constraint ck_%s_longitude '
      'check (longitude is null or (longitude >= -180 and longitude <= 180))',
      t, replace(t, 'ws_tbl', ''));
  end loop;
end
$$;

comment on column public.ws_tblcustomers.latitude is
  'Where the customer is, captured once when someone pressed the button. Null '
  'means never captured — the normal state, not an error.';

comment on column public.ws_tbldeliveries.locationcapturedat is
  'When the coordinates were read, which is NOT the same as when the delivery '
  'synced. A delivery recorded offline carries the moment it happened.';

-- Finding customers with no location yet is the one query this feature adds.
create index if not exists ix_customer_located
  on public.ws_tblcustomers(orgid) where latitude is not null;


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. ws_record_customer
-- ═════════════════════════════════════════════════════════════════════════════
-- Old signature dropped first: a defaulted parameter creates an overload and a
-- call with the previous argument count would match both. Same trap as 010,
-- 014 and 015.

drop function if exists public.ws_record_customer(bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,numeric,uuid,bigint);

create or replace function public.ws_record_customer(
  p_orgid          bigint,
  p_customername   text,
  p_areaid         bigint  default null,
  p_customercode   text    default null,
  p_contactperson  text    default null,
  p_phone          text    default null,
  p_email          text    default null,
  p_address        text    default null,
  p_rateoverride   numeric default null,
  p_depositamount  numeric default 0,
  p_routeid        bigint  default null,
  p_groupid        bigint  default null,
  p_openingbalance numeric default 0,
  p_clientuuid     uuid    default null,
  p_storeid        bigint  default null,
  p_latitude       numeric default null,
  p_longitude      numeric default null,
  p_accuracy       numeric default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_customerid bigint;
  v_areaorg    bigint;
  v_storeid    bigint;
begin
  if not ws.has_perm(p_orgid, 'customers.manage') then
    raise exception 'permission denied: customers.manage' using errcode = '42501';
  end if;

  if p_clientuuid is not null then
    select customerid into v_customerid
    from public.ws_tblcustomers
    where orgid = p_orgid and clientuuid = p_clientuuid;

    if v_customerid is not null then
      return v_customerid;
    end if;
  end if;

  if coalesce(trim(p_customername), '') = '' then
    raise exception 'customer name is required' using errcode = '22023';
  end if;

  if p_areaid is not null then
    select orgid into v_areaorg from public.ws_tblareas where areaid = p_areaid;
    if v_areaorg is null then
      raise exception 'area % not found', p_areaid using errcode = 'P0002';
    end if;
    perform ws.assert_same_org(p_orgid, v_areaorg, 'customer vs area');
  end if;

  v_storeid := ws.resolve_store(p_orgid, p_storeid);

  insert into public.ws_tblcustomers
    (orgid, customername, customercode, areaid, routeid, groupid,
     contactperson, phone, email, address, rateoverride, depositamount,
     openingbalance, clientuuid, storeid,
     latitude, longitude, locationaccuracy, locationcapturedat)
  values
    (p_orgid, p_customername, p_customercode, p_areaid, p_routeid, p_groupid,
     p_contactperson, p_phone, p_email, p_address, p_rateoverride,
     coalesce(p_depositamount, 0), coalesce(p_openingbalance, 0), p_clientuuid,
     v_storeid,
     p_latitude, p_longitude, p_accuracy,
     -- Stamped only when there is something to stamp.
     case when p_latitude is not null then now() end)
  returning customerid into v_customerid;

  return v_customerid;
end
$$;

revoke all on function public.ws_record_customer(
  bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,
  numeric,uuid,bigint,numeric,numeric,numeric) from public;
grant execute on function public.ws_record_customer(
  bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,
  numeric,uuid,bigint,numeric,numeric,numeric) to authenticated;


-- ─── Updating a customer's location on its own ───────────────────────────────
--
-- Exists so "Capture current location" on an EXISTING customer does not have
-- to send every other field back with it. Passing null for the coordinates
-- clears them, which is the only way a user can undo a capture.

create or replace function public.ws_set_customer_location(
  p_customerid bigint,
  p_latitude   numeric default null,
  p_longitude  numeric default null,
  p_accuracy   numeric default null
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare v_org bigint;
begin
  select orgid into v_org from public.ws_tblcustomers
  where customerid = p_customerid;

  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'customers.manage') then
    raise exception 'permission denied: customers.manage' using errcode = '42501';
  end if;

  -- Half a coordinate is not a location.
  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'latitude and longitude must be given together'
      using errcode = '22023';
  end if;

  update public.ws_tblcustomers
  set latitude = p_latitude,
      longitude = p_longitude,
      locationaccuracy = p_accuracy,
      locationcapturedat = case when p_latitude is not null then now() end
  where customerid = p_customerid;
end
$$;

revoke all on function public.ws_set_customer_location(bigint,numeric,numeric,numeric) from public;
grant execute on function public.ws_set_customer_location(bigint,numeric,numeric,numeric) to authenticated;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. ws_record_delivery
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists public.ws_record_delivery(bigint,date,integer,integer,bigint,numeric,text,bigint,bigint,text,uuid,bigint);

create or replace function public.ws_record_delivery(
  p_customerid    bigint,
  p_deliverydate  date    default current_date,
  p_delivered     int     default 0,
  p_returned      int     default 0,
  p_productid     bigint  default null,
  p_amountpaid    numeric default 0,
  p_paymentmethod text    default 'cash',
  p_deliveredbyid bigint  default null,
  p_routeid       bigint  default null,
  p_notes         text    default null,
  p_clientuuid    uuid    default null,
  p_storeid       bigint  default null,
  p_latitude      numeric default null,
  p_longitude     numeric default null,
  p_accuracy      numeric default null,
  -- WHEN THE READING WAS TAKEN, not when it reached the server. A delivery
  -- queued in a basement and synced two hours later must carry the moment it
  -- actually happened, so the client sends it rather than the server assuming
  -- now().
  p_capturedat    timestamptz default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org        bigint;
  v_product    bigint;
  v_deliveryid bigint;
  v_methodid   bigint;
  v_storeid    bigint;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'delivery.manage') then
    raise exception 'permission denied: delivery.manage' using errcode = '42501';
  end if;

  -- ── THE IDEMPOTENCY CHECK ──────────────────────────────────────────────
  -- Before anything is written, and before the store or the coordinates are
  -- looked at. A RETRY THEREFORE CANNOT MOVE A POSTED DELIVERY: it returns
  -- the original id and ignores everything it was sent, including a different
  -- location.
  if p_clientuuid is not null then
    select deliveryid into v_deliveryid
    from public.ws_tbldeliveries
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_deliveryid is not null then
      return v_deliveryid;
    end if;
  end if;

  v_storeid := ws.resolve_store(v_org, p_storeid);

  v_product := p_productid;
  if v_product is null then
    select p.productid into v_product
    from public.ws_tblproducts p
    join public.ws_tblbottletypes b on b.bottletypeid = p.bottletypeid
    where p.orgid = v_org and p.isactive and b.isdefault
    order by p.productid
    limit 1;
  end if;

  if v_product is null then
    raise exception 'org % has no returnable product configured on its default bottle type', v_org
      using errcode = 'P0002';
  end if;

  insert into public.ws_tbldeliveries
    (orgid, customerid, routeid, deliveredbyid, deliverydate, notes, clientuuid,
     storeid, latitude, longitude, locationaccuracy, locationcapturedat)
  values
    (v_org, p_customerid, p_routeid, p_deliveredbyid, p_deliverydate, p_notes,
     p_clientuuid, v_storeid,
     p_latitude, p_longitude, p_accuracy,
     case when p_latitude is not null
          then coalesce(p_capturedat, now()) end)
  returning deliveryid into v_deliveryid;

  insert into public.ws_tbldeliverydetails
    (deliveryid, orgid, productid, deliveredqty, returnedqty)
  values
    (v_deliveryid, v_org, v_product, p_delivered, p_returned);

  if coalesce(p_amountpaid, 0) > 0 then
    select methodid into v_methodid
    from public.ws_tblpaymentmethods
    where orgid = v_org and methodcode = coalesce(p_paymentmethod, 'cash');

    insert into public.ws_tblpayments
      (orgid, customerid, deliveryid, receivedbyid, methodid, paymentdate,
       amountreceived, paymentmethod, clientuuid, storeid)
    values
      (v_org, p_customerid, v_deliveryid, p_deliveredbyid, v_methodid, p_deliverydate,
       p_amountpaid, coalesce(p_paymentmethod, 'cash'),
       -- The payment inside a delivery is part of the SAME document, so it
       -- shares the delivery's key and store.
       --
       -- It does NOT get the coordinates: the money was handed over at the
       -- same place, so a second copy adds nothing and puts location on a
       -- table this migration deliberately left alone.
       p_clientuuid, v_storeid);
  end if;

  return v_deliveryid;
end
$$;

revoke all on function public.ws_record_delivery(bigint,date,integer,integer,bigint,numeric,text,bigint,bigint,text,uuid,bigint,numeric,numeric,numeric,timestamptz) from public;
grant execute on function public.ws_record_delivery(bigint,date,integer,integer,bigint,numeric,text,bigint,bigint,text,uuid,bigint,numeric,numeric,numeric,timestamptz) to authenticated;


-- =============================================================================
-- VERIFICATION
--
--   -- a delivery with coordinates
--   select public.ws_record_delivery(p_customerid => 1, p_delivered => 2,
--          p_latitude => 24.8607, p_longitude => 67.0011, p_accuracy => 12.5,
--          p_clientuuid => gen_random_uuid());
--
--   -- a retry with DIFFERENT coordinates changes nothing
--   select latitude, longitude from public.ws_tbldeliveries
--    order by deliveryid desc limit 1;
--
--   -- impossible coordinates are refused
--   select public.ws_record_delivery(p_customerid => 1, p_latitude => 999);
--
--   -- and everything without a location still works
--   select public.ws_record_delivery(p_customerid => 1, p_delivered => 1);
--
--   select count(*) from public.vw_ws_reconciliation;            -- 0
-- =============================================================================
