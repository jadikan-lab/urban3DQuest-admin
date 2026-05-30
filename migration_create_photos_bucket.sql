-- Crée (ou répare) le bucket public "photos" et ses policies RLS Storage.
-- À exécuter dans Supabase SQL Editor (PROD), puis STG si nécessaire.

begin;

-- 1) Bucket photos (idempotent)
insert into storage.buckets (id, name, public)
values ('photos', 'photos', true)
on conflict (id) do update
set name = excluded.name,
    public = excluded.public;

-- 2) Policies storage.objects pour le bucket photos
-- Public read
drop policy if exists photos_public_read on storage.objects;
create policy photos_public_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'photos');

-- Admin insert
drop policy if exists photos_admin_insert on storage.objects;
create policy photos_admin_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'photos' and public.is_admin());

-- Admin update
drop policy if exists photos_admin_update on storage.objects;
create policy photos_admin_update on storage.objects
  for update to authenticated
  using (bucket_id = 'photos' and public.is_admin())
  with check (bucket_id = 'photos' and public.is_admin());

-- Admin delete
drop policy if exists photos_admin_delete on storage.objects;
create policy photos_admin_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'photos' and public.is_admin());

commit;
