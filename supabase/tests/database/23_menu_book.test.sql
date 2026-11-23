-- =====================================================================
-- Libro del menú (migración 20261122120000_menu_book.sql): los nombres de los ingredientes de cada
-- plato en el contexto del envío y en la huella de la foto.
--   * private.recipe_ingredient_names: los nombres en el orden de Evelyn (position), recortados y sin
--     repetir sin distinguir mayúsculas (queda el primero); [] sin ingredientes. Solo el dueño la usa.
--   * chef_menu_send_context: cada plato trae ingredients, solo los nombres; nada de cantidades,
--     unidades, secciones ni notas del plato. Lo demás del contexto, igual que antes.
--   * private.menu_send_fingerprint: cambia si cambia un nombre, el orden o la cantidad de
--     ingredientes; no si cambia solo una cantidad, una unidad, una sección, un repetido que no sale en
--     la foto, la nota del plato o un plato que no está en el menú.
--   * Una vista previa con la huella de antes de un cambio no se guarda, y una que se armó antes del
--     cambio no sale (menu_changed); otra vista previa, sí.
--
-- C1 tiene a la clienta A con el pedido R (de la web, en italiano) y su sesión S1 (confirmada), con
-- el menú de dos platos: P1 (cinco ingredientes, uno repetido con otra mayúscula, y una nota interna)
-- y P2 (sin ingredientes). P3 es un plato de la cocina que no está en el menú.
-- Corre como postgres (el dueño de las funciones): las de la service role se prueban en 20_menu_sends.
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

select plan(35);

-- ---------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values ('7e6d0000-0000-4000-8000-00000000c001', 'chef1@libro.test');
update public.profiles set role = 'chef' where id = '7e6d0000-0000-4000-8000-00000000c001';
insert into public.chefs (id, profile_id, display_name) values
  ('7e6d1000-0000-4000-8000-000000000001', '7e6d0000-0000-4000-8000-00000000c001', 'Evelyn');
insert into public.chef_settings (chef_id) values ('7e6d1000-0000-4000-8000-000000000001');

insert into public.clients (id, chef_id, display_name, status) values
  ('7e6d2000-0000-4000-8000-00000000000a', '7e6d1000-0000-4000-8000-000000000001', 'Anna Rota', 'trial');
insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals, weeks, source, locale) values
  ('7e6d3000-0000-4000-8000-00000000000a', '7e6d1000-0000-4000-8000-000000000001', '7e6d2000-0000-4000-8000-00000000000a',
   'week', 'accepted', 2, 0, 5, '{dinner}', 1, 'web', 'it');
insert into public.sessions (id, chef_id, client_id, request_id, "date", start_time, cook_minutes, status) values
  ('7e6d4000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', '7e6d2000-0000-4000-8000-00000000000a',
   '7e6d3000-0000-4000-8000-00000000000a', '2027-03-01', '10:00', 180, 'confirmed');

insert into public.recipes (id, chef_id, name_it, name_es, description_it, diet) values
  ('7e6d6000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', 'Lasagne', 'Lasaña', 'Al ragù', null),
  ('7e6d6000-0000-4000-8000-000000000002', '7e6d1000-0000-4000-8000-000000000001', 'Minestrone', null, null, 'vegan'),
  ('7e6d6000-0000-4000-8000-000000000003', '7e6d1000-0000-4000-8000-000000000001', 'Tiramisù', null, null, null);
-- Los de P1, cargados en desorden (manda position): «sale» repite a «Sale» con otra mayúscula.
-- Cantidades fáciles de buscar (437, 523, 1019): no tienen que aparecer en el contexto de los platos.
insert into public.recipe_ingredients (recipe_id, chef_id, position, name, section, quantity, unit) values
  ('7e6d6000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', 3, 'Carne macinata', 'meat_fish', 437, 'g'),
  ('7e6d6000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', 1, 'Sfoglia all''uovo', 'pantry', 523, 'g'),
  ('7e6d6000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', 4, 'sale', 'pantry', null, null),
  ('7e6d6000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', 2, 'Sale', 'pantry', null, null),
  ('7e6d6000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', 5, 'Latte intero', 'dairy_eggs', 1019, 'ml'),
  ('7e6d6000-0000-4000-8000-000000000003', '7e6d1000-0000-4000-8000-000000000001', 1, 'Mascarpone', 'dairy_eggs', 500, 'g');
insert into public.recipe_notes (recipe_id, chef_id, notes) values
  ('7e6d6000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', 'NOTA-INTERNA-xyz: el truco del ragù');

insert into public.session_menus (session_id, chef_id) values
  ('7e6d4000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001');
insert into public.session_menu (session_id, recipe_id, chef_id, portions, position) values
  ('7e6d4000-0000-4000-8000-000000000001', '7e6d6000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', 6, 1),
  ('7e6d4000-0000-4000-8000-000000000001', '7e6d6000-0000-4000-8000-000000000002', '7e6d1000-0000-4000-8000-000000000001', 4, 2);
insert into public.session_shopping_items (session_id, chef_id, position, name, section, quantity, unit) values
  ('7e6d4000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', 1, 'Carne macinata', 'meat_fish', 600, 'g');

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

-- El contexto de S1, como lo pide la función chef.
create function pg_temp.ctx() returns jsonb
language sql
stable
as $$ select public.chef_menu_send_context('7e6d1000-0000-4000-8000-000000000001', '7e6d4000-0000-4000-8000-000000000001') $$;

-- La huella de S1 antes y después de un cambio: ¿cambió? El cambio queda hecho.
create function pg_temp.fingerprint_changes(p_change text) returns boolean
language plpgsql
as $$
declare
  v_before text := private.menu_send_fingerprint('7e6d4000-0000-4000-8000-000000000001');
begin
  execute p_change;
  return v_before is distinct from private.menu_send_fingerprint('7e6d4000-0000-4000-8000-000000000001');
end
$$;

-- El hash de un token de prueba, como lo calcula la función chef.
create function pg_temp.h(p_token text) returns text
language sql
immutable
as $$ select encode(sha256(convert_to(p_token, 'UTF8')), 'hex') $$;

-- Una vista previa de S1 con la huella de ahora; el token de prueba va en la foto para encontrar el envío.
create function pg_temp.prepare(p_token text) returns uuid
language sql
as $$
  select (public.chef_prepare_menu_send('7e6d1000-0000-4000-8000-000000000001', '7e6d4000-0000-4000-8000-000000000001', 1, 'it',
            jsonb_build_object('v', 1, 'token', p_token), false, pg_temp.ctx() ->> 'fingerprint') ->> 'sendId')::uuid
$$;

create function pg_temp.send_of(p_token text) returns uuid
language sql
stable
as $$ select ms.id from public.menu_sends ms where ms.snapshot ->> 'token' = p_token $$;

-- Enviar como la función chef: el link con el hash del token y después marcarlo enviado.
create function pg_temp.deliver(p_send uuid, p_token text) returns timestamptz
language sql
as $$
  select public.chef_link_menu_send('7e6d1000-0000-4000-8000-000000000001', p_send, pg_temp.h(p_token));
  select (public.chef_complete_menu_send('7e6d1000-0000-4000-8000-000000000001', p_send, array['email']) ->> 'sentAt')::timestamptz;
$$;

create temp table huellas (k text primary key, v text not null);

-- ---------------------------------------------------------------------
-- 1. Privilegios
-- ---------------------------------------------------------------------
select ok(
  not has_function_privilege('anon', 'private.recipe_ingredient_names(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'private.recipe_ingredient_names(uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'private.recipe_ingredient_names(uuid)', 'EXECUTE')
  and not has_function_privilege('public', 'private.recipe_ingredient_names(uuid)', 'EXECUTE'),
  'private.recipe_ingredient_names: nadie fuera del dueño (la usan el contexto y la huella)');
select ok(
  (select p.prosecdef from pg_proc p where p.oid = 'public.chef_menu_send_context(uuid, uuid)'::regprocedure)
  and has_function_privilege('service_role', 'public.chef_menu_send_context(uuid, uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.chef_menu_send_context(uuid, uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.chef_menu_send_context(uuid, uuid)', 'EXECUTE')
  and not has_function_privilege('public', 'public.chef_menu_send_context(uuid, uuid)', 'EXECUTE'),
  'chef_menu_send_context sigue security definer y solo para service_role');

-- ---------------------------------------------------------------------
-- 2. private.recipe_ingredient_names
-- ---------------------------------------------------------------------
select is(private.recipe_ingredient_names('7e6d6000-0000-4000-8000-000000000001'),
  '["Sfoglia all''uovo", "Sale", "Carne macinata", "Latte intero"]'::jsonb,
  'los nombres en el orden de position, sin repetir sin distinguir mayúsculas (queda el primero)');
select is(private.recipe_ingredient_names('7e6d6000-0000-4000-8000-000000000002'), '[]'::jsonb, 'un plato sin ingredientes: []');
select is(private.recipe_ingredient_names('7e6d6000-0000-4000-8000-0000000000ff'), '[]'::jsonb, 'un plato que no existe: []');

-- ---------------------------------------------------------------------
-- 3. chef_menu_send_context
-- ---------------------------------------------------------------------
select is(pg_temp.ctx() #> '{menu,dishes,0,ingredients}',
  '["Sfoglia all''uovo", "Sale", "Carne macinata", "Latte intero"]'::jsonb,
  'cada plato trae los nombres de sus ingredientes, en orden y sin repetir');
select is(pg_temp.ctx() #> '{menu,dishes,1,ingredients}', '[]'::jsonb, 'un plato sin ingredientes trae []');
select is(
  (select array_agg(k order by k collate "C") from jsonb_object_keys(pg_temp.ctx() #> '{menu,dishes,0}') as k),
  array['allergens', 'descriptionEn', 'descriptionEs', 'descriptionIt', 'diet', 'ingredients', 'nameEn', 'nameEs', 'nameIt',
        'photoId', 'portions', 'recipeId'],
  'cada plato: las claves de antes más ingredients');
select is((pg_temp.ctx() #> '{menu,dishes,0}') - 'ingredients',
  '{"recipeId": "7e6d6000-0000-4000-8000-000000000001", "portions": 6, "nameIt": "Lasagne", "nameEs": "Lasaña", "nameEn": null,
    "descriptionIt": "Al ragù", "descriptionEs": null, "descriptionEn": null, "diet": null, "photoId": null, "allergens": []}'::jsonb,
  'lo demás del plato, igual que antes');
select ok(
  (select bool_and(jsonb_typeof(e) = 'string') from jsonb_array_elements(pg_temp.ctx() #> '{menu,dishes,0,ingredients}') as e),
  'los ingredientes son solo textos: nada de objetos con cantidad o unidad');
select ok(
  not ((pg_temp.ctx() -> 'menu' -> 'dishes')::text
       ~ '(437|523|1019|meat_fish|dairy_eggs|pantry|"g"|"ml"|"quantity"|"unit"|"section"|"position"|"notes"|NOTA-INTERNA)'),
  'en los platos no hay cantidades, unidades, secciones ni la nota interna del plato');
select is(
  (select array_agg(k order by k collate "C") from jsonb_object_keys(pg_temp.ctx()) as k),
  array['chef', 'contact', 'fingerprint', 'lastSend', 'menu', 'quote', 'request', 'session', 'weeks'],
  'el contexto: las mismas claves que antes');
select is(
  (select array_agg(k order by k collate "C") from jsonb_object_keys(pg_temp.ctx() -> 'menu') as k),
  array['allergensConfirmed', 'dishes', 'items', 'note', 'version'],
  'el menú: las mismas claves que antes');
select is(pg_temp.ctx() #> '{menu,items}',
  '[{"name": "Carne macinata", "section": "meat_fish", "quantity": 600, "unit": "g"}]'::jsonb,
  'la lista de compras sigue con su sección y su cantidad (la del súper, no la de la receta)');
select is(pg_temp.ctx() ->> 'fingerprint', private.menu_send_fingerprint('7e6d4000-0000-4000-8000-000000000001'),
  'la huella del contexto es la de private.menu_send_fingerprint');

-- ---------------------------------------------------------------------
-- 4. La huella cubre los nombres de los ingredientes, y solo eso de recipe_ingredients
-- ---------------------------------------------------------------------
select ok(not pg_temp.fingerprint_changes('select 1'), 'sin cambios, la misma huella');
select ok(not pg_temp.fingerprint_changes($$
  update public.recipe_ingredients set quantity = 451
  where recipe_id = '7e6d6000-0000-4000-8000-000000000001' and position = 3 $$),
  'una cantidad no cambia la huella (no está en la foto)');
select ok(not pg_temp.fingerprint_changes($$
  update public.recipe_ingredients set quantity = null, unit = null
  where recipe_id = '7e6d6000-0000-4000-8000-000000000001' and position = 5 $$),
  'una unidad (pasar a q.b.) tampoco');
select ok(not pg_temp.fingerprint_changes($$
  update public.recipe_ingredients set section = 'other'
  where recipe_id = '7e6d6000-0000-4000-8000-000000000001' and position = 1 $$),
  'ni una sección');
select ok(not pg_temp.fingerprint_changes($$
  update public.recipe_ingredients set name = 'SALE'
  where recipe_id = '7e6d6000-0000-4000-8000-000000000001' and position = 4 $$),
  'ni un repetido que no sale en la foto');
select ok(not pg_temp.fingerprint_changes($$
  update public.recipe_notes set notes = 'Otra nota interna'
  where recipe_id = '7e6d6000-0000-4000-8000-000000000001' $$),
  'ni la nota interna del plato');
select ok(not pg_temp.fingerprint_changes($$
  insert into public.recipe_ingredients (recipe_id, chef_id, position, name, section, quantity, unit)
  values ('7e6d6000-0000-4000-8000-000000000003', '7e6d1000-0000-4000-8000-000000000001', 2, 'Zucchero', 'pantry', 100, 'g') $$),
  'ni un plato que no está en el menú');
select ok(pg_temp.fingerprint_changes($$
  update public.recipe_ingredients set name = 'Sale grosso'
  where recipe_id = '7e6d6000-0000-4000-8000-000000000001' and position = 2 $$),
  'un nombre cambia la huella');
select ok(pg_temp.fingerprint_changes($$
  insert into public.recipe_ingredients (recipe_id, chef_id, position, name, section, quantity, unit)
  values ('7e6d6000-0000-4000-8000-000000000002', '7e6d1000-0000-4000-8000-000000000001', 1, 'Fagioli borlotti', 'produce', 300, 'g') $$),
  'un ingrediente nuevo, también en un plato que no tenía, la cambia');
select ok(pg_temp.fingerprint_changes($$
  update public.recipe_ingredients set position = 9
  where recipe_id = '7e6d6000-0000-4000-8000-000000000001' and position = 1 $$),
  'el orden la cambia');
select ok(pg_temp.fingerprint_changes($$
  delete from public.recipe_ingredients
  where recipe_id = '7e6d6000-0000-4000-8000-000000000001' and position = 5 $$),
  'uno menos la cambia');
select is(
  (select jsonb_agg(d.e -> 'ingredients' order by d.n) from jsonb_array_elements(pg_temp.ctx() #> '{menu,dishes}') with ordinality as d(e, n)),
  '[["Sale grosso", "Carne macinata", "SALE", "Sfoglia all''uovo"], ["Fagioli borlotti"]]'::jsonb,
  'el contexto trae los nombres de ahora («SALE» ya no repite a nadie)');

-- ---------------------------------------------------------------------
-- 5. Vista previa y envío
-- ---------------------------------------------------------------------
insert into huellas (k, v) values ('antes', private.menu_send_fingerprint('7e6d4000-0000-4000-8000-000000000001'));
select ok(pg_temp.prepare('token-a') is not null, 'una vista previa con la huella de ahora se guarda');

update public.recipe_ingredients set name = 'Carne di manzo'
where recipe_id = '7e6d6000-0000-4000-8000-000000000001' and position = 3;

select is(
  pg_temp.error_of($$ select public.chef_link_menu_send('7e6d1000-0000-4000-8000-000000000001', pg_temp.send_of('token-a'), pg_temp.h('token-a')) $$),
  '40001: menu_changed',
  'cambió un nombre después de la vista previa: el envío no sale (hace falta otra vista previa)');
select is(
  pg_temp.error_of(format(
    $$ select public.chef_prepare_menu_send('7e6d1000-0000-4000-8000-000000000001', '7e6d4000-0000-4000-8000-000000000001', 1, 'it', '{"v": 1}', false, %L) $$,
    (select h.v from huellas h where h.k = 'antes'))),
  '40001: menu_changed',
  'ni se guarda una vista previa armada con la huella de antes del cambio');
select ok(pg_temp.deliver(pg_temp.prepare('token-b'), 'token-b') is not null, 'otra vista previa, con la huella nueva, sale');

-- ---------------------------------------------------------------------
-- 6. Con un presupuesto abierto (20261121120000_quotes.sql): la semana 1 lleva el presupuesto y los
--    ingredientes; la huella cubre los dos, y un presupuesto con el plazo vencido (cerrado: quote_live)
--    ya no entra en la huella ni en el contexto.
-- ---------------------------------------------------------------------
insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals, weeks, source, locale) values
  ('7e6d3000-0000-4000-8000-00000000000b', '7e6d1000-0000-4000-8000-000000000001', '7e6d2000-0000-4000-8000-00000000000a',
   'week', 'new', 2, 0, 5, '{dinner}', 1, 'web', 'it');
create temp table qs as
  select (public.chef_create_quote('7e6d1000-0000-4000-8000-000000000001', '7e6d3000-0000-4000-8000-00000000000b',
            array[(date_trunc('week', (now() at time zone 'Europe/Rome')::date::timestamp)::date + 7 + 9)], '10:00', 180, 14000, 4)
          ->> 'quote_id')::uuid as id;
create temp table qsess as
  select s.id from public.sessions s where s.request_id = '7e6d3000-0000-4000-8000-00000000000b' and s.status = 'held';
insert into public.session_menus (session_id, chef_id)
  select id, '7e6d1000-0000-4000-8000-000000000001' from qsess;
insert into public.session_menu (session_id, recipe_id, chef_id, portions, position)
  select id, '7e6d6000-0000-4000-8000-000000000001', '7e6d1000-0000-4000-8000-000000000001', 4, 1 from qsess;

select is(
  (select public.chef_menu_send_context('7e6d1000-0000-4000-8000-000000000001', q.id) #> '{menu,dishes,0,ingredients}' from qsess q),
  private.recipe_ingredient_names('7e6d6000-0000-4000-8000-000000000001'),
  'la semana de un presupuesto abierto trae los ingredientes del plato…');
select ok(
  (select public.chef_menu_send_context('7e6d1000-0000-4000-8000-000000000001', q.id) -> 'quote' is not null from qsess q),
  '…y el presupuesto');
insert into huellas (k, v) select 'q1', private.menu_send_fingerprint(q.id) from qsess q;
select public.chef_update_quote('7e6d1000-0000-4000-8000-000000000001', (select id from qs), 15000);
select isnt(
  (select private.menu_send_fingerprint(q.id) from qsess q), (select h.v from huellas h where h.k = 'q1'),
  'otro precio cambia la huella (los términos del presupuesto entran)');
insert into huellas (k, v) select 'q2', private.menu_send_fingerprint(q.id) from qsess q;
update public.quotes set hold_until = now() - interval '1 minute' where id = (select id from qs);
update public.sessions set hold_until = now() - interval '1 minute' where id = (select id from qsess);
select is(
  (select (private.menu_send_fingerprint(q.id) is distinct from (select h.v from huellas h where h.k = 'q2'))
          and public.chef_menu_send_context('7e6d1000-0000-4000-8000-000000000001', q.id) -> 'quote' = 'null'::jsonb from qsess q),
  true,
  'con el plazo vencido el presupuesto está cerrado: sale de la huella y del contexto, aunque el cron no haya pasado');

select * from finish();
rollback;
