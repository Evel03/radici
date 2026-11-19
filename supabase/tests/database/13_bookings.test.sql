-- =====================================================================
-- Reservas (plan del área de Evelyn, PR 3; migraciones 20261116150000_pay_mode_manual.sql y
-- 20261116150100_bookings.sql). Decisiones del dueño del 16/11/2026: una reserva es de 1 a 8
-- semanas, con una sesión de cocina por semana; en Fase 0 las reservas ya crean sesiones reales y
-- la web descuenta esos días; el precio del servicio lo fija Evelyn; el cobro es manual.
--
--   1. Esquema: pay_mode 'manual', las columnas nuevas de sessions, una sesión por semana, la
--      guarda y el delete de requests y de clients.
--   2. split_cents: el reparto exacto del servicio.
--   3. dryRun: el estado de cada fecha (con su prioridad) y la llegada sugerida, sin escribir nada.
--   4. Creación desde un pedido: N sesiones confirmed con pay_mode manual, el pedido accepted con
--      weeks y seen_at, la ficha de prospect a trial; la web deja de ofrecer esos días.
--   5. Reintento desde un pedido: mismas fechas y hora.
--   6. Choques: todo o nada, y el error dice la fecha.
--   7. Validaciones (el precio del servicio es obligatorio).
--   8. Alta a mano: ficha nueva, ficha existente (no se modifica) y reintento con la misma clave.
--   9. Transiciones (sessions_guard_update), para todos los roles.
--  10. Mover: solo held o confirmed, con la hora y los minutos guardados si no vienen.
--  11. Cancelar: el día vuelve a aparecer en get_free_days; una semana cobrada, solo con permiso.
--  12. Permisos: la app no ejecuta las chef_*, no escribe sesiones y no borra pedidos ni fichas.
--
-- Las fechas se arman desde el lunes que viene en Roma: pg_temp.d(0) es ese lunes, d(1) el martes,
-- d(5) el sábado, d(7) el lunes siguiente. Siempre caen después de hoy y, hasta d(49), dentro de la
-- ventana de 56 días (8 semanas) de get_free_days.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(163);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
--   C1: margen 30 y horizonte 56 (por defecto), sin aviso mínimo (get_free_days ofrece cualquier
--       día desde mañana); lunes a viernes de 9 a 15, el horario de Evelyn.
--   C2: otra cocinera (aislamiento y pruebas de la guarda).
--   Las dos con 45 minutos de compra, fijos: desde el 19/11/2026 el valor por defecto es 0 (la
--   compra la hace el cliente), pero la cuenta con compra sigue en la base (la llegada sugerida,
--   outside y busy) y estos tests la prueban. Sin compra: 16_sin_compra.test.sql.
--   Fichas de C1: P (prospecto, pedido R1 de la web por 2 semanas, que Evelyn confirma por 4),
--   Q (prospecto: R2 extra, R3 de 3 semanas, RW de la web con clave y RC, un pedido de cambio),
--   A (activa), O (activa, con una sesión el miércoles d(9) a las 10:00) y S (prospecto).
--   De C2: X, con el pedido RX y la sesión XS.
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e630000-0000-4000-8000-00000000c001', 'chef1@reservas.test'),
  ('7e630000-0000-4000-8000-00000000c002', 'chef2@reservas.test');
update public.profiles set role = 'chef'
where id in ('7e630000-0000-4000-8000-00000000c001', '7e630000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e631000-0000-4000-8000-000000000001', '7e630000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e631000-0000-4000-8000-000000000002', '7e630000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id, shop_minutes, min_notice_hours) values
  ('7e631000-0000-4000-8000-000000000001', 45, 0),
  ('7e631000-0000-4000-8000-000000000002', 45, 0);
insert into public.availability_rules (chef_id, dow, start_time, end_time)
select c, d, time '09:00', time '15:00'
from unnest(array['7e631000-0000-4000-8000-000000000001', '7e631000-0000-4000-8000-000000000002']::uuid[]) as c
cross join generate_series(1, 5) as d;

-- El lunes que viene en Roma más p_offset días, y lo mismo como texto AAAA-MM-DD.
create function pg_temp.d(p_offset int) returns date
language sql
stable
as $$ select date_trunc('week', (now() at time zone 'Europe/Rome')::date::timestamp)::date + 7 + p_offset $$;

create function pg_temp.f(p_offset int) returns text
language sql
stable
as $$ select to_char(pg_temp.d(p_offset), 'YYYY-MM-DD') $$;

insert into public.clients (id, chef_id, display_name, contact_phone, zone, address, adults, kids, status) values
  ('7e632000-0000-4000-8000-0000000000a1', '7e631000-0000-4000-8000-000000000001', 'Paola Rinaldi', '+393330000001', 'Loreto',     null,            2, 2, 'prospect'),
  ('7e632000-0000-4000-8000-0000000000a2', '7e631000-0000-4000-8000-000000000001', 'Quinto Sala',   '+393330000002', 'Redona',     null,            1, 0, 'prospect'),
  ('7e632000-0000-4000-8000-0000000000a3', '7e631000-0000-4000-8000-000000000001', 'Anna Rota',     '+393330000003', 'Città Alta', 'Via Gombito 1', 2, 0, 'active'),
  ('7e632000-0000-4000-8000-0000000000a4', '7e631000-0000-4000-8000-000000000001', 'Otto Villa',    '+393330000004', 'Valtesse',   null,            1, 0, 'active'),
  ('7e632000-0000-4000-8000-0000000000a5', '7e631000-0000-4000-8000-000000000001', 'Sofia Bassi',   '+393330000005', 'Boccaleone', null,            3, 0, 'prospect'),
  ('7e632000-0000-4000-8000-0000000000f1', '7e631000-0000-4000-8000-000000000002', 'Xenia Ferri',   '+393330000009', 'Dalmine',    null,            1, 0, 'active');

insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals, weeks, source, preferred_date, request_key) values
  ('7e633000-0000-4000-8000-0000000000b1', '7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a1',
   'week',  'new', 2, 2, 5, '{dinner}', 2, 'web', pg_temp.d(1), null),
  ('7e633000-0000-4000-8000-0000000000b2', '7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a2',
   'extra', 'new', 8, 0, 1, '{dinner}', 1, 'web', null, null),
  ('7e633000-0000-4000-8000-0000000000b3', '7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a2',
   'week',  'new', 1, 0, 5, '{lunch}', 3, 'web', null, null),
  ('7e633000-0000-4000-8000-0000000000b4', '7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a2',
   'week',  'new', 1, 0, 3, '{lunch}', 1, 'web', null, '7e63e000-0000-4000-8000-000000000003'),
  ('7e633000-0000-4000-8000-0000000000bf', '7e631000-0000-4000-8000-000000000002', '7e632000-0000-4000-8000-0000000000f1',
   'week',  'new', 1, 0, 5, '{lunch}', 1, 'web', null, null);
insert into public.requests (id, chef_id, client_id, type, status, text, source) values
  ('7e633000-0000-4000-8000-0000000000b5', '7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a2',
   'change', 'new', 'Pasar la cena del jueves al viernes', 'app');

insert into public.sessions (id, chef_id, client_id, "date", start_time, cook_minutes, status) values
  ('7e634000-0000-4000-8000-0000000000c1', '7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a4',
   pg_temp.d(9), '10:00', 180, 'confirmed'),
  ('7e634000-0000-4000-8000-0000000000cf', '7e631000-0000-4000-8000-000000000002', '7e632000-0000-4000-8000-0000000000f1',
   pg_temp.d(1), '10:00', 180, 'confirmed');

insert into public.availability_exceptions (chef_id, "date", note)
values ('7e631000-0000-4000-8000-000000000001', pg_temp.d(17), 'Ferie');

-- Respuestas de las funciones e ids de las sesiones creadas.
create temp table res (k text primary key, r jsonb);
create temp table ids (k text primary key, v uuid);

-- Reserva desde un pedido de C1: compra estimada 63 € y 20 porciones por semana.
create function pg_temp.reservar(
  p_request uuid, p_dates date[], p_start time default '10:00',
  p_service int default 56000, p_dry boolean default false, p_cook int default 180
) returns jsonb
language sql
as $$
  select public.chef_create_booking(
    p_chef_id => '7e631000-0000-4000-8000-000000000001', p_dates => p_dates, p_start => p_start,
    p_cook_minutes => p_cook, p_portions => 20, p_groceries_est_cents => 6300,
    p_service_total_cents => p_service, p_request_id => p_request, p_dry_run => p_dry)
$$;

-- Reserva a mano de C1 (ficha existente o nueva).
create function pg_temp.a_mano(
  p_dates date[], p_key uuid, p_client uuid default null, p_new jsonb default null,
  p_type public.request_type default 'week', p_start time default '10:00', p_service int default 50000,
  p_household jsonb default '{"adults": 2, "kids": 1, "days": 5, "meals": ["dinner"]}',
  p_locale text default null, p_dry boolean default false
) returns jsonb
language sql
as $$
  select public.chef_create_booking(
    p_chef_id => '7e631000-0000-4000-8000-000000000001', p_dates => p_dates, p_start => p_start,
    p_cook_minutes => 180, p_portions => 15, p_groceries_est_cents => 5050,
    p_service_total_cents => p_service, p_client_id => p_client, p_new_client => p_new,
    p_type => p_type, p_household => p_household, p_locale => p_locale,
    p_request_key => p_key, p_dry_run => p_dry)
$$;

-- Un campo de cada semana de una respuesta guardada en res, en orden.
create function pg_temp.semanas(p_k text, p_campo text) returns text[]
language sql
stable
as $$
  select array_agg(x.w ->> p_campo order by x.n)
  from res, jsonb_array_elements(res.r -> 'weeks') with ordinality as x (w, n)
  where res.k = p_k
$$;

-- Corre una sentencia y devuelve 'ok' o 'SQLSTATE mensaje | detalle' (el detalle trae la fecha
-- de un choque). Si falla, el bloque con exception deshace lo que haya escrito.
create function pg_temp.err(p_sql text) returns text
language plpgsql
as $$
declare
  v_state text;
  v_msg   text;
  v_det   text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_det = pg_exception_detail;
  return v_state || ' ' || v_msg || coalesce(' | ' || nullif(v_det, ''), '');
end
$$;

-- Cuántas fichas, pedidos y sesiones tiene C1 (para ver que algo no escribió nada).
create function pg_temp.conteo() returns text
language sql
stable
as $$
  select format('fichas %s · pedidos %s · sesiones %s',
    (select count(*) from public.clients  where chef_id = '7e631000-0000-4000-8000-000000000001'),
    (select count(*) from public.requests where chef_id = '7e631000-0000-4000-8000-000000000001'),
    (select count(*) from public.sessions where chef_id = '7e631000-0000-4000-8000-000000000001'))
$$;

-- =====================================================================
-- 1. Esquema
-- =====================================================================
select enum_has_labels('public', 'pay_mode', array['preauth', 'pay_after', 'manual'],
  'pay_mode suma manual: el de las sesiones que crea Evelyn (el cron de pre-autorización de M6 toma solo las preauth)');

select is(
  (select array_agg(format('%s %s %s', c.column_name, c.data_type, c.is_generated) order by c.column_name)
   from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'sessions'
     and c.column_name in ('shopping_done_at', 'cooked_at', 'week_start')),
  array['cooked_at timestamp with time zone NEVER', 'shopping_done_at timestamp with time zone NEVER',
        'week_start date ALWAYS'],
  'sessions: shopping_done_at y cooked_at (timestamptz) y week_start, una columna generada'
);

select is(
  (select i.indexdef from pg_indexes i where i.schemaname = 'public' and i.indexname = 'sessions_una_por_semana'),
  'CREATE UNIQUE INDEX sessions_una_por_semana ON public.sessions USING btree (request_id, week_start) WHERE ((request_id IS NOT NULL) AND (status <> ''cancelled''::session_status))',
  'una sesión viva por semana de cada pedido: las canceladas y las sesiones sin pedido no cuentan'
);

select is(
  (select format('%s %s', case when t.tgtype & 2 = 2 then 'before' else 'after' end,
                 concat_ws(' ', case when t.tgtype & 4 = 4 then 'insert' end,
                                case when t.tgtype & 16 = 16 then 'update' end,
                                case when t.tgtype & 8 = 8 then 'delete' end))
   from pg_trigger t
   where t.tgrelid = 'public.sessions'::regclass and t.tgname = 'sessions_guard_update'),
  'before update',
  'sessions_guard_update corre antes de cada UPDATE, no en INSERT'
);

select ok(
  not has_table_privilege('authenticated', 'public.requests', 'DELETE')
  and has_table_privilege('authenticated', 'public.requests', 'SELECT')
  and has_table_privilege('service_role', 'public.requests', 'DELETE'),
  'requests: authenticated ya no borra pedidos (los sigue leyendo); service_role sí'
);
select ok(
  not has_table_privilege('authenticated', 'public.clients', 'DELETE')
  and has_table_privilege('authenticated', 'public.clients', 'SELECT')
  and has_column_privilege('authenticated', 'public.clients', 'status', 'UPDATE')
  and has_table_privilege('service_role', 'public.clients', 'DELETE'),
  'clients: authenticated tampoco borra fichas (en cascada se llevaban la reserva); las sigue leyendo y cambia su estado; service_role sí'
);

-- =====================================================================
-- 2. split_cents
-- =====================================================================
select is(private.split_cents(50000, 3), array[16667, 16667, 16666],
  'split_cents: 500 € en 3 semanas son 166,67 + 166,67 + 166,66 (los centavos que sobran, a las primeras)');
select is(private.split_cents(56000, 4), array[14000, 14000, 14000, 14000],
  '560 € en 4 semanas, 4 × 140 €');
select is(private.split_cents(5, 8) || private.split_cents(0, 2), array[1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
  '5 centavos en 8: uno a cada una de las cinco primeras; 0 en 2: ceros');
select is(
  (select array_agg(format('%s/%s', t, n) order by t, n)
   from generate_series(0, 1000, 7) as t
   cross join generate_series(1, 8) as n
   cross join lateral (select private.split_cents(t, n) as p) as x
   where cardinality(x.p) <> n
      or (select sum(v) from unnest(x.p) as v) <> t
      or (select max(v) - min(v) from unnest(x.p) as v) > 1
      or x.p[1] < x.p[n]),
  null::text[],
  'propiedad: n partes que suman el total, difieren como mucho en 1 y las primeras nunca son menores'
);
select throws_ok($$ select private.split_cents(-1, 2) $$, '22023', 'invalid_cents', 'un total negativo: error');
select throws_ok($$ select private.split_cents(100, 0) $$, '22023', 'invalid_parts', 'cero partes: error');

-- =====================================================================
-- 3. dryRun
-- =====================================================================
insert into res (k, r) values ('conteo_inicial', to_jsonb(pg_temp.conteo()));

select lives_ok(
  $$ insert into res (k, r)
     select 'dry', pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1',
                                    array[pg_temp.d(-13), pg_temp.d(3), pg_temp.d(9), pg_temp.d(17), pg_temp.d(26)],
                                    '10:00', 50001, true) $$,
  'dryRun de un pedido con 5 fechas, una por semana'
);
select is(pg_temp.semanas('dry', 'status'), array['past', 'ok', 'busy', 'blocked', 'closed'],
  'el estado de cada fecha: el martes pasado, un jueves libre, el miércoles de otra clienta a la misma hora, un día bloqueado y un sábado');
select is(pg_temp.semanas('dry', 'suggested_start'), array['10:00:00', '10:00:00', '10:00:00', '10:00:00', null],
  'la llegada sugerida es ceil_a_30(9:00 + 45 de compra) = 10:00; un día sin horario no tiene');
select is(pg_temp.semanas('dry', 'service_cents'), array['10001', '10000', '10000', '10000', '10000'],
  'y el servicio de cada semana, ya repartido');
select is(
  (select format('%s %s %s %s %s', r ->> 'dry_run', r ->> 'duplicate', r ->> 'request_id', r ->> 'client_id',
                 (select count(*) from jsonb_array_elements(r -> 'weeks') as w where w ->> 'session_id' is not null))
   from res where k = 'dry'),
  'true false 7e633000-0000-4000-8000-0000000000b1 7e632000-0000-4000-8000-0000000000a1 0',
  'trae el pedido y la clienta, y ninguna sesión'
);
select is(pg_temp.conteo(), (select r #>> '{}' from res where k = 'conteo_inicial'),
  'el dryRun no escribe nada');
select is(
  (select format('%s %s', r.status, c.status)
   from public.requests r join public.clients c on c.id = r.client_id
   where r.id = '7e633000-0000-4000-8000-0000000000b1'),
  'new prospect',
  'el pedido sigue new y la ficha, prospecto'
);

select is(
  array[
    pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[pg_temp.d(4)], '09:30', 0, true) #>> '{weeks,0,status}',
    pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[pg_temp.d(4)], '13:00', 0, true) #>> '{weeks,0,status}',
    pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[pg_temp.d(4)], '12:00', 0, true) #>> '{weeks,0,status}',
    pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[pg_temp.d(4)], '10:00', 0, true, 300) #>> '{weeks,0,status}',
    pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[pg_temp.d(4)], '10:00', 0, true, 330) #>> '{weeks,0,status}'
  ],
  array['outside', 'outside', 'ok', 'ok', 'outside'],
  'fuera de horario: compra antes de las 9:00 (llega 9:30) o cocina después de las 15:00 (13:00 + 180); 12:00 + 180 y 10:00 + 300 entran justo; 330 min, nunca'
);
select is(
  (select format('%s %s %s', w ->> 'start_time', w ->> 'status', w ->> 'suggested_start')
   from jsonb_array_elements(pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[pg_temp.d(4)], null, 0, true) -> 'weeks') as w),
  '10:00:00 ok 10:00:00',
  'dryRun sin hora: cada fecha se evalúa con su llegada sugerida'
);
select is(
  (select format('%s %s %s', coalesce(w ->> 'start_time', '-'), w ->> 'status', coalesce(w ->> 'suggested_start', '-'))
   from jsonb_array_elements(pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[pg_temp.d(5)], null, 0, true) -> 'weeks') as w),
  '- closed -',
  'y un día sin horario queda sin hora: closed'
);
select is(
  (select format('%s %s %s', r ->> 'dry_run', coalesce(r ->> 'client_id', '-'), coalesce(r ->> 'request_id', '-'))
   from (select pg_temp.a_mano(array[pg_temp.d(4)], null, p_new => '{"name": "Nuova Cliente"}', p_dry => true) as r) as q),
  'true - -',
  'dryRun a mano con una ficha nueva (sin clave): sin ficha ni pedido'
);
select is(pg_temp.conteo(), (select r #>> '{}' from res where k = 'conteo_inicial'),
  'tampoco escribe nada');

-- Prioridad de los estados (busy > past > blocked > closed > outside > ok): solo busy impide crear,
-- así que un día que choca nunca puede mostrarse solo con un aviso. Una sesión ya hecha el
-- miércoles pasado y, por un rato, el sábado d(5) y el miércoles d(9) (el de otra clienta) bloqueados.
insert into public.sessions (chef_id, client_id, "date", start_time, cook_minutes, status)
values ('7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a4', pg_temp.d(-12), '10:00', 180, 'cooked');
insert into public.availability_exceptions (chef_id, "date", note) values
  ('7e631000-0000-4000-8000-000000000001', pg_temp.d(5), 'Prueba de prioridad'),
  ('7e631000-0000-4000-8000-000000000001', pg_temp.d(9), 'Prueba de prioridad');
insert into res (k, r)
select 'prioridad', pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1',
                                     array[pg_temp.d(-12), pg_temp.d(5), pg_temp.d(9)], '10:00', 0, true);
select is(pg_temp.semanas('prioridad', 'status'), array['busy', 'blocked', 'busy'],
  'prioridad: una fecha pasada que choca es busy (no past), un sábado bloqueado es blocked (no closed) y un día bloqueado que choca es busy (no blocked)');
delete from public.availability_exceptions
where chef_id = '7e631000-0000-4000-8000-000000000001' and note = 'Prueba de prioridad';
select is(
  array[
    pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[(now() at time zone 'Europe/Rome')::date - 1], '10:00', 0, true) #>> '{weeks,0,status}',
    ((pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[(now() at time zone 'Europe/Rome')::date], '10:00', 0, true) #>> '{weeks,0,status}') = 'past')::text
  ],
  array['past', 'false'],
  'ayer en Roma es past; hoy no (es ok, o closed en un fin de semana)'
);

-- =====================================================================
-- 4. Creación desde un pedido
-- =====================================================================
select lives_ok(
  $$ insert into res (k, r)
     select 'r1', pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1',
                                   array[pg_temp.d(1), pg_temp.d(8), pg_temp.d(15), pg_temp.d(22)]) $$,
  'Evelyn confirma desde el pedido una reserva de 4 semanas: los martes a las 10:00, 560 € de servicio'
);
insert into ids (k, v)
select 'r1w' || x.n, (x.w ->> 'session_id')::uuid
from res, jsonb_array_elements(res.r -> 'weeks') with ordinality as x (w, n)
where res.k = 'r1';

select is(
  (select format('%s %s %s %s', r ->> 'dry_run', r ->> 'duplicate', r ->> 'request_id', r ->> 'client_id')
   from res where k = 'r1'),
  'false false 7e633000-0000-4000-8000-0000000000b1 7e632000-0000-4000-8000-0000000000a1',
  'la respuesta trae el pedido y la clienta'
);
select is(pg_temp.semanas('r1', 'date'), array[pg_temp.f(1), pg_temp.f(8), pg_temp.f(15), pg_temp.f(22)],
  'y las 4 semanas, en orden');
select is(pg_temp.semanas('r1', 'status'), array['ok', 'ok', 'ok', 'ok'], 'todas sin avisos');
select is(pg_temp.semanas('r1', 'service_cents'), array['14000', '14000', '14000', '14000'], 'a 140 € cada una');
select results_eq(
  $$ select s.id, s."date", s.start_time, s.status::text, s.pay_mode::text, s.hold_until, s.service_cents,
            s.groceries_est_cents, s.preauth_cents, s.portions, s.cook_minutes
     from public.sessions s
     where s.request_id = '7e633000-0000-4000-8000-0000000000b1'
     order by s."date" $$,
  $$ select i.v, pg_temp.d(w.o), time '10:00', 'confirmed'::text, 'manual'::text, null::timestamptz, 14000,
            6300, 0, 20, 180
     from (values (1, 1), (2, 8), (3, 15), (4, 22)) as w (n, o)
     join ids i on i.k = 'r1w' || w.n
     order by w.n $$,
  'se crearon 4 sesiones confirmed con pay_mode manual, sin retención, con el servicio repartido y la compra estimada de cada semana'
);
select results_eq(
  $$ select s.shop_minutes, s.gap_minutes from public.sessions s
     where s.request_id = '7e633000-0000-4000-8000-0000000000b1' $$,
  $$ select cs.shop_minutes, cs.gap_minutes from public.chef_settings cs
     cross join generate_series(1, 4)
     where cs.chef_id = '7e631000-0000-4000-8000-000000000001' $$,
  'la compra y el margen se copian de chef_settings'
);
select is(
  (select array_agg(s.week_start order by s."date") from public.sessions s
   where s.request_id = '7e633000-0000-4000-8000-0000000000b1'),
  array[pg_temp.d(0), pg_temp.d(7), pg_temp.d(14), pg_temp.d(21)],
  'week_start es el lunes de cada semana'
);
select is(
  (select format('%s %s %s', r.status, r.weeks, r.seen_at is not null) from public.requests r
   where r.id = '7e633000-0000-4000-8000-0000000000b1'),
  'accepted 4 t',
  'el pedido pasa a accepted, con las semanas que se crearon (la web pedía 2) y visto'
);
select is(
  (select c.status::text from public.clients c where c.id = '7e632000-0000-4000-8000-0000000000a1'),
  'trial',
  'y la ficha pasa de prospecto a cliente (trial)'
);
select is(
  (select f.available from public.get_free_days('7e631000-0000-4000-8000-000000000001', 150, pg_temp.d(1), 1) as f),
  false,
  'la web ya no ofrece el martes de la primera semana'
);

-- =====================================================================
-- 5. Reintento desde un pedido
-- =====================================================================
select is(
  (select format('%s %s', q.r ->> 'duplicate', (q.r -> 'weeks') = (select x.r -> 'weeks' from res x where x.k = 'r1'))
   from (select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1',
                                 array[pg_temp.d(1), pg_temp.d(8), pg_temp.d(15), pg_temp.d(22)]) as r) as q),
  'true t',
  'reintento (se perdió la respuesta y la app manda lo mismo): devuelve lo mismo, con duplicate'
);
select is(
  (select count(*)::int from public.sessions s where s.request_id = '7e633000-0000-4000-8000-0000000000b1'),
  4,
  'y no crea nada más'
);
select throws_ok(
  $$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[pg_temp.d(2), pg_temp.d(9)]) $$,
  '55000', 'request_not_new',
  'otra reserva sobre un pedido ya aceptado (otras fechas): request_not_new'
);
select throws_ok(
  $$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1',
                             array[pg_temp.d(1), pg_temp.d(8), pg_temp.d(15), pg_temp.d(22)], '11:00') $$,
  '55000', 'request_not_new',
  'las mismas fechas a otra hora tampoco son un reintento: request_not_new (no la reserva vieja con duplicate)'
);
select throws_ok(
  $$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b1', array[pg_temp.d(1)], '10:00', 0, true) $$,
  '55000', 'request_not_new',
  'tampoco un dryRun'
);

-- =====================================================================
-- 6. Choques
-- =====================================================================
select is(
  pg_temp.err($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3',
                                         array[pg_temp.d(2), pg_temp.d(9), pg_temp.d(16)], '10:00', 42000) $$),
  '23P01 slot_taken | ' || pg_temp.f(9),
  'si una semana choca (la segunda: otra clienta el mismo miércoles a las 10:00), slot_taken con la fecha'
);
select is(
  format('%s sesiones · pedido %s · ficha %s',
    (select count(*) from public.sessions s where s.request_id = '7e633000-0000-4000-8000-0000000000b3'),
    (select r.status from public.requests r where r.id = '7e633000-0000-4000-8000-0000000000b3'),
    (select c.status from public.clients c where c.id = '7e632000-0000-4000-8000-0000000000a2')),
  '0 sesiones · pedido new · ficha prospect',
  'y no se crea ninguna, ni la primera semana, que estaba libre'
);
select is(
  (select array_agg(x.w ->> 'status' order by x.n)
   from jsonb_array_elements(pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3',
          array[pg_temp.d(2), pg_temp.d(9), pg_temp.d(16)], '10:00', 42000, true) -> 'weeks') with ordinality as x (w, n)),
  array['ok', 'busy', 'ok'],
  'el dryRun lo avisaba: busy en esa semana'
);
select is(
  array[
    pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(9)], '13:45', 0, true, 60) #>> '{weeks,0,status}',
    pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(9)], '14:15', 0, true, 60) #>> '{weeks,0,status}'
  ],
  array['busy', 'outside'],
  'busy es la regla de no_overlap: la otra termina con el margen a las 13:30; comprar desde las 13:00 choca y desde las 13:30 no (solo queda fuera de horario)'
);
select is(
  pg_temp.err($$ do $x$ begin
       insert into public.sessions (chef_id, client_id, request_id, "date", start_time, cook_minutes, status)
       values ('7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a2',
               '7e633000-0000-4000-8000-0000000000b3', pg_temp.d(4), '13:00', 60, 'confirmed');
       perform pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(2)], '10:00', 0);
     end $x$ $$),
  '23505 week_taken | ' || pg_temp.f(2),
  'si el pedido ya tenía una sesión viva en esa semana: week_taken, con la fecha'
);

-- =====================================================================
-- 7. Validaciones (ninguna escribe nada)
-- =====================================================================
insert into res (k, r) values ('conteo_validaciones', to_jsonb(pg_temp.conteo()));

select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(1), pg_temp.d(3)]) $$,
  '22023', 'dates_same_week', 'dos fechas en la misma semana: dates_same_week');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3',
                                            array(select pg_temp.d(7 * i + 2) from generate_series(0, 8) as i)) $$,
  '22023', 'invalid_dates', 'más de 8 semanas: invalid_dates');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', '{}'::date[]) $$,
  '22023', 'invalid_dates', 'ninguna fecha');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', null) $$,
  '22023', 'invalid_dates', 'sin fechas');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(9), pg_temp.d(2)]) $$,
  '22023', 'invalid_dates', 'fechas desordenadas');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(2), null]) $$,
  '22023', 'invalid_dates', 'una fecha vacía');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(400)]) $$,
  '22023', 'invalid_dates', 'una fecha a más de un año');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(-400)]) $$,
  '22023', 'invalid_dates', 'ni una de hace más de un año');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b2', array[pg_temp.d(2), pg_temp.d(9)]) $$,
  '22023', 'weeks_only_for_week', 'un pedido extra de 2 semanas: weeks_only_for_week');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(2)], null) $$,
  '22023', 'invalid_start', 'sin hora de llegada (fuera del dryRun)');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(2)], '10:00', 0, false, 0) $$,
  '22023', 'invalid_cook_minutes', '0 min de cocina');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(2)], '10:00', 0, false, 721) $$,
  '22023', 'invalid_cook_minutes', 'más de 720 min de cocina');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(2)], '10:00', -1) $$,
  '22023', 'invalid_cents', 'servicio negativo');
select throws_ok(
  $$ select public.chef_create_booking(p_chef_id => '7e631000-0000-4000-8000-000000000001', p_dates => array[pg_temp.d(2)],
       p_start => '10:00', p_cook_minutes => 180, p_request_id => '7e633000-0000-4000-8000-0000000000b3') $$,
  '42883', null,
  'sin el precio del servicio no hay función: p_service_total_cents no tiene valor por defecto (ninguna ruta lo corrige después)'
);
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(2)], '10:00', null) $$,
  '22023', 'invalid_cents', 'ni con el precio en null (0 sí vale: sin cargo)');
select throws_ok(
  $$ select public.chef_create_booking(p_chef_id => '7e631000-0000-4000-8000-000000000001', p_dates => array[pg_temp.d(2)],
       p_start => '10:00', p_cook_minutes => 180, p_service_total_cents => 0, p_groceries_est_cents => null,
       p_request_id => '7e633000-0000-4000-8000-0000000000b3') $$,
  '22023', 'invalid_cents', 'sin compra estimada');
select throws_ok(
  $$ select public.chef_create_booking(p_chef_id => '7e631000-0000-4000-8000-000000000001', p_dates => array[pg_temp.d(2)],
       p_start => '10:00', p_cook_minutes => 180, p_service_total_cents => 0, p_portions => -1,
       p_request_id => '7e633000-0000-4000-8000-0000000000b3') $$,
  '22023', 'invalid_portions', 'porciones negativas');
select throws_ok(
  $$ select public.chef_create_booking(p_chef_id => '7e631000-0000-4000-8000-000000000001', p_dates => array[pg_temp.d(2)],
       p_start => '10:00', p_cook_minutes => 180, p_service_total_cents => 0) $$,
  '22023', 'invalid_client', 'sin pedido, ficha ni ficha nueva: invalid_client');
select throws_ok(
  $$ select public.chef_create_booking(p_chef_id => '7e631000-0000-4000-8000-000000000001', p_dates => array[pg_temp.d(2)],
       p_start => '10:00', p_cook_minutes => 180, p_service_total_cents => 0,
       p_request_id => '7e633000-0000-4000-8000-0000000000b3', p_client_id => '7e632000-0000-4000-8000-0000000000a2') $$,
  '22023', 'invalid_client', 'pedido y ficha a la vez');
select throws_ok(
  $$ select public.chef_create_booking(p_chef_id => '7e631000-0000-4000-8000-0000000000ff', p_dates => array[pg_temp.d(2)],
       p_start => '10:00', p_cook_minutes => 180, p_service_total_cents => 0,
       p_request_id => '7e633000-0000-4000-8000-0000000000b3') $$,
  'P0002', 'chef_not_found', 'una cocinera que no existe: chef_not_found');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000ff', array[pg_temp.d(2)]) $$,
  'P0002', 'request_not_found', 'un pedido que no existe: request_not_found');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000bf', array[pg_temp.d(2)]) $$,
  'P0002', 'request_not_found', 'ni uno de otra cocinera');
select throws_ok(
  $$ select public.chef_create_booking(p_chef_id => '7e631000-0000-4000-8000-000000000001', p_dates => array[pg_temp.d(2)],
       p_start => '10:00', p_cook_minutes => 180, p_service_total_cents => 0,
       p_request_id => '7e633000-0000-4000-8000-0000000000b3', p_type => 'extra') $$,
  '22023', 'invalid_request_type', 'desde un pedido, el tipo es el del pedido');
select throws_ok($$ select pg_temp.reservar('7e633000-0000-4000-8000-0000000000b5', array[pg_temp.d(2)]) $$,
  '22023', 'invalid_request_type', 'un pedido de cambio no se confirma como reserva');
select throws_ok($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                                          p_client => '7e632000-0000-4000-8000-0000000000a3', p_type => 'change') $$,
  '22023', 'invalid_request_type', 'a mano, una reserva es week o extra (no change)');
select throws_ok($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                                          p_client => '7e632000-0000-4000-8000-0000000000a3', p_type => null) $$,
  '22023', 'invalid_request_type', 'y el tipo es obligatorio');
select throws_ok($$ select pg_temp.a_mano(array[pg_temp.d(2), pg_temp.d(9)], '7e63e000-0000-4000-8000-0000000000ee',
                                          p_client => '7e632000-0000-4000-8000-0000000000a3', p_type => 'extra') $$,
  '22023', 'weeks_only_for_week', 'una sesión extra a mano de 2 semanas');
select throws_ok($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                                          p_client => '7e632000-0000-4000-8000-0000000000f1') $$,
  'P0002', 'client_not_found', 'una ficha de otra cocinera: client_not_found');
select throws_ok($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                                          p_client => '7e632000-0000-4000-8000-0000000000a3', p_household => null) $$,
  '22023', 'invalid_household', 'a mano, sin personas, días ni comidas');
select is(
  array[
    pg_temp.err($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                     p_client => '7e632000-0000-4000-8000-0000000000a3',
                     p_household => '{"adults": 0, "kids": 0, "days": 5, "meals": ["dinner"]}') $$),
    pg_temp.err($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                     p_client => '7e632000-0000-4000-8000-0000000000a3',
                     p_household => '{"adults": 31, "kids": 0, "days": 5, "meals": ["dinner"]}') $$),
    pg_temp.err($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                     p_client => '7e632000-0000-4000-8000-0000000000a3',
                     p_household => '{"adults": 1, "kids": 31, "days": 5, "meals": ["dinner"]}') $$),
    pg_temp.err($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                     p_client => '7e632000-0000-4000-8000-0000000000a3',
                     p_household => '{"adults": 2, "kids": 0, "days": 8, "meals": ["dinner"]}') $$),
    pg_temp.err($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                     p_client => '7e632000-0000-4000-8000-0000000000a3',
                     p_household => '{"adults": 2, "kids": 0, "days": 5, "meals": ["brunch"]}') $$),
    pg_temp.err($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                     p_client => '7e632000-0000-4000-8000-0000000000a3',
                     p_household => '{"adults": 2, "kids": 0, "days": 5, "meals": ["dinner", "dinner"]}') $$),
    pg_temp.err($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                     p_client => '7e632000-0000-4000-8000-0000000000a3',
                     p_household => '{"adults": "2", "kids": 0, "days": 5, "meals": ["dinner"]}') $$)
  ],
  array_fill('22023 invalid_household'::text, array[7]),
  'personas, días y comidas como en quote.ts: nadie, más de 30 adultos o de 30 niños, 8 días, una comida desconocida o repetida, o un número en texto'
);
select throws_ok($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                                          p_new => '{"phone": "+393339990000"}') $$,
  '22023', 'name_required', 'una ficha nueva sin nombre: name_required');
select throws_ok($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                                          p_new => '["Marta"]') $$,
  '22023', 'invalid_new_client', 'una ficha nueva que no es un objeto');
select throws_ok($$ select pg_temp.a_mano(array[pg_temp.d(2)], null, p_client => '7e632000-0000-4000-8000-0000000000a3') $$,
  '22023', 'request_key_required', 'a mano, la clave de idempotencia es obligatoria');
select throws_ok($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-0000000000ee',
                                          p_client => '7e632000-0000-4000-8000-0000000000a3', p_locale => 'fr') $$,
  '22023', 'invalid_locale', 'el idioma es it, es o en');
select throws_ok($$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-000000000003',
                                          p_client => '7e632000-0000-4000-8000-0000000000a3') $$,
  '22023', 'request_key_conflict', 'una clave que ya usó un pedido de la web: request_key_conflict');
select is(pg_temp.conteo(), (select r #>> '{}' from res where k = 'conteo_validaciones'),
  'ninguna validación escribió nada');

-- =====================================================================
-- 8. Alta a mano
-- =====================================================================
select lives_ok(
  $$ insert into res (k, r)
     select 'marta', pg_temp.a_mano(
       array[pg_temp.d(4), pg_temp.d(11), pg_temp.d(18)], '7e63e000-0000-4000-8000-000000000001',
       p_new => '{"name": " Marta Gentili ", "phone": " +393331112233 ", "email": "Marta@Example.TEST",
                  "zone": "Loreto", "address": "Via Roma 1, Bergamo"}',
       p_household => '{"adults": 2, "kids": 1, "days": 5, "meals": ["dinner", "lunch"]}',
       p_locale => 'es') $$,
  'reserva a mano de 3 semanas para una clienta nueva que llegó por WhatsApp'
);
insert into ids (k, v)
select 'marta_pedido', (r ->> 'request_id')::uuid from res where k = 'marta'
union all
select 'marta_ficha', (r ->> 'client_id')::uuid from res where k = 'marta';

select is(pg_temp.semanas('marta', 'service_cents'), array['16667', '16667', '16666'],
  'reparto exacto: 500 € en 3 semanas son 166,67 + 166,67 + 166,66');
select is(
  (select format('%s | %s | %s | %s | %s | %s %s | %s %s | %s', c.display_name, c.contact_phone, c.contact_email,
                 c.zone, c.address, c.adults, c.kids, c.status, c.pay_mode, c.profile_id is null)
   from public.clients c where c.id = (select v from ids where k = 'marta_ficha')),
  'Marta Gentili | +393331112233 | marta@example.test | Loreto | Via Roma 1, Bergamo | 2 1 | trial manual | t',
  'la ficha nueva: lo que cargó Evelyn, el hogar de la reserva semanal, en trial y con pago manual'
);
select is(
  (select format('%s %s %s %s %s | %s %s %s %s | %s %s | %s %s %s %s %s',
                 r.type, r.status, r.source, r.seen_at is not null, r.request_key,
                 r.adults, r.kids, r.days, r.meals, r.weeks, r.locale,
                 r.restrictions is null, r.no_allergies is null, r.estimate is null, r.contact is null,
                 r.preferred_date is null)
   from public.requests r where r.id = (select v from ids where k = 'marta_pedido')),
  'week accepted app t 7e63e000-0000-4000-8000-000000000001 | 2 1 5 {lunch,dinner} | 3 es | t t t t t',
  'el pedido: de la app, aceptado y visto, con la clave, personas, días, comidas en orden, 3 semanas e idioma; sin alergias (falta su consentimiento)'
);
select is(
  (select array_agg(format('%s %s %s', to_char(s."date", 'YYYY-MM-DD'), s.status, s.pay_mode) order by s."date")
   from public.sessions s where s.request_id = (select v from ids where k = 'marta_pedido')),
  array[pg_temp.f(4) || ' confirmed manual', pg_temp.f(11) || ' confirmed manual', pg_temp.f(18) || ' confirmed manual'],
  'y sus 3 sesiones'
);
select is(
  (select format('%s %s %s', q.r ->> 'duplicate', q.r ->> 'request_id' = (select v::text from ids where k = 'marta_pedido'),
                 (q.r -> 'weeks') = (select x.r -> 'weeks' from res x where x.k = 'marta'))
   from (select pg_temp.a_mano(array[pg_temp.d(7)], '7e63e000-0000-4000-8000-000000000001',
                               p_new => '{"name": "Marta Gentili"}') as r) as q),
  'true t t',
  'reintento con la misma clave (aunque mande otras fechas): la misma reserva, con duplicate'
);
select is(
  format('%s fichas · %s pedidos · %s sesiones',
    (select count(*) from public.clients c where c.display_name = 'Marta Gentili'),
    (select count(*) from public.requests r where r.request_key = '7e63e000-0000-4000-8000-000000000001'),
    (select count(*) from public.sessions s where s.request_id = (select v from ids where k = 'marta_pedido'))),
  '1 fichas · 1 pedidos · 3 sesiones',
  'y no duplica la ficha, el pedido ni las sesiones'
);

select lives_ok(
  $$ insert into res (k, r)
     select 'anna', pg_temp.a_mano(array[pg_temp.d(3)], '7e63e000-0000-4000-8000-000000000002',
                                   p_client => '7e632000-0000-4000-8000-0000000000a3', p_type => 'extra',
                                   p_start => '12:00', p_service => 30000,
                                   p_household => '{"adults": 6, "kids": 2, "days": 1, "meals": ["dinner"]}') $$,
  'una sesión extra a mano para una clienta que ya existe'
);
select is(
  (select format('%s | %s | %s | %s %s | %s %s', c.display_name, c.contact_phone, c.address, c.adults, c.kids,
                 c.status, c.pay_mode)
   from public.clients c where c.id = '7e632000-0000-4000-8000-0000000000a3'),
  'Anna Rota | +393330000003 | Via Gombito 1 | 2 0 | active preauth',
  'la ficha que ya existía no cambia (ni su hogar, aunque esta sesión sea para 8)'
);
select is(
  (select format('%s %s %s %s %s %s', r.type, r.weeks, r.adults, r.kids, r.client_id, r.locale)
   from public.requests r where r.id = (select (x.r ->> 'request_id')::uuid from res x where x.k = 'anna')),
  'extra 1 6 2 7e632000-0000-4000-8000-0000000000a3 it',
  'el pedido es de esa ficha, con las personas de esta sesión; sin idioma, it'
);

select lives_ok(
  $$ insert into res (k, r)
     select 'ugo', pg_temp.a_mano(array[pg_temp.d(24)], '7e63e000-0000-4000-8000-000000000005',
                                  p_new => '{"name": "Ugo Neri"}', p_type => 'extra', p_start => '12:00', p_service => 0,
                                  p_household => '{"adults": 6, "kids": 2, "days": 1, "meals": ["dinner"]}') $$,
  'una sesión extra a mano, sin cargo, para una clienta nueva'
);
select is(
  (select format('%s %s %s | %s', c.adults, c.kids, c.status,
                 (select string_agg(s.service_cents::text, ',') from public.sessions s where s.client_id = c.id))
   from public.clients c where c.id = (select (x.r ->> 'client_id')::uuid from res x where x.k = 'ugo')),
  '1 0 trial | 0',
  'la ficha nueva de una sesión extra no toma el hogar de esa sesión (1 adulto, 0 niños), y el servicio en 0 vale'
);

select lives_ok(
  $$ select pg_temp.a_mano(array[pg_temp.d(2)], '7e63e000-0000-4000-8000-000000000004',
                           p_client => '7e632000-0000-4000-8000-0000000000a5', p_service => 15000,
                           p_household => '{"adults": 4, "kids": 0, "days": 5, "meals": ["lunch"]}') $$,
  'una reserva a mano para un prospecto que había llegado por la web'
);
select is(
  (select format('%s | %s %s | %s', c.display_name, c.adults, c.kids, c.status)
   from public.clients c where c.id = '7e632000-0000-4000-8000-0000000000a5'),
  'Sofia Bassi | 3 0 | trial',
  'pasa a cliente (trial), como desde un pedido; sus datos no cambian'
);

-- =====================================================================
-- 9. Transiciones (sessions_guard_update)
-- =====================================================================
-- Crea una sesión de C2 en p_from y la pasa a p_to (con hold_until y cancelled_at como piden los
-- checks, así lo único que puede rechazarla es la guarda). Devuelve 'ok' o 'SQLSTATE mensaje' y
-- deshace todo.
create function pg_temp.transicion(p_from public.session_status, p_to public.session_status) returns text
language plpgsql
as $$
declare
  v_id    uuid;
  v_state text;
  v_msg   text;
begin
  insert into public.sessions (chef_id, client_id, "date", start_time, cook_minutes, status, hold_until, cancelled_at)
  values ('7e631000-0000-4000-8000-000000000002', '7e632000-0000-4000-8000-0000000000f1', pg_temp.d(30), '10:00', 60,
          p_from,
          case when p_from = 'held' then now() + interval '1 day' end,
          case when p_from = 'cancelled' then now() end)
  returning id into v_id;
  update public.sessions
     set status       = p_to,
         hold_until   = case when p_to = 'held' then now() + interval '1 day' end,
         cancelled_at = case when p_to = 'cancelled' then now() end
   where id = v_id;
  raise exception 'probe_ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  if v_msg = 'probe_ok' then
    return 'ok';
  end if;
  return v_state || ' ' || v_msg;
end
$$;

-- Crea una sesión de C2 en p_status y le aplica "update ... set <p_set>". Igual que la anterior.
create function pg_temp.cambio(p_status public.session_status, p_set text) returns text
language plpgsql
as $$
declare
  v_id    uuid;
  v_state text;
  v_msg   text;
begin
  insert into public.sessions (chef_id, client_id, "date", start_time, cook_minutes, status, hold_until, cancelled_at)
  values ('7e631000-0000-4000-8000-000000000002', '7e632000-0000-4000-8000-0000000000f1', pg_temp.d(31), '10:00', 60,
          p_status,
          case when p_status = 'held' then now() + interval '1 day' end,
          case when p_status = 'cancelled' then now() end)
  returning id into v_id;
  execute format('update public.sessions set %s where id = %L', p_set, v_id);
  raise exception 'probe_ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  if v_msg = 'probe_ok' then
    return 'ok';
  end if;
  return v_state || ' ' || v_msg;
end
$$;

select is(
  (select array_agg(f::text || ' → ' || t::text order by f, t)
   from unnest(enum_range(null::public.session_status)) as f
   cross join unnest(enum_range(null::public.session_status)) as t
   where f <> t and pg_temp.transicion(f, t) = 'ok'),
  array['held → confirmed', 'held → cancelled',
        'confirmed → shopping_done', 'confirmed → cooked', 'confirmed → cancelled',
        'shopping_done → cooked', 'shopping_done → cancelled',
        'cooked → confirmed', 'cooked → shopping_done', 'cooked → paid',
        'paid → cooked'],
  'las transiciones válidas son exactamente estas (cooked → confirmed o shopping_done deshace «Cociné»; paid → cooked, al anular un cobro)'
);
select is(
  (select array_agg(distinct pg_temp.transicion(f, t))
   from unnest(enum_range(null::public.session_status)) as f
   cross join unnest(enum_range(null::public.session_status)) as t
   where f <> t and pg_temp.transicion(f, t) <> 'ok'),
  array['55000 invalid_transition'],
  'las otras 19 fallan con invalid_transition, también como postgres (la guarda es para todos los roles)'
);

set local role service_role;
select throws_ok(
  $$ update public.sessions set status = 'paid' where id = '7e634000-0000-4000-8000-0000000000cf' $$,
  '55000', 'invalid_transition',
  'service_role tampoco salta pasos (confirmed → paid)'
);
select lives_ok(
  $$ update public.sessions set status = 'cooked' where id = '7e634000-0000-4000-8000-0000000000cf' $$,
  'y sí hace una válida (confirmed → cooked)'
);
update public.sessions set status = 'confirmed' where id = '7e634000-0000-4000-8000-0000000000cf';
reset role;

select is(
  (select array_agg(q.x order by q.x) from (
     select distinct s::text || ': ' || pg_temp.cambio(s, c) as x
     from unnest(enum_range(null::public.session_status)) as s
     cross join unnest(array['"date" = "date" + 1', 'start_time = start_time + interval ''30 minutes''',
                             'cook_minutes = cook_minutes + 30', 'shop_minutes = shop_minutes + 5',
                             'gap_minutes = gap_minutes + 5']) as c
   ) as q),
  array['cancelled: 55000 session_not_movable', 'confirmed: ok', 'cooked: 55000 session_not_movable',
        'held: ok', 'paid: 55000 session_not_movable', 'shopping_done: 55000 session_not_movable'],
  'fecha, hora, cocina, compra y margen cambian solo en held o confirmed; en otro estado, session_not_movable'
);
select is(
  array[pg_temp.cambio('paid', 'groceries_actual_cents = 4100, quote_id = null'),
        pg_temp.cambio('cooked', 'portions = 12, cooked_at = now()'),
        pg_temp.cambio('cancelled', 'cancel_reason = ''declined''')],
  array['ok', 'ok', 'ok'],
  'el resto de las columnas cambia en cualquier estado (el seed completa quote_id de una sesión paga)'
);
select lives_ok(
  $$ insert into public.sessions (chef_id, client_id, "date", start_time, cook_minutes, status)
     values ('7e631000-0000-4000-8000-000000000002', '7e632000-0000-4000-8000-0000000000f1', pg_temp.d(32), '10:00', 60, 'paid') $$,
  'la guarda no corre en INSERT: el seed y los tests cargan sesiones cooked o paid'
);

select throws_ok(
  $$ insert into public.sessions (chef_id, client_id, request_id, "date", start_time, cook_minutes, status)
     values ('7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a1',
             '7e633000-0000-4000-8000-0000000000b1', pg_temp.d(7), '10:00', 180, 'confirmed') $$,
  '23505', 'duplicate key value violates unique constraint "sessions_una_por_semana"',
  'una segunda sesión viva de la reserva en la misma semana: la base la rechaza'
);
select lives_ok(
  $$ insert into public.sessions (chef_id, client_id, request_id, "date", start_time, cook_minutes, status,
                                  cancelled_at, cancel_reason)
     values ('7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a1',
             '7e633000-0000-4000-8000-0000000000b1', pg_temp.d(7), '10:00', 180, 'cancelled', now(), 'declined') $$,
  'una cancelada en esa semana, sí (no cuenta)'
);
insert into public.sessions (id, chef_id, client_id, "date", start_time, cook_minutes, status)
values ('7e634000-0000-4000-8000-0000000000c6', '7e631000-0000-4000-8000-000000000001',
        '7e632000-0000-4000-8000-0000000000a4', pg_temp.d(6), '10:00', 60, 'confirmed');
select is(
  (select s.week_start from public.sessions s where s.id = '7e634000-0000-4000-8000-0000000000c6'),
  pg_temp.d(0),
  'la semana de un domingo empieza el lunes anterior (semana ISO)'
);

-- =====================================================================
-- 10. Mover
-- =====================================================================
select is(
  (select format('%s %s %s %s', q.r ->> 'dry_run', q.r ->> 'status', q.r ->> 'week_taken', q.r ->> 'date')
   from (select public.chef_move_session('7e631000-0000-4000-8000-000000000001', (select v from ids where k = 'r1w2'),
                                         pg_temp.d(10), '11:00', p_dry_run => true) as r) as q),
  'true ok false ' || pg_temp.f(10),
  'dryRun: mover la semana 2 al jueves de esa misma semana entra'
);
select is(
  (select s."date" from public.sessions s where s.id = (select v from ids where k = 'r1w2')),
  pg_temp.d(8),
  'y no la mueve'
);
select is(
  (select format('%s %s', q.r ->> 'status', q.r ->> 'week_taken')
   from (select public.chef_move_session('7e631000-0000-4000-8000-000000000001', (select v from ids where k = 'r1w2'),
                                         pg_temp.d(16), p_dry_run => true) as r) as q),
  'ok true',
  'dryRun a la semana 3, que ya tiene su sesión: avisa week_taken (la app ofrece pasarla al final)'
);
select is(
  public.chef_move_session('7e631000-0000-4000-8000-000000000001', (select v from ids where k = 'r1w2'),
                           pg_temp.d(9), '10:00', p_dry_run => true) ->> 'status',
  'busy',
  'dryRun al miércoles de otra clienta a la misma hora: busy'
);
select is(
  pg_temp.err(format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L) $$,
                     (select v from ids where k = 'r1w2'), pg_temp.d(16))),
  '23505 week_taken | ' || pg_temp.f(16),
  'mover de verdad a la semana 3: week_taken, con la fecha'
);
select is(
  pg_temp.err(format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L, '10:00') $$,
                     (select v from ids where k = 'r1w2'), pg_temp.d(9))),
  '23P01 slot_taken | ' || pg_temp.f(9),
  'a un horario ocupado: slot_taken, con la fecha'
);
select lives_ok(
  format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L) $$,
         (select v from ids where k = 'r1w4'), pg_temp.d(29)),
  'pasar la última semana una semana más tarde (al final de la reserva)'
);
select is(
  (select format('%s %s %s %s %s %s', s."date" = pg_temp.d(29), s.week_start = pg_temp.d(28), s.start_time,
                 s.cook_minutes, s.shop_minutes, s.gap_minutes)
   from public.sessions s where s.id = (select v from ids where k = 'r1w4')),
  't t 10:00:00 180 45 30',
  'queda en la fecha nueva, con su semana, y la hora, la cocina, la compra y el margen que tenía (sin hora ni minutos, los guardados)'
);
select lives_ok(
  format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L, '11:00') $$,
         (select v from ids where k = 'r1w2'), pg_temp.d(10)),
  'mover la semana 2 al jueves a las 11:00'
);
select is(
  (select format('%s %s', s."date" = pg_temp.d(10), s.start_time) from public.sessions s
   where s.id = (select v from ids where k = 'r1w2')),
  't 11:00:00',
  'con la hora nueva'
);

update public.chef_settings set shop_minutes = 60 where chef_id = '7e631000-0000-4000-8000-000000000001';
select is(
  array[
    public.chef_move_session('7e631000-0000-4000-8000-000000000001', (select v from ids where k = 'r1w2'),
                             pg_temp.d(7), '09:45', p_dry_run => true) ->> 'status',
    pg_temp.reservar('7e633000-0000-4000-8000-0000000000b3', array[pg_temp.d(7)], '09:45', 0, true) #>> '{weeks,0,status}'
  ],
  array['ok', 'outside'],
  'con 60 min de compra en chef_settings: mover usa los 45 que la sesión ya tiene (compra desde las 9:00); una reserva nueva, los 60 (desde las 8:45, fuera de horario)'
);
update public.chef_settings set shop_minutes = 45 where chef_id = '7e631000-0000-4000-8000-000000000001';

update public.sessions set status = 'cooked' where id = (select v from ids where k = 'r1w1');
select is(
  array[
    pg_temp.err(format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L, p_dry_run => true) $$,
                       (select v from ids where k = 'r1w1'), pg_temp.d(2))),
    pg_temp.err(format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L) $$,
                       (select v from ids where k = 'r1w1'), pg_temp.d(2)))
  ],
  array_fill('55000 session_not_movable | cooked'::text, array[2]),
  'una sesión ya cocinada no se mueve, tampoco en un dryRun: session_not_movable con su estado (lo controla la función, antes que la guarda)'
);
update public.sessions set status = 'confirmed' where id = (select v from ids where k = 'r1w1');

-- Una sesión held (un presupuesto enviado, M4) también se mueve; con p_cook_minutes cambia la cocina.
insert into public.sessions (id, chef_id, client_id, "date", start_time, cook_minutes, status, hold_until)
values ('7e634000-0000-4000-8000-0000000000c8', '7e631000-0000-4000-8000-000000000001',
        '7e632000-0000-4000-8000-0000000000a4', pg_temp.d(30), '12:00', 120, 'held', now() + interval '48 hours');
select lives_ok(
  format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', '7e634000-0000-4000-8000-0000000000c8',
                                            %L, p_cook_minutes => 150) $$, pg_temp.d(31)),
  'mover una sesión held al día siguiente, con 150 min de cocina'
);
select is(
  (select format('%s %s %s %s', s."date" = pg_temp.d(31), s.start_time, s.cook_minutes, s.status)
   from public.sessions s where s.id = '7e634000-0000-4000-8000-0000000000c8'),
  't 12:00:00 150 held',
  'queda en la fecha nueva, con la hora que tenía, la cocina nueva y todavía held'
);
select is(
  array[
    pg_temp.err(format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L, p_cook_minutes => 0) $$,
                       (select v from ids where k = 'r1w3'), pg_temp.d(16))),
    pg_temp.err(format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L, p_cook_minutes => 721) $$,
                       (select v from ids where k = 'r1w3'), pg_temp.d(16))),
    pg_temp.err(format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L) $$,
                       (select v from ids where k = 'r1w3'), pg_temp.d(400))),
    pg_temp.err(format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L) $$,
                       (select v from ids where k = 'r1w3'), pg_temp.d(-400)))
  ],
  array['22023 invalid_cook_minutes', '22023 invalid_cook_minutes', '22023 invalid_date', '22023 invalid_date'],
  'al mover, la cocina va de 1 a 720 min y la fecha, a menos de un año de hoy'
);
select throws_ok(
  $$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', '7e634000-0000-4000-8000-0000000000cf',
                                     pg_temp.d(2)) $$,
  'P0002', 'session_not_found',
  'ni una de otra cocinera: session_not_found'
);
select throws_ok(
  format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, null) $$,
         (select v from ids where k = 'r1w1')),
  '22023', 'invalid_date',
  'sin fecha: invalid_date'
);

-- =====================================================================
-- 11. Cancelar
-- =====================================================================
select is(
  (select f.available from public.get_free_days('7e631000-0000-4000-8000-000000000001', 150, pg_temp.d(1), 1) as f),
  false,
  'antes de cancelar, la web no ofrece el martes de la semana 1'
);
select lives_ok(
  format($$ insert into res (k, r)
            select 'cancelar_w1', public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001', array[%L]::uuid[]) $$,
         (select v from ids where k = 'r1w1')),
  'Evelyn cancela la semana 1'
);
select is(
  (select format('%s %s %s %s', r -> 'cancelled' = jsonb_build_array((select v from ids where k = 'r1w1')),
                 r -> 'already_cancelled', r -> 'with_payments', r ->> 'had_payments')
   from res where k = 'cancelar_w1'),
  't [] [] false',
  'devuelve la cancelada, ninguna que ya lo estuviera y ningún cobro'
);
select is(
  (select format('%s %s %s %s', s.status, s.cancelled_at is not null, s.cancel_reason, s.hold_until is null)
   from public.sessions s where s.id = (select v from ids where k = 'r1w1')),
  'cancelled t chef_cancelled t',
  'la sesión queda cancelled, con fecha y motivo'
);
select is(
  (select f.available from public.get_free_days('7e631000-0000-4000-8000-000000000001', 150, pg_temp.d(1), 1) as f),
  true,
  'y el día vuelve a aparecer en la web (get_free_days)'
);
select is(
  (select format('%s %s', q.r -> 'cancelled', q.r -> 'already_cancelled' = jsonb_build_array((select v from ids where k = 'r1w1')))
   from (select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001',
                                            array[(select v from ids where k = 'r1w1')]) as r) as q),
  '[] t',
  'cancelarla otra vez no falla: ya estaba cancelada'
);

update public.sessions set status = 'cooked' where id = (select v from ids where k = 'r1w3');
select throws_ok(
  format($$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001', array[%L, %L]::uuid[]) $$,
         (select v from ids where k = 'r1w2'), (select v from ids where k = 'r1w3')),
  '55000', 'invalid_transition',
  'con una semana ya cocinada en la lista: invalid_transition'
);
select is(
  (select s.status::text from public.sessions s where s.id = (select v from ids where k = 'r1w2')),
  'confirmed',
  'y no cancela ninguna (todo o nada)'
);
update public.sessions set status = 'confirmed' where id = (select v from ids where k = 'r1w3');

-- Una semana ya cobrada: una cancelada no se mueve ni se reactiva, así que sin permiso no se
-- cancela (la app ofrece antes pasarla al final de la reserva) y con permiso, para registrar la
-- devolución (decisión 5 del plan).
insert into public.payments (chef_id, session_id, kind, provider, amount_cents, service_part_cents, status)
select '7e631000-0000-4000-8000-000000000001', v, 'transfer', 'transfer', 14000, 14000, 'succeeded'
from ids where k = 'r1w2';
select is(
  pg_temp.err(format($$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001', array[%L, %L]::uuid[]) $$,
                     (select v from ids where k = 'r1w2'), (select v from ids where k = 'r1w3'))),
  '55000 has_payments | ' || (select v::text from ids where k = 'r1w2'),
  'una semana ya cobrada no se cancela sin permiso: has_payments con su id'
);
select is(
  (select array_agg(s.status::text order by s."date") from public.sessions s
   where s.id in (select v from ids where k in ('r1w2', 'r1w3'))),
  array['confirmed', 'confirmed'],
  'y no cancela ninguna, tampoco la que no tenía cobros (todo o nada)'
);
select is(
  public.chef_move_session('7e631000-0000-4000-8000-000000000001', (select v from ids where k = 'r1w2'),
                           pg_temp.d(36), p_dry_run => true) ->> 'status',
  'ok',
  'pasarla al final de la reserva sí se puede (dryRun)'
);
select is(
  (select format('%s %s %s', q.r -> 'cancelled' = jsonb_build_array((select v from ids where k = 'r1w2')),
                 q.r -> 'with_payments' = jsonb_build_array((select v from ids where k = 'r1w2')), q.r ->> 'had_payments')
   from (select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001',
                                            array[(select v from ids where k = 'r1w2')], 'client_cancelled',
                                            p_allow_with_payments => true) as r) as q),
  't t true',
  'con permiso (Evelyn va a registrar la devolución) se cancela, y la respuesta la marca con cobros'
);
select is(
  (select format('%s %s', q.r -> 'already_cancelled' = jsonb_build_array((select v from ids where k = 'r1w2')),
                 q.r -> 'with_payments' = jsonb_build_array((select v from ids where k = 'r1w2')))
   from (select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001',
                                            array[(select v from ids where k = 'r1w2')]) as r) as q),
  't t',
  'una vez cancelada, repetir sin permiso no falla: ya estaba cancelada y sigue esperando su devolución'
);

insert into public.payments (chef_id, session_id, kind, provider, amount_cents, service_part_cents, status)
select '7e631000-0000-4000-8000-000000000001', i.v, p.kind, p.provider, 14000, 14000, p.status
from ids i
cross join (values ('cash'::public.payment_kind, 'cash'::public.payment_provider, 'pending'::public.payment_status),
                   ('refund', 'transfer', 'succeeded')) as p (kind, provider, status)
where i.k = 'r1w3';
select is(
  (select format('%s %s %s', q.r -> 'cancelled' = jsonb_build_array((select v from ids where k = 'r1w3')),
                 q.r -> 'with_payments', q.r ->> 'had_payments')
   from (select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001',
                                            array[(select v from ids where k = 'r1w3')]) as r) as q),
  't [] false',
  'un cobro pendiente o una devolución no son plata cobrada: se cancela sin permiso y sin cobros'
);

update public.sessions set status = 'shopping_done'
where request_id = (select v from ids where k = 'marta_pedido') and "date" = pg_temp.d(18);
select lives_ok(
  format($$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001', array[%L]::uuid[], 'chef_unavailable') $$,
         (select s.id from public.sessions s
          where s.request_id = (select v from ids where k = 'marta_pedido') and s."date" = pg_temp.d(18))),
  'cancelar una semana que ya tenía la compra hecha (shopping_done)'
);
select is(
  (select format('%s %s', s.status, s.cancel_reason) from public.sessions s
   where s.request_id = (select v from ids where k = 'marta_pedido') and s."date" = pg_temp.d(18)),
  'cancelled chef_unavailable',
  'queda cancelled, con el motivo'
);
select is(
  (select array_agg(x.w ->> 'date' order by x.n)
   from jsonb_array_elements(pg_temp.a_mano(array[pg_temp.d(4)], '7e63e000-0000-4000-8000-000000000001',
                                            p_new => '{"name": "Marta Gentili"}') -> 'weeks') with ordinality as x (w, n)),
  array[pg_temp.f(4), pg_temp.f(11)],
  'un reintento de la reserva de Marta devuelve solo sus semanas vivas'
);

insert into public.sessions (id, chef_id, client_id, "date", start_time, cook_minutes, status, hold_until)
values ('7e634000-0000-4000-8000-0000000000c7', '7e631000-0000-4000-8000-000000000001',
        '7e632000-0000-4000-8000-0000000000a4', pg_temp.d(23), '10:00', 180, 'held', now() + interval '48 hours');
select lives_ok(
  $$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001',
                                        array['7e634000-0000-4000-8000-0000000000c7'::uuid]) $$,
  'cancelar una sesión held'
);
select is(
  (select format('%s %s', s.status, s.hold_until is null) from public.sessions s
   where s.id = '7e634000-0000-4000-8000-0000000000c7'),
  'cancelled t',
  'queda cancelled y sin hold_until'
);
select lives_ok(
  format($$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', %L, %L, '10:00') $$,
         (select v from ids where k = 'r1w4'), pg_temp.d(1)),
  'cancelada la semana 1, otra semana de la reserva puede ocupar ese lugar: la cancelada no cuenta'
);
select throws_ok(
  $$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001',
                                        array['7e634000-0000-4000-8000-0000000000cf'::uuid]) $$,
  'P0002', 'session_not_found',
  'una sesión de otra cocinera: session_not_found'
);
select is(
  array[
    pg_temp.err(format($$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001', array[%L]::uuid[], 'lo pidió ella') $$,
                       (select v from ids where k = 'r1w4'))),
    pg_temp.err(format($$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001', array[%L]::uuid[], 'clienta_maleducada_no_paga') $$,
                       (select v from ids where k = 'r1w4'))),
    pg_temp.err(format($$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001', array[%L]::uuid[], 'hold_expired') $$,
                       (select v from ids where k = 'r1w4')))
  ],
  array_fill('22023 invalid_reason'::text, array[3]),
  'el motivo es uno de los códigos de Evelyn (chef_cancelled, client_cancelled, chef_unavailable): ni texto libre, ni otra frase en snake_case, ni uno del sistema'
);
select is(
  array[
    pg_temp.err($$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001', '{}'::uuid[]) $$),
    pg_temp.err($$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001',
                                                      array(select gen_random_uuid() from generate_series(1, 101))) $$),
    pg_temp.err(format($$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001', array[%L, null]::uuid[]) $$,
                       (select v from ids where k = 'r1w4')))
  ],
  array_fill('22023 invalid_sessions'::text, array[3]),
  'de 1 a 100 sesiones y ninguna vacía: invalid_sessions'
);
select is(
  (select s.status::text from public.sessions s where s.id = (select v from ids where k = 'r1w4')),
  'confirmed',
  'ninguno de esos intentos tocó la sesión'
);

-- =====================================================================
-- 12. Permisos
-- =====================================================================
select is(
  (select array_agg(format('%s → %s', r, p.proname) order by 1)
   from pg_proc p
   cross join unnest(array['anon', 'authenticated']) as r
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('chef_create_booking', 'chef_move_session', 'chef_cancel_sessions')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  null::text[],
  'anon y authenticated no ejecutan las funciones chef_*'
);
select is(
  (select array_agg(p.proname::text order by p.proname)
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('chef_create_booking', 'chef_move_session', 'chef_cancel_sessions')
     and has_function_privilege('service_role', p.oid, 'EXECUTE')
     and p.prosecdef
     and p.proconfig = array['search_path=""']),
  array['chef_cancel_sessions', 'chef_create_booking', 'chef_move_session'],
  'service_role sí (Edge Function chef); las tres son security definer con search_path vacío'
);
select is(
  (select array_agg(format('%s → %s', r, p.proname) order by 1)
   from pg_proc p
   cross join unnest(array['anon', 'authenticated', 'service_role']) as r
   where p.pronamespace = 'private'::regnamespace
     and p.proname in ('split_cents', 'booking_day_checks', 'booking_result')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  null::text[],
  'los helpers de private no los ejecuta ningún rol de la API'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e630000-0000-4000-8000-00000000c001","role":"authenticated"}';
select throws_ok(
  $$ select public.chef_create_booking(p_chef_id => '7e631000-0000-4000-8000-000000000001', p_dates => array[current_date + 30],
       p_start => '10:00', p_cook_minutes => 180, p_service_total_cents => 0,
       p_request_id => '7e633000-0000-4000-8000-0000000000b3', p_dry_run => true) $$,
  '42501', 'permission denied for function chef_create_booking',
  'la cocinera desde la app (authenticated) no ejecuta chef_create_booking: va por la Edge Function'
);
select throws_ok(
  $$ select public.chef_move_session('7e631000-0000-4000-8000-000000000001', '7e634000-0000-4000-8000-0000000000c1',
                                     current_date + 30) $$,
  '42501', 'permission denied for function chef_move_session',
  'ni chef_move_session'
);
select throws_ok(
  $$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001',
                                        array['7e634000-0000-4000-8000-0000000000c1'::uuid]) $$,
  '42501', 'permission denied for function chef_cancel_sessions',
  'ni chef_cancel_sessions'
);
select throws_ok(
  $$ insert into public.sessions (chef_id, client_id, "date", start_time, cook_minutes, status)
     values ('7e631000-0000-4000-8000-000000000001', '7e632000-0000-4000-8000-0000000000a4', current_date + 30,
             '10:00', 180, 'confirmed') $$,
  '42501', null,
  'no inserta sesiones'
);
select throws_ok(
  $$ update public.sessions set "date" = "date" + 1 where id = '7e634000-0000-4000-8000-0000000000c1' $$,
  '42501', null,
  'ni las mueve'
);
select throws_ok(
  $$ delete from public.requests where id = '7e633000-0000-4000-8000-0000000000b2' $$,
  '42501', 'permission denied for table requests',
  'ni borra pedidos'
);
select throws_ok(
  $$ delete from public.clients where id = '7e632000-0000-4000-8000-0000000000a1' $$,
  '42501', 'permission denied for table clients',
  'ni borra fichas: la de P se llevaba en cascada su pedido aceptado y las sesiones de su reserva'
);
select ok(
  (select count(*) from public.sessions s
   where s.chef_id = '7e631000-0000-4000-8000-000000000001' and s.status <> 'cancelled' and s.week_start is not null) > 0,
  'y sigue leyendo sus sesiones (RLS), con las columnas nuevas'
);

set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select throws_ok(
  $$ select public.chef_cancel_sessions('7e631000-0000-4000-8000-000000000001',
                                        array['7e634000-0000-4000-8000-0000000000c1'::uuid]) $$,
  '42501', 'permission denied for function chef_cancel_sessions',
  'anon, tampoco'
);
reset role;

set local role service_role;
select lives_ok(
  $$ select public.chef_create_booking(p_chef_id => '7e631000-0000-4000-8000-000000000001', p_dates => array[current_date + 30],
       p_start => '10:00', p_cook_minutes => 180, p_service_total_cents => 0,
       p_request_id => '7e633000-0000-4000-8000-0000000000b3', p_dry_run => true) $$,
  'service_role sí (un dryRun)'
);
reset role;

select is(
  (select count(*)::int from public.requests r where r.id = '7e633000-0000-4000-8000-0000000000b2'),
  1,
  'el pedido que la app intentó borrar sigue ahí'
);
select is(
  (select format('%s · %s · %s sesiones vivas', c.status, r.status,
                 (select count(*) from public.sessions s where s.request_id = r.id and s.status <> 'cancelled'))
   from public.clients c join public.requests r on r.client_id = c.id
   where c.id = '7e632000-0000-4000-8000-0000000000a1'),
  'trial · accepted · 1 sesiones vivas',
  'y la ficha de P sigue ahí, con su pedido aceptado y la semana de su reserva que queda'
);

select finish();
rollback;
