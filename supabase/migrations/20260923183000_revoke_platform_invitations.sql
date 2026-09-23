create or replace function public.revoke_platform_invitation(
  p_invitation_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.platform_memberships
    where user_id = auth.uid()
      and role = 'platform_owner'
  ) then
    raise exception 'Platform owner access required';
  end if;

  update public.platform_invitations
  set status = 'revoked'
  where id = p_invitation_id
    and status = 'pending';

  if not found then
    raise exception 'Invitation is invalid or is no longer pending';
  end if;
end;
$$;

revoke all on function public.revoke_platform_invitation(uuid)
from public, anon, authenticated;
grant execute on function public.revoke_platform_invitation(uuid)
to authenticated;
