-- =====================================================================
-- Radici · Libro del menú: los ingredientes de cada plato en el envío (SPEC 5.8, «Libro del menú»).
-- Tests: supabase/tests/database/23_menu_book.test.sql.
--
-- Nicolas, 22/11/2026: «un menú tipo libro de menú de restaurante […] un plato por hoja, la
-- descripción, los ingredientes, la foto arriba centrada y grande». La clienta abre el libro desde su
-- link (/prenotazione/#t=…&libro=<sesión>) y ve la foto del envío: hasta acá los platos iban sin
-- ingredientes. Decisión de Nicolas: solo los nombres, sin cantidades.
--
--   1. private.recipe_ingredient_names(p_recipe_id): los nombres de los ingredientes de un plato, en el
--      orden en que los escribió Evelyn (position), recortados y sin repetir (sin distinguir mayúsculas:
--      queda el primero). Nunca la cantidad, la unidad ni la sección: eso sigue siendo solo de la
--      cocinera (recipe_ingredients no cambia de RLS; la clienta ve los nombres solo en la foto).
--   2. chef_menu_send_context: igual que en 20261121120000_quotes.sql, más ingredients en cada plato.
--   3. private.menu_send_fingerprint: igual que en 20261121120000_quotes.sql, más los ingredientes de
--      cada plato: si Evelyn cambia un nombre mientras se arma la foto (o entre la vista previa y el
--      envío), la foto no se guarda ni sale (menu_changed). Una cantidad, una unidad o una sección no
--      cambian la huella: no están en la foto.
--
-- Las dos funciones salen de la misma ayuda, así la huella cubre exactamente lo que entra en la foto.
--
-- Despliegue: una vista previa que se armó antes de esta migración y todavía no salió tiene la huella
-- vieja: al mandarla da menu_changed una vez y hace falta otra vista previa (la app ya lo ofrece).
-- Las fotos que ya salieron no cambian: el libro las muestra sin ingredientes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. private.recipe_ingredient_names
-- ---------------------------------------------------------------------
create function private.recipe_ingredient_names(p_recipe_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(u.name order by u.position), '[]'::jsonb)
  from (select distinct on (lower(btrim(i.name))) btrim(i.name) as name, i.position
        from public.recipe_ingredients i
        where i.recipe_id = p_recipe_id and btrim(i.name) <> ''
        order by lower(btrim(i.name)), i.position) u
$$;

comment on function private.recipe_ingredient_names(uuid) is
  'Los nombres de los ingredientes de un plato para la foto del envío (libro del menú, SPEC 5.8): en el orden de position, recortados y sin repetir sin distinguir mayúsculas (queda el primero). Nunca cantidades, unidades ni secciones. jsonb: una lista de textos ([] sin ingredientes).';

revoke all on function private.recipe_ingredient_names(uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. La huella de la foto: la de 20261121120000_quotes.sql, más los ingredientes de cada plato.
-- ---------------------------------------------------------------------
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
                               from public.recipe_allergens a where a.recipe_id = r.id),
                 'ingredients', private.recipe_ingredient_names(r.id))
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

-- ---------------------------------------------------------------------
-- 3. chef_menu_send_context: el de 20261121120000_quotes.sql, más ingredients en cada plato.
-- ---------------------------------------------------------------------
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
                                        from public.recipe_allergens a where a.recipe_id = r.id), '[]'::jsonb),
                 'ingredients', private.recipe_ingredient_names(r.id))
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
  'Lo que la función chef necesita para armar el mensaje del menú de una semana (SPEC 5.8): sesión con «Semana k de N», fechas de la reserva, pedido, contacto (el del pedido de la web o el de la ficha), cocinera, menú (platos en los tres idiomas, alérgenos, dieta, foto, porciones y los nombres de sus ingredientes, para el libro del menú; lista; nota; versión), el último envío, si la semana es de un presupuesto abierto el presupuesto (quote: versión, si ya salió, plazo, si es su primera semana y sus términos) y la huella de todo eso. Errores: P0002 session_not_found / menu_not_found; 55000 session_not_editable / session_without_request. Solo service_role.';
