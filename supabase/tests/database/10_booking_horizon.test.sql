-- =====================================================================
-- Ventana de reserva de 8 semanas (migración 20261115130200_booking_horizon_8_weeks.sql).
-- Decisión del dueño del 15/11/2026: el día preferido se elige de mañana a 56 días.
--
-- El valor por defecto y el corte en hoy + 56 los prueba 07_free_slots (parte 5 y parte 9). Acá,
-- private.replace_booking_horizon, que pasa a las cocineras que ya existían (en producción,
-- Evelyn). db reset aplica las migraciones sobre una base vacía y siembra después, así que la
-- llamada de la migración no encuentra filas: lo que se prueba es la función. Que la migración la
-- llame con (14, 56) lo exige supabase/functions/_shared/availability.test.ts.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(8);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS): cuatro cocineras con un updated_at viejo.
--   C07: en 7, puesto a mano (más corto que el anterior).
--   C14: en 14, el valor por defecto anterior (como Evelyn en producción antes de la migración).
--   C21: en 21, puesto a mano (más largo).
--   C56: ya en 56.
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e600000-0000-4000-8000-00000000c007', 'chef07@horizonte.test'),
  ('7e600000-0000-4000-8000-00000000c014', 'chef14@horizonte.test'),
  ('7e600000-0000-4000-8000-00000000c021', 'chef21@horizonte.test'),
  ('7e600000-0000-4000-8000-00000000c056', 'chef56@horizonte.test');
update public.profiles set role = 'chef' where id::text like '7e600000-%';

insert into public.chefs (id, profile_id, display_name) values
  ('7e601000-0000-4000-8000-000000000007', '7e600000-0000-4000-8000-00000000c007', 'C07'),
  ('7e601000-0000-4000-8000-000000000014', '7e600000-0000-4000-8000-00000000c014', 'C14'),
  ('7e601000-0000-4000-8000-000000000021', '7e600000-0000-4000-8000-00000000c021', 'C21'),
  ('7e601000-0000-4000-8000-000000000056', '7e600000-0000-4000-8000-00000000c056', 'C56');
insert into public.chef_settings (chef_id, booking_horizon_days, updated_at) values
  ('7e601000-0000-4000-8000-000000000007', 7, '2026-11-01 10:00 Europe/Rome'),
  ('7e601000-0000-4000-8000-000000000014', 14, '2026-11-01 10:00 Europe/Rome'),
  ('7e601000-0000-4000-8000-000000000021', 21, '2026-11-01 10:00 Europe/Rome'),
  ('7e601000-0000-4000-8000-000000000056', 56, '2026-11-01 10:00 Europe/Rome');

-- Las filas en 14 en este momento (en la base de los tests, también las del seed si estuvieran).
create temp table en_14 as
select chef_id from public.chef_settings where booking_horizon_days = 14;

-- Las del fixture: ventana y si updated_at es el de ahora (now() es el de la transacción).
create function pg_temp.fixture() returns table (chef text, days int, touched boolean)
language sql
as $$
  select c.display_name, s.booking_horizon_days, s.updated_at = now()
  from public.chef_settings s
  join public.chefs c on c.id = s.chef_id
  where c.id::text like '7e601000-%'
  order by c.display_name
$$;

select ok(
  exists (select 1 from en_14 where chef_id = '7e601000-0000-4000-8000-000000000014'),
  'antes: C14 sigue en 14'
);

select is(
  private.replace_booking_horizon(14, 56),
  (select count(*)::int from en_14),
  'devuelve cuántas filas cambió: las que estaban en 14'
);
select results_eq(
  $$ select chef, days, touched from pg_temp.fixture() $$,
  $$ values ('C07', 7, false), ('C14', 56, true), ('C21', 21, false), ('C56', 56, false) $$,
  'la de 14 pasa a 56 con updated_at nuevo; las de 7 y 21 (puestas a mano) y la de 56 quedan como estaban'
);
select is(private.replace_booking_horizon(14, 56), 0, 'otra corrida no cambia nada');

select throws_ok(
  $$ select private.replace_booking_horizon(null, 56) $$,
  '22023', 'invalid_horizon',
  'sin la ventana anterior: error (si no, no encontraría filas y pasaría en silencio)'
);
select throws_ok(
  $$ select private.replace_booking_horizon(14, 0) $$,
  '22023', 'invalid_horizon',
  'una ventana de 0 días: error'
);

select is(
  (select array_agg(r order by r)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, 'private.replace_booking_horizon(integer, integer)', 'EXECUTE')),
  null::text[],
  'ningún rol de la API la ejecuta (la corren la migración o el dueño desde el SQL editor)'
);
select ok(
  has_function_privilege('postgres', 'private.replace_booking_horizon(integer, integer)', 'EXECUTE'),
  'postgres sí la ejecuta (db push y el SQL editor)'
);

select finish();
rollback;
