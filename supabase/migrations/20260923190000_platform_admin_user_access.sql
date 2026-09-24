drop function if exists public.list_platform_access();

create function public.list_platform_access()
returns table (
  user_id uuid,
  email text,
  platform_role text,
  tenant_id uuid,
  tenant_name text,
  tenant_role text,
  is_disabled boolean
)
language sql
security definer
set search_path = public
as $$
  select
    au.id,
    au.email,
    pm.role,
    tm.tenant_id,
    t.name,
    tm.role,
    coalesce(au.banned_until is not null and au.banned_until > now(), false)
  from auth.users au
  left join public.platform_memberships pm on pm.user_id = au.id
  left join public.tenant_memberships tm on tm.user_id = au.id
  left join public.tenants t on t.id = tm.tenant_id
  where (pm.user_id is not null or tm.user_id is not null)
    and exists (
      select 1
      from public.platform_memberships viewer
      where viewer.user_id = auth.uid()
        and viewer.role in ('platform_owner', 'platform_admin', 'platform_support')
    )
  order by au.email, t.name;
$$;

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
      and platform_membership.role in (
        'platform_owner',
        'platform_admin',
        'platform_support'
      )
  )
);

revoke all on function public.list_platform_access()
from public, anon, authenticated;
grant execute on function public.list_platform_access() to authenticated;
