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
