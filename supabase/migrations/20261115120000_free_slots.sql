-- =====================================================================
-- Radici · Horarios libres (SPEC §5.2)
-- Tests: supabase/tests/database/07_free_slots.test.sql.
--
--   1. private.session_busy: el rango ocupado de una sesión, con la misma cuenta que la columna
--      generada sessions.busy (el test la compara con todas las sesiones de la base).
--   2. private.free_slot_candidates: el generador común. Toda hora de llegada válida para una
--      cocinera y una duración de cocina, con la regla de choque de no_overlap.
--   3. public.get_free_slots: los horarios que se muestran (hasta 3 por día, separados al
--      menos 2 h, en los primeros 5 días con lugar).
--   4. public.get_free_days: cada fecha del rango pedido, con o sin lugar (calendario de la web).
--
-- Quién las ejecuta: solo service_role. La web no usa una RPC anónima: lee los días con
-- GET <public-request>/availability (Edge Function, con CORS y su propio límite por IP;
-- docs/contracts/public-request.md §11). Las dos funciones públicas son security definer
-- porque el generador vive en el esquema private, fuera de la API: ni service_role tiene USAGE
-- sobre él (lo verifica 04_public_requests). Corren como su dueño solo para poder llamarlo; no
-- hace falta para leer las tablas (service_role ya saltea RLS). search_path vacío y nombres
-- calificados, como las demás security definer de public (00_schema lo exige).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. private.session_busy
-- La expresión de sessions.busy (20261019100000_enums_and_tables.sql), con los minutos como
-- parámetros: [llegada − compra, llegada + cocina + margen), el margen de un solo lado. La
-- aritmética va en UTC (minutos reales aunque el día tenga cambio de hora) y es inmutable: no
-- depende del TimeZone de la conexión. Si algún día cambia esa columna, cambiar esto igual: el
-- test compara las dos en todas las sesiones.
-- ---------------------------------------------------------------------
create function private.session_busy(
  p_date         date,
  p_start        time,
  p_shop_minutes int,
  p_cook_minutes int,
  p_gap_minutes  int
)
returns tstzrange
language sql
immutable
parallel safe
set search_path = ''
as $$
  select tstzrange(
    ((((p_date + p_start) at time zone 'Europe/Rome') at time zone 'UTC')
       - make_interval(mins => p_shop_minutes)) at time zone 'UTC',
    ((((p_date + p_start) at time zone 'Europe/Rome') at time zone 'UTC')
       + make_interval(mins => p_cook_minutes + p_gap_minutes)) at time zone 'UTC',
    '[)'
  )
$$;

comment on function private.session_busy(date, time, int, int, int) is
  'Rango ocupado de una sesión que llega p_start (hora de Roma) el día p_date: [llegada − compra, llegada + cocina + margen). Misma cuenta que la columna generada sessions.busy.';

-- ---------------------------------------------------------------------
-- 2. private.free_slot_candidates: el generador común
--
-- Devuelve cada (día, hora de llegada) válido, en orden:
--   * Ventana: desde mañana en Roma (respecto de p_now) hasta hoy + booking_horizon_days,
--     recortada a [p_from_date, p_from_date + p_days − 1].
--   * Solo días con regla de disponibilidad (dow: 0 = domingo, como extract(dow)) y sin
--     bloqueo (availability_exceptions, kind = 'blocked').
--   * Por cada regla del día: llegadas cada slot_step_minutes desde ceil_a_30(apertura +
--     compra), mientras llegada + cocina <= cierre (SPEC §5.2; el redondeo es a la media hora
--     aunque el paso sea otro). Esa cuenta va en hora local; los cambios de hora son de
--     madrugada, fuera de cualquier horario de trabajo. Varias reglas el mismo día se suman,
--     sin repetir horas.
--   * Aviso mínimo: la compra (llegada − compra) empieza como pronto p_now + min_notice_hours.
--   * Choque, idéntico a no_overlap: el rango de la candidata, armado como sessions.busy con la
--     compra y el margen ACTUALES de la cocinera (los que copiaría el trigger al crearla), no
--     puede superponerse (&&) con el busy guardado de ninguna sesión suya que no esté
--     cancelada. Las held cuentan aunque su hold_until ya haya pasado: no_overlap las sigue
--     protegiendo hasta que el cron las cancele. Así un horario ofrecido nunca lo rechaza la base.
--
-- Valida los datos (22023: invalid_cook_minutes, invalid_days, invalid_from_date, invalid_now;
-- P0002: chef_not_found si no hay chef_settings de esa cocinera). p_now existe para los tests;
-- las funciones públicas no lo exponen y usan now().
-- ---------------------------------------------------------------------
create function private.free_slot_candidates(
  p_chef_id      uuid,
  p_cook_minutes int,
  p_from_date    date,
  p_days         int,
  p_now          timestamptz default now()
)
returns table (day date, start_time time)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_shop    int;
  v_gap     int;
  v_step    int;
  v_horizon int;
  v_notice  int;
  v_today   date;
  v_first   date;
  v_last    date;
begin
  -- El máximo de cocina es el de la Edge Function (AVAILABILITY_MINUTES en _shared/availability.ts).
  if p_cook_minutes is null or p_cook_minutes not between 1 and 720 then
    raise exception 'invalid_cook_minutes' using errcode = '22023';
  end if;
  if p_days is null or p_days not between 1 and 366 then
    raise exception 'invalid_days' using errcode = '22023';
  end if;
  if p_from_date is null or not isfinite(p_from_date) then
    raise exception 'invalid_from_date' using errcode = '22023';
  end if;
  if p_now is null or not isfinite(p_now) then
    raise exception 'invalid_now' using errcode = '22023';
  end if;

  select s.shop_minutes, s.gap_minutes, s.slot_step_minutes, s.booking_horizon_days, s.min_notice_hours
    into v_shop, v_gap, v_step, v_horizon, v_notice
  from public.chef_settings s
  where s.chef_id = p_chef_id;
  if not found then
    raise exception 'chef_not_found' using errcode = 'P0002';
  end if;

  v_today := (p_now at time zone 'Europe/Rome')::date;
  v_first := greatest(p_from_date, v_today + 1);
  if v_first > v_today + v_horizon then
    return;  -- todo el rango pedido queda después del horizonte
  end if;
  v_last := least(p_from_date + (p_days - 1), v_today + v_horizon);

  return query
  with dias as (
    select v_first + i as dia
    from generate_series(0, v_last - v_first) as i
    where not exists (
      select 1
      from public.availability_exceptions e
      where e.chef_id = p_chef_id
        and e.date = v_first + i
        and e.kind = 'blocked'
    )
  ),
  llegadas as (
    -- Minutos desde la medianoche (hora de Roma). Una regla con segundos redondea hacia adentro.
    select d.dia, m.minuto
    from dias d
    join public.availability_rules r
      on r.chef_id = p_chef_id
     and r.dow = extract(dow from d.dia)::int
    cross join lateral generate_series(
      (ceil((extract(epoch from r.start_time) / 60 + v_shop) / 30) * 30)::int,
      floor(extract(epoch from r.end_time) / 60 - p_cook_minutes)::int,
      v_step
    ) as m(minuto)
  ),
  candidatas as (
    select distinct l.dia, make_time(l.minuto / 60, l.minuto % 60, 0) as llegada
    from llegadas l
  ),
  rangos as (
    select c.dia, c.llegada,
           private.session_busy(c.dia, c.llegada, v_shop, p_cook_minutes, v_gap) as busy
    from candidatas c
  )
  select r.dia, r.llegada
  from rangos r
  where lower(r.busy) >= p_now + make_interval(hours => v_notice)
    and not exists (
      select 1
      from public.sessions s
      where s.chef_id = p_chef_id
        and s.status <> 'cancelled'
        and s.busy && r.busy
    )
  order by r.dia, r.llegada;
end
$$;

comment on function private.free_slot_candidates(uuid, int, date, int, timestamptz) is
  'Generador de horarios libres (SPEC §5.2): cada (día, hora de llegada en Roma) válido para p_cook_minutes de cocina, de mañana a hoy + booking_horizon_days, con aviso mínimo, reglas, bloqueos y la regla de choque de no_overlap. Lo usan get_free_slots y get_free_days.';

-- ---------------------------------------------------------------------
-- 3. public.get_free_slots: los horarios que se muestran
-- De las candidatas, en orden: hasta 3 por día, cada uno al menos 2 h después del anterior
-- mostrado (se toma el primero que cumple), en los primeros 5 días con lugar.
-- ---------------------------------------------------------------------
create function public.get_free_slots(
  p_chef_id      uuid,
  p_cook_minutes int,
  p_from_date    date,
  p_days         int
)
returns table (day date, start_time time)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_slot  record;
  v_day   date;
  v_last  time;
  v_shown int := 0;  -- horarios mostrados del día actual
  v_days  int := 0;  -- días con lugar mostrados
begin
  for v_slot in
    select c.day, c.start_time
    from private.free_slot_candidates(p_chef_id, p_cook_minutes, p_from_date, p_days) as c
    order by c.day, c.start_time
  loop
    if v_slot.day is distinct from v_day then
      exit when v_days = 5;
      v_day   := v_slot.day;
      v_days  := v_days + 1;
      v_shown := 0;
      v_last  := null;
    end if;
    -- time − time es un intervalo (no da la vuelta a la medianoche).
    if v_shown < 3 and (v_last is null or v_slot.start_time - v_last >= interval '2 hours') then
      day        := v_slot.day;
      start_time := v_slot.start_time;
      return next;
      v_shown := v_shown + 1;
      v_last  := v_slot.start_time;
    end if;
  end loop;
end
$$;

comment on function public.get_free_slots(uuid, int, date, int) is
  'Horarios libres para mostrar (SPEC §5.2): hasta 3 por día separados al menos 2 h, en los primeros 5 días con lugar. start_time es la hora de llegada a la casa (Roma). Solo service role.';

-- ---------------------------------------------------------------------
-- 4. public.get_free_days: cada fecha del rango, con o sin lugar
-- available = hay al menos una candidata ese día. Las fechas fuera de la ventana (hoy, el
-- pasado, después del horizonte) salen con available = false.
-- ---------------------------------------------------------------------
create function public.get_free_days(
  p_chef_id      uuid,
  p_cook_minutes int,
  p_from_date    date,
  p_days         int
)
returns table (day date, available boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_free date[];
begin
  -- Primero el generador: valida los datos y falla antes de devolver nada.
  v_free := array(
    select distinct c.day
    from private.free_slot_candidates(p_chef_id, p_cook_minutes, p_from_date, p_days) as c
  );

  return query
  select p_from_date + i, (p_from_date + i) = any (v_free)
  from generate_series(0, p_days - 1) as i
  order by 1;
end
$$;

comment on function public.get_free_days(uuid, int, date, int) is
  'Calendario de la web: cada fecha de [p_from_date, p_from_date + p_days − 1] con available = true si hay al menos un horario libre para p_cook_minutes (SPEC §5.2). Solo service role: la web lo lee por la Edge Function public-request (GET …/availability).';

-- ---------------------------------------------------------------------
-- Privilegios: solo la service role ejecuta las públicas (Supabase da EXECUTE a anon y
-- authenticated por defecto en public); las de private, nadie de la API.
-- ---------------------------------------------------------------------
revoke all on function private.session_busy(date, time, int, int, int)                 from public, anon, authenticated, service_role;
revoke all on function private.free_slot_candidates(uuid, int, date, int, timestamptz)  from public, anon, authenticated, service_role;
revoke all on function public.get_free_slots(uuid, int, date, int)                      from public, anon, authenticated;
revoke all on function public.get_free_days(uuid, int, date, int)                       from public, anon, authenticated;
grant execute on function public.get_free_slots(uuid, int, date, int) to service_role;
grant execute on function public.get_free_days(uuid, int, date, int)  to service_role;
