-- =====================================================================
-- Menú de la web con los nombres de los ingredientes (migración 20261125100000_public_menu_ingredient_names.sql).
--   * get_public_menu trae `ingredients` en cada plato: solo los nombres, como los escribió la cocinera,
--     recortados, sin repetir sin distinguir mayúsculas (queda el primero), en el orden del plato (position)
--     y hasta 40; [] sin ingredientes (la clave está siempre).
--   * Nunca cantidades, unidades, secciones ni notas.
--   * Estructural: lee los nombres de private.recipe_ingredient_names y los corta en 40.
--   * Privilegios: solo service_role la ejecuta (anon y authenticated no).
-- Corre como postgres (el dueño de las funciones); service_role se prueba con set local role.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(9);

insert into auth.users (id, email) values ('7e6e0000-0000-4000-8000-00000000c001', 'chef@ingredientes.test');
update public.profiles set role = 'chef' where id = '7e6e0000-0000-4000-8000-00000000c001';
insert into public.chefs (id, profile_id, display_name) values
  ('7e6e1000-0000-4000-8000-000000000001', '7e6e0000-0000-4000-8000-00000000c001', 'Evelyn');
insert into public.chef_settings (chef_id) values ('7e6e1000-0000-4000-8000-000000000001');

-- P1: ingredientes cargados en desorden (manda position), con uno repetido con otra mayúscula, cantidades que
-- se buscan fácil (437, 523, 1019) y una nota interna. P2: sin ingredientes. P3: 45 ingredientes.
insert into public.recipes (id, chef_id, name_it, description_it) values
  ('7e6e6000-0000-4000-8000-000000000001', '7e6e1000-0000-4000-8000-000000000001', 'Lasagne', 'Al ragù'),
  ('7e6e6000-0000-4000-8000-000000000002', '7e6e1000-0000-4000-8000-000000000001', 'Minestrone', 'Di verdure'),
  ('7e6e6000-0000-4000-8000-000000000003', '7e6e1000-0000-4000-8000-000000000001', 'Zuppa', 'Con tutto');
insert into public.recipe_ingredients (recipe_id, chef_id, position, name, section, quantity, unit) values
  ('7e6e6000-0000-4000-8000-000000000001', '7e6e1000-0000-4000-8000-000000000001', 3, 'Carne de res', 'meat_fish', 437, 'g'),
  ('7e6e6000-0000-4000-8000-000000000001', '7e6e1000-0000-4000-8000-000000000001', 1, 'Pasta all''uovo', 'pantry', 523, 'g'),
  ('7e6e6000-0000-4000-8000-000000000001', '7e6e1000-0000-4000-8000-000000000001', 4, 'sal', 'pantry', null, null),
  ('7e6e6000-0000-4000-8000-000000000001', '7e6e1000-0000-4000-8000-000000000001', 2, 'Sal', 'pantry', null, null),
  ('7e6e6000-0000-4000-8000-000000000001', '7e6e1000-0000-4000-8000-000000000001', 5, 'Leche', 'dairy_eggs', 1019, 'ml');
insert into public.recipe_notes (recipe_id, chef_id, notes) values
  ('7e6e6000-0000-4000-8000-000000000001', '7e6e1000-0000-4000-8000-000000000001', 'NOTA-INTERNA-xyz');
insert into public.recipe_ingredients (recipe_id, chef_id, position, name, section)
select '7e6e6000-0000-4000-8000-000000000003', '7e6e1000-0000-4000-8000-000000000001', g, 'Ingrediente ' || g, 'other'
from generate_series(1, 45) as g;

set local role service_role;
select is(
  (select d -> 'ingredients' from jsonb_array_elements(public.get_public_menu('7e6e1000-0000-4000-8000-000000000001')) as d
   where d ->> 'id' = '7e6e6000-0000-4000-8000-000000000001'),
  '["Pasta all''uovo", "Sal", "Carne de res", "Leche"]'::jsonb,
  'los nombres como los escribió la cocinera, en el orden del plato y sin repetir sin distinguir mayúsculas (queda el primero)'
);
select is(
  (select d -> 'ingredients' from jsonb_array_elements(public.get_public_menu('7e6e1000-0000-4000-8000-000000000001')) as d
   where d ->> 'id' = '7e6e6000-0000-4000-8000-000000000002'),
  '[]'::jsonb,
  'un plato sin ingredientes trae [] (la clave está siempre)'
);
select is(
  (select jsonb_array_length(d -> 'ingredients') || ' · ' || (d -> 'ingredients' ->> 0) || ' · ' || (d -> 'ingredients' ->> 39)
   from jsonb_array_elements(public.get_public_menu('7e6e1000-0000-4000-8000-000000000001')) as d
   where d ->> 'id' = '7e6e6000-0000-4000-8000-000000000003'),
  '40 · Ingrediente 1 · Ingrediente 40',
  'hasta 40 nombres, los primeros del plato'
);
select is(
  (select bool_or(jsonb_typeof(i) <> 'string')
   from jsonb_array_elements(public.get_public_menu('7e6e1000-0000-4000-8000-000000000001')) as d,
        jsonb_array_elements(d -> 'ingredients') as i),
  false,
  'cada ingrediente es un texto: sin objetos con cantidad, unidad ni sección'
);
select is(
  (select count(*)
   from regexp_matches(public.get_public_menu('7e6e1000-0000-4000-8000-000000000001')::text,
                       '437|523|1019|meat_fish|pantry|dairy_eggs|NOTA-INTERNA|"quantity"|"unit"|"section"|"notes"', 'g')),
  0::bigint,
  'ni cantidades, ni unidades, ni secciones, ni la nota del plato aparecen en el menú'
);
reset role;

select ok(
  (select p.prosrc ~ 'private\.recipe_ingredient_names\(r\.id\)' and p.prosrc ~ 't\.n <= 40'
          and p.prosrc !~* 'recipe_notes' and p.prosrc !~* '\.(quantity|unit|section)\M'
   from pg_proc p where p.oid = 'public.get_public_menu(uuid)'::regprocedure),
  'estructural: los nombres salen de private.recipe_ingredient_names, cortados en 40, sin leer notas, cantidades, unidades ni secciones'
);
select ok(
  (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""']
   from pg_proc p where p.oid = 'public.get_public_menu(uuid)'::regprocedure),
  'sigue siendo stable, security definer y con search_path vacío'
);
select is(
  (select array_agg(r order by r)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, 'public.get_public_menu(uuid)', 'EXECUTE')),
  array['service_role'],
  'solo la ejecuta service_role: anon y authenticated no (los privilegios de antes se conservan)'
);
select ok(
  not has_function_privilege('service_role', 'private.recipe_ingredient_names(uuid)', 'EXECUTE'),
  'la ayuda private.recipe_ingredient_names sigue cerrada para todos (la usa el dueño de get_public_menu)'
);

select finish();
rollback;
