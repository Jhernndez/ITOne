create table public.demo_appointment_patients (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  patient_code text not null,
  patient_name text not null,
  primary key (tenant_id, patient_code)
);

alter table public.demo_appointment_patients enable row level security;
revoke all on public.demo_appointment_patients from public, anon, authenticated;

alter table public.demo_appointment_slots
  add column doctor_name text not null default 'Profesional ficticio';
alter table public.demo_appointment_effects
  add column action text not null default 'reservar';

create function public.seed_demo_agenda(p_tenant uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from demo_appointment_integrations where tenant_id = p_tenant) then
    raise exception 'La agenda ficticia no esta instalada';
  end if;
  insert into demo_appointment_patients(tenant_id, patient_code, patient_name)
    values (p_tenant, 'DEMO-001', 'Ana Ejemplo'),
           (p_tenant, 'DEMO-002', 'Luis Ejemplo')
    on conflict do nothing;
  insert into demo_appointment_slots(tenant_id, starts_at, doctor_name)
    select p_tenant, date_trunc('day',now()) + interval '1 day' * d + interval '14 hours',
      case when d % 2 = 0 then 'Dra. Laura Ejemplo' else 'Dr. Mateo Ejemplo' end
    from generate_series(1,14) d on conflict (tenant_id, starts_at) do nothing;
  update demo_appointment_slots
    set doctor_name = case when extract(day from starts_at)::integer % 2 = 0
      then 'Dra. Laura Ejemplo' else 'Dr. Mateo Ejemplo' end
    where tenant_id = p_tenant and doctor_name = 'Profesional ficticio';
end;
$$;
revoke all on function public.seed_demo_agenda(uuid) from public, anon, authenticated;

create function public.list_demo_agenda(p_tenant_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.current_tenant_role(p_tenant_id),'') not in ('tenant_admin','supervisor','operator') then
    raise exception 'Acceso no disponible';
  end if;
  if not exists(select 1 from demo_appointment_integrations where tenant_id = p_tenant_id) then
    return jsonb_build_object('installed', false, 'appointments', '[]'::jsonb);
  end if;
  perform seed_demo_agenda(p_tenant_id);
  return jsonb_build_object(
    'installed', true,
    'appointments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'starts_at', s.starts_at, 'doctor', s.doctor_name,
        'patient', p.patient_name, 'patient_code', s.patient_code,
        'status', case when s.patient_code is null then 'Disponible' else 'Reservada' end
      ) order by s.starts_at)
      from demo_appointment_slots s
      left join demo_appointment_patients p
        on p.tenant_id = s.tenant_id and p.patient_code = s.patient_code
      where s.tenant_id = p_tenant_id and s.starts_at > now()
    ), '[]'::jsonb)
  );
end;
$$;
revoke all on function public.list_demo_agenda(uuid) from public, anon, authenticated;
grant execute on function public.list_demo_agenda(uuid) to authenticated;

alter function public.install_demo_appointments(uuid,text,text) rename to install_demo_appointments_v1;
revoke all on function public.install_demo_appointments_v1(uuid,text,text) from service_role;

create function public.install_demo_appointments(p_tenant uuid, p_base_url text, p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb; integration uuid; cancel_id uuid;
begin
  result := install_demo_appointments_v1(p_tenant, p_base_url, p_key);
  integration := (result->>'integration_id')::uuid;
  perform seed_demo_agenda(p_tenant);
  select id into cancel_id from tenant_api_resources
    where tenant_id = p_tenant and integration_id = integration and name = 'DEMO - Cancelar cita';
  if cancel_id is null then
    insert into tenant_api_resources(tenant_id,integration_id,name,path,http_method,enabled,enabled_for_automation,allow_automation_writes)
      values(p_tenant,integration,'DEMO - Cancelar cita','/cancelar','POST',true,true,true)
      returning id into cancel_id;
  end if;
  return result || jsonb_build_object('cancel_id',cancel_id);
end;
$$;
revoke all on function public.install_demo_appointments(uuid,text,text) from public, anon, authenticated;
grant execute on function public.install_demo_appointments(uuid,text,text) to service_role;

create or replace function public.run_demo_appointments(p_key text, p_action text, p_body jsonb, p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t uuid; patient text; patient_name text; slot uuid; selected demo_appointment_slots;
  result jsonb; old_request jsonb; old_response jsonb; old_action text; current_appointment jsonb;
begin
  if p_key is null or p_key !~ '^[a-f0-9]{64}$' then raise exception 'Credencial no valida'; end if;
  select tenant_id into t from demo_appointment_integrations
    where key_hash=sha256(convert_to(p_key,'UTF8'));
  if t is null then raise exception 'Credencial no valida'; end if;
  if p_action='salud' then
    return jsonb_build_object('status',200,'body',jsonb_build_object('mensaje','API de citas ficticias disponible'));
  end if;
  if jsonb_typeof(p_body) is distinct from 'object' then raise exception 'Solicitud no valida'; end if;
  perform seed_demo_agenda(t);
  patient := p_body->>'cedula';
  select p.patient_name into patient_name from demo_appointment_patients p
    where p.tenant_id = t and p.patient_code = patient;
  if patient_name is null then
    return jsonb_build_object('status',404,'body',jsonb_build_object('error','Paciente ficticio no encontrado'));
  end if;
  if p_action='buscar' then
    select jsonb_build_object('id',s.id,'horario',to_char(s.starts_at at time zone 'America/Bogota','YYYY-MM-DD HH24:MI'),
      'profesional',s.doctor_name) into current_appointment
      from demo_appointment_slots s where s.tenant_id=t and s.patient_code=patient and s.starts_at>now();
    return jsonb_build_object('status',200,'body',jsonb_build_object(
      'paciente',patient_name, 'cita',current_appointment,
      'horarios',(select coalesce(jsonb_agg(jsonb_build_object(
        'id', id::text, 'nombre', to_char(starts_at at time zone 'America/Bogota','YYYY-MM-DD HH24:MI') || ' - ' || doctor_name
      ) order by starts_at),'[]'::jsonb) from (
        select id,starts_at,doctor_name from demo_appointment_slots where tenant_id=t and patient_code is null
          and starts_at>now() order by starts_at limit 3
      ) available)
    ));
  end if;
  if coalesce(p_action,'') not in ('reservar','cancelar') then raise exception 'Operacion no valida'; end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9._:-]{1,200}$' then
    raise exception 'Se requiere una clave de idempotencia';
  end if;
  if p_action='reservar' then
    if coalesce(p_body->>'horario','') !~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' then
      raise exception 'Horario no valido';
    end if;
    slot := (p_body->>'horario')::uuid;
  end if;
  perform 1 from tenants where id=t for update;
  select request,response,action into old_request,old_response,old_action from demo_appointment_effects
    where tenant_id=t and key=p_idempotency_key;
  if found then
    if old_request is distinct from p_body or old_action is distinct from p_action then
      raise exception 'Clave de idempotencia ya utilizada';
    end if;
    return old_response;
  end if;
  if p_action='cancelar' then
    update demo_appointment_slots set patient_code=null
      where tenant_id=t and patient_code=patient and starts_at>now();
    if found then
      result := jsonb_build_object('status',200,'body',jsonb_build_object('mensaje','Cita ficticia cancelada.'));
    else
      result := jsonb_build_object('status',404,'body',jsonb_build_object('error','No hay cita ficticia para cancelar'));
    end if;
  else
    select * into selected from demo_appointment_slots
      where tenant_id=t and id=slot and patient_code is null and starts_at>now() for update;
    if not found then
      result := jsonb_build_object('status',409,'body',jsonb_build_object('error','El horario ya no esta disponible'));
    else
      update demo_appointment_slots set patient_code=null where tenant_id=t and patient_code=patient;
      update demo_appointment_slots set patient_code=patient where id=slot and tenant_id=t;
      result := jsonb_build_object('status',200,'body',jsonb_build_object(
        'mensaje','Cita ficticia asignada. No es una cita real.',
        'horario',to_char(selected.starts_at at time zone 'America/Bogota','YYYY-MM-DD HH24:MI'),
        'profesional', selected.doctor_name
      ));
    end if;
  end if;
  insert into demo_appointment_effects(tenant_id,key,request,response,action)
    values(t,p_idempotency_key,p_body,result,p_action);
  return result;
end;
$$;
