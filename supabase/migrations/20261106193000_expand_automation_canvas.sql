create or replace function public.validate_automation_graph(p_graph jsonb, p_publish boolean)
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
    if abs((n->>'x')::numeric) > 1000000000 or abs((n->>'y')::numeric) > 1000000000
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
  with recursive reachable(id) as (
    select value->>'id' from jsonb_array_elements(p_graph->'nodes') where value->>'kind' = 'start'
    union
    select ge->>'to' from reachable join jsonb_array_elements(p_graph->'edges') ge on ge->>'from' = reachable.id
  ) select count(*) into reached from reachable;
  if reached <> node_count then raise exception 'Hay bloques sin conexion desde Inicio'; end if;
end;
$$;
revoke all on function public.validate_automation_graph(jsonb,boolean) from public,anon,authenticated;
