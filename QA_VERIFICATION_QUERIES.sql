-- =============================================================================
-- QA_VERIFICATION_QUERIES.sql
-- Read-only checks for a fresh QA Supabase project.
--
-- Creates nothing, changes nothing. Safe to run repeatedly.
--
-- ORDER OF USE
--   STAGE A   run alone, BEFORE installing anything
--   STAGE D   run after install.sql and 019_plan_limits.sql have both succeeded
--
-- Usage:
--   psql "$QA_DB" -f QA_VERIFICATION_QUERIES.sql
-- or paste a section at a time into the Supabase SQL Editor.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- STAGE A — IS THE PROJECT CLEAN?
--
-- Run this FIRST, on the brand-new project, before install.sql.
-- EXPECT: 0 | 0 | 0
--
-- Anything non-zero means the project is not empty. Do NOT install over it —
-- discard the project and create another. A partial schema is how the previous
-- attempt produced a 55006 error that looked like a code defect and was not.
-- ═════════════════════════════════════════════════════════════════════════════

select
  (select count(*) from pg_tables
     where schemaname = 'public' and tablename like 'ws\_tbl%')          as tables,
  (select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'ws')                                              as ws_functions,
  (select count(*) from pg_namespace where nspname = 'ws')               as ws_schema;


-- ═════════════════════════════════════════════════════════════════════════════
-- STAGE D — Q1 .. Q5
-- Run only after BOTH of these have completed without error:
--     database/install.sql
--     database/migrations/019_plan_limits.sql
-- ═════════════════════════════════════════════════════════════════════════════


-- ── Q1 ── Migration 019's triggers exist ─────────────────────────────────────
-- EXPECT: 2
-- Anything else means 019 did not apply. install.sql does NOT contain it.
select count(*) as q1_trigger_count
  from pg_trigger
 where tgname in ('trg_customer_plan_limit_ins',
                  'trg_customer_plan_limit_upd');


-- ── Q2 ── The trigger function exists and is SECURITY DEFINER ────────────────
-- EXPECT: exactly 1 row  →  tg_customer_plan_limit | t
-- prosecdef must be t. Without it the trigger cannot read ws_tblsubscriptions
-- under a caller who has no direct grant on it.
select p.proname       as q2_function,
       p.prosecdef     as q2_security_definer
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'ws'
   and p.proname = 'tg_customer_plan_limit';


-- ── Q3 ── The free plan carries the cap the E2E test depends on ──────────────
-- EXPECT: exactly 1 row  →  free | 50 | 1
-- Scenario 3 creates 50 customers and expects the 51st to be refused.
select plancode      as q3_plan,
       maxcustomers  as q3_max_customers,
       maxusers      as q3_max_users
  from public.ws_tblplans
 where plancode = 'free';


-- ── Q4 ── THE GATE: real Supabase auth.uid(), not the local test shim ────────
-- EXPECT: exactly 1 row, and prosrc must NOT contain 'ws.test_uid'.
--
-- Migration 001 creates a local auth.uid() shim ONLY when no auth schema
-- exists (plain Postgres, CI, docker). On Supabase the schema is already
-- there, so the block is a no-op and the real GoTrue function survives.
--
-- If prosrc DOES contain ws.test_uid, the shim fired. STOP: every RLS result
-- afterwards would be meaningless, because RLS would be reading a session
-- variable instead of the JWT.
select p.proname as q4_function,
       p.prosrc  as q4_body
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'auth'
   and p.proname = 'uid';


-- ── Q5 ── RLS is enabled AND forced on every tenant table ────────────────────
-- EXPECT: 0 rows.
--
-- Acceptable exceptions if they appear: ws_tblpermissions and ws_tblplans.
-- RLS is disabled on those two deliberately — they are reference data granted
-- to authenticated and anon.
--
-- FORCE matters as much as ENABLE: without it the table owner bypasses its own
-- policies, which silently hides policy mistakes.
select relname               as q5_table,
       relrowsecurity        as q5_rls_enabled,
       relforcerowsecurity   as q5_rls_forced
  from pg_class
 where relname like 'ws\_tbl%'
   and (relrowsecurity = false or relforcerowsecurity = false)
 order by relname;


-- ═════════════════════════════════════════════════════════════════════════════
-- OPTIONAL — did install.sql actually finish?
-- A rough completeness signal. Not a substitute for Q1..Q5.
-- EXPECT on a full install: tables 35, ws functions ~48, views 15
-- ═════════════════════════════════════════════════════════════════════════════

select
  (select count(*) from pg_tables
     where schemaname = 'public' and tablename like 'ws\_tbl%')            as tables,
  (select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'ws')                                                as ws_functions,
  (select count(*) from pg_views
     where schemaname = 'public' and viewname like 'vw\_ws\_%')            as views,
  (select count(*) from pg_policies where schemaname = 'public')           as policies;
