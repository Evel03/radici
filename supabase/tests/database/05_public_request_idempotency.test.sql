-- =====================================================================
-- Idempotencia del pedido de la web (docs/contracts/public-request.md §3):
-- requests.request_key, índice único por cocinera y submit_public_request
-- que devuelve el pedido guardado cuando la clave se repite.
-- (Dos envíos simultáneos con la misma clave necesitan dos conexiones: eso
-- se prueba aparte, contra la base local, con dos sesiones de psql.)
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

select plan(34);

-- ---------------------------------------------------------------------
-- Fixture (como postgres): C1 recibe los pedidos de la web; C2 es otra cocinera.
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e590000-0000-4000-8000-00000000c001', 'chef1@idem.test'),
  ('7e590000-0000-4000-8000-00000000c002', 'chef2@idem.test');
update public.profiles set role = 'chef'
where id in ('7e590000-0000-4000-8000-00000000c001', '7e590000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e591000-0000-4000-8000-000000000001', '7e590000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e591000-0000-4000-8000-000000000002', '7e590000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e591000-0000-4000-8000-000000000001'),
  ('7e591000-0000-4000-8000-000000000002');

-- Payload como lo arma la Edge Function (snake_case). p_extra pisa claves.
create function pg_temp.payload(p_extra jsonb default '{}') returns jsonb
language sql
as $$
  select jsonb_build_object(
    'chef_id', '7e591000-0000-4000-8000-000000000001',
    'type', 'week', 'adults', 2, 'kids', 1, 'days', 5, 'meals', jsonb_build_array('dinner'),
    'allergens', jsonb_build_array('milk'), 'diets', jsonb_build_array(), 'restrictions_note', '',
    'preferred_date', null, 'preferred_slot', 'any',
    'name', 'Anna Verdi', 'zone', 'Redona', 'phone', '+393331112222', 'email', 'anna@idem.test',
    'whatsapp_opt_in', false, 'notes', '', 'locale', 'it',
    'privacy_consent_version', '2026-10-19', 'health_consent_version', '2026-10-19',
    'estimate', jsonb_build_object('portions', 15, 'recipes', 3, 'cookMinutes', 180, 'serviceCents', 7800,
                                   'groceriesEstCents', 5050, 'totalCents', 12850,
                                   'pricing', jsonb_build_object('hourlyRateCents', 2200))
  ) || p_extra
$$;

-- Cuántas filas hay de cada cosa (para ver que un duplicado no toca nada).
create function pg_temp.footprint() returns jsonb
language sql
as $$
  select jsonb_build_object(
    'clients',       (select count(*) from public.clients),
    'requests',      (select count(*) from public.requests),
    'consents',      (select count(*) from public.consents),
    'restrictions',  (select count(*) from public.client_restrictions),
    'notifications', (select count(*) from public.notifications)
  )
$$;

-- Resultados de submit_public_request y fotos de footprint.
create temp table results (k text primary key, r jsonb);

-- =====================================================================
-- 1. Esquema y privilegios
-- =====================================================================
select is(
  (select format('%s %s %s', c.data_type, c.is_nullable, coalesce(c.column_default, '-'))
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'requests' and c.column_name = 'request_key'),
  'uuid YES -',
  'requests.request_key: uuid, opcional y sin default'
);
select is(
  (select indexdef from pg_indexes where schemaname = 'public' and indexname = 'requests_chef_request_key_idx'),
  'CREATE UNIQUE INDEX requests_chef_request_key_idx ON public.requests USING btree (chef_id, request_key) WHERE (request_key IS NOT NULL)',
  'índice único por (cocinera, clave), solo para pedidos con clave'
);
select ok(
  not has_column_privilege('authenticated', 'public.requests', 'request_key', 'INSERT')
  and not has_column_privilege('authenticated', 'public.requests', 'request_key', 'UPDATE'),
  'la app no escribe request_key (ni al crear ni al actualizar)'
);
select is(
  pg_get_function_result('public.submit_public_request(jsonb)'::regprocedure),
  'jsonb',
  'submit_public_request devuelve jsonb ({request_id, duplicate, estimate})'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
   from pg_proc p where p.oid = 'public.submit_public_request(jsonb)'::regprocedure),
  'sigue siendo security definer con search_path vacío'
);
select ok(
  not has_function_privilege('anon', 'public.submit_public_request(jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.submit_public_request(jsonb)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.submit_public_request(jsonb)', 'EXECUTE'),
  'solo la service role la ejecuta'
);

-- =====================================================================
-- 2. Primer envío con clave
-- =====================================================================
set local role service_role;
select lives_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"request_key": "00000000-0000-4000-8000-0000000000aa", "email": "rol@idem.test"}')) $$,
  'la service role guarda un pedido con clave'
);
reset role;

insert into results (k, r)
values ('first', public.submit_public_request(pg_temp.payload('{"request_key": "3F2B8C1E-9A4D-4C7B-8E2F-0123456789AB"}')));

select is(
  (select r - 'request_id' from results where k = 'first'),
  jsonb_build_object('duplicate', false, 'estimate', pg_temp.payload() -> 'estimate', 'menu', '[]'::jsonb),
  'pedido nuevo: duplicate false, la estimación que se guardó y el menu (sin platos elegidos, []: 17_menu_web)'
);
select results_eq(
  $$ select r.request_key, r.source, r.status::text, c.display_name
     from public.requests r join public.clients c on c.id = r.client_id
     where r.id = (select (r ->> 'request_id')::uuid from results where k = 'first') $$,
  $$ values ('3f2b8c1e-9a4d-4c7b-8e2f-0123456789ab'::uuid, 'web'::text, 'new'::text, 'Anna Verdi'::text) $$,
  'el pedido guarda la clave (normalizada como uuid), origen web y el prospecto'
);
select is(
  (select count(*)::int from public.notifications
   where payload ->> 'request_id' = (select r ->> 'request_id' from results where k = 'first')),
  1,
  'una notificación para la cocinera'
);

-- =====================================================================
-- 3. La misma clave otra vez: el pedido guardado, sin tocar nada
-- =====================================================================
insert into results (k, r) values ('before_dup', pg_temp.footprint());

-- Mismo email, otros datos (nombre, teléfono, zona, restricciones, estimación) y la clave en minúsculas.
insert into results (k, r)
values ('dup', public.submit_public_request(pg_temp.payload(
  '{"request_key": "3f2b8c1e-9a4d-4c7b-8e2f-0123456789ab", "name": "Anna Cambiata", "phone": "+393339999999",
    "zone": "Altrove", "allergens": ["eggs", "fish"], "days": 2,
    "estimate": {"portions": 1, "recipes": 2, "cookMinutes": 150, "serviceCents": 1, "groceriesEstCents": 1, "totalCents": 2}}')));

select is(
  (select r -> 'duplicate' from results where k = 'dup'),
  'true'::jsonb,
  'clave repetida: duplicate true'
);
select is(
  (select r ->> 'request_id' from results where k = 'dup'),
  (select r ->> 'request_id' from results where k = 'first'),
  'devuelve el id del pedido original'
);
select is(
  (select r -> 'estimate' from results where k = 'dup'),
  pg_temp.payload() -> 'estimate',
  'y la estimación guardada del original (no la del reintento)'
);
select is(
  pg_temp.footprint(),
  (select r from results where k = 'before_dup'),
  'no inserta ni borra nada: clientes, pedidos, consentimientos, restricciones y notificaciones iguales'
);
select results_eq(
  $$ select display_name, contact_phone, zone from public.clients
     where id = (select client_id from public.requests where id = (select (r ->> 'request_id')::uuid from results where k = 'first')) $$,
  $$ values ('Anna Verdi'::text, '+393331112222'::text, 'Redona'::text) $$,
  'no actualiza el prospecto con los datos del reintento'
);
select is(
  (select array_agg(coalesce(allergen::text, diet::text)) from public.client_restrictions
   where client_id = (select client_id from public.requests where id = (select (r ->> 'request_id')::uuid from results where k = 'first'))),
  array['milk'],
  'ni le reemplaza las restricciones'
);
select results_eq(
  $$ select days, restrictions from public.requests where id = (select (r ->> 'request_id')::uuid from results where k = 'first') $$,
  $$ values (5::smallint, '{"allergens": ["milk"], "diets": [], "note": ""}'::jsonb) $$,
  'ni toca el pedido guardado'
);

-- Un tercer intento, ahora desde otro email: sigue siendo el mismo pedido.
select is(
  (public.submit_public_request(pg_temp.payload(
     '{"request_key": "3f2b8c1e-9a4d-4c7b-8e2f-0123456789ab", "email": "otra@idem.test", "name": "Otra"}')) ->> 'request_id'),
  (select r ->> 'request_id' from results where k = 'first'),
  'la clave manda aunque cambie el email'
);
select is(
  (select count(*)::int from public.clients where lower(contact_email) = 'otra@idem.test'),
  0,
  'y no crea un prospecto para el otro email'
);

-- La validación va antes que la búsqueda: un reintento inválido falla igual.
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"request_key": "3f2b8c1e-9a4d-4c7b-8e2f-0123456789ab", "name": " "}')) $$,
  '22023', 'name_required',
  'con la clave repetida pero datos inválidos: error de validación'
);

-- =====================================================================
-- 4. Alcance de la clave
-- =====================================================================
insert into results (k, r)
values ('other_chef', public.submit_public_request(pg_temp.payload(
  '{"chef_id": "7e591000-0000-4000-8000-000000000002", "request_key": "3f2b8c1e-9a4d-4c7b-8e2f-0123456789ab"}')));
select is(
  (select r -> 'duplicate' from results where k = 'other_chef'),
  'false'::jsonb,
  'la misma clave en otra cocinera es otro pedido'
);
select isnt(
  (select r ->> 'request_id' from results where k = 'other_chef'),
  (select r ->> 'request_id' from results where k = 'first'),
  'con su propio id'
);

-- Sin clave (web vieja): cada envío es un pedido.
insert into results (k, r) values ('nokey1', public.submit_public_request(pg_temp.payload('{"email": "sinclave@idem.test"}')));
insert into results (k, r) values ('nokey2', public.submit_public_request(pg_temp.payload('{"email": "sinclave@idem.test", "request_key": null}')));
select is(
  (select array_agg(r -> 'duplicate' order by k) from results where k in ('nokey1', 'nokey2')),
  array['false'::jsonb, 'false'::jsonb],
  'sin clave (ausente o null) nunca es duplicado'
);
select is(
  (select count(*)::int from public.requests r
   join public.clients c on c.id = r.client_id
   where c.contact_email = 'sinclave@idem.test' and r.request_key is null),
  2,
  'dos pedidos sin clave del mismo prospecto'
);

-- =====================================================================
-- 5. Claves inválidas y el índice único
-- =====================================================================
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"request_key": "no-es-un-uuid"}')) $$,
  '22023', 'invalid_request_key',
  'una clave que no es UUID: rechazada'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"request_key": 12345}')) $$,
  '22023', 'invalid_request_key',
  'una clave que no es texto: rechazada'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"request_key": "{3f2b8c1e-9a4d-4c7b-8e2f-0123456789ab}"}')) $$,
  '22023', 'invalid_request_key',
  'solo el formato canónico (sin llaves ni otras variantes que acepta uuid)'
);
select is(
  (select count(*)::int from public.clients
   where chef_id = '7e591000-0000-4000-8000-000000000001' and lower(contact_email) = 'anna@idem.test'),
  1,
  'las claves inválidas no guardaron nada'
);

select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, request_key)
     select r.chef_id, r.client_id, 'week', 1, 0, 1, '{dinner}', r.request_key
     from public.requests r where r.id = (select (r ->> 'request_id')::uuid from results where k = 'first') $$,
  '23505', null,
  'la base no admite dos pedidos con la misma clave y cocinera aunque se salteen la función'
);
select lives_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals)
     select r.chef_id, r.client_id, 'week', 1, 0, 1, '{dinner}'
     from public.requests r where r.id = (select (r ->> 'request_id')::uuid from results where k = 'first') $$,
  'los pedidos sin clave no chocan entre sí (los de la app)'
);

-- =====================================================================
-- 6. El 04 sigue valiendo: prospecto reutilizado entre pedidos con claves distintas
-- =====================================================================
insert into results (k, r)
values ('second_key', public.submit_public_request(pg_temp.payload(
  '{"request_key": "7d0e1c55-2b1a-4f7e-9c3d-aabbccddeeff", "name": "Anna V."}')));
select is(
  (select r -> 'duplicate' from results where k = 'second_key'),
  'false'::jsonb,
  'otra clave del mismo email: pedido nuevo'
);
select is(
  (select count(*)::int from public.clients
   where chef_id = '7e591000-0000-4000-8000-000000000001' and lower(contact_email) = 'anna@idem.test'),
  1,
  'reutiliza el mismo prospecto'
);
select is(
  (select display_name from public.clients
   where chef_id = '7e591000-0000-4000-8000-000000000001' and lower(contact_email) = 'anna@idem.test'),
  'Anna Verdi',
  'sin cambiarle el nombre (un envío sin login nunca modifica a una persona que ya existe)'
);
select is(
  (select contact ->> 'name' from public.requests where id = (select (r ->> 'request_id')::uuid from results where k = 'second_key')),
  'Anna V.',
  'el nombre que llegó queda en la copia del contacto del pedido nuevo'
);

select finish();
rollback;
