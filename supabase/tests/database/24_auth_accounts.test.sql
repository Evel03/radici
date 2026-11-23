-- =====================================================================
-- Cuentas de Auth (migración 20261123120000_auth_profile_name.sql, docs/contracts/auth.md §4).
-- El perfil de un usuario nuevo lo crea el trigger on_auth_user_created (handle_new_user):
--   * nace siempre como client, aunque los metadatos digan role = chef o admin (los metadatos los
--     escribe quien se registra);
--   * nace sin nombre: full_name de los metadatos ya no se copia (nadie lo verificó);
--   * el idioma sí se copia, solo si es it, es o en;
--   * no crea ninguna cocina, ni ficha de cliente, ni colaboración.
-- Más un test estructural de la regla clave (pg_proc.prosrc), así otra reescritura de la función no
-- la pierde sin que falle un test, y que el trigger sigue siendo lo único que la llama.
-- Corre como postgres.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(17);

-- ---------------------------------------------------------------------
-- 1. Metadatos con full_name y role
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('a0240000-0000-4000-8000-000000000001', 'mallory@auth.test',
   '{"full_name": "Evelyn Ramírez", "role": "chef", "locale": "es"}'),
  ('a0240000-0000-4000-8000-000000000002', 'otra@auth.test',
   '{"full_name": "Otra Persona", "role": "admin", "locale": "fr"}'),
  ('a0240000-0000-4000-8000-000000000003', 'sin-datos@auth.test', '{}'),
  ('a0240000-0000-4000-8000-000000000004', 'en@auth.test', '{"locale": "en"}');

select is((select role::text from public.profiles where id = 'a0240000-0000-4000-8000-000000000001'),
  'client', 'role = chef en los metadatos: el perfil nace client');
select is((select full_name from public.profiles where id = 'a0240000-0000-4000-8000-000000000001'),
  null, 'full_name de los metadatos: el perfil nace sin nombre');
select is((select locale from public.profiles where id = 'a0240000-0000-4000-8000-000000000001'),
  'es', 'el idioma válido de los metadatos sí se copia');

select is((select role::text from public.profiles where id = 'a0240000-0000-4000-8000-000000000002'),
  'client', 'role = admin en los metadatos: el perfil nace client');
select is((select full_name from public.profiles where id = 'a0240000-0000-4000-8000-000000000002'),
  null, 'el nombre de los metadatos tampoco se copia en este caso');
select is((select locale from public.profiles where id = 'a0240000-0000-4000-8000-000000000002'),
  'it', 'un idioma que no es it, es ni en cae en it');

select is((select role::text || '/' || coalesce(full_name, '-') || '/' || locale from public.profiles
  where id = 'a0240000-0000-4000-8000-000000000003'), 'client/-/it', 'sin metadatos: client, sin nombre, en italiano');
select is((select locale from public.profiles where id = 'a0240000-0000-4000-8000-000000000004'),
  'en', 'locale en');

select is((select count(*)::int from public.chefs where profile_id in
  ('a0240000-0000-4000-8000-000000000001', 'a0240000-0000-4000-8000-000000000002')), 0,
  'ninguna cocina nace de los metadatos');
select is((select count(*)::int from public.chef_members where profile_id in
  ('a0240000-0000-4000-8000-000000000001', 'a0240000-0000-4000-8000-000000000002')), 0,
  'ninguna colaboración nace de los metadatos');

-- ---------------------------------------------------------------------
-- 2. La regla, en el código de la función (estructural)
-- ---------------------------------------------------------------------
select ok((select p.prosrc !~* 'full_name' from pg_proc p where p.oid = 'public.handle_new_user()'::regprocedure),
  'handle_new_user no nombra full_name: no copia el nombre de los metadatos');
select ok((select p.prosrc ~ $re$'client'$re$ and p.prosrc !~* $re$->>\s*'role'$re$
  from pg_proc p where p.oid = 'public.handle_new_user()'::regprocedure),
  'el rol es el literal client y nunca sale de los metadatos');
select ok((select p.prosrc ~ $re$in \('it','es','en'\)$re$ and p.prosrc ~* 'on conflict \(id\) do nothing'
  from pg_proc p where p.oid = 'public.handle_new_user()'::regprocedure),
  'sigue validando el idioma y con on conflict do nothing');
select ok((select p.prosecdef and 'search_path=""' = any (p.proconfig)
  from pg_proc p where p.oid = 'public.handle_new_user()'::regprocedure),
  'security definer con search_path vacío');

-- ---------------------------------------------------------------------
-- 3. Quién la llama y quién puede ejecutarla
-- ---------------------------------------------------------------------
select is((select count(*)::int from pg_trigger t
  where t.tgrelid = 'auth.users'::regclass and t.tgname = 'on_auth_user_created'
    and t.tgfoid = 'public.handle_new_user()'::regprocedure), 1, 'el trigger on_auth_user_created la sigue llamando');
select ok(not has_function_privilege('anon', 'public.handle_new_user()', 'execute')
  and not has_function_privilege('authenticated', 'public.handle_new_user()', 'execute'),
  'anon y authenticated no la ejecutan (el trigger no lo necesita)');
select ok(not exists (
  select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.oid = 'public.handle_new_user()'::regprocedure and a.grantee = 0),
  'ni PUBLIC');

select * from finish();
rollback;
