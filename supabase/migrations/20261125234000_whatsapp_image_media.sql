alter table public.whatsapp_messages
  add column media_id text check (media_id is null or media_id ~ '^[0-9]{1,64}$'),
  add column media_mime_type text;
