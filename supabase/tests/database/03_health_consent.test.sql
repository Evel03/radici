-- =====================================================================
-- Datos de salud (SPEC §6): sin consentimiento health_data vigente no se
-- guardan restricciones; al revocarlo se borran.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(23);

-- ---------------------------------------------------------------------
-- Fixture: cocinera, cliente K con cuenta y prospecto P sin cuenta
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e570000-0000-4000-8000-00000000c001', 'chef@consent.test'),
  ('7e570000-0000-4000-8000-00000000a001', 'k@consent.test');
update public.profiles set role = 'chef' where id = '7e570000-0000-4000-8000-00000000c001';
insert into public.chefs (id, profile_id, display_name) values
  ('7e571000-0000-4000-8000-000000000001', '7e570000-0000-4000-8000-00000000c001', 'Chef');
insert into public.clients (id, chef_id, profile_id, display_name, status, contact_email) values
  ('7e572000-0000-4000-8000-00000000000a', '7e571000-0000-4000-8000-000000000001', '7e570000-0000-4000-8000-00000000a001', 'Cliente K', 'active', null),
  ('7e572000-0000-4000-8000-00000000000c', '7e571000-0000-4000-8000-000000000001', null, 'Prospecto P', 'prospect', 'p@consent.test');

-- ---------------------------------------------------------------------
-- Sin consentimiento: rechazo para cualquier rol (también postgres / service role)
-- ---------------------------------------------------------------------
select throws_ok(
  $$ insert into public.client_restrictions (chef_id, client_id, allergen)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000c', 'milk') $$,
  'P0001', 'health_data_consent_required',
  'sin consentimiento de salud no se guarda la restricción (aun con la service role)'
);

insert into public.consents (chef_id, client_id, kind, text_version)
values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000c', 'privacy', 'privacy-v1');

select throws_ok(
  $$ insert into public.client_restrictions (chef_id, client_id, allergen)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000c', 'milk') $$,
  'P0001', 'health_data_consent_required',
  'el consentimiento de privacidad no alcanza: hace falta el de salud, separado'
);

-- ---------------------------------------------------------------------
-- Flujo del cliente con cuenta
-- ---------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e570000-0000-4000-8000-00000000a001","role":"authenticated"}';

select throws_ok(
  $$ insert into public.client_restrictions (chef_id, client_id, allergen)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'gluten') $$,
  'P0001', 'health_data_consent_required',
  'cliente: sin consentimiento no puede guardar su restricción'
);

select throws_ok(
  $$ insert into public.consents (chef_id, client_id, kind, text_version, granted_at)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'health_data', 'health-v1', now() - interval '1 year') $$,
  '42501', null,
  'cliente: no puede antedatar el consentimiento (granted_at lo pone la base)'
);

select lives_ok(
  $$ insert into public.consents (chef_id, client_id, kind, text_version)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'health_data', 'health-v1') $$,
  'cliente: otorga el consentimiento de salud'
);

select throws_ok(
  $$ insert into public.consents (chef_id, client_id, kind, text_version)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'health_data', 'health-v2') $$,
  '23505', null,
  'no puede haber dos consentimientos de salud vigentes a la vez'
);

select lives_ok(
  $$ insert into public.client_restrictions (chef_id, client_id, allergen)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'gluten') $$,
  'cliente: con consentimiento guarda un alérgeno'
);

select lives_ok(
  $$ insert into public.client_restrictions (chef_id, client_id, diet)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'vegetarian') $$,
  'cliente: con consentimiento guarda una dieta'
);

select throws_ok(
  $$ insert into public.client_restrictions (chef_id, client_id, allergen, diet)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'eggs', 'vegan') $$,
  '23514', null,
  'una fila es un alérgeno o una dieta, no ambos'
);

select throws_ok(
  $$ delete from public.consents where client_id = '7e572000-0000-4000-8000-00000000000a' $$,
  '42501', null,
  'cliente: no puede borrar consentimientos (son la prueba del consentimiento)'
);

select lives_ok(
  $$ update public.consents set revoked_at = now()
     where client_id = '7e572000-0000-4000-8000-00000000000a' and kind = 'health_data' and revoked_at is null $$,
  'cliente: revoca el consentimiento de salud'
);

select is(
  (select count(*)::int from public.client_restrictions where client_id = '7e572000-0000-4000-8000-00000000000a'),
  0,
  'al revocar el consentimiento se borran sus restricciones'
);

select throws_ok(
  $$ insert into public.client_restrictions (chef_id, client_id, allergen)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'gluten') $$,
  'P0001', 'health_data_consent_required',
  'revocado el consentimiento, no se pueden volver a guardar restricciones'
);

select throws_ok(
  $$ update public.consents set revoked_at = null
     where client_id = '7e572000-0000-4000-8000-00000000000a' and kind = 'health_data' $$,
  'P0001', 'consent_already_revoked',
  'un consentimiento revocado no se reactiva'
);

-- ---------------------------------------------------------------------
-- Revocación registrada por la cocinera; privacidad no afecta restricciones
-- ---------------------------------------------------------------------
reset role;
insert into public.consents (chef_id, client_id, kind, text_version)
values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000c', 'health_data', 'health-v1');
insert into public.client_restrictions (chef_id, client_id, allergen)
values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000c', 'milk');

update public.consents set revoked_at = now()
where client_id = '7e572000-0000-4000-8000-00000000000c' and kind = 'privacy';

select is(
  (select count(*)::int from public.client_restrictions where client_id = '7e572000-0000-4000-8000-00000000000c'),
  1,
  'revocar privacidad no borra las restricciones'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e570000-0000-4000-8000-00000000c001","role":"authenticated"}';

select lives_ok(
  $$ update public.consents set revoked_at = now()
     where client_id = '7e572000-0000-4000-8000-00000000000c' and kind = 'health_data' and revoked_at is null $$,
  'cocinera: registra la revocación del consentimiento de salud de un prospecto'
);

reset role;

select is(
  (select count(*)::int from public.client_restrictions where client_id = '7e572000-0000-4000-8000-00000000000c'),
  0,
  'la revocación registrada por la cocinera también borra las restricciones'
);

-- ---------------------------------------------------------------------
-- private.revoke_health_consent: retiro pedido por el cliente (contrato §10).
-- Revoca y borra también las copias en sus pedidos; las de otro cliente quedan.
-- ---------------------------------------------------------------------
insert into public.clients (id, chef_id, display_name, status, contact_email) values
  ('7e572000-0000-4000-8000-00000000000d', '7e571000-0000-4000-8000-000000000001', 'Prospecto Q', 'prospect', 'q@consent.test');
insert into public.consents (chef_id, client_id, kind, text_version)
values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000d', 'health_data', 'health-v1');
insert into public.client_restrictions (chef_id, client_id, allergen)
values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000d', 'peanuts');
insert into public.requests (chef_id, client_id, type, adults, kids, days, meals, restrictions) values
  ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000d', 'week', 2, 0, 5, '{dinner}',
   '{"allergens": ["peanuts"], "diets": [], "note": ""}'),
  ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000d', 'extra', 6, 0, 1, '{dinner}',
   '{"allergens": [], "diets": ["vegan"], "note": "un invitato"}'),
  ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000c', 'week', 1, 0, 3, '{lunch}',
   '{"allergens": ["milk"], "diets": [], "note": ""}');

select is(
  (select array_agg(format('%s → %s', r, 'revoke_health_consent') order by r)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, 'private.revoke_health_consent(uuid)', 'EXECUTE')),
  null::text[],
  'revoke_health_consent: ningún rol de la API la ejecuta (se corre desde el SQL editor)'
);
select is(
  private.revoke_health_consent('7e572000-0000-4000-8000-00000000000d'),
  '{"consents": 1, "requests": 2}'::jsonb,
  'revoca el consentimiento vigente y borra las copias de sus dos pedidos'
);
select results_eq(
  $$ select (select count(*)::int from public.consents
             where client_id = '7e572000-0000-4000-8000-00000000000d' and kind = 'health_data' and revoked_at is null),
            (select count(*)::int from public.client_restrictions where client_id = '7e572000-0000-4000-8000-00000000000d'),
            (select count(*)::int from public.requests
             where client_id = '7e572000-0000-4000-8000-00000000000d' and restrictions is not null) $$,
  $$ values (0, 0, 0) $$,
  'sin consentimiento vigente, sin restricciones del hogar y sin copias en los pedidos'
);
select is(
  (select restrictions from public.requests where client_id = '7e572000-0000-4000-8000-00000000000c'),
  '{"allergens": ["milk"], "diets": [], "note": ""}'::jsonb,
  'los pedidos de otro cliente no se tocan'
);
select is(
  private.revoke_health_consent('7e572000-0000-4000-8000-00000000000d'),
  '{"consents": 0, "requests": 0}'::jsonb,
  'otra vez no hace nada (idempotente)'
);
select throws_ok(
  $$ select private.revoke_health_consent('7e572000-0000-4000-8000-0000000000ff') $$,
  'P0002', 'client_not_found',
  'un cliente que no existe: error claro'
);

select finish();
rollback;
