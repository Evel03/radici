-- =====================================================================
-- Mestolo · Pedido desde la web, bandeja de Evelyn y notificaciones
-- Contrato: docs/contracts/public-request.md §3 (aprobado el 19/10/2026).
--
--   1. requests: franja, idioma, WhatsApp, estimación, origen y "visto".
--   2. Privilegios: desde la app solo se cambian seen_at y status, y el alta
--      no puede traer estimación, origen ni "visto".
--   3. Registro de intentos por IP (hash, nunca la IP) en el esquema private.
--   4. Funciones para la Edge Function public-request y para el arranque:
--      submit_public_request, hit_public_request_rate, promote_to_chef.
--      Todas security definer + search_path vacío; solo las ejecuta la
--      service role (Edge Function y SQL editor).
--   5. requests en la publicación supabase_realtime (aviso en vivo en la app).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. requests: columnas nuevas
-- ---------------------------------------------------------------------
alter table public.requests
  add column preferred_slot  text
    constraint requests_franja_valida check (preferred_slot in ('morning', 'afternoon', 'any')),
  add column locale          text not null default 'it'
    constraint requests_locale_valido check (locale in ('it', 'es', 'en')),
  add column whatsapp_opt_in boolean not null default false,
  add column estimate        jsonb
    constraint requests_estimacion_es_objeto check (estimate is null or jsonb_typeof(estimate) = 'object'),
  add column source          text not null default 'app'
    constraint requests_origen_valido check (source in ('web', 'app')),
  add column seen_at         timestamptz;

comment on column public.requests.preferred_slot  is 'Franja preferida: morning, afternoon o any.';
comment on column public.requests.locale          is 'Idioma del cliente (it, es, en): emails y WhatsApp.';
comment on column public.requests.whatsapp_opt_in is 'El cliente aceptó recibir la confirmación también por WhatsApp.';
comment on column public.requests.estimate        is 'Resultado de calcQuote (quote.ts, camelCase) con las tarifas de chef_settings al crear el pedido, más "pricing" con esas tarifas. Lo escribe el servidor.';
comment on column public.requests.source          is 'Origen del pedido: web (formulario público vía Edge Function) o app.';
comment on column public.requests.seen_at         is 'Cuándo lo abrió la cocinera; null = nuevo en la bandeja.';
comment on column public.requests.restrictions    is 'Copia de las restricciones al pedir: {"allergens": [...], "diets": [...], "note": "..."}. Dato de salud: solo con consentimiento health_data; si no, null.';

-- Agenda de la cocinera: pedidos por fecha preferida.
create index requests_chef_preferred_date_idx on public.requests (chef_id, preferred_date)
  where preferred_date is not null;

-- Reutilización de prospectos por email, sin distinguir mayúsculas.
create index clients_prospect_email_idx on public.clients (chef_id, lower(contact_email))
  where status = 'prospect';

-- ---------------------------------------------------------------------
-- 2. Privilegios de la app sobre requests
-- ---------------------------------------------------------------------
-- La cocinera, desde la app, solo marca visto y cambia el estado (contrato §3).
-- Restricciones, estimación y origen no se tocan. El cliente no tiene política
-- de update, así que no actualiza nada.
revoke update on public.requests from authenticated;
grant update (status, seen_at) on public.requests to authenticated;

-- Alta desde la app: sin estimación (la calcula el servidor con las tarifas),
-- sin origen (siempre 'app'), sin "visto" y sin antedatar created_at.
revoke insert on public.requests from authenticated;
grant insert (id, chef_id, client_id, type, status, adults, kids, days, meals, restrictions, wishes, notes,
              preferred_date, preferred_start, pay_mode, target_session_id, text,
              preferred_slot, locale, whatsapp_opt_in)
  on public.requests to authenticated;

-- Desde la app la cocinera solo rechaza (o deshace el rechazo) y resuelve
-- pedidos de cambio. Presupuestar, aceptar, declinar y vencer son del servidor
-- (Edge Functions y cron con la service role), que no pasa por esta guarda.
create function public.requests_guard_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user <> 'authenticated' then
    return new;
  end if;

  if new.status is distinct from old.status
     and not ((old.status = 'new' and new.status in ('rejected', 'resolved'))
              or (old.status = 'rejected' and new.status = 'new'))
  then
    raise exception 'request_status_change_not_allowed'
      using errcode = '42501',
            detail  = format('El paso de %s a %s lo hace el servidor, no la app.', old.status, new.status);
  end if;

  return new;
end
$$;

create trigger requests_guard_update
  before update on public.requests
  for each row execute function public.requests_guard_update();

-- ---------------------------------------------------------------------
-- 3. Registro de intentos del formulario público (límite por IP)
-- Va en el esquema private (no está en [api].schemas): ningún rol de la API
-- lo ve. Solo lo usa hit_public_request_rate (security definer).
-- ---------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
comment on schema private is 'Datos internos: fuera de la API. Solo los usan funciones security definer.';

create table private.public_request_hits (
  id          bigint generated always as identity primary key,
  -- SHA-256 en hexadecimal de la IP con sal (IP_HASH_SALT): la IP nunca se guarda en claro.
  ip_hash     text not null
    constraint public_request_hits_ip_hash_sha256 check (ip_hash ~ '^[0-9a-f]{64}$'),
  created_at  timestamptz not null default now()
);
create index public_request_hits_ip_created_idx on private.public_request_hits (ip_hash, created_at);
create index public_request_hits_created_idx on private.public_request_hits (created_at);

alter table private.public_request_hits enable row level security;
revoke all on private.public_request_hits from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4a. hit_public_request_rate: registra el intento y dice si está dentro del límite
-- Ventanas deslizantes de 1 hora y 1 día. Cuentan todos los intentos,
-- también los rechazados (quien insiste sigue bloqueado).
-- ---------------------------------------------------------------------
create function public.hit_public_request_rate(p_ip_hash text, p_max_hour int, p_max_day int)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_last_hour int;
  v_last_day  int;
begin
  if p_ip_hash is null or p_ip_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_ip_hash' using errcode = '22023';
  end if;
  if p_max_hour is null or p_max_hour < 1 or p_max_day is null or p_max_day < 1 then
    raise exception 'invalid_rate_limits' using errcode = '22023';
  end if;

  -- Serializa los intentos de una misma IP para que el conteo sea exacto.
  perform pg_advisory_xact_lock(hashtextextended('public_request_hits:' || p_ip_hash, 0));

  -- Limpieza: nada necesita más de 2 días (la ventana más larga es de 1 día).
  delete from private.public_request_hits h where h.created_at < now() - interval '2 days';

  insert into private.public_request_hits (ip_hash) values (p_ip_hash);

  select count(*) filter (where h.created_at > now() - interval '1 hour'),
         count(*)
    into v_last_hour, v_last_day
  from private.public_request_hits h
  where h.ip_hash = p_ip_hash
    and h.created_at > now() - interval '1 day';

  return v_last_hour <= p_max_hour and v_last_day <= p_max_day;
end
$$;

comment on function public.hit_public_request_rate(text, int, int) is
  'Límite del formulario público: registra el intento de la IP (hash) y devuelve true si en la última hora hay como máximo p_max_hour intentos y en el último día p_max_day. Solo service role.';

-- ---------------------------------------------------------------------
-- 4b. submit_public_request: guarda el pedido de la web en una transacción
--
-- p (lo arma la Edge Function a partir de parsePublicRequest, ya validado):
--   chef_id, type ('week' | 'extra'), adults, kids, days, meals (['lunch','dinner']),
--   allergens, diets, restrictions_note, preferred_date ('AAAA-MM-DD' | null),
--   preferred_slot, name, zone, phone (E.164), email, whatsapp_opt_in, notes,
--   locale, privacy_consent_version, health_consent_version (null sin restricciones),
--   estimate (objeto: calcQuote + pricing).
--
-- Cliente: reutiliza solo un prospecto del mismo chef con el mismo email (sin
-- distinguir mayúsculas): le actualiza nombre, teléfono y zona y le reemplaza
-- las restricciones. Nunca toca clientes con cuenta: si el email es de uno,
-- crea un prospecto nuevo (Evelyn los une a mano).
-- Restricciones (dato de salud): solo con consentimiento health_data, que se
-- registra antes que ellas (lo exige client_restrictions_require_consent).
-- ---------------------------------------------------------------------
create function public.submit_public_request(p jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_chef_id      uuid;
  v_chef_profile uuid;
  v_type         public.request_type;
  v_name         text;
  v_zone         text;
  v_phone        text;
  v_email        text;
  v_privacy      text;
  v_health       text;
  v_note         text;
  v_meals        text[];
  v_allergens    public.allergen[];
  v_diets        public.diet[];
  v_restricted   boolean;
  v_client_id    uuid;
  v_request_id   uuid;
begin
  if jsonb_typeof(p) is distinct from 'object' then
    raise exception 'invalid_payload' using errcode = '22023';
  end if;

  select c.id, c.profile_id
    into v_chef_id, v_chef_profile
  from public.chefs c
  where c.id = (p ->> 'chef_id')::uuid;
  if v_chef_id is null then
    raise exception 'chef_not_found' using errcode = 'P0002';
  end if;

  -- 'change' es solo para clientes con cuenta y una sesión propia.
  if coalesce(p ->> 'type', '') not in ('week', 'extra') then
    raise exception 'invalid_request_type' using errcode = '22023';
  end if;
  v_type := (p ->> 'type')::public.request_type;

  v_name    := nullif(btrim(p ->> 'name'), '');
  v_zone    := nullif(btrim(p ->> 'zone'), '');
  v_phone   := nullif(btrim(p ->> 'phone'), '');
  v_email   := lower(nullif(btrim(p ->> 'email'), ''));
  v_privacy := nullif(btrim(p ->> 'privacy_consent_version'), '');
  v_health  := nullif(btrim(p ->> 'health_consent_version'), '');
  v_note    := coalesce(btrim(p ->> 'restrictions_note'), '');

  if v_name is null then
    raise exception 'name_required' using errcode = '22023';
  end if;
  if v_zone is null then
    raise exception 'zone_required' using errcode = '22023';
  end if;
  if v_phone is null then
    raise exception 'phone_required' using errcode = '22023';
  end if;
  if v_email is null then
    raise exception 'email_required' using errcode = '22023';
  end if;
  if v_privacy is null then
    raise exception 'privacy_consent_required' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p -> 'estimate') is distinct from 'object' then
    raise exception 'estimate_required' using errcode = '22023';
  end if;

  -- Comidas en orden canónico, sin repetir ni valores desconocidos.
  if jsonb_typeof(p -> 'meals') is distinct from 'array' then
    raise exception 'invalid_meals' using errcode = '22023';
  end if;
  v_meals := array(select m from unnest(array['lunch', 'dinner']) as m where (p -> 'meals') ? m);
  if cardinality(v_meals) = 0 or cardinality(v_meals) <> jsonb_array_length(p -> 'meals') then
    raise exception 'invalid_meals' using errcode = '22023';
  end if;

  -- Alérgenos y dietas: sin repetir, en el orden de los enums (un valor desconocido falla con 22P02).
  select coalesce(array_agg(distinct a::public.allergen order by a::public.allergen), '{}')
    into v_allergens
  from jsonb_array_elements_text(coalesce(p -> 'allergens', '[]'::jsonb)) as a;
  select coalesce(array_agg(distinct d::public.diet order by d::public.diet), '{}')
    into v_diets
  from jsonb_array_elements_text(coalesce(p -> 'diets', '[]'::jsonb)) as d;

  v_restricted := cardinality(v_allergens) > 0 or cardinality(v_diets) > 0 or v_note <> '';
  if v_restricted and v_health is null then
    raise exception 'health_consent_required'
      using errcode = 'P0001',
            detail  = 'Sin consentimiento de salud no se guardan alergias, dietas ni la nota de restricciones.';
  end if;

  -- Cliente: un pedido a la vez por chef y email (evita dos prospectos gemelos).
  perform pg_advisory_xact_lock(hashtextextended('public_request:' || v_chef_id::text || ':' || v_email, 0));

  select cl.id
    into v_client_id
  from public.clients cl
  where cl.chef_id = v_chef_id
    and cl.status = 'prospect'
    and lower(cl.contact_email) = v_email
  order by cl.created_at desc, cl.id
  limit 1
  for update;

  if v_client_id is null then
    insert into public.clients (chef_id, display_name, contact_email, contact_phone, zone, adults, kids, status)
    values (
      v_chef_id, v_name, v_email, v_phone, v_zone,
      -- El hogar se toma de un pedido semanal; un evento no describe la casa.
      case when v_type = 'week' then (p ->> 'adults')::smallint else 1 end,
      case when v_type = 'week' then (p ->> 'kids')::smallint else 0 end,
      'prospect'
    )
    returning id into v_client_id;
  else
    update public.clients cl
       set display_name  = v_name,
           contact_phone = v_phone,
           zone          = v_zone
     where cl.id = v_client_id;
  end if;

  -- Consentimientos. Con la misma versión del texto se conserva el vigente; una
  -- versión nueva reemplaza a la anterior, que queda cerrada (revoked_at) como traza.
  if not exists (
    select 1 from public.consents c
    where c.client_id = v_client_id and c.kind = 'privacy' and c.revoked_at is null and c.text_version = v_privacy
  ) then
    update public.consents c set revoked_at = now()
     where c.client_id = v_client_id and c.kind = 'privacy' and c.revoked_at is null;
    insert into public.consents (chef_id, client_id, kind, text_version)
    values (v_chef_id, v_client_id, 'privacy', v_privacy);
  end if;

  -- Salud: antes que las restricciones. Sin restricciones nuevas no se toca:
  -- el consentimiento anterior cubre las copias de pedidos anteriores.
  if v_restricted and not exists (
    select 1 from public.consents c
    where c.client_id = v_client_id and c.kind = 'health_data' and c.revoked_at is null and c.text_version = v_health
  ) then
    -- Cerrar el anterior dispara consents_purge_health_data (borra las restricciones viejas): se reemplazan igual.
    update public.consents c set revoked_at = now()
     where c.client_id = v_client_id and c.kind = 'health_data' and c.revoked_at is null;
    insert into public.consents (chef_id, client_id, kind, text_version)
    values (v_chef_id, v_client_id, 'health_data', v_health);
  end if;

  -- Restricciones del cliente: se reemplazan por las de este pedido.
  delete from public.client_restrictions r where r.client_id = v_client_id;
  if v_restricted then
    insert into public.client_restrictions (chef_id, client_id, allergen)
    select v_chef_id, v_client_id, a from unnest(v_allergens) as a;
    insert into public.client_restrictions (chef_id, client_id, diet)
    select v_chef_id, v_client_id, d from unnest(v_diets) as d;
  end if;

  insert into public.requests (
    chef_id, client_id, type, status, adults, kids, days, meals, restrictions, notes,
    preferred_date, preferred_slot, locale, whatsapp_opt_in, estimate, source
  )
  values (
    v_chef_id, v_client_id, v_type, 'new',
    (p ->> 'adults')::smallint, (p ->> 'kids')::smallint, (p ->> 'days')::smallint, v_meals,
    case when v_restricted then
      jsonb_build_object('allergens', to_jsonb(v_allergens::text[]),
                         'diets',     to_jsonb(v_diets::text[]),
                         'note',      v_note)
    end,
    nullif(btrim(p ->> 'notes'), ''),
    nullif(p ->> 'preferred_date', '')::date,
    coalesce(p ->> 'preferred_slot', 'any'),
    coalesce(p ->> 'locale', 'it'),
    coalesce((p ->> 'whatsapp_opt_in')::boolean, false),
    p -> 'estimate',
    'web'
  )
  returning id into v_request_id;

  -- Aviso para la cocinera: la Edge Function manda el email y completa sent_at.
  -- El payload nunca lleva restricciones ni direcciones (SPEC §6).
  insert into public.notifications (profile_id, kind, channel, payload)
  values (v_chef_profile, 'new_request', 'email', jsonb_build_object('request_id', v_request_id));

  return v_request_id;
end
$$;

comment on function public.submit_public_request(jsonb) is
  'Guarda un pedido del formulario público (Edge Function public-request): prospecto, consentimientos, restricciones, pedido y notificación, en una transacción. Devuelve el id del pedido. Solo service role.';

-- ---------------------------------------------------------------------
-- 4c. promote_to_chef: arranque. Convierte un usuario de auth en cocinera.
-- Se corre una vez desde el SQL editor; repetirla devuelve la misma ficha.
-- ---------------------------------------------------------------------
create function public.promote_to_chef(p_email text, p_display_name text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_email   text := lower(nullif(btrim(p_email), ''));
  v_name    text := nullif(btrim(p_display_name), '');
  v_user_id uuid;
  v_chef_id uuid;
begin
  if v_email is null then
    raise exception 'email_required' using errcode = '22023';
  end if;
  if v_name is null then
    raise exception 'display_name_required' using errcode = '22023';
  end if;

  begin
    select u.id into strict v_user_id from auth.users u where lower(u.email) = v_email;
  exception
    when no_data_found then
      raise exception 'user_not_found'
        using errcode = 'P0002',
              hint    = 'Crear antes el usuario (Authentication → Users → Add user) o pedirle que entre una vez con el código por email.';
    when too_many_rows then
      raise exception 'email_ambiguous' using errcode = 'P0003';
  end;

  -- El perfil lo crea el trigger de auth.users; si faltara, se crea acá.
  insert into public.profiles (id, role) values (v_user_id, 'chef')
  on conflict (id) do update set role = 'chef';

  insert into public.chefs (profile_id, display_name) values (v_user_id, v_name)
  on conflict (profile_id) do update set display_name = excluded.display_name
  returning id into v_chef_id;

  insert into public.chef_settings (chef_id) values (v_chef_id)
  on conflict (chef_id) do nothing;

  return v_chef_id;
end
$$;

comment on function public.promote_to_chef(text, text) is
  'Arranque: el usuario de auth con ese email pasa a cocinera (rol chef, ficha en chefs y chef_settings por defecto). Devuelve chef_id. Idempotente. Solo service role / SQL editor.';

-- Solo la service role (Supabase da EXECUTE a anon y authenticated por defecto en public).
revoke all on function public.hit_public_request_rate(text, int, int) from public, anon, authenticated;
revoke all on function public.submit_public_request(jsonb)            from public, anon, authenticated;
revoke all on function public.promote_to_chef(text, text)              from public, anon, authenticated;
grant execute on function public.hit_public_request_rate(text, int, int) to service_role;
grant execute on function public.submit_public_request(jsonb)            to service_role;
grant execute on function public.promote_to_chef(text, text)              to service_role;

-- La guarda de requests es un trigger: nadie la llama directo.
revoke all on function public.requests_guard_update() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Realtime: la app escucha los INSERT de requests (RLS decide quién los recibe)
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'requests'
  ) then
    alter publication supabase_realtime add table public.requests;
  end if;
end
$$;
