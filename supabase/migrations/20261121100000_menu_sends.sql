-- =====================================================================
-- Radici · Envío del menú de cada semana y link de la clienta (proceso de presupuesto y menús del
-- 21/11/2026, SPEC 5.8). Tests: supabase/tests/database/20_menu_sends.test.sql.
--
-- Evelyn le manda a la clienta el menú de una semana (los platos, la lista de compras y la nota que
-- guarda save_session_menu) por email, por WhatsApp o por los dos. Cada mensaje lleva un link a una
-- página de la web donde la clienta lo ve entero y lo confirma o pide cambios: todavía no tiene
-- cuenta (M2), así que el link es la llave.
--
--   1. menu_sends: cada envío, con la foto de lo que se mandó (snapshot: los platos, la lista y la
--      nota ya en el idioma de la clienta), por dónde salió y lo que contestó la clienta. La página
--      muestra el último envío de cada semana tal como salió, aunque Evelyn edite el menú después, y
--      la confirmación vale para esa foto.
--   2. client_links: los links de la clienta. Cada envío crea uno al salir; la base guarda solo el
--      hash (sha-256) del token, nunca el token. Un link abre la reserva entera (todas sus semanas)
--      durante 120 días.
--   3. Funciones security definer, solo para la service role (las llaman las Edge Functions chef y
--      client-link; los ayudantes van en private, fuera de la API):
--        chef_menu_send_context    lo que hace falta para armar el mensaje de una semana.
--        chef_prepare_menu_send    guarda el envío, todavía sin salir: la vista previa.
--        chef_link_menu_send       al enviar: crea el link del mensaje y devuelve lo que hace falta
--                                  para armarlo (la foto, el idioma y el contacto).
--        chef_complete_menu_send   lo marca enviado, después de mandar el email (si iba por email).
--        client_link_view          la reserva que abre un link: semanas y último envío de cada una.
--        client_link_confirm_menu  la clienta confirma el menú de una semana.
--        client_link_request_changes  la clienta pide cambios, con su mensaje.
--
-- Nada de esto lo escribe la app: la cocina solo lee menu_sends (para saber qué salió y qué contestó
-- la clienta) y nadie fuera de la service role toca client_links.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. menu_sends
--
-- Un envío nace al pedir la vista previa (sent_at null) y sale cuando Evelyn lo manda: si va por
-- email, la función chef lo marca enviado recién cuando el email salió. Una vista previa que no se
-- mandó queda sin sent_at y nunca se muestra. El envío vigente de una semana es el último con
-- sent_at (con el mismo sent_at, el de id mayor: el mismo orden en todas las funciones).
--
-- snapshot: lo arma la función chef, en el idioma de la clienta (locale), con los platos (nombre,
-- descripción, alérgenos, dieta, porciones y foto), la lista de compras, la nota y las fechas de la
-- reserva. Lo leen la página de la clienta y el email. La base solo controla que sea un objeto y su
-- tamaño. Nunca lleva la dirección, las alergias de la clienta ni nada de pagos.
-- translated: los nombres de la lista de compras se tradujeron solos al idioma de la clienta (la nota
-- sale como la escribió Evelyn: decisión de Nicolas del 22/11/2026, SPEC §6).
-- fingerprint: la huella de lo que entra en la foto al prepararla (private.menu_send_fingerprint:
-- día y hora de la sesión, semanas vivas de la reserva, versión del menú y los platos del catálogo con
-- sus alérgenos). Si cambia antes de mandarlo, el envío no sale (menu_changed).
-- sent_via: 'email', 'whatsapp' o los dos.
-- client_confirmed_at: la clienta confirmó ese menú. changes_*: la clienta pidió cambios (con un
-- mensaje). Solo una de las dos cosas, y solo en un envío que salió.
-- ---------------------------------------------------------------------
create table public.menu_sends (
  id                   uuid primary key default gen_random_uuid(),
  chef_id              uuid not null,
  session_id           uuid not null,
  request_id           uuid not null,
  menu_version         int not null,
  locale               text not null,
  snapshot             jsonb not null,
  translated           boolean not null default false,
  fingerprint          text,
  created_at           timestamptz not null default now(),
  sent_at              timestamptz,
  sent_via             text[],
  client_confirmed_at  timestamptz,
  changes_requested_at timestamptz,
  changes_text         text,
  unique (id, chef_id),
  foreign key (session_id, chef_id) references public.sessions (id, chef_id) on delete cascade,
  foreign key (request_id, chef_id) references public.requests (id, chef_id) on delete cascade,
  constraint menu_sends_version_valida check (menu_version >= 1),
  constraint menu_sends_locale_valido check (locale in ('it', 'es', 'en')),
  constraint menu_sends_snapshot_valido check (jsonb_typeof(snapshot) = 'object' and pg_column_size(snapshot) <= 65536),
  constraint menu_sends_via_con_envio check (
    (sent_at is null and sent_via is null)
    or (sent_at is not null
        and sent_via is not null
        and cardinality(sent_via) between 1 and 2
        and sent_via <@ array['email', 'whatsapp']
        and (cardinality(sent_via) = 1 or sent_via[1] <> sent_via[2]))),
  constraint menu_sends_respuesta_tras_envio check (
    sent_at is not null or (client_confirmed_at is null and changes_requested_at is null)),
  constraint menu_sends_una_respuesta check (client_confirmed_at is null or changes_requested_at is null),
  constraint menu_sends_cambios_con_texto check (
    (changes_requested_at is null) = (changes_text is null)
    and (changes_text is null
         or (char_length(changes_text) between 1 and 1000
             and changes_text = btrim(changes_text)
             and replace(changes_text, E'\n', '') !~ '[[:cntrl:]]')))
);

create index menu_sends_por_sesion on public.menu_sends (session_id, sent_at desc);

comment on table public.menu_sends is
  'Envíos del menú de una semana a la clienta (SPEC 5.8): la foto de lo que se mandó (snapshot, en su idioma), por dónde salió y su respuesta (confirmó o pidió cambios). sent_at null = vista previa que no salió. Lo escriben solo las funciones de la service role; la cocina lo lee.';
comment on column public.menu_sends.snapshot is
  'Lo que ve la clienta, tal como salió: platos, lista de compras, nota y fechas, en su idioma. Nunca dirección, alergias de la clienta ni pagos.';

alter table public.menu_sends enable row level security;

create policy "menu_sends: la cocinera lee los suyos"
  on public.menu_sends for select to authenticated
  using (chef_id = (select public.current_chef_id()));

revoke all on table public.menu_sends from public, anon, authenticated, service_role;
grant select on table public.menu_sends to authenticated;
grant select, insert, update, delete on table public.menu_sends to service_role;

-- ---------------------------------------------------------------------
-- 2. client_links
--
-- token_hash: sha-256 del token en hexadecimal (64 caracteres). El token (32 bytes al azar) lo
-- genera la función chef al enviar, va en el link del mensaje (en el fragmento: #t=…, que no llega a
-- ningún servidor ni al Referer) y no se guarda en ningún lado: ni en la base ni en la vista previa,
-- que muestra el mensaje sin el link. Cada envío crea un link; todos los de una
-- reserva valen a la vez, así un mensaje viejo sigue abriendo la reserva. Vencen a los 120 días
-- (una reserva dura hasta 8 semanas).
-- ---------------------------------------------------------------------
create table public.client_links (
  token_hash  text primary key,
  chef_id     uuid not null,
  request_id  uuid not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '120 days',
  foreign key (request_id, chef_id) references public.requests (id, chef_id) on delete cascade,
  constraint client_links_hash_valido check (token_hash ~ '^[0-9a-f]{64}$'),
  constraint client_links_vence_despues check (expires_at > created_at)
);

create index client_links_por_pedido on public.client_links (request_id);

comment on table public.client_links is
  'Links de la clienta a su reserva (SPEC 5.8): el hash sha-256 del token, nunca el token. Un link por envío; vencen a los 120 días. Solo la service role.';

alter table public.client_links enable row level security;
revoke all on table public.client_links from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.client_links to service_role;

-- ---------------------------------------------------------------------
-- private.menu_send_fingerprint(p_session_id): la huella (md5) de todo lo que entra en la foto de un
-- envío y puede cambiar sin save_session_menu: el día y la hora de la sesión, las semanas vivas de la
-- reserva (k de N y la lista de fechas), la versión del menú (platos, porciones, lista y nota) y, de
-- cada plato, lo que sale del catálogo (nombres, descripciones, dieta, foto y alérgenos). La foto se
-- arma con chef_menu_send_context; prepare, link y complete comparan contra la huella de ese momento.
-- ---------------------------------------------------------------------
create function private.menu_send_fingerprint(p_session_id uuid)
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
               where d.session_id = p_session_id)
  )::text)
$$;

revoke all on function private.menu_send_fingerprint(uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3a. public.chef_menu_send_context(p_chef_id, p_session_id)
--
-- Todo lo que necesita la función chef para armar el mensaje de una semana, en un solo jsonb:
--   session  {id, date, start, status, requestId, week, weeks}: week/weeks como «Semana k de N» de
--            la app (las sesiones no canceladas del pedido, por fecha y hora).
--   weeks    [{sessionId, date, start}]: esas mismas, para la lista de fechas del mensaje.
--   request  {id, type, locale, adults, kids, days, meals}.
--   contact  {name, email, phone}: los del pedido de la web (requests.contact) si los tiene; si no,
--            los de la ficha. La app se los muestra a Evelyn en la vista previa antes de mandar.
--   chef     {displayName}.
--   menu     {version, note, allergensConfirmed, dishes: [...], items: [...]}: los platos con sus
--            nombres y descripciones en los tres idiomas, alérgenos, dieta, foto y porciones; los
--            renglones de la lista en orden.
--   lastSend el último envío que salió ({id, menuVersion, sentAt, sentVia, confirmedAt,
--            changesRequestedAt}) o null.
--   fingerprint  la huella de todo eso (private.menu_send_fingerprint), que la función chef le pasa a
--            chef_prepare_menu_send: si algo cambió mientras armaba la foto, no se guarda.
-- Errores: P0002 session_not_found (no existe o es de otra cocina), P0002 menu_not_found (la semana
-- no tiene menú guardado), 55000 session_not_editable (cancelada, cocinada o cobrada; DETAIL: el
-- estado), 55000 session_without_request (una sesión sin pedido: no hay reserva que mostrar en el
-- link).
-- ---------------------------------------------------------------------
create function public.chef_menu_send_context(p_chef_id uuid, p_session_id uuid)
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
    'fingerprint', private.menu_send_fingerprint(p_session_id));
end
$$;

comment on function public.chef_menu_send_context(uuid, uuid) is
  'Lo que la función chef necesita para armar el mensaje del menú de una semana (SPEC 5.8): sesión con «Semana k de N», fechas de la reserva, pedido, contacto (el del pedido de la web o el de la ficha), cocinera, menú (platos en los tres idiomas, alérgenos, dieta, foto, porciones; lista; nota; versión), el último envío y la huella de todo eso. Errores: P0002 session_not_found / menu_not_found; 55000 session_not_editable / session_without_request. Solo service_role.';

-- ---------------------------------------------------------------------
-- 3b. public.chef_prepare_menu_send(...)
--
-- La vista previa: guarda el envío sin salir (sent_at null) con su foto. La versión tiene que ser la
-- del menú guardado y p_fingerprint la huella con que se armó la foto (la de chef_menu_send_context):
-- si Evelyn cambió el menú, movió la semana, se canceló otra semana de la reserva o cambió un plato
-- del catálogo mientras tanto, menu_changed. El menú tiene que tener algún plato. Devuelve {sendId}.
-- Errores: P0002 session_not_found / menu_not_found; 55000 session_not_editable (DETAIL: el estado),
-- session_without_request; 40001 menu_changed; 22023 menu_empty, invalid_locale, invalid_snapshot.
-- ---------------------------------------------------------------------
create function public.chef_prepare_menu_send(
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

  -- El menú, bloqueado: un guardado de la app espera a que termine esta transacción.
  select m.version into v_version from public.session_menus m where m.session_id = p_session_id for update;
  if not found then
    raise exception 'menu_not_found' using errcode = 'P0002';
  end if;
  if p_menu_version is distinct from v_version then
    raise exception 'menu_changed' using errcode = '40001';
  end if;
  if p_fingerprint is distinct from private.menu_send_fingerprint(p_session_id) then
    raise exception 'menu_changed' using errcode = '40001';
  end if;
  if not exists (select 1 from public.session_menu d where d.session_id = p_session_id) then
    raise exception 'menu_empty' using errcode = '22023';
  end if;

  insert into public.menu_sends (chef_id, session_id, request_id, menu_version, locale, snapshot, translated, fingerprint)
  values (p_chef_id, p_session_id, v_session.request_id, v_version, p_locale, p_snapshot, coalesce(p_translated, false),
          p_fingerprint)
  returning id into v_send_id;

  return jsonb_build_object('sendId', v_send_id);
end
$$;

comment on function public.chef_prepare_menu_send(uuid, uuid, int, text, jsonb, boolean, text) is
  'Vista previa del envío del menú de una semana (SPEC 5.8): guarda el envío sin salir con la foto de lo que ve la clienta y su huella. Exige la versión guardada del menú, la huella con que se armó la foto y algún plato. Devuelve {sendId}. Errores: P0002 session_not_found / menu_not_found; 55000 session_not_editable, session_without_request; 40001 menu_changed; 22023 menu_empty, invalid_locale, invalid_snapshot. Solo service_role.';

-- ---------------------------------------------------------------------
-- 3c. public.chef_link_menu_send(p_chef_id, p_send_id, p_token_hash)
--
-- Al enviar, antes de mandar el email: crea el link del mensaje (el hash del token) y devuelve lo
-- que la función chef necesita para armarlo: {sendId, sessionId, requestId, locale, snapshot,
-- contact: {name, email, phone}, chefName}. El contacto es el de ahora (el del pedido de la web o
-- el de la ficha, como en chef_menu_send_context). Valida lo mismo que el envío: si el menú, el día
-- o la hora, las semanas de la reserva o un plato del catálogo cambiaron desde la vista previa
-- (menu_changed: la huella) o la sesión ya no se arma, no crea nada. Un envío que ya salió no se
-- vuelve a mandar (already_sent).
-- Errores: P0002 send_not_found; 22023 invalid_token; 55000 already_sent, session_not_editable
-- (DETAIL: el estado); 40001 menu_changed; 23505 un token repetido (la función genera otro).
-- ---------------------------------------------------------------------
create function public.chef_link_menu_send(p_chef_id uuid, p_send_id uuid, p_token_hash text)
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
  if v_version is distinct from v_send.menu_version
     or v_send.fingerprint is distinct from private.menu_send_fingerprint(v_send.session_id) then
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
  'Al enviar el menú de una semana (SPEC 5.8), antes del email: crea el link del mensaje (el hash sha-256 del token) y devuelve la foto, el idioma, el contacto de ahora y el nombre de la cocinera para armarlo. Errores: P0002 send_not_found; 22023 invalid_token; 55000 already_sent / session_not_editable; 40001 menu_changed; 23505 token repetido. Solo service_role.';

-- ---------------------------------------------------------------------
-- 3d. public.chef_complete_menu_send(p_chef_id, p_send_id, p_via)
--
-- Marca enviado un envío preparado, cuando ya salió por p_via ('email', 'whatsapp' o los dos): si
-- iba por email, la función chef lo llama después de que el email salió. Si algo de la foto cambió
-- desde la vista previa (menu_changed: la versión o la huella) o la sesión ya no se puede armar, no
-- se marca: hay que pedir otra vista previa. Si ya estaba enviado (un reintento), no cambia nada y devuelve lo que había.
-- Devuelve {sendId, sentAt, sentVia}.
-- Errores: P0002 send_not_found; 22023 invalid_via; 55000 session_not_editable (DETAIL: el estado);
-- 40001 menu_changed.
-- ---------------------------------------------------------------------
create function public.chef_complete_menu_send(p_chef_id uuid, p_send_id uuid, p_via text[])
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
  if v_version is distinct from v_send.menu_version
     or v_send.fingerprint is distinct from private.menu_send_fingerprint(v_send.session_id) then
    raise exception 'menu_changed' using errcode = '40001';
  end if;

  update public.menu_sends ms
  set sent_at  = now(),
      sent_via = array(select v from unnest(p_via) as v order by v)
  where ms.id = p_send_id
  returning * into v_send;

  return jsonb_build_object('sendId', v_send.id, 'sentAt', v_send.sent_at, 'sentVia', to_jsonb(v_send.sent_via));
end
$$;

comment on function public.chef_complete_menu_send(uuid, uuid, text[]) is
  'Marca enviado un envío del menú preparado por chef_prepare_menu_send, cuando ya salió por p_via (email, whatsapp o los dos). Idempotente: si ya estaba enviado devuelve lo que había. Errores: P0002 send_not_found; 22023 invalid_via; 55000 session_not_editable; 40001 menu_changed (hay que pedir otra vista previa). Devuelve {sendId, sentAt, sentVia}. Solo service_role.';

-- ---------------------------------------------------------------------
-- 3e. Link de la clienta
--
-- private.client_link_request(p_token_hash): el pedido de un link vigente, o null.
-- ---------------------------------------------------------------------
create function private.client_link_request(p_token_hash text)
returns uuid
language sql
stable
security invoker
set search_path = ''
as $$
  select l.request_id
  from public.client_links l
  where l.token_hash = p_token_hash and l.expires_at > now()
$$;

revoke all on function private.client_link_request(text) from public, anon, authenticated, service_role;

-- public.client_link_view(p_token_hash): la reserva que abre un link vigente, o null (vencido, que
-- no existe o con una forma que no es un hash). Devuelve:
--   {requestId, locale, chefName, clientName, weeks: [{sessionId, date, start, status, week, weeks,
--    send: {id, sentAt, snapshot, confirmedAt, changesRequestedAt} | null}]}
-- Las semanas son las no canceladas, por fecha; send es el último envío que salió de esa semana.
-- clientName es el nombre con que llegó el pedido (requests.contact, el mismo del mensaje) o, si no
-- tiene, el de la ficha: la función client-link deja solo un nombre de pila que parezca un nombre.
-- Nada de dirección, contacto, alergias ni precios.
create function public.client_link_view(p_token_hash text)
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
                          'confirmedAt', ms.client_confirmed_at, 'changesRequestedAt', ms.changes_requested_at)
                 from public.menu_sends ms
                 where ms.session_id = w.id and ms.sent_at is not null
                 order by ms.sent_at desc, ms.id desc
                 limit 1))
               order by w.n)
      from (select s.id, s."date", s.start_time, s.status,
                   row_number() over (order by s."date", s.start_time, s.id)::int as n,
                   count(*) over ()::int as total
            from public.sessions s
            where s.request_id = v_request.id and s.status <> 'cancelled') w), '[]'::jsonb));
end
$$;

comment on function public.client_link_view(text) is
  'La reserva que abre un link de la clienta (SPEC 5.8), con el hash sha-256 del token: semanas no canceladas por fecha y el último envío del menú de cada una (la foto tal como salió y la respuesta). null si el link no vale. Nada de dirección, contacto, alergias ni precios. Solo service_role.';

-- El envío de un link al que la clienta contesta: tiene que ser de esa reserva, haber salido, ser el
-- último de su semana (si Evelyn mandó otro después, se contesta el nuevo: menu_outdated) y su semana
-- no puede estar cancelada (session_cancelled). Bloquea la fila. Errores: P0002 link_not_found,
-- send_not_found; 55000 menu_outdated, session_cancelled.
create function private.client_link_send_for_answer(p_token_hash text, p_send_id uuid)
returns public.menu_sends
language plpgsql
volatile
security invoker
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
  where ms.id = p_send_id and ms.request_id = v_request_id and ms.sent_at is not null
  for update;
  if not found then
    raise exception 'send_not_found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.menu_sends o
             where o.session_id = v_send.session_id and o.sent_at is not null
               and (o.sent_at, o.id) > (v_send.sent_at, v_send.id)) then
    raise exception 'menu_outdated' using errcode = '55000';
  end if;
  if exists (select 1 from public.sessions s where s.id = v_send.session_id and s.status = 'cancelled') then
    raise exception 'session_cancelled' using errcode = '55000';
  end if;
  return v_send;
end
$$;

revoke all on function private.client_link_send_for_answer(text, uuid) from public, anon, authenticated, service_role;

-- La respuesta para el aviso a Evelyn: el envío, la semana y la clienta (el nombre con que llegó el
-- pedido o, si no tiene, el de la ficha: el mismo que ve Evelyn en la bandeja). Lo usa la función
-- client-link para el email a la cocina (que es de Evelyn: ahí sí va el nombre de la clienta).
create function private.client_link_answer(p_send public.menu_sends, p_already boolean)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'sendId', p_send.id,
    'sessionId', p_send.session_id,
    'requestId', p_send.request_id,
    'chefId', p_send.chef_id,
    'already', p_already,
    'confirmedAt', p_send.client_confirmed_at,
    'changesRequestedAt', p_send.changes_requested_at,
    'date', s."date",
    'start', to_char(s.start_time, 'HH24:MI'),
    'week', (select o.n from (select x.id, row_number() over (order by x."date", x.start_time, x.id)::int as n
                              from public.sessions x
                              where x.request_id = s.request_id and x.status <> 'cancelled') o
             where o.id = s.id),
    'weeks', (select count(*)::int from public.sessions x where x.request_id = s.request_id and x.status <> 'cancelled'),
    'clientName', coalesce(nullif(btrim(r.contact ->> 'name'), ''), c.display_name),
    'locale', p_send.locale)
  from public.sessions s
  join public.clients c on c.id = s.client_id
  join public.requests r on r.id = p_send.request_id
  where s.id = p_send.session_id
$$;

revoke all on function private.client_link_answer(public.menu_sends, boolean) from public, anon, authenticated, service_role;

-- public.client_link_confirm_menu(p_token_hash, p_send_id): la clienta confirma el menú de una
-- semana. Idempotente (already = true si ya estaba confirmado). Si había pedido cambios para ese
-- envío, ya no puede confirmarlo: Evelyn tiene que mandar el menú de nuevo (changes_requested).
-- Errores: P0002 link_not_found, send_not_found; 55000 menu_outdated, session_cancelled,
-- changes_requested.
create function public.client_link_confirm_menu(p_token_hash text, p_send_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_send public.menu_sends;
begin
  v_send := private.client_link_send_for_answer(p_token_hash, p_send_id);
  if v_send.client_confirmed_at is not null then
    return private.client_link_answer(v_send, true);
  end if;
  if v_send.changes_requested_at is not null then
    raise exception 'changes_requested' using errcode = '55000';
  end if;
  update public.menu_sends ms set client_confirmed_at = now() where ms.id = v_send.id returning * into v_send;
  return private.client_link_answer(v_send, false);
end
$$;

comment on function public.client_link_confirm_menu(text, uuid) is
  'La clienta confirma el menú de una semana desde su link (SPEC 5.8). Idempotente (already). Errores: P0002 link_not_found / send_not_found; 55000 menu_outdated (hay un envío más nuevo) / session_cancelled (la semana se canceló) / changes_requested (ya pidió cambios: Evelyn manda otro). Devuelve lo necesario para avisarle a Evelyn. Solo service_role.';

-- public.client_link_request_changes(p_token_hash, p_send_id, p_text): la clienta pide cambios para
-- el menú de una semana, con un mensaje (1 a 1000 caracteres, admite saltos de línea; los \r\n
-- pasan a \n). Si ya lo confirmó, no: los cambios se hablan con Evelyn (already_confirmed). Si ya
-- había pedido cambios, el mensaje nuevo reemplaza al anterior.
-- Errores: P0002 link_not_found, send_not_found; 55000 menu_outdated, session_cancelled,
-- already_confirmed; 22023 invalid_text.
create function public.client_link_request_changes(p_token_hash text, p_send_id uuid, p_text text)
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
  v_send := private.client_link_send_for_answer(p_token_hash, p_send_id);
  if v_send.client_confirmed_at is not null then
    raise exception 'already_confirmed' using errcode = '55000';
  end if;
  update public.menu_sends ms
  set changes_requested_at = now(), changes_text = v_text
  where ms.id = v_send.id
  returning * into v_send;
  return private.client_link_answer(v_send, false);
end
$$;

comment on function public.client_link_request_changes(text, uuid, text) is
  'La clienta pide cambios para el menú de una semana desde su link, con un mensaje de 1 a 1000 caracteres (SPEC 5.8). Errores: P0002 link_not_found / send_not_found; 55000 menu_outdated / session_cancelled / already_confirmed; 22023 invalid_text. Devuelve lo necesario para avisarle a Evelyn. Solo service_role.';

-- Solo la service role (las Edge Functions chef y client-link).
revoke all on function public.chef_menu_send_context(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.chef_prepare_menu_send(uuid, uuid, int, text, jsonb, boolean, text) from public, anon, authenticated, service_role;
revoke all on function public.chef_link_menu_send(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.chef_complete_menu_send(uuid, uuid, text[]) from public, anon, authenticated, service_role;
revoke all on function public.client_link_view(text) from public, anon, authenticated, service_role;
revoke all on function public.client_link_confirm_menu(text, uuid) from public, anon, authenticated, service_role;
revoke all on function public.client_link_request_changes(text, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.chef_menu_send_context(uuid, uuid) to service_role;
grant execute on function public.chef_prepare_menu_send(uuid, uuid, int, text, jsonb, boolean, text) to service_role;
grant execute on function public.chef_link_menu_send(uuid, uuid, text) to service_role;
grant execute on function public.chef_complete_menu_send(uuid, uuid, text[]) to service_role;
grant execute on function public.client_link_view(text) to service_role;
grant execute on function public.client_link_confirm_menu(text, uuid) to service_role;
grant execute on function public.client_link_request_changes(text, uuid, text) to service_role;
