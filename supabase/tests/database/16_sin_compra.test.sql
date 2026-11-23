-- =====================================================================
-- Sin compra (migración 20261119090000_sin_compra.sql). Decisión del 19/11/2026: Evelyn no hace
-- la compra (la hace el cliente, con la lista que ella le manda), así que llega a la primera casa
-- desde las 9:00 y una sesión puede durar hasta 6 h (de 9:00 a 15:00).
--
--   1. chef_settings.shop_minutes vale 0 por defecto: una cocinera nueva no tiene compra, y el check
--      sigue (0 vale, un negativo no).
--   2. Un día de 9:00 a 15:00: el primer horario libre es 09:00, entra una sesión de 360 min y una
--      de 390 no (el generador, la base, booking_day_checks y get_free_days dicen lo mismo).
--   3. private.replace_shop_minutes: pasa a 0 las que seguían en 45 (en producción, Evelyn), sin
--      tocar las que tienen otro valor ni las sesiones que ya existen. db reset aplica las
--      migraciones sobre una base vacía y siembra después: la llamada de la migración no encuentra
--      filas y lo que se prueba es la función.
--   4. private.clear_upcoming_shop_minutes: las sesiones held o confirmed desde hoy dejan la compra
--      (su rango ocupado empieza en la llegada); una pasada guarda sus 45 minutos.
--
-- La cuenta con compra (un valor distinto de 0) la siguen probando 01_sessions_no_overlap,
-- 07_free_slots y 13_bookings, con 45 minutos fijos.
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

select plan(25);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
--   CN: cocinera nueva (chef_settings sin shop_minutes), lunes a viernes de 9 a 15 (el horario de
--       Evelyn) y los demás valores por defecto (margen 30, paso 30, aviso 24 h, horizonte 56).
--   C45, C40 y C00: para replace_shop_minutes, con un updated_at viejo. C45 sigue en 45 (como
--       Evelyn en producción antes de la migración) y tiene una sesión creada con esos 45; C40 lo
--       eligió a mano; C00 ya está en 0.
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e640000-0000-4000-8000-00000000c0aa', 'nueva@sincompra.test'),
  ('7e640000-0000-4000-8000-00000000c045', 'chef45@sincompra.test'),
  ('7e640000-0000-4000-8000-00000000c040', 'chef40@sincompra.test'),
  ('7e640000-0000-4000-8000-00000000c000', 'chef00@sincompra.test');
update public.profiles set role = 'chef' where id::text like '7e640000-%';

insert into public.chefs (id, profile_id, display_name) values
  ('7e641000-0000-4000-8000-0000000000aa', '7e640000-0000-4000-8000-00000000c0aa', 'CN'),
  ('7e641000-0000-4000-8000-000000000045', '7e640000-0000-4000-8000-00000000c045', 'C45'),
  ('7e641000-0000-4000-8000-000000000040', '7e640000-0000-4000-8000-00000000c040', 'C40'),
  ('7e641000-0000-4000-8000-000000000000', '7e640000-0000-4000-8000-00000000c000', 'C00');
insert into public.chef_settings (chef_id) values
  ('7e641000-0000-4000-8000-0000000000aa');
insert into public.chef_settings (chef_id, shop_minutes, updated_at) values
  ('7e641000-0000-4000-8000-000000000045', 45, '2026-11-01 10:00 Europe/Rome'),
  ('7e641000-0000-4000-8000-000000000040', 40, '2026-11-01 10:00 Europe/Rome'),
  ('7e641000-0000-4000-8000-000000000000', 0, '2026-11-01 10:00 Europe/Rome');

insert into public.availability_rules (chef_id, dow, start_time, end_time)
select '7e641000-0000-4000-8000-0000000000aa'::uuid, d, time '09:00', time '15:00' from generate_series(1, 5) as d;

insert into public.clients (id, chef_id, display_name) values
  ('7e642000-0000-4000-8000-0000000000aa', '7e641000-0000-4000-8000-0000000000aa', 'Cliente N'),
  ('7e642000-0000-4000-8000-000000000045', '7e641000-0000-4000-8000-000000000045', 'Cliente 45');

-- Horarios (HH:MI) que ofrece el generador a CN el martes 02/03/2027, con ahora = lunes 01/03/2027
-- a las 08:00 en Roma (no depende del día en que corre el test).
create function pg_temp.slots(p_cook int) returns text[]
language sql
as $$
  select coalesce(array_agg(to_char(c.start_time, 'HH24:MI') order by c.start_time), '{}')
  from private.free_slot_candidates('7e641000-0000-4000-8000-0000000000aa', p_cook, '2027-03-02', 1,
                                    '2027-03-01 08:00 Europe/Rome') as c
$$;

-- El martes de la semana que viene en Roma: booking_day_checks y get_free_days usan now().
create function pg_temp.next_tuesday() returns date
language sql
stable
as $$ select date_trunc('week', (now() at time zone 'Europe/Rome')::date)::date + 8 $$;

-- =====================================================================
-- 1. El valor por defecto
-- =====================================================================
select col_default_is('public', 'chef_settings', 'shop_minutes', '0',
  'chef_settings.shop_minutes vale 0 por defecto: la compra la hace el cliente');
select is(
  (select shop_minutes from public.chef_settings where chef_id = '7e641000-0000-4000-8000-0000000000aa'),
  0,
  'una cocinera nueva no tiene minutos de compra'
);
select is(
  (select shop_minutes from public.chef_settings where chef_id = 'cef00000-0000-4000-8000-000000000001'),
  0,
  'Evelyn en el seed (sembrada sin shop_minutes) tampoco'
);
select throws_ok(
  $$ update public.chef_settings set shop_minutes = -1 where chef_id = '7e641000-0000-4000-8000-0000000000aa' $$,
  '23514', null,
  'el check sigue: 0 vale, un negativo no'
);

-- =====================================================================
-- 2. Un día de 9:00 a 15:00
-- =====================================================================
select is(pg_temp.slots(180), array['09:00', '09:30', '10:00', '10:30', '11:00', '11:30', '12:00'],
  'el primer horario libre es 09:00 (ceil_a_30(9:00 + 0)); con 180 de cocina, el último 12:00');
select is(pg_temp.slots(360), array['09:00'], 'una sesión de 360 min (6 h) entra: de 9:00 a 15:00');
select is(pg_temp.slots(390), '{}'::text[], 'una de 390 min no entra nunca');

select lives_ok(
  $$ insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, status)
     values ('7e644000-0000-4000-8000-0000000000aa', '7e641000-0000-4000-8000-0000000000aa',
             '7e642000-0000-4000-8000-0000000000aa', '2027-03-03', '09:00', 360, 'confirmed') $$,
  'la base acepta una sesión de 9:00 a 15:00 (el miércoles: nunca es el martes que miran los de abajo)'
);
select is(
  (select format('%s %s', s.shop_minutes, s.busy = tstzrange('2027-03-03 09:00 Europe/Rome', '2027-03-03 15:30 Europe/Rome', '[)'))
   from public.sessions s where s.id = '7e644000-0000-4000-8000-0000000000aa'),
  '0 t',
  'copia los 0 minutos de compra: su rango ocupado empieza en la llegada y termina con el margen, [9:00, 15:30)'
);

select is(
  (select format('%s %s %s', c.start_time, c.status, c.suggested_start)
   from private.booking_day_checks('7e641000-0000-4000-8000-0000000000aa', array[pg_temp.next_tuesday()], null, 360) as c),
  '09:00:00 ok 09:00:00',
  'booking_day_checks: la llegada sugerida es 09:00 y una reserva de 360 min a esa hora está ok'
);
select is(
  (select c.status
   from private.booking_day_checks('7e641000-0000-4000-8000-0000000000aa', array[pg_temp.next_tuesday()], '09:00', 390) as c),
  'outside',
  'booking_day_checks: 390 min desde las 9:00 terminan después de las 15:00 (outside)'
);
select is(
  array[
    (select f.available from public.get_free_days('7e641000-0000-4000-8000-0000000000aa', 360, pg_temp.next_tuesday(), 1) as f),
    (select f.available from public.get_free_days('7e641000-0000-4000-8000-0000000000aa', 390, pg_temp.next_tuesday(), 1) as f)
  ],
  array[true, false],
  'get_free_days (el calendario de la web): el martes que viene tiene lugar para 360 min y no para 390'
);

-- =====================================================================
-- 3. private.replace_shop_minutes
-- =====================================================================
insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, status)
values ('7e644000-0000-4000-8000-000000000045', '7e641000-0000-4000-8000-000000000045',
        '7e642000-0000-4000-8000-000000000045', '2027-03-02', '10:00', 180, 'confirmed');

-- Las filas en 45 en este momento (en la base de los tests, también las del seed si estuvieran).
create temp table en_45 as
select chef_id from public.chef_settings where shop_minutes = 45;

-- Las del fixture: minutos de compra y si updated_at es el de ahora (now() es el de la transacción).
create function pg_temp.fixture() returns table (chef text, minutes int, touched boolean)
language sql
as $$
  select c.display_name, s.shop_minutes, s.updated_at = now()
  from public.chef_settings s
  join public.chefs c on c.id = s.chef_id
  where c.id in ('7e641000-0000-4000-8000-000000000045', '7e641000-0000-4000-8000-000000000040',
                 '7e641000-0000-4000-8000-000000000000')
  order by c.display_name
$$;

select is(
  (select format('%s %s', s.shop_minutes, s.busy = tstzrange('2027-03-02 09:15 Europe/Rome', '2027-03-02 13:30 Europe/Rome', '[)'))
   from public.sessions s where s.id = '7e644000-0000-4000-8000-000000000045'),
  '45 t',
  'antes: la sesión de C45 copió sus 45 minutos (compra desde las 9:15)'
);
select is(
  private.replace_shop_minutes(45, 0),
  (select count(*)::int from en_45),
  'devuelve cuántas filas cambió: las que estaban en 45'
);
select results_eq(
  $$ select chef, minutes, touched from pg_temp.fixture() $$,
  $$ values ('C00', 0, false), ('C40', 40, false), ('C45', 0, true) $$,
  'la de 45 pasa a 0 con updated_at nuevo; la de 40 (puesta a mano) y la de 0 quedan como estaban'
);
select is(
  (select format('%s %s', s.shop_minutes, s.busy = tstzrange('2027-03-02 09:15 Europe/Rome', '2027-03-02 13:30 Europe/Rome', '[)'))
   from public.sessions s where s.id = '7e644000-0000-4000-8000-000000000045'),
  '45 t',
  'la sesión que ya existía no cambia: guarda sus 45 minutos y su rango ocupado'
);
select is(private.replace_shop_minutes(45, 0), 0, 'otra corrida no cambia nada');

select throws_ok(
  $$ select private.replace_shop_minutes(null, 0) $$,
  '22023', 'invalid_shop_minutes',
  'sin los minutos anteriores: error (si no, no encontraría filas y pasaría en silencio)'
);
select throws_ok(
  $$ select private.replace_shop_minutes(45, -1) $$,
  '22023', 'invalid_shop_minutes',
  'minutos negativos: error (0 vale: sin compra)'
);

select is(
  (select array_agg(r order by r)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, 'private.replace_shop_minutes(integer, integer)', 'EXECUTE')),
  null::text[],
  'ningún rol de la API la ejecuta (la corren la migración o el dueño desde el SQL editor)'
);

-- =====================================================================
-- 4. private.clear_upcoming_shop_minutes
-- =====================================================================
-- Una sesión pasada de C45 con sus 45 minutos (la de 2027 es futura y sigue con los suyos).
insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, shop_minutes, status)
values ('7e644000-0000-4000-8000-000000000046', '7e641000-0000-4000-8000-000000000045',
        '7e642000-0000-4000-8000-000000000045', '2026-01-05', '10:00', 180, 45, 'confirmed');

-- Las vivas desde hoy con compra en este momento (también las del seed, si las hubiera).
create temp table vivas_con_compra as
select id from public.sessions
where shop_minutes > 0 and status in ('held', 'confirmed') and "date" >= (now() at time zone 'Europe/Rome')::date;

select is(
  private.clear_upcoming_shop_minutes(),
  (select count(*)::int from vivas_con_compra),
  'devuelve cuántas sesiones cambió: las held o confirmed desde hoy que tenían compra'
);
select is(
  (select format('%s %s', s.shop_minutes, s.busy = tstzrange('2027-03-02 10:00 Europe/Rome', '2027-03-02 13:30 Europe/Rome', '[)'))
   from public.sessions s where s.id = '7e644000-0000-4000-8000-000000000045'),
  '0 t',
  'la sesión futura de C45 deja la compra: su rango ocupado empieza en la llegada (10:00)'
);
select is(
  (select shop_minutes from public.sessions where id = '7e644000-0000-4000-8000-000000000046'),
  45,
  'la sesión pasada guarda sus 45 minutos'
);
select is(private.clear_upcoming_shop_minutes(), 0, 'otra corrida no cambia nada');
select is(
  (select array_agg(r order by r)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, 'private.clear_upcoming_shop_minutes()', 'EXECUTE')),
  null::text[],
  'ningún rol de la API ejecuta clear_upcoming_shop_minutes'
);

select finish();
rollback;
