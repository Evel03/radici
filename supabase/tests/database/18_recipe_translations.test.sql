-- =====================================================================
-- Traducción automática de los platos, la base (migración 20261120090000_recipe_translations.sql):
--   * recipes.auto_translated: los campos de destino (name_it, description_it, name_en,
--     description_en) que llenó el traductor y Evelyn no tocó a mano. Sin repetir, nunca el
--     español (es la fuente) y ninguno marcado sin texto en la fila.
--   * save_recipe: la clave opcional auto_translated. Sin ella, ninguno (una app que no la conoce
--     guarda todo como escrito a mano); un valor fuera de la lista, repetido, de otro tipo o un campo
--     marcado que no llega con texto es invalid_payload.
--
-- C1 guarda sus platos con save_recipe, como la app.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(25);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e670000-0000-4000-8000-00000000c001', 'chef1@traduzioni.test');
update public.profiles set role = 'chef' where id = '7e670000-0000-4000-8000-00000000c001';
insert into public.chefs (id, profile_id, display_name) values
  ('7e671000-0000-4000-8000-000000000001', '7e670000-0000-4000-8000-00000000c001', 'Chef Uno');
insert into public.chef_settings (chef_id) values ('7e671000-0000-4000-8000-000000000001');

-- Un plato cargado antes de la migración (sin la columna en el insert) y otro con todos los textos.
insert into public.recipes (id, chef_id, name_it, name_es, name_en, description_it, description_es, description_en) values
  ('7e676000-0000-4000-8000-000000000001', '7e671000-0000-4000-8000-000000000001',
   'Empanadas di carne', 'Empanadas de carne', null, null, 'Al horno, con carne cortada a cuchillo.', null),
  ('7e676000-0000-4000-8000-000000000002', '7e671000-0000-4000-8000-000000000001',
   'Lasagne alla bolognese', 'Lasaña a la boloñesa', 'Lasagne Bolognese',
   'Ragù di manzo e besciamella.', 'Ragú de carne y bechamel.', 'Beef ragù and béchamel.');

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

-- Los checks que frenan poner auto_translated = cada uno de p_values en el plato p_recipe.
create function pg_temp.update_checks(p_recipe uuid, p_values text[]) returns text[]
language sql
as $$
  select array_agg(pg_temp.check_of(format(
           $f$ update public.recipes set auto_translated = %L where id = %L $f$, x.v, p_recipe)) order by x.n)
  from unnest(p_values) with ordinality as x(v, n)
$$;

-- Un plato válido de C1 con los textos en los tres idiomas; p_extra pisa o agrega claves.
create function pg_temp.dish(p_extra jsonb default '{}') returns jsonb
language sql
as $$
  select jsonb_build_object(
    'id', '7e676000-0000-4000-8000-0000000000c1',
    'name_it', 'Milanese alla napoletana',
    'name_es', 'Milanesa a la napolitana',
    'name_en', 'Neapolitan-style milanese',
    'description_it', 'Con pomodoro, prosciutto cotto e mozzarella.',
    'description_es', 'Con salsa de tomate, jamón y muzzarella.',
    'description_en', 'With tomato, ham and mozzarella.',
    'allergens', jsonb_build_array('gluten', 'milk', 'eggs'),
    'ingredients', jsonb_build_array()
  ) || p_extra
$$;

-- auto_translated del plato de C1.
create function pg_temp.auto_of(p_id uuid default '7e676000-0000-4000-8000-0000000000c1') returns text[]
language sql
as $$
  select r.auto_translated from public.recipes r where r.id = p_id
$$;

-- Los errores de guardar el plato de C1 con cada uno de p_extras encima (en orden).
create function pg_temp.save_errors(p_extras text[]) returns text[]
language sql
as $$
  select array_agg(pg_temp.error_of(format($f$ select public.save_recipe(pg_temp.dish(%L)) $f$, x.extra)) order by x.n)
  from unnest(p_extras) with ordinality as x(extra, n)
$$;

-- =====================================================================
-- 1. recipes.auto_translated
-- =====================================================================
select is(
  (select format('%s %s %s %s', c.data_type, c.udt_name, c.is_nullable, c.column_default)
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'recipes' and c.column_name = 'auto_translated'),
  'ARRAY _text NO ''{}''::text[]',
  'recipes.auto_translated: text[] not null, vacío por defecto'
);
select is(
  (select array_agg(k.conname::text order by k.conname)
   from pg_constraint k
   where k.conrelid = 'public.recipes'::regclass and k.contype = 'c' and k.conname like 'recipes_auto_translated%'),
  array['recipes_auto_translated_con_texto', 'recipes_auto_translated_valido'],
  'dos checks: la lista y que lo marcado tenga texto'
);
select is(
  (select array_agg(r.auto_translated::text order by r.id) from public.recipes r
   where r.id in ('7e676000-0000-4000-8000-000000000001', '7e676000-0000-4000-8000-000000000002')),
  array['{}', '{}'],
  'un plato guardado sin la columna queda sin marcas: escrito a mano'
);

-- Escrituras directas (como postgres) sobre el plato con todos los textos.
select is(
  pg_temp.update_checks('7e676000-0000-4000-8000-000000000002',
    array['{name_es}', '{description_es}', '{name}', '{NAME_IT}', '{name_it,name_it}',
          '{name_en,description_en,name_en}', '{NULL}', '{name_it,NULL}']),
  array['23514 recipes_auto_translated_valido', '23514 recipes_auto_translated_valido',
        '23514 recipes_auto_translated_valido', '23514 recipes_auto_translated_valido',
        '23514 recipes_auto_translated_valido', '23514 recipes_auto_translated_valido',
        '23514 recipes_auto_translated_valido', '23514 recipes_auto_translated_valido'],
  'el check rechaza el español (es la fuente), un campo que no existe, mayúsculas, repetidos y elementos null'
);
select is(
  pg_temp.update_checks('7e676000-0000-4000-8000-000000000002',
    array['{}', '{name_it}', '{description_en,name_it}', '{name_it,description_it,name_en,description_en}']),
  array[null, null, null, null]::text[],
  'y deja ninguno, uno, varios en cualquier orden o los cuatro, si tienen texto'
);
select is(
  pg_temp.update_checks('7e676000-0000-4000-8000-000000000001',
    array['{name_en}', '{description_it}', '{description_en}', '{name_it,name_en}', '{name_it}']),
  array['23514 recipes_auto_translated_con_texto', '23514 recipes_auto_translated_con_texto',
        '23514 recipes_auto_translated_con_texto', '23514 recipes_auto_translated_con_texto', null],
  'un campo marcado tiene que tener texto en la fila (las empanadas no tienen inglés ni descripción italiana)'
);
select is(
  array[
    pg_temp.check_of($f$ update public.recipes set description_en = null where id = '7e676000-0000-4000-8000-000000000002' $f$),
    pg_temp.check_of($f$ update public.recipes set name_en = null, auto_translated = '{name_it}' where id = '7e676000-0000-4000-8000-000000000002' $f$)
  ],
  array['23514 recipes_auto_translated_con_texto', null],
  'borrar el texto de un campo marcado lo frena el check; sacándolo de la lista a la vez, pasa'
);

-- =====================================================================
-- 2. save_recipe con auto_translated (C1, como la app)
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e670000-0000-4000-8000-00000000c001","role":"authenticated"}';

select lives_ok(
  $$ select public.save_recipe(pg_temp.dish()) $$,
  'C1 crea un plato sin la clave auto_translated'
);
select is(pg_temp.auto_of(), '{}'::text[], 'sin la clave, ninguno: todo escrito a mano');

select lives_ok(
  $$ select public.save_recipe(pg_temp.dish('{"auto_translated": ["description_en", "name_it", "name_en"]}')) $$,
  'C1 lo guarda con tres campos que llenó el traductor, en cualquier orden'
);
select is(
  pg_temp.auto_of(),
  array['name_it', 'name_en', 'description_en'],
  'quedan en el orden de los campos: name_it, description_it, name_en, description_en'
);
select lives_ok(
  $$ select public.save_recipe(pg_temp.dish('{"auto_translated": ["name_it", "description_it", "name_en", "description_en"]}')) $$,
  'C1 marca los cuatro'
);
select is(
  pg_temp.auto_of(),
  array['name_it', 'description_it', 'name_en', 'description_en'],
  'los cuatro'
);
select lives_ok(
  $$ select public.save_recipe(pg_temp.dish('{"auto_translated": ["name_en"], "name_en": "  Milanese Neapolitan style "}')) $$,
  'Evelyn corrige tres a mano: queda uno, con su texto recortado'
);
select is(
  (select format('%s | %s', r.auto_translated, r.name_en) from public.recipes r where r.id = '7e676000-0000-4000-8000-0000000000c1'),
  '{name_en} | Milanese Neapolitan style',
  'la lista reemplaza a la anterior entera'
);
select lives_ok(
  $$ select public.save_recipe(pg_temp.dish('{"auto_translated": []}')) $$,
  'C1 lo guarda con la lista vacía'
);
select is(pg_temp.auto_of(), '{}'::text[], 'la lista vacía: ninguno');

select lives_ok(
  $$ select public.save_recipe(pg_temp.dish('{"auto_translated": ["name_it"]}')) $$,
  'C1 marca name_it'
);
select lives_ok(
  $$ select public.save_recipe(pg_temp.dish()) $$,
  'una app que no conoce la clave vuelve a guardar el plato'
);
select is(pg_temp.auto_of(), '{}'::text[], 'y lo deja sin marcas: lo que no se sabe si es del traductor cuenta como escrito a mano');

select is(
  pg_temp.save_errors(array[
    '{"auto_translated": "name_it"}', '{"auto_translated": null}', '{"auto_translated": {"name_it": true}}',
    '{"auto_translated": ["name_es"]}', '{"auto_translated": ["name_it", "description_es"]}',
    '{"auto_translated": ["NAME_IT"]}', '{"auto_translated": ["name_it", "name_it"]}',
    '{"auto_translated": ["name_en", 5]}', '{"auto_translated": [null]}', '{"auto_translated": [["name_it"]]}',
    '{"auto_translated": ["description_it"], "description_it": null}',
    '{"auto_translated": ["description_it"], "description_it": "   "}',
    '{"auto_translated": ["name_en", "description_en"], "description_en": ""}',
    '{"auto_translated": ["name_it"], "name_it": " "}']),
  array['22023: invalid_payload (auto_translated)', '22023: invalid_payload (auto_translated)',
        '22023: invalid_payload (auto_translated)', '22023: invalid_payload (auto_translated[0])',
        '22023: invalid_payload (auto_translated[1])', '22023: invalid_payload (auto_translated[0])',
        '22023: invalid_payload (auto_translated[1])', '22023: invalid_payload (auto_translated[1])',
        '22023: invalid_payload (auto_translated[0])', '22023: invalid_payload (auto_translated[0])',
        '22023: invalid_payload (auto_translated[0])', '22023: invalid_payload (auto_translated[0])',
        '22023: invalid_payload (auto_translated[1])', '22023: invalid_payload (auto_translated[0])'],
  'invalid_payload con el elemento en el DETAIL: no es una lista, el español, otro campo, mayúsculas, '
  'repetido, otro tipo, o un campo marcado que llega null, vacío o con solo espacios'
);
select is(
  pg_temp.error_of($f$ select public.save_recipe(pg_temp.dish('{"auto_translated": ["description_it"]}') - 'description_it') $f$),
  '22023: invalid_payload (auto_translated[0])',
  'un campo marcado que no viene en p también: al actualizar, el texto guardado puede no ser el traducido'
);

-- Duplicar es guardar con un id nuevo, sin las descripciones de la web (SPEC §4): la copia no puede
-- llevar las marcas de las descripciones.
select is(
  array[
    pg_temp.error_of($f$ select public.save_recipe(pg_temp.dish(jsonb_build_object(
      'id', '7e676000-0000-4000-8000-0000000000c2', 'description_it', null, 'description_es', null, 'description_en', null,
      'auto_translated', jsonb_build_array('name_it', 'description_it')))) $f$),
    pg_temp.error_of($f$ select public.save_recipe(pg_temp.dish(jsonb_build_object(
      'id', '7e676000-0000-4000-8000-0000000000c2', 'description_it', null, 'description_es', null, 'description_en', null,
      'auto_translated', jsonb_build_array('name_it', 'name_en')))) $f$)
  ],
  array['22023: invalid_payload (auto_translated[1])', null],
  'una copia sin descripciones no puede marcar una descripción; los nombres copiados, sí'
);
select is(
  array[pg_temp.auto_of()::text, pg_temp.auto_of('7e676000-0000-4000-8000-0000000000c2')::text],
  array['{}', '{name_it,name_en}'],
  'después de los intentos fallidos el original sigue sin marcas, y la copia guarda las suyas'
);
reset role;

select ok(
  has_function_privilege('authenticated', 'public.save_recipe(jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.save_recipe(jsonb)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.save_recipe(jsonb)', 'EXECUTE')
  and (select not p.prosecdef and p.proconfig @> array['search_path=""']
       from pg_proc p where p.oid = 'public.save_recipe(jsonb)'::regprocedure),
  'save_recipe sigue siendo security invoker, con search_path vacío y solo para authenticated'
);

select finish();
rollback;
