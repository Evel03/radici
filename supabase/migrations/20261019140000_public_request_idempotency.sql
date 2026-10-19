-- =====================================================================
-- Radici · Pedido de la web: idempotencia con requestKey
-- Contrato: docs/contracts/public-request.md §2 y §3.
--
-- La web genera un UUID por pedido (requestKey) y lo repite en cada
-- reintento. Si la misma clave llega otra vez, submit_public_request
-- devuelve el pedido ya guardado (mismo id y la estimación guardada) sin
-- insertar ni modificar nada (ni otra notificación), y la Edge Function
-- responde lo mismo que la primera vez sin repetir emails ni WhatsApp.
--
--   1. requests.request_key + índice único (chef_id, request_key) parcial.
--   2. submit_public_request devuelve jsonb {request_id, duplicate, estimate}
--      (antes uuid). Cambia el tipo de retorno: se borra y se vuelve a crear,
--      con los mismos privilegios (solo service_role).
--
-- Concurrencia: dos envíos simultáneos con la misma clave se serializan con
-- un advisory lock por (cocinera, clave); el segundo espera el commit del
-- primero y lo encuentra. El índice único es la garantía final de la base.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. requests.request_key
-- ---------------------------------------------------------------------
alter table public.requests
  add column request_key uuid;

comment on column public.requests.request_key is
  'Clave de idempotencia del formulario web (requestKey: UUID que genera la web una vez por pedido). Única por cocinera; null en los pedidos de la app. La escribe solo submit_public_request.';

-- Un pedido por clave y cocinera. Los pedidos sin clave (app, web vieja) no cuentan.
create unique index requests_chef_request_key_idx on public.requests (chef_id, request_key)
  where request_key is not null;

-- La app no la escribe: los privilegios de insert/update de authenticated en
-- requests son por columna (20261019120000_public_requests.sql) y esta no está.

-- ---------------------------------------------------------------------
-- 2. submit_public_request: igual que antes, más la clave de idempotencia
--
-- p: lo mismo que en 20261019120000_public_requests.sql, más
--   request_key (UUID en texto, o null / ausente si la web no la manda).
--
-- Devuelve {"request_id": uuid, "duplicate": bool, "estimate": jsonb}:
--   * duplicate = false: pedido nuevo; estimate es la que se acaba de guardar.
--   * duplicate = true: la clave ya existía para esta cocinera; request_id y
--     estimate son los del pedido original y no se tocó nada (ni el prospecto,
--     ni los consentimientos, ni las restricciones, ni las notificaciones).
-- ---------------------------------------------------------------------
drop function public.submit_public_request(jsonb);

create function public.submit_public_request(p jsonb)
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
    preferred_date, preferred_slot, locale, whatsapp_opt_in, estimate, source, request_key
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
    'web',
    v_request_key
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
  'Guarda un pedido del formulario público (Edge Function public-request): prospecto, consentimientos, restricciones, pedido y notificación, en una transacción. Idempotente por (chef_id, request_key): con una clave ya usada devuelve el pedido guardado sin tocar nada. Devuelve {request_id, duplicate, estimate}. Solo service role.';

-- Solo la service role (Supabase da EXECUTE a anon y authenticated por defecto en public).
revoke all on function public.submit_public_request(jsonb) from public, anon, authenticated;
grant execute on function public.submit_public_request(jsonb) to service_role;
