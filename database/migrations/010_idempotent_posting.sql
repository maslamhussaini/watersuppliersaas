-- =============================================================================
-- 010_idempotent_posting.sql
-- Makes posting a document SAFE TO RETRY. This is the foundation the offline
-- queue stands on; nothing else in the offline work is safe without it.
--
-- ─── THE PROBLEM RETRY CREATES ───────────────────────────────────────────────
--
-- A queued delivery is posted over a bad connection. The request reaches
-- Postgres, the transaction commits, and the response is lost on the way back.
-- The client sees a timeout, marks the item Failed, and retries.
--
-- Without this migration that retry inserts a SECOND delivery: a second set of
-- bottle movements, a second journal entry, a second charge on the customer's
-- ledger. Worse, it is invisible — both rows look legitimate, and the only
-- evidence is a customer who was billed twice.
--
-- No amount of client-side care fixes this. The client cannot know whether a
-- request it never got an answer to was applied. A flag written before the
-- call over-reports failures; a flag written after loses the record if the
-- process dies mid-flight. The guarantee has to be enforced where the write
-- lands.
--
-- ─── THE FIX ─────────────────────────────────────────────────────────────────
--
-- The CLIENT generates a UUID for the document at the moment the user saves it
-- — offline, on the device, before any network exists. That UUID travels with
-- every retry of that same document.
--
-- Postgres holds a UNIQUE constraint on (orgid, clientuuid). The posting
-- function looks the UUID up first: if a document already carries it, the
-- function returns the EXISTING id and writes nothing. Retry as many times as
-- you like; the second call is a read.
--
-- This is idempotency by key, and it is the same thing Stripe's
-- Idempotency-Key header does, for the same reason.
--
-- ─── WHAT THIS MIGRATION DOES NOT DO ─────────────────────────────────────────
--
-- It does not add offline storage, a queue, or any client behaviour. It is
-- deliberately useful on its own: even the current online-only app stops being
-- able to double-post when a user taps Save twice on a slow connection.
--
-- Safe to re-run.
-- =============================================================================

-- ─── 1. The idempotency key ──────────────────────────────────────────────────

alter table public.ws_tbldeliveries
  add column if not exists clientuuid uuid;

alter table public.ws_tblpayments
  add column if not exists clientuuid uuid;

comment on column public.ws_tbldeliveries.clientuuid is
  'Client-generated idempotency key. Set by the device when the document is '
  'created (possibly offline). Retries carry the same value so a re-post is a '
  'no-op rather than a duplicate.';

comment on column public.ws_tblpayments.clientuuid is
  'Client-generated idempotency key. See ws_tbldeliveries.clientuuid.';

-- PARTIAL unique indexes: null clientuuid means "posted directly, not from a
-- queue", and there may be any number of those. Only non-null keys are
-- constrained, so this cannot break existing rows.
create unique index if not exists ux_delivery_clientuuid
  on public.ws_tbldeliveries(orgid, clientuuid)
  where clientuuid is not null;

create unique index if not exists ux_payment_clientuuid
  on public.ws_tblpayments(orgid, clientuuid)
  where clientuuid is not null;

-- ─── 2. Idempotent delivery posting ──────────────────────────────────────────
--
-- NOTE ON THE SIGNATURE: p_clientuuid is added as a trailing parameter WITH A
-- DEFAULT, so every existing caller — the current delivery screen included —
-- keeps working untouched and simply posts without a key.

create or replace function public.ws_record_delivery(
  p_customerid    bigint,
  p_deliverydate  date    default current_date,
  p_delivered     int     default 0,
  p_returned      int     default 0,
  p_productid     bigint  default null,
  p_amountpaid    numeric default 0,
  p_paymentmethod text    default 'cash',
  p_deliveredbyid bigint  default null,
  p_routeid       bigint  default null,
  p_notes         text    default null,
  p_clientuuid    uuid    default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org        bigint;
  v_product    bigint;
  v_deliveryid bigint;
  v_methodid   bigint;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'delivery.manage') then
    raise exception 'permission denied: delivery.manage' using errcode = '42501';
  end if;

  -- ── THE IDEMPOTENCY CHECK ──────────────────────────────────────────────
  -- Before anything is written. A retry of a call that already succeeded
  -- returns the original id and touches nothing.
  if p_clientuuid is not null then
    select deliveryid into v_deliveryid
    from public.ws_tbldeliveries
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_deliveryid is not null then
      return v_deliveryid;
    end if;
  end if;

  -- Default product = the org's returnable water product on the default
  -- bottle type.
  v_product := p_productid;
  if v_product is null then
    select p.productid into v_product
    from public.ws_tblproducts p
    join public.ws_tblbottletypes b on b.bottletypeid = p.bottletypeid
    where p.orgid = v_org and p.isactive and b.isdefault
    order by p.productid
    limit 1;
  end if;

  if v_product is null then
    raise exception 'org % has no returnable product configured on its default bottle type', v_org
      using errcode = 'P0002';
  end if;

  insert into public.ws_tbldeliveries
    (orgid, customerid, routeid, deliveredbyid, deliverydate, notes, clientuuid)
  values
    (v_org, p_customerid, p_routeid, p_deliveredbyid, p_deliverydate, p_notes,
     p_clientuuid)
  returning deliveryid into v_deliveryid;

  insert into public.ws_tbldeliverydetails
    (deliveryid, orgid, productid, deliveredqty, returnedqty)
  values
    (v_deliveryid, v_org, v_product, p_delivered, p_returned);

  if coalesce(p_amountpaid, 0) > 0 then
    select methodid into v_methodid
    from public.ws_tblpaymentmethods
    where orgid = v_org and methodcode = coalesce(p_paymentmethod, 'cash');

    insert into public.ws_tblpayments
      (orgid, customerid, deliveryid, receivedbyid, methodid, paymentdate,
       amountreceived, paymentmethod, clientuuid)
    values
      (v_org, p_customerid, v_deliveryid, p_deliveredbyid, v_methodid, p_deliverydate,
       p_amountpaid, coalesce(p_paymentmethod, 'cash'),
       -- The payment inside a delivery is part of the SAME document, so it
       -- shares the delivery's key rather than needing one of its own. The
       -- unique index is per table, so there is no collision with a standalone
       -- payment that happens to be posted with the same key.
       p_clientuuid);
  end if;

  return v_deliveryid;
end
$$;

revoke all on function public.ws_record_delivery(bigint,date,int,int,bigint,numeric,text,bigint,bigint,text,uuid) from public;
grant execute on function public.ws_record_delivery(bigint,date,int,int,bigint,numeric,text,bigint,bigint,text,uuid) to authenticated;

-- The previous 10-argument signature still exists as a separate function until
-- Postgres is told otherwise, and an overloaded pair is how "function is not
-- unique" errors start. Drop the old one now that the new one covers it.
drop function if exists public.ws_record_delivery(bigint,date,int,int,bigint,numeric,text,bigint,bigint,text);

-- ─── 3. Idempotent standalone payment ────────────────────────────────────────
-- Payments not attached to a delivery are inserted directly by the app, so
-- they need a posting function of their own to get the same guarantee.

create or replace function public.ws_record_payment(
  p_customerid    bigint,
  p_amount        numeric,
  p_paymentdate   date    default current_date,
  p_paymentmethod text    default 'cash',
  p_referenceno   text    default null,
  p_notes         text    default null,
  p_clientuuid    uuid    default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org       bigint;
  v_paymentid bigint;
  v_methodid  bigint;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'payments.manage') then
    raise exception 'permission denied: payments.manage' using errcode = '42501';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'payment amount must be greater than zero' using errcode = '22023';
  end if;

  if p_clientuuid is not null then
    select paymentid into v_paymentid
    from public.ws_tblpayments
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_paymentid is not null then
      return v_paymentid;
    end if;
  end if;

  select methodid into v_methodid
  from public.ws_tblpaymentmethods
  where orgid = v_org and methodcode = coalesce(p_paymentmethod, 'cash');

  insert into public.ws_tblpayments
    (orgid, customerid, methodid, paymentdate, amountreceived, paymentmethod,
     referenceno, notes, clientuuid)
  values
    (v_org, p_customerid, v_methodid, p_paymentdate, p_amount,
     coalesce(p_paymentmethod, 'cash'), p_referenceno, p_notes, p_clientuuid)
  returning paymentid into v_paymentid;

  return v_paymentid;
end
$$;

revoke all on function public.ws_record_payment(bigint,numeric,date,text,text,text,uuid) from public;
grant execute on function public.ws_record_payment(bigint,numeric,date,text,text,text,uuid) to authenticated;

-- ─── 4. Look up what a key posted to ─────────────────────────────────────────
--
-- For DIAGNOSING a failed sync without risking a re-post. When an item is
-- stuck in Failed, this answers the only question that matters — did it
-- actually land? — with a read rather than another write.

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
    and ws.is_member(p.orgid);
$$;

revoke all on function public.ws_lookup_clientuuid(uuid) from public;
grant execute on function public.ws_lookup_clientuuid(uuid) to authenticated;

-- =============================================================================
-- VERIFICATION — run these; the second call must NOT create a second delivery.
--
--   select public.ws_record_delivery(
--     p_customerid   => 1,
--     p_delivered    => 5,
--     p_returned     => 3,
--     p_amountpaid   => 450,
--     p_clientuuid   => '11111111-1111-1111-1111-111111111111'
--   );
--   -- run the EXACT same statement again: same id returned.
--
--   select count(*) from public.ws_tbldeliveries
--   where clientuuid = '11111111-1111-1111-1111-111111111111';
--   -- must be 1
--
--   select * from public.ws_lookup_clientuuid(
--     '11111111-1111-1111-1111-111111111111');
--
--   select count(*) from public.vw_ws_reconciliation;   -- must still be 0
-- =============================================================================
