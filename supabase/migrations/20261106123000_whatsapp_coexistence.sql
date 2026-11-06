alter table public.whatsapp_accounts
  add column onboarding_mode text not null default 'cloud_api'
    check (onboarding_mode in ('cloud_api', 'coexistence')),
  add column history_sync_status text not null default 'not_requested'
    check (history_sync_status in ('not_requested', 'pending', 'syncing', 'complete', 'declined', 'error')),
  add column history_sync_progress integer not null default 0
    check (history_sync_progress between 0 and 100),
  add column history_sync_error text,
  add column contacts_sync_request_id text,
  add column history_sync_request_id text;

grant select (onboarding_mode, history_sync_status, history_sync_progress,
  history_sync_error, contacts_sync_request_id, history_sync_request_id)
  on public.whatsapp_accounts to authenticated;

alter table public.whatsapp_contacts
  alter column phone_number drop not null,
  add column whatsapp_user_id text,
  add column whatsapp_account_id uuid references public.whatsapp_accounts(id) on delete cascade,
  add column address_book_updated_at timestamptz;

create unique index whatsapp_contacts_scoped_user_idx
  on public.whatsapp_contacts (whatsapp_account_id, whatsapp_user_id)
  where whatsapp_user_id is not null;

alter table public.whatsapp_conversations
  drop constraint whatsapp_conversations_tenant_id_contact_id_status_key,
  add constraint whatsapp_conversations_account_contact_status_key
    unique (tenant_id, whatsapp_account_id, contact_id, status);

alter table public.whatsapp_messages
  add column source text not null default 'cloud_api'
    check (source in ('cloud_api', 'business_app', 'history')),
  add column original_message_id text,
  add column content_updated_at timestamptz;

alter table public.tenant_integrations
  drop constraint tenant_integrations_status_check,
  add constraint tenant_integrations_status_check check (
    status in ('not_configured', 'configuring', 'active', 'error', 'disabled', 'restricted')
  );

create or replace function public.connect_whatsapp_coexistence(
  p_tenant_id uuid, p_phone_number_id text, p_business_account_id text,
  p_access_token text, p_display_phone_number text, p_name text
) returns uuid
language plpgsql
set search_path = public
as $$
declare
  account_id uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('waba:' || p_business_account_id, 0));
  perform pg_advisory_xact_lock(hashtextextended('phone:' || p_phone_number_id, 0));
  if exists (
    select 1 from whatsapp_accounts
    where (phone_number_id = p_phone_number_id or business_account_id = p_business_account_id)
      and tenant_id <> p_tenant_id
  ) then
    raise exception 'This WhatsApp asset is already connected to another tenant';
  end if;
  insert into whatsapp_accounts (
    tenant_id, phone_number_id, business_account_id, access_token,
    display_phone_number, name, status, onboarding_mode
  ) values (
    p_tenant_id, p_phone_number_id, p_business_account_id, p_access_token,
    p_display_phone_number, p_name, 'active', 'coexistence'
  )
  on conflict (phone_number_id) do update set
    business_account_id = excluded.business_account_id,
    access_token = excluded.access_token,
    display_phone_number = excluded.display_phone_number,
    name = excluded.name,
    status = 'active',
    onboarding_mode = 'coexistence',
    updated_at = now()
  where whatsapp_accounts.tenant_id = p_tenant_id
  returning id into account_id;
  if account_id is null then
    raise exception 'This WhatsApp asset is already connected to another tenant';
  end if;

  insert into tenant_integrations (tenant_id, provider, status, configured_at, metadata)
  values (p_tenant_id, 'whatsapp', 'active', now(), jsonb_build_object(
    'business_account_id', p_business_account_id,
    'phone_number_id', p_phone_number_id,
    'display_phone_number', p_display_phone_number,
    'name', p_name,
    'onboarding_mode', 'coexistence'
  ))
  on conflict (tenant_id, provider) do update set
    status = excluded.status, configured_at = now(),
    metadata = excluded.metadata, updated_at = now();
  return account_id;
end;
$$;

-- One database transaction per webhook chunk; retries cannot duplicate messages,
-- and older history chunks cannot move live conversations backwards in time.
create or replace function public.ingest_whatsapp_messages(
  p_account_id uuid, p_messages jsonb
) returns jsonb
language plpgsql
set search_path = public
as $$
declare
  account_row whatsapp_accounts%rowtype;
  item jsonb;
  contact_id_value uuid;
  conversation_id_value uuid;
  message_time timestamptz;
  inserted_count integer := 0;
  affected integer;
  latest_edit whatsapp_messages%rowtype;
begin
  select * into strict account_row from whatsapp_accounts
    where id = p_account_id and status = 'active' for update;
  for item in select * from jsonb_array_elements(p_messages)
  loop
    if nullif(item->>'provider_message_id', '') is null
      or (nullif(item->>'phone_number', '') is null and nullif(item->>'user_id', '') is null)
      or item->>'direction' not in ('inbound', 'outbound')
    then
      raise exception 'Invalid WhatsApp message identity or direction';
    end if;
    message_time := (item->>'timestamp')::timestamptz;
    contact_id_value := null;
    if nullif(item->>'phone_number', '') is not null then
      select id into contact_id_value from whatsapp_contacts
        where tenant_id = account_row.tenant_id and phone_number = item->>'phone_number';
    end if;
    if contact_id_value is null and nullif(item->>'user_id', '') is not null then
      select id into contact_id_value from whatsapp_contacts
        where whatsapp_account_id = p_account_id and whatsapp_user_id = item->>'user_id';
    end if;
    if contact_id_value is null then
      insert into whatsapp_contacts (
        tenant_id, phone_number, whatsapp_user_id, whatsapp_account_id, profile_name, last_message_at
      ) values (
        account_row.tenant_id, nullif(item->>'phone_number', ''), nullif(item->>'user_id', ''),
        p_account_id, item->>'profile_name', message_time
      )
      on conflict (tenant_id, phone_number) do update set
        last_message_at = greatest(whatsapp_contacts.last_message_at, excluded.last_message_at)
      returning id into contact_id_value;
    else
      update whatsapp_contacts set
        profile_name = coalesce(nullif(item->>'profile_name', ''), profile_name),
        phone_number = coalesce(phone_number, nullif(item->>'phone_number', '')),
        whatsapp_user_id = case when whatsapp_account_id is null or whatsapp_account_id = p_account_id
          then coalesce(nullif(item->>'user_id', ''), whatsapp_user_id) else whatsapp_user_id end,
        whatsapp_account_id = coalesce(whatsapp_account_id, p_account_id),
        last_message_at = greatest(last_message_at, message_time),
        updated_at = greatest(updated_at, message_time)
      where id = contact_id_value;
    end if;
    select id into conversation_id_value from whatsapp_conversations
      where tenant_id = account_row.tenant_id and whatsapp_account_id = p_account_id
        and contact_id = contact_id_value
      order by (status = 'open') desc, updated_at desc limit 1;
    if conversation_id_value is null then
      insert into whatsapp_conversations (
        tenant_id, whatsapp_account_id, contact_id, status, last_message_at, updated_at
      ) values (
        account_row.tenant_id, p_account_id, contact_id_value, 'open',
        message_time, coalesce(message_time, now())
      ) returning id into conversation_id_value;
    end if;
    insert into whatsapp_messages (
      tenant_id, conversation_id, whatsapp_account_id, provider_message_id,
      direction, message_type, body, provider_timestamp, created_at, delivery_status, source,
      original_message_id
    ) values (
      account_row.tenant_id, conversation_id_value, p_account_id, item->>'provider_message_id',
      item->>'direction', item->>'message_type', item->>'body',
      message_time, coalesce(message_time, now()), item->>'delivery_status', item->>'source',
      item->>'original_message_id'
    ) on conflict (whatsapp_account_id, provider_message_id) do nothing;
    get diagnostics affected = row_count;
    inserted_count := inserted_count + affected;
    if item->>'original_message_id' is not null then
      update whatsapp_messages set body = item->>'body', content_updated_at = message_time
        where whatsapp_account_id = p_account_id
          and provider_message_id = item->>'original_message_id'
          and (content_updated_at is null or content_updated_at < message_time);
    else
      select * into latest_edit from whatsapp_messages
        where whatsapp_account_id = p_account_id
          and original_message_id = item->>'provider_message_id'
        order by provider_timestamp desc limit 1;
      if found then
        update whatsapp_messages set body = latest_edit.body,
          content_updated_at = latest_edit.provider_timestamp
          where whatsapp_account_id = p_account_id
            and provider_message_id = item->>'provider_message_id'
            and (content_updated_at is null or content_updated_at < latest_edit.provider_timestamp);
      end if;
    end if;
    update whatsapp_conversations set
      last_message_at = greatest(last_message_at, message_time),
      updated_at = greatest(updated_at, message_time),
      status = case when item->>'source' = 'cloud_api' and item->>'direction' = 'inbound'
        then 'open' else status end
      where id = conversation_id_value;
    if affected = 1 and item->>'source' = 'cloud_api' and item->>'direction' = 'inbound' then
      insert into notifications (tenant_id, recipient_user_id, type, title, body, data)
        select account_row.tenant_id, user_id, 'whatsapp_inbound', 'Nuevo mensaje de WhatsApp',
          coalesce(item->>'profile_name', item->>'phone_number', item->>'user_id') || ': ' ||
            coalesce(item->>'body', 'Mensaje recibido'),
          jsonb_build_object('conversation_id', conversation_id_value,
            'provider_message_id', item->>'provider_message_id',
            'phone_number', item->>'phone_number')
        from tenant_memberships where tenant_id = account_row.tenant_id
          and role in ('tenant_admin', 'supervisor', 'operator');
    end if;
  end loop;
  return jsonb_build_object('inserted', inserted_count);
end;
$$;

create or replace function public.update_whatsapp_history_progress(
  p_account_id uuid, p_progress integer, p_error text, p_declined boolean
) returns void
language sql
set search_path = public
as $$
  update whatsapp_accounts set
    history_sync_progress = greatest(history_sync_progress, coalesce(p_progress, 0)),
    history_sync_status = case
      when p_declined then 'declined'
      when p_error is not null then 'error'
      when greatest(history_sync_progress, coalesce(p_progress, 0)) >= 100 then 'complete'
      else 'syncing' end,
    history_sync_error = p_error,
    updated_at = now()
  where id = p_account_id
    and (p_progress is not null or p_error is not null)
    and history_sync_status <> 'declined';
$$;

create or replace function public.sync_whatsapp_contacts(p_account_id uuid, p_contacts jsonb)
returns void
language plpgsql
set search_path = public
as $$
declare
  account_row whatsapp_accounts%rowtype;
  item jsonb;
  contact jsonb;
  contact_id_value uuid;
  contact_phone text;
  contact_time timestamptz;
begin
  select * into strict account_row from whatsapp_accounts
    where id = p_account_id and status = 'active' for update;
  for item in select * from jsonb_array_elements(p_contacts)
  loop
    if item->>'type' <> 'contact' then continue; end if;
    contact := item->'contact';
    contact_phone := nullif(regexp_replace(contact->>'phone_number', '[^0-9]', '', 'g'), '');
    contact_time := to_timestamp((item->'metadata'->>'timestamp')::double precision);
    if contact_phone is null and nullif(contact->>'user_id', '') is null then
      raise exception 'State sync contact lacks an identity';
    end if;
    select id into contact_id_value from whatsapp_contacts
      where tenant_id = account_row.tenant_id and (
        (contact_phone is not null and phone_number = contact_phone)
        or (whatsapp_account_id = p_account_id and whatsapp_user_id = contact->>'user_id')
      ) limit 1;
    if contact_id_value is null then
      insert into whatsapp_contacts (
        tenant_id, phone_number, whatsapp_user_id, whatsapp_account_id, display_name, address_book_updated_at
      ) values (
        account_row.tenant_id, contact_phone, contact->>'user_id', p_account_id,
        case when item->>'action' = 'add' then coalesce(contact->>'full_name', contact->>'first_name') end,
        contact_time
      ) on conflict (tenant_id, phone_number) do nothing;
    else
      update whatsapp_contacts set
        display_name = case when item->>'action' = 'remove' then null
          else coalesce(contact->>'full_name', contact->>'first_name') end,
        address_book_updated_at = contact_time,
        updated_at = now()
        where id = contact_id_value
          and (address_book_updated_at is null or address_book_updated_at <= contact_time);
    end if;
  end loop;
end;
$$;

revoke all on function public.connect_whatsapp_coexistence(uuid, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.connect_whatsapp_coexistence(uuid, text, text, text, text, text)
  to service_role;
revoke all on function public.ingest_whatsapp_messages(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.ingest_whatsapp_messages(uuid, jsonb) to service_role;
revoke all on function public.update_whatsapp_history_progress(uuid, integer, text, boolean)
  from public, anon, authenticated;
grant execute on function public.update_whatsapp_history_progress(uuid, integer, text, boolean)
  to service_role;
revoke all on function public.sync_whatsapp_contacts(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.sync_whatsapp_contacts(uuid, jsonb) to service_role;
