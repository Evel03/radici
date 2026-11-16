-- =====================================================================
-- Días bloqueados desde la app (PR «Bloquear días», sin migración): la cocinera escribe
-- availability_exceptions con su sesión, bajo la RLS "la cocinera gestiona las suyas"
-- (20261019100200_rls.sql) y los grants de 20261019130000_api_grants.sql, y la web deja de
-- ofrecer esos días (get_free_days los descuenta, 20261115130000_free_slots.sql).
--
-- La app bloquea con un upsert on conflict (chef_id, date, kind) do nothing: devuelve solo las
-- filas creadas, así «Deshacer» nunca borra un bloqueo que ya existía.
--
-- D = hoy en Roma + 3: dentro de la ventana de reserva (14 días, o 56) y con el aviso mínimo de
-- 24 h cumplido, así el día tiene lugar si no está bloqueado.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(20);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS): dos cocineras y un cliente de C1. C1 trabaja los 7 días
-- de 9 a 15, para que D tenga horario caiga el día que caiga.
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e5b0000-0000-4000-8000-00000000c001', 'chef1@bloqueos.test'),
  ('7e5b0000-0000-4000-8000-00000000c002', 'chef2@bloqueos.test'),
  ('7e5b0000-0000-4000-8000-00000000a001', 'a@bloqueos.test');
update public.profiles set role = 'chef'
where id in ('7e5b0000-0000-4000-8000-00000000c001', '7e5b0000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e5b1000-0000-4000-8000-000000000001', '7e5b0000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e5b1000-0000-4000-8000-000000000002', '7e5b0000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e5b1000-0000-4000-8000-000000000001'),
  ('7e5b1000-0000-4000-8000-000000000002');
insert into public.availability_rules (chef_id, dow, start_time, end_time)
select '7e5b1000-0000-4000-8000-000000000001'::uuid, d, time '09:00', time '15:00'
from generate_series(0, 6) as d;

insert into public.clients (id, chef_id, profile_id, display_name, status) values
  ('7e5b2000-0000-4000-8000-00000000000a', '7e5b1000-0000-4000-8000-000000000001',
   '7e5b0000-0000-4000-8000-00000000a001', 'Cliente A', 'active');

-- C2 bloqueó el mismo día.
insert into public.availability_exceptions (chef_id, date, note)
values ('7e5b1000-0000-4000-8000-000000000002', (now() at time zone 'Europe/Rome')::date + 3, 'C2');

-- =====================================================================
-- Cocinera 1, con su sesión
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e5b0000-0000-4000-8000-00000000c001","role":"authenticated"}';

select lives_ok(
  $$ insert into public.availability_exceptions (chef_id, date, note)
     values ('7e5b1000-0000-4000-8000-000000000001', (now() at time zone 'Europe/Rome')::date + 3, 'Ferie') $$,
  'C1 bloquea un día suyo'
);
select is(
  (select count(*)::int from public.availability_exceptions), 1,
  'C1 ve solo los suyos (ni los de C2 ni los de otras cocineras)'
);
select is(
  (select kind::text from public.availability_exceptions
   where date = (now() at time zone 'Europe/Rome')::date + 3), 'blocked',
  'el tipo es blocked por defecto'
);
select lives_ok(
  $$ insert into public.availability_exceptions (chef_id, date, kind, note)
     values ('7e5b1000-0000-4000-8000-000000000001', (now() at time zone 'Europe/Rome')::date + 3, 'blocked', 'Otra')
     on conflict (chef_id, date, kind) do nothing $$,
  'bloquear dos veces no falla (upsert)'
);
select is_empty(
  $$ insert into public.availability_exceptions (chef_id, date, kind, note)
     values ('7e5b1000-0000-4000-8000-000000000001', (now() at time zone 'Europe/Rome')::date + 3, 'blocked', 'Otra')
     on conflict (chef_id, date, kind) do nothing
     returning id $$,
  'el upsert no devuelve el bloqueo que ya existía: «Deshacer» nunca lo borra'
);
select is(
  (select note from public.availability_exceptions
   where date = (now() at time zone 'Europe/Rome')::date + 3), 'Ferie',
  'el upsert no pisa la nota del que ya existía'
);
select throws_ok(
  $$ insert into public.availability_exceptions (chef_id, date)
     values ('7e5b1000-0000-4000-8000-000000000001', (now() at time zone 'Europe/Rome')::date + 3) $$,
  '23505', null,
  'sin upsert, el mismo día choca con el único'
);
select isnt_empty(
  $$ insert into public.availability_exceptions (chef_id, date, kind, note)
     values ('7e5b1000-0000-4000-8000-000000000001', (now() at time zone 'Europe/Rome')::date + 5, 'blocked', null)
     on conflict (chef_id, date, kind) do nothing
     returning id, date, note $$,
  'el upsert devuelve el bloqueo que creó (con id, fecha y nota)'
);
select throws_ok(
  $$ insert into public.availability_exceptions (chef_id, date)
     values ('7e5b1000-0000-4000-8000-000000000002', (now() at time zone 'Europe/Rome')::date + 4) $$,
  '42501', null,
  'C1 no bloquea días de C2'
);
select lives_ok(
  $$ update public.availability_exceptions set note = 'Vacanze'
     where chef_id = '7e5b1000-0000-4000-8000-000000000001'
       and date = (now() at time zone 'Europe/Rome')::date + 3 $$,
  'C1 edita su nota'
);
select is(
  (select note from public.availability_exceptions
   where date = (now() at time zone 'Europe/Rome')::date + 3), 'Vacanze',
  'la nota quedó cambiada'
);
select is_empty(
  $$ update public.availability_exceptions set note = 'x'
     where chef_id = '7e5b1000-0000-4000-8000-000000000002' returning id $$,
  'C1 no edita los de C2 (no los ve)'
);
select is_empty(
  $$ delete from public.availability_exceptions
     where chef_id = '7e5b1000-0000-4000-8000-000000000002' returning id $$,
  'C1 no borra los de C2 (no los ve)'
);

-- =====================================================================
-- Cliente A (de C1) y anónimo
-- =====================================================================
set local request.jwt.claims = '{"sub":"7e5b0000-0000-4000-8000-00000000a001","role":"authenticated"}';

select is(
  (select count(*)::int from public.availability_exceptions), 0,
  'un cliente no ve los días bloqueados (ni las notas)'
);
select throws_ok(
  $$ insert into public.availability_exceptions (chef_id, date)
     values ('7e5b1000-0000-4000-8000-000000000001', (now() at time zone 'Europe/Rome')::date + 6) $$,
  '42501', null,
  'un cliente no bloquea días de su cocinera'
);

reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';

select throws_ok(
  $$ select * from public.availability_exceptions $$,
  '42501', null,
  'anon: no lee los días bloqueados'
);

-- =====================================================================
-- La web (get_free_days, que corre con la service role) deja de ofrecerlos
-- =====================================================================
reset role;

select results_eq(
  $$ select available from public.get_free_days(
       '7e5b1000-0000-4000-8000-000000000001', 300, (now() at time zone 'Europe/Rome')::date + 3, 3) $$,
  $$ values (false), (true), (false) $$,
  'la web no ofrece los días bloqueados desde la app: D no, el siguiente sí, D + 2 no'
);
select is(
  (select note from public.availability_exceptions
   where chef_id = '7e5b1000-0000-4000-8000-000000000002'), 'C2',
  'el de C2 quedó intacto'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e5b0000-0000-4000-8000-00000000c001","role":"authenticated"}';

select lives_ok(
  $$ delete from public.availability_exceptions
     where chef_id = '7e5b1000-0000-4000-8000-000000000001'
       and date = (now() at time zone 'Europe/Rome')::date + 3 $$,
  'C1 desbloquea su día'
);

reset role;

select is(
  (select available from public.get_free_days(
     '7e5b1000-0000-4000-8000-000000000001', 300, (now() at time zone 'Europe/Rome')::date + 3, 1)),
  true,
  'desbloqueado, la web lo vuelve a ofrecer'
);

select finish();
rollback;
