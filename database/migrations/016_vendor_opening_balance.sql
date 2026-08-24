-- =============================================================================
-- 016_vendor_opening_balance.sql
-- Makes the vendor opening balance an ACCOUNTING fact instead of a loose number.
--
-- ─── WHAT WAS ACTUALLY WRONG (three things, not one) ─────────────────────────
--
-- Both of these were confirmed by running them, not by reading:
--
--   1. THE RAW WRITE. The vendor form writes ws_tblvendors.openingbalance
--      directly, through saveRow and ws_record_vendor. vw_ws_reconciliation
--      computes the AP subsidiary as sum(openingbalance) + purchases −
--      payments, and the GL side from journal lines on the AP control account.
--      A column written with no journal entry therefore moves one side and not
--      the other: reconciliation went 0 → 1 the moment a vendor was saved with
--      an opening balance.
--
--   2. CLEARING IT DID NOT CLEAR THE ENTRY. ws_set_vendor_opening posted a
--      journal entry when the amount was non-zero, but its `if <> 0` had no
--      else branch. Setting 1000 and then 0 left the column at 0 and a 1000
--      payable in the general ledger. ws_set_customer_opening (migration 009)
--      has always deleted the entry in that case; the vendor twin never did.
--
--   3. So the two sources could disagree in EITHER direction, and which one
--      was right depended on which code path last touched the vendor.
--
-- ─── THE FIX: ONE WRITER, REACHED BY EVERY PATH ──────────────────────────────
--
-- The journal is the source of truth and ws_tblvendors.openingbalance is a
-- display copy of it. They cannot drift, because the column no longer posts
-- anything by itself — a TRIGGER does, and the trigger fires whichever way the
-- column is written: the RPC, the form's generic update, a direct SQL insert,
-- or a future code path nobody has written yet.
--
-- That is deliberately stronger than fixing ws_set_vendor_opening alone. Fixing
-- the function would leave saveRow's raw update still able to reintroduce
-- exactly the bug this migration exists to remove.
--
-- ─── DELTA BEHAVIOUR ─────────────────────────────────────────────────────────
--
--        0 → 1000   posts an opening entry of 1000        (AP +1000)
--     1000 → 1000   does nothing at all, no second entry  (AP  +0)
--     1000 →  600   restates the entry to 600             (AP  −400)
--      600 →    0   deletes the entry                     (AP  −600)
--
-- The restatement is how migration 009 already does customers:
-- ws.journal_upsert_header() upserts the header and deletes its lines, so
-- re-posting REPLACES rather than appends. There is one opening entry per
-- vendor, forever, and the movement it causes is exactly the delta. An
-- append-only variant would produce the same balance through a longer trail;
-- restating keeps vendor openings consistent with customer openings, which
-- matters more than the shape of the audit trail for a figure that exists to
-- record where the books started.
--
-- ─── WHAT IS NOT TOUCHED ─────────────────────────────────────────────────────
--
--   · Vendor payments and purchases. Unchanged, and their tests still pass.
--   · The store dimension from 015. Opening entries are organization-level
--     like every other journal entry; the vendor keeps its storeid and this
--     migration does not read or write it.
--   · Customer opening balances.
--   · ws_record_vendor's signature and idempotency.
--
-- ADDITIVE apart from the corrected behaviour: one helper, one trigger, a
-- rewritten ws_set_vendor_opening, and a one-time reconciliation of existing
-- data. Safe to re-run.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. WHAT IS CURRENTLY POSTED
-- ═════════════════════════════════════════════════════════════════════════════
-- Read from the AP control account rather than from the vendor column, because
-- the whole point is that the column may be lying.

create or replace function ws.vendor_opening_posted(
  p_orgid    bigint,
  p_vendorid bigint
)
returns numeric
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select coalesce(sum(d.credit - d.debit), 0)
  from public.ws_tbljournalentrydetails d
  join public.ws_tbljournalentries e on e.journalid = d.journalid
  join public.ws_tblaccounts a on a.accountid = d.accountid
  where e.orgid = p_orgid
    and e.sourcetype = 'opening'
    and e.sourceid = -p_vendorid      -- negative keyspace: see below
    and a.controlfor = 'ap';
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. THE ONLY THING THAT POSTS A VENDOR OPENING BALANCE
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function ws.sync_vendor_opening(
  p_orgid    bigint,
  p_vendorid bigint,
  p_amount   numeric,
  p_asof     date default current_date
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
    -- Vendor openings live in the NEGATIVE sourceid keyspace so they cannot
    -- collide with customer openings, which share sourcetype 'opening'.
    -- journal_upsert_header upserts on (orgid, sourcetype, sourceid) and then
    -- deletes the existing lines, so this restates rather than appends: one
    -- entry per vendor whatever happens.
    v_j := ws.journal_upsert_header(
             p_orgid, 'opening', -p_vendorid, p_asof,
             'Opening balance for vendor ' || p_vendorid);

    perform ws.journal_line(v_j, p_orgid, ws.account_by_code(p_orgid, '3900'),
                            v_amount, 0, null, p_vendorid,
                            'Opening balance equity');
    perform ws.journal_line(v_j, p_orgid, ws.account_by_control(p_orgid, 'ap'),
                            0, v_amount, null, p_vendorid, 'Opening payable');
  else
    -- ZERO MEANS GONE. This is the branch the old function was missing: it
    -- cleared the column and left the payable standing in the general ledger.
    delete from public.ws_tbljournalentrydetails
    where journalid in (
      select journalid from public.ws_tbljournalentries
      where orgid = p_orgid and sourcetype = 'opening' and sourceid = -p_vendorid
    );
    delete from public.ws_tbljournalentries
    where orgid = p_orgid and sourcetype = 'opening' and sourceid = -p_vendorid;
  end if;
end
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. THE TRIGGER THAT MAKES DRIFT IMPOSSIBLE
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Fires only when the figure actually CHANGES. Saving a vendor again with the
-- same opening balance touches no journal at all — which is what makes a
-- retried Save, or a lost response followed by a retry, produce exactly one
-- entry rather than a second one.

create or replace function ws.tg_vendor_opening_sync()
returns trigger
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(new.openingbalance, 0) <> 0 then
      perform ws.sync_vendor_opening(new.orgid, new.vendorid,
                                     new.openingbalance, current_date);
    end if;
  elsif coalesce(new.openingbalance, 0)
        is distinct from coalesce(old.openingbalance, 0) then
    perform ws.sync_vendor_opening(new.orgid, new.vendorid,
                                   new.openingbalance, current_date);
  end if;
  return null;   -- AFTER trigger; the row is already written
end
$$;

drop trigger if exists trg_vendor_opening_sync on public.ws_tblvendors;
create trigger trg_vendor_opening_sync
  after insert or update of openingbalance on public.ws_tblvendors
  for each row execute function ws.tg_vendor_opening_sync();


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. ws_set_vendor_opening BECOMES A THIN, VALIDATED WRAPPER
-- ═════════════════════════════════════════════════════════════════════════════
-- It no longer posts anything itself. It checks permission, writes the column,
-- and the trigger does the accounting — so this function and the vendor form
-- and a raw UPDATE all produce identical books.
--
-- Same signature, so this replaces rather than overloads and every existing
-- caller keeps working.

create or replace function public.ws_set_vendor_opening(
  p_vendorid bigint,
  p_opening  numeric default 0,
  p_asof     date default current_date
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org     bigint;
  v_current numeric;
begin
  select orgid, coalesce(openingbalance, 0)
    into v_org, v_current
  from public.ws_tblvendors where vendorid = p_vendorid;

  if v_org is null then
    raise exception 'vendor % not found', p_vendorid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'vendors.manage') then
    raise exception 'permission denied: vendors.manage' using errcode = '42501';
  end if;

  -- IDEMPOTENT BY VALUE. Saving the same figure again is a no-op: the update
  -- below would not change the column, so the trigger would not fire, but
  -- returning early makes that explicit rather than incidental.
  if v_current = coalesce(p_opening, 0)
     and ws.vendor_opening_posted(v_org, p_vendorid) = coalesce(p_opening, 0) then
    return;
  end if;

  update public.ws_tblvendors
  set openingbalance = coalesce(p_opening, 0)
  where vendorid = p_vendorid;

  -- Belt and braces for the case where the column already held the right
  -- figure but the ledger did not — the exact state migrations before this one
  -- could leave behind. The update above would not have fired the trigger.
  if v_current = coalesce(p_opening, 0) then
    perform ws.sync_vendor_opening(v_org, p_vendorid, coalesce(p_opening, 0),
                                   p_asof);
  end if;
end
$$;

revoke all on function public.ws_set_vendor_opening(bigint,numeric,date) from public;
grant execute on function public.ws_set_vendor_opening(bigint,numeric,date) to authenticated;


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. RECONCILE THE DATA THAT ALREADY EXISTS
-- ═════════════════════════════════════════════════════════════════════════════
--
-- THE DANGEROUS STEP, and the reason this is delta-based rather than a blanket
-- re-post. Existing vendors are in one of three states:
--
--   · opening set through ws_set_vendor_opening → column AND entry agree.
--     Re-posting would DOUBLE the payable. These must be left alone.
--   · opening written raw by the form → column set, no entry. Needs the entry.
--   · opening cleared to 0 after being set → column 0, entry still standing.
--     Needs the entry removed.
--
-- Comparing what is posted against the column tells the three apart, so only
-- the vendors that actually disagree are touched. The column is taken as the
-- intended figure, because it is what the user last entered and what every
-- screen has been showing them.

do $$
declare
  r        record;
  v_posted numeric;
  v_fixed  int := 0;
begin
  for r in
    select vendorid, orgid, coalesce(openingbalance, 0) as opening
    from public.ws_tblvendors
  loop
    v_posted := ws.vendor_opening_posted(r.orgid, r.vendorid);

    if v_posted is distinct from r.opening then
      perform ws.sync_vendor_opening(r.orgid, r.vendorid, r.opening,
                                     current_date);
      v_fixed := v_fixed + 1;
    end if;
  end loop;

  if v_fixed > 0 then
    raise notice '016: reconciled % vendor opening balance(s) with the ledger',
      v_fixed;
  end if;
end
$$;


-- =============================================================================
-- VERIFICATION
--
--   select public.ws_set_vendor_opening(1, 1000);
--   select ws.vendor_opening_posted(1, 1);              -- 1000
--   select public.ws_set_vendor_opening(1, 1000);       -- no second entry
--   select count(*) from public.ws_tbljournalentries
--    where sourcetype = 'opening' and sourceid = -1;    -- 1
--
--   select public.ws_set_vendor_opening(1, 600);
--   select ws.vendor_opening_posted(1, 1);              -- 600  (AP moved -400)
--
--   select public.ws_set_vendor_opening(1, 0);
--   select ws.vendor_opening_posted(1, 1);              -- 0
--   select count(*) from public.ws_tbljournalentries
--    where sourcetype = 'opening' and sourceid = -1;    -- 0
--
--   select count(*) from public.vw_ws_reconciliation;   -- 0 throughout
--   select count(*) from public.vw_ws_unbalancedentries;-- 0 throughout
-- =============================================================================
