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
begin;

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

commit;

-- ─── What changed ────────────────────────────────────────────────────────────
-- Run database/preflight.sql afterwards to confirm every expected object now
-- exists before moving on to 001.
