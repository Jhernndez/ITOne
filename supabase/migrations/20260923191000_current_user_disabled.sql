create or replace function public.is_current_user_disabled()
returns boolean
language sql
security definer
set search_path = public
as $$
  select coalesce(
    au.banned_until is not null and au.banned_until > now(),
    false
  )
  from auth.users au
  where au.id = auth.uid();
$$;

revoke all on function public.is_current_user_disabled()
from public, anon, authenticated;
grant execute on function public.is_current_user_disabled() to authenticated;
