-- =====================================================================
-- Hooks de Auth (migración 20261126100000_auth_hooks.sql, docs/contracts/auth.md §8).
--   * kitchen_access_token_hook: la cocina (chefs y chef_members) solo con código (amr otp o magiclink);
--     las demás cuentas pasan sin tocar. Decide por claims.amr, nunca por authentication_method.
--   * before_user_created_guard: pausa, tope diario, tope por IP y por hora, purga a las 48 h.
-- Los eventos tienen la forma de los de GoTrue (docs de Supabase, hooks). Los valores de los topes son
-- los reales de private.auth_guard (50 por día, 5 por IP y hora). Corre como postgres.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(80);

-- ---------------------------------------------------------------------
-- 0. Cuentas: cocinera, colaborador, clienta y cuenta sin ficha
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a0260000-0000-4000-8000-000000000001', 'cocinera@hooks.test'),
  ('a0260000-0000-4000-8000-000000000002', 'colaborador@hooks.test'),
  ('a0260000-0000-4000-8000-000000000003', 'clienta@hooks.test');
insert into public.chefs (id, profile_id, display_name) values
  ('cef26000-0000-4000-8000-000000000001', 'a0260000-0000-4000-8000-000000000001', 'Cocina de hooks');
insert into public.chef_members (chef_id, profile_id) values
  ('cef26000-0000-4000-8000-000000000001', 'a0260000-0000-4000-8000-000000000002');

-- Evento de un Custom Access Token hook: authentication_method y amr aparte.
create function pg_temp.ev(p_user uuid, p_method text, p_amr jsonb) returns jsonb language sql as $$
  select jsonb_build_object(
    'user_id', p_user, 'authentication_method', p_method,
    'claims', jsonb_build_object('aud', 'authenticated', 'role', 'authenticated', 'aal', 'aal1',
      'sub', p_user, 'email', 'x@hooks.test', 'amr', p_amr, 'session_id', '5e550000-0000-4000-8000-000000000001'));
$$;
create function pg_temp.amr(p_method text) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('method', p_method, 'timestamp', 1790000000));
$$;
create function pg_temp.code(r jsonb) returns text language sql as $$
  select (r -> 'error' ->> 'http_code') || ' ' || (r -> 'error' ->> 'message');
$$;

-- ---------------------------------------------------------------------
-- 1. Hook de la cocina: cocinera y colaborador
-- ---------------------------------------------------------------------
select is(pg_temp.code(public.kitchen_access_token_hook(
  pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'password', pg_temp.amr('password')))),
  '403 kitchen_code_only', 'cocinera con contraseña: 403 kitchen_code_only');
select is(pg_temp.code(public.kitchen_access_token_hook(
  pg_temp.ev('a0260000-0000-4000-8000-000000000002', 'password', pg_temp.amr('password')))),
  '403 kitchen_code_only', 'colaborador con contraseña: 403 kitchen_code_only');
select is(pg_temp.code(public.kitchen_access_token_hook(
  pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'oauth', pg_temp.amr('oauth')))),
  '403 kitchen_code_only', 'cocinera con oauth: 403');
select is(pg_temp.code(public.kitchen_access_token_hook(
  pg_temp.ev('a0260000-0000-4000-8000-000000000002', 'oauth', pg_temp.amr('oauth')))),
  '403 kitchen_code_only', 'colaborador con oauth: 403');
select is(pg_temp.code(public.kitchen_access_token_hook(
  pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'recovery', pg_temp.amr('recovery')))),
  '403 kitchen_code_only', 'cocinera con recovery: 403');
select is(pg_temp.code(public.kitchen_access_token_hook(
  pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'totp', pg_temp.amr('totp')))),
  '403 kitchen_code_only', 'cocinera con totp: 403');

select is(public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', pg_temp.amr('otp'))) -> 'claims' ->> 'role',
  'authenticated', 'cocinera con código (otp): pasa y devuelve los claims');
select ok(public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', pg_temp.amr('otp'))) ? 'claims'
  and not public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', pg_temp.amr('otp'))) ? 'error',
  'con código: la respuesta es {claims}, sin error');
select ok(public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000002', 'otp', pg_temp.amr('otp'))) ? 'claims',
  'colaborador con código (otp): pasa');
select ok(public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'magiclink', pg_temp.amr('magiclink'))) ? 'claims',
  'cocinera con magiclink: pasa');

-- Refresh: authentication_method vale token_refresh y el amr conserva el método de la sesión.
select ok(public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'token_refresh', pg_temp.amr('otp'))) ? 'claims',
  'refresh de una sesión abierta con código (token_refresh, amr otp): pasa');
select ok(public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000002', 'token_refresh', pg_temp.amr('otp'))) ? 'claims',
  'refresh del colaborador (token_refresh, amr otp): pasa');
select is(pg_temp.code(public.kitchen_access_token_hook(
  pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'token_refresh', pg_temp.amr('password')))),
  '403 kitchen_code_only', 'refresh de una sesión abierta con contraseña (amr password): 403');
select is(pg_temp.code(public.kitchen_access_token_hook(
  pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', pg_temp.amr('password')))),
  '403 kitchen_code_only', 'se decide por amr, no por authentication_method: otp con amr password es 403');

-- Formas raras del amr: ninguna deja pasar a la cocina.
select is(pg_temp.code(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp',
  '[{"method":"otp","timestamp":1},{"method":"password","timestamp":2}]'::jsonb))),
  '403 kitchen_code_only', 'amr con otp y password a la vez: 403 (todos los métodos tienen que ser otp)');
select is(pg_temp.code(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp',
  '[{"method":"password","timestamp":2},{"method":"otp","timestamp":1}]'::jsonb))),
  '403 kitchen_code_only', 'el orden del amr no importa: password primero o último, 403');
select ok(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp',
  '[{"method":"otp","timestamp":1},{"method":"magiclink","timestamp":2}]'::jsonb)) ? 'claims',
  'amr con otp y magiclink: pasa');
select is(pg_temp.code(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', '[]'::jsonb))),
  '403 kitchen_code_only', 'amr vacío: 403');
select is(pg_temp.code(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', null))),
  '403 kitchen_code_only', 'amr ausente (null): 403');
select is(pg_temp.code(public.kitchen_access_token_hook(
  jsonb_build_object('user_id', 'a0260000-0000-4000-8000-000000000001', 'authentication_method', 'otp',
    'claims', jsonb_build_object('role', 'authenticated')))),
  '403 kitchen_code_only', 'claims sin la clave amr: 403');
select is(pg_temp.code(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', '"otp"'::jsonb))),
  '403 kitchen_code_only', 'amr que es un texto y no una lista: 403');
select is(pg_temp.code(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', '{"method":"otp"}'::jsonb))),
  '403 kitchen_code_only', 'amr que es un objeto y no una lista: 403');
select is(pg_temp.code(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', '["otp"]'::jsonb))),
  '403 kitchen_code_only', 'amr con elementos que no son objetos: 403');
select is(pg_temp.code(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', '[{"timestamp":1}]'::jsonb))),
  '403 kitchen_code_only', 'amr con un elemento sin method: 403');
select is(pg_temp.code(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', '[{"method":["otp"]}]'::jsonb))),
  '403 kitchen_code_only', 'method que no es un texto: 403');
select is(pg_temp.code(public.kitchen_access_token_hook(pg_temp.ev('a0260000-0000-4000-8000-000000000001', 'otp', '[{"method":"OTP"}]'::jsonb))),
  '403 kitchen_code_only', 'el método se compara exacto: OTP en mayúsculas no pasa');

-- ---------------------------------------------------------------------
-- 2. Hook de la cocina: la clienta y los casos que fallan cerrados
-- ---------------------------------------------------------------------
select is(public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000003', 'password', pg_temp.amr('password'))) -> 'claims' ->> 'email',
  'x@hooks.test', 'clienta con contraseña: pasa');
select is(public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000003', 'password', pg_temp.amr('password'))),
  jsonb_build_object('claims',
    pg_temp.ev('a0260000-0000-4000-8000-000000000003', 'password', pg_temp.amr('password')) -> 'claims'),
  'a la clienta le devuelve exactamente {claims: los mismos claims}, sin tocar');
select ok(public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000003', 'oauth', pg_temp.amr('oauth'))) ? 'claims',
  'clienta con oauth (Google): pasa');
select ok(public.kitchen_access_token_hook(
    pg_temp.ev('a0260000-0000-4000-8000-000000000003', 'otp', null)) ? 'claims',
  'clienta sin amr: pasa (la regla es solo de la cocina)');
select throws_ok($$select public.kitchen_access_token_hook('{"claims": {}}'::jsonb)$$, '22023', null,
  'evento sin user_id: lanza (falla cerrado, GoTrue contesta 500)');
select throws_ok($$select public.kitchen_access_token_hook('{"user_id": "no-es-un-uuid", "claims": {}}'::jsonb)$$, '22P02', null,
  'user_id que no es un uuid: lanza (falla cerrado)');

-- ---------------------------------------------------------------------
-- 3. Privilegios (las dos funciones y las dos tablas)
-- ---------------------------------------------------------------------
select is((select array_agg(r order by r) from unnest(array['public', 'anon', 'authenticated', 'service_role', 'supabase_auth_admin']) r
  where has_function_privilege(r, 'public.kitchen_access_token_hook(jsonb)', 'EXECUTE')),
  array['supabase_auth_admin'], 'kitchen_access_token_hook: solo supabase_auth_admin la ejecuta');
select is((select array_agg(r order by r) from unnest(array['public', 'anon', 'authenticated', 'service_role', 'supabase_auth_admin']) r
  where has_function_privilege(r, 'public.before_user_created_guard(jsonb)', 'EXECUTE')),
  array['supabase_auth_admin'], 'before_user_created_guard: solo supabase_auth_admin la ejecuta');
select is((select array_agg(r order by r) from unnest(array['public', 'anon', 'authenticated', 'service_role', 'supabase_auth_admin']) r
  where has_function_privilege(r, 'private.purge_signup_attempts()', 'EXECUTE')),
  null, 'purge_signup_attempts: nadie de la API ni de Auth la ejecuta');
select is((select count(*)::int from unnest(array['public', 'anon', 'authenticated', 'service_role', 'supabase_auth_admin']) r,
    unnest(array['private.auth_guard', 'private.signup_attempts']) t
  where has_table_privilege(r, t, 'SELECT') or has_table_privilege(r, t, 'INSERT')
     or has_table_privilege(r, t, 'UPDATE') or has_table_privilege(r, t, 'DELETE')),
  0, 'auth_guard y signup_attempts: ningún rol de la API ni supabase_auth_admin tiene privilegios de tabla');
select ok(not has_schema_privilege('supabase_auth_admin', 'private', 'USAGE'),
  'supabase_auth_admin no tiene usage sobre private (las funciones son security definer)');

-- Estructura de las dos funciones
select ok((select p.prosecdef and 'search_path=""' = any (p.proconfig)
  from pg_proc p where p.oid = 'public.kitchen_access_token_hook(jsonb)'::regprocedure),
  'kitchen_access_token_hook: security definer con search_path vacío');
select ok((select p.prosecdef and 'search_path=""' = any (p.proconfig)
  from pg_proc p where p.oid = 'public.before_user_created_guard(jsonb)'::regprocedure),
  'before_user_created_guard: security definer con search_path vacío');
select ok((select p.prosrc ~ $re$'claims'\s*->\s*'amr'$re$ and p.prosrc ~ $re$not in \('otp', 'magiclink'\)$re$
    and p.prosrc !~ $re$event\s*->>?\s*'authentication_method'$re$
  from pg_proc p where p.oid = 'public.kitchen_access_token_hook(jsonb)'::regprocedure),
  'regla clave del hook de la cocina: mira claims.amr, solo otp y magiclink, y nunca authentication_method');
select ok((select p.prosrc ~ 'kitchen_code_only' and p.prosrc ~ '403'
  from pg_proc p where p.oid = 'public.kitchen_access_token_hook(jsonb)'::regprocedure),
  'el hook de la cocina responde 403 kitchen_code_only');
select ok((select p.prosrc ~ 'pg_advisory_xact_lock' and p.prosrc ~ 'signups_paused'
    and p.prosrc ~ 'signups_daily_cap' and p.prosrc ~ 'signups_ip_cap' and p.prosrc ~ 'set_masklen'
    and p.prosrc ~ 'hmac' and p.prosrc ~ 'purge_signup_attempts'
  from pg_proc p where p.oid = 'public.before_user_created_guard(jsonb)'::regprocedure),
  'regla clave del freno de altas: candado, pausa, topes, /64, hmac y purga están en el código');
select ok((select p.prosrc ~ '48 hours' from pg_proc p where p.oid = 'private.purge_signup_attempts()'::regprocedure),
  'la purga es de 48 horas');

-- ---------------------------------------------------------------------
-- 4. Freno de altas: valores y primera alta
-- ---------------------------------------------------------------------
delete from private.signup_attempts;
select is((select paused::text || '/' || daily_cap || '/' || ip_hour_cap from private.auth_guard),
  'false/50/5', 'valores reales: sin pausa, 50 altas por día y 5 por IP y hora');
select is((select count(*)::int from private.auth_guard), 1, 'una sola fila de valores');
select throws_ok($$insert into private.auth_guard (id) values (false)$$, '23514', null, 'no puede haber una segunda fila');

create function pg_temp.sg(p_ip text) returns jsonb language sql as $$
  select public.before_user_created_guard(jsonb_build_object(
    'metadata', jsonb_build_object('name', 'before-user-created', 'ip_address', p_ip),
    'user', jsonb_build_object('email', 'nueva@hooks.test')));
$$;

select is(pg_temp.sg('203.0.113.7'), '{}'::jsonb, 'primera alta: se permite ({})');
select is((select count(*)::int from private.signup_attempts), 1, 'queda un renglón');
select ok((select ip_hash ~ '^[0-9a-f]{64}$' and ip_hash not like '%203.0.113.7%' from private.signup_attempts),
  'el renglón guarda un hash de 64 hex, no la IP');
select is((select count(*)::int from private.signup_attempts where ip_hash = encode(extensions.digest('203.0.113.7', 'sha256'), 'hex')), 0,
  'el hash no es un sha256 pelado de la IP (lleva pepper)');

-- ---------------------------------------------------------------------
-- 5. Tope por IP (5 por hora)
-- ---------------------------------------------------------------------
select is((select string_agg(pg_temp.sg('198.51.100.9')::text, ',') from generate_series(1, 5)),
  '{},{},{},{},{}', 'cinco altas de la misma IP en una hora: pasan');
select is(pg_temp.code(pg_temp.sg('198.51.100.9')), '429 signups_ip_cap', 'la sexta de la misma IP: 429 signups_ip_cap');
select is(pg_temp.sg('198.51.100.10'), '{}'::jsonb, 'otra IP sigue pasando');
select is((select count(*)::int from private.signup_attempts), 7, 'la rechazada no deja renglón (1 + 5 + 1)');
-- IPv6: todo el /64 es una sola IP
select is((select string_agg(pg_temp.sg('2001:db8:aaaa:1::' || g)::text, ',') from generate_series(1, 5) g),
  '{},{},{},{},{}', 'cinco altas del mismo /64 IPv6, con 5 direcciones distintas: pasan');
select is(pg_temp.code(pg_temp.sg('2001:db8:aaaa:1:ffff:ffff:ffff:ffff')), '429 signups_ip_cap',
  'una sexta dirección del mismo /64 (rotar dentro del /64): 429');
select is(pg_temp.sg('2001:db8:aaaa:2::1'), '{}'::jsonb, 'otro /64: otro cubo');
-- IPv4 mapeada en IPv6 = la IPv4
select is(pg_temp.code(pg_temp.sg('::ffff:198.51.100.9')), '429 signups_ip_cap', 'IPv4 mapeada en IPv6: cuenta como la IPv4');
-- Sin IP, o con algo que no es una IP: un cubo común, con tope
select is((select string_agg(pg_temp.sg(null)::text, ',') from generate_series(1, 5)), '{},{},{},{},{}', 'sin IP: cinco pasan');
select is(pg_temp.code(pg_temp.sg(null)), '429 signups_ip_cap', 'sin IP: la sexta se frena (no es un permiso)');
select is(pg_temp.code(pg_temp.sg('no-soy-una-ip')), '429 signups_ip_cap', 'texto que no es una IP: cae en el mismo cubo, frenada');
select is(pg_temp.code(public.before_user_created_guard('{}'::jsonb)), '429 signups_ip_cap', 'evento sin metadata: el mismo cubo, frenada');

-- ---------------------------------------------------------------------
-- 6. Ventana de la hora, purga a las 48 h y tope diario (50)
-- ---------------------------------------------------------------------
delete from private.signup_attempts;
select is((select count(*)::int from generate_series(1, 5) g where pg_temp.sg('192.0.2.1') = '{}'::jsonb), 5, 'cinco altas de una IP');
select is(pg_temp.code(pg_temp.sg('192.0.2.1')), '429 signups_ip_cap', 'IP en el tope');
update private.signup_attempts set created_at = now() - interval '61 minutes';
select is(pg_temp.sg('192.0.2.1'), '{}'::jsonb, 'pasada la hora, la IP vuelve a poder (los renglones de hace 61 minutos no cuentan)');

delete from private.signup_attempts;
insert into private.signup_attempts (ip_hash, created_at) values
  (repeat('a', 64), now() - interval '49 hours'),
  (repeat('b', 64), now() - interval '47 hours');
select is((select count(*)::int from private.signup_attempts), 2, 'dos renglones viejos (49 h y 47 h)');
select is(pg_temp.sg('192.0.2.50'), '{}'::jsonb, 'una alta cualquiera');
select is((select array_agg(ip_hash order by ip_hash) filter (where ip_hash in (repeat('a', 64), repeat('b', 64))) from private.signup_attempts),
  array[repeat('b', 64)], 'la alta purga el de 49 h y deja el de 47 h');
select is(private.purge_signup_attempts(), 0, 'purge_signup_attempts directa: nada más que borrar');
update private.signup_attempts set created_at = now() - interval '48 hours 1 minute' where ip_hash = repeat('b', 64);
select is(private.purge_signup_attempts(), 1, 'purge_signup_attempts directa: borra el de más de 48 h');
select is((select count(*)::int from cron.job where jobname = 'radici-purge-signup-attempts'
  and command = 'select private.purge_signup_attempts()'), 1, 'pg_cron purga una vez por hora');

-- Tope diario: 50 altas de 50 IP distintas
delete from private.signup_attempts;
select is((select count(*)::int from generate_series(1, 50) g where pg_temp.sg('10.0.0.' || g) = '{}'::jsonb),
  50, 'cincuenta altas de cincuenta IP distintas: pasan');
select is(pg_temp.code(pg_temp.sg('10.9.9.9')), '429 signups_daily_cap', 'la 51.ª del día, de una IP nueva: 429 signups_daily_cap');
-- las de hace más de 24 h no cuentan
update private.signup_attempts set created_at = now() - interval '25 hours' where ip_hash in
  (select ip_hash from private.signup_attempts order by id limit 10);
select is(pg_temp.sg('10.9.9.9'), '{}'::jsonb, 'con 10 renglones de más de 24 h, hay lugar otra vez');

-- ---------------------------------------------------------------------
-- 7. Pausa de emergencia
-- ---------------------------------------------------------------------
delete from private.signup_attempts;
update private.auth_guard set paused = true;
select is(pg_temp.code(pg_temp.sg('203.0.113.99')), '403 signups_paused', 'en pausa: 403 signups_paused aunque no haya ningún renglón');
select is((select count(*)::int from private.signup_attempts), 0, 'en pausa no se registra nada');
update private.auth_guard set paused = false;
select is(pg_temp.sg('203.0.113.99'), '{}'::jsonb, 'sin la pausa, vuelve a pasar');

-- Valores cambiados por SQL: los topes se leen en cada llamada
update private.auth_guard set ip_hour_cap = 1;
select is(pg_temp.code(pg_temp.sg('203.0.113.99')), '429 signups_ip_cap', 'cambiar ip_hour_cap por SQL rige de inmediato');
select throws_ok($$update private.auth_guard set daily_cap = 0$$, '23514', null, 'daily_cap menor que 1: la base lo rechaza');
delete from private.auth_guard;
select throws_ok($$select public.before_user_created_guard('{}'::jsonb)$$, '55000', null,
  'sin la fila de valores: lanza (falla cerrado, no deja pasar)');

select * from finish();
rollback;
