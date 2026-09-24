create table if not exists public.tenant_integrations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  provider text not null,
  status text not null default 'not_configured'
    check (status in ('not_configured', 'configuring', 'active', 'error', 'disabled')),
  configured_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, provider)
);

create index if not exists tenant_integrations_tenant_id_idx
  on public.tenant_integrations(tenant_id);

alter table public.tenant_integrations enable row level security;

create policy "Tenant members can view integrations"
  on public.tenant_integrations
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.tenant_memberships membership
      where membership.tenant_id = tenant_integrations.tenant_id
        and membership.user_id = (select auth.uid())
    )
  );

create policy "Tenant admins can manage integrations"
  on public.tenant_integrations
  for all
  to authenticated
  using (
    exists (
      select 1
      from public.tenant_memberships membership
      where membership.tenant_id = tenant_integrations.tenant_id
        and membership.user_id = (select auth.uid())
        and membership.role = 'tenant_admin'
    )
  )
  with check (
    exists (
      select 1
      from public.tenant_memberships membership
      where membership.tenant_id = tenant_integrations.tenant_id
        and membership.user_id = (select auth.uid())
        and membership.role = 'tenant_admin'
    )
  );

grant select, insert, update, delete
  on table public.tenant_integrations to authenticated;
