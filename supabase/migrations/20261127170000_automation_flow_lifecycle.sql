create function public.export_automation_flow(p_tenant_id uuid, p_flow_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  if public.current_tenant_role(p_tenant_id) not in ('tenant_admin','supervisor')
    or public.current_tenant_role(p_tenant_id) is null then
    raise exception 'No tienes permiso para exportar flujos de esta empresa';
  end if;
  select jsonb_build_object(
    'format', 'itone-automation-backup', 'schema', 1, 'tenant_id', f.tenant_id,
    'name', f.name, 'draft', f.draft, 'last_version', coalesce(f.published_version, 0),
    'versions', coalesce((select jsonb_agg(jsonb_build_object(
      'version', v.version, 'name', v.name, 'graph', v.graph, 'mode', v.mode
    ) order by v.version) from automation_flow_versions v
      where v.tenant_id=f.tenant_id and v.flow_id=f.id), '[]'::jsonb)
  ) into result from automation_flows f where f.id=p_flow_id and f.tenant_id=p_tenant_id;
  if result is null then raise exception 'Flujo no disponible para esta empresa'; end if;
  if jsonb_array_length(result->'versions') > 1000 or octet_length(result::text) > 20000000 then
    raise exception 'El flujo supera el limite permitido para el respaldo';
  end if;
  return result;
end;
$$;

create function public.restore_automation_flow(p_tenant_id uuid, p_backup jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f automation_flows; v jsonb; last_version integer; version_number integer;
begin
  if public.current_tenant_role(p_tenant_id) is distinct from 'tenant_admin' then
    raise exception 'Solo un administrador activo puede restaurar flujos';
  end if;
  if octet_length(p_backup::text) > 20000000
    or p_backup->>'format' is distinct from 'itone-automation-backup'
    or p_backup->'schema' is distinct from '1'::jsonb
    or p_backup->>'tenant_id' is distinct from p_tenant_id::text
    or jsonb_typeof(p_backup->'name') is distinct from 'string'
    or length(trim(p_backup->>'name')) not between 1 and 100
    or jsonb_typeof(p_backup->'versions') is distinct from 'array'
    or jsonb_typeof(p_backup->'last_version') is distinct from 'number'
    or coalesce(p_backup->>'last_version','') !~ '^(0|[1-9][0-9]{0,8})$' then
    raise exception 'Respaldo invalido o de otra empresa';
  end if;
  if jsonb_array_length(p_backup->'versions') > 1000 then
    raise exception 'El respaldo supera el limite de versiones';
  end if;
  last_version := (p_backup->>'last_version')::integer;
  perform public.validate_automation_graph(p_backup->'draft', false);
  for v in select value from jsonb_array_elements(p_backup->'versions') loop
    if jsonb_typeof(v->'version') is distinct from 'number'
      or coalesce(v->>'version','') !~ '^[1-9][0-9]{0,8}$'
      or jsonb_typeof(v->'name') is distinct from 'string'
      or length(trim(v->>'name')) not between 1 and 100
      or v->>'mode' not in ('published','simulation')
      or v->>'mode' is null then
      raise exception 'Version invalida en el respaldo';
    end if;
    version_number := (v->>'version')::integer;
    if version_number > last_version then
      raise exception 'Numeracion invalida en el respaldo';
    end if;
    perform public.validate_automation_graph(v->'graph', true);
  end loop;
  if (select count(distinct value->>'version') from jsonb_array_elements(p_backup->'versions'))
    <> jsonb_array_length(p_backup->'versions') then
    raise exception 'Versiones duplicadas en el respaldo';
  end if;
  insert into automation_flows(tenant_id,name,draft,published_version)
    values(p_tenant_id,trim(p_backup->>'name'),p_backup->'draft',nullif(last_version,0))
    returning * into f;
  insert into automation_flow_versions(tenant_id,flow_id,version,name,graph,mode,created_by)
    select p_tenant_id,f.id,(value->>'version')::integer,trim(value->>'name'),
      value->'graph',value->>'mode',auth.uid()
    from jsonb_array_elements(p_backup->'versions');
  return to_jsonb(f);
end;
$$;

create function public.delete_automation_version(p_tenant_id uuid, p_flow_id uuid, p_version integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_tenant_role(p_tenant_id) is distinct from 'tenant_admin' then
    raise exception 'Solo un administrador activo puede eliminar versiones';
  end if;
  perform 1 from automation_flows where tenant_id=p_tenant_id and id=p_flow_id for update;
  if not found then raise exception 'Flujo no disponible para esta empresa'; end if;
  if exists(select 1 from whatsapp_bot_bindings where tenant_id=p_tenant_id and flow_id=p_flow_id and version=p_version)
    or exists(select 1 from whatsapp_bot_sessions where tenant_id=p_tenant_id and flow_id=p_flow_id and version=p_version) then
    raise exception 'La version esta vinculada a un numero o a sesiones de WhatsApp y no se puede eliminar';
  end if;
  begin
    delete from automation_flow_versions where tenant_id=p_tenant_id and flow_id=p_flow_id and version=p_version;
  exception when foreign_key_violation then
    raise exception 'La version esta vinculada a un numero o a sesiones de WhatsApp y no se puede eliminar';
  end;
  if not found then raise exception 'Version no disponible para esta empresa'; end if;
end;
$$;

create function public.delete_automation_flow(p_tenant_id uuid, p_flow_id uuid, p_expected_revision integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_tenant_role(p_tenant_id) is distinct from 'tenant_admin' then
    raise exception 'Solo un administrador activo puede eliminar flujos';
  end if;
  perform 1 from automation_flows where tenant_id=p_tenant_id and id=p_flow_id
    and revision=p_expected_revision for update;
  if not found then raise exception 'El borrador cambio o no tienes acceso. Recarga antes de eliminar'; end if;
  if exists(select 1 from whatsapp_bot_bindings where tenant_id=p_tenant_id and flow_id=p_flow_id)
    or exists(select 1 from whatsapp_bot_sessions where tenant_id=p_tenant_id and flow_id=p_flow_id) then
    raise exception 'El flujo esta vinculado a un numero o a sesiones de WhatsApp y no se puede eliminar';
  end if;
  begin
    delete from automation_flows where tenant_id=p_tenant_id and id=p_flow_id;
  exception when foreign_key_violation then
    raise exception 'El flujo esta vinculado a un numero o a sesiones de WhatsApp y no se puede eliminar';
  end;
end;
$$;

revoke all on function public.export_automation_flow(uuid,uuid) from public,anon,authenticated;
revoke all on function public.restore_automation_flow(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.delete_automation_version(uuid,uuid,integer) from public,anon,authenticated;
revoke all on function public.delete_automation_flow(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.export_automation_flow(uuid,uuid),
  public.restore_automation_flow(uuid,jsonb),
  public.delete_automation_version(uuid,uuid,integer),
  public.delete_automation_flow(uuid,uuid,integer) to authenticated;
