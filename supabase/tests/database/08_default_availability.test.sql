-- =====================================================================
-- Horario inicial de las cocineras (migración 20261115130100_default_availability.sql).
-- Decisión del dueño del 15/11/2026: lunes a viernes de 9 a 15 para toda cocinera sin
-- ninguna regla de disponibilidad, hasta que la app tenga editor.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(6);

-- ---------------------------------------------------------------------
-- Fixture (como postgres): C1 sin reglas, C2 con una regla propia (sábado de 10 a 12).
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e5e0000-0000-4000-8000-00000000c001', 'chef1@horario.test'),
  ('7e5e0000-0000-4000-8000-00000000c002', 'chef2@horario.test');
update public.profiles set role = 'chef' where id::text like '7e5e0000-%';

insert into public.chefs (id, profile_id, display_name) values
  ('7e5e1000-0000-4000-8000-000000000001', '7e5e0000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e5e1000-0000-4000-8000-000000000002', '7e5e0000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.availability_rules (chef_id, dow, start_time, end_time)
values ('7e5e1000-0000-4000-8000-000000000002', 6, '10:00', '12:00');

-- Las cocineras sin reglas en este momento (en la base de los tests, también las del seed si no tuvieran).
create temp table sin_reglas as
select c.id from public.chefs c
where not exists (select 1 from public.availability_rules r where r.chef_id = c.id);

select ok(
  exists (select 1 from sin_reglas where id = '7e5e1000-0000-4000-8000-000000000001'),
  'antes: C1 no tiene ninguna regla'
);

select is(
  private.add_default_availability(),
  (select 5 * count(*)::int from sin_reglas),
  'agrega 5 reglas (lunes a viernes) por cada cocinera sin ninguna'
);
select results_eq(
  $$ select dow, start_time, end_time from public.availability_rules
     where chef_id = '7e5e1000-0000-4000-8000-000000000001' order by dow $$,
  $$ values (1::smallint, '09:00'::time, '15:00'::time), (2::smallint, '09:00'::time, '15:00'::time),
            (3::smallint, '09:00'::time, '15:00'::time), (4::smallint, '09:00'::time, '15:00'::time),
            (5::smallint, '09:00'::time, '15:00'::time) $$,
  'la cocinera sin reglas queda de lunes a viernes de 9 a 15'
);
select results_eq(
  $$ select dow, start_time, end_time from public.availability_rules
     where chef_id = '7e5e1000-0000-4000-8000-000000000002' $$,
  $$ values (6::smallint, '10:00'::time, '12:00'::time) $$,
  'una cocinera que ya tenía alguna regla no se toca'
);
select is(private.add_default_availability(), 0, 'idempotente: otra corrida no agrega nada');

select is(
  (select array_agg(r order by r)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, 'private.add_default_availability()', 'EXECUTE')),
  null::text[],
  'ningún rol de la API la ejecuta (la corren la migración o el dueño desde el SQL editor)'
);

select finish();
rollback;
