-- =====================================================================
-- Presupuesto que la clienta acepta (migración 20261121120000_quotes.sql):
--   * chef_create_quote / chef_update_quote / chef_withdraw_quote: preparar (sesiones held), cambiar
--     el precio y retirar.
--   * El envío de la semana 1 lleva el presupuesto: al salir, el pedido pasa a quoted, el plazo
--     empieza y cada reenvío es otra versión.
--   * La clienta, con su link: acepta (sesiones confirmed, pedido accepted, prospecto → trial, menú
--     confirmado), rechaza (sesiones canceladas, pedido declined) o pide cambios.
--   * private.expire_quotes: vence los que no contestó (y los borradores que nunca salieron).
--
-- C1 tiene a la prospecta A (pedido semanal R1 de la web), a B (R2 extra, R5, R6 y R7 semanales) y a
-- C (R3 de cambio, R4 ya aceptado). C2 es otra cocinera con su pedido RX. Las fechas salen del lunes
-- que viene en Roma: pg_temp.d(0) es ese lunes.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(83);

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

create function pg_temp.prep(p_session uuid, p_token text) returns uuid
language sql
as $$
  select (public.chef_prepare_menu_send('7e6c1000-0000-4000-8000-000000000001', p_session,
            (select m.version from public.session_menus m where m.session_id = p_session), 'it',
            jsonb_build_object('v', 1, 'token', p_token), false) ->> 'sendId')::uuid
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
  (select string_agg(concat_ws(' ', s.status, s.pay_mode, s.service_cents, s.hold_until between now() + interval '23 hours 59 minutes' and now() + interval '24 hours', s.quote_is_set), ' | ' order by s."date")
   from (select s.*, (s.quote_id is not null)::text as quote_is_set from public.sessions s
         where s.request_id = '7e6c3000-0000-4000-8000-000000000001') s),
  'held manual 15001 t true | held manual 15000 t true',
  'dos sesiones held (manual), con el precio repartido, retenidas 24 h y ligadas al presupuesto');
select is(
  (select concat_ws(' ', q.version, q.sent_at is null, q.service_cents, q.slot_date = pg_temp.d(0), q.slot_start,
                    q.session_id = pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1))
   from public.quotes q where q.request_id = '7e6c3000-0000-4000-8000-000000000001'),
  '1 t 30001 t 10:00:00 t',
  'el presupuesto: versión 1, sin enviar, con el total, la primera fecha y la primera sesión');
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

-- Evelyn cambia el precio después de la vista previa: ese envío ya no sale.
select ok(public.chef_update_quote('7e6c1000-0000-4000-8000-000000000001',
  (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000001'), 42000) is not null, 'otro precio');
select is(pg_temp.error_of($$ select public.chef_link_menu_send('7e6c1000-0000-4000-8000-000000000001', pg_temp.send_of('r1-a'), pg_temp.h('r1-a')) $$),
  '40001: quote_changed', 'una vista previa con otros términos: quote_changed');

select ok(pg_temp.deliver(pg_temp.prep(pg_temp.week('7e6c3000-0000-4000-8000-000000000001', 1), 'r1-b'), 'r1-b') is not null,
  'nueva vista previa y envío');
select is(
  (select concat_ws(' ', q.version, q.sent_at = now(), q.last_sent_at = now(), q.hold_until = now() + interval '48 hours',
                    q.service_cents, q.pricing_snapshot ->> 'totalCents')
   from public.quotes q where q.request_id = '7e6c3000-0000-4000-8000-000000000001'),
  '1 t t t 42000 42000', 'el presupuesto sale: versión 1, enviado ahora, plazo de 48 h y los términos enviados');
select is(
  (select array_agg(s.hold_until = now() + interval '48 hours' order by s."date") from public.sessions s
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
  array[1, 2]::smallint[], 'con la versión siguiente');

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
select ok(public.chef_cancel_sessions('7e6c1000-0000-4000-8000-000000000001',
  array[pg_temp.week('7e6c3000-0000-4000-8000-000000000007', 1)]) is not null, 'Evelyn cancela su única semana');
select is(pg_temp.error_of($$ select public.chef_update_quote('7e6c1000-0000-4000-8000-000000000001',
    (select id from public.quotes where request_id = '7e6c3000-0000-4000-8000-000000000007' and withdrawn_at is null), 100) $$),
  '55000: quote_empty', 'un presupuesto sin semanas no cambia de precio');

reset role;
select * from finish();
rollback;
