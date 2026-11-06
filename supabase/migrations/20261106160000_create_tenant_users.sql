create or replace function public.current_tenant_role(p_tenant_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  member_row tenant_memberships%rowtype;
  granted_role text;
begin
  if auth.uid() is null or not exists (
    select 1 from auth.users where id = auth.uid()
      and (banned_until is null or banned_until <= now())
      and raw_app_meta_data->>'must_set_password' is distinct from 'true'
  ) then return null; end if;

  select * into member_row from tenant_memberships
    where tenant_id = p_tenant_id and user_id = auth.uid();
  if found then
    return case when member_row.is_active then member_row.role else null end;
  end if;

  select tenant_role into granted_role from platform_tenant_grants
    where tenant_id = p_tenant_id and platform_user_id = auth.uid();
  if found then return granted_role; end if;
  if exists (
    select 1 from platform_memberships where user_id = auth.uid()
      and role in ('platform_owner', 'platform_admin')
  ) then return 'tenant_admin'; end if;
  return null;
end;
$$;

-- Only an actual password change clears the server-controlled requirement.
create or replace function public.complete_temporary_password()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.raw_app_meta_data->>'must_set_password' = 'true'
    and new.encrypted_password is distinct from old.encrypted_password
    and coalesce(new.encrypted_password, '') <> '' then
    new.raw_app_meta_data := jsonb_set(
      coalesce(new.raw_app_meta_data, '{}'::jsonb), '{must_set_password}', 'false'::jsonb
    );
    new.raw_user_meta_data := jsonb_set(
      coalesce(new.raw_user_meta_data, '{}'::jsonb), '{must_set_password}', 'false'::jsonb
    );
  end if;
  return new;
end;
$$;

create trigger complete_temporary_password
before update of encrypted_password on auth.users
for each row execute function public.complete_temporary_password();

create or replace function public.finish_tenant_user_creation(
  p_actor_id uuid, p_tenant_id uuid, p_user_id uuid, p_full_name text, p_role text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- The Edge Function authenticates the actor; this service-only RPC rechecks
  -- their current membership under the same lock as role/access updates.
  perform 1 from public.tenants where id = p_tenant_id for update;
  if not found or not exists (
    select 1 from public.tenant_memberships m
    join auth.users u on u.id = m.user_id
    where m.tenant_id = p_tenant_id and m.user_id = p_actor_id
      and m.role = 'tenant_admin' and m.is_active
      and (u.banned_until is null or u.banned_until <= now())
      and u.raw_app_meta_data->>'must_set_password' is distinct from 'true'
  ) then
    raise exception 'Solo un administrador activo de esta empresa puede crear usuarios';
  end if;
  if p_role is null or p_role not in ('tenant_admin', 'supervisor', 'operator')
    or p_full_name is null or length(trim(p_full_name)) not between 1 and 120 then
    raise exception 'Nombre o rol no valido';
  end if;
  if not exists (
    select 1 from auth.users u
    where u.id = p_user_id
      and u.raw_app_meta_data->>'tenant_creation_actor' = p_actor_id::text
      and u.raw_app_meta_data->>'tenant_creation_id' = p_tenant_id::text
      and u.raw_app_meta_data->>'must_set_password' = 'true'
  ) or exists (select 1 from public.tenant_memberships where user_id = p_user_id) then
    raise exception 'Solo se pueden agregar cuentas nuevas creadas para esta empresa';
  end if;

  insert into public.user_profiles(user_id, full_name)
    values(p_user_id, trim(p_full_name))
    on conflict (user_id) do update set full_name = excluded.full_name;
  insert into public.tenant_memberships(tenant_id, user_id, role)
    values(p_tenant_id, p_user_id, p_role);
end;
$$;

revoke all on function public.finish_tenant_user_creation(uuid, uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.finish_tenant_user_creation(uuid, uuid, uuid, text, text)
  to service_role;
revoke all on function public.complete_temporary_password() from public, anon, authenticated;
