create table public.automation_flows (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 100),
  draft jsonb not null,
  revision integer not null default 1,
  published_version integer,
  updated_at timestamptz not null default now(),
  unique(tenant_id, id)
);

create table public.automation_flow_versions (
  tenant_id uuid not null,
  flow_id uuid not null,
  version integer not null,
  name text not null,
  graph jsonb not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  mode text not null default 'simulation' check (mode = 'simulation'),
  primary key(flow_id, version),
  foreign key(tenant_id, flow_id) references public.automation_flows(tenant_id, id) on delete cascade
);
alter table public.automation_flows enable row level security;
alter table public.automation_flow_versions enable row level security;
revoke all on public.automation_flows, public.automation_flow_versions from public, anon, authenticated;
grant select on public.automation_flows, public.automation_flow_versions to authenticated;

create policy "active managers read flows" on public.automation_flows
for select to authenticated using (public.current_tenant_role(tenant_id) in ('tenant_admin','supervisor'));
create policy "active managers read versions" on public.automation_flow_versions
for select to authenticated using (public.current_tenant_role(tenant_id) in ('tenant_admin','supervisor'));

create function public.validate_automation_graph(p_graph jsonb, p_publish boolean)
returns void language plpgsql set search_path = public as $$
declare
  n jsonb; e jsonb; port text; ports text[]; opts text[];
  config jsonb; kind text; node_count integer; reached integer;
begin
  if jsonb_typeof(p_graph) is distinct from 'object'
    or p_graph->'schema' is distinct from '1'::jsonb
    or jsonb_typeof(p_graph->'nodes') is distinct from 'array'
    or jsonb_typeof(p_graph->'edges') is distinct from 'array' then
    raise exception 'Formato de flujo no valido';
  end if;
  node_count := jsonb_array_length(p_graph->'nodes');
  if node_count not between 1 and 60 or jsonb_array_length(p_graph->'edges') > 180
    or octet_length(p_graph::text) > 200000 then
    raise exception 'El flujo supera los limites de bloques, conexiones o tamano';
  end if;
  if (select count(distinct value->>'id') from jsonb_array_elements(p_graph->'nodes')) <> node_count then
    raise exception 'Identificadores de bloque duplicados';
  end if;
  for n in select value from jsonb_array_elements(p_graph->'nodes') loop
    kind := n->>'kind'; config := n->'config';
    if jsonb_typeof(n->'id') is distinct from 'string' or length(n->>'id') not between 1 and 100
      or kind is null or kind not in ('start','text','question','options','condition','api','review','handoff','end')
      or jsonb_typeof(config) is distinct from 'object'
      or jsonb_typeof(n->'x') is distinct from 'number'
      or jsonb_typeof(n->'y') is distinct from 'number' then
      raise exception 'Bloque no valido';
    end if;
    if (n->>'x')::numeric not between 0 and 2600 or (n->>'y')::numeric not between 0 and 1600
      or exists(select 1 from jsonb_each(config) where jsonb_typeof(value) <> 'string' or length(value #>> '{}') > 1000) then
      raise exception 'Configuracion o posicion no valida';
    end if;
    if not p_publish then continue; end if;
    if kind in ('text','question','options') and coalesce(trim(config->>'text'),'') = '' then
      raise exception 'Falta el mensaje en un bloque';
    end if;
    if kind in ('question','options','condition') and
      coalesce(config->>'variable','') !~ '^[a-zA-Z][a-zA-Z0-9_]{0,39}$' then
      raise exception 'Variable no valida';
    end if;
    if kind = 'condition' and coalesce(trim(config->>'equals'),'') = '' then
      raise exception 'Falta el valor de comparacion';
    end if;
    ports := case kind
      when 'end' then '{}'::text[] when 'handoff' then '{}'::text[]
      when 'condition' then array['Sí','No']
      when 'api' then array['Éxito','Error']
      when 'review' then array['Aprobada','Denegada']
      else array['Siguiente'] end;
    if kind = 'options' then
      select array_agg(trim(v)) into opts from unnest(string_to_array(config->>'options','|')) v where trim(v) <> '';
      if coalesce(cardinality(opts),0) not between 2 and 6
        or (select count(distinct v) from unnest(opts) v) <> cardinality(opts) then
        raise exception 'Usa entre 2 y 6 opciones unicas';
      end if;
      ports := opts;
    end if;
    foreach port in array ports loop
      if (select count(*) from jsonb_array_elements(p_graph->'edges') edge
        where edge->>'from' = n->>'id' and edge->>'port' = port) <> 1 then
        raise exception 'Hay salidas sin conectar o duplicadas';
      end if;
    end loop;
    if exists(select 1 from jsonb_array_elements(p_graph->'edges') edge
      where edge->>'from' = n->>'id' and not (edge->>'port' = any(ports))) then
      raise exception 'Salida de bloque no valida';
    end if;
  end loop;
  for e in select value from jsonb_array_elements(p_graph->'edges') loop
    if jsonb_typeof(e->'from') is distinct from 'string' or jsonb_typeof(e->'to') is distinct from 'string'
      or jsonb_typeof(e->'port') is distinct from 'string'
      or not exists(select 1 from jsonb_array_elements(p_graph->'nodes') gn where gn->>'id' = e->>'from')
      or not exists(select 1 from jsonb_array_elements(p_graph->'nodes') gn where gn->>'id' = e->>'to') then
      raise exception 'Conexion a bloque inexistente';
    end if;
  end loop;
  if not p_publish then return; end if;
  if (select count(*) from jsonb_array_elements(p_graph->'nodes') where value->>'kind' = 'start') <> 1 then
    raise exception 'Debe existir exactamente un Inicio';
  end if;
  if exists(select 1 from jsonb_array_elements(p_graph->'edges') ge
    join jsonb_array_elements(p_graph->'nodes') gn on gn->>'id' = ge->>'to' where gn->>'kind' = 'start') then
    raise exception 'No se puede conectar hacia Inicio';
  end if;
  if exists(
    with recursive paths(a,b) as (
      select value->>'from',value->>'to' from jsonb_array_elements(p_graph->'edges')
      union
      select paths.a,ge->>'to' from paths join jsonb_array_elements(p_graph->'edges') ge on ge->>'from' = paths.b
    ) select 1 from paths where a = b
  ) then raise exception 'El flujo contiene ciclos'; end if;
  with recursive reachable(id) as (
    select value->>'id' from jsonb_array_elements(p_graph->'nodes') where value->>'kind' = 'start'
    union
    select ge->>'to' from reachable join jsonb_array_elements(p_graph->'edges') ge on ge->>'from' = reachable.id
  ) select count(*) into reached from reachable;
  if reached <> node_count then raise exception 'Hay bloques sin conexion desde Inicio'; end if;
end;
$$;

create function public.save_automation_flow(
  p_tenant_id uuid, p_flow_id uuid, p_name text, p_graph jsonb, p_expected_revision integer
) returns jsonb language plpgsql security definer set search_path = public as $$
declare f public.automation_flows;
begin
  perform 1 from public.tenants where id = p_tenant_id for update;
  if public.current_tenant_role(p_tenant_id) is distinct from 'tenant_admin' then
    raise exception 'Solo un administrador activo puede guardar flujos';
  end if;
  if p_name is null or length(trim(p_name)) not between 1 and 100 then raise exception 'Nombre no valido'; end if;
  perform public.validate_automation_graph(p_graph, false);
  if p_flow_id is null then
    if p_expected_revision is not null then raise exception 'Revision inicial no valida'; end if;
    insert into public.automation_flows(tenant_id,name,draft)
      values(p_tenant_id,trim(p_name),p_graph) returning * into f;
  else
    update public.automation_flows set name=trim(p_name), draft=p_graph, revision=revision+1, updated_at=now()
      where id=p_flow_id and tenant_id=p_tenant_id and revision=p_expected_revision returning * into f;
    if not found then raise exception 'El borrador cambio o no tienes acceso. Recarga antes de guardar'; end if;
  end if;
  return to_jsonb(f);
end;
$$;

create function public.publish_automation_flow(p_tenant_id uuid, p_flow_id uuid, p_expected_revision integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f public.automation_flows; next_version integer;
begin
  perform 1 from public.tenants where id=p_tenant_id for update;
  if public.current_tenant_role(p_tenant_id) is distinct from 'tenant_admin' then
    raise exception 'Solo un administrador activo puede publicar para simulacion';
  end if;
  select * into f from public.automation_flows where id=p_flow_id and tenant_id=p_tenant_id for update;
  if not found or f.revision is distinct from p_expected_revision then
    raise exception 'El borrador cambio o no tienes acceso. Recarga antes de publicar';
  end if;
  perform public.validate_automation_graph(f.draft, true);
  next_version := coalesce(f.published_version,0)+1;
  insert into public.automation_flow_versions(tenant_id,flow_id,version,name,graph,created_by)
    values(p_tenant_id,f.id,next_version,f.name,f.draft,auth.uid());
  update public.automation_flows set published_version=next_version,revision=revision+1,updated_at=now()
    where id=f.id returning * into f;
  return to_jsonb(f);
end;
$$;
revoke all on function public.validate_automation_graph(jsonb,boolean) from public,anon,authenticated;
revoke all on function public.save_automation_flow(uuid,uuid,text,jsonb,integer) from public,anon,authenticated;
revoke all on function public.publish_automation_flow(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.save_automation_flow(uuid,uuid,text,jsonb,integer) to authenticated;
grant execute on function public.publish_automation_flow(uuid,uuid,integer) to authenticated;
