-- =============================================================================
-- 007_views.sql
-- Ledgers, balances, the delivery card, trial balance, reconciliation.
--
-- CRITICAL — security_invoker = true ON EVERY VIEW
-- By default a Postgres view executes with the privileges of its OWNER, which
-- means row level security on the underlying tables is BYPASSED. A view over
-- ws_tblcustomers without security_invoker would happily hand every tenant's
-- customer list to any authenticated caller — the exact leak RLS was added to
-- prevent, reintroduced by the reporting layer.
--
-- Requires Postgres 15+. Supabase is 15+. Verify after any restore:
--   select relname from pg_class
--   where relkind = 'v' and relnamespace = 'public'::regnamespace
--     and not coalesce((reloptions::text like '%security_invoker=true%'), false);
--   -- must return zero rows
-- =============================================================================

-- ─── Customer balance (compatibility view for the existing Flutter code) ─────
-- The current client reads `vw_ws_customerbalance` and expects the customer
-- columns plus areaname, rateperbottle and outstandingdue. Preserved verbatim,
-- with per-type bottle data added.

create or replace view public.vw_ws_customerbalance
with (security_invoker = true) as
with money as (
  select
    d.orgid,
    d.customerid,
    coalesce(sum(d.amountcharged), 0) as totalcharged
  from public.ws_tbldeliveries d
  where not d.isvoid
  group by d.orgid, d.customerid
),
paid as (
  select
    p.orgid,
    p.customerid,
    coalesce(sum(p.amountreceived), 0) as totalreceived
  from public.ws_tblpayments p
  where not p.isvoid
  group by p.orgid, p.customerid
)
select
  c.customerid,
  c.orgid,
  c.customercode,
  c.customername,
  c.contactperson,
  c.phone,
  c.email,
  c.address,
  c.areaid,
  c.routeid,
  c.groupid,
  c.authuserid,
  c.creditlimit,
  c.depositamount,
  c.openingbalance,
  c.rateoverride,
  c.bottlebalance,
  c.isactive,
  c.createddate,
  a.areaname,
  a.rateperbottle,
  coalesce(m.totalcharged, 0)                                   as totalcharged,
  coalesce(pd.totalreceived, 0)                                 as totalreceived,
  -- The formula from the spec: opening + sales - payments.
  round(c.openingbalance
        + coalesce(m.totalcharged, 0)
        - coalesce(pd.totalreceived, 0), 2)                     as outstandingdue,
  coalesce((
    select sum(b.balance) from public.ws_tblcustomerbottlebalances b
    where b.customerid = c.customerid
  ), 0)                                                          as bottlesallteypes,
  coalesce((
    select sum(b.balance * bt.depositamount)
    from public.ws_tblcustomerbottlebalances b
    join public.ws_tblbottletypes bt on bt.bottletypeid = b.bottletypeid
    where b.customerid = c.customerid
  ), 0)                                                          as bottledepositvalue
from public.ws_tblcustomers c
left join public.ws_tblareas a on a.areaid = c.areaid
left join money  m  on m.customerid  = c.customerid
left join paid   pd on pd.customerid = c.customerid;

-- ─── Bottle balance per customer per type ────────────────────────────────────

create or replace view public.vw_ws_customerbottlebalance
with (security_invoker = true) as
select
  b.orgid,
  b.customerid,
  c.customername,
  b.bottletypeid,
  t.bottlecode,
  t.bottlename,
  t.isdefault,
  b.balance,
  b.balance * t.depositamount as depositvalue,
  b.updated_at
from public.ws_tblcustomerbottlebalances b
join public.ws_tblcustomers   c on c.customerid   = b.customerid
join public.ws_tblbottletypes t on t.bottletypeid = b.bottletypeid;

-- ─── Bottle ledger (full movement history, per customer per type) ────────────

create or replace view public.vw_ws_bottleledger
with (security_invoker = true) as
select
  bt.bottletxnid,
  bt.orgid,
  bt.customerid,
  c.customername,
  bt.bottletypeid,
  t.bottlecode,
  t.bottlename,
  bt.txndate,
  bt.txntype,
  bt.qty,
  bt.balancebefore,
  bt.balanceafter,
  bt.deliveryid,
  d.referenceno,
  bt.notes
from public.ws_tblbottletransactions bt
left join public.ws_tblcustomers   c on c.customerid   = bt.customerid
join      public.ws_tblbottletypes t on t.bottletypeid = bt.bottletypeid
left join public.ws_tbldeliveries  d on d.deliveryid   = bt.deliveryid;

-- ─── Organization-wide bottle position ───────────────────────────────────────

create or replace view public.vw_ws_bottleposition
with (security_invoker = true) as
select
  t.orgid,
  t.bottletypeid,
  t.bottlecode,
  t.bottlename,
  coalesce(sum(case when bt.customerid is not null then bt.qty else 0 end), 0)::int as withcustomers,
  coalesce(sum(case when bt.customerid is null     then bt.qty else 0 end), 0)::int as purchasedintostock,
  coalesce(sum(case when bt.txntype = 'lost'    then -bt.qty else 0 end), 0)::int   as lost,
  coalesce(sum(case when bt.txntype = 'damaged' then -bt.qty else 0 end), 0)::int   as damaged,
  (coalesce(sum(case when bt.customerid is null then bt.qty else 0 end), 0)
   - coalesce(sum(case when bt.customerid is not null then bt.qty else 0 end), 0))::int as instock
from public.ws_tblbottletypes t
left join public.ws_tblbottletransactions bt on bt.bottletypeid = t.bottletypeid
group by t.orgid, t.bottletypeid, t.bottlecode, t.bottlename;

-- ─── Customer money ledger (debit / credit / running balance) ────────────────

create or replace view public.vw_ws_customerledger
with (security_invoker = true) as
with lines as (
  -- Opening balance as the first line so the running total ties to the card.
  select
    c.orgid,
    c.customerid,
    c.createddate::date            as txndate,
    0::bigint                      as sortkey,
    'Opening Balance'::text        as description,
    null::text                     as referenceno,
    c.openingbalance               as debit,
    0::numeric                     as credit
  from public.ws_tblcustomers c
  where c.openingbalance <> 0

  union all

  select
    d.orgid,
    d.customerid,
    d.deliverydate,
    1::bigint,
    'Delivery: ' || d.bottlesdelivered || ' out / ' || d.bottlesreturned || ' in',
    d.referenceno,
    d.amountcharged,
    0::numeric
  from public.ws_tbldeliveries d
  where not d.isvoid and d.amountcharged <> 0

  union all

  select
    p.orgid,
    p.customerid,
    p.paymentdate,
    2::bigint,
    'Payment (' || coalesce(p.paymentmethod, 'cash') || ')',
    p.receiptno,
    0::numeric,
    p.amountreceived
  from public.ws_tblpayments p
  where not p.isvoid
)
select
  l.orgid,
  l.customerid,
  l.txndate,
  -- Exposed so callers can reproduce the view's own ordering. Without it, two
  -- lines on the same date (a delivery and its payment) have no defined order
  -- and "the closing balance" is ambiguous.
  l.sortkey,
  l.description,
  l.referenceno,
  l.debit,
  l.credit,
  sum(l.debit - l.credit) over (
    partition by l.customerid
    order by l.txndate, l.sortkey
    rows between unbounded preceding and current row
  ) as balance
from lines l;

-- ─── Vendor ledger ───────────────────────────────────────────────────────────

create or replace view public.vw_ws_vendorledger
with (security_invoker = true) as
with lines as (
  select
    v.orgid, v.vendorid, v.createddate::date as txndate, 0::bigint as sortkey,
    'Opening Balance'::text as description, null::text as referenceno,
    0::numeric as debit, v.openingbalance as credit
  from public.ws_tblvendors v
  where v.openingbalance <> 0

  union all

  select
    p.orgid, p.vendorid, p.purchasedate, 1::bigint,
    'Purchase', coalesce(p.billno, p.referenceno),
    0::numeric, p.totalamount
  from public.ws_tblpurchases p
  where not p.isvoid and p.totalamount <> 0

  union all

  select
    vp.orgid, vp.vendorid, vp.paiddate, 2::bigint,
    'Payment', vp.voucherno,
    vp.amountpaid, 0::numeric
  from public.ws_tblvendorpayments vp
  where not vp.isvoid
)
select
  l.orgid,
  l.vendorid,
  l.txndate,
  l.sortkey,
  l.description,
  l.referenceno,
  l.debit,
  l.credit,
  -- Payables are a credit balance: positive = we owe the vendor.
  sum(l.credit - l.debit) over (
    partition by l.vendorid
    order by l.txndate, l.sortkey
    rows between unbounded preceding and current row
  ) as balance
from lines l;

-- ─── THE DELIVERY CARD ───────────────────────────────────────────────────────
-- One row per delivery date per customer, matching the physical card columns:
--   Date | Delivery Bottles | Received Bottles | Bottle Balance
--        | Total Amount | Amount Received
-- Payments not tied to a delivery still appear, so cash collected on a
-- no-delivery visit is not silently dropped from the card.

create or replace view public.vw_ws_deliverycard
with (security_invoker = true) as
with days as (
  select orgid, customerid, deliverydate as cardate from public.ws_tbldeliveries where not isvoid
  union
  select orgid, customerid, paymentdate  as cardate from public.ws_tblpayments   where not isvoid
),
del as (
  select
    orgid, customerid, deliverydate,
    sum(bottlesdelivered)::int as delivered,
    sum(bottlesreturned)::int  as received,
    sum(amountcharged)         as amount,
    max(bottlebalance)         as balance_snapshot,
    min(referenceno)           as referenceno
  from public.ws_tbldeliveries
  where not isvoid
  group by orgid, customerid, deliverydate
),
pay as (
  select orgid, customerid, paymentdate, sum(amountreceived) as received_amount
  from public.ws_tblpayments
  where not isvoid
  group by orgid, customerid, paymentdate
)
select
  dy.orgid,
  dy.customerid,
  c.customername,
  dy.cardate                                         as entrydate,
  coalesce(d.delivered, 0)                           as deliverybottles,
  coalesce(d.received, 0)                            as receivedbottles,
  -- Running bottle balance recomputed from history rather than trusting the
  -- per-row snapshot, so a backdated delivery still produces a correct card.
  coalesce((
    select sum(bt.qty)::int
    from public.ws_tblbottletransactions bt
    join public.ws_tblbottletypes t on t.bottletypeid = bt.bottletypeid and t.isdefault
    where bt.customerid = dy.customerid and bt.txndate <= dy.cardate
  ), 0)                                              as bottlebalance,
  coalesce(d.amount, 0)                              as totalamount,
  coalesce(p.received_amount, 0)                     as amountreceived,
  -- Running money balance as at this date.
  round(c.openingbalance
    + coalesce((select sum(x.amountcharged) from public.ws_tbldeliveries x
                where x.customerid = dy.customerid and not x.isvoid
                  and x.deliverydate <= dy.cardate), 0)
    - coalesce((select sum(y.amountreceived) from public.ws_tblpayments y
                where y.customerid = dy.customerid and not y.isvoid
                  and y.paymentdate <= dy.cardate), 0), 2) as runningbalance,
  d.referenceno
from days dy
join public.ws_tblcustomers c on c.customerid = dy.customerid
left join del d on d.customerid = dy.customerid and d.deliverydate = dy.cardate
left join pay p on p.customerid = dy.customerid and p.paymentdate  = dy.cardate;

-- ─── Today's delivery list (route sheet) ─────────────────────────────────────

create or replace view public.vw_ws_todaydeliveries
with (security_invoker = true) as
select
  d.orgid,
  d.deliveryid,
  d.referenceno,
  d.deliverydate,
  d.customerid,
  c.customername,
  c.phone,
  c.address,
  a.areaname,
  r.routename,
  u.fullname as deliveredby,
  d.bottlesdelivered,
  d.bottlesreturned,
  d.bottlebalance,
  d.rateapplied,
  d.amountcharged,
  coalesce((
    select sum(p.amountreceived) from public.ws_tblpayments p
    where p.deliveryid = d.deliveryid and not p.isvoid
  ), 0) as amountreceived
from public.ws_tbldeliveries d
join      public.ws_tblcustomers      c on c.customerid     = d.customerid
left join public.ws_tblareas          a on a.areaid         = c.areaid
left join public.ws_tblroutes         r on r.routeid        = d.routeid
left join public.ws_tblinternalusers  u on u.internaluserid = d.deliveredbyid
where not d.isvoid;

-- ─── Trial balance ───────────────────────────────────────────────────────────

create or replace view public.vw_ws_trialbalance
with (security_invoker = true) as
select
  a.orgid,
  a.accountid,
  a.accountcode,
  a.accountname,
  a.accounttype,
  a.controlfor,
  coalesce(sum(jd.debit),  0) as totaldebit,
  coalesce(sum(jd.credit), 0) as totalcredit,
  coalesce(sum(jd.debit), 0) - coalesce(sum(jd.credit), 0) as netdebit,
  (coalesce(sum(jd.debit), 0) - coalesce(sum(jd.credit), 0))
    * ws.account_sign(a.accounttype) as balance
from public.ws_tblaccounts a
left join public.ws_tbljournalentrydetails jd on jd.accountid = a.accountid
group by a.orgid, a.accountid, a.accountcode, a.accountname, a.accounttype, a.controlfor;

-- ─── General ledger ──────────────────────────────────────────────────────────

create or replace view public.vw_ws_generalledger
with (security_invoker = true) as
select
  j.orgid,
  j.journalid,
  j.entrydate,
  j.sourcetype,
  j.sourceid,
  j.memo,
  a.accountcode,
  a.accountname,
  a.accounttype,
  jd.customerid,
  jd.vendorid,
  jd.debit,
  jd.credit,
  jd.description
from public.ws_tbljournalentries j
join public.ws_tbljournalentrydetails jd on jd.journalid = j.journalid
join public.ws_tblaccounts a on a.accountid = jd.accountid;

-- ─── RECONCILIATION — the safety net for the journal-derived design ──────────
-- Compares each control account's journal balance against the subsidiary sum.
-- MUST return zero rows. Any row means a posting rule is wrong and the reports
-- and the ledgers now disagree. Put this on the admin dashboard.

create or replace view public.vw_ws_reconciliation
with (security_invoker = true) as
with ar_journal as (
  select jd.orgid, coalesce(sum(jd.debit - jd.credit), 0) as journalbalance
  from public.ws_tbljournalentrydetails jd
  join public.ws_tblaccounts a on a.accountid = jd.accountid and a.controlfor = 'ar'
  group by jd.orgid
),
ar_subsidiary as (
  select orgid, coalesce(sum(outstandingdue), 0) as subsidiarybalance
  from public.vw_ws_customerbalance
  group by orgid
),
ap_journal as (
  select jd.orgid, coalesce(sum(jd.credit - jd.debit), 0) as journalbalance
  from public.ws_tbljournalentrydetails jd
  join public.ws_tblaccounts a on a.accountid = jd.accountid and a.controlfor = 'ap'
  group by jd.orgid
),
ap_subsidiary as (
  select
    v.orgid,
    coalesce(sum(v.openingbalance), 0)
      + coalesce((select sum(p.totalamount) from public.ws_tblpurchases p
                  where p.orgid = v.orgid and not p.isvoid), 0)
      - coalesce((select sum(vp.amountpaid) from public.ws_tblvendorpayments vp
                  where vp.orgid = v.orgid and not vp.isvoid), 0) as subsidiarybalance
  from public.ws_tblvendors v
  group by v.orgid
),
bottle_cache as (
  select orgid, customerid, bottletypeid, balance from public.ws_tblcustomerbottlebalances
),
bottle_truth as (
  select orgid, customerid, bottletypeid, sum(qty)::int as balance
  from public.ws_tblbottletransactions
  where customerid is not null
  group by orgid, customerid, bottletypeid
)
select 'ar'::text as area, j.orgid,
       j.journalbalance, s.subsidiarybalance,
       round(j.journalbalance - s.subsidiarybalance, 2) as difference,
       null::bigint as customerid, null::bigint as bottletypeid
from ar_journal j
join ar_subsidiary s on s.orgid = j.orgid
where round(j.journalbalance - s.subsidiarybalance, 2) <> 0

union all

select 'ap', j.orgid, j.journalbalance, s.subsidiarybalance,
       round(j.journalbalance - s.subsidiarybalance, 2),
       null, null
from ap_journal j
join ap_subsidiary s on s.orgid = j.orgid
where round(j.journalbalance - s.subsidiarybalance, 2) <> 0

union all

select 'bottles', coalesce(c.orgid, t.orgid),
       coalesce(c.balance, 0)::numeric, coalesce(t.balance, 0)::numeric,
       (coalesce(c.balance, 0) - coalesce(t.balance, 0))::numeric,
       coalesce(c.customerid, t.customerid), coalesce(c.bottletypeid, t.bottletypeid)
from bottle_cache c
full outer join bottle_truth t
  on t.customerid = c.customerid and t.bottletypeid = c.bottletypeid
where coalesce(c.balance, 0) <> coalesce(t.balance, 0);

-- Unbalanced journal entries. Also must be empty; the deferred constraint
-- trigger should make this impossible, so a row here means the trigger was
-- disabled or a restore bypassed it.
create or replace view public.vw_ws_unbalancedentries
with (security_invoker = true) as
select
  j.orgid,
  j.journalid,
  j.entrydate,
  j.sourcetype,
  j.sourceid,
  sum(jd.debit)  as totaldebit,
  sum(jd.credit) as totalcredit,
  sum(jd.debit) - sum(jd.credit) as difference
from public.ws_tbljournalentries j
left join public.ws_tbljournalentrydetails jd on jd.journalid = j.journalid
group by j.orgid, j.journalid, j.entrydate, j.sourcetype, j.sourceid
having coalesce(sum(jd.debit), 0) - coalesce(sum(jd.credit), 0) <> 0
    or count(jd.detailid) = 0;

-- ─── Dashboard ───────────────────────────────────────────────────────────────

create or replace view public.vw_ws_dashboard
with (security_invoker = true) as
select
  o.orgid,
  (select coalesce(sum(d.amountcharged), 0) from public.ws_tbldeliveries d
   where d.orgid = o.orgid and not d.isvoid and d.deliverydate = current_date)      as todaysales,
  (select coalesce(sum(p.amountreceived), 0) from public.ws_tblpayments p
   where p.orgid = o.orgid and not p.isvoid and p.paymentdate = current_date)       as todaycollections,
  (select count(*) from public.ws_tbldeliveries d
   where d.orgid = o.orgid and not d.isvoid and d.deliverydate = current_date)      as todaydeliveries,
  (select coalesce(sum(v.outstandingdue), 0) from public.vw_ws_customerbalance v
   where v.orgid = o.orgid)                                                        as receivables,
  (select coalesce(sum(s.subsidiary), 0) from (
      select coalesce(sum(vn.openingbalance), 0)
             + coalesce((select sum(p.totalamount) from public.ws_tblpurchases p
                         where p.orgid = o.orgid and not p.isvoid), 0)
             - coalesce((select sum(vp.amountpaid) from public.ws_tblvendorpayments vp
                         where vp.orgid = o.orgid and not vp.isvoid), 0) as subsidiary
      from public.ws_tblvendors vn where vn.orgid = o.orgid
   ) s)                                                                            as payables,
  (select count(*) from public.ws_tblcustomers c
   where c.orgid = o.orgid and c.isactive)                                         as totalcustomers,
  (select coalesce(sum(b.balance), 0) from public.ws_tblcustomerbottlebalances b
   where b.orgid = o.orgid)                                                        as bottlesout,
  (select coalesce(sum(bp.instock), 0) from public.vw_ws_bottleposition bp
   where bp.orgid = o.orgid)                                                       as bottlesinstock,
  (select count(*) from public.vw_ws_reconciliation r
   where r.orgid = o.orgid)                                                        as reconciliationissues
from public.ws_tblorganization o;

-- ─── Grants: views inherit RLS via security_invoker, so SELECT is safe ────────
grant select on
  public.vw_ws_customerbalance,
  public.vw_ws_customerbottlebalance,
  public.vw_ws_bottleledger,
  public.vw_ws_bottleposition,
  public.vw_ws_customerledger,
  public.vw_ws_vendorledger,
  public.vw_ws_deliverycard,
  public.vw_ws_todaydeliveries,
  public.vw_ws_trialbalance,
  public.vw_ws_generalledger,
  public.vw_ws_reconciliation,
  public.vw_ws_unbalancedentries,
  public.vw_ws_dashboard
to authenticated;
