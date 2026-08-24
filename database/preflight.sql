-- =============================================================================
-- preflight.sql
-- "Which objects exist, and which still need creating?"
--
-- Read-only. Creates nothing, changes nothing. Safe to run at any time, on
-- production, as often as you like.
--
-- Paste the whole file into the Supabase SQL editor and run it. It returns ONE
-- result set, ordered worst-first, so anything needing attention is at the top.
--
-- status column:
--   MISSING        the object does not exist  -> the migration that creates it
--                  either has not run or aborted
--   NEEDS COLUMNS  the table exists but is the OLD shape -> run
--                  migrations/000_adopt_existing_schema.sql
--   NO RLS         table exists but row level security is off -> 008 did not run
--   NO POLICIES    RLS is on but no policy exists -> the table is unreadable
--   NOT INVOKER    view is missing security_invoker=true -> it BYPASSES RLS
--   OK             nothing to do
-- =============================================================================

with expected_tables(name, created_by) as (
  values
    ('ws_tblorganization',            '002'),
    ('ws_tblpermissions',             '002'),
    ('ws_tblroles',                   '002'),
    ('ws_tblrolepermissions',         '002'),
    ('ws_tblmemberships',             '002'),
    ('ws_tblinternalusers',           '002'),
    ('ws_tblplans',                   '002'),
    ('ws_tblsubscriptions',           '002'),
    ('ws_tblsubscriptionpayments',    '002'),
    ('ws_tblareas',                   '003'),
    ('ws_tblroutes',                  '003'),
    ('ws_tblbottletypes',             '003'),
    ('ws_tblproducts',                '003'),
    ('ws_tblcustomergroups',          '003'),
    ('ws_tblcustomers',               '003'),
    ('ws_tblcustomeraddresses',       '003'),
    ('ws_tblvendors',                 '003'),
    ('ws_tblpaymentmethods',          '003'),
    ('ws_tblproductprices',           '003'),
    ('ws_tblaccounts',                '004'),
    ('ws_tbljournalentries',          '004'),
    ('ws_tbljournalentrydetails',     '004'),
    ('ws_tbldocumentsequences',       '005'),
    ('ws_tblcustomerbottlebalances',  '005'),
    ('ws_tbldeliveries',              '005'),
    ('ws_tbldeliverydetails',         '005'),
    ('ws_tblbottletransactions',      '005'),
    ('ws_tblbottleinventory',         '005'),
    ('ws_tblpayments',                '005'),
    ('ws_tblpurchases',               '006'),
    ('ws_tblpurchasedetails',         '006'),
    ('ws_tblvendorpayments',          '006'),
    ('ws_tblauditlogs',               '008')
),

expected_views(name, created_by) as (
  values
    ('vw_ws_customerbalance',       '007'),
    ('vw_ws_customerbottlebalance', '007'),
    ('vw_ws_bottleledger',          '007'),
    ('vw_ws_bottleposition',        '007'),
    ('vw_ws_customerledger',        '007'),
    ('vw_ws_vendorledger',          '007'),
    ('vw_ws_deliverycard',          '007'),
    ('vw_ws_todaydeliveries',       '007'),
    ('vw_ws_trialbalance',          '007'),
    ('vw_ws_generalledger',         '007'),
    ('vw_ws_reconciliation',        '007'),
    ('vw_ws_unbalancedentries',     '007'),
    ('vw_ws_dashboard',             '007')
),

-- Functions the rest of the schema calls. A missing one here is why you saw
-- "function ws.is_member(bigint) does not exist": 002 aborted before creating it.
expected_functions(schema_name, name, created_by) as (
  values
    ('ws',     'current_uid',              '001'),
    ('ws',     'assert_same_org',          '001'),
    ('ws',     'member_org_ids',           '002'),
    ('ws',     'is_member',                '002'),
    ('ws',     'portal_customer_id',       '002'),
    ('ws',     'has_perm',                 '002'),
    ('ws',     'provision_organization',   '002'),
    ('public', 'ws_create_organization',   '002'),
    ('ws',     'resolve_price',            '003'),
    ('public', 'ws_resolve_price',         '003'),
    ('ws',     'seed_chart_of_accounts',   '004'),
    ('public', 'ws_seed_chart_of_accounts','004'),
    ('ws',     'account_by_code',          '004'),
    ('ws',     'account_by_control',       '004'),
    ('ws',     'journal_upsert_header',    '004'),
    ('ws',     'journal_line',             '004'),
    ('ws',     'next_docnumber',           '005'),
    ('ws',     'recalc_delivery',          '005'),
    ('ws',     'post_delivery',            '005'),
    ('ws',     'post_customer_payment',    '005'),
    ('public', 'ws_record_delivery',       '005'),
    ('public', 'ws_set_customer_opening',  '005'),
    ('public', 'ws_rebuild_bottle_balances','005'),
    ('ws',     'post_purchase',            '006'),
    ('ws',     'post_vendor_payment',      '006'),
    ('public', 'ws_set_vendor_opening',    '006'),
    ('ws',     'is_portal',                '008')
),

-- Columns added to pre-existing tables by 000. If a table exists but these are
-- absent, 000 has not run and 002/003 will abort on the first reference.
expected_columns(tbl, col, created_by) as (
  values
    ('ws_tblorganization', 'owneruserid',    '000/002'),
    ('ws_tblorganization', 'currencysymbol', '000/002'),
    ('ws_tblorganization', 'cardsettings',   '000/002'),
    ('ws_tblorganization', 'receiptprefix',  '000/002'),
    ('ws_tblcustomers',    'customercode',   '000/003'),
    ('ws_tblcustomers',    'openingbalance', '000/003'),
    ('ws_tblcustomers',    'groupid',        '000/003'),
    ('ws_tblcustomers',    'routeid',        '000/003'),
    ('ws_tbldeliveries',   'referenceno',    '000/005'),
    ('ws_tbldeliveries',   'isvoid',         '000/005'),
    ('ws_tbldeliveries',   'routeid',        '000/005'),
    ('ws_tblpayments',     'receiptno',      '000/005'),
    ('ws_tblpayments',     'methodid',       '000/005'),
    ('ws_tblpayments',     'isvoid',         '000/005'),
    ('ws_tblinternalusers','membershipid',   '000/002')
),

-- ── Assessment ──────────────────────────────────────────────────────────────

table_status as (
  select
    'TABLE'      as kind,
    e.name       as object_name,
    e.created_by as migration,
    case
      when c.oid is null then 'MISSING'
      when exists (
        select 1 from expected_columns x
        where x.tbl = e.name
          and not exists (
            select 1 from information_schema.columns ic
            where ic.table_schema = 'public'
              and ic.table_name = x.tbl
              and ic.column_name = x.col
          )
      ) then 'NEEDS COLUMNS'
      when e.name in ('ws_tblpermissions','ws_tblplans') then 'OK'
      when not c.relrowsecurity then 'NO RLS'
      when not exists (
        select 1 from pg_policies p
        where p.schemaname = 'public' and p.tablename = e.name
      ) then 'NO POLICIES'
      else 'OK'
    end as status,
    case
      when c.oid is null then 'run migrations/' || e.created_by
      else coalesce((
        select string_agg(x.col, ', ' order by x.col)
        from expected_columns x
        where x.tbl = e.name
          and not exists (
            select 1 from information_schema.columns ic
            where ic.table_schema = 'public'
              and ic.table_name = x.tbl and ic.column_name = x.col
          )
      ), '')
    end as detail
  from expected_tables e
  left join pg_class c
    on c.relname = e.name
   and c.relnamespace = 'public'::regnamespace
   and c.relkind = 'r'
),

view_status as (
  select
    'VIEW'       as kind,
    e.name       as object_name,
    e.created_by as migration,
    case
      when c.oid is null then 'MISSING'
      -- A view without security_invoker runs as its OWNER and bypasses RLS
      -- entirely, handing every tenant's rows to any caller.
      when not coalesce(
        array_to_string(c.reloptions, ',') like '%security_invoker=%true%', false
      ) then 'NOT INVOKER'
      else 'OK'
    end as status,
    case when c.oid is null then 'run migrations/' || e.created_by
         else '' end as detail
  from expected_views e
  left join pg_class c
    on c.relname = e.name
   and c.relnamespace = 'public'::regnamespace
   and c.relkind = 'v'
),

function_status as (
  select
    'FUNCTION'   as kind,
    e.schema_name || '.' || e.name as object_name,
    e.created_by as migration,
    case when p.oid is null then 'MISSING' else 'OK' end as status,
    case when p.oid is null then 'run migrations/' || e.created_by
         else '' end as detail
  from expected_functions e
  left join pg_proc p
    on p.proname = e.name
   and p.pronamespace = (
     select oid from pg_namespace where nspname = e.schema_name
   )
),

schema_status as (
  select
    'SCHEMA' as kind,
    'ws'     as object_name,
    '001'    as migration,
    case when exists (select 1 from pg_namespace where nspname = 'ws')
         then 'OK' else 'MISSING' end as status,
    case when exists (select 1 from pg_namespace where nspname = 'ws')
         then '' else 'run migrations/001' end as detail
),

all_status as (
  select * from schema_status
  union all select * from table_status
  union all select * from view_status
  union all select * from function_status
)

select
  case status
    when 'OK' then 'OK'
    else 'ACTION'
  end                       as flag,
  kind,
  object_name,
  status,
  migration                 as from_migration,
  nullif(detail, '')        as missing_or_hint
from all_status
order by
  (status = 'OK'),                       -- problems first
  case status
    when 'MISSING'       then 1
    when 'NEEDS COLUMNS' then 2
    when 'NO RLS'        then 3
    when 'NOT INVOKER'   then 4
    when 'NO POLICIES'   then 5
    else 9
  end,
  kind,
  object_name;

-- =============================================================================
-- Summary. Run this second query for the one-line verdict.
-- =============================================================================
--
--   with t as ( ...paste the CTEs above... )
--   select status, count(*) from all_status group by status order by 2 desc;
--
-- Or more simply, after the migrations have all run these three should each
-- return zero rows:
--
--   select * from public.vw_ws_reconciliation;      -- ledger drift
--   select * from public.vw_ws_unbalancedentries;   -- broken journal entries
--   select relname from pg_class
--    where relkind = 'v' and relnamespace = 'public'::regnamespace
--      and relname like 'vw\_ws%'
--      and not coalesce(array_to_string(reloptions, ',')
--                       like '%security_invoker=%true%', false);
-- =============================================================================
