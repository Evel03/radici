-- =====================================================================
-- Presupuesto que la clienta acepta (migración 20261121120000_quotes.sql):
--   * chef_create_quote / chef_update_quote / chef_withdraw_quote: preparar (sesiones held), cambiar
--     el precio y retirar.
--   * El envío de la semana 1 lleva el presupuesto: al salir, el pedido pasa a quoted, el plazo
--     empieza y cada reenvío es otra versión.
--   * La clienta, con su link: acepta (sesiones confirmed, pedido accepted, prospecto → trial, menú
--     confirmado), rechaza (sesiones canceladas, pedido declined) o pide cambios.
--   * private.expire_quotes: vence los que no contestó (y los borradores que nunca salieron).
--   * La versión es la que ve la clienta: un borrador que nunca salió no gasta número.
--   * Confirmar sin presupuesto (chef_create_booking) retira el presupuesto abierto del pedido, en
--     borrador o enviado, y su dryRun no cuenta sus semanas held como ocupadas.
--   * El link no muestra un presupuesto cerrado sin aceptar si la reserva siguió sin él.
--   * Una semana que llevaba el presupuesto y dejó de ser la primera: su menú no se confirma mientras
--     el presupuesto está abierto, y aceptado, Evelyn recibe el aviso de esa semana.
--
-- C1 tiene a la prospecta A (pedido semanal R1 de la web), a B (R2 extra, R5 a R16 semanales; R16
-- quoted sin presupuesto) y a C (R3 de cambio, R4 ya aceptado). C2 es otra cocinera con su pedido RX.
-- Las fechas salen del lunes que viene en Roma: pg_temp.d(0) es ese lunes.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(185);

-- ---------------------------------------------------------------------
-- Fixture (como postgres)
-- ---------------------------------------------------------------------
create function pg_temp.d(p_offset int) returns date
language sql
stable
as $$ select date_trunc('week', (now() at time zone 'Europe/Rome')::date::timestamp)::date + 7 + p_offset $$;

insert into auth.users (id, email) values
  ('7e6c0000-0000-4000-8000-00000000c001', 'chef1@presupuestos.test'),
  ('7e6c0000-0000-4000-8000-00000000c002', 'chef2@presupuestos.test');
update public.profiles set role = 'chef'
where id in ('7e6c0000-0000-4000-8000-00000000c001', '7e6c0000-0000-4000-8000-00000000c002');
insert into public.chefs (id, profile_id, display_name) values
  ('7e6c1000-0000-4000-8000-000000000001', '7e6c0000-0000-4000-8000-00000000c001', 'Evelyn'),
  ('7e6c1000-0000-4000-8000-000000000002', '7e6c0000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e6c1000-0000-4000-8000-000000000001'),
  ('7e6c1000-0000-4000-8000-000000000002');

insert into public.clients (id, chef_id, display_name, status) values
  ('7e6c2000-0000-4000-8000-00000000000a', '7e6c1000-0000-4000-8000-000000000001', 'Anna Rota', 'prospect'),
  ('7e6c2000-0000-4000-8000-00000000000b', '7e6c1000-0000-4000-8000-000000000001', 'Bruno Sala', 'active'),
  ('7e6c2000-0000-4000-8000-00000000000c', '7e6c1000-0000-4000-8000-000000000001', 'Carla Neri', 'active'),
  ('7e6c2000-0000-4000-8000-00000000000f', '7e6c1000-0000-4000-8000-000000000002', 'Xenia Ferri', 'active');

insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals, weeks, source, locale, text) values
  ('7e6c3000-0000-4000-8000-000000000001', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000a', 'week',   'new',      2, 1, 5, '{dinner}', 2, 'web', 'it', null),
  ('7e6c3000-0000-4000-8000-000000000002', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'extra',  'new',      8, 0, 1, '{dinner}', 1, 'web', 'es', null),
  ('7e6c3000-0000-4000-8000-000000000004', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000c', 'week',   'accepted', 2, 0, 5, '{dinner}', 1, 'app', 'it', null),
  ('7e6c3000-0000-4000-8000-000000000005', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week',   'new',      2, 0, 5, '{dinner}', 1, 'web', 'it', null),
  ('7e6c3000-0000-4000-8000-000000000006', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week',   'new',      2, 0, 5, '{dinner}', 1, 'web', 'it', null),
  ('7e6c3000-0000-4000-8000-000000000007', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week',   'new',      2, 0, 5, '{dinner}', 1, 'web', 'it', null),
  ('7e6c3000-0000-4000-8000-00000000000f', '7e6c1000-0000-4000-8000-000000000002', '7e6c2000-0000-4000-8000-00000000000f', 'week',   'new',      1, 0, 3, '{dinner}', 1, 'app', 'it', null);
insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals, weeks, source, locale) values
  ('7e6c3000-0000-4000-8000-000000000008', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 2, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000017', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 1, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000018', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 1, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000019', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 1, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000009', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 2, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000010', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 1, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000011', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 1, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000012', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 1, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000013', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 2, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000014', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 2, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000015', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'new', 2, 0, 5, '{dinner}', 3, 'web', 'it'),
  ('7e6c3000-0000-4000-8000-000000000016', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000b', 'week', 'quoted', 2, 0, 5, '{dinner}', 1, 'web', 'it');
insert into public.requests (id, chef_id, client_id, type, status, text, source) values
  ('7e6c3000-0000-4000-8000-000000000003', '7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000c', 'change', 'new', 'Otra cosa', 'app');

-- Una sesión confirmada de C (R4) el miércoles de la tercera semana: choca con un presupuesto ahí.
insert into public.sessions (chef_id, client_id, request_id, "date", start_time, cook_minutes, status) values
  ('7e6c1000-0000-4000-8000-000000000001', '7e6c2000-0000-4000-8000-00000000000c', '7e6c3000-0000-4000-8000-000000000004',
   pg_temp.d(16), '10:00', 180, 'confirmed');

insert into public.recipes (id, chef_id, name_it) values
  ('7e6c6000-0000-4000-8000-000000000001', '7e6c1000-0000-4000-8000-000000000001', 'Lasagne');

create function pg_temp.error_of(p_sql text) returns text
language plpgsql
as $$
declare
  v_detail text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return sqlstate || ': ' || sqlerrm || coalesce(' (' || nullif(v_detail, '') || ')', '');
end
$$;

create function pg_temp.h(p_token text) returns text
language sql
immutable
as $$ select encode(sha256(convert_to(p_token, 'UTF8')), 'hex') $$;

-- Un presupuesto de C1 para un pedido: fechas (offsets), 10:00, 180 min, 10 porciones y el total.
create function pg_temp.quote(p_request text, p_offsets int[], p_total int) returns uuid
language sql
as $$
  select (public.chef_create_quote('7e6c1000-0000-4000-8000-000000000001', p_request::uuid,
            array(select pg_temp.d(o) from unnest(p_offsets) as o), '10:00', 180, p_total, 10) ->> 'quote_id')::uuid
$$;

-- La semana k (desde 1) de un pedido, entre las vivas.
create function pg_temp.week(p_request text, p_k int) returns uuid
language sql
stable
as $$
  select s.id from public.sessions s
  where s.request_id = p_request::uuid and s.status <> 'cancelled'
  order by s."date", s.start_time, s.id offset p_k - 1 limit 1
$$;

-- Un menú guardado (un plato) para una sesión, como lo dejaría save_session_menu.
create function pg_temp.add_menu(p_session uuid) returns void
language sql
as $$
  insert into public.session_menus (session_id, chef_id) values (p_session, '7e6c1000-0000-4000-8000-000000000001');
  insert into public.session_menu (session_id, recipe_id, chef_id, portions, position)
  values (p_session, '7e6c6000-0000-4000-8000-000000000001', '7e6c1000-0000-4000-8000-000000000001', 8, 1);
$$;

-- La vista previa de una semana, con la huella del contexto de ahora o con una leída antes.
create function pg_temp.prep(p_session uuid, p_token text, p_fingerprint text default null) returns uuid
language sql
as $$
  select (public.chef_prepare_menu_send('7e6c1000-0000-4000-8000-000000000001', p_session,
            (select m.version from public.session_menus m where m.session_id = p_session), 'it',
            jsonb_build_object('v', 1, 'token', p_token), false,
            coalesce(p_fingerprint,
                     public.chef_menu_send_context('7e6c1000-0000-4000-8000-000000000001', p_session) ->> 'fingerprint')) ->> 'sendId')::uuid
$$;

-- Huellas leídas del contexto antes de un cambio (las lee y las escribe service_role).
create temp table huellas (k text primary key, v text not null);
grant select, insert on huellas to service_role;

-- «Confirmar sin presupuesto» desde un pedido de C1: fechas (offsets), hora, 180 min y 280 €.
create function pg_temp.book(p_request text, p_offsets int[], p_start time, p_dry boolean default false) returns jsonb
language sql
as $$
  select public.chef_create_booking('7e6c1000-0000-4000-8000-000000000001',
           array(select pg_temp.d(o) from unnest(p_offsets) as o), p_start, 180, 28000,
           p_request_id => p_request::uuid, p_dry_run => p_dry)
$$;

create function pg_temp.deliver(p_send uuid, p_token text) returns timestamptz
language sql
as $$
  select public.chef_link_menu_send('7e6c1000-0000-4000-8000-000000000001', p_send, pg_temp.h(p_token));
  select (public.chef_complete_menu_send('7e6c1000-0000-4000-8000-000000000001', p_send, array['email']) ->> 'sentAt')::timestamptz;
$$;

create function pg_temp.send_of(p_token text) returns uuid
language sql
stable
as $$ select ms.id from public.menu_sends ms where ms.snapshot ->> 'token' = p_token $$;

-- ---------------------------------------------------------------------
-- 1. Privilegios y pg_cron
-- ---------------------------------------------------------------------
select is(
  (select array_agg(p.proname::text order by p.proname)
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('chef_create_quote', 'chef_update_quote', 'chef_withdraw_quote',
                       'client_link_accept_quote', 'client_link_decline_quote')
     and p.prosecdef
     and has_function_privilege('service_role', p.oid, 'EXECUTE')
     and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and not has_function_privilege('anon', p.oid, 'EXECUTE')),
  array['chef_create_quote', 'chef_update_quote', 'chef_withdraw_quote', 'client_link_accept_quote', 'client_link_decline_quote'],
  'las funciones nuevas: security definer y solo service_role');
select ok(not has_function_privilege('service_role', 'private.expire_quotes(timestamptz)', 'EXECUTE'),
  'private.expire_quotes no la ejecuta nadie por la API');
select is((select count(*)::int from cron.job where jobname = 'radici-expire-quotes' and schedule = '*/15 * * * *'
           and command = 'select private.expire_quotes()'),
  1, 'pg_cron vence los presupuestos cada 15 minutos');
select is(
  (select indexdef from pg_indexes where schemaname = 'public' and indexname = 'quotes_version_por_pedido'),
  'CREATE UNIQUE INDEX quotes_version_por_pedido ON public.quotes USING btree (request_id, version) WHERE (sent_at IS NOT NULL)',
  'la versión es única solo entre los presupuestos que salieron: un borrador no gasta número');

-- ---------------------------------------------------------------------
-- 2. chef_create_quote
-- ---------------------------------------------------------------------
set local role service_role;

select is(
  (select jsonb_agg(w - 'suggested_start' - 'start_time' - 'date' - 'status')
   from jsonb_array_elements(public.chef_create_quote('7e6c1000-0000-4000-8000-000000000001',
          '7e6c3000-0000-4000-8000-000000000001', array[pg_temp.d(0), pg_temp.d(7)], '10:00', 180, 30001, 10, true) -> 'weeks') as w),
  '[{"cook_minutes": 180, "service_cents": 15001, "session_id": null},
    {"cook_minutes": 180, "service_cents": 15000, "session_id": null}]'::jsonb,
  'dryRun: el reparto del precio por semana, sin crear nada (el estado de cada fecha es el de booking_day_checks)');
select is((select count(*)::int from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'), 0,
  'el dryRun no escribe nada');

select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000001', array[0, 7], 30001) is not null, 'prepara el presupuesto de R1');
select is(
  (select string_agg(concat_ws(' ', s.status, s.pay_mode, s.service_cents,
                              s.hold_until = least(now() + interval '24 hours', (pg_temp.d(0) + time '10:00') at time zone 'Europe/Rome'),
                              s.quote_is_set), ' | ' order by s."date")
   from (select s.*, (s.quote_id is not null)::text as quote_is_set from public.sessions s
         where s.request_id = '7e6c3000-0000-4000-8000-000000000001') s),
  'held manual 15001 t true | held manual 15000 t true',
  'dos sesiones held (manual), con el precio repartido, retenidas 24 h (sin pasar la llegada de la primera) y ligadas al presupuesto');
select is(
  (select concat_ws(' ', q.version, q.sent_at is null, q.service_cents, q.slot_date = pg_temp.d(0), q.slot_start,
                    q.session_id = pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1), q.pricing_snapshot = '{}')
   from public.quotes q where q.request_id = '7e6c3000-0000-4000-8000-000000000001'),
  '1 t 30001 t 10:00:00 t t',
  'el presupuesto: versión 1, sin enviar, con el total, la primera fecha y la primera sesión (sin términos enviados todavía)');
select is((select concat_ws(' ', r.status, r.seen_at is not null) from public.requests r where r.id = '7e6c3000-0000-4000-8000-000000000001'),
  'new t', 'el pedido sigue new (sale quoted al enviarlo) y queda visto');

select is(
  array[
    pg_temp.error_of($$ select pg_temp.quote('7e6c3000-0000-4000-8000-000000000001', array[21], 100) $$),
    pg_temp.error_of($$ select pg_temp.quote('7e6c3000-0000-4000-8000-000000000004', array[21], 100) $$),
    pg_temp.error_of($$ select pg_temp.quote('7e6c3000-0000-4000-8000-000000000003', array[21], 100) $$),
    pg_temp.error_of($$ select pg_temp.quote('7e6c3000-0000-4000-8000-000000000002', array[21, 28], 100) $$),
    pg_temp.error_of($$ select pg_temp.quote('7e6c3000-0000-4000-8000-00000000000f', array[21], 100) $$),
    pg_temp.error_of($$ select pg_temp.quote('7e6c3000-0000-4000-8000-000000000005', array[16], 100) $$),
    pg_temp.error_of($$ select pg_temp.quote('7e6c3000-0000-4000-8000-000000000005', array[21], -1) $$),
    pg_temp.error_of($$ select pg_temp.quote('7e6c3000-0000-4000-8000-000000000005', array[21, 22], 100) $$)
  ]::text[],
  array['55000: quote_exists', '55000: request_not_new (accepted)', '22023: invalid_request_type',
        '22023: weeks_only_for_week', 'P0002: request_not_found', '23P01: slot_taken (' || to_char(pg_temp.d(16), 'YYYY-MM-DD') || ')',
        '22023: invalid_cents', '22023: dates_same_week (' || to_char(pg_temp.d(22), 'YYYY-MM-DD') || ')'],
  'presupuesto repetido, pedido no new, de cambio, extra con dos semanas, de otra cocina, horario ocupado, precio y semanas');

-- ---------------------------------------------------------------------
-- 3. chef_update_quote
-- ---------------------------------------------------------------------
select is(
  public.chef_update_quote('7e6c1000-0000-4000-8000-000000000001',
    (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'), 40000) ->> 'totalCents',
  '40000', 'otro precio: devuelve los términos con el total nuevo');
select is(
  (select array_agg(s.service_cents order by s."date") from public.sessions s where s.request_id = '7e6c3000-0000-4000-8000-000000000001'),
  array[20000, 20000], 'y lo reparte entre las semanas');
select is(
  array[
    pg_temp.error_of($$ select public.chef_update_quote('7e6c1000-0000-4000-8000-000000000002',
      (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'), 1) $$),
    pg_temp.error_of($$ select public.chef_update_quote('7e6c1000-0000-4000-8000-000000000001',
      (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'), null) $$)
  ]::text[],
  array['P0002: quote_not_found', '22023: invalid_cents'],
  'precio: de otra cocina o inválido');

-- ---------------------------------------------------------------------
-- 4. El envío de la semana 1 lleva el presupuesto
-- ---------------------------------------------------------------------
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1)) $$, 'menú de la semana 1 de R1');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 2)) $$, 'menú de la semana 2 de R1');

select is(
  (public.chef_menu_send_context('7e6c1000-0000-4000-8000-000000000001', pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1)) -> 'quote')
    - 'id' - 'holdUntil' - 'terms',
  '{"version": 1, "sent": false, "holdHours": 48, "firstWeek": true}'::jsonb,
  'el contexto de la semana 1 trae el presupuesto (sin enviar, plazo de 48 h, primera semana)');
select is(
  (public.chef_menu_send_context('7e6c1000-0000-4000-8000-000000000001', pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1)) #> '{quote,terms,weeks}')
    @> jsonb_build_array(jsonb_build_object('date', pg_temp.d(7), 'start', '10:00', 'cookMinutes', 180, 'serviceCents', 20000)),
  true, 'con sus términos: cada semana con fecha, hora, minutos y precio');
select is(
  (public.chef_menu_send_context('7e6c1000-0000-4000-8000-000000000001', pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 2)) #>> '{quote,firstWeek}'),
  'false', 'la semana 2 no es la que lleva el presupuesto');
select is(pg_temp.error_of($$ select pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 2), 'r1-w2') $$),
  '55000: quote_week_not_first', 'el menú de la semana 2 no sale antes de aceptar el presupuesto');

select ok(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1), 'r1-a') is not null, 'vista previa de la semana 1');
select is(
  (select concat_ws(' ', ms.quote_id = q.id, ms.quote_terms ->> 'totalCents')
   from public.menu_sends ms join public.quotes q on q.request_id = '7e6c3000-0000-4000-8000-000000000001'
   where ms.id = pg_temp.send_of('r1-a')),
  't 40000', 'el envío lleva el presupuesto y sus términos');

-- La huella de la foto cubre los términos del presupuesto: si cambian entre el contexto (la función
-- traduce la lista con la huella en la mano) y la vista previa, la foto no se guarda, aunque el menú
-- sea el mismo. Los minutos de la semana 2, con la misma fecha y hora, solo los ven los términos: otra
-- fecha u hora ya cambiaría la clave de las semanas de la reserva.
insert into huellas (k, v)
values ('r1-precio', public.chef_menu_send_context('7e6c1000-0000-4000-8000-000000000001',
                       pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1)) ->> 'fingerprint');
select ok(public.chef_update_quote('7e6c1000-0000-4000-8000-000000000001',
  (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'), 41000) is not null,
  'Evelyn cambia el precio mientras la función arma la foto');
select isnt(
  public.chef_menu_send_context('7e6c1000-0000-4000-8000-000000000001', pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1)) ->> 'fingerprint',
  (select v from huellas where k = 'r1-precio'),
  'la huella cambia con el precio, aunque el menú es el mismo');
select is(pg_temp.error_of($$ select pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1), 'r1-huella-precio',
                                                (select v from huellas where k = 'r1-precio')) $$),
  '40001: menu_changed', 'la foto armada con el precio de antes no se guarda (menu_changed)');
select is((select count(*)::int from public.menu_sends where session_id = pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1)),
  1, 'ni deja otro envío: sigue solo la vista previa r1-a');

insert into huellas (k, v)
values ('r1-minutos', public.chef_menu_send_context('7e6c1000-0000-4000-8000-000000000001',
                        pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1)) ->> 'fingerprint');
select ok(public.chef_move_session('7e6c1000-0000-4000-8000-000000000001', pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 2),
  pg_temp.d(7), null, 200) is not null,
  'Evelyn le cambia los minutos a la semana 2 (misma fecha y hora) mientras se arma la foto de la semana 1');
select is(pg_temp.error_of($$ select pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1), 'r1-huella-minutos',
                                                (select v from huellas where k = 'r1-minutos')) $$),
  '40001: menu_changed', 'esa foto tampoco se guarda: los términos del presupuesto cambiaron');
select is((select count(*)::int from public.menu_sends where session_id = pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1)),
  1, 'y tampoco deja otro envío');
select ok(public.chef_move_session('7e6c1000-0000-4000-8000-000000000001', pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 2),
  pg_temp.d(7), null, 180) is not null, 'la semana 2 vuelve a sus 180 minutos');

-- Evelyn cambia el precio después de la vista previa: ese envío ya no sale.
select ok(public.chef_update_quote('7e6c1000-0000-4000-8000-000000000001',
  (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'), 42000) is not null, 'otro precio');
select is(pg_temp.error_of($$ select public.chef_link_menu_send('7e6c1000-0000-4000-8000-000000000001', pg_temp.send_of('r1-a'), pg_temp.h('r1-a')) $$),
  '40001: quote_changed', 'una vista previa con otros términos: quote_changed');

select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1), 'r1-b'), 'r1-b') is not null,
  'nueva vista previa y envío');
select is(
  (select concat_ws(' ', q.version, q.sent_at = now(), q.last_sent_at = now(),
                    q.hold_until = least(now() + interval '48 hours', (pg_temp.d(0) + time '10:00') at time zone 'Europe/Rome'),
                    q.service_cents, q.pricing_snapshot ->> 'totalCents')
   from public.quotes q where q.request_id = '7e6c3000-0000-4000-8000-000000000001'),
  '1 t t t 42000 42000', 'el presupuesto sale: versión 1, enviado ahora, plazo de 48 h (sin pasar la llegada de la primera semana) y los términos enviados');
select is(
  (select array_agg(s.hold_until = least(now() + interval '48 hours', (pg_temp.d(0) + time '10:00') at time zone 'Europe/Rome')
                     order by s."date") from public.sessions s
   where s.request_id = '7e6c3000-0000-4000-8000-000000000001'),
  array[true, true], 'las semanas held quedan retenidas el mismo plazo');
select is((select status::text from public.requests where id = '7e6c3000-0000-4000-8000-000000000001'), 'quoted', 'el pedido pasa a quoted');

-- ---------------------------------------------------------------------
-- 5. Lo que ve la clienta y lo que contesta
-- ---------------------------------------------------------------------
select is(
  (public.client_link_view(pg_temp.h('r1-b')) -> 'quote') - 'id' - 'sentAt' - 'holdUntil',
  jsonb_build_object('version', 1, 'status', 'sent', 'acceptedAt', null, 'sendId', pg_temp.send_of('r1-b')),
  'el link muestra el presupuesto enviado y el envío que lo lleva');
select is(
  (select jsonb_agg(w ->> 'status') from jsonb_array_elements(public.client_link_view(pg_temp.h('r1-b')) -> 'weeks') as w),
  '["held", "held"]'::jsonb, 'las semanas propuestas');
select is(public.client_link_view(pg_temp.h('r1-b')) #>> '{weeks,0,send,quoteId}',
  (select id::text from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'),
  'el envío de la semana 1 dice qué presupuesto lleva');

select is(pg_temp.error_of($$ select public.client_link_confirm_menu(pg_temp.h('r1-b'), pg_temp.send_of('r1-b')) $$),
  '55000: quote_pending', 'el menú que va con un presupuesto no se confirma solo: se acepta el presupuesto');
select is(pg_temp.error_of($$ select public.client_link_accept_quote(pg_temp.h('r1-b'), gen_random_uuid()) $$),
  'P0002: send_not_found', 'aceptar un envío que no existe');

select is(
  public.client_link_request_changes(pg_temp.h('r1-b'), pg_temp.send_of('r1-b'), 'Mejor a las 11') ->> 'quoteId',
  (select id::text from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'),
  'la clienta pide cambios (y la respuesta dice que iba con el presupuesto)');
select is(pg_temp.error_of($$ select public.client_link_accept_quote(pg_temp.h('r1-b'), pg_temp.send_of('r1-b')) $$),
  '55000: changes_requested', 'después de pedir cambios no acepta esa versión');

-- Evelyn lo vuelve a mandar: versión 2. El envío viejo ya no se contesta. (now() no cambia en la
-- transacción: el primer envío se corre una hora atrás.)
reset role;
update public.menu_sends set sent_at = now() - interval '1 hour' where id = pg_temp.send_of('r1-b');
set local role service_role;
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1), 'r1-c'), 'r1-c') is not null,
  'Evelyn manda el presupuesto otra vez');
select is((select version from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'), 2::smallint,
  'el reenvío es la versión 2');
select is(pg_temp.error_of($$ select public.client_link_accept_quote(pg_temp.h('r1-b'), pg_temp.send_of('r1-b')) $$),
  '55000: menu_outdated', 'la versión vieja ya no se acepta');

select is(
  public.client_link_accept_quote(pg_temp.h('r1-b'), pg_temp.send_of('r1-c')) - 'sendId' - 'confirmedAt' - 'sessionId' - 'date' - 'quoteId',
  jsonb_build_object('requestId', '7e6c3000-0000-4000-8000-000000000001', 'chefId', '7e6c1000-0000-4000-8000-000000000001',
    'already', false, 'changesRequestedAt', null, 'start', '10:00', 'week', 1, 'weeks', 2, 'clientName', 'Anna Rota',
    'locale', 'it', 'totalCents', 42000, 'quoteWeeks', 2),
  'la clienta acepta (con cualquier link de la reserva): lo necesario para avisarle a Evelyn');
select is(
  (select array_agg(concat_ws(' ', s.status, s.hold_until is null) order by s."date") from public.sessions s
   where s.request_id = '7e6c3000-0000-4000-8000-000000000001'),
  array['confirmed t', 'confirmed t'], 'las semanas pasan a confirmed, sin retención');
select is((select concat_ws(' ', r.status, r.weeks) from public.requests r where r.id = '7e6c3000-0000-4000-8000-000000000001'),
  'accepted 2', 'el pedido pasa a accepted con sus semanas');
select is((select status::text from public.clients where id = '7e6c2000-0000-4000-8000-00000000000a'), 'trial',
  'la prospecta pasa a trial');
select is((select accepted_at from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'), now(),
  'el presupuesto queda aceptado');
select is((select client_confirmed_at from public.menu_sends where id = pg_temp.send_of('r1-c')), now(),
  'y el menú de la semana 1, confirmado');
select is(public.client_link_accept_quote(pg_temp.h('r1-c'), pg_temp.send_of('r1-c')) ->> 'already', 'true',
  'aceptar de nuevo no hace nada (already)');
select is(public.client_link_confirm_menu(pg_temp.h('r1-c'), pg_temp.send_of('r1-c')) ->> 'already', 'true',
  'confirmar ese menú: ya estaba');
select is(pg_temp.error_of($$ select public.client_link_decline_quote(pg_temp.h('r1-c'), pg_temp.send_of('r1-c')) $$),
  '55000: quote_closed (accepted)', 'un presupuesto aceptado no se rechaza');
select is((public.client_link_view(pg_temp.h('r1-c')) #>> '{quote,status}'), 'accepted', 'el link lo muestra aceptado');
select is(pg_temp.error_of($$ select public.chef_update_quote('7e6c1000-0000-4000-8000-000000000001',
    (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'), 1) $$),
  '55000: quote_closed', 'ni cambia de precio');

-- Ya confirmada, la semana 2 sigue el camino de siempre: su menú sale sin presupuesto.
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 2), 'r1-w2b'), 'r1-w2b') is not null,
  'el menú de la semana 2 sale');
select is((select quote_id from public.menu_sends where id = pg_temp.send_of('r1-w2b')), null, 'sin presupuesto');
select is(public.client_link_confirm_menu(pg_temp.h('r1-w2b'), pg_temp.send_of('r1-w2b')) ->> 'already', 'false',
  'y la clienta lo confirma');

-- ---------------------------------------------------------------------
-- 5b. Términos cambiados sin reenviar (R8) y una versión reemplazada desde otra semana (R9)
-- ---------------------------------------------------------------------
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000008', array[49, 56], 30000) is not null, 'presupuesto de R8');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000008', 1)) $$, 'su menú');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000008', 1), 'r8-a'), 'r8-a') is not null, 'sale');
select ok(public.chef_update_quote('7e6c1000-0000-4000-8000-000000000001', (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000008'), 90000) is not null,
  'Evelyn le cambia el precio y no lo reenvía');
select is(pg_temp.error_of($$ select public.client_link_accept_quote(pg_temp.h('r8-a'), pg_temp.send_of('r8-a')) $$),
  '40001: quote_changed', 'la clienta no acepta un precio que ya no es el de ahora');
select is((select array_agg(status::text order by "date") from public.sessions where request_id = '7e6c3000-0000-4000-8000-000000000008'),
  array['held', 'held'], 'y nada pasa a confirmed');
select is(public.client_link_view(pg_temp.h('r8-a')) #>> '{quote,status}', 'changed', 'el link lo muestra cambiado (sin aceptar)');
select is((select pricing_snapshot ->> 'totalCents' from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000008'),
  '30000', 'pricing_snapshot sigue con lo enviado');
reset role;
update public.menu_sends set sent_at = now() - interval '1 hour' where id = pg_temp.send_of('r8-a');
set local role service_role;
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000008', 1), 'r8-b'), 'r8-b') is not null, 'Evelyn lo reenvía');
select is(public.client_link_accept_quote(pg_temp.h('r8-b'), pg_temp.send_of('r8-b')) ->> 'totalCents', '90000', 'ahora sí: acepta el precio nuevo');
select is(
  (select concat_ws(' ', q.service_cents, q.pricing_snapshot ->> 'totalCents', q.slot_date = pg_temp.d(49), q.slot_start)
   from public.quotes q where q.request_id = '7e6c3000-0000-4000-8000-000000000008'),
  '90000 90000 t 10:00:00', 'el presupuesto guarda lo aceptado');

select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000009', array[63, 70], 40000) is not null, 'presupuesto de R9 (dos semanas)');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000009', 1)) $$, 'menú de su semana 1');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000009', 1), 'r9-a'), 'r9-a') is not null, 'sale la versión 1');
reset role;
update public.menu_sends set sent_at = now() - interval '1 hour' where id = pg_temp.send_of('r9-a');
set local role service_role;
select ok(public.chef_cancel_sessions('7e6c1000-0000-4000-8000-000000000001', array[pg_temp.week('7e6c3000-0000-4000-8000-000000000009', 1)]) is not null,
  'Evelyn cancela la semana 1');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000009', 1)) $$, 'menú de la que ahora es la primera');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000009', 1), 'r9-b'), 'r9-b') is not null,
  'y reenvía desde ahí (versión 2)');
select is(pg_temp.error_of($$ select public.client_link_accept_quote(pg_temp.h('r9-a'), pg_temp.send_of('r9-a')) $$),
  '55000: session_cancelled', 'la versión 1 (de una semana cancelada) ya no se acepta');
select is(pg_temp.error_of($$ select public.client_link_decline_quote(pg_temp.h('r9-a'), pg_temp.send_of('r9-a')) $$),
  '55000: session_cancelled', 'ni se rechaza');
select is(public.client_link_accept_quote(pg_temp.h('r9-b'), pg_temp.send_of('r9-b')) ->> 'quoteWeeks', '1', 'la versión 2 sí, con su única semana');

-- ---------------------------------------------------------------------
-- 6. Rechazar (R2, una sesión extra)
-- ---------------------------------------------------------------------
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000002', array[23], 50000) is not null, 'presupuesto de R2');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000002', 1)) $$, 'su menú');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000002', 1), 'r2'), 'r2') is not null, 'sale');
select is(public.client_link_decline_quote(pg_temp.h('r2'), pg_temp.send_of('r2')) ->> 'already', 'false', 'la clienta lo rechaza');
select is(
  (select concat_ws(' ', s.status, s.cancel_reason, s.hold_until is null) from public.sessions s
   where s.request_id = '7e6c3000-0000-4000-8000-000000000002'),
  'cancelled declined t', 'la sesión se cancela (declined)');
select is((select status::text from public.requests where id = '7e6c3000-0000-4000-8000-000000000002'), 'declined', 'el pedido pasa a declined');
select is(public.client_link_decline_quote(pg_temp.h('r2'), pg_temp.send_of('r2')) ->> 'already', 'true', 'rechazar de nuevo no hace nada');
select is(pg_temp.error_of($$ select public.client_link_accept_quote(pg_temp.h('r2'), pg_temp.send_of('r2')) $$),
  '55000: quote_closed (declined)', 'un presupuesto rechazado no se acepta');
select is(pg_temp.error_of($$ select public.client_link_request_changes(pg_temp.h('r2'), pg_temp.send_of('r2'), 'Al final sí') $$),
  '55000: quote_closed', 'ni se piden cambios');

-- ---------------------------------------------------------------------
-- 7. Vencer (R5 enviado, R6 borrador)
-- ---------------------------------------------------------------------
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000005', array[29], 30000) is not null, 'presupuesto de R5');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000005', 1)) $$, 'su menú');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000005', 1), 'r5'), 'r5') is not null, 'sale');
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000006', array[30], 30000) is not null, 'borrador de R6 (no sale)');
reset role;
update public.quotes set hold_until = now() - interval '1 minute'
where request_id in ('7e6c3000-0000-4000-8000-000000000005', '7e6c3000-0000-4000-8000-000000000006');
update public.sessions set hold_until = now() - interval '1 minute'
where request_id in ('7e6c3000-0000-4000-8000-000000000005', '7e6c3000-0000-4000-8000-000000000006');
set local role service_role;
select is(pg_temp.error_of($$ select public.client_link_accept_quote(pg_temp.h('r5'), pg_temp.send_of('r5')) $$),
  '55000: quote_closed (expired)', 'pasado el plazo no se acepta, aunque el cron todavía no haya pasado');
select is(public.client_link_view(pg_temp.h('r5')) #>> '{quote,status}', 'expired', 'y el link lo muestra vencido');
reset role;
select is(private.expire_quotes(now()), 2, 'expire_quotes vence los dos');
select is(
  (select string_agg(concat_ws(' ', s.status, s.cancel_reason), ' | ' order by s."date") from public.sessions s
   where s.request_id in ('7e6c3000-0000-4000-8000-000000000005', '7e6c3000-0000-4000-8000-000000000006')),
  'cancelled hold_expired | cancelled hold_expired', 'sus sesiones se cancelan (hold_expired)');
select is(
  (select string_agg(r.status::text, ' ' order by r.id) from public.requests r
   where r.id in ('7e6c3000-0000-4000-8000-000000000005', '7e6c3000-0000-4000-8000-000000000006')),
  'expired new', 'R5 (enviado) pasa a expired; R6 (borrador) queda new');
select is(private.expire_quotes(now()), 0, 'una segunda pasada no hace nada');
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000006', array[30], 31000) is not null,
  'R6 admite otro presupuesto (el vencido ya no está abierto)');
select is((select array_agg(version order by version) from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000006'),
  array[1, 1]::smallint[], 'también la versión 1: el borrador vencido nunca salió y no gastó número');
select is(public.chef_withdraw_quote('7e6c1000-0000-4000-8000-000000000001',
    (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000006'
       and withdrawn_at is null and expired_at is null)) ->> 'cancelled',
  '1', 'Evelyn retira ese borrador sin mandarlo');
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000006', array[30], 32000) is not null, 'y prepara otro');
select is((select array_agg(version order by version) from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000006'),
  array[1, 1, 1]::smallint[], 'un borrador retirado tampoco gasta número');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000006', 1)) $$, 'su menú');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000006', 1), 'r6'), 'r6') is not null,
  'sale: es el primer presupuesto que le llega');
select is(public.client_link_view(pg_temp.h('r6')) #>> '{quote,version}', '1',
  'la clienta lo ve como la versión 1 (no «aggiornato»)');

-- ---------------------------------------------------------------------
-- 8. Retirar (R7) y un presupuesto sin semanas
-- ---------------------------------------------------------------------
set local role service_role;
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000007', array[35, 42], 60000) is not null, 'presupuesto de R7');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000007', 1)) $$, 'su menú');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000007', 1), 'r7'), 'r7') is not null, 'sale');
select is(
  public.chef_withdraw_quote('7e6c1000-0000-4000-8000-000000000001',
    (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000007')) - 'quote_id' - 'request_id',
  '{"already": false, "cancelled": 2}'::jsonb, 'Evelyn lo retira: cancela sus dos semanas');
select is(
  (select concat_ws(' ', (select string_agg(distinct s.cancel_reason, ',') from public.sessions s where s.request_id = r.id), r.status)
   from public.requests r where r.id = '7e6c3000-0000-4000-8000-000000000007'),
  'quote_withdrawn new', 'las semanas quedan canceladas (quote_withdrawn) y el pedido vuelve a new');
select is(
  public.chef_withdraw_quote('7e6c1000-0000-4000-8000-000000000001',
    (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000007')) ->> 'already',
  'true', 'retirarlo de nuevo no hace nada');
select is(pg_temp.error_of($$ select public.client_link_accept_quote(pg_temp.h('r7'), pg_temp.send_of('r7')) $$),
  '55000: quote_closed (withdrawn)', 'uno retirado no se acepta');
select is(pg_temp.error_of($$ select public.chef_withdraw_quote('7e6c1000-0000-4000-8000-000000000001',
    (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001')) $$),
  '55000: quote_closed', 'uno aceptado no se retira');

-- R7 de nuevo, y Evelyn cancela todas sus semanas antes de mandarlo: no hay nada que aceptar.
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000007', array[35], 30000) is not null, 'otro presupuesto de R7');
select is((select version from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000007' and withdrawn_at is null),
  2::smallint, 'la versión 2: la clienta ya vio la 1 (la retirada), así que este sí es «aggiornato»');
select ok(public.chef_cancel_sessions('7e6c1000-0000-4000-8000-000000000001',
  array[pg_temp.week('7e6c3000-0000-4000-8000-000000000007', 1)]) is not null, 'Evelyn cancela su única semana');
select is(pg_temp.error_of($$ select public.chef_update_quote('7e6c1000-0000-4000-8000-000000000001',
    (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000007' and withdrawn_at is null), 100) $$),
  '55000: quote_empty', 'un presupuesto sin semanas no cambia de precio');

-- R12: un presupuesto para mañana a las 16:00 (la semana 1 de R1 puede caer mañana a las 10:00). El plazo de 48 h no pasa la llegada.
select ok((public.chef_create_quote('7e6c1000-0000-4000-8000-000000000001', '7e6c3000-0000-4000-8000-000000000012',
  array[(now() at time zone 'Europe/Rome')::date + 1], '16:00', 120, 20000, 4) ->> 'quote_id') is not null, 'presupuesto de R12 para mañana');
select is(
  (select q.hold_until from public.quotes q where q.request_id = '7e6c3000-0000-4000-8000-000000000012'),
  least(now() + interval '24 hours', (((now() at time zone 'Europe/Rome')::date + 1) + time '16:00') at time zone 'Europe/Rome'),
  'el borrador retiene 24 h, sin pasar la llegada');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000012', 1)) $$, 'su menú');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000012', 1), 'r12'), 'r12') is not null, 'sale');
select is(
  (select q.hold_until from public.quotes q where q.request_id = '7e6c3000-0000-4000-8000-000000000012'),
  (((now() at time zone 'Europe/Rome')::date + 1) + time '16:00') at time zone 'Europe/Rome',
  'enviado: el plazo es la llegada de mañana, no 48 h');

-- R7 tenía un presupuesto retirado y otro borrador: el link de antes no muestra el borrador.
select is(jsonb_array_length(public.client_link_view(pg_temp.h('r7')) -> 'weeks'), 0,
  'el link no muestra las semanas de un borrador que no salió');
select is(public.client_link_view(pg_temp.h('r7')) #>> '{quote,status}', 'withdrawn',
  'y sigue mostrando retirado el que le llegó, mientras el pedido no siga por otro camino');

-- Evelyn confirma R7 sin presupuesto: el link deja de mostrar arriba el presupuesto retirado.
select ok(pg_temp.book('7e6c3000-0000-4000-8000-000000000007', array[35], '10:00') is not null,
  'Evelyn confirma R7 sin presupuesto (retira el borrador vacío)');
select is(public.client_link_view(pg_temp.h('r7')) -> 'quote', 'null'::jsonb,
  'el link ya no muestra el presupuesto retirado arriba de la reserva');
select is(
  (select jsonb_agg(w ->> 'status') from jsonb_array_elements(public.client_link_view(pg_temp.h('r7')) -> 'weeks') as w),
  '["confirmed"]'::jsonb, 'solo la semana confirmada');

-- R10: Evelyn rechaza el pedido desde la bandeja con un borrador abierto.
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000010', array[77], 30000) is not null, 'borrador de R10');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e6c0000-0000-4000-8000-00000000c001","role":"authenticated"}';
update public.requests set status = 'rejected' where id = '7e6c3000-0000-4000-8000-000000000010';
reset role;
select is(
  (select concat_ws(' ', s.status, s.cancel_reason, q.withdrawn_at is not null)
   from public.sessions s join public.quotes q on q.id = s.quote_id
   where s.request_id = '7e6c3000-0000-4000-8000-000000000010'),
  'cancelled quote_withdrawn t', 'rechazar el pedido retira el borrador y libera su semana');

-- R11: Evelyn confirma sin presupuesto otra semana, con un borrador abierto.
set local role service_role;
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000011', array[84], 30000) is not null, 'borrador de R11');
select ok(public.chef_create_booking('7e6c1000-0000-4000-8000-000000000001', array[pg_temp.d(91)], '10:00', 180, 25000,
  p_request_id => '7e6c3000-0000-4000-8000-000000000011') is not null, 'Evelyn confirma sin presupuesto otra semana');
select is(
  (select string_agg(concat_ws(' ', s.status, s.cancel_reason), ' | ' order by s."date") from public.sessions s
   where s.request_id = '7e6c3000-0000-4000-8000-000000000011'),
  'cancelled quote_withdrawn | confirmed', 'el borrador se retira solo; queda la semana confirmada');

-- ---------------------------------------------------------------------
-- 9. Confirmar sin presupuesto con las fechas del presupuesto abierto: R13 (borrador, pedido new),
--    R14 (enviado, pedido quoted) y R16 (quoted sin presupuesto abierto)
-- ---------------------------------------------------------------------
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000013', array[98, 105], 30000) is not null, 'borrador de R13');
select is(
  (select array_agg(w ->> 'status' = 'busy' order by w ->> 'date')
   from jsonb_array_elements(pg_temp.book('7e6c3000-0000-4000-8000-000000000013', array[98, 105], '10:00', true) -> 'weeks') as w),
  array[false, false], 'dryRun desde R13 con sus fechas y su hora: las semanas de su propio borrador no cuentan como ocupadas');
select is(
  (select array_agg(w ->> 'status' order by w ->> 'date')
   from jsonb_array_elements(public.chef_create_booking('7e6c1000-0000-4000-8000-000000000001', array[pg_temp.d(98), pg_temp.d(105)],
          '10:00', 180, 0, p_client_id => '7e6c2000-0000-4000-8000-00000000000b', p_type => 'week',
          p_household => '{"adults": 2, "kids": 0, "days": 5, "meals": ["dinner"]}', p_dry_run => true) -> 'weeks') as w),
  array['busy', 'busy'], 'para otra reserva siguen ocupadas');
select is(pg_temp.error_of($$ select pg_temp.book('7e6c3000-0000-4000-8000-000000000013', array[16, 98], '10:00') $$),
  '23P01: slot_taken (' || to_char(pg_temp.d(16), 'YYYY-MM-DD') || ')',
  'si una semana choca con otra reserva, no se confirma nada');
select is(
  (select concat_ws(' ', q.withdrawn_at is null, (select count(*) from public.sessions s where s.quote_id = q.id and s.status = 'held'), r.status)
   from public.quotes q join public.requests r on r.id = q.request_id
   where q.request_id = '7e6c3000-0000-4000-8000-000000000013'),
  't 2 new', 'y el retiro vuelve atrás con todo: el borrador sigue abierto, con sus dos semanas, y el pedido new');
select ok(pg_temp.book('7e6c3000-0000-4000-8000-000000000013', array[98, 107], '10:00') is not null,
  'Evelyn confirma sin presupuesto: la semana 1 a la misma hora del borrador, la 2 en la semana de la del borrador (otro día)');
select is(
  (select string_agg(concat_ws(' ', s."date" - pg_temp.d(0), s.status, s.cancel_reason), ' | ' order by s."date", s.status::text)
   from public.sessions s where s.request_id = '7e6c3000-0000-4000-8000-000000000013'),
  '98 cancelled quote_withdrawn | 98 confirmed | 105 cancelled quote_withdrawn | 107 confirmed',
  'el borrador se retira antes de crear las semanas (las suyas, canceladas: quote_withdrawn) y quedan las confirmadas');
select is(
  (select concat_ws(' ', q.withdrawn_at = now(), r.status, r.weeks)
   from public.quotes q join public.requests r on r.id = q.request_id
   where q.request_id = '7e6c3000-0000-4000-8000-000000000013'),
  't accepted 2', 'el presupuesto queda retirado y el pedido, aceptado con sus dos semanas');

select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000014', array[119, 126], 30000) is not null, 'presupuesto de R14');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000014', 1)) $$, 'su menú');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000014', 1), 'r14'), 'r14') is not null,
  'sale: el pedido pasa a quoted');
select is(
  (select array_agg(w ->> 'status' = 'busy' order by w ->> 'date')
   from jsonb_array_elements(pg_temp.book('7e6c3000-0000-4000-8000-000000000014', array[119, 126], '11:00', true) -> 'weeks') as w),
  array[false, false], 'dryRun desde el pedido quoted: no da requestNotNew y las semanas de su presupuesto no cuentan');
select ok(pg_temp.book('7e6c3000-0000-4000-8000-000000000014', array[119, 126], '11:00') is not null,
  'la clienta aceptó por WhatsApp, a las 11: Evelyn confirma sin presupuesto');
select is(
  (select string_agg(concat_ws(' ', s."date" - pg_temp.d(0), to_char(s.start_time, 'HH24:MI'), s.status, s.cancel_reason), ' | '
                     order by s."date", s.status::text)
   from public.sessions s where s.request_id = '7e6c3000-0000-4000-8000-000000000014'),
  '119 10:00 cancelled quote_withdrawn | 119 11:00 confirmed | 126 10:00 cancelled quote_withdrawn | 126 11:00 confirmed',
  'el presupuesto enviado se retira y quedan las semanas confirmadas a las 11');
select is(
  (select concat_ws(' ', q.withdrawn_at is not null, r.status)
   from public.quotes q join public.requests r on r.id = q.request_id
   where q.request_id = '7e6c3000-0000-4000-8000-000000000014'),
  't accepted', 'presupuesto retirado y pedido aceptado');
select is(pg_temp.book('7e6c3000-0000-4000-8000-000000000014', array[119, 126], '11:00') ->> 'duplicate', 'true',
  'confirmar otra vez es un reintento (duplicate)');
select is(pg_temp.error_of($$ select public.client_link_accept_quote(pg_temp.h('r14'), pg_temp.send_of('r14')) $$),
  '55000: quote_closed (withdrawn)', 'la clienta ya no acepta el presupuesto retirado');
select is(public.client_link_view(pg_temp.h('r14')) -> 'quote', 'null'::jsonb,
  'y su link no lo muestra: la reserva siguió sin él');
select is(
  (select jsonb_agg(concat_ws(' ', w ->> 'start', w ->> 'status'))
   from jsonb_array_elements(public.client_link_view(pg_temp.h('r14')) -> 'weeks') as w),
  '["11:00 confirmed", "11:00 confirmed"]'::jsonb, 'solo las semanas confirmadas');

select is(
  array[pg_temp.error_of($$ select pg_temp.book('7e6c3000-0000-4000-8000-000000000016', array[175], '10:00', true) $$),
        pg_temp.error_of($$ select pg_temp.book('7e6c3000-0000-4000-8000-000000000016', array[175], '10:00') $$)]::text[],
  array['55000: request_not_new (quoted)', '55000: request_not_new (quoted)'],
  'un pedido quoted sin presupuesto abierto no se confirma (requestNotNew), tampoco en el dryRun');

-- ---------------------------------------------------------------------
-- 10. La semana que llevaba el presupuesto deja de ser la primera (R15): Evelyn la pasa al final y
--     reenvía desde la nueva primera semana.
-- ---------------------------------------------------------------------
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000015', array[140, 147, 154], 45000) is not null,
  'presupuesto de R15 (tres semanas)');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000015', 1)) $$, 'menú de su semana 1');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000015', 1), 'r15-a'), 'r15-a') is not null,
  'sale la versión 1 con el menú de la semana 1');
reset role;
update public.menu_sends set sent_at = now() - interval '1 hour' where id = pg_temp.send_of('r15-a');
set local role service_role;
select ok(public.chef_move_session('7e6c1000-0000-4000-8000-000000000001',
  (select session_id from public.menu_sends where id = pg_temp.send_of('r15-a')), pg_temp.d(161)) is not null,
  'la clienta quiere empezar una semana después: Evelyn pasa la semana 1 al final');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000015', 1)) $$, 'menú de la que ahora es la primera');
select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000015', 1), 'r15-b'), 'r15-b') is not null,
  'y reenvía desde ahí (versión 2)');
select is(pg_temp.error_of($$ select public.client_link_confirm_menu(pg_temp.h('r15-b'), pg_temp.send_of('r15-a')) $$),
  '55000: quote_pending', 'el envío viejo, ahora en la última semana: su menú no se confirma mientras el presupuesto está abierto');
select is(pg_temp.error_of($$ select public.client_link_accept_quote(pg_temp.h('r15-b'), pg_temp.send_of('r15-a')) $$),
  '55000: menu_outdated', 'ni acepta el presupuesto: vale la versión del envío nuevo');
select is(public.client_link_accept_quote(pg_temp.h('r15-b'), pg_temp.send_of('r15-b')) ->> 'quoteWeeks', '3',
  'la clienta acepta la versión 2, con sus tres semanas');
select is(
  (select count(*)::int
   from jsonb_array_elements(public.menu_reminders_due('7e6c1000-0000-4000-8000-000000000001',
          ((pg_temp.d(161) - 2) + time '12:00') at time zone 'Europe/Rome')) as e
   where e ->> 'sessionId' = (select session_id::text from public.menu_sends where id = pg_temp.send_of('r15-a'))),
  1, 'Evelyn recibe el aviso de esa semana: su menú salió con una versión anterior del presupuesto y nadie lo confirmó');
select is(public.client_link_confirm_menu(pg_temp.h('r15-b'), pg_temp.send_of('r15-a')) ->> 'already', 'false',
  'aceptado el presupuesto, la clienta puede confirmar ese menú');
select is(
  (select count(*)::int
   from jsonb_array_elements(public.menu_reminders_due('7e6c1000-0000-4000-8000-000000000001',
          ((pg_temp.d(161) - 2) + time '12:00') at time zone 'Europe/Rome')) as e
   where e ->> 'sessionId' = (select session_id::text from public.menu_sends where id = pg_temp.send_of('r15-a'))),
  0, 'confirmado, ya no hay aviso');


-- ---------------------------------------------------------------------
-- 8. Presupuestos en el pasado (defensa en la base)
-- ---------------------------------------------------------------------
select is(pg_temp.error_of($$ select public.chef_create_quote('7e6c1000-0000-4000-8000-000000000001',
    '7e6c3000-0000-4000-8000-000000000001', array[pg_temp.d(-30)], '10:00', 180, 10000, 4) $$),
  '22023: invalid_dates (La primera semana ya pasó.)', 'no se prepara un presupuesto cuya primera semana ya pasó');
select is(pg_temp.error_of($$ select public.chef_create_quote('7e6c1000-0000-4000-8000-000000000001',
    '7e6c3000-0000-4000-8000-000000000001', array[(now() at time zone 'Europe/Rome')::date], '00:00', 180, 10000, 4) $$),
  '22023: invalid_dates (La primera semana ya pasó.)', 'tampoco hoy a una hora que ya pasó (hora de Roma)');
select is(pg_temp.error_of($$ select public.chef_create_quote('7e6c1000-0000-4000-8000-000000000001',
    '7e6c3000-0000-4000-8000-000000000001', array[pg_temp.d(-30)], null, 180, 10000, 4, true) $$),
  '22023: invalid_dates (La primera semana ya pasó.)', 'el dryRun sin hora rechaza un día que ya pasó');

-- Plazo vencido sin que haya pasado el cron: está cerrado en todo lo que manda o contesta.
-- R17: borrador con vista previa; al vencer su plazo, el link no sale.
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000017', array[300], 30000) is not null, 'presupuesto de R17');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000017', 1)) $$, 'su menú');
select ok(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000017', 1), 'r17') is not null, 'vista previa de R17');
-- R18: con el link armado; al vencer su plazo, no se completa el envío.
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000018', array[310], 30000) is not null, 'presupuesto de R18');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000018', 1)) $$, 'su menú');
select ok(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000018', 1), 'r18') is not null, 'vista previa de R18');
select lives_ok($$ select public.chef_link_menu_send('7e6c1000-0000-4000-8000-000000000001', pg_temp.send_of('r18'), pg_temp.h('r18')) $$,
  'link armado de R18');
-- R19: borrador cuyo plazo vence antes de la vista previa.
select ok(pg_temp.quote('7e6c3000-0000-4000-8000-000000000019', array[320], 30000) is not null, 'presupuesto de R19');
select lives_ok($$ select pg_temp.add_menu(pg_temp.week('7e6c3000-0000-4000-8000-000000000019', 1)) $$, 'su menú');
reset role;
update public.quotes set hold_until = now() - interval '1 minute'
where request_id in ('7e6c3000-0000-4000-8000-000000000017', '7e6c3000-0000-4000-8000-000000000018', '7e6c3000-0000-4000-8000-000000000019');
update public.sessions set hold_until = now() - interval '1 minute'
where request_id in ('7e6c3000-0000-4000-8000-000000000017', '7e6c3000-0000-4000-8000-000000000018', '7e6c3000-0000-4000-8000-000000000019');
set local role service_role;
select is(pg_temp.error_of($$ select public.chef_link_menu_send('7e6c1000-0000-4000-8000-000000000001', pg_temp.send_of('r17'), pg_temp.h('r17')) $$),
  '55000: quote_closed', 'vencido el plazo, el link del envío no se arma (aunque el cron no haya pasado)');
select is(pg_temp.error_of($$ select public.chef_complete_menu_send('7e6c1000-0000-4000-8000-000000000001', pg_temp.send_of('r18'), array['email']) $$),
  '55000: quote_closed', 'ni se completa un envío con el link armado');
select is(public.chef_menu_send_context('7e6c1000-0000-4000-8000-000000000001', pg_temp.week('7e6c3000-0000-4000-8000-000000000019', 1)) -> 'quote',
  'null'::jsonb, 'el contexto del envío ya no trae el presupuesto vencido');
select is(pg_temp.error_of($$ select pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000019', 1), 'r19') $$),
  '55000: quote_closed', 'ni se prepara la vista previa');
select is((select count(*)::int from public.quotes
           where request_id in ('7e6c3000-0000-4000-8000-000000000017', '7e6c3000-0000-4000-8000-000000000018', '7e6c3000-0000-4000-8000-000000000019')
             and expired_at is null), 3, 'nada de eso escribió el vencimiento: lo escribe expire_quotes');
reset role;
select is(private.expire_quotes(now()), 3, 'expire_quotes sigue venciendo y cancelando como antes');
select is((select count(*)::int from public.sessions
           where request_id in ('7e6c3000-0000-4000-8000-000000000017', '7e6c3000-0000-4000-8000-000000000018', '7e6c3000-0000-4000-8000-000000000019')
             and status = 'cancelled' and cancel_reason = 'hold_expired'), 3, 'con sus sesiones canceladas (hold_expired)');
set local role service_role;

reset role;
select * from finish();
rollback;
