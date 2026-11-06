create or replace function public.can_manage_tenant_account(p_tenant_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.tenant_memberships
    where tenant_id = p_tenant_id and user_id = p_user_id
  )
  and not exists (
    select 1 from public.tenant_memberships
    where user_id = p_user_id and tenant_id <> p_tenant_id
  )
  and not exists (select 1 from public.platform_memberships where user_id = p_user_id)
  and not exists (select 1 from public.platform_tenant_grants where platform_user_id = p_user_id)
  and exists (
    select 1 from auth.users where id = p_user_id
      and (banned_until is null or banned_until <= now())
  );
$$;

drop function public.list_tenant_users(uuid);
create function public.list_tenant_users(p_tenant_id uuid)
returns table (
  user_id uuid, email text, full_name text, avatar_url text,
  role text, is_active boolean, is_globally_disabled boolean,
  last_sign_in_at timestamptz, created_at timestamptz,
  can_manage_account boolean
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
      tm.role, tm.is_active, coalesce(au.banned_until > now(), false),
      au.last_sign_in_at, tm.created_at,
      au.id <> auth.uid() and public.can_manage_tenant_account(p_tenant_id, au.id)
    from public.tenant_memberships tm
    join auth.users au on au.id = tm.user_id
    left join public.user_profiles up on up.user_id = tm.user_id
    where tm.tenant_id = p_tenant_id
    order by lower(coalesce(nullif(up.full_name, ''), au.email::text)), au.id;
end;
$$;

create function public.update_tenant_user_account(
  p_actor_id uuid, p_tenant_id uuid, p_user_id uuid,
  p_full_name text, p_expected_name text, p_password_hash text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Keep scope validation, profile changes and credential changes atomic.
  lock table public.tenant_memberships, public.platform_memberships,
    public.platform_tenant_grants in share row exclusive mode;
  perform 1 from auth.users where id in (p_actor_id, p_user_id) order by id for update;
  if p_actor_id = p_user_id or not exists (
    select 1 from public.tenant_memberships m join auth.users u on u.id = m.user_id
    where m.tenant_id = p_tenant_id and m.user_id = p_actor_id
      and m.role = 'tenant_admin' and m.is_active
      and (u.banned_until is null or u.banned_until <= now())
      and u.raw_app_meta_data->>'must_set_password' is distinct from 'true'
  ) then
    raise exception 'Solo otro administrador activo de esta empresa puede editar la cuenta';
  end if;
  if not public.can_manage_tenant_account(p_tenant_id, p_user_id) then
    raise exception 'Cuenta compartida, de plataforma o bloqueada. Gestiona sus datos desde plataforma';
  end if;
  if p_full_name is null or length(trim(p_full_name)) not between 1 and 120 then
    raise exception 'El nombre debe tener entre 1 y 120 caracteres';
  end if;
  perform 1 from public.user_profiles where user_id = p_user_id for update;
  if coalesce((select full_name from public.user_profiles where user_id = p_user_id), '')
      is distinct from p_expected_name then
    raise exception 'El nombre cambio. Actualiza la lista antes de guardar';
  end if;
  if p_password_hash is not null and
    p_password_hash !~ '^\$2[ab]\$12\$[./A-Za-z0-9]{53}$' then
    raise exception 'Formato de credencial no valido';
  end if;

  insert into public.user_profiles(user_id, full_name)
    values(p_user_id, trim(p_full_name))
    on conflict (user_id) do update set full_name = excluded.full_name;
  update auth.users
    set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
          || jsonb_build_object('full_name', trim(p_full_name)),
        updated_at = now()
    where id = p_user_id;
  if p_password_hash is not null then
    update auth.users set encrypted_password = p_password_hash where id = p_user_id;
    -- The password-change trigger clears the old requirement; this is a new
    -- administrator-issued password, so require another change by its owner.
    update auth.users
      set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
            || '{"must_set_password":true}'::jsonb,
          raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
            || '{"must_set_password":true}'::jsonb
      where id = p_user_id;
    delete from auth.refresh_tokens where user_id = p_user_id::text;
    delete from auth.sessions where user_id = p_user_id;
  end if;
end;
$$;

revoke all on function public.can_manage_tenant_account(uuid, uuid) from public, anon, authenticated;
revoke all on function public.list_tenant_users(uuid) from public, anon, authenticated;
grant execute on function public.list_tenant_users(uuid) to authenticated;
revoke all on function public.update_tenant_user_account(uuid, uuid, uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.update_tenant_user_account(uuid, uuid, uuid, text, text, text)
  to service_role;
