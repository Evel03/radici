-- =====================================================================
-- Radici · Pedido de la web: endurecimiento después de la revisión
-- Contrato: docs/contracts/public-request.md §3, §8 y §9.
--
--   1. requests.contact: copia de nombre, zona, teléfono y email tal como
--      llegaron con cada pedido de la web. La app la muestra en lugar de la
--      ficha del cliente.
--   2. submit_public_request: un envío sin login nunca cambia a una persona
--      que ya existe. Al reutilizar un prospecto no le pisa nombre, teléfono
--      ni zona, y nunca le borra restricciones: las de un pedido semanal se
--      suman a las suyas; las de un evento quedan solo en la copia del pedido
--      (como el hogar: "un evento no describe la casa").
--   3. requests_guard_update también en el alta: desde la app un pedido nace
--      en 'new' (quoted, accepted, etc. los pone el servidor).
--   4. promote_to_chef: contraseña nueva al azar y sesiones y factores MFA
--      borrados, para que nadie que haya registrado antes ese email (con una
--      contraseña suya) entre como cocinera. Exige el email confirmado.
--   5. Límite por IP: los intentos se borran pasado 1 día (la ventana más
--      larga), así ninguno dura más de 2 días aun con el borrado diario.
--   6. private.revoke_health_consent: revocar el consentimiento de salud
--      borra también las copias de las restricciones en los pedidos (lo que
--      promete la privacy). Solo el dueño (SQL editor).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. requests.contact
-- ---------------------------------------------------------------------
alter table public.requests
  add column contact jsonb
    constraint requests_contacto_es_objeto check (contact is null or jsonb_typeof(contact) = 'object');

comment on column public.requests.contact is
  'Contacto tal como llegó con este pedido de la web: {"name", "zone", "phone" (E.164), "email"}. Lo escribe solo submit_public_request; la app lo muestra en lugar de la ficha del cliente, que un envío sin login no modifica. null en los pedidos de la app.';

-- La app no la escribe: los privilegios de insert/update de authenticated en
-- requests son por columna (20261019120000_public_requests.sql) y esta no está.

-- ---------------------------------------------------------------------
-- 2. submit_public_request
--
-- p: lo mismo que en 20261019140000_public_request_idempotency.sql.
-- Devuelve {"request_id": uuid, "duplicate": bool, "estimate": jsonb} (igual).
--
-- Cambios:
--   * Prospecto reutilizado (mismo chef y email): no se le actualiza nada.
--     Cualquiera que conozca un email podía cambiarle el teléfono a esa
--     persona (y con él los botones de WhatsApp y llamada de sus pedidos).
--     Lo que llegó con cada pedido queda en requests.contact.
--   * client_restrictions (restricciones del hogar): solo desde un pedido
--     semanal, y se suman (nunca se borran desde la web). Las de un evento
--     son de sus invitados: quedan solo en requests.restrictions.
--     Un cambio de versión del texto de salud cierra el consentimiento
--     anterior y, como antes, eso borra las restricciones del prospecto
--     (consents_purge_health_data); las de un pedido semanal se vuelven a cargar.
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
    chef_id, client_id, type, status, adults, kids, days, meals, restrictions, notes,
    preferred_date, preferred_slot, locale, whatsapp_opt_in, estimate, source, request_key, contact
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
  'Guarda un pedido del formulario público (Edge Function public-request): prospecto (nuevo; uno existente no se modifica), consentimientos, restricciones del hogar (solo de un pedido semanal, se suman), pedido con la copia del contacto y notificación, en una transacción. Idempotente por (chef_id, request_key). Devuelve {request_id, duplicate, estimate}. Solo service role.';

-- create or replace conserva los privilegios; se repiten para que quede a la vista.
revoke all on function public.submit_public_request(jsonb) from public, anon, authenticated;
grant execute on function public.submit_public_request(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 3. requests_guard_update: también en el alta
-- Desde la app (rol authenticated) un pedido nuevo empieza en 'new': ni la
-- cocinera ni el cliente lo crean ya presupuestado o aceptado (el contrato §3
-- dice que esos estados los pone el servidor; la retención de prospectos los
-- usa para conservar a una persona).
-- ---------------------------------------------------------------------
create or replace function public.requests_guard_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user <> 'authenticated' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'new' then
      raise exception 'request_status_change_not_allowed'
        using errcode = '42501',
              detail  = format('Desde la app un pedido empieza en new, no en %s.', new.status);
    end if;
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

drop trigger requests_guard_update on public.requests;
create trigger requests_guard_update
  before insert or update on public.requests
  for each row execute function public.requests_guard_update();

revoke all on function public.requests_guard_update() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. promote_to_chef: el acceso queda solo para quien recibe el código
--
-- Con las altas abiertas, cualquiera que conozca el email de Evelyn podía
-- registrarse antes que ella con una contraseña propia; Supabase conserva esa
-- contraseña cuando ella entra después con el código, y al promoverla esa
-- persona entraba como cocinera. Ahora, al promover:
--   * el email tiene que estar confirmado (entró con el código, o se creó
--     confirmado desde el panel);
--   * la contraseña pasa a ser una al azar que nadie conoce (la app entra con
--     código: no usa contraseña);
--   * se borran sus sesiones (con sus refresh tokens) y sus factores MFA: hay
--     que volver a entrar con el código. Un access token ya emitido vale hasta
--     que vence (jwt_expiry, 1 h).
-- Repetirla devuelve la misma ficha y vuelve a cerrar las sesiones.
-- ---------------------------------------------------------------------
create or replace function public.promote_to_chef(p_email text, p_display_name text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_email     text := lower(nullif(btrim(p_email), ''));
  v_name      text := nullif(btrim(p_display_name), '');
  v_user_id   uuid;
  v_confirmed timestamptz;
  v_chef_id   uuid;
begin
  if v_email is null then
    raise exception 'email_required' using errcode = '22023';
  end if;
  if v_name is null then
    raise exception 'display_name_required' using errcode = '22023';
  end if;

  begin
    select u.id, u.email_confirmed_at into strict v_user_id, v_confirmed
    from auth.users u where lower(u.email) = v_email;
  exception
    when no_data_found then
      raise exception 'user_not_found'
        using errcode = 'P0002',
              hint    = 'Crear antes el usuario confirmado (Authentication → Users → Add user, con Auto Confirm User) o pedirle que entre una vez con el código por email.';
    when too_many_rows then
      raise exception 'email_ambiguous' using errcode = 'P0003';
  end;

  if v_confirmed is null then
    raise exception 'user_not_confirmed'
      using errcode = 'P0001',
            hint    = 'El email no está confirmado: que entre una vez con el código, o borrar ese usuario y crearlo confirmado desde el panel.';
  end if;

  -- Nadie más que quien recibe el código puede entrar como cocinera.
  update auth.users u
     set encrypted_password = extensions.crypt(encode(extensions.gen_random_bytes(32), 'hex'), extensions.gen_salt('bf'))
   where u.id = v_user_id;
  delete from auth.sessions s where s.user_id = v_user_id;            -- en cascada: refresh_tokens, mfa_amr_claims
  delete from auth.refresh_tokens t where t.user_id = v_user_id::text; -- por si queda alguno sin sesión
  delete from auth.mfa_factors f where f.user_id = v_user_id;

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
  'Arranque: el usuario de auth con ese email (confirmado) pasa a cocinera (rol chef, ficha en chefs y chef_settings por defecto). Le pone una contraseña al azar y le cierra las sesiones: solo entra quien recibe el código. Devuelve chef_id. Solo service role / SQL editor.';

revoke all on function public.promote_to_chef(text, text) from public, anon, authenticated;
grant execute on function public.promote_to_chef(text, text) to service_role;

-- ---------------------------------------------------------------------
-- 5. Límite por IP: nada dura más de 1 día después de la ventana más larga
-- La ventana más larga es de 1 día: un intento más viejo ya no cuenta. Con el
-- borrado de cada intento y el diario (03:30 UTC), ninguno dura 2 días.
-- ---------------------------------------------------------------------
create or replace function public.hit_public_request_rate(p_ip_hash text, p_max_hour int, p_max_day int)
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

  -- Limpieza: lo de más de 1 día ya no cuenta para ninguna ventana.
  delete from private.public_request_hits h where h.created_at < now() - interval '1 day';

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
  'Límite del formulario público: registra el intento de la IP (hash) y devuelve true si en la última hora hay como máximo p_max_hour intentos y en el último día p_max_day. Borra los intentos de más de 1 día. Solo service role.';

revoke all on function public.hit_public_request_rate(text, int, int) from public, anon, authenticated;
grant execute on function public.hit_public_request_rate(text, int, int) to service_role;

-- El borrado diario: igual que en 20261019150000_prospect_retention.sql, con 1 día para los intentos.
create or replace function private.purge_expired_prospects()
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_candidate     record;
  v_request_ids   uuid[];
  v_deleted       int;
  v_clients       int := 0;
  v_requests      int := 0;
  v_notifications int := 0;
  v_hits          int := 0;
begin
  for v_candidate in
    select cl.id, cl.chef_id, lower(cl.contact_email) as email
    from public.clients cl
    where cl.status = 'prospect'
      and cl.profile_id is null
      and private.prospect_retention_expired(cl.id)
    order by cl.id
  loop
    begin
      -- Sin email no hay pedido de la web que pueda chocar (siempre trae email).
      if v_candidate.email is not null then
        perform pg_advisory_xact_lock(hashtextextended('public_request:' || v_candidate.chef_id::text || ':' || v_candidate.email, 0));
      end if;

      perform 1 from public.clients cl where cl.id = v_candidate.id for update;
      if not found then
        continue;
      end if;
      perform 1 from public.requests r where r.client_id = v_candidate.id for update;

      -- Con la ficha y sus pedidos bloqueados, otra vez la regla (sentencia nueva: ve lo confirmado).
      if not private.prospect_retention_expired(v_candidate.id) then
        continue;
      end if;

      select coalesce(array_agg(r.id), '{}')
        into v_request_ids
      from public.requests r
      where r.client_id = v_candidate.id;

      -- Avisos que apuntan a esos pedidos (payload {"request_id": ...}), de cualquier tipo.
      delete from public.notifications n
      where n.payload ->> 'request_id' = any (v_request_ids::text[]);
      get diagnostics v_deleted = row_count;

      -- En cascada: pedidos (y presupuestos), consentimientos, restricciones,
      -- sesiones canceladas, planes, porciones y despensa del cliente.
      delete from public.clients cl where cl.id = v_candidate.id;

      v_clients       := v_clients + 1;
      v_requests      := v_requests + cardinality(v_request_ids);
      v_notifications := v_notifications + v_deleted;
    exception
      -- Un pago registrado justo ahora (payments → sessions es restrict): se
      -- deshace solo este cliente y se sigue; mañana la regla ya lo conserva.
      when foreign_key_violation then
        raise warning 'purge_expired_prospects: cliente % conservado (sqlstate %)', v_candidate.id, sqlstate;
    end;
  end loop;

  -- Límite por IP: la ventana más larga es de 1 día; lo más viejo ya no cuenta (igual que
  -- hit_public_request_rate, que solo limpia cuando llega otro intento).
  delete from private.public_request_hits h where h.created_at < now() - interval '1 day';
  get diagnostics v_hits = row_count;

  -- Solo contadores: nunca datos del cliente en los logs.
  raise log 'purge_expired_prospects: clients=% requests=% notifications=% rate_limit_hits=%',
    v_clients, v_requests, v_notifications, v_hits;

  return jsonb_build_object('clients', v_clients, 'requests', v_requests, 'notifications', v_notifications,
                            'rate_limit_hits', v_hits);
end
$$;

comment on function private.purge_expired_prospects() is
  'Conservación (SPEC §6): borra los prospectos de private.prospect_retention_expired, con sus pedidos, consentimientos y restricciones en cascada, las notificaciones que apuntan a esos pedidos y los intentos del límite por IP de más de 1 día. Devuelve {clients, requests, notifications, rate_limit_hits}. Idempotente. La corre pg_cron a diario.';

revoke all on function private.purge_expired_prospects() from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6. private.revoke_health_consent: el cliente retira el consentimiento de salud
--
-- La privacy promete conservar alergias y dietas "fino alla revoca del
-- consenso". Revocar el consentimiento vigente ya borra client_restrictions
-- (trigger consents_purge_on_revoke); esto además borra las copias en sus
-- pedidos (requests.restrictions), que la app no puede tocar.
-- No va en consents_purge_health_data: ese trigger también corre cuando
-- submit_public_request reemplaza la versión del texto, y ahí las copias valen.
-- Cuando existan presupuestos con restricciones (M3), borrarlas acá también.
-- SPEC §14: si quien asesore en privacidad decide conservar las copias como
-- prueba, cambiar la privacy (finalidad y plazo) y esta función.
-- Se corre desde el SQL editor (procedimiento en el contrato §10).
-- ---------------------------------------------------------------------
create function private.revoke_health_consent(p_client_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_consents int;
  v_requests int;
begin
  if p_client_id is null or not exists (select 1 from public.clients cl where cl.id = p_client_id) then
    raise exception 'client_not_found' using errcode = 'P0002';
  end if;

  update public.consents c set revoked_at = now()
   where c.client_id = p_client_id and c.kind = 'health_data' and c.revoked_at is null;
  get diagnostics v_consents = row_count;

  update public.requests r set restrictions = null
   where r.client_id = p_client_id and r.restrictions is not null;
  get diagnostics v_requests = row_count;

  -- Solo contadores: nunca datos del cliente en los logs.
  raise log 'revoke_health_consent: consents=% requests=%', v_consents, v_requests;

  return jsonb_build_object('consents', v_consents, 'requests', v_requests);
end
$$;

comment on function private.revoke_health_consent(uuid) is
  'Retiro del consentimiento de salud: lo revoca (el trigger borra client_restrictions) y borra las copias de las restricciones en los pedidos del cliente. Devuelve {consents, requests}. Solo el dueño (SQL editor).';

revoke all on function private.revoke_health_consent(uuid) from public, anon, authenticated, service_role;
