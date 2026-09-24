alter table public.tenants
  add column if not exists sector text not null default 'general'
  check (sector in (
    'general',
    'it_services',
    'msp',
    'ips',
    'therapy_center',
    'consulting',
    'professional_services',
    'logistics',
    'construction',
    'education',
    'retail',
    'manufacturing',
    'real_estate',
    'nonprofit'
  ));
