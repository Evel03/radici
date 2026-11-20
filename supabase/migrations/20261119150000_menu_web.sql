-- =====================================================================
-- Radici · Pestaña «Menù» del formulario de pedido (la base)
-- Tests: supabase/tests/database/17_menu_web.test.sql.
--
-- Pedido de Evelyn del 19/11/2026: en el formulario de pedido, una pestaña «Menù» donde el cliente
-- tilda platos según los días elegidos, cada uno con una descripción corta; lo elegido le aparece a
-- Evelyn en su área como aviso. Decisión de Nicolas: hasta un plato por día elegido (days, de 1 a
-- 7) y opcional; si tilda menos o ninguno, el resto lo propone Evelyn, que tiene la última palabra
-- (alergias, temporada). Un catálogo vacío nunca traba el envío. Es el primero de tres PRs: esta
-- base; la Edge Function y la web; la app.
--
--   1. recipes: description_it, description_es y description_en, como los nombres: null, o de 1 a
--      200 caracteres, sin espacios al borde y sin caracteres de control. Un plato está publicado
--      (sale en la web) si está activo, visible en el catálogo y tiene descripción en italiano. La
--      descripción es pública: el cliente la lee con la política de siempre (las recetas activas y
--      visibles de su cocinera), como el nombre.
--   2. save_recipe acepta las tres descripciones: texto o null ("" o solo espacios = null). Como
--      name_es: al crear, la que no viene queda null; al actualizar, la que no viene no se toca.
--   3. public.get_public_menu(p_chef_id): los platos publicados de una cocinera, para la web (la
--      Edge Function public-request). Solo service_role.
--   4. submit_public_request guarda p.wishes (los platos elegidos, en orden) en requests.wishes, que
--      existe desde la primera migración sin uso, y devuelve además menu: los platos guardados, con
--      sus nombres. private.request_menu arma ese menu, igual en un pedido nuevo y en un reintento.
--
-- Despliegue:
--   * wishes es opcional y la respuesta solo suma una clave: la función que sigue en producción
--     guarda pedidos como antes mientras se despliega la nueva.
--   * Ningún plato tiene descripción al desplegar: la web no muestra ninguno hasta que Evelyn las
--     escriba desde la app.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. recipes: descripción corta
--
-- Los mismos checks que los nombres (recipes_name_*_valido, 20261116170000_recipe_catalog.sql),
-- con 200 caracteres: una línea que la web muestra al lado del nombre. Sin saltos de línea.
-- ---------------------------------------------------------------------
alter table public.recipes
  add column description_it text,
  add column description_es text,
  add column description_en text,
  add constraint recipes_description_it_valida check (
    description_it is null
    or (char_length(description_it) between 1 and 200 and description_it = btrim(description_it)
        and description_it !~ '[[:cntrl:]]')),
  add constraint recipes_description_es_valida check (
    description_es is null
    or (char_length(description_es) between 1 and 200 and description_es = btrim(description_es)
        and description_es !~ '[[:cntrl:]]')),
  add constraint recipes_description_en_valida check (
    description_en is null
    or (char_length(description_en) between 1 and 200 and description_en = btrim(description_en)
        and description_en !~ '[[:cntrl:]]'));

comment on column public.recipes.description_it is
  'Descripción corta del plato en italiano (hasta 200 caracteres), la que la web muestra al lado del nombre. Sin ella el plato no sale en la web (get_public_menu). null = sin descripción.';
comment on column public.recipes.description_es is
  'Descripción corta del plato en español. null = sin traducción (la web usa la italiana).';
comment on column public.recipes.description_en is
  'Descripción corta del plato en inglés. null = sin traducción (la web usa la italiana).';

-- ---------------------------------------------------------------------
-- 2. public.save_recipe(p jsonb)
--
-- p: lo mismo que en 20261116170000_recipe_catalog.sql, más
--   description_it, description_es, description_en  texto o null ("" también es null).
-- Como los nombres traducidos: si no vienen no se tocan (en un plato nuevo, null). Una descripción
-- vacía, larga o con caracteres de control la rechaza el check de su idioma (23514). Lo demás, igual.
-- ---------------------------------------------------------------------
create or replace function public.save_recipe(p jsonb)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  -- Las claves que entiende: cualquier otra es invalid_payload.
  c_keys constant text[] := array['id', 'name_it', 'name_es', 'name_en', 'description_it', 'description_es',
                                  'description_en', 'diet', 'season_months', 'fridge_days', 'freezable',
                                  'freezer_days', 'notes', 'active', 'catalog_visible', 'allergens',
                                  'ingredients'];
  c_ingredient_keys constant text[] := array['name', 'section', 'quantity', 'unit'];
  v_chef_id     uuid := public.current_chef_id();
  v_id          uuid;
  v_name_it     text;
  v_name_es     text;
  v_name_en     text;
  v_desc_it     text;
  v_desc_es     text;
  v_desc_en     text;
  v_diet        public.diet;
  v_months      smallint[];
  v_fridge      smallint;
  v_freezable   boolean;
  v_freezer     smallint;
  v_notes       text;
  v_active      boolean;
  v_visible     boolean;
  v_allergens   public.allergen[];
  v_key         text;
  v_item        jsonb;
  v_i           int;
begin
  if v_chef_id is null then
    raise exception 'not_a_chef' using errcode = '42501';
  end if;

  if jsonb_typeof(p) is distinct from 'object' then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'p';
  end if;

  select min(k) into v_key from jsonb_object_keys(p) as k where k <> all (c_keys);
  if v_key is not null then
    raise exception 'invalid_payload' using errcode = '22023', detail = v_key;
  end if;

  if jsonb_typeof(p -> 'id') is distinct from 'string'
     or (p ->> 'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'id';
  end if;
  v_id := (p ->> 'id')::uuid;

  -- Nombres, descripciones y notas: se recortan los espacios. Uno vacío o larguísimo lo rechazan
  -- los checks.
  if jsonb_typeof(p -> 'name_it') is distinct from 'string' then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'name_it';
  end if;
  v_name_it := btrim(p ->> 'name_it');

  foreach v_key in array array['name_es', 'name_en', 'description_it', 'description_es', 'description_en', 'notes'] loop
    if coalesce(jsonb_typeof(p -> v_key), 'null') not in ('string', 'null') then
      raise exception 'invalid_payload' using errcode = '22023', detail = v_key;
    end if;
  end loop;
  v_name_es := nullif(btrim(p ->> 'name_es'), '');
  v_name_en := nullif(btrim(p ->> 'name_en'), '');
  v_desc_it := nullif(btrim(p ->> 'description_it'), '');
  v_desc_es := nullif(btrim(p ->> 'description_es'), '');
  v_desc_en := nullif(btrim(p ->> 'description_en'), '');
  v_notes   := nullif(btrim(p ->> 'notes'), '');

  if coalesce(jsonb_typeof(p -> 'diet'), 'null') <> 'null' then
    if jsonb_typeof(p -> 'diet') <> 'string'
       or (p ->> 'diet') <> all (enum_range(null::public.diet)::text[]) then
      raise exception 'invalid_payload' using errcode = '22023', detail = 'diet';
    end if;
    v_diet := (p ->> 'diet')::public.diet;
  end if;

  -- Meses en orden. Fuera de 1 a 12, repetidos o ninguno los rechaza el check de recipes.
  case coalesce(jsonb_typeof(p -> 'season_months'), 'null')
    when 'null' then
      v_months := null;
    when 'array' then
      if exists (select 1 from jsonb_array_elements(p -> 'season_months') as e
                 where jsonb_typeof(e) <> 'number' or e::text !~ '^[0-9]{1,2}$') then
        raise exception 'invalid_payload' using errcode = '22023', detail = 'season_months';
      end if;
      v_months := array(select e::text::smallint
                        from jsonb_array_elements(p -> 'season_months') as e
                        order by 1);
    else
      raise exception 'invalid_payload' using errcode = '22023', detail = 'season_months';
  end case;

  -- Conservación y estado: no admiten null; si no vienen, no se tocan.
  foreach v_key in array array['fridge_days', 'freezer_days'] loop
    if p ? v_key and (jsonb_typeof(p -> v_key) <> 'number' or (p -> v_key)::text !~ '^[0-9]{1,4}$') then
      raise exception 'invalid_payload' using errcode = '22023', detail = v_key;
    end if;
  end loop;
  v_fridge  := (p ->> 'fridge_days')::smallint;
  v_freezer := (p ->> 'freezer_days')::smallint;

  foreach v_key in array array['freezable', 'active', 'catalog_visible'] loop
    if p ? v_key and jsonb_typeof(p -> v_key) <> 'boolean' then
      raise exception 'invalid_payload' using errcode = '22023', detail = v_key;
    end if;
  end loop;
  v_freezable := (p ->> 'freezable')::boolean;
  v_active    := (p ->> 'active')::boolean;
  v_visible   := (p ->> 'catalog_visible')::boolean;

  -- Alérgenos: lista obligatoria ([] = ninguno), sin repetir.
  if jsonb_typeof(p -> 'allergens') is distinct from 'array' then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'allergens';
  end if;
  select min(t.o) - 1 into v_i
  from jsonb_array_elements(p -> 'allergens') with ordinality as t(e, o)
  where jsonb_typeof(t.e) <> 'string'
     or (t.e #>> '{}') <> all (enum_range(null::public.allergen)::text[]);
  if v_i is not null then
    raise exception 'invalid_payload' using errcode = '22023', detail = format('allergens[%s]', v_i);
  end if;
  v_allergens := array(select distinct (e #>> '{}')::public.allergen
                       from jsonb_array_elements(p -> 'allergens') as e
                       order by 1);

  -- Ingredientes: lista obligatoria ([] = ninguno). Acá solo la forma; nombre vacío o largo,
  -- cantidad sin unidad (o al revés), cantidad fuera de rango y más de 50 los rechazan los checks.
  if jsonb_typeof(p -> 'ingredients') is distinct from 'array' then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'ingredients';
  end if;
  for v_item, v_i in
    select t.e, (t.o - 1)::int from jsonb_array_elements(p -> 'ingredients') with ordinality as t(e, o)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('ingredients[%s]', v_i);
    end if;
    select min(k) into v_key from jsonb_object_keys(v_item) as k where k <> all (c_ingredient_keys);
    if v_key is not null then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('ingredients[%s].%s', v_i, v_key);
    end if;
    if jsonb_typeof(v_item -> 'name') is distinct from 'string' then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('ingredients[%s].name', v_i);
    end if;
    if coalesce(jsonb_typeof(v_item -> 'section'), 'null') <> 'null'
       and (jsonb_typeof(v_item -> 'section') <> 'string'
            or (v_item ->> 'section') <> all (enum_range(null::public.shopping_section)::text[])) then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('ingredients[%s].section', v_i);
    end if;
    if coalesce(jsonb_typeof(v_item -> 'quantity'), 'null') <> 'null'
       and (jsonb_typeof(v_item -> 'quantity') <> 'number' or (v_item -> 'quantity')::text !~ '^-?[0-9]{1,9}$') then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('ingredients[%s].quantity', v_i);
    end if;
    if coalesce(jsonb_typeof(v_item -> 'unit'), 'null') <> 'null'
       and (jsonb_typeof(v_item -> 'unit') <> 'string'
            or (v_item ->> 'unit') <> all (enum_range(null::public.ingredient_unit)::text[])) then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('ingredients[%s].unit', v_i);
    end if;
  end loop;

  -- 1. La receta. Si el id no existe se crea con los valores por defecto de la tabla; si es de otra
  --    cocinera, el insert no hace nada y el update no la ve (RLS).
  insert into public.recipes (id, chef_id, name_it)
  values (v_id, v_chef_id, v_name_it)
  on conflict (id) do nothing;

  -- Lo que trae p. El update toma el lock de la fila: dos guardados del mismo plato van uno
  -- después del otro y gana entero el último.
  update public.recipes r
  set name_it         = v_name_it,
      name_es         = case when p ? 'name_es'         then v_name_es   else r.name_es end,
      name_en         = case when p ? 'name_en'         then v_name_en   else r.name_en end,
      description_it  = case when p ? 'description_it'  then v_desc_it   else r.description_it end,
      description_es  = case when p ? 'description_es'  then v_desc_es   else r.description_es end,
      description_en  = case when p ? 'description_en'  then v_desc_en   else r.description_en end,
      diet            = case when p ? 'diet'            then v_diet      else r.diet end,
      season_months   = case when p ? 'season_months'   then v_months    else r.season_months end,
      fridge_days     = case when p ? 'fridge_days'     then v_fridge    else r.fridge_days end,
      freezable       = case when p ? 'freezable'       then v_freezable else r.freezable end,
      freezer_days    = case when p ? 'freezer_days'    then v_freezer   else r.freezer_days end,
      active          = case when p ? 'active'          then v_active    else r.active end,
      catalog_visible = case when p ? 'catalog_visible' then v_visible   else r.catalog_visible end
  where r.id = v_id;
  if not found then
    raise exception 'recipe_not_found' using errcode = 'P0002';
  end if;

  -- La dieta que queda (la de p o, si no vino, la guardada) contra los alérgenos nuevos.
  if exists (
    select 1 from public.recipes r
    where r.id = v_id
      and ((r.diet = 'vegan'
            and v_allergens && array['milk', 'eggs', 'fish', 'crustaceans', 'molluscs']::public.allergen[])
           or (r.diet = 'vegetarian'
               and v_allergens && array['fish', 'crustaceans', 'molluscs']::public.allergen[]))
  ) then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'diet';
  end if;

  -- 2. Alérgenos, enteros.
  delete from public.recipe_allergens a where a.recipe_id = v_id;
  insert into public.recipe_allergens (recipe_id, chef_id, allergen)
  select v_id, v_chef_id, x from unnest(v_allergens) as x;

  -- 3. Ingredientes, enteros, en el orden de la lista.
  delete from public.recipe_ingredients i where i.recipe_id = v_id;
  insert into public.recipe_ingredients (recipe_id, chef_id, position, name, section, quantity, unit)
  select v_id, v_chef_id, t.o::smallint, btrim(t.e ->> 'name'),
         coalesce((t.e ->> 'section')::public.shopping_section, 'other'),
         (t.e ->> 'quantity')::int,
         (t.e ->> 'unit')::public.ingredient_unit
  from jsonb_array_elements(p -> 'ingredients') with ordinality as t(e, o);

  -- 4. Notas, solo de la cocinera: si vienen, se reemplazan (null o "" las borra); si no, no se
  --    tocan.
  if p ? 'notes' then
    if v_notes is null then
      delete from public.recipe_notes n where n.recipe_id = v_id;
    else
      insert into public.recipe_notes (recipe_id, chef_id, notes)
      values (v_id, v_chef_id, v_notes)
      on conflict (recipe_id) do update set notes = excluded.notes;
    end if;
  end if;

  return v_id;
end
$$;

comment on function public.save_recipe(jsonb) is
  'Guarda un plato entero en una transacción (PR 13a): la receta con sus nombres y descripciones (si el id no existe la crea; el id lo genera la app, así un reintento no duplica), sus alérgenos y sus ingredientes, que se reemplazan enteros, y sus notas (recipe_notes, solo de la cocinera). Una clave escalar que no viene no se toca; una desconocida es un error. La dieta no puede contradecir los alérgenos. Security invoker: corre con la RLS de quien llama. Errores: 42501 not_a_chef; 22023 invalid_payload (DETAIL: el campo, o "diet"); P0002 recipe_not_found; 23514 los checks de recipes y recipe_ingredients. Duplicar = guardar con un id nuevo. Devuelve el id.';

-- create or replace conserva los privilegios; se repiten para que quede a la vista. La app
-- (authenticated); anon y service_role no la ejecutan.
revoke all on function public.save_recipe(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.save_recipe(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 3. public.get_public_menu(p_chef_id uuid)
--
-- Los platos publicados de la cocinera (activos, visibles en el catálogo y con descripción en
-- italiano), ordenados por nombre sin mayúsculas y después por id:
--   [{"id", "name": {"it", "es", "en"}, "description": {"it", "es", "en"},
--     "allergens": [...], "diet", "seasonMonths": [...]}]
-- allergens en el orden del enum ([] = ninguno); diet null = sin dieta; seasonMonths en orden, null
-- = todo el año. Nunca ingredientes ni notas: lo lee cualquiera que abra la web. Un array vacío si
-- no hay ninguno (o la cocinera no existe): la web dice que el menú lo propone Evelyn.
-- La temporada no se filtra acá: la web la mira con la fecha elegida.
-- ---------------------------------------------------------------------
create function public.get_public_menu(p_chef_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', r.id,
             'name', jsonb_build_object('it', r.name_it, 'es', r.name_es, 'en', r.name_en),
             'description', jsonb_build_object('it', r.description_it, 'es', r.description_es,
                                               'en', r.description_en),
             'allergens', (select coalesce(jsonb_agg(a.allergen order by a.allergen), '[]'::jsonb)
                           from public.recipe_allergens a
                           where a.recipe_id = r.id),
             'diet', r.diet,
             'seasonMonths', (select jsonb_agg(m order by m) from unnest(r.season_months) as m))
           order by lower(r.name_it), r.id),
         '[]'::jsonb)
  from public.recipes r
  where r.chef_id = p_chef_id
    and r.active
    and r.catalog_visible
    and r.description_it is not null
$$;

comment on function public.get_public_menu(uuid) is
  'Los platos publicados de una cocinera (activos, visibles en el catálogo y con descripción en italiano) para la pestaña «Menù» de la web: [{id, name: {it, es, en}, description: {it, es, en}, allergens, diet, seasonMonths}], por nombre sin mayúsculas y después por id; [] si no hay. Nunca ingredientes ni notas. Solo service role (Edge Function public-request).';

revoke all on function public.get_public_menu(uuid) from public, anon, authenticated;
grant execute on function public.get_public_menu(uuid) to service_role;

-- ---------------------------------------------------------------------
-- 4. submit_public_request y requests.wishes
-- ---------------------------------------------------------------------
comment on column public.requests.wishes is
  'Platos que eligió el cliente en la pestaña «Menù» de la web, en el orden en que los tildó: hasta uno por día (days). Solo los que estaban publicados al guardar el pedido. {} = no eligió (el menú lo propone la cocinera). Desde la web la escribe submit_public_request.';

-- El menu de la respuesta: los platos de p_wishes de la cocinera, en ese orden, con sus nombres de
-- hoy. Lo usan el pedido nuevo y el reintento, que lo arma con lo guardado aunque el plato ya no
-- esté publicado. Un plato borrado después (la cocinera puede borrar uno que no está en ningún
-- menú de una sesión) no sale.
create function private.request_menu(p_chef_id uuid, p_wishes uuid[])
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', r.id,
             'name', jsonb_build_object('it', r.name_it, 'es', r.name_es, 'en', r.name_en))
           order by t.o),
         '[]'::jsonb)
  from unnest(p_wishes) with ordinality as t(id, o)
  join public.recipes r on r.id = t.id and r.chef_id = p_chef_id
$$;

comment on function private.request_menu(uuid, uuid[]) is
  'El menu que devuelve submit_public_request: [{id, name: {it, es, en}}] de los platos de p_wishes de la cocinera, en ese orden, con sus nombres actuales. Solo para funciones security definer.';

revoke all on function private.request_menu(uuid, uuid[]) from public, anon, authenticated, service_role;

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
  'Guarda un pedido del formulario público (Edge Function public-request): prospecto (nuevo; uno existente no se modifica), consentimientos, restricciones del hogar (solo de un pedido semanal, se suman), pedido con sus semanas, los platos elegidos (solo los publicados, en orden), la respuesta a la pregunta de alergias y la copia del contacto, y notificación, en una transacción. Idempotente por (chef_id, request_key). Devuelve {request_id, duplicate, estimate, menu}; menu son los platos guardados con sus nombres actuales, también en un reintento. Solo service role.';

-- create or replace conserva los privilegios; se repiten para que quede a la vista.
revoke all on function public.submit_public_request(jsonb) from public, anon, authenticated;
grant execute on function public.submit_public_request(jsonb) to service_role;
