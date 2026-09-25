-- Tenant-scoped notifications and internal API integrations foundation.
--
-- Tables:
--   notifications                 - per-user, tenant-scoped notification feed
--   tenant_notification_settings  - tenant + per-user notification preferences
--   tenant_api_integrations       - tenant-scoped external/internal API integration definitions
--   tenant_api_resources          - individual callable resources (path + method) per integration
--
-- All tables are tenant-scoped via tenant_id referencing public.tenants and are protected
-- by row level security. Only tenant admins may manage settings/integrations/resources;
-- members may read their own notifications and the notification settings relevant to them.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists notifications_recipient_idx
  on public.notifications (tenant_id, recipient_user_id, created_at desc);
create index if not exists notifications_unread_idx
  on public.notifications (tenant_id, recipient_user_id)
  where read_at is null;

alter table public.notifications enable row level security;

grant select, update on public.notifications to authenticated;
-- Notifications are created by trusted backend logic (e.g. security definer
-- functions or service role), not directly inserted by end users.
grant insert, delete on public.notifications to service_role;

create policy "recipients can read own notifications"
on public.notifications for select to authenticated
using (
  recipient_user_id = (select auth.uid())
  and exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = notifications.tenant_id
      and membership.user_id = (select auth.uid())
  )
);

create policy "recipients can update own notifications"
on public.notifications for update to authenticated
using (recipient_user_id = (select auth.uid()))
with check (recipient_user_id = (select auth.uid()));

create table if not exists public.tenant_notification_settings (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  browser_notifications_enabled boolean not null default true,
  email_notifications_enabled boolean not null default true,
  unanswered_chat_threshold_minutes integer not null default 15
    check (unanswered_chat_threshold_minutes > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (tenant_id, user_id)
);

create index if not exists tenant_notification_settings_tenant_idx
  on public.tenant_notification_settings (tenant_id);

alter table public.tenant_notification_settings enable row level security;

grant select, insert, update, delete on public.tenant_notification_settings to authenticated;

create policy "members can read own notification settings"
on public.tenant_notification_settings for select to authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_notification_settings.tenant_id
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
);

create policy "tenant admins can manage notification settings"
on public.tenant_notification_settings for all to authenticated
using (
  exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_notification_settings.tenant_id
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
)
with check (
  exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_notification_settings.tenant_id
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
);

create policy "members can update own notification settings"
on public.tenant_notification_settings for update to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_notification_settings.tenant_id
      and membership.user_id = (select auth.uid())
  )
)
with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_notification_settings.tenant_id
      and membership.user_id = (select auth.uid())
  )
);

create table if not exists public.tenant_api_integrations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  base_url text not null,
  auth_type text not null default 'none'
    check (auth_type in ('none', 'api_key', 'bearer_token', 'basic', 'oauth2')),
  auth_config jsonb not null default '{}'::jsonb,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, name)
);

create index if not exists tenant_api_integrations_tenant_idx
  on public.tenant_api_integrations (tenant_id);

alter table public.tenant_api_integrations enable row level security;

grant select, insert, update, delete on public.tenant_api_integrations to authenticated;

create policy "tenant members can view api integrations"
on public.tenant_api_integrations for select to authenticated
using (
  exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_api_integrations.tenant_id
      and membership.user_id = (select auth.uid())
  )
);

create policy "tenant admins can manage api integrations"
on public.tenant_api_integrations for all to authenticated
using (
  exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_api_integrations.tenant_id
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
)
with check (
  exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_api_integrations.tenant_id
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
);

create table if not exists public.tenant_api_resources (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  integration_id uuid not null references public.tenant_api_integrations(id) on delete cascade,
  name text not null,
  path text not null,
  http_method text not null default 'GET'
    check (http_method in ('GET', 'POST', 'PUT', 'PATCH', 'DELETE')),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (integration_id, name)
);

create index if not exists tenant_api_resources_tenant_idx
  on public.tenant_api_resources (tenant_id);
create index if not exists tenant_api_resources_integration_idx
  on public.tenant_api_resources (integration_id);

alter table public.tenant_api_resources enable row level security;

grant select, insert, update, delete on public.tenant_api_resources to authenticated;

create policy "tenant members can view api resources"
on public.tenant_api_resources for select to authenticated
using (
  exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_api_resources.tenant_id
      and membership.user_id = (select auth.uid())
  )
);

create policy "tenant admins can manage api resources"
on public.tenant_api_resources for all to authenticated
using (
  exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_api_resources.tenant_id
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
)
with check (
  exists (
    select 1 from public.tenant_memberships membership
    where membership.tenant_id = tenant_api_resources.tenant_id
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
  and exists (
    select 1 from public.tenant_api_integrations integration
    where integration.id = tenant_api_resources.integration_id
      and integration.tenant_id = tenant_api_resources.tenant_id
  )
);
