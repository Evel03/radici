-- =====================================================================
-- Radici · Reservas (2 de 2): base de datos
-- Plan del área de Evelyn, PR 3. Tests: supabase/tests/database/13_bookings.test.sql.
--
-- Decisiones del dueño del 16/11/2026: una reserva es de 1 a 8 semanas, con una sesión de cocina
-- por semana; en Fase 0 las reservas ya crean sesiones reales y la web descuenta esos días
-- (get_free_days ya cuenta toda sesión que no esté cancelada); el precio del servicio lo fija
-- Evelyn al confirmar; la compra va aparte, al costo del ticket; el cobro es manual.
--
-- Una reserva es un pedido aceptado: sus semanas son las sesiones con ese request_id (la FK y el
-- índice ya existen). No hay tabla nueva. Hasta M4 las reservas nacen confirmed, sin presupuesto
-- ni retención de 48 h, igual que hoy por WhatsApp.
--
--   1. requests y clients: la app ya no borra pedidos ni fichas (borrar una ficha se llevaba en
--      cascada su reserva). requests.weeks ya existe (20261116120000_weekly_pricing.sql) y una
--      reserva la reescribe con las semanas que se crearon.
--   2. sessions: shopping_done_at, cooked_at, week_start (generada) y una sesión viva por semana de
--      cada pedido (índice único sessions_una_por_semana).
--   3. sessions_guard_update: solo las transiciones de estado válidas, y fecha, hora y duración
--      solo en held o confirmed. Corre en UPDATE para todos los roles (también service_role y
--      postgres); no toca INSERT, porque el seed y los tests 02 y 07 insertan sesiones cooked o paid.
--   4. Helpers en private: split_cents, booking_day_checks y booking_result.
--   5. public.chef_create_booking, public.chef_move_session y public.chef_cancel_sessions: security
--      definer con search_path vacío; solo las ejecuta service_role. Las llama la Edge Function chef
--      (PR 4), que valida el JWT, busca la cocinera por chefs.profile_id y pasa su chef_id.
--
-- Errores (mensaje = identificador estable; la Edge Function los traduce):
--   22023 datos inválidos (400) · P0002 no encontrado (404) ·
--   55000 el estado no lo permite (409: invalid_transition, session_not_movable, request_not_new,
--         has_payments) ·
--   23P01 slot_taken y 23505 week_taken (409), con detail = la fecha que choca (AAAA-MM-DD).
-- Ninguna de estas funciones escribe en el log: nada de nombres, teléfonos, direcciones ni notas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. requests y clients: la app ya no borra pedidos ni fichas
-- 20261019130000_api_grants.sql le daba delete sobre las dos tablas a authenticated y la app nunca
-- lo usó. Un pedido aceptado es el registro de su reserva: se borra solo desde el servidor (la
-- purga de prospectos, que no alcanza a un pedido aceptado, y el SQL editor, contrato
-- public-request §10.2). Borrar una ficha se llevaba en cascada sus pedidos, sus sesiones y sus
-- consentimientos (las FK hacia clients son on delete cascade, y la cascada no pasa por estos
-- privilegios ni por la guarda de sesiones): una reserva entera desaparecía y sus días volvían a la
-- web. El borrado de una persona también queda del lado del servidor (la purga, el SQL editor y,
-- desde M2, la supresión de la cuenta). Las políticas "la cocinera gestiona los suyos" (for all)
-- no cambian: sin el privilegio, el delete falla antes de llegar a RLS. La app sigue leyendo sus
-- fichas y cambiando su estado («Segna come cliente»).
-- ---------------------------------------------------------------------
revoke delete on public.requests from authenticated;
revoke delete on public.clients  from authenticated;

-- ---------------------------------------------------------------------
-- 2. sessions: columnas nuevas y una sesión por semana
-- ---------------------------------------------------------------------
alter table public.sessions
  add column shopping_done_at timestamptz,
  add column cooked_at        timestamptz,
  -- Lunes de la semana ISO de la sesión. date_trunc sobre timestamp sin zona es inmutable y no
  -- depende del TimeZone de la conexión.
  add column week_start       date generated always as (date_trunc('week', "date"::timestamp)::date) stored;

comment on column public.sessions.shopping_done_at is
  'Cuándo se cargó la compra (la sesión pasó a shopping_done). Lo escribe el servidor (tickets, PR 9).';
comment on column public.sessions.cooked_at is
  'Cuándo Evelyn marcó «Cociné» (la sesión pasó a cooked). Lo escribe el servidor (PR 10).';
comment on column public.sessions.week_start is
  'Lunes de la semana ISO de date (columna generada). Una reserva tiene como máximo una sesión viva por semana (sessions_una_por_semana).';

-- Una reserva es de una sesión por semana: dos sesiones vivas del mismo pedido no caen en la misma
-- semana ISO. Las canceladas no cuentan (cancelar una semana la libera) y las sesiones sin pedido
-- tampoco.
create unique index sessions_una_por_semana on public.sessions (request_id, week_start)
  where request_id is not null and status <> 'cancelled';

-- ---------------------------------------------------------------------
-- 3. sessions_guard_update: transiciones de estado y fecha, hora y duración
--
--   held          → confirmed, cancelled
--   confirmed     → shopping_done, cooked, cancelled   (se puede marcar «Cociné» sin el ticket)
--   shopping_done → cooked, cancelled
--   cooked        → paid, confirmed, shopping_done     (volver atrás es deshacer «Cociné»)
--   paid          → cooked                             (solo al anular un cobro, PR 10)
--   cancelled     → nada
--
-- Fecha, hora de llegada, minutos de cocina, de compra y de margen (todo lo que arma busy) cambian
-- solo si la sesión estaba held o confirmed. El resto de las columnas no se vigila acá.
-- Corre para todos los roles: ni service_role ni postgres se la saltean. No corre en INSERT.
-- ---------------------------------------------------------------------
create function public.sessions_guard_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status is distinct from old.status
     and not (
          (old.status = 'held'          and new.status in ('confirmed', 'cancelled'))
       or (old.status = 'confirmed'     and new.status in ('shopping_done', 'cooked', 'cancelled'))
       or (old.status = 'shopping_done' and new.status in ('cooked', 'cancelled'))
       or (old.status = 'cooked'        and new.status in ('paid', 'confirmed', 'shopping_done'))
       or (old.status = 'paid'          and new.status = 'cooked')
     )
  then
    raise exception 'invalid_transition'
      using errcode = '55000',
            detail  = format('Una sesión no pasa de %s a %s.', old.status, new.status);
  end if;

  if old.status not in ('held', 'confirmed')
     and (new."date"       is distinct from old."date"
       or new.start_time   is distinct from old.start_time
       or new.cook_minutes is distinct from old.cook_minutes
       or new.shop_minutes is distinct from old.shop_minutes
       or new.gap_minutes  is distinct from old.gap_minutes)
  then
    raise exception 'session_not_movable'
      using errcode = '55000',
            detail  = format('Una sesión %s no cambia de fecha, hora ni duración.', old.status);
  end if;

  return new;
end
$$;

create trigger sessions_guard_update
  before update on public.sessions
  for each row execute function public.sessions_guard_update();

-- ---------------------------------------------------------------------
-- 4a. private.split_cents: reparte un total en partes iguales, en centavos
-- Los centavos que sobran van de a uno a las primeras partes: 50000 en 3 son 16667 + 16667 +
-- 16666; 56000 en 4, 4 × 14000. La suma siempre es el total.
-- ---------------------------------------------------------------------
create function private.split_cents(p_total int, p_parts int)
returns int[]
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
begin
  if p_total is null or p_total < 0 then
    raise exception 'invalid_cents' using errcode = '22023';
  end if;
  if p_parts is null or p_parts not between 1 and 100 then
    raise exception 'invalid_parts' using errcode = '22023';
  end if;

  return array(
    select p_total / p_parts + case when i <= p_total % p_parts then 1 else 0 end
    from generate_series(1, p_parts) as i
    order by i
  );
end
$$;

comment on function private.split_cents(int, int) is
  'Reparte p_total centavos en p_parts partes (1 a 100) que difieren como mucho en 1: los que sobran van a las primeras. La suma es el total.';

-- ---------------------------------------------------------------------
-- 4b. private.booking_day_checks: cómo queda cada fecha de una reserva o de un movimiento
--
-- Devuelve, por fecha (ord = su posición en p_dates), la llegada evaluada, un estado y la llegada
-- sugerida. La sugerida es ceil_a_30(apertura + compra) de la primera regla del día, la misma
-- primera llegada que ofrece el generador (private.free_slot_candidates); null si el día no tiene
-- regla. Sin p_start (solo en un dryRun) se evalúa cada fecha con su sugerida.
--
-- Estado, en este orden de prioridad:
--   busy     choca con otra sesión no cancelada: la misma cuenta que no_overlap (private.session_busy
--            contra sessions.busy), con la compra y el margen que va a tener la sesión.  Impide crear.
--   past     la fecha es anterior a hoy en Roma (se puede cargar lo ya hecho en Fase 0).  Aviso.
--   blocked  día bloqueado (puede ser justo el que Evelyn bloqueó por la sesión acordada). Aviso.
--   closed   ese día de la semana no tiene regla de horario.                              Aviso.
--   outside  la compra empieza antes de la apertura o la cocina termina después del cierre de
--            todas las reglas del día (un evento puede caer fuera de horario).            Aviso.
--   ok
--
-- Compra y margen: los actuales de chef_settings, los que va a copiar el trigger
-- sessions_fill_minutes al crear la sesión. Con p_ignore_session_id (mover una sesión), los que esa
-- sesión ya tiene guardados (mover no los cambia), y esa sesión no cuenta para el choque.
-- No toca el generador ni sus pruebas (07_free_slots).
-- ---------------------------------------------------------------------
create function private.booking_day_checks(
  p_chef_id           uuid,
  p_dates             date[],
  p_start             time,
  p_cook_minutes      int,
  p_ignore_session_id uuid default null
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

comment on function private.booking_day_checks(uuid, date[], time, int, uuid) is
  'Por cada fecha de una reserva (o el destino de un movimiento): llegada evaluada, estado (busy, past, blocked, closed, outside u ok; solo busy impide crear) y llegada sugerida (ceil_a_30(apertura + compra), como el generador). Con p_ignore_session_id usa la compra y el margen de esa sesión y no la cuenta para el choque.';

-- ---------------------------------------------------------------------
-- 4c. private.booking_result: la respuesta de una reserva ya guardada
-- La misma para la creación y para un reintento (duplicate = true): el pedido, la clienta y sus
-- sesiones vivas en orden de fecha, cada una con su estado (calculado sin contarse a sí misma).
-- ---------------------------------------------------------------------
create function private.booking_result(p_request_id uuid, p_duplicate boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'dry_run',    false,
    'duplicate',  p_duplicate,
    'request_id', r.id,
    'client_id',  r.client_id,
    'weeks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'date',            s."date",
               'start_time',      s.start_time,
               'cook_minutes',    s.cook_minutes,
               'status',          c.status,
               'suggested_start', c.suggested_start,
               'service_cents',   s.service_cents,
               'session_id',      s.id)
             order by s."date")
      from public.sessions s
      cross join lateral private.booking_day_checks(s.chef_id, array[s."date"], s.start_time, s.cook_minutes, s.id) as c
      where s.request_id = r.id
        and s.status <> 'cancelled'
    ), '[]'::jsonb)
  )
  from public.requests r
  where r.id = p_request_id
$$;

comment on function private.booking_result(uuid, boolean) is
  'Respuesta de chef_create_booking para una reserva guardada: {dry_run, duplicate, request_id, client_id, weeks: [{date, start_time, cook_minutes, status, suggested_start, service_cents, session_id}]}.';

-- ---------------------------------------------------------------------
-- 5a. public.chef_create_booking: confirmar una reserva de 1 a 8 semanas
--
-- La clienta, una sola de estas:
--   p_request_id  desde un pedido (el caso de la bandeja). Lo bloquea (for update) y exige que
--                 esté en new. Si ya está accepted con esas mismas sesiones vivas (mismas fechas y
--                 hora), es un reintento: devuelve lo mismo con duplicate = true. Crea las sesiones,
--                 pasa el pedido a accepted con weeks y seen_at, y la ficha de prospect a trial.
--                 El tipo es el del pedido; p_household, p_locale y p_request_key no se usan.
--   p_client_id   una ficha que ya existe (reserva a mano: clienta por WhatsApp, «Renovar»).
--   p_new_client  una ficha nueva: {name, phone, email, zone, address}; nace en trial, con
--                 pay_mode manual. Sin restricciones: falta su consentimiento de salud (M2).
--   A mano: p_type ('week' o 'extra'), p_household {adults, kids, days, meals} (el check
--   requests_datos_de_presupuesto los exige; de una ficha nueva y semanal sale también su hogar),
--   p_locale (it, es, en; it por defecto) y p_request_key, obligatoria salvo en el dryRun: único
--   por cocinera (requests_chef_request_key_idx), hace idempotente el reintento. Crea el pedido
--   (source 'app', accepted, con seen_at) y las sesiones. Una ficha existente no se modifica,
--   salvo el paso de prospect a trial (como desde un pedido y «Segna come cliente»).
--
-- Semanas: p_dates, de 1 a 8 fechas, una por semana ISO y en orden, a menos de un año de hoy (las
-- pasadas valen: cargar lo ya hecho en Fase 0). Más de una solo en un pedido semanal (M3b: un
-- evento, una sola). Cada semana es una sesión confirmed con pay_mode 'manual', llegada p_start,
-- p_cook_minutes de cocina (1 a 720), p_portions, p_groceries_est_cents (la compra estimada de cada
-- semana) y su parte de p_service_total_cents (el precio del servicio de toda la reserva, que fija
-- Evelyn, repartido con split_cents). La compra y el margen los copia sessions_fill_minutes de
-- chef_settings.
-- p_service_total_cents no tiene valor por defecto: ninguna ruta cambia después el servicio de una
-- sesión, así que una reserva no se crea sin precio por olvido. 0 vale (sin cargo); null es
-- invalid_cents, también en el dryRun.
--
-- p_dry_run: valida todo y devuelve el estado de cada fecha (booking_day_checks) sin escribir nada;
-- ahí p_start puede faltar (cada fecha se evalúa con su llegada sugerida).
--
-- Todo o nada: si una semana choca, no se crea ninguna. 23P01 slot_taken (no_overlap) o 23505
-- week_taken (sessions_una_por_semana), con detail = la fecha.
-- Devuelve {dry_run, duplicate, request_id, client_id, weeks: [...]} (private.booking_result).
-- ---------------------------------------------------------------------
create function public.chef_create_booking(
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
    -- Desde un pedido. El lock serializa dos confirmaciones del mismo pedido: la segunda espera y
    -- lo encuentra accepted (reintento) o lo rechaza.
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

  -- dryRun: los chequeos de cada fecha, sin escribir nada.
  if p_dry_run then
    if p_request_id is not null and v_request.status <> 'new' then
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
        from private.booking_day_checks(p_chef_id, v_dates, p_start, p_cook_minutes) as c
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
    if v_request.status <> 'new' then
      raise exception 'request_not_new' using errcode = '55000', detail = v_request.status::text;
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
  'Confirma una reserva de 1 a 8 semanas (una sesión confirmed por semana, pay_mode manual, servicio repartido con split_cents) desde un pedido new o a mano (ficha existente o nueva, pedido source app). Todo o nada (slot_taken / week_taken con la fecha); reintento idempotente; p_dry_run solo devuelve los chequeos. Solo service_role (Edge Function chef).';

-- ---------------------------------------------------------------------
-- 5b. public.chef_move_session: mover una semana
-- Solo una sesión held o confirmed (session_not_movable). p_start y p_cook_minutes en null dejan
-- los que tiene; la compra y el margen guardados no cambian. Una semana que ya tiene otra sesión
-- viva de la misma reserva da 23505 week_taken (la app ofrece pasarla al final); un horario
-- ocupado, 23P01 slot_taken; los dos con detail = la fecha. p_dry_run no escribe nada.
-- Devuelve {dry_run, session_id, request_id, date, start_time, cook_minutes, status,
-- suggested_start, week_taken}: status y suggested_start como en booking_day_checks (sin contar
-- la sesión misma), week_taken si esa semana ya tiene otra sesión viva de la reserva.
-- ---------------------------------------------------------------------
create function public.chef_move_session(
  p_chef_id      uuid,
  p_session_id   uuid,
  p_date         date,
  p_start        time    default null,
  p_cook_minutes int     default null,
  p_dry_run      boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_today      date := (now() at time zone 'Europe/Rome')::date;
  v_session    public.sessions%rowtype;
  v_start      time;
  v_cook       int;
  v_status     text;
  v_suggested  time;
  v_week_taken boolean;
  v_constraint text;
begin
  if p_chef_id is null or not exists (select 1 from public.chefs c where c.id = p_chef_id) then
    raise exception 'chef_not_found' using errcode = 'P0002';
  end if;
  if p_date is null or not isfinite(p_date) or p_date not between v_today - 366 and v_today + 366 then
    raise exception 'invalid_date' using errcode = '22023';
  end if;
  if p_cook_minutes is not null and p_cook_minutes not between 1 and 720 then
    raise exception 'invalid_cook_minutes' using errcode = '22023';
  end if;

  select s.* into v_session
  from public.sessions s
  where s.id = p_session_id
    and s.chef_id = p_chef_id
  for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if v_session.status not in ('held', 'confirmed') then
    raise exception 'session_not_movable' using errcode = '55000', detail = v_session.status::text;
  end if;

  v_start := coalesce(p_start, v_session.start_time);
  v_cook  := coalesce(p_cook_minutes, v_session.cook_minutes);

  if not p_dry_run then
    begin
      update public.sessions s
         set "date"       = p_date,
             start_time   = v_start,
             cook_minutes = v_cook
       where s.id = v_session.id;
    exception
      when exclusion_violation then
        raise exception 'slot_taken' using errcode = '23P01', detail = to_char(p_date, 'YYYY-MM-DD');
      when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint = 'sessions_una_por_semana' then
          raise exception 'week_taken' using errcode = '23505', detail = to_char(p_date, 'YYYY-MM-DD');
        end if;
        raise;
    end;
  end if;

  select c.status, c.suggested_start
    into v_status, v_suggested
  from private.booking_day_checks(p_chef_id, array[p_date], v_start, v_cook, v_session.id) as c;

  v_week_taken := v_session.request_id is not null and exists (
    select 1
    from public.sessions o
    where o.request_id = v_session.request_id
      and o.id <> v_session.id
      and o.status <> 'cancelled'
      and o.week_start = date_trunc('week', p_date::timestamp)::date
  );

  return jsonb_build_object(
    'dry_run',         p_dry_run,
    'session_id',      v_session.id,
    'request_id',      v_session.request_id,
    'date',            p_date,
    'start_time',      v_start,
    'cook_minutes',    v_cook,
    'status',          v_status,
    'suggested_start', v_suggested,
    'week_taken',      v_week_taken
  );
end
$$;

comment on function public.chef_move_session(uuid, uuid, date, time, int, boolean) is
  'Mueve una sesión held o confirmed a otra fecha (y hora o duración). week_taken si esa semana ya tiene otra sesión viva de la reserva, slot_taken si choca; los dos con la fecha. p_dry_run solo devuelve el chequeo. Solo service_role (Edge Function chef).';

-- ---------------------------------------------------------------------
-- 5c. public.chef_cancel_sessions: cancelar una o varias semanas
-- Pasa a cancelled las held, confirmed y shopping_done (con cancelled_at y cancel_reason, y sin
-- hold_until). Todo o nada: si alguna está cooked o paid, invalid_transition y no cancela ninguna.
-- Las ya canceladas no cambian (un reintento no falla).
-- p_reason es uno de estos códigos, nunca texto libre (el cliente puede leer su sesión, y los de
-- otros caminos, como hold_expired o declined, no se escriben desde acá): chef_cancelled (por
-- defecto), client_cancelled (lo pidió la clienta) o chef_unavailable (Evelyn no puede ir).
-- Semanas ya cobradas (algún pago succeeded que no es devolución): una cancelada no se mueve ni se
-- reactiva, así que, sin p_allow_with_payments, has_payments (55000, detail = sus ids separados por
-- coma) y no cancela ninguna. La app ofrece primero pasarla al final de la reserva
-- (chef_move_session) y cancela con p_allow_with_payments solo para registrar la devolución
-- (decisión 5 del plan; los cobros manuales llegan en el PR 10).
-- Devuelve {cancelled, already_cancelled, with_payments, had_payments}: with_payments son las de
-- la lista que tienen algún cobro (canceladas ahora o antes), las que esperan su devolución.
-- ---------------------------------------------------------------------
create function public.chef_cancel_sessions(
  p_chef_id             uuid,
  p_session_ids         uuid[],
  p_reason              text    default 'chef_cancelled',
  p_allow_with_payments boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_ids       uuid[];
  v_found     int;
  v_blocked   uuid;
  v_with_paid text;
  v_already   uuid[];
  v_cancelled uuid[];
  v_paid      uuid[];
begin
  if p_chef_id is null or not exists (select 1 from public.chefs c where c.id = p_chef_id) then
    raise exception 'chef_not_found' using errcode = 'P0002';
  end if;
  if p_session_ids is null or cardinality(p_session_ids) not between 1 and 100
     or exists (select 1 from unnest(p_session_ids) as u (id) where u.id is null) then
    raise exception 'invalid_sessions' using errcode = '22023';
  end if;
  if p_reason is null or p_reason not in ('chef_cancelled', 'client_cancelled', 'chef_unavailable') then
    raise exception 'invalid_reason' using errcode = '22023';
  end if;

  v_ids := array(select distinct u.id from unnest(p_session_ids) as u (id) order by u.id);

  -- Bloquea las sesiones en orden de id: dos cancelaciones simultáneas no se trancan.
  perform 1
  from public.sessions s
  where s.id = any (v_ids)
    and s.chef_id = p_chef_id
  order by s.id
  for update;

  select count(*) into v_found
  from public.sessions s
  where s.id = any (v_ids)
    and s.chef_id = p_chef_id;
  if v_found <> cardinality(v_ids) then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;

  select s.id into v_blocked
  from public.sessions s
  where s.id = any (v_ids)
    and s.status in ('cooked', 'paid')
  order by s.id
  limit 1;
  if v_blocked is not null then
    raise exception 'invalid_transition' using errcode = '55000', detail = v_blocked::text;
  end if;

  -- Cobros: los pagos succeeded que no son devoluciones (un pendiente todavía no es plata cobrada).
  v_paid := array(
    select distinct p.session_id
    from public.payments p
    where p.session_id = any (v_ids)
      and p.status = 'succeeded'
      and p.kind <> 'refund'
    order by p.session_id
  );

  -- Una semana cobrada que todavía se podía pasar al final de la reserva: solo con el permiso.
  if not coalesce(p_allow_with_payments, false) then
    select string_agg(s.id::text, ',' order by s.id) into v_with_paid
    from public.sessions s
    where s.id = any (v_paid)
      and s.status in ('held', 'confirmed', 'shopping_done');
    if v_with_paid is not null then
      raise exception 'has_payments' using errcode = '55000', detail = v_with_paid;
    end if;
  end if;

  v_already := array(
    select s.id from public.sessions s
    where s.id = any (v_ids) and s.status = 'cancelled'
    order by s.id
  );

  with canceladas as (
    update public.sessions s
       set status        = 'cancelled',
           hold_until    = null,
           cancelled_at  = now(),
           cancel_reason = p_reason
     where s.id = any (v_ids)
       and s.status in ('held', 'confirmed', 'shopping_done')
    returning s.id
  )
  select coalesce(array_agg(c.id order by c.id), '{}') into v_cancelled
  from canceladas c;

  return jsonb_build_object(
    'cancelled',         to_jsonb(v_cancelled),
    'already_cancelled', to_jsonb(v_already),
    'with_payments',     to_jsonb(v_paid),
    'had_payments',      cardinality(v_paid) > 0
  );
end
$$;

comment on function public.chef_cancel_sessions(uuid, uuid[], text, boolean) is
  'Cancela sesiones held, confirmed o shopping_done (todo o nada; las ya canceladas no cambian). Una semana ya cobrada solo con p_allow_with_payments (si no, has_payments con sus ids). p_reason: chef_cancelled, client_cancelled o chef_unavailable. Devuelve {cancelled, already_cancelled, with_payments, had_payments}. Solo service_role (Edge Function chef).';

-- ---------------------------------------------------------------------
-- 6. Privilegios
-- Las de public, solo service_role (Supabase da EXECUTE a anon y authenticated por defecto en
-- public). Las de private, ningún rol de la API (ni service_role tiene USAGE sobre private): las
-- usan las de public, que corren como su dueño. La guarda es un trigger: nadie la llama directo.
-- ---------------------------------------------------------------------
revoke all on function private.split_cents(int, int)                               from public, anon, authenticated, service_role;
revoke all on function private.booking_day_checks(uuid, date[], time, int, uuid)   from public, anon, authenticated, service_role;
revoke all on function private.booking_result(uuid, boolean)                       from public, anon, authenticated, service_role;
revoke all on function public.sessions_guard_update()                              from public, anon, authenticated;

revoke all on function public.chef_create_booking(uuid, date[], time, int, int, int, int, uuid, uuid, jsonb, public.request_type, jsonb, text, uuid, boolean)
  from public, anon, authenticated;
revoke all on function public.chef_move_session(uuid, uuid, date, time, int, boolean)  from public, anon, authenticated;
revoke all on function public.chef_cancel_sessions(uuid, uuid[], text, boolean)        from public, anon, authenticated;
grant execute on function public.chef_create_booking(uuid, date[], time, int, int, int, int, uuid, uuid, jsonb, public.request_type, jsonb, text, uuid, boolean)
  to service_role;
grant execute on function public.chef_move_session(uuid, uuid, date, time, int, boolean)  to service_role;
grant execute on function public.chef_cancel_sessions(uuid, uuid[], text, boolean)        to service_role;
