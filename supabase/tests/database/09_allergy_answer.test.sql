-- =====================================================================
-- Pregunta de alergias del formulario web (contrato v2, docs/contracts/public-request.md §3):
-- requests.no_allergies, lo que guarda submit_public_request, que la app solo
-- lo lee (privilegios y RLS) y que retirar el consentimiento de salud borra
-- también el "hay alergias" del pedido.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(40);

-- ---------------------------------------------------------------------
-- Fixture (como postgres): C1 recibe los pedidos de la web; C2 es otra
-- cocinera; A es cliente con cuenta de C1.
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e610000-0000-4000-8000-00000000c001', 'chef1@allergy.test'),
  ('7e610000-0000-4000-8000-00000000c002', 'chef2@allergy.test'),
  ('7e610000-0000-4000-8000-00000000a001', 'cliente@allergy.test');
update public.profiles set role = 'chef'
where id in ('7e610000-0000-4000-8000-00000000c001', '7e610000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e611000-0000-4000-8000-000000000001', '7e610000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e611000-0000-4000-8000-000000000002', '7e610000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e611000-0000-4000-8000-000000000001'),
  ('7e611000-0000-4000-8000-000000000002');
insert into public.clients (id, chef_id, profile_id, display_name, status, contact_email) values
  ('7e612000-0000-4000-8000-00000000000a', '7e611000-0000-4000-8000-000000000001', '7e610000-0000-4000-8000-00000000a001',
   'Cliente A', 'active', 'cliente@allergy.test');

-- Payload como lo arma la Edge Function de la v2 (snake_case): por defecto,
-- "nadie tiene alergias". p_extra pisa claves.
create function pg_temp.payload(p_extra jsonb default '{}') returns jsonb
language sql
as $$
  select jsonb_build_object(
    'chef_id', '7e611000-0000-4000-8000-000000000001',
    'type', 'week', 'adults', 2, 'kids', 1, 'days', 5, 'meals', jsonb_build_array('dinner'),
    'no_allergies', true,
    'allergens', jsonb_build_array(), 'diets', jsonb_build_array(), 'restrictions_note', '',
    'preferred_date', null, 'preferred_slot', 'any',
    'name', 'Lucia Neri', 'zone', 'Loreto', 'phone', '+393331234000', 'email', 'lucia@allergy.test',
    'whatsapp_opt_in', false, 'notes', '', 'locale', 'it',
    'privacy_consent_version', '2026-11-16', 'health_consent_version', null,
    'estimate', jsonb_build_object('portions', 15, 'totalCents', 12850,
                                   'pricing', jsonb_build_object('hourlyRateCents', 2200))
  ) || p_extra
$$;

-- Ids de los pedidos guardados (los usuarios simulados también los leen).
create temp table ids (k text primary key, v uuid);
grant select on ids to anon, authenticated, service_role;

create function pg_temp.submit(p_key text, p jsonb) returns void
language sql
as $$
  insert into ids (k, v) values (p_key, (public.submit_public_request(p) ->> 'request_id')::uuid)
$$;

-- =====================================================================
-- 1. Esquema y privilegios
-- =====================================================================
select is(
  (select format('%s %s %s', c.data_type, c.is_nullable, coalesce(c.column_default, '-'))
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'requests' and c.column_name = 'no_allergies'),
  'boolean YES -',
  'requests.no_allergies: boolean, opcional y sin default (null = sin respuesta)'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, no_allergies, restrictions)
     values ('7e611000-0000-4000-8000-000000000001', '7e612000-0000-4000-8000-00000000000a', 'week', 1, 0, 1, '{dinner}',
             true, '{"allergens": [], "diets": [], "note": "noci"}') $$,
  '23514', null,
  '"nadie tiene alergias" nunca va junto con restricciones'
);
select lives_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, no_allergies, restrictions) values
       ('7e611000-0000-4000-8000-000000000001', '7e612000-0000-4000-8000-00000000000a', 'week', 1, 0, 1, '{dinner}',
        true, null),
       ('7e611000-0000-4000-8000-000000000001', '7e612000-0000-4000-8000-00000000000a', 'week', 1, 0, 1, '{dinner}',
        false, '{"allergens": [], "diets": [], "note": "noci"}'),
       ('7e611000-0000-4000-8000-000000000001', '7e612000-0000-4000-8000-00000000000a', 'week', 1, 0, 1, '{dinner}',
        null, '{"allergens": ["milk"], "diets": [], "note": ""}') $$,
  'sí valen "nadie" sin restricciones, "hay" con restricciones y sin respuesta (pedidos viejos), con o sin ellas'
);
select ok(
  has_column_privilege('authenticated', 'public.requests', 'no_allergies', 'SELECT')
  and not has_column_privilege('authenticated', 'public.requests', 'no_allergies', 'INSERT')
  and not has_column_privilege('authenticated', 'public.requests', 'no_allergies', 'UPDATE'),
  'authenticated la lee (con RLS) pero no la escribe: la pone solo submit_public_request'
);
select ok(
  not has_column_privilege('anon', 'public.requests', 'no_allergies', 'SELECT'),
  'anon no la ve'
);

-- =====================================================================
-- 2. submit_public_request
-- =====================================================================
select lives_ok(
  $$ select pg_temp.submit('nadie', pg_temp.payload()) $$,
  'v2: guarda un pedido con "nadie tiene alergias"'
);
select results_eq(
  $$ select r.no_allergies, r.restrictions from public.requests r where r.id = (select v from ids where k = 'nadie') $$,
  $$ values (true, null::jsonb) $$,
  'queda no_allergies = true, sin restricciones'
);
select is(
  (select array_agg(c.kind::text order by c.kind) from public.consents c
   where c.revoked_at is null
     and c.client_id = (select r.client_id from public.requests r where r.id = (select v from ids where k = 'nadie'))),
  array['privacy'],
  'sin alergias no hay consentimiento de salud: solo el de privacidad'
);

select lives_ok(
  $$ select pg_temp.submit('hay', pg_temp.payload(
       '{"email": "marta@allergy.test", "name": "Marta Riva", "no_allergies": false,
         "restrictions_note": "Celiachia (Marco)\nAllergia alle noci", "health_consent_version": "2026-11-16"}')) $$,
  'v2: guarda un pedido con las alergias escritas y el consentimiento de salud'
);
select results_eq(
  $$ select r.no_allergies, r.restrictions from public.requests r where r.id = (select v from ids where k = 'hay') $$,
  $$ values (false, jsonb_build_object('allergens', jsonb_build_array(), 'diets', jsonb_build_array(),
                                      'note', E'Celiachia (Marco)\nAllergia alle noci')) $$,
  'queda no_allergies = false y la nota en la copia de las restricciones, con su salto de línea'
);
select is(
  (select c.text_version from public.consents c
   where c.kind = 'health_data' and c.revoked_at is null
     and c.client_id = (select r.client_id from public.requests r where r.id = (select v from ids where k = 'hay'))),
  '2026-11-16',
  'con el consentimiento de salud de la versión del texto que aceptó'
);

select lives_ok(
  $$ select pg_temp.submit('vieja', pg_temp.payload('{"email": "vieja@allergy.test", "name": "Vieja"}') - 'no_allergies') $$,
  'sin no_allergies (la función de antes de la v2, mientras se despliega la nueva): se guarda igual'
);
select is(
  (select r.no_allergies from public.requests r where r.id = (select v from ids where k = 'vieja')),
  null::boolean,
  'y queda sin respuesta (null), como los pedidos anteriores'
);
select lives_ok(
  $$ select pg_temp.submit('nula', pg_temp.payload('{"email": "nula@allergy.test", "name": "Nula", "no_allergies": null}')) $$,
  'no_allergies null: también se guarda'
);
select is(
  (select r.no_allergies from public.requests r where r.id = (select v from ids where k = 'nula')),
  null::boolean,
  'sin respuesta'
);

-- Validaciones de defensa (la Edge Function ya valida con parsePublicRequest).
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"no_allergies": "no"}')) $$,
  '22023', 'invalid_no_allergies',
  'no_allergies que no es booleano: rechazado'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"no_allergies": 1}')) $$,
  '22023', 'invalid_no_allergies',
  'ni un número'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload(
       '{"restrictions_note": "noci", "health_consent_version": "2026-11-16"}')) $$,
  '22023', 'no_allergies_with_restrictions',
  '"nadie tiene alergias" con una nota: rechazado (no se sabe cuál vale)'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload(
       '{"allergens": ["milk"], "health_consent_version": "2026-11-16"}')) $$,
  '22023', 'no_allergies_with_restrictions',
  'tampoco con alérgenos marcados'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"no_allergies": false}')) $$,
  '22023', 'restrictions_required',
  '"hay alergias" sin escribirlas: rechazado'
);
select throws_ok(
  $$ select public.submit_public_request(pg_temp.payload('{"no_allergies": false, "restrictions_note": "noci"}')) $$,
  'P0001', 'health_consent_required',
  'alergias escritas sin consentimiento de salud: rechazado, como siempre'
);
select is(
  (select count(*)::int from public.requests r join public.clients cl on cl.id = r.client_id
   where lower(cl.contact_email) = 'lucia@allergy.test'),
  1,
  'los rechazos no guardan nada: Lucía sigue con su único pedido'
);

-- Idempotencia: un reintento no cambia la respuesta guardada.
select lives_ok(
  $$ select pg_temp.submit('clave', pg_temp.payload(
       '{"email": "clave@allergy.test", "name": "Clave", "request_key": "5b0c7a52-1d2e-4f3a-9b8c-0d1e2f3a4b5c"}')) $$,
  'pedido con clave de idempotencia y "nadie tiene alergias"'
);
select is(
  public.submit_public_request(pg_temp.payload(
    '{"email": "clave@allergy.test", "name": "Clave", "request_key": "5b0c7a52-1d2e-4f3a-9b8c-0d1e2f3a4b5c",
      "no_allergies": false, "restrictions_note": "noci", "health_consent_version": "2026-11-16"}')) ->> 'duplicate',
  'true',
  'el reintento con la misma clave es un duplicado, aunque traiga otra respuesta'
);
select results_eq(
  $$ select r.no_allergies, r.restrictions from public.requests r where r.id = (select v from ids where k = 'clave') $$,
  $$ values (true, null::jsonb) $$,
  'y lo guardado no cambia'
);

-- =====================================================================
-- 3. RLS: quién ve la respuesta y quién la puede escribir
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e610000-0000-4000-8000-00000000c001","role":"authenticated"}';
select results_eq(
  $$ select ids.k, r.no_allergies from public.requests r join ids on ids.v = r.id
     where ids.k in ('nadie', 'hay', 'vieja') order by ids.k $$,
  $$ values ('hay'::text, false), ('nadie'::text, true), ('vieja'::text, null::boolean) $$,
  'C1: lee la respuesta de sus pedidos (true, false o sin respuesta)'
);
select throws_ok(
  $$ update public.requests set no_allergies = true where id = (select v from ids where k = 'hay') $$,
  '42501', null,
  'C1: no la cambia desde la app'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, no_allergies)
     values ('7e611000-0000-4000-8000-000000000001', '7e612000-0000-4000-8000-00000000000a', 'week', 1, 0, 1, '{dinner}', true) $$,
  '42501', null,
  'C1: ni la escribe al crear un pedido'
);

set local request.jwt.claims = '{"sub":"7e610000-0000-4000-8000-00000000c002","role":"authenticated"}';
select is(
  (select count(*)::int from public.requests r where r.id in (select v from ids)),
  0,
  'C2: no ve los pedidos de C1 (ni su respuesta)'
);

set local request.jwt.claims = '{"sub":"7e610000-0000-4000-8000-00000000a001","role":"authenticated"}';
select is(
  (select count(*)::int from public.requests r where r.id in (select v from ids)),
  0,
  'A (cliente con cuenta de C1): no ve los pedidos de la web de otras personas'
);
select is(
  (select array_agg(r.no_allergies order by r.no_allergies nulls last) from public.requests r
   where r.client_id = '7e612000-0000-4000-8000-00000000000a'),
  array[false, true, null]::boolean[],
  'A: ve la respuesta de sus propios pedidos'
);
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, no_allergies)
     values ('7e611000-0000-4000-8000-000000000001', '7e612000-0000-4000-8000-00000000000a', 'week', 1, 0, 3, '{dinner}', true) $$,
  '42501', null,
  'A: tampoco la escribe en sus pedidos de la app'
);

set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select throws_ok(
  $$ select no_allergies from public.requests $$,
  '42501', null,
  'anon: sin acceso'
);
reset role;

-- =====================================================================
-- 4. Retiro del consentimiento de salud (private.revoke_health_consent)
-- =====================================================================
select is(
  private.revoke_health_consent((select r.client_id from public.requests r where r.id = (select v from ids where k = 'hay'))),
  '{"consents": 1, "requests": 1}'::jsonb,
  'Marta retira el consentimiento de salud: se revoca y se limpia su pedido'
);
select results_eq(
  $$ select r.no_allergies, r.restrictions from public.requests r where r.id = (select v from ids where k = 'hay') $$,
  $$ values (null::boolean, null::jsonb) $$,
  'sin la nota y sin el "hay alergias" (que también es un dato de salud): el pedido queda sin respuesta'
);
select is(
  private.revoke_health_consent((select r.client_id from public.requests r where r.id = (select v from ids where k = 'hay'))),
  '{"consents": 0, "requests": 0}'::jsonb,
  'otra vez no hace nada (idempotente)'
);
select is(
  private.revoke_health_consent((select r.client_id from public.requests r where r.id = (select v from ids where k = 'nadie'))),
  '{"consents": 0, "requests": 0}'::jsonb,
  'a quien confirmó que nadie tiene alergias no le cambia nada'
);
select is(
  (select r.no_allergies from public.requests r where r.id = (select v from ids where k = 'nadie')),
  true,
  'su pedido sigue con "nadie tiene alergias"'
);
select is(
  private.revoke_health_consent('7e612000-0000-4000-8000-00000000000a'),
  '{"consents": 0, "requests": 2}'::jsonb,
  'A: limpia sus dos pedidos con alergias (uno escrito y uno viejo, con alérgenos marcados)'
);
select is(
  (select array_agg(s.estado order by s.estado) from (
     select format('%s/%s', coalesce(r.no_allergies::text, 'null'), (r.restrictions is not null)::text) as estado
     from public.requests r where r.client_id = '7e612000-0000-4000-8000-00000000000a') s),
  array['null/false', 'null/false', 'true/false'],
  'y deja el de "nadie tiene alergias" como estaba'
);

select finish();
rollback;
