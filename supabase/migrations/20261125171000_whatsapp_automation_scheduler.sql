create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

create function public.dispatch_whatsapp_bot() returns bigint
language plpgsql security definer set search_path=public as $$
declare worker_url text; worker_secret text; request_id bigint;
begin
  select decrypted_secret into worker_url from vault.decrypted_secrets where name='itone_bot_worker_url';
  select decrypted_secret into worker_secret from vault.decrypted_secrets where name='itone_bot_worker_secret';
  if worker_url is null or worker_secret is null then
    raise exception 'Configura el worker de automatizacion en Vault antes de activar bots';
  end if;
  select net.http_post(
    url:=worker_url,
    headers:=jsonb_build_object('Content-Type','application/json','x-bot-secret',worker_secret),
    body:='{}'::jsonb,
    timeout_milliseconds:=100000
  ) into request_id;
  return request_id;
end;
$$;
revoke all on function public.dispatch_whatsapp_bot() from public,anon,authenticated;
grant execute on function public.dispatch_whatsapp_bot() to service_role;
select cron.schedule('itone-whatsapp-bot','* * * * *','select public.dispatch_whatsapp_bot();');
