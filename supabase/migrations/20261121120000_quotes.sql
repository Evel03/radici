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
--      retirarlo (chef_withdraw_quote): el pedido vuelve a new. Si el pedido sigue por otro camino,
--      el presupuesto abierto se retira solo: si Evelyn lo confirma sin presupuesto,
--      chef_create_booking lo retira antes de crear las semanas (también si ya salió); si lo rechaza
--      desde la bandeja, requests_close_open_quotes.
-- «Confirmar sin presupuesto» (chef_create_booking) sigue, para lo que se acordó por fuera: desde un
-- pedido con un presupuesto abierto, lo retira. Nada de esto toca los pagos.
--
--   1. quotes: last_sent_at, declined_at, withdrawn_at, expired_at; un presupuesto abierto por pedido;
--      la versión, única entre los que salieron (un borrador que nunca salió no gasta número).
--   2. menu_sends: quote_id y quote_terms.
--   3. private.quote_terms y las funciones de la cocina: chef_create_quote, chef_update_quote,
--      chef_withdraw_quote (con private.withdraw_quote).
--   4. El envío (chef_menu_send_context, chef_prepare_menu_send, chef_link_menu_send,
--      chef_complete_menu_send), con el presupuesto.
--   5. El link de la clienta: client_link_view con el presupuesto, client_link_accept_quote,
--      client_link_decline_quote, y confirmar o pedir cambios de un menú que va con un presupuesto.
--   6. private.expire_quotes y su trabajo de pg_cron.
--   7. Si el pedido sigue por otro camino: chef_create_booking retira el presupuesto abierto (y
--      private.booking_day_checks, en su dryRun, no cuenta sus semanas) y requests_close_open_quotes.
--   8. menu_reminders_due: una semana cuyo último envío llevaba una versión anterior del presupuesto
--      sigue pendiente.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. quotes
--
-- version: la que ve la clienta. Al prepararlo, la siguiente a la última que le llegó de ese pedido
-- (1 si todavía no le llegó ninguno: un borrador que venció o se retiró sin salir no gasta número);
-- cada envío después del primero la sube (la clienta ve «versión 2» y solo puede aceptar la última).
-- Por eso es única solo entre los que salieron (quotes_version_por_pedido). sent_at = el primer
-- envío; last_sent_at = el último (null en los presupuestos de antes, que salían una sola vez: vale
-- sent_at). service_cents es el total de ahora (chef_update_quote lo cambia); pricing_snapshot, los
-- términos del último envío y, al aceptarlo, los aceptados.
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

-- La versión, única entre los presupuestos que salieron (antes, entre todos los del pedido): dos
-- borradores que nunca salieron pueden tener la misma.
create unique index quotes_version_por_pedido on public.quotes (request_id, version) where sent_at is not null;
alter table public.quotes drop constraint quotes_request_id_version_key;

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

-- quote_live: abierto y a tiempo. Un presupuesto cuyo plazo (hold_until) ya pasó está cerrado (vencido)
-- aunque private.expire_quotes (cada 15 minutos) todavía no lo haya escrito: todo lo que manda o
-- contesta lo pregunta con esto. quote_open queda para lo que no depende del reloj (retirar, cambiar).
create function private.quote_live(p_quote public.quotes)
returns boolean
language sql
stable
set search_path = ''
as $$
  select private.quote_open(p_quote) and (p_quote.hold_until is null or p_quote.hold_until > now())
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
revoke all on function private.quote_live(public.quotes) from public, anon, authenticated, service_role;
revoke all on function private.quote_terms(uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3b. public.chef_create_quote: preparar el presupuesto de un pedido
--
-- Desde un pedido new (semanal o extra; no un cambio), sin otro presupuesto abierto. Las fechas, la
-- hora, los minutos, las porciones y el precio, como chef_create_booking: de 1 a 8 fechas, una por
-- semana ISO y en orden (más de una solo en un pedido semanal), a menos de un año de hoy; el precio
-- de todo el presupuesto, repartido entre las semanas con split_cents.
-- Crea una sesión held por semana (pay_mode manual, hold_until: 24 h, el borrador, sin pasar la
-- llegada de la primera) y el presupuesto (sin enviar, con la versión siguiente a la última que
-- salió del pedido: 1 si no salió ninguna). El pedido sigue new (con seen_at): pasa a quoted cuando
-- sale. p_dry_run: valida y devuelve el estado de cada fecha (booking_day_checks) sin escribir nada;
-- ahí p_start puede faltar.
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
  -- La primera semana no puede estar en el pasado: llegada (fecha + hora, Roma) a más tardar ahora es
  -- inválida; sin hora (dryRun), basta con que el día ya haya pasado.
  if (p_start is not null and ((v_dates[1] + p_start) at time zone 'Europe/Rome') <= now())
     or (p_start is null and v_dates[1] < v_today) then
    raise exception 'invalid_dates' using errcode = '22023', detail = 'La primera semana ya pasó.';
  end if;
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

  -- La versión que va a ver la clienta: los borradores que nunca salieron no cuentan.
  select coalesce(max(q.version), 0) + 1 into v_version
  from public.quotes q
  where q.request_id = v_request.id and q.sent_at is not null;
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
-- 3d. private.withdraw_quote(p_quote_id) y public.chef_withdraw_quote(p_chef_id, p_quote_id)
--
-- private.withdraw_quote: retira un presupuesto si sigue abierto (lo bloquea y lo vuelve a mirar,
-- por si otro camino lo cerró mientras tanto): sus semanas held se cancelan (cancel_reason
-- quote_withdrawn) y queda withdrawn_at. No toca el pedido. Devuelve cuántas semanas canceló, o null
-- si ya no estaba abierto (y no cambia nada). La usan chef_withdraw_quote, «confirmar sin
-- presupuesto» (chef_create_booking, sección 7) y el trigger requests_close_open_quotes.
--
-- chef_withdraw_quote: Evelyn retira un presupuesto abierto (enviado o no): sus semanas held se
-- cancelan, el presupuesto queda retirado y el pedido vuelve a new, para preparar otro, confirmar
-- sin presupuesto o rechazarlo. Idempotente: uno ya retirado devuelve already = true. Devuelve
-- {quote_id, request_id, already, cancelled}.
-- Errores: P0002 quote_not_found; 55000 quote_closed (aceptado, rechazado o vencido).
-- ---------------------------------------------------------------------
create function private.withdraw_quote(p_quote_id uuid)
returns int
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_quote     public.quotes;
  v_cancelled int;
begin
  select q.* into v_quote from public.quotes q where q.id = p_quote_id for update;
  if not found or not private.quote_open(v_quote) then
    return null;
  end if;
  update public.sessions s
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'quote_withdrawn', hold_until = null
   where s.quote_id = p_quote_id and s.status = 'held';
  get diagnostics v_cancelled = row_count;
  update public.quotes q set withdrawn_at = now() where q.id = p_quote_id;
  return v_cancelled;
end
$$;

revoke all on function private.withdraw_quote(uuid) from public, anon, authenticated, service_role;

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
  v_cancelled := private.withdraw_quote(p_quote_id);
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
  where q.id = p_session.quote_id and p_session.status = 'held' and private.quote_live(q)
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
              where s.id = p_session_id and s.status = 'held' and private.quote_live(q))
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
  if not found or not private.quote_live(v_quote) then
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
-- versión (la primera vez queda la que recibió al prepararlo; cada reenvío, la siguiente), plazo
-- (quote_hold_hours desde ahora sin pasar la llegada de la primera semana, también en sus semanas
-- held), los términos enviados (pricing_snapshot) y el pedido pasa a quoted.
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
-- se puede aceptar). Los términos (fechas, horas y precio) van en la foto de ese envío. Uno cerrado
-- sin aceptar (rechazado, retirado o vencido) no se devuelve si el pedido quedó accepted por otro
-- camino (Evelyn lo confirmó sin presupuesto): la reserva confirmada no lleva arriba un «Ritirato».
-- Las semanas held de un presupuesto que todavía no salió (un borrador) no se muestran. clientName:
-- el nombre con que llegó el pedido o, si no tiene, el de la ficha.
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
        -- Uno cerrado sin aceptar no queda arriba de una reserva que siguió sin él.
        and (q.accepted_at is not null or v_request.status <> 'accepted')
      order by q.version desc, q.created_at desc
      limit 1));
end
$$;

comment on function public.client_link_view(text) is
  'La reserva que abre un link de la clienta (SPEC 5.8), con el hash sha-256 del token: semanas no canceladas por fecha (sin las de un borrador) con el último envío del menú de cada una (la foto tal como salió y la respuesta) y el último presupuesto que salió (estado, con changed si cambió sin reenviarse; plazo y el envío que lo lleva; sus términos van en la foto), salvo uno cerrado sin aceptar si el pedido quedó accepted por otro camino. null si el link no vale. Nada de dirección, contacto ni alergias. Solo service_role.';

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
-- 7. Si el pedido sigue por otro camino: confirmar sin presupuesto y requests_close_open_quotes
--
-- «Confirmar sin presupuesto» (chef_create_booking desde el pedido: la clienta aceptó por fuera,
-- quizás las mismas fechas que Evelyn le había preparado) retira el presupuesto abierto del pedido,
-- en borrador (pedido new) o ya enviado (pedido quoted), antes de crear las semanas y en la misma
-- transacción: si algo choca, todo vuelve atrás, el retiro también. Si Evelyn rechaza el pedido
-- desde la bandeja, el trigger requests_close_open_quotes lo retira.
--
-- 7a. private.booking_day_checks suma p_ignore_quote_id: las semanas held de ese presupuesto no
-- cuentan para el choque (busy). Es el dryRun de confirmar sin presupuesto desde un pedido con un
-- presupuesto abierto: al confirmar se retira. Cambia la firma (un parámetro más, con valor por
-- defecto), así que se borra y se vuelve a crear, igual salvo eso: los que la llaman con 4 o 5
-- argumentos (chef_create_quote, chef_move_session, booking_result) no cambian.
-- ---------------------------------------------------------------------
drop function private.booking_day_checks(uuid, date[], time, int, uuid);

create function private.booking_day_checks(
  p_chef_id           uuid,
  p_dates             date[],
  p_start             time,
  p_cook_minutes      int,
  p_ignore_session_id uuid default null,
  p_ignore_quote_id   uuid default null
)
returns table (ord int, day date, start_time time, status text, suggested_start time)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_shop  int;
  v_gap   int;
  v_today date := (now() at time zone 'Europe/Rome')::date;
begin
  if p_cook_minutes is null or p_cook_minutes < 1 then
    raise exception 'invalid_cook_minutes' using errcode = '22023';
  end if;

  if p_ignore_session_id is not null then
    select s.shop_minutes, s.gap_minutes
      into v_shop, v_gap
    from public.sessions s
    where s.id = p_ignore_session_id
      and s.chef_id = p_chef_id;
    if not found then
      raise exception 'session_not_found' using errcode = 'P0002';
    end if;
  else
    select cs.shop_minutes, cs.gap_minutes
      into v_shop, v_gap
    from public.chef_settings cs
    where cs.chef_id = p_chef_id;
    if not found then
      raise exception 'chef_not_found' using errcode = 'P0002';
    end if;
  end if;

  return query
  with fechas as (
    select u.d, u.n::int as n
    from unnest(p_dates) with ordinality as u (d, n)
  ),
  reglas as (
    -- Minutos desde la medianoche (hora de Roma), como en el generador.
    select f.n,
           extract(epoch from r.start_time) / 60 as abre,
           extract(epoch from r.end_time) / 60   as cierra
    from fechas f
    join public.availability_rules r
      on r.chef_id = p_chef_id
     and r.dow = extract(dow from f.d)::int
  ),
  sugeridas as (
    select g.n, min((ceil((g.abre + v_shop) / 30) * 30)::int) as minuto
    from reglas g
    group by g.n
  ),
  evaluadas as (
    select f.n, f.d,
           case when sg.minuto < 1440 then make_time(sg.minuto / 60, sg.minuto % 60, 0) end as sugerida
    from fechas f
    left join sugeridas sg on sg.n = f.n
  )
  select e.n,
         e.d,
         coalesce(p_start, e.sugerida),
         case
           when coalesce(p_start, e.sugerida) is not null and exists (
             select 1
             from public.sessions s
             where s.chef_id = p_chef_id
               and s.status <> 'cancelled'
               and s.id is distinct from p_ignore_session_id
               and not (p_ignore_quote_id is not null and s.quote_id = p_ignore_quote_id and s.status = 'held')
               and s.busy && private.session_busy(e.d, coalesce(p_start, e.sugerida), v_shop, p_cook_minutes, v_gap)
           ) then 'busy'
           when e.d < v_today then 'past'
           when exists (
             select 1
             from public.availability_exceptions x
             where x.chef_id = p_chef_id
               and x.date = e.d
               and x.kind = 'blocked'
           ) then 'blocked'
           when not exists (select 1 from reglas g where g.n = e.n) then 'closed'
           when coalesce(p_start, e.sugerida) is not null and not exists (
             select 1
             from reglas g
             where g.n = e.n
               and extract(epoch from coalesce(p_start, e.sugerida)) / 60 - v_shop >= g.abre
               and extract(epoch from coalesce(p_start, e.sugerida)) / 60 + p_cook_minutes <= g.cierra
           ) then 'outside'
           else 'ok'
         end,
         e.sugerida
  from evaluadas e
  order by e.n;
end
$$;

comment on function private.booking_day_checks(uuid, date[], time, int, uuid, uuid) is
  'Por cada fecha de una reserva (o el destino de un movimiento): llegada evaluada, estado (busy, past, blocked, closed, outside u ok; solo busy impide crear) y llegada sugerida (ceil_a_30(apertura + compra), como el generador). Con p_ignore_session_id usa la compra y el margen de esa sesión y no la cuenta para el choque. Con p_ignore_quote_id, las semanas held de ese presupuesto no cuentan para el choque (confirmar sin presupuesto lo retira).';

revoke all on function private.booking_day_checks(uuid, date[], time, int, uuid, uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 7b. public.chef_create_booking: igual que en 20261116150100_bookings.sql (misma firma), salvo
-- desde un pedido con un presupuesto abierto:
--   * el pedido puede estar new (un borrador) o quoted (ya salió); quoted sin presupuesto abierto
--     sigue siendo request_not_new;
--   * el dryRun no cuenta como ocupadas las semanas held de ese presupuesto;
--   * al confirmar, se retira (private.withdraw_quote: sus semanas held se cancelan con
--     quote_withdrawn) antes de crear las semanas, en la misma transacción.
-- Un reintento (el pedido ya accepted con esas mismas semanas) sigue devolviendo duplicate = true.
-- ---------------------------------------------------------------------
create or replace function public.chef_create_booking(
  p_chef_id             uuid,
  p_dates               date[],
  p_start               time,
  p_cook_minutes        int,
  p_service_total_cents int,
  p_portions            int                 default 0,
  p_groceries_est_cents int                 default 0,
  p_request_id          uuid                default null,
  p_client_id           uuid                default null,
  p_new_client          jsonb               default null,
  p_type                public.request_type default null,
  p_household           jsonb               default null,
  p_locale              text                default null,
  p_request_key         uuid                default null,
  p_dry_run             boolean             default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_today      date := (now() at time zone 'Europe/Rome')::date;
  v_dates      date[];
  v_n          int;
  v_split      int[];
  v_type       public.request_type;
  v_request    public.requests%rowtype;
  v_existing   public.requests%rowtype;
  v_request_id uuid;
  v_client_id  uuid;
  v_quote_id   uuid;
  v_adults     smallint;
  v_kids       smallint;
  v_days       smallint;
  v_meals      text[];
  v_locale     text;
  v_name       text;
  v_constraint text;
begin
  -- Cocinera: la Edge Function la saca del JWT. Sin chef_settings no hay compra ni margen.
  if p_chef_id is null or not exists (select 1 from public.chef_settings s where s.chef_id = p_chef_id) then
    raise exception 'chef_not_found' using errcode = 'P0002';
  end if;

  if num_nonnulls(p_request_id, p_client_id, p_new_client) <> 1 then
    raise exception 'invalid_client'
      using errcode = '22023',
            detail  = 'Una sola de p_request_id, p_client_id o p_new_client.';
  end if;

  -- Fechas: de 1 a 8, a menos de un año de hoy, una por semana ISO y en orden.
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
  if p_service_total_cents is null or p_service_total_cents < 0
     or p_groceries_est_cents is null or p_groceries_est_cents < 0 then
    raise exception 'invalid_cents' using errcode = '22023';
  end if;
  v_split := private.split_cents(p_service_total_cents, v_n);

  if p_request_id is not null then
    -- Desde un pedido. El lock serializa dos confirmaciones del mismo pedido (y una confirmación y
    -- un presupuesto, que chef_create_quote prepara con el mismo lock): la segunda espera y lo
    -- encuentra accepted (reintento) o lo rechaza.
    select r.* into v_request
    from public.requests r
    where r.id = p_request_id
      and r.chef_id = p_chef_id
    for update;
    if not found then
      raise exception 'request_not_found' using errcode = 'P0002';
    end if;
    if v_request.type = 'change' or (p_type is not null and p_type <> v_request.type) then
      raise exception 'invalid_request_type' using errcode = '22023';
    end if;
    v_type       := v_request.type;
    v_request_id := v_request.id;
    v_client_id  := v_request.client_id;
    -- Su presupuesto abierto (a lo sumo uno), en borrador o enviado: se retira al confirmar.
    select q.id into v_quote_id
    from public.quotes q
    where q.request_id = v_request.id and private.quote_open(q);
  else
    if p_type is null or p_type not in ('week', 'extra') then
      raise exception 'invalid_request_type' using errcode = '22023';
    end if;
    v_type := p_type;
  end if;

  if v_n > 1 and v_type <> 'week' then
    raise exception 'weeks_only_for_week' using errcode = '22023';
  end if;

  if p_request_id is null then
    -- El pedido de la reserva a mano: personas, días y comidas (mismos límites que quote.ts).
    if jsonb_typeof(p_household) is distinct from 'object'
       or jsonb_typeof(p_household -> 'adults') is distinct from 'number'
       or jsonb_typeof(p_household -> 'kids')   is distinct from 'number'
       or jsonb_typeof(p_household -> 'days')   is distinct from 'number'
       or jsonb_typeof(p_household -> 'meals')  is distinct from 'array'
       or (p_household ->> 'adults') !~ '^[0-9]{1,2}$'
       or (p_household ->> 'kids')   !~ '^[0-9]{1,2}$'
       or (p_household ->> 'days')   !~ '^[1-7]$'
    then
      raise exception 'invalid_household' using errcode = '22023';
    end if;
    v_adults := (p_household ->> 'adults')::smallint;
    v_kids   := (p_household ->> 'kids')::smallint;
    v_days   := (p_household ->> 'days')::smallint;
    -- Comidas en orden canónico, sin repetir ni valores desconocidos (como submit_public_request).
    v_meals  := array(select m from unnest(array['lunch', 'dinner']) as m where (p_household -> 'meals') ? m);
    if v_adults > 30 or v_kids > 30 or v_adults + v_kids < 1
       or cardinality(v_meals) = 0 or cardinality(v_meals) <> jsonb_array_length(p_household -> 'meals') then
      raise exception 'invalid_household' using errcode = '22023';
    end if;

    v_locale := coalesce(p_locale, 'it');
    if v_locale not in ('it', 'es', 'en') then
      raise exception 'invalid_locale' using errcode = '22023';
    end if;

    if p_client_id is not null then
      select c.id into v_client_id
      from public.clients c
      where c.id = p_client_id
        and c.chef_id = p_chef_id;
      if v_client_id is null then
        raise exception 'client_not_found' using errcode = 'P0002';
      end if;
    else
      if jsonb_typeof(p_new_client) is distinct from 'object' then
        raise exception 'invalid_new_client' using errcode = '22023';
      end if;
      v_name := nullif(btrim(p_new_client ->> 'name'), '');
      if v_name is null then
        raise exception 'name_required' using errcode = '22023';
      end if;
    end if;

    if p_request_key is null and not p_dry_run then
      raise exception 'request_key_required' using errcode = '22023';
    end if;
  end if;

  -- dryRun: los chequeos de cada fecha, sin escribir nada. Las semanas held del presupuesto abierto
  -- del pedido no cuentan como ocupadas: al confirmar se retira.
  if p_dry_run then
    if p_request_id is not null and v_request.status <> 'new'
       and not (v_request.status = 'quoted' and v_quote_id is not null) then
      raise exception 'request_not_new' using errcode = '55000', detail = v_request.status::text;
    end if;
    return jsonb_build_object(
      'dry_run',    true,
      'duplicate',  false,
      'request_id', v_request_id,
      'client_id',  v_client_id,
      'weeks', (
        select jsonb_agg(jsonb_build_object(
                 'date',            c.day,
                 'start_time',      c.start_time,
                 'cook_minutes',    p_cook_minutes,
                 'status',          c.status,
                 'suggested_start', c.suggested_start,
                 'service_cents',   v_split[c.ord],
                 'session_id',      null)
               order by c.ord)
        from private.booking_day_checks(p_chef_id, v_dates, p_start, p_cook_minutes, null, v_quote_id) as c
      )
    );
  end if;

  if p_request_id is not null then
    -- ¿Reintento? El pedido ya está accepted con esas mismas sesiones vivas.
    if v_request.status = 'accepted'
       and (select coalesce(array_agg(s."date" order by s."date"), '{}')
            from public.sessions s
            where s.request_id = v_request.id and s.status <> 'cancelled') = v_dates
       and not exists (
         select 1 from public.sessions s
         where s.request_id = v_request.id and s.status <> 'cancelled' and s.start_time <> p_start
       )
    then
      return private.booking_result(v_request.id, true);
    end if;
    if v_request.status <> 'new' and not (v_request.status = 'quoted' and v_quote_id is not null) then
      raise exception 'request_not_new' using errcode = '55000', detail = v_request.status::text;
    end if;
    -- Confirmar sin presupuesto: el presupuesto abierto se retira antes de crear las semanas, así sus
    -- semanas held no chocan con las nuevas (no_overlap y una por semana).
    if v_quote_id is not null then
      perform private.withdraw_quote(v_quote_id);
    end if;
  else
    -- A mano. La clave es única por cocinera, compartida con los pedidos de la web
    -- (requests_chef_request_key_idx): el mismo lock que submit_public_request, así dos envíos con
    -- la misma clave se hacen de a uno y el segundo encuentra el primero.
    perform pg_advisory_xact_lock(hashtextextended('public_request_key:' || p_chef_id::text || ':' || p_request_key::text, 0));

    select r.* into v_existing
    from public.requests r
    where r.chef_id = p_chef_id
      and r.request_key = p_request_key;
    if found then
      if v_existing.source <> 'app' then
        raise exception 'request_key_conflict' using errcode = '22023';
      end if;
      return private.booking_result(v_existing.id, true);
    end if;

    if p_new_client is not null then
      insert into public.clients (chef_id, display_name, contact_phone, contact_email, zone, address,
                                  adults, kids, pay_mode, status)
      values (
        p_chef_id, v_name,
        nullif(btrim(p_new_client ->> 'phone'), ''),
        lower(nullif(btrim(p_new_client ->> 'email'), '')),
        nullif(btrim(p_new_client ->> 'zone'), ''),
        nullif(btrim(p_new_client ->> 'address'), ''),
        -- El hogar se toma de una reserva semanal; una sesión extra no describe la casa.
        case when v_type = 'week' then v_adults else 1 end,
        case when v_type = 'week' then v_kids else 0 end,
        'manual', 'trial'
      )
      returning id into v_client_id;
    end if;

    insert into public.requests (chef_id, client_id, type, status, adults, kids, days, meals, weeks,
                                 locale, source, seen_at, request_key)
    values (p_chef_id, v_client_id, v_type, 'accepted', v_adults, v_kids, v_days, v_meals, v_n,
            v_locale, 'app', now(), p_request_key)
    returning id into v_request_id;
  end if;

  -- Una sesión confirmed por semana, en orden de fecha: la primera que choca corta todo.
  for i in 1 .. v_n loop
    begin
      insert into public.sessions (chef_id, client_id, request_id, "date", start_time, cook_minutes, portions,
                                   status, pay_mode, service_cents, groceries_est_cents)
      values (p_chef_id, v_client_id, v_request_id, v_dates[i], p_start, p_cook_minutes, p_portions,
              'confirmed', 'manual', v_split[i], p_groceries_est_cents);
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

  if p_request_id is not null then
    update public.requests r
       set status  = 'accepted',
           weeks   = v_n,
           seen_at = coalesce(r.seen_at, now())
     where r.id = v_request_id;
  end if;

  -- La ficha pasa de prospecto a cliente, como «Segna come cliente». Nada más de la ficha cambia.
  update public.clients c
     set status = 'trial'
   where c.id = v_client_id
     and c.status = 'prospect';

  return private.booking_result(v_request_id, false);
end
$$;

comment on function public.chef_create_booking(uuid, date[], time, int, int, int, int, uuid, uuid, jsonb, public.request_type, jsonb, text, uuid, boolean) is
  'Confirma una reserva de 1 a 8 semanas (una sesión confirmed por semana, pay_mode manual, servicio repartido con split_cents) desde un pedido new o a mano (ficha existente o nueva, pedido source app). Desde un pedido con un presupuesto abierto (new con un borrador, o quoted: SPEC 5.8), lo retira antes de crear las semanas (quote_withdrawn) y el dryRun no cuenta sus semanas held. Todo o nada (slot_taken / week_taken con la fecha); reintento idempotente; p_dry_run solo devuelve los chequeos. Solo service_role (Edge Function chef).';

-- ---------------------------------------------------------------------
-- 7c. requests_close_open_quotes
--
-- Si el pedido pasa a un estado que no es new ni quoted por otro camino (Evelyn lo rechaza desde la
-- bandeja), el presupuesto abierto se retira (private.withdraw_quote): sus semanas held se cancelan
-- (quote_withdrawn) y deja de retener el calendario. Confirmar sin presupuesto ya lo retiró antes de
-- crear las semanas (7b); aceptar, rechazar o vencer el presupuesto lo cierran antes de cambiar el
-- pedido: en esos casos acá no encuentran nada.
-- Security definer: el rechazo llega con la sesión de la cocina, que no escribe sesiones.
-- ---------------------------------------------------------------------
create function private.close_open_quotes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quote_id uuid;
begin
  for v_quote_id in
    select q.id from public.quotes q
    where q.request_id = new.id
      and q.accepted_at is null and q.declined_at is null and q.withdrawn_at is null and q.expired_at is null
  loop
    perform private.withdraw_quote(v_quote_id);
  end loop;
  return null;
end
$$;

comment on function private.close_open_quotes() is
  'Trigger de requests: si el pedido pasa a un estado que no es new ni quoted por otro camino (Evelyn lo rechaza desde la bandeja), retira su presupuesto abierto y cancela sus semanas held (quote_withdrawn; private.withdraw_quote). Confirmar sin presupuesto lo retira antes, en chef_create_booking. SPEC 5.8.';

revoke all on function private.close_open_quotes() from public, anon, authenticated, service_role;

create trigger requests_close_open_quotes
  after update of status on public.requests
  for each row
  when (new.status is distinct from old.status and new.status not in ('new', 'quoted'))
  execute function private.close_open_quotes();

-- ---------------------------------------------------------------------
-- 8. Avisos del menú (menu_reminders_due, de 20261121110000_menu_reminders.sql): una semana cuyo
-- último envío llevaba una versión anterior del presupuesto
--
-- Si la semana que llevaba el presupuesto deja de ser la primera (Evelyn la pasa al final con
-- chef_move_session) y Evelyn lo reenvía desde la nueva primera semana, el envío viejo queda como el
-- último de esa semana: salió con términos que ya no valen y la clienta no pudo confirmarlo
-- (quote_pending). Para los avisos esa semana sigue pendiente, como si no hubiera salido, hasta que
-- Evelyn le mande el menú de nuevo o, aceptado el presupuesto, la clienta lo confirme. Todo lo demás,
-- igual.
-- ---------------------------------------------------------------------
create or replace function public.menu_reminders_due(p_chef_id uuid, p_now timestamptz default now())
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with live as (
    select s.*,
           ((s."date" + s.start_time) at time zone 'Europe/Rome') as starts_at,
           row_number() over (partition by s.request_id order by s."date", s.start_time, s.id)::int as week,
           count(*) over (partition by s.request_id)::int as weeks
    from public.sessions s
    where s.chef_id = p_chef_id and s.request_id is not null and s.status <> 'cancelled'
  ),
  pending as (
    select l.*,
           r.first_at, r.last_at, r.overdue_at,
           coalesce(last_send.changes_requested_at is not null, false) as changes_requested
    from live l
    left join private.menu_reminders r on r.session_id = l.id and r.starts_at = l.starts_at
    left join lateral (
      select ms.id, ms.sent_at, ms.changes_requested_at, ms.client_confirmed_at, ms.quote_id
      from public.menu_sends ms
      where ms.session_id = l.id and ms.sent_at is not null
      order by ms.sent_at desc, ms.id desc
      limit 1
    ) last_send on true
    where l.status in ('confirmed', 'shopping_done')
      and l.starts_at > p_now
      and l.starts_at - interval '4 days' <= p_now
      and l.created_at <= p_now - interval '1 hour'
      and (last_send.id is null
           or last_send.changes_requested_at is not null
           -- Llevaba el presupuesto, que después salió en otro envío (desde otra semana), y nadie lo confirmó.
           or (last_send.quote_id is not null and last_send.client_confirmed_at is null
               and exists (select 1 from public.menu_sends o
                           where o.quote_id = last_send.quote_id and o.sent_at is not null
                             and (o.sent_at, o.id) > (last_send.sent_at, last_send.id))))
  ),
  due as (
    select p.*,
           case
             when p_now >= p.starts_at - interval '48 hours' then
               case when p.overdue_at is null or p.overdue_at <= p_now - interval '1 hour 55 minutes' then 'overdue' end
             when p_now >= p.starts_at - interval '72 hours' then
               case when p.last_at is null then 'last' end
             else
               case when p.first_at is null and p.last_at is null then 'first' end
           end as kind
    from pending p
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'sessionId', d.id,
           'requestId', d.request_id,
           'kind', d.kind,
           'date', d."date",
           'start', to_char(d.start_time, 'HH24:MI'),
           'deadline', d.starts_at - interval '48 hours',
           'week', d.week,
           'weeks', d.weeks,
           'clientName', coalesce(nullif(btrim(r.contact ->> 'name'), ''), c.display_name),
           'changesRequested', d.changes_requested)
           order by d.starts_at, d.id), '[]'::jsonb)
  from due d
  join public.clients c on c.id = d.client_id
  join public.requests r on r.id = d.request_id
  where d.kind is not null
    and extract(hour from (p_now at time zone 'Europe/Rome')) between 8 and 20
$$;

comment on function public.menu_reminders_due(uuid, timestamptz) is
  'Las semanas de la cocina con un aviso a Evelyn que toca en p_now para completar el menú (SPEC 5.8): pendientes (sin menú enviado, con cambios pedidos, o con un último envío que llevaba una versión anterior del presupuesto y nadie confirmó), confirmadas, dentro de 4 días, creadas hace más de una hora; «first» 4 días antes, «last» 72 h antes, «overdue» cada 2 horas pasado el límite de 48 h; de 8 a 20:59 en Roma. Solo service_role.';
