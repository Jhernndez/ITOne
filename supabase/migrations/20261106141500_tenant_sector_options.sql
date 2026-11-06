alter table public.tenants
  drop constraint tenants_sector_check;

alter table public.tenants
  alter column sector set default 'general';

alter table public.tenants
  add constraint tenants_sector_check
  check (sector in (
    'general',
    'it_services',
    'ips',
    'logistics',
    'furniture_services'
  ));
