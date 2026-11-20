-- =====================================================================
-- Horarios libres (SPEC §5.2): generador común, get_free_slots y get_free_days.
--
-- La regla de choque es la de no_overlap (margen de un solo lado): una candidata choca con una
-- sesión no cancelada (held incluida) si [llegada − compra, llegada + cocina + margen), armado
-- como sessions.busy con la compra y el margen actuales de la cocinera, se superpone con el busy
-- guardado de la sesión.
--
-- private.free_slot_candidates recibe p_now: las partes 1 a 8 lo fijan (lunes 01/03/2027 a las
-- 08:00 en Roma, salvo que se diga otra cosa) y no dependen del día en que corre el test.
-- get_free_slots y get_free_days usan now(): la parte 9 arma las fechas desde hoy en Roma, con
-- una cocinera sin aviso mínimo que trabaja todos los días.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(78);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
--   C1: valores por defecto (margen 30, paso 30, horizonte 56, aviso 24 h) y el horario decidido
--       el 15/11/2026: lunes a viernes de 9 a 15.
--   C2: otra cocinera, todos los días de 9 a 15 (cambios de hora).
--   C3: para las funciones públicas: todos los días de 8 a 20 y sin aviso mínimo.
--   Las tres con 45 minutos de compra, fijos: desde el 19/11/2026 el valor por defecto es 0 (la
--   compra la hace el cliente), pero la cuenta con compra sigue en la base (sessions.busy, la primera
--   llegada y el aviso mínimo) y estos tests la prueban. Sin compra: 16_sin_compra.test.sql.
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e5f0000-0000-4000-8000-00000000c001', 'chef1@slots.test'),
  ('7e5f0000-0000-4000-8000-00000000c002', 'chef2@slots.test'),
  ('7e5f0000-0000-4000-8000-00000000c003', 'chef3@slots.test');
update public.profiles set role = 'chef' where id::text like '7e5f0000-%';

insert into public.chefs (id, profile_id, display_name) values
  ('7e5f1000-0000-4000-8000-000000000001', '7e5f0000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e5f1000-0000-4000-8000-000000000002', '7e5f0000-0000-4000-8000-00000000c002', 'Chef Due'),
  ('7e5f1000-0000-4000-8000-000000000003', '7e5f0000-0000-4000-8000-00000000c003', 'Chef Tre');
insert into public.chef_settings (chef_id, shop_minutes) values
  ('7e5f1000-0000-4000-8000-000000000001', 45),
  ('7e5f1000-0000-4000-8000-000000000002', 45);
insert into public.chef_settings (chef_id, shop_minutes, min_notice_hours) values
  ('7e5f1000-0000-4000-8000-000000000003', 45, 0);

insert into public.availability_rules (chef_id, dow, start_time, end_time)
select '7e5f1000-0000-4000-8000-000000000001'::uuid, d, time '09:00', time '15:00' from generate_series(1, 5) as d
union all
select '7e5f1000-0000-4000-8000-000000000002'::uuid, d, time '09:00', time '15:00' from generate_series(0, 6) as d
union all
select '7e5f1000-0000-4000-8000-000000000003'::uuid, d, time '08:00', time '20:00' from generate_series(0, 6) as d;

insert into public.clients (id, chef_id, display_name) values
  ('7e5f2000-0000-4000-8000-00000000000a', '7e5f1000-0000-4000-8000-000000000001', 'Cliente A'),
  ('7e5f2000-0000-4000-8000-00000000000b', '7e5f1000-0000-4000-8000-000000000002', 'Cliente B'),
  ('7e5f2000-0000-4000-8000-00000000000c', '7e5f1000-0000-4000-8000-000000000003', 'Cliente C');

-- Horarios (HH:MI) que ofrece el generador un día, en orden. Por defecto: C1, ahora = lunes
-- 01/03/2027 a las 08:00 en Roma.
create function pg_temp.slots(
  p_day date, p_cook int,
  p_now timestamptz default '2027-03-01 08:00 Europe/Rome',
  p_chef uuid default '7e5f1000-0000-4000-8000-000000000001'
) returns text[]
language sql
as $$
  select coalesce(array_agg(to_char(c.start_time, 'HH24:MI') order by c.start_time), '{}')
  from private.free_slot_candidates(p_chef, p_cook, p_day, 1, p_now) as c
$$;

-- ¿La base acepta una sesión confirmada a esa hora? Inserta (compra y margen actuales: los copia
-- el trigger), mira si no_overlap la rechaza y la deshace: el bloque con exception es una
-- subtransacción.
create function pg_temp.fits(
  p_day date, p_start time, p_cook int,
  p_chef uuid default '7e5f1000-0000-4000-8000-000000000001',
  p_client uuid default '7e5f2000-0000-4000-8000-00000000000a'
) returns boolean
language plpgsql
as $$
begin
  insert into public.sessions (chef_id, client_id, date, start_time, cook_minutes, status)
  values (p_chef, p_client, p_day, p_start, p_cook, 'confirmed');
  raise exception 'probe_ok';
exception
  when exclusion_violation then
    return false;
  when raise_exception then
    if sqlerrm = 'probe_ok' then
      return true;
    end if;
    raise;
end
$$;

-- Horas de la grilla (cada 30 min, de p_first a p_close − cocina) en las que el generador y la
-- base no coinciden: ofrecida pero rechazada por no_overlap, o aceptada pero no ofrecida.
-- Vacío = coinciden.
create function pg_temp.mismatches(
  p_day date, p_cook int, p_first time, p_close time,
  p_now timestamptz default '2027-03-01 08:00 Europe/Rome',
  p_chef uuid default '7e5f1000-0000-4000-8000-000000000001',
  p_client uuid default '7e5f2000-0000-4000-8000-00000000000a'
) returns text[]
language sql
as $$
  select coalesce(array_agg(to_char(g.t, 'HH24:MI') order by g.t), '{}')
  from (
    select (p_first + make_interval(mins => m))::time as t
    from generate_series(0, (extract(epoch from p_close - p_first) / 60)::int - p_cook, 30) as m
  ) as g
  where pg_temp.fits(p_day, g.t, p_cook, p_chef, p_client)
        is distinct from (to_char(g.t, 'HH24:MI') = any (pg_temp.slots(p_day, p_cook, p_now, p_chef)))
$$;

-- Hoy en Roma (las funciones públicas usan now()).
create function pg_temp.today() returns date
language sql
stable
as $$ select (now() at time zone 'Europe/Rome')::date $$;

-- =====================================================================
-- 1. El rango ocupado de una candidata se arma como sessions.busy
-- =====================================================================
select is(
  private.session_busy('2027-07-15', '10:00', 45, 120, 30),
  tstzrange('2027-07-15 07:15:00+00', '2027-07-15 10:30:00+00', '[)'),
  'session_busy: en verano (CEST) 10:00 en Roma son las 08:00 UTC → [07:15, 10:30) con compra 45, cocina 120 y margen 30'
);
select is(
  private.session_busy('2027-01-15', '10:00', 45, 120, 30),
  tstzrange('2027-01-15 08:15:00+00', '2027-01-15 11:30:00+00', '[)'),
  'session_busy: en invierno (CET) → [08:15, 11:30) UTC'
);

-- =====================================================================
-- 2. Días: solo con regla y sin bloqueo
-- =====================================================================
select is(
  pg_temp.slots('2027-03-02', 150),
  array['10:00', '10:30', '11:00', '11:30', '12:00', '12:30'],
  'martes (mañana): desde ceil_a_30(9:00 + 45 de compra) = 10:00, cada 30 min, mientras la cocina termine a las 15:00'
);
select is(pg_temp.slots('2027-03-06', 150), '{}'::text[], 'sábado: sin regla, sin horarios');
select is(pg_temp.slots('2027-03-07', 150), '{}'::text[], 'domingo: sin regla, sin horarios');

insert into public.availability_exceptions (chef_id, date, note)
values ('7e5f1000-0000-4000-8000-000000000001', '2027-03-03', 'Giorno libero');
select is(pg_temp.slots('2027-03-03', 150), '{}'::text[], 'miércoles bloqueado: sin horarios');
select is(
  pg_temp.slots('2027-03-04', 150),
  array['10:00', '10:30', '11:00', '11:30', '12:00', '12:30'],
  'el bloqueo es solo de ese día: el jueves sigue igual'
);

-- =====================================================================
-- 3. Primera llegada, paso y cierre
-- =====================================================================
select is(
  pg_temp.slots('2027-03-02', 180),
  array['10:00', '10:30', '11:00', '11:30', '12:00'],
  'cocina 180: la última llegada es 12:00 (la cocina termina justo a las 15:00)'
);
select is(pg_temp.slots('2027-03-02', 300), array['10:00'], 'cocina 300: solo las 10:00');
select is(
  pg_temp.slots('2027-03-02', 330), '{}'::text[],
  'cocina 330: de 9 a 15 y con 45 de compra, una sesión de más de 5 h no entra nunca'
);

update public.chef_settings set slot_step_minutes = 60 where chef_id = '7e5f1000-0000-4000-8000-000000000001';
select is(pg_temp.slots('2027-03-02', 150), array['10:00', '11:00', '12:00'], 'con paso de 60 min: 10:00, 11:00 y 12:00');
update public.chef_settings set slot_step_minutes = 30, shop_minutes = 75 where chef_id = '7e5f1000-0000-4000-8000-000000000001';
select is(
  pg_temp.slots('2027-03-02', 150),
  array['10:30', '11:00', '11:30', '12:00', '12:30'],
  'con 75 min de compra, la primera llegada es ceil_a_30(10:15) = 10:30'
);
update public.chef_settings set shop_minutes = 45 where chef_id = '7e5f1000-0000-4000-8000-000000000001';

insert into public.availability_rules (chef_id, dow, start_time, end_time) values
  ('7e5f1000-0000-4000-8000-000000000001', 6, '09:00', '12:00'),
  ('7e5f1000-0000-4000-8000-000000000001', 6, '09:30', '12:00'),
  ('7e5f1000-0000-4000-8000-000000000001', 6, '14:00', '17:00');
select is(
  pg_temp.slots('2027-03-06', 60),
  array['10:00', '10:30', '11:00', '15:00', '15:30', '16:00'],
  'varias reglas el mismo día: la unión de sus horarios, sin repetir'
);
delete from public.availability_rules where chef_id = '7e5f1000-0000-4000-8000-000000000001' and dow = 6;

-- =====================================================================
-- 4. Aviso mínimo (p_now) y "hoy" en Roma
-- =====================================================================
select is(
  pg_temp.slots('2027-03-02', 150, '2027-03-01 10:00 Europe/Rome'),
  array['11:00', '11:30', '12:00', '12:30'],
  'aviso de 24 h: a las 10:00 del lunes, el martes la compra tiene que empezar desde las 10:00'
);
select is(
  pg_temp.slots('2027-03-02', 150, '2027-03-01 09:45 Europe/Rome'),
  array['10:30', '11:00', '11:30', '12:00', '12:30'],
  'la compra de las 10:30 empieza a las 9:45, justo 24 h después de ahora: entra'
);
select is(
  pg_temp.slots('2027-03-02', 150, '2027-03-01 09:46 Europe/Rome'),
  array['11:00', '11:30', '12:00', '12:30'],
  'un minuto después ya no'
);

update public.chef_settings set min_notice_hours = 48 where chef_id = '7e5f1000-0000-4000-8000-000000000001';
select is(pg_temp.slots('2027-03-02', 150), '{}'::text[], 'con aviso de 48 h, el martes no tiene horarios');

update public.chef_settings set min_notice_hours = 0 where chef_id = '7e5f1000-0000-4000-8000-000000000001';
select is(
  pg_temp.slots('2027-03-01', 150), '{}'::text[],
  'sin aviso mínimo, hoy igual no se ofrece: la ventana empieza mañana'
);
select is(
  pg_temp.slots('2027-03-02', 150, '2027-03-01 23:30+00'), '{}'::text[],
  'a las 23:30 UTC del lunes ya es martes en Roma: el martes es hoy'
);
select is(
  pg_temp.slots('2027-03-02', 150, '2027-03-01 22:30+00'),
  array['10:00', '10:30', '11:00', '11:30', '12:00', '12:30'],
  'a las 22:30 UTC todavía es lunes en Roma: el martes es mañana'
);
update public.chef_settings set min_notice_hours = 24 where chef_id = '7e5f1000-0000-4000-8000-000000000001';

-- =====================================================================
-- 5. Horizonte: de mañana a hoy + booking_horizon_days. Por defecto 56 (8 semanas, decisión del
--    15/11/2026): la ventana del formulario, DATE_WINDOW.maxDaysAhead en el contrato. Si se separan,
--    falla availability.test.ts (compara el valor por defecto de las migraciones con el contrato).
--    Las cocineras que ya existían (en producción, Evelyn en 14) las pasa a 56
--    private.replace_booking_horizon: la prueba 10_booking_horizon.
-- =====================================================================
select col_default_is(
  'public', 'chef_settings', 'booking_horizon_days', '56'::text,
  'booking_horizon_days vale 56 por defecto: las 8 semanas del formulario'
);
select is(
  (select array_agg(s.booking_horizon_days order by s.chef_id)
   from public.chef_settings s
   where s.chef_id in ('cef00000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000002')),
  array[56, 56],
  'el valor por defecto llega a las filas nuevas: las cocineras del seed (sembradas sin booking_horizon_days) tienen 56'
);
select is(
  (select max(c.day)
   from private.free_slot_candidates('7e5f1000-0000-4000-8000-000000000001', 150, '2027-03-02', 90,
                                     '2027-03-01 08:00 Europe/Rome') as c),
  date '2027-04-26',
  'con el valor por defecto, el último día es el lunes 26/04 (hoy + 56) aunque se pidan 90'
);

update public.chef_settings set booking_horizon_days = 14 where chef_id = '7e5f1000-0000-4000-8000-000000000001';
select is(
  (select array_agg(distinct c.day order by c.day)
   from private.free_slot_candidates('7e5f1000-0000-4000-8000-000000000001', 150, '2027-03-02', 30,
                                     '2027-03-01 08:00 Europe/Rome') as c),
  array['2027-03-02', '2027-03-04', '2027-03-05', '2027-03-08', '2027-03-09', '2027-03-10',
        '2027-03-11', '2027-03-12', '2027-03-15']::date[],
  'con horizonte de 14 días: de mañana a hoy + 14, días hábiles sin bloqueo, aunque se pidan 30'
);

update public.chef_settings set booking_horizon_days = 7 where chef_id = '7e5f1000-0000-4000-8000-000000000001';
select is(
  (select max(c.day)
   from private.free_slot_candidates('7e5f1000-0000-4000-8000-000000000001', 150, '2027-03-02', 30,
                                     '2027-03-01 08:00 Europe/Rome') as c),
  date '2027-03-08',
  'con horizonte de 7 días, el último es el lunes 08/03 (hoy + 7)'
);
update public.chef_settings set booking_horizon_days = default where chef_id = '7e5f1000-0000-4000-8000-000000000001';

select is(
  (select min(c.day)
   from private.free_slot_candidates('7e5f1000-0000-4000-8000-000000000001', 150, '2027-02-20', 30,
                                     '2027-03-01 08:00 Europe/Rome') as c),
  date '2027-03-02',
  'una fecha de inicio pasada empieza igual mañana'
);
select is(
  (select array_agg(distinct c.day order by c.day)
   from private.free_slot_candidates('7e5f1000-0000-4000-8000-000000000001', 150, '2027-03-10', 2,
                                     '2027-03-01 08:00 Europe/Rome') as c),
  array['2027-03-10', '2027-03-11']::date[],
  'p_days recorta el rango pedido: del 10 al 11'
);

-- =====================================================================
-- 6. Choques: held, confirmadas y cualquier estado salvo cancelled
-- =====================================================================
insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, status, hold_until) values
  ('7e5f3000-0000-4000-8000-000000000001', '7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a',
   '2027-03-04', '10:00', 150, 'held', now() + interval '48 hours');
select is(
  pg_temp.slots('2027-03-04', 150), '{}'::text[],
  'una sesión held (presupuesto enviado; ocupa de 9:15 a 13:00 con el margen) bloquea como una confirmada'
);

update public.sessions set status = 'cancelled', hold_until = null, cancelled_at = now(), cancel_reason = 'declined'
where id = '7e5f3000-0000-4000-8000-000000000001';
select is(
  pg_temp.slots('2027-03-04', 150),
  array['10:00', '10:30', '11:00', '11:30', '12:00', '12:30'],
  'cancelada, ya no bloquea'
);

insert into public.sessions (chef_id, client_id, date, start_time, cook_minutes, status) values
  ('7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a', '2027-03-05', '10:00', 150, 'confirmed'),
  ('7e5f1000-0000-4000-8000-000000000002', '7e5f2000-0000-4000-8000-00000000000b', '2027-03-08', '10:00', 150, 'confirmed'),
  ('7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a', '2027-03-09', '10:00', 150, 'cooked');
select is(pg_temp.slots('2027-03-05', 150), '{}'::text[], 'una confirmada bloquea');
select is(
  pg_temp.slots('2027-03-08', 150),
  array['10:00', '10:30', '11:00', '11:30', '12:00', '12:30'],
  'la sesión de otra cocinera no bloquea'
);
select is(pg_temp.slots('2027-03-09', 150), '{}'::text[], 'cualquier estado que no sea cancelled bloquea (cooked)');

-- Margen de un solo lado, en el borde exacto (cocina 60: llegadas de 10:00 a 14:00).
-- Antes de la candidata: E1 llega 9:15 y cocina 90 → termina 10:45, + 30 de margen = 11:15.
insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, status) values
  ('7e5f3000-0000-4000-8000-0000000000e1', '7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a',
   '2027-03-10', '09:15', 90, 'confirmed');
select is(
  pg_temp.slots('2027-03-10', 60),
  array['12:00', '12:30', '13:00', '13:30', '14:00'],
  'después de una sesión: la compra de las 12:00 empieza 11:15, justo al terminar su margen; entra'
);
update public.sessions set start_time = '09:16' where id = '7e5f3000-0000-4000-8000-0000000000e1';
select is(
  pg_temp.slots('2027-03-10', 60),
  array['12:30', '13:00', '13:30', '14:00'],
  'con un minuto menos de margen (termina 10:46), las 12:00 ya no'
);
select ok(
  not pg_temp.fits('2027-03-10', '12:00', 60) and pg_temp.fits('2027-03-10', '12:30', 60),
  'la base dice lo mismo: las 12:00 chocan y las 12:30 entran'
);

-- Después de la candidata: E2 llega 13:15, así que su compra empieza 12:30.
insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, status) values
  ('7e5f3000-0000-4000-8000-0000000000e2', '7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a',
   '2027-03-11', '13:15', 60, 'confirmed');
select is(
  pg_temp.slots('2027-03-11', 60),
  array['10:00', '10:30', '11:00'],
  'antes de una sesión: terminar de cocinar a las 12:00 deja justo los 30 de margen hasta su compra (12:30); entra'
);
update public.sessions set start_time = '13:14' where id = '7e5f3000-0000-4000-8000-0000000000e2';
select is(
  pg_temp.slots('2027-03-11', 60),
  array['10:00', '10:30'],
  'si su compra empieza 12:29, las 11:00 ya no'
);
select throws_ok(
  $$ insert into public.sessions (chef_id, client_id, date, start_time, cook_minutes, status)
     values ('7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a',
             '2027-03-11', '11:00', 60, 'confirmed') $$,
  '23P01', null,
  'y la base rechaza esa misma hora (no_overlap): lo que no se ofrece tampoco se puede reservar'
);

-- Cada sesión guarda su compra y su margen; la candidata usa los actuales de la cocinera.
insert into public.sessions (chef_id, client_id, date, start_time, cook_minutes, shop_minutes, gap_minutes, status) values
  ('7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a', '2027-03-12', '10:00', 60, 45, 60, 'confirmed');
select is(
  pg_temp.slots('2027-03-12', 60),
  array['13:00', '13:30', '14:00'],
  'una sesión con 60 de margen guardado (termina 11:00, libre desde 12:00): las 12:30 no entran aunque hoy el margen sea 30'
);
update public.chef_settings set gap_minutes = 60 where chef_id = '7e5f1000-0000-4000-8000-000000000001';
select is(
  pg_temp.slots('2027-03-11', 60),
  array['10:00'],
  'con 60 de margen actual, las 10:30 ya no entran antes de la compra de las 12:29'
);
update public.chef_settings set gap_minutes = 30 where chef_id = '7e5f1000-0000-4000-8000-000000000001';

-- =====================================================================
-- 7. Propiedad: el generador y no_overlap dicen lo mismo
-- =====================================================================
select is(
  (select array_agg(format('%s, cocina %s: %s', g.d::date, k.cook, x.m) order by g.d, k.cook)
   from generate_series(date '2027-03-02', date '2027-03-15', interval '1 day') as g(d)
   cross join (values (60), (150), (180)) as k(cook)
   cross join lateral (select pg_temp.mismatches(g.d::date, k.cook, '10:00', '15:00') as m) as x
   where extract(isodow from g.d) <= 5 and g.d::date <> date '2027-03-03' and cardinality(x.m) > 0),
  null::text[],
  'en cada día hábil de la ventana, toda llegada posible se ofrece si y solo si la base acepta la sesión (cocina 60, 150 y 180)'
);
select ok(
  (select count(*) from private.free_slot_candidates('7e5f1000-0000-4000-8000-000000000001', 60, '2027-03-02', 14,
                                                     '2027-03-01 08:00 Europe/Rome')) > 20
  and not pg_temp.fits('2027-03-05', '10:00', 60),
  'y no es trivial: hay muchos horarios ofrecidos y horas que la base rechaza'
);

-- =====================================================================
-- 8. Cambios de hora (C2, todos los días de 9 a 15), con otro TimeZone en la conexión
-- =====================================================================
set local timezone = 'America/New_York';

select is(
  pg_temp.slots('2027-03-28', 150, '2027-03-20 12:00 Europe/Rome', '7e5f1000-0000-4000-8000-000000000002'),
  array['10:00', '10:30', '11:00', '11:30', '12:00', '12:30'],
  'domingo 28/03/2027 (pasa a CEST): las mismas horas de llegada en Roma'
);
select is(
  private.session_busy('2027-03-28', '10:00', 45, 150, 30),
  tstzrange('2027-03-28 07:15:00+00', '2027-03-28 11:00:00+00', '[)'),
  'ese día 10:00 en Roma son las 08:00 UTC: [07:15, 11:00) con cocina 150'
);

insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, status) values
  ('7e5f3000-0000-4000-8000-000000000328', '7e5f1000-0000-4000-8000-000000000002', '7e5f2000-0000-4000-8000-00000000000b',
   '2027-03-28', '14:00', 30, 'confirmed');
select is(
  (select busy from public.sessions where id = '7e5f3000-0000-4000-8000-000000000328'),
  tstzrange('2027-03-28 11:15:00+00', '2027-03-28 13:00:00+00', '[)'),
  'una sesión de ese día (14:00, cocina 30) ocupa [11:15, 13:00) UTC'
);
select is(
  pg_temp.slots('2027-03-28', 60, '2027-03-20 12:00 Europe/Rome', '7e5f1000-0000-4000-8000-000000000002'),
  array['10:00', '10:30', '11:00', '11:30'],
  'y quedan libres las llegadas que terminan, con el margen, antes de su compra (13:15)'
);
select is(
  pg_temp.mismatches('2027-03-28', 60, '10:00', '15:00', '2027-03-20 12:00 Europe/Rome',
                     '7e5f1000-0000-4000-8000-000000000002', '7e5f2000-0000-4000-8000-00000000000b'),
  '{}'::text[],
  'el día del cambio de hora, el generador y no_overlap también coinciden'
);

select is(
  pg_temp.slots('2027-10-31', 150, '2027-10-25 12:00 Europe/Rome', '7e5f1000-0000-4000-8000-000000000002'),
  array['10:00', '10:30', '11:00', '11:30', '12:00', '12:30'],
  'domingo 31/10/2027 (vuelve a CET): las mismas horas de llegada'
);
select is(
  private.session_busy('2027-10-31', '10:00', 45, 150, 30),
  tstzrange('2027-10-31 08:15:00+00', '2027-10-31 12:00:00+00', '[)'),
  'ese día 10:00 en Roma son las 09:00 UTC'
);

set local timezone = 'UTC';

-- =====================================================================
-- 9. Funciones públicas (usan now()): C3, todos los días de 8 a 20, sin aviso mínimo
--   hoy + 2: bloqueado
--   hoy + 4: confirmada 9:30, cocina 150 → ocupado de 8:45 a 12:30
--   hoy + 5: confirmada 8:45, cocina 660 → todo el día
--   hoy + 6: held 15:00, cocina 60 → ocupado de 14:15 a 16:30
-- =====================================================================
insert into public.availability_exceptions (chef_id, date, note)
values ('7e5f1000-0000-4000-8000-000000000003', pg_temp.today() + 2, 'Giorno libero');
insert into public.sessions (chef_id, client_id, date, start_time, cook_minutes, status, hold_until) values
  ('7e5f1000-0000-4000-8000-000000000003', '7e5f2000-0000-4000-8000-00000000000c', pg_temp.today() + 4, '09:30', 150, 'confirmed', null),
  ('7e5f1000-0000-4000-8000-000000000003', '7e5f2000-0000-4000-8000-00000000000c', pg_temp.today() + 5, '08:45', 660, 'confirmed', null),
  ('7e5f1000-0000-4000-8000-000000000003', '7e5f2000-0000-4000-8000-00000000000c', pg_temp.today() + 6, '15:00', 60, 'held',
   now() + interval '48 hours');

-- get_free_slots de C3 como "días desde hoy HH:MI".
create function pg_temp.shown(p_cook int, p_from date, p_days int) returns text[]
language sql
as $$
  select coalesce(array_agg(format('%s %s', s.day - pg_temp.today(), to_char(s.start_time, 'HH24:MI'))
                            order by s.day, s.start_time), '{}')
  from public.get_free_slots('7e5f1000-0000-4000-8000-000000000003', p_cook, p_from, p_days) as s
$$;

-- get_free_days de C3 como "días desde hoy:t|f".
create function pg_temp.flags(p_cook int, p_from date, p_days int) returns text[]
language sql
as $$
  select array_agg(format('%s:%s', d.day - pg_temp.today(), case when d.available then 't' else 'f' end) order by d.day)
  from public.get_free_days('7e5f1000-0000-4000-8000-000000000003', p_cook, p_from, p_days) as d
$$;

select is(
  pg_temp.shown(150, pg_temp.today() + 1, 14),
  array['1 09:00', '1 11:00', '1 13:00', '3 09:00', '3 11:00', '3 13:00', '4 13:30', '4 15:30', '4 17:30',
        '6 09:00', '6 11:00', '6 17:30', '7 09:00', '7 11:00', '7 13:00'],
  'get_free_slots: hasta 3 por día, separados al menos 2 h, en los primeros 5 días con lugar (saltea el bloqueado y el lleno)'
);
select is(
  (select count(*)::int from public.get_free_slots('7e5f1000-0000-4000-8000-000000000003', 150, pg_temp.today() + 1, 14) as s
   where not pg_temp.fits(s.day, s.start_time, 150, '7e5f1000-0000-4000-8000-000000000003', '7e5f2000-0000-4000-8000-00000000000c')),
  0,
  'propiedad: cada horario que muestra get_free_slots se puede reservar sin chocar con no_overlap'
);
select is(
  pg_temp.shown(150, pg_temp.today() - 3, 14),
  pg_temp.shown(150, pg_temp.today() + 1, 14),
  'una fecha de inicio pasada no ofrece días pasados ni hoy'
);
select is(
  pg_temp.shown(150, pg_temp.today() + 1, 2),
  array['1 09:00', '1 11:00', '1 13:00'],
  'p_days recorta el rango: mañana y pasado (bloqueado)'
);
select is(
  pg_temp.shown(600, pg_temp.today() + 1, 14),
  array['1 09:00', '3 09:00', '7 09:00', '8 09:00', '9 09:00'],
  'cocina 600: un horario por día (9:00, 9:30 y 10:00 están a menos de 2 h) y los días con sesiones ya no tienen lugar'
);
select is(
  pg_temp.flags(150, pg_temp.today() - 1, 18),
  array['-1:f', '0:f', '1:t', '2:f', '3:t', '4:t', '5:f', '6:t', '7:t', '8:t', '9:t', '10:t', '11:t', '12:t',
        '13:t', '14:t', '15:t', '16:t'],
  'get_free_days: cada fecha del rango; con lugar desde mañana, salvo el día bloqueado y el lleno'
);
select is(
  pg_temp.flags(150, pg_temp.today() + 54, 5),
  array['54:t', '55:t', '56:t', '57:f', '58:f'],
  'get_free_days: con lugar hasta hoy + 56 (booking_horizon_days por defecto); después del horizonte, no'
);
select is(
  pg_temp.flags(600, pg_temp.today() + 1, 14),
  array['1:t', '2:f', '3:t', '4:f', '5:f', '6:f', '7:t', '8:t', '9:t', '10:t', '11:t', '12:t', '13:t', '14:t'],
  'get_free_days depende de la duración: con 600 min, los días con una sesión ya no tienen lugar'
);

-- Validación de los datos
select throws_ok(
  $$ select * from public.get_free_days('7e5f1000-0000-4000-8000-000000000003', 0, current_date, 14) $$,
  '22023', 'invalid_cook_minutes', 'cocina 0: error'
);
select throws_ok(
  $$ select * from public.get_free_slots('7e5f1000-0000-4000-8000-000000000003', 721, current_date, 14) $$,
  '22023', 'invalid_cook_minutes', 'cocina de más de 720 min: error'
);
select throws_ok(
  $$ select * from public.get_free_days('7e5f1000-0000-4000-8000-000000000003', null, current_date, 14) $$,
  '22023', 'invalid_cook_minutes', 'sin cocina: error'
);
select throws_ok(
  $$ select * from public.get_free_days('7e5f1000-0000-4000-8000-000000000003', 150, current_date, 0) $$,
  '22023', 'invalid_days', '0 días: error'
);
select throws_ok(
  $$ select * from public.get_free_slots('7e5f1000-0000-4000-8000-000000000003', 150, current_date, 367) $$,
  '22023', 'invalid_days', 'más de 366 días: error'
);
select throws_ok(
  $$ select * from public.get_free_days('7e5f1000-0000-4000-8000-000000000003', 150, null, 14) $$,
  '22023', 'invalid_from_date', 'sin fecha de inicio: error'
);
select throws_ok(
  $$ select * from public.get_free_days('7e5f1000-0000-4000-8000-000000000003', 150, 'infinity', 14) $$,
  '22023', 'invalid_from_date', 'fecha de inicio infinita: error'
);
select throws_ok(
  $$ select * from public.get_free_slots('7e5f1000-0000-4000-8000-0000000000ff', 150, current_date, 14) $$,
  'P0002', 'chef_not_found', 'cocinera inexistente: error'
);
select throws_ok(
  $$ select * from private.free_slot_candidates('7e5f1000-0000-4000-8000-000000000003', 150, current_date, 14, null) $$,
  '22023', 'invalid_now', 'el generador exige p_now'
);
select lives_ok(
  $$ select * from public.get_free_days('7e5f1000-0000-4000-8000-000000000003', 720, current_date, 366) $$,
  'los máximos válidos (720 min, 366 días) se aceptan'
);
select lives_ok(
  $$ select * from public.get_free_slots('7e5f1000-0000-4000-8000-000000000003', 1, current_date, 1) $$,
  'y los mínimos (1 min, 1 día)'
);

-- Quién las ejecuta
select is(
  (select array_agg(p.proname::text order by p.proname)
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('get_free_slots', 'get_free_days')
     and p.prosecdef
     and p.proconfig @> array['search_path=""']),
  array['get_free_days', 'get_free_slots'],
  'las dos funciones públicas son security definer con search_path vacío (para llamar al generador de private)'
);
select is(
  (select array_agg(format('%s → %s', r, f) order by 1)
   from unnest(array['public.get_free_slots(uuid,integer,date,integer)',
                     'public.get_free_days(uuid,integer,date,integer)']) as f
   cross join unnest(array['anon', 'authenticated']) as r
   where has_function_privilege(r, f, 'EXECUTE')),
  null::text[],
  'anon y authenticated no las ejecutan: la web lee los días por la Edge Function'
);
select ok(
  has_function_privilege('service_role', 'public.get_free_slots(uuid,integer,date,integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.get_free_days(uuid,integer,date,integer)', 'EXECUTE'),
  'la service role sí (Edge Function public-request)'
);
select is(
  (select array_agg(format('%s → %s', r, f) order by 1)
   from unnest(array['private.free_slot_candidates(uuid,integer,date,integer,timestamp with time zone)',
                     'private.session_busy(date,time without time zone,integer,integer,integer)']) as f
   cross join unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, f, 'EXECUTE')),
  null::text[],
  'las funciones de private no las ejecuta ningún rol de la API'
);

set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select throws_ok(
  $$ select * from public.get_free_days('7e5f1000-0000-4000-8000-000000000003', 150, current_date, 14) $$,
  '42501', 'permission denied for function get_free_days',
  'anon: no lee los días libres por RPC'
);
select throws_ok(
  $$ select * from public.get_free_slots('7e5f1000-0000-4000-8000-000000000003', 150, current_date, 14) $$,
  '42501', 'permission denied for function get_free_slots',
  'anon: ni los horarios'
);
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e5f0000-0000-4000-8000-00000000c003","role":"authenticated"}';
select throws_ok(
  $$ select * from public.get_free_days('7e5f1000-0000-4000-8000-000000000003', 150, current_date, 14) $$,
  '42501', 'permission denied for function get_free_days',
  'authenticated (aunque sea la cocinera): tampoco'
);
reset role;
set local role service_role;
select lives_ok(
  $$ select * from public.get_free_days('7e5f1000-0000-4000-8000-000000000003', 150,
                                        (now() at time zone 'Europe/Rome')::date + 1, 14) $$,
  'service_role: lee los días'
);
reset role;

-- =====================================================================
-- 10. La cuenta de las candidatas es exactamente la de la columna generada
-- =====================================================================
select is(
  (select count(*)::int from public.sessions s
   where s.busy is distinct from private.session_busy(s.date, s.start_time, s.shop_minutes, s.cook_minutes, s.gap_minutes)),
  0,
  'private.session_busy da el mismo rango que sessions.busy en todas las sesiones (seed y fixture, con cambios de hora)'
);
select ok((select count(*) from public.sessions) >= 10, 'y hay sesiones de sobra para comparar');

select finish();
rollback;
