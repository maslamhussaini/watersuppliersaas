-- =============================================================================
-- 008_rls_policies.sql
-- Row level security. THIS IS THE FILE THAT MAKES THE APPLICATION MULTI-TENANT.
--
-- WHAT WAS ACTUALLY WRONG BEFORE
-- Tenant isolation lived entirely in Dart: WsTenantService held _selectedOrgId
-- in a static field and every query appended .eq('orgid', orgId). The Supabase
-- anon key ships inside the Flutter web bundle, so it is public by definition.
-- Anyone could take that key, call the REST endpoint directly, and read
-- ws_tblcustomers with no orgid filter at all — every tenant's customer list,
-- phone numbers, addresses and outstanding balances. The client-side filter was
-- decoration.
--
-- After this migration the database refuses those reads regardless of what the
-- client sends. The Dart .eq('orgid', ...) calls become a performance hint, not
-- a security control.
--
-- STRUCTURE
--   * SELECT is gated on membership: ws.is_member(orgid).
--   * Writes are gated on a permission code: ws.has_perm(orgid, '...').
--   * Portal (customer) logins are additionally scoped to their own customerid,
--     so one customer of an org cannot read another customer of the same org.
--   * `anon` gets nothing. Reference tables are the only exception.
-- =============================================================================

-- ─── Baseline grants: strip anon, give authenticated table-level DML only ────
-- Table-level GRANT is necessary but not sufficient; RLS still decides rows.

do $$
declare t text;
begin
  for t in
    select tablename from pg_tables
    where schemaname = 'public' and tablename like 'ws\_tbl%'
  loop
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    -- Belt and braces: the table owner would otherwise bypass its own policies,
    -- which silently breaks tests run as the owner and hides policy mistakes.
    execute format('alter table public.%I force row level security', t);
  end loop;
end
$$;

-- Reference data that is intentionally global and read-only.
alter table public.ws_tblpermissions disable row level security;
alter table public.ws_tblplans       disable row level security;
grant select on public.ws_tblpermissions, public.ws_tblplans to authenticated, anon;

-- ─── Helper: does the current caller hold a portal (customer) membership? ────

create or replace function ws.is_portal(p_orgid bigint)
returns boolean
language sql
stable
security definer
set search_path = ws, public, pg_catalog
as $$
  select coalesce((
    select m.customerid is not null
    from public.ws_tblmemberships m
    where m.authuserid = ws.current_uid()
      and m.orgid = p_orgid
      and m.isactive
    limit 1
  ), false)
$$;

-- =============================================================================
-- Tenancy tables
-- =============================================================================

-- ws_tblorganization: visible to members. Creation goes through
-- ws_create_organization() (SECURITY DEFINER), so there is no INSERT policy —
-- a client cannot conjure an organization it is not a member of.
drop policy if exists org_select on public.ws_tblorganization;
create policy org_select on public.ws_tblorganization
  for select to authenticated
  using (ws.is_member(orgid));

drop policy if exists org_update on public.ws_tblorganization;
create policy org_update on public.ws_tblorganization
  for update to authenticated
  using (ws.has_perm(orgid, 'org.manage'))
  with check (ws.has_perm(orgid, 'org.manage'));

-- ws_tblmemberships: the RLS root. Its policy touches NO other table, which is
-- what keeps ws.member_org_ids() from recursing.
drop policy if exists membership_select_self on public.ws_tblmemberships;
create policy membership_select_self on public.ws_tblmemberships
  for select to authenticated
  using (authuserid = ws.current_uid());

-- Seeing co-workers requires users.view. Evaluated through the SECURITY DEFINER
-- helper, so this second policy also avoids self-reference.
drop policy if exists membership_select_org on public.ws_tblmemberships;
create policy membership_select_org on public.ws_tblmemberships
  for select to authenticated
  using (ws.has_perm(orgid, 'users.view'));

drop policy if exists membership_write on public.ws_tblmemberships;
create policy membership_write on public.ws_tblmemberships
  for all to authenticated
  using (ws.has_perm(orgid, 'users.manage'))
  with check (ws.has_perm(orgid, 'users.manage'));

-- ws_tblroles / ws_tblrolepermissions
drop policy if exists roles_select on public.ws_tblroles;
create policy roles_select on public.ws_tblroles
  for select to authenticated using (ws.is_member(orgid));

drop policy if exists roles_write on public.ws_tblroles;
create policy roles_write on public.ws_tblroles
  for all to authenticated
  using (ws.has_perm(orgid, 'users.manage') and not issystem)
  with check (ws.has_perm(orgid, 'users.manage') and not issystem);

drop policy if exists roleperm_select on public.ws_tblrolepermissions;
create policy roleperm_select on public.ws_tblrolepermissions
  for select to authenticated
  using (exists (
    select 1 from public.ws_tblroles r
    where r.roleid = ws_tblrolepermissions.roleid and ws.is_member(r.orgid)
  ));

drop policy if exists roleperm_write on public.ws_tblrolepermissions;
create policy roleperm_write on public.ws_tblrolepermissions
  for all to authenticated
  using (exists (
    select 1 from public.ws_tblroles r
    where r.roleid = ws_tblrolepermissions.roleid and ws.has_perm(r.orgid, 'users.manage')
  ))
  with check (exists (
    select 1 from public.ws_tblroles r
    where r.roleid = ws_tblrolepermissions.roleid and ws.has_perm(r.orgid, 'users.manage')
  ));

-- ws_tblinternalusers: portal customers must not enumerate staff.
drop policy if exists internalusers_select on public.ws_tblinternalusers;
create policy internalusers_select on public.ws_tblinternalusers
  for select to authenticated
  using (ws.is_member(orgid) and not ws.is_portal(orgid));

drop policy if exists internalusers_write on public.ws_tblinternalusers;
create policy internalusers_write on public.ws_tblinternalusers
  for all to authenticated
  using (ws.has_perm(orgid, 'users.manage'))
  with check (ws.has_perm(orgid, 'users.manage'));

-- Subscriptions
drop policy if exists subs_select on public.ws_tblsubscriptions;
create policy subs_select on public.ws_tblsubscriptions
  for select to authenticated using (ws.has_perm(orgid, 'org.view'));

drop policy if exists subs_write on public.ws_tblsubscriptions;
create policy subs_write on public.ws_tblsubscriptions
  for all to authenticated
  using (ws.has_perm(orgid, 'org.manage'))
  with check (ws.has_perm(orgid, 'org.manage'));

drop policy if exists subpay_select on public.ws_tblsubscriptionpayments;
create policy subpay_select on public.ws_tblsubscriptionpayments
  for select to authenticated using (ws.has_perm(orgid, 'org.view'));

-- =============================================================================
-- Master data
-- =============================================================================

do $$
declare
  spec record;
begin
  for spec in
    select * from (values
      ('ws_tblareas',           'products.view',  'products.manage'),
      ('ws_tblroutes',          'delivery.view',  'delivery.manage'),
      ('ws_tblbottletypes',     'products.view',  'products.manage'),
      ('ws_tblproducts',        'products.view',  'products.manage'),
      ('ws_tblcustomergroups',  'customers.view', 'customers.manage'),
      ('ws_tblproductprices',   'products.view',  'products.manage'),
      ('ws_tblpaymentmethods',  'payments.view',  'org.manage'),
      ('ws_tblvendors',         'vendors.view',   'vendors.manage'),
      ('ws_tblpurchases',       'purchases.view', 'purchases.manage'),
      ('ws_tblpurchasedetails', 'purchases.view', 'purchases.manage'),
      ('ws_tblvendorpayments',  'purchases.view', 'purchases.manage'),
      ('ws_tblaccounts',        'accounting.view','accounting.manage'),
      ('ws_tbldocumentsequences','delivery.view', 'org.manage'),
      -- Legacy snapshot table. Without a policy here, 008's blanket
      -- `enable row level security` would make it silently unreadable.
      ('ws_tblbottleinventory', 'delivery.view',  'delivery.manage')
    ) as v(tbl, readperm, writeperm)
  loop
    execute format('drop policy if exists %1$s_select on public.%1$s', spec.tbl);
    -- Master data is readable by any member holding the read permission.
    -- Portal customers are excluded from vendor and accounting data entirely.
    execute format($p$
      create policy %1$s_select on public.%1$s
        for select to authenticated
        using (ws.is_member(orgid) and ws.has_perm(orgid, %2$L))
    $p$, spec.tbl, spec.readperm);

    execute format('drop policy if exists %1$s_write on public.%1$s', spec.tbl);
    execute format($p$
      create policy %1$s_write on public.%1$s
        for all to authenticated
        using (ws.has_perm(orgid, %2$L))
        with check (ws.has_perm(orgid, %2$L))
    $p$, spec.tbl, spec.writeperm);
  end loop;
end
$$;

-- Products and areas are needed by the portal to render its own history, so
-- grant portal logins a narrow read on the two harmless ones.
drop policy if exists products_portal_select on public.ws_tblproducts;
create policy products_portal_select on public.ws_tblproducts
  for select to authenticated
  using (ws.is_portal(orgid) and ws.is_member(orgid));

drop policy if exists bottletypes_portal_select on public.ws_tblbottletypes;
create policy bottletypes_portal_select on public.ws_tblbottletypes
  for select to authenticated
  using (ws.is_portal(orgid) and ws.is_member(orgid));

-- =============================================================================
-- Customers — staff see all, portal sees only itself
-- =============================================================================

drop policy if exists customers_select on public.ws_tblcustomers;
create policy customers_select on public.ws_tblcustomers
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (
      ws.has_perm(orgid, 'customers.view')
      or customerid = ws.portal_customer_id(orgid)
    )
    and (
      not ws.is_portal(orgid)
      or customerid = ws.portal_customer_id(orgid)
    )
  );

drop policy if exists customers_write on public.ws_tblcustomers;
create policy customers_write on public.ws_tblcustomers
  for all to authenticated
  using (ws.has_perm(orgid, 'customers.manage') and not ws.is_portal(orgid))
  with check (ws.has_perm(orgid, 'customers.manage') and not ws.is_portal(orgid));

drop policy if exists custaddr_select on public.ws_tblcustomeraddresses;
create policy custaddr_select on public.ws_tblcustomeraddresses
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or (not ws.is_portal(orgid) and ws.has_perm(orgid, 'customers.view')))
  );

drop policy if exists custaddr_write on public.ws_tblcustomeraddresses;
create policy custaddr_write on public.ws_tblcustomeraddresses
  for all to authenticated
  using (ws.has_perm(orgid, 'customers.manage') and not ws.is_portal(orgid))
  with check (ws.has_perm(orgid, 'customers.manage') and not ws.is_portal(orgid));

-- =============================================================================
-- Operations — same staff/portal split
-- =============================================================================

drop policy if exists deliveries_select on public.ws_tbldeliveries;
create policy deliveries_select on public.ws_tbldeliveries
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or (not ws.is_portal(orgid) and ws.has_perm(orgid, 'delivery.view')))
  );

drop policy if exists deliveries_write on public.ws_tbldeliveries;
create policy deliveries_write on public.ws_tbldeliveries
  for all to authenticated
  using (ws.has_perm(orgid, 'delivery.manage') and not ws.is_portal(orgid))
  with check (ws.has_perm(orgid, 'delivery.manage') and not ws.is_portal(orgid));

drop policy if exists deliverydetails_select on public.ws_tbldeliverydetails;
create policy deliverydetails_select on public.ws_tbldeliverydetails
  for select to authenticated
  using (exists (
    select 1 from public.ws_tbldeliveries d
    where d.deliveryid = ws_tbldeliverydetails.deliveryid
      and ws.is_member(d.orgid)
      and (d.customerid = ws.portal_customer_id(d.orgid)
           or (not ws.is_portal(d.orgid) and ws.has_perm(d.orgid, 'delivery.view')))
  ));

drop policy if exists deliverydetails_write on public.ws_tbldeliverydetails;
create policy deliverydetails_write on public.ws_tbldeliverydetails
  for all to authenticated
  using (ws.has_perm(orgid, 'delivery.manage') and not ws.is_portal(orgid))
  with check (ws.has_perm(orgid, 'delivery.manage') and not ws.is_portal(orgid));

drop policy if exists payments_select on public.ws_tblpayments;
create policy payments_select on public.ws_tblpayments
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or (not ws.is_portal(orgid) and ws.has_perm(orgid, 'payments.view')))
  );

drop policy if exists payments_write on public.ws_tblpayments;
create policy payments_write on public.ws_tblpayments
  for all to authenticated
  using (ws.has_perm(orgid, 'payments.manage') and not ws.is_portal(orgid))
  with check (ws.has_perm(orgid, 'payments.manage') and not ws.is_portal(orgid));

drop policy if exists bottletxn_select on public.ws_tblbottletransactions;
create policy bottletxn_select on public.ws_tblbottletransactions
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or (not ws.is_portal(orgid) and ws.has_perm(orgid, 'delivery.view')))
  );

-- Inserts happen through triggers and SECURITY DEFINER functions. A direct
-- client insert is allowed only with delivery.manage, for manual adjustments.
drop policy if exists bottletxn_insert on public.ws_tblbottletransactions;
create policy bottletxn_insert on public.ws_tblbottletransactions
  for insert to authenticated
  with check (ws.has_perm(orgid, 'delivery.manage') and not ws.is_portal(orgid));

drop policy if exists bottlebal_select on public.ws_tblcustomerbottlebalances;
create policy bottlebal_select on public.ws_tblcustomerbottlebalances
  for select to authenticated
  using (
    ws.is_member(orgid)
    and (customerid = ws.portal_customer_id(orgid)
         or (not ws.is_portal(orgid) and ws.has_perm(orgid, 'customers.view')))
  );

-- The cache is trigger-owned. No client write policy at all: without a
-- permissive policy for INSERT/UPDATE, RLS denies them, while the trigger
-- functions run as SECURITY DEFINER owners and are unaffected.

-- =============================================================================
-- Accounting — never visible to portal logins
-- =============================================================================

drop policy if exists journal_select on public.ws_tbljournalentries;
create policy journal_select on public.ws_tbljournalentries
  for select to authenticated
  using (ws.has_perm(orgid, 'accounting.view') and not ws.is_portal(orgid));

drop policy if exists journal_write on public.ws_tbljournalentries;
create policy journal_write on public.ws_tbljournalentries
  for all to authenticated
  using (ws.has_perm(orgid, 'accounting.manage') and sourcetype = 'manual')
  with check (ws.has_perm(orgid, 'accounting.manage') and sourcetype = 'manual');

drop policy if exists jdetail_select on public.ws_tbljournalentrydetails;
create policy jdetail_select on public.ws_tbljournalentrydetails
  for select to authenticated
  using (ws.has_perm(orgid, 'accounting.view') and not ws.is_portal(orgid));

drop policy if exists jdetail_write on public.ws_tbljournalentrydetails;
create policy jdetail_write on public.ws_tbljournalentrydetails
  for all to authenticated
  using (exists (
    select 1 from public.ws_tbljournalentries j
    where j.journalid = ws_tbljournalentrydetails.journalid
      and j.sourcetype = 'manual'
      and ws.has_perm(j.orgid, 'accounting.manage')
  ))
  with check (exists (
    select 1 from public.ws_tbljournalentries j
    where j.journalid = ws_tbljournalentrydetails.journalid
      and j.sourcetype = 'manual'
      and ws.has_perm(j.orgid, 'accounting.manage')
  ));

-- =============================================================================
-- Trigger functions must run with the privileges needed to maintain caches and
-- post journals even when the calling user has no direct write policy on those
-- tables. FORCE RLS applies to the table owner too, so these are marked
-- SECURITY DEFINER and owned by the migration role.
-- =============================================================================

alter function ws.tg_bottletxn_apply_cache()   security definer;
alter function ws.tg_bottletxn_compute_balance() security definer;
alter function ws.recalc_delivery(bigint)      security definer;
alter function ws.recalc_purchase(bigint)      security definer;
alter function ws.post_delivery(bigint)        security definer;
alter function ws.post_customer_payment(bigint) security definer;
alter function ws.post_purchase(bigint)        security definer;
alter function ws.post_vendor_payment(bigint)  security definer;
alter function ws.journal_upsert_header(bigint,text,bigint,date,text) security definer;
alter function ws.journal_line(bigint,bigint,bigint,numeric,numeric,bigint,bigint,text) security definer;
alter function ws.next_docnumber(bigint,text)  security definer;
alter function ws.tg_deliverydetail_after()    security definer;
alter function ws.tg_deliverydetail_prepare()  security definer;
alter function ws.tg_delivery_after()          security definer;
alter function ws.tg_purchasedetail_after()    security definer;
alter function ws.tg_purchase_after()          security definer;
alter function ws.tg_vendorpayment_after()     security definer;
alter function ws.tg_payment_after()           security definer;

-- =============================================================================
-- Audit log
-- =============================================================================

create table if not exists public.ws_tblauditlogs (
  auditid     bigint generated by default as identity primary key,
  orgid       bigint references public.ws_tblorganization(orgid) on delete cascade,
  authuserid  uuid,
  tablename   text not null,
  recordid    text,
  action      text not null check (action in ('insert','update','delete')),
  changes     jsonb,
  occurred_at timestamptz not null default now()
);

create index if not exists ix_audit_org_time on public.ws_tblauditlogs(orgid, occurred_at desc);

alter table public.ws_tblauditlogs enable row level security;
alter table public.ws_tblauditlogs force row level security;
revoke all on public.ws_tblauditlogs from anon;
grant select on public.ws_tblauditlogs to authenticated;

drop policy if exists audit_select on public.ws_tblauditlogs;
create policy audit_select on public.ws_tblauditlogs
  for select to authenticated
  using (ws.has_perm(orgid, 'org.manage'));

create or replace function ws.tg_audit()
returns trigger
language plpgsql
security definer
set search_path = ws, public, pg_catalog
as $$
declare
  v_org bigint;
  v_id  text;
begin
  v_org := case tg_op when 'DELETE' then (to_jsonb(old)->>'orgid')::bigint
                      else (to_jsonb(new)->>'orgid')::bigint end;
  v_id  := case tg_op when 'DELETE' then to_jsonb(old)->>(tg_argv[0])
                      else to_jsonb(new)->>(tg_argv[0]) end;

  insert into public.ws_tblauditlogs (orgid, authuserid, tablename, recordid, action, changes)
  values (
    v_org, ws.current_uid(), tg_table_name, v_id, lower(tg_op),
    case tg_op
      when 'INSERT' then jsonb_build_object('new', to_jsonb(new))
      when 'DELETE' then jsonb_build_object('old', to_jsonb(old))
      else jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new))
    end
  );
  return null;
end
$$;

-- Audit the tables where a silent change is expensive: money and pricing.
do $$
declare
  spec record;
begin
  for spec in
    select * from (values
      ('ws_tblcustomers',      'customerid'),
      ('ws_tblpayments',       'paymentid'),
      ('ws_tbldeliveries',     'deliveryid'),
      ('ws_tblproductprices',  'priceid'),
      ('ws_tblvendorpayments', 'vendorpaymentid'),
      ('ws_tblmemberships',    'membershipid')
    ) as v(tbl, pk)
  loop
    execute format('drop trigger if exists trg_audit_%1$s on public.%1$s', spec.tbl);
    execute format(
      'create trigger trg_audit_%1$s after insert or update or delete on public.%1$s
       for each row execute function ws.tg_audit(%2$L)', spec.tbl, spec.pk);
  end loop;
end
$$;
