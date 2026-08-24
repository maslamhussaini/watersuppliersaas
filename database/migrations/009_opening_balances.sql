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
