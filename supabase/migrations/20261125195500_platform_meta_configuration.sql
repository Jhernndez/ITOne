-- The server only needs the public company identity for owner diagnostics.
grant select(id,name) on public.tenants to service_role;

create table public.platform_meta_configuration (
  id boolean primary key default true check(id),
  app_id text not null check(app_id ~ '^[0-9]{5,30}$'),
  config_id text not null check(config_id ~ '^[0-9]{5,30}$'),
  app_secret_id uuid references vault.secrets(id),
  verify_token_id uuid references vault.secrets(id),
  updated_at timestamptz not null default now()
);
alter table public.platform_meta_configuration enable row level security;
revoke all on public.platform_meta_configuration from public,anon,authenticated;
grant all on public.platform_meta_configuration to service_role;

create function public.read_platform_meta_configuration() returns jsonb
language sql security definer set search_path=public as $$
  select jsonb_build_object('app_id',c.app_id,'config_id',c.config_id,
    'app_secret',(select decrypted_secret from vault.decrypted_secrets where id=c.app_secret_id),
    'verify_token',(select decrypted_secret from vault.decrypted_secrets where id=c.verify_token_id),
    'updated_at',c.updated_at)
  from platform_meta_configuration c where id=true;
$$;
create function public.write_platform_meta_configuration(p_app_id text,p_config_id text,
  p_app_secret text default null,p_verify_token text default null) returns void
language plpgsql security definer set search_path=public as $$
declare c platform_meta_configuration; secret_id uuid; token_id uuid;
begin
  perform pg_advisory_xact_lock(72451861);
  select * into c from platform_meta_configuration where id=true for update;
  if p_app_id is null or p_config_id is null or p_app_id !~ '^[0-9]{5,30}$' or p_config_id !~ '^[0-9]{5,30}$' then raise exception 'IDs de Meta no validos'; end if;
  if c.app_id is not null and c.app_id<>p_app_id and nullif(p_app_secret,'') is null then
    raise exception 'Al cambiar la app debes configurar su App Secret';
  end if;
  secret_id:=c.app_secret_id; token_id:=c.verify_token_id;
  if nullif(p_app_secret,'') is not null then
    if length(p_app_secret) not between 16 and 256 then raise exception 'App Secret no valido'; end if;
    if secret_id is null then select vault.create_secret(p_app_secret) into secret_id;
    else perform vault.update_secret(secret_id,p_app_secret); end if;
  end if;
  if nullif(p_verify_token,'') is not null then
    if length(p_verify_token) not between 8 and 256 then raise exception 'Token de webhook no valido'; end if;
    if token_id is null then select vault.create_secret(p_verify_token) into token_id;
    else perform vault.update_secret(token_id,p_verify_token); end if;
  end if;
  insert into platform_meta_configuration(id,app_id,config_id,app_secret_id,verify_token_id)
    values(true,p_app_id,p_config_id,secret_id,token_id)
    on conflict(id) do update set app_id=excluded.app_id,config_id=excluded.config_id,
      app_secret_id=excluded.app_secret_id,verify_token_id=excluded.verify_token_id,updated_at=now();
end;
$$;
revoke all on function public.read_platform_meta_configuration(),
  public.write_platform_meta_configuration(text,text,text,text) from public,anon,authenticated;
grant execute on function public.read_platform_meta_configuration(),
  public.write_platform_meta_configuration(text,text,text,text) to service_role;
