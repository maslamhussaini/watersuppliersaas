# Mineral Water SaaS — Database

Postgres / Supabase schema for the multi-tenant mineral water distribution and
billing system. Verified against PostgreSQL 16.2: all nine files apply cleanly
and `tests.sql` passes 52 assertions.

```
database/
├── preflight.sql                        READ-ONLY: what exists vs what is missing
├── migrations/
│   ├── 000_adopt_existing_schema.sql    upgrade a database that already has the old tables
│   ├── 001_extensions_and_helpers.sql   helper schema, tenant resolution primitives
│   ├── 002_tenancy_and_rbac.sql         organizations, membership, roles, permissions, plans
│   ├── 003_master_data.sql              areas, routes, bottle types, products, pricing, customers, vendors
│   ├── 004_accounting_core.sql          chart of accounts, journal, posting helpers
│   ├── 005_operations_and_triggers.sql  deliveries, bottle movements, payments, numbering
│   ├── 006_vendor_operations.sql        purchases, vendor payments
│   ├── 007_views.sql                    ledgers, delivery card, trial balance, reconciliation
│   └── 008_rls_policies.sql             row level security, audit log
├── seed.sql                             two organizations; org 1 reproduces the paper card
├── tests.sql                            52 assertions incl. cross-tenant isolation
└── DATABASE.md
```

## Applying

**Use `install.sql`.** It is migrations 000–008 concatenated in order, and the
Supabase SQL editor runs a script in a single transaction — so it either all
applies or none of it does. Running the files individually is what caused every
problem in this project so far.

```bash
# Supabase SQL editor: paste database/install.sql, run once. Done.

# psql — the -1 flag is what makes it atomic. Without it psql commits each
# statement separately and you are back to partial application.
psql "$DATABASE_URL" -1 -v ON_ERROR_STOP=1 -f database/install.sql

# Confirm: every row should read OK
psql "$DATABASE_URL" -f database/preflight.sql

# Dev databases only — these create their own organizations and tests.sql
# assumes the seed's org ids
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database/seed.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database/tests.sql
```

`install.sql` is safe to re-run: every statement is idempotent, and no data is
deleted. The numbered files under `migrations/` remain the readable source — but
apply them through `install.sql`.

### If you had data before the migration, you are not finished

`install.sql` creates the schema. It does not create the ROWS the new schema
needs to serve your existing data, and one of those omissions locks you out:

**RLS is now enforced, and every policy resolves through `ws_tblmemberships`.
A pre-existing organization has no membership rows** — memberships were only
ever created as a side effect of creating a brand new organization. So
`ws.is_member()` returns false for your own owner account and the app shows
empty screens with no error message. Verified: before bootstrap, the legacy
owner could see 0 organizations, 0 customers, 0 deliveries in their own database.

```bash
psql "$DATABASE_URL" -1 -v ON_ERROR_STOP=1 -f database/bootstrap_existing_data.sql
```

It backfills, per organization:

| | |
|---|---|
| roles + permissions | via `ws.ensure_org_roles()` |
| owner membership | from `ws_tblorganization.owneruserid` — **this is the lockout fix** |
| staff memberships | from `ws_tblinternalusers`, mapping the legacy free-text `role` onto a real role; anything unrecognised becomes `sales` |
| portal memberships | for customers that already have `authuserid` |
| chart of accounts + payment methods | `ws.seed_chart_of_accounts()` |
| default bottle type + returnable product | priced from your most common area rate, so customers keep being billed the same |
| bottle transactions | reconstructed per delivery from legacy `bottlesdelivered` / `bottlesreturned`, plus a derived opening row so the rebuilt closing balance equals the legacy `bottlebalance` exactly |
| journal entries | posted for legacy deliveries and payments |
| document sequences | advanced past existing rows so the first new delivery does not collide |

**Money is never recalculated.** Legacy `amountcharged` and `amountreceived` are
read, not rewritten. Repricing history from today's rate card would silently
restate what customers were actually billed.

Safe to re-run — the second run reports `bottle transactions rebuilt: 0` and
re-posts the same journal entries idempotently rather than duplicating them.
It ends by printing three counters that must all be zero: reconciliation drift,
unbalanced journal entries, and organizations with no members.

Two things it cannot decide for you, both printed as notices:

- the default bottle type is created with **deposit 0** — set your real deposit
- if an organization has no `owneruserid`, nobody can be granted owner access
  automatically; it warns and tells you the `update` to run

### Why running them one at a time went wrong

Each file depends on the ones before it. When one fails and the next is run
anyway, every later file reports a missing table that an earlier file should
have created — so one fault reads as many:

| Message | Actual cause |
|---|---|
| `column "owneruserid" does not exist` | the real error: 002 hit a pre-existing table |
| `function ws.is_member(bigint) does not exist` | 002 aborted before creating it |
| `relation "public.ws_tblvendors" does not exist` | 003 aborted |
| `relation "public.ws_tblbottletypes" does not exist` | 003 creates it; 005/007/008 only reference it |
| `relation "public.ws_tblpermissions" does not exist` | 002 creates it; 008 only references it |

The last two are the giveaway: they name tables that **later** files merely read.
Seeing them means 002 and 003 have still not completed, no matter how many times
the later files are re-run.

### If your database already has the old app's tables

`create table if not exists` does nothing when the table exists — including
when the existing table has the wrong columns. That is a real weakness of these
migrations on a non-empty database, and it produces exactly this:

```
ERROR: 42703: column "owneruserid" does not exist          <- 002 aborts here
ERROR: 42883: function ws.is_member(bigint) does not exist <- 002 never finished
ERROR: 42P01: relation "public.ws_tblvendors" does not exist
ERROR: 42P01: relation "public.ws_tblbottletypes" does not exist
ERROR: 42P01: relation "public.vw_ws_deliverycard" does not exist
```

Only the first line is a real error. Everything after it is fallout from 002
aborting at its eighth statement.

A pre-existing table brings its old CONSTRAINTS too, not just its old columns.
The original app constrained `ws_tblinternalusers.role` to `('admin','staff')`;
the new schema has six roles, so creating any organization failed with:

```
new row for relation "ws_tblinternalusers" violates check constraint
"ws_tblinternalusers_role_check"
```

Same for `ws_tblpayments.paymentmethod`, which was a fixed list and is now
tenant-defined so a business can add its own wallet.

`000_adopt_existing_schema.sql` fixes all of this. It:

- folds mixed-case column names (`"OrgID"` → `orgid`) to lowercase, since
  Supabase's table editor quotes identifiers and the old Dart read both
  spellings defensively;
- adds every column the new schema expects to the seven legacy tables, always
  nullable or with a default — adding a bare `NOT NULL` column to a populated
  table fails, and these tables have live rows;
- backfills `owneruserid` from the legacy `authuserid`;
- adds the unique constraints the new code relies on, downgrading to a warning
  when existing duplicates block one, so the rest of the schema still installs;
- drops legacy CHECK constraints on `role` and `paymentmethod`, whose value lists
  the new schema widens — announcing each drop by name and definition. It touches
  only those two columns; a blanket "drop every check" would silently remove
  business rules you added on purpose;
- drops the old `vw_ws_customerbalance`, because `create or replace view` in 007
  cannot change an existing view's column list.

It runs inside a single transaction, only ever adds, and deletes no data.
Running it twice changes nothing, and on an empty database it is a no-op.

### Idempotency

Migrations use `create ... if not exists`, `create or replace` and
`drop policy if exists`, so re-running is safe. `seed.sql` is NOT — it inserts
fresh auth users each time, and `tests.sql` assumes the seed's org ids (1 and 2),
so both are for a clean development database only.

---

## Read this first: what was actually broken

**Tenant isolation did not exist.** It lived entirely in Dart:
`WsTenantService._selectedOrgId` held an org id in a static field, and each
query appended `.eq('orgid', orgId)`. The Supabase anon key is compiled into the
Flutter web bundle and is therefore public. Anyone could take that key, call
`/rest/v1/ws_tblcustomers` directly with no `orgid` filter, and read every
tenant's customer list, phone numbers, addresses and outstanding balances. The
client-side filter was a convention, not a control.

Migration 008 closes that. `tests.sql` §12 proves it: authenticated as org 1's
owner, `select count(*) from ws_tblcustomers` with no filter returns 3 — org 1's
customers — and `where orgid = 2` returns 0.

Two related traps that are easy to reintroduce:

- **Views bypass RLS by default.** A Postgres view runs as its owner unless
  created `with (security_invoker = true)`. A reporting view over
  `ws_tblcustomers` without it hands every tenant's data to any caller. Every
  `vw_ws_*` view sets it, and `tests.sql` §13 fails the build if one does not.
- **`.env` is listed as a Flutter asset in `pubspec.yaml` and committed to the
  repo.** For web builds the asset is served to the browser. The anon key is
  meant to be public so this is survivable *now that RLS exists* — but it was
  not before, and if a `service_role` key ever lands in that file it is a total
  compromise. Remove `.env` from git, keep `.env.example`, and inject values at
  build time.

---

## Core model

```
ws_tblorganization
├── ws_tblmemberships ──── the ONLY table RLS consults
│     ├── ws_tblroles ──── ws_tblrolepermissions ──── ws_tblpermissions
│     ├── ws_tblinternalusers   (staff profile)
│     └── ws_tblcustomers       (portal login, via customerid)
├── ws_tblareas / ws_tblroutes / ws_tblcustomergroups
├── ws_tblbottletypes ──── ws_tblproducts ──── ws_tblproductprices
├── ws_tblcustomers
│     ├── ws_tbldeliveries ──── ws_tbldeliverydetails
│     ├── ws_tblpayments
│     └── ws_tblbottletransactions ──── ws_tblcustomerbottlebalances (cache)
├── ws_tblvendors
│     ├── ws_tblpurchases ──── ws_tblpurchasedetails
│     └── ws_tblvendorpayments
└── ws_tblaccounts ──── ws_tbljournalentries ──── ws_tbljournalentrydetails
```

### Why membership is its own table

The original code resolved "which orgs can I see" from
`ws_tblinternalusers UNION ws_tblcustomers`. Making RLS policies on those tables
consult those same tables produces `infinite recursion detected in policy`.
`ws_tblmemberships` breaks the cycle: its own policy is a bare
`authuserid = current_uid()` self-check touching nothing else, and every other
policy reaches it through `ws.is_member()` / `ws.has_perm()`, which are
`SECURITY DEFINER` and live in the private `ws` schema so PostREST cannot call
them.

### Three ledgers, as specified

| Ledger | Truth | Read via |
|---|---|---|
| Money — customers | `ws_tbldeliveries` + `ws_tblpayments` | `vw_ws_customerledger`, `vw_ws_customerbalance` |
| Money — vendors | `ws_tblpurchases` + `ws_tblvendorpayments` | `vw_ws_vendorledger` |
| Bottles | `ws_tblbottletransactions` (append-only) | `vw_ws_bottleledger`, `vw_ws_customerbottlebalance` |

### Invariants the database enforces

- `balanceafter = balancebefore + qty` on every bottle transaction (check constraint).
- Bottle transactions reject `UPDATE` and `DELETE`. Corrections are compensating
  `adjustment` rows, so history always explains the balance.
- Every journal entry balances to zero, checked by a **deferrable** constraint
  trigger at commit — so an entry can be built line by line and still be checked.
- Manual journal entries cannot touch the AR or AP control accounts.
- No row may reference a parent in another organization (`ws.assert_same_org`).
- A product either declares a bottle type and `bottlesperunit >= 1`, or declares
  neither. No half-configured returnables.
- One default bottle type per organization (partial unique index).
- No two overlapping price windows for the same product and scope.

---

## Decisions you made, and the risk you took

### Bottle balance: per bottle type

`ws_tblcustomerbottlebalances` is keyed `(customerid, bottletypeid)`.
`ws_tblcustomers.bottlebalance` survives as a **cache of the default type only**,
maintained by trigger, so the current Flutter build keeps working. Do not write
to it. The seed includes a customer holding both a 19L and a 20L bottle — the
case a single integer cannot represent.

### Accounting: both, journal derived

You chose the option with the highest drift risk: two representations of the same
balance that can disagree. Two things reduce that risk to something manageable:

1. **No background poster.** Journal entries are written by `AFTER` triggers in
   the same transaction as the source row. Either both exist or neither does. A
   crash cannot leave them out of step, because there is no window between them.
   The cost: a posting-rule bug now aborts the delivery insert instead of quietly
   producing a wrong report. That is the correct trade.
2. **`vw_ws_reconciliation` must always return zero rows.** It compares the AR
   and AP control accounts against the subsidiary sums, and the bottle cache
   against recomputed history. Surface `reconciliationissues` from
   `vw_ws_dashboard` on the admin screen. A non-zero value means a posting rule
   is wrong and reports have started lying.

If reconciliation ever goes non-zero and you cannot find the cause within a day,
the honest fallback is to drop to subsidiary-only and derive the trial balance
from the transaction tables. That is a smaller loss than shipping numbers you
cannot defend.

### Payments are balance-forward, not invoice-allocated

Money reduces the running balance; it is not matched to a specific delivery. That
is what the paper card does. Per-invoice aging would need a
`ws_tblpaymentallocations` child table — nothing else changes. Do not add it
before a real customer asks, because it doubles the reconciliation surface.

---

## The delivery card

`vw_ws_deliverycard` returns exactly the physical card's columns:

| entrydate | deliverybottles | receivedbottles | bottlebalance | totalamount | amountreceived | runningbalance |
|---|---|---|---|---|---|---|

Verified against the card in `tests.sql` §1 (opening balance 4, rate Rs 250):

| Date | Delivered | Received | Balance | Amount | Received |
|---|---:|---:|---:|---:|---:|
| 01-07 | 4 | 3 | 5 | 1,000 | 1,000 |
| 02-07 | 5 | 3 | 7 | 1,250 | 0 |
| 03-07 | 3 | 4 | 6 | 750 | 750 |

Closing: 6 bottles out, Rs 1,250 outstanding.

Two details worth knowing:

- `bottlebalance` is recomputed from transaction history as at that date, not read
  from the delivery row's snapshot. A backdated delivery therefore still produces
  a correct card, where a stored snapshot would leave every later row wrong.
- Days with a payment but no delivery still appear, so cash collected on a
  no-delivery visit is not silently dropped.

Report layout is data, not code: `ws_tblorganization.cardsettings` holds page
size, column list and signature/deposit flags per tenant.

---

## Client-callable RPCs

Everything else is table reads through PostgREST. These exist because they must
be atomic or must not be re-implemented in Dart.

| Function | Purpose |
|---|---|
| `ws_create_organization(name, owner, phone, address, currency)` | Creates the org, seven default roles with permission sets, the owner membership, the staff record and a 14-day trial — in one transaction. Replaces the current multi-step client sequence, which can leave an org with no membership row if a later insert fails. |
| `ws_seed_chart_of_accounts(orgid)` | Default 15-account chart plus payment methods wired to settlement accounts. |
| `ws_record_delivery(customerid, date, delivered, returned, productid, amountpaid, method, driver, route, notes)` | The one call the delivery screen needs. Delivery + line + bottle movements + payment + journal, atomically. |
| `ws_set_customer_opening(customerid, due, bottletypeid, qty, asof)` | Opening money and bottle balances as real transactions, so the ledger ties to the journal. |
| `ws_set_vendor_opening(vendorid, opening, asof)` | Same for vendors. |
| `ws_resolve_price(orgid, productid, customerid, on)` | Price preview. Never reimplement precedence in Dart. |
| `ws_rebuild_bottle_balances(orgid)` | Recomputes the cache from history. Run after a bulk import. |

### Price precedence

`customer > customer group > area > organization default`, each with an effective
date window. Legacy fallbacks (`ws_tblcustomers.rateoverride`,
`ws_tblareas.rateperbottle`) apply **only to the default returnable product** —
they describe a per-bottle rate, and applying them to everything billed a case of
500ml bottles at the 19L water rate. The first test run caught exactly that.

---

## Required Flutter changes

The schema is backwards-compatible where it reasonably can be. These are the
client changes that are still needed, in order of severity.

### 1. PostgREST returns lowercase keys — several reads are dead

Column names come back exactly as stored, i.e. lowercase. Code that reads
PascalCase keys gets `null` unconditionally.

`lib/services/auth_service.dart`, `resolveRole()`:

```dart
return internal['Role'] == 'admin' ? WsUserRole.admin : WsUserRole.staff;
```

`internal['Role']` is always null, so **every admin is silently downgraded to
staff**. Should be `internal['role']`.

`lib/services/supabase_service.dart`, `fetchDashboardStats()` reads
`r['BottleBalance']`, `r['BottlesDelivered']`, `r['BottlesReturned']` and
`r['OutstandingDue']`. All four are always null, so the dashboard renders zeros
regardless of the data. Use lowercase, or better, read `vw_ws_dashboard` in a
single query instead of three client-side full-table folds.

Other model `fromJson` methods are safe — they use `j['x'] ?? j['X']`.

### 2. `upsert` without the primary key duplicates rows

`WsCustomer.toInsert()` and `WsArea.toInsert()` omit `customerid` / `areaid`, and
`upsertCustomer()` / `upsertArea()` pass the result to `.upsert()`. With no
conflict target and no key, every edit inserts a new row. Include the primary key
when updating, or use `.update().eq(...)` for edits and `.insert()` for creates.

### 3. `resolveRole` throws for multi-org users

`maybeSingle()` raises `PGRST116` when more than one row matches. A user who
belongs to two organizations, called with `orgId == null`, hits that. The
multi-org story is broken at the auth layer. Replace role resolution entirely:
call `ws.has_perm()` server-side rather than mapping to the three-value
`WsUserRole` enum, which cannot express the six roles the spec asks for.

### 4. The PDF module does not compile and cannot run on web

- `lib/ws_bottle_ledger_pdf.dart` line 22 does
  `import 'ws_customer_ledger_pdf.dart' show ... _ShareOption;`. `_ShareOption`
  is library-private; importing it across files is a compile error.
- Both PDF files import `dart:io` and use `File` + `getTemporaryDirectory()`.
  `vercel.json` indicates a web deployment, where `dart:io` is unavailable. Use
  `Printing.sharePdf(bytes: ...)`, which works on all targets.
- Both redefine `WsOrganization` and `WsBottleCondition`, colliding with
  `lib/models/ws_models.dart`.
- Neither file is imported anywhere in `lib/`. They are dead code today.

Rebuild the card generator against `vw_ws_deliverycard` and
`ws_tblorganization.cardsettings`.

### 5. Registration should be one RPC

`AuthService.registerOrganization()` does `signUp` → insert org → insert internal
user as three separate round trips. If the second insert fails, the org exists
with no members and is invisible to its own creator. Replace with
`supabase.rpc('ws_create_organization', params: {...})`.

### 6. Delivery + payment should be one RPC

`delivery_screen.dart` inserts the delivery, then the payment. If the payment
insert fails, the delivery is already committed and the money is lost. Replace
with `supabase.rpc('ws_record_delivery', params: {...})`.

### 7. Stop sending derived columns

`WsDelivery.toInsert()` no longer needs `bottlebalance`, `rateapplied` or
`amountcharged` — triggers compute them and the seal trigger discards client
values. Sending them is harmless but misleading.

---

## Operational checks

Put these on the admin dashboard or in a scheduled job. Each should return zero.

```sql
select count(*) from vw_ws_reconciliation;      -- journal vs subsidiary drift
select count(*) from vw_ws_unbalancedentries;   -- broken journal entries

-- any view that bypasses RLS
select relname from pg_class
where relkind = 'v' and relnamespace = 'public'::regnamespace
  and relname like 'vw\_ws%'
  and not coalesce(array_to_string(reloptions, ',') like '%security_invoker=%true%', false);

-- any tenant table without RLS or without policies
select t.tablename from pg_tables t
join pg_class c on c.relname = t.tablename and c.relnamespace = 'public'::regnamespace
where t.schemaname = 'public' and t.tablename like 'ws\_tbl%'
  and t.tablename not in ('ws_tblpermissions','ws_tblplans')
  and (not c.relrowsecurity
       or not exists (select 1 from pg_policies p
                      where p.schemaname='public' and p.tablename=t.tablename));
```

---

## Not built yet

Deliberately out of scope for this pass, in rough priority order:

1. **Recurring delivery schedules** (spec §20). Needs a
   `ws_tblcustomerschedules` table and a generator that produces
   `vw_ws_todaydeliveries` rows in advance. Straightforward on this schema.
2. **Driver day-end reconciliation** (spec §21: loaded / delivered / returned /
   damaged). The bottle ledger already supports it; needs a route-load document.
3. **Plan limit enforcement.** `ws_tblplans` carries `maxcustomers` and
   `maxusers`; nothing checks them. Add a trigger on customer and membership
   insert.
4. **Payment allocation to invoices.** See above — wait for demand.
5. **Inventory valuation.** Purchases debit Inventory; nothing credits it on
   sale, so COGS is never recognised. Fine for a cash-basis view of the business,
   wrong for a real P&L. Needs a costing method decision (weighted average is the
   usual answer here).
6. **Bottle deposit accounting.** `ws_tblbottletypes.depositamount` and account
   2100 exist and `vw_ws_customerbalance` exposes `bottledepositvalue`, but no
   journal entry moves the deposit liability. Decide first whether deposits are
   refundable in practice; if they are not, they are revenue, not a liability.
