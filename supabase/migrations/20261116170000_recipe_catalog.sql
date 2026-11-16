-- =====================================================================
-- Radici · Catálogo de platos: base de datos (área de Evelyn, PR 13a; M4a)
-- Tests: supabase/tests/database/14_recipe_catalog.test.sql.
--
-- Decisión del dueño del 16/11/2026: la lista de compras (PR 15) es automática y editable. Sale
-- del menú de la sesión por las porciones, así que cada ingrediente de un plato lleva cantidad: un
-- entero para 4 porciones con su unidad (g, ml o piezas), o «q.b.» (sin cantidad ni unidad, como
-- la sal). Esta migración solo guarda bien los datos: la lista la genera el PR 15.
--
--   1. recipes: name_en, season_months (meses de 1 a 12, sin repetir; null = todo el año),
--      catalog_visible (false = receta de un evento, M3b: no se ofrece en el catálogo) y checks de
--      los nombres. El cliente lee solo las activas y visibles en el catálogo, y solo los alérgenos
--      de esas recetas.
--   2. recipe_ingredients: los ingredientes de cada plato, solo de la cocinera.
--   3. recipe_notes: las notas de cada plato, solo de la cocinera. Salen de recipes.notes, que el
--      cliente podía leer (la RLS filtra filas, no columnas).
--   4. public.save_recipe(p jsonb): guarda un plato entero (receta, alérgenos, ingredientes y notas)
--      en una transacción. Un plato nunca queda con los alérgenos a medio guardar: el menú y sus
--      alertas dependen de ellos. Security invoker: corre con los privilegios y la RLS de quien
--      llama.
--
-- Duplicar un plato no tiene función propia: la app ya tiene el plato cargado para editarlo y lo
-- guarda con save_recipe con un id nuevo (y el nombre que elija Evelyn). Sale atómico e idempotente,
-- como cualquier guardado.
--
-- Despliegue:
--   * Ningún código la usa todavía (la pantalla llega con el PR 13b), y recipes.notes tampoco: sus
--     datos pasan a recipe_notes y la columna se borra.
--   * Los checks de los nombres se validan contra las filas que ya existan. En producción no
--     debería haber recetas (ninguna pantalla las crea todavía); si alguna tuviera un nombre vacío,
--     con espacios al borde, con caracteres de control o de más de 120 caracteres, db push falla en
--     ese check y hay que corregirla a mano antes de volver a desplegar.
--   * Orden: va después de las migraciones de precio por semanas (20261116120000) y de reservas
--     (20261116150000 y 20261116150100), que todavía no están en main. deploy-supabase.yml corre
--     `db push` sin --include-all: si esta llega antes a producción, el push siguiente con esas
--     falla («Found local migration files to be inserted before the last migration on remote
--     database»). Si igual se mergea antes, hay que pasar esas a una versión posterior a esta.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. recipes
--
-- Nombres: sin espacios al borde (save_recipe los recorta), sin caracteres de control (un salto de
-- línea rompería la lista copiada a Notas o WhatsApp) y de 120 caracteres como mucho. Un nombre
-- traducido vacío no existe: sin traducción es null.
--
-- season_months: meses de 1 a 12, sin repetir, al menos uno; null = todo el año. Un check no admite
-- subconsultas, así que «sin repetir» va mes por mes. El case evita evaluarlo sobre una matriz
-- (array_positions no las acepta) y deja afuera el arreglo vacío y los meses null (<@ nunca da
-- verdadero con un null).
-- ---------------------------------------------------------------------
alter table public.recipes
  add column name_en         text,
  add column season_months   smallint[],
  add column catalog_visible boolean not null default true,
  add constraint recipes_name_it_valido check (
    char_length(name_it) between 1 and 120 and name_it = btrim(name_it) and name_it !~ '[[:cntrl:]]'),
  add constraint recipes_name_es_valido check (
    name_es is null
    or (char_length(name_es) between 1 and 120 and name_es = btrim(name_es) and name_es !~ '[[:cntrl:]]')),
  add constraint recipes_name_en_valido check (
    name_en is null
    or (char_length(name_en) between 1 and 120 and name_en = btrim(name_en) and name_en !~ '[[:cntrl:]]')),
  add constraint recipes_season_months_validos check (
    season_months is null
    or case
         when array_ndims(season_months) = 1
          and cardinality(season_months) between 1 and 12
          and season_months <@ '{1,2,3,4,5,6,7,8,9,10,11,12}'::smallint[]
         then cardinality(array_positions(season_months, 1::smallint)) <= 1
          and cardinality(array_positions(season_months, 2::smallint)) <= 1
          and cardinality(array_positions(season_months, 3::smallint)) <= 1
          and cardinality(array_positions(season_months, 4::smallint)) <= 1
          and cardinality(array_positions(season_months, 5::smallint)) <= 1
          and cardinality(array_positions(season_months, 6::smallint)) <= 1
          and cardinality(array_positions(season_months, 7::smallint)) <= 1
          and cardinality(array_positions(season_months, 8::smallint)) <= 1
          and cardinality(array_positions(season_months, 9::smallint)) <= 1
          and cardinality(array_positions(season_months, 10::smallint)) <= 1
          and cardinality(array_positions(season_months, 11::smallint)) <= 1
          and cardinality(array_positions(season_months, 12::smallint)) <= 1
         else false
       end
  );

comment on column public.recipes.name_en is
  'Nombre del plato en inglés (M4a). null = sin traducción.';
comment on column public.recipes.season_months is
  'Meses (1 a 12, sin repetir) en que el plato se ofrece; null = todo el año.';
comment on column public.recipes.catalog_visible is
  'false = receta de un evento (M3b): entra en el menú de ese evento, pero no se ofrece en el catálogo y el cliente no la ve.';

-- El cliente lee las recetas activas y visibles en el catálogo de su cocinera. Desde M2, solo un
-- cliente activo (SPEC §6).
drop policy "recipes: el cliente lee las activas de su cocinera" on public.recipes;
create policy "recipes: el cliente lee las del catálogo de su cocinera"
  on public.recipes for select to authenticated
  using (active and catalog_visible and chef_id in (select public.current_client_chef_ids()));

-- Y los alérgenos solo de las recetas que ve: no los de una desactivada ni los de un evento de otra
-- clienta. La subconsulta corre con la RLS de recipes, así que sigue sola a sus políticas (también
-- a la de «las recetas del menú de mis sesiones» que va a hacer falta en M3b/M4). La cocinera sigue
-- con la suya («la cocinera gestiona los suyos»).
drop policy "recipe_allergens: el cliente lee los de su cocinera" on public.recipe_allergens;
create policy "recipe_allergens: el cliente lee los de las recetas que ve"
  on public.recipe_allergens for select to authenticated
  using (recipe_id in (select r.id from public.recipes r));

-- ---------------------------------------------------------------------
-- 2. recipe_ingredients
--
-- Una fila por ingrediente, en el orden en que Evelyn los escribió (position 1, 2, …). quantity es
-- para 4 porciones, entera, en la unidad de unit; sin ninguna de las dos es «q.b.» (cantidad a
-- gusto). El tope de 100000 frena un error de tipeo (100 kg para 4 porciones) y deja margen para
-- multiplicar por las porciones de una sesión sin salirse de int.
-- ---------------------------------------------------------------------
create type public.shopping_section as enum ('produce', 'meat_fish', 'dairy_eggs', 'bakery', 'pantry', 'frozen', 'other');
comment on type public.shopping_section is
  'Sección del súper de un ingrediente, en el orden del recorrido: verdulería, carnes y pescados, lácteos y huevos, panadería, almacén, congelados y otros. La lista de compras agrupa en este orden.';

create type public.ingredient_unit as enum ('g', 'ml', 'pcs');
comment on type public.ingredient_unit is
  'Unidad de la cantidad de un ingrediente: gramos, mililitros o piezas.';

create table public.recipe_ingredients (
  recipe_id  uuid not null,
  chef_id    uuid not null,
  position   smallint not null,
  name       text not null,
  section    public.shopping_section not null default 'other',
  quantity   int,
  unit       public.ingredient_unit,
  primary key (recipe_id, position),
  foreign key (recipe_id, chef_id) references public.recipes (id, chef_id) on delete cascade,
  constraint recipe_ingredients_posicion_valida check (position between 1 and 50),
  constraint recipe_ingredients_nombre_valido check (
    char_length(name) between 1 and 80 and name = btrim(name) and name !~ '[[:cntrl:]]'),
  constraint recipe_ingredients_cantidad_con_unidad check ((quantity is null) = (unit is null)),
  constraint recipe_ingredients_cantidad_valida check (quantity between 1 and 100000)
);

comment on table public.recipe_ingredients is
  'Ingredientes de un plato, solo de la cocinera (el cliente no los lee). Se escriben con save_recipe, que los reemplaza enteros. La lista de compras de una sesión sale de acá (PR 15).';
comment on column public.recipe_ingredients.position is
  'Orden del ingrediente en el plato, desde 1.';
comment on column public.recipe_ingredients.quantity is
  'Cantidad entera para 4 porciones, en unit. null (junto con unit) = q.b.';

alter table public.recipe_ingredients enable row level security;

create policy "recipe_ingredients: la cocinera gestiona los suyos"
  on public.recipe_ingredients for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

-- Privilegios explícitos (Supabase ya no los da solo, y en local da TRUNCATE y otros que no van):
-- la app con RLS y la service role, las cuatro operaciones; anon, nada.
revoke all on table public.recipe_ingredients from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.recipe_ingredients to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. recipe_notes
--
-- Las notas de un plato son de la cocinera (la app dice «solo las ves tú»). En recipes las leería
-- cualquier cliente de su catálogo: la RLS filtra filas, no columnas, y cocinera y clientes son el
-- mismo rol (authenticated, con select sobre la tabla entera). Por eso van en una tabla aparte, solo
-- de la cocinera, como recipe_ingredients: una fila por plato con notas; sin notas, sin fila.
-- ---------------------------------------------------------------------
create table public.recipe_notes (
  recipe_id  uuid primary key,
  chef_id    uuid not null,
  notes      text not null,
  foreign key (recipe_id, chef_id) references public.recipes (id, chef_id) on delete cascade,
  constraint recipe_notes_no_vacias check (notes <> '' and notes = btrim(notes))
);

comment on table public.recipe_notes is
  'Notas de un plato, solo de la cocinera (el cliente no las lee). Una fila por plato con notas; sin notas, sin fila. Se escriben con save_recipe.';

alter table public.recipe_notes enable row level security;

create policy "recipe_notes: la cocinera gestiona las suyas"
  on public.recipe_notes for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

-- Los mismos privilegios que recipe_ingredients: la app con RLS y la service role; anon, nada.
revoke all on table public.recipe_notes from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.recipe_notes to authenticated, service_role;

-- Las notas que ya hubiera pasan a la tabla nueva (recortadas; una vacía no es nota) y la columna
-- se borra: ninguna pantalla ni función la usa.
insert into public.recipe_notes (recipe_id, chef_id, notes)
select r.id, r.chef_id, btrim(r.notes) from public.recipes r where btrim(r.notes) <> '';
alter table public.recipes drop column notes;

-- ---------------------------------------------------------------------
-- 4. public.save_recipe(p jsonb)
--
-- p: el plato completo, como lo arma la app.
--   id               uuid (texto). Obligatorio: lo genera la app, así un reintento no duplica.
--   name_it          texto. Obligatorio.
--   name_es, name_en texto o null ("" también es null).
--   diet             'vegetarian', 'vegan' o null.
--   season_months    [1..12] sin repetir, o null (todo el año).
--   fridge_days, freezer_days  enteros; freezable, active, catalog_visible  booleanos (no null).
--   notes            texto o null ("" también es null). Van en recipe_notes.
--   allergens        lista de alérgenos (los 14 del enum). Obligatoria: [] es «ninguno».
--   ingredients      lista, en orden, de {name, section?, quantity?, unit?}. Obligatoria.
--                    section: una de shopping_section ('other' si no viene). quantity y unit,
--                    las dos o ninguna (q.b.).
-- Una clave escalar que no viene no se toca (en un plato nuevo, el valor por defecto de la
-- columna): una versión vieja de la app no reactiva un plato ni pasa una receta de evento al
-- catálogo por no conocer la clave. null borra donde la columna lo admite. allergens e ingredients
-- se reemplazan enteros. Una clave desconocida (también dentro de un ingrediente) es un error: si se
-- ignorara, un nombre cambiado de un solo lado perdería el dato en silencio. La app lee c_keys y
-- c_ingredient_keys de este archivo en un test (recipe_save_contract_test.dart).
--
-- La dieta no contradice los alérgenos (SPEC §5.6): un plato vegano no lleva leche, huevos,
-- pescado, crustáceos ni moluscos, y uno vegetariano no lleva pescado, crustáceos ni moluscos. Si
-- no, se le ofrecería a un cliente con esa dieta (el control por dieta mira la etiqueta del plato).
--
-- Errores:
--   42501 not_a_chef         quien llama no es cocinera.
--   22023 invalid_payload    tipo, forma o clave inválidos, o una dieta que contradice los
--                            alérgenos; DETAIL dice el campo (p. ej. "ingredients[2].unit",
--                            contando desde 0, o "diet"). Se valida antes de escribir, salvo la
--                            dieta: se mira con la fila ya bloqueada, porque puede no venir en p.
--   P0002 recipe_not_found   el id es de un plato que la RLS no deja ver (de otra cocinera).
--   23514                    los checks de recipes y recipe_ingredients (nombres, meses, cantidad y
--                            unidad, hasta 50 ingredientes): el mensaje dice cuál.
-- Cualquier error deshace todo: la receta, los alérgenos, los ingredientes y las notas quedan como
-- estaban. Devuelve el id del plato.
-- ---------------------------------------------------------------------
create function public.save_recipe(p jsonb)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  -- Las claves que entiende: cualquier otra es invalid_payload.
  c_keys constant text[] := array['id', 'name_it', 'name_es', 'name_en', 'diet', 'season_months',
                                  'fridge_days', 'freezable', 'freezer_days', 'notes', 'active',
                                  'catalog_visible', 'allergens', 'ingredients'];
  c_ingredient_keys constant text[] := array['name', 'section', 'quantity', 'unit'];
  v_chef_id     uuid := public.current_chef_id();
  v_id          uuid;
  v_name_it     text;
  v_name_es     text;
  v_name_en     text;
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

  -- Nombres y notas: se recortan los espacios. Uno vacío o larguísimo lo rechazan los checks.
  if jsonb_typeof(p -> 'name_it') is distinct from 'string' then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'name_it';
  end if;
  v_name_it := btrim(p ->> 'name_it');

  foreach v_key in array array['name_es', 'name_en', 'notes'] loop
    if coalesce(jsonb_typeof(p -> v_key), 'null') not in ('string', 'null') then
      raise exception 'invalid_payload' using errcode = '22023', detail = v_key;
    end if;
  end loop;
  v_name_es := nullif(btrim(p ->> 'name_es'), '');
  v_name_en := nullif(btrim(p ->> 'name_en'), '');
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
  'Guarda un plato entero en una transacción (PR 13a): la receta (si el id no existe la crea; el id lo genera la app, así un reintento no duplica), sus alérgenos y sus ingredientes, que se reemplazan enteros, y sus notas (recipe_notes, solo de la cocinera). Una clave escalar que no viene no se toca; una desconocida es un error. La dieta no puede contradecir los alérgenos. Security invoker: corre con la RLS de quien llama. Errores: 42501 not_a_chef; 22023 invalid_payload (DETAIL: el campo, o "diet"); P0002 recipe_not_found; 23514 los checks de recipes y recipe_ingredients. Duplicar = guardar con un id nuevo. Devuelve el id.';

-- La app (authenticated); la RLS decide qué filas. anon y service_role no la ejecutan (service_role
-- no tiene cocinera: current_chef_id() es null).
revoke all on function public.save_recipe(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.save_recipe(jsonb) to authenticated;
