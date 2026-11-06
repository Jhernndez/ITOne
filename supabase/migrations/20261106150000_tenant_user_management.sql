alter table public.tenant_memberships
  add column is_active boolean not null default true,
  add column updated_at timestamptz not null default now();

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

-- A restrictive policy supplements existing role-specific policies. Definer
-- lookup avoids recursive membership RLS, and checks current database state.
do $$
declare
  target record;
begin
  for target in
    select c.relname from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
      and a.attname = 'tenant_id' and not a.attisdropped
      and c.relname not in ('tenant_memberships', 'platform_tenant_grants', 'platform_invitations')
  loop
    execute format(
      'create policy "active tenant access required" on public.%I as restrictive for all to authenticated
       using (public.current_tenant_role(tenant_id) is not null)
       with check (public.current_tenant_role(tenant_id) is not null)', target.relname
    );
  end loop;
end;
$$;

create policy "active tenant access required" on public.tenants
as restrictive for all to authenticated
using (
  public.current_tenant_role(id) is not null
  or (
    not exists (select 1 from public.tenant_memberships m where m.tenant_id = id and m.user_id = auth.uid())
    and exists (select 1 from public.platform_memberships p
      where p.user_id = auth.uid() and p.role = 'platform_support')
  )
)
with check (public.current_tenant_role(id) = 'tenant_admin');

create policy "active tenant membership required" on public.tenant_memberships
as restrictive for select to authenticated
using (user_id = auth.uid() or public.current_tenant_role(tenant_id) is not null);

create or replace function public.list_tenant_users(p_tenant_id uuid)
returns table (
  user_id uuid, email text, full_name text, avatar_url text,
  role text, is_active boolean, is_globally_disabled boolean,
  last_sign_in_at timestamptz, created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.current_tenant_role(p_tenant_id) is distinct from 'tenant_admin' then
    raise exception 'Solo un administrador activo de esta empresa puede consultar sus usuarios';
  end if;
  return query
    select au.id, au.email::text, up.full_name, up.avatar_url,
      tm.role, tm.is_active,
      coalesce(au.banned_until > now(), false),
      au.last_sign_in_at, tm.created_at
    from public.tenant_memberships tm
    join auth.users au on au.id = tm.user_id
    left join public.user_profiles up on up.user_id = tm.user_id
    where tm.tenant_id = p_tenant_id
    order by lower(coalesce(nullif(up.full_name, ''), au.email::text)), au.id;
end;
$$;

create or replace function public.guard_tenant_administrator()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' then
    new.updated_at := now();
    if new.tenant_id <> old.tenant_id or new.user_id <> old.user_id then
      raise exception 'La identidad de la membresia no puede cambiar';
    end if;
    if new.role = 'tenant_admin' and new.is_active then return new; end if;
  end if;
  if old.role = 'tenant_admin' and old.is_active then
    -- Lock the parent so concurrent mutations cannot remove both last admins.
    perform 1 from public.tenants where id = old.tenant_id for update;
    if found and not exists (
      select 1 from public.tenant_memberships m
      join auth.users u on u.id = m.user_id
      where m.tenant_id = old.tenant_id and m.user_id <> old.user_id
        and m.role = 'tenant_admin' and m.is_active
        and (u.banned_until is null or u.banned_until <= now())
    ) then
      raise exception 'La empresa debe conservar al menos un administrador activo';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger protect_tenant_administrator
before update or delete on public.tenant_memberships
for each row execute function public.guard_tenant_administrator();

create or replace function public.update_tenant_user(
  p_tenant_id uuid, p_user_id uuid, p_role text, p_is_active boolean,
  p_expected_role text, p_expected_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform 1 from public.tenants where id = p_tenant_id for update;
  if public.current_tenant_role(p_tenant_id) is distinct from 'tenant_admin' then
    raise exception 'Solo un administrador activo de esta empresa puede gestionar sus usuarios';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'No puedes modificar tu propio rol ni desactivar tu acceso';
  end if;
  if p_role is null or p_role not in ('tenant_admin', 'supervisor', 'operator')
    or p_is_active is null or p_expected_role is null or p_expected_active is null then
    raise exception 'Rol o estado no valido';
  end if;
  update public.tenant_memberships
    set role = p_role, is_active = p_is_active
    where tenant_id = p_tenant_id and user_id = p_user_id
      and role = p_expected_role and is_active = p_expected_active;
  if not found then
    raise exception 'El usuario ya no pertenece a esta empresa o su acceso cambio. Actualiza la lista';
  end if;
end;
$$;

revoke all on function public.current_tenant_role(uuid) from public, anon, authenticated;
grant execute on function public.current_tenant_role(uuid) to authenticated;
revoke all on function public.list_tenant_users(uuid) from public, anon, authenticated;
grant execute on function public.list_tenant_users(uuid) to authenticated;
revoke all on function public.update_tenant_user(uuid, uuid, text, boolean, text, boolean)
  from public, anon, authenticated;
grant execute on function public.update_tenant_user(uuid, uuid, text, boolean, text, boolean)
  to authenticated;

create policy "active tenant logo update required" on storage.objects
as restrictive for update to authenticated
using (
  bucket_id <> 'tenant-logos' or exists (
    select 1 from public.tenants t
    where t.id::text = (storage.foldername(objects.name))[1]
      and public.current_tenant_role(t.id) = 'tenant_admin'
  )
)
with check (
  bucket_id <> 'tenant-logos' or exists (
    select 1 from public.tenants t
    where t.id::text = (storage.foldername(objects.name))[1]
      and public.current_tenant_role(t.id) = 'tenant_admin'
  )
);

create policy "active tenant logo insert required" on storage.objects
as restrictive for insert to authenticated
with check (
  bucket_id <> 'tenant-logos' or exists (
    select 1 from public.tenants t
    where t.id::text = (storage.foldername(objects.name))[1]
      and public.current_tenant_role(t.id) = 'tenant_admin'
  )
);

create policy "active tenant logo delete required" on storage.objects
as restrictive for delete to authenticated
using (
  bucket_id <> 'tenant-logos' or exists (
    select 1 from public.tenants t
    where t.id::text = (storage.foldername(objects.name))[1]
      and public.current_tenant_role(t.id) = 'tenant_admin'
  )
);
