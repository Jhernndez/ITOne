alter table public.tenant_memberships
  drop constraint if exists tenant_memberships_role_check;

alter table public.tenant_memberships
  add constraint tenant_memberships_role_check
  check (role in ('tenant_admin', 'supervisor', 'operator'));
