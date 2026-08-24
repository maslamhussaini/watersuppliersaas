# CSV Import Recovery — Engineering Checkpoint

**Status: COMPLETE / CLOSED.** No blocker. No implementation pending from this scope.

Handoff record. Everything below is evidence-backed; where evidence is from an
earlier checkpoint rather than independently reproduced at close, it says so.

---

## 1. Completed work

**Planner resume/convergence verification.** The planner (`ws_csv_import.dart`)
is pure Dart and was executed directly against hand-built fixtures. Confirmed
that re-planning the same CSV after a partial application produces a correct
completion plan: already-applied rows come back as `unchanged`, a
created-but-unposted row comes back as `update` carrying the missing opening
balance, and untouched rows remain `create`. Also confirmed the harness copy at
`test_harness/lib/ws_csv_import.dart` is byte-identical to production, so
harness evidence transfers.

**Narrow Supabase-free applier seam.** `WsCsvImportService.apply()` previously
reached straight for the Supabase client and had therefore never been executed
by any test — the integration harness reimplements the apply loop rather than
importing it. A three-operation interface (`recordCustomer`, `updateCustomer`,
`setCustomerOpening`) plus a small deps bundle now sits between the applier and
Supabase. The interface file has zero imports.

Pattern follows `WsAuthGateDeps`: `apply(plan, {deps})` resolves
`deps ?? wsProductionCsvImportDeps()`, so the single production call site is
unchanged. `loadContext()`'s three reads were deliberately left outside the seam
— the planner takes context as data, so tests never needed them.

**Production Supabase adapter.** `WsSupabaseCsvImportOps` is the only file in
the import path that knows about Supabase. Every call was moved verbatim: same
RPC names, same twelve parameter keys in the same order, same `?? 0` on the
deposit, same `.eq('customerid').eq('orgid')` chain, same
`(result as num).toInt()` cast, exceptions still propagating raw.

**Real-applier tests.** 13 tests drive the actual production `apply()` with the
actual production planner, faking only the three writes.

**Lost-response modelling.** The test double models state rather than recording
calls, and commits before throwing. This matters: a fake that throws *before*
writing models a server rejection, which leaves a completely different database
behind. The fake is also idempotent on `clientuuid`, mirroring
`ws_record_customer`.

**Partial-application resume verification.** An injected opening-balance failure
produces a partial apply; the state is then re-planned through the real planner
and re-applied, converging with no duplicates.

**Reporting / UI recovery messaging.** The outcome card previously read
`"Import finished with problems — 3 created, 0 updated, 0 unchanged, 37 failed"`
followed by 37 raw `PostgrestException`s. It now reports what was saved and
states that re-uploading the same file is safe. Presentation only — every
counter and failure string is unchanged, and derived getters (`saved`, `failed`)
are asserted to be derivations.

**P0001 human-readable reporting.** A plan-limit refusal is recognised at the
reporting boundary and rendered as *"Your free plan allows 50 active customers.
Remove a customer you no longer serve, or upgrade the plan, then upload the file
again."* The number is parsed from the message migration 019 raises — nothing is
hard-coded, and a `basic` organization reads 500. The raw exception is retained
in `failures` for diagnostics.

**Corrected documentation.** Two comments were wrong and made the codebase look
self-contradictory:

- `ws_csv_import_apply.dart` cited "the header of ws_csv_import.dart for why
  partial imports are worse than none" — a phrase that does not appear there.
- `ws_csv_import.dart`'s header claimed a partly applied file "cannot simply be
  re-run, because the first 46 are now duplicates-in-waiting" — true when
  written, false since migration 014.

Both now distinguish validation failure (whole plan rejected, nothing written)
from runtime write failure (valid plan, rows may already have committed,
recovery is by re-upload).

**Final scope audit.** A whole-tree scan confirmed exactly eight changed files,
all inside the CSV import path.

---

## 2. Verified invariants

Evidence is separated by layer because the layers prove different things. SQL
evidence proves the database cannot duplicate; applier evidence proves the Dart
code drives that behaviour. They are not interchangeable.

| Guarantee | SQL evidence | Planner evidence | Applier evidence | UI evidence |
|---|---|---|---|---|
| No duplicate customer on replay | `014:105–114` clientuuid short-circuit returns before the insert; `master_data_idempotency` 74/0; `plan_limits` PL-4 (replay at the cap returns the same id) | Re-plan yields `update`, never `create`, for an existing row | `csv_import_apply_test` — replay returns the same id, three rows total | — |
| No duplicate opening journal | `017` sets an absolute `openingbalance`; `trg_customer_opening_sync` restates rather than appends; `customer_opening` COB-3 "still exactly ONE journal entry", COB-6 | Opening balances participate in change detection (`:557–563`) | Retry after a committed opening leaves 1000, not 2000 | — |
| No duplicate bottle transaction | `v_delta := p_openingqty − v_posted`, insert only when non-zero; `csv_import_write` "THE BOTTLES SURVIVED A BLANK CELL" | — | `openingQty` stable across retry | — |
| Same CSV converges after partial application | The two rows above, combined | Executed probe: `unchanged` / `update` / `create` split is correct and deterministic | "a partial import is completed by re-planning and applying again" | Pasted CSV survives a failed import (`_csv` never cleared), so re-upload is actionable |
| No-phone matching fails closed | — | Name+area, then name alone; `candidates.length > 1` → error row, never a guess. Normalisation tolerates case and whitespace | — | — |
| Customer commit + lost response recoverable | clientuuid key | Row matches on re-plan | Fake commits then throws; retry finds the existing customer, no duplicate | — |
| Opening commit + lost response recoverable | Convergent RPC | Re-plan sees the applied state | Retry does not double-apply | Card explains saved rows remain stored |
| Validation errors write nothing | — | `plan.hasErrors` set whole-file, up front | `apply()` throws `StateError` before any write; asserted that nothing was written | Preview blocks the Import button |
| Saved rows survive and are recoverable | All of the above | — | Partial apply leaves earlier rows committed | Outcome card states what was saved and that re-upload is safe |

---

## 3. Final changed-file inventory

**Production (5)**

1. `flutter/lib/services/import/ws_csv_import.dart` — header comment only
2. `flutter/lib/services/import/ws_csv_import_apply.dart` — seam wiring, presentation getters, doc comment
3. `flutter/lib/services/import/ws_csv_import_ops.dart` — **new**, interface + deps bundle, no vendor import
4. `flutter/lib/services/import/ws_csv_import_ops_supabase.dart` — **new**, adapter + production factory
5. `flutter/lib/screens/import_customers_screen.dart` — outcome card

**Tests (3)**

6. `flutter/test/csv_import_apply_test.dart` — **new**, 13 tests
7. `flutter/test/csv_import_reporting_test.dart` — **new**, 16 tests
8. `flutter/test/support/fake_csv_import_ops.dart` — **new**, state-modelling fake

**No migration or database object was modified.** Migrations remain 20 files
ending at `019_plan_limits.sql`; `014`, `017`, `019` and `008` hash-verified
unchanged, which covers `ws_record_customer`, `ws_set_customer_opening`,
`ws_lookup_clientuuid`, the RLS policies and the plan-limit triggers.

**No unrelated application area was modified** — outbox, auth, models, other
screens, other services, `test_harness/` and `database/` all reported zero files
touched during the work.

---

## 4. Accepted behaviours / technical debt

Recorded so the next reader inherits knowledge rather than a puzzle. **None is a
blocker, and none is an open task.** Each is characterised by a passing test, so
a future change to any of them will be caught rather than absorbed.

- **`created++` counts successful customer RPC returns, not proven inserts.**
  `ws_record_customer` returns a bare `bigint` and cannot distinguish an insert
  from a clientuuid replay. Display-only, one consumer. Correcting it would
  require an RPC contract change.
- **`updated++` counts an opening-only change as an updated row.** The increment
  sits outside the `patch.isNotEmpty` guard. Read as "rows changed" the counter
  is correct, and that is the more useful reading.
- **Runtime errors continue row-by-row.** A global failure produces one line per
  remaining row. Noisy, not unsafe. Whether to fail fast is a product decision
  and is *not* obvious: `P0001` is not globally terminal, because update rows
  keep succeeding after the cap is reached.
- **`loadContext()` remains outside the injected seam.** Deliberate — the
  planner takes context as data, so tests never needed those three reads.
- **The production adapter has no direct automated coverage.** ~40 lines of pure
  delegation. Parity was verified by a twelve-parameter positional inspection
  against the pre-seam source, and the underlying SQL contracts are separately
  tested by four harnesses. A drift here fails loudly and immediately on first
  use — PostgREST rejects an unknown named argument rather than substituting a
  default — so the failure mode is a visible error, not silent corruption.

---

## 5. Verification status

**Independently verified at the final read-only audit:**

| Check | Result |
|---|---|
| CSV planner + applier + reporting (35 + 13 + 16) | **64 passed** |
| `flutter analyze` | **4 issues** — the same four pre-existing infos |
| Sample of unrelated suites (`outbox_ownership`, `outbox`, `models`) | **64 passed** |
| Migrations | unchanged, hash-verified |

**From the previous checkpoint, not reproduced at close:**

| Check | Result |
|---|---|
| Full Flutter suite | **527 passed** — *a previous checkpoint result. It was NOT independently reproduced in the final audit; the `flutter test` runner is flaky in this sandbox on multi-file batches. Every batch that did run passed.* |
| `flutter build web --release` | passed; no source has changed since |
| SQL harnesses — `csv_import_write` 41/0, `plan_limits` 60/0, `master_data_idempotency` 74/0, `customer_opening` 60/0, `vendor_opening` 58/0 | passed previously; **deliberately not rerun** in the final read-only audit because they mutate the sandbox databases |

**Note for whoever runs the suite next:** `flutter test` intermittently reports
`No tests ran` or hangs at load on large multi-file invocations here. It is a
runner flake, not a code failure — `csv_import_test.dart` reported "No tests ran"
once and then passed 35/35 twice on retry, with `dart analyze` clean throughout.
Run in batches of 3–7 files.

The SQL harness databases are long-lived and accumulate rows. `plan_limits.dart`
and `csv_import_write.dart` establish their own baselines and are re-runnable in
place; the others assume a reasonably clean database.

---

## 6. Final status

**CSV import recovery: COMPLETE / CLOSED.**

No blocker. No implementation pending from this recovery scope.

The work added testability and honest reporting. It did not change behaviour:
the counters, the per-row error handling, the validation gate, the RPC payloads
and the database layer are all exactly as they were.
