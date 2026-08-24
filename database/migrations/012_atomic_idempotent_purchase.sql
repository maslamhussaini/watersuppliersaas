-- =============================================================================
-- 012_atomic_idempotent_purchase.sql
-- Makes recording a purchase ATOMIC and SAFE TO RETRY.
--
-- ─── TWO DEFECTS, ONE FIX ────────────────────────────────────────────────────
--
-- The Flutter client currently records a purchase as two separate round trips:
--
--     1. INSERT ws_tblpurchases      (the header)
--     2. INSERT ws_tblpurchasedetails (one line)
--
-- 1. NOT ATOMIC. Every consequence of a purchase — the line amount, the header
--    total, the journal entry, the bottles into stock — is produced by triggers
--    on the DETAIL row, not the header. So if step 2 never happens the database
--    is left holding a purchase with:
--
--       totalamount = 0        no journal entry        no stock movement
--
--    and nothing anywhere says so. The vendor ledger under-states what is owed
--    and inventory under-counts, silently. That is worse than an error: an
--    error gets noticed.
--
-- 2. NOT IDEMPOTENT. If step 1 commits and the response is lost, the retry
--    creates a SECOND purchase — the same failure migrations 010 and 011 fixed
--    for deliveries and payments.
--
-- ─── THE FIX ─────────────────────────────────────────────────────────────────
--
-- One function, therefore one transaction. It checks the idempotency key
-- BEFORE writing, inserts the header, then inserts every line. The existing
-- AFTER trigger fires per line inside that same transaction, so recalc, the
-- journal entry and the stock movement either all land or none do.
--
-- A header with no lines becomes unrepresentable: the function raises on an
-- empty p_lines before it writes anything.
--
-- ─── WHAT IS DELIBERATELY NOT CHANGED ────────────────────────────────────────
--
--   · ws.post_purchase              — journal logic untouched
--   · ws.recalc_purchase            — header total untouched
--   · ws.tg_purchasedetail_prepare  — unitcost default and line amount untouched
--   · ws.tg_purchasedetail_after    — stock movement untouched
--   · referenceno                   — still assigned by the BEFORE trigger on
--                                     the header via ws.next_docnumber()
--   · the existing two-insert client path — still works, unchanged
--
-- No accounting logic is reimplemented here. This function only creates rows in
-- the right order, in one transaction, once.
--
-- PURELY ADDITIVE: one nullable column, one partial index, one new function.
-- No data migration. Safe to re-run.
-- =============================================================================

-- ─── 1. Idempotency key ──────────────────────────────────────────────────────

alter table public.ws_tblpurchases
  add column if not exists clientuuid uuid;

comment on column public.ws_tblpurchases.clientuuid is
  'Client-generated idempotency key. Retries carry the same value so a re-post '
  'returns the existing purchaseid rather than creating a duplicate.';

-- PARTIAL: null means "recorded by the older direct path", and there may be any
-- number of those. Only non-null keys are constrained, so no existing row can
-- violate this.
create unique index if not exists ux_purchase_clientuuid
  on public.ws_tblpurchases(orgid, clientuuid)
  where clientuuid is not null;

-- ─── 2. The atomic, idempotent recorder ──────────────────────────────────────
--
-- p_lines is jsonb:
--
--   '[{"productid": 1, "quantity": 10, "unitcost": 45, "notes": null},
--     {"productid": 2, "quantity":  5}]'
--
-- unitcost and notes are optional per line. Omitting unitcost lets
-- tg_purchasedetail_prepare fall back to ws_tblproducts.purchaseprice, which is
-- the existing behaviour and is preserved exactly.

create or replace function public.ws_record_purchase(
  p_vendorid     bigint,
  p_lines        jsonb,
  p_purchasedate date default current_date,
  p_billno       text default null,
  p_notes        text default null,
  p_clientuuid   uuid default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org        bigint;
  v_purchaseid bigint;
  v_line       jsonb;
  v_count      int := 0;
  v_qty        numeric;
  v_cost       numeric;
  v_productid  bigint;
begin
  select orgid into v_org from public.ws_tblvendors where vendorid = p_vendorid;
  if v_org is null then
    raise exception 'vendor % not found', p_vendorid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'purchases.manage') then
    raise exception 'permission denied: purchases.manage' using errcode = '42501';
  end if;

  -- ── IDEMPOTENCY CHECK, before anything is written ──────────────────────
  -- A retry of a call that already succeeded returns the original id and
  -- touches nothing. The payload of the retry is deliberately ignored: the
  -- first write wins, so a corrupted or edited retry cannot rewrite a posted
  -- document.
  if p_clientuuid is not null then
    select purchaseid into v_purchaseid
    from public.ws_tblpurchases
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_purchaseid is not null then
      return v_purchaseid;
    end if;
  end if;

  -- ── REJECT AN EMPTY DOCUMENT ───────────────────────────────────────────
  -- Checked BEFORE the header insert. A purchase with no lines is the exact
  -- corrupt state this migration exists to prevent: it would produce
  -- totalamount 0, no journal entry and no stock, while looking like a real
  -- record in the list.
  if p_lines is null
     or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'a purchase must have at least one line'
      using errcode = '22023';
  end if;

  -- Validate EVERY line before writing any of them, so a bad third line does
  -- not leave the first two posted. Cheap, and it makes the failure mode
  -- "nothing happened" rather than "half happened".
  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    if v_line->>'productid' is null then
      raise exception 'every purchase line needs a productid'
        using errcode = '22023';
    end if;

    v_productid := (v_line->>'productid')::bigint;
    v_qty := coalesce((v_line->>'quantity')::numeric, 0);

    if v_qty <= 0 then
      raise exception 'line for product %: quantity must be greater than zero',
        v_productid using errcode = '22023';
    end if;

    -- Cross-tenant guard. assert_same_org runs in the detail trigger too, but
    -- catching it here means the header is never created for a doomed line.
    perform ws.assert_same_org(
      v_org,
      (select orgid from public.ws_tblproducts where productid = v_productid),
      'purchase line vs product');
  end loop;

  -- ── HEADER ─────────────────────────────────────────────────────────────
  -- referenceno is NOT supplied: the BEFORE trigger on this table assigns it
  -- from ws.next_docnumber(orgid, 'purchase') so numbering stays gapless and
  -- per-tenant. A client-supplied number would race.
  insert into public.ws_tblpurchases
    (orgid, vendorid, purchasedate, billno, notes, clientuuid, createdby)
  values
    (v_org, p_vendorid, p_purchasedate, p_billno, p_notes, p_clientuuid,
     ws.current_uid())
  returning purchaseid into v_purchaseid;

  -- ── LINES ──────────────────────────────────────────────────────────────
  -- Same transaction. Each insert fires tg_purchasedetail_prepare (unitcost
  -- default, line amount) and tg_purchasedetail_after (recalc header total,
  -- post the journal entry, move bottles into stock).
  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_cost := (v_line->>'unitcost')::numeric;   -- null is fine; trigger defaults it

    insert into public.ws_tblpurchasedetails
      (purchaseid, orgid, productid, quantity, unitcost, notes)
    values
      (v_purchaseid,
       v_org,
       (v_line->>'productid')::bigint,
       (v_line->>'quantity')::numeric,
       coalesce(v_cost, 0),
       v_line->>'notes');

    v_count := v_count + 1;
  end loop;

  -- Belt and braces. If this ever fires, the loop above silently wrote
  -- nothing and we would rather roll back than return a header id for an
  -- empty purchase.
  if v_count = 0 then
    raise exception 'no purchase lines were written' using errcode = '22023';
  end if;

  return v_purchaseid;
end
$$;

revoke all on function public.ws_record_purchase(bigint,jsonb,date,text,text,uuid) from public;
grant execute on function public.ws_record_purchase(bigint,jsonb,date,text,text,uuid) to authenticated;

-- ─── 3. Extend the diagnostic lookup to purchases ────────────────────────────
-- Same read-only "did this actually land?" question, now covering all three
-- document types. Still a READ: safe to call against a stuck queue item.

create or replace function public.ws_lookup_clientuuid(p_clientuuid uuid)
returns table (doctype text, docid bigint, docnumber text, docdate date)
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select 'delivery'::text, d.deliveryid, d.referenceno, d.deliverydate
  from public.ws_tbldeliveries d
  where d.clientuuid = p_clientuuid
    and ws.is_member(d.orgid)
  union all
  select 'payment'::text, p.paymentid, p.receiptno, p.paymentdate
  from public.ws_tblpayments p
  where p.clientuuid = p_clientuuid
    and ws.is_member(p.orgid)
  union all
  select 'purchase'::text, pu.purchaseid, pu.referenceno, pu.purchasedate
  from public.ws_tblpurchases pu
  where pu.clientuuid = p_clientuuid
    and ws.is_member(pu.orgid);
$$;

revoke all on function public.ws_lookup_clientuuid(uuid) from public;
grant execute on function public.ws_lookup_clientuuid(uuid) to authenticated;

-- =============================================================================
-- VERIFICATION
--
--   -- single line (what the current UI sends)
--   select public.ws_record_purchase(
--     p_vendorid   => 1,
--     p_lines      => '[{"productid":1,"quantity":10,"unitcost":45}]'::jsonb,
--     p_clientuuid => '88888888-8888-8888-8888-888888888888');
--
--   -- run it again: same id, no second document
--
--   -- multi-line
--   select public.ws_record_purchase(
--     p_vendorid => 1,
--     p_lines    => '[{"productid":1,"quantity":10,"unitcost":45},
--                     {"productid":1,"quantity":5,"unitcost":50}]'::jsonb);
--
--   -- empty must RAISE, and must leave no header behind
--   select public.ws_record_purchase(p_vendorid => 1, p_lines => '[]'::jsonb);
--
--   select count(*) from public.vw_ws_reconciliation;   -- must be 0
-- =============================================================================
