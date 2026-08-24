# Flutter fixes

Verified with Flutter 3.44.8 / Dart 3.12.2.

| Check | Before | After |
|---|---|---|
| `flutter analyze` | 65 issues, **25 errors** | **No issues found** |
| `flutter test` | 1 test | **26 tests, all passing** |
| `dart compile js` (web) | would not compile | **12 MB main.dart.js produced** |

The 25 errors were all in the two PDF files, which nothing imported — so the app
ran fine and the delivery-card feature simply did not exist.

---

## Correctness bugs

### 1. Every admin was silently demoted to staff

`auth_service.dart` decided the role with:

```dart
return internal['Role'] == 'admin' ? WsUserRole.admin : WsUserRole.staff;
```

PostgREST returns column names exactly as stored — `role`, never `Role`. The key
was always `null`, the comparison always false. Owners could not reach
admin-only screens in organizations they owned.

Nothing failed loudly, which is why it survived: a demoted admin looks like a
permissions decision, not a bug.

Role resolution now reads `ws_tblmemberships` joined to `ws_tblroles`, the same
table RLS consults, so client and server cannot disagree.

### 2. The dashboard always showed zeros

`fetchDashboardStats()` ran three full-table scans and folded them client-side
reading `r['BottleBalance']`, `r['BottlesDelivered']`, `r['BottlesReturned']`
and `r['OutstandingDue']`. Same casing fault, four times. Every tile rendered 0
regardless of the data underneath.

Replaced with one read of `vw_ws_dashboard`.

### 3. Editing a customer created a duplicate

```dart
await supabase.from('ws_tblcustomers').upsert(c.toInsert());
```

`toInsert()` omits the primary key, and no conflict target was specified, so
PostgREST had nothing to match on. Every save inserted a new row. Same bug in
`upsertArea()`.

Now `insert` when the id is 0, `update ... .eq(pk)` otherwise. Covered by a
test asserting `toInsert()` has no `customerid` and `toUpdate()` does.

### 4. Multi-organization users crashed at login

`resolveRole()` called `.maybeSingle()` on a query filtered only by
`authuserid`. `maybeSingle()` raises `PGRST116` when more than one row matches —
so a user belonging to two organizations threw on sign-in. That is the exact
multi-tenant case the product is built around.

Now `.limit(1).maybeSingle()`, with `orgId` supplied from the tenant service.

### 5. A delivery could be recorded without its payment

`delivery_screen.dart` inserted the delivery, then inserted the payment as a
second call. If the second failed — dropped connection on a delivery round,
expired token, RLS rejection — the delivery had already committed. The customer
was billed and the cash they had just handed over was recorded nowhere.

Both now go through `ws_record_delivery`, one server-side transaction that also
computes the bottle movements, resolves the price and posts the journal entries.

### 6. Registration could orphan an organization

`registerOrganization()` did signUp → insert org → insert internal user as three
round trips. A failure after the first left an organization with no members,
invisible to its own creator and unrepairable from the app.

Now one `ws_create_organization` call. It also handles the email-confirmation
case: when signUp returns a user but no session, the RPC would run
unauthenticated, so provisioning is deferred rather than failing silently.

### 7. `(a ?? b as num)` parses the wrong way

```dart
ratePerBottle: (j['rateperbottle'] ?? j['RatePerBottle'] as num).toDouble(),
```

Dart binds `as` tighter than `??`, so this is `j['a'] ?? (j['B'] as num)` — the
cast applies only to the fallback, and when both keys are absent it throws a
`TypeError` on `null as num`. Present in `WsArea`, `WsDelivery` (twice) and
`WsPayment`.

Replaced with typed helpers that also cope with `numeric` columns arriving as
JSON strings.

### 8. The "Delivered By" dropdown was a mock

```dart
value: 'Tanveer Ahmed (Admin)',
items: const [DropdownMenuItem(value: 'Tanveer Ahmed (Admin)', ...)],
onChanged: (v) {},
```

`_staff` was declared but never populated. Every delivery saved a null driver,
so route accountability did not work. Now loads real staff and binds `_selStaff`.

### 9. The price preview contradicted the invoice

The screen previewed `WsCustomer.effectiveRate`, i.e. `rateOverride ?? areaRate`.
That cannot see customer-group pricing or effective-date windows. A customer in
a discounted group was shown Rs 250 on screen and billed Rs 230.

Now calls `ws_resolve_price` server-side, falling back to the local estimate
only while the request is in flight. `effectiveRate` is documented as
display-only.

### 10. An unknown payment method silently became cash

`WsPayment.fromJson` defaulted any unrecognised code to `cash`, which overstates
the cash drawer at day-end. Unknown codes now map to `other`.

---

## Security

### `.env` was shipped to browsers

`pubspec.yaml` declared `.env` as a Flutter asset. On web every asset is copied
into `build/web/assets` and served. Configuration now comes from `--dart-define`,
with a local `.env` read only when `!kReleaseMode`:

```bash
flutter build web --release \
  --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOi...
```

The anon key is public by design, so shipping it is tolerable — **but only
because RLS now stands behind it**. Before the database migrations it was the
only thing between a stranger and every tenant's customer list. Never put a
`service_role` key in a dart-define or an asset; it bypasses RLS entirely.

### Roles replaced with permissions

`WsUserRole` has three values; the system defines six staff roles plus a portal
role. Any widget saying `if (role == admin)` was wrong for four of them.
`WsPermissions` now carries the permission codes loaded once per organization
from the caller's membership.

Switching organizations clears the cache — otherwise an owner in org A would
keep owner-level UI in org B, where they may only be a driver. RLS would refuse
the writes, but the UI would be offering buttons that always fail.

This is a UI convenience. **Hiding a button is not access control**; the
database enforces the same rules through `ws.has_perm()`.

---

## The PDF module

`lib/ws_customer_ledger_pdf.dart` and `lib/ws_bottle_ledger_pdf.dart` are
deleted and replaced by `lib/reports/ws_delivery_card_pdf.dart`.

What was wrong with them:

- `ws_bottle_ledger_pdf.dart` imported `_ShareOption` from the other file with a
  `show` clause. A leading underscore makes a declaration library-private;
  naming it in an import is a hard compile error.
- Both used a hand-maintained `show` list on `package:flutter/material.dart`
  that omitted identifiers they went on to use — `Uint8List`,
  `FractionallySizedBox`, `RoundedRectangleBorder`, `Radius`, `AppBar`.
- `Printing.pickPrinter(context: null)` passes null to a non-nullable
  `BuildContext`.
- `await` appeared inside a non-`async` closure.
- Both redefined `WsOrganization` and `WsBottleCondition`, colliding with
  `lib/models/ws_models.dart`.
- Both used `dart:io` + `path_provider` to write the PDF to disk. Neither works
  in a browser, and `vercel.json` shows this app deploys to web.

The replacement keeps the document in memory as `Uint8List` and hands it to
`Printing` / `SharePlus`, which work on every target. It reads
`vw_ws_deliverycard`, so the printed figures are the same ones the ledger and
dashboard show — nothing is recomputed. Page size and column order come from
`ws_tblorganization.cardsettings`, per tenant.

When a customer holds more than one bottle type, a breakdown is printed below
the table: the card's single Bottle Balance column shows the default type only,
and dropping the rest silently would misstate what the customer is holding.

`share_plus` moved 7.2.2 → 12.0.0 for the `SharePlus.instance` API and web
support. `path_provider` removed.

---

## Verifying

```bash
flutter pub get
flutter analyze        # No issues found
flutter test           # 21 tests
flutter build web --release --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

`test/models_test.dart` is a regression suite: every test in it fails against
the previous `ws_models.dart`. They exist because each of these bugs produced a
plausible-looking wrong number rather than an exception.

---

## Round 2 — after the schema went live

### The delivery card was unreachable

`lib/reports/ws_delivery_card_pdf.dart` compiled, but nothing navigated to it.
The feature you asked for as a core deliverable existed as dead code, exactly
like the two files it replaced.

Now wired into the customer detail sheet: **Delivery Card (PDF)** loads the
organization, the card rows from `vw_ws_deliverycard` and the per-type bottle
balances in one call (`fetchDeliveryCardData`), then opens the preview with
print and share.

It handles the two cases that would otherwise print a broken document: no
organization readable (message, no card) and no activity yet (message naming the
customer, no empty card).

### Permission gating

`WsPermissions` was loaded, cached and tested but no screen consulted it. Now:

- **New Delivery** FAB hidden unless `delivery.manage`
- **Edit / Delete** on a customer disabled unless `customers.manage`, with an
  explicit "You have read-only access to customers." line rather than buttons
  that just look broken
- the **Delivery Card** action is deliberately NOT gated — a driver on a round
  should be able to show a customer their own history

Still a UX layer only. RLS refuses the writes regardless; this stops the app
offering actions that can only end in an error.

### Permission loading was too clever

`loadPermissions()` used a two-level PostgREST embed through an aliased middle
table:

```dart
.select('ws_tblrolepermissions:ws_tblroles(ws_tblrolepermissions(permcode))')
```

Embeds rely on PostgREST inferring relationships from foreign keys, and that
shape is a known source of "could not find a relationship". If it returned an
empty set the entire UI would silently degrade to read-only with no error.
Replaced with two plain queries. A permission loader should be the least clever
code in the app.

### The bottle screen was reading a table nothing writes

`WsBottleHealthScreen` read `ws_tblbottleinventory` via `fetchLatestSnapshot()`.
That table has to be populated by hand and **nothing in the app ever wrote to
it**, so every tile showed zero regardless of how many bottles were in
circulation — under a caption reading "Last checked 30 April", hardcoded.

Repointed to `vw_ws_bottleposition`, derived from the append-only bottle ledger,
so it is correct by construction. The caption now reports real lost/damaged
counts.

Condition grading (needs cleaning / damaged-per-bottle) is not tracked anywhere
in the schema, so those old tiles were displaying a number with no source. They
now show in-stock and with-customers, which are real.

### Dashboard

- Header said **"Kent Water"** — one tenant's name shown to every tenant, in a
  multi-tenant product. Now reads the organization.
- `catch (_)` swallowed load failures, leaving a blank screen indistinguishable
  from "you have no data yet". Errors are now shown.
- **Reconciliation banner.** `vw_ws_reconciliation` must always be empty; because
  journal entries post in the same transaction as the document, a non-zero count
  means a posting rule is wrong, not that a job is behind. That belongs in front
  of whoever runs the business, not in a log.

### Verification

`flutter analyze` — No issues found. `flutter test` — **26 tests**, including new
coverage for bottle-position maths (and the divide-by-zero on an empty
organization), the card bundle's empty state, and per-tenant `cardsettings`.

---

## Still outstanding

1. **`insertSnapshot()` / `WsBottleSnapshot` are now unused by any screen.**
   Kept in the service because the table still exists and holds your historical
   rows. Delete both once you are satisfied nothing needs the old snapshots.
2. **`DemoStore` grants every permission.** Reasonable with no server to ask, but
   demo mode cannot exercise permission-gated UI.
3. **Payments and areas screens are not gated yet.** Same pattern as customers;
   mechanical to extend.
4. **No offline queue.** `ws_record_delivery` needs connectivity. For drivers in
   the field this is the next real gap, and it is a design decision — a local
   write-ahead log plus conflict rules — not a small patch.
5. **Delivery card date range is not selectable.** It prints all activity. The
   service already accepts `from` / `to`; the UI needs a picker.
