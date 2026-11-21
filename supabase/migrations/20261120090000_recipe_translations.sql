-- =====================================================================
-- Radici · Traducción automática de los platos (la base)
-- Tests: supabase/tests/database/18_recipe_translations.test.sql.
--
-- Pedido de Evelyn del 20/11/2026: escribe el nombre y la descripción de cada plato en español y el
-- italiano y el inglés se completan solos (los traduce Claude, POST /chef/translate de la Edge
-- Function chef, contrato docs/contracts/chef-api.md §12); los puede corregir. Es el primero de dos
-- PRs: esta base y la función; el editor de la app viene después (traduccion-app).
--
--   1. recipes.auto_translated: los campos de destino que llenó el traductor y Evelyn no tocó a
--      mano (name_it, description_it, name_en, description_en; el español es la fuente y nunca
--      está). Sin repetir, ninguno marcado sin texto en la fila y ninguno sin su fuente: un nombre
--      marcado exige name_es y una descripción marcada, description_es. Con esto la app sabe qué
--      volver a traducir cuando cambia el español sin pisar lo que Evelyn corrigió.
--   2. save_recipe acepta la clave opcional auto_translated. Sin la clave la lista queda vacía,
--      también al actualizar: una app que no la conoce guarda todo como escrito a mano.
--   3. hit_public_request_rate y private.public_request_hits: los comentarios dicen que ahora
--      también guardan el límite por cocina de POST /chef/translate (otra clave, la misma tabla).
--
-- Despliegue:
--   * La columna nace vacía en todas las filas: lo cargado hasta hoy cuenta como escrito a mano.
--   * La app de hoy no manda la clave: cada guardado deja la lista vacía, que es lo correcto para
--     una app que no traduce.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. recipes.auto_translated
--
-- Los checks no admiten subconsultas: que no haya repetidos se mira campo por campo con
-- array_positions. Un elemento null tampoco pasa (<@ no lo encuentra en la lista).
-- ---------------------------------------------------------------------
alter table public.recipes
  add column auto_translated text[] not null default '{}',
  add constraint recipes_auto_translated_valido check (
    auto_translated <@ array['name_it', 'description_it', 'name_en', 'description_en']::text[]
    and cardinality(array_positions(auto_translated, 'name_it')) <= 1
    and cardinality(array_positions(auto_translated, 'description_it')) <= 1
    and cardinality(array_positions(auto_translated, 'name_en')) <= 1
    and cardinality(array_positions(auto_translated, 'description_en')) <= 1),
  add constraint recipes_auto_translated_con_texto check (
    ('description_it' <> all (auto_translated) or description_it is not null)
    and ('name_en' <> all (auto_translated) or name_en is not null)
    and ('description_en' <> all (auto_translated) or description_en is not null)),
  -- El español es la fuente: no hay traducción sin el texto del que sale.
  add constraint recipes_auto_translated_con_fuente check (
    (('name_it' <> all (auto_translated) and 'name_en' <> all (auto_translated)) or name_es is not null)
    and (('description_it' <> all (auto_translated) and 'description_en' <> all (auto_translated))
         or description_es is not null));

comment on column public.recipes.auto_translated is
  'Campos de destino que llenó la traducción automática (POST /chef/translate) y la cocinera no tocó a mano: name_it, description_it, name_en, description_en, sin repetir. El español es la fuente y nunca está. Un campo marcado siempre tiene texto, y su fuente también (name_es para un nombre, description_es para una descripción). {} = todo escrito a mano.';

-- ---------------------------------------------------------------------
-- 2. public.save_recipe(p jsonb)
--
-- p: lo mismo que en 20261119150000_menu_web.sql, más
--   auto_translated  lista de textos, sin repetir, de name_it, description_it, name_en y
--                    description_en (en cualquier orden; se guarda en ese). Opcional: sin la clave
--                    queda {} (al crear y al actualizar). Un valor fuera de la lista, repetido o que
--                    no es texto, un campo marcado que no viene en p con texto, o uno cuya fuente
--                    en español no viene en p con texto (name_es para name_it y name_en,
--                    description_es para las descripciones), es invalid_payload con el elemento en
--                    el DETAIL (auto_translated[i]); si no es una lista, auto_translated.
-- Lo demás, igual.
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
                                  'ingredients', 'auto_translated'];
  c_ingredient_keys constant text[] := array['name', 'section', 'quantity', 'unit'];
  -- Los campos que puede llenar el traductor, en el orden en que se guardan.
  c_translated_keys constant text[] := array['name_it', 'description_it', 'name_en', 'description_en'];
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
  v_auto        text[] := '{}';
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

  -- Lo que llenó el traductor (20/11/2026). Cada campo marcado tiene que venir en p con texto, y su
  -- fuente en español también: al actualizar, lo guardado puede no ser lo que se tradujo. El primer
  -- elemento que no sirve va en el DETAIL; uno repetido cuenta en su segunda aparición.
  if p ? 'auto_translated' then
    if jsonb_typeof(p -> 'auto_translated') <> 'array' then
      raise exception 'invalid_payload' using errcode = '22023', detail = 'auto_translated';
    end if;
    select min(t.o) - 1 into v_i
    from jsonb_array_elements(p -> 'auto_translated') with ordinality as t(e, o)
    where jsonb_typeof(t.e) <> 'string'
       or (t.e #>> '{}') <> all (c_translated_keys)
       or exists (select 1 from jsonb_array_elements(p -> 'auto_translated') with ordinality as u(e, o)
                  where u.o < t.o and u.e = t.e)
       or nullif(btrim(p ->> (t.e #>> '{}')), '') is null
       or ((t.e #>> '{}') in ('name_it', 'name_en') and nullif(btrim(p ->> 'name_es'), '') is null)
       or ((t.e #>> '{}') in ('description_it', 'description_en')
           and nullif(btrim(p ->> 'description_es'), '') is null);
    if v_i is not null then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('auto_translated[%s]', v_i);
    end if;
    v_auto := array(select c.k from unnest(c_translated_keys) with ordinality as c(k, o)
                    where (p -> 'auto_translated') ? c.k
                    order by c.o);
  end if;

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
  -- después del otro y gana entero el último. auto_translated se reemplaza siempre (sin la clave,
  -- {}).
  update public.recipes r
  set name_it         = v_name_it,
      name_es         = case when p ? 'name_es'         then v_name_es   else r.name_es end,
      name_en         = case when p ? 'name_en'         then v_name_en   else r.name_en end,
      description_it  = case when p ? 'description_it'  then v_desc_it   else r.description_it end,
      description_es  = case when p ? 'description_es'  then v_desc_es   else r.description_es end,
      description_en  = case when p ? 'description_en'  then v_desc_en   else r.description_en end,
      auto_translated = v_auto,
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
  'Guarda un plato entero en una transacción (PR 13a): la receta con sus nombres y descripciones (si el id no existe la crea; el id lo genera la app, así un reintento no duplica), sus alérgenos y sus ingredientes, que se reemplazan enteros, y sus notas (recipe_notes, solo de la cocinera). Una clave escalar que no viene no se toca; una desconocida es un error. auto_translated (los campos que llenó la traducción automática) se reemplaza siempre: sin la clave queda {}. La dieta no puede contradecir los alérgenos. Security invoker: corre con la RLS de quien llama. Errores: 42501 not_a_chef; 22023 invalid_payload (DETAIL: el campo, "auto_translated[i]" o "diet"); P0002 recipe_not_found; 23514 los checks de recipes y recipe_ingredients. Duplicar = guardar con un id nuevo. Devuelve el id.';

-- create or replace conserva los privilegios; se repiten para que quede a la vista. La app
-- (authenticated); anon y service_role no la ejecutan.
revoke all on function public.save_recipe(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.save_recipe(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 3. El límite por cocina de POST /chef/translate
--
-- La Edge Function chef cuenta las traducciones de cada cocina con la misma función y la misma tabla
-- que el límite por IP del formulario: la clave es el SHA-256 de "translate:<chef_id>" (sin sal, el
-- id de la cocina no es un dato personal), otra fila que no gasta ningún cupo de la web. Nada cambia
-- en la función ni en la tabla: solo sus comentarios.
-- ---------------------------------------------------------------------
comment on function public.hit_public_request_rate(text, int, int) is
  'Límites por clave (hash de 64 caracteres hexadecimales): registra el intento y devuelve true si en la última hora hay como máximo p_max_hour intentos y en el último día p_max_day. El intento rechazado también se registra. Lo usan el formulario público (HMAC con IP_HASH_SALT de "<ruta>:<ip>", por IP) y la traducción de los platos de la función chef (SHA-256 de "translate:<chef_id>", por cocina). Borra los intentos de más de 1 día. Solo service role.';

comment on table private.public_request_hits is
  'Intentos de los límites por clave de hit_public_request_rate: los del formulario público (por IP, con HMAC) y los de POST /chef/translate (por cocina). Los de más de 1 día se borran en cada intento y en el borrado diario (purge_expired_prospects): ninguno dura 2 días.';

comment on column private.public_request_hits.ip_hash is
  'La clave del límite en hexadecimal (64 caracteres): el HMAC-SHA-256 de "<ruta>:<ip>" con IP_HASH_SALT (formulario; la IP nunca se guarda en claro) o el SHA-256 de "translate:<chef_id>" (traducción de los platos, por cocina).';
