# QA Runbook — Web Build + Real Supabase E2E

Use after `QA_VERIFICATION_QUERIES.sql` Stage D (Q1–Q5) is clean.
**Do not start if Q4 shows `ws.test_uid`** — RLS results would be meaningless.

Code is frozen. Nothing in this runbook changes the repository.

---

## Secrets boundary

**Never send, paste in chat, or put in a screenshot**
database password · connection string / `$QA_DB` · `service_role` key · any JWT,
access or refresh token · OTP codes.

**Safe — needed for the build**
`SUPABASE_URL` · `SUPABASE_ANON_KEY` (anon/public only) · project ref.
All three ship inside the client bundle and are public by design. RLS is what
protects the data, which is exactly what Scenario 4 tests.

---

## Part 1 — Web release build

```bash
cd flutter

flutter build web --release \
  --dart-define=SUPABASE_URL=<qa-project-url> \
  --dart-define=SUPABASE_ANON_KEY=<qa-anon-key>
```

**Leave `.env` untouched.** It stays placeholder-only. `--dart-define` takes
precedence (`supabase_config.dart:79–83`), and `.env` is a declared asset
(`pubspec.yaml:92`) that ships downloadable — real values there would create a
second copy to forget about.

The app refuses to start if it detects a `service_role` key
(`supabase_config.dart:109`).

### Serve it

```bash
cd build/web
python3 -m http.server 8080
```

Then open `http://localhost:8080`.

---

## Part 2 — Browser preparation (do this before creating any data)

1. **Normal persistent profile.** Not incognito — Scenarios 5–9 need storage
   that survives a reload and a sign-out.
2. **Clear stale build artefacts.** DevTools → Application → Storage →
   **Clear site data**. Flutter ships a service worker
   (`flutter_service_worker.js`) that caches aggressively; without this you can
   silently test an older bundle pointing at a different project.
3. **Open DevTools** and keep Console + Network visible.
4. **Confirm the target.** The console must print
   `Supabase connected: <your QA URL>` (`main.dart:72`).
   **If the URL is not the QA project, stop.** Everything after this creates data.

---

## Part 3 — The nine scenarios

Run in this order. It is not arbitrary: 3 populates the data that 4 needs, and
5→6→7→8 is one continuous queue lifecycle.

Record for each: **PASS / FAIL / BLOCKED**, what you did, what you expected,
what actually happened, and the evidence.

---

### 1 · Registration / OTP
*Layers: app + Auth · needs: email, phone*

**Pre** No account for User A. The four dashboard settings recorded.

**Do** Register User A — email, password, org name, owner name, personal phone.

**Expect** Behaviour branches on dashboard config, and all of these are valid:
- session immediately (`mailer_autoconfirm` on) **or** `emailConfirmationPending`
- then `phoneOtpSent` → enter the SMS code → verified
- **or** `phoneAlreadyConfirmed` (`phone_autoconfirm` on)
- **or** `phoneProviderUnavailable` if no SMS provider — a valid outcome, not a failure

**Evidence** Which branch occurred; screenshot; whether an SMS arrived.

**PASS if** the branch matches the dashboard settings and nothing hangs.

---

### 2 · Organization provisioning
*Layers: app + DB · needs: SQL editor*

**Pre** 1 passed.

**Do** Complete registration through to the dashboard.

**Expect**
```sql
select orgname from public.ws_tblorganization;                       -- Org A
select storecode, isdefault from public.ws_tblstores;                -- MAIN | t
select count(*) from public.ws_tblmemberships;                       -- 1
select count(*) from public.ws_tblinternalusers;                     -- 1
select plancode, status, trialenddate from public.ws_tblsubscriptions;
                                              -- free | trialing | today + 30
select count(*) from public.ws_tblaccounts;                          -- > 0 (COA seeded)
select count(*) from public.ws_tblcustomers;                         -- 0
```

**PASS if** all seven hold — especially **0 customers**, which Scenario 3 depends on.

---

### 3 · Free-tier 50-customer cap
*Layers: app + DB trigger · needs: DevTools, SQL editor*

**Pre** Org A at 0 customers.

**Do**
1. Create customers until exactly **50** active. CSV import is fastest and
   exercises a second code path.
2. Confirm `select count(*) from public.ws_tblcustomers where isactive;` → **50**
   and the Account screen reads **"50 of 50"**.
3. Attempt customer **#51**.

**Expect**
- UI shows: *"Your free plan allows 50 active customers. Remove a customer you
  no longer serve, or upgrade the plan, then upload the file again."*
- **Not** a raw `PostgrestException`
- DevTools → Network shows `code: P0001`, message
  `plan limit reached: the free plan allows 50 active customers (currently 50)`
- Count is **still 50**; no #51 row exists

4. **Retry check** — submit the *same* save again. It must return the existing
   customer via the `clientuuid` short-circuit, **not** raise.

**PASS if** all four hold. The retry check is the regression `plan_limits.dart`
PL-4 protects.

---

### 4 · Real-JWT RLS isolation ★ highest risk
*Layers: RLS under a real JWT · needs: two users, DevTools, SQL editor*

This is the least-proven layer in the whole project. The SQL harnesses run as
superuser with `ws.test_uid`, so they prove policy *expressions*, not policy
*enforcement*.

**Pre** Org A holds ~50 customers. User B registered with **Org B**.

**Do** Signed in as **B**, attempt to read Org A's customers **through the app /
PostgREST**, carrying B's bearer token.

**Do NOT use the SQL Editor for this** — it runs privileged and bypasses RLS.
A pass there would prove nothing.

**Expect** **HTTP 200 with zero rows.** A working policy filters silently.
A 403 usually means a missing grant — a different failure.

**Also confirm**
- Q4 already showed `auth.uid()` free of `ws.test_uid`
- Q5 already showed RLS enabled **and forced**
- the request in DevTools carries an `Authorization: Bearer` header

**PASS if** zero rows returned and all three confirmations hold.

---

### 5 · Offline queue
*Layers: app + browser storage · needs: DevTools offline*

**Pre** A signed in, Org A.

**Do** DevTools → Network → **Offline**. Record a delivery. Save. Then **reload
the page**.

**Expect** Saved locally, marked *"Saved on this device — waiting to sync"*,
visible in A's Sync Queue, and **still there after the reload**.

**PASS if** it survives the reload.

> If it vanishes on reload, the cause is storage-backend selection, not queue
> logic: `ws_kv_default.dart` silently falls back to an in-memory store if
> `shared_preferences` throws. Use a normal (non-private) profile.

---

### 6 · Idempotent delivery
*Layers: app + DB · needs: DevTools, SQL editor*

**Pre** 5 complete, item still queued.

**Do** Restore connectivity. Let the drain run. Then force a replay of the same
`clientuuid`.

**Expect** Item → synced with a document id, and
```sql
select count(*) from public.ws_tbldeliveries where clientuuid = '<uuid>';  -- 1
```
**1 both times.**

**PASS if** the count is 1 after the replay.

---

### 7 · Sign-out warning
*Layers: app · needs: DevTools offline*

**Pre** At least one unsent item queued.

**Do** Sign out from the Account sheet. **Cancel.** Then sign out again and
confirm.

**Expect**
- Dialog titled **"Sign out?"**, count = pending + syncing + failed
- Copy matches the approved variant, e.g.
  *"This device has 1 item that hasn't been sent yet. Signing out will not
  delete it — it stays on this device until it can be sent."*
- **Cancel** → sheet stays open, session alive, queue untouched
- **Confirm** → signed out, and the **queued item is NOT deleted**

**PASS if** the count is right, Cancel is inert, and the item survives.

---

### 8 · Re-login / drain
*Layers: app + DB · needs: SQL editor*

**Pre** 7 complete, A signed out with work queued.

**Do** A signs back in.

**Expect** Queue survived the session transition; the drain posts the item;
server holds **exactly one** delivery for that `clientuuid`.

**PASS if** posted and no duplicate.

---

### 9 · Shared-device ownership ★ validates the release-gate fix
*Layers: app + DB · needs: two users, one browser profile, SQL editor*

Never run outside unit tests. This is the reason the ownership fix exists.

**Do**
1. A queues a delivery offline → visible in A's Sync Queue.
2. A signs out — warning fires and counts it. **Cancel** once (session and queue
   intact), then confirm.
3. Item survives sign-out.
4. **B signs in on the SAME browser profile. Do not clear storage.**
5. **B's Sync Queue must not list A's item** — no customer name, no amount.
6. Console check:
   ```js
   // both must return false
   discard('<A_uuid>')
   retry('<A_uuid>')
   ```
   A's item must remain present with `status`, `attempts` and
   `budgetedAttempts` unchanged.
7. B signs out. A signs back in. Item visible again; drain posts it.
8. ```sql
   select count(*) from public.ws_tbldeliveries where clientuuid = '<uuid>';  -- 1
   ```

**PASS if** 5, 6, 7 and 8 all hold.

**Also check** — an item queued after a session expiry (null owner) should be
visible to whoever signs in next and adopted wholesale by the first drain.

---

## Part 4 — Result template

```
Scenario 1  Registration / OTP ............ PASS / FAIL / BLOCKED
Scenario 2  Organization provisioning ..... PASS / FAIL / BLOCKED
Scenario 3  Free-tier 50-customer cap ..... PASS / FAIL / BLOCKED
Scenario 4  Real-JWT RLS isolation ........ PASS / FAIL / BLOCKED
Scenario 5  Offline queue ................. PASS / FAIL / BLOCKED
Scenario 6  Idempotent delivery ........... PASS / FAIL / BLOCKED
Scenario 7  Sign-out warning .............. PASS / FAIL / BLOCKED
Scenario 8  Re-login / drain .............. PASS / FAIL / BLOCKED
Scenario 9  Shared-device ownership ....... PASS / FAIL / BLOCKED

Dashboard settings observed
  mailer_autoconfirm : on / off
  phone_autoconfirm  : on / off
  external.phone     : enabled / disabled
  sms_provider       : <name> / none
```

**PRODUCTION READY requires all nine PASS**, and specifically 4, 9 and 3.

---

## Part 5 — If something fails

1. **Stop that scenario.** Do not carry on into a dependent one.
2. **Capture** the exact error, the failing screen, and the Network entry.
3. **Classify** — code defect / database / configuration / browser / procedure.
4. **Do not change code.** The 55006 incident is the precedent: a real failure
   with an environment cause and zero code changes.
5. Send me the evidence and I will diagnose read-only.

---

## Part 6 — Cleanup

Delete the whole QA project from the dashboard. There is no in-app
delete-account flow, so removing users individually is slower and less complete.
