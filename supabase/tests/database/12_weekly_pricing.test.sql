-- =====================================================================
-- Precio por semanas, la base (migración 20261116120000_weekly_pricing.sql; contrato
-- docs/contracts/public-request.md §3 y §8). Decisiones del dueño del 15 y 16/11/2026: el pedido
-- semanal es de 1 a 8 semanas, con una sesión de cocina por semana, y el servicio tiene un precio
-- por semana. El cálculo es del motor de presupuesto (quote.ts, en el PR siguiente); acá, lo que
-- guarda la base:
--
--   1. chef_settings: las columnas del precio por semana, sus valores por defecto y sus checks, y
--      el tope del costo por porción (el del motor).
--   2. requests.weeks: de 1 a 8, y 1 en lo que no es un pedido semanal.
--   3. submit_public_request guarda p.weeks; sin el campo (la función de hoy) o en null, 1.
--      Defensa: fuera de rango, que no es un entero o más de una semana en un pedido que no es
--      semanal fallan sin guardar nada. La respuesta y la estimación, como antes.
--   4. Privilegios y RLS: los de antes.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(61);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS): C1 recibe los pedidos de la web; C2 es otra cocinera; A es
-- cliente con cuenta de C1. Las dos cocineras, con chef_settings por defecto (como las crea
-- promote_to_chef).
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e620000-0000-4000-8000-00000000c001', 'chef1@semanas.test'),
  ('7e620000-0000-4000-8000-00000000c002', 'chef2@semanas.test'),
  ('7e620000-0000-4000-8000-00000000a001', 'cliente@semanas.test');
update public.profiles set role = 'chef'
where id in ('7e620000-0000-4000-8000-00000000c001', '7e620000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e621000-0000-4000-8000-000000000001', '7e620000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e621000-0000-4000-8000-000000000002', '7e620000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e621000-0000-4000-8000-000000000001'),
  ('7e621000-0000-4000-8000-000000000002');
insert into public.clients (id, chef_id, profile_id, display_name, status, contact_email) values
  ('7e622000-0000-4000-8000-00000000000a', '7e621000-0000-4000-8000-000000000001', '7e620000-0000-4000-8000-00000000a001',
   'Cliente A', 'active', 'cliente@semanas.test');

-- Payload como lo arma hoy la Edge Function (contrato v2, snake_case): sin weeks. p_extra pisa claves.
create function pg_temp.payload(p_extra jsonb default '{}') returns jsonb
language sql
as $$
  select jsonb_build_object(
    'chef_id', '7e621000-0000-4000-8000-000000000001',
    'type', 'week', 'adults', 2, 'kids', 2, 'days', 5, 'meals', jsonb_build_array('dinner'),
    'no_allergies', true,
    'allergens', jsonb_build_array(), 'diets', jsonb_build_array(), 'restrictions_note', '',
    'preferred_date', null, 'preferred_slot', 'any',
    'name', 'Anna Bassi', 'zone', 'Borgo Palazzo', 'phone', '+393331234100', 'email', 'anna@semanas.test',
    'whatsapp_opt_in', false, 'notes', '', 'locale', 'it',
    'privacy_consent_version', '2026-11-16', 'health_consent_version', null,
    'estimate', jsonb_build_object('portions', 20, 'recipes', 3, 'cookMinutes', 180, 'serviceCents', 7800,
                                   'groceriesEstCents', 6300, 'totalCents', 14100,
                                   'pricing', jsonb_build_object('hourlyRateCents', 2200))
  ) || p_extra
$$;

-- Ids de los pedidos guardados y, de los de la web, la respuesta de la función (los usuarios
-- simulados también los leen).
create temp table ids (k text primary key, v uuid, res jsonb);
grant select on ids to anon, authenticated, service_role;

create function pg_temp.submit(p_key text, p jsonb) returns void
language sql
as $$
  insert into ids (k, v, res)
  select p_key, (s.r ->> 'request_id')::uuid, s.r from (select public.submit_public_request(p) as r) s
$$;

-- =====================================================================
-- 1. chef_settings: precio por semana
-- =====================================================================
select is(
  (select array_agg(format('%s %s %s %s', c.column_name, c.data_type, c.is_nullable, coalesce(c.column_default, '-'))
                    order by c.column_name)
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'chef_settings'
     and c.column_name in ('weekly_rate_cents', 'weekly_rate_discounted_cents', 'weekly_discount_min_weeks',
                           'weekly_rate_max_people')),
  array['weekly_discount_min_weeks integer NO 4', 'weekly_rate_cents integer NO 15000',
        'weekly_rate_discounted_cents integer NO 14000', 'weekly_rate_max_people integer NO 5'],
  'chef_settings: tarifa por semana, tarifa con descuento, desde cuántas semanas y hasta cuántas personas (enteros obligatorios)'
);
select results_eq(
  $$ select weekly_rate_cents, weekly_rate_discounted_cents, weekly_discount_min_weeks, weekly_rate_max_people
     from public.chef_settings where chef_id = '7e621000-0000-4000-8000-000000000001' $$,
  $$ values (15000, 14000, 4, 5) $$,
  'una fila nueva (como la de promote_to_chef) recibe 15000, 14000, 4 y 5'
);

select throws_ok(
  $$ update public.chef_settings set weekly_rate_cents = -1
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  '23514', null,
  'la tarifa por semana no es negativa'
);
select throws_ok(
  $$ update public.chef_settings set weekly_rate_cents = 1000001
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  '23514', null,
  'ni pasa de 10.000 €'
);
select throws_ok(
  $$ update public.chef_settings set weekly_rate_discounted_cents = -1
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  '23514', null,
  'la tarifa con descuento no es negativa'
);
select throws_ok(
  $$ update public.chef_settings set weekly_rate_discounted_cents = 15001
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  '23514', 'new row for relation "chef_settings" violates check constraint "chef_settings_descuento_no_supera_tarifa"',
  'ni supera a la tarifa sin descuento'
);
select throws_ok(
  $$ update public.chef_settings set weekly_discount_min_weeks = 0
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  '23514', null,
  'el descuento vale desde 1 semana como pronto'
);
select throws_ok(
  $$ update public.chef_settings set weekly_discount_min_weeks = 9
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  '23514', null,
  'y desde 8 como tarde (no se pueden pedir más semanas)'
);
select throws_ok(
  $$ update public.chef_settings set weekly_rate_max_people = 0
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  '23514', null,
  'el precio automático es al menos para 1 persona'
);
select throws_ok(
  $$ update public.chef_settings set weekly_rate_max_people = 61
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  '23514', null,
  'y como mucho para 60 (30 adultos y 30 niños, LIMITS.maxPeople de quote.ts)'
);
select lives_ok(
  $$ update public.chef_settings
     set weekly_rate_cents = 0, weekly_rate_discounted_cents = 0, weekly_discount_min_weeks = 1, weekly_rate_max_people = 1
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  'valen los mínimos (0 €, 0 €, desde 1 semana, 1 persona) y la misma tarifa con y sin descuento'
);
select lives_ok(
  $$ update public.chef_settings
     set weekly_rate_cents = 1000000, weekly_rate_discounted_cents = 1000000, weekly_discount_min_weeks = 8,
         weekly_rate_max_people = 60
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  'y los máximos (10.000 €, desde 8 semanas, 60 personas)'
);

-- Costo por porción: el motor acepta hasta 1000 € (validateSettings); más caro, cada pedido de la
-- cocinera daría quote_failed.
select throws_ok(
  $$ update public.chef_settings set adult_portion_cents = 100001
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  '23514', 'new row for relation "chef_settings" violates check constraint "chef_settings_porcion_adulto_valida"',
  'la porción de adulto no pasa de 1000 € (el tope del motor)'
);
select throws_ok(
  $$ update public.chef_settings set kid_portion_cents = 100001
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  '23514', 'new row for relation "chef_settings" violates check constraint "chef_settings_porcion_nino_valida"',
  'ni la de niño'
);
select lives_ok(
  $$ update public.chef_settings set adult_portion_cents = 100000, kid_portion_cents = 100000
     where chef_id = '7e621000-0000-4000-8000-000000000002' $$,
  'las dos valen hasta 1000 € justos'
);

-- =====================================================================
-- 2. requests.weeks
-- =====================================================================
select is(
  (select format('%s %s %s', c.data_type, c.is_nullable, coalesce(c.column_default, '-'))
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'requests' and c.column_name = 'weeks'),
  'smallint NO 1',
  'requests.weeks: smallint obligatorio, 1 por defecto'
);

-- Un pedido de A cargado sin weeks, como todos los anteriores a la migración.
with r as (
  insert into public.requests (chef_id, client_id, type, adults, kids, days, meals)
  values ('7e621000-0000-4000-8000-000000000001', '7e622000-0000-4000-8000-00000000000a', 'week', 2, 0, 5, '{dinner}')
  returning id
)
insert into ids (k, v) select 'a_sin_semanas', id from r;

select is(
  (select r.weeks::int from public.requests r where r.id = (select v from ids where k = 'a_sin_semanas')),
  1,
  'un pedido sin weeks queda en 1 (los anteriores a la migración eran de una semana)'
);
select lives_ok(
  $$ with r as (
       insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, weeks)
       values ('7e621000-0000-4000-8000-000000000001', '7e622000-0000-4000-8000-00000000000a', 'week', 2, 0, 5, '{dinner}', 8)
       returning id)
     insert into ids (k, v) select 'a_ocho', id from r $$,
  'un pedido semanal de 8 semanas'
);
select lives_ok(
  $$ with r as (
       insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, weeks)
       values ('7e621000-0000-4000-8000-000000000001', '7e622000-0000-4000-8000-00000000000a', 'extra', 6, 0, 1, '{dinner}', 1)
       returning id)
     insert into ids (k, v) select 'a_extra', id from r $$,
  'una sesión extra, con weeks = 1'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, weeks)
     values ('7e621000-0000-4000-8000-000000000001', '7e622000-0000-4000-8000-00000000000a', 'week', 2, 0, 5, '{dinner}', 0) $$,
  '23514', 'new row for relation "requests" violates check constraint "requests_semanas_validas"',
  'semanas: al menos 1'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, weeks)
     values ('7e621000-0000-4000-8000-000000000001', '7e622000-0000-4000-8000-00000000000a', 'week', 2, 0, 5, '{dinner}', 9) $$,
  '23514', 'new row for relation "requests" violates check constraint "requests_semanas_validas"',
  'y como mucho 8'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, weeks)
     values ('7e621000-0000-4000-8000-000000000001', '7e622000-0000-4000-8000-00000000000a', 'extra', 6, 0, 1, '{dinner}', 2) $$,
  '23514', 'new row for relation "requests" violates check constraint "requests_semanas_solo_week"',
  'una sesión extra no es de varias semanas'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, text, weeks)
     values ('7e621000-0000-4000-8000-000000000001', '7e622000-0000-4000-8000-00000000000a', 'change', 'Più verdure', 2) $$,
  '23514', 'new row for relation "requests" violates check constraint "requests_semanas_solo_week"',
  'ni un pedido de cambio'
);

-- =====================================================================
-- 3. submit_public_request
-- =====================================================================
select lives_ok(
  $$ select pg_temp.submit('sin_campo', pg_temp.payload()) $$,
  'sin weeks (la función de hoy, mientras se despliega la nueva): se guarda igual'
);
select lives_ok(
  $$ select pg_temp.submit('nulo', pg_temp.payload('{"weeks": null}')) $$,
  'weeks null: también'
);
select lives_ok(
  $$ select pg_temp.submit('una', pg_temp.payload('{"weeks": 1}')) $$,
  'una semana'
);
select lives_ok(
  $$ select pg_temp.submit('cuatro', pg_temp.payload('{"weeks": 4}')) $$,
  'cuatro semanas'
);
select lives_ok(
  $$ select pg_temp.submit('ocho', pg_temp.payload('{"weeks": 8}')) $$,
  'ocho, el máximo'
);
select lives_ok(
  $$ select pg_temp.submit('extra', pg_temp.payload('{"type": "extra", "adults": 8, "kids": 0, "days": 1}')) $$,
  'una sesión extra sin weeks'
);
select lives_ok(
  $$ select pg_temp.submit('extra_una', pg_temp.payload('{"type": "extra", "adults": 8, "kids": 0, "days": 1, "weeks": 1}')) $$,
  'una sesión extra con weeks = 1'
);
select results_eq(
  $$ select ids.k, r.weeks::int from public.requests r join ids on ids.v = r.id
     where ids.k in ('sin_campo', 'nulo', 'una', 'cuatro', 'ocho', 'extra', 'extra_una')
     order by ids.k collate "C" $$,
  $$ values ('cuatro'::text, 4), ('extra', 1), ('extra_una', 1), ('nulo', 1), ('ocho', 8), ('sin_campo', 1), ('una', 1) $$,
  'guarda las semanas que llegan; sin el campo o en null, 1'
);

-- Defensa (la Edge Function valida antes).
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"weeks": 0}')) $$,
  '22023', 'invalid_weeks',
  'weeks 0: rechazado'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"weeks": 9}')) $$,
  '22023', 'invalid_weeks',
  'ni 9 (más de 8 semanas)'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"weeks": 2.5}')) $$,
  '22023', 'invalid_weeks',
  'ni un número con decimales'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"weeks": "4"}')) $$,
  '22023', 'invalid_weeks',
  'ni un texto, aunque diga un número'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"type": "extra", "adults": 8, "kids": 0, "days": 1, "weeks": 2}')) $$,
  '22023', 'weeks_only_for_week',
  'una sesión extra de 2 semanas: rechazada'
);
select is(
  (select count(*)::int from public.requests r where r.contact ->> 'email' = 'anna@semanas.test'),
  7,
  'los rechazos no guardan nada: siguen los 7 pedidos de Anna'
);

-- Idempotencia: un reintento no cambia lo guardado.
select lives_ok(
  $$ select pg_temp.submit('clave', pg_temp.payload(
       '{"email": "carla@semanas.test", "name": "Carla Vitali", "weeks": 2,
         "request_key": "6c1d8b63-2e3f-4a5b-8c9d-1e2f3a4b5c6d"}')) $$,
  'pedido de 2 semanas con clave de idempotencia'
);
select is(
  public.submit_public_request(pg_temp.payload(
    '{"email": "carla@semanas.test", "name": "Carla Vitali", "weeks": 6,
      "request_key": "6c1d8b63-2e3f-4a5b-8c9d-1e2f3a4b5c6d"}')) ->> 'duplicate',
  'true',
  'el reintento con la misma clave es un duplicado, aunque pida otras semanas'
);
select is(
  (select r.weeks::int from public.requests r where r.id = (select v from ids where k = 'clave')),
  2,
  'y lo guardado no cambia'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload(
       '{"email": "carla@semanas.test", "name": "Carla Vitali", "weeks": 9,
         "request_key": "6c1d8b63-2e3f-4a5b-8c9d-1e2f3a4b5c6d"}')) $$,
  '22023', 'invalid_weeks',
  'un reintento con semanas inválidas falla igual (se valida antes de buscar la clave)'
);

-- La estimación es un objeto que la base guarda tal cual: su forma la decide quote.ts. Por
-- ejemplo, una sin precio del servicio (más personas que weekly_rate_max_people).
select lives_ok(
  $$ select pg_temp.submit('sin_precio', pg_temp.payload(
       '{"email": "rota@semanas.test", "name": "Famiglia Rota", "adults": 4, "kids": 3, "weeks": 3,
         "estimate": {"portions": 35, "recipes": 3, "cookMinutes": 240, "groceriesEstCents": 11650,
                      "pricing": {"weeklyRateMaxPeople": 5}}}')) $$,
  'una estimación sin precio del servicio (7 personas, 3 semanas): se guarda'
);
select is(
  (select r.estimate from public.requests r where r.id = (select v from ids where k = 'sin_precio')),
  '{"portions": 35, "recipes": 3, "cookMinutes": 240, "groceriesEstCents": 11650,
    "pricing": {"weeklyRateMaxPeople": 5}}'::jsonb,
  'tal cual llegó'
);
select is(
  (select array_agg(clave order by clave) from jsonb_object_keys((select res from ids where k = 'sin_precio')) as clave),
  array['duplicate', 'estimate', 'menu', 'request_id'],
  'y la respuesta sigue siendo {request_id, duplicate, estimate}, más menu (17_menu_web)'
);

-- =====================================================================
-- 4. Privilegios y RLS: los de antes
-- =====================================================================
select ok(
  has_column_privilege('authenticated', 'public.requests', 'weeks', 'SELECT')
  and not has_column_privilege('authenticated', 'public.requests', 'weeks', 'INSERT')
  and not has_column_privilege('authenticated', 'public.requests', 'weeks', 'UPDATE'),
  'requests.weeks: authenticated la lee (con RLS) y no la escribe; la pone submit_public_request'
);
select is(
  (select array_agg(a.attname::text order by a.attname)
   from pg_attribute a
   where a.attrelid = 'public.requests'::regclass and a.attnum > 0 and not a.attisdropped
     and has_column_privilege('authenticated', 'public.requests', a.attname, 'INSERT')),
  array['adults', 'chef_id', 'client_id', 'days', 'id', 'kids', 'locale', 'meals', 'notes', 'pay_mode',
        'preferred_date', 'preferred_slot', 'preferred_start', 'restrictions', 'status', 'target_session_id',
        'text', 'type', 'whatsapp_opt_in', 'wishes'],
  'authenticated: al crear un pedido escribe las mismas columnas que antes'
);
select is(
  (select array_agg(a.attname::text order by a.attname)
   from pg_attribute a
   where a.attrelid = 'public.requests'::regclass and a.attnum > 0 and not a.attisdropped
     and has_column_privilege('authenticated', 'public.requests', a.attname, 'UPDATE')),
  array['seen_at', 'status'],
  'y desde la app solo cambia seen_at y status'
);
select ok(
  (select bool_and(has_column_privilege('authenticated', 'public.chef_settings', c, 'SELECT')
                   and has_column_privilege('authenticated', 'public.chef_settings', c, 'INSERT')
                   and has_column_privilege('authenticated', 'public.chef_settings', c, 'UPDATE')
                   and has_column_privilege('service_role', 'public.chef_settings', c, 'SELECT'))
   from unnest(array['weekly_rate_cents', 'weekly_rate_discounted_cents', 'weekly_discount_min_weeks',
                     'weekly_rate_max_people']) as c),
  'las tarifas nuevas, como las demás: authenticated las gestiona (RLS: solo la cocinera dueña) y service_role las lee (Edge Function)'
);
select ok(
  not has_column_privilege('anon', 'public.requests', 'weeks', 'SELECT,INSERT,UPDATE')
  and (select bool_and(not has_column_privilege('anon', 'public.chef_settings', c, 'SELECT,INSERT,UPDATE'))
       from unnest(array['weekly_rate_cents', 'weekly_rate_discounted_cents', 'weekly_discount_min_weeks',
                         'weekly_rate_max_people']) as c),
  'anon no ve ni escribe las semanas ni las tarifas nuevas'
);
select is(
  (select array_agg(format('%s | %s | %s | %s', p.tablename, p.policyname, p.cmd, p.roles::text)
                    order by p.tablename, p.policyname)
   from pg_policies p
   where p.schemaname = 'public' and p.tablename in ('requests', 'chef_settings')),
  array[
    'chef_settings | chef_settings: la cocinera gestiona las suyas | ALL | {authenticated}',
    'requests | requests: el cliente crea los suyos (siempre como new) | INSERT | {authenticated}',
    'requests | requests: el cliente lee los suyos | SELECT | {authenticated}',
    'requests | requests: la cocinera gestiona los suyos | ALL | {authenticated}'
  ],
  'RLS: las políticas de requests y chef_settings son las mismas'
);
select ok(
  not has_function_privilege('anon', 'public.submit_public_request(jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.submit_public_request(jsonb)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.submit_public_request(jsonb)', 'EXECUTE')
  and (select p.prosecdef and p.proconfig = array['search_path=""']
       from pg_proc p where p.oid = 'public.submit_public_request(jsonb)'::regprocedure),
  'submit_public_request: la ejecuta solo service_role, security definer y search_path vacío'
);

-- Cocinera 1
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e620000-0000-4000-8000-00000000c001","role":"authenticated"}';
select results_eq(
  $$ select chef_id, weekly_rate_cents, weekly_rate_discounted_cents, weekly_discount_min_weeks, weekly_rate_max_people
     from public.chef_settings $$,
  $$ values ('7e621000-0000-4000-8000-000000000001'::uuid, 15000, 14000, 4, 5) $$,
  'C1: ve sus tarifas por semana y no las de nadie más'
);
select lives_ok(
  $$ update public.chef_settings set weekly_rate_cents = 16000, weekly_rate_discounted_cents = 15000
     where chef_id = '7e621000-0000-4000-8000-000000000001' $$,
  'C1: cambia sus tarifas por semana'
);
-- Las de C2 no las ve: el update no encuentra filas (se comprueba al final, como postgres).
update public.chef_settings set weekly_rate_max_people = 2 where chef_id = '7e621000-0000-4000-8000-000000000002';
select results_eq(
  $$ select ids.k, r.weeks::int from public.requests r join ids on ids.v = r.id
     where ids.k in ('a_ocho', 'a_sin_semanas', 'cuatro') order by ids.k collate "C" $$,
  $$ values ('a_ocho'::text, 8), ('a_sin_semanas', 1), ('cuatro', 4) $$,
  'C1: lee las semanas de sus pedidos (de la app y de la web)'
);
select throws_ok(
  $$ update public.requests set weeks = 2 where id = (select v from ids where k = 'cuatro') $$,
  '42501', null,
  'C1: no cambia las semanas de un pedido desde la app'
);

-- Cliente A (con cuenta)
set local request.jwt.claims = '{"sub":"7e620000-0000-4000-8000-00000000a001","role":"authenticated"}';
select is(
  (select count(*)::int from public.chef_settings),
  0,
  'A: no ve ninguna tarifa'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, weeks)
     values ('7e621000-0000-4000-8000-000000000001', '7e622000-0000-4000-8000-00000000000a', 'week', 2, 0, 5, '{dinner}', 3) $$,
  '42501', null,
  'A: no elige las semanas al crear un pedido desde la app'
);
select lives_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals)
     values ('7e621000-0000-4000-8000-000000000001', '7e622000-0000-4000-8000-00000000000a', 'week', 2, 0, 5, '{lunch}') $$,
  'A: crea un pedido como antes, sin weeks'
);
select results_eq(
  $$ select r.weeks::int from public.requests r order by r.weeks, r.created_at $$,
  $$ values (1), (1), (1), (8) $$,
  'A: ve las semanas de sus pedidos y solo de los suyos (el que acaba de crear, en 1)'
);

-- Anónimo
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select throws_ok(
  $$ select weekly_rate_cents from public.chef_settings $$,
  '42501', null,
  'anon: sin acceso a las tarifas'
);
reset role;

select results_eq(
  $$ select chef_id, weekly_rate_cents, weekly_rate_max_people from public.chef_settings
     where chef_id in ('7e621000-0000-4000-8000-000000000001', '7e621000-0000-4000-8000-000000000002')
     order by chef_id $$,
  $$ values ('7e621000-0000-4000-8000-000000000001'::uuid, 16000, 5),
            ('7e621000-0000-4000-8000-000000000002'::uuid, 1000000, 60) $$,
  'C1 cambió las suyas y no las de C2'
);

select finish();
rollback;
