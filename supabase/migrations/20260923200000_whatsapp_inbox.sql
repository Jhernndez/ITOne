create table if not exists public.whatsapp_accounts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  phone_number_id text not null unique,
  business_account_id text not null,
  display_phone_number text,
  name text,
  access_token text,
  status text not null default 'active'
    check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, business_account_id)
);

create table if not exists public.whatsapp_contacts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  phone_number text not null,
  display_name text,
  profile_name text,
  last_message_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, phone_number)
);

create table if not exists public.whatsapp_conversations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  whatsapp_account_id uuid not null references public.whatsapp_accounts(id) on delete cascade,
  contact_id uuid not null references public.whatsapp_contacts(id) on delete cascade,
  status text not null default 'open'
    check (status in ('open', 'pending', 'closed')),
  last_message_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, contact_id, status)
);

create table if not exists public.whatsapp_messages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  conversation_id uuid not null references public.whatsapp_conversations(id) on delete cascade,
  whatsapp_account_id uuid not null references public.whatsapp_accounts(id) on delete cascade,
  provider_message_id text not null,
  direction text not null check (direction in ('inbound', 'outbound')),
  message_type text not null default 'text',
  body text,
  provider_timestamp timestamptz,
  created_at timestamptz not null default now(),
  unique (whatsapp_account_id, provider_message_id)
);

create index if not exists whatsapp_contacts_tenant_idx
  on public.whatsapp_contacts (tenant_id, last_message_at desc);
create index if not exists whatsapp_conversations_tenant_idx
  on public.whatsapp_conversations (tenant_id, updated_at desc);
create index if not exists whatsapp_messages_conversation_idx
  on public.whatsapp_messages (tenant_id, conversation_id, created_at);

alter table public.whatsapp_accounts enable row level security;
alter table public.whatsapp_contacts enable row level security;
alter table public.whatsapp_conversations enable row level security;
alter table public.whatsapp_messages enable row level security;

grant select on public.whatsapp_accounts,
  public.whatsapp_contacts,
  public.whatsapp_conversations,
  public.whatsapp_messages to authenticated;

create policy "tenant members can read whatsapp accounts"
on public.whatsapp_accounts for select to authenticated
using (exists (
  select 1 from public.tenant_memberships m
  where m.tenant_id = whatsapp_accounts.tenant_id
    and m.user_id = auth.uid()
));

create policy "tenant members can read whatsapp contacts"
on public.whatsapp_contacts for select to authenticated
using (exists (
  select 1 from public.tenant_memberships m
  where m.tenant_id = whatsapp_contacts.tenant_id
    and m.user_id = auth.uid()
));

create policy "tenant members can read whatsapp conversations"
on public.whatsapp_conversations for select to authenticated
using (exists (
  select 1 from public.tenant_memberships m
  where m.tenant_id = whatsapp_conversations.tenant_id
    and m.user_id = auth.uid()
));

create policy "tenant members can read whatsapp messages"
on public.whatsapp_messages for select to authenticated
using (exists (
  select 1 from public.tenant_memberships m
  where m.tenant_id = whatsapp_messages.tenant_id
    and m.user_id = auth.uid()
));
