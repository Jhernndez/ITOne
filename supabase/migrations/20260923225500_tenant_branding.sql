alter table public.tenants
  add column if not exists logo_url text;

insert into storage.buckets (id, name, public)
values ('tenant-logos', 'tenant-logos', true)
on conflict (id) do nothing;

create policy "tenant admins can upload tenant logo"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'tenant-logos'
  and exists (
    select 1
    from public.tenant_memberships membership
    where membership.tenant_id::text = (storage.foldername(name))[1]
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
);

create policy "tenant admins can update tenant logo"
on storage.objects for update to authenticated
using (
  bucket_id = 'tenant-logos'
  and exists (
    select 1
    from public.tenant_memberships membership
    where membership.tenant_id::text = (storage.foldername(name))[1]
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
)
with check (
  bucket_id = 'tenant-logos'
  and exists (
    select 1
    from public.tenant_memberships membership
    where membership.tenant_id::text = (storage.foldername(name))[1]
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
);

create policy "tenant admins can delete tenant logo"
on storage.objects for delete to authenticated
using (
  bucket_id = 'tenant-logos'
  and exists (
    select 1
    from public.tenant_memberships membership
    where membership.tenant_id::text = (storage.foldername(name))[1]
      and membership.user_id = (select auth.uid())
      and membership.role = 'tenant_admin'
  )
);

create policy "authenticated users can read tenant logos"
on storage.objects for select to authenticated
using (bucket_id = 'tenant-logos');
