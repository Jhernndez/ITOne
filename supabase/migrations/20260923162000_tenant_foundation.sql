create table if not exists public.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.tenant_memberships (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'tenant_admin',
  created_at timestamptz not null default now(),
  primary key (tenant_id, user_id),
  constraint tenant_memberships_role_check
    check (role in ('tenant_admin', 'supervisor', 'operator', 'end_user', 'external_client'))
);

alter table public.tenants enable row level security;
alter table public.tenant_memberships enable row level security;

create policy "members can read their tenants"
on public.tenants for select to authenticated
using (
  exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenants.id
      and membership.user_id = (select auth.uid())
  )
);

create policy "members can read memberships in their tenants"
on public.tenant_memberships for select to authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1 from public.tenant_memberships member_tenant
    where member_tenant.tenant_id = tenant_memberships.tenant_id
      and member_tenant.user_id = (select auth.uid())
  )
);

create or replace function public.create_tenant_for_current_user(
  p_name text,
  p_slug text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_tenant_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_name is null or length(trim(p_name)) < 2 then
    raise exception 'Company name is required';
  end if;

  if p_slug !~ '^[a-z0-9-]{3,40}$' then
    raise exception 'Invalid company identifier';
  end if;

  if exists (
    select 1 from public.tenant_memberships
    where user_id = auth.uid()
  ) then
    raise exception 'User already belongs to a tenant';
  end if;

  insert into public.tenants (name, slug)
  values (trim(p_name), lower(p_slug))
  returning id into new_tenant_id;

  insert into public.tenant_memberships (tenant_id, user_id, role)
  values (new_tenant_id, auth.uid(), 'tenant_admin');

  return new_tenant_id;
exception
  when unique_violation then
    raise exception 'Company identifier is already in use';
end;
$$;

revoke all on function public.create_tenant_for_current_user(text, text)
from public, anon;
grant execute on function public.create_tenant_for_current_user(text, text)
to authenticated;
