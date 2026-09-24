create or replace function public.update_platform_access_bulk(
  p_user_id uuid,
  p_platform_role text default null,
  p_tenant_access jsonb default '[]'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.platform_memberships
    where user_id = auth.uid()
      and role in ('platform_owner', 'platform_admin')
  ) then
    raise exception 'Platform administrator access required';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'The platform owner access cannot be changed here';
  end if;

  if p_platform_role is not null
     and p_platform_role not in ('platform_admin', 'platform_support') then
    raise exception 'Invalid platform role';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_tenant_access) access
    where access->>'tenant_id' is null
       or access->>'tenant_role' not in ('tenant_admin', 'supervisor', 'operator')
  ) then
    raise exception 'Invalid tenant access';
  end if;

  if p_platform_role is null then
    delete from public.platform_memberships where user_id = p_user_id;
  else
    insert into public.platform_memberships (user_id, role)
    values (p_user_id, p_platform_role)
    on conflict (user_id) do update set role = excluded.role;
  end if;

  delete from public.tenant_memberships
  where user_id = p_user_id
    and tenant_id not in (
      select (access->>'tenant_id')::uuid
      from jsonb_array_elements(p_tenant_access) access
    );

  insert into public.tenant_memberships (tenant_id, user_id, role)
  select
    (access->>'tenant_id')::uuid,
    p_user_id,
    access->>'tenant_role'
  from jsonb_array_elements(p_tenant_access) access
  on conflict (tenant_id, user_id)
  do update set role = excluded.role;
end;
$$;

revoke all on function public.update_platform_access_bulk(uuid, text, jsonb)
from public, anon, authenticated;
grant execute on function public.update_platform_access_bulk(uuid, text, jsonb)
to authenticated;
