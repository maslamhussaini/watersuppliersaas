-- =============================================================================
-- remove_seed_data.sql
-- Delete the two fictional seed organizations from a real database.
--
-- WHY YOU NEED THIS
-- seed.sql ran against this database before it had a guard. Your auth.users
-- now contains four fictional accounts:
--
--   owner@kentwater.pk       →  Kent Mineral Water
--   ali@kentwater.pk         →  Kent Mineral Water
--   hotelabc@example.com     →  Kent Mineral Water
--   owner@aquapure.pk        →  AquaPure Distributors
--
-- HOW BAD IS IT
-- Not very. Those accounts were inserted with NO password, so nobody can sign
-- in as them, and RLS scopes everything by membership — your own account cannot
-- see any of that data. It is clutter, not a breach. But it will confuse your
-- reporting and your row counts, so clear it before you start entering real
-- work.
--
-- ⚠ THIS SCRIPT DELETES DATA. Read the preview in step 1 before running step 2.
-- =============================================================================

-- ── 1. PREVIEW — what would be removed. Read-only, run this first. ───────────

select
  o.orgid,
  o.orgname,
  (select count(*) from public.ws_tblcustomers   c where c.orgid = o.orgid) as customers,
  (select count(*) from public.ws_tbldeliveries  d where d.orgid = o.orgid) as deliveries,
  (select count(*) from public.ws_tblpayments    p where p.orgid = o.orgid) as payments,
  (select count(*) from public.ws_tblmemberships m where m.orgid = o.orgid) as members
from public.ws_tblorganization o
where o.orgname in ('Kent Mineral Water', 'AquaPure Distributors')
order by o.orgid;

-- ⚠ If either of those names is YOUR real business, stop. Rename your business
--    first, or edit the name list in step 2. The script matches on name only.


-- ── 2. DELETE. Uncomment the block below and run it. ─────────────────────────
--
-- Deletion order matters here and a plain `delete from ws_tblorganization`
-- WILL FAIL. Several child tables use ON DELETE RESTRICT deliberately — you
-- should not be able to remove a customer who still has deliveries or bottle
-- movements against them. And ws_tblbottletransactions is append-only: its
-- trigger raises an exception on any DELETE, which is the whole point of a
-- transaction-based bottle ledger.
--
-- So the script disables that one guard, deletes children before parents, and
-- puts the guard back. It runs in a single transaction: if any part fails,
-- nothing is removed.

/*
do $$
declare
  v_orgids bigint[];
  v_emails text[] := array[
    'owner@kentwater.pk',
    'ali@kentwater.pk',
    'hotelabc@example.com',
    'owner@aquapure.pk'
  ];
  t text;
begin
  select array_agg(orgid) into v_orgids
  from public.ws_tblorganization
  where orgname in ('Kent Mineral Water', 'AquaPure Distributors');

  if v_orgids is null then
    raise notice 'No seed organizations found — nothing to do.';
    return;
  end if;

  raise notice 'Removing organizations %', v_orgids;

  -- The append-only guard would abort the bottle-ledger delete.
  alter table public.ws_tblbottletransactions disable trigger trg_bottletxn_append_only;

  -- Children first, in dependency order. Every one of these tables carries
  -- orgid, which is what makes a per-tenant purge possible at all.
  foreach t in array array[
    'ws_tbljournalentrydetails',
    'ws_tbljournalentries',
    'ws_tblbottletransactions',
    'ws_tblcustomerbottlebalances',
    'ws_tbldeliverydetails',
    'ws_tblpayments',
    'ws_tbldeliveries',
    'ws_tblpurchasedetails',
    'ws_tblvendorpayments',
    'ws_tblpurchases',
    'ws_tblproductprices',
    'ws_tblcustomeraddresses',
    'ws_tblcustomers',
    'ws_tblvendors',
    'ws_tblproducts',
    'ws_tblbottletypes',
    'ws_tblcustomergroups',
    'ws_tblroutes',
    'ws_tblareas',
    'ws_tblpaymentmethods',
    'ws_tblaccounts',
    'ws_tblinternalusers',
    'ws_tblmemberships',
    'ws_tblroles',
    'ws_tblsubscriptionpayments',
    'ws_tblsubscriptions',
    'ws_tbldocumentsequences',
    'ws_tblbottleinventory',
    'ws_tblauditlogs'
  ] loop
    execute format('delete from public.%I where orgid = any($1)', t) using v_orgids;
  end loop;

  delete from public.ws_tblorganization where orgid = any(v_orgids);

  alter table public.ws_tblbottletransactions enable trigger trg_bottletxn_append_only;

  -- The fictional auth accounts. Safe: they have no password and cannot sign in.
  delete from auth.users where email = any(v_emails);

  raise notice 'Seed data removed.';
end
$$;
*/


-- ── 3. Confirm ───────────────────────────────────────────────────────────────
-- Re-run the query in fix_user_without_org.sql step 1. Only your own accounts
-- should remain. These two should still return zero rows:
--
--   select * from public.vw_ws_reconciliation;
--   select * from public.vw_ws_unbalancedentries;
