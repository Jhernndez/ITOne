alter table public.platform_invitations
  alter column platform_role drop not null;

create or replace function public.create_platform_invitation(
  p_email text,
  p_platform_role text,
  p_tenant_id uuid default null,
  p_tenant_role text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  invitation_id uuid;
begin
  if not exists (
    select 1 from public.platform_memberships
    where user_id = auth.uid() and role = 'platform_owner'
  ) then
    raise exception 'Platform owner access required';
  end if;

  if p_email is null or position('@' in p_email) < 2 then
    raise exception 'Valid email is required';
  end if;

  if p_platform_role is null
     and (p_tenant_id is null or p_tenant_role is null) then
    raise exception 'A tenant role is required when platform access is not granted';
  end if;

  if p_platform_role is not null
     and p_platform_role not in ('platform_admin', 'platform_support') then
    raise exception 'Invalid platform role';
  end if;

  if (p_tenant_id is null) <> (p_tenant_role is null) then
    raise exception 'Tenant role and tenant are required together';
  end if;

  if p_tenant_id is not null
     and not exists (select 1 from public.tenants where id = p_tenant_id) then
    raise exception 'Tenant not found';
  end if;

  insert into public.platform_invitations (
    email, platform_role, tenant_id, tenant_role, invited_by
  )
  values (
    lower(trim(p_email)), p_platform_role, p_tenant_id, p_tenant_role, auth.uid()
  )
  returning id into invitation_id;

  return invitation_id;
end;
$$;

create or replace function public.accept_platform_invitation(
  p_invitation_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  invitation public.platform_invitations;
  current_email text;
begin
  select * into invitation
  from public.platform_invitations
  where id = p_invitation_id
    and status = 'pending'
    and expires_at > now()
  for update;

  if not found then
    raise exception 'Invitation is invalid, expired, or already used';
  end if;

  select email into current_email from auth.users where id = auth.uid();
  if lower(current_email) <> invitation.email then
    raise exception 'Invitation email does not match authenticated user';
  end if;

  if invitation.platform_role is not null then
    insert into public.platform_memberships (user_id, role)
    values (auth.uid(), invitation.platform_role)
    on conflict (user_id) do update set role = excluded.role;
  end if;

  if invitation.tenant_id is not null then
    insert into public.tenant_memberships (tenant_id, user_id, role)
    values (invitation.tenant_id, auth.uid(), invitation.tenant_role)
    on conflict (tenant_id, user_id) do update set role = excluded.role;
  end if;

  update public.platform_invitations
  set status = 'accepted', accepted_at = now()
  where id = invitation.id;
end;
$$;
