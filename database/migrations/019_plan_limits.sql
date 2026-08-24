-- =============================================================================
-- 019_plan_limits.sql
-- Makes ws_tblplans.maxcustomers a rule the database keeps, not a number the
-- account screen displays.
--
-- ─── WHAT WAS ACTUALLY WRONG ─────────────────────────────────────────────────
--
-- Migration 002 defined four plans and seeded a limit for each. Migration 015's
-- provision_organization gives every new organization plancode='free', which
-- carries maxcustomers = 50. account_screen.dart:366 renders "12 of 50" from
-- those columns, so the product tells the user a limit exists.
--
-- Nothing enforced it. Grepping every migration for maxcustomers returns only
-- the column definition in 002 and the RLS grant in 008 — no trigger, no check
-- constraint, no guard inside ws_record_customer, no policy predicate. A free
-- organization could add its 51st, 500th and 5000th customer.
--
-- Client-side enforcement was never an option. The anon key ships inside
-- build/web/assets (see .env.example's own warning) and customers_write is
-- `for all to authenticated`, so anyone can POST straight to PostgREST and
-- skip ws_record_customer entirely. The rule has to live where the writes land.
--
-- ─── WHAT THIS MIGRATION DOES NOT DO ─────────────────────────────────────────
--
-- Only maxcustomers. Deliberately NOT enforced here:
--
--   maxusers        There is no operation to block. master_data_screens.dart
--                   sets canCreate:false on the staff screen and its create
--                   branch throws by design — staff accounts are made in
--                   Supabase Authentication. Every `insert into
--                   ws_tblinternalusers` in this schema is inside a
--                   provision_organization variant, creating the owner once.
--                   free.maxusers = 1 is already true by construction.
--
--   allowaccounting Journal entries post from in-transaction triggers on every
--   allowroutes     delivery, payment, purchase and vendor payment. Accounting
--   allowapi        is not a feature flag in this schema, it is the schema, and
--                   free.allowaccounting = false would brick every new signup
--                   on day one. Those three booleans stay display-only
--                   (account_screen.dart:579-581) until there is a product
--                   definition of what they gate.
--
-- No subscription-expiry logic. No backfill. No DML against ws_tblcustomers.
-- ws_record_customer is not modified, and neither is any other function,
-- policy or table.
--
-- ─── THE ENFORCEMENT POINT: A TRIGGER, FOR THE SAME REASON AS 016 ────────────
--
-- 016 put vendor opening balances in a trigger so the RPC, the setter and a raw
-- UPDATE would all produce identical books. Same argument here. Customers are
-- created through ws_record_customer from two callers (supabase_service.dart
-- and the CSV import), and the table is directly writable through PostgREST. A
-- BEFORE ROW trigger is reached by all of them; an RPC guard is reached by two.
--
-- RLS was considered and rejected: customers_write is `for all`, so a counting
-- predicate would also apply to UPDATE and DELETE and would stop an over-limit
-- organization from deleting its way back under the cap. That is the wrong
-- failure mode.
--
-- ─── WHY TWO TRIGGERS AND NOT ONE ────────────────────────────────────────────
--
-- WsCustomer.toInsert() (ws_models.dart:369) includes 'isactive', and the edit
-- path at supabase_service.dart:281 sends toInsert() on every save. PostgreSQL
-- fires `update of isactive` whenever the column appears in the SET list,
-- changed or not — so a plain `update of` trigger would run a plan lookup and a
-- count(*) on every name, phone and address edit in the product.
--
-- The WHEN clauses stop that. PostgreSQL evaluates WHEN WITHOUT entering the
-- function, so only the two transitions that can raise the active count cost
-- anything:
--
--   insert isactive = false        WHEN false   no query
--   insert isactive = true         WHEN true    checked
--   update of other columns        not matched  no query
--   update isactive true  -> false WHEN false   no query
--   update isactive true  -> true  WHEN false   no query   <- the ordinary edit
--   update isactive false -> true  WHEN true    checked    <- reactivation
--
-- An INSERT trigger's WHEN cannot reference OLD, which is why this is two
-- triggers rather than one `before insert or update of`.
--
-- Reactivation is unreachable from the app today — there is no restore or
-- undelete path anywhere in lib/, and the CSV import builds its patch map field
-- by field and never includes isactive. It is guarded because PostgREST can
-- reach it with the public anon key, not because the UI does it.
--
-- ─── SERIALISATION ───────────────────────────────────────────────────────────
--
-- Count-then-insert races: two sessions each read 49 and both commit, landing
-- at 51. A FOR UPDATE on the live subscription row was the first proposal, and
-- it is not sufficient on its own — an organization whose subscription has been
-- cancelled has NO live row, and locking a row that does not exist locks
-- nothing. That state is supported (see the plan resolution rules below), so
-- the serialisation primitive is a transaction-scoped advisory lock keyed on
-- the organization, taken unconditionally.
--
-- The FOR UPDATE is kept as well, and earns its place separately: it pins the
-- subscription row so a concurrent plan change cannot land between the lookup
-- and the insert.
--
-- The design review proposed the two-key form,
-- pg_advisory_xact_lock(regclass::oid, orgid), to keep this lock in a namespace
-- of its own. That overload does not exist: PostgreSQL's two-key form takes
-- (int4, int4) and only the single-key form takes bigint, so it failed with
-- 42883 the first time the harness ran it.
--
-- The single-key hashtextextended() form used by tg_bottletxn_compute (005:222)
-- is used instead, with an explicit namespace prefix in the hashed text. That
-- recovers the same property — 'ws.customer_plan_limit:1' cannot collide with
-- the bottle-balance key '1:1' — through the string rather than through a
-- separate key column. Same primitive, same per-organization scope, same
-- guarantee.
--
-- ─── PLAN RESOLUTION ─────────────────────────────────────────────────────────
--
--   live statuses     trialing, active, past_due — the same set
--                     fetchSubscription uses (supabase_service.dart:1208) and
--                     the set protected by ux_subscription_active_per_org.
--   past_due          keeps the plan's normal limits. No grace behaviour.
--   no live row       treated as the FREE plan. Not unlimited, and not a block:
--                     a lapsed organization keeps working within free limits.
--   maxcustomers null  unlimited (pro, enterprise). Stated at 002:262.
--
-- ─── BOUNDARY AND GRANDFATHERING ─────────────────────────────────────────────
--
-- The cap is inclusive: "48 of 50" means the 50th is allowed and the 51st is
-- not. A BEFORE ROW trigger sees the table without the pending row, so
-- count = 49 admits the 50th and count = 50 refuses the 51st. On reactivation
-- the row is still isactive = false and so is correctly absent from its own
-- count.
--
-- The count is `orgid = ? and isactive`, matching _countRows' .eq('isactive',
-- true) at supabase_service.dart:1236 — otherwise the card and the database
-- would disagree about the same number.
--
-- Existing over-limit organizations are grandfathered by construction. This
-- migration runs no DML against ws_tblcustomers and a write-time trigger never
-- evaluates rows at rest. An organization that downgrades from pro at 60
-- customers keeps all 60, may edit and deactivate them freely, and simply
-- cannot reach 61.
--
-- ─── IDEMPOTENCY ─────────────────────────────────────────────────────────────
--
-- ws_record_customer returns at 014:105-114 on a clientuuid hit, BEFORE the
-- INSERT. A save retried after a lost response therefore never reaches this
-- trigger and can never be refused for a seat it already occupies. That is why
-- the RPC is left alone rather than given a guard of its own.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. THE CHECK
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function ws.tg_customer_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_max    int;
  v_plan   text;
  v_active int;
begin
  -- Serialise every active-customer write for THIS organization. Transaction
  -- scoped, so it is released on commit or rollback with nothing to clean up.
  -- Unconditional: see the note above on why the subscription row lock cannot
  -- carry this on its own.
  perform pg_advisory_xact_lock(
            hashtextextended('ws.customer_plan_limit:' || new.orgid::text, 0));

  -- Pin the plan for the rest of the transaction where there is one to pin.
  perform 1
     from public.ws_tblsubscriptions
    where orgid = new.orgid
      and status in ('trialing', 'active', 'past_due')
      for update;

  select p.maxcustomers, p.plancode
    into v_max, v_plan
    from public.ws_tblsubscriptions s
    join public.ws_tblplans p on p.plancode = s.plancode
   where s.orgid = new.orgid
     and s.status in ('trialing', 'active', 'past_due');

  -- Cancelled, expired, or never subscribed. Falls back to free rather than to
  -- unlimited, and never blocks outright.
  if not found then
    select maxcustomers, plancode
      into v_max, v_plan
      from public.ws_tblplans
     where plancode = 'free';
  end if;

  -- null = unlimited (pro, enterprise). Also covers the case where the free row
  -- has somehow been deleted: no limit is knowable, so nothing is enforced.
  if v_max is null then
    return new;
  end if;

  select count(*)
    into v_active
    from public.ws_tblcustomers
   where orgid = new.orgid
     and isactive;

  if v_active >= v_max then
    raise exception
      'plan limit reached: the % plan allows % active customers (currently %)',
      v_plan, v_max, v_active
      using errcode = 'P0001',
            hint   = 'Deactivate a customer, or upgrade the plan.';
  end if;

  return new;
end
$$;

comment on function ws.tg_customer_plan_limit() is
  'Enforces ws_tblplans.maxcustomers on every path that raises an organization''s '
  'active customer count. Reached by ws_record_customer, by the CSV import and by '
  'a direct PostgREST insert alike. See 019_plan_limits.sql.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. THE TWO EVENTS THAT CAN RAISE THE COUNT
-- ═════════════════════════════════════════════════════════════════════════════

drop trigger if exists trg_customer_plan_limit_ins on public.ws_tblcustomers;
create trigger trg_customer_plan_limit_ins
  before insert on public.ws_tblcustomers
  for each row
  when (new.isactive)
  execute function ws.tg_customer_plan_limit();

drop trigger if exists trg_customer_plan_limit_upd on public.ws_tblcustomers;
create trigger trg_customer_plan_limit_upd
  before update of isactive on public.ws_tblcustomers
  for each row
  when (new.isactive and not old.isactive)
  execute function ws.tg_customer_plan_limit();


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. WHAT THIS LOOKS LIKE FROM THE CLIENT
-- ═════════════════════════════════════════════════════════════════════════════
--
-- errcode P0001 reaches PostgREST as HTTP 400 and Dart as a PostgrestException
-- with code 'P0001', carrying the message and the hint.
--
-- No Dart changes ship with this migration. Two consequences are worth having
-- written down:
--
--   · upsertCustomer catches nothing, so a refusal surfaces as an unhandled
--     exception. Presenting it properly is a separate item.
--
--   · If a customer operation is ever added to the outbox, no classifier change
--     is needed: ws_outbox_supabase.dart:339 already treats anything that is
--     not 23505 and not 5xx as PERMANENT, which is correct for a limit —
--     retrying cannot change the answer. Customers are online-only today; the
--     four enqueue sites are delivery, payment, purchase and vendor payment.
--
-- ─── VERIFY ──────────────────────────────────────────────────────────────────
--
--   dart run bin/plan_limits.dart      (test_harness)
--
-- covering the boundary, the direct-insert bypass, the CSV import path, a
-- same-clientuuid retry at the cap, soft-delete-then-create, reactivation, an
-- ordinary edit at the cap, a grandfathered over-limit organization, unlimited
-- pro, the no-subscription fallback, past_due, concurrent inserts, tenant
-- isolation, and a multi-row INSERT ... SELECT crossing the cap.
-- =============================================================================
