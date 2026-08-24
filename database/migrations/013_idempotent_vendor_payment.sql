-- =============================================================================
-- 013_idempotent_vendor_payment.sql
-- Makes paying a vendor SAFE TO RETRY. The last money write that could not be.
--
-- ─── THE PROBLEM ─────────────────────────────────────────────────────────────
--
-- The client inserts straight into ws_tblvendorpayments. If that insert commits
-- and the response is lost, the retry pays the vendor a second time: a second
-- voucher, a second journal entry, and a payable understated by the duplicate
-- amount. Same failure as deliveries (010), payments (010) and purchases (012);
-- this is the last table without the fix.
--
-- Unlike purchases there is no atomicity problem here — a vendor payment is a
-- single row, and its journal entry is posted by an AFTER trigger in the same
-- transaction. Only idempotency is missing.
--
-- ─── methodid IS DELIBERATELY LEFT NULL ──────────────────────────────────────
--
-- The current client does not set methodid, so every vendor payment recorded so
-- far has a null one. This migration PRESERVES that exactly: no method
-- parameter, no defaulting, no behaviour change.
--
-- That is safe because ws.post_vendor_payment already handles it:
--
--     select accountid into v_acct from ws_tblpaymentmethods where methodid = v_method;
--     v_acct := coalesce(v_acct, ws.account_by_control(v_org, 'cash'));
--
-- A null method falls back to the cash control account, so the journal entry is
-- still correct and balanced. Adding a method parameter would be a business
-- change; this migration is strictly an idempotency change.
--
-- ─── WHAT IS NOT CHANGED ─────────────────────────────────────────────────────
--
--   · ws.post_vendor_payment      — journal logic untouched
--   · ws.tg_vendorpayment_before  — voucherno still from ws.next_docnumber()
--   · ws.tg_vendorpayment_after   — posting trigger untouched
--   · the existing direct-insert client path — still works, unchanged
--
-- PURELY ADDITIVE: one nullable column, one partial index, one new function,
-- plus a fourth branch on the lookup. No data migration. Safe to re-run.
-- =============================================================================

-- ─── 1. Idempotency key ──────────────────────────────────────────────────────

alter table public.ws_tblvendorpayments
  add column if not exists clientuuid uuid;

comment on column public.ws_tblvendorpayments.clientuuid is
  'Client-generated idempotency key. Retries carry the same value so a re-post '
  'returns the existing vendorpaymentid rather than paying the vendor twice.';

-- PARTIAL: rows recorded by the older direct path have a null key, and there
-- may be any number of those. Only non-null keys are constrained.
create unique index if not exists ux_vendorpayment_clientuuid
  on public.ws_tblvendorpayments(orgid, clientuuid)
  where clientuuid is not null;

-- ─── 2. The idempotent recorder ──────────────────────────────────────────────

create or replace function public.ws_record_vendor_payment(
  p_vendorid    bigint,
  p_amount      numeric,
  p_paiddate    date    default current_date,
  p_purchaseid  bigint  default null,
  p_referenceno text    default null,
  p_notes       text    default null,
  p_clientuuid  uuid    default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org      bigint;
  v_paymentid bigint;
  v_porg     bigint;
begin
  select orgid into v_org from public.ws_tblvendors where vendorid = p_vendorid;
  if v_org is null then
    raise exception 'vendor % not found', p_vendorid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'purchases.manage') then
    raise exception 'permission denied: purchases.manage' using errcode = '42501';
  end if;

  -- ── IDEMPOTENCY CHECK, before anything is written ──────────────────────
  -- First write wins. A retry returns the original id and ignores its own
  -- payload, so a corrupted or edited retry cannot change a posted payment.
  if p_clientuuid is not null then
    select vendorpaymentid into v_paymentid
    from public.ws_tblvendorpayments
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_paymentid is not null then
      return v_paymentid;
    end if;
  end if;

  -- ── VALIDATE BEFORE WRITING ────────────────────────────────────────────
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'vendor payment amount must be greater than zero'
      using errcode = '22023';
  end if;

  -- A payment can be tied to a specific purchase. If one is named it must
  -- belong to the same tenant; catching it here beats a foreign-key error
  -- that says nothing about which tenant owns what.
  if p_purchaseid is not null then
    select orgid into v_porg from public.ws_tblpurchases
    where purchaseid = p_purchaseid;

    if v_porg is null then
      raise exception 'purchase % not found', p_purchaseid using errcode = 'P0002';
    end if;
    perform ws.assert_same_org(v_org, v_porg, 'vendor payment vs purchase');
  end if;

  -- ── WRITE ──────────────────────────────────────────────────────────────
  -- methodid is NOT supplied: see the header. voucherno is NOT supplied
  -- either — tg_vendorpayment_before assigns it from ws.next_docnumber() so
  -- numbering stays gapless and per-tenant.
  --
  -- The AFTER trigger posts the journal entry (AP debit / cash credit) inside
  -- this same transaction.
  insert into public.ws_tblvendorpayments
    (orgid, vendorid, purchaseid, paiddate, amountpaid, referenceno, notes,
     clientuuid, createdby)
  values
    (v_org, p_vendorid, p_purchaseid, p_paiddate, p_amount, p_referenceno,
     p_notes, p_clientuuid, ws.current_uid())
  returning vendorpaymentid into v_paymentid;

  return v_paymentid;
end
$$;

revoke all on function public.ws_record_vendor_payment(bigint,numeric,date,bigint,text,text,uuid) from public;
grant execute on function public.ws_record_vendor_payment(bigint,numeric,date,bigint,text,text,uuid) to authenticated;

-- ─── 3. Extend the diagnostic lookup ─────────────────────────────────────────
-- All four document types now resolvable from one key. Still a READ, so it is
-- safe to call against a stuck queue item.

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
    and ws.is_member(pu.orgid)
  union all
  select 'vendorpayment'::text, vp.vendorpaymentid, vp.voucherno, vp.paiddate
  from public.ws_tblvendorpayments vp
  where vp.clientuuid = p_clientuuid
    and ws.is_member(vp.orgid);
$$;

revoke all on function public.ws_lookup_clientuuid(uuid) from public;
grant execute on function public.ws_lookup_clientuuid(uuid) to authenticated;

-- =============================================================================
-- VERIFICATION
--
--   select public.ws_record_vendor_payment(
--     p_vendorid   => 1, p_amount => 500,
--     p_clientuuid => 'aaaaaaaa-1111-2222-3333-444444444444');
--   -- run again: same id, no second voucher
--
--   select count(*) from public.ws_tblvendorpayments
--    where clientuuid = 'aaaaaaaa-1111-2222-3333-444444444444';   -- must be 1
--
--   select * from public.ws_lookup_clientuuid(
--     'aaaaaaaa-1111-2222-3333-444444444444');
--
--   select count(*) from public.vw_ws_reconciliation;             -- must be 0
-- =============================================================================
