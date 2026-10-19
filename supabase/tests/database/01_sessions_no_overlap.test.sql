-- =====================================================================
-- Sesiones: busy, no_overlap (margen de un solo lado) y hold_until.
-- SPEC §4 (anti doble reserva), §5.2 (regla de choque), criterios 3 y 4.
--
-- Regla: busy = [inicio − compra, fin de cocina + margen). Dos sesiones del
-- mismo chef chocan si a_ini < b_fin + margen y b_ini < a_fin + margen.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(26);

-- ---------------------------------------------------------------------
-- Fixture: dos cocineras con un cliente cada una (como postgres, sin RLS)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e570000-0000-4000-8000-00000000c001', 'chef1@overlap.test'),
  ('7e570000-0000-4000-8000-00000000c002', 'chef2@overlap.test');
update public.profiles set role = 'chef'
where id in ('7e570000-0000-4000-8000-00000000c001', '7e570000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e571000-0000-4000-8000-000000000001', '7e570000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e571000-0000-4000-8000-000000000002', '7e570000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e571000-0000-4000-8000-000000000001'),
  ('7e571000-0000-4000-8000-000000000002');

insert into public.clients (id, chef_id, display_name, contact_email) values
  ('7e572000-0000-4000-8000-00000000000a', '7e571000-0000-4000-8000-000000000001', 'Cliente A', 'a@overlap.test'),
  ('7e572000-0000-4000-8000-00000000000f', '7e571000-0000-4000-8000-000000000002', 'Cliente X', 'x@overlap.test');

-- Atajo: crea una sesión del chef 1 (compra 45, margen 30 salvo que se indique) y devuelve su id.
create function pg_temp.sesion(
  p_date date, p_start time, p_cook int,
  p_status public.session_status default 'confirmed',
  p_chef uuid default '7e571000-0000-4000-8000-000000000001',
  p_client uuid default '7e572000-0000-4000-8000-00000000000a',
  p_shop int default 45, p_gap int default 30
) returns uuid
language sql
as $$
  insert into public.sessions (chef_id, client_id, date, start_time, cook_minutes, shop_minutes, gap_minutes,
                               status, hold_until, cancelled_at)
  values (p_chef, p_client, p_date, p_start, p_cook, p_shop, p_gap, p_status,
          case when p_status = 'held' then now() + interval '48 hours' end,
          case when p_status = 'cancelled' then now() end)
  returning id
$$;

-- ---------------------------------------------------------------------
-- busy: instantes UTC correctos en verano e invierno, sin depender del
-- TimeZone de la conexión
-- ---------------------------------------------------------------------
set local timezone = 'America/New_York';

insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, shop_minutes, gap_minutes, status) values
  ('7e574000-0000-4000-8000-0000000000a7', '7e571000-0000-4000-8000-000000000002', '7e572000-0000-4000-8000-00000000000f',
   '2027-07-15', '10:00', 120, 45, 30, 'confirmed'),
  ('7e574000-0000-4000-8000-0000000000a1', '7e571000-0000-4000-8000-000000000002', '7e572000-0000-4000-8000-00000000000f',
   '2027-01-15', '10:00', 120, 45, 30, 'confirmed'),
  -- Domingo 28/03/2027 a las 02:00 Roma pasa a 03:00: 01:30 + 60 min de cocina = 60 minutos reales
  ('7e574000-0000-4000-8000-0000000000a3', '7e571000-0000-4000-8000-000000000002', '7e572000-0000-4000-8000-00000000000f',
   '2027-03-28', '01:30', 60, 0, 0, 'confirmed');

select is(
  (select busy from public.sessions where id = '7e574000-0000-4000-8000-0000000000a7'),
  tstzrange('2027-07-15 07:15:00+00', '2027-07-15 10:30:00+00', '[)'),
  'verano (CEST): 10:00 en Roma = 08:00 UTC → busy [07:15, 10:30) UTC con compra 45, cocina 120, margen 30'
);

select is(
  (select lower(busy) + make_interval(mins => shop_minutes) from public.sessions
   where id = '7e574000-0000-4000-8000-0000000000a7'),
  '2027-07-15 08:00:00+00'::timestamptz,
  'verano: la llegada (inicio de cocina) es 08:00 UTC'
);

select is(
  (select busy from public.sessions where id = '7e574000-0000-4000-8000-0000000000a1'),
  tstzrange('2027-01-15 08:15:00+00', '2027-01-15 11:30:00+00', '[)'),
  'invierno (CET): 10:00 en Roma = 09:00 UTC → busy [08:15, 11:30) UTC'
);

select is(
  (select busy from public.sessions where id = '7e574000-0000-4000-8000-0000000000a3'),
  tstzrange('2027-03-28 00:30:00+00', '2027-03-28 01:30:00+00', '[)'),
  'cambio de hora: la aritmética de busy es en minutos reales'
);

set local timezone = 'UTC';

-- Compra y margen se copian de chef_settings si no vienen, y quedan fijos en la fila
insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, status)
values ('7e574000-0000-4000-8000-0000000000d1', '7e571000-0000-4000-8000-000000000002',
        '7e572000-0000-4000-8000-00000000000f', '2027-05-03', '10:00', 150, 'confirmed');

select is(
  (select array[shop_minutes, gap_minutes] from public.sessions where id = '7e574000-0000-4000-8000-0000000000d1'),
  array[45, 30],
  'sin compra/margen explícitos se copian de chef_settings (45 y 30)'
);

update public.chef_settings set shop_minutes = 60, gap_minutes = 45
where chef_id = '7e571000-0000-4000-8000-000000000002';

select is(
  (select busy from public.sessions where id = '7e574000-0000-4000-8000-0000000000d1'),
  tstzrange('2027-05-03 07:15:00+00', '2027-05-03 11:00:00+00', '[)'),
  'cambiar chef_settings no mueve sesiones existentes'
);

-- ---------------------------------------------------------------------
-- Borde del margen (un solo lado)
-- B: llega 10:00, compra desde 09:15, termina de cocinar 12:00, margen 30 → busy [09:15, 12:30)
-- ---------------------------------------------------------------------
select lives_ok(
  $$ select pg_temp.sesion('2027-03-10', '10:00', 120) $$,
  'sesión B: 10:00–12:00, compra 45, margen 30'
);

select throws_ok(
  $$ select pg_temp.sesion('2027-03-10', '13:14', 90) $$,
  '23P01', null,
  'después de B: una sesión cuya compra empieza 12:29 choca (falta 1 minuto de margen)'
);

select lives_ok(
  $$ select pg_temp.sesion('2027-03-10', '13:15', 90) $$,
  'después de B: una sesión cuya compra empieza 12:30 entra (exactamente un margen)'
);

-- Antes de B: termina de cocinar 08:45 + margen 30 = 09:15 = inicio de compra de B
select throws_ok(
  $$ select pg_temp.sesion('2027-03-10', '07:16', 90) $$,
  '23P01', null,
  'antes de B: terminar de cocinar 08:46 choca con la compra de B a las 09:15'
);

select lives_ok(
  $$ select pg_temp.sesion('2027-03-10', '07:15', 90) $$,
  'antes de B: terminar de cocinar 08:45 entra (margen de 30 hasta 09:15)'
);

select throws_ok(
  $$ select pg_temp.sesion('2027-03-10', '10:00', 120) $$,
  '23P01', null,
  'mismo horario exacto choca'
);

select throws_ok(
  $$ select pg_temp.sesion('2027-03-10', '11:00', 30) $$,
  '23P01', null,
  'una sesión contenida dentro de otra choca'
);

-- ---------------------------------------------------------------------
-- held bloquea; cancelled no bloquea; distintos chefs no chocan
-- ---------------------------------------------------------------------
insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, shop_minutes, gap_minutes, status, hold_until)
values ('7e574000-0000-4000-8000-0000000000e1', '7e571000-0000-4000-8000-000000000001',
        '7e572000-0000-4000-8000-00000000000a', '2027-03-11', '10:00', 120, 45, 30, 'held', now() + interval '48 hours');

select throws_ok(
  $$ select pg_temp.sesion('2027-03-11', '11:00', 120, 'confirmed') $$,
  '23P01', null,
  'una sesión held (presupuesto enviado) bloquea el horario a una confirmada'
);

select throws_ok(
  $$ select pg_temp.sesion('2027-03-11', '11:00', 120, 'held') $$,
  '23P01', null,
  'dos presupuestos (held) no pueden prometer el mismo horario'
);

select lives_ok(
  $$ update public.sessions set status = 'confirmed', hold_until = null
     where id = '7e574000-0000-4000-8000-0000000000e1' $$,
  'held → confirmed no choca consigo misma'
);

select lives_ok(
  $$ update public.sessions set status = 'cancelled', cancelled_at = now(), cancel_reason = 'declined'
     where id = '7e574000-0000-4000-8000-0000000000e1' $$,
  'cancelar la sesión'
);

select lives_ok(
  $$ select pg_temp.sesion('2027-03-11', '11:00', 120, 'confirmed') $$,
  'al cancelarse, el horario queda libre'
);

select lives_ok(
  $$ select pg_temp.sesion('2027-03-12', '10:00', 120, 'cancelled') $$,
  'sesión cancelada'
);

select lives_ok(
  $$ select pg_temp.sesion('2027-03-12', '10:00', 120, 'confirmed') $$,
  'una sesión cancelada no bloquea el mismo horario'
);

select lives_ok(
  $$ select pg_temp.sesion('2027-03-10', '10:00', 120,
       p_chef => '7e571000-0000-4000-8000-000000000002', p_client => '7e572000-0000-4000-8000-00000000000f') $$,
  'otra cocinera puede tener una sesión a la misma hora'
);

-- ---------------------------------------------------------------------
-- hold_until obligatorio solo para held
-- ---------------------------------------------------------------------
select throws_ok(
  $$ insert into public.sessions (chef_id, client_id, date, start_time, cook_minutes, status)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a',
             '2027-04-01', '10:00', 120, 'held') $$,
  '23514', null,
  'held sin hold_until se rechaza'
);

select throws_ok(
  $$ insert into public.sessions (chef_id, client_id, date, start_time, cook_minutes, status, hold_until)
     values ('7e571000-0000-4000-8000-000000000001', '7e572000-0000-4000-8000-00000000000a',
             '2027-04-02', '10:00', 120, 'confirmed', now() + interval '1 day') $$,
  '23514', null,
  'confirmed con hold_until se rechaza'
);

select lives_ok(
  $$ select pg_temp.sesion('2027-03-11', '16:00', 60, 'held') $$,
  'held con hold_until se acepta'
);

select throws_ok(
  $$ update public.sessions set status = 'confirmed'
     where chef_id = '7e571000-0000-4000-8000-000000000001' and status = 'held' and date = '2027-03-11' $$,
  '23514', null,
  'pasar de held a confirmed exige limpiar hold_until'
);

select is(
  (select count(*)::int from public.sessions
   where chef_id = '7e571000-0000-4000-8000-000000000001' and status = 'held' and hold_until is not null),
  1,
  'la held con hold_until se guardó bien'
);

select finish();
rollback;
