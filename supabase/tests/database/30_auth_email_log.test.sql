-- =====================================================================
-- Hook de envío de Auth: las reglas (migración 20261127130000_auth_email_log.sql, auth.md §16).
--
--   1. Privilegios: la tabla no la lee nadie por la API; la función, solo service_role.
--   2. Qué sale y qué no: cambio de email, invitación y reautenticación se rechazan; el código solo a la
--      cocina; la recuperación y la confirmación nunca a la cocina.
--   3. Topes: por destinatario (hora y día), por cuenta y global para las clientas; la cocina va aparte.
--   4. Retención: 2 días, con pg_cron.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(31);

-- La cocinera C, su colaborador M y dos clientas A y B.
insert into auth.users (id, email, email_confirmed_at) values
  ('30a00000-0000-4000-8000-0000000000c1', 'cocina@hook.test', now()),
  ('30a00000-0000-4000-8000-0000000000a1', 'socio@hook.test',  now()),
  ('30a00000-0000-4000-8000-00000000000a', 'a@hook.test',      now()),
  ('30a00000-0000-4000-8000-00000000000b', 'b@hook.test',      now());
update public.profiles set role = 'chef'
where id in ('30a00000-0000-4000-8000-0000000000c1', '30a00000-0000-4000-8000-0000000000a1');
insert into public.chefs (id, profile_id, display_name, whatsapp) values
  ('30a10000-0000-4000-8000-000000000001', '30a00000-0000-4000-8000-0000000000c1', 'Chef Hook', '+393330000030');
insert into public.chef_members (chef_id, profile_id) values
  ('30a10000-0000-4000-8000-000000000001', '30a00000-0000-4000-8000-0000000000a1');

-- Un hash de destinatario de prueba (64 hexadecimales, como el HMAC de la función).
create function pg_temp.h(p text) returns text language sql as $$ select encode(extensions.digest(p, 'sha256'), 'hex') $$;

-- =====================================================================
-- 1. Privilegios
-- =====================================================================
select has_table('private'::name, 'auth_email_log'::name, 'existe private.auth_email_log');
select is(
  (select array_agg(format('%s %s', r, p) order by 1)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) as p
   where has_table_privilege(r, 'private.auth_email_log', p)),
  null::text[],
  'nadie toca el registro por la API (ni service_role: solo la función)'
);
select hasnt_column('private', 'auth_email_log', 'email', 'el registro no tiene el email: solo su hash');
select ok(has_function_privilege('service_role', 'public.auth_email_gate(uuid, text, text)', 'EXECUTE'),
  'service_role ejecuta auth_email_gate (la Edge Function con la clave secreta)');
select is(
  (select array_agg(r order by r) from unnest(array['anon', 'authenticated']) as r
   where has_function_privilege(r, 'public.auth_email_gate(uuid, text, text)', 'EXECUTE')),
  null::text[],
  'ni anon ni authenticated: desde la app nadie pregunta por los emails de Auth');
select throws_ok(
  $$ select public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'recovery', 'no-es-un-hash') $$,
  '22023', 'invalid_auth_email', 'un hash con otra forma (o nulo) corta');

-- =====================================================================
-- 2. Qué sale y qué no
-- =====================================================================
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'email_change', pg_temp.h('a')), 'reject',
  'cambio de email: se rechaza (así PUT /user {email} falla sin mandar nada)');
select is(public.auth_email_gate('30a00000-0000-4000-8000-0000000000c1', 'email_change', pg_temp.h('c')), 'reject',
  'también a la cocina');
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'invite', pg_temp.h('a')), 'reject',
  'invitación: se rechaza');
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'reauthentication', pg_temp.h('a')), 'reject',
  'reautenticación: se rechaza');
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'otro', pg_temp.h('a')), 'reject',
  'un tipo desconocido tampoco sale');

select is(public.auth_email_gate('30a00000-0000-4000-8000-0000000000c1', 'magic_link', pg_temp.h('c')), 'send',
  'el código a la cocinera sale');
select is(public.auth_email_gate('30a00000-0000-4000-8000-0000000000a1', 'magic_link', pg_temp.h('m')), 'send',
  'y a un colaborador');
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'magic_link', pg_temp.h('a')), 'skip',
  'el código a una clienta no sale, sin error (no delata qué emails son de la cocina)');
select is(public.auth_email_gate('30a00000-0000-4000-8000-0000000000c1', 'recovery', pg_temp.h('c')), 'skip',
  'la recuperación a la cocina no sale (le abriría una sesión como el código)');
select is(public.auth_email_gate('30a00000-0000-4000-8000-0000000000a1', 'confirmation', pg_temp.h('m')), 'skip',
  'ni la confirmación');
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'recovery', pg_temp.h('a')), 'send',
  'la recuperación a una clienta sale');
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000b', 'confirmation', pg_temp.h('b')), 'send',
  'y la confirmación del alta');

select results_eq(
  $$ select kind, kitchen from private.auth_email_log order by id $$,
  $$ values ('magic_link', true), ('magic_link', true), ('recovery', false), ('confirmation', false) $$,
  'se anota solo lo que sale, con su tipo y su carril');

-- =====================================================================
-- 3. Topes
-- =====================================================================
-- A ya tiene uno en la última hora: dos más y el cuarto no.
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'recovery', pg_temp.h('a')), 'send', 'A: el segundo en la hora');
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'recovery', pg_temp.h('a')), 'send', 'A: el tercero');
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'recovery', pg_temp.h('a')), 'limited',
  'A: el cuarto en una hora no (3 por hora por destinatario)');

-- Por cuenta: B con tres direcciones distintas (el hash cambia) en la misma hora.
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000b', 'recovery', pg_temp.h('b2')), 'send', 'B: otro destinatario');
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000b', 'recovery', pg_temp.h('b3')), 'send', 'B: otro más');
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000b', 'recovery', pg_temp.h('b4')), 'limited',
  'B: el cuarto de la misma cuenta en una hora no (3 por hora por cuenta)');

-- Por día: A con lo de la última hora corrido a hace 2 horas, y siete más en el día: 10 en 24 horas.
update private.auth_email_log set sent_at = now() - interval '2 hours' where recipient_hash = pg_temp.h('a');
insert into private.auth_email_log (sent_at, kind, kitchen, user_id, recipient_hash)
select now() - interval '3 hours', 'recovery', false, '30a00000-0000-4000-8000-00000000000a', pg_temp.h('a')
from generate_series(1, 7);
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000a', 'recovery', pg_temp.h('a')), 'limited',
  'A: con 10 en el día no sale (10 por día por destinatario), aunque en la última hora no haya ninguno');

-- Global de las clientas: 60 en el día entre todas (Resend gratis: 100 por día).
update private.auth_email_log set sent_at = now() - interval '5 hours' where not kitchen;
insert into private.auth_email_log (sent_at, kind, kitchen, user_id, recipient_hash)
select now() - interval '5 hours', 'recovery', false, '30a00000-0000-4000-8000-00000000000b', pg_temp.h('otra' || g)
from generate_series(1, 60 - (select count(*)::int from private.auth_email_log where not kitchen)) as g;
select is(public.auth_email_gate('30a00000-0000-4000-8000-00000000000b', 'recovery', pg_temp.h('nueva')), 'limited',
  'con 60 de clientas en el día, la siguiente no sale');
select is(public.auth_email_gate('30a00000-0000-4000-8000-0000000000c1', 'magic_link', pg_temp.h('c')), 'send',
  'pero la cocina va aparte: su código sale igual');

-- La cocina: 10 por hora por destinatario.
insert into private.auth_email_log (kind, kitchen, user_id, recipient_hash)
select 'magic_link', true, '30a00000-0000-4000-8000-0000000000c1', pg_temp.h('c')
from generate_series(1, 10 - (select count(*)::int from private.auth_email_log where recipient_hash = pg_temp.h('c')));
select is(public.auth_email_gate('30a00000-0000-4000-8000-0000000000c1', 'magic_link', pg_temp.h('c')), 'limited',
  'la cocina: el código número 11 en una hora no sale');

-- =====================================================================
-- 4. Retención
-- =====================================================================
update private.auth_email_log set sent_at = now() - interval '3 days' where recipient_hash = pg_temp.h('c');
select is(private.purge_auth_email_log(), 10, 'la limpieza borra lo de hace más de 2 días');
select is(
  (select count(*)::int from cron.job
   where jobname = 'radici-purge-auth-email-log' and schedule = '50 3 * * *'
     and command = 'select private.purge_auth_email_log()'),
  1,
  'y corre todos los días a las 03:50 UTC');

select * from finish();
rollback;
