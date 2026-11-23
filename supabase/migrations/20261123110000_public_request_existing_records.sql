-- =====================================================================
-- PR03 · El formulario público no toca fichas existentes
--
-- Hasta hoy clients_prospect_sin_cuenta impedía que una ficha con cuenta fuera prospect, y eso era lo que
-- frenaba a submit_public_request de reutilizarla. El M2 da a cada cuenta una ficha propia (prospect con
-- cuenta), así que el cuidado pasa a la función:
--
--   1. Se quita clients_prospect_sin_cuenta (se vuelve a poder tener un prospect con profile_id).
--   2. clients_prospect_email_idx pasa a parcial (status = 'prospect' y profile_id is null): es el
--      índice de la búsqueda de submit_public_request, que ahora solo mira prospectos sin cuenta.
--      Es un índice común (no único): dos envíos simultáneos con el mismo email no pueden chocar con
--      una violación de unicidad; los serializa, como antes, el lock advisory por (cocinera, email)
--      que toma la función antes de buscar, así que el segundo ve la ficha que creó el primero.
--   3. submit_public_request reutiliza solo prospectos sin cuenta y, si el pedido trae restricciones,
--      con el mismo consentimiento de salud vigente; si cambió esa versión, crea una gemela. Nunca
--      cierra ni reemplaza el consentimiento de salud de una ficha existente. Si cambió solo la privacy,
--      la suma como hasta ahora. Las restricciones de un pedido semanal se siguen sumando.
--      No hay columna de anonimización en clients: la baja de una ficha es el borrado (retención de 90
--      días o borrado de cuenta), así que no hay fichas anonimizadas que filtrar.
--   La firma no cambia (create or replace conserva el grant a service_role).
-- =====================================================================

alter table public.clients drop constraint clients_prospect_sin_cuenta;

drop index public.clients_prospect_email_idx;
create index clients_prospect_email_idx on public.clients (chef_id, lower(contact_email))
  where status = 'prospect' and profile_id is null;

-- ---------------------------------------------------------------------
-- submit_public_request: el cuerpo de 20261119150000_menu_web.sql, sin otro cambio que los
-- comentarios y bloques marcados «PR03» (búsqueda de la ficha y consentimiento de salud).
-- ---------------------------------------------------------------------

-- p: lo mismo que en 20261116120000_weekly_pricing.sql, más
--   wishes (array de uuids en texto, sin repetir y como mucho days; null / ausente = ninguno).
-- Devuelve {"request_id": uuid, "duplicate": bool, "estimate": jsonb, "menu": jsonb}.
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
  v_wishes       uuid[];
  v_saved_wishes uuid[];
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

  -- Platos elegidos en la pestaña «Menù»: uuids en texto (sin distinguir mayúsculas), sin repetir
  -- y como mucho uno por día, en el orden en que llegan; null / ausente = ninguno (la función de
  -- antes del menú no lo manda). Defensa (la Edge Function valida antes). Acá solo la forma: cuáles
  -- se guardan se decide al insertar el pedido. Se valida antes de buscar la clave, como weeks.
  case coalesce(jsonb_typeof(p -> 'wishes'), 'null')
    when 'null' then
      v_wishes := '{}';
    when 'array' then
      if exists (select 1 from jsonb_array_elements(p -> 'wishes') as e
                 where jsonb_typeof(e) <> 'string'
                    or (e #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
        raise exception 'invalid_wishes' using errcode = '22023';
      end if;
      v_wishes := array(select (t.e #>> '{}')::uuid
                        from jsonb_array_elements(p -> 'wishes') with ordinality as t(e, o)
                        order by t.o);
      if (select count(distinct w) from unnest(v_wishes) as w) <> cardinality(v_wishes) then
        raise exception 'invalid_wishes' using errcode = '22023';
      end if;
      -- Sin platos no se mira days: un days inválido lo sigue rechazando el insert, como antes.
      if cardinality(v_wishes) > 0 then
        if cardinality(v_wishes) > (p ->> 'days')::smallint then
          raise exception 'invalid_wishes' using errcode = '22023';
        end if;
      end if;
    else
      raise exception 'invalid_wishes' using errcode = '22023';
  end case;

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
  -- El menu sale de los platos guardados, no de los del reintento.
  if v_request_key is not null then
    perform pg_advisory_xact_lock(hashtextextended('public_request_key:' || v_chef_id::text || ':' || v_request_key::text, 0));

    select r.id, r.estimate, r.wishes
      into v_request_id, v_estimate, v_saved_wishes
    from public.requests r
    where r.chef_id = v_chef_id
      and r.request_key = v_request_key;

    if v_request_id is not null then
      return jsonb_build_object('request_id', v_request_id, 'duplicate', true, 'estimate', v_estimate,
                                'menu', private.request_menu(v_chef_id, v_saved_wishes));
    end if;
  end if;

  -- Cliente: un pedido a la vez por chef y email (evita dos prospectos gemelos).
  perform pg_advisory_xact_lock(hashtextextended('public_request:' || v_chef_id::text || ':' || v_email, 0));

  -- PR03: el formulario solo reutiliza un prospecto SIN CUENTA (profile_id is null: la ficha de una
  -- cuenta es de esa persona, no de quien escriba su email) y, si el pedido trae dato de salud, solo uno
  -- cuyo consentimiento de salud vigente sea de la misma versión (o que no tenga ninguno vigente: ahí
  -- no hay nada que cerrar). Con otra versión de salud no se reutiliza: nace una gemela, y la ficha de
  -- antes queda como estaba (cerrar su consentimiento purgaría sus restricciones). Sin dato de salud en
  -- el pedido no se mira la versión: no se escribe nada de salud. Entre las que sirven, la más nueva.
  select cl.id
    into v_client_id
  from public.clients cl
  where cl.chef_id = v_chef_id
    and cl.status = 'prospect'
    and cl.profile_id is null
    and lower(cl.contact_email) = v_email
    and (not v_restricted
         or not exists (select 1 from public.consents c1
                        where c1.client_id = cl.id and c1.kind = 'health_data' and c1.revoked_at is null)
         or exists (select 1 from public.consents c2
                    where c2.client_id = cl.id and c2.kind = 'health_data' and c2.revoked_at is null
                      and c2.text_version = v_health))
  order by cl.created_at desc, cl.id
  limit 1
  for update;

  -- Prospecto nuevo con los datos del pedido (también la gemela: otra versión de salud, o el email de
  -- una cuenta). Uno que ya existe no se toca: el email no está verificado y cualquiera puede escribir
  -- el de otra persona.
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

  -- Consentimientos. Privacy: con la misma versión del texto se conserva el vigente; una versión nueva
  -- reemplaza a la anterior, que queda cerrada (revoked_at) como traza (como hoy).
  if not exists (
    select 1 from public.consents c
    where c.client_id = v_client_id and c.kind = 'privacy' and c.revoked_at is null and c.text_version = v_privacy
  ) then
    update public.consents c set revoked_at = now()
     where c.client_id = v_client_id and c.kind = 'privacy' and c.revoked_at is null;
    insert into public.consents (chef_id, client_id, kind, text_version)
    values (v_chef_id, v_client_id, 'privacy', v_privacy);
  end if;

  -- Salud: antes que las restricciones. Sin restricciones nuevas no se toca: el consentimiento anterior
  -- cubre las copias de pedidos anteriores. PR03: acá NUNCA se cierra ni se reemplaza el consentimiento
  -- de salud de una ficha (cerrarlo dispararía consents_purge_health_data y borraría sus restricciones):
  -- la ficha elegida arriba no tiene ninguno vigente (el nuevo se agrega) o ya tiene este mismo.
  if v_restricted and not exists (
    select 1 from public.consents c
    where c.client_id = v_client_id and c.kind = 'health_data' and c.revoked_at is null and c.text_version = v_health
  ) then
    insert into public.consents (chef_id, client_id, kind, text_version)
    values (v_chef_id, v_client_id, 'health_data', v_health);
  end if;

  -- Restricciones del hogar: solo de un pedido semanal, y se suman a las que ya tenía la ficha (la
  -- misma versión de salud, o la gemela). Nunca se borran desde la web (las cura Evelyn).
  if v_restricted and v_type = 'week' then
    insert into public.client_restrictions (chef_id, client_id, allergen)
    select v_chef_id, v_client_id, a from unnest(v_allergens) as a
    on conflict on constraint client_restrictions_unica do nothing;
    insert into public.client_restrictions (chef_id, client_id, diet)
    select v_chef_id, v_client_id, d from unnest(v_diets) as d
    on conflict on constraint client_restrictions_unica do nothing;
  end if;

  -- Platos: solo los publicados de esta cocinera (la misma condición que get_public_menu), en el
  -- orden en que llegaron. Los demás se descartan sin error: uno que se desactivó entre la carga de
  -- la página y el envío, o un id que no es de un plato suyo, no traba el pedido.
  v_wishes := array(
    select t.w
    from unnest(v_wishes) with ordinality as t(w, o)
    where exists (select 1 from public.recipes r
                  where r.id = t.w
                    and r.chef_id = v_chef_id
                    and r.active
                    and r.catalog_visible
                    and r.description_it is not null)
    order by t.o);

  insert into public.requests (
    chef_id, client_id, type, status, adults, kids, days, meals, weeks, restrictions, no_allergies, wishes, notes,
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
    v_wishes,
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

  return jsonb_build_object('request_id', v_request_id, 'duplicate', false, 'estimate', v_estimate,
                            'menu', private.request_menu(v_chef_id, v_wishes));
end
$$;

comment on function public.submit_public_request(jsonb) is
  'Guarda un pedido del formulario público (Edge Function public-request): prospecto (nuevo, o uno sin cuenta con la misma versión de salud vigente: uno existente no se modifica, una ficha con cuenta nunca se reutiliza y con otra versión de salud nace una gemela), consentimientos, restricciones del hogar (solo de un pedido semanal, se suman), pedido con sus semanas, los platos elegidos (solo los publicados, en orden), la respuesta a la pregunta de alergias y la copia del contacto, y notificación, en una transacción. Idempotente por (chef_id, request_key). Devuelve {request_id, duplicate, estimate, menu}; menu son los platos guardados con sus nombres actuales, también en un reintento. Solo service role.';

-- create or replace conserva los privilegios; se repiten para que quede a la vista.
revoke all on function public.submit_public_request(jsonb) from public, anon, authenticated;
grant execute on function public.submit_public_request(jsonb) to service_role;
