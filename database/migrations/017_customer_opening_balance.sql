-- =============================================================================
-- 017_customer_opening_balance.sql
-- The customer half of the fix migration 016 made for vendors.
--
-- ─── WHAT WAS WRONG, AND HOW IT GOT THERE ────────────────────────────────────
--
-- ws_record_customer (migration 014 — mine) accepts p_openingbalance and writes
-- it straight to the column. vw_ws_customerbalance computes outstandingdue as
--
--     openingbalance + charges - payments
--
-- so the AR subsidiary moves while the general ledger does not, and
-- vw_ws_reconciliation goes from 0 to 1. Confirmed by running it: a customer
-- created with p_openingbalance => 5000 produced an AR opening journal of 0.
--
-- The 014 tests never caught it because every one of them passed
-- p_openingbalance => 0. The parameter existed, was never exercised, and was
-- wrong.
--
-- ─── HOW THIS DIFFERS FROM 016 ───────────────────────────────────────────────
--
-- Two differences, both of which change what needs doing:
--
--   1. ws_set_customer_opening ALREADY deletes the journal entry when the
--      amount is zero. The vendor twin did not, and that was 016's second bug.
--      There is no equivalent defect here, and this migration does not invent
--      one to fix.
--
--   2. ws_set_customer_opening also manages OPENING BOTTLE QUANTITIES, which
--      have nothing to do with money and are already delta-based and correct.
--      That half is reproduced verbatim below. It is the reason this migration
--      rewrites the function rather than reducing it to a one-line wrapper.
--
-- So the only thing being fixed is the direct-write path — but it is fixed the
-- same way, because the same reasoning applies: a trigger owns the posting, so
-- every route to the column produces the same books.
--
-- ─── DELTA BEHAVIOUR (identical to 016) ──────────────────────────────────────
--
--        0 → 1000   posts an opening entry of 1000        (AR +1000)
--     1000 → 1000   does nothing at all, no second entry  (AR  +0)
--     1000 →  600   restates the entry to 600             (AR  -400)
--      600 →    0   deletes the entry                     (AR  -600)
--
-- ─── NOT TOUCHED ─────────────────────────────────────────────────────────────
--
--   · Opening bottle balances — copied through unchanged.
--   · Deliveries, payments, customer CRUD, and editing unrelated fields: an
--     UPDATE that does not change openingbalance does not fire the trigger.
--   · The store dimension from 015. Opening entries are organization-level and
--     this migration neither reads nor writes storeid.
--   · Vendor opening balances (016).
--   · Any import or CSV code. None exists yet, deliberately.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. WHAT IS CURRENTLY POSTED
-- ═════════════════════════════════════════════════════════════════════════════
-- AR is a debit balance, so the posted opening is debit − credit — the mirror
-- of ws.vendor_opening_posted, which reads credit − debit against AP.
--
-- Customer openings use the POSITIVE sourceid keyspace; vendor openings use the
-- negative one. Both share sourcetype 'opening' and must not collide.

create or replace function ws.customer_opening_posted(
  p_orgid      bigint,
  p_customerid bigint
)
returns numeric
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select coalesce(sum(d.debit - d.credit), 0)
  from public.ws_tbljournalentrydetails d
  join public.ws_tbljournalentries e on e.journalid = d.journalid
  join public.ws_tblaccounts a on a.accountid = d.accountid
  where e.orgid = p_orgid
    and e.sourcetype = 'opening'
    and e.sourceid = p_customerid
    and a.controlfor = 'ar';
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. THE ONLY THING THAT POSTS A CUSTOMER OPENING BALANCE
-- ═════════════════════════════════════════════════════════════════════════════
-- Lifted from ws_set_customer_opening's money block so that exactly one piece
-- of code produces these entries. Same accounts, same order, same signs.

create or replace function ws.sync_customer_opening(
  p_orgid      bigint,
  p_customerid bigint,
  p_amount     numeric,
  p_asof       date default current_date
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_amount numeric := coalesce(p_amount, 0);
  v_j      bigint;
begin
  if v_amount <> 0 then
    -- journal_upsert_header upserts on (orgid, sourcetype, sourceid) and then
    -- deletes the existing lines, so this RESTATES rather than appends: one
    -- opening entry per customer, and the movement it causes is the delta.
    v_j := ws.journal_upsert_header(
             p_orgid, 'opening', p_customerid, p_asof,
             'Opening balance for customer ' || p_customerid);

    perform ws.journal_line(v_j, p_orgid, ws.account_by_control(p_orgid, 'ar'),
                            v_amount, 0, p_customerid, null,
                            'Opening receivable');
    perform ws.journal_line(v_j, p_orgid, ws.account_by_code(p_orgid, '3900'),
                            0, v_amount, p_customerid, null,
                            'Opening balance equity');
  else
    -- Clearing the figure clears the entry. This branch already existed in
    -- migration 009 and is preserved exactly.
    delete from public.ws_tbljournalentrydetails
    where journalid in (
      select journalid from public.ws_tbljournalentries
      where orgid = p_orgid and sourcetype = 'opening' and sourceid = p_customerid
    );
    delete from public.ws_tbljournalentries
    where orgid = p_orgid and sourcetype = 'opening' and sourceid = p_customerid;
  end if;
end
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. THE TRIGGER
-- ═════════════════════════════════════════════════════════════════════════════
--
-- `update of openingbalance` plus the is-distinct-from guard means editing a
-- customer's phone, address, rate or area does not touch the ledger — which is
-- the behaviour the CRUD form depends on, since it writes every field back on
-- every save.

create or replace function ws.tg_customer_opening_sync()
returns trigger
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(new.openingbalance, 0) <> 0 then
      perform ws.sync_customer_opening(new.orgid, new.customerid,
                                       new.openingbalance, current_date);
    end if;
  elsif coalesce(new.openingbalance, 0)
        is distinct from coalesce(old.openingbalance, 0) then
    perform ws.sync_customer_opening(new.orgid, new.customerid,
                                     new.openingbalance, current_date);
  end if;
  return null;   -- AFTER trigger; the row is already written
end
$$;

drop trigger if exists trg_customer_opening_sync on public.ws_tblcustomers;
create trigger trg_customer_opening_sync
  after insert or update of openingbalance on public.ws_tblcustomers
  for each row execute function ws.tg_customer_opening_sync();


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. ws_set_customer_opening — MONEY DELEGATED, BOTTLES UNCHANGED
-- ═════════════════════════════════════════════════════════════════════════════
-- Same signature, so this replaces rather than overloads and every existing
-- caller keeps working. The money half no longer posts anything directly: it
-- writes the column and the trigger does the accounting, so this function, the
-- customer form and a raw UPDATE all produce identical books.

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
  v_posted  int;
  v_delta   int;
  v_current numeric;
begin
  select orgid, coalesce(openingbalance, 0)
    into v_org, v_current
  from public.ws_tblcustomers where customerid = p_customerid;

  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'customers.manage') then
    raise exception 'permission denied: customers.manage' using errcode = '42501';
  end if;

  -- ── MONEY ──────────────────────────────────────────────────────────────
  update public.ws_tblcustomers
  set openingbalance = coalesce(p_openingdue, 0)
  where customerid = p_customerid;

  -- Covers the case where the column already held the right figure but the
  -- ledger did not — the exact state a pre-017 direct write leaves behind. The
  -- update above would not have changed the column, so the trigger would not
  -- have fired.
  if v_current = coalesce(p_openingdue, 0) then
    perform ws.sync_customer_opening(v_org, p_customerid,
                                     coalesce(p_openingdue, 0), p_asof);
  end if;

  -- ── BOTTLES ────────────────────────────────────────────────────────────
  -- Reproduced from migration 009 without modification. Nothing about opening
  -- bottle quantities was wrong, and this migration is about money.
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

revoke all on function public.ws_set_customer_opening(bigint,numeric,bigint,integer,date) from public;
grant execute on function public.ws_set_customer_opening(bigint,numeric,bigint,integer,date) to authenticated;


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. RECONCILE EXISTING DATA
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Delta-based for the same reason as 016: customers whose opening balance was
-- set through ws_set_customer_opening already have a matching entry, and
-- re-posting them would DOUBLE the receivable. Only the ones that disagree are
-- touched, and the column is taken as the intended figure — it is what the user
-- last entered and what every screen has been showing them.
--
-- That rule was checked, not assumed: the CRUD form pre-populates every field
-- from the loaded row, so editing an unrelated field writes the same opening
-- balance back and changes nothing.

do $$
declare
  r        record;
  v_posted numeric;
  v_fixed  int := 0;
begin
  for r in
    select customerid, orgid, coalesce(openingbalance, 0) as opening
    from public.ws_tblcustomers
  loop
    v_posted := ws.customer_opening_posted(r.orgid, r.customerid);

    if v_posted is distinct from r.opening then
      perform ws.sync_customer_opening(r.orgid, r.customerid, r.opening,
                                       current_date);
      v_fixed := v_fixed + 1;
    end if;
  end loop;

  if v_fixed > 0 then
    raise notice '017: reconciled % customer opening balance(s) with the ledger',
      v_fixed;
  end if;
end
$$;


-- =============================================================================
-- VERIFICATION
--
--   select public.ws_set_customer_opening(1, 1000);
--   select ws.customer_opening_posted(1, 1);            -- 1000
--   select public.ws_set_customer_opening(1, 1000);     -- no second entry
--   select public.ws_set_customer_opening(1, 600);      -- AR moves -400
--   select public.ws_set_customer_opening(1, 0);        -- entry removed
--
--   -- the path that caused all this:
--   select public.ws_record_customer(1, 'X', p_openingbalance => 750,
--          p_clientuuid => gen_random_uuid());
--   select count(*) from public.vw_ws_reconciliation;   -- must be 0
--   select count(*) from public.vw_ws_unbalancedentries;-- must be 0
-- =============================================================================
