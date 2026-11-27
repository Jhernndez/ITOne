create table public.demo_appointment_integrations (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  integration_id uuid not null unique references public.tenant_api_integrations(id) on delete cascade,
  key_hash bytea not null unique
);
create table public.demo_appointment_slots (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  starts_at timestamptz not null,
  patient_code text,
  unique(tenant_id, starts_at)
);
create unique index demo_one_appointment_per_patient on public.demo_appointment_slots(tenant_id, patient_code)
  where patient_code is not null;
create table public.demo_appointment_effects (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  key text not null,
  request jsonb not null,
  response jsonb not null,
  primary key(tenant_id, key)
);
alter table public.demo_appointment_integrations enable row level security;
alter table public.demo_appointment_slots enable row level security;
alter table public.demo_appointment_effects enable row level security;
revoke all on public.demo_appointment_integrations, public.demo_appointment_slots,
  public.demo_appointment_effects from public, anon, authenticated;

create function public.install_demo_appointments(p_tenant uuid, p_base_url text, p_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare integration uuid; lookup_id uuid; reserve_id uuid;
begin
  if p_key !~ '^[a-f0-9]{64}$' or p_base_url !~ '^https://[a-z0-9-]+\.supabase\.co/functions/v1/demo-appointments$' then
    raise exception 'Configuracion de demostracion no valida';
  end if;
  perform 1 from tenants where id=p_tenant for update;
  if not found then raise exception 'Empresa no disponible'; end if;
  select integration_id into integration from demo_appointment_integrations where tenant_id=p_tenant;
  if found then
    select id into lookup_id from tenant_api_resources where tenant_id=p_tenant and integration_id=integration
      and name='DEMO - Buscar paciente y horarios';
    select id into reserve_id from tenant_api_resources where tenant_id=p_tenant and integration_id=integration
      and name='DEMO - Asignar o cambiar cita';
    if lookup_id is null or reserve_id is null then raise exception 'Faltan recursos de la demostracion'; end if;
    return jsonb_build_object('integration_id',integration,'lookup_id',lookup_id,'reserve_id',reserve_id);
  end if;
  insert into tenant_api_integrations(tenant_id,name,base_url,auth_type,auth_config)
    values(p_tenant,'DEMO - Citas ficticias',p_base_url,'api_key',
      jsonb_build_object('header_name','x-demo-key','header_value',p_key))
    returning id into integration;
  insert into demo_appointment_integrations(tenant_id,integration_id,key_hash)
    values(p_tenant,integration,sha256(convert_to(p_key,'UTF8')));
  insert into tenant_api_resources(tenant_id,integration_id,name,path,http_method,enabled,enabled_for_automation,allow_automation_writes)
    values(p_tenant,integration,'DEMO - Buscar paciente y horarios','/buscar','POST',true,true,true)
    returning id into lookup_id;
  insert into tenant_api_resources(tenant_id,integration_id,name,path,http_method,enabled,enabled_for_automation,allow_automation_writes)
    values(p_tenant,integration,'DEMO - Asignar o cambiar cita','/reservar','POST',true,true,true)
    returning id into reserve_id;
  insert into demo_appointment_slots(tenant_id,starts_at)
    select p_tenant,date_trunc('day',now()) + interval '1 day' * d + interval '14 hours'
    from generate_series(1,14) d on conflict(tenant_id,starts_at) do nothing;
  return jsonb_build_object('integration_id',integration,'lookup_id',lookup_id,'reserve_id',reserve_id);
end;
$$;

create function public.run_demo_appointments(p_key text, p_action text, p_body jsonb, p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t uuid; patient text; slot uuid; selected demo_appointment_slots;
  result jsonb; old_request jsonb; old_response jsonb;
begin
  if p_key is null or p_key !~ '^[a-f0-9]{64}$' then raise exception 'Credencial no valida'; end if;
  select tenant_id into t from demo_appointment_integrations
    where key_hash=sha256(convert_to(p_key,'UTF8'));
  if t is null then raise exception 'Credencial no valida'; end if;
  if p_action='salud' then
    return jsonb_build_object('status',200,'body',jsonb_build_object('mensaje','API de citas ficticias disponible'));
  end if;
  if jsonb_typeof(p_body) is distinct from 'object' then raise exception 'Solicitud no valida'; end if;
  patient := p_body->>'cedula';
  if patient not in ('DEMO-001','DEMO-002') or patient is null then
    return jsonb_build_object('status',404,'body',jsonb_build_object('error','Paciente ficticio no encontrado'));
  end if;
  if p_action='buscar' then
    insert into demo_appointment_slots(tenant_id,starts_at)
      select t,date_trunc('day',now()) + interval '1 day' * d + interval '14 hours'
      from generate_series(1,14) d on conflict(tenant_id,starts_at) do nothing;
    return jsonb_build_object('status',200,'body',jsonb_build_object(
      'paciente','Paciente de prueba',
      'horarios',(select coalesce(jsonb_agg(jsonb_build_object(
        'id', id::text, 'nombre', to_char(starts_at at time zone 'America/Bogota','YYYY-MM-DD HH24:MI')
      ) order by starts_at),'[]'::jsonb) from (
        select id,starts_at from demo_appointment_slots where tenant_id=t and patient_code is null
          and starts_at>now() order by starts_at limit 3
      ) available)
    ));
  end if;
  if p_action is distinct from 'reservar' then raise exception 'Operacion no valida'; end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9._:-]{1,200}$' then
    raise exception 'Se requiere una clave de idempotencia';
  end if;
  if coalesce(p_body->>'horario','') !~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' then
    raise exception 'Horario no valido';
  end if;
  slot := (p_body->>'horario')::uuid;
  perform 1 from tenants where id=t for update;
  select request,response into old_request,old_response from demo_appointment_effects
    where tenant_id=t and key=p_idempotency_key;
  if found then
    if old_request is distinct from p_body then raise exception 'Clave de idempotencia ya utilizada'; end if;
    return old_response;
  end if;
  select * into selected from demo_appointment_slots
    where tenant_id=t and id=slot and patient_code is null and starts_at>now() for update;
  if not found then
    result := jsonb_build_object('status',409,'body',jsonb_build_object('error','El horario ya no esta disponible'));
  else
    update demo_appointment_slots set patient_code=null where tenant_id=t and patient_code=patient;
    update demo_appointment_slots set patient_code=patient where id=slot and tenant_id=t;
    result := jsonb_build_object('status',200,'body',jsonb_build_object(
      'mensaje','Cita ficticia asignada. No es una cita real.',
      'horario',to_char(selected.starts_at at time zone 'America/Bogota','YYYY-MM-DD HH24:MI')
    ));
  end if;
  insert into demo_appointment_effects(tenant_id,key,request,response)
    values(t,p_idempotency_key,p_body,result);
  return result;
end;
$$;
revoke all on function public.install_demo_appointments(uuid,text,text) from public,anon,authenticated;
revoke all on function public.run_demo_appointments(text,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.install_demo_appointments(uuid,text,text),
  public.run_demo_appointments(text,text,jsonb,text) to service_role;
