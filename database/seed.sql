-- =============================================================================
-- seed.sql
-- Two organizations, so tenant isolation can actually be tested rather than
-- assumed. Org 1 reproduces the numbers on the physical delivery card exactly:
--
--   Opening bottle balance: 4          Rate: Rs 250 / 19L bottle
--   Date    Delivered  Received  Balance   Amount   Received
--   01-07       4          3        5       1,000     1,000
--   02-07       5          3        7       1,250         0
--   03-07       3          4        6         750       750
--
--   Expected end state: bottle balance 6, outstanding due Rs 1,250.
--
-- Run as a superuser / the postgres role (Supabase SQL editor qualifies).
-- Uses the private ws.* provisioning functions, not the permission-gated
-- public RPCs, because a seed has no authenticated session to check.
-- =============================================================================

-- =============================================================================
-- ⚠  DEVELOPMENT DATABASES ONLY. THIS IS NOT A PRODUCTION SCRIPT.
--
-- It inserts two fictional companies ("Kent Mineral Water", "AquaPure
-- Distributors"), four auth users, fictional customers and a month of invented
-- deliveries. On a live database that is contamination you would have to unpick
-- by hand, and the fake organizations would appear in your app.
--
-- The guard below refuses to run if the database already contains an
-- organization that is not one of the two this file creates. That check exists
-- because "don't run this on production" in a comment is not a safety mechanism.
-- =============================================================================

do $guard$
declare
  v_other int;
begin
  select count(*) into v_other
  from public.ws_tblorganization
  where orgname not in ('Kent Mineral Water', 'AquaPure Distributors');

  if v_other > 0 then
    raise exception
      'REFUSING TO SEED: this database already contains % real organization(s). '
      'seed.sql is for a scratch database only — it would add fictional companies '
      'and customers alongside your live data. If you are certain, delete this '
      'guard block. If you have real data, what you want is '
      'bootstrap_existing_data.sql, not seed.sql.',
      v_other
      using errcode = 'P0001';
  end if;

  if exists (select 1 from public.ws_tblorganization
             where orgname in ('Kent Mineral Water', 'AquaPure Distributors')) then
    raise exception
      'REFUSING TO SEED: the seed data is already present. Re-running would '
      'duplicate it. Drop and recreate the database, or delete those two '
      'organizations first.'
      using errcode = 'P0001';
  end if;
end
$guard$;

do $seed$
declare
  v_owner1  uuid;
  v_owner2  uuid;
  v_staff1  uuid;
  v_portal1 uuid;
  v_org1    bigint;
  v_org2    bigint;
  v_area1   bigint;
  v_area2   bigint;
  v_bt19    bigint;
  v_bt20    bigint;
  v_prod19  bigint;
  v_prod500 bigint;
  v_grp     bigint;
  v_cust1   bigint;   -- Hotel ABC  (the card)
  v_cust2   bigint;   -- Restaurant XYZ
  v_cust3   bigint;   -- Home customer, has portal login
  v_vendor  bigint;
  v_route   bigint;
  v_driver  bigint;
  v_roleid  bigint;
  v_purch   bigint;
  v_org2cust bigint;
begin
  -- ── auth users ────────────────────────────────────────────────────────────
  -- Supabase's auth.users.id has NO default: GoTrue supplies it. Omitting it
  -- fails with
  --   null value in column "id" of relation "users" violates not-null constraint
  -- so the uuid is generated explicitly here.
  insert into auth.users (id, email)
  values (gen_random_uuid(), 'owner@kentwater.pk')   returning id into v_owner1;
  insert into auth.users (id, email)
  values (gen_random_uuid(), 'ali@kentwater.pk')     returning id into v_staff1;
  insert into auth.users (id, email)
  values (gen_random_uuid(), 'hotelabc@example.com') returning id into v_portal1;
  insert into auth.users (id, email)
  values (gen_random_uuid(), 'owner@aquapure.pk')    returning id into v_owner2;

  -- ── organizations ─────────────────────────────────────────────────────────
  v_org1 := ws.provision_organization(
    v_owner1, 'Kent Mineral Water', 'Kamran Khan', '0300-1112233',
    'Plot 14, Industrial Area, Lahore', 'PKR');

  v_org2 := ws.provision_organization(
    v_owner2, 'AquaPure Distributors', 'Sana Malik', '0321-4445566',
    '22-B Clifton, Karachi', 'PKR');

  perform ws.seed_chart_of_accounts(v_org1);
  perform ws.seed_chart_of_accounts(v_org2);

  -- ── org 1: staff ──────────────────────────────────────────────────────────
  select roleid into v_roleid from public.ws_tblroles
  where orgid = v_org1 and rolecode = 'delivery';

  insert into public.ws_tblmemberships (orgid, authuserid, roleid)
  values (v_org1, v_staff1, v_roleid);

  insert into public.ws_tblinternalusers (orgid, authuserid, fullname, role, phone, membershipid)
  select v_org1, v_staff1, 'Ali Raza', 'delivery', '0333-9998877', m.membershipid
  from public.ws_tblmemberships m
  where m.orgid = v_org1 and m.authuserid = v_staff1
  returning internaluserid into v_driver;

  -- ── org 1: areas and routes ───────────────────────────────────────────────
  insert into public.ws_tblareas (orgid, areaname, rateperbottle, deliverydays)
  values (v_org1, 'Gulberg', 250, 'Mon,Wed,Fri') returning areaid into v_area1;

  insert into public.ws_tblareas (orgid, areaname, rateperbottle, deliverydays)
  values (v_org1, 'DHA Phase 5', 270, 'Tue,Thu,Sat') returning areaid into v_area2;

  insert into public.ws_tblroutes (orgid, routecode, routename, areaid, driverid, vehicleno)
  values (v_org1, 'R-01', 'Gulberg Morning', v_area1, v_driver, 'LEA-2244')
  returning routeid into v_route;

  -- ── org 1: bottle types ───────────────────────────────────────────────────
  insert into public.ws_tblbottletypes
    (orgid, bottlecode, bottlename, capacitylitres, depositamount, isdefault)
  values (v_org1, 'BT19', '19 Litre Returnable', 19.0, 500, true)
  returning bottletypeid into v_bt19;

  -- A second returnable type: this is the case the old single-integer
  -- bottlebalance column could not represent.
  insert into public.ws_tblbottletypes
    (orgid, bottlecode, bottlename, capacitylitres, depositamount, isdefault)
  values (v_org1, 'BT20', '20 Litre Returnable', 20.0, 550, false)
  returning bottletypeid into v_bt20;

  -- ── org 1: products ───────────────────────────────────────────────────────
  insert into public.ws_tblproducts
    (orgid, productcode, productname, producttype, unitlabel, sizelabel,
     capacitylitres, bottletypeid, bottlesperunit, saleprice, purchaseprice)
  values (v_org1, 'W19', '19 Litre Mineral Water', 'water', 'Bottle', '19L',
          19.0, v_bt19, 1, 250, 120)
  returning productid into v_prod19;

  insert into public.ws_tblproducts
    (orgid, productcode, productname, producttype, unitlabel, sizelabel,
     capacitylitres, bottletypeid, bottlesperunit, saleprice, purchaseprice)
  values (v_org1, 'W20', '20 Litre Mineral Water', 'water', 'Bottle', '20L',
          20.0, v_bt20, 1, 270, 130);

  -- Non-returnable: bottletypeid null AND bottlesperunit 0 (see the check
  -- constraint in 003 — a product cannot claim to move bottles of no type).
  insert into public.ws_tblproducts
    (orgid, productcode, productname, producttype, unitlabel, sizelabel,
     bottletypeid, bottlesperunit, saleprice, purchaseprice)
  values (v_org1, 'W500', '500ml Bottle (case of 12)', 'water', 'Case', '500ml',
          null, 0, 600, 380)
  returning productid into v_prod500;

  -- ── org 1: pricing (customer > group > area > default) ─────────────────────
  insert into public.ws_tblcustomergroups (orgid, groupname)
  values (v_org1, 'Hotels') returning groupid into v_grp;

  -- Organization default for the 19L product.
  insert into public.ws_tblproductprices (orgid, productid, price, effectivefrom)
  values (v_org1, v_prod19, 250, date '2026-01-01');

  -- Group price: hotels pay less.
  insert into public.ws_tblproductprices (orgid, productid, groupid, price, effectivefrom)
  values (v_org1, v_prod19, v_grp, 230, date '2026-01-01');

  -- ── org 1: customers ──────────────────────────────────────────────────────
  insert into public.ws_tblcustomers
    (orgid, customercode, customername, contactperson, phone, address, areaid, routeid,
     groupid, creditlimit, depositamount)
  values (v_org1, 'C-001', 'Hotel ABC', 'Mr. Tariq', '0300-1234567',
          '12 Main Boulevard, Gulberg', v_area1, v_route, null, 50000, 2000)
  returning customerid into v_cust1;

  insert into public.ws_tblcustomers
    (orgid, customercode, customername, contactperson, phone, address, areaid, routeid,
     groupid, creditlimit)
  values (v_org1, 'C-002', 'Restaurant XYZ', 'Ms. Hina', '0301-7654321',
          '5 Liberty Market, Gulberg', v_area1, v_route, v_grp, 30000)
  returning customerid into v_cust2;

  -- Portal customer: gets an auth login. The trigger in 003 creates the
  -- matching membership row, which is what scopes its RLS visibility.
  insert into public.ws_tblcustomers
    (orgid, customercode, customername, phone, address, areaid, routeid, authuserid)
  values (v_org1, 'C-003', 'Ahmed Household', '0345-1112222',
          'House 9, Street 4, Gulberg', v_area1, v_route, v_portal1)
  returning customerid into v_cust3;

  -- Customer-specific override for Hotel ABC: beats the group and org prices.
  insert into public.ws_tblproductprices
    (orgid, productid, customerid, price, effectivefrom)
  values (v_org1, v_prod19, v_cust1, 250, date '2026-01-01');

  -- ── org 1: opening balances ───────────────────────────────────────────────
  -- Hotel ABC starts holding 4 bottles, which is what makes the card's first
  -- row come out at a balance of 5.
  insert into public.ws_tblbottletransactions
    (orgid, customerid, bottletypeid, txndate, txntype, qty, balancebefore, balanceafter, notes)
  values (v_org1, v_cust1, v_bt19, date '2026-06-30', 'opening', 4, 0, 0,
          'Opening bottle balance');

  insert into public.ws_tblbottletransactions
    (orgid, customerid, bottletypeid, txndate, txntype, qty, balancebefore, balanceafter, notes)
  values (v_org1, v_cust2, v_bt19, date '2026-06-30', 'opening', 2, 0, 0,
          'Opening bottle balance');

  -- ── org 1: vendor and a bottle purchase into stock ────────────────────────
  insert into public.ws_tblvendors
    (orgid, vendorcode, vendorname, contactperson, phone, address)
  values (v_org1, 'V-001', 'Pak Plastics (Pvt) Ltd', 'Mr. Javed', '042-35771234',
          'Kot Lakhpat, Lahore')
  returning vendorid into v_vendor;

  insert into public.ws_tblpurchases (orgid, vendorid, purchasedate, billno)
  values (v_org1, v_vendor, date '2026-06-25', 'BILL-8891')
  returning purchaseid into v_purch;

  -- 100 empty 19L bottles at Rs 420. Recorded against the returnable product so
  -- the bottle ledger sees them arrive into stock (customerid NULL).
  insert into public.ws_tblpurchasedetails (purchaseid, orgid, productid, quantity, unitcost)
  values (v_purch, v_org1, v_prod19, 100, 420);

  insert into public.ws_tblvendorpayments (orgid, vendorid, purchaseid, paiddate, amountpaid)
  values (v_org1, v_vendor, v_purch, date '2026-07-05', 20000);

  -- ── org 1: THE DELIVERY CARD ──────────────────────────────────────────────
  -- 01-07: 4 out, 3 in, Rs 1,000 charged, Rs 1,000 collected
  declare
    v_d bigint;
    v_m bigint;
  begin
    select methodid into v_m from public.ws_tblpaymentmethods
    where orgid = v_org1 and methodcode = 'cash';

    insert into public.ws_tbldeliveries
      (orgid, customerid, routeid, deliveredbyid, deliverydate)
    values (v_org1, v_cust1, v_route, v_driver, date '2026-07-01')
    returning deliveryid into v_d;
    insert into public.ws_tbldeliverydetails
      (deliveryid, orgid, productid, deliveredqty, returnedqty)
    values (v_d, v_org1, v_prod19, 4, 3);
    insert into public.ws_tblpayments
      (orgid, customerid, deliveryid, receivedbyid, methodid, paymentdate, amountreceived, paymentmethod)
    values (v_org1, v_cust1, v_d, v_driver, v_m, date '2026-07-01', 1000, 'cash');

    -- 02-07: 5 out, 3 in, Rs 1,250 charged, nothing collected
    insert into public.ws_tbldeliveries
      (orgid, customerid, routeid, deliveredbyid, deliverydate)
    values (v_org1, v_cust1, v_route, v_driver, date '2026-07-02')
    returning deliveryid into v_d;
    insert into public.ws_tbldeliverydetails
      (deliveryid, orgid, productid, deliveredqty, returnedqty)
    values (v_d, v_org1, v_prod19, 5, 3);

    -- 03-07: 3 out, 4 in, Rs 750 charged, Rs 750 collected
    insert into public.ws_tbldeliveries
      (orgid, customerid, routeid, deliveredbyid, deliverydate)
    values (v_org1, v_cust1, v_route, v_driver, date '2026-07-03')
    returning deliveryid into v_d;
    insert into public.ws_tbldeliverydetails
      (deliveryid, orgid, productid, deliveredqty, returnedqty)
    values (v_d, v_org1, v_prod19, 3, 4);
    insert into public.ws_tblpayments
      (orgid, customerid, deliveryid, receivedbyid, methodid, paymentdate, amountreceived, paymentmethod)
    values (v_org1, v_cust1, v_d, v_driver, v_m, date '2026-07-03', 750, 'cash');

    -- Restaurant XYZ: exercises group pricing (Rs 230, not Rs 250) and a
    -- mixed delivery that includes a non-returnable line.
    insert into public.ws_tbldeliveries
      (orgid, customerid, routeid, deliveredbyid, deliverydate)
    values (v_org1, v_cust2, v_route, v_driver, date '2026-07-02')
    returning deliveryid into v_d;
    insert into public.ws_tbldeliverydetails
      (deliveryid, orgid, productid, deliveredqty, returnedqty)
    values (v_d, v_org1, v_prod19, 6, 2);
    insert into public.ws_tbldeliverydetails
      (deliveryid, orgid, productid, deliveredqty, returnedqty)
    values (v_d, v_org1, v_prod500, 2, 0);

    -- Portal customer: one delivery plus a 20L bottle, so a single customer
    -- holds two bottle types at once.
    insert into public.ws_tbldeliveries
      (orgid, customerid, routeid, deliveredbyid, deliverydate)
    values (v_org1, v_cust3, v_route, v_driver, date '2026-07-02')
    returning deliveryid into v_d;
    insert into public.ws_tbldeliverydetails
      (deliveryid, orgid, productid, deliveredqty, returnedqty)
    values (v_d, v_org1, v_prod19, 2, 1);
    insert into public.ws_tbldeliverydetails
      (deliveryid, orgid, productid, deliveredqty, returnedqty)
    select v_d, v_org1, productid, 1, 0
    from public.ws_tblproducts where orgid = v_org1 and productcode = 'W20';
  end;

  -- Lost bottle: a compensating movement, recorded as its own transaction so
  -- the history explains the balance instead of silently changing it.
  insert into public.ws_tblbottletransactions
    (orgid, customerid, bottletypeid, txndate, txntype, qty, balancebefore, balanceafter, notes)
  values (v_org1, v_cust2, v_bt19, date '2026-07-10', 'lost', -1, 0, 0,
          'Bottle reported broken by customer');

  -- ── org 2: minimal, exists purely to prove isolation ──────────────────────
  insert into public.ws_tblareas (orgid, areaname, rateperbottle)
  values (v_org2, 'Clifton', 300) returning areaid into v_area2;

  insert into public.ws_tblbottletypes
    (orgid, bottlecode, bottlename, capacitylitres, depositamount, isdefault)
  values (v_org2, 'BT19', '19 Litre Returnable', 19.0, 600, true)
  returning bottletypeid into v_bt19;

  insert into public.ws_tblproducts
    (orgid, productcode, productname, producttype, unitlabel,
     bottletypeid, bottlesperunit, saleprice, purchaseprice)
  values (v_org2, 'W19', '19 Litre Mineral Water', 'water', 'Bottle',
          v_bt19, 1, 300, 140)
  returning productid into v_prod19;

  insert into public.ws_tblcustomers
    (orgid, customercode, customername, phone, address, areaid)
  values (v_org2, 'C-001', 'CONFIDENTIAL Karachi Client', '0311-0000000',
          'Should never be visible to Kent Mineral Water', v_area2)
  returning customerid into v_org2cust;

  declare v_d2 bigint;
  begin
    insert into public.ws_tbldeliveries (orgid, customerid, deliverydate)
    values (v_org2, v_org2cust, date '2026-07-02') returning deliveryid into v_d2;
    insert into public.ws_tbldeliverydetails
      (deliveryid, orgid, productid, deliveredqty, returnedqty)
    values (v_d2, v_org2, v_prod19, 10, 8);
  end;

  raise notice 'Seed complete. org1=% org2=% hotelABC=%', v_org1, v_org2, v_cust1;
end
$seed$;
