# Production QA Checkpoint — WaterFlow

Read-only inventory. No code, test, migration, database object or configuration
was modified to produce this document; it is the only file created.

Closed decisions are recorded here as settled and are **not** to be reopened:
CSV Contract B, Migration 019, sign-out wording and count semantics, and the
device-scoped sign-out warning.

---

## Status corrections applied

**Migration 019 / Plan limits — ✅ COMPLETE** (previously tracked as 0%, which
was wrong).

- `database/migrations/019_plan_limits.sql` exists, 14,908 bytes, dated
  2026-08-16, and is the newest migration in the tree.
- Contains `ws.tg_customer_plan_limit()` plus `trg_customer_plan_limit_ins` and
  `trg_customer_plan_limit_upd`.
- `plan_limits.dart`: **60 passed, 0 failed**, re-runnable in place.
- Applied and verified against five sandbox databases (`ws_plan`, `ws_md`,
  `ws_csv`, `ws_cob`, `ws_vob`, `ws4`).
- Hash `79ec93b3…`, unchanged across every checkpoint since it landed.

**CSV Import — ✅ COMPLETE**, with five accepted items recorded as debt rather
than blockers:

1. `created++` counts successful customer RPC returns, not proven inserts.
   Display-only, one consumer; correcting it needs an RPC contract change.
2. `updated++` may count an opening-only change as an updated row. Correct when
   read as "rows changed".
3. Runtime errors continue row-by-row **by deliberate Contract B design**. Not
   to be changed.
4. `loadContext()`'s three reads remain outside the test seam, deliberately.
5. `WsSupabaseCsvImportOps` has no direct automated coverage. Testability debt,
   blocked on live Supabase/`.env` configuration.

### Recorded explicitly

- **Validation errors remain all-or-nothing.** Enforced at `apply()`'s
  `plan.hasErrors` guard; a faulty plan writes nothing.
- **Runtime partial application is intentional.** Rows apply through separate
  PostgREST requests with no transaction around them.
- **Recovery is by re-uploading the same file.** `ws_record_customer` is
  idempotent on `clientuuid`, `ws_set_customer_opening` is convergent, and the
  planner re-derives the delta from live state.
- **The import does not claim transaction-wide rollback**, and cannot: there is
  no session-level `BEGIN`/`COMMIT` available to a REST client. Atomicity would
  require a new server-side batch RPC.
- **No CSV implementation work is pending.**

---

## A. Feature / status matrix

| Area | Status | Basis |
|---|---|---|
| Core architecture | ✅ Complete | 20 migrations, RLS on every table, seam pattern used consistently across auth, location, registration, outbox and CSV |
| Accounting | ✅ Complete | In-transaction journal posting; `vw_ws_reconciliation` = 0 and zero unbalanced entries asserted across five harnesses |
| Offline / sync | ✅ Complete | Durable outbox, `clientuuid` idempotency, owner attribution, adopt-on-first-sign-in, drain deferral without a session |
| Registration | ✅ Complete (code) | Config-invariant state machine; every branch covered offline. **End-to-end unverified** — see blockers |
| Security / ownership | ✅ Complete, one open finding | Ownership guard + `has_perm` + org derived from entity. `WsSyncScreen` exposure open — see § E |
| CSV import | ✅ Complete | Planner, applier seam, reporting; five accepted debt items above |
| Sign-out | ✅ Complete | Device-scoped warning, shared action, source-audit bypass protection |
| Plan limits / Migration 019 | ✅ Complete | Trigger-enforced customer cap; corrected from 0% above |
| **Final production QA** | ⏳ This document | — |

---

## B. Test and build evidence

**Independently verified at this checkpoint:**

| Check | Result |
|---|---|
| `flutter analyze` | **4 issues** — all pre-existing infos |
| Migrations | 20 files, ending at `019_plan_limits.sql`, hash `79ec93b3…` |
| Test inventory | 29 Flutter test files, 11 integration harnesses |
| `.env` | **Byte-identical to `.env.example`** — still unconfigured |

**Established at recent checkpoints:**

| Check | Result |
|---|---|
| Full Flutter suite | **541 passed, 0 failed** (four batches: 133 + 187 + 128 + 93) |
| Sign-out | **14 / 14** |
| CSV planner + applier + reporting | 64 (35 + 13 + 16) |
| `flutter build web --release` | ✓ Built build/web |
| `plan_limits.dart` | **60 / 0** |
| `csv_import_write.dart` | 41 / 0 |
| `master_data_idempotency.dart` | 74 / 0 |
| `customer_opening.dart` | 60 / 0 |
| `vendor_opening.dart` | 58 / 0 |
| `outbox_matrix.dart` | 160 / 0 |
| `rpc_integration.dart` | 67 / 0 |

Harness total **520 assertions**. Harnesses were not re-run here because they
mutate the sandbox databases.

**Runner note for whoever runs the suite next:** `flutter test` intermittently
reports `No tests ran` or hangs at load on large multi-file invocations in this
sandbox. It is a runner flake, not a code failure — `csv_import_test.dart`
reported zero once and then passed 35/35 twice on retry with `dart analyze`
clean. Run in batches of 3–8 files.

---

## C. Remaining production-QA risks

### Actual blockers

**1. Supabase Auth configuration — externally blocked.** `.env` is byte-identical
to `.env.example`; no project is configured. This blocks *confirmation*, not
correctness: the registration layer infers server behaviour rather than reading
it, and every branch is covered offline. But nothing has ever run against a real
project.

Missing: `SUPABASE_URL` and `SUPABASE_ANON_KEY` (via `.env` **or** `--dart-define`,
which takes precedence), plus dashboard Auth settings — `mailer_autoconfirm`,
`phone_autoconfirm`, `external.phone`, `sms_provider` — which cannot be supplied
from the repository at all.

**2. No production smoke test has ever been performed.** Follows from (1). Sign-up,
OTP delivery, provisioning, RLS under a real JWT, and the plan-limit trigger
under a real session are all unexercised end to end.

### Accepted technical debt — none blocking

- The five CSV items listed above.
- Four pre-existing analyzer infos (`account_screen.dart:597`,
  `master_data_screens.dart:60/62/62`).
- Harness fixture isolation: `plan_limits.dart` and `csv_import_write.dart`
  establish their own baselines; the others assume a reasonably clean database
  and will eventually hit the 019 customer cap as their databases accumulate.
- `WsSupabaseCsvImportOps` parity verified by inspection, not by test.

### Product decisions outstanding

- **Business-phone fallback** (`DECISIONS.md`) — a blank business phone
  publishes the OTP-verified personal number as the organization's contact.
- **Android / iOS platform targets** — web-only today; `.metadata` declares
  `root` and `web` only.
- **CSV fail-fast vs continue** — deferred by design. Note `P0001` is *not*
  globally terminal, because update rows keep succeeding after the customer cap
  is reached, so naive fail-fast would abandon work that would have applied.
- **Trial expiry** — `provision_organization` sets `trialenddate = +30 days` and
  nothing transitions a subscription out of `trialing`. Trials currently run
  forever.

### Pre-existing findings

- Free-tier feature flags `allowaccounting`, `allowroutes`, `allowapi` are
  displayed but not enforced, deliberately: accounting is not a feature flag in
  this schema, and enforcing `free.allowaccounting = false` would brick every
  new signup.
- `maxusers` is unenforced and unenforceable — there is no in-app invite path.

---

## E. Out-of-scope security finding — requires a decision

**`WsSyncScreen` is owner-unfiltered.**

`sync_screen.dart:257` renders `box.items`, which is `List.unmodifiable(_items)`
— the raw queue, not filtered by `authUserId`. The drain filters by owner; the
screen does not.

A signed-in user can therefore, for **another** user's queued work on a shared
device:

- read `item.label`, which carries customer/vendor names and amounts
  (`'Payment $amount — $customerName'`, `'$delivered out / $returned in —
  $customerName'`);
- read creation time, attempt count and `clientUuid`;
- **permanently discard it** via the Discard button.

They cannot sync it — the drain refuses another owner's item — and the raw RPC
`args` are never rendered. The owner is never displayed, so the exposure is
data-without-attribution.

This is **pre-existing**, surfaced during the outbox audits, and was out of
scope everywhere it appeared. It is the largest untriaged finding in the
project. Classification: **security / privacy backlog item requiring an explicit
decision** — not fixed, not scheduled.

---

## F. Recommendation

**One thing must happen before production release: connect a real Supabase
project and run an end-to-end smoke test.** Everything else is verified as far
as it can be without one.

Minimum smoke path once credentials exist: sign up → OTP → provision an
organization → create a customer → cross the 50-customer free cap and confirm
`P0001` surfaces with the human-readable message → queue a delivery offline →
sign out and confirm the unsent-work warning → sign back in and confirm the
drain posts → verify RLS isolation between two organizations under real JWTs.

**Second, decide `WsSyncScreen` filtering** (§ E) before shipping to any
customer who shares a device between drivers. It is a one-line filter if the
answer is "user-scoped", but the decision is yours and it changes what the sync
screen means.

Everything else — the four product decisions, the analyzer infos, the CSV debt,
harness fixture isolation — can ship as-is and be scheduled afterwards.

**No implementation is pending from any closed scope.**
