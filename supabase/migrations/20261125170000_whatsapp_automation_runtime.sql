alter table public.automation_flow_versions drop constraint automation_flow_versions_mode_check;
alter table public.automation_flow_versions add constraint automation_flow_versions_mode_check
  check(mode in ('simulation','published'));
alter table public.automation_flow_versions alter column mode set default 'published';

create table public.whatsapp_bot_bindings (
  account_id uuid primary key references public.whatsapp_accounts(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  flow_id uuid not null,
  version integer not null,
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  foreign key(flow_id, version) references public.automation_flow_versions(flow_id,version)
);
create table public.whatsapp_bot_sessions (
  conversation_id uuid primary key references public.whatsapp_conversations(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  account_id uuid not null references public.whatsapp_accounts(id) on delete cascade,
  flow_id uuid not null,
  version integer not null,
  node_id text not null,
  variables jsonb not null default '{}',
  status text not null default 'running'
    check (status in ('running','waiting','human','completed','error')),
  steps integer not null default 0,
  review_pending boolean not null default false,
  error text,
  updated_at timestamptz not null default now(),
  foreign key(flow_id,version) references public.automation_flow_versions(flow_id,version)
);
create table public.whatsapp_bot_jobs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  account_id uuid not null references public.whatsapp_accounts(id) on delete cascade,
  conversation_id uuid not null references public.whatsapp_conversations(id) on delete cascade,
  message_id uuid unique references public.whatsapp_messages(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','processing','done','failed')),
  lease uuid,
  error text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);
create index on public.whatsapp_bot_jobs(created_at) where status='pending';
create index on public.whatsapp_bot_jobs(conversation_id,status);
create table public.whatsapp_bot_effects (
  job_id uuid not null references public.whatsapp_bot_jobs(id) on delete cascade,
  step integer not null,
  kind text not null check(kind in ('message','api')),
  status text not null default 'started' check(status in ('started','confirmed','failed','unknown')),
  provider_id text,
  created_at timestamptz not null default now(),
  primary key(job_id,step)
);

alter table public.whatsapp_bot_bindings enable row level security;
alter table public.whatsapp_bot_sessions enable row level security;
alter table public.whatsapp_bot_jobs enable row level security;
alter table public.whatsapp_bot_effects enable row level security;
revoke all on public.whatsapp_bot_bindings, public.whatsapp_bot_sessions,
  public.whatsapp_bot_jobs, public.whatsapp_bot_effects from public,anon,authenticated;
grant select on public.whatsapp_bot_bindings,public.whatsapp_bot_sessions,public.whatsapp_bot_jobs to authenticated;
grant all on public.whatsapp_bot_bindings,public.whatsapp_bot_sessions,
  public.whatsapp_bot_jobs,public.whatsapp_bot_effects to service_role;
create policy "managers read bot bindings" on public.whatsapp_bot_bindings for select to authenticated
  using (public.current_tenant_role(tenant_id) in ('tenant_admin','supervisor'));
create policy "team reads bot sessions" on public.whatsapp_bot_sessions for select to authenticated
  using (public.current_tenant_role(tenant_id) in ('tenant_admin','supervisor','operator'));
create policy "managers read bot jobs" on public.whatsapp_bot_jobs for select to authenticated
  using (public.current_tenant_role(tenant_id) in ('tenant_admin','supervisor'));

create function public.configure_whatsapp_bot(p_tenant_id uuid,p_account_id uuid,
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
    and status='active' and onboarding_mode='coexistence' and nullif(access_token,'') is not null) then
    raise exception 'Conecta primero el numero mediante coexistencia';
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

create function public.control_whatsapp_bot(p_tenant_id uuid,p_conversation_id uuid,
  p_action text,p_reason text default '') returns void
language plpgsql security definer set search_path=public as $$
declare c whatsapp_conversations; s whatsapp_bot_sessions; g jsonb; n jsonb; dest text;
begin
  if coalesce(public.current_tenant_role(p_tenant_id),'') not in ('tenant_admin','supervisor','operator') then
    raise exception 'No tienes acceso a esta conversacion';
  end if;
  select * into c from whatsapp_conversations
    where id=p_conversation_id and tenant_id=p_tenant_id for update;
  if not found then raise exception 'Conversacion no disponible'; end if;
  select * into s from whatsapp_bot_sessions where conversation_id=c.id for update;
  if p_action='pause' then
    if s.conversation_id is null then
      insert into whatsapp_bot_sessions(conversation_id,tenant_id,account_id,flow_id,version,node_id,status)
        select c.id,p_tenant_id,c.whatsapp_account_id,b.flow_id,b.version,'','human'
        from whatsapp_bot_bindings b where b.account_id=c.whatsapp_account_id;
    else
      update whatsapp_bot_sessions set status='human',updated_at=now() where conversation_id=c.id;
    end if;
  elsif p_action='resume' then
    -- Restart on the next inbound message; never replay an uncertain effect.
    update whatsapp_bot_jobs set status='failed',finished_at=now(),error='Reactivado manualmente'
      where conversation_id=c.id and status in ('pending','processing');
    delete from whatsapp_bot_sessions where conversation_id=c.id;
  elsif p_action in ('approve','deny') then
    if s.status is distinct from 'human' then raise exception 'La conversacion no espera revision'; end if;
    select graph into g from automation_flow_versions where flow_id=s.flow_id and version=s.version;
    select value into n from jsonb_array_elements(g->'nodes') where value->>'id'=s.node_id;
    if n->>'kind' is distinct from 'review' then raise exception 'El bloque actual no solicita revision'; end if;
    if p_action='deny' and length(trim(p_reason)) not between 1 and 1000 then
      raise exception 'Indica el motivo de denegacion';
    end if;
    select value->>'to' into dest from jsonb_array_elements(g->'edges')
      where value->>'from'=s.node_id and value->>'port'=case when p_action='approve' then 'Aprobada' else 'Denegada' end;
    if dest is null then raise exception 'Salida de revision no configurada'; end if;
    update whatsapp_bot_sessions set node_id=dest,status='running',error=null,review_pending=false,
      variables=variables || jsonb_build_object('motivo_denegacion',left(p_reason,1000)),updated_at=now()
      where conversation_id=c.id;
    insert into whatsapp_bot_jobs(tenant_id,account_id,conversation_id)
      values(p_tenant_id,c.whatsapp_account_id,c.id);
  else raise exception 'Accion de bot no valida'; end if;
end;
$$;

create function public.enqueue_whatsapp_bot() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.source='business_app' and new.direction='outbound' then
    insert into whatsapp_bot_sessions(conversation_id,tenant_id,account_id,flow_id,version,node_id,status)
      select new.conversation_id,new.tenant_id,new.whatsapp_account_id,b.flow_id,b.version,'','human'
      from whatsapp_bot_bindings b where b.account_id=new.whatsapp_account_id
      on conflict(conversation_id) do nothing;
    update whatsapp_bot_sessions set status='human',updated_at=now()
      where conversation_id=new.conversation_id;
  elsif new.source='cloud_api' and new.direction='inbound' and new.original_message_id is null
    and exists(select 1 from whatsapp_bot_bindings where account_id=new.whatsapp_account_id and enabled) then
    insert into whatsapp_bot_jobs(tenant_id,account_id,conversation_id,message_id)
      values(new.tenant_id,new.whatsapp_account_id,new.conversation_id,new.id)
      on conflict(message_id) do nothing;
  end if;
  return new;
end;
$$;
create trigger enqueue_whatsapp_bot_message after insert on public.whatsapp_messages
  for each row execute function public.enqueue_whatsapp_bot();

create function public.claim_whatsapp_bot_job() returns jsonb
language plpgsql set search_path=public as $$
declare c uuid; j whatsapp_bot_jobs;
begin
  -- Expired workers are not retried: an external write/send may already have succeeded.
  with expired as (
    update whatsapp_bot_jobs set status='failed',error='Ejecucion interrumpida; revisar antes de reactivar',finished_at=now()
      where status='processing' and started_at<now()-interval '5 minutes'
      returning conversation_id
  )
  update whatsapp_bot_sessions set status='error',error='Ejecucion interrumpida; revisar antes de reactivar',updated_at=now()
    where conversation_id in (select conversation_id from expired) and status<>'human';
  select conv.id into c from whatsapp_conversations conv
    where exists(select 1 from whatsapp_bot_jobs q where q.conversation_id=conv.id and q.status='pending')
      and not exists(select 1 from whatsapp_bot_jobs q where q.conversation_id=conv.id and q.status='processing')
    order by (select min(q.created_at) from whatsapp_bot_jobs q where q.conversation_id=conv.id and q.status='pending')
    for update of conv skip locked limit 1;
  if c is null then return null; end if;
  -- Recheck after acquiring the conversation lock with a fresh statement snapshot.
  if exists(select 1 from whatsapp_bot_jobs where conversation_id=c and status='processing') then
    return null;
  end if;
  select * into j from whatsapp_bot_jobs where conversation_id=c and status='pending'
    order by created_at,id for update limit 1;
  update whatsapp_bot_jobs set status='processing',lease=gen_random_uuid(),started_at=now()
    where id=j.id returning * into j;
  return to_jsonb(j);
end;
$$;

create function public.reserve_whatsapp_bot_effect(p_job_id uuid,p_lease uuid,p_step integer,p_kind text)
returns void language plpgsql set search_path=public as $$
declare j whatsapp_bot_jobs; c uuid;
begin
  select conversation_id into c from whatsapp_bot_jobs where id=p_job_id;
  perform 1 from whatsapp_conversations where id=c for update;
  select * into j from whatsapp_bot_jobs where id=p_job_id and lease=p_lease and status='processing' for update;
  if not found or not exists(select 1 from whatsapp_bot_bindings where account_id=j.account_id and enabled)
    or not exists(select 1 from whatsapp_bot_sessions where conversation_id=c and status in ('running','waiting'))
    then raise exception 'Bot pausado o ejecucion no disponible'; end if;
  insert into whatsapp_bot_effects(job_id,step,kind) values(j.id,p_step,p_kind);
end;
$$;

create function public.save_whatsapp_bot_session(p_job_id uuid,p_lease uuid,p_state jsonb)
returns void language plpgsql set search_path=public as $$
declare j whatsapp_bot_jobs; c uuid;
begin
  select conversation_id into c from whatsapp_bot_jobs where id=p_job_id;
  perform 1 from whatsapp_conversations where id=c for update;
  select * into j from whatsapp_bot_jobs where id=p_job_id and lease=p_lease and status='processing' for update;
  if not found or not exists(select 1 from whatsapp_bot_bindings where account_id=j.account_id and enabled)
    or exists(select 1 from whatsapp_bot_sessions where conversation_id=c and status in ('human','error')) then
    raise exception 'Bot pausado o ejecucion no disponible';
  end if;
  if jsonb_typeof(p_state->'variables') is distinct from 'object'
    or octet_length(p_state::text)>100000 or (p_state->>'steps')::integer not between 0 and 1000
    or p_state->>'status' not in ('running','waiting','human','completed','error') then
    raise exception 'Estado de bot no valido';
  end if;
  if not exists(select 1 from automation_flow_versions where tenant_id=j.tenant_id
    and flow_id=(p_state->>'flow_id')::uuid and version=(p_state->>'version')::integer) then
    raise exception 'Flujo no disponible para esta empresa';
  end if;
  insert into whatsapp_bot_sessions(conversation_id,tenant_id,account_id,flow_id,version,node_id,variables,status,steps,error,review_pending)
    values(c,j.tenant_id,j.account_id,(p_state->>'flow_id')::uuid,(p_state->>'version')::integer,
      p_state->>'node_id',p_state->'variables',p_state->>'status',(p_state->>'steps')::integer,p_state->>'error',
      p_state->>'status'='human' and exists(
        select 1 from automation_flow_versions v,jsonb_array_elements(v.graph->'nodes') n
        where v.flow_id=(p_state->>'flow_id')::uuid and v.version=(p_state->>'version')::integer
          and n->>'id'=p_state->>'node_id' and n->>'kind'='review'))
    on conflict(conversation_id) do update set node_id=excluded.node_id,variables=excluded.variables,
      status=excluded.status,steps=excluded.steps,error=excluded.error,flow_id=excluded.flow_id,
      version=excluded.version,review_pending=excluded.review_pending,updated_at=now();
end;
$$;

create function public.finish_whatsapp_bot_job(p_job_id uuid,p_lease uuid,p_error text default null)
returns void language plpgsql set search_path=public as $$
declare j whatsapp_bot_jobs; c uuid;
begin
  select conversation_id into c from whatsapp_bot_jobs where id=p_job_id;
  perform 1 from whatsapp_conversations where id=c for update;
  select * into j from whatsapp_bot_jobs where id=p_job_id and lease=p_lease and status='processing' for update;
  if not found then return; end if;
  if p_error is not null then
    insert into whatsapp_bot_sessions(conversation_id,tenant_id,account_id,flow_id,version,node_id,status,error)
      select c,j.tenant_id,j.account_id,b.flow_id,b.version,'','error',left(p_error,1000)
      from whatsapp_bot_bindings b where b.account_id=j.account_id
      on conflict(conversation_id) do update set status='error',error=left(p_error,1000),updated_at=now()
        where whatsapp_bot_sessions.status<>'human';
  end if;
  update whatsapp_bot_jobs set status=case when p_error is null then 'done' else 'failed' end,
    error=left(p_error,1000),finished_at=now() where id=j.id;
end;
$$;

revoke all on function public.configure_whatsapp_bot(uuid,uuid,uuid,integer,boolean) from public,anon;
revoke all on function public.control_whatsapp_bot(uuid,uuid,text,text) from public,anon;
grant execute on function public.configure_whatsapp_bot(uuid,uuid,uuid,integer,boolean),
  public.control_whatsapp_bot(uuid,uuid,text,text) to authenticated;
revoke all on function public.enqueue_whatsapp_bot(),
  public.claim_whatsapp_bot_job(),
  public.save_whatsapp_bot_session(uuid,uuid,jsonb),
  public.finish_whatsapp_bot_job(uuid,uuid,text),
  public.reserve_whatsapp_bot_effect(uuid,uuid,integer,text) from public,anon,authenticated;
grant execute on function public.claim_whatsapp_bot_job(),
  public.save_whatsapp_bot_session(uuid,uuid,jsonb),
  public.finish_whatsapp_bot_job(uuid,uuid,text),
  public.reserve_whatsapp_bot_effect(uuid,uuid,integer,text) to service_role;

do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    alter publication supabase_realtime add table public.whatsapp_bot_sessions;
  end if;
end $$;
