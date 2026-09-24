create policy "tenant admins can update tenant sector"
on public.tenants for update to authenticated
using (exists (
  select 1
  from public.tenant_memberships membership
  where membership.tenant_id = tenants.id
    and membership.user_id = (select auth.uid())
    and membership.role = 'tenant_admin'
))
with check (exists (
  select 1
  from public.tenant_memberships membership
  where membership.tenant_id = tenants.id
    and membership.user_id = (select auth.uid())
    and membership.role = 'tenant_admin'
));
