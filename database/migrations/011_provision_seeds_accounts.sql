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
