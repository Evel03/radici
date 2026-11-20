-- =====================================================================
-- Radici · Fotos de los platos (la base)
-- Tests: supabase/tests/database/18_recipe_photos.test.sql.
--
-- Pedido de Evelyn del 20/11/2026: una foto por plato, que se ve en la pestaña «Menù» del formulario
-- de pedido (la web pública) y en la app (lista de platos, editor y el menù elegido en el detalle del
-- pedido). No en la portada. Es el primero de dos PRs: esta base, la Edge Function y la web; después,
-- la app (que elige, achica y sube las fotos).
--
--   1. Bucket público 'recipe-photos' (la web muestra las fotos sin login): JPEG de hasta 2 MiB. La
--      app sube dos archivos por foto, ya achicados y sin metadatos:
--        {chef_id}/{recipe_id}/{photo_id}.jpg        (lado mayor 1200 px)
--        {chef_id}/{recipe_id}/{photo_id}-thumb.jpg  (lado mayor 480 px)
--      Cada foto nueva lleva un uuid nuevo: un archivo nunca se pisa, así la caché puede ser larga.
--      Las URL públicas (/storage/v1/object/public/…) no pasan por las políticas: cualquiera que tenga
--      la URL ve la foto, aunque el plato no esté publicado. Por la API (listar, subir, borrar):
--        * Cocinera (y sus colaboradores, current_chef_id()): lee, sube, reemplaza y borra solo en la
--          carpeta de su cocina; lo que sube tiene que tener la forma de arriba.
--        * Cliente y anónimo: nada.
--   2. recipes.photo_id: la foto del plato (null = sin foto). save_recipe no lo toca: duplicar un
--      plato (guardar con un id nuevo) no copia la foto.
--   3. public.set_recipe_photo(p_recipe_id, p_photo_id): pone, cambia o saca la foto de un plato,
--      después de subir los dos archivos. Devuelve la foto que deja de usarse, para que la app borre
--      sus archivos.
--   4. get_public_menu suma photoId: la Edge Function public-request arma las URL públicas.
--
-- Despliegue: ningún plato tiene foto al desplegar; la web y la app de hoy no leen photoId (la web
-- arma cada plato campo por campo y la app no usa get_public_menu).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Storage: bucket 'recipe-photos'
--
-- Mismo estilo que 'receipts' (20261019100300_storage.sql). El tamaño y el tipo los controla el
-- servicio de Storage al subir; acá quedan escritos.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'recipe-photos',
  'recipe-photos',
  true,                -- la web pública las muestra sin login
  2 * 1024 * 1024,     -- 2 MiB por archivo (la app los sube achicados)
  array['image/jpeg']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Lectura y borrado: cualquier archivo de la carpeta de la cocina (también uno con otra forma, para
-- poder limpiarlo). Subida y reemplazo: solo con la forma {chef_id}/{recipe_id}/{photo_id}[-thumb].jpg,
-- uuids en minúsculas (como los escribe set_recipe_photo), en la carpeta de la cocina.
create policy "recipe-photos: la cocinera lee su carpeta"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'recipe-photos'
    and (storage.foldername(name))[1] = (select public.current_chef_id())::text
  );

create policy "recipe-photos: la cocinera sube a su carpeta"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'recipe-photos'
    and (storage.foldername(name))[1] = (select public.current_chef_id())::text
    and name ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}(-thumb)?\.jpg$'
  );

create policy "recipe-photos: la cocinera reemplaza en su carpeta"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'recipe-photos'
    and (storage.foldername(name))[1] = (select public.current_chef_id())::text
  )
  with check (
    bucket_id = 'recipe-photos'
    and (storage.foldername(name))[1] = (select public.current_chef_id())::text
    and name ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}(-thumb)?\.jpg$'
  );

create policy "recipe-photos: la cocinera borra en su carpeta"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'recipe-photos'
    and (storage.foldername(name))[1] = (select public.current_chef_id())::text
  );

-- ---------------------------------------------------------------------
-- 2. recipes.photo_id
-- ---------------------------------------------------------------------
alter table public.recipes
  add column photo_id uuid;

comment on column public.recipes.photo_id is
  'La foto del plato: los archivos {chef_id}/{id}/{photo_id}.jpg y {photo_id}-thumb.jpg del bucket público recipe-photos. null = sin foto. La escribe set_recipe_photo; save_recipe no la toca (duplicar un plato no copia la foto).';

-- ---------------------------------------------------------------------
-- 3. public.set_recipe_photo(p_recipe_id uuid, p_photo_id uuid)
--
-- La app sube los dos archivos (con un photo_id nuevo) y después llama a esta función, que los exige
-- (en la carpeta de este plato) antes de guardar: el plato nunca apunta a una foto a medio subir. Con
-- p_photo_id null saca la foto. Devuelve la foto que deja de usarse (la anterior; null si no había o si
-- es la misma), para que la app borre sus archivos. Security invoker: corre con la RLS de quien llama
-- (recipes y storage.objects). Errores:
--   42501 not_a_chef         quien llama no es la cocinera ni un colaborador suyo.
--   P0002 recipe_not_found   el plato no existe o es de otra cocina (el mismo de save_recipe).
--   22023 photo_not_found    falta alguno de los dos archivos (DETAIL: las rutas que faltan).
-- ---------------------------------------------------------------------
create function public.set_recipe_photo(p_recipe_id uuid, p_photo_id uuid)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_chef_id  uuid := public.current_chef_id();
  v_previous uuid;
  v_base     text;
  v_missing  text;
begin
  if v_chef_id is null then
    raise exception 'not_a_chef' using errcode = '42501';
  end if;

  -- El plato, con el lock de la fila: dos cambios de foto del mismo plato van uno después del otro.
  select r.photo_id into v_previous
  from public.recipes r
  where r.id = p_recipe_id and r.chef_id = v_chef_id
  for update;
  if not found then
    raise exception 'recipe_not_found' using errcode = 'P0002';
  end if;

  if p_photo_id is not null then
    v_base := format('%s/%s/%s', v_chef_id, p_recipe_id, p_photo_id);
    select string_agg(f.name, ', ' order by f.n) into v_missing
    from unnest(array[v_base || '.jpg', v_base || '-thumb.jpg']) with ordinality as f(name, n)
    where not exists (select 1 from storage.objects o
                      where o.bucket_id = 'recipe-photos' and o.name = f.name);
    if v_missing is not null then
      raise exception 'photo_not_found' using errcode = '22023', detail = v_missing;
    end if;
  end if;

  update public.recipes r
  set photo_id = p_photo_id
  where r.id = p_recipe_id;

  return nullif(v_previous, p_photo_id);
end
$$;

comment on function public.set_recipe_photo(uuid, uuid) is
  'Pone, cambia o (con p_photo_id null) saca la foto de un plato. Exige los dos archivos {chef_id}/{recipe_id}/{photo_id}.jpg y {photo_id}-thumb.jpg en el bucket recipe-photos. Devuelve la foto que deja de usarse (null si no había o si es la misma), para que la app borre sus archivos. Security invoker: corre con la RLS de quien llama. Errores: 42501 not_a_chef; P0002 recipe_not_found (no existe o es de otra cocina); 22023 photo_not_found (DETAIL: las rutas que faltan).';

-- Como save_recipe: la app (authenticated); anon y service_role no la ejecutan.
revoke all on function public.set_recipe_photo(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.set_recipe_photo(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. get_public_menu con photoId
--
-- Lo mismo que en 20261119150000_menu_web.sql, más photoId (uuid o null): la Edge Function arma con
-- él, el id de la cocinera y el del plato las URL públicas de los dos archivos.
-- ---------------------------------------------------------------------
create or replace function public.get_public_menu(p_chef_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', r.id,
             'name', jsonb_build_object('it', r.name_it, 'es', r.name_es, 'en', r.name_en),
             'description', jsonb_build_object('it', r.description_it, 'es', r.description_es,
                                               'en', r.description_en),
             'allergens', (select coalesce(jsonb_agg(a.allergen order by a.allergen), '[]'::jsonb)
                           from public.recipe_allergens a
                           where a.recipe_id = r.id),
             'diet', r.diet,
             'seasonMonths', (select jsonb_agg(m order by m) from unnest(r.season_months) as m),
             'photoId', r.photo_id)
           order by lower(r.name_it), r.id),
         '[]'::jsonb)
  from public.recipes r
  where r.chef_id = p_chef_id
    and r.active
    and r.catalog_visible
    and r.description_it is not null
$$;

comment on function public.get_public_menu(uuid) is
  'Los platos publicados de una cocinera (activos, visibles en el catálogo y con descripción en italiano) para la pestaña «Menù» de la web: [{id, name: {it, es, en}, description: {it, es, en}, allergens, diet, seasonMonths, photoId}], por nombre sin mayúsculas y después por id; [] si no hay. photoId null = sin foto. Nunca ingredientes ni notas. Solo service role (Edge Function public-request).';

-- create or replace conserva los privilegios; se repiten para que quede a la vista.
revoke all on function public.get_public_menu(uuid) from public, anon, authenticated;
grant execute on function public.get_public_menu(uuid) to service_role;
