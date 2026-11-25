-- =====================================================================
-- Fotos de los platos, la base (migración 20261120100000_recipe_photos.sql):
--   * Bucket público recipe-photos (JPEG, 2 MiB) y sus políticas: la cocinera y sus colaboradores
--     leen, suben y borran solo en la carpeta de su cocina, y suben solo con la forma
--     {chef_id}/{recipe_id}/{photo_id}[-thumb].jpg; nadie reemplaza ni renombra (sin política de
--     UPDATE); el cliente y anon, nada por la API.
--   * recipes.photo_id (null = sin foto), que save_recipe no toca, y el trigger recipes_check_photo, que
--     exige los dos archivos también en un update o insert directo.
--   * public.set_recipe_photo(p_recipe_id, p_photo_id): guarda la foto (con el trigger) y devuelve la
--     que deja de usarse.
--   * get_public_menu: photoId en cada plato.
--
-- C1 tiene un colaborador (M) y una clienta con cuenta (A); C2 es otra cocina. Las rutas y los ids se
-- leen con claves cortas (C1/R1/P1.jpg): pg_temp.photo las arma y pg_temp.short las devuelve.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

-- Desde la migración client_rls_lockdown lo nuevo nace sin EXECUTE para nadie: las ayudas de pg_temp
-- de este test las llaman authenticated y service_role, así que en pg_temp nacen ejecutables
-- (solo dentro de esta transacción: el default privilege y el esquema temporal se van con el rollback).
create temp table zz_esquema_temp (i int) on commit drop;
do $$
begin
  execute format('alter default privileges in schema %I grant execute on functions to public',
    (select nspname from pg_namespace where oid = pg_my_temp_schema()));
end
$$;

select plan(50);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
-- ---------------------------------------------------------------------
create temp table keys (key text primary key, id uuid not null unique);
insert into keys (key, id) values
  ('C1', '7e661000-0000-4000-8000-000000000001'),
  ('C2', '7e661000-0000-4000-8000-000000000002'),
  ('R1', '7e666000-0000-4000-8000-000000000001'),  -- C1, publicado
  ('R2', '7e666000-0000-4000-8000-000000000002'),  -- C1, publicado
  ('R3', '7e666000-0000-4000-8000-000000000003'),  -- C1, desactivado
  ('R5', '7e666000-0000-4000-8000-000000000005'),  -- C1, la copia de R1 (save_recipe)
  ('R7', '7e666000-0000-4000-8000-000000000007'),  -- no existe
  ('R9', '7e666000-0000-4000-8000-0000000000f9'),  -- C2, publicado
  ('P1', '7e667000-0000-4000-8000-000000000001'),
  ('P2', '7e667000-0000-4000-8000-000000000002'),
  ('P3', '7e667000-0000-4000-8000-000000000003'),
  ('P4', '7e667000-0000-4000-8000-000000000004'),
  ('P7', '7e667000-0000-4000-8000-000000000007'),
  ('P9', '7e667000-0000-4000-8000-0000000000f9');
grant select on keys to anon, authenticated, service_role;

create function pg_temp.id(p_key text) returns uuid
language sql stable
as $$ select k.id from keys k where k.key = p_key $$;

-- La ruta de un archivo: pg_temp.photo('C1', 'R1', 'P1') = '{C1}/{R1}/{P1}.jpg'; con p_thumb, -thumb.jpg.
create function pg_temp.photo(p_chef text, p_recipe text, p_photo text, p_thumb boolean default false) returns text
language sql stable
as $$
  select format('%s/%s/%s%s.jpg', pg_temp.id(p_chef), pg_temp.id(p_recipe), pg_temp.id(p_photo),
                case when p_thumb then '-thumb' else '' end)
$$;

-- Un texto con los ids cambiados por sus claves.
create function pg_temp.short(p_text text) returns text
language plpgsql stable
as $$
declare
  v_text text := p_text;
  v_key  record;
begin
  for v_key in select k.key, k.id from keys k loop
    v_text := replace(v_text, v_key.id::text, v_key.key);
  end loop;
  return v_text;
end
$$;

-- Los archivos del bucket que ve el usuario de la sesión, con claves cortas.
create function pg_temp.visible() returns text[]
language sql stable
as $$
  select coalesce(array_agg(s.name order by s.name collate "C"), '{}')
  from (select pg_temp.short(o.name) as name from storage.objects o where o.bucket_id = 'recipe-photos') as s
$$;

-- El error de una sentencia como "SQLSTATE: mensaje (DETAIL)", con claves cortas, o null si no falla.
create function pg_temp.error_of(p_sql text) returns text
language plpgsql
as $$
declare
  v_detail text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return pg_temp.short(sqlstate || ': ' || sqlerrm || coalesce(' (' || nullif(v_detail, '') || ')', ''));
end
$$;

-- Las filas que tocó una sentencia (un update o un delete que la RLS filtra no falla: toca 0).
create function pg_temp.affected(p_sql text) returns int
language plpgsql
as $$
declare
  v_count int;
begin
  execute p_sql;
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- Subir un archivo (como lo hace el servicio de Storage, con la RLS de quien sube).
create function pg_temp.upload(p_name text) returns void
language sql
as $$ insert into storage.objects (bucket_id, name) values ('recipe-photos', p_name) $$;

-- La foto de un plato, con claves cortas.
create function pg_temp.photo_of(p_recipe text) returns text
language sql stable
as $$ select pg_temp.short(r.photo_id::text) from public.recipes r where r.id = pg_temp.id(p_recipe) $$;

-- Un plato válido para save_recipe; p_extra pisa o agrega claves.
create function pg_temp.dish(p_id text, p_extra jsonb default '{}') returns jsonb
language sql stable
as $$
  select jsonb_build_object('id', pg_temp.id(p_id), 'name_it', 'Lasagne alla bolognese',
                            'allergens', jsonb_build_array('gluten'), 'ingredients', jsonb_build_array()) || p_extra
$$;

insert into auth.users (id, email) values
  ('7e660000-0000-4000-8000-00000000c001', 'chef1@foto.test'),
  ('7e660000-0000-4000-8000-00000000c002', 'chef2@foto.test'),
  ('7e660000-0000-4000-8000-00000000d001', 'socio@foto.test'),
  ('7e660000-0000-4000-8000-00000000a001', 'a@foto.test');
update public.profiles set role = 'chef'
where id in ('7e660000-0000-4000-8000-00000000c001', '7e660000-0000-4000-8000-00000000c002',
             '7e660000-0000-4000-8000-00000000d001');

insert into public.chefs (id, profile_id, display_name) values
  (pg_temp.id('C1'), '7e660000-0000-4000-8000-00000000c001', 'Chef Uno'),
  (pg_temp.id('C2'), '7e660000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values (pg_temp.id('C1')), (pg_temp.id('C2'));
insert into public.chef_members (chef_id, profile_id) values
  (pg_temp.id('C1'), '7e660000-0000-4000-8000-00000000d001');
insert into public.clients (chef_id, profile_id, display_name, status) values
  (pg_temp.id('C1'), '7e660000-0000-4000-8000-00000000a001', 'Cliente A', 'active');

insert into public.recipes (id, chef_id, name_it, description_it, active) values
  (pg_temp.id('R1'), pg_temp.id('C1'), 'Lasagne alla bolognese', 'Ragù e besciamella.', true),
  (pg_temp.id('R2'), pg_temp.id('C1'), 'Minestrone', 'Verdure di stagione.', true),
  (pg_temp.id('R3'), pg_temp.id('C1'), 'Brasato', 'Manzo al vino.', false),
  (pg_temp.id('R9'), pg_temp.id('C2'), 'Ossobuco', 'Con gremolata.', true);

-- P1: la foto completa de R1 (los dos archivos). P2: solo el archivo grande (la miniatura no llegó a
-- subirse). P9: la de R9, de C2. Un archivo suelto de C1 con otra forma y un ticket de C1 (otro bucket).
insert into storage.objects (bucket_id, name) values
  ('recipe-photos', pg_temp.photo('C1', 'R1', 'P1')),
  ('recipe-photos', pg_temp.photo('C1', 'R1', 'P1', true)),
  ('recipe-photos', pg_temp.photo('C1', 'R1', 'P2')),
  ('recipe-photos', pg_temp.id('C1') || '/viejo.png'),
  ('recipe-photos', pg_temp.photo('C2', 'R9', 'P9')),
  ('recipe-photos', pg_temp.photo('C2', 'R9', 'P9', true)),
  ('receipts', pg_temp.id('C1') || '/sesion/ticket.jpg');

-- =====================================================================
-- 1. Bucket, políticas y columna
-- =====================================================================
select is(
  (select format('%s %s %s', b.public::text, b.file_size_limit, b.allowed_mime_types) from storage.buckets b
   where b.id = 'recipe-photos'),
  'true 2097152 {image/jpeg}',
  'el bucket recipe-photos es público (la web muestra las fotos sin login), de 2 MiB por archivo y solo JPEG'
);
select is(
  (select array_agg(format('%s | %s | %s', p.policyname, p.cmd, p.roles::text) order by p.policyname)
   from pg_policies p
   where p.schemaname = 'storage' and p.tablename = 'objects'
     and concat_ws(' ', p.qual, p.with_check) like '%recipe-photos%'),
  array['recipe-photos: la cocinera borra en su carpeta | DELETE | {authenticated}',
        'recipe-photos: la cocinera lee su carpeta | SELECT | {authenticated}',
        'recipe-photos: la cocinera sube a su carpeta | INSERT | {authenticated}'],
  'storage.objects: tres políticas del bucket, solo de la cocinera (authenticated): sin UPDATE (no reemplaza ni '
  'renombra) y ninguna para el cliente ni anon'
);
select is(
  (select format('%s %s', c.data_type, c.is_nullable) from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'recipes' and c.column_name = 'photo_id'),
  'uuid YES',
  'recipes.photo_id: uuid, null = sin foto'
);

-- =====================================================================
-- 2. Storage con cada usuario
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000c001","role":"authenticated"}';

select is(
  pg_temp.visible(),
  array['C1/R1/P1-thumb.jpg', 'C1/R1/P1.jpg', 'C1/R1/P2.jpg', 'C1/viejo.png'],
  'C1 ve los archivos de su carpeta (también el suelto), y no los de C2 ni los tickets'
);
select lives_ok(
  $$ select pg_temp.upload(pg_temp.photo('C1', 'R2', 'P4')), pg_temp.upload(pg_temp.photo('C1', 'R2', 'P4', true)) $$,
  'C1 sube los dos archivos de una foto a su carpeta'
);
select throws_ok(
  $$ select pg_temp.upload(pg_temp.photo('C2', 'R9', 'P4')) $$,
  '42501', null,
  'C1 no sube a la carpeta de C2'
);
select is(
  (select array_agg(left(pg_temp.error_of(format('select pg_temp.upload(%L)', n)), 6) order by n)
   from unnest(array[
     pg_temp.id('C1') || '/' || pg_temp.id('R2') || '/foto.jpg',
     pg_temp.id('C1') || '/' || pg_temp.id('P4') || '.jpg',
     replace(pg_temp.photo('C1', 'R2', 'P4'), '.jpg', '.png'),
     replace(pg_temp.photo('C1', 'R2', 'P4'), '.jpg', '.JPG'),
     replace(pg_temp.photo('C1', 'R2', 'P4'), '.jpg', '-big.jpg'),
     pg_temp.photo('C1', 'R2', 'P4') || '/otra.jpg',
     upper(pg_temp.photo('C1', 'R2', 'P4'))]) as n),
  array['42501:', '42501:', '42501:', '42501:', '42501:', '42501:', '42501:'],
  'ni en su carpeta sube un archivo con otra forma: un nombre que no es un uuid, sin la carpeta del plato, '
  'otra extensión (o en mayúsculas), otro sufijo, una carpeta de más o los uuids en mayúsculas'
);
-- Sin política de UPDATE un update no falla: la RLS no le deja ninguna fila.
select is(
  array[
    pg_temp.affected($$ update storage.objects set metadata = '{"cacheControl": "max-age=604800"}'
                        where bucket_id = 'recipe-photos' and name = pg_temp.photo('C1', 'R2', 'P4') $$),
    pg_temp.affected($$ update storage.objects set name = pg_temp.id('C1') || '/viejo2.png'
                        where bucket_id = 'recipe-photos' and name = pg_temp.photo('C1', 'R2', 'P4') $$),
    pg_temp.affected($$ update storage.objects set name = pg_temp.photo('C2', 'R9', 'P4')
                        where bucket_id = 'recipe-photos' and name = pg_temp.photo('C1', 'R2', 'P4', true) $$)],
  array[0, 0, 0],
  'C1 no actualiza un archivo suyo, no lo renombra dentro de su carpeta ni lo mueve a la de C2 (0 filas)'
);
reset role;
select is(
  (select string_agg(format('%s · %s', pg_temp.short(o.name), coalesce(o.metadata::text, 'sin metadata')), '; '
                     order by o.name collate "C")
   from storage.objects o where o.bucket_id = 'recipe-photos' and o.name like pg_temp.id('C1') || '/' || pg_temp.id('R2') || '/%'),
  'C1/R2/P4-thumb.jpg · sin metadata; C1/R2/P4.jpg · sin metadata',
  'y los dos archivos de P4 siguen con su nombre y sin cambios'
);
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000c001","role":"authenticated"}';
-- El servicio de Storage habilita el borrado con storage.allow_delete_query (storage.protect_delete).
set local storage.allow_delete_query = 'true';
select is(
  array[pg_temp.affected($$ delete from storage.objects where bucket_id = 'recipe-photos' and name = pg_temp.photo('C2', 'R9', 'P9') $$),
        pg_temp.affected($$ delete from storage.objects where bucket_id = 'recipe-photos' and name = pg_temp.id('C1') || '/viejo.png' $$)],
  array[0, 1],
  'C1 borra en su carpeta (también un archivo con otra forma) y no en la de C2'
);
set local storage.allow_delete_query = 'false';

-- El colaborador M: lo mismo que la cocinera.
set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000d001","role":"authenticated"}';
select is(
  pg_temp.visible(),
  array['C1/R1/P1-thumb.jpg', 'C1/R1/P1.jpg', 'C1/R1/P2.jpg', 'C1/R2/P4-thumb.jpg', 'C1/R2/P4.jpg'],
  'M ve la carpeta de la cocina, y no la de C2'
);
select lives_ok(
  $$ select pg_temp.upload(pg_temp.photo('C1', 'R1', 'P3')), pg_temp.upload(pg_temp.photo('C1', 'R1', 'P3', true)) $$,
  'M sube una foto a la carpeta de la cocina'
);
select throws_ok(
  $$ select pg_temp.upload(pg_temp.photo('C2', 'R9', 'P3')) $$,
  '42501', null,
  'M no sube a la carpeta de otra cocina'
);
set local storage.allow_delete_query = 'true';
select is(
  array[pg_temp.affected($$ delete from storage.objects where bucket_id = 'recipe-photos' and name = pg_temp.photo('C2', 'R9', 'P9', true) $$),
        pg_temp.affected($$ delete from storage.objects where bucket_id = 'recipe-photos' and name = pg_temp.photo('C1', 'R2', 'P4', true) $$)],
  array[0, 1],
  'M borra en la carpeta de la cocina (la miniatura de P4) y no en la de otra'
);
set local storage.allow_delete_query = 'false';

-- La clienta A: nada por la API (ve las fotos por su URL pública, como cualquiera).
set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000a001","role":"authenticated"}';
select is(pg_temp.visible(), '{}'::text[], 'A no lista ningún archivo del bucket');
select throws_ok(
  $$ select pg_temp.upload(pg_temp.photo('C1', 'R1', 'P7')) $$,
  '42501', null,
  'A no sube a la carpeta de su cocinera'
);
reset role;

set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select is(pg_temp.visible(), '{}'::text[], 'anon no lista ningún archivo del bucket (las URL públicas no pasan por la API)');
select throws_ok(
  $$ select pg_temp.upload(pg_temp.photo('C1', 'R1', 'P7')) $$,
  '42501', null,
  'anon no sube nada'
);
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000c002","role":"authenticated"}';
select is(
  pg_temp.visible(),
  array['C2/R9/P9-thumb.jpg', 'C2/R9/P9.jpg'],
  'C2 ve solo su carpeta'
);
reset role;

-- =====================================================================
-- 3. set_recipe_photo
-- =====================================================================
select ok(
  (select not p.prosecdef and p.provolatile = 'v' and p.proconfig = array['search_path=""']
          and pg_get_function_result(p.oid) = 'uuid'
   from pg_proc p where p.oid = 'public.set_recipe_photo(uuid,uuid)'::regprocedure),
  'set_recipe_photo(uuid, uuid) devuelve uuid: security invoker (corre con la RLS de quien llama), volatile y search_path vacío'
);
select is(
  (select array_agg(r order by r)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, 'public.set_recipe_photo(uuid,uuid)', 'EXECUTE')),
  array['authenticated'],
  'solo la ejecuta authenticated (la app), como save_recipe'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000c001","role":"authenticated"}';
select is(
  public.set_recipe_photo(pg_temp.id('R1'), pg_temp.id('P1')),
  null::uuid,
  'C1 le pone a R1 la foto P1: no había otra, no hay nada que borrar'
);
select is(pg_temp.photo_of('R1'), 'P1', 'y R1 queda con P1');
select is(
  public.set_recipe_photo(pg_temp.id('R1'), pg_temp.id('P1')),
  null::uuid,
  'otra vez la misma foto: devuelve null (sus archivos siguen en uso)'
);
select is(
  array[
    pg_temp.error_of($$ select public.set_recipe_photo(pg_temp.id('R1'), pg_temp.id('P2')) $$),
    pg_temp.error_of($$ select public.set_recipe_photo(pg_temp.id('R2'), pg_temp.id('P1')) $$),
    pg_temp.error_of($$ select public.set_recipe_photo(pg_temp.id('R1'), pg_temp.id('P7')) $$),
    pg_temp.error_of($$ select public.set_recipe_photo(pg_temp.id('R9'), pg_temp.id('P9')) $$),
    pg_temp.error_of($$ select public.set_recipe_photo(pg_temp.id('R7'), pg_temp.id('P1')) $$),
    pg_temp.error_of($$ select public.set_recipe_photo(null, pg_temp.id('P1')) $$)
  ],
  array[
    '22023: photo_not_found (C1/R1/P2-thumb.jpg)',
    '22023: photo_not_found (C1/R2/P1.jpg, C1/R2/P1-thumb.jpg)',
    '22023: photo_not_found (C1/R1/P7.jpg, C1/R1/P7-thumb.jpg)',
    'P0002: recipe_not_found',
    'P0002: recipe_not_found',
    'P0002: recipe_not_found'
  ],
  'sin los dos archivos en la carpeta de ese plato, photo_not_found con las rutas que faltan (falta la miniatura, '
  'los archivos son de otro plato o no se subió nada); un plato de otra cocina, uno que no existe o null, '
  'recipe_not_found (como save_recipe)'
);
select is(
  array[pg_temp.photo_of('R1'), pg_temp.photo_of('R2')],
  array['P1', null],
  'después de esos intentos, R1 sigue con P1 y R2 sin foto'
);

set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000d001","role":"authenticated"}';
select is(
  pg_temp.short(public.set_recipe_photo(pg_temp.id('R1'), pg_temp.id('P3'))::text),
  'P1',
  'M cambia la foto de R1 por P3, que subió él: devuelve P1, para que la app borre sus archivos'
);
select is(pg_temp.photo_of('R1'), 'P3', 'y R1 queda con P3');

set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000c001","role":"authenticated"}';
select is(
  pg_temp.short(public.set_recipe_photo(pg_temp.id('R1'), null)::text),
  'P3',
  'C1 le saca la foto a R1 (p_photo_id null): devuelve P3'
);
select is(pg_temp.photo_of('R1'), null, 'y R1 queda sin foto');
select is(
  array[public.set_recipe_photo(pg_temp.id('R1'), null), public.set_recipe_photo(pg_temp.id('R3'), null)],
  array[null, null]::uuid[],
  'sacar la foto de un plato que no tiene (también uno desactivado): devuelve null'
);
select is(
  public.set_recipe_photo(pg_temp.id('R1'), pg_temp.id('P1')),
  null::uuid,
  'C1 le vuelve a poner P1 a R1'
);

set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000a001","role":"authenticated"}';
select throws_ok(
  $$ select public.set_recipe_photo(pg_temp.id('R1'), null) $$,
  '42501', 'not_a_chef',
  'la clienta A no cambia fotos: not_a_chef'
);
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select throws_ok(
  $$ select public.set_recipe_photo(pg_temp.id('R1'), null) $$,
  '42501', 'permission denied for function set_recipe_photo',
  'anon no la ejecuta'
);
reset role;
select is(pg_temp.photo_of('R1'), 'P1', 'R1 sigue con P1');

-- =====================================================================
-- 4. El trigger recipes_check_photo: también para un update o insert directo
-- =====================================================================
select is(
  (select format('%s | %s', t.tgname, pg_get_triggerdef(t.oid))
   from pg_trigger t where t.tgrelid = 'public.recipes'::regclass and t.tgname = 'recipes_check_photo'),
  'recipes_check_photo | CREATE TRIGGER recipes_check_photo BEFORE INSERT OR UPDATE OF photo_id, id, chef_id ON public.recipes '
  'FOR EACH ROW EXECUTE FUNCTION recipes_check_photo()',
  'recipes: trigger antes de cada insert y de cada update de photo_id, id o chef_id'
);
select ok(
  (select not p.prosecdef and p.proconfig = array['search_path=""']
          and not has_function_privilege('anon', p.oid, 'EXECUTE')
          and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
   from pg_proc p where p.oid = 'public.recipes_check_photo()'::regprocedure),
  'recipes_check_photo: security invoker (busca los archivos con la RLS de quien escribe), search_path vacío y sin EXECUTE para la API'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000c001","role":"authenticated"}';
select is(
  array[
    pg_temp.error_of($$ update public.recipes set photo_id = pg_temp.id('P7') where id = pg_temp.id('R1') $$),
    pg_temp.error_of($$ update public.recipes set photo_id = pg_temp.id('P2') where id = pg_temp.id('R1') $$),
    pg_temp.error_of($$ insert into public.recipes (id, chef_id, name_it, photo_id)
                        values (pg_temp.id('R7'), pg_temp.id('C1'), 'Risotto', pg_temp.id('P1')) $$)
  ],
  array[
    '22023: photo_not_found (C1/R1/P7.jpg, C1/R1/P7-thumb.jpg)',
    '22023: photo_not_found (C1/R1/P2-thumb.jpg)',
    '22023: photo_not_found (C1/R7/P1.jpg, C1/R7/P1-thumb.jpg)'
  ],
  'C1 por la API (sin set_recipe_photo): un update a una foto sin archivos, o sin la miniatura, y un insert con '
  'una foto de otro plato dan photo_not_found con las rutas que faltan'
);
select is(pg_temp.photo_of('R1'), 'P1', 'R1 sigue con P1');
select is(
  array[pg_temp.affected($$ update public.recipes set photo_id = null where id = pg_temp.id('R1') $$),
        pg_temp.affected($$ update public.recipes set photo_id = pg_temp.id('P3') where id = pg_temp.id('R1') $$),
        pg_temp.affected($$ update public.recipes set photo_id = pg_temp.id('P3'), active = true where id = pg_temp.id('R1') $$)],
  array[1, 1, 1],
  'un update directo a null pasa, uno a una foto con sus dos archivos también, y uno que deja la misma foto también'
);
reset role;
set local role service_role;
select is(
  pg_temp.error_of($$ update public.recipes set photo_id = pg_temp.id('P7') where id = pg_temp.id('R9') $$),
  '22023: photo_not_found (C2/R9/P7.jpg, C2/R9/P7-thumb.jpg)',
  'la service role tampoco guarda una foto sin archivos'
);
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000c001","role":"authenticated"}';
select is(
  pg_temp.short(public.set_recipe_photo(pg_temp.id('R1'), pg_temp.id('P1'))::text),
  'P3',
  'C1 vuelve a poner P1 con set_recipe_photo: devuelve P3, la que puso el update directo'
);
reset role;

-- =====================================================================
-- 5. save_recipe no toca photo_id
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e660000-0000-4000-8000-00000000c001","role":"authenticated"}';
select lives_ok(
  $$ select public.save_recipe(pg_temp.dish('R1', '{"name_it": "Lasagne verdi"}')) $$,
  'C1 vuelve a guardar R1 con save_recipe'
);
select is(pg_temp.photo_of('R1'), 'P1', 'y la foto sigue');
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('R1', jsonb_build_object('photo_id', pg_temp.id('P3')))) $$),
  '22023: invalid_payload (photo_id)',
  'save_recipe no recibe photo_id (es una clave desconocida): la foto se cambia solo con set_recipe_photo'
);
select is(
  pg_temp.short(public.save_recipe(pg_temp.dish('R5'))::text),
  'R5',
  'C1 duplica R1: lo guarda con un id nuevo'
);
select is(
  (select format('%s · %s', r.name_it, coalesce(pg_temp.short(r.photo_id::text), 'sin foto'))
   from public.recipes r where r.id = pg_temp.id('R5')),
  'Lasagne alla bolognese · sin foto',
  'y la copia no tiene la foto del original'
);
reset role;

-- =====================================================================
-- 6. get_public_menu con photoId
-- =====================================================================
set local role service_role;
select is(
  (select jsonb_agg(jsonb_build_object('id', pg_temp.short(d ->> 'id'), 'photoId', pg_temp.short(d ->> 'photoId'))
                    order by o)
   from jsonb_array_elements(public.get_public_menu(pg_temp.id('C1'))) with ordinality as t(d, o)),
  '[{"id": "R1", "photoId": "P1"}, {"id": "R2", "photoId": null}]'::jsonb,
  'el menú de C1: R1 con su foto y R2 con photoId null (sin foto); el desactivado y la copia sin descripción no salen'
);
select is(
  (select array_agg(distinct k order by k)
   from jsonb_array_elements(public.get_public_menu(pg_temp.id('C1'))) as d, jsonb_object_keys(d) as k),
  array['allergens', 'description', 'diet', 'id', 'ingredients', 'name', 'photoId', 'seasonMonths'],
  'cada plato trae ocho claves: las de antes más ingredients (20261125100000)'
);
select is(
  public.get_public_menu(pg_temp.id('C2')) -> 0 -> 'photoId',
  'null'::jsonb,
  'el plato de C2 sin foto puesta (aunque sus archivos estén en el bucket): photoId null'
);
reset role;

select finish();
rollback;
