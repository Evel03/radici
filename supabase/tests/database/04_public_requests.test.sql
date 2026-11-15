-- =====================================================================
-- Pedido desde la web (docs/contracts/public-request.md §3):
-- columnas nuevas de requests, submit_public_request, límite por IP,
-- promote_to_chef, Realtime y lo que ve y hace cada uno con el pedido nuevo.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(101);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
--   C1 recibe los pedidos de la web; C2 es otra cocinera.
--   A es cliente con cuenta de C1 con el mismo email que la persona del
--   formulario (giulia@public.test): no se tiene que tocar.
--   P2 es un prospecto de C2 con ese mismo email: tampoco.
--   E será promovida a cocinera.
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e580000-0000-4000-8000-00000000c001', 'chef1@public.test'),
  ('7e580000-0000-4000-8000-00000000c002', 'chef2@public.test'),
  ('7e580000-0000-4000-8000-00000000a001', 'giulia@public.test'),
  ('7e580000-0000-4000-8000-00000000e001', 'Nuova.Cuoca@Public.test');
update public.profiles set role = 'chef'
where id in ('7e580000-0000-4000-8000-00000000c001', '7e580000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e581000-0000-4000-8000-000000000001', '7e580000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e581000-0000-4000-8000-000000000002', '7e580000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e581000-0000-4000-8000-000000000001'),
  ('7e581000-0000-4000-8000-000000000002');

insert into public.clients (id, chef_id, profile_id, display_name, status, contact_email, contact_phone, zone) values
  ('7e582000-0000-4000-8000-00000000000a', '7e581000-0000-4000-8000-000000000001', '7e580000-0000-4000-8000-00000000a001',
   'Cliente A', 'active', 'Giulia@Public.test', '+390000000001', 'Zona A'),
  ('7e582000-0000-4000-8000-00000000000f', '7e581000-0000-4000-8000-000000000002', null,
   'Prospetto di C2', 'prospect', 'giulia@public.test', '+390000000002', 'Treviglio');
insert into public.consents (chef_id, client_id, kind, text_version) values
  ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'health_data', 'v1');
insert into public.client_restrictions (chef_id, client_id, allergen) values
  ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'nuts');

-- Payload como lo arma la Edge Function (snake_case). p_extra pisa claves.
create function pg_temp.payload(p_extra jsonb default '{}') returns jsonb
language sql
as $$
  select jsonb_build_object(
    'chef_id', '7e581000-0000-4000-8000-000000000001',
    'type', 'week', 'adults', 2, 'kids', 2, 'days', 5, 'meals', jsonb_build_array('dinner'),
    'allergens', jsonb_build_array(), 'diets', jsonb_build_array(), 'restrictions_note', '',
    'preferred_date', null, 'preferred_slot', 'any',
    'name', 'Giulia Rossi', 'zone', 'Città Alta', 'phone', '+393331234567', 'email', 'giulia@public.test',
    'whatsapp_opt_in', true, 'notes', '', 'locale', 'it',
    'privacy_consent_version', '2026-10-19', 'health_consent_version', null,
    'estimate', jsonb_build_object('portions', 20, 'totalCents', 14100,
                                   'pricing', jsonb_build_object('hourlyRateCents', 2200))
  ) || p_extra
$$;

-- ids generados durante el test (los usuarios simulados también los leen)
create temp table ids (k text primary key, v uuid);
grant select on ids to anon, authenticated, service_role;

-- =====================================================================
-- 1. Esquema
-- =====================================================================
select is(
  (select array_agg(format('%s %s %s %s', c.column_name, c.data_type, c.is_nullable, coalesce(c.column_default, '-'))
                    order by c.column_name)
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'requests'
     and c.column_name in ('preferred_slot', 'locale', 'whatsapp_opt_in', 'estimate', 'source', 'seen_at', 'contact')),
  array[
    'contact jsonb YES -',
    'estimate jsonb YES -',
    'locale text NO ''it''::text',
    'preferred_slot text YES -',
    'seen_at timestamp with time zone YES -',
    'source text NO ''app''::text',
    'whatsapp_opt_in boolean NO false'
  ],
  'requests: columnas nuevas con el tipo, la nulabilidad y el default del contrato'
);

select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, preferred_slot)
     values ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'week', 1, 0, 1, '{dinner}', 'night') $$,
  '23514', null, 'preferred_slot solo admite morning, afternoon o any');
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, locale)
     values ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'week', 1, 0, 1, '{dinner}', 'fr') $$,
  '23514', null, 'locale solo admite it, es o en');
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, source)
     values ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'week', 1, 0, 1, '{dinner}', 'email') $$,
  '23514', null, 'source solo admite web o app');
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, estimate)
     values ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'week', 1, 0, 1, '{dinner}', '[]') $$,
  '23514', null, 'estimate, si está, es un objeto JSON');

select ok(
  exists (select 1 from pg_publication_tables
          where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'requests'),
  'requests está en la publicación supabase_realtime (aviso en vivo en la app)'
);

-- =====================================================================
-- 2. Funciones nuevas: security definer, search_path vacío, solo service_role
-- =====================================================================
select is(
  (select array_agg(p.proname::text order by p.proname)
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('submit_public_request', 'hit_public_request_rate', 'promote_to_chef')
     and p.prosecdef
     and p.proconfig @> array['search_path=""']),
  array['hit_public_request_rate', 'promote_to_chef', 'submit_public_request'],
  'las tres funciones son security definer con search_path vacío'
);

select is(
  (select array_agg(format('%s → %s', r, f) order by 1)
   from unnest(array['public.submit_public_request(jsonb)',
                     'public.hit_public_request_rate(text,integer,integer)',
                     'public.promote_to_chef(text,text)']) as f
   cross join unnest(array['anon', 'authenticated']) as r
   where has_function_privilege(r, f, 'EXECUTE')),
  null::text[],
  'anon y authenticated no pueden ejecutar las funciones nuevas'
);

select ok(
  (select bool_and(has_function_privilege('service_role', f, 'EXECUTE'))
   from unnest(array['public.submit_public_request(jsonb)',
                     'public.hit_public_request_rate(text,integer,integer)',
                     'public.promote_to_chef(text,text)']) as f),
  'la service role ejecuta las tres'
);

set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select throws_ok(
  $$ select public.submit_public_request('{}'::jsonb) $$,
  '42501', 'permission denied for function submit_public_request',
  'anon: no puede guardar un pedido salteando la Edge Function');
select throws_ok(
  $$ select public.hit_public_request_rate(repeat('a', 64), 5, 20) $$,
  '42501', 'permission denied for function hit_public_request_rate',
  'anon: no puede tocar el límite por IP');

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e580000-0000-4000-8000-00000000c001","role":"authenticated"}';
select throws_ok(
  $$ select public.submit_public_request('{}'::jsonb) $$,
  '42501', 'permission denied for function submit_public_request',
  'authenticated (aunque sea la cocinera): tampoco');
select throws_ok(
  $$ select public.promote_to_chef('giulia@public.test', 'Giulia') $$,
  '42501', 'permission denied for function promote_to_chef',
  'authenticated: no puede convertir a nadie en cocinera');
reset role;

-- =====================================================================
-- 3. Registro de intentos: esquema private, fuera de la API
-- =====================================================================
select ok(
  not has_schema_privilege('anon', 'private', 'USAGE')
  and not has_schema_privilege('authenticated', 'private', 'USAGE')
  and not has_schema_privilege('service_role', 'private', 'USAGE'),
  'el esquema private no es accesible para anon, authenticated ni service_role'
);
select is(
  (select c.relrowsecurity from pg_class c where c.oid = 'private.public_request_hits'::regclass),
  true,
  'public_request_hits tiene RLS habilitado'
);
select is(
  (select count(*)::int from pg_policies where schemaname = 'private' and tablename = 'public_request_hits'),
  0,
  'public_request_hits no tiene políticas'
);
select throws_ok(
  $$ insert into private.public_request_hits (ip_hash) values ('203.0.113.7') $$,
  '23514', null,
  'la IP en claro no se puede guardar: solo un hash SHA-256 en hexadecimal'
);

-- =====================================================================
-- 4. hit_public_request_rate: 5 por hora y 20 por día por IP
-- =====================================================================
select is(
  (select array_agg(public.hit_public_request_rate(repeat('a', 64), 5, 20) order by n) from generate_series(1, 7) as n),
  array[true, true, true, true, true, false, false],
  'por hora: pasan los 5 primeros intentos; el 6.º y los siguientes, no'
);
select is(
  (select count(*)::int from private.public_request_hits where ip_hash = repeat('a', 64)),
  7,
  'se registran todos los intentos, también los rechazados'
);
select is(
  public.hit_public_request_rate(repeat('b', 64), 5, 20),
  true,
  'cada IP tiene su propio contador'
);

insert into private.public_request_hits (ip_hash, created_at)
select repeat('c', 64), now() - interval '3 hours' from generate_series(1, 19);
select is(
  (select array_agg(public.hit_public_request_rate(repeat('c', 64), 5, 20) order by n) from generate_series(1, 2) as n),
  array[true, false],
  'por día: con 19 intentos de hace 3 horas pasa el 20.º y no el 21.º (los de hace más de una hora no cuentan para la hora)'
);

insert into private.public_request_hits (ip_hash, created_at) values
  (repeat('d', 64), now() - interval '3 days'),
  (repeat('d', 64), now() - interval '25 hours');
select ok(public.hit_public_request_rate(repeat('e', 64), 5, 20), 'un intento de otra IP pasa');
select is(
  (select count(*)::int from private.public_request_hits where ip_hash = repeat('d', 64)),
  0,
  'cada llamada borra los registros de más de 1 día (ya no cuentan para ninguna ventana)'
);
select throws_ok(
  $$ select public.hit_public_request_rate('203.0.113.7', 5, 20) $$,
  '22023', 'invalid_ip_hash',
  'rechaza una IP sin hashear'
);

-- =====================================================================
-- 5. submit_public_request: prospecto nuevo
-- =====================================================================
set local role service_role;
select lives_ok(
  $$ select public.submit_public_request(pg_temp.payload()) $$,
  'service role: guarda el pedido de Giulia (sin restricciones)'
);
reset role;

insert into ids (k, v)
select 'giulia', cl.id from public.clients cl
where cl.chef_id = '7e581000-0000-4000-8000-000000000001' and cl.status = 'prospect'
  and cl.contact_email = 'giulia@public.test';
insert into ids (k, v)
select 'r_giulia', r.id from public.requests r where r.client_id = (select v from ids where k = 'giulia');

select is(
  (select count(*)::int from public.clients
   where chef_id = '7e581000-0000-4000-8000-000000000001' and lower(contact_email) = 'giulia@public.test'),
  2,
  'el email es de un cliente con cuenta: se crea un prospecto nuevo al lado (Evelyn los une a mano)'
);
select results_eq(
  $$ select display_name, contact_email, contact_phone, zone, profile_id, status::text, adults, kids
     from public.clients where id = (select v from ids where k = 'giulia') $$,
  $$ values ('Giulia Rossi'::text, 'giulia@public.test'::text, '+393331234567'::text, 'Città Alta'::text,
             null::uuid, 'prospect'::text, 2::smallint, 2::smallint) $$,
  'el prospecto guarda nombre, email, teléfono E.164, zona y el hogar del pedido semanal'
);
select results_eq(
  $$ select display_name, contact_phone, zone, status::text
     from public.clients where id = '7e582000-0000-4000-8000-00000000000a' $$,
  $$ values ('Cliente A'::text, '+390000000001'::text, 'Zona A'::text, 'active'::text) $$,
  'el cliente con cuenta del mismo email no se modifica'
);
select is(
  (select array_agg(allergen::text) from public.client_restrictions
   where client_id = '7e582000-0000-4000-8000-00000000000a'),
  array['nuts'],
  'ni se le tocan las restricciones'
);
select results_eq(
  $$ select display_name, contact_phone from public.clients where id = '7e582000-0000-4000-8000-00000000000f' $$,
  $$ values ('Prospetto di C2'::text, '+390000000002'::text) $$,
  'el prospecto de otra cocinera con el mismo email no se reutiliza ni se modifica'
);
select results_eq(
  $$ select r.type::text, r.status::text, r.source, r.locale, r.whatsapp_opt_in, r.preferred_slot, r.preferred_date,
            r.adults, r.kids, r.days, r.meals, r.restrictions, r.notes, r.seen_at, r.estimate
     from public.requests r where r.id = (select v from ids where k = 'r_giulia') $$,
  $$ values ('week'::text, 'new'::text, 'web'::text, 'it'::text, true, 'any'::text, null::date,
             2::smallint, 2::smallint, 5::smallint, array['dinner']::text[], null::jsonb, null::text, null::timestamptz,
             '{"portions": 20, "totalCents": 14100, "pricing": {"hourlyRateCents": 2200}}'::jsonb) $$,
  'el pedido queda new, con origen web, idioma, WhatsApp, franja y la estimación del servidor; sin restricciones'
);
select is(
  (select r.contact from public.requests r where r.id = (select v from ids where k = 'r_giulia')),
  '{"name": "Giulia Rossi", "zone": "Città Alta", "phone": "+393331234567", "email": "giulia@public.test"}'::jsonb,
  'el pedido guarda la copia del contacto tal como llegó (la app la muestra en lugar de la ficha)'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, contact)
     values ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'week', 1, 0, 1, '{dinner}', '"x"') $$,
  '23514', null, 'contact, si está, es un objeto JSON');
select is(
  (select array_agg(kind::text || ':' || text_version order by kind) from public.consents
   where client_id = (select v from ids where k = 'giulia') and revoked_at is null),
  array['privacy:2026-10-19'],
  'sin restricciones: solo el consentimiento de privacidad'
);
select is(
  (select count(*)::int from public.client_restrictions where client_id = (select v from ids where k = 'giulia')),
  0,
  'sin restricciones no se guarda ninguna'
);
select results_eq(
  $$ select n.profile_id, n.kind, n.channel, n.payload, n.sent_at from public.notifications n
     where n.payload ->> 'request_id' = (select v from ids where k = 'r_giulia')::text $$,
  $$ values ('7e580000-0000-4000-8000-00000000c001'::uuid, 'new_request'::text, 'email'::text,
             jsonb_build_object('request_id', (select v from ids where k = 'r_giulia')), null::timestamptz) $$,
  'una notificación por email para el perfil de la cocinera, con el id del pedido y todavía sin enviar'
);

-- =====================================================================
-- 6. Restricciones: solo con consentimiento de salud
-- =====================================================================
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload(
       '{"email": "marco@public.test", "name": "Marco", "allergens": ["milk"]}')) $$,
  'P0001', 'health_consent_required',
  'con restricciones y sin consentimiento de salud: rechazado'
);
select is(
  (select count(*)::int from public.clients where lower(contact_email) = 'marco@public.test'),
  0,
  'y no queda nada guardado'
);
select lives_ok(
  $$ select public.submit_public_request(pg_temp.payload(
       '{"email": "Marco@Public.test", "name": "Marco Bianchi", "phone": "+393401112233", "zone": "Redona",
         "allergens": ["milk", "gluten"], "diets": ["vegan"], "restrictions_note": "niente maiale",
         "health_consent_version": "2026-10-19", "type": "extra", "locale": "es", "whatsapp_opt_in": false,
         "preferred_date": "2026-10-25", "preferred_slot": "morning", "meals": ["lunch", "dinner"],
         "notes": "Citofono rotto"}')) $$,
  'con consentimiento de salud se guarda el pedido con restricciones'
);
insert into ids (k, v)
select 'marco', cl.id from public.clients cl
where cl.chef_id = '7e581000-0000-4000-8000-000000000001' and lower(cl.contact_email) = 'marco@public.test';
insert into ids (k, v)
select 'r_marco1', r.id from public.requests r where r.client_id = (select v from ids where k = 'marco');

select is(
  (select array_agg(kind::text || ':' || text_version order by kind) from public.consents
   where client_id = (select v from ids where k = 'marco') and revoked_at is null),
  array['health_data:2026-10-19', 'privacy:2026-10-19'],
  'se guardan los consentimientos de salud y de privacidad'
);
select is(
  (select count(*)::int from public.client_restrictions where client_id = (select v from ids where k = 'marco')),
  0,
  'un evento: las restricciones son de los invitados y quedan solo en la copia del pedido, no en el hogar'
);
select results_eq(
  $$ select restrictions, type::text, locale, whatsapp_opt_in, preferred_date, preferred_slot, meals, notes
     from public.requests where id = (select v from ids where k = 'r_marco1') $$,
  $$ values ('{"allergens": ["gluten", "milk"], "diets": ["vegan"], "note": "niente maiale"}'::jsonb,
             'extra'::text, 'es'::text, false, '2026-10-25'::date, 'morning'::text,
             array['lunch', 'dinner']::text[], 'Citofono rotto'::text) $$,
  'el pedido guarda la copia de las restricciones (orden canónico, con la nota) y los demás datos'
);

-- =====================================================================
-- 7. Reutilización del prospecto (mismo chef, mismo email sin distinguir mayúsculas)
-- =====================================================================
select lives_ok(
  $$ select public.submit_public_request(pg_temp.payload(
       '{"email": "MARCO@public.TEST", "name": "Marco B.", "phone": "+393409998877", "zone": "Borgo Palazzo",
         "allergens": ["eggs"], "health_consent_version": "2026-10-19"}')) $$,
  'segundo pedido del mismo prospecto'
);
select is(
  (select array_agg(id) from public.clients
   where chef_id = '7e581000-0000-4000-8000-000000000001' and lower(contact_email) = 'marco@public.test'),
  array[(select v from ids where k = 'marco')],
  'reutiliza el prospecto: no crea otro'
);
insert into ids (k, v)
select 'r_marco2', r.id from public.requests r
where r.client_id = (select v from ids where k = 'marco') and r.id <> (select v from ids where k = 'r_marco1');

select results_eq(
  $$ select display_name, contact_phone, zone from public.clients where id = (select v from ids where k = 'marco') $$,
  $$ values ('Marco Bianchi'::text, '+393401112233'::text, 'Redona'::text) $$,
  'no le cambia nombre, teléfono ni zona: un envío sin login no modifica a una persona que ya existe'
);
select is(
  (select contact from public.requests where id = (select v from ids where k = 'r_marco2')),
  '{"name": "Marco B.", "zone": "Borgo Palazzo", "phone": "+393409998877", "email": "marco@public.test"}'::jsonb,
  'lo que llegó con el pedido nuevo queda en su copia del contacto'
);
select is(
  (select contact from public.requests where id = (select v from ids where k = 'r_marco1')),
  '{"name": "Marco Bianchi", "zone": "Redona", "phone": "+393401112233", "email": "marco@public.test"}'::jsonb,
  'y el pedido anterior conserva el suyo (Evelyn lo contacta con los datos de ese pedido)'
);
select is(
  (select array_agg(coalesce(allergen::text, diet::text)) from public.client_restrictions
   where client_id = (select v from ids where k = 'marco')),
  array['eggs'],
  'un pedido semanal suma sus restricciones a las del hogar'
);
select is(
  (select count(*)::int from public.consents
   where client_id = (select v from ids where k = 'marco') and revoked_at is null),
  2,
  'con la misma versión del texto no duplica los consentimientos vigentes'
);
select is(
  (select count(*)::int from public.requests where client_id = (select v from ids where k = 'marco')),
  2,
  'el prospecto tiene sus dos pedidos'
);

select lives_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"email": "marco@public.test", "name": "Marco B."}')) $$,
  'tercer pedido, ahora sin restricciones'
);
select is(
  (select count(*)::int from public.client_restrictions where client_id = (select v from ids where k = 'marco')),
  1,
  'un pedido sin restricciones no borra las del hogar (desde la web nunca se borran)'
);
select is(
  (select count(*)::int from public.consents
   where client_id = (select v from ids where k = 'marco') and kind = 'health_data' and revoked_at is null),
  1,
  'el consentimiento de salud anterior sigue vigente (cubre las copias de los pedidos anteriores)'
);
select is(
  (select count(*)::int from public.requests
   where client_id = (select v from ids where k = 'marco') and restrictions is null),
  1,
  'y el pedido nuevo no lleva restricciones'
);

select lives_ok(
  $$ select public.submit_public_request(pg_temp.payload(
       '{"email": "marco@public.test", "name": "Marco B.", "allergens": ["eggs", "gluten"], "diets": ["vegan"],
         "health_consent_version": "2026-10-19"}')) $$,
  'cuarto pedido semanal, con otras restricciones'
);
select is(
  (select array_agg(coalesce(allergen::text, diet::text) order by coalesce(allergen::text, diet::text))
   from public.client_restrictions where client_id = (select v from ids where k = 'marco')),
  array['eggs', 'gluten', 'vegan'],
  'se suman a las que ya tenía el hogar, sin repetir'
);

select lives_ok(
  $$ select public.submit_public_request(pg_temp.payload(
       '{"email": "marco@public.test", "name": "Marco B.", "privacy_consent_version": "2027-01-01"}')) $$,
  'pedido con una versión nueva del texto de privacidad'
);
select results_eq(
  $$ select text_version, revoked_at is null from public.consents
     where client_id = (select v from ids where k = 'marco') and kind = 'privacy'
     order by revoked_at nulls last $$,
  $$ values ('2026-10-19'::text, false), ('2027-01-01'::text, true) $$,
  'la versión nueva reemplaza a la anterior, que queda cerrada como traza'
);

-- =====================================================================
-- 8. Validaciones de defensa (la Edge Function ya valida con parsePublicRequest)
-- =====================================================================
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"chef_id": "7e581000-0000-4000-8000-0000000000ff"}')) $$,
  'P0002', 'chef_not_found', 'cocinera inexistente');
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"type": "change"}')) $$,
  '22023', 'invalid_request_type', 'desde la web no se piden cambios de sesión');
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"privacy_consent_version": null}')) $$,
  'P0001', 'privacy_consent_required', 'sin consentimiento de privacidad no se guarda nada');
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"email": " "}')) $$,
  '22023', 'email_required', 'el email es obligatorio');
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"estimate": null}')) $$,
  '22023', 'estimate_required', 'la estimación calculada por el servidor es obligatoria');

-- =====================================================================
-- 9. promote_to_chef
-- =====================================================================
select throws_ok(
  $$ select public.promote_to_chef('nadie@public.test', 'Nadie') $$,
  'P0002', 'user_not_found', 'email sin usuario de auth: error claro');

-- Alguien registró antes ese email con una contraseña suya (contrato §8).
update auth.users set encrypted_password = extensions.crypt('clave-de-otra-persona', extensions.gen_salt('bf'))
where id = '7e580000-0000-4000-8000-00000000e001';
select throws_ok(
  $$ select public.promote_to_chef('nuova.cuoca@public.test', 'Nuova Cuoca') $$,
  'P0001', 'user_not_confirmed',
  'email sin confirmar: no se promueve (que entre una vez con el código o crearlo confirmado)');
select is(
  (select role::text from public.profiles where id = '7e580000-0000-4000-8000-00000000e001'),
  'client',
  'y el perfil sigue siendo de cliente'
);

-- Ya confirmado (entró con el código), pero con la sesión, los refresh tokens y un factor MFA de la otra persona.
update auth.users set email_confirmed_at = now() where id = '7e580000-0000-4000-8000-00000000e001';
insert into auth.sessions (id, user_id) values ('7e589000-0000-4000-8000-000000000001', '7e580000-0000-4000-8000-00000000e001');
insert into auth.refresh_tokens (token, user_id, session_id, revoked) values
  ('rt-de-la-sesion', '7e580000-0000-4000-8000-00000000e001', '7e589000-0000-4000-8000-000000000001', false),
  ('rt-sin-sesion',   '7e580000-0000-4000-8000-00000000e001', null, false);
insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
values ('7e589100-0000-4000-8000-000000000001', '7e580000-0000-4000-8000-00000000e001', 'otra persona', 'totp', 'verified', now(), now());

insert into ids (k, v) values ('chef3', public.promote_to_chef('  nuova.cuoca@public.test ', 'Nuova Cuoca'));

select ok(
  (select u.encrypted_password <> extensions.crypt('clave-de-otra-persona', u.encrypted_password)
   from auth.users u where u.id = '7e580000-0000-4000-8000-00000000e001'),
  'la contraseña que había puesto otra persona ya no sirve (queda una al azar: se entra con el código)'
);
select is(
  (select count(*)::int from auth.sessions where user_id = '7e580000-0000-4000-8000-00000000e001'),
  0,
  'sus sesiones se cierran'
);
select is(
  (select count(*)::int from auth.refresh_tokens where user_id = '7e580000-0000-4000-8000-00000000e001'),
  0,
  'y se borran sus refresh tokens, también los que no tenían sesión'
);
select is(
  (select count(*)::int from auth.mfa_factors where user_id = '7e580000-0000-4000-8000-00000000e001'),
  0,
  'y sus factores MFA'
);

select is(
  (select role::text from public.profiles where id = '7e580000-0000-4000-8000-00000000e001'),
  'chef',
  'el perfil pasa a rol chef (el email no distingue mayúsculas)'
);
select results_eq(
  $$ select id, display_name from public.chefs where profile_id = '7e580000-0000-4000-8000-00000000e001' $$,
  $$ values ((select v from ids where k = 'chef3'), 'Nuova Cuoca'::text) $$,
  'crea la ficha en chefs y devuelve su id'
);
select results_eq(
  $$ select hourly_rate_cents, travel_fee_cents, booking_horizon_days
     from public.chef_settings where chef_id = (select v from ids where k = 'chef3') $$,
  $$ values (2200, 1200, 56) $$,
  'con las tarifas y la ventana (8 semanas) por defecto'
);
select is(
  public.promote_to_chef('NUOVA.CUOCA@PUBLIC.TEST', 'Nuova Cuoca'),
  (select v from ids where k = 'chef3'),
  'repetirla devuelve la misma cocinera'
);
select is(
  (select count(*)::int from public.chefs where profile_id = '7e580000-0000-4000-8000-00000000e001'),
  1,
  'sin duplicar la ficha'
);

-- =====================================================================
-- 10. Bandeja: la cocinera ve y gestiona el pedido; nadie más lo ve
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e580000-0000-4000-8000-00000000c001","role":"authenticated"}';

select is(
  (select count(*)::int from public.requests where id in (select v from ids where k in ('r_giulia', 'r_marco1'))),
  2,
  'C1: ve los pedidos nuevos de la web'
);
select is(
  (select restrictions from public.requests where id = (select v from ids where k = 'r_marco1')),
  '{"allergens": ["gluten", "milk"], "diets": ["vegan"], "note": "niente maiale"}'::jsonb,
  'C1: ve las restricciones del pedido (la cocinera sí las ve)'
);
select lives_ok(
  $$ update public.requests set seen_at = now() where id = (select v from ids where k = 'r_giulia') $$,
  'C1: marca el pedido como visto'
);
select lives_ok(
  $$ update public.requests set status = 'rejected' where id = (select v from ids where k = 'r_giulia') $$,
  'C1: lo rechaza (new → rejected)'
);
select results_eq(
  $$ select status::text, seen_at is not null from public.requests where id = (select v from ids where k = 'r_giulia') $$,
  $$ values ('rejected'::text, true) $$,
  'C1: el pedido queda visto y rechazado'
);
select lives_ok(
  $$ update public.requests set status = 'new' where id = (select v from ids where k = 'r_giulia') $$,
  'C1: puede deshacer el rechazo (rejected → new)'
);
select throws_ok(
  $$ update public.requests set status = 'accepted' where id = (select v from ids where k = 'r_marco1') $$,
  '42501', 'request_status_change_not_allowed',
  'C1: no acepta ni presupuesta desde la app (esos estados los pone el servidor)'
);
select throws_ok(
  $$ update public.requests set restrictions = null where id = (select v from ids where k = 'r_marco1') $$,
  '42501', null,
  'C1: no puede modificar la copia de las restricciones'
);
select throws_ok(
  $$ update public.requests set estimate = '{"totalCents": 1}' where id = (select v from ids where k = 'r_marco1') $$,
  '42501', null,
  'C1: no puede modificar la estimación del servidor'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, status, adults, kids, days, meals)
     values ('7e581000-0000-4000-8000-000000000001', (select v from ids where k = 'giulia'), 'week', 'accepted', 1, 0, 1, '{dinner}') $$,
  '42501', 'request_status_change_not_allowed',
  'C1: tampoco crea un pedido ya aceptado (la guarda vale también en el alta)'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, status, adults, kids, days, meals)
     values ('7e581000-0000-4000-8000-000000000001', (select v from ids where k = 'giulia'), 'week', 'quoted', 1, 0, 1, '{dinner}') $$,
  '42501', 'request_status_change_not_allowed',
  'C1: ni uno ya presupuestado'
);
select lives_ok(
  $$ insert into public.requests (chef_id, client_id, type, status, adults, kids, days, meals, preferred_slot)
     values ('7e581000-0000-4000-8000-000000000001', (select v from ids where k = 'giulia'), 'week', 'new', 1, 0, 1, '{dinner}', 'afternoon') $$,
  'C1: un pedido en new sí lo puede crear (por ejemplo, uno que le llegó por teléfono)'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, contact)
     values ('7e581000-0000-4000-8000-000000000001', (select v from ids where k = 'giulia'), 'week', 1, 0, 1, '{dinner}', '{"name": "x"}') $$,
  '42501', null,
  'C1: no escribe la copia del contacto (solo la escribe submit_public_request)'
);
select throws_ok(
  $$ update public.requests set contact = '{"phone": "+390000000000"}' where id = (select v from ids where k = 'r_giulia') $$,
  '42501', null,
  'C1: ni la cambia'
);
select is(
  (select count(*)::int from public.notifications
   where payload ->> 'request_id' = (select v from ids where k = 'r_giulia')::text),
  1,
  'C1: ve su notificación del pedido nuevo'
);
select throws_ok(
  $$ update public.notifications set sent_at = now() $$,
  '42501', null,
  'C1: no marca notificaciones como enviadas (lo hace la Edge Function)'
);

-- Cocinera 2
set local request.jwt.claims = '{"sub":"7e580000-0000-4000-8000-00000000c002","role":"authenticated"}';
select is(
  (select count(*)::int from public.requests where source = 'web'),
  0,
  'C2: no ve los pedidos de la web de C1'
);
select lives_ok(
  $$ update public.requests set seen_at = null, status = 'rejected' where id = (select v from ids where k = 'r_giulia') $$,
  'C2: un update sobre el pedido de C1 no afecta filas'
);
select is(
  (select count(*)::int from public.notifications where kind = 'new_request'),
  0,
  'C2: no ve las notificaciones de C1'
);

-- Cliente A (de C1, con el mismo email que Giulia)
set local request.jwt.claims = '{"sub":"7e580000-0000-4000-8000-00000000a001","role":"authenticated"}';
select is(
  (select count(*)::int from public.requests where source = 'web'),
  0,
  'A: no ve el pedido de la web aunque tenga el mismo email'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, seen_at)
     values ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'week', 1, 0, 3, '{dinner}', now()) $$,
  '42501', null,
  'A: no crea pedidos ya marcados como vistos'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, source)
     values ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'week', 1, 0, 3, '{dinner}', 'web') $$,
  '42501', null,
  'A: no puede hacer pasar su pedido por uno de la web'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, estimate)
     values ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'week', 1, 0, 3, '{dinner}', '{"totalCents": 1}') $$,
  '42501', null,
  'A: no puede escribir la estimación'
);
select lives_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, preferred_slot, locale)
     values ('7e581000-0000-4000-8000-000000000001', '7e582000-0000-4000-8000-00000000000a', 'week', 1, 0, 3, '{dinner}', 'morning', 'es') $$,
  'A: sigue creando sus pedidos desde la app, con franja e idioma'
);

-- =====================================================================
-- Verificación final como postgres
-- =====================================================================
reset role;

select results_eq(
  $$ select status::text, seen_at is not null from public.requests where id = (select v from ids where k = 'r_giulia') $$,
  $$ values ('new'::text, true) $$,
  'el update de C2 no cambió nada: el pedido sigue visto y en new'
);
select is(
  (select source from public.requests
   where client_id = '7e582000-0000-4000-8000-00000000000a' and preferred_slot = 'morning'),
  'app',
  'el pedido creado desde la app queda con origen app'
);

select finish();
rollback;
