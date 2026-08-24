# Your views were deleted by my own migration. Here is the fix.

## What happened

```
PGRST205: Could not find the table 'public.vw_ws_dashboard' in the schema cache
PGRST205: Could not find the table 'public.vw_ws_customerbalance' in the schema cache
```

Not a stale cache — I was wrong about that last message. The views are genuinely
gone, and `000_adopt_existing_schema.sql` deleted them.

Line 271 of that file was:

```sql
drop view if exists public.vw_ws_customerbalance cascade;
```

Two other views select from `vw_ws_customerbalance`:

```
vw_ws_customerbalance
        ├── vw_ws_reconciliation      (compares journal vs subsidiary ledgers)
        └── vw_ws_dashboard           (every tile on your home screen)
```

`CASCADE` takes dependents with it. So **one statement destroyed three views** —
and it fired the moment 000 ran a second time, on a database where 007 had
already created the good version. The file advertises itself as "additive and
idempotent… no data is deleted", which was true of the columns and false of that
line. That is my error, in a file whose whole job was to be safe to re-run.

It explains the order you saw the failures in, too: the dashboard broke first
because `vw_ws_dashboard` is read on the home screen, then `vw_ws_customerbalance`
when you navigated to Customers.

## Fix your database now

Re-run **`install.sql`**. It is idempotent and recreates all thirteen views.

```
-- Supabase SQL editor: paste database/install.sql, run once.
```

Then, because PostgREST caches the schema:

```sql
notify pgrst, 'reload schema';
```

Wait about five seconds and restart the app.

### Confirm

```sql
select count(*) as should_be_13
from pg_class
where relkind = 'v'
  and relnamespace = 'public'::regnamespace
  and relname like 'vw\_ws%';
```

## What I changed so it cannot happen again

000 no longer drops that view blindly. It checks which version is present —
`bottledepositvalue` is a column only the new view has — and skips the drop when
007 has already run:

| Situation | Before | Now |
|---|---|---|
| Legacy view present (first upgrade) | dropped, 007 recreates it | dropped, 007 recreates it — unchanged |
| New view present (000 re-run) | **dropped with 2 dependents** | left alone, notice printed |
| No view at all | no-op | no-op |

Verified on a real Postgres, both paths:

```
install.sql                        -> ok | vw_ws_* views: 13
000 alone, after a full install    -> ok | vw_ws_* views: 13
   NOTICE: vw_ws_customerbalance is already the migrated version — leaving it alone.
install.sql re-run                 -> ok | vw_ws_* views: 13

legacy fixture + install.sql       -> ok | vw_ws_* views: 13
   NOTICE: Dropping the legacy vw_ws_customerbalance (007 recreates it).
bootstrap_existing_data.sql        -> ok | vw_ws_* views: 13
```

Before the patch, the second line would have left **10**.

## The general lesson for this project

Run `install.sql`, never the individual migration files. Every problem in this
migration has come from running pieces separately: 002 aborting and taking the
rest with it, 004 failing its second run on a constraint, and now 000 deleting
views on its second run. `install.sql` applies everything in one transaction, in
order, and is safe to repeat.
