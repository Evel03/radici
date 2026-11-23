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

select plan(118);

-- ---------------------------------------------------------------------
-- Fixture (como postgres: sin RLS)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e570000-0000-4000-8000-00000000d001', 'z@rls.test'),
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

insert into public.session_menu (session_id, recipe_id, chef_id, portions, position) values
  ('7e574000-0000-4000-8000-00000000000a', '7e576000-0000-4000-8000-000000000001', '7e571000-0000-4000-8000-000000000001', 10, 1),
  ('7e574000-0000-4000-8000-00000000000b', '7e576000-0000-4000-8000-000000000001', '7e571000-0000-4000-8000-000000000001', 10, 1),
  ('7e574000-0000-4000-8000-00000000000f', '7e576000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', 5, 1);

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
-- Cuentas sin cocina (PR02: la RLS de la clienta está cerrada)
--
-- La clienta no lee ni escribe nada de negocio por la API de datos: todo pasa por Edge Functions
-- (service role). Solo conserva su perfil (y cambiar su idioma) y sus avisos. Se prueba con dos
-- cuentas: A, con ficha de cliente vinculada, y Z, recién creada, sin ficha ni cocina.
-- =====================================================================

-- Ayudas del test (las crea postgres y se van con el rollback; corren con el rol de quien las llama)
create function public.zz_rows(p_sql text) returns text
language plpgsql
as $$
declare
  n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n::text;
exception when insufficient_privilege then
  return 'denied';
end
$$;
grant execute on function public.zz_rows(text) to authenticated;

-- Huella del contenido de todas las tablas de negocio (todas menos profiles) y de storage.objects
create function public.zz_snap() returns text
language plpgsql
as $$
declare
  t text;
  h text;
  acc text := '';
begin
  for t in select tablename from pg_tables where schemaname = 'public' and tablename <> 'profiles' order by 1 loop
    execute format('select coalesce(md5(string_agg(md5(r::text), '''' order by md5(r::text))), '''') from public.%I r', t) into h;
    acc := acc || t || ':' || h || ';';
  end loop;
  select acc || coalesce(md5(string_agg(md5(o.name), '' order by o.name)), '') into acc from storage.objects o;
  return md5(acc);
end
$$;
create temp table zz_before as select public.zz_snap() as h;

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e570000-0000-4000-8000-00000000a001","role":"authenticated"}';

-- Perfil y avisos propios: se conservan
select is((select array_agg(id) from public.profiles),
  array['7e570000-0000-4000-8000-00000000a001']::uuid[], 'A: lee solo su perfil');
select is((select count(*)::int from public.notifications), 1, 'A: lee solo sus avisos');

-- Ninguna tabla de negocio: ni leer, ni cambiar, ni borrar (leer puede dar 0 filas o privilegio denegado)
select ok(
  public.zz_rows(format('select 1 from public.%I', t.tablename)) in ('0', 'denied')
  and public.zz_rows(format('update public.%1$I set %2$I = %2$I', t.tablename, a.attname)) in ('0', 'denied')
  and public.zz_rows(format('delete from public.%I', t.tablename)) in ('0', 'denied'),
  'A: ' || t.tablename || ': ni lee, ni cambia, ni borra')
from pg_tables t
join pg_attribute a on a.attrelid = format('public.%I', t.tablename)::regclass and a.attnum = 1
where t.schemaname = 'public' and t.tablename not in ('profiles', 'notifications')
order by t.tablename;

-- Inserciones: denegadas, también las que antes la clienta podía hacer sobre lo suyo
select throws_ok(
  $$ insert into public.requests (chef_id, client_id, type, adults, kids, days, meals)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'week', 2, 0, 3, '{dinner}') $$,
  '42501', null, 'A: no crea pedidos propios por la API (va por Edge Function)');
select throws_ok(
  $$ insert into public.consents (chef_id, client_id, kind, text_version)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'health_data', 'v9') $$,
  '42501', null, 'A: no otorga consentimientos por la API');
select throws_ok(
  $$ insert into public.client_restrictions (chef_id, client_id, allergen)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'eggs') $$,
  '42501', null, 'A: no agrega restricciones por la API');
select throws_ok(
  $$ insert into public.pantry_items (chef_id, client_id, name)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a', 'Uova') $$,
  '42501', null, 'A: no escribe en la despensa por la API');
select throws_ok(
  $$ insert into public.push_tokens (profile_id, token, platform)
     values ('7e570000-0000-4000-8000-00000000a001', 'token-de-a', 'android') $$,
  '42501', null, 'A: no registra tokens push por la API');
select throws_ok(
  $$ insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
     values ('7e571000-0000-4000-8000-000000000001', '7e574000-0000-4000-8000-00000000000a', 'cash', 'cash', 100, 'pending') $$,
  '42501', null, 'A: no inserta pagos');
select throws_ok(
  $$ insert into public.notifications (profile_id, kind, channel)
     values ('7e570000-0000-4000-8000-00000000a001', 'session_reminder', 'push') $$,
  '42501', null, 'A: no se escribe avisos');
select throws_ok(
  $$ insert into public.profiles (id) values ('7e570000-0000-4000-8000-00000000f001') $$,
  '42501', null, 'A: no crea perfiles');

-- Perfil: solo cambia su idioma
select is(public.zz_rows($$ update public.profiles set locale = 'en' where id = '7e570000-0000-4000-8000-00000000a001' $$),
  '1', 'A: cambia el idioma de su perfil');
select is(public.zz_rows($$ update public.profiles set locale = 'es' where id = '7e570000-0000-4000-8000-00000000b001' $$),
  '0', 'A: no cambia el idioma del perfil de otro');
select throws_ok(
  $$ update public.profiles set full_name = 'Otro nombre' where id = '7e570000-0000-4000-8000-00000000a001' $$,
  '42501', null, 'A: no cambia su nombre (update solo de locale)');
select throws_ok(
  $$ update public.profiles set phone = '+390000000' where id = '7e570000-0000-4000-8000-00000000a001' $$,
  '42501', null, 'A: no cambia su teléfono');
select throws_ok(
  $$ update public.profiles set role = 'chef' where id = '7e570000-0000-4000-8000-00000000a001' $$,
  '42501', null, 'A: no se pone el rol de cocinera');
select is(public.zz_rows($$ delete from public.profiles where id = '7e570000-0000-4000-8000-00000000a001' $$),
  'denied', 'A: no borra su perfil');

-- Storage: ni los tickets de sus sesiones
select is((select count(*)::int from storage.objects where bucket_id = 'receipts'), 0,
  'A: en storage no ve ningún ticket (tampoco el de sus sesiones)');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('receipts', '7e571000-0000-4000-8000-000000000001/7e574000-0000-4000-8000-00000000000a/falso.jpg') $$,
  '42501', null, 'A: no sube tickets');

-- Z: cuenta sin ficha ni cocina
set local request.jwt.claims = '{"sub":"7e570000-0000-4000-8000-00000000d001","role":"authenticated"}';

select is((select array_agg(id) from public.profiles),
  array['7e570000-0000-4000-8000-00000000d001']::uuid[], 'Z: lee solo su perfil');
select is((select count(*)::int from public.notifications), 0, 'Z: sin avisos, no ve los de otros');
select ok(
  public.zz_rows(format('select 1 from public.%I', t.tablename)) in ('0', 'denied')
  and public.zz_rows(format('update public.%1$I set %2$I = %2$I', t.tablename, a.attname)) in ('0', 'denied')
  and public.zz_rows(format('delete from public.%I', t.tablename)) in ('0', 'denied'),
  'Z: ' || t.tablename || ': ni lee, ni cambia, ni borra')
from pg_tables t
join pg_attribute a on a.attrelid = format('public.%I', t.tablename)::regclass and a.attnum = 1
where t.schemaname = 'public' and t.tablename not in ('profiles', 'notifications')
order by t.tablename;
select is((select count(*)::int from storage.objects where bucket_id = 'receipts'), 0, 'Z: no ve tickets en storage');
select is(public.zz_rows($$ update public.profiles set locale = 'es' where id = '7e570000-0000-4000-8000-00000000d001' $$),
  '1', 'Z: cambia su idioma');
select throws_ok(
  $$ update public.profiles set full_name = 'X' where id = '7e570000-0000-4000-8000-00000000d001' $$,
  '42501', null, 'Z: no cambia su nombre');

-- Ninguna de las dos cuentas cambió nada de negocio (los cambios fallidos no dejan rastro)
reset role;
select is(public.zz_snap(), (select h from zz_before), 'las cuentas sin cocina no cambiaron ninguna tabla de negocio ni storage');
set local role authenticated;

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
