create table public.whatsapp_review_attempts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index on public.whatsapp_review_attempts(tenant_id, created_at);
alter table public.whatsapp_review_attempts enable row level security;
revoke all on public.whatsapp_review_attempts from public, anon, authenticated;

create function public.reserve_whatsapp_review_send(p_tenant_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform 1 from public.tenants where id = p_tenant_id for update;
  if not found then raise exception 'Empresa no encontrada'; end if;
  if exists(select 1 from public.whatsapp_review_attempts
      where tenant_id = p_tenant_id and created_at > now() - interval '1 minute') then
    raise exception 'Espera un minuto antes de enviar otra prueba';
  end if;
  if (select count(*) from public.whatsapp_review_attempts
      where tenant_id = p_tenant_id and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'Limite de 20 intentos de prueba en 24 horas';
  end if;
  insert into public.whatsapp_review_attempts(tenant_id) values(p_tenant_id);
end;
$$;
revoke all on function public.reserve_whatsapp_review_send(uuid) from public, anon, authenticated;
grant execute on function public.reserve_whatsapp_review_send(uuid) to service_role;
