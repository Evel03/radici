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
-- PR05 (migración 20261123130000_auth_confirm_clears_password.sql, auth.md §4): la primera
-- confirmación del email (email_confirmed_at pasa de null a una fecha) borra la contraseña y deja en
-- los metadatos solo locale (válido), email, email_verified, phone_verified y sub (y GoTrue los reescribe
-- después de confirmar: ahí también se limpian). Se modela GoTrue:
-- INSERT sin confirmar y después el UPDATE de la confirmación. Lo que se probó contra un GoTrue real
-- está en auth.md §4.
-- Corre como postgres.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(49);

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

-- ---------------------------------------------------------------------
-- 4. La primera confirmación borra la contraseña (modelando GoTrue)
-- ---------------------------------------------------------------------
-- Alta ajena: alguien se registra con el email de otra persona y una contraseña que conoce, con
-- metadatos de más. La dueña del email confirma: la contraseña del atacante no sobrevive.
insert into auth.users (id, email, encrypted_password, raw_user_meta_data) values
  ('a0240000-0000-4000-8000-000000000010', 'victima@auth.test', extensions.crypt('la-del-atacante', extensions.gen_salt('bf')),
   '{"full_name": "Nombre falso", "role": "chef", "locale": "es", "avatar_url": "http://x", "email": "victima@auth.test",
     "email_verified": false, "phone_verified": false, "sub": "a0240000-0000-4000-8000-000000000010", "otro": {"a": 1}}'),
  ('a0240000-0000-4000-8000-000000000011', 'locale-malo@auth.test', extensions.crypt('x', extensions.gen_salt('bf')),
   '{"locale": "fr", "full_name": "N"}'),
  ('a0240000-0000-4000-8000-000000000012', 'sin-password@auth.test', null,
   '{"full_name": "Con nombre de Google", "avatar_url": "http://x", "locale": "en", "iss": "https://accounts.google.com"}'),
  ('a0240000-0000-4000-8000-000000000013', 'sin-meta@auth.test', extensions.crypt('x', extensions.gen_salt('bf')), null),
  ('a0240000-0000-4000-8000-000000000014', 'meta-rara@auth.test', extensions.crypt('x', extensions.gen_salt('bf')),
   '{"locale": ["es"], "email": {"a": 1}, "email_verified": "no", "sub": 7, "phone_verified": true}');

select isnt((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000010'), null,
  'antes de confirmar, la contraseña sigue (el alta ajena todavía no confirmó nadie)');

update auth.users set email_confirmed_at = now()
 where id in ('a0240000-0000-4000-8000-000000000010', 'a0240000-0000-4000-8000-000000000011',
              'a0240000-0000-4000-8000-000000000012', 'a0240000-0000-4000-8000-000000000013',
              'a0240000-0000-4000-8000-000000000014');

select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000010'), null,
  'la primera confirmación pone encrypted_password en NULL');
select is((select raw_user_meta_data from auth.users where id = 'a0240000-0000-4000-8000-000000000010'),
  '{"locale": "es", "email": "victima@auth.test", "email_verified": false, "phone_verified": false,
    "sub": "a0240000-0000-4000-8000-000000000010"}'::jsonb,
  'y deja en los metadatos solo locale, email, email_verified, phone_verified y sub (sin full_name, role ni lo demás)');
select is((select raw_user_meta_data from auth.users where id = 'a0240000-0000-4000-8000-000000000011'), '{}'::jsonb,
  'un locale que no es it, es ni en se descarta');
select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000011'), null,
  'también ahí, la contraseña se borra');
select is((select raw_user_meta_data from auth.users where id = 'a0240000-0000-4000-8000-000000000012'),
  '{"locale": "en"}'::jsonb, 'una cuenta sin contraseña (Google, admin): los metadatos de más salen');
select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000012'), null,
  'y sigue sin contraseña (sin efecto sobre ella)');
select is((select raw_user_meta_data from auth.users where id = 'a0240000-0000-4000-8000-000000000013'), '{}'::jsonb,
  'metadatos nulos: quedan vacíos, sin error');
select is((select raw_user_meta_data from auth.users where id = 'a0240000-0000-4000-8000-000000000014'),
  '{"phone_verified": true}'::jsonb,
  'valores de otro tipo (lista, objeto, número, texto en lugar de booleano) no se conservan; el booleano sí');

-- Un UPDATE posterior no toca la contraseña: solo se borra en el paso de null a una fecha. Los metadatos
-- de una cuenta confirmada sí se vuelven a limpiar cuando cambian: GoTrue, después de confirmar, los
-- escribe otra vez desde su copia en memoria (medido contra GoTrue v2.197.0).
update auth.users set encrypted_password = 'hash-nuevo', raw_user_meta_data = '{"full_name": "Otro", "locale": "it"}'
 where id = 'a0240000-0000-4000-8000-000000000010';
update auth.users set email_confirmed_at = now() + interval '1 minute', last_sign_in_at = now()
 where id = 'a0240000-0000-4000-8000-000000000010'; -- este UPDATE ni siquiera dispara el trigger (el WHEN da falso)
select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000010'), 'hash-nuevo',
  'un UPDATE posterior (contraseña y metadatos a la vez, y otra fecha de confirmación) no toca la contraseña');
select is((select raw_user_meta_data from auth.users where id = 'a0240000-0000-4000-8000-000000000010'),
  '{"locale": "it"}'::jsonb, 'los metadatos que se escriben después en una cuenta confirmada vuelven a quedar solo con lo permitido');
-- Una cuenta sin confirmar no se toca: los metadatos del alta siguen hasta que confirme.
insert into auth.users (id, email, encrypted_password, raw_user_meta_data) values
  ('a0240000-0000-4000-8000-000000000017', 'pendiente@auth.test', 'hash-pendiente', '{"full_name": "A"}');
update auth.users set raw_user_meta_data = '{"full_name": "B"}' where id = 'a0240000-0000-4000-8000-000000000017';
select is((select raw_user_meta_data::text || '/' || encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000017'),
  '{"full_name": "B"}/hash-pendiente', 'una cuenta sin confirmar no se toca: ni la contraseña ni los metadatos');

-- Cambio de email de una cuenta ya confirmada (updateUser({email}) con la doble confirmación): al confirmarlo
-- GoTrue pone email = email_change y no toca email_confirmed_at. Alguien que registró y confirmó un email
-- propio, con una contraseña que conoce, y pide cambiarlo al de otra persona, conservaría la contraseña
-- cuando la víctima confirma el cambio: es el mismo secuestro previo. Cambiar el email borra la contraseña.
insert into auth.users (id, email, encrypted_password, email_confirmed_at) values
  ('a0240000-0000-4000-8000-000000000018', 'atacante@auth.test', 'hash-atacante', now());
update auth.users set email = 'victima2@auth.test', email_change = '' where id = 'a0240000-0000-4000-8000-000000000018';
select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000018'), null,
  'confirmar un cambio de email (email nuevo, email_confirmed_at intacto) borra la contraseña');
update auth.users set encrypted_password = 'hash-nuevo-2' where id = 'a0240000-0000-4000-8000-000000000018';
update auth.users set email = 'victima2@auth.test' where id = 'a0240000-0000-4000-8000-000000000018';
select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000018'), 'hash-nuevo-2',
  'un UPDATE del email al mismo valor no toca la contraseña');
update auth.users set encrypted_password = 'hash-nuevo-3', raw_app_meta_data = '{"provider": "email"}'
 where id = 'a0240000-0000-4000-8000-000000000018';
select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000018'), 'hash-nuevo-3',
  'y cambiar la contraseña sin cambiar el email (la cocina, la demo) tampoco');

-- Una cuenta con contraseña se crea confirmada (la demo): el alta con email_confirmed_at ya puesto no la borra.
insert into auth.users (id, email, encrypted_password, email_confirmed_at, raw_user_meta_data) values
  ('a0240000-0000-4000-8000-000000000015', 'demo@auth.test', 'hash-demo', now(), '{"full_name": "Demo"}');
select is((select encrypted_password || '/' || (raw_user_meta_data ->> 'full_name') from auth.users
  where id = 'a0240000-0000-4000-8000-000000000015'), 'hash-demo/Demo',
  'una cuenta creada ya confirmada conserva su contraseña (la demo la fija después)');
update auth.users set encrypted_password = 'hash-demo-2' where id = 'a0240000-0000-4000-8000-000000000015';
select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000015'), 'hash-demo-2',
  'y fijarla después tampoco dispara nada');

-- Confirmar a mano desde el panel es lo mismo: un UPDATE de email_confirmed_at.
insert into auth.users (id, email, encrypted_password) values
  ('a0240000-0000-4000-8000-000000000016', 'panel@auth.test', 'hash-panel');
update auth.users set email_confirmed_at = now(), updated_at = now() where id = 'a0240000-0000-4000-8000-000000000016';
select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000016'), null,
  'confirmar a mano desde el panel también borra la contraseña');
-- Si la confirmación se quita y vuelve a ponerse, es otra primera confirmación.
update auth.users set encrypted_password = 'hash-panel-2', email_confirmed_at = null where id = 'a0240000-0000-4000-8000-000000000016';
select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000016'), 'hash-panel-2',
  'quitar la confirmación no toca la contraseña');
update auth.users set email_confirmed_at = now() where id = 'a0240000-0000-4000-8000-000000000016';
select is((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000016'), null,
  'y volver a confirmar la borra de nuevo');

-- El perfil que creó handle_new_user no se toca.
select is((select role::text || '/' || locale from public.profiles where id = 'a0240000-0000-4000-8000-000000000010'),
  'client/es', 'el perfil de la cuenta confirmada sigue igual');

-- ---------------------------------------------------------------------
-- 5. La cocina no se afecta: promote_to_chef y sync_chef_members siguen andando
-- ---------------------------------------------------------------------
insert into auth.users (id, email, encrypted_password, email_confirmed_at) values
  ('a0240000-0000-4000-8000-000000000020', 'cocinera@auth.test', null, now()),            -- creada confirmada, sin contraseña
  ('a0240000-0000-4000-8000-000000000021', 'colabora@auth.test', null, null);             -- creada sin confirmar
update auth.users set email_confirmed_at = now() where id = 'a0240000-0000-4000-8000-000000000021';

select lives_ok($$select public.promote_to_chef('cocinera@auth.test', 'Cocinera de prueba')$$,
  'promote_to_chef sigue andando sobre una cuenta confirmada sin contraseña');
select isnt((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000020'), null,
  'y le pone su contraseña al azar (un UPDATE que no toca email_confirmed_at: el trigger no interviene)');
select is((select (private.sync_chef_members(array['colabora@auth.test'], (select id from public.chefs where profile_id = 'a0240000-0000-4000-8000-000000000020')) ->> 'added')::int), 1,
  'sync_chef_members sigue andando: suma al colaborador confirmado');
select is((select count(*)::int from public.chef_members where profile_id = 'a0240000-0000-4000-8000-000000000021'), 1,
  'y queda como colaborador');
select isnt((select encrypted_password from auth.users where id = 'a0240000-0000-4000-8000-000000000021'), null,
  'con su contraseña al azar');

-- ---------------------------------------------------------------------
-- 6. La regla, en el código de la función (estructural), y quién la llama
-- ---------------------------------------------------------------------
select ok((select p.prosrc ~* $re$if old\.email_confirmed_at is null or old\.email is distinct from new\.email then\s+new\.encrypted_password\s*:=\s*null$re$
    and p.prosrc ~ $re$in \('it', ?'es', ?'en'\)$re$
    and p.prosrc ~ $re$in \('email', ?'sub'\)$re$ and p.prosrc ~ $re$in \('email_verified', ?'phone_verified'\)$re$
    and p.prosrc !~* $re$(update|insert|delete|perform|execute|raise)\s$re$
  from pg_proc p where p.oid = 'public.auth_confirm_clears_password()'::regprocedure),
  'auth_confirm_clears_password: pone la contraseña en NULL y deja solo locale validado, email, email_verified, phone_verified y sub; no escribe, ejecuta ni lanza nada');
select ok((select p.prosecdef and 'search_path=""' = any (p.proconfig) and pg_get_userbyid(p.proowner) = 'postgres'
  from pg_proc p where p.oid = 'public.auth_confirm_clears_password()'::regprocedure),
  'security definer, search_path vacío y de postgres');
select ok(not exists (
  select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.oid = 'public.auth_confirm_clears_password()'::regprocedure and a.grantee <> p.proowner),
  'nadie más que su dueña tiene EXECUTE (ni PUBLIC, anon, authenticated ni service_role): un trigger no lo necesita');
select is((select pg_get_triggerdef(t.oid) from pg_trigger t
  where t.tgrelid = 'auth.users'::regclass and t.tgname = 'on_auth_user_confirmed_clear_password'),
  'CREATE TRIGGER on_auth_user_confirmed_clear_password BEFORE UPDATE OF email, email_confirmed_at, raw_user_meta_data ON auth.users FOR EACH ROW WHEN (((new.email_confirmed_at IS NOT NULL) AND ((old.email_confirmed_at IS NULL) OR ((old.email)::text IS DISTINCT FROM (new.email)::text) OR (old.raw_user_meta_data IS DISTINCT FROM new.raw_user_meta_data)))) EXECUTE FUNCTION auth_confirm_clears_password()',
  'el trigger: BEFORE UPDATE OF email, email_confirmed_at y raw_user_meta_data, solo en cuentas confirmadas y cuando pasa de null a una fecha, cambia el email o cambian los metadatos');
select ok((select t.tgenabled = 'O' and t.tgfoid = 'public.auth_confirm_clears_password()'::regprocedure
  from pg_trigger t where t.tgrelid = 'auth.users'::regclass and t.tgname = 'on_auth_user_confirmed_clear_password'),
  'activo y llama a la función');
select is((select count(*)::int from pg_trigger t
  where t.tgrelid = 'auth.users'::regclass and not t.tgisinternal and t.tgname in
    ('on_auth_user_created', 'on_auth_user_confirmed_clear_password')), 2,
  'conviven el trigger de alta y el de confirmación');

select * from finish();
rollback;
