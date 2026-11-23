-- =====================================================================
-- Avisos a Evelyn para completar el menú de cada semana (migración 20261121110000_menu_reminders.sql):
--   * menu_reminders_due: qué semanas tienen un aviso que toca (4 días antes, 72 h antes y cada 2
--     horas pasado el límite de 48 h; de 8 a 20:59 en Roma; no en la primera hora de la sesión).
--   * menu_reminders_mark: marca los avisos que salieron.
--   * private.call_menu_reminders y el trabajo de pg_cron: llama a la función solo con la URL y el
--     secreto en Vault.
--
-- Las horas van en UTC; en enero Roma es UTC+1. S1 (R, confirmada) llega el lunes 11/1/2027 a las
-- 10:00 de Roma = 09:00 UTC: 4 días antes es el 7/1 09:00 UTC, 72 h antes el 8/1 y el límite de
-- 48 h el 9/1. S6 (R3) llega el martes 12/1 y se creó el 8/1 a las 09:30 UTC.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

-- Desde la migración client_rls_lockdown lo nuevo nace sin EXECUTE para nadie: las ayudas de pg_temp
-- de este test las llaman authenticated y service_role, así que en pg_temp nacen ejecutables
-- (solo dentro de esta transacción: el default privilege y el esquema temporal se van con el rollback).
create temp table zz_esquema_temp (i int) on commit drop;
do $$
begin
  execute format('alter default privileges in schema %I grant execute on functions to public',
    (select nspname from pg_namespace where oid = pg_my_temp_schema()));
end
$$;

select plan(44);

-- ---------------------------------------------------------------------
-- Fixture (como postgres)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e6b0000-0000-4000-8000-00000000c001', 'chef1@avisos.test'),
  ('7e6b0000-0000-4000-8000-00000000c002', 'chef2@avisos.test');
update public.profiles set role = 'chef'
where id in ('7e6b0000-0000-4000-8000-00000000c001', '7e6b0000-0000-4000-8000-00000000c002');
insert into public.chefs (id, profile_id, display_name) values
  ('7e6b1000-0000-4000-8000-000000000001', '7e6b0000-0000-4000-8000-00000000c001', 'Evelyn'),
  ('7e6b1000-0000-4000-8000-000000000002', '7e6b0000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e6b1000-0000-4000-8000-000000000001'),
  ('7e6b1000-0000-4000-8000-000000000002');

insert into public.clients (id, chef_id, display_name, status) values
  ('7e6b2000-0000-4000-8000-00000000000a', '7e6b1000-0000-4000-8000-000000000001', 'Anna Rota', 'trial'),
  ('7e6b2000-0000-4000-8000-00000000000b', '7e6b1000-0000-4000-8000-000000000001', 'Bruno Sala', 'active'),
  ('7e6b2000-0000-4000-8000-00000000000f', '7e6b1000-0000-4000-8000-000000000002', 'Xenia Ferri', 'active');

insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals, weeks, source) values
  ('7e6b3000-0000-4000-8000-000000000001', '7e6b1000-0000-4000-8000-000000000001', '7e6b2000-0000-4000-8000-00000000000a', 'week', 'accepted', 2, 0, 5, '{dinner}', 2, 'web'),
  ('7e6b3000-0000-4000-8000-000000000002', '7e6b1000-0000-4000-8000-000000000001', '7e6b2000-0000-4000-8000-00000000000b', 'week', 'quoted', 2, 0, 5, '{dinner}', 1, 'web'),
  ('7e6b3000-0000-4000-8000-000000000003', '7e6b1000-0000-4000-8000-000000000001', '7e6b2000-0000-4000-8000-00000000000b', 'week', 'accepted', 2, 0, 5, '{dinner}', 1, 'app'),
  ('7e6b3000-0000-4000-8000-00000000000f', '7e6b1000-0000-4000-8000-000000000002', '7e6b2000-0000-4000-8000-00000000000f', 'week', 'accepted', 1, 0, 3, '{dinner}', 1, 'app');

insert into public.sessions (id, chef_id, client_id, request_id, "date", start_time, cook_minutes, status, hold_until, cancelled_at, created_at) values
  -- S1 y S2: las dos semanas de R.
  ('7e6b4000-0000-4000-8000-000000000001', '7e6b1000-0000-4000-8000-000000000001', '7e6b2000-0000-4000-8000-00000000000a',
   '7e6b3000-0000-4000-8000-000000000001', '2027-01-11', '10:00', 180, 'confirmed', null, null, '2026-12-01'),
  ('7e6b4000-0000-4000-8000-000000000002', '7e6b1000-0000-4000-8000-000000000001', '7e6b2000-0000-4000-8000-00000000000a',
   '7e6b3000-0000-4000-8000-000000000001', '2027-01-18', '10:00', 180, 'confirmed', null, null, '2026-12-01'),
  -- S3: held (un presupuesto sin aceptar). S4: cancelada. S5: sin pedido.
  ('7e6b4000-0000-4000-8000-000000000003', '7e6b1000-0000-4000-8000-000000000001', '7e6b2000-0000-4000-8000-00000000000b',
   '7e6b3000-0000-4000-8000-000000000002', '2027-01-11', '15:00', 120, 'held', '2027-01-20', null, '2026-12-01'),
  ('7e6b4000-0000-4000-8000-000000000004', '7e6b1000-0000-4000-8000-000000000001', '7e6b2000-0000-4000-8000-00000000000a',
   '7e6b3000-0000-4000-8000-000000000001', '2027-01-12', '12:00', 180, 'cancelled', null, '2026-12-02', '2026-12-01'),
  ('7e6b4000-0000-4000-8000-000000000005', '7e6b1000-0000-4000-8000-000000000001', '7e6b2000-0000-4000-8000-00000000000b',
   null, '2027-01-13', '10:00', 180, 'confirmed', null, null, '2026-12-01'),
  -- S6: R3, creada el 8/1 a las 09:30 UTC.
  ('7e6b4000-0000-4000-8000-000000000006', '7e6b1000-0000-4000-8000-000000000001', '7e6b2000-0000-4000-8000-00000000000b',
   '7e6b3000-0000-4000-8000-000000000003', '2027-01-12', '10:00', 120, 'confirmed', null, null, '2027-01-08 09:30Z'),
  -- SX: de C2.
  ('7e6b4000-0000-4000-8000-00000000000f', '7e6b1000-0000-4000-8000-000000000002', '7e6b2000-0000-4000-8000-00000000000f',
   '7e6b3000-0000-4000-8000-00000000000f', '2027-01-11', '10:00', 180, 'confirmed', null, null, '2026-12-01');

-- R llegó de la web con su propio nombre: los avisos usan ese, como la bandeja.
update public.requests set contact = '{"name": "Anna R.", "email": "anna@avisos.test"}'
where id = '7e6b3000-0000-4000-8000-000000000001';

-- Lo que toca en p_now para C1, como "S1:first,S6:last" (o '' si nada).
create function pg_temp.due(p_now text) returns text
language sql
as $$
  select coalesce(string_agg(
    'S' || right(e ->> 'sessionId', 1) || ':' || (e ->> 'kind') || case when (e ->> 'changesRequested')::boolean then '*' else '' end,
    ',' order by o), '')
  from jsonb_array_elements(public.menu_reminders_due('7e6b1000-0000-4000-8000-000000000001', p_now::timestamptz))
       with ordinality as t(e, o)
$$;

create function pg_temp.mark(p_items text, p_now text) returns int
language sql
as $$ select public.menu_reminders_mark('7e6b1000-0000-4000-8000-000000000001', p_items::jsonb, p_now::timestamptz) $$;

create function pg_temp.error_of(p_sql text) returns text
language plpgsql
as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlstate || ': ' || sqlerrm;
end
$$;

-- ---------------------------------------------------------------------
-- 1. Privilegios y trabajo de pg_cron
-- ---------------------------------------------------------------------
select ok(has_function_privilege('service_role', 'public.menu_reminders_due(uuid, timestamptz)', 'EXECUTE')
          and has_function_privilege('service_role', 'public.menu_reminders_mark(uuid, jsonb, timestamptz)', 'EXECUTE'),
  'service_role ejecuta las dos funciones');
select ok(not has_function_privilege('authenticated', 'public.menu_reminders_due(uuid, timestamptz)', 'EXECUTE')
          and not has_function_privilege('anon', 'public.menu_reminders_due(uuid, timestamptz)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'public.menu_reminders_mark(uuid, jsonb, timestamptz)', 'EXECUTE')
          and not has_function_privilege('anon', 'public.menu_reminders_mark(uuid, jsonb, timestamptz)', 'EXECUTE'),
  'authenticated y anon no');
select ok(not has_table_privilege('service_role', 'private.menu_reminders', 'SELECT,INSERT,UPDATE,DELETE'),
  'private.menu_reminders no la toca nadie por la API');
select is((select count(*)::int from cron.job where jobname = 'radici-menu-reminders' and schedule = '*/15 * * * *'
           and command = 'select private.call_menu_reminders()'),
  1, 'pg_cron llama a private.call_menu_reminders cada 15 minutos');

-- ---------------------------------------------------------------------
-- 2. Cuándo toca cada aviso
-- ---------------------------------------------------------------------
set local role service_role;

select is(pg_temp.due('2027-01-06 09:00Z'), '', '5 días antes: nada');
select is(pg_temp.due('2027-01-07 09:05Z'), 'S1:first', '4 días antes (10:05 en Roma): el primero');
select is(public.menu_reminders_due('7e6b1000-0000-4000-8000-000000000001', '2027-01-07 09:05Z') -> 0 ->> 'clientName', 'Anna R.',
  'con el nombre con que llegó el pedido, no el de la ficha');
select is(pg_temp.due('2027-01-07 22:00Z'), '', 'a las 23:00 de Roma no sale nada');
select is(pg_temp.mark('[{"sessionId": "7e6b4000-0000-4000-8000-000000000001", "kind": "first"}]', '2027-01-07 09:05Z'),
  1, 'marca el primero');
select is(pg_temp.due('2027-01-07 09:20Z'), '', 'el primero no se repite');

select is(pg_temp.due('2027-01-08 09:10Z'), 'S1:last', '72 h antes: el segundo');
select is(pg_temp.mark('[{"sessionId": "7e6b4000-0000-4000-8000-000000000001", "kind": "last"}]', '2027-01-08 09:10Z'),
  1, 'marca el segundo');
select is(pg_temp.due('2027-01-08 10:00Z'), '', 'S6 se creó hace menos de una hora: todavía nada');
select is(pg_temp.due('2027-01-08 10:31Z'), 'S6:first', 'una hora después de crearla: el primero de S6');
select is(pg_temp.mark('[{"sessionId": "7e6b4000-0000-4000-8000-000000000006", "kind": "first"}]', '2027-01-08 10:31Z'),
  1, 'marca el primero de S6');

select is(pg_temp.due('2027-01-09 09:01Z'), 'S1:overdue,S6:last', 'pasado el límite de 48 h de S1: el urgente; S6 entra en sus 72 h');
select is(pg_temp.mark('[{"sessionId": "7e6b4000-0000-4000-8000-000000000001", "kind": "overdue"},
                         {"sessionId": "7e6b4000-0000-4000-8000-000000000006", "kind": "last"}]', '2027-01-09 09:01Z'),
  2, 'marca los dos');
select is(pg_temp.due('2027-01-09 10:30Z'), '', 'una hora y media después: nada');
select is(pg_temp.due('2027-01-09 10:57Z'), 'S1:overdue', 'el turno de pg_cron que cae a 1 h 56 min ya avisa (5 minutos de tolerancia)');
select is(pg_temp.due('2027-01-09 11:02Z'), 'S1:overdue', 'dos horas después: otra vez el urgente');
select is(pg_temp.due('2027-01-09 20:30Z'), '', 'a las 21:30 de Roma no sale');
select is(pg_temp.due('2027-01-10 07:00Z'), 'S1:overdue', 'a las 8:00 de Roma vuelve (y S6 todavía no pasó el límite)');

select is(pg_temp.due('2027-01-11 09:30Z'), 'S6:overdue', 'S1 ya empezó: no avisa más; S6 pasó su límite');

-- Con el menú de S6 enviado, nada; si la clienta pide cambios, vuelve a estar pendiente.
reset role;
insert into public.session_menus (session_id, chef_id) values ('7e6b4000-0000-4000-8000-000000000006', '7e6b1000-0000-4000-8000-000000000001');
insert into public.menu_sends (id, chef_id, session_id, request_id, menu_version, locale, snapshot, sent_at, sent_via) values
  ('7e6b5000-0000-4000-8000-000000000006', '7e6b1000-0000-4000-8000-000000000001', '7e6b4000-0000-4000-8000-000000000006',
   '7e6b3000-0000-4000-8000-000000000003', 1, 'it', '{}', '2027-01-11 08:00Z', '{whatsapp}');
insert into public.menu_sends (chef_id, session_id, request_id, menu_version, locale, snapshot) values
  ('7e6b1000-0000-4000-8000-000000000001', '7e6b4000-0000-4000-8000-000000000001',
   '7e6b3000-0000-4000-8000-000000000001', 1, 'it', '{}');
set local role service_role;
select is(pg_temp.due('2027-01-11 09:30Z'), '', 'con el menú enviado, nada');
reset role;
update public.menu_sends set changes_requested_at = '2027-01-11 09:00Z', changes_text = 'Sin ajo'
where id = '7e6b5000-0000-4000-8000-000000000006';
set local role service_role;
select is(pg_temp.due('2027-01-11 09:30Z'), 'S6:overdue*', 'si la clienta pidió cambios, vuelve a avisar (con la marca)');
select is(pg_temp.due('2027-01-10 07:00Z'), 'S1:overdue',
  'una vista previa que no salió no cuenta como enviado (S1 sigue pendiente)');

select is(
  (public.menu_reminders_due('7e6b1000-0000-4000-8000-000000000001', '2027-01-11 09:30Z') -> 0) - 'sessionId' - 'requestId',
  '{"kind": "overdue", "date": "2027-01-12", "start": "10:00", "deadline": "2027-01-10T09:00:00+00:00",
    "week": 1, "weeks": 1, "clientName": "Bruno Sala", "changesRequested": true}'::jsonb,
  'cada aviso trae fecha, hora, límite, semana, clienta y si pidió cambios');

-- S2 (la semana 2 de R, el lunes 18/1) recibe sus dos primeros avisos y Evelyn la pasa al 25/1.
select is(pg_temp.due('2027-01-14 09:05Z'), 'S2:first', 'S2: el primero, 4 días antes del 18/1');
select is(pg_temp.mark('[{"sessionId": "7e6b4000-0000-4000-8000-000000000002", "kind": "first"}]', '2027-01-14 09:05Z'), 1, 'marca el primero de S2');
select is(pg_temp.due('2027-01-15 09:05Z'), 'S2:last', 'S2: el segundo, 72 h antes');
select is(pg_temp.mark('[{"sessionId": "7e6b4000-0000-4000-8000-000000000002", "kind": "last"}]', '2027-01-15 09:05Z'), 1, 'marca el segundo de S2');
reset role;
update public.sessions set "date" = '2027-01-25' where id = '7e6b4000-0000-4000-8000-000000000002';
set local role service_role;
select is(pg_temp.due('2027-01-16 09:05Z'), '', 'movida al 25/1: el 16/1 todavía no toca nada (antes habría tocado el urgente)');
select is(pg_temp.due('2027-01-21 09:05Z'), 'S2:first', 'para la fecha nueva vuelve el de 4 días');
select is(pg_temp.mark('[{"sessionId": "7e6b4000-0000-4000-8000-000000000002", "kind": "first"}]', '2027-01-21 09:05Z'), 1, 'lo marca');
select is(pg_temp.due('2027-01-22 09:05Z'), 'S2:last', 'y el de 72 h también');

-- ---------------------------------------------------------------------
-- 3. menu_reminders_mark
-- ---------------------------------------------------------------------
select is(pg_temp.mark('[{"sessionId": "7e6b4000-0000-4000-8000-00000000000f", "kind": "first"},
                         {"sessionId": "7e6b4000-0000-4000-8000-000000000002", "kind": "nuevo"},
                         {"sessionId": "no", "kind": "first"},
                         3,
                         {"sessionId": "7e6b4000-0000-4000-8000-000000000006", "kind": "overdue"}]', '2027-01-11 09:30Z'),
  1, 'ignora la sesión de otra cocina, tipos desconocidos e ítems inválidos');
select is(pg_temp.error_of($$ select pg_temp.mark('{}', '2027-01-11 09:30Z') $$),
  '22023: invalid_items', 'p_items tiene que ser una lista');
reset role;
select is((select overdue_count from private.menu_reminders where session_id = '7e6b4000-0000-4000-8000-000000000006'),
  1, 'cuenta los urgentes de S6');
select is(
  (select concat_ws(' ', r.starts_at = '2027-01-25 09:00Z', r.first_at = '2027-01-21 09:05Z', r.last_at is null, r.overdue_count)
   from private.menu_reminders r where r.session_id = '7e6b4000-0000-4000-8000-000000000002'),
  't t t 0', 'la fila de S2 quedó para la llegada nueva, sin los avisos de la fecha vieja');

-- ---------------------------------------------------------------------
-- 4. private.call_menu_reminders
-- ---------------------------------------------------------------------
select lives_ok($$ select private.call_menu_reminders() $$, 'sin la URL ni el secreto en Vault no hace nada');
select is((select count(*)::int from net.http_request_queue where url like '%menu-reminders%'), 0, 'y no encola nada');
-- Como el despliegue: el secreto viejo se reemplaza.
do $$
begin
  perform private.upsert_vault_secret('radici_menu_reminders_url', 'https://ejemplo.test/functions/v1/menu-reminders');
  perform private.upsert_vault_secret('radici_menu_reminders_secret', 'secreto-viejo');
  perform private.upsert_vault_secret('radici_menu_reminders_secret', 'secreto-de-prueba');
  perform private.call_menu_reminders();
end
$$;
select is((select count(*)::int from vault.secrets where name = 'radici_menu_reminders_secret'), 1,
  'upsert_vault_secret reemplaza el secreto en lugar de duplicarlo');
select is(pg_temp.error_of($$ select private.upsert_vault_secret('radici_menu_reminders_secret', '') $$),
  '22023: invalid_secret', 'un secreto vacío no se guarda');
select is(
  (select count(*)::int from net.http_request_queue q
   where q.url = 'https://ejemplo.test/functions/v1/menu-reminders'
     and q.method = 'POST'
     and q.headers ->> 'x-reminders-secret' = 'secreto-de-prueba'),
  1, 'con los dos en Vault encola el POST a la función con el secreto');

select * from finish();
rollback;
