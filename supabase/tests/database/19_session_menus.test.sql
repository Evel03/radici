-- =====================================================================
-- Menú y lista de compras de cada semana (migración 20261121090000_session_menus.sql):
--   * session_menu: position (orden de los platos, de 1 a 30) y porciones de 1 a 500.
--   * session_shopping_items: la lista de compras de la semana, solo de la cocinera.
--   * session_menus: la nota para la clienta, la versión y la confirmación de alérgenos.
--   * public.save_session_menu(p jsonb): guarda todo junto con la RLS de quien llama, reemplaza
--     platos y lista, y controla la versión (menu_changed).
--
-- C1 tiene a la clienta A (con cuenta) y a un colaborador M; sus sesiones: S1 confirmada, S2 held,
-- S3 cancelada y S4 cocinada. C2 es otra cocinera, con su sesión SX y su receta RX.
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

select plan(61);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e690000-0000-4000-8000-00000000c001', 'chef1@menus.test'),
  ('7e690000-0000-4000-8000-00000000c002', 'chef2@menus.test'),
  ('7e690000-0000-4000-8000-00000000d001', 'm@menus.test'),
  ('7e690000-0000-4000-8000-00000000a001', 'a@menus.test');
update public.profiles set role = 'chef'
where id in ('7e690000-0000-4000-8000-00000000c001', '7e690000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e691000-0000-4000-8000-000000000001', '7e690000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e691000-0000-4000-8000-000000000002', '7e690000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e691000-0000-4000-8000-000000000001'),
  ('7e691000-0000-4000-8000-000000000002');
insert into public.chef_members (chef_id, profile_id) values
  ('7e691000-0000-4000-8000-000000000001', '7e690000-0000-4000-8000-00000000d001');

insert into public.clients (id, chef_id, profile_id, display_name, status) values
  ('7e692000-0000-4000-8000-00000000000a', '7e691000-0000-4000-8000-000000000001',
   '7e690000-0000-4000-8000-00000000a001', 'Cliente A', 'active'),
  ('7e692000-0000-4000-8000-00000000000f', '7e691000-0000-4000-8000-000000000002',
   null, 'Cliente X', 'active');

insert into public.sessions (id, chef_id, client_id, "date", start_time, cook_minutes, status, hold_until, cancelled_at) values
  ('7e694000-0000-4000-8000-000000000001', '7e691000-0000-4000-8000-000000000001', '7e692000-0000-4000-8000-00000000000a',
   '2027-03-01', '10:00', 180, 'confirmed', null, null),
  ('7e694000-0000-4000-8000-000000000002', '7e691000-0000-4000-8000-000000000001', '7e692000-0000-4000-8000-00000000000a',
   '2027-03-08', '10:00', 180, 'held', now() + interval '48 hours', null),
  ('7e694000-0000-4000-8000-000000000003', '7e691000-0000-4000-8000-000000000001', '7e692000-0000-4000-8000-00000000000a',
   '2027-03-15', '10:00', 180, 'cancelled', null, now()),
  ('7e694000-0000-4000-8000-000000000004', '7e691000-0000-4000-8000-000000000001', '7e692000-0000-4000-8000-00000000000a',
   '2026-01-05', '10:00', 180, 'cooked', null, null),
  ('7e694000-0000-4000-8000-00000000000f', '7e691000-0000-4000-8000-000000000002', '7e692000-0000-4000-8000-00000000000f',
   '2027-03-01', '10:00', 180, 'confirmed', null, null);

insert into public.recipes (id, chef_id, name_it, active) values
  ('7e696000-0000-4000-8000-000000000001', '7e691000-0000-4000-8000-000000000001', 'Lasagne', true),
  ('7e696000-0000-4000-8000-000000000002', '7e691000-0000-4000-8000-000000000001', 'Minestrone', true),
  ('7e696000-0000-4000-8000-000000000003', '7e691000-0000-4000-8000-000000000001', 'Polpette', false),
  ('7e696000-0000-4000-8000-00000000000f', '7e691000-0000-4000-8000-000000000002', 'Ossobuco', true);

-- El texto del error de una sentencia ("SQLSTATE: mensaje (DETAIL)"), o null si no falla.
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

-- El check que frena una sentencia como "SQLSTATE constraint", o null si no falla.
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

-- Un menú válido de S1 (sin version: la pone cada test); p_extra pisa o agrega claves.
create function pg_temp.menu(p_extra jsonb default '{}') returns jsonb
language sql
as $$
  select jsonb_build_object(
    'session_id', '7e694000-0000-4000-8000-000000000001',
    'dishes', jsonb_build_array(
      jsonb_build_object('recipe_id', '7e696000-0000-4000-8000-000000000002', 'portions', 6),
      jsonb_build_object('recipe_id', '7e696000-0000-4000-8000-000000000001', 'portions', 8)),
    'items', jsonb_build_array(
      jsonb_build_object('name', ' Zucchine ', 'section', 'produce', 'quantity', 750, 'unit', 'g'),
      jsonb_build_object('name', 'Latte', 'quantity', 1500, 'unit', 'ml'),
      jsonb_build_object('name', 'Sale', 'section', 'pantry'))
  ) || p_extra
$$;

-- El estado del menú de una sesión: versión, nota, alérgenos, platos (receta:porciones en orden) y
-- renglones (nombre/sección/cantidad/unidad en orden).
create function pg_temp.state(p_session uuid) returns text
language sql
as $$
  select concat_ws(' | ',
    (select concat_ws(' ', 'v' || m.version, coalesce(m.note, '-'), m.allergens_confirmed::text)
     from public.session_menus m where m.session_id = p_session),
    (select string_agg(right(d.recipe_id::text, 1) || ':' || d.portions, ',' order by d.position)
     from public.session_menu d where d.session_id = p_session),
    (select string_agg(concat_ws('/', i.name, i.section::text, i.quantity::text, i.unit::text), ',' order by i.position)
     from public.session_shopping_items i where i.session_id = p_session))
$$;

-- ---------------------------------------------------------------------
-- 1. Esquema y privilegios
-- ---------------------------------------------------------------------
select has_table('public'::name, 'session_shopping_items'::name, 'existe public.session_shopping_items');
select has_table('public'::name, 'session_menus'::name, 'existe public.session_menus');
select col_not_null('public', 'session_menu', 'position', 'session_menu.position es obligatoria');
select ok(
  (select bool_and(c.relrowsecurity) from pg_class c
   where c.oid in ('public.session_shopping_items'::regclass, 'public.session_menus'::regclass)),
  'RLS habilitado en las dos tablas nuevas');
select ok(
  not has_table_privilege('anon', 'public.session_shopping_items', 'SELECT,INSERT,UPDATE,DELETE')
  and not has_table_privilege('anon', 'public.session_menus', 'SELECT,INSERT,UPDATE,DELETE'),
  'anon no toca las tablas nuevas');
select ok(has_function_privilege('authenticated', 'public.save_session_menu(jsonb)', 'EXECUTE'),
  'authenticated ejecuta save_session_menu');
select ok(not has_function_privilege('anon', 'public.save_session_menu(jsonb)', 'EXECUTE')
          and not has_function_privilege('service_role', 'public.save_session_menu(jsonb)', 'EXECUTE')
          and not has_function_privilege('public', 'public.save_session_menu(jsonb)', 'EXECUTE'),
  'anon, service_role y public no la ejecutan');
select is(
  (select p.prosecdef from pg_proc p where p.oid = 'public.save_session_menu(jsonb)'::regprocedure),
  false, 'save_session_menu es security invoker');

-- Los checks, con escrituras directas (como postgres).
select is(pg_temp.check_of($$ insert into public.session_menu (session_id, recipe_id, chef_id, portions, position)
  values ('7e694000-0000-4000-8000-000000000001', '7e696000-0000-4000-8000-000000000001', '7e691000-0000-4000-8000-000000000001', 0, 1) $$),
  '23514 session_menu_porciones_validas', 'session_menu: 0 porciones no');
select is(pg_temp.check_of($$ insert into public.session_menu (session_id, recipe_id, chef_id, portions, position)
  values ('7e694000-0000-4000-8000-000000000001', '7e696000-0000-4000-8000-000000000001', '7e691000-0000-4000-8000-000000000001', 4, 31) $$),
  '23514 session_menu_posicion_valida', 'session_menu: posición 31 no');
select is(pg_temp.check_of($$ insert into public.session_shopping_items (session_id, chef_id, position, name, quantity)
  values ('7e694000-0000-4000-8000-000000000001', '7e691000-0000-4000-8000-000000000001', 1, 'Uova', 6) $$),
  '23514 session_shopping_items_cantidad_con_unidad', 'session_shopping_items: cantidad sin unidad no');
select is(pg_temp.check_of($$ insert into public.session_menus (session_id, chef_id, note)
  values ('7e694000-0000-4000-8000-000000000001', '7e691000-0000-4000-8000-000000000001', E'Hola\tchau') $$),
  '23514 session_menus_nota_valida', 'session_menus: una nota con tabulación no');

-- ---------------------------------------------------------------------
-- 2. save_session_menu (C1, como la app)
-- ---------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e690000-0000-4000-8000-00000000c001","role":"authenticated"}';

select is(public.save_session_menu(pg_temp.menu(jsonb_build_object('note', E'  Tené listos\r\n4 táperes. ', 'version', null))),
  1, 'el primer guardado devuelve la versión 1');
select is(pg_temp.state('7e694000-0000-4000-8000-000000000001'),
  E'v1 Tené listos\n4 táperes. false | 2:6,1:8 | Zucchine/produce/750/g,Latte/other/1500/ml,Sale/pantry',
  'guarda platos en orden, renglones recortados (sección other si no viene; q.b. sin cantidad) y la nota con \n');

select is(public.save_session_menu(jsonb_build_object(
    'session_id', '7e694000-0000-4000-8000-000000000001', 'version', 1, 'allergens_confirmed', true,
    'dishes', jsonb_build_array(jsonb_build_object('recipe_id', '7e696000-0000-4000-8000-000000000003', 'portions', 12)),
    'items', jsonb_build_array(jsonb_build_object('name', 'Carne macinata', 'section', 'meat_fish', 'quantity', 900, 'unit', 'g')))),
  2, 'el segundo guardado, con la versión 1, devuelve la 2');
select is(pg_temp.state('7e694000-0000-4000-8000-000000000001'),
  E'v2 Tené listos\n4 táperes. true | 3:12 | Carne macinata/meat_fish/900/g',
  'reemplaza platos y lista (una receta desactivada vale); la nota que no viene no se toca');

select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu('{"version": 1}')) $$),
  '40001: menu_changed', 'con una versión vieja: menu_changed');
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu('{"version": null}')) $$),
  '40001: menu_changed', 'sin versión cuando ya hay menú: menu_changed');
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu()) $$),
  '40001: menu_changed', 'sin la clave version, igual: menu_changed');
select is(pg_temp.state('7e694000-0000-4000-8000-000000000001'),
  E'v2 Tené listos\n4 táperes. true | 3:12 | Carne macinata/meat_fish/900/g',
  'un guardado rechazado no cambia nada');

select is(public.save_session_menu(pg_temp.menu('{"version": 2, "note": "", "allergens_confirmed": false}') || '{"dishes": [], "items": []}'),
  3, 'menú vacío y nota "" valen');
select is(pg_temp.state('7e694000-0000-4000-8000-000000000001'), 'v3 - false',
  'sin platos ni renglones, y la nota "" queda null');
select is(public.save_session_menu(pg_temp.menu('{"version": 3, "note": "Ciao"}')), 4, 'guardado 4');
select is(public.save_session_menu(pg_temp.menu('{"version": 4, "note": null}')), 5, 'guardado 5');
select is((select note from public.session_menus where session_id = '7e694000-0000-4000-8000-000000000001'),
  null, 'note null borra la nota');
select is((select updated_at from public.session_menus where session_id = '7e694000-0000-4000-8000-000000000001'),
  now(), 'updated_at es el momento del guardado');

-- Una sesión held (de un presupuesto) también se arma; una versión que no existe no crea el menú.
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu(
    '{"session_id": "7e694000-0000-4000-8000-000000000002", "version": 3}')) $$),
  '40001: menu_changed', 'una versión cuando todavía no hay menú: menu_changed');
select is(public.save_session_menu(pg_temp.menu('{"session_id": "7e694000-0000-4000-8000-000000000002", "version": null}')),
  1, 'una sesión held se arma');

-- Sesiones y recetas que no se pueden usar.
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu(
    '{"session_id": "7e694000-0000-4000-8000-000000000003", "version": null}')) $$),
  '55000: session_not_editable (cancelled)', 'una sesión cancelada no se arma');
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu(
    '{"session_id": "7e694000-0000-4000-8000-000000000004", "version": null}')) $$),
  '55000: session_not_editable (cooked)', 'una sesión cocinada tampoco');
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu(
    '{"session_id": "7e694000-0000-4000-8000-00000000000f", "version": null}')) $$),
  'P0002: session_not_found', 'la sesión de otra cocina no existe para C1');
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu(
    '{"session_id": "7e694000-0000-4000-8000-0000000000ee", "version": null}')) $$),
  'P0002: session_not_found', 'una sesión que no existe');
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu('{"version": 5}') || '{"dishes": [
    {"recipe_id": "7e696000-0000-4000-8000-000000000001", "portions": 4},
    {"recipe_id": "7e696000-0000-4000-8000-00000000000f", "portions": 4}]}') $$),
  'P0002: recipe_not_found (dishes[1].recipe_id)', 'una receta de otra cocina: recipe_not_found con el campo');
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu('{"version": 5}') || '{"dishes": [
    {"recipe_id": "7e696000-0000-4000-8000-0000000000ee", "portions": 4}]}') $$),
  'P0002: recipe_not_found (dishes[0].recipe_id)', 'una receta que no existe');

-- La forma de p: cada error dice el campo, contando desde 0.
select is(
  (select array_agg(pg_temp.error_of(format($f$ select public.save_session_menu(%L::jsonb) $f$, x.p)) order by x.n)
   from (values
     (1,  '[]'),
     (2,  pg_temp.menu('{"version": 5, "extra": 1}')::text),
     (3,  pg_temp.menu('{"version": 5, "session_id": "no"}')::text),
     (4,  pg_temp.menu('{"version": "5"}')::text),
     (5,  pg_temp.menu('{"version": -5}')::text),
     (6,  pg_temp.menu('{"version": 5.5}')::text),
     (7,  pg_temp.menu('{"version": 5, "note": 3}')::text),
     (8,  pg_temp.menu('{"version": 5, "allergens_confirmed": "true"}')::text),
     (9,  pg_temp.menu('{"version": 5, "dishes": {}}')::text),
     (10, (pg_temp.menu('{"version": 5}') - 'dishes')::text),
     (11, pg_temp.menu('{"version": 5, "dishes": [3]}')::text),
     (12, pg_temp.menu('{"version": 5, "dishes": [{"recipe_id": "7e696000-0000-4000-8000-000000000001", "portions": 4, "day": 1}]}')::text),
     (13, pg_temp.menu('{"version": 5, "dishes": [{"recipe_id": "x", "portions": 4}]}')::text),
     (14, pg_temp.menu('{"version": 5, "dishes": [{"recipe_id": "7e696000-0000-4000-8000-000000000001", "portions": "4"}]}')::text),
     (15, pg_temp.menu('{"version": 5, "dishes": [{"recipe_id": "7e696000-0000-4000-8000-000000000001", "portions": 4.5}]}')::text),
     (16, pg_temp.menu('{"version": 5, "dishes": [{"recipe_id": "7e696000-0000-4000-8000-000000000001"}]}')::text),
     (17, pg_temp.menu('{"version": 5, "dishes": [{"recipe_id": "7e696000-0000-4000-8000-000000000001", "portions": 4},
                                                  {"recipe_id": "7e696000-0000-4000-8000-000000000002", "portions": 4},
                                                  {"recipe_id": "7E696000-0000-4000-8000-000000000001", "portions": 2}]}')::text),
     (18, pg_temp.menu('{"version": 5, "items": null}')::text),
     (19, pg_temp.menu('{"version": 5, "items": ["Sale"]}')::text),
     (20, pg_temp.menu('{"version": 5, "items": [{"name": "Sale", "qty": 1}]}')::text),
     (21, pg_temp.menu('{"version": 5, "items": [{"name": 3}]}')::text),
     (22, pg_temp.menu('{"version": 5, "items": [{"name": "Sale", "section": "spices"}]}')::text),
     (23, pg_temp.menu('{"version": 5, "items": [{"name": "Sale", "quantity": "1", "unit": "g"}]}')::text),
     (24, pg_temp.menu('{"version": 5, "items": [{"name": "Sale", "quantity": 1.5, "unit": "g"}]}')::text),
     (25, pg_temp.menu('{"version": 5, "items": [{"name": "Sale"}, {"name": "Olio", "quantity": 1, "unit": "l"}]}')::text)
   ) as x(n, p)),
  array[
    '22023: invalid_payload (p)',
    '22023: invalid_payload (extra)',
    '22023: invalid_payload (session_id)',
    '22023: invalid_payload (version)',
    '22023: invalid_payload (version)',
    '22023: invalid_payload (version)',
    '22023: invalid_payload (note)',
    '22023: invalid_payload (allergens_confirmed)',
    '22023: invalid_payload (dishes)',
    '22023: invalid_payload (dishes)',
    '22023: invalid_payload (dishes[0])',
    '22023: invalid_payload (dishes[0].day)',
    '22023: invalid_payload (dishes[0].recipe_id)',
    '22023: invalid_payload (dishes[0].portions)',
    '22023: invalid_payload (dishes[0].portions)',
    '22023: invalid_payload (dishes[0].portions)',
    '22023: invalid_payload (dishes[2].recipe_id)',
    '22023: invalid_payload (items)',
    '22023: invalid_payload (items[0])',
    '22023: invalid_payload (items[0].qty)',
    '22023: invalid_payload (items[0].name)',
    '22023: invalid_payload (items[0].section)',
    '22023: invalid_payload (items[0].quantity)',
    '22023: invalid_payload (items[0].quantity)',
    '22023: invalid_payload (items[1].unit)'
  ],
  'cada forma inválida es invalid_payload con su campo (una receta repetida, sin importar mayúsculas)');

-- Los checks de las tablas, por la función.
select is(
  (select array_agg(pg_temp.check_of(format($f$ select public.save_session_menu(%L::jsonb) $f$, x.p)) order by x.n)
   from (values
     (1, pg_temp.menu('{"version": 5, "dishes": [{"recipe_id": "7e696000-0000-4000-8000-000000000001", "portions": 0}]}')::text),
     (2, pg_temp.menu('{"version": 5, "dishes": [{"recipe_id": "7e696000-0000-4000-8000-000000000001", "portions": 501}]}')::text),
     (3, pg_temp.menu('{"version": 5, "items": [{"name": "   "}]}')::text),
     (4, pg_temp.menu(jsonb_build_object('version', 5, 'items', jsonb_build_array(jsonb_build_object('name', repeat('x', 81)))))::text),
     (5, pg_temp.menu('{"version": 5, "items": [{"name": "Uova", "quantity": 6}]}')::text),
     (6, pg_temp.menu('{"version": 5, "items": [{"name": "Uova", "quantity": 0, "unit": "pcs"}]}')::text),
     (7, pg_temp.menu(jsonb_build_object('version', 5, 'items',
           (select jsonb_agg(jsonb_build_object('name', 'Cosa ' || g)) from generate_series(1, 151) g)))::text),
     (8, pg_temp.menu(jsonb_build_object('version', 5, 'note', repeat('x', 1001)))::text),
     (9, pg_temp.menu(jsonb_build_object('version', 5, 'note', E'Hola\u0007'))::text)
   ) as x(n, p)),
  array[
    '23514 session_menu_porciones_validas',
    '23514 session_menu_porciones_validas',
    '23514 session_shopping_items_nombre_valido',
    '23514 session_shopping_items_nombre_valido',
    '23514 session_shopping_items_cantidad_con_unidad',
    '23514 session_shopping_items_cantidad_valida',
    '23514 session_shopping_items_posicion_valida',
    '23514 session_menus_nota_valida',
    '23514 session_menus_nota_valida'
  ],
  'los checks frenan porciones, nombres, cantidades, más de 150 renglones y la nota');
select is(pg_temp.check_of(format($f$ select public.save_session_menu(%L::jsonb) $f$,
    pg_temp.menu(jsonb_build_object('version', 5, 'dishes',
      (select jsonb_agg(jsonb_build_object('recipe_id', id, 'portions', 2))
       from (select gen_random_uuid() as id from generate_series(1, 31)) r))))),
  'P0002 recipe_not_found', 'más de 30 platos: ninguno existe, recipe_not_found antes que el check');
select is(pg_temp.state('7e694000-0000-4000-8000-000000000001'),
  'v5 - false | 2:6,1:8 | Zucchine/produce/750/g,Latte/other/1500/ml,Sale/pantry',
  'después de todos los errores, el menú sigue como en la versión 5');

-- 31 platos de verdad (30 recetas nuevas de C1, como postgres, y dos de las existentes).
reset role;
insert into public.recipes (id, chef_id, name_it)
select ('7e696100-0000-4000-8000-0000000000' || lpad(g::text, 2, '0'))::uuid, '7e691000-0000-4000-8000-000000000001', 'Piatto ' || g
from generate_series(1, 30) g;
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e690000-0000-4000-8000-00000000c001","role":"authenticated"}';
select is(pg_temp.check_of(format($f$ select public.save_session_menu(%L::jsonb) $f$,
    pg_temp.menu(jsonb_build_object('version', 5, 'dishes',
      (select jsonb_agg(jsonb_build_object('recipe_id', id, 'portions', 2) order by id)
       from (select r.id from public.recipes r where r.name_it like 'Piatto %'
             union all select '7e696000-0000-4000-8000-000000000001'::uuid) r))))),
  '23514 session_menu_posicion_valida', '31 platos: el check de la posición');
select is(public.save_session_menu(pg_temp.menu(jsonb_build_object('version', 5, 'dishes',
      (select jsonb_agg(jsonb_build_object('recipe_id', r.id, 'portions', 2) order by r.id)
       from public.recipes r where r.name_it like 'Piatto %')))),
  6, '30 platos sí');
select is((select count(*)::int from public.session_menu where session_id = '7e694000-0000-4000-8000-000000000001'),
  30, 'quedan los 30 platos');

-- ---------------------------------------------------------------------
-- 3. RLS: C1 ve lo suyo; C2, la clienta y anon, no
-- ---------------------------------------------------------------------
select is((select array_agg(session_id order by session_id) from public.session_menus),
  array['7e694000-0000-4000-8000-000000000001', '7e694000-0000-4000-8000-000000000002']::uuid[],
  'C1 ve los menús de sus dos sesiones');
select is((select count(*)::int from public.session_shopping_items where session_id = '7e694000-0000-4000-8000-000000000002'),
  3, 'C1 ve la lista de la sesión held');

-- C2 arma el de su sesión y no ve nada de C1.
set local request.jwt.claims = '{"sub":"7e690000-0000-4000-8000-00000000c002","role":"authenticated"}';
select is(public.save_session_menu(jsonb_build_object(
    'session_id', '7e694000-0000-4000-8000-00000000000f', 'version', null,
    'dishes', jsonb_build_array(jsonb_build_object('recipe_id', '7e696000-0000-4000-8000-00000000000f', 'portions', 4)),
    'items', '[]'::jsonb)),
  1, 'C2 arma el menú de su sesión');
select is((select array_agg(session_id) from public.session_menus),
  array['7e694000-0000-4000-8000-00000000000f']::uuid[], 'C2 ve solo su menú');
select is((select count(*)::int from public.session_shopping_items), 0, 'C2 no ve la lista de C1');
select is((select count(*)::int from public.session_menu where chef_id = '7e691000-0000-4000-8000-000000000001'),
  0, 'C2 no ve los platos de C1');
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu('{"version": 6}')) $$),
  'P0002: session_not_found', 'C2 no arma el menú de C1');
select is(pg_temp.error_of($$ insert into public.session_shopping_items (session_id, chef_id, position, name)
    values ('7e694000-0000-4000-8000-000000000001', '7e691000-0000-4000-8000-000000000001', 99, 'Intruso') $$),
  '42501: new row violates row-level security policy for table "session_shopping_items"',
  'C2 no escribe en la lista de C1');
update public.session_menus set note = 'Intruso' where session_id = '7e694000-0000-4000-8000-000000000001';
delete from public.session_shopping_items where session_id = '7e694000-0000-4000-8000-000000000001';

-- El colaborador de C1 arma los de la cocina.
set local request.jwt.claims = '{"sub":"7e690000-0000-4000-8000-00000000d001","role":"authenticated"}';
select is(public.save_session_menu(pg_temp.menu('{"session_id": "7e694000-0000-4000-8000-000000000002", "version": 1, "note": "Da M"}')),
  2, 'el colaborador de C1 guarda el menú de una sesión de la cocina');
select is((select count(*)::int from public.session_menus), 2, 'el colaborador ve los menús de la cocina');

-- La clienta A: ni la lista ni la nota; tampoco guarda.
set local request.jwt.claims = '{"sub":"7e690000-0000-4000-8000-00000000a001","role":"authenticated"}';
select is((select count(*)::int from public.session_shopping_items), 0, 'la clienta no lee la lista por la API');
select is((select count(*)::int from public.session_menus), 0, 'la clienta no lee las notas por la API');
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu('{"version": 6}')) $$),
  '42501: not_a_chef', 'la clienta no guarda menús');

reset role;
set local role anon;
select is(pg_temp.error_of($$ select public.save_session_menu(pg_temp.menu('{"version": 6}')) $$),
  '42501: permission denied for function save_session_menu', 'anon no ejecuta save_session_menu');
reset role;

-- Lo que intentó C2 no tocó nada de C1.
select is((select note from public.session_menus where session_id = '7e694000-0000-4000-8000-000000000001'),
  null, 'el update de C2 no cambió la nota de C1');
select is((select count(*)::int from public.session_shopping_items where session_id = '7e694000-0000-4000-8000-000000000001'),
  3, 'el delete de C2 no borró la lista de C1');
select is((select note from public.session_menus where session_id = '7e694000-0000-4000-8000-000000000002'),
  'Da M', 'el guardado del colaborador quedó');

-- ---------------------------------------------------------------------
-- 4. Al borrar una sesión se va su menú
-- ---------------------------------------------------------------------
delete from public.sessions where id = '7e694000-0000-4000-8000-000000000002';
select is((select count(*)::int from public.session_menus where session_id = '7e694000-0000-4000-8000-000000000002'),
  0, 'borrar la sesión borra su session_menus');
select is((select count(*)::int from public.session_menu where session_id = '7e694000-0000-4000-8000-000000000002')
        + (select count(*)::int from public.session_shopping_items where session_id = '7e694000-0000-4000-8000-000000000002'),
  0, 'y sus platos y su lista');

-- Una receta en un menú no se borra (se desactiva).
select is(pg_temp.error_of($$ delete from public.recipes where id = '7e696100-0000-4000-8000-000000000001' $$) like '23503:%',
  true, 'una receta en el menú de una semana no se puede borrar');

select * from finish();
rollback;
