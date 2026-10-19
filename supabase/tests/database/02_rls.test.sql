-- =====================================================================
-- RLS con usuarios simulados (SPEC §6 "RLS (resumen)", criterios 6 y 7).
--
-- Cocinera 1 (C1) con clientes A, B y un prospecto P; cocinera 2 (C2) con
-- cliente X. Cada cliente tiene pedido, sesión, presupuesto, menú, ticket,
-- pago, restricción, consentimientos, porciones y despensa.
-- Se cambia de usuario con:
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<uuid>","role":"authenticated"}';
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(81);

-- ---------------------------------------------------------------------
-- Fixture (como postgres: sin RLS)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e570000-0000-4000-8000-00000000c001', 'chef1@rls.test'),
  ('7e570000-0000-4000-8000-00000000c002', 'chef2@rls.test'),
  ('7e570000-0000-4000-8000-00000000a001', 'a@rls.test'),
  ('7e570000-0000-4000-8000-00000000b001', 'b@rls.test'),
  ('7e570000-0000-4000-8000-00000000f001', 'x@rls.test');
update public.profiles set role = 'chef'
where id in ('7e570000-0000-4000-8000-00000000c001', '7e570000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e571000-0000-4000-8000-000000000001', '7e570000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e571000-0000-4000-8000-000000000002', '7e570000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e571000-0000-4000-8000-000000000001'),
  ('7e571000-0000-4000-8000-000000000002');
insert into public.availability_rules (chef_id, dow, start_time, end_time) values
  ('7e571000-0000-4000-8000-000000000001', 1, '09:00', '18:00'),
  ('7e571000-0000-4000-8000-000000000002', 2, '10:00', '19:00');

insert into public.clients (id, chef_id, profile_id, display_name, status, share_pantry, adults) values
  ('7e572000-0000-4000-8000-00000000000a', '7e571000-0000-4000-8000-000000000001', '7e570000-0000-4000-8000-00000000a001', 'Cliente A', 'active', true, 2),
  ('7e572000-0000-4000-8000-00000000000b', '7e571000-0000-4000-8000-000000000001', '7e570000-0000-4000-8000-00000000b001', 'Cliente B', 'active', false, 2),
  ('7e572000-0000-4000-8000-00000000000c', '7e571000-0000-4000-8000-000000000001', null, 'Prospecto P', 'prospect', false, 2),
  ('7e572000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', '7e570000-0000-4000-8000-00000000f001', 'Cliente X', 'active', true, 1);

insert into public.consents (chef_id, client_id, kind, text_version) values
  ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'health_data', 'v1'),
  ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'privacy',     'v1'),
  ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000b', 'health_data', 'v1'),
  ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000b', 'privacy',     'v1'),
  ('7e571000-0000-4000-8000-000000000002', '7e572000-0000-4000-8000-00000000000f', 'health_data', 'v1');

insert into public.client_restrictions (chef_id, client_id, allergen) values
  ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'milk'),
  ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000b', 'gluten'),
  ('7e571000-0000-4000-8000-000000000002', '7e572000-0000-4000-8000-00000000000f', 'nuts');

insert into public.recipes (id, chef_id, name_it, active) values
  ('7e576000-0000-4000-8000-000000000001', '7e571000-0000-4000-8000-000000000001', 'Minestrone', true),
  ('7e576000-0000-4000-8000-000000000002', '7e571000-0000-4000-8000-000000000001', 'Ricetta ritirata', false),
  ('7e576000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', 'Ossobuco', true);
insert into public.recipe_allergens (recipe_id, chef_id, allergen) values
  ('7e576000-0000-4000-8000-000000000001', '7e571000-0000-4000-8000-000000000001', 'celery'),
  ('7e576000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', 'gluten');

insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals) values
  ('7e573000-0000-4000-8000-00000000000a', '7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'week', 'accepted', 2, 0, 5, '{dinner}'),
  ('7e573000-0000-4000-8000-00000000000b', '7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000b', 'week', 'accepted', 2, 0, 5, '{dinner}'),
  ('7e573000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', '7e572000-0000-4000-8000-00000000000f', 'week', 'accepted', 1, 0, 5, '{lunch}');

insert into public.sessions (id, chef_id, client_id, request_id, date, start_time, cook_minutes, status) values
  ('7e574000-0000-4000-8000-00000000000a', '7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', '7e573000-0000-4000-8000-00000000000a', '2027-02-01', '10:00', 150, 'confirmed'),
  ('7e574000-0000-4000-8000-00000000000b', '7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000b', '7e573000-0000-4000-8000-00000000000b', '2027-02-02', '10:00', 150, 'cooked'),
  ('7e574000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', '7e572000-0000-4000-8000-00000000000f', '7e573000-0000-4000-8000-00000000000f', '2027-02-01', '10:00', 150, 'confirmed');

insert into public.quotes (id, chef_id, request_id, session_id, cook_minutes, portions, service_cents, groceries_est_cents, preauth_cents) values
  ('7e575000-0000-4000-8000-00000000000a', '7e571000-0000-4000-8000-000000000001', '7e573000-0000-4000-8000-00000000000a', '7e574000-0000-4000-8000-00000000000a', 150, 10, 6700, 3800, 4370),
  ('7e575000-0000-4000-8000-00000000000b', '7e571000-0000-4000-8000-000000000001', '7e573000-0000-4000-8000-00000000000b', '7e574000-0000-4000-8000-00000000000b', 150, 10, 6700, 3800, 4370),
  ('7e575000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', '7e573000-0000-4000-8000-00000000000f', '7e574000-0000-4000-8000-00000000000f', 150, 5, 6700, 1900, 2185);

insert into public.session_menu (session_id, recipe_id, chef_id, portions) values
  ('7e574000-0000-4000-8000-00000000000a', '7e576000-0000-4000-8000-000000000001', '7e571000-0000-4000-8000-000000000001', 10),
  ('7e574000-0000-4000-8000-00000000000b', '7e576000-0000-4000-8000-000000000001', '7e571000-0000-4000-8000-000000000001', 10),
  ('7e574000-0000-4000-8000-00000000000f', '7e576000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', 5);

insert into public.receipts (id, chef_id, session_id, storage_path, total_cents) values
  ('7e577000-0000-4000-8000-00000000000a', '7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000a',
   '7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000a/ticket.jpg', 3900),
  ('7e577000-0000-4000-8000-00000000000b', '7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000b',
   '7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000b/ticket.jpg', 4100),
  ('7e577000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', '7e574000-0000-4000-8000-00000000000f',
   '7e571000-0000-4000-8000-000000000002/7e574000-0000-4000-8000-00000000000f/ticket.jpg', 2000);

insert into public.payments (id, chef_id, session_id, kind, provider, amount_cents, status) values
  ('7e578000-0000-4000-8000-00000000000a', '7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000a', 'preauth', 'stripe', 11070, 'authorized'),
  ('7e578000-0000-4000-8000-00000000000b', '7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000b', 'cash', 'cash', 10600, 'pending'),
  ('7e578000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', '7e574000-0000-4000-8000-00000000000f', 'preauth', 'stripe', 8885, 'authorized');

insert into public.prepared_portions (id, chef_id, client_id, session_id, recipe_id, count_initial, count_left, made_on, consume_by) values
  ('7e579000-0000-4000-8000-00000000000a', '7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a',
   '7e574000-0000-4000-8000-00000000000a', '7e576000-0000-4000-8000-000000000001', 5, 5, '2027-02-01', '2027-02-05'),
  ('7e579000-0000-4000-8000-00000000000b', '7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000b',
   '7e574000-0000-4000-8000-00000000000b', '7e576000-0000-4000-8000-000000000001', 5, 5, '2027-02-02', '2027-02-06');

insert into public.pantry_items (id, chef_id, client_id, name) values
  ('7e57a000-0000-4000-8000-00000000000a', '7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'Zucchine'),
  ('7e57a000-0000-4000-8000-00000000000b', '7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000b', 'Riso'),
  ('7e57a000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', '7e572000-0000-4000-8000-00000000000f', 'Latte');

insert into public.notifications (profile_id, kind, channel) values
  ('7e570000-0000-4000-8000-00000000a001', 'session_reminder', 'push'),
  ('7e570000-0000-4000-8000-00000000b001', 'session_reminder', 'push');

insert into storage.objects (bucket_id, name) values
  ('receipts', '7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000a/ticket.jpg'),
  ('receipts', '7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000b/ticket.jpg'),
  ('receipts', '7e571000-0000-4000-8000-000000000002/7e574000-0000-4000-8000-00000000000f/ticket.jpg');

-- =====================================================================
-- Cliente A
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e570000-0000-4000-8000-00000000a001","role":"authenticated"}';

select is((select array_agg(id order by id) from public.clients),
  array['7e572000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo su ficha de cliente');
select is((select array_agg(id order by id) from public.requests),
  array['7e573000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo sus pedidos');
select is((select array_agg(id order by id) from public.sessions),
  array['7e574000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo sus sesiones');
select is((select array_agg(client_id order by client_id) from public.client_restrictions),
  array['7e572000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo sus restricciones');
select is((select array_agg(distinct client_id) from public.consents),
  array['7e572000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo sus consentimientos');
select is((select array_agg(id order by id) from public.quotes),
  array['7e575000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo sus presupuestos');
select is((select array_agg(session_id order by session_id) from public.session_menu),
  array['7e574000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo el menú de sus sesiones');
select is((select array_agg(id order by id) from public.receipts),
  array['7e577000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo sus tickets');
select is((select array_agg(id order by id) from public.payments),
  array['7e578000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo sus pagos');
select is((select array_agg(id order by id) from public.prepared_portions),
  array['7e579000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo sus porciones');
select is((select array_agg(id order by id) from public.pantry_items),
  array['7e57a000-0000-4000-8000-00000000000a']::uuid[], 'A: ve solo su despensa');
select is((select array_agg(id order by id) from public.recipes),
  array['7e576000-0000-4000-8000-000000000001']::uuid[], 'A: ve solo las recetas activas de su cocinera');
select is((select array_agg(id order by id) from public.chefs),
  array['7e571000-0000-4000-8000-000000000001']::uuid[], 'A: ve solo la ficha de su cocinera');
select is((select array_agg(id order by id) from public.profiles),
  array['7e570000-0000-4000-8000-00000000a001']::uuid[], 'A: ve solo su perfil');
select is((select count(*)::int from public.notifications), 1, 'A: ve solo sus notificaciones');
select is((select count(*)::int from public.chef_settings) + (select count(*)::int from public.availability_rules), 0,
  'A: no ve tarifas ni disponibilidad');

-- escrituras prohibidas
select throws_ok(
  $$ update public.sessions set status = 'cancelled' where id = '7e574000-0000-4000-8000-00000000000a' $$,
  '42501', null, 'A: no puede cambiar el estado de su sesión');
select throws_ok(
  $$ insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
     values ('7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000a', 'cash', 'cash', 100, 'pending') $$,
  '42501', null, 'A: no puede insertar pagos');
select throws_ok(
  $$ update public.clients set status = 'churned' where id = '7e572000-0000-4000-8000-00000000000a' $$,
  '42501', 'only_chef_can_change_client_status', 'A: no puede cambiar su estado de cliente');
select throws_ok(
  $$ update public.clients set profile_id = '7e570000-0000-4000-8000-00000000b001' where id = '7e572000-0000-4000-8000-00000000000a' $$,
  '42501', null, 'A: no puede cambiar la cuenta vinculada');
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000b', 'week', 1, 0, 3, '{dinner}') $$,
  '42501', null, 'A: no puede crear pedidos a nombre de B');
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, status, adults, kids, days, meals)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'week', 'accepted', 1, 0, 3, '{dinner}') $$,
  '42501', null, 'A: no puede crear un pedido ya aceptado');
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, status, target_session_id, text)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'change', 'new',
             '7e574000-0000-4000-8000-00000000000b', 'cambio') $$,
  '42501', null, 'A: no puede pedir un cambio sobre la sesión de B');
select throws_ok(
  $$ insert into public.client_restrictions (chef_id, client_id, allergen)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000b', 'eggs') $$,
  '42501', null, 'A: no puede agregar restricciones a B');
select throws_ok(
  $$ insert into public.pantry_items (chef_id, client_id, name)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000b', 'Intruso') $$,
  '42501', null, 'A: no puede escribir en la despensa de B');
select throws_ok(
  $$ update public.prepared_portions set location = 'freezer' where id = '7e579000-0000-4000-8000-00000000000a' $$,
  '42501', null, 'A: no puede cambiar la ubicación de una porción (solo count_left/discarded_at)');
select throws_ok(
  $$ insert into public.push_tokens (profile_id, token, platform)
     values ('7e570000-0000-4000-8000-00000000b001', 'token-ajeno', 'ios') $$,
  '42501', null, 'A: no puede registrar tokens push de otro usuario');

-- escrituras permitidas
select lives_ok(
  $$ update public.clients set adults = 3, kitchen_notes = 'Forno nuovo' where id = '7e572000-0000-4000-8000-00000000000a' $$,
  'A: edita los datos de su hogar');
select lives_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'week', 2, 0, 3, '{dinner}') $$,
  'A: crea un pedido propio (queda new)');
select lives_ok(
  $$ update public.prepared_portions set count_left = 4 where id = '7e579000-0000-4000-8000-00000000000a' $$,
  'A: descuenta una porción');
select lives_ok(
  $$ insert into public.pantry_items (chef_id, client_id, name, expires_on)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'Uova', '2027-02-03') $$,
  'A: agrega un producto a su despensa');
select lives_ok(
  $$ insert into public.push_tokens (profile_id, token, platform)
     values ('7e570000-0000-4000-8000-00000000a001', 'token-de-a', 'android') $$,
  'A: registra su token push');

-- updates sobre filas ajenas no fallan pero no tocan nada (se verifica abajo como postgres)
select lives_ok(
  $$ update public.clients set adults = 9 where id = '7e572000-0000-4000-8000-00000000000b' $$,
  'A: un update sobre la ficha de B no afecta filas');
select lives_ok(
  $$ update public.prepared_portions set count_left = 0 where id = '7e579000-0000-4000-8000-00000000000b' $$,
  'A: un update sobre porciones de B no afecta filas');

-- storage: tickets
select is((select array_agg(name order by name) from storage.objects where bucket_id = 'receipts'),
  array['7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000a/ticket.jpg'],
  'A: en storage ve solo el ticket de su sesión');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('receipts', '7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000a/falso.jpg') $$,
  '42501', null, 'A: no puede subir tickets');

-- =====================================================================
-- Cliente B (simétrico, muestra)
-- =====================================================================
set local request.jwt.claims = '{"sub":"7e570000-0000-4000-8000-00000000b001","role":"authenticated"}';

select is((select array_agg(id order by id) from public.sessions),
  array['7e574000-0000-4000-8000-00000000000b']::uuid[], 'B: ve solo sus sesiones');
select is((select array_agg(allergen::text) from public.client_restrictions),
  array['gluten'], 'B: ve solo sus restricciones');
select is((select array_agg(name order by name) from storage.objects where bucket_id = 'receipts'),
  array['7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000b/ticket.jpg'],
  'B: en storage ve solo el ticket de su sesión');

-- =====================================================================
-- Cocinera 1
-- =====================================================================
set local request.jwt.claims = '{"sub":"7e570000-0000-4000-8000-00000000c001","role":"authenticated"}';

select is((select array_agg(id order by id) from public.clients),
  array['7e572000-0000-4000-8000-00000000000a', '7e572000-0000-4000-8000-00000000000b',
        '7e572000-0000-4000-8000-00000000000c']::uuid[],
  'C1: ve sus clientes (incluido el prospecto) y no los de C2');
select is((select array_agg(id order by id) from public.sessions),
  array['7e574000-0000-4000-8000-00000000000a', '7e574000-0000-4000-8000-00000000000b']::uuid[],
  'C1: ve sus sesiones y no las de C2');
select is((select array_agg(client_id order by client_id) from public.client_restrictions),
  array['7e572000-0000-4000-8000-00000000000a', '7e572000-0000-4000-8000-00000000000b']::uuid[],
  'C1: ve las restricciones de sus clientes');
select is((select count(*)::int from public.consents), 4, 'C1: ve los consentimientos de sus clientes');
select is((select array_agg(id order by id) from public.payments),
  array['7e578000-0000-4000-8000-00000000000a', '7e578000-0000-4000-8000-00000000000b']::uuid[],
  'C1: ve sus pagos y no los de C2');
select is((select array_agg(id order by id) from public.quotes),
  array['7e575000-0000-4000-8000-00000000000a', '7e575000-0000-4000-8000-00000000000b']::uuid[],
  'C1: ve sus presupuestos');
select is((select array_agg(id order by id) from public.recipes),
  array['7e576000-0000-4000-8000-000000000001', '7e576000-0000-4000-8000-000000000002']::uuid[],
  'C1: ve todo su recetario (también inactivas) y no el de C2');
select is((select array_agg(chef_id) from public.chef_settings),
  array['7e571000-0000-4000-8000-000000000001']::uuid[], 'C1: ve solo sus tarifas');
select is((select array_agg(distinct client_id) from public.pantry_items),
  array['7e572000-0000-4000-8000-00000000000a']::uuid[],
  'C1: ve la despensa de A (comparte) y no la de B (no comparte)');
select is((select array_agg(id order by id) from public.profiles),
  array['7e570000-0000-4000-8000-00000000a001', '7e570000-0000-4000-8000-00000000b001',
        '7e570000-0000-4000-8000-00000000c001']::uuid[],
  'C1: ve su perfil y los de sus clientes');
select is((select array_agg(name order by name) from storage.objects where bucket_id = 'receipts'),
  array['7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000a/ticket.jpg',
        '7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000b/ticket.jpg'],
  'C1: en storage ve su carpeta y no la de C2');

-- criterio 6: Evelyn no cambia estados de sesión ni registra cobros de Stripe
select throws_ok(
  $$ update public.sessions set status = 'paid' where id = '7e574000-0000-4000-8000-00000000000b' $$,
  '42501', null, 'C1: no puede marcar pagada una sesión');
select throws_ok(
  $$ insert into public.sessions (chef_id, client_id, date, start_time, cook_minutes, status)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', '2027-03-01', '10:00', 150, 'confirmed') $$,
  '42501', null, 'C1: no puede crear sesiones directamente');
select throws_ok(
  $$ update public.quotes set service_cents = 1 where id = '7e575000-0000-4000-8000-00000000000a' $$,
  '42501', null, 'C1: no puede modificar presupuestos directamente');
select throws_ok(
  $$ insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
     values ('7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000b', 'capture', 'stripe', 10600, 'succeeded') $$,
  '42501', null, 'C1: no puede insertar pagos de Stripe');
select throws_ok(
  $$ insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
     values ('7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000b', 'charge', 'stripe', 10600, 'pending') $$,
  '42501', null, 'C1: no puede insertar pagos de Stripe ni siquiera pendientes');
select throws_ok(
  $$ insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
     values ('7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000b', 'cash', 'cash', 10600, 'succeeded') $$,
  '42501', null, 'C1: no puede registrar efectivo ya confirmado');
select throws_ok(
  $$ update public.payments set status = 'succeeded' where id = '7e578000-0000-4000-8000-00000000000b' $$,
  '42501', null, 'C1: no puede confirmar un pago');
select throws_ok(
  $$ insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
     values ('7e571000-0000-4000-8000-000000000002', '7e574000-0000-4000-8000-00000000000f', 'cash', 'cash', 100, 'pending') $$,
  '42501', null, 'C1: no puede registrar pagos en sesiones de C2');
select lives_ok(
  $$ insert into public.payments (chef_id, session_id, kind, provider, amount_cents, service_part_cents, groceries_part_cents, status)
     values ('7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000b', 'cash', 'cash', 10600, 6700, 3900, 'pending') $$,
  'C1: registra un pago en efectivo pendiente');
select lives_ok(
  $$ insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
     values ('7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000b', 'transfer', 'transfer', 500, 'pending') $$,
  'C1: registra una transferencia pendiente');

-- otras reglas de la cocinera
select throws_ok(
  $$ update public.clients set share_pantry = true where id = '7e572000-0000-4000-8000-00000000000b' $$,
  '42501', 'only_client_can_change_share_pantry', 'C1: no puede activar la despensa compartida de B');
select lives_ok(
  $$ update public.clients set status = 'paused' where id = '7e572000-0000-4000-8000-00000000000b' $$,
  'C1: cambia el estado de un cliente');
select throws_ok(
  $$ insert into public.consents (chef_id, client_id, kind, text_version)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000c', 'health_data', 'v1') $$,
  '42501', null, 'C1: no puede otorgar consentimientos en nombre del cliente');
select throws_ok(
  $$ insert into public.availability_rules (chef_id, dow, start_time, end_time)
     values ('7e571000-0000-4000-8000-000000000002', 3, '09:00', '12:00') $$,
  '42501', null, 'C1: no puede tocar la disponibilidad de C2');
select lives_ok(
  $$ insert into public.availability_rules (chef_id, dow, start_time, end_time)
     values ('7e571000-0000-4000-8000-000000000001', 6, '09:00', '13:00') $$,
  'C1: agrega disponibilidad propia');
select lives_ok(
  $$ update public.chef_settings set hourly_rate_cents = 2400 where chef_id = '7e571000-0000-4000-8000-000000000001' $$,
  'C1: cambia sus tarifas');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('receipts', '7e571000-0000-4000-8000-000000000002/7e574000-0000-4000-8000-00000000000f/intruso.jpg') $$,
  '42501', null, 'C1: no puede subir a la carpeta de C2');
select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('receipts', '7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000b/ticket2.jpg') $$,
  'C1: sube un ticket a su carpeta');

-- =====================================================================
-- Cocinera 2: no ve nada de C1
-- =====================================================================
set local request.jwt.claims = '{"sub":"7e570000-0000-4000-8000-00000000c002","role":"authenticated"}';

select is((select array_agg(id order by id) from public.clients),
  array['7e572000-0000-4000-8000-00000000000f']::uuid[], 'C2: ve solo su cliente');
select is((select count(*)::int from public.client_restrictions where chef_id = '7e571000-0000-4000-8000-000000000001'), 0,
  'C2: no ve restricciones de clientes de C1');
select is((select count(*)::int from public.chef_settings where chef_id = '7e571000-0000-4000-8000-000000000001'), 0,
  'C2: no ve las tarifas de C1');

-- =====================================================================
-- Anónimo: nada
-- =====================================================================
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';

select throws_ok($$ select * from public.clients $$, '42501', null, 'anon: no lee clientes');
select throws_ok($$ select * from public.sessions $$, '42501', null, 'anon: no lee sesiones');
select throws_ok($$ select * from public.client_restrictions $$, '42501', null, 'anon: no lee restricciones');
select throws_ok($$ select * from public.recipes $$, '42501', null, 'anon: no lee recetas');
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000c', 'week', 1, 0, 3, '{dinner}') $$,
  '42501', null, 'anon: no crea pedidos directamente (va por la Edge Function)');
select throws_ok($$ select public.current_client_ids() $$, '42501', null, 'anon: no ejecuta los helpers');
select is((select count(*)::int from storage.objects where bucket_id = 'receipts'), 0, 'anon: no ve tickets en storage');

-- =====================================================================
-- Verificación final como postgres: los updates sobre filas ajenas no cambiaron nada
-- =====================================================================
reset role;

select is((select adults from public.clients where id = '7e572000-0000-4000-8000-00000000000b'), 2::smallint,
  'la ficha de B sigue intacta');
select is((select count_left from public.prepared_portions where id = '7e579000-0000-4000-8000-00000000000b'), 5,
  'las porciones de B siguen intactas');
select is((select status::text from public.sessions where id = '7e574000-0000-4000-8000-00000000000b'), 'cooked',
  'la sesión de B sigue en cooked');

select finish();
rollback;
