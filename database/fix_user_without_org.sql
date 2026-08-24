-- =============================================================================
-- fix_user_without_org.sql
-- Give an existing auth user an organization, so they stop seeing empty screens.
--
-- WHEN YOU NEED THIS
-- A user signed up while Supabase email confirmation was ON. signUp() created
-- the auth row but returned NO SESSION, so ws_create_organization — which needs
-- an authenticated caller — never ran. After confirming their email they can
-- sign in, but they have no organization and no membership, and every RLS
-- policy resolves through ws_tblmemberships. Result: they see nothing.
--
-- Run in the Supabase SQL editor. Change the email and business details.
-- =============================================================================

-- ── 1. Who is affected? Run this first. ──────────────────────────────────────
select
  u.email,
  u.id as auth_uid,
  u.email_confirmed_at,
  u.last_sign_in_at,
  case
    when m.membershipid is null then 'NO ORGANIZATION — needs the fix below'
    else 'ok: ' || o.orgname
  end as status
from auth.users u
left join public.ws_tblmemberships  m on m.authuserid = u.id and m.isactive
left join public.ws_tblorganization o on o.orgid = m.orgid
order by u.created_at desc;


-- ── 2. Create the organization for that user ─────────────────────────────────
-- ws.provision_organization() takes the owner uid explicitly, so it works from
-- the SQL editor where there is no authenticated session. It creates, in one
-- transaction: the organization, seven default roles with their permission
-- sets, the OWNER MEMBERSHIP, the staff record and a trial subscription.

do $$
declare
  v_email   text := 'maslamhussaini@gmail.com';   -- ← change
  v_orgname text := 'My Water Business';          -- ← change
  v_owner   text := 'Owner Name';                 -- ← change
  v_phone   text := '';                           -- ← optional
  v_address text := '';                           -- ← optional
  v_uid     uuid;
  v_orgid   bigint;
begin
  select id into v_uid from auth.users where email = v_email;

  if v_uid is null then
    raise exception 'No auth user with email %. Check the spelling.', v_email;
  end if;

  if exists (select 1 from public.ws_tblmemberships
             where authuserid = v_uid and isactive) then
    raise notice 'User % already has a membership — nothing to do.', v_email;
    return;
  end if;

  v_orgid := ws.provision_organization(
    v_uid, v_orgname, v_owner, v_phone, v_address, 'PKR');

  -- Chart of accounts + payment methods. Without these, recording a payment
  -- fails with "no cash control account configured for org".
  perform ws.seed_chart_of_accounts(v_orgid);

  -- A returnable product on a default bottle type. ws_record_delivery() raises
  -- "no returnable product configured" without one, so the delivery screen
  -- would fail on first use.
  insert into public.ws_tblbottletypes
    (orgid, bottlecode, bottlename, capacitylitres, depositamount, isdefault)
  values (v_orgid, 'BT19', '19 Litre Returnable', 19.0, 0, true);

  insert into public.ws_tblproducts
    (orgid, productcode, productname, producttype, unitlabel, sizelabel,
     capacitylitres, bottletypeid, bottlesperunit, saleprice)
  select v_orgid, 'W19', '19 Litre Mineral Water', 'water', 'Bottle', '19L',
         19.0, bottletypeid, 1, 0
  from public.ws_tblbottletypes
  where orgid = v_orgid and isdefault;

  raise notice 'Created organization % (orgid %) for %', v_orgname, v_orgid, v_email;
  raise notice 'Set the bottle deposit and the 19L price before going live.';
end
$$;


-- ── 3. Confirm ───────────────────────────────────────────────────────────────
-- Re-run query 1. The user should now read "ok: <your business name>".
-- Then sign out and back in inside the app.

-- Set your real price and deposit (both were created as 0):
--   update public.ws_tblproducts    set saleprice     = 250 where orgid = <id> and productcode = 'W19';
--   update public.ws_tblbottletypes set depositamount = 500 where orgid = <id> and isdefault;
