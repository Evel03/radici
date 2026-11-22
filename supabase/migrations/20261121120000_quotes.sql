-- =====================================================================
-- Radici · Presupuesto que la clienta acepta (proceso de presupuesto y menús del 21/11/2026, SPEC 5.8).
-- Tests: supabase/tests/database/22_quotes.test.sql.
--
-- Nicolas, 21/11/2026: «la clienta debe confirmar los menúes, y el presupuesto que le pasa Evelyn».
-- Hasta acá Evelyn confirmaba la reserva sola (chef_create_booking). Ahora, desde un pedido:
--   1. Evelyn prepara el presupuesto: semanas, fechas, hora, minutos, porciones y precio
--      (chef_create_quote). Las sesiones nacen held, así el horario queda reservado mientras arma el
--      menú de la semana 1; el borrador retiene 24 h.
--   2. Lo manda junto con el menú de la semana 1: el envío de esa semana (menu_sends) lleva el
--      presupuesto (quote_id) y sus términos (quote_terms: semanas, horas y precio, tal como los ve
--      la clienta). Al salir, el pedido pasa a quoted y el horario queda retenido quote_hold_hours
--      (48 h por defecto).
--   3. La clienta, en su link, acepta la última versión, con los términos que vio (las sesiones pasan
--      a confirmed, el pedido a accepted, la ficha de prospecto a trial, el menú de la semana 1 queda
--      confirmado y el presupuesto guarda lo aceptado), lo rechaza (sesiones canceladas, pedido
--      declined) o pide cambios (como con cualquier menú). Evelyn cambia lo que haga falta (precio con
--      chef_update_quote; fechas y semanas con chef_move_session y chef_cancel_sessions; el menú con
--      save_session_menu) y lo vuelve a mandar: otra versión, y el plazo vuelve a empezar. Mientras
--      no lo reenvíe, la clienta no puede aceptar términos que ya no son los de ahora
--      (quote_changed).
--   4. Si nadie contesta a tiempo, vence: private.expire_quotes (pg_cron, cada 15 minutos) cancela
--      las sesiones (hold_expired) y el pedido pasa a expired; un borrador que nunca salió deja el
--      pedido en new. El plazo nunca pasa la llegada de la primera semana. Evelyn también puede
--      retirarlo (chef_withdraw_quote): el pedido vuelve a new. Si el pedido pasa a otro estado por
--      otro camino (Evelyn lo rechaza, o lo confirma sin presupuesto), el presupuesto abierto se
--      retira solo (requests_close_open_quotes).
-- «Confirmar sin presupuesto» (chef_create_booking) sigue igual, para lo que se acordó por fuera.
-- Nada de esto toca los pagos.
--
--   1. quotes: last_sent_at, declined_at, withdrawn_at, expired_at; un presupuesto abierto por pedido.
--   2. menu_sends: quote_id y quote_terms.
--   3. private.quote_terms y las funciones de la cocina: chef_create_quote, chef_update_quote,
--      chef_withdraw_quote.
--   4. El envío (chef_menu_send_context, chef_prepare_menu_send, chef_link_menu_send,
--      chef_complete_menu_send), con el presupuesto.
--   5. El link de la clienta: client_link_view con el presupuesto, client_link_accept_quote,
--      client_link_decline_quote, y confirmar o pedir cambios de un menú que va con un presupuesto.
--   6. private.expire_quotes y su trabajo de pg_cron.
--   7. requests_close_open_quotes: retirar el presupuesto abierto si el pedido cambia de estado por
--      otro camino.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. quotes
--
-- version: 1 al prepararlo; cada envío después del primero la sube (la clienta ve «versión 2» y
-- solo puede aceptar la última). sent_at = el primer envío; last_sent_at = el último (null en los
-- presupuestos de antes, que salían una sola vez: vale sent_at). service_cents es el total de ahora
-- (chef_update_quote lo cambia); pricing_snapshot, los términos del último envío y, al aceptarlo,
-- los aceptados.
-- Un presupuesto está abierto mientras no tenga accepted_at, declined_at, withdrawn_at ni
-- expired_at (a lo sumo uno de los cuatro). Uno abierto por pedido.
-- ---------------------------------------------------------------------
alter table public.quotes
  add column last_sent_at timestamptz,
  add column declined_at  timestamptz,
  add column withdrawn_at timestamptz,
  add column expired_at   timestamptz;

update public.quotes set last_sent_at = sent_at where sent_at is not null;

alter table public.quotes
  add constraint quotes_ultimo_envio check (last_sent_at is null or (sent_at is not null and last_sent_at >= sent_at)),
  add constraint quotes_un_cierre check (num_nonnulls(accepted_at, declined_at, withdrawn_at, expired_at) <= 1),
  add constraint quotes_rechazo_tras_envio check (declined_at is null or sent_at is not null);

create unique index quotes_uno_abierto_por_pedido on public.quotes (request_id)
  where accepted_at is null and declined_at is null and withdrawn_at is null and expired_at is null;

comment on column public.quotes.last_sent_at is 'Último envío del presupuesto a la clienta (sent_at es el primero).';
comment on column public.quotes.declined_at is 'La clienta lo rechazó desde su link.';
comment on column public.quotes.withdrawn_at is 'Evelyn lo retiró (chef_withdraw_quote).';
comment on column public.quotes.expired_at is 'Venció sin respuesta (private.expire_quotes).';

-- ---------------------------------------------------------------------
-- 2. menu_sends: el envío de la semana 1 que lleva el presupuesto
--
-- quote_id: el presupuesto que viaja con ese envío (solo el de la primera semana viva de un
-- presupuesto abierto). quote_terms: sus términos al preparar la vista previa, calculados por la
-- base (private.quote_terms): si cambian antes de mandarlo (otro precio, una semana movida), el envío
-- no sale (quote_changed) y hay que pedir otra vista previa.
-- ---------------------------------------------------------------------
alter table public.menu_sends
  add column quote_id    uuid,
  add column quote_terms jsonb,
  add constraint menu_sends_quote_fk foreign key (quote_id, chef_id)
    references public.quotes (id, chef_id) on delete set null (quote_id),
  add constraint menu_sends_terminos_validos check (quote_terms is null or jsonb_typeof(quote_terms) = 'object'),
  add constraint menu_sends_presupuesto_con_terminos check (quote_id is null or quote_terms is not null);

create index menu_sends_por_presupuesto on public.menu_sends (quote_id) where quote_id is not null;

-- ---------------------------------------------------------------------
-- 3a. private.quote_open(q) y private.quote_terms(p_quote_id)
--
-- quote_terms: {quoteId, totalCents, weeks: [{sessionId, date, start, cookMinutes, serviceCents}]}
-- con las sesiones vivas (no canceladas) del presupuesto, por fecha. totalCents es la suma de sus
-- servicios: si Evelyn cancela una semana, el total baja con ella (y con chef_update_quote fija otro).
-- ---------------------------------------------------------------------
create function private.quote_open(p_quote public.quotes)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_quote.accepted_at is null and p_quote.declined_at is null
     and p_quote.withdrawn_at is null and p_quote.expired_at is null
$$;

create function private.quote_terms(p_quote_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'quoteId', p_quote_id,
    'totalCents', coalesce(sum(s.service_cents), 0),
    'weeks', coalesce(jsonb_agg(jsonb_build_object(
               'sessionId', s.id, 'date', s."date", 'start', to_char(s.start_time, 'HH24:MI'),
               'cookMinutes', s.cook_minutes, 'serviceCents', s.service_cents)
               order by s."date", s.start_time, s.id), '[]'::jsonb))
  from public.sessions s
  where s.quote_id = p_quote_id and s.status <> 'cancelled'
$$;

revoke all on function private.quote_open(public.quotes) from public, anon, authenticated, service_role;
revoke all on function private.quote_terms(uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3b. public.chef_create_quote: preparar el presupuesto de un pedido
--
-- Desde un pedido new (semanal o extra; no un cambio), sin otro presupuesto abierto. Las fechas, la
-- hora, los minutos, las porciones y el precio, como chef_create_booking: de 1 a 8 fechas, una por
-- semana ISO y en orden (más de una solo en un pedido semanal), a menos de un año de hoy; el precio
-- de todo el presupuesto, repartido entre las semanas con split_cents.
-- Crea una sesión held por semana (pay_mode manual, hold_until: 24 h, el borrador, sin pasar la
-- llegada de la primera) y el presupuesto (sin enviar, versión siguiente a la última del pedido). El pedido sigue new (con seen_at): pasa a
-- quoted cuando sale. p_dry_run: valida y devuelve el estado de cada fecha (booking_day_checks) sin
-- escribir nada; ahí p_start puede faltar.
-- Todo o nada: si una semana choca, no se crea ninguna (23P01 slot_taken o 23505 week_taken, con la
-- fecha).
-- Devuelve {dry_run, quote_id, request_id, client_id, hold_until, weeks: [{date, start_time,
-- cook_minutes, status, suggested_start, service_cents, session_id}]}.
-- Errores: P0002 chef_not_found, request_not_found; 22023 invalid_dates, dates_same_week,
-- invalid_start, invalid_cook_minutes, invalid_portions, invalid_cents, invalid_request_type,
-- weeks_only_for_week; 55000 request_not_new (DETAIL: el estado), quote_exists.
-- ---------------------------------------------------------------------
create function public.chef_create_quote(
  p_chef_id             uuid,
  p_request_id          uuid,
  p_dates               date[],
  p_start               time,
  p_cook_minutes        int,
  p_service_total_cents int,
  p_portions            int     default 0,
  p_dry_run             boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_today      date := (now() at time zone 'Europe/Rome')::date;
  v_hold       timestamptz;
  v_dates      date[];
  v_n          int;
  v_split      int[];
  v_request    public.requests%rowtype;
  v_quote_id   uuid;
  v_version    smallint;
  v_constraint text;
begin
  if p_chef_id is null or not exists (select 1 from public.chef_settings s where s.chef_id = p_chef_id) then
    raise exception 'chef_not_found' using errcode = 'P0002';
  end if;

  v_n := coalesce(cardinality(p_dates), 0);
  if v_n not between 1 and 8 or array_ndims(p_dates) <> 1 then
    raise exception 'invalid_dates' using errcode = '22023', detail = 'De 1 a 8 fechas.';
  end if;
  v_dates := array(select u.d from unnest(p_dates) with ordinality as u (d, n) order by u.n);
  if exists (
    select 1 from unnest(v_dates) as u (d)
    where u.d is null or not isfinite(u.d) or u.d not between v_today - 366 and v_today + 366
  ) then
    raise exception 'invalid_dates' using errcode = '22023', detail = 'Fechas a menos de un año de hoy.';
  end if;
  for i in 2 .. v_n loop
    if date_trunc('week', v_dates[i]::timestamp) = date_trunc('week', v_dates[i - 1]::timestamp) then
      raise exception 'dates_same_week' using errcode = '22023', detail = to_char(v_dates[i], 'YYYY-MM-DD');
    end if;
    if v_dates[i] < v_dates[i - 1] then
      raise exception 'invalid_dates' using errcode = '22023', detail = 'En orden.';
    end if;
  end loop;
  if p_start is null and not p_dry_run then
    raise exception 'invalid_start' using errcode = '22023';
  end if;
  if p_cook_minutes is null or p_cook_minutes not between 1 and 720 then
    raise exception 'invalid_cook_minutes' using errcode = '22023';
  end if;
  if p_portions is null or p_portions < 0 then
    raise exception 'invalid_portions' using errcode = '22023';
  end if;
  if p_service_total_cents is null or p_service_total_cents < 0 then
    raise exception 'invalid_cents' using errcode = '22023';
  end if;
  v_split := private.split_cents(p_service_total_cents, v_n);
  -- El borrador retiene 24 h, nunca más allá de la llegada de la primera semana.
  v_hold := least(now() + interval '24 hours',
                  ((v_dates[1] + coalesce(p_start, time '00:00')) at time zone 'Europe/Rome'));

  -- El lock serializa dos presupuestos (o una reserva y un presupuesto) del mismo pedido.
  select r.* into v_request
  from public.requests r
  where r.id = p_request_id and r.chef_id = p_chef_id
  for update;
  if not found then
    raise exception 'request_not_found' using errcode = 'P0002';
  end if;
  if v_request.type not in ('week', 'extra') then
    raise exception 'invalid_request_type' using errcode = '22023';
  end if;
  if v_n > 1 and v_request.type <> 'week' then
    raise exception 'weeks_only_for_week' using errcode = '22023';
  end if;
  if v_request.status <> 'new' then
    raise exception 'request_not_new' using errcode = '55000', detail = v_request.status::text;
  end if;
  if exists (select 1 from public.quotes q where q.request_id = v_request.id and private.quote_open(q)) then
    raise exception 'quote_exists' using errcode = '55000';
  end if;

  if p_dry_run then
    return jsonb_build_object(
      'dry_run', true, 'quote_id', null, 'request_id', v_request.id, 'client_id', v_request.client_id,
      'hold_until', null,
      'weeks', (
        select jsonb_agg(jsonb_build_object(
                 'date', c.day, 'start_time', c.start_time, 'cook_minutes', p_cook_minutes, 'status', c.status,
                 'suggested_start', c.suggested_start, 'service_cents', v_split[c.ord], 'session_id', null)
               order by c.ord)
        from private.booking_day_checks(p_chef_id, v_dates, p_start, p_cook_minutes) as c));
  end if;

  select coalesce(max(q.version), 0) + 1 into v_version from public.quotes q where q.request_id = v_request.id;
  insert into public.quotes (chef_id, request_id, version, cook_minutes, portions, service_cents,
                             groceries_est_cents, preauth_cents, slot_date, slot_start, hold_until)
  values (p_chef_id, v_request.id, v_version, p_cook_minutes, p_portions, p_service_total_cents,
          0, 0, v_dates[1], p_start, v_hold)
  returning id into v_quote_id;

  for i in 1 .. v_n loop
    begin
      insert into public.sessions (chef_id, client_id, request_id, quote_id, "date", start_time, cook_minutes,
                                   portions, status, hold_until, pay_mode, service_cents)
      values (p_chef_id, v_request.client_id, v_request.id, v_quote_id, v_dates[i], p_start, p_cook_minutes,
              p_portions, 'held', v_hold, 'manual', v_split[i]);
    exception
      when exclusion_violation then
        raise exception 'slot_taken' using errcode = '23P01', detail = to_char(v_dates[i], 'YYYY-MM-DD');
      when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint = 'sessions_una_por_semana' then
          raise exception 'week_taken' using errcode = '23505', detail = to_char(v_dates[i], 'YYYY-MM-DD');
        end if;
        raise;
    end;
  end loop;

  update public.quotes q
     set session_id = (select s.id from public.sessions s where s.quote_id = v_quote_id order by s."date" limit 1)
   where q.id = v_quote_id;
  update public.requests r set seen_at = coalesce(r.seen_at, now()) where r.id = v_request.id;

  return jsonb_build_object(
    'dry_run', false, 'quote_id', v_quote_id, 'request_id', v_request.id, 'client_id', v_request.client_id,
    'hold_until', v_hold,
    'weeks', (
      select jsonb_agg(jsonb_build_object(
               'date', s."date", 'start_time', to_char(s.start_time, 'HH24:MI'), 'cook_minutes', s.cook_minutes,
               'status', 'free', 'suggested_start', null, 'service_cents', s.service_cents, 'session_id', s.id)
             order by s."date")
      from public.sessions s where s.quote_id = v_quote_id));
end
$$;

comment on function public.chef_create_quote(uuid, uuid, date[], time, int, int, int, boolean) is
  'Prepara el presupuesto de un pedido new (SPEC 5.8): una sesión held por semana (borrador: retiene 24 h) y el presupuesto sin enviar. Valida como chef_create_booking; p_dry_run solo devuelve los chequeos. Errores: chef_not_found, request_not_found, invalid_*, dates_same_week, weeks_only_for_week, request_not_new, quote_exists, slot_taken, week_taken. Solo service_role (Edge Function chef).';

-- ---------------------------------------------------------------------
-- 3c. public.chef_update_quote(p_chef_id, p_quote_id, p_service_total_cents)
--
-- Otro precio para un presupuesto abierto: se reparte entre sus semanas vivas (split_cents). Si ya
-- salió, hay que volver a mandarlo para que la clienta vea el precio nuevo: los envíos preparados
-- antes ya no salen (quote_changed) y el que ella tiene no se puede aceptar hasta que llegue el
-- nuevo. pricing_snapshot sigue con los términos enviados. Devuelve los términos nuevos.
-- Errores: P0002 quote_not_found; 22023 invalid_cents; 55000 quote_closed, quote_empty.
-- ---------------------------------------------------------------------
create function public.chef_update_quote(p_chef_id uuid, p_quote_id uuid, p_service_total_cents int)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_quote public.quotes;
  v_ids   uuid[];
  v_split int[];
begin
  if p_service_total_cents is null or p_service_total_cents < 0 then
    raise exception 'invalid_cents' using errcode = '22023';
  end if;
  select q.* into v_quote from public.quotes q where q.id = p_quote_id and q.chef_id = p_chef_id for update;
  if not found then
    raise exception 'quote_not_found' using errcode = 'P0002';
  end if;
  if not private.quote_open(v_quote) then
    raise exception 'quote_closed' using errcode = '55000';
  end if;
  v_ids := array(select s.id from public.sessions s
                 where s.quote_id = p_quote_id and s.status <> 'cancelled'
                 order by s."date", s.start_time, s.id);
  if cardinality(v_ids) = 0 then
    raise exception 'quote_empty' using errcode = '55000';
  end if;
  v_split := private.split_cents(p_service_total_cents, cardinality(v_ids));
  for i in 1 .. cardinality(v_ids) loop
    update public.sessions s set service_cents = v_split[i] where s.id = v_ids[i];
  end loop;
  update public.quotes q set service_cents = p_service_total_cents where q.id = p_quote_id;
  return private.quote_terms(p_quote_id);
end
$$;

comment on function public.chef_update_quote(uuid, uuid, int) is
  'Otro precio para un presupuesto abierto (SPEC 5.8), repartido entre sus semanas vivas. Hay que volver a mandarlo. Errores: P0002 quote_not_found; 22023 invalid_cents; 55000 quote_closed / quote_empty. Devuelve los términos. Solo service_role.';

-- ---------------------------------------------------------------------
-- 3d. public.chef_withdraw_quote(p_chef_id, p_quote_id)
--
-- Evelyn retira un presupuesto abierto (enviado o no): sus semanas held se cancelan
-- (cancel_reason quote_withdrawn), el presupuesto queda retirado y el pedido vuelve a new, para
-- preparar otro, confirmar sin presupuesto o rechazarlo. Idempotente: uno ya retirado devuelve
-- already = true. Devuelve {quote_id, request_id, already, cancelled}.
-- Errores: P0002 quote_not_found; 55000 quote_closed (aceptado, rechazado o vencido).
-- ---------------------------------------------------------------------
create function public.chef_withdraw_quote(p_chef_id uuid, p_quote_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_quote     public.quotes;
  v_cancelled int;
begin
  select q.* into v_quote from public.quotes q where q.id = p_quote_id and q.chef_id = p_chef_id for update;
  if not found then
    raise exception 'quote_not_found' using errcode = 'P0002';
  end if;
  if v_quote.withdrawn_at is not null then
    return jsonb_build_object('quote_id', v_quote.id, 'request_id', v_quote.request_id, 'already', true, 'cancelled', 0);
  end if;
  if not private.quote_open(v_quote) then
    raise exception 'quote_closed' using errcode = '55000';
  end if;
  update public.sessions s
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'quote_withdrawn', hold_until = null
   where s.quote_id = p_quote_id and s.status = 'held';
  get diagnostics v_cancelled = row_count;
  update public.quotes q set withdrawn_at = now() where q.id = p_quote_id;
  update public.requests r set status = 'new' where r.id = v_quote.request_id and r.status = 'quoted';
  return jsonb_build_object('quote_id', v_quote.id, 'request_id', v_quote.request_id, 'already', false, 'cancelled', v_cancelled);
end
$$;

comment on function public.chef_withdraw_quote(uuid, uuid) is
  'Evelyn retira un presupuesto abierto (SPEC 5.8): cancela sus semanas held (quote_withdrawn) y el pedido vuelve a new. Idempotente (already). Errores: P0002 quote_not_found; 55000 quote_closed. Solo service_role.';

revoke all on function public.chef_create_quote(uuid, uuid, date[], time, int, int, int, boolean) from public, anon, authenticated, service_role;
revoke all on function public.chef_update_quote(uuid, uuid, int) from public, anon, authenticated, service_role;
revoke all on function public.chef_withdraw_quote(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.chef_create_quote(uuid, uuid, date[], time, int, int, int, boolean) to service_role;
grant execute on function public.chef_update_quote(uuid, uuid, int) to service_role;
grant execute on function public.chef_withdraw_quote(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------
-- 4. El envío con el presupuesto
--
-- private.session_quote(p_session): el presupuesto abierto de una sesión held y si es su primera
-- semana viva (la que lo lleva), o null.
-- ---------------------------------------------------------------------
create function private.session_quote(p_session public.sessions)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', q.id,
    'version', q.version,
    'sent', q.sent_at is not null,
    'holdUntil', q.hold_until,
    'holdHours', cs.quote_hold_hours,
    'firstWeek', p_session.id = (select s.id from public.sessions s
                                 where s.quote_id = q.id and s.status <> 'cancelled'
                                 order by s."date", s.start_time, s.id limit 1),
    'terms', private.quote_terms(q.id))
  from public.quotes q
  join public.chef_settings cs on cs.chef_id = q.chef_id
  where q.id = p_session.quote_id and p_session.status = 'held' and private.quote_open(q)
$$;

revoke all on function private.session_quote(public.sessions) from public, anon, authenticated, service_role;

-- La huella de la foto (private.menu_send_fingerprint, de la migración del envío) suma, en una semana
-- held de un presupuesto abierto, sus términos: si cambia el precio o una semana mientras se arma la
-- foto, la vista previa no se guarda (menu_changed).
create or replace function private.menu_send_fingerprint(p_session_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select md5(jsonb_build_object(
    'session', (select jsonb_build_object('date', s."date", 'start', s.start_time)
                from public.sessions s where s.id = p_session_id),
    'weeks', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'date', o."date", 'start', o.start_time)
                                        order by o."date", o.start_time, o.id), '[]'::jsonb)
              from public.sessions s
              join public.sessions o on o.request_id = s.request_id and o.status <> 'cancelled'
              where s.id = p_session_id),
    'menu', (select m.version from public.session_menus m where m.session_id = p_session_id),
    'dishes', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', r.id, 'nameIt', r.name_it, 'nameEs', r.name_es, 'nameEn', r.name_en,
                 'descriptionIt', r.description_it, 'descriptionEs', r.description_es,
                 'descriptionEn', r.description_en, 'diet', r.diet, 'photoId', r.photo_id,
                 'allergens', (select coalesce(jsonb_agg(a.allergen order by a.allergen), '[]'::jsonb)
                               from public.recipe_allergens a where a.recipe_id = r.id))
                 order by d.position), '[]'::jsonb)
               from public.session_menu d
               join public.recipes r on r.id = d.recipe_id
               where d.session_id = p_session_id),
    'quote', (select private.quote_terms(s.quote_id)
              from public.sessions s
              join public.quotes q on q.id = s.quote_id
              where s.id = p_session_id and s.status = 'held' and private.quote_open(q))
  )::text)
$$;

revoke all on function private.menu_send_fingerprint(uuid) from public, anon, authenticated, service_role;

-- 4a. chef_menu_send_context: igual que antes, más quote (private.session_quote o null).
create or replace function public.chef_menu_send_context(p_chef_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_session public.sessions;
  v_request public.requests;
  v_client  public.clients;
  v_menu    public.session_menus;
  v_weeks   jsonb;
  v_week    int;
  v_count   int;
begin
  select s.* into v_session from public.sessions s where s.id = p_session_id and s.chef_id = p_chef_id;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if v_session.status not in ('held', 'confirmed', 'shopping_done') then
    raise exception 'session_not_editable' using errcode = '55000', detail = v_session.status::text;
  end if;
  if v_session.request_id is null then
    raise exception 'session_without_request' using errcode = '55000';
  end if;
  select m.* into v_menu from public.session_menus m where m.session_id = p_session_id;
  if not found then
    raise exception 'menu_not_found' using errcode = 'P0002';
  end if;
  select r.* into v_request from public.requests r where r.id = v_session.request_id;
  select c.* into v_client from public.clients c where c.id = v_session.client_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sessionId', s.id, 'date', s."date", 'start', to_char(s.start_time, 'HH24:MI'))
           order by s."date", s.start_time, s.id), '[]'::jsonb),
         count(*)::int
  into v_weeks, v_count
  from public.sessions s
  where s.request_id = v_session.request_id and s.status <> 'cancelled';

  select o.n into v_week
  from (select s.id, row_number() over (order by s."date", s.start_time, s.id)::int as n
        from public.sessions s
        where s.request_id = v_session.request_id and s.status <> 'cancelled') o
  where o.id = p_session_id;

  return jsonb_build_object(
    'session', jsonb_build_object(
      'id', v_session.id, 'date', v_session."date", 'start', to_char(v_session.start_time, 'HH24:MI'),
      'status', v_session.status, 'requestId', v_session.request_id, 'week', v_week, 'weeks', v_count),
    'weeks', v_weeks,
    'request', jsonb_build_object(
      'id', v_request.id, 'type', v_request.type, 'locale', v_request.locale,
      'adults', v_request.adults, 'kids', v_request.kids, 'days', v_request.days,
      'meals', to_jsonb(v_request.meals)),
    'contact', jsonb_build_object(
      'name', coalesce(nullif(btrim(v_request.contact ->> 'name'), ''), v_client.display_name),
      'email', coalesce(nullif(btrim(v_request.contact ->> 'email'), ''), v_client.contact_email),
      'phone', coalesce(nullif(btrim(v_request.contact ->> 'phone'), ''), v_client.contact_phone)),
    'chef', (select jsonb_build_object('displayName', c.display_name) from public.chefs c where c.id = p_chef_id),
    'menu', jsonb_build_object(
      'version', v_menu.version,
      'note', v_menu.note,
      'allergensConfirmed', v_menu.allergens_confirmed,
      'dishes', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'recipeId', r.id, 'portions', d.portions,
                 'nameIt', r.name_it, 'nameEs', r.name_es, 'nameEn', r.name_en,
                 'descriptionIt', r.description_it, 'descriptionEs', r.description_es,
                 'descriptionEn', r.description_en,
                 'diet', r.diet, 'photoId', r.photo_id,
                 'allergens', coalesce((select jsonb_agg(a.allergen order by a.allergen)
                                        from public.recipe_allergens a where a.recipe_id = r.id), '[]'::jsonb))
                 order by d.position)
        from public.session_menu d
        join public.recipes r on r.id = d.recipe_id
        where d.session_id = p_session_id), '[]'::jsonb),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'name', i.name, 'section', i.section, 'quantity', i.quantity, 'unit', i.unit)
                 order by i.position)
        from public.session_shopping_items i
        where i.session_id = p_session_id), '[]'::jsonb)),
    'lastSend', (
      select jsonb_build_object(
               'id', ms.id, 'menuVersion', ms.menu_version, 'sentAt', ms.sent_at, 'sentVia', to_jsonb(ms.sent_via),
               'confirmedAt', ms.client_confirmed_at, 'changesRequestedAt', ms.changes_requested_at)
      from public.menu_sends ms
      where ms.session_id = p_session_id and ms.sent_at is not null
      order by ms.sent_at desc, ms.id desc
      limit 1),
    'quote', private.session_quote(v_session),
    'fingerprint', private.menu_send_fingerprint(p_session_id));
end
$$;

comment on function public.chef_menu_send_context(uuid, uuid) is
  'Lo que la función chef necesita para armar el mensaje del menú de una semana (SPEC 5.8): sesión con «Semana k de N», fechas de la reserva, pedido, contacto (el del pedido de la web o el de la ficha), cocinera, menú (platos en los tres idiomas, alérgenos, dieta, foto, porciones; lista; nota; versión), el último envío, si la semana es de un presupuesto abierto el presupuesto (quote: versión, si ya salió, plazo, si es su primera semana y sus términos) y la huella de todo eso. Errores: P0002 session_not_found / menu_not_found; 55000 session_not_editable / session_without_request. Solo service_role.';

-- 4b. chef_prepare_menu_send: una semana held solo sale con su presupuesto, y solo la primera. La huella
-- (p_fingerprint, la del contexto) cubre también los términos del presupuesto.
create or replace function public.chef_prepare_menu_send(
  p_chef_id      uuid,
  p_session_id   uuid,
  p_menu_version int,
  p_locale       text,
  p_snapshot     jsonb,
  p_translated   boolean,
  p_fingerprint  text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session public.sessions;
  v_version int;
  v_send_id uuid;
  v_quote   jsonb;
begin
  if p_locale is null or p_locale not in ('it', 'es', 'en') then
    raise exception 'invalid_locale' using errcode = '22023';
  end if;
  if p_snapshot is null or jsonb_typeof(p_snapshot) <> 'object' then
    raise exception 'invalid_snapshot' using errcode = '22023';
  end if;

  select s.* into v_session from public.sessions s where s.id = p_session_id and s.chef_id = p_chef_id;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if v_session.status not in ('held', 'confirmed', 'shopping_done') then
    raise exception 'session_not_editable' using errcode = '55000', detail = v_session.status::text;
  end if;
  if v_session.request_id is null then
    raise exception 'session_without_request' using errcode = '55000';
  end if;
  if v_session.status = 'held' then
    v_quote := private.session_quote(v_session);
    if v_quote is null then
      raise exception 'quote_closed' using errcode = '55000';
    end if;
    if not (v_quote ->> 'firstWeek')::boolean then
      raise exception 'quote_week_not_first' using errcode = '55000';
    end if;
  end if;

  select m.version into v_version from public.session_menus m where m.session_id = p_session_id for update;
  if not found then
    raise exception 'menu_not_found' using errcode = 'P0002';
  end if;
  if p_menu_version is distinct from v_version
     or p_fingerprint is distinct from private.menu_send_fingerprint(p_session_id) then
    raise exception 'menu_changed' using errcode = '40001';
  end if;
  if not exists (select 1 from public.session_menu d where d.session_id = p_session_id) then
    raise exception 'menu_empty' using errcode = '22023';
  end if;

  insert into public.menu_sends (chef_id, session_id, request_id, menu_version, locale, snapshot, translated,
                                 fingerprint, quote_id, quote_terms)
  values (p_chef_id, p_session_id, v_session.request_id, v_version, p_locale, p_snapshot, coalesce(p_translated, false),
          p_fingerprint, (v_quote ->> 'id')::uuid, v_quote -> 'terms')
  returning id into v_send_id;

  return jsonb_build_object('sendId', v_send_id);
end
$$;

comment on function public.chef_prepare_menu_send(uuid, uuid, int, text, jsonb, boolean, text) is
  'Vista previa del envío del menú de una semana (SPEC 5.8): guarda el envío sin salir con la foto de lo que ve la clienta y su huella. Exige la versión guardada del menú, la huella con que se armó la foto y algún plato. Una semana held solo sale como la primera de su presupuesto abierto, y el envío lo lleva (quote_id y sus términos). Devuelve {sendId}. Errores: P0002 session_not_found / menu_not_found; 55000 session_not_editable, session_without_request, quote_closed, quote_week_not_first; 40001 menu_changed; 22023 menu_empty, invalid_locale, invalid_snapshot. Solo service_role.';

-- private.send_quote_check(p_send): para un envío con presupuesto, que siga abierto y con los mismos
-- términos que en la vista previa. Bloquea el presupuesto. Errores: 55000 quote_closed; 40001
-- quote_changed.
create function private.send_quote_check(p_send public.menu_sends)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_quote public.quotes;
begin
  if p_send.quote_id is null then
    return;
  end if;
  select q.* into v_quote from public.quotes q where q.id = p_send.quote_id for update;
  if not found or not private.quote_open(v_quote) then
    raise exception 'quote_closed' using errcode = '55000';
  end if;
  if private.quote_terms(v_quote.id) is distinct from p_send.quote_terms then
    raise exception 'quote_changed' using errcode = '40001';
  end if;
end
$$;

revoke all on function private.send_quote_check(public.menu_sends) from public, anon, authenticated, service_role;

-- 4c. chef_link_menu_send: igual que antes; si lleva presupuesto, que siga abierto y sin cambios.
create or replace function public.chef_link_menu_send(p_chef_id uuid, p_send_id uuid, p_token_hash text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_send    public.menu_sends;
  v_session public.sessions;
  v_request public.requests;
  v_client  public.clients;
  v_version int;
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_token' using errcode = '22023';
  end if;
  select ms.* into v_send from public.menu_sends ms where ms.id = p_send_id and ms.chef_id = p_chef_id;
  if not found then
    raise exception 'send_not_found' using errcode = 'P0002';
  end if;
  if v_send.sent_at is not null then
    raise exception 'already_sent' using errcode = '55000';
  end if;
  select s.* into v_session from public.sessions s where s.id = v_send.session_id;
  if v_session.status not in ('held', 'confirmed', 'shopping_done') then
    raise exception 'session_not_editable' using errcode = '55000', detail = v_session.status::text;
  end if;
  select m.version into v_version from public.session_menus m where m.session_id = v_send.session_id;
  if v_version is distinct from v_send.menu_version then
    raise exception 'menu_changed' using errcode = '40001';
  end if;
  perform private.send_quote_check(v_send);
  if v_send.fingerprint is distinct from private.menu_send_fingerprint(v_send.session_id) then
    raise exception 'menu_changed' using errcode = '40001';
  end if;

  insert into public.client_links (token_hash, chef_id, request_id)
  values (p_token_hash, p_chef_id, v_send.request_id);

  select r.* into v_request from public.requests r where r.id = v_send.request_id;
  select c.* into v_client from public.clients c where c.id = v_session.client_id;
  return jsonb_build_object(
    'sendId', v_send.id,
    'sessionId', v_send.session_id,
    'requestId', v_send.request_id,
    'locale', v_send.locale,
    'snapshot', v_send.snapshot,
    'contact', jsonb_build_object(
      'name', coalesce(nullif(btrim(v_request.contact ->> 'name'), ''), v_client.display_name),
      'email', coalesce(nullif(btrim(v_request.contact ->> 'email'), ''), v_client.contact_email),
      'phone', coalesce(nullif(btrim(v_request.contact ->> 'phone'), ''), v_client.contact_phone)),
    'chefName', (select c.display_name from public.chefs c where c.id = p_chef_id));
end
$$;

comment on function public.chef_link_menu_send(uuid, uuid, text) is
  'Al enviar el menú de una semana (SPEC 5.8), antes del email: crea el link del mensaje (el hash sha-256 del token) y devuelve la foto, el idioma, el contacto de ahora y el nombre de la cocinera para armarlo. Si lleva presupuesto, tiene que seguir abierto y con los términos de la vista previa. Errores: P0002 send_not_found; 22023 invalid_token; 55000 already_sent / session_not_editable / quote_closed; 40001 menu_changed / quote_changed; 23505 token repetido. Solo service_role.';

-- 4d. chef_complete_menu_send: igual que antes; si lleva presupuesto, el presupuesto sale con él:
-- versión (la primera vez queda la 1), plazo (quote_hold_hours desde ahora sin pasar la llegada de
-- la primera semana, también en sus semanas held), los términos enviados (pricing_snapshot) y el
-- pedido pasa a quoted.
create or replace function public.chef_complete_menu_send(p_chef_id uuid, p_send_id uuid, p_via text[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_send    public.menu_sends;
  v_status  public.session_status;
  v_version int;
  v_hold    timestamptz;
begin
  select ms.* into v_send from public.menu_sends ms where ms.id = p_send_id and ms.chef_id = p_chef_id for update;
  if not found then
    raise exception 'send_not_found' using errcode = 'P0002';
  end if;
  if v_send.sent_at is not null then
    return jsonb_build_object('sendId', v_send.id, 'sentAt', v_send.sent_at, 'sentVia', to_jsonb(v_send.sent_via));
  end if;

  if p_via is null or cardinality(p_via) not between 1 and 2 or array_ndims(p_via) <> 1
     or not (p_via <@ array['email', 'whatsapp'])
     or (cardinality(p_via) = 2 and p_via[1] = p_via[2]) then
    raise exception 'invalid_via' using errcode = '22023';
  end if;

  select s.status into v_status from public.sessions s where s.id = v_send.session_id;
  if v_status not in ('held', 'confirmed', 'shopping_done') then
    raise exception 'session_not_editable' using errcode = '55000', detail = v_status::text;
  end if;
  select m.version into v_version from public.session_menus m where m.session_id = v_send.session_id for update;
  if v_version is distinct from v_send.menu_version then
    raise exception 'menu_changed' using errcode = '40001';
  end if;
  perform private.send_quote_check(v_send);
  if v_send.fingerprint is distinct from private.menu_send_fingerprint(v_send.session_id) then
    raise exception 'menu_changed' using errcode = '40001';
  end if;

  update public.menu_sends ms
  set sent_at  = now(),
      sent_via = array(select v from unnest(p_via) as v order by v)
  where ms.id = p_send_id
  returning * into v_send;

  if v_send.quote_id is not null then
    -- El plazo: quote_hold_hours desde ahora, nunca más allá de la llegada de la primera semana.
    v_hold := least(
      now() + make_interval(hours => (select cs.quote_hold_hours from public.chef_settings cs where cs.chef_id = p_chef_id)),
      ((v_send.quote_terms #>> '{weeks,0,date}')::date + (v_send.quote_terms #>> '{weeks,0,start}')::time)
        at time zone 'Europe/Rome');
    update public.quotes q
       set version      = case when q.sent_at is null then q.version else q.version + 1 end,
           sent_at      = coalesce(q.sent_at, now()),
           last_sent_at = now(),
           hold_until   = v_hold,
           slot_date    = (v_send.quote_terms #>> '{weeks,0,date}')::date,
           slot_start   = (v_send.quote_terms #>> '{weeks,0,start}')::time,
           service_cents = (v_send.quote_terms ->> 'totalCents')::int,
           pricing_snapshot = v_send.quote_terms
     where q.id = v_send.quote_id;
    update public.sessions s set hold_until = v_hold where s.quote_id = v_send.quote_id and s.status = 'held';
    update public.requests r set status = 'quoted' where r.id = v_send.request_id and r.status in ('new', 'quoted');
  end if;

  return jsonb_build_object('sendId', v_send.id, 'sentAt', v_send.sent_at, 'sentVia', to_jsonb(v_send.sent_via));
end
$$;

comment on function public.chef_complete_menu_send(uuid, uuid, text[]) is
  'Marca enviado un envío del menú preparado por chef_prepare_menu_send, cuando ya salió por p_via (email, whatsapp o los dos). Si lleva presupuesto, el presupuesto sale con él: versión, plazo de quote_hold_hours (también en sus semanas held) y el pedido pasa a quoted. Idempotente: si ya estaba enviado devuelve lo que había. Errores: P0002 send_not_found; 22023 invalid_via; 55000 session_not_editable / quote_closed; 40001 menu_changed / quote_changed (hay que pedir otra vista previa). Devuelve {sendId, sentAt, sentVia}. Solo service_role.';

-- ---------------------------------------------------------------------
-- 5. El link de la clienta
--
-- 5a. client_link_view: igual que antes, más quote: el último presupuesto que salió de la reserva,
-- {id, version, status ('sent', 'changed', 'accepted', 'declined', 'withdrawn' o 'expired'),
-- sentAt, holdUntil, acceptedAt, sendId (el último envío que lo llevó: su foto tiene lo que ve la
-- clienta)} o null. 'expired' también si venció el plazo y todavía no pasó private.expire_quotes;
-- 'changed' si Evelyn cambió el precio o una semana después de mandarlo y todavía no lo reenvió (no
-- se puede aceptar). Los términos (fechas, horas y precio) van en la foto de ese envío. Las semanas
-- held de un presupuesto que todavía no salió (un borrador) no se muestran. clientName: el nombre
-- con que llegó el pedido o, si no tiene, el de la ficha.
-- ---------------------------------------------------------------------
create or replace function public.client_link_view(p_token_hash text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_request_id uuid;
  v_request    public.requests;
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    return null;
  end if;
  v_request_id := private.client_link_request(p_token_hash);
  if v_request_id is null then
    return null;
  end if;
  select r.* into v_request from public.requests r where r.id = v_request_id;

  return jsonb_build_object(
    'requestId', v_request.id,
    'locale', v_request.locale,
    'chefName', (select c.display_name from public.chefs c where c.id = v_request.chef_id),
    'clientName', coalesce(nullif(btrim(v_request.contact ->> 'name'), ''),
                           (select c.display_name from public.clients c where c.id = v_request.client_id)),
    'weeks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sessionId', w.id, 'date', w."date", 'start', to_char(w.start_time, 'HH24:MI'),
               'status', w.status, 'week', w.n, 'weeks', w.total,
               'send', (
                 select jsonb_build_object(
                          'id', ms.id, 'sentAt', ms.sent_at, 'snapshot', ms.snapshot,
                          'confirmedAt', ms.client_confirmed_at, 'changesRequestedAt', ms.changes_requested_at,
                          'quoteId', ms.quote_id)
                 from public.menu_sends ms
                 where ms.session_id = w.id and ms.sent_at is not null
                 order by ms.sent_at desc, ms.id desc
                 limit 1))
               order by w.n)
      from (select s.id, s."date", s.start_time, s.status,
                   row_number() over (order by s."date", s.start_time, s.id)::int as n,
                   count(*) over ()::int as total
            from public.sessions s
            where s.request_id = v_request.id and s.status <> 'cancelled'
              and not (s.status = 'held'
                       and exists (select 1 from public.quotes q where q.id = s.quote_id and q.sent_at is null))) w), '[]'::jsonb),
    'quote', (
      select jsonb_build_object(
               'id', q.id,
               'version', q.version,
               'status', case
                           when q.accepted_at is not null then 'accepted'
                           when q.declined_at is not null then 'declined'
                           when q.withdrawn_at is not null then 'withdrawn'
                           when q.expired_at is not null or q.hold_until <= now() then 'expired'
                           when private.quote_terms(q.id) is distinct from
                                (select ms.quote_terms from public.menu_sends ms
                                 where ms.quote_id = q.id and ms.sent_at is not null
                                 order by ms.sent_at desc, ms.id desc limit 1) then 'changed'
                           else 'sent'
                         end,
               'sentAt', coalesce(q.last_sent_at, q.sent_at),
               'holdUntil', q.hold_until,
               'acceptedAt', q.accepted_at,
               'sendId', (select ms.id from public.menu_sends ms
                          where ms.quote_id = q.id and ms.sent_at is not null
                          order by ms.sent_at desc, ms.id desc limit 1))
      from public.quotes q
      where q.request_id = v_request.id and q.sent_at is not null
      order by q.version desc, q.created_at desc
      limit 1));
end
$$;

comment on function public.client_link_view(text) is
  'La reserva que abre un link de la clienta (SPEC 5.8), con el hash sha-256 del token: semanas no canceladas por fecha (sin las de un borrador) con el último envío del menú de cada una (la foto tal como salió y la respuesta) y el último presupuesto que salió (estado, con changed si cambió sin reenviarse; plazo y el envío que lo lleva; sus términos van en la foto). null si el link no vale. Nada de dirección, contacto ni alergias. Solo service_role.';

-- 5b. Confirmar o pedir cambios de un menú: si el envío lleva un presupuesto todavía abierto, no se
-- confirma el menú solo (se acepta el presupuesto: quote_pending); pedir cambios sí. Si el
-- presupuesto se cerró sin aceptarse (rechazado, retirado o vencido), ninguna de las dos
-- (quote_closed). Un presupuesto aceptado ya dejó ese menú confirmado.
-- private.client_link_sent_send(p_token_hash, p_send_id): el envío que salió de la reserva del link,
-- sin más controles (para contestar primero que el presupuesto está cerrado, o que ya se contestó,
-- aunque sus semanas se hayan cancelado al cerrarlo). Errores: P0002 link_not_found, send_not_found.
create function private.client_link_sent_send(p_token_hash text, p_send_id uuid)
returns public.menu_sends
language plpgsql
stable
set search_path = ''
as $$
declare
  v_request_id uuid;
  v_send       public.menu_sends;
begin
  v_request_id := case when p_token_hash ~ '^[0-9a-f]{64}$' then private.client_link_request(p_token_hash) end;
  if v_request_id is null then
    raise exception 'link_not_found' using errcode = 'P0002';
  end if;
  select ms.* into v_send
  from public.menu_sends ms
  where ms.id = p_send_id and ms.request_id = v_request_id and ms.sent_at is not null;
  if not found then
    raise exception 'send_not_found' using errcode = 'P0002';
  end if;
  return v_send;
end
$$;

revoke all on function private.client_link_sent_send(text, uuid) from public, anon, authenticated, service_role;

-- private.quote_closed_reason(p_quote_id): 'accepted', 'declined', 'withdrawn', 'expired' (también si
-- venció el plazo y todavía no pasó expire_quotes) o null si está abierto y a tiempo.
create function private.quote_closed_reason(p_quote_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
           when q.accepted_at is not null then 'accepted'
           when q.declined_at is not null then 'declined'
           when q.withdrawn_at is not null then 'withdrawn'
           when q.expired_at is not null or q.hold_until <= now() then 'expired'
         end
  from public.quotes q
  where q.id = p_quote_id
$$;

revoke all on function private.quote_closed_reason(uuid) from public, anon, authenticated, service_role;

create function private.client_send_quote_state(p_send public.menu_sends)
returns text
language sql
stable
set search_path = ''
as $$
  select case
           when p_send.quote_id is null then 'none'
           when q.accepted_at is not null then 'accepted'
           when private.quote_open(q) and q.hold_until > now() then 'open'
           else 'closed'
         end
  from (select 1) x
  left join public.quotes q on q.id = p_send.quote_id
$$;

revoke all on function private.client_send_quote_state(public.menu_sends) from public, anon, authenticated, service_role;

create or replace function public.client_link_confirm_menu(p_token_hash text, p_send_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_send  public.menu_sends;
  v_state text;
begin
  v_send := private.client_link_sent_send(p_token_hash, p_send_id);
  if v_send.client_confirmed_at is null and private.client_send_quote_state(v_send) = 'closed' then
    raise exception 'quote_closed' using errcode = '55000';
  end if;
  v_send := private.client_link_send_for_answer(p_token_hash, p_send_id);
  if v_send.client_confirmed_at is not null then
    return private.client_link_answer(v_send, true);
  end if;
  v_state := private.client_send_quote_state(v_send);
  if v_state = 'open' then
    raise exception 'quote_pending' using errcode = '55000';
  elsif v_state = 'closed' then
    raise exception 'quote_closed' using errcode = '55000';
  end if;
  if v_send.changes_requested_at is not null then
    raise exception 'changes_requested' using errcode = '55000';
  end if;
  update public.menu_sends ms set client_confirmed_at = now() where ms.id = v_send.id returning * into v_send;
  return private.client_link_answer(v_send, false);
end
$$;

comment on function public.client_link_confirm_menu(text, uuid) is
  'La clienta confirma el menú de una semana desde su link (SPEC 5.8). Idempotente (already). Errores: P0002 link_not_found / send_not_found; 55000 menu_outdated (hay un envío más nuevo) / changes_requested (ya pidió cambios: Evelyn manda otro) / quote_pending (va con un presupuesto: se acepta el presupuesto) / quote_closed. Devuelve lo necesario para avisarle a Evelyn. Solo service_role.';

create or replace function public.client_link_request_changes(p_token_hash text, p_send_id uuid, p_text text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_send public.menu_sends;
  v_text text := btrim(replace(p_text, E'\r\n', E'\n'));
begin
  if v_text is null or char_length(v_text) not between 1 and 1000 or replace(v_text, E'\n', '') ~ '[[:cntrl:]]' then
    raise exception 'invalid_text' using errcode = '22023';
  end if;
  v_send := private.client_link_sent_send(p_token_hash, p_send_id);
  if v_send.client_confirmed_at is null and private.client_send_quote_state(v_send) = 'closed' then
    raise exception 'quote_closed' using errcode = '55000';
  end if;
  v_send := private.client_link_send_for_answer(p_token_hash, p_send_id);
  if v_send.client_confirmed_at is not null then
    raise exception 'already_confirmed' using errcode = '55000';
  end if;
  if private.client_send_quote_state(v_send) = 'closed' then
    raise exception 'quote_closed' using errcode = '55000';
  end if;
  update public.menu_sends ms
  set changes_requested_at = now(), changes_text = v_text
  where ms.id = v_send.id
  returning * into v_send;
  return private.client_link_answer(v_send, false) || jsonb_build_object('quoteId', v_send.quote_id);
end
$$;

comment on function public.client_link_request_changes(text, uuid, text) is
  'La clienta pide cambios para el menú de una semana (o para el presupuesto que va con él) desde su link, con un mensaje de 1 a 1000 caracteres (SPEC 5.8). Errores: P0002 link_not_found / send_not_found; 55000 menu_outdated / already_confirmed / quote_closed; 22023 invalid_text. Devuelve lo necesario para avisarle a Evelyn (quoteId si iba con un presupuesto). Solo service_role.';

-- 5c. private.client_quote_for_answer: el presupuesto de un envío al que la clienta contesta, abierto
-- y a tiempo, con sus semanas bloqueadas (presupuesto → sesiones por id, el mismo orden que el resto).
-- El envío tiene que ser el último que lo llevó (menu_outdated: hay una versión más nueva) y los
-- términos de ahora, los que ella vio (quote_changed: Evelyn lo cambió y tiene que reenviarlo).
-- Errores: 55000 not_a_quote (el envío no lleva presupuesto), quote_closed (aceptado, rechazado,
-- retirado o vencido; DETAIL: cuál), menu_outdated, changes_requested, quote_empty; 40001
-- quote_changed.
create function private.client_quote_for_answer(p_send public.menu_sends)
returns public.quotes
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_quote public.quotes;
begin
  if p_send.quote_id is null then
    raise exception 'not_a_quote' using errcode = '55000';
  end if;
  select q.* into v_quote from public.quotes q where q.id = p_send.quote_id for update;
  if v_quote.accepted_at is not null then
    raise exception 'quote_closed' using errcode = '55000', detail = 'accepted';
  elsif v_quote.declined_at is not null then
    raise exception 'quote_closed' using errcode = '55000', detail = 'declined';
  elsif v_quote.withdrawn_at is not null then
    raise exception 'quote_closed' using errcode = '55000', detail = 'withdrawn';
  elsif v_quote.expired_at is not null or v_quote.hold_until <= now() then
    raise exception 'quote_closed' using errcode = '55000', detail = 'expired';
  end if;
  perform 1 from public.sessions s where s.quote_id = v_quote.id and s.status <> 'cancelled' order by s.id for update;
  if exists (select 1 from public.menu_sends o
             where o.quote_id = v_quote.id and o.sent_at is not null
               and (o.sent_at, o.id) > (p_send.sent_at, p_send.id)) then
    raise exception 'menu_outdated' using errcode = '55000';
  end if;
  if p_send.changes_requested_at is not null then
    raise exception 'changes_requested' using errcode = '55000';
  end if;
  if private.quote_terms(v_quote.id) is distinct from p_send.quote_terms then
    raise exception 'quote_changed' using errcode = '40001';
  end if;
  if not exists (select 1 from public.sessions s where s.quote_id = v_quote.id and s.status = 'held') then
    raise exception 'quote_empty' using errcode = '55000';
  end if;
  return v_quote;
end
$$;

revoke all on function private.client_quote_for_answer(public.menu_sends) from public, anon, authenticated, service_role;

-- 5d. public.client_link_accept_quote(p_token_hash, p_send_id): la clienta acepta el presupuesto del
-- último envío que lo llevó, con los términos que vio. Sus semanas held pasan a confirmed, el pedido
-- a accepted (con esas semanas), la ficha de prospecto a trial, el presupuesto queda aceptado con lo
-- aceptado (total, primera fecha y hora, términos) y el menú de ese envío, confirmado. Idempotente:
-- si ya lo aceptó, already = true.
-- Errores: P0002 link_not_found / send_not_found; 55000 menu_outdated (hay un envío más nuevo),
-- session_cancelled, not_a_quote, quote_closed (DETAIL: accepted, declined, withdrawn o expired),
-- changes_requested, quote_empty; 40001 quote_changed.
create function public.client_link_accept_quote(p_token_hash text, p_send_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_send   public.menu_sends;
  v_quote  public.quotes;
  v_weeks  int;
  v_reason text;
begin
  v_send := private.client_link_sent_send(p_token_hash, p_send_id);
  if v_send.quote_id is null then
    raise exception 'not_a_quote' using errcode = '55000';
  end if;
  v_reason := private.quote_closed_reason(v_send.quote_id);
  if v_reason = 'accepted' and v_send.client_confirmed_at is not null then
    return private.client_link_answer(v_send, true)
           || jsonb_build_object('quoteId', v_send.quote_id,
                                 'totalCents', (v_send.quote_terms ->> 'totalCents')::int,
                                 'quoteWeeks', jsonb_array_length(v_send.quote_terms -> 'weeks'));
  end if;
  if v_reason is not null then
    raise exception 'quote_closed' using errcode = '55000', detail = v_reason;
  end if;
  v_send := private.client_link_send_for_answer(p_token_hash, p_send_id);
  v_quote := private.client_quote_for_answer(v_send);

  update public.sessions s
     set status = 'confirmed', hold_until = null
   where s.quote_id = v_quote.id and s.status = 'held';
  get diagnostics v_weeks = row_count;
  update public.quotes q
     set accepted_at      = now(),
         service_cents    = (v_send.quote_terms ->> 'totalCents')::int,
         pricing_snapshot = v_send.quote_terms,
         slot_date        = (v_send.quote_terms #>> '{weeks,0,date}')::date,
         slot_start       = (v_send.quote_terms #>> '{weeks,0,start}')::time
   where q.id = v_quote.id;
  update public.requests r
     set status = 'accepted', weeks = greatest(v_weeks, 1)
   where r.id = v_quote.request_id;
  update public.clients c
     set status = 'trial'
   where c.id = (select r.client_id from public.requests r where r.id = v_quote.request_id)
     and c.status = 'prospect';
  update public.menu_sends ms set client_confirmed_at = now() where ms.id = v_send.id returning * into v_send;

  return private.client_link_answer(v_send, false)
         || jsonb_build_object('quoteId', v_quote.id,
                               'totalCents', (v_send.quote_terms ->> 'totalCents')::int,
                               'quoteWeeks', v_weeks);
end
$$;

comment on function public.client_link_accept_quote(text, uuid) is
  'La clienta acepta desde su link la última versión del presupuesto, con los términos que vio (SPEC 5.8): sus semanas held pasan a confirmed, el pedido a accepted, la ficha de prospecto a trial, el presupuesto guarda lo aceptado y el menú de la semana 1 queda confirmado. Idempotente (already). Errores: P0002 link_not_found / send_not_found; 55000 menu_outdated / session_cancelled / not_a_quote / quote_closed (DETAIL: cuál) / changes_requested / quote_empty; 40001 quote_changed. Devuelve lo necesario para avisarle a Evelyn. Solo service_role.';

-- 5e. public.client_link_decline_quote(p_token_hash, p_send_id): la clienta rechaza el presupuesto.
-- Sus semanas held se cancelan (declined), el pedido pasa a declined y el presupuesto queda
-- rechazado. Idempotente (already). Se puede rechazar aunque haya pedido cambios antes, pero solo la
-- última versión (si Evelyn mandó otra, menu_outdated: la página muestra la nueva).
-- Errores: P0002 link_not_found / send_not_found; 55000 menu_outdated, session_cancelled,
-- not_a_quote, quote_closed (DETAIL: cuál).
create function public.client_link_decline_quote(p_token_hash text, p_send_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_send   public.menu_sends;
  v_quote  public.quotes;
  v_reason text;
begin
  v_send := private.client_link_sent_send(p_token_hash, p_send_id);
  if v_send.quote_id is null then
    raise exception 'not_a_quote' using errcode = '55000';
  end if;
  v_reason := private.quote_closed_reason(v_send.quote_id);
  if v_reason = 'declined' then
    return private.client_link_answer(v_send, true) || jsonb_build_object('quoteId', v_send.quote_id);
  end if;
  if v_reason is not null then
    raise exception 'quote_closed' using errcode = '55000', detail = v_reason;
  end if;
  v_send := private.client_link_send_for_answer(p_token_hash, p_send_id);
  select q.* into v_quote from public.quotes q where q.id = v_send.quote_id for update;
  if v_quote.declined_at is not null then
    return private.client_link_answer(v_send, true) || jsonb_build_object('quoteId', v_quote.id);
  end if;
  if v_quote.accepted_at is not null then
    raise exception 'quote_closed' using errcode = '55000', detail = 'accepted';
  elsif v_quote.withdrawn_at is not null then
    raise exception 'quote_closed' using errcode = '55000', detail = 'withdrawn';
  elsif v_quote.expired_at is not null or v_quote.hold_until <= now() then
    raise exception 'quote_closed' using errcode = '55000', detail = 'expired';
  end if;
  if exists (select 1 from public.menu_sends o
             where o.quote_id = v_quote.id and o.sent_at is not null
               and (o.sent_at, o.id) > (v_send.sent_at, v_send.id)) then
    raise exception 'menu_outdated' using errcode = '55000';
  end if;

  update public.sessions s
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'declined', hold_until = null
   where s.quote_id = v_quote.id and s.status = 'held';
  update public.quotes q set declined_at = now() where q.id = v_quote.id;
  update public.requests r set status = 'declined' where r.id = v_quote.request_id;
  return private.client_link_answer(v_send, false) || jsonb_build_object('quoteId', v_quote.id);
end
$$;

comment on function public.client_link_decline_quote(text, uuid) is
  'La clienta rechaza el presupuesto desde su link (SPEC 5.8): sus semanas held se cancelan (declined) y el pedido pasa a declined. Idempotente (already). Errores: P0002 link_not_found / send_not_found; 55000 menu_outdated / not_a_quote / quote_closed (DETAIL: cuál). Devuelve lo necesario para avisarle a Evelyn. Solo service_role.';

revoke all on function public.client_link_accept_quote(text, uuid) from public, anon, authenticated, service_role;
revoke all on function public.client_link_decline_quote(text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.client_link_accept_quote(text, uuid) to service_role;
grant execute on function public.client_link_decline_quote(text, uuid) to service_role;

-- ---------------------------------------------------------------------
-- 6. private.expire_quotes(p_now) y pg_cron
--
-- Los presupuestos abiertos con el plazo vencido: sus semanas held se cancelan (hold_expired), el
-- presupuesto queda vencido y el pedido, si estaba quoted, pasa a expired (un borrador que nunca
-- salió deja el pedido en new). Devuelve cuántos venció.
-- ---------------------------------------------------------------------
create function private.expire_quotes(p_now timestamptz default now())
returns int
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_quote public.quotes;
  v_count int := 0;
begin
  for v_quote in
    select q.* from public.quotes q
    where q.accepted_at is null and q.declined_at is null and q.withdrawn_at is null and q.expired_at is null
      and q.hold_until <= p_now
    order by q.hold_until
    for update skip locked
  loop
    update public.sessions s
       set status = 'cancelled', cancelled_at = p_now, cancel_reason = 'hold_expired', hold_until = null
     where s.quote_id = v_quote.id and s.status = 'held';
    update public.quotes q set expired_at = p_now where q.id = v_quote.id;
    update public.requests r set status = 'expired' where r.id = v_quote.request_id and r.status = 'quoted';
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;

comment on function private.expire_quotes(timestamptz) is
  'Vence los presupuestos abiertos con el plazo cumplido (SPEC 5.8): cancela sus semanas held (hold_expired) y el pedido quoted pasa a expired. La corre pg_cron cada 15 minutos.';

revoke all on function private.expire_quotes(timestamptz) from public, anon, authenticated, service_role;

select cron.schedule('radici-expire-quotes', '*/15 * * * *', 'select private.expire_quotes()');

-- ---------------------------------------------------------------------
-- 7. requests_close_open_quotes
--
-- Si el pedido pasa a un estado que no es new ni quoted por otro camino (Evelyn lo rechaza desde la
-- bandeja, o lo confirma sin presupuesto con chef_create_booking), el presupuesto abierto se retira:
-- sus semanas held se cancelan (quote_withdrawn) y deja de retener el calendario. Aceptar, rechazar
-- o vencer el presupuesto lo cierran antes de cambiar el pedido, así que acá no encuentran nada.
-- Security definer: el rechazo llega con la sesión de la cocina, que no escribe sesiones.
-- ---------------------------------------------------------------------
create function private.close_open_quotes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quote public.quotes;
begin
  for v_quote in
    select q.* from public.quotes q
    where q.request_id = new.id
      and q.accepted_at is null and q.declined_at is null and q.withdrawn_at is null and q.expired_at is null
    for update
  loop
    update public.sessions s
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'quote_withdrawn', hold_until = null
     where s.quote_id = v_quote.id and s.status = 'held';
    update public.quotes q set withdrawn_at = now() where q.id = v_quote.id;
  end loop;
  return null;
end
$$;

comment on function private.close_open_quotes() is
  'Trigger de requests: si el pedido pasa a un estado que no es new ni quoted por otro camino (rechazado, o confirmado sin presupuesto), retira su presupuesto abierto y cancela sus semanas held (quote_withdrawn). SPEC 5.8.';

revoke all on function private.close_open_quotes() from public, anon, authenticated, service_role;

create trigger requests_close_open_quotes
  after update of status on public.requests
  for each row
  when (new.status is distinct from old.status and new.status not in ('new', 'quoted'))
  execute function private.close_open_quotes();
