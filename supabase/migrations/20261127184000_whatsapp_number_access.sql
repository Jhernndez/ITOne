alter table public.whatsapp_accounts
  drop constraint if exists whatsapp_accounts_tenant_id_business_account_id_key;

create function public.connect_whatsapp_cloud_number(
  p_tenant uuid, p_phone text, p_waba text, p_token text, p_display text, p_name text
) returns uuid language plpgsql security definer set search_path = public as $$
declare existing whatsapp_accounts; account_id uuid;
begin
  if p_phone is null or p_waba is null or p_phone !~ '^[0-9]{1,40}$' or p_waba !~ '^[0-9]{1,40}$'
    or p_token is null or length(p_token) not between 1 and 4096 then
    raise exception 'Credenciales no validas';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('waba:' || p_waba, 0));
  perform pg_advisory_xact_lock(hashtextextended('phone:' || p_phone, 0));
  if exists (select 1 from whatsapp_accounts where business_account_id=p_waba and tenant_id<>p_tenant) then
    raise exception 'Esta cuenta pertenece a otra empresa';
  end if;
  select * into existing from whatsapp_accounts where phone_number_id=p_phone for update;
  if found then
    if existing.tenant_id<>p_tenant or existing.onboarding_mode<>'cloud_api'
      or existing.business_account_id<>p_waba then
      raise exception 'Este numero ya tiene otra conexion';
    end if;
    update whatsapp_accounts set access_token=p_token,display_phone_number=p_display,
      name=p_name,status='active',updated_at=now() where id=existing.id;
    return existing.id;
  end if;
  insert into whatsapp_accounts(tenant_id,phone_number_id,business_account_id,access_token,
    display_phone_number,name,status,onboarding_mode)
    values(p_tenant,p_phone,p_waba,p_token,p_display,p_name,'active','cloud_api')
    returning id into account_id;
  return account_id;
end;
$$;
revoke all on function public.connect_whatsapp_cloud_number(uuid,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.connect_whatsapp_cloud_number(uuid,text,text,text,text,text) to service_role;

create or replace function public.configure_whatsapp_bot(p_tenant_id uuid,p_account_id uuid,
  p_flow_id uuid,p_version integer,p_enabled boolean) returns void
language plpgsql security definer set search_path=public as $$
declare g jsonb; n jsonb;
begin
  if p_enabled is null then raise exception 'Indica si el bot debe estar activo'; end if;
  if public.current_tenant_role(p_tenant_id) is distinct from 'tenant_admin' then
    raise exception 'Solo un administrador activo puede configurar el bot';
  end if;
  perform 1 from whatsapp_accounts where id=p_account_id and tenant_id=p_tenant_id for update;
  if not found then raise exception 'Cuenta no disponible para esta empresa'; end if;
  if not p_enabled then
    update whatsapp_bot_bindings set enabled=false,updated_at=now()
      where account_id=p_account_id and tenant_id=p_tenant_id;
    return;
  end if;
  if not exists(select 1 from whatsapp_accounts where id=p_account_id
    and status='active' and onboarding_mode in ('coexistence','cloud_api')
    and nullif(access_token,'') is not null) then
    raise exception 'Conecta primero el numero de WhatsApp';
  end if;
  select graph into g from automation_flow_versions
    where tenant_id=p_tenant_id and flow_id=p_flow_id and version=p_version;
  if g is null then raise exception 'Version publicada no disponible para esta empresa'; end if;
  perform validate_automation_graph(g,true);
  for n in select value from jsonb_array_elements(g->'nodes') loop
    if n->>'kind'='api' and coalesce(n->'config'->>'resource_id','') !~
      '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' then
      raise exception 'Configura un recurso real en cada bloque API';
    end if;
    if n->>'kind'='api' and not exists(select 1 from tenant_api_resources r
      where r.id=(n->'config'->>'resource_id')::uuid and r.tenant_id=p_tenant_id
        and r.enabled and r.enabled_for_automation and (r.http_method='GET' or r.allow_automation_writes)) then
      raise exception 'El recurso API no pertenece a esta empresa o no tiene autorizacion para automatizacion';
    end if;
    if n->>'kind'='api' then
      if jsonb_typeof(coalesce(nullif(n->'config'->>'query',''),'{}')::jsonb) is distinct from 'object'
        or jsonb_typeof(coalesce(nullif(n->'config'->>'body',''),'{}')::jsonb) is distinct from 'object'
        or coalesce(nullif(n->'config'->>'result_variable',''),'api_result') !~ '^[a-zA-Z][a-zA-Z0-9_]{0,39}$'
        or (coalesce(n->'config'->>'result_path','')<>'' and n->'config'->>'result_path' !~
          '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)*$') then
        raise exception 'Configura objetos JSON y una variable de resultado valida en el bloque API';
      end if;
    end if;
  end loop;
  insert into whatsapp_bot_bindings(account_id,tenant_id,flow_id,version,enabled)
    values(p_account_id,p_tenant_id,p_flow_id,p_version,true)
    on conflict(account_id) do update set flow_id=excluded.flow_id,version=excluded.version,
      enabled=true,updated_at=now() where whatsapp_bot_bindings.tenant_id=p_tenant_id;
end;
$$;

create table public.whatsapp_number_access (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  account_id uuid not null references public.whatsapp_accounts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (account_id, user_id)
);

alter table public.whatsapp_number_access enable row level security;
revoke all on public.whatsapp_number_access from public, anon, authenticated;
grant select on public.whatsapp_number_access to authenticated;

create function public.can_access_whatsapp_number(p_tenant_id uuid, p_account_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from whatsapp_accounts a
    where a.id = p_account_id and a.tenant_id = p_tenant_id
      and (
        public.current_tenant_role(p_tenant_id) = 'tenant_admin'
        or (
          public.current_tenant_role(p_tenant_id) in ('supervisor', 'operator')
          and exists (
            select 1 from whatsapp_number_access access
            where access.tenant_id = p_tenant_id and access.account_id = a.id
              and access.user_id = auth.uid()
          )
        )
      )
  );
$$;
revoke all on function public.can_access_whatsapp_number(uuid,uuid) from public, anon, authenticated;
grant execute on function public.can_access_whatsapp_number(uuid,uuid) to authenticated;

create policy "read number permissions" on public.whatsapp_number_access
  for select to authenticated using (
    public.current_tenant_role(tenant_id) = 'tenant_admin'
    or (user_id = auth.uid() and public.current_tenant_role(tenant_id) in ('supervisor','operator'))
  );

create function public.set_whatsapp_number_access(
  p_tenant_id uuid, p_account_id uuid, p_user_id uuid, p_allowed boolean
) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_tenant_role(p_tenant_id) is distinct from 'tenant_admin' then
    raise exception 'Solo un administrador puede asignar numeros';
  end if;
  if p_allowed is null or not exists (
    select 1 from whatsapp_accounts where tenant_id = p_tenant_id and id = p_account_id
  ) then raise exception 'Numero no disponible'; end if;
  if not exists (
    select 1 from tenant_memberships where tenant_id = p_tenant_id and user_id = p_user_id and is_active
    union all
    select 1 from platform_tenant_grants where tenant_id = p_tenant_id and platform_user_id = p_user_id
  ) then raise exception 'Usuario no disponible para esta empresa'; end if;
  if p_allowed then
    insert into whatsapp_number_access(tenant_id, account_id, user_id)
      values (p_tenant_id, p_account_id, p_user_id) on conflict do nothing;
  else
    delete from whatsapp_number_access
      where tenant_id = p_tenant_id and account_id = p_account_id and user_id = p_user_id;
  end if;
end;
$$;
revoke all on function public.set_whatsapp_number_access(uuid,uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.set_whatsapp_number_access(uuid,uuid,uuid,boolean) to authenticated;

create policy "active roles read whatsapp accounts" on public.whatsapp_accounts
  for select to authenticated using (public.current_tenant_role(tenant_id) is not null);
create policy "active roles read whatsapp conversations" on public.whatsapp_conversations
  for select to authenticated using (public.current_tenant_role(tenant_id) is not null);
create policy "active roles read whatsapp messages" on public.whatsapp_messages
  for select to authenticated using (public.current_tenant_role(tenant_id) is not null);
create policy "active roles read whatsapp contacts" on public.whatsapp_contacts
  for select to authenticated using (public.current_tenant_role(tenant_id) is not null);

create policy "number access required" on public.whatsapp_accounts as restrictive
  for select to authenticated using (public.can_access_whatsapp_number(tenant_id,id));
create policy "number access required" on public.whatsapp_conversations as restrictive
  for select to authenticated using (public.can_access_whatsapp_number(tenant_id,whatsapp_account_id));
create policy "number access required" on public.whatsapp_messages as restrictive
  for select to authenticated using (public.can_access_whatsapp_number(tenant_id,whatsapp_account_id));
create policy "number access required" on public.whatsapp_contacts as restrictive
  for select to authenticated using (
    public.current_tenant_role(tenant_id) = 'tenant_admin'
    or (whatsapp_account_id is not null and public.can_access_whatsapp_number(tenant_id,whatsapp_account_id))
    or exists (
      select 1 from public.whatsapp_conversations c
      where c.tenant_id = whatsapp_contacts.tenant_id and c.contact_id = whatsapp_contacts.id
        and public.can_access_whatsapp_number(c.tenant_id,c.whatsapp_account_id)
    )
  );
create policy "number access required" on public.whatsapp_bot_sessions as restrictive
  for select to authenticated using (public.can_access_whatsapp_number(tenant_id,account_id));
create policy "number access required" on public.whatsapp_bot_jobs as restrictive
  for select to authenticated using (public.can_access_whatsapp_number(tenant_id,account_id));

create policy "number access required for chat notifications" on public.notifications as restrictive
  for all to authenticated
  using (
    type not in ('whatsapp_inbound', 'unanswered_chat')
    or exists (
      select 1 from public.whatsapp_conversations c
      where c.tenant_id = notifications.tenant_id
        and c.id::text = notifications.data->>'conversation_id'
        and public.can_access_whatsapp_number(c.tenant_id,c.whatsapp_account_id)
    )
  )
  with check (
    type not in ('whatsapp_inbound', 'unanswered_chat')
    or exists (
      select 1 from public.whatsapp_conversations c
      where c.tenant_id = notifications.tenant_id
        and c.id::text = notifications.data->>'conversation_id'
        and public.can_access_whatsapp_number(c.tenant_id,c.whatsapp_account_id)
    )
  );

alter function public.control_whatsapp_bot(uuid,uuid,text,text) rename to control_whatsapp_bot_v1;
revoke all on function public.control_whatsapp_bot_v1(uuid,uuid,text,text) from public, anon, authenticated;
create function public.control_whatsapp_bot(
  p_tenant_id uuid,p_conversation_id uuid,p_action text,p_reason text default ''
) returns void language plpgsql security definer set search_path=public as $$
declare account uuid;
begin
  select whatsapp_account_id into account from whatsapp_conversations
    where tenant_id = p_tenant_id and id = p_conversation_id;
  if account is null or not public.can_access_whatsapp_number(p_tenant_id,account) then
    raise exception 'No tienes acceso a esta conversacion';
  end if;
  perform public.control_whatsapp_bot_v1(p_tenant_id,p_conversation_id,p_action,p_reason);
end;
$$;
revoke all on function public.control_whatsapp_bot(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.control_whatsapp_bot(uuid,uuid,text,text) to authenticated;
