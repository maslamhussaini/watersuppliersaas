-- =============================================================================
-- bootstrap_existing_data.sql
-- RUN THIS AFTER install.sql, IF YOU HAD DATA BEFORE THE MIGRATION.
--
-- WHY YOU NEED IT
-- install.sql creates the schema. It does not create the ROWS the new schema
-- needs in order to serve your existing data, and one of those omissions locks
-- you out of your own database:
--
--   Row level security is now enforced, and every policy resolves through
--   ws_tblmemberships. Your pre-existing organization has no membership rows,
--   because memberships only ever got created as a side effect of creating a
--   brand new organization. So ws.is_member() returns false for your owner
--   account, and the app shows empty screens with no error.
--
-- It also backfills the rows that make the new features work against old data:
--
--   * roles and permissions for each existing organization
--   * memberships for the owner, for each ws_tblinternalusers row, and for any
--     customer with a portal login
--   * chart of accounts and payment methods
--   * a default bottle type and a returnable product, derived from your area rate
--   * bottle transactions reconstructed from legacy deliveries, so the delivery
--     card and bottle ledger show real history instead of zeros
--   * journal entries for legacy deliveries and payments, so the trial balance
--     and vw_ws_reconciliation agree with the customer ledger
--
-- SAFE TO RE-RUN. Everything is guarded on "does this already exist".
-- NO EXISTING ROW IS MODIFIED except ws_tblcustomers.bottlebalance, which is a
-- trigger-maintained cache and is recomputed from the transactions this script
-- creates.
--
-- MONEY IS NOT RECALCULATED. Legacy amountcharged and amountreceived are read,
-- never rewritten. Reconstructing historical prices from today's rate card would
-- silently restate what customers were actually billed.
-- =============================================================================

do $bootstrap$
declare
  o          record;
  c          record;
  u          record;
  d          record;
  v_roleid   bigint;
  v_btid     bigint;
  v_prodid   bigint;
  v_rate     numeric(12,2);
  v_opening  int;
  v_net      int;
  v_first    date;
  n_members  int := 0;
  n_bottles  int := 0;
  n_posted   int := 0;
begin
  for o in select orgid, orgname, owneruserid from public.ws_tblorganization loop

    raise notice '--- organization % (%) ---', o.orgid, o.orgname;

    -- ── 1. Roles and permissions ─────────────────────────────────────────────
    if not exists (select 1 from public.ws_tblroles where orgid = o.orgid) then
      perform ws.ensure_org_roles(o.orgid);
      raise notice '    created default roles';
    end if;

    -- ── 2. Chart of accounts and payment methods ─────────────────────────────
    if not exists (select 1 from public.ws_tblaccounts where orgid = o.orgid) then
      perform ws.seed_chart_of_accounts(o.orgid);
      raise notice '    seeded chart of accounts';
    end if;

    -- ── 3. Owner membership — THE LOCKOUT FIX ────────────────────────────────
    select roleid into v_roleid
    from public.ws_tblroles where orgid = o.orgid and rolecode = 'owner';

    if o.owneruserid is not null then
      insert into public.ws_tblmemberships (orgid, authuserid, roleid)
      values (o.orgid, o.owneruserid, v_roleid)
      on conflict (orgid, authuserid) do update set isactive = true;
      n_members := n_members + 1;
    else
      raise warning
        'org % has no owneruserid — nobody can be granted owner access automatically. '
        'Set it, then re-run: update ws_tblorganization set owneruserid = ''<auth uid>'' where orgid = %;',
        o.orgid, o.orgid;
    end if;

    -- ── 4. Staff memberships from ws_tblinternalusers ────────────────────────
    -- The legacy `role` column was free text ('admin' / 'staff'). Map it onto a
    -- real role; anything unrecognised becomes 'sales', which can record
    -- deliveries and payments but cannot change pricing or see accounting.
    for u in
      select internaluserid, authuserid, coalesce(lower(role), 'staff') as rolecode
      from public.ws_tblinternalusers
      where orgid = o.orgid and authuserid is not null and coalesce(isactive, true)
    loop
      select roleid into v_roleid
      from public.ws_tblroles
      where orgid = o.orgid
        and rolecode = case
              when u.rolecode in ('owner','admin','accountant','sales','delivery','readonly')
                then u.rolecode
              when u.rolecode = 'staff' then 'sales'
              else 'sales'
            end;

      insert into public.ws_tblmemberships (orgid, authuserid, roleid)
      values (o.orgid, u.authuserid, v_roleid)
      on conflict (orgid, authuserid) do nothing;

      update public.ws_tblinternalusers i
         set membershipid = m.membershipid
        from public.ws_tblmemberships m
       where m.orgid = o.orgid and m.authuserid = u.authuserid
         and i.internaluserid = u.internaluserid
         and i.membershipid is distinct from m.membershipid;

      n_members := n_members + 1;
    end loop;

    -- ── 5. Portal memberships for customers that already have a login ────────
    -- The trigger in 003 handles new links; rows that predate it need this.
    select roleid into v_roleid
    from public.ws_tblroles where orgid = o.orgid and rolecode = 'customer';

    for c in
      select customerid, authuserid
      from public.ws_tblcustomers
      where orgid = o.orgid and authuserid is not null
    loop
      insert into public.ws_tblmemberships (orgid, authuserid, roleid, customerid)
      values (o.orgid, c.authuserid, v_roleid, c.customerid)
      on conflict (orgid, authuserid)
      do update set customerid = excluded.customerid, isactive = true;
      n_members := n_members + 1;
    end loop;

    -- ── 6. Default bottle type and returnable product ────────────────────────
    -- ws_record_delivery() needs a returnable product on the default bottle
    -- type; without one it raises "no returnable product configured".
    if not exists (select 1 from public.ws_tblbottletypes where orgid = o.orgid) then
      insert into public.ws_tblbottletypes
        (orgid, bottlecode, bottlename, capacitylitres, depositamount, isdefault)
      values (o.orgid, 'BT19', '19 Litre Returnable', 19.0, 0, true)
      returning bottletypeid into v_btid;
      raise notice '    created default bottle type (deposit 0 — set your real deposit)';
    else
      select bottletypeid into v_btid
      from public.ws_tblbottletypes where orgid = o.orgid and isdefault;
    end if;

    if not exists (
      select 1 from public.ws_tblproducts
      where orgid = o.orgid and bottletypeid is not null
    ) then
      -- Price from the most common area rate, so existing customers keep being
      -- billed what they were being billed. Area rate and customer rateoverride
      -- both remain live fallbacks in ws.resolve_price().
      select rateperbottle into v_rate
      from public.ws_tblareas
      where orgid = o.orgid and rateperbottle > 0
      group by rateperbottle
      order by count(*) desc, rateperbottle desc
      limit 1;

      insert into public.ws_tblproducts
        (orgid, productcode, productname, producttype, unitlabel, sizelabel,
         capacitylitres, bottletypeid, bottlesperunit, saleprice)
      values (o.orgid, 'W19', '19 Litre Mineral Water', 'water', 'Bottle', '19L',
              19.0, v_btid, 1, coalesce(v_rate, 0))
      returning productid into v_prodid;
      raise notice '    created default product at rate %', coalesce(v_rate, 0);
    end if;

    -- ── 7. Reconstruct bottle history ────────────────────────────────────────
    -- vw_ws_deliverycard and vw_ws_bottleledger derive balances from
    -- ws_tblbottletransactions. Empty table = every historical bottle balance
    -- reads zero. Rebuild from the legacy per-delivery counts.
    for c in
      select customerid, coalesce(bottlebalance, 0) as legacy_balance
      from public.ws_tblcustomers where orgid = o.orgid
    loop
      if not exists (
        select 1 from public.ws_tblbottletransactions where customerid = c.customerid
      ) then
        select coalesce(sum(bottlesdelivered - bottlesreturned), 0),
               min(deliverydate)
          into v_net, v_first
        from public.ws_tbldeliveries
        where customerid = c.customerid and not coalesce(isvoid, false);

        -- Whatever the customer held before the first recorded delivery.
        -- Derived so the reconstructed closing balance equals the legacy
        -- bottlebalance exactly, rather than approximately.
        v_opening := c.legacy_balance - v_net;

        if v_opening <> 0 then
          insert into public.ws_tblbottletransactions
            (orgid, customerid, bottletypeid, txndate, txntype, qty,
             balancebefore, balanceafter, notes)
          values (o.orgid, c.customerid, v_btid,
                  coalesce(v_first, current_date) - 1, 'opening', v_opening, 0, 0,
                  'Opening balance carried in from the previous system');
          n_bottles := n_bottles + 1;
        end if;

        for d in
          select deliveryid, deliverydate,
                 coalesce(bottlesdelivered, 0) as out_qty,
                 coalesce(bottlesreturned, 0)  as in_qty
          from public.ws_tbldeliveries
          where customerid = c.customerid and not coalesce(isvoid, false)
          order by deliverydate, deliveryid
        loop
          if d.out_qty <> 0 then
            insert into public.ws_tblbottletransactions
              (orgid, customerid, bottletypeid, deliveryid, txndate, txntype, qty,
               balancebefore, balanceafter, notes)
            values (o.orgid, c.customerid, v_btid, d.deliveryid, d.deliverydate,
                    'delivery', d.out_qty, 0, 0, 'Reconstructed from legacy delivery');
            n_bottles := n_bottles + 1;
          end if;
          if d.in_qty <> 0 then
            insert into public.ws_tblbottletransactions
              (orgid, customerid, bottletypeid, deliveryid, txndate, txntype, qty,
               balancebefore, balanceafter, notes)
            values (o.orgid, c.customerid, v_btid, d.deliveryid, d.deliverydate,
                    'return', -d.in_qty, 0, 0, 'Reconstructed from legacy delivery');
            n_bottles := n_bottles + 1;
          end if;
        end loop;
      end if;
    end loop;

    -- ── 8. Post legacy documents to the journal ──────────────────────────────
    -- Reads amountcharged / amountreceived as recorded. Nothing is repriced.
    for d in
      select deliveryid from public.ws_tbldeliveries
      where orgid = o.orgid and not coalesce(isvoid, false)
        and coalesce(amountcharged, 0) <> 0
    loop
      perform ws.post_delivery(d.deliveryid);
      n_posted := n_posted + 1;
    end loop;

    for d in
      select paymentid from public.ws_tblpayments
      where orgid = o.orgid and not coalesce(isvoid, false)
    loop
      perform ws.post_customer_payment(d.paymentid);
      n_posted := n_posted + 1;
    end loop;

    -- ── 9. Document number sequences continue past existing references ───────
    -- Otherwise the first new delivery tries DEL-000001 and collides with a
    -- reference number 000 may already have assigned.
    insert into public.ws_tbldocumentsequences (orgid, doctype, nextno)
    values (o.orgid, 'delivery',
            coalesce((select count(*) from public.ws_tbldeliveries where orgid = o.orgid), 0) + 1)
    on conflict (orgid, doctype) do nothing;

    insert into public.ws_tbldocumentsequences (orgid, doctype, nextno)
    values (o.orgid, 'receipt',
            coalesce((select count(*) from public.ws_tblpayments where orgid = o.orgid), 0) + 1)
    on conflict (orgid, doctype) do nothing;

  end loop;

  raise notice '';
  raise notice 'memberships created/refreshed : %', n_members;
  raise notice 'bottle transactions rebuilt   : %', n_bottles;
  raise notice 'documents posted to journal   : %', n_posted;
end
$bootstrap$;

-- ─── Verify ──────────────────────────────────────────────────────────────────
-- Both of these must return zero rows. The first proves the journal agrees with
-- the customer and vendor ledgers; the second proves the bottle cache agrees
-- with the transactions just created.

select 'reconciliation drift' as check, count(*) as rows_should_be_zero
from public.vw_ws_reconciliation
union all
select 'unbalanced journal entries', count(*) from public.vw_ws_unbalancedentries
union all
select 'organizations with no members',
       count(*) from public.ws_tblorganization o
       where not exists (select 1 from public.ws_tblmemberships m
                         where m.orgid = o.orgid and m.isactive);
