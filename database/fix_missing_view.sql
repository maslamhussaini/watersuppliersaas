-- =============================================================================
-- fix_missing_view.sql
-- "Could not find the table 'public.vw_ws_dashboard' in the schema cache"
--
-- That message comes from PostgREST, not Postgres. There are only two causes,
-- and the hint in your error tells them apart: it suggested
-- 'public.vw_ws_deliverycard', which means PostgREST DOES know about the other
-- views from the same migration. So the view is almost certainly present in the
-- database and simply missing from PostgREST's cached schema.
--
-- Step 1 tells you which case you are in. Run it first.
-- =============================================================================

-- ── 1. DIAGNOSE ──────────────────────────────────────────────────────────────
select
  v.name as view_name,
  case when c.oid is null then '✗ DOES NOT EXIST'
       else '✓ exists' end                                    as in_database,
  case when c.oid is null then '—'
       when has_table_privilege('authenticated', c.oid, 'SELECT')
         then '✓ authenticated can select'
       else '✗ NO GRANT — PostgREST hides it' end             as grant_status,
  case when c.oid is null then '—'
       when coalesce(array_to_string(c.reloptions, ',')
            like '%security_invoker=%true%', false)
         then '✓ security_invoker'
       else '✗ BYPASSES RLS' end                              as rls_status
from (values
  ('vw_ws_dashboard'), ('vw_ws_customerbalance'), ('vw_ws_deliverycard'),
  ('vw_ws_customerbottlebalance'), ('vw_ws_bottleledger'), ('vw_ws_bottleposition'),
  ('vw_ws_customerledger'), ('vw_ws_vendorledger'), ('vw_ws_todaydeliveries'),
  ('vw_ws_trialbalance'), ('vw_ws_generalledger'), ('vw_ws_reconciliation'),
  ('vw_ws_unbalancedentries')
) as v(name)
left join pg_class c
  on c.relname = v.name
 and c.relnamespace = 'public'::regnamespace
 and c.relkind = 'v'
order by (c.oid is not null), v.name;


-- ── 2a. IF vw_ws_dashboard SAYS "✓ exists" ───────────────────────────────────
-- PostgREST is serving a stale schema cache. Reload it — instant, no downtime,
-- changes no data. This is the usual answer after creating views in the SQL
-- editor, and it is why the app can read some views but not others.

notify pgrst, 'reload schema';

-- Wait ~5 seconds, then restart the app. If it still fails, the Supabase
-- dashboard has a manual trigger: Settings → API → "Reload schema cache",
-- or pause/resume the project.


-- ── 2b. IF vw_ws_dashboard SAYS "✗ DOES NOT EXIST" ───────────────────────────
-- Migration 007 did not finish. vw_ws_dashboard is the LAST view in that file,
-- so it is the first casualty of any error partway through. Re-run
-- database/install.sql in full — it is idempotent and safe to repeat.
--
-- Or create just this one view now:

/*
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

grant select on public.vw_ws_dashboard to authenticated;
notify pgrst, 'reload schema';
*/


-- ── 3. Set your display name ─────────────────────────────────────────────────
-- The dashboard greeting reads ws_tblinternalusers.fullname. The repair script
-- created your row with the placeholder 'Owner Name' because that was the
-- default in its parameter block.

update public.ws_tblinternalusers
   set fullname = 'Your Real Name'          -- ← change
 where authuserid = (select id from auth.users
                     where email = 'maslamhussaini@gmail.com');

select internaluserid, orgid, fullname, role
from public.ws_tblinternalusers
where authuserid = (select id from auth.users
                    where email = 'maslamhussaini@gmail.com');
