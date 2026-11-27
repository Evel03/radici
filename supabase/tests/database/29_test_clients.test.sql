-- =====================================================================
-- Cuentas de prueba de clienta (migración 20261127120000_test_clients.sql, auth.md §15).
--
--   1. Privilegios: solo el despliegue (postgres) ejecuta private.sync_test_clients.
--   2. Lo que corta, sin cambiar nada: lista inválida, más de 10, una cuenta que no existe, sin
--      confirmar o de la cocina.
--   3. La lista manda: marca a las nuevas, deja a las que siguen, borra a la que sale sin ficha y le
--      saca la marca a la que sale con ficha. No toca contraseñas, sesiones ni user_metadata, ni las
--      cuentas que nunca fueron de prueba.
--   4. Otra vez la misma lista no cambia nada; la lista vacía saca a todas.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(26);

-- Cuentas: N (nueva en la lista), S (sigue), X (sale, sin ficha), F (sale, con ficha), R (clienta de
-- verdad, nunca de prueba), U (sin confirmar), la cocinera C y su colaborador M.
insert into auth.users (id, email, email_confirmed_at, encrypted_password, raw_app_meta_data, raw_user_meta_data) values
  ('29a00000-0000-4000-8000-00000000000a', 'nueva@prueba.test',    now(), null,
   '{"provider": "email", "providers": ["email"]}', '{"locale": "es"}'),
  ('29a00000-0000-4000-8000-00000000000b', 'sigue@prueba.test',    now(), extensions.crypt('la-de-sigue', extensions.gen_salt('bf')),
   '{"provider": "email", "providers": ["email"], "radici_test": true}', '{"locale": "it"}'),
  ('29a00000-0000-4000-8000-00000000000c', 'sale@prueba.test',     now(), null,
   '{"provider": "email", "providers": ["email"], "radici_test": true}', '{}'),
  ('29a00000-0000-4000-8000-00000000000d', 'saleficha@prueba.test', now(), null,
   '{"provider": "email", "providers": ["email"], "radici_test": true}', '{}'),
  ('29a00000-0000-4000-8000-00000000000e', 'clienta@prueba.test',  now(), null,
   '{"provider": "email", "providers": ["email"]}', '{}'),
  ('29a00000-0000-4000-8000-00000000000f', 'sinconfirmar@prueba.test', null, null,
   '{"provider": "email", "providers": ["email"]}', '{}'),
  ('29a00000-0000-4000-8000-0000000000c1', 'cocina@prueba.test',   now(), null,
   '{"provider": "email", "providers": ["email"]}', '{}'),
  ('29a00000-0000-4000-8000-0000000000a1', 'socio@prueba.test',    now(), null,
   '{"provider": "email", "providers": ["email"]}', '{}');

update public.profiles set role = 'chef'
where id in ('29a00000-0000-4000-8000-0000000000c1', '29a00000-0000-4000-8000-0000000000a1');
insert into public.chefs (id, profile_id, display_name, whatsapp) values
  ('29a10000-0000-4000-8000-000000000001', '29a00000-0000-4000-8000-0000000000c1', 'Chef Prueba', '+393330000029');
insert into public.chef_members (chef_id, profile_id) values
  ('29a10000-0000-4000-8000-000000000001', '29a00000-0000-4000-8000-0000000000a1');
insert into public.clients (id, chef_id, profile_id, display_name, status, share_pantry) values
  ('29a20000-0000-4000-8000-00000000000d', '29a10000-0000-4000-8000-000000000001', '29a00000-0000-4000-8000-00000000000d', 'Ficha de F', 'active', false),
  ('29a20000-0000-4000-8000-00000000000e', '29a10000-0000-4000-8000-000000000001', '29a00000-0000-4000-8000-00000000000e', 'Clienta R', 'active', false);
insert into auth.sessions (id, user_id) values
  ('29a30000-0000-4000-8000-00000000000b', '29a00000-0000-4000-8000-00000000000b');

-- =====================================================================
-- 1. Privilegios
-- =====================================================================
select has_function('private', 'sync_test_clients', array['text[]'], 'existe private.sync_test_clients(text[])');
select is(
  (select array_agg(r order by r)
   from unnest(array['public', 'anon', 'authenticated', 'service_role']) as r
   where r <> 'public' and has_function_privilege(r, 'private.sync_test_clients(text[])', 'EXECUTE')),
  null::text[],
  'ni anon, ni authenticated, ni service_role la ejecutan: la corre solo el despliegue, como postgres'
);
select ok(
  not (select p.prosecdef from pg_proc p where p.oid = 'private.sync_test_clients(text[])'::regprocedure),
  'no es security definer: corre con los permisos de quien la llama (postgres en el despliegue)'
);

-- =====================================================================
-- 2. Lo que corta, sin cambiar nada
-- =====================================================================
select throws_ok($$ select private.sync_test_clients(null) $$, '22023', 'invalid_test_client_email',
  'una lista nula no es una lista');
select throws_ok($$ select private.sync_test_clients(array['nueva@prueba.test', 'con espacio@prueba.test']) $$,
  '22023', 'invalid_test_client_email', 'un email con espacios (o comillas) no llega a ninguna consulta');
select throws_ok(
  $$ select private.sync_test_clients(array(select format('p%s@prueba.test', g) from generate_series(1, 11) g)) $$,
  '22023', 'too_many_test_clients', 'más de 10 cuentas de prueba no');
select throws_ok($$ select private.sync_test_clients(array['nadie@prueba.test']) $$,
  'P0002', 'test_client_user_not_found', 'un email sin cuenta: el despliegue la tiene que crear antes');
select throws_ok($$ select private.sync_test_clients(array['nueva@prueba.test', 'sinconfirmar@prueba.test']) $$,
  'P0001', 'test_client_not_confirmed', 'una cuenta sin confirmar no la creó el despliegue: corta');
select throws_ok($$ select private.sync_test_clients(array['nueva@prueba.test', 'cocina@prueba.test']) $$,
  '22023', 'test_client_is_kitchen', 'la cuenta de la cocinera nunca es de prueba');
select throws_ok($$ select private.sync_test_clients(array['socio@prueba.test']) $$,
  '22023', 'test_client_is_kitchen', 'la de un colaborador tampoco');

update public.profiles set role = 'chef' where id = '29a00000-0000-4000-8000-00000000000e';
select throws_ok($$ select private.sync_test_clients(array['clienta@prueba.test']) $$,
  '22023', 'test_client_is_kitchen', 'ni un perfil con otro rol que client');
update public.profiles set role = 'client' where id = '29a00000-0000-4000-8000-00000000000e';

select results_eq(
  $$ select lower(email) from auth.users where raw_app_meta_data -> 'radici_test' = 'true'::jsonb order by 1 $$,
  $$ values ('sale@prueba.test'), ('saleficha@prueba.test'), ('sigue@prueba.test') $$,
  'después de los errores, las marcas son las de antes: nada se cambió a medias');

-- =====================================================================
-- 3. La lista manda
-- =====================================================================
create temp table sync1 as
select private.sync_test_clients(array[' NUEVA@prueba.test', 'sigue@prueba.test', 'nueva@prueba.test ']) as r;

select is((select r from sync1),
  '{"testers": 2, "added": 1, "kept": 1, "removed": 2, "accounts_deleted": 1}'::jsonb,
  'N entra, S sigue, X sale con su cuenta y F sale sin la marca (tiene ficha)');
select results_eq(
  $$ select lower(email) from auth.users where raw_app_meta_data -> 'radici_test' = 'true'::jsonb order by 1 $$,
  $$ values ('nueva@prueba.test'), ('sigue@prueba.test') $$,
  'quedan marcadas las de la lista, sin mayúsculas, espacios ni repetidos');
select is(
  (select raw_app_meta_data from auth.users where id = '29a00000-0000-4000-8000-00000000000a'),
  '{"provider": "email", "providers": ["email"], "radici_test": true}'::jsonb,
  'la marca se suma a app_metadata sin pisar lo que GoTrue guarda ahí');
select is(
  (select raw_user_meta_data from auth.users where id = '29a00000-0000-4000-8000-00000000000a'),
  '{"locale": "es"}'::jsonb,
  'user_metadata (el idioma del email) no cambia');
select ok(
  (select encrypted_password = extensions.crypt('la-de-sigue', encrypted_password)
   from auth.users where id = '29a00000-0000-4000-8000-00000000000b'),
  'S conserva la contraseña que eligió');
select is((select count(*)::int from auth.sessions where user_id = '29a00000-0000-4000-8000-00000000000b'), 1,
  'y su sesión: seguir en la lista no la saca');
select is(
  (select count(*)::int from auth.users where id = '29a00000-0000-4000-8000-00000000000c')
    + (select count(*)::int from public.profiles where id = '29a00000-0000-4000-8000-00000000000c'),
  0,
  'X salió de la lista sin ficha: se borra su cuenta, y con ella el perfil');
select is(
  (select raw_app_meta_data from auth.users where id = '29a00000-0000-4000-8000-00000000000d'),
  '{"provider": "email", "providers": ["email"]}'::jsonb,
  'F salió con ficha: la cuenta queda, sin la marca');
select is((select profile_id from public.clients where id = '29a20000-0000-4000-8000-00000000000d'),
  '29a00000-0000-4000-8000-00000000000d'::uuid,
  'y su ficha sigue unida a la cuenta');
select is(
  (select raw_app_meta_data from auth.users where id = '29a00000-0000-4000-8000-00000000000e'),
  '{"provider": "email", "providers": ["email"]}'::jsonb,
  'R, que nunca estuvo en la lista, no cambia');
select is(
  (select count(*)::int from auth.users
   where id in ('29a00000-0000-4000-8000-0000000000c1', '29a00000-0000-4000-8000-0000000000a1')
     and raw_app_meta_data ? 'radici_test'),
  0,
  'las cuentas de la cocina no se marcan');

-- =====================================================================
-- 4. Otra vez, y la lista vacía
-- =====================================================================
select is(private.sync_test_clients(array['sigue@prueba.test', 'nueva@prueba.test']),
  '{"testers": 2, "added": 0, "kept": 2, "removed": 0, "accounts_deleted": 0}'::jsonb,
  'la misma lista otra vez no cambia nada');
select is(private.sync_test_clients(array[]::text[]),
  '{"testers": 0, "added": 0, "kept": 0, "removed": 2, "accounts_deleted": 2}'::jsonb,
  'la lista vacía (o el secreto sin cargar) saca a todas: sin ficha, se borran');
select is(
  (select count(*)::int from auth.users where raw_app_meta_data ? 'radici_test'),
  0,
  'no queda ninguna cuenta de prueba');

select * from finish();
rollback;
