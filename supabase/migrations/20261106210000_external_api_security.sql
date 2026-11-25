-- Table privileges override column-level revokes, so replace them explicitly.
revoke select, insert, update on public.tenant_api_integrations from public, anon, authenticated;
revoke select (auth_config), insert (auth_config), update (auth_config)
  on public.tenant_api_integrations from public, anon, authenticated;
grant select (id, tenant_id, name, base_url, auth_type, enabled, created_at, updated_at)
  on public.tenant_api_integrations to authenticated;
-- Integration mutations containing credentials go exclusively through the edge function.
revoke insert, update on public.tenant_api_integrations from authenticated;

alter table public.tenant_api_resources
  add column if not exists enabled_for_automation boolean not null default false,
  add column if not exists allow_automation_writes boolean not null default false;

-- Match the edge function's active-role check, including platform grants.
drop policy if exists "tenant members can view api integrations" on public.tenant_api_integrations;
drop policy if exists "tenant admins can manage api integrations" on public.tenant_api_integrations;
create policy "active tenant members can view api integrations"
  on public.tenant_api_integrations for select to authenticated
  using (public.current_tenant_role(tenant_id) is not null);
create policy "active tenant admins can delete api integrations"
  on public.tenant_api_integrations for delete to authenticated
  using (public.current_tenant_role(tenant_id) = 'tenant_admin');

drop policy if exists "tenant members can view api resources" on public.tenant_api_resources;
drop policy if exists "tenant admins can manage api resources" on public.tenant_api_resources;
create policy "active tenant members can view api resources"
  on public.tenant_api_resources for select to authenticated
  using (public.current_tenant_role(tenant_id) is not null);
create policy "active tenant admins can manage api resources"
  on public.tenant_api_resources for all to authenticated
  using (public.current_tenant_role(tenant_id) = 'tenant_admin')
  with check (
    public.current_tenant_role(tenant_id) = 'tenant_admin'
    and exists (
      select 1 from public.tenant_api_integrations integration
      where integration.id = tenant_api_resources.integration_id
        and integration.tenant_id = tenant_api_resources.tenant_id
    )
  );
