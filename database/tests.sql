-- =============================================================================
-- tests.sql
-- Run after migrations + seed. Every check raises on failure, so a clean run
-- means the invariants hold. Exits non-zero under `psql -v ON_ERROR_STOP=1`.
--
--   psql -v ON_ERROR_STOP=1 -f database/tests.sql
--
-- On Supabase these run as `postgres`, which has BYPASSRLS. The RLS section
-- therefore uses `set local role authenticated` to drop those privileges before
-- asserting isolation — without that, every RLS test would pass vacuously.
-- =============================================================================

\set ON_ERROR_STOP on
\timing off

create or replace function ws.expect(p_label text, p_actual anyelement, p_expected anyelement)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL % : expected %, got %', p_label, p_expected, p_actual;
  end if;
  raise notice 'pass  %  = %', p_label, p_actual;
end $$;


-- =============================================================================
-- ⚠  REQUIRES seed.sql. DEVELOPMENT DATABASES ONLY.
--
-- Every assertion below is written against the seed's fixtures — organization
-- ids 1 and 2, customer codes C-001..C-003. Against any other database the
-- numbers are meaningless, and the first failure you see is
--   FAIL card row count : expected 3, got 0
-- which says nothing useful. Fail with an explanation instead.
-- =============================================================================
do $precheck$
begin
  if not exists (
    select 1 from public.ws_tblcustomers
    where customercode = 'C-001' and customername = 'Hotel ABC'
  ) then
    raise exception
      'tests.sql requires the seed fixtures and they are not present. '
      'Run database/seed.sql first, on a SCRATCH database. Do not run either '
      'file against a database that holds real data — the assertions here '
      'target organization id 1, which on your database is your own company.'
      using errcode = 'P0001';
  end if;
end
$precheck$;

-- =============================================================================
-- 1. The delivery card must reproduce the physical card, row for row.
-- =============================================================================
do $$
declare r record; n int := 0;
begin
  for r in
    select entrydate, deliverybottles, receivedbottles, bottlebalance,
           totalamount, amountreceived
    from public.vw_ws_deliverycard
    where customerid = (select customerid from public.ws_tblcustomers where customercode='C-001' and orgid=1)
    order by entrydate
  loop
    n := n + 1;
    if n = 1 then
      perform ws.expect('card 01-07 delivered', r.deliverybottles, 4);
      perform ws.expect('card 01-07 received',  r.receivedbottles, 3);
      perform ws.expect('card 01-07 balance',   r.bottlebalance,   5);
      perform ws.expect('card 01-07 amount',    r.totalamount,     1000.00::numeric);
      perform ws.expect('card 01-07 paid',      r.amountreceived,  1000.00::numeric);
    elsif n = 2 then
      perform ws.expect('card 02-07 delivered', r.deliverybottles, 5);
      perform ws.expect('card 02-07 received',  r.receivedbottles, 3);
      perform ws.expect('card 02-07 balance',   r.bottlebalance,   7);
      perform ws.expect('card 02-07 amount',    r.totalamount,     1250.00::numeric);
      perform ws.expect('card 02-07 paid',      r.amountreceived,  0.00::numeric);
    elsif n = 3 then
      perform ws.expect('card 03-07 delivered', r.deliverybottles, 3);
      perform ws.expect('card 03-07 received',  r.receivedbottles, 4);
      perform ws.expect('card 03-07 balance',   r.bottlebalance,   6);
      perform ws.expect('card 03-07 amount',    r.totalamount,     750.00::numeric);
      perform ws.expect('card 03-07 paid',      r.amountreceived,  750.00::numeric);
    end if;
  end loop;
  perform ws.expect('card row count', n, 3);
end $$;

-- =============================================================================
-- 2. Bottle balance: opening 4 + 12 out - 10 in = 6, per bottle type.
-- =============================================================================
do $$
declare v int;
begin
  select balance into v
  from public.vw_ws_customerbottlebalance
  where customerid = (select customerid from public.ws_tblcustomers where customercode='C-001' and orgid=1)
    and isdefault;
  perform ws.expect('Hotel ABC 19L balance', v, 6);

  -- Legacy cache column must agree with the per-type truth.
  select bottlebalance into v from public.ws_tblcustomers where customercode='C-001' and orgid=1;
  perform ws.expect('legacy bottlebalance cache', v, 6);

  -- The case the single-integer design could not represent: one customer,
  -- two bottle types at once.
  select count(*) into v
  from public.ws_tblcustomerbottlebalances
  where customerid = (select customerid from public.ws_tblcustomers where customercode='C-003' and orgid=1)
    and balance <> 0;
  perform ws.expect('portal customer holds 2 bottle types', v, 2);
end $$;

-- =============================================================================
-- 3. Money: 3,000 charged - 1,750 collected = 1,250 outstanding.
-- =============================================================================
do $$
declare v numeric;
begin
  select outstandingdue into v from public.vw_ws_customerbalance
  where customercode='C-001' and orgid=1;
  perform ws.expect('Hotel ABC outstanding', v, 1250.00::numeric);

  select balance into v from public.vw_ws_customerledger
  where customerid = (select customerid from public.ws_tblcustomers where customercode='C-001' and orgid=1)
  order by txndate desc, sortkey desc limit 1;
  perform ws.expect('ledger closing balance', v, 1250.00::numeric);
end $$;

-- =============================================================================
-- 4. Dynamic pricing precedence: customer > group > area > org default.
-- =============================================================================
do $$
declare v numeric; p bigint;
begin
  select productid into p from public.ws_tblproducts where orgid=1 and productcode='W19';

  -- C-001 has an explicit customer price of 250.
  select ws.resolve_price(1, p,
    (select customerid from public.ws_tblcustomers where customercode='C-001' and orgid=1))
  into v;
  perform ws.expect('price: customer override', v, 250.00::numeric);

  -- C-002 is in the Hotels group: 230.
  select ws.resolve_price(1, p,
    (select customerid from public.ws_tblcustomers where customercode='C-002' and orgid=1))
  into v;
  perform ws.expect('price: group', v, 230.00::numeric);

  -- C-003 has neither: falls through to the org default of 250.
  select ws.resolve_price(1, p,
    (select customerid from public.ws_tblcustomers where customercode='C-003' and orgid=1))
  into v;
  perform ws.expect('price: org default', v, 250.00::numeric);

  -- The group price must have actually been billed, not just resolvable.
  select amountcharged into v from public.ws_tbldeliveries
  where customerid = (select customerid from public.ws_tblcustomers where customercode='C-002' and orgid=1);
  -- 6 x 230 (19L) + 2 x 600 (500ml case, non-returnable) = 2,580
  perform ws.expect('mixed delivery billed at group price', v, 2580.00::numeric);
end $$;

-- =============================================================================
-- 5. Every journal entry balances, and the trial balance nets to zero.
-- =============================================================================
do $$
declare v int; d numeric;
begin
  select count(*) into v from public.vw_ws_unbalancedentries;
  perform ws.expect('unbalanced journal entries', v, 0);

  select sum(totaldebit - totalcredit) into d from public.vw_ws_trialbalance where orgid = 1;
  perform ws.expect('org 1 trial balance nets to zero', coalesce(d,0), 0.00::numeric);

  select sum(totaldebit - totalcredit) into d from public.vw_ws_trialbalance where orgid = 2;
  perform ws.expect('org 2 trial balance nets to zero', coalesce(d,0), 0.00::numeric);

  -- Sales actually posted: 1000 + 1250 + 750 + 2580 + portal delivery.
  select balance into d from public.vw_ws_trialbalance
  where orgid = 1 and accountcode = '4000';
  if d <= 0 then
    raise exception 'FAIL sales account has no credit balance: %', d;
  end if;
  raise notice 'pass  sales account balance = %', d;
end $$;

-- =============================================================================
-- 6. RECONCILIATION — the guard for the journal-derived design. Must be empty.
-- =============================================================================
do $$
declare v int; r record;
begin
  select count(*) into v from public.vw_ws_reconciliation;
  if v <> 0 then
    for r in select * from public.vw_ws_reconciliation loop
      raise warning 'drift: area=% org=% journal=% subsidiary=% diff=%',
        r.area, r.orgid, r.journalbalance, r.subsidiarybalance, r.difference;
    end loop;
    raise exception 'FAIL reconciliation: % row(s) of drift between journal and subsidiary ledgers', v;
  end if;
  raise notice 'pass  reconciliation clean (journal ties to subsidiary ledgers)';
end $$;

-- =============================================================================
-- 7. Bottle transactions are append-only.
-- =============================================================================
do $$
declare v bigint;
begin
  select bottletxnid into v from public.ws_tblbottletransactions limit 1;
  begin
    update public.ws_tblbottletransactions set qty = 999 where bottletxnid = v;
    raise exception 'FAIL append-only: UPDATE on ws_tblbottletransactions succeeded';
  exception when insufficient_privilege then
    raise notice 'pass  bottle transactions reject UPDATE';
  end;
  begin
    delete from public.ws_tblbottletransactions where bottletxnid = v;
    raise exception 'FAIL append-only: DELETE on ws_tblbottletransactions succeeded';
  exception when insufficient_privilege then
    raise notice 'pass  bottle transactions reject DELETE';
  end;
end $$;

-- =============================================================================
-- 8. Cross-tenant references are rejected at the database level.
-- =============================================================================
do $$
declare v_cust2 bigint;
begin
  select customerid into v_cust2 from public.ws_tblcustomers where orgid = 2 limit 1;
  begin
    -- org 1 delivery pointing at an org 2 customer
    insert into public.ws_tbldeliveries (orgid, customerid, deliverydate)
    values (1, v_cust2, current_date);
    raise exception 'FAIL cross-tenant delivery insert succeeded';
  exception when check_violation then
    raise notice 'pass  cross-tenant delivery rejected';
  end;
end $$;

-- =============================================================================
-- 9. An unbalanced manual journal cannot be committed.
-- =============================================================================
do $$
declare v_j bigint;
begin
  begin
    insert into public.ws_tbljournalentries (orgid, sourcetype, sourceid, entrydate, memo)
    values (1, 'manual', 999001, current_date, 'deliberately unbalanced')
    returning journalid into v_j;

    insert into public.ws_tbljournalentrydetails (journalid, orgid, accountid, debit, credit)
    values (v_j, 1, ws.account_by_code(1, '5900'), 500, 0);
    -- No matching credit. The deferred constraint trigger fires here.
    perform 1;
    -- Force the deferred check inside this block.
    set constraints all immediate;
    raise exception 'FAIL unbalanced journal entry was accepted';
  exception when check_violation then
    raise notice 'pass  unbalanced journal entry rejected';
  end;
end $$;

-- =============================================================================
-- 10. Manual journals cannot touch the AR/AP control accounts.
-- =============================================================================
do $$
declare v_j bigint;
begin
  begin
    insert into public.ws_tbljournalentries (orgid, sourcetype, sourceid, entrydate, memo)
    values (1, 'manual', 999002, current_date, 'hand-poking AR')
    returning journalid into v_j;
    insert into public.ws_tbljournalentrydetails (journalid, orgid, accountid, debit, credit)
    values (v_j, 1, ws.account_by_control(1, 'ar'), 100, 0);
    raise exception 'FAIL manual journal wrote to the AR control account';
  exception when insufficient_privilege then
    raise notice 'pass  manual journal blocked from AR control account';
  end;
end $$;

-- =============================================================================
-- 11. The bottle balance cache is honest: rebuilding from history changes nothing.
-- =============================================================================
do $$
declare v int;
begin
  select count(*) into v
  from public.ws_tblcustomerbottlebalances c
  full outer join (
    select customerid, bottletypeid, sum(qty)::int as balance
    from public.ws_tblbottletransactions where customerid is not null
    group by customerid, bottletypeid
  ) t on t.customerid = c.customerid and t.bottletypeid = c.bottletypeid
  where coalesce(c.balance,0) <> coalesce(t.balance,0);
  perform ws.expect('cache matches recomputed history', v, 0);
end $$;

-- =============================================================================
-- 12. ROW LEVEL SECURITY — the isolation the old client-side filter never gave.
-- =============================================================================

-- 12a. Org 1 owner sees only org 1.
do $$
declare v int; uid uuid;
begin
  select id into uid from auth.users where email = 'owner@kentwater.pk';
  perform set_config('ws.test_uid', uid::text, true);
  set local role authenticated;

  select count(*) into v from public.ws_tblcustomers;
  perform ws.expect('RLS owner1 sees own customers only', v, 3);

  select count(*) into v from public.ws_tblcustomers where orgid = 2;
  perform ws.expect('RLS owner1 cannot see org 2 customers', v, 0);

  -- The attack the old design allowed: query with no orgid filter at all.
  select count(*) into v from public.vw_ws_customerbalance;
  perform ws.expect('RLS unfiltered view read is still scoped', v, 3);

  select count(*) into v from public.ws_tbldeliveries where orgid = 2;
  perform ws.expect('RLS owner1 cannot see org 2 deliveries', v, 0);
end $$;
reset role;

-- 12b. Org 2 owner sees only org 2.
do $$
declare v int; uid uuid;
begin
  select id into uid from auth.users where email = 'owner@aquapure.pk';
  perform set_config('ws.test_uid', uid::text, true);
  set local role authenticated;

  select count(*) into v from public.ws_tblcustomers;
  perform ws.expect('RLS owner2 sees own customers only', v, 1);

  select count(*) into v from public.ws_tblorganization;
  perform ws.expect('RLS owner2 sees one organization', v, 1);
end $$;
reset role;

-- 12c. Portal customer sees only its own rows, inside its own org.
do $$
declare v int; uid uuid;
begin
  select id into uid from auth.users where email = 'hotelabc@example.com';
  perform set_config('ws.test_uid', uid::text, true);
  set local role authenticated;

  select count(*) into v from public.ws_tblcustomers;
  perform ws.expect('RLS portal sees only itself', v, 1);

  select count(*) into v from public.ws_tbldeliveries;
  perform ws.expect('RLS portal sees only its own deliveries', v, 1);

  select count(*) into v from public.ws_tblvendors;
  perform ws.expect('RLS portal cannot read vendors', v, 0);

  select count(*) into v from public.ws_tblinternalusers;
  perform ws.expect('RLS portal cannot enumerate staff', v, 0);

  select count(*) into v from public.ws_tbljournalentries;
  perform ws.expect('RLS portal cannot read the journal', v, 0);
end $$;
reset role;

-- 12d. A delivery-role user can record a delivery but not change pricing.
do $$
declare v int; uid uuid;
begin
  select id into uid from auth.users where email = 'ali@kentwater.pk';
  perform set_config('ws.test_uid', uid::text, true);
  set local role authenticated;

  perform ws.expect('driver has delivery.manage', ws.has_perm(1,'delivery.manage'), true);
  perform ws.expect('driver lacks products.manage', ws.has_perm(1,'products.manage'), false);
  perform ws.expect('driver lacks accounting.view', ws.has_perm(1,'accounting.view'), false);

  begin
    update public.ws_tblproducts set saleprice = 1 where orgid = 1;
    if found then
      raise exception 'FAIL driver was able to change product pricing';
    end if;
    raise notice 'pass  driver update on products affected 0 rows';
  exception when insufficient_privilege then
    raise notice 'pass  driver blocked from changing pricing';
  end;
end $$;
reset role;

-- 12e. Anonymous access is nil.
do $$
declare v int;
begin
  perform set_config('ws.test_uid', '', true);
  set local role anon;
  begin
    select count(*) into v from public.ws_tblcustomers;
    raise exception 'FAIL anon could read ws_tblcustomers (got % rows)', v;
  exception when insufficient_privilege then
    raise notice 'pass  anon has no table privilege on ws_tblcustomers';
  end;
end $$;
reset role;

-- =============================================================================
-- 13. Every view enforces RLS (security_invoker). A missing option here would
--     re-open the leak that migration 008 closes.
-- =============================================================================
do $$
declare v int; r record;
begin
  select count(*) into v
  from pg_class c
  where c.relkind = 'v'
    and c.relnamespace = 'public'::regnamespace
    and c.relname like 'vw\_ws%'
    and not coalesce(array_to_string(c.reloptions, ',') like '%security_invoker=%true%', false);
  if v <> 0 then
    for r in
      select relname from pg_class c
      where c.relkind='v' and c.relnamespace='public'::regnamespace and c.relname like 'vw\_ws%'
        and not coalesce(array_to_string(c.reloptions, ',') like '%security_invoker=%true%', false)
    loop
      raise warning 'view % is missing security_invoker=true and bypasses RLS', r.relname;
    end loop;
    raise exception 'FAIL % view(s) bypass RLS', v;
  end if;
  raise notice 'pass  all vw_ws_* views use security_invoker';
end $$;

-- =============================================================================
-- 14. Every tenant table has RLS enabled and at least one policy.
-- =============================================================================
do $$
declare v int; r record;
begin
  select count(*) into v
  from pg_tables t
  join pg_class c on c.relname = t.tablename and c.relnamespace = 'public'::regnamespace
  where t.schemaname = 'public'
    and t.tablename like 'ws\_tbl%'
    and t.tablename not in ('ws_tblpermissions','ws_tblplans')
    and (not c.relrowsecurity
         or not exists (select 1 from pg_policies p
                        where p.schemaname='public' and p.tablename=t.tablename));
  if v <> 0 then
    for r in
      select t.tablename, c.relrowsecurity,
             (select count(*) from pg_policies p where p.schemaname='public' and p.tablename=t.tablename) as policies
      from pg_tables t
      join pg_class c on c.relname=t.tablename and c.relnamespace='public'::regnamespace
      where t.schemaname='public' and t.tablename like 'ws\_tbl%'
        and t.tablename not in ('ws_tblpermissions','ws_tblplans')
        and (not c.relrowsecurity or (select count(*) from pg_policies p
             where p.schemaname='public' and p.tablename=t.tablename) = 0)
    loop
      raise warning 'table % rls=% policies=%', r.tablename, r.relrowsecurity, r.policies;
    end loop;
    raise exception 'FAIL % tenant table(s) unprotected', v;
  end if;
  raise notice 'pass  every tenant table has RLS and policies';
end $$;

-- =============================================================================
-- 15. Document numbering is per-tenant and gapless.
-- =============================================================================
do $$
declare a text; b text;
begin
  select referenceno into a from public.ws_tbldeliveries where orgid=1 order by deliveryid limit 1;
  select referenceno into b from public.ws_tbldeliveries where orgid=2 order by deliveryid limit 1;
  perform ws.expect('org1 first delivery number', a, 'DEL-000001');
  perform ws.expect('org2 numbering restarts',    b, 'DEL-000001');
end $$;

do $$ begin raise notice '=========== ALL TESTS PASSED ==========='; end $$;
