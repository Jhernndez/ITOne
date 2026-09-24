grant select on storage.objects to authenticated;

create policy "users can read own avatar"
on storage.objects for select to authenticated
using (
  bucket_id = 'user-avatars'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);
