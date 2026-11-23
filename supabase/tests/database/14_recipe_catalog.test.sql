-- =====================================================================
-- Catálogo de platos, base de datos (área de Evelyn, PR 13a; migración
-- 20261116170000_recipe_catalog.sql):
--   * recipes: name_en, season_months (meses 1 a 12, sin repetir; null = todo el año) y
--     catalog_visible (false = receta de un evento: no se ofrece en el catálogo).
--   * recipe_ingredients: cantidad entera para 4 porciones con su unidad (g, ml o piezas), o «q.b.»
--     sin ninguna de las dos. Solo de la cocinera.
--   * recipe_notes: las notas de cada plato, solo de la cocinera (ya no están en recipes, que el
--     cliente lee). La clienta lee solo los alérgenos de las recetas que ve.
--   * public.save_recipe(p jsonb): guarda el plato entero (receta, alérgenos, ingredientes y notas)
--     en una transacción, con la RLS de quien llama (security invoker). Rechaza las claves que no
--     conoce y una dieta que contradice los alérgenos.
--
-- C1 tiene a la clienta A; C2 es otra cocinera, con una receta propia. C1 guarda sus platos con
-- save_recipe, como la app. Duplicar es guardar con un id nuevo el plato que la app ya tiene cargado.
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

select plan(142);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e5c0000-0000-4000-8000-00000000c001', 'chef1@catalogo.test'),
  ('7e5c0000-0000-4000-8000-00000000c002', 'chef2@catalogo.test'),
  ('7e5c0000-0000-4000-8000-00000000a001', 'a@catalogo.test');
update public.profiles set role = 'chef'
where id in ('7e5c0000-0000-4000-8000-00000000c001', '7e5c0000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e5c1000-0000-4000-8000-000000000001', '7e5c0000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e5c1000-0000-4000-8000-000000000002', '7e5c0000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e5c1000-0000-4000-8000-000000000001'),
  ('7e5c1000-0000-4000-8000-000000000002');

insert into public.clients (id, chef_id, profile_id, display_name, status) values
  ('7e5c2000-0000-4000-8000-00000000000a', '7e5c1000-0000-4000-8000-000000000001',
   '7e5c0000-0000-4000-8000-00000000a001', 'Cliente A', 'active');

-- La receta de C2, con un alérgeno y un ingrediente.
insert into public.recipes (id, chef_id, name_it) values
  ('7e5c6000-0000-4000-8000-0000000000f1', '7e5c1000-0000-4000-8000-000000000002', 'Ossobuco');
insert into public.recipe_allergens (recipe_id, chef_id, allergen) values
  ('7e5c6000-0000-4000-8000-0000000000f1', '7e5c1000-0000-4000-8000-000000000002', 'celery');
insert into public.recipe_ingredients (recipe_id, chef_id, position, name, section, quantity, unit) values
  ('7e5c6000-0000-4000-8000-0000000000f1', '7e5c1000-0000-4000-8000-000000000002', 1,
   'Ossibuchi di vitello', 'meat_fish', 800, 'g');

-- Una receta de C1 para probar los checks con escrituras directas.
insert into public.recipes (id, chef_id, name_it) values
  ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 'Prova');

-- Un plato válido; p_extra pisa o agrega claves.
create function pg_temp.dish(p_id text, p_extra jsonb default '{}') returns jsonb
language sql
as $$
  select jsonb_build_object(
    'id', p_id,
    'name_it', 'Frittata di zucchine',
    'allergens', jsonb_build_array('eggs', 'milk'),
    'ingredients', jsonb_build_array(
      jsonb_build_object('name', 'Zucchine', 'section', 'produce', 'quantity', 500, 'unit', 'g'),
      jsonb_build_object('name', 'Uova', 'section', 'dairy_eggs', 'quantity', 6, 'unit', 'pcs'),
      jsonb_build_object('name', 'Sale', 'section', 'pantry', 'quantity', null, 'unit', null))
  ) || p_extra
$$;

-- El plato completo de la app, con espacios de más, un alérgeno repetido y meses desordenados.
create function pg_temp.lasagne() returns jsonb
language sql
as $$
  select '{
    "id": "7e5c6000-0000-4000-8000-000000000001",
    "name_it": "  Lasagne alla bolognese ",
    "name_es": "Lasaña a la boloñesa",
    "name_en": "",
    "diet": null,
    "season_months": [12, 1, 2],
    "fridge_days": 4,
    "freezable": true,
    "freezer_days": 90,
    "notes": "Il ragù cuoce 3 ore.",
    "allergens": ["milk", "gluten", "eggs", "milk"],
    "ingredients": [
      {"name": " Farina 00 ", "section": "pantry", "quantity": 400, "unit": "g"},
      {"name": "Uova", "section": "dairy_eggs", "quantity": 4, "unit": "pcs"},
      {"name": "Latte intero", "section": "dairy_eggs", "quantity": 1000, "unit": "ml"},
      {"name": "Sale"}
    ]
  }'::jsonb
$$;

-- Duplicar, como la app: lee el plato (con la RLS de quien llama) y lo guarda con otro id. Como
-- recipeSavePayload, no manda active ni catalog_visible: la copia nace con los de la tabla.
create function pg_temp.copy_of(p_src uuid, p_new_id text, p_suffix text) returns jsonb
language sql
as $$
  select jsonb_build_object(
    'id', p_new_id,
    'name_it', r.name_it || p_suffix,
    'name_es', r.name_es, 'name_en', r.name_en, 'diet', r.diet, 'season_months', r.season_months,
    'fridge_days', r.fridge_days, 'freezable', r.freezable, 'freezer_days', r.freezer_days,
    'notes', (select n.notes from public.recipe_notes n where n.recipe_id = r.id),
    'allergens', (select coalesce(jsonb_agg(a.allergen), '[]')
                  from public.recipe_allergens a where a.recipe_id = r.id),
    'ingredients', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'section', i.section,
                                                                 'quantity', i.quantity, 'unit', i.unit)
                                              order by i.position), '[]')
                    from public.recipe_ingredients i where i.recipe_id = r.id))
  from public.recipes r
  where r.id = p_src
$$;

-- El plato guardado (receta, alérgenos e ingredientes), para comparar antes y después.
create function pg_temp.saved(p_id uuid) returns jsonb
language sql
as $$
  select jsonb_build_object(
    'name_it', r.name_it, 'name_es', r.name_es, 'name_en', r.name_en, 'diet', r.diet,
    'season_months', r.season_months, 'fridge_days', r.fridge_days, 'freezable', r.freezable,
    'freezer_days', r.freezer_days,
    'notes', (select n.notes from public.recipe_notes n where n.recipe_id = r.id),
    'active', r.active, 'catalog_visible', r.catalog_visible,
    'allergens', (select coalesce(jsonb_agg(a.allergen order by a.allergen), '[]')
                  from public.recipe_allergens a where a.recipe_id = r.id),
    'ingredients', (select coalesce(jsonb_agg(jsonb_build_array(i.name, i.section, i.quantity, i.unit)
                                              order by i.position), '[]')
                    from public.recipe_ingredients i where i.recipe_id = r.id))
  from public.recipes r
  where r.id = p_id
$$;

-- El error de una sentencia como "SQLSTATE: mensaje (DETAIL)", o null si no falla.
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
  return sqlstate || ': ' || sqlerrm || coalesce(' (' || nullif(v_detail, '') || ')', '');
end
$$;

-- Los errores de guardar el plato 1 con cada uno de p_extras encima (en orden).
create function pg_temp.errors_of(p_extras text[]) returns text[]
language sql
as $$
  select array_agg(pg_temp.error_of(format(
           $f$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001', %L)) $f$, x.extra))
         order by x.n)
  from unnest(p_extras) with ordinality as x(extra, n)
$$;

-- Fotos de un plato para comparar después de un intento fallido (los usuarios simulados las escriben).
create temp table snap (k text primary key, v jsonb);
grant select, insert on snap to authenticated;

-- =====================================================================
-- 1. Esquema
-- =====================================================================
select has_column('public', 'recipes', 'name_en', 'recipes.name_en');
select col_type_is('public', 'recipes', 'season_months', 'smallint[]', 'recipes.season_months es smallint[]');
select is(
  (select format('%s %s %s', c.data_type, c.is_nullable, c.column_default)
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'recipes' and c.column_name = 'catalog_visible'),
  'boolean NO true',
  'recipes.catalog_visible: boolean, obligatorio y true por defecto'
);
select has_table('public', 'recipe_ingredients', 'existe public.recipe_ingredients');
select is(
  (select array_agg(format('%s %s %s', c.column_name, c.udt_name, c.is_nullable) order by c.ordinal_position)
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'recipe_ingredients'),
  array['recipe_id uuid NO', 'chef_id uuid NO', 'position int2 NO', 'name text NO',
        'section shopping_section NO', 'quantity int4 YES', 'unit ingredient_unit YES'],
  'recipe_ingredients: columnas y tipos (la cantidad es un entero; cantidad y unidad, opcionales para «q.b.»)'
);
select is(
  (select c.column_default from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'recipe_ingredients' and c.column_name = 'section'),
  '''other''::shopping_section',
  'la sección es «otros» si no se elige'
);
select col_is_pk('public', 'recipe_ingredients', array['recipe_id', 'position'], 'PK (recipe_id, position)');
select is(
  (select pg_get_constraintdef(k.oid) from pg_constraint k
   where k.conrelid = 'public.recipe_ingredients'::regclass and k.contype = 'f'),
  'FOREIGN KEY (recipe_id, chef_id) REFERENCES recipes(id, chef_id) ON DELETE CASCADE',
  'FK compuesta (recipe_id, chef_id) a recipes, con on delete cascade'
);
select enum_has_labels('public', 'shopping_section',
  array['produce', 'meat_fish', 'dairy_eggs', 'bakery', 'pantry', 'frozen', 'other'],
  'secciones del súper, pocas y fijas, en el orden del recorrido');
select enum_has_labels('public', 'ingredient_unit', array['g', 'ml', 'pcs'], 'unidades: g, ml y piezas');
select is(
  (select array_agg(format('%s | %s | %s', p.policyname, p.cmd, p.roles::text) order by p.policyname)
   from pg_policies p
   where p.schemaname = 'public' and p.tablename = 'recipe_ingredients'),
  array['recipe_ingredients: la cocinera gestiona los suyos | ALL | {authenticated}'],
  'recipe_ingredients: solo la política de la cocinera (el cliente no tiene ninguna)'
);

-- Notas: fuera de recipes (el cliente lee la fila entera: la RLS filtra filas, no columnas).
select hasnt_column('public', 'recipes', 'notes', 'recipes ya no tiene notes: el cliente lee recipes');
select has_table('public', 'recipe_notes', 'existe public.recipe_notes');
select is(
  (select array_agg(format('%s %s %s', c.column_name, c.udt_name, c.is_nullable) order by c.ordinal_position)
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'recipe_notes'),
  array['recipe_id uuid NO', 'chef_id uuid NO', 'notes text NO'],
  'recipe_notes: columnas y tipos (una fila por plato con notas)'
);
select col_is_pk('public', 'recipe_notes', array['recipe_id'], 'recipe_notes: PK recipe_id (una por plato)');
select is(
  (select pg_get_constraintdef(k.oid) from pg_constraint k
   where k.conrelid = 'public.recipe_notes'::regclass and k.contype = 'f'),
  'FOREIGN KEY (recipe_id, chef_id) REFERENCES recipes(id, chef_id) ON DELETE CASCADE',
  'recipe_notes: FK compuesta (recipe_id, chef_id) a recipes, con on delete cascade'
);
select is(
  (select array_agg(format('%s | %s | %s', p.policyname, p.cmd, p.roles::text) order by p.policyname)
   from pg_policies p
   where p.schemaname = 'public' and p.tablename = 'recipe_notes'),
  array['recipe_notes: la cocinera gestiona las suyas | ALL | {authenticated}'],
  'recipe_notes: solo la política de la cocinera (el cliente no tiene ninguna)'
);
select is(
  (select array_agg(format('%s | %s | %s', p.policyname, p.cmd, p.roles::text) order by p.policyname)
   from pg_policies p
   where p.schemaname = 'public' and p.tablename = 'recipe_allergens'),
  array['recipe_allergens: la cocinera gestiona los suyos | ALL | {authenticated}'],
  'recipe_allergens: solo la política de la cocinera (el cliente no tiene ninguna: la clienta lee por Edge Functions)'
);

-- =====================================================================
-- 2. Privilegios
-- =====================================================================
select ok(
  not has_table_privilege('anon', 'public.recipe_ingredients', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),
  'anon: ningún privilegio sobre recipe_ingredients'
);
select ok(
  has_table_privilege('authenticated', 'public.recipe_ingredients', 'SELECT')
  and has_table_privilege('authenticated', 'public.recipe_ingredients', 'INSERT')
  and has_table_privilege('authenticated', 'public.recipe_ingredients', 'UPDATE')
  and has_table_privilege('authenticated', 'public.recipe_ingredients', 'DELETE')
  and not has_table_privilege('authenticated', 'public.recipe_ingredients', 'TRUNCATE,REFERENCES,TRIGGER'),
  'authenticated: select, insert, update y delete (la RLS decide las filas), sin truncate'
);
select ok(
  has_table_privilege('service_role', 'public.recipe_ingredients', 'SELECT')
  and has_table_privilege('service_role', 'public.recipe_ingredients', 'INSERT')
  and has_table_privilege('service_role', 'public.recipe_ingredients', 'UPDATE')
  and has_table_privilege('service_role', 'public.recipe_ingredients', 'DELETE')
  and not has_table_privilege('service_role', 'public.recipe_ingredients', 'TRUNCATE,REFERENCES,TRIGGER'),
  'service_role: las cuatro operaciones y nada más'
);
select ok(
  not has_table_privilege('anon', 'public.recipe_notes', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),
  'anon: ningún privilegio sobre recipe_notes'
);
select ok(
  has_table_privilege('authenticated', 'public.recipe_notes', 'SELECT')
  and has_table_privilege('authenticated', 'public.recipe_notes', 'INSERT')
  and has_table_privilege('authenticated', 'public.recipe_notes', 'UPDATE')
  and has_table_privilege('authenticated', 'public.recipe_notes', 'DELETE')
  and not has_table_privilege('authenticated', 'public.recipe_notes', 'TRUNCATE,REFERENCES,TRIGGER'),
  'recipe_notes, authenticated: select, insert, update y delete (la RLS decide las filas), sin truncate'
);
select ok(
  has_table_privilege('service_role', 'public.recipe_notes', 'SELECT')
  and has_table_privilege('service_role', 'public.recipe_notes', 'INSERT')
  and has_table_privilege('service_role', 'public.recipe_notes', 'UPDATE')
  and has_table_privilege('service_role', 'public.recipe_notes', 'DELETE')
  and not has_table_privilege('service_role', 'public.recipe_notes', 'TRUNCATE,REFERENCES,TRIGGER'),
  'recipe_notes, service_role: las cuatro operaciones y nada más'
);
select ok(
  has_function_privilege('authenticated', 'public.save_recipe(jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.save_recipe(jsonb)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.save_recipe(jsonb)', 'EXECUTE'),
  'save_recipe: la ejecuta authenticated (la app); anon y service_role no'
);
select ok(
  (select not p.prosecdef and p.proconfig @> array['search_path=""']
   from pg_proc p where p.oid = 'public.save_recipe(jsonb)'::regprocedure),
  'save_recipe es security invoker (corre con la RLS de quien llama) y fija search_path vacío'
);

-- =====================================================================
-- 3. C1 crea un plato
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e5c0000-0000-4000-8000-00000000c001","role":"authenticated"}';

select is(
  public.save_recipe(pg_temp.lasagne()),
  '7e5c6000-0000-4000-8000-000000000001'::uuid,
  'C1 crea un plato con save_recipe: devuelve el id que generó la app'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001') - 'allergens' - 'ingredients',
  '{"name_it": "Lasagne alla bolognese", "name_es": "Lasaña a la boloñesa", "name_en": null, "diet": null,
    "season_months": [1, 2, 12], "fridge_days": 4, "freezable": true, "freezer_days": 90,
    "notes": "Il ragù cuoce 3 ore.", "active": true, "catalog_visible": true}'::jsonb,
  'la receta: nombres recortados (el vacío queda null), meses en orden, activa y visible por defecto'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001') -> 'allergens',
  '["gluten", "eggs", "milk"]'::jsonb,
  'los alérgenos, sin repetir'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001') -> 'ingredients',
  '[["Farina 00", "pantry", 400, "g"], ["Uova", "dairy_eggs", 4, "pcs"],
    ["Latte intero", "dairy_eggs", 1000, "ml"], ["Sale", "other", null, null]]'::jsonb,
  'los ingredientes en el orden de la lista: cantidad para 4 porciones con su unidad, o q.b. (sin sección: otros)'
);
select is(
  (select format('%s | %s',
     (select array_agg(distinct x.chef_id) from (
        select chef_id from public.recipes where id = '7e5c6000-0000-4000-8000-000000000001'
        union all select chef_id from public.recipe_allergens where recipe_id = '7e5c6000-0000-4000-8000-000000000001'
        union all select chef_id from public.recipe_ingredients where recipe_id = '7e5c6000-0000-4000-8000-000000000001'
        union all select chef_id from public.recipe_notes where recipe_id = '7e5c6000-0000-4000-8000-000000000001'
      ) as x),
     (select array_agg(i.position order by i.position) from public.recipe_ingredients i
      where i.recipe_id = '7e5c6000-0000-4000-8000-000000000001'))),
  '{7e5c1000-0000-4000-8000-000000000001} | {1,2,3,4}',
  'todo queda con el chef_id de la sesión (no viene en el plato) y los ingredientes numerados 1, 2, 3, 4'
);
select is(
  public.save_recipe(pg_temp.lasagne()),
  '7e5c6000-0000-4000-8000-000000000001'::uuid,
  'reintentar el mismo guardado (se cortó la señal) devuelve el mismo id'
);
select is(
  (select format('%s recetas, %s alérgenos, %s ingredientes, %s notas',
     (select count(*) from public.recipes where id <> '7e5c6000-0000-4000-8000-000000000009'),
     (select count(*) from public.recipe_allergens),
     (select count(*) from public.recipe_ingredients),
     (select count(*) from public.recipe_notes))),
  '1 recetas, 3 alérgenos, 4 ingredientes, 1 notas',
  'y no duplica nada: el id lo generó la app'
);

-- =====================================================================
-- 4. C1 lo edita: lo que no viene no se toca; null borra
-- =====================================================================
select is(
  public.save_recipe('{
    "id": "7e5c6000-0000-4000-8000-000000000001",
    "name_it": "Lasagne verdi",
    "season_months": null,
    "allergens": ["celery", "gluten", "milk"],
    "ingredients": [
      {"name": "Spinaci", "section": "produce", "quantity": 300, "unit": "g"},
      {"name": "Farina 00", "section": "pantry", "quantity": 300, "unit": "g"}
    ]
  }'),
  '7e5c6000-0000-4000-8000-000000000001'::uuid,
  'C1 edita el plato: otro nombre, todo el año, otros alérgenos y otros ingredientes'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001') - 'allergens' - 'ingredients',
  '{"name_it": "Lasagne verdi", "name_es": "Lasaña a la boloñesa", "name_en": null, "diet": null,
    "season_months": null, "fridge_days": 4, "freezable": true, "freezer_days": 90,
    "notes": "Il ragù cuoce 3 ore.", "active": true, "catalog_visible": true}'::jsonb,
  'cambia lo que vino; lo que no vino (nombre en español, notas, conservación) no se toca'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001') -> 'allergens',
  '["gluten", "milk", "celery"]'::jsonb,
  'los alérgenos se reemplazan enteros (sale eggs, entra celery)'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001') -> 'ingredients',
  '[["Spinaci", "produce", 300, "g"], ["Farina 00", "pantry", 300, "g"]]'::jsonb,
  'los ingredientes se reemplazan enteros: no quedan los de antes'
);
select is(
  public.save_recipe('{
    "id": "7e5c6000-0000-4000-8000-000000000001",
    "name_it": "Lasagne verdi",
    "name_es": null,
    "notes": null,
    "diet": "vegetarian",
    "allergens": ["celery", "gluten", "milk"],
    "ingredients": [
      {"name": "Spinaci", "section": "produce", "quantity": 300, "unit": "g"},
      {"name": "Farina 00", "section": "pantry", "quantity": 300, "unit": "g"}
    ]
  }'),
  '7e5c6000-0000-4000-8000-000000000001'::uuid,
  'C1 borra el nombre en español y las notas (null) y elige una dieta'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001') - 'allergens' - 'ingredients',
  '{"name_it": "Lasagne verdi", "name_es": null, "name_en": null, "diet": "vegetarian",
    "season_months": null, "fridge_days": 4, "freezable": true, "freezer_days": 90,
    "notes": null, "active": true, "catalog_visible": true}'::jsonb,
  'null borra; la dieta queda guardada'
);
select is(
  (select count(*)::int from public.recipe_notes where recipe_id = '7e5c6000-0000-4000-8000-000000000001'),
  0,
  'las notas en null borran su fila (sin notas, sin fila)'
);

-- =====================================================================
-- 5. Duplicar: la app guarda con un id nuevo el plato que tiene cargado
-- =====================================================================
select is(
  public.save_recipe(pg_temp.copy_of('7e5c6000-0000-4000-8000-000000000001',
                                     '7e5c6000-0000-4000-8000-000000000002', ' (copia)')),
  '7e5c6000-0000-4000-8000-000000000002'::uuid,
  'C1 duplica el plato: save_recipe con un id nuevo'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000002'),
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001') || '{"name_it": "Lasagne verdi (copia)"}',
  'la copia tiene los mismos alérgenos, ingredientes, temporada, dieta y conservación'
);
select is(
  public.save_recipe(pg_temp.copy_of('7e5c6000-0000-4000-8000-000000000001',
                                     '7e5c6000-0000-4000-8000-000000000002', ' (copia)')),
  '7e5c6000-0000-4000-8000-000000000002'::uuid,
  'reintentar la copia devuelve el mismo id'
);
select is(
  (select array_agg(name_it order by name_it) from public.recipes
   where id <> '7e5c6000-0000-4000-8000-000000000009'),
  array['Lasagne verdi', 'Lasagne verdi (copia)'],
  'y no hace una tercera: el original y una sola copia'
);

-- =====================================================================
-- 6. Desactivar y recetas fuera del catálogo
-- =====================================================================
select is(
  public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000004')),
  '7e5c6000-0000-4000-8000-000000000004'::uuid,
  'C1 crea otro plato'
);
select is(
  public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000005',
                                  '{"name_it": "Vitello tonnato", "catalog_visible": false, "notes": "Per 20 persone."}')),
  '7e5c6000-0000-4000-8000-000000000005'::uuid,
  'C1 crea una receta de evento, fuera del catálogo (catalog_visible = false)'
);
select lives_ok(
  $$ update public.recipes set active = false where id = '7e5c6000-0000-4000-8000-000000000004' $$,
  'C1 desactiva un plato (un update directo: es una sola sentencia)'
);
select is(
  public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000004',
                                  '{"name_it": "Frittata di zucchine e menta", "notes": "  Menta fresca. "}')),
  '7e5c6000-0000-4000-8000-000000000004'::uuid,
  'C1 vuelve a guardar el plato desactivado, sin la clave active'
);
select is(
  public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000005',
                                  '{"name_it": "Vitello tonnato", "notes": "   "}')),
  '7e5c6000-0000-4000-8000-000000000005'::uuid,
  'y la receta de evento, sin la clave catalog_visible'
);
select is(
  (select array_agg(format('%s · active %s · catalog_visible %s', name_it, active::text, catalog_visible::text)
                    order by name_it)
   from public.recipes
   where id in ('7e5c6000-0000-4000-8000-000000000004', '7e5c6000-0000-4000-8000-000000000005')),
  array['Frittata di zucchine e menta · active false · catalog_visible true',
        'Vitello tonnato · active true · catalog_visible false'],
  'guardar sin esas claves no reactiva el plato ni pasa la receta de evento al catálogo'
);
select is(
  (select array_agg(format('%s: %s', recipe_id, notes) order by recipe_id) from public.recipe_notes
   where recipe_id in ('7e5c6000-0000-4000-8000-000000000004', '7e5c6000-0000-4000-8000-000000000005')),
  array['7e5c6000-0000-4000-8000-000000000004: Menta fresca.'],
  'las notas se guardan recortadas y, si quedan solo espacios, se borran (sin notas, sin fila)'
);

-- Duplicar un plato desactivado: la app no manda active, así que la copia sale activa.
select is(
  public.save_recipe(pg_temp.copy_of('7e5c6000-0000-4000-8000-000000000004',
                                     '7e5c6000-0000-4000-8000-000000000008', ' (copia)')),
  '7e5c6000-0000-4000-8000-000000000008'::uuid,
  'C1 duplica el plato desactivado'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000008'),
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000004')
    || '{"name_it": "Frittata di zucchine e menta (copia)", "active": true}',
  'la copia sale activa, con las mismas notas, alérgenos e ingredientes'
);

-- Lo que no viene no se toca, también cuando tiene valor (nombre en inglés, dieta y temporada).
select is(
  public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000006',
                                  '{"name_en": "Courgette frittata", "diet": "vegetarian", "season_months": [7, 6]}')),
  '7e5c6000-0000-4000-8000-000000000006'::uuid,
  'C1 crea un plato con nombre en inglés, dieta y temporada'
);
select is(
  public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000006')),
  '7e5c6000-0000-4000-8000-000000000006'::uuid,
  'y lo vuelve a guardar sin esas claves'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000006') - 'allergens' - 'ingredients',
  '{"name_it": "Frittata di zucchine", "name_es": null, "name_en": "Courgette frittata", "diet": "vegetarian",
    "season_months": [6, 7], "fridge_days": 3, "freezable": false, "freezer_days": 60,
    "notes": null, "active": true, "catalog_visible": true}'::jsonb,
  'el nombre en inglés, la dieta y la temporada siguen como estaban'
);

-- =====================================================================
-- 7. Guardado atómico: si algo falla, no cambia nada
-- =====================================================================
insert into snap (k, v) values ('r1', pg_temp.saved('7e5c6000-0000-4000-8000-000000000001'));

select throws_ok(
  $$ select public.save_recipe('{
       "id": "7e5c6000-0000-4000-8000-000000000001",
       "name_it": "Lasagne rotta",
       "allergens": ["nuts", "soy"],
       "ingredients": [
         {"name": "Pomodori", "section": "produce", "quantity": 800, "unit": "g"},
         {"name": "Burro", "section": "dairy_eggs", "quantity": 0, "unit": "g"}
       ]
     }') $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_cantidad_valida"',
  'un ingrediente inválido (cantidad 0, el último) hace fallar el guardado entero'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001'),
  (select v from snap where k = 'r1'),
  'el plato quedó como estaba: ni el nombre, ni los alérgenos, ni el ingrediente que sí era válido'
);
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000007',
       '{"ingredients": [{"name": "Burro", "section": "dairy_eggs", "unit": "g"}]}')) $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_cantidad_con_unidad"',
  'un plato nuevo con una unidad sin cantidad no se guarda'
);
select is(
  (select count(*)::int from public.recipes where id = '7e5c6000-0000-4000-8000-000000000007')
  + (select count(*)::int from public.recipe_allergens where recipe_id = '7e5c6000-0000-4000-8000-000000000007'),
  0,
  'y no queda creado a medias: ni la receta ni sus alérgenos'
);

-- Datos mal formados: invalid_payload (22023) con el campo en el DETAIL, antes de escribir nada.
select is(
  pg_temp.error_of($$ select public.save_recipe('[]') $$),
  '22023: invalid_payload (p)',
  'el plato tiene que ser un objeto JSON'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('42')) $$),
  '22023: invalid_payload (id)',
  'el id es un uuid que genera la app (sin id no se guarda)'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001', '{"name_it": null}')) $$),
  '22023: invalid_payload (name_it)',
  'el nombre en italiano es obligatorio'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001') - 'allergens') $$),
  '22023: invalid_payload (allergens)',
  'sin la lista de alérgenos no guarda: nunca se borran por omisión ([] es «ninguno»)'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001') - 'ingredients') $$),
  '22023: invalid_payload (ingredients)',
  'sin la lista de ingredientes tampoco'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
                        '{"allergens": ["eggs", "lattosio"]}')) $$),
  '22023: invalid_payload (allergens[1])',
  'un alérgeno que no es de los 14 (dice cuál, contando desde 0)'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
                        '{"ingredients": ["Riso"]}')) $$),
  '22023: invalid_payload (ingredients[0])',
  'cada ingrediente es un objeto'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
                        '{"ingredients": [{"name": "Riso", "quantity": 2.5, "unit": "g"}]}')) $$),
  '22023: invalid_payload (ingredients[0].quantity)',
  'la cantidad es un entero'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
                        '{"ingredients": [{"name": "Uova", "quantity": 2, "unit": "pz"}]}')) $$),
  '22023: invalid_payload (ingredients[0].unit)',
  'la unidad es g, ml o pcs'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
                        '{"ingredients": [{"name": "Riso", "section": "deli"}]}')) $$),
  '22023: invalid_payload (ingredients[0].section)',
  'la sección es una de las fijas'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
                        '{"season_months": ["1"]}')) $$),
  '22023: invalid_payload (season_months)',
  'los meses son números enteros'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
                        '{"fridge_days": null}')) $$),
  '22023: invalid_payload (fridge_days)',
  'una columna obligatoria no acepta null (si no viene, no se toca)'
);

-- Cada validación de forma, con su campo (sin ellas, la base guardaría «5» como nombre o «yes» como
-- true, o daría 22P02 o 23502, que la app toma por un corte de conexión).
select is(
  pg_temp.errors_of(array['{"name_es": 5}', '{"name_en": true}', '{"notes": ["x"]}']),
  array['22023: invalid_payload (name_es)', '22023: invalid_payload (name_en)', '22023: invalid_payload (notes)'],
  'los nombres traducidos y las notas son texto o null'
);
select is(
  pg_temp.errors_of(array['{"diet": "pescatarian"}', '{"diet": 1}']),
  array['22023: invalid_payload (diet)', '22023: invalid_payload (diet)'],
  'la dieta es vegetarian, vegan o null'
);
select is(
  pg_temp.errors_of(array['{"season_months": [1.5]}', '{"season_months": "1"}']),
  array['22023: invalid_payload (season_months)', '22023: invalid_payload (season_months)'],
  'los meses son una lista de enteros, o null'
);
select is(
  pg_temp.errors_of(array['{"freezer_days": null}', '{"freezer_days": "30"}', '{"freezer_days": 1.5}']),
  array['22023: invalid_payload (freezer_days)', '22023: invalid_payload (freezer_days)',
        '22023: invalid_payload (freezer_days)'],
  'los días del freezer son un entero (si no vienen, no se tocan)'
);
select is(
  pg_temp.errors_of(array['{"freezable": "true"}', '{"active": "yes"}', '{"catalog_visible": 1}', '{"active": null}']),
  array['22023: invalid_payload (freezable)', '22023: invalid_payload (active)',
        '22023: invalid_payload (catalog_visible)', '22023: invalid_payload (active)'],
  'freezable, active y catalog_visible son true o false'
);
select is(
  pg_temp.errors_of(array['{"ingredients": [{"quantity": 1, "unit": "g"}]}', '{"ingredients": [{"name": 5}]}',
                          '{"ingredients": [{"name": "Riso"}, {"name": null}]}']),
  array['22023: invalid_payload (ingredients[0].name)', '22023: invalid_payload (ingredients[0].name)',
        '22023: invalid_payload (ingredients[1].name)'],
  'cada ingrediente tiene nombre, y es texto'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
                        '{"months": [1, 2]}')) $$),
  '22023: invalid_payload (months)',
  'una clave que no conoce da error y dice cuál: ignorarla perdería el dato en silencio'
);
select is(
  pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
                        '{"ingredients": [{"name": "Riso", "shelf": "pantry"}]}')) $$),
  '22023: invalid_payload (ingredients[0].shelf)',
  'también dentro de un ingrediente'
);

-- La dieta contra los alérgenos (SPEC §5.6): cada dieta con cada uno de los 14, en un plato aparte
-- (los que valen se guardan).
select is(
  (select array_agg(format('%s + %s', d, a) order by d, a)
   from unnest(array['vegan', 'vegetarian']) as d, unnest(enum_range(null::public.allergen)) as a
   where pg_temp.error_of(format(
           $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-00000000000c',
                '{"diet": "%s", "allergens": ["%s"]}')) $$, d, a)) = '22023: invalid_payload (diet)'),
  array['vegan + crustaceans', 'vegan + eggs', 'vegan + fish', 'vegan + milk', 'vegan + molluscs',
        'vegetarian + crustaceans', 'vegetarian + fish', 'vegetarian + molluscs'],
  'la dieta no contradice los alérgenos: un plato vegano no lleva crustáceos, huevos, pescado, leche ni '
  'moluscos; uno vegetariano, ni crustáceos, ni pescado, ni moluscos (los otros alérgenos, sí)'
);
select is(
  array[
    pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
                          '{"allergens": ["molluscs"]}')) $$),
    pg_temp.error_of($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-00000000000b',
                          '{"diet": "vegan"}')) $$)
  ],
  array['22023: invalid_payload (diet)', '22023: invalid_payload (diet)'],
  'se mira la dieta que queda: la guardada (vegetariana) si no viene, y también en un plato nuevo'
);
select is(
  (select count(*)::int from public.recipes where id = '7e5c6000-0000-4000-8000-00000000000b'),
  0,
  'el plato nuevo que rechazó la dieta no queda creado'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001'),
  (select v from snap where k = 'r1'),
  'después de todos esos intentos el plato sigue igual'
);

-- =====================================================================
-- 8. Checks: meses, nombres, cantidades, unidades y orden
-- =====================================================================
-- Por save_recipe (C1).
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001', '{"season_months": [0]}')) $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_season_months_validos"',
  'mes 0: no existe'
);
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001', '{"season_months": [13]}')) $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_season_months_validos"',
  'mes 13: no existe'
);
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001', '{"season_months": [3, 3]}')) $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_season_months_validos"',
  'un mes repetido'
);
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001', '{"season_months": []}')) $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_season_months_validos"',
  'ningún mes: «todo el año» es null'
);
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001', '{"name_it": "   "}')) $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_it_valido"',
  'un nombre de plato vacío (solo espacios)'
);
select throws_ok(
  format($$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001', '{"name_it": "%s"}')) $$,
         repeat('x', 121)),
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_it_valido"',
  'un nombre de plato de más de 120 caracteres'
);
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001', '{"name_it": "\tProva"}')) $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_it_valido"',
  'un nombre con un tabulador (save_recipe recorta solo espacios: lo frena el check)'
);
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
       '{"ingredients": [{"name": "  ", "quantity": 1, "unit": "pcs"}]}')) $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_nombre_valido"',
  'un ingrediente sin nombre'
);
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001',
       jsonb_build_object('ingredients', (select jsonb_agg(jsonb_build_object('name', 'Spezia ' || n)) from generate_series(1, 51) as n)))) $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_posicion_valida"',
  'más de 50 ingredientes en un plato'
);

-- Escrituras directas (como postgres), sobre la receta de prueba de C1.
reset role;

select throws_ok(
  $$ update public.recipes set season_months = '{1,NULL}' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_season_months_validos"',
  'un mes null'
);
select throws_ok(
  $$ update public.recipes set season_months = '{{1,2},{3,4}}' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_season_months_validos"',
  'una matriz de meses'
);
select lives_ok(
  $$ update public.recipes set season_months = '{1,2,3,4,5,6,7,8,9,10,11,12}' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  'los doce meses, sin repetir, valen'
);
select throws_ok(
  $$ update public.recipes set name_es = '' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_es_valido"',
  'un nombre traducido vacío: sin traducción es null'
);
select throws_ok(
  $$ update public.recipes set name_en = repeat('x', 121) where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_en_valido"',
  'un nombre en inglés de más de 120 caracteres'
);
select throws_ok(
  $$ update public.recipes set name_it = ' Prova' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_it_valido"',
  'un nombre con espacios al borde'
);
select throws_ok(
  $$ update public.recipes set name_it = E'Prova\nbis' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_it_valido"',
  'un nombre con un salto de línea (rompería la lista copiada)'
);
select throws_ok(
  $$ update public.recipes set name_es = 'Prueba ' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_es_valido"',
  'un nombre en español con espacios al borde'
);
select throws_ok(
  $$ update public.recipes set name_es = E'Prueba\nbis' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_es_valido"',
  'un nombre en español con un salto de línea'
);
select throws_ok(
  $$ update public.recipes set name_en = 'Test ' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_en_valido"',
  'un nombre en inglés con espacios al borde'
);
select throws_ok(
  $$ update public.recipes set name_en = E'Test\tx' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
  '23514', 'new row for relation "recipes" violates check constraint "recipes_name_en_valido"',
  'un nombre en inglés con un tabulador'
);
select is(
  (select array_agg(m order by m) from generate_series(1, 12) as m
   where pg_temp.error_of(format(
           $$ update public.recipes set season_months = '{%s,%s}' where id = '7e5c6000-0000-4000-8000-000000000009' $$,
           m, m)) is null),
  null::int[],
  'ningún mes repetido vale (los doce, uno por uno)'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 1, '') $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_nombre_valido"',
  'nombre de ingrediente vacío'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 1, ' Sale') $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_nombre_valido"',
  'nombre con espacios al borde (save_recipe los recorta)'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 1, E'Sale\nfino') $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_nombre_valido"',
  'nombre con un salto de línea (rompería la lista copiada)'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 1, repeat('x', 81)) $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_nombre_valido"',
  'nombre de ingrediente de más de 80 caracteres'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name, quantity, unit)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 1, 'Burro', 0, 'g') $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_cantidad_valida"',
  'cantidad 0'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name, quantity, unit)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 1, 'Burro', -50, 'g') $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_cantidad_valida"',
  'cantidad negativa'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name, quantity, unit)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 1, 'Farina', 100001, 'g') $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_cantidad_valida"',
  'más de 100000 (100 kg para 4 porciones es un error de tipeo)'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name, quantity)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 1, 'Uova', 2) $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_cantidad_con_unidad"',
  'una cantidad sin unidad'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name, unit)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 1, 'Uova', 'pcs') $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_cantidad_con_unidad"',
  'una unidad sin cantidad'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 0, 'Sale') $$,
  '23514', 'new row for relation "recipe_ingredients" violates check constraint "recipe_ingredients_posicion_valida"',
  'el orden empieza en 1'
);
select lives_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name, section, quantity, unit) values
       ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 1, repeat('x', 80), 'pantry', 100000, 'g'),
       ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 2, 'Sale', 'pantry', null, null),
       ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', 50, 'Pepe', 'pantry', 1, 'g') $$,
  'en el borde valen: 80 caracteres, 100000 g, q.b. sin cantidad ni unidad y el ingrediente 50'
);
select throws_ok(
  $$ insert into public.recipe_notes (recipe_id, chef_id, notes)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', '') $$,
  '23514', 'new row for relation "recipe_notes" violates check constraint "recipe_notes_no_vacias"',
  'una nota vacía no es nota: sin notas, sin fila'
);
select throws_ok(
  $$ insert into public.recipe_notes (recipe_id, chef_id, notes)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001', ' Nota') $$,
  '23514', 'new row for relation "recipe_notes" violates check constraint "recipe_notes_no_vacias"',
  'una nota con espacios al borde (save_recipe los recorta)'
);
select lives_ok(
  $$ insert into public.recipe_notes (recipe_id, chef_id, notes)
     values ('7e5c6000-0000-4000-8000-000000000009', '7e5c1000-0000-4000-8000-000000000001',
             E'Costo 3,10 € a porzione.\nFornitore: Rossi.') $$,
  'una nota de varias líneas vale'
);

-- =====================================================================
-- 9. Otra cocinera no ve ni toca nada de C1
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e5c0000-0000-4000-8000-00000000c002","role":"authenticated"}';

select is(
  (select format('%s recetas, %s alérgenos, %s ingredientes, %s notas de C1; %s ingrediente propio',
     (select count(*) from public.recipes where chef_id = '7e5c1000-0000-4000-8000-000000000001'),
     (select count(*) from public.recipe_allergens where chef_id = '7e5c1000-0000-4000-8000-000000000001'),
     (select count(*) from public.recipe_ingredients where chef_id = '7e5c1000-0000-4000-8000-000000000001'),
     (select count(*) from public.recipe_notes where chef_id = '7e5c1000-0000-4000-8000-000000000001'),
     (select count(*) from public.recipe_ingredients))),
  '0 recetas, 0 alérgenos, 0 ingredientes, 0 notas de C1; 1 ingrediente propio',
  'C2 no ve recetas, alérgenos, ingredientes ni notas de C1; los suyos sí'
);
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-000000000001')) $$,
  'P0002', 'recipe_not_found',
  'C2 no puede guardar sobre un plato de C1 (el id existe, pero la RLS no se lo deja ver)'
);
select is_empty(
  $$ update public.recipes set name_it = 'Rubata' where id = '7e5c6000-0000-4000-8000-000000000001' returning id $$,
  'C2 no edita recetas de C1 (no las ve)'
);
select is_empty(
  $$ delete from public.recipes where id = '7e5c6000-0000-4000-8000-000000000002' returning id $$,
  'C2 no borra recetas de C1'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name)
     values ('7e5c6000-0000-4000-8000-000000000001', '7e5c1000-0000-4000-8000-000000000001', 9, 'Intruso') $$,
  '42501', null,
  'C2 no agrega ingredientes con el chef_id de C1'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name)
     values ('7e5c6000-0000-4000-8000-000000000001', '7e5c1000-0000-4000-8000-000000000002', 9, 'Intruso') $$,
  '23503', null,
  'ni con el suyo: la FK compuesta exige que la receta sea de la misma cocinera'
);
select is_empty(
  $$ update public.recipe_ingredients set quantity = 1 where recipe_id = '7e5c6000-0000-4000-8000-000000000001' returning position $$,
  'C2 no cambia ingredientes de C1'
);
select is_empty(
  $$ delete from public.recipe_ingredients where recipe_id = '7e5c6000-0000-4000-8000-000000000001' returning position $$,
  'C2 no borra ingredientes de C1'
);

reset role;
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001'),
  (select v from snap where k = 'r1'),
  'el plato de C1 sigue intacto'
);

-- =====================================================================
-- 10. Clienta A (de C1)
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e5c0000-0000-4000-8000-00000000a001","role":"authenticated"}';

select is(
  (select array_agg(name_it order by name_it) from public.recipes
   where id in ('7e5c6000-0000-4000-8000-000000000001', '7e5c6000-0000-4000-8000-000000000002',
                '7e5c6000-0000-4000-8000-000000000004', '7e5c6000-0000-4000-8000-000000000005')),
  null::text[],
  'A no ve ningún plato (RLS de la clienta cerrada): ni los del catálogo de su cocinera'
);
select is(
  (select count(*)::int from public.recipe_ingredients),
  0,
  'A no lee ingredientes (ni de los platos que sí ve)'
);
select is(
  (select array_agg(r.name_it || ': ' || coalesce((select n.notes from public.recipe_notes n where n.recipe_id = r.id),
                                                  'sin notas a la vista'))
   from public.recipes r where r.id = '7e5c6000-0000-4000-8000-000000000009'),
  null::text[],
  'A no ve el plato ni su nota: las notas son de la cocinera'
);
select is(
  (select count(*)::int from public.recipe_allergens
   where recipe_id in ('7e5c6000-0000-4000-8000-000000000004', '7e5c6000-0000-4000-8000-000000000005',
                       '7e5c6000-0000-4000-8000-0000000000f1')),
  0,
  'A no lee los alérgenos de un plato desactivado, de una receta de evento ni de otra cocinera'
);
select is(
  (select array_agg(allergen order by allergen)::text from public.recipe_allergens
   where recipe_id = '7e5c6000-0000-4000-8000-000000000001'),
  null::text,
  'ni los de un plato del catálogo de su cocinera'
);
select throws_ok(
  $$ select public.save_recipe(pg_temp.dish('7e5c6000-0000-4000-8000-0000000000a1')) $$,
  '42501', 'not_a_chef',
  'A no guarda platos'
);
select throws_ok(
  $$ insert into public.recipe_ingredients (recipe_id, chef_id, position, name)
     values ('7e5c6000-0000-4000-8000-000000000001', '7e5c1000-0000-4000-8000-000000000001', 9, 'Intruso') $$,
  '42501', null,
  'A no agrega ingredientes'
);

-- =====================================================================
-- 11. Anónimo
-- =====================================================================
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';

select throws_ok(
  $$ select * from public.recipe_ingredients $$,
  '42501', 'permission denied for table recipe_ingredients',
  'anon: no lee ingredientes'
);
select throws_ok(
  $$ select public.save_recipe('{}') $$,
  '42501', 'permission denied for function save_recipe',
  'anon: no ejecuta save_recipe'
);

-- =====================================================================
-- 12. Borrar: cascada si no se usó; restrict si está en un menú
-- =====================================================================
reset role;
insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, status) values
  ('7e5c4000-0000-4000-8000-00000000000a', '7e5c1000-0000-4000-8000-000000000001',
   '7e5c2000-0000-4000-8000-00000000000a', '2027-03-01', '10:00', 150, 'confirmed');
insert into public.session_menu (session_id, recipe_id, chef_id, portions, position) values
  ('7e5c4000-0000-4000-8000-00000000000a', '7e5c6000-0000-4000-8000-000000000001',
   '7e5c1000-0000-4000-8000-000000000001', 4, 1);

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e5c0000-0000-4000-8000-00000000c001","role":"authenticated"}';

select lives_ok(
  $$ delete from public.recipes where id = '7e5c6000-0000-4000-8000-000000000004' $$,
  'C1 borra un plato que nunca usó'
);
select throws_ok(
  $$ delete from public.recipes where id = '7e5c6000-0000-4000-8000-000000000001' $$,
  '23503', null,
  'un plato usado en un menú no se borra (session_menu: on delete restrict); se desactiva'
);
select lives_ok(
  $$ update public.recipes set active = false where id = '7e5c6000-0000-4000-8000-000000000001' $$,
  'C1 desactiva el plato usado'
);

reset role;
select is(
  (select count(*)::int from public.recipes where id = '7e5c6000-0000-4000-8000-000000000004')
  + (select count(*)::int from public.recipe_allergens where recipe_id = '7e5c6000-0000-4000-8000-000000000004')
  + (select count(*)::int from public.recipe_ingredients where recipe_id = '7e5c6000-0000-4000-8000-000000000004')
  + (select count(*)::int from public.recipe_notes where recipe_id = '7e5c6000-0000-4000-8000-000000000004'),
  0,
  'el borrado se llevó en cascada sus alérgenos, sus ingredientes y sus notas'
);
select is(
  pg_temp.saved('7e5c6000-0000-4000-8000-000000000001'),
  (select v from snap where k = 'r1') || '{"active": false}',
  'el usado sigue, desactivado, con sus alérgenos y sus ingredientes'
);

select finish();
rollback;
