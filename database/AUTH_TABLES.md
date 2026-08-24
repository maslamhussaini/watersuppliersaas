# Which table holds users for login and register?

**`auth.users`** — and you do not create it, write to it, or manage it. Supabase
Auth (GoTrue) owns that table. It lives in the `auth` schema, not `public`, and
it is not one of the `ws_tbl*` tables.

The `ws_tbl*` tables answer a different question: *what is this authenticated
person allowed to do, and in which organization?*

```
LOGIN / REGISTER  ─────────────►  auth.users          (Supabase Auth owns this)
                                      │ id (uuid)
                                      │
                                      ▼
                                  ws_tblmemberships    ◄── THE ONE TABLE RLS READS
                                      │ authuserid ──► auth.users.id
                                      │ orgid      ──► which company
                                      │ roleid     ──► what they can do
                                      │ customerid ──► set = portal login, null = staff
                                      │
                    ┌─────────────────┴─────────────────┐
                    ▼                                   ▼
              ws_tblroles                        (staff)  ws_tblinternalusers
                    │ rolecode                            name, phone, role label
                    ▼
              ws_tblrolepermissions
                    │ permcode
                    ▼
              ws_tblpermissions                  (customer) ws_tblcustomers.authuserid
```

## What each screen does

| Screen | Calls | Writes to |
|---|---|---|
| Login | `AuthService.signIn()` → `supabase.auth.signInWithPassword()` | nothing — reads `auth.users` |
| Register | `AuthService.registerOrganization()` → `supabase.auth.signUp()` then the `ws_create_organization` RPC | `auth.users`, then org + roles + membership + chart of accounts |

`ws_create_organization` does the whole provisioning in one transaction. It was
three separate client writes before; a failure after the first left an
organization with no members, invisible to the person who had just created it.

## The part that matters

**`ws_tblmemberships` is the only table row level security consults.** No
membership row means every policy evaluates false, so the user sees nothing —
no error, just empty screens. That is exactly the lockout
`bootstrap_existing_data.sql` fixes for organizations that predate this schema.

`ws_tblinternalusers.role` is a display label. It is NOT used for authorization
— `ws.has_perm()` reads roles through the membership. Two places holding
"what can this person do" would eventually disagree.

## Inspecting who can log in

Run in the Supabase SQL editor. Users with no membership row are the ones who
will sign in successfully and then see nothing.

```sql
select
  u.email,
  u.created_at,
  u.last_sign_in_at,
  o.orgname,
  r.rolecode,
  case
    when m.membershipid is null then '⚠ NO MEMBERSHIP — will see empty screens'
    when m.customerid is not null then 'customer portal'
    else 'staff'
  end as access,
  iu.fullname as staff_name,
  c.customername as portal_customer
from auth.users u
left join public.ws_tblmemberships   m  on m.authuserid = u.id and m.isactive
left join public.ws_tblorganization  o  on o.orgid  = m.orgid
left join public.ws_tblroles         r  on r.roleid = m.roleid
left join public.ws_tblinternalusers iu on iu.authuserid = u.id and iu.orgid = m.orgid
left join public.ws_tblcustomers     c  on c.customerid = m.customerid
order by u.created_at;
```

## Adding a user to an existing organization

Creating the auth account is a Supabase Auth operation — invite them from
**Authentication → Users**, or have them register. Then grant access:

```sql
-- Staff member, e.g. a delivery driver
with m as (
  insert into public.ws_tblmemberships (orgid, authuserid, roleid)
  select 1,
         (select id from auth.users where email = 'driver@example.com'),
         (select roleid from public.ws_tblroles where orgid = 1 and rolecode = 'delivery')
  on conflict (orgid, authuserid) do update set isactive = true
  returning membershipid, orgid, authuserid
)
insert into public.ws_tblinternalusers (orgid, authuserid, fullname, role, membershipid)
select m.orgid, m.authuserid, 'Driver Name', 'delivery', m.membershipid from m
on conflict (orgid, authuserid) do nothing;
```

```sql
-- Customer portal login: just set authuserid on the customer.
-- The trigger in migration 003 creates the membership automatically.
update public.ws_tblcustomers
   set authuserid = (select id from auth.users where email = 'customer@example.com')
 where customerid = 42;
```

Available `rolecode` values: `owner`, `admin`, `accountant`, `sales`,
`delivery`, `readonly`, `customer`. See what each one grants:

```sql
select r.rolecode, string_agg(rp.permcode, ', ' order by rp.permcode) as permissions
from public.ws_tblroles r
join public.ws_tblrolepermissions rp on rp.roleid = r.roleid
where r.orgid = 1
group by r.rolecode
order by r.rolecode;
```

## Why not a `ws_tblusers` table

Passwords, email confirmation, password reset, OAuth and session tokens are
Supabase Auth's job. A parallel user table would mean two sources of truth for
identity, and the one you maintain would be the one with the security bugs.
`auth.users` holds identity; `ws_tblmemberships` holds authorization.
