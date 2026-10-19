-- =====================================================================
-- Radici · M1 · Storage: fotos de tickets (SPEC §6)
--
-- Bucket privado 'receipts'. Ruta: {chef_id}/{session_id}/{archivo}.
-- La app muestra las fotos con URL firmadas de corta duración (createSignedUrl),
-- que respetan estas políticas.
--   * Cocinera: lee y escribe solo dentro de la carpeta de su chef_id.
--   * Cliente: lee los tickets registrados en receipts para sus sesiones.
--   * Anónimo: nada.
-- El esquema storage lo crea el servicio de storage de Supabase; con
-- `supabase db start` (solo la base) ya está disponible, así que esta migración
-- corre también en CI.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'receipts',
  'receipts',
  false,
  10 * 1024 * 1024,   -- 10 MiB por foto
  array['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy "receipts: la cocinera lee su carpeta"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'receipts'
    and (storage.foldername(name))[1] = (select public.current_chef_id())::text
  );

create policy "receipts: la cocinera sube a su carpeta"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'receipts'
    and (storage.foldername(name))[1] = (select public.current_chef_id())::text
  );

create policy "receipts: la cocinera reemplaza en su carpeta"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'receipts'
    and (storage.foldername(name))[1] = (select public.current_chef_id())::text
  )
  with check (
    bucket_id = 'receipts'
    and (storage.foldername(name))[1] = (select public.current_chef_id())::text
  );

create policy "receipts: la cocinera borra en su carpeta"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'receipts'
    and (storage.foldername(name))[1] = (select public.current_chef_id())::text
  );

create policy "receipts: el cliente lee los tickets de sus sesiones"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'receipts'
    and public.client_can_read_receipt(name)
  );
