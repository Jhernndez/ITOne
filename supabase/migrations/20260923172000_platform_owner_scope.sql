drop policy if exists "authorized users can read tenants"
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
  or exists (
    select 1
    from public.platform_memberships platform_membership
    where platform_membership.user_id = (select auth.uid())
      and platform_membership.role = 'platform_owner'
  )
);

drop policy if exists "users can read authorized memberships"
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
  or exists (
    select 1
    from public.platform_memberships platform_membership
    where platform_membership.user_id = (select auth.uid())
      and platform_membership.role = 'platform_owner'
  )
);
