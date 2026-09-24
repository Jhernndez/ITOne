alter table public.whatsapp_messages
  add column if not exists delivery_status text not null default 'accepted'
  check (delivery_status in ('accepted', 'sent', 'delivered', 'read', 'failed'));

alter table public.whatsapp_messages
  add column if not exists delivery_error_code text,
  add column if not exists delivery_error text;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'whatsapp_conversations'
  ) then
    alter publication supabase_realtime add table public.whatsapp_conversations;
  end if;
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'whatsapp_messages'
  ) then
    alter publication supabase_realtime add table public.whatsapp_messages;
  end if;
end $$;
