-- =====================================================================
-- Radici · Precio por semanas (la base)
-- Contrato: docs/contracts/public-request.md §3 y §8. Tests: supabase/tests/database/12_weekly_pricing.test.sql.
--
-- Decisiones del dueño del 15 y 16/11/2026: el pedido semanal es de 1 a 8 semanas, con un menú y
-- una sesión de cocina por semana, y el servicio pasa a tener un precio por semana. El cálculo es
-- del motor de presupuesto (supabase/functions/_shared/quote.ts) y llega en el PR siguiente, con la
-- función, la web y la app. Esta migración va antes, en un PR propio (contrato §8): agrega lo que
-- ese código lee y anda con la función y la web que siguen en producción.
--
--   1. chef_settings: tarifa por semana (15000), tarifa por semana con descuento (14000), desde
--      cuántas semanas vale el descuento (4) y hasta cuántas personas, adultos y niños, hay precio
--      automático (5). Las filas que ya existen (en producción, Evelyn) reciben estos valores.
--      Los checks acotan cada valor; el motor tiene que aceptar al menos esos rangos, así un valor
--      que la base guarda nunca hace fallar el cálculo.
--      El costo por porción (adult_portion_cents, kid_portion_cents) solo pedía >= 0, y el motor (el
--      de hoy y el del PR siguiente) acepta hasta 100000 (1000 €): con una porción más cara, cada
--      pedido de esa cocinera daba quote_failed (500). Pasa a tener ese tope; las filas que ya
--      existen lo cumplen (en producción, 380 y 250). Las demás columnas que lee el motor del PR
--      siguiente ya tenían sus rangos: las cuatro de arriba, preauth_buffer_pct (0 a 100) y
--      min_cook_minutes (0 a 1440).
--   2. requests.weeks (1 a 8): las semanas del pedido semanal; 1 en todo lo demás (extra, change).
--      Las filas que ya existen quedan en 1: eran de una semana.
--   3. submit_public_request guarda p.weeks. Sin el campo, o en null, 1: así la función de hoy, que
--      no lo manda, sigue guardando pedidos mientras se despliega la nueva (la web, la función y
--      las migraciones se despliegan por separado). Defensa (la Edge Function va a validar antes):
--      fuera de 1–8 o que no es un número entero, invalid_weeks; más de una semana en un pedido que
--      no es semanal, weeks_only_for_week (22023).
--
-- Lo que no cambia:
--   * requests.estimate: la base lo sigue guardando tal cual (un objeto) y no lee ninguna de sus
--     claves. Su forma, también la de un pedido sin precio automático, la decide quote.ts y viaja
--     con la estimación (un reintento devuelve la guardada): no hace falta otra columna.
--   * Privilegios y RLS. La app lee weeks (authenticated tiene select sobre requests; RLS decide las
--     filas) y no la escribe: insert y update de requests son por columna
--     (20261019120000_public_requests.sql) y weeks no está; un pedido creado desde la app queda en
--     1. Las columnas nuevas de chef_settings siguen a las demás tarifas: las lee y las cambia solo
--     la cocinera dueña (política "chef_settings: la cocinera gestiona las suyas"), la Edge Function
--     las lee con la clave secreta, y los clientes y anon no las ven.
--   * El tiempo de cocina se sigue estimando como hasta ahora: de él dependen get_free_days y el
--     tope de 300 min del calendario.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. chef_settings: precio por semana y tope del costo por porción
-- ---------------------------------------------------------------------
alter table public.chef_settings
  add column weekly_rate_cents            int not null default 15000
    check (weekly_rate_cents between 0 and 1000000),
  add column weekly_rate_discounted_cents int not null default 14000
    check (weekly_rate_discounted_cents between 0 and 1000000),
  -- Hasta 8: las semanas que se pueden pedir (requests_semanas_validas). Para no hacer descuento,
  -- la misma tarifa en las dos columnas.
  add column weekly_discount_min_weeks    int not null default 4
    check (weekly_discount_min_weeks between 1 and 8),
  -- Hasta 60: 30 adultos y 30 niños (LIMITS.maxPeople de quote.ts); más es lo mismo que sin tope.
  add column weekly_rate_max_people       int not null default 5
    check (weekly_rate_max_people between 1 and 60),
  add constraint chef_settings_descuento_no_supera_tarifa
    check (weekly_rate_discounted_cents <= weekly_rate_cents);

-- Costo por porción: el tope del motor (validateSettings de quote.ts y de la copia Dart). El check
-- de create table (>= 0) sigue; estos suman el máximo.
alter table public.chef_settings
  add constraint chef_settings_porcion_adulto_valida check (adult_portion_cents between 0 and 100000),
  add constraint chef_settings_porcion_nino_valida check (kid_portion_cents between 0 and 100000);

comment on column public.chef_settings.weekly_rate_cents is
  'Servicio por semana de un pedido semanal (un menú y una sesión de cocina por semana), en centavos. Para el motor de presupuesto (quote.ts).';
comment on column public.chef_settings.weekly_rate_discounted_cents is
  'Servicio por semana, en centavos, de un pedido de weekly_discount_min_weeks semanas o más. Nunca más que weekly_rate_cents.';
comment on column public.chef_settings.weekly_discount_min_weeks is
  'Desde cuántas semanas vale weekly_rate_discounted_cents (de 1 a 8, las que se pueden pedir).';
comment on column public.chef_settings.weekly_rate_max_people is
  'Hasta cuántas personas (adultos + niños) tiene precio automático un pedido semanal; con más, la cocinera pasa el presupuesto.';

-- ---------------------------------------------------------------------
-- 2. requests.weeks
-- ---------------------------------------------------------------------
alter table public.requests
  add column weeks smallint not null default 1,
  add constraint requests_semanas_validas check (weeks between 1 and 8),
  add constraint requests_semanas_solo_week check (type = 'week' or weeks = 1);

comment on column public.requests.weeks is
  'Semanas del pedido semanal (type = week), de 1 a 8: un menú y una sesión de cocina por semana. 1 en todo lo demás (extra, change) y en los pedidos anteriores al precio por semanas. La escribe submit_public_request (p.weeks); la app la lee y no la escribe.';

-- ---------------------------------------------------------------------
-- 3. submit_public_request
--
-- p: lo mismo que en 20261115120000_requests_no_allergies.sql, más
--   weeks (entero de 1 a 8, o null / ausente = 1; distinto de 1 solo con type = 'week').
-- Devuelve {"request_id": uuid, "duplicate": bool, "estimate": jsonb} (igual).
-- ---------------------------------------------------------------------
create or replace function public.submit_public_request(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_chef_id      uuid;
  v_chef_profile uuid;
  v_request_key  uuid;
  v_type         public.request_type;
  v_weeks        smallint;
  v_name         text;
  v_zone         text;
  v_phone        text;
  v_email        text;
  v_privacy      text;
  v_health       text;
  v_note         text;
  v_no_allergies boolean;
  v_meals        text[];
  v_allergens    public.allergen[];
  v_diets        public.diet[];
  v_restricted   boolean;
  v_client_id    uuid;
  v_request_id   uuid;
  v_estimate     jsonb;
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

  -- Clave de idempotencia: un UUID en texto (sin distinguir mayúsculas) o nada.
  case coalesce(jsonb_typeof(p -> 'request_key'), 'null')
    when 'null' then
      v_request_key := null;
    when 'string' then
      if (p ->> 'request_key') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception 'invalid_request_key' using errcode = '22023';
      end if;
      v_request_key := (p ->> 'request_key')::uuid;
    else
      raise exception 'invalid_request_key' using errcode = '22023';
  end case;

  -- Pregunta de alergias (v2): true, false, o null / ausente (la función de antes de la v2).
  case coalesce(jsonb_typeof(p -> 'no_allergies'), 'null')
    when 'null' then
      v_no_allergies := null;
    when 'boolean' then
      v_no_allergies := (p ->> 'no_allergies')::boolean;
    else
      raise exception 'invalid_no_allergies' using errcode = '22023';
  end case;

  -- 'change' es solo para clientes con cuenta y una sesión propia.
  if coalesce(p ->> 'type', '') not in ('week', 'extra') then
    raise exception 'invalid_request_type' using errcode = '22023';
  end if;
  v_type := (p ->> 'type')::public.request_type;

  -- Semanas: un número entero de 1 a 8 (el tope de requests_semanas_validas), o null / ausente,
  -- que es 1 (la función de antes del precio por semanas no lo manda y sus pedidos son de una
  -- semana). Lo que no es un pedido semanal es siempre de 1.
  case coalesce(jsonb_typeof(p -> 'weeks'), 'null')
    when 'null' then
      v_weeks := 1;
    when 'number' then
      if (p ->> 'weeks') !~ '^[1-8]$' then
        raise exception 'invalid_weeks' using errcode = '22023';
      end if;
      v_weeks := (p ->> 'weeks')::smallint;
    else
      raise exception 'invalid_weeks' using errcode = '22023';
  end case;
  if v_type <> 'week' and v_weeks <> 1 then
    raise exception 'weeks_only_for_week' using errcode = '22023';
  end if;

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

  -- "Nadie tiene alergias" no va con restricciones (no se sabría cuál vale), y
  -- "hay alergias" sin escribirlas no le dice nada a Evelyn.
  if v_no_allergies is true and v_restricted then
    raise exception 'no_allergies_with_restrictions' using errcode = '22023';
  end if;
  if v_no_allergies is false and not v_restricted then
    raise exception 'restrictions_required' using errcode = '22023';
  end if;

  if v_restricted and v_health is null then
    raise exception 'health_consent_required'
      using errcode = 'P0001',
            detail  = 'Sin consentimiento de salud no se guardan alergias, dietas ni la nota de restricciones.';
  end if;

  -- Reintento del mismo pedido: se devuelve el guardado y no se toca nada.
  -- El lock serializa dos envíos simultáneos con la misma clave (se toma antes
  -- que el del email, siempre en este orden): el segundo espera el commit del
  -- primero y lo encuentra en esta consulta (cada sentencia ve lo confirmado).
  if v_request_key is not null then
    perform pg_advisory_xact_lock(hashtextextended('public_request_key:' || v_chef_id::text || ':' || v_request_key::text, 0));

    select r.id, r.estimate
      into v_request_id, v_estimate
    from public.requests r
    where r.chef_id = v_chef_id
      and r.request_key = v_request_key;

    if v_request_id is not null then
      return jsonb_build_object('request_id', v_request_id, 'duplicate', true, 'estimate', v_estimate);
    end if;
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

  -- Prospecto nuevo con los datos del pedido. Uno que ya existe no se toca: el
  -- email no está verificado y cualquiera puede escribir el de otra persona.
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
    -- Cerrar el anterior dispara consents_purge_health_data (borra las restricciones del prospecto).
    update public.consents c set revoked_at = now()
     where c.client_id = v_client_id and c.kind = 'health_data' and c.revoked_at is null;
    insert into public.consents (chef_id, client_id, kind, text_version)
    values (v_chef_id, v_client_id, 'health_data', v_health);
  end if;

  -- Restricciones del hogar: solo de un pedido semanal, y se suman a las que ya
  -- tenía. Nunca se borran desde la web (las cura Evelyn o el cliente con cuenta).
  if v_restricted and v_type = 'week' then
    insert into public.client_restrictions (chef_id, client_id, allergen)
    select v_chef_id, v_client_id, a from unnest(v_allergens) as a
    on conflict on constraint client_restrictions_unica do nothing;
    insert into public.client_restrictions (chef_id, client_id, diet)
    select v_chef_id, v_client_id, d from unnest(v_diets) as d
    on conflict on constraint client_restrictions_unica do nothing;
  end if;

  insert into public.requests (
    chef_id, client_id, type, status, adults, kids, days, meals, weeks, restrictions, no_allergies, notes,
    preferred_date, preferred_slot, locale, whatsapp_opt_in, estimate, source, request_key, contact
  )
  values (
    v_chef_id, v_client_id, v_type, 'new',
    (p ->> 'adults')::smallint, (p ->> 'kids')::smallint, (p ->> 'days')::smallint, v_meals, v_weeks,
    case when v_restricted then
      jsonb_build_object('allergens', to_jsonb(v_allergens::text[]),
                         'diets',     to_jsonb(v_diets::text[]),
                         'note',      v_note)
    end,
    v_no_allergies,
    nullif(btrim(p ->> 'notes'), ''),
    nullif(p ->> 'preferred_date', '')::date,
    coalesce(p ->> 'preferred_slot', 'any'),
    coalesce(p ->> 'locale', 'it'),
    coalesce((p ->> 'whatsapp_opt_in')::boolean, false),
    p -> 'estimate',
    'web',
    v_request_key,
    jsonb_build_object('name', v_name, 'zone', v_zone, 'phone', v_phone, 'email', v_email)
  )
  returning id, estimate into v_request_id, v_estimate;

  -- Aviso para la cocinera: la Edge Function manda el email y completa sent_at.
  -- El payload nunca lleva restricciones ni direcciones (SPEC §6).
  insert into public.notifications (profile_id, kind, channel, payload)
  values (v_chef_profile, 'new_request', 'email', jsonb_build_object('request_id', v_request_id));

  return jsonb_build_object('request_id', v_request_id, 'duplicate', false, 'estimate', v_estimate);
end
$$;

comment on function public.submit_public_request(jsonb) is
  'Guarda un pedido del formulario público (Edge Function public-request): prospecto (nuevo; uno existente no se modifica), consentimientos, restricciones del hogar (solo de un pedido semanal, se suman), pedido con sus semanas, la respuesta a la pregunta de alergias y la copia del contacto, y notificación, en una transacción. Idempotente por (chef_id, request_key). Devuelve {request_id, duplicate, estimate}. Solo service role.';

-- create or replace conserva los privilegios; se repiten para que quede a la vista.
revoke all on function public.submit_public_request(jsonb) from public, anon, authenticated;
grant execute on function public.submit_public_request(jsonb) to service_role;
