-- =====================================================================
-- Conservación (SPEC §6, docs/contracts/public-request.md §9):
-- private.purge_expired_prospects borra los prospectos sin cuenta cuyos
-- pedidos no avanzaron y cuyo último pedido supera prospect_retention_days,
-- con todo lo suyo en cascada y los avisos que apuntan a esos pedidos, y los
-- intentos del límite por IP de más de 1 día.
-- Se prueba la función, no el planificador (solo que el trabajo existe).
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(40);

-- ---------------------------------------------------------------------
-- Fixture (como postgres)
--   C1: retención por defecto (90 días). C2: 30 días. C3: sin chef_settings (90).
--   K es cliente con cuenta de C1.
-- Prospectos (p_*) y lo que se espera:
--   p_old_new      pedido new de hace 91 días, con consentimientos,
--                  restricción y dos avisos                          → se borra
--   p_old_mix      rejected (120 d), expired (95 d, con presupuesto y
--                  sesión cancelada) y declined (100 d)              → se borra
--   p_no_req_old   sin pedidos, alta de hace 100 días               → se borra
--   p_recent       new de hace 10 días                               → queda
--   p_last_recent  new de hace 200 días y rejected de hace 30        → queda
--   p_quoted       quoted de hace 200 días (avanza)                  → queda
--   p_accepted     accepted de hace 200 días (avanzó)                → queda
--   p_no_req_new   sin pedidos, alta de hace 5 días                  → queda
--   p_paid         expired de hace 200 días con un pago registrado   → queda
--   p_live         expired de hace 200 días con una sesión confirmada → queda
--   p_edge         new de hace 89 días                               → queda
--   k_account      cliente con cuenta, new de hace 200 días          → queda
--   p_account      prospecto CON cuenta (ya no lo impide un check), new de hace 200 días → queda
--   t_trial        trial sin cuenta, new de hace 200 días            → queda
--   q_old (C2)     new de hace 40 días (C2 guarda 30)                → se borra
--   q_new (C2)     new de hace 20 días                               → queda
--   r_old (C3)     new de hace 100 días (sin chef_settings: 90)      → se borra
--   r_new (C3)     new de hace 60 días                               → queda
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e600000-0000-4000-8000-00000000c001', 'chef1@purge.test'),
  ('7e600000-0000-4000-8000-00000000c002', 'chef2@purge.test'),
  ('7e600000-0000-4000-8000-00000000c003', 'chef3@purge.test'),
  ('7e600000-0000-4000-8000-00000000a001', 'k@purge.test'),
  ('7e600000-0000-4000-8000-00000000a002', 'p_account@purge.test');
update public.profiles set role = 'chef'
where id in ('7e600000-0000-4000-8000-00000000c001', '7e600000-0000-4000-8000-00000000c002',
             '7e600000-0000-4000-8000-00000000c003');

insert into public.chefs (id, profile_id, display_name) values
  ('7e601000-0000-4000-8000-000000000001', '7e600000-0000-4000-8000-00000000c001', 'Chef Uno'),
  ('7e601000-0000-4000-8000-000000000002', '7e600000-0000-4000-8000-00000000c002', 'Chef Due'),
  ('7e601000-0000-4000-8000-000000000003', '7e600000-0000-4000-8000-00000000c003', 'Chef Tre');
insert into public.chef_settings (chef_id, prospect_retention_days) values
  ('7e601000-0000-4000-8000-000000000001', 90),
  ('7e601000-0000-4000-8000-000000000002', 30);

-- Clientes: (clave, id, cocinera, perfil, estado, alta hace N días)
create temp table fx (k text primary key, id uuid not null, chef uuid not null);
insert into fx (k, id, chef) values
  ('p_old_new',     '7e602000-0000-4000-8000-000000000001', '7e601000-0000-4000-8000-000000000001'),
  ('p_old_mix',     '7e602000-0000-4000-8000-000000000002', '7e601000-0000-4000-8000-000000000001'),
  ('p_no_req_old',  '7e602000-0000-4000-8000-000000000003', '7e601000-0000-4000-8000-000000000001'),
  ('p_recent',      '7e602000-0000-4000-8000-000000000004', '7e601000-0000-4000-8000-000000000001'),
  ('p_last_recent', '7e602000-0000-4000-8000-000000000005', '7e601000-0000-4000-8000-000000000001'),
  ('p_quoted',      '7e602000-0000-4000-8000-000000000006', '7e601000-0000-4000-8000-000000000001'),
  ('p_accepted',    '7e602000-0000-4000-8000-000000000007', '7e601000-0000-4000-8000-000000000001'),
  ('p_no_req_new',  '7e602000-0000-4000-8000-000000000008', '7e601000-0000-4000-8000-000000000001'),
  ('p_paid',        '7e602000-0000-4000-8000-000000000009', '7e601000-0000-4000-8000-000000000001'),
  ('p_live',        '7e602000-0000-4000-8000-00000000000a', '7e601000-0000-4000-8000-000000000001'),
  ('p_edge',        '7e602000-0000-4000-8000-00000000000b', '7e601000-0000-4000-8000-000000000001'),
  ('k_account',     '7e602000-0000-4000-8000-00000000000c', '7e601000-0000-4000-8000-000000000001'),
  ('t_trial',       '7e602000-0000-4000-8000-00000000000d', '7e601000-0000-4000-8000-000000000001'),
  ('p_account',     '7e602000-0000-4000-8000-000000000012', '7e601000-0000-4000-8000-000000000001'),
  ('q_old',         '7e602000-0000-4000-8000-00000000000e', '7e601000-0000-4000-8000-000000000002'),
  ('q_new',         '7e602000-0000-4000-8000-00000000000f', '7e601000-0000-4000-8000-000000000002'),
  ('r_old',         '7e602000-0000-4000-8000-000000000010', '7e601000-0000-4000-8000-000000000003'),
  ('r_new',         '7e602000-0000-4000-8000-000000000011', '7e601000-0000-4000-8000-000000000003');

insert into public.clients (id, chef_id, profile_id, display_name, contact_email, status, created_at)
select fx.id, fx.chef,
       case fx.k when 'k_account' then '7e600000-0000-4000-8000-00000000a001'::uuid
                 when 'p_account' then '7e600000-0000-4000-8000-00000000a002'::uuid end,
       'Cliente ' || fx.k, fx.k || '@purge.test',
       case fx.k when 'k_account' then 'active' when 't_trial' then 'trial' else 'prospect' end::public.client_status,
       now() - make_interval(days => case fx.k when 'p_no_req_new' then 5 when 'p_recent' then 10 else 100 end)
from fx;

-- Pedidos: (cliente, estado, hace N días)
create temp table fx_req (id uuid primary key default gen_random_uuid(), k text not null, status public.request_status not null, days_ago int not null);
insert into fx_req (k, status, days_ago) values
  ('p_old_new', 'new', 91),
  ('p_old_mix', 'rejected', 120), ('p_old_mix', 'expired', 95), ('p_old_mix', 'declined', 100),
  ('p_recent', 'new', 10),
  ('p_last_recent', 'new', 200), ('p_last_recent', 'rejected', 30),
  ('p_quoted', 'quoted', 200),
  ('p_accepted', 'accepted', 200),
  ('p_paid', 'expired', 200),
  ('p_live', 'expired', 200),
  ('p_edge', 'new', 89),
  ('k_account', 'new', 200),
  ('t_trial', 'new', 200),
  ('p_account', 'new', 200),
  ('q_old', 'new', 40),
  ('q_new', 'new', 20),
  ('r_old', 'new', 100),
  ('r_new', 'new', 60);

insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals, source, created_at)
select q.id, fx.chef, fx.id, 'week', q.status, 2, 0, 3, '{dinner}', 'web', now() - make_interval(days => q.days_ago)
from fx_req q join fx on fx.k = q.k;

-- p_old_new: consentimientos, una restricción y dos avisos (de tipos distintos) sobre su pedido.
insert into public.consents (chef_id, client_id, kind, text_version)
select fx.chef, fx.id, kind, '2026-10-19'
from fx cross join unnest(array['privacy', 'health_data']::public.consent_kind[]) as kind
where fx.k in ('p_old_new', 'p_recent');
insert into public.client_restrictions (chef_id, client_id, allergen)
select fx.chef, fx.id, 'milk' from fx where fx.k in ('p_old_new', 'p_recent');

insert into public.notifications (profile_id, kind, channel, payload)
select '7e600000-0000-4000-8000-00000000c001', kind, 'email', jsonb_build_object('request_id', q.id)
from fx_req q cross join unnest(array['new_request', 'request_reminder']) as kind
where q.k in ('p_old_new', 'p_recent');
insert into public.notifications (profile_id, kind, channel, payload)
values ('7e600000-0000-4000-8000-00000000c001', 'weekly_summary', 'email', '{"week": "2026-W42"}');

-- p_old_mix: el pedido vencido tuvo presupuesto y sesión (cancelada al vencer).
insert into public.sessions (id, chef_id, client_id, request_id, date, start_time, cook_minutes, status, cancelled_at, cancel_reason)
select '7e603000-0000-4000-8000-000000000001', fx.chef, fx.id, q.id, current_date - 93, '10:00', 150, 'cancelled', now() - interval '93 days', 'hold_expired'
from fx_req q join fx on fx.k = q.k where q.k = 'p_old_mix' and q.status = 'expired';
insert into public.quotes (chef_id, request_id, session_id, cook_minutes, portions, service_cents, groceries_est_cents,
                           preauth_cents, slot_date, slot_start, hold_until, sent_at)
select fx.chef, q.id, '7e603000-0000-4000-8000-000000000001', 150, 6, 6700, 2280, 2622,
       current_date - 93, '10:00', now() - interval '93 days', now() - interval '95 days'
from fx_req q join fx on fx.k = q.k where q.k = 'p_old_mix' and q.status = 'expired';

-- p_paid: sesión cancelada con un pago registrado (registro contable).
insert into public.sessions (id, chef_id, client_id, request_id, date, start_time, cook_minutes, status, cancelled_at, cancel_reason)
select '7e603000-0000-4000-8000-000000000002', fx.chef, fx.id, q.id, current_date - 198, '10:00', 150, 'cancelled', now() - interval '198 days', 'declined'
from fx_req q join fx on fx.k = q.k where q.k = 'p_paid';
insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
values ('7e601000-0000-4000-8000-000000000001', '7e603000-0000-4000-8000-000000000002', 'cash', 'cash', 1500, 'pending');

-- p_live: una sesión que no está cancelada.
insert into public.sessions (id, chef_id, client_id, request_id, date, start_time, cook_minutes, status)
select '7e603000-0000-4000-8000-000000000003', fx.chef, fx.id, q.id, current_date - 150, '10:00', 150, 'confirmed'
from fx_req q join fx on fx.k = q.k where q.k = 'p_live';

-- Límite por IP: intentos de hace 3 días y de hace 25 horas (se borran) y uno de hace una hora (queda).
insert into private.public_request_hits (ip_hash, created_at) values
  (repeat('1', 64), now() - interval '3 days'),
  (repeat('1', 64), now() - interval '25 hours'),
  (repeat('2', 64), now() - interval '1 hour');

create temp table results (k text primary key, r jsonb);

-- =====================================================================
-- 1. Funciones y trabajo programado
-- =====================================================================
select is(
  (select array_agg(p.proname::text order by p.proname)
   from pg_proc p
   where p.pronamespace = 'private'::regnamespace
     and p.proname in ('prospect_retention_expired', 'purge_expired_prospects')
     and p.proconfig @> array['search_path=""']),
  array['prospect_retention_expired', 'purge_expired_prospects'],
  'las dos funciones están en private, con search_path vacío'
);
select is(
  (select array_agg(format('%s → %s', r, f) order by 1)
   from unnest(array['private.purge_expired_prospects()', 'private.prospect_retention_expired(uuid)']) as f
   cross join unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, f, 'EXECUTE')),
  null::text[],
  'ningún rol de la API puede ejecutarlas (ni la service role)'
);
select results_eq(
  $$ select schedule, command, username, database, active from cron.job where jobname = 'radici-purge-expired-prospects' $$,
  $$ values ('30 3 * * *'::text, 'select private.purge_expired_prospects()'::text, 'postgres'::text, 'postgres'::text, true) $$,
  'pg_cron la corre todos los días a las 03:30 UTC, como postgres'
);

insert into results (k, r)
values ('job', (select to_jsonb(j.jobid) from cron.job j where j.jobname = 'radici-purge-expired-prospects'));
select lives_ok(
  $$ select cron.schedule('radici-purge-expired-prospects', '30 3 * * *', 'select private.purge_expired_prospects()') $$,
  'volver a programarla (correr de nuevo la migración) no falla'
);
select results_eq(
  $$ select count(*)::int, min(jobid) from cron.job where jobname = 'radici-purge-expired-prospects' $$,
  $$ values (1, (select (r #>> '{}')::bigint from results where k = 'job')) $$,
  'y no duplica el trabajo: actualiza el mismo (upsert por nombre)'
);

-- =====================================================================
-- 2. La regla
-- =====================================================================
select is(
  (select array_agg(fx.k order by fx.k collate "C") from fx where private.prospect_retention_expired(fx.id)),
  array['p_no_req_old', 'p_old_mix', 'p_old_new', 'q_old', 'r_old'],
  'vencidos: prospectos sin cuenta, sin pedidos que avanzaron, sin sesiones vivas ni pagos, con el último pedido (o el alta) fuera del plazo de su cocinera'
);
select is(
  private.prospect_retention_expired('7e602000-0000-4000-8000-0000000000ff'),
  false,
  'un id que no existe no está vencido'
);
select is(
  (select count(*)::int from public.clients cl
   where cl.id not in (select id from fx) and private.prospect_retention_expired(cl.id)),
  0,
  'fuera del fixture no hay nada vencido (los contadores de abajo son exactos)'
);

-- =====================================================================
-- 3. El borrado
-- =====================================================================
insert into results (k, r) values ('run1', private.purge_expired_prospects());
select is(
  (select r - 'rate_limit_hits' from results where k = 'run1'),
  '{"clients": 5, "requests": 6, "notifications": 2}'::jsonb,
  'borra 5 prospectos, sus 6 pedidos y los 2 avisos de esos pedidos'
);
select ok(
  (select (r ->> 'rate_limit_hits')::int >= 1 from results where k = 'run1')
  and not exists (select 1 from private.public_request_hits where ip_hash = repeat('1', 64)),
  'y los intentos del límite por IP de más de 1 día (aunque no haya llegado otro intento)'
);
select is(
  (select count(*)::int from private.public_request_hits where ip_hash = repeat('2', 64)),
  1,
  'los intentos recientes quedan (cuentan para el límite)'
);

select is(
  (select array_agg(fx.k order by fx.k collate "C") from fx where not exists (select 1 from public.clients cl where cl.id = fx.id)),
  array['p_no_req_old', 'p_old_mix', 'p_old_new', 'q_old', 'r_old'],
  'desaparecen exactamente los vencidos'
);
select is(
  (select count(*)::int from fx_req q
   where q.k in ('p_no_req_old', 'p_old_mix', 'p_old_new', 'q_old', 'r_old')
     and exists (select 1 from public.requests r where r.id = q.id)),
  0,
  'sus pedidos se borran en cascada'
);
select is(
  (select count(*)::int from public.consents c join fx on fx.id = c.client_id where fx.k = 'p_old_new'),
  0,
  'sus consentimientos también'
);
select is(
  (select count(*)::int from public.client_restrictions r join fx on fx.id = r.client_id where fx.k = 'p_old_new'),
  0,
  'y sus restricciones (dato de salud)'
);
select is(
  (select count(*)::int from public.sessions where id = '7e603000-0000-4000-8000-000000000001'),
  0,
  'la sesión cancelada del pedido vencido se borra'
);
select is(
  (select count(*)::int from public.quotes q join fx_req r on r.id = q.request_id where r.k = 'p_old_mix'),
  0,
  'y el presupuesto de ese pedido'
);
select is(
  (select count(*)::int from public.notifications n
   join fx_req q on n.payload ->> 'request_id' = q.id::text
   where q.k = 'p_old_new'),
  0,
  'los avisos que apuntaban a los pedidos borrados se borran (de cualquier tipo)'
);

-- Lo que queda
select is(
  (select array_agg(fx.k order by fx.k collate "C") from fx where exists (select 1 from public.clients cl where cl.id = fx.id)),
  array['k_account', 'p_accepted', 'p_account', 'p_edge', 'p_last_recent', 'p_live', 'p_no_req_new', 'p_paid', 'p_quoted',
        'p_recent', 'q_new', 'r_new', 't_trial'],
  'se conservan: recientes, con pedidos que avanzaron, con sesión viva o pago, clientes con cuenta y no prospectos'
);
select is(
  (select count(*)::int from fx_req q
   where q.k not in ('p_no_req_old', 'p_old_mix', 'p_old_new', 'q_old', 'r_old')
     and exists (select 1 from public.requests r where r.id = q.id)),
  13,
  'todos los pedidos de los que quedan siguen ahí'
);
select is(
  (select count(*)::int from public.clients cl join fx on fx.id = cl.id where fx.k = 'k_account' and cl.profile_id is not null),
  1,
  'el cliente con cuenta no se toca aunque su pedido sea viejo'
);
select ok(
  not private.prospect_retention_expired('7e602000-0000-4000-8000-000000000012')
  and (select cl.profile_id = '7e600000-0000-4000-8000-00000000a002' from public.clients cl where cl.id = '7e602000-0000-4000-8000-000000000012'),
  'un prospecto con cuenta (sin el check clients_prospect_sin_cuenta) tampoco vence ni se borra: la retención toca solo fichas sin cuenta'
);
select is(
  (select count(*)::int from public.clients cl join fx on fx.id = cl.id where fx.k = 'p_last_recent'),
  1,
  'cuenta el último pedido: uno viejo y uno reciente → queda'
);
select is(
  (select count(*)::int from public.clients cl join fx on fx.id = cl.id where fx.k in ('p_quoted', 'p_accepted')),
  2,
  'un pedido presupuestado o aceptado conserva al prospecto aunque sea viejo'
);
select is(
  (select count(*)::int from public.clients cl join fx on fx.id = cl.id where fx.k = 'p_edge'),
  1,
  'un día antes del plazo (89 de 90) todavía queda'
);
select is(
  (select count(*)::int from public.payments where session_id = '7e603000-0000-4000-8000-000000000002'),
  1,
  'el pago registrado (y su sesión y cliente) se conserva'
);
select is(
  (select count(*)::int from public.sessions where id = '7e603000-0000-4000-8000-000000000003'),
  1,
  'la sesión confirmada se conserva'
);
select is(
  (select array_agg(kind::text order by kind) from public.consents c join fx on fx.id = c.client_id where fx.k = 'p_recent'),
  array['health_data', 'privacy'],
  'los consentimientos del prospecto reciente siguen'
);
select is(
  (select count(*)::int from public.client_restrictions r join fx on fx.id = r.client_id where fx.k = 'p_recent'),
  1,
  'y su restricción'
);
select is(
  (select count(*)::int from public.notifications n
   join fx_req q on n.payload ->> 'request_id' = q.id::text
   where q.k = 'p_recent'),
  2,
  'los avisos de pedidos que siguen no se tocan'
);
select is(
  (select count(*)::int from public.notifications where kind = 'weekly_summary'),
  1,
  'ni los avisos que no apuntan a un pedido'
);
select is(
  (select count(*)::int from public.clients cl join fx on fx.id = cl.id where fx.k = 'q_new'),
  1,
  'cada cocinera con su plazo: C2 (30 días) conserva el de hace 20'
);
select is(
  (select count(*)::int from public.clients cl join fx on fx.id = cl.id where fx.k = 'r_new'),
  1,
  'sin chef_settings se usan 90 días: el de hace 60 queda'
);

-- =====================================================================
-- 4. Idempotente y con el estado al momento de correr
-- =====================================================================
insert into results (k, r) values ('run2', private.purge_expired_prospects());
select is(
  (select r from results where k = 'run2'),
  '{"clients": 0, "requests": 0, "notifications": 0, "rate_limit_hits": 0}'::jsonb,
  'una segunda corrida no borra nada'
);

-- p_edge vuelve a pedir hoy: aunque el pedido viejo pase el plazo, el último es de hoy.
update public.requests set created_at = now() - interval '200 days'
where id in (select id from fx_req where k = 'p_edge');
insert into public.requests (chef_id, client_id, type, status, adults, kids, days, meals, source)
select fx.chef, fx.id, 'week', 'new', 1, 0, 1, '{dinner}', 'web' from fx where fx.k = 'p_edge';
select is(
  (select r -> 'clients' from (select private.purge_expired_prospects() as r) as x),
  '0'::jsonb,
  'un pedido nuevo de un prospecto viejo lo conserva'
);

-- p_quoted: el presupuesto vence → expired → el próximo borrado se lo lleva.
update public.requests set status = 'expired' where id in (select id from fx_req where k = 'p_quoted');
select is(
  private.purge_expired_prospects(),
  '{"clients": 1, "requests": 1, "notifications": 0, "rate_limit_hits": 0}'::jsonb,
  'cuando su pedido deja de avanzar (vence), el prospecto viejo se borra'
);
select is(
  (select count(*)::int from public.clients cl join fx on fx.id = cl.id where fx.k = 'p_quoted'),
  0,
  'p_quoted ya no está'
);

-- =====================================================================
-- 5. Un pago que aparece justo al borrar (payments → sessions es restrict)
-- Se simula con un trigger que registra el pago antes de borrar al cliente
-- (el trigger y todo lo demás se deshacen con el rollback del final).
-- =====================================================================
insert into public.clients (id, chef_id, display_name, contact_email, status, created_at) values
  ('7e602000-0000-4000-8000-000000000020', '7e601000-0000-4000-8000-000000000001', 'Cliente s_race', 's_race@purge.test', 'prospect', now() - interval '200 days'),
  ('7e602000-0000-4000-8000-000000000021', '7e601000-0000-4000-8000-000000000001', 'Cliente s_ok', 's_ok@purge.test', 'prospect', now() - interval '200 days');
insert into public.requests (chef_id, client_id, type, status, adults, kids, days, meals, source, created_at) values
  ('7e601000-0000-4000-8000-000000000001', '7e602000-0000-4000-8000-000000000020', 'week', 'expired', 1, 0, 1, '{dinner}', 'web', now() - interval '200 days'),
  ('7e601000-0000-4000-8000-000000000001', '7e602000-0000-4000-8000-000000000021', 'week', 'new', 1, 0, 1, '{dinner}', 'web', now() - interval '200 days');
insert into public.sessions (id, chef_id, client_id, date, start_time, cook_minutes, status, cancelled_at, cancel_reason)
values ('7e603000-0000-4000-8000-000000000020', '7e601000-0000-4000-8000-000000000001', '7e602000-0000-4000-8000-000000000020',
        current_date - 199, '10:00', 150, 'cancelled', now() - interval '199 days', 'hold_expired');

create function public.test_pay_before_delete() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.id = '7e602000-0000-4000-8000-000000000020' then
    insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
    values (old.chef_id, '7e603000-0000-4000-8000-000000000020', 'cash', 'cash', 1000, 'pending');
  end if;
  return old;
end
$$;
create trigger test_pay_before_delete before delete on public.clients
  for each row execute function public.test_pay_before_delete();

select is(
  (select r - 'rate_limit_hits' from (select private.purge_expired_prospects() as r) as x),
  '{"clients": 1, "requests": 1, "notifications": 0}'::jsonb,
  'si al borrar un cliente aparece un pago, ese cliente se conserva y el resto se borra igual'
);
select is(
  (select count(*)::int from public.clients where id = '7e602000-0000-4000-8000-000000000020'),
  1,
  'el cliente del pago sigue, con su pedido (solo se deshizo su borrado)'
);
select is(
  (select count(*)::int from public.clients where id = '7e602000-0000-4000-8000-000000000021'),
  0,
  'el otro vencido se borró'
);

select finish();
rollback;
