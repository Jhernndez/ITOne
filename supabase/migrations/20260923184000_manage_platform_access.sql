create or replace function public.list_platform_access()
returns table (
  user_id uuid,
  email text,
  platform_role text,
  tenant_id uuid,
  tenant_name text,
  tenant_role text
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
    tm.role
  from auth.users au
  left join public.platform_memberships pm on pm.user_id = au.id
  left join public.tenant_memberships tm on tm.user_id = au.id
  left join public.tenants t on t.id = tm.tenant_id
  where (pm.user_id is not null or tm.user_id is not null)
    and exists (
      select 1 from public.platform_memberships owner_membership
      where owner_membership.user_id = auth.uid()
        and owner_membership.role = 'platform_owner'
    )
  order by au.email, t.name;
$$;

create or replace function public.update_platform_access(
  p_user_id uuid,
  p_platform_role text default null,
  p_tenant_id uuid default null,
  p_tenant_role text default null,
  p_current_tenant_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.platform_memberships
    where user_id = auth.uid() and role = 'platform_owner'
  ) then
    raise exception 'Platform owner access required';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'The platform owner access cannot be changed here';
  end if;

  if p_platform_role is not null
     and p_platform_role not in ('platform_admin', 'platform_support') then
    raise exception 'Invalid platform role';
  end if;

  if p_tenant_id is null and p_tenant_role is not null then
    raise exception 'Tenant role requires a tenant';
  end if;

  if p_tenant_id is not null
     and p_tenant_role is not null
     and p_tenant_role not in ('tenant_admin', 'supervisor', 'operator') then
    raise exception 'Invalid tenant role';
  end if;

  if p_current_tenant_id is distinct from p_tenant_id then
    delete from public.tenant_memberships
    where user_id = p_user_id and tenant_id = p_current_tenant_id;
  end if;

  if p_platform_role is null then
    delete from public.platform_memberships
    where user_id = p_user_id;
  else
    insert into public.platform_memberships (user_id, role)
    values (p_user_id, p_platform_role)
    on conflict (user_id) do update set role = excluded.role;
  end if;

  if p_tenant_id is not null then
    if p_tenant_role is null then
      delete from public.tenant_memberships
      where user_id = p_user_id and tenant_id = p_tenant_id;
    else
      insert into public.tenant_memberships (tenant_id, user_id, role)
      values (p_tenant_id, p_user_id, p_tenant_role)
      on conflict (tenant_id, user_id) do update set role = excluded.role;
    end if;
  end if;
end;
$$;

revoke all on function public.list_platform_access()
from public, anon, authenticated;
grant execute on function public.list_platform_access() to authenticated;

revoke all on function public.update_platform_access(uuid, text, uuid, text, uuid)
from public, anon, authenticated;
grant execute on function public.update_platform_access(uuid, text, uuid, text, uuid)
to authenticated;

create or replace function public.remove_user_from_tenant(
  p_user_id uuid,
  p_tenant_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.platform_memberships
    where user_id = auth.uid() and role = 'platform_owner'
  ) then
    raise exception 'Platform owner access required';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'The platform owner access cannot be removed here';
  end if;

  delete from public.tenant_memberships
  where user_id = p_user_id and tenant_id = p_tenant_id;
end;
$$;

revoke all on function public.remove_user_from_tenant(uuid, uuid)
from public, anon, authenticated;
grant execute on function public.remove_user_from_tenant(uuid, uuid)
to authenticated;
