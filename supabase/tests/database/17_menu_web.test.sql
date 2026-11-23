-- =====================================================================
-- Pestaña «Menù» del formulario de pedido, la base (migración 20261119150000_menu_web.sql):
--   * recipes: description_it, description_es y description_en (null, o de 1 a 200 caracteres,
--     sin espacios al borde ni caracteres de control). Un plato está publicado (sale en la web) si
--     está activo, visible en el catálogo y tiene descripción en italiano.
--   * save_recipe: las tres descripciones, opcionales, como name_es.
--   * public.get_public_menu(p_chef_id): los platos publicados de una cocinera, solo service_role.
--   * submit_public_request: p.wishes (hasta un plato por día) en requests.wishes, solo los
--     publicados de esa cocinera y en orden; devuelve además menu, también en el reintento.
--
-- C1 recibe los pedidos de la web y tiene el catálogo de prueba; C2 es otra cocinera, con un plato
-- publicado; C3 guarda sus platos con save_recipe, como la app (aparte, para no tocar el catálogo
-- de C1). A es clienta con cuenta de C1.
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

select plan(54);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e650000-0000-4000-8000-00000000c001', 'chef1@menu.test'),
  ('7e650000-0000-4000-8000-00000000c002', 'chef2@menu.test'),
  ('7e650000-0000-4000-8000-00000000c003', 'chef3@menu.test'),
  ('7e650000-0000-4000-8000-00000000a001', 'a@menu.test');
update public.profiles set role = 'chef'
where id in ('7e650000-0000-4000-8000-00000000c001', '7e650000-0000-4000-8000-00000000c002',
             '7e650000-0000-4000-8000-00000000c003');

insert into public.chefs (id, profile_id, display_name) values
  ('7e651000-0000-4000-8000-000000000001', '7e650000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e651000-0000-4000-8000-000000000002', '7e650000-0000-4000-8000-00000000c002', 'Chef Due'),
  ('7e651000-0000-4000-8000-000000000003', '7e650000-0000-4000-8000-00000000c003', 'Chef Tre');
insert into public.chef_settings (chef_id) values
  ('7e651000-0000-4000-8000-000000000001'),
  ('7e651000-0000-4000-8000-000000000002'),
  ('7e651000-0000-4000-8000-000000000003');

insert into public.clients (id, chef_id, profile_id, display_name, status) values
  ('7e652000-0000-4000-8000-00000000000a', '7e651000-0000-4000-8000-000000000001',
   '7e650000-0000-4000-8000-00000000a001', 'Cliente A', 'active');

-- El catálogo de C1. Publicados: 01, 02, 06, 0a y 0b. No publicados: 03 (desactivado), 04 (receta
-- de evento) y 05 (sin descripción en italiano, aunque la tenga en español). 0a y 0b se llaman igual
-- salvo la mayúscula: el orden los separa por id. f1 es de C2.
insert into public.recipes (id, chef_id, name_it, name_es, name_en, description_it, description_es, description_en,
                            diet, season_months, active, catalog_visible) values
  ('7e656000-0000-4000-8000-000000000001', '7e651000-0000-4000-8000-000000000001',
   'Lasagne alla bolognese', null, 'Lasagne Bolognese',
   'Ragù di manzo, besciamella e sfoglia all''uovo.', null, 'Beef ragù, béchamel and egg pasta.',
   null, null, true, true),
  ('7e656000-0000-4000-8000-000000000002', '7e651000-0000-4000-8000-000000000001',
   'minestrone di verdure', 'Minestrone de verduras', 'Vegetable minestrone',
   'Verdure di stagione e legumi.', 'Verduras de estación y legumbres.', 'Seasonal vegetables and pulses.',
   'vegan', '{11,10,12}', true, true),
  ('7e656000-0000-4000-8000-000000000003', '7e651000-0000-4000-8000-000000000001',
   'Brasato al vino rosso', null, null, 'Manzo cotto a lungo nel vino.', null, null,
   null, null, false, true),
  ('7e656000-0000-4000-8000-000000000004', '7e651000-0000-4000-8000-000000000001',
   'Vitello tonnato', null, null, 'Per il buffet di un evento.', null, null,
   null, null, true, false),
  ('7e656000-0000-4000-8000-000000000005', '7e651000-0000-4000-8000-000000000001',
   'Frittata di zucchine', 'Tortilla de zapallitos', null, null, 'Con huevos de granja.', null,
   'vegetarian', null, true, true),
  ('7e656000-0000-4000-8000-000000000006', '7e651000-0000-4000-8000-000000000001',
   'Polenta taragna', null, null, 'Grano saraceno e formaggio della Valtellina.', null, null,
   'vegetarian', '{1,2}', true, true),
  ('7e656000-0000-4000-8000-00000000000b', '7e651000-0000-4000-8000-000000000001',
   'Pasta e fagioli', null, null, 'Con i borlotti.', null, null,
   'vegan', null, true, true),
  ('7e656000-0000-4000-8000-00000000000a', '7e651000-0000-4000-8000-000000000001',
   'pasta e fagioli', null, null, 'Con i cannellini.', null, null,
   'vegan', null, true, true),
  ('7e656000-0000-4000-8000-0000000000f1', '7e651000-0000-4000-8000-000000000002',
   'Ossobuco', null, null, 'Con gremolata.', null, null,
   null, null, true, true);

-- Alérgenos fuera del orden del enum (la web los recibe en ese orden), ingredientes y notas (que
-- nunca salen en el menú).
insert into public.recipe_allergens (recipe_id, chef_id, allergen) values
  ('7e656000-0000-4000-8000-000000000001', '7e651000-0000-4000-8000-000000000001', 'milk'),
  ('7e656000-0000-4000-8000-000000000001', '7e651000-0000-4000-8000-000000000001', 'gluten'),
  ('7e656000-0000-4000-8000-000000000001', '7e651000-0000-4000-8000-000000000001', 'eggs'),
  ('7e656000-0000-4000-8000-000000000006', '7e651000-0000-4000-8000-000000000001', 'milk'),
  ('7e656000-0000-4000-8000-00000000000b', '7e651000-0000-4000-8000-000000000001', 'gluten'),
  ('7e656000-0000-4000-8000-00000000000a', '7e651000-0000-4000-8000-000000000001', 'gluten'),
  ('7e656000-0000-4000-8000-0000000000f1', '7e651000-0000-4000-8000-000000000002', 'celery');
insert into public.recipe_ingredients (recipe_id, chef_id, position, name, section, quantity, unit) values
  ('7e656000-0000-4000-8000-000000000001', '7e651000-0000-4000-8000-000000000001', 1,
   'Carne macinata', 'meat_fish', 400, 'g');
insert into public.recipe_notes (recipe_id, chef_id, notes) values
  ('7e656000-0000-4000-8000-000000000001', '7e651000-0000-4000-8000-000000000001', 'Il ragù cuoce 3 ore.');

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

-- El check que frena una sentencia como "SQLSTATE constraint", o null si no falla (el DETAIL de un
-- check trae la fila entera).
create function pg_temp.check_of(p_sql text) returns text
language plpgsql
as $$
declare
  v_constraint text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_constraint = constraint_name;
  return sqlstate || ' ' || coalesce(nullif(v_constraint, ''), sqlerrm);
end
$$;

-- Un plato válido de C3; p_extra pisa o agrega claves.
create function pg_temp.dish(p_extra jsonb default '{}') returns jsonb
language sql
as $$
  select jsonb_build_object(
    'id', '7e656000-0000-4000-8000-0000000000c1',
    'name_it', 'Lasagne alla bolognese',
    'allergens', jsonb_build_array('gluten', 'milk'),
    'ingredients', jsonb_build_array(jsonb_build_object('name', 'Sfoglia', 'section', 'pantry', 'quantity', 250, 'unit', 'g'))
  ) || p_extra
$$;

-- Las descripciones del plato de C3.
create function pg_temp.descriptions() returns jsonb
language sql
as $$
  select jsonb_build_object('it', r.description_it, 'es', r.description_es, 'en', r.description_en)
  from public.recipes r
  where r.id = '7e656000-0000-4000-8000-0000000000c1'
$$;

-- Los errores de guardar el plato de C3 con cada uno de p_extras encima (en orden).
create function pg_temp.save_errors(p_extras text[]) returns text[]
language sql
as $$
  select array_agg(pg_temp.error_of(format($f$ select public.save_recipe(pg_temp.dish(%L)) $f$, x.extra)) order by x.n)
  from unnest(p_extras) with ordinality as x(extra, n)
$$;

-- Payload como lo arma la Edge Function (snake_case), un pedido semanal de 7 días para C1, sin
-- wishes. p_extra pisa claves.
create function pg_temp.payload(p_extra jsonb default '{}') returns jsonb
language sql
as $$
  select jsonb_build_object(
    'chef_id', '7e651000-0000-4000-8000-000000000001',
    'type', 'week', 'adults', 2, 'kids', 0, 'days', 7, 'meals', jsonb_build_array('dinner'), 'weeks', 1,
    'no_allergies', true,
    'allergens', jsonb_build_array(), 'diets', jsonb_build_array(), 'restrictions_note', '',
    'preferred_date', null, 'preferred_slot', 'any',
    'name', 'Anna Bassi', 'zone', 'Borgo Palazzo', 'phone', '+393331234100', 'email', 'anna@menu.test',
    'whatsapp_opt_in', false, 'notes', '', 'locale', 'it',
    'privacy_consent_version', '2026-11-16', 'health_consent_version', null,
    'estimate', jsonb_build_object('portions', 14, 'recipes', 3, 'cookMinutes', 180)
  ) || p_extra
$$;

-- Respuestas de submit_public_request (los usuarios simulados también las leen).
create temp table res (k text primary key, r jsonb);
grant select, insert on res to anon, authenticated, service_role;

create function pg_temp.submit(p_key text, p jsonb) returns void
language sql
as $$
  insert into res (k, r) values (p_key, public.submit_public_request(p))
$$;

-- Los platos guardados de un pedido (requests.wishes).
create function pg_temp.wishes_of(p_key text) returns uuid[]
language sql
as $$
  select r.wishes from public.requests r where r.id = (select (x.r ->> 'request_id')::uuid from res x where x.k = p_key)
$$;

-- Los errores de enviar el pedido con cada uno de p_extras encima (en orden).
create function pg_temp.submit_errors(p_extras text[]) returns text[]
language sql
as $$
  select array_agg(pg_temp.error_of(format($f$ select public.submit_public_request(pg_temp.payload(%L)) $f$, x.extra))
                   order by x.n)
  from unnest(p_extras) with ordinality as x(extra, n)
$$;

-- =====================================================================
-- 1. recipes: descripción corta
-- =====================================================================
select is(
  (select array_agg(format('%s %s %s', c.column_name, c.data_type, c.is_nullable) order by c.column_name)
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'recipes' and c.column_name like 'description%'),
  array['description_en text YES', 'description_es text YES', 'description_it text YES'],
  'recipes: description_it, description_es y description_en, texto opcional'
);
select is(
  (select array_agg(k.conname::text order by k.conname)
   from pg_constraint k
   where k.conrelid = 'public.recipes'::regclass and k.contype = 'c' and k.conname like 'recipes_description%'),
  array['recipes_description_en_valida', 'recipes_description_es_valida', 'recipes_description_it_valida'],
  'un check por idioma, con el nombre del contrato'
);

-- Escrituras directas (como postgres) sobre el plato desactivado de C1.
select is(
  (select array_agg(pg_temp.check_of(format(
            $f$ update public.recipes set %I = %L where id = '7e656000-0000-4000-8000-000000000003' $f$, c, v))
          order by c, n)
   from unnest(array['description_en', 'description_es', 'description_it']) as c,
        unnest(array['', ' Manzo', 'Manzo ', E'Manzo\nal vino', E'Manzo\tal vino', repeat('x', 201)])
          with ordinality as t(v, n)),
  array['23514 recipes_description_en_valida', '23514 recipes_description_en_valida',
        '23514 recipes_description_en_valida', '23514 recipes_description_en_valida',
        '23514 recipes_description_en_valida', '23514 recipes_description_en_valida',
        '23514 recipes_description_es_valida', '23514 recipes_description_es_valida',
        '23514 recipes_description_es_valida', '23514 recipes_description_es_valida',
        '23514 recipes_description_es_valida', '23514 recipes_description_es_valida',
        '23514 recipes_description_it_valida', '23514 recipes_description_it_valida',
        '23514 recipes_description_it_valida', '23514 recipes_description_it_valida',
        '23514 recipes_description_it_valida', '23514 recipes_description_it_valida'],
  'en los tres idiomas, el check rechaza una descripción vacía (sin descripción es null), con espacios al borde, '
  'con un salto de línea o un tabulador, o de más de 200 caracteres'
);
select is(
  (select array_agg(format('%s %s: %s', c, n, x.e) order by c, n)
   from unnest(array['description_en', 'description_es', 'description_it']) as c,
        unnest(array[repeat('x', 200), 'Ragù, besciamella e sfoglia all''uovo: 3 ore di cottura.', null])
          with ordinality as t(v, n),
        lateral (select pg_temp.check_of(format(
                   $f$ update public.recipes set %I = %L where id = '7e656000-0000-4000-8000-000000000003' $f$, c, v)) as e) as x
   where x.e is not null),
  null::text[],
  'y deja 200 caracteres, una frase con acentos y puntuación, o null'
);

-- =====================================================================
-- 2. save_recipe con descripciones (C3, como la app)
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e650000-0000-4000-8000-00000000c003","role":"authenticated"}';

select is(
  public.save_recipe(pg_temp.dish('{"description_it": "  Ragù di manzo e besciamella. ", "description_es": ""}')),
  '7e656000-0000-4000-8000-0000000000c1'::uuid,
  'C3 crea un plato con descripción en italiano, la española vacía y sin la inglesa'
);
select is(
  pg_temp.descriptions(),
  '{"it": "Ragù di manzo e besciamella.", "es": null, "en": null}'::jsonb,
  'la italiana queda recortada; la vacía y la que no vino, null'
);
select lives_ok(
  $$ select public.save_recipe(pg_temp.dish('{"description_es": "Ragú de carne y bechamel.", "description_en": "Beef ragù and béchamel."}')) $$,
  'C3 agrega las descripciones en español e inglés, sin la clave description_it'
);
select is(
  pg_temp.descriptions(),
  '{"it": "Ragù di manzo e besciamella.", "es": "Ragú de carne y bechamel.", "en": "Beef ragù and béchamel."}'::jsonb,
  'cambian las que vinieron; la italiana, que no vino, no se toca'
);
select lives_ok(
  $$ select public.save_recipe(pg_temp.dish('{"name_it": "Lasagne verdi"}')) $$,
  'C3 vuelve a guardar el plato sin ninguna descripción (una versión de la app que no las conoce)'
);
select is(
  pg_temp.descriptions(),
  '{"it": "Ragù di manzo e besciamella.", "es": "Ragú de carne y bechamel.", "en": "Beef ragù and béchamel."}'::jsonb,
  'y las tres siguen como estaban'
);
select lives_ok(
  $$ select public.save_recipe(pg_temp.dish('{"description_es": "   ", "description_en": null}')) $$,
  'C3 borra la española (solo espacios) y la inglesa (null)'
);
select is(
  pg_temp.descriptions(),
  '{"it": "Ragù di manzo e besciamella.", "es": null, "en": null}'::jsonb,
  'solo espacios y null quedan null'
);
select is(
  pg_temp.save_errors(array['{"description_it": 5}', '{"description_es": true}', '{"description_en": ["x"]}',
                            '{"description_it": {"it": "x"}}', '{"description": "Ragù"}']),
  array['22023: invalid_payload (description_it)', '22023: invalid_payload (description_es)',
        '22023: invalid_payload (description_en)', '22023: invalid_payload (description_it)',
        '22023: invalid_payload (description)'],
  'una descripción que no es texto ni null es invalid_payload con la clave en el DETAIL (y description a secas es una clave desconocida)'
);
select is(
  array[
    pg_temp.check_of(format($f$ select public.save_recipe(pg_temp.dish('{"description_it": "%s"}')) $f$, repeat('x', 201))),
    pg_temp.check_of(format($f$ select public.save_recipe(pg_temp.dish('{"description_es": "%s"}')) $f$, repeat('x', 201))),
    pg_temp.check_of(format($f$ select public.save_recipe(pg_temp.dish('{"description_en": "%s"}')) $f$, repeat('x', 201))),
    pg_temp.check_of($f$ select public.save_recipe(pg_temp.dish('{"description_it": "Ragù\tdi manzo"}')) $f$)
  ],
  array['23514 recipes_description_it_valida', '23514 recipes_description_es_valida',
        '23514 recipes_description_en_valida', '23514 recipes_description_it_valida'],
  'más de 200 caracteres (o un tabulador: save_recipe recorta solo espacios) los frena el check del idioma'
);
select is(
  pg_temp.descriptions(),
  '{"it": "Ragù di manzo e besciamella.", "es": null, "en": null}'::jsonb,
  'después de esos intentos, las descripciones siguen igual'
);
select lives_ok(
  format($f$ select public.save_recipe(pg_temp.dish('{"description_it": "  %s "}')) $f$, repeat('x', 200)),
  '200 caracteres después de recortar valen'
);
reset role;

-- =====================================================================
-- 3. get_public_menu
-- =====================================================================
select ok(
  (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""']
          and pg_get_function_result(p.oid) = 'jsonb'
   from pg_proc p where p.oid = 'public.get_public_menu(uuid)'::regprocedure),
  'get_public_menu(uuid) devuelve jsonb: stable, security definer y search_path vacío'
);
select is(
  (select array_agg(r order by r)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, 'public.get_public_menu(uuid)', 'EXECUTE')),
  array['service_role'],
  'solo la ejecuta service_role (la Edge Function public-request)'
);

set local role service_role;
select is(
  public.get_public_menu('7e651000-0000-4000-8000-000000000001'),
  '[
    {"id": "7e656000-0000-4000-8000-000000000001",
     "name": {"it": "Lasagne alla bolognese", "es": null, "en": "Lasagne Bolognese"},
     "description": {"it": "Ragù di manzo, besciamella e sfoglia all''uovo.", "es": null, "en": "Beef ragù, béchamel and egg pasta."},
     "allergens": ["gluten", "eggs", "milk"], "diet": null, "seasonMonths": null, "photoId": null},
    {"id": "7e656000-0000-4000-8000-000000000002",
     "name": {"it": "minestrone di verdure", "es": "Minestrone de verduras", "en": "Vegetable minestrone"},
     "description": {"it": "Verdure di stagione e legumi.", "es": "Verduras de estación y legumbres.", "en": "Seasonal vegetables and pulses."},
     "allergens": [], "diet": "vegan", "seasonMonths": [10, 11, 12], "photoId": null},
    {"id": "7e656000-0000-4000-8000-00000000000a",
     "name": {"it": "pasta e fagioli", "es": null, "en": null},
     "description": {"it": "Con i cannellini.", "es": null, "en": null},
     "allergens": ["gluten"], "diet": "vegan", "seasonMonths": null, "photoId": null},
    {"id": "7e656000-0000-4000-8000-00000000000b",
     "name": {"it": "Pasta e fagioli", "es": null, "en": null},
     "description": {"it": "Con i borlotti.", "es": null, "en": null},
     "allergens": ["gluten"], "diet": "vegan", "seasonMonths": null, "photoId": null},
    {"id": "7e656000-0000-4000-8000-000000000006",
     "name": {"it": "Polenta taragna", "es": null, "en": null},
     "description": {"it": "Grano saraceno e formaggio della Valtellina.", "es": null, "en": null},
     "allergens": ["milk"], "diet": "vegetarian", "seasonMonths": [1, 2], "photoId": null}
  ]'::jsonb,
  'el menú de C1: solo los publicados (sin el desactivado, la receta de evento ni el que no tiene descripción '
  'en italiano), por nombre sin mayúsculas y después por id, con los alérgenos en el orden del enum, [] sin '
  'alérgenos, dieta null sin dieta, los meses en orden (null = todo el año) y photoId null sin foto '
  '(20261120100000_recipe_photos.sql)'
);
select is(
  (select array_agg(distinct k order by k)
   from jsonb_array_elements(public.get_public_menu('7e651000-0000-4000-8000-000000000001')) as d,
        jsonb_object_keys(d) as k),
  array['allergens', 'description', 'diet', 'id', 'name', 'photoId', 'seasonMonths'],
  'cada plato trae solo esas siete claves: nunca ingredientes ni notas'
);
select is(
  public.get_public_menu('7e651000-0000-4000-8000-000000000002') -> 0 -> 'name' ->> 'it'
    || ' · ' || jsonb_array_length(public.get_public_menu('7e651000-0000-4000-8000-000000000002')),
  'Ossobuco · 1',
  'el de C2 trae solo su plato: nunca los de otra cocinera'
);
select is(
  array[public.get_public_menu('7e651000-0000-4000-8000-0000000000ff'), public.get_public_menu(null)],
  array['[]'::jsonb, '[]'::jsonb],
  'una cocinera que no existe (o null) da un array vacío'
);
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e650000-0000-4000-8000-00000000c001","role":"authenticated"}';
select throws_ok(
  $$ select public.get_public_menu('7e651000-0000-4000-8000-000000000001') $$,
  '42501', 'permission denied for function get_public_menu',
  'authenticated no la ejecuta, ni la cocinera con su propio id'
);
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select throws_ok(
  $$ select public.get_public_menu('7e651000-0000-4000-8000-000000000001') $$,
  '42501', 'permission denied for function get_public_menu',
  'anon tampoco: la web la recibe por la Edge Function'
);
reset role;

-- La clienta no lee recetas por la API (RLS cerrada): la descripción le llega por Edge Functions.
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e650000-0000-4000-8000-00000000a001","role":"authenticated"}';
select is(
  (select array_agg(r.description_it order by r.id) from public.recipes r
   where r.id in ('7e656000-0000-4000-8000-000000000001', '7e656000-0000-4000-8000-000000000003')),
  null::text[],
  'A no lee la descripción de ningún plato por la API'
);
reset role;

-- =====================================================================
-- 4. submit_public_request con wishes
-- =====================================================================
select ok(
  (select p.prosecdef and p.proconfig = array['search_path=""']
          and has_function_privilege('service_role', p.oid, 'EXECUTE')
          and not has_function_privilege('anon', p.oid, 'EXECUTE')
          and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
   from pg_proc p where p.oid = 'public.submit_public_request(jsonb)'::regprocedure),
  'submit_public_request sigue igual: security definer, search_path vacío y solo service_role'
);
select is(
  (select array_agg(format('%s → %s', r, p.oid::regprocedure) order by 1)
   from pg_proc p
   cross join unnest(array['anon', 'authenticated', 'service_role']) as r
   where p.pronamespace = 'private'::regnamespace
     and p.proname = 'request_menu'
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  null::text[],
  'private.request_menu (el menu de la respuesta) no lo ejecuta ningún rol de la API'
);

set local role service_role;
select lives_ok(
  $$ select pg_temp.submit('sin_campo', pg_temp.payload()) $$,
  'sin wishes (la función de hoy): se guarda igual'
);
select lives_ok(
  $$ select pg_temp.submit('nulo', pg_temp.payload('{"wishes": null}')) $$,
  'wishes null: también'
);
select lives_ok(
  $$ select pg_temp.submit('vacio', pg_temp.payload('{"wishes": []}')) $$,
  'wishes []: también'
);
reset role;
select is(
  (select array_agg(format('%s: %s · %s', k, pg_temp.wishes_of(k), r -> 'menu') order by k)
   from res where k in ('sin_campo', 'nulo', 'vacio')),
  array['nulo: {} · []', 'sin_campo: {} · []', 'vacio: {} · []'],
  'sin platos elegidos: wishes {} y menu []'
);
select is(
  (select array_agg(c order by c) from jsonb_object_keys((select r from res where k = 'sin_campo')) as c),
  array['duplicate', 'estimate', 'menu', 'request_id'],
  'la respuesta suma menu a {request_id, duplicate, estimate}'
);

-- Siete días, siete platos: el desactivado (03), el de C2 (f1), la receta de evento (04) y el que no
-- tiene descripción en italiano (05) se descartan; el 01 llega en mayúsculas.
set local role service_role;
select lives_ok(
  $$ select pg_temp.submit('siete', pg_temp.payload('{"wishes": [
       "7e656000-0000-4000-8000-00000000000b", "7e656000-0000-4000-8000-000000000003",
       "7e656000-0000-4000-8000-0000000000f1", "7E656000-0000-4000-8000-000000000001",
       "7e656000-0000-4000-8000-000000000004", "7e656000-0000-4000-8000-000000000005",
       "7e656000-0000-4000-8000-000000000002"]}')) $$,
  'siete platos para siete días: se guarda aunque algunos ya no estén publicados'
);
reset role;
select is(
  pg_temp.wishes_of('siete'),
  array['7e656000-0000-4000-8000-00000000000b', '7e656000-0000-4000-8000-000000000001',
        '7e656000-0000-4000-8000-000000000002']::uuid[],
  'guarda solo los publicados de C1, en el orden en que llegaron'
);
select is(
  (select r -> 'menu' from res where k = 'siete'),
  '[{"id": "7e656000-0000-4000-8000-00000000000b", "name": {"it": "Pasta e fagioli", "es": null, "en": null}},
    {"id": "7e656000-0000-4000-8000-000000000001", "name": {"it": "Lasagne alla bolognese", "es": null, "en": "Lasagne Bolognese"}},
    {"id": "7e656000-0000-4000-8000-000000000002", "name": {"it": "minestrone di verdure", "es": "Minestrone de verduras", "en": "Vegetable minestrone"}}]'::jsonb,
  'y devuelve menu: los guardados, en orden, con sus nombres'
);

set local role service_role;
select lives_ok(
  $$ select pg_temp.submit('ninguno', pg_temp.payload('{"days": 1, "wishes": ["7e656000-0000-4000-8000-0000000000ee"]}')) $$,
  'un plato que no existe: el pedido se guarda igual'
);
select lives_ok(
  $$ select pg_temp.submit('otra', pg_temp.payload('{"chef_id": "7e651000-0000-4000-8000-000000000002", "days": 2,
       "wishes": ["7e656000-0000-4000-8000-000000000001", "7e656000-0000-4000-8000-0000000000f1"]}')) $$,
  'un pedido para C2 con un plato de C1 y uno suyo'
);
reset role;
select is(
  array[format('%s · %s', pg_temp.wishes_of('ninguno'), (select r -> 'menu' from res where k = 'ninguno')),
        format('%s · %s', pg_temp.wishes_of('otra'), (select r -> 'menu' -> 0 -> 'name' ->> 'it' from res where k = 'otra'))],
  array['{} · []', '{7e656000-0000-4000-8000-0000000000f1} · Ossobuco'],
  'el que no existe se descarta (wishes {}, menu []); en el de C2 queda solo su plato'
);

-- Defensa (la Edge Function valida antes): invalid_wishes (22023).
select is(
  pg_temp.submit_errors(array[
    '{"wishes": "7e656000-0000-4000-8000-000000000001"}',
    '{"wishes": {"id": "7e656000-0000-4000-8000-000000000001"}}',
    '{"wishes": 5}',
    '{"wishes": true}'
  ]),
  array['22023: invalid_wishes', '22023: invalid_wishes', '22023: invalid_wishes', '22023: invalid_wishes'],
  'wishes que no es un array (un texto, un objeto, un número o un booleano): invalid_wishes'
);
select is(
  pg_temp.submit_errors(array[
    '{"wishes": [5]}',
    '{"wishes": [null]}',
    '{"wishes": [["7e656000-0000-4000-8000-000000000001"]]}',
    '{"wishes": ["lasagne"]}',
    '{"wishes": ["7e656000000040008000000000000001"]}',
    '{"wishes": ["{7e656000-0000-4000-8000-000000000001}"]}',
    '{"wishes": ["7e656000-0000-4000-8000-000000000001", "7e656000-0000-4000-8000-00000000000g"]}'
  ]),
  array['22023: invalid_wishes', '22023: invalid_wishes', '22023: invalid_wishes', '22023: invalid_wishes',
        '22023: invalid_wishes', '22023: invalid_wishes', '22023: invalid_wishes'],
  'un elemento que no es un uuid en texto (un número, null, un array, un nombre, sin guiones, entre llaves o con una letra que no es hexadecimal)'
);
select is(
  pg_temp.submit_errors(array[
    '{"wishes": ["7e656000-0000-4000-8000-000000000001", "7e656000-0000-4000-8000-000000000001"]}',
    '{"wishes": ["7e656000-0000-4000-8000-000000000001", "7E656000-0000-4000-8000-000000000001"]}',
    '{"wishes": ["7e656000-0000-4000-8000-0000000000ee", "7e656000-0000-4000-8000-0000000000ee"]}'
  ]),
  array['22023: invalid_wishes', '22023: invalid_wishes', '22023: invalid_wishes'],
  'un plato repetido (también en mayúsculas, o uno que se descartaría)'
);
select is(
  pg_temp.submit_errors(array[
    '{"days": 2, "wishes": ["7e656000-0000-4000-8000-000000000001", "7e656000-0000-4000-8000-000000000002",
                            "7e656000-0000-4000-8000-000000000006"]}',
    '{"days": 1, "wishes": ["7e656000-0000-4000-8000-0000000000ee", "7e656000-0000-4000-8000-0000000000ef"]}',
    '{"type": "extra", "adults": 8, "days": 1, "wishes": ["7e656000-0000-4000-8000-000000000001",
                                                          "7e656000-0000-4000-8000-000000000002"]}'
  ]),
  array['22023: invalid_wishes', '22023: invalid_wishes', '22023: invalid_wishes'],
  'más platos que días (también si se descartarían, y en un evento de un día)'
);
select is(
  (select count(*)::int from public.requests r where r.contact ->> 'email' = 'anna@menu.test'),
  6,
  'los rechazos no guardan nada: siguen los 6 pedidos de Anna'
);
set local role service_role;
select lives_ok(
  $$ select pg_temp.submit('tope', pg_temp.payload('{"days": 2, "wishes": ["7e656000-0000-4000-8000-000000000006",
       "7e656000-0000-4000-8000-000000000001"]}')) $$,
  'tantos platos como días: vale'
);
reset role;
select is(
  pg_temp.wishes_of('tope'),
  array['7e656000-0000-4000-8000-000000000006', '7e656000-0000-4000-8000-000000000001']::uuid[],
  'y se guardan los dos, en orden'
);

-- Reintento: devuelve el menu de lo guardado, con los nombres de hoy.
set local role service_role;
select lives_ok(
  $$ select pg_temp.submit('clave', pg_temp.payload(
       '{"email": "carla@menu.test", "name": "Carla Vitali", "days": 5,
         "request_key": "5b0c7a52-1d2e-4f3a-9b8c-0d1e2f3a4b5c",
         "wishes": ["7e656000-0000-4000-8000-000000000006", "7e656000-0000-4000-8000-000000000001"]}')) $$,
  'Carla elige dos platos, con clave de idempotencia'
);
select lives_ok(
  $$ select pg_temp.submit('clave_otra_vez', pg_temp.payload(
       '{"email": "carla@menu.test", "name": "Carla Vitali", "days": 5,
         "request_key": "5b0c7a52-1d2e-4f3a-9b8c-0d1e2f3a4b5c",
         "wishes": ["7e656000-0000-4000-8000-000000000002"]}')) $$,
  'el reintento con la misma clave elige otro plato'
);
reset role;
select is(
  (select format('%s · %s', r ->> 'duplicate', (r -> 'menu' = (select x.r -> 'menu' from res x where x.k = 'clave'))::text)
   from res where k = 'clave_otra_vez'),
  'true · true',
  'es un duplicado y devuelve el menu de lo guardado (no lo del reintento)'
);
select is(
  pg_temp.wishes_of('clave'),
  array['7e656000-0000-4000-8000-000000000006', '7e656000-0000-4000-8000-000000000001']::uuid[],
  'y lo guardado no cambia'
);

-- C1 cambia el nombre de uno y desactiva el otro (como postgres).
update public.recipes set name_it = 'Lasagne verdi' where id = '7e656000-0000-4000-8000-000000000001';
update public.recipes set active = false where id = '7e656000-0000-4000-8000-000000000006';
select is(
  public.submit_public_request(pg_temp.payload(
    '{"email": "carla@menu.test", "name": "Carla Vitali", "days": 5,
      "request_key": "5b0c7a52-1d2e-4f3a-9b8c-0d1e2f3a4b5c"}')) -> 'menu',
  '[{"id": "7e656000-0000-4000-8000-000000000006", "name": {"it": "Polenta taragna", "es": null, "en": null}},
    {"id": "7e656000-0000-4000-8000-000000000001", "name": {"it": "Lasagne verdi", "es": null, "en": "Lasagne Bolognese"}}]'::jsonb,
  'otro reintento: el menu sale de lo guardado, con los nombres de hoy (también el plato que ya no está publicado)'
);
-- La cocinera puede borrar un plato que nunca usó en un menú (14_recipe_catalog): un reintento
-- posterior lo omite.
delete from public.recipes where id = '7e656000-0000-4000-8000-000000000006';
select is(
  public.submit_public_request(pg_temp.payload(
    '{"email": "carla@menu.test", "name": "Carla Vitali", "days": 5,
      "request_key": "5b0c7a52-1d2e-4f3a-9b8c-0d1e2f3a4b5c"}')) -> 'menu',
  '[{"id": "7e656000-0000-4000-8000-000000000001", "name": {"it": "Lasagne verdi", "es": null, "en": "Lasagne Bolognese"}}]'::jsonb,
  'si un plato guardado se borró después, el menu del reintento lo omite'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload(
       '{"email": "carla@menu.test", "name": "Carla Vitali", "days": 5,
         "request_key": "5b0c7a52-1d2e-4f3a-9b8c-0d1e2f3a4b5c", "wishes": ["lasagne"]}')) $$,
  '22023', 'invalid_wishes',
  'un reintento con wishes inválido falla igual (se valida antes de buscar la clave)'
);

-- El aviso a la cocinera sigue llevando solo el id del pedido.
select is(
  (select array_agg(distinct c order by c)
   from public.notifications n, jsonb_object_keys(n.payload) as c
   where n.payload ->> 'request_id' in (select r ->> 'request_id' from res)),
  array['request_id'],
  'el payload del aviso a la cocinera sigue siendo {request_id}'
);

-- Una cocinera sin platos publicados (como Evelyn al desplegar, sin descripciones).
update public.recipes set description_it = null where id = '7e656000-0000-4000-8000-0000000000f1';
set local role service_role;
select is(
  public.get_public_menu('7e651000-0000-4000-8000-000000000002'),
  '[]'::jsonb,
  'C2 sin descripción en su único plato: menú vacío'
);
reset role;

select finish();
rollback;
