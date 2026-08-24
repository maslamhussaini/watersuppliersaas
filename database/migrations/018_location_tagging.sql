-- =============================================================================
-- 018_location_tagging.sql
-- Where a customer is, and where a delivery was made.
--
-- ─── ONLY TWO TABLES ─────────────────────────────────────────────────────────
--
-- ws_tblcustomers  — so a driver can find the door.
-- ws_tbldeliveries — so "delivered" has evidence behind it.
--
-- NOT payments, purchases, vendor payments, bottle transactions or journal
-- entries. Adding coordinates to every table because GPS is being introduced
-- would put a column nobody reads on rows nobody geolocates, and each one is
-- another place privacy has to be reasoned about. A payment recorded at the
-- counter has no location question to answer; if one appears later it can have
-- its own migration and its own argument.
--
-- ─── PLAIN NUMERIC, NOT POSTGIS ──────────────────────────────────────────────
--
-- The extension is not available here, and this feature needs to store a point
-- and show it on a map — not index proximity, compute distance or route. Two
-- numerics do that with no extension, no new operator classes and no migration
-- risk. If radius search on thousands of customers is ever wanted, that is when
-- PostGIS earns its place.
--
-- ─── NOTHING BECOMES INVALID ─────────────────────────────────────────────────
--
-- Every column is NULLABLE and no existing row is touched. A customer with no
-- coordinates is a customer whose location was never captured, which is the
-- normal state for every row that exists today and for every one saved by a
-- user who declines the permission. GPS is never required to save anything.
--
-- The CHECK constraints reject impossible coordinates but accept NULL, so they
-- validate new data without invalidating old.
--
-- ADDITIVE: eight nullable columns, four checks, two RPCs gaining three
-- defaulted parameters. Safe to re-run.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. COLUMNS
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare t text;
begin
  foreach t in array array['ws_tblcustomers', 'ws_tbldeliveries']
  loop
    execute format(
      'alter table public.%I '
      '  add column if not exists latitude numeric(9,6), '
      '  add column if not exists longitude numeric(9,6), '
      '  add column if not exists locationaccuracy numeric(7,2), '
      '  add column if not exists locationcapturedat timestamptz', t);

    -- Range checks. NOT NULL is deliberately absent: these accept a row with
    -- no location at all, and only reject a location that cannot exist.
    execute format(
      'alter table public.%I drop constraint if exists ck_%s_latitude', t,
      replace(t, 'ws_tbl', ''));
    execute format(
      'alter table public.%I add constraint ck_%s_latitude '
      'check (latitude is null or (latitude >= -90 and latitude <= 90))',
      t, replace(t, 'ws_tbl', ''));

    execute format(
      'alter table public.%I drop constraint if exists ck_%s_longitude', t,
      replace(t, 'ws_tbl', ''));
    execute format(
      'alter table public.%I add constraint ck_%s_longitude '
      'check (longitude is null or (longitude >= -180 and longitude <= 180))',
      t, replace(t, 'ws_tbl', ''));
  end loop;
end
$$;

comment on column public.ws_tblcustomers.latitude is
  'Where the customer is, captured once when someone pressed the button. Null '
  'means never captured — the normal state, not an error.';

comment on column public.ws_tbldeliveries.locationcapturedat is
  'When the coordinates were read, which is NOT the same as when the delivery '
  'synced. A delivery recorded offline carries the moment it happened.';

-- Finding customers with no location yet is the one query this feature adds.
create index if not exists ix_customer_located
  on public.ws_tblcustomers(orgid) where latitude is not null;


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. ws_record_customer
-- ═════════════════════════════════════════════════════════════════════════════
-- Old signature dropped first: a defaulted parameter creates an overload and a
-- call with the previous argument count would match both. Same trap as 010,
-- 014 and 015.

drop function if exists public.ws_record_customer(bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,numeric,uuid,bigint);

create or replace function public.ws_record_customer(
  p_orgid          bigint,
  p_customername   text,
  p_areaid         bigint  default null,
  p_customercode   text    default null,
  p_contactperson  text    default null,
  p_phone          text    default null,
  p_email          text    default null,
  p_address        text    default null,
  p_rateoverride   numeric default null,
  p_depositamount  numeric default 0,
  p_routeid        bigint  default null,
  p_groupid        bigint  default null,
  p_openingbalance numeric default 0,
  p_clientuuid     uuid    default null,
  p_storeid        bigint  default null,
  p_latitude       numeric default null,
  p_longitude      numeric default null,
  p_accuracy       numeric default null
)
returns bigint
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_customerid bigint;
  v_areaorg    bigint;
  v_storeid    bigint;
begin
  if not ws.has_perm(p_orgid, 'customers.manage') then
    raise exception 'permission denied: customers.manage' using errcode = '42501';
  end if;

  if p_clientuuid is not null then
    select customerid into v_customerid
    from public.ws_tblcustomers
    where orgid = p_orgid and clientuuid = p_clientuuid;

    if v_customerid is not null then
      return v_customerid;
    end if;
  end if;

  if coalesce(trim(p_customername), '') = '' then
    raise exception 'customer name is required' using errcode = '22023';
  end if;

  if p_areaid is not null then
    select orgid into v_areaorg from public.ws_tblareas where areaid = p_areaid;
    if v_areaorg is null then
      raise exception 'area % not found', p_areaid using errcode = 'P0002';
    end if;
    perform ws.assert_same_org(p_orgid, v_areaorg, 'customer vs area');
  end if;

  v_storeid := ws.resolve_store(p_orgid, p_storeid);

  insert into public.ws_tblcustomers
    (orgid, customername, customercode, areaid, routeid, groupid,
     contactperson, phone, email, address, rateoverride, depositamount,
     openingbalance, clientuuid, storeid,
     latitude, longitude, locationaccuracy, locationcapturedat)
  values
    (p_orgid, p_customername, p_customercode, p_areaid, p_routeid, p_groupid,
     p_contactperson, p_phone, p_email, p_address, p_rateoverride,
     coalesce(p_depositamount, 0), coalesce(p_openingbalance, 0), p_clientuuid,
     v_storeid,
     p_latitude, p_longitude, p_accuracy,
     -- Stamped only when there is something to stamp.
     case when p_latitude is not null then now() end)
  returning customerid into v_customerid;

  return v_customerid;
end
$$;

revoke all on function public.ws_record_customer(
  bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,
  numeric,uuid,bigint,numeric,numeric,numeric) from public;
grant execute on function public.ws_record_customer(
  bigint,text,bigint,text,text,text,text,text,numeric,numeric,bigint,bigint,
  numeric,uuid,bigint,numeric,numeric,numeric) to authenticated;


-- ─── Updating a customer's location on its own ───────────────────────────────
--
-- Exists so "Capture current location" on an EXISTING customer does not have
-- to send every other field back with it. Passing null for the coordinates
-- clears them, which is the only way a user can undo a capture.

create or replace function public.ws_set_customer_location(
  p_customerid bigint,
  p_latitude   numeric default null,
  p_longitude  numeric default null,
  p_accuracy   numeric default null
)
returns void
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare v_org bigint;
begin
  select orgid into v_org from public.ws_tblcustomers
  where customerid = p_customerid;

  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'customers.manage') then
    raise exception 'permission denied: customers.manage' using errcode = '42501';
  end if;

  -- Half a coordinate is not a location.
  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'latitude and longitude must be given together'
      using errcode = '22023';
  end if;

  update public.ws_tblcustomers
  set latitude = p_latitude,
      longitude = p_longitude,
      locationaccuracy = p_accuracy,
      locationcapturedat = case when p_latitude is not null then now() end
  where customerid = p_customerid;
end
$$;

revoke all on function public.ws_set_customer_location(bigint,numeric,numeric,numeric) from public;
grant execute on function public.ws_set_customer_location(bigint,numeric,numeric,numeric) to authenticated;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. ws_record_delivery
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists public.ws_record_delivery(bigint,date,integer,integer,bigint,numeric,text,bigint,bigint,text,uuid,bigint);

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
  p_clientuuid    uuid    default null,
  p_storeid       bigint  default null,
  p_latitude      numeric default null,
  p_longitude     numeric default null,
  p_accuracy      numeric default null,
  -- WHEN THE READING WAS TAKEN, not when it reached the server. A delivery
  -- queued in a basement and synced two hours later must carry the moment it
  -- actually happened, so the client sends it rather than the server assuming
  -- now().
  p_capturedat    timestamptz default null
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
  v_storeid    bigint;
begin
  select orgid into v_org from public.ws_tblcustomers where customerid = p_customerid;
  if v_org is null then
    raise exception 'customer % not found', p_customerid using errcode = 'P0002';
  end if;
  if not ws.has_perm(v_org, 'delivery.manage') then
    raise exception 'permission denied: delivery.manage' using errcode = '42501';
  end if;

  -- ── THE IDEMPOTENCY CHECK ──────────────────────────────────────────────
  -- Before anything is written, and before the store or the coordinates are
  -- looked at. A RETRY THEREFORE CANNOT MOVE A POSTED DELIVERY: it returns
  -- the original id and ignores everything it was sent, including a different
  -- location.
  if p_clientuuid is not null then
    select deliveryid into v_deliveryid
    from public.ws_tbldeliveries
    where orgid = v_org and clientuuid = p_clientuuid;

    if v_deliveryid is not null then
      return v_deliveryid;
    end if;
  end if;

  v_storeid := ws.resolve_store(v_org, p_storeid);

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
    (orgid, customerid, routeid, deliveredbyid, deliverydate, notes, clientuuid,
     storeid, latitude, longitude, locationaccuracy, locationcapturedat)
  values
    (v_org, p_customerid, p_routeid, p_deliveredbyid, p_deliverydate, p_notes,
     p_clientuuid, v_storeid,
     p_latitude, p_longitude, p_accuracy,
     case when p_latitude is not null
          then coalesce(p_capturedat, now()) end)
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
       amountreceived, paymentmethod, clientuuid, storeid)
    values
      (v_org, p_customerid, v_deliveryid, p_deliveredbyid, v_methodid, p_deliverydate,
       p_amountpaid, coalesce(p_paymentmethod, 'cash'),
       -- The payment inside a delivery is part of the SAME document, so it
       -- shares the delivery's key and store.
       --
       -- It does NOT get the coordinates: the money was handed over at the
       -- same place, so a second copy adds nothing and puts location on a
       -- table this migration deliberately left alone.
       p_clientuuid, v_storeid);
  end if;

  return v_deliveryid;
end
$$;

revoke all on function public.ws_record_delivery(bigint,date,integer,integer,bigint,numeric,text,bigint,bigint,text,uuid,bigint,numeric,numeric,numeric,timestamptz) from public;
grant execute on function public.ws_record_delivery(bigint,date,integer,integer,bigint,numeric,text,bigint,bigint,text,uuid,bigint,numeric,numeric,numeric,timestamptz) to authenticated;


-- =============================================================================
-- VERIFICATION
--
--   -- a delivery with coordinates
--   select public.ws_record_delivery(p_customerid => 1, p_delivered => 2,
--          p_latitude => 24.8607, p_longitude => 67.0011, p_accuracy => 12.5,
--          p_clientuuid => gen_random_uuid());
--
--   -- a retry with DIFFERENT coordinates changes nothing
--   select latitude, longitude from public.ws_tbldeliveries
--    order by deliveryid desc limit 1;
--
--   -- impossible coordinates are refused
--   select public.ws_record_delivery(p_customerid => 1, p_latitude => 999);
--
--   -- and everything without a location still works
--   select public.ws_record_delivery(p_customerid => 1, p_delivered => 1);
--
--   select count(*) from public.vw_ws_reconciliation;            -- 0
-- =============================================================================
