alter table public.tenants
  add column if not exists language text not null default 'es'
    check (language in ('es', 'en')),
  add column if not exists timezone text not null default 'America/Bogota';

grant update on table public.tenants to authenticated;
