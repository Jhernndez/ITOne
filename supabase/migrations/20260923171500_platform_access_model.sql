create table if not exists public.platform_memberships (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null,
  created_at timestamptz not null default now(),
  constraint platform_memberships_role_check
    check (role in ('platform_owner', 'platform_admin', 'platform_support'))
);

create table if not exists public.platform_tenant_grants (
  platform_user_id uuid not null references auth.users(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  tenant_role text not null,
  created_at timestamptz not null default now(),
  primary key (platform_user_id, tenant_id),
  constraint platform_tenant_grants_role_check
    check (tenant_role in ('tenant_admin', 'supervisor', 'operator'))
);

alter table public.platform_memberships enable row level security;
alter table public.platform_tenant_grants enable row level security;

grant select on table public.platform_memberships to authenticated;
grant select on table public.platform_tenant_grants to authenticated;

create policy "users can read their platform membership"
on public.platform_memberships for select to authenticated
using (user_id = (select auth.uid()));

create policy "platform users can read their tenant grants"
on public.platform_tenant_grants for select to authenticated
using (platform_user_id = (select auth.uid()));

drop policy if exists "users can read their own memberships"
on public.tenant_memberships;

create policy "users can read authorized memberships"
on public.tenant_memberships for select to authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1
    from public.platform_tenant_grants grant_record
    where grant_record.platform_user_id = (select auth.uid())
      and grant_record.tenant_id = tenant_memberships.tenant_id
  )
);

drop policy if exists "members can read their tenants"
on public.tenants;

create policy "authorized users can read tenants"
on public.tenants for select to authenticated
using (
  exists (
    select 1
    from public.tenant_memberships membership
    where membership.tenant_id = tenants.id
      and membership.user_id = (select auth.uid())
  )
  or exists (
    select 1
    from public.platform_tenant_grants grant_record
    where grant_record.platform_user_id = (select auth.uid())
      and grant_record.tenant_id = tenants.id
  )
);
