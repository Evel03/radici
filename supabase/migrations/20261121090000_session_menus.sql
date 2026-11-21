-- =====================================================================
-- Radici · Menú y lista de compras de cada semana (proceso de presupuesto y menús del 21/11/2026,
-- PR 1). Tests: supabase/tests/database/19_session_menus.test.sql.
--
-- Una sesión es una semana de una reserva, y sessions.request_id la liga al pedido. Para cada
-- semana Evelyn arma el menú (platos del catálogo con sus porciones) y la lista de compras para la
-- clienta, que la app saca de los ingredientes de esos platos por las porciones y Evelyn edita.
-- Puede agregar una nota para la clienta. Esta migración solo guarda eso. Enviarlo y que la clienta
-- lo confirme llega en el PR de base siguiente, con una tabla propia que escribe solo el servidor.
--
--   1. session_menu, que existía sin uso: position (el orden de los platos) y porciones de 1 a 500.
--   2. session_shopping_items: la lista de compras de la semana, con las mismas reglas que
--      recipe_ingredients. Solo de la cocinera.
--   3. session_menus: una fila por sesión con menú. Guarda la nota, la versión (sube en cada
--      guardado) y si Evelyn confirmó los platos que chocan con las alergias del pedido (SPEC §9,
--      criterio 8: la app lo pide explícitamente).
--   4. public.save_session_menu(p jsonb): guarda platos, lista y nota juntos, en una transacción,
--      con la RLS de quien llama. Con control de versión: dos teléfonos (Evelyn y un colaborador)
--      nunca se pisan en silencio.
--
-- Despliegue: ninguna pantalla ni función escribe session_menu todavía. Si hubiera filas, position
-- se llena por plato, en el orden del id de la receta.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. session_menu: orden de los platos y tope de porciones
--
-- Hasta 30 platos por semana: una semana tiene como mucho 7 días con almuerzo y cena, más algún
-- postre. Las porciones son de ese plato en la semana (un plato puede cubrir varias comidas); el
-- tope de 500 frena un error de tipeo y deja margen para multiplicar cantidades sin salirse de int.
-- ---------------------------------------------------------------------
alter table public.session_menu add column position smallint;

update public.session_menu m
set position = o.n
from (select session_id, recipe_id,
             row_number() over (partition by session_id order by recipe_id)::smallint as n
      from public.session_menu) o
where o.session_id = m.session_id and o.recipe_id = m.recipe_id;

alter table public.session_menu
  alter column position set not null,
  drop constraint if exists session_menu_portions_check,
  add constraint session_menu_posicion_valida check (position between 1 and 30),
  add constraint session_menu_porciones_validas check (portions between 1 and 500),
  add constraint session_menu_posicion_unica unique (session_id, position);

comment on table public.session_menu is
  'Platos del menú de una semana (una sesión), en orden, con sus porciones. Se escribe con save_session_menu, que lo reemplaza entero.';
comment on column public.session_menu.position is
  'Orden del plato en el menú de la semana, desde 1.';
comment on column public.session_menu.portions is
  'Porciones de ese plato en la semana (de 1 a 500). La lista de compras multiplica los ingredientes, que son para 4 porciones.';

-- ---------------------------------------------------------------------
-- 2. session_shopping_items: la lista de compras de la semana
--
-- La compra la hace la clienta (sin compra, 19/11/2026). La app arma la lista con los ingredientes de
-- los platos por las porciones, juntando los iguales y agrupada por sección del súper, y Evelyn la
-- edita: cambia cantidades, saca o agrega cosas. Se guarda tal como queda, así lo que se le manda a
-- la clienta es lo que Evelyn vio. Las mismas reglas que recipe_ingredients, con hasta 150
-- renglones. La cantidad queda entera y en g, ml o piezas; la forma de mostrarla (1,2 kg) es del
-- mensaje. La clienta no la lee por la API: le llega en el mensaje y en su link (PR siguiente).
-- ---------------------------------------------------------------------
create table public.session_shopping_items (
  session_id uuid not null,
  chef_id    uuid not null,
  position   smallint not null,
  name       text not null,
  section    public.shopping_section not null default 'other',
  quantity   int,
  unit       public.ingredient_unit,
  primary key (session_id, position),
  foreign key (session_id, chef_id) references public.sessions (id, chef_id) on delete cascade,
  constraint session_shopping_items_posicion_valida check (position between 1 and 150),
  constraint session_shopping_items_nombre_valido check (
    char_length(name) between 1 and 80 and name = btrim(name) and name !~ '[[:cntrl:]]'),
  constraint session_shopping_items_cantidad_con_unidad check ((quantity is null) = (unit is null)),
  constraint session_shopping_items_cantidad_valida check (quantity between 1 and 1000000)
);

comment on table public.session_shopping_items is
  'Lista de compras de una semana (una sesión) para la clienta, tal como la dejó Evelyn. Solo de la cocinera. Se escribe con save_session_menu, que la reemplaza entera.';
comment on column public.session_shopping_items.quantity is
  'Cantidad entera en unit (de 1 a 1000000). null (junto con unit) = q.b.';

alter table public.session_shopping_items enable row level security;

create policy "session_shopping_items: la cocinera gestiona los suyos"
  on public.session_shopping_items for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

revoke all on table public.session_shopping_items from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.session_shopping_items to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. session_menus: una fila por semana con menú
--
-- note: lo que Evelyn quiere decirle a la clienta esa semana («tené listos 4 táperes»). Admite
-- saltos de línea y ningún otro carácter de control, hasta 1000 caracteres. Llega a la clienta (por
-- eso la app pide no escribir datos de salud ni direcciones).
-- version: 1 al crearse; cada guardado la sube. El envío (PR siguiente) guarda qué versión salió, así
-- la app sabe si el menú cambió después de mandarlo.
-- allergens_confirmed: true si Evelyn confirmó, al guardar, los platos que chocan con las alergias
-- del pedido. Lo calcula la app (las alergias pueden venir de otro pedido, en una renovación) y la
-- base solo lo registra.
-- ---------------------------------------------------------------------
create table public.session_menus (
  session_id          uuid primary key,
  chef_id             uuid not null,
  note                text,
  version             int not null default 1,
  allergens_confirmed boolean not null default false,
  updated_at          timestamptz not null default now(),
  foreign key (session_id, chef_id) references public.sessions (id, chef_id) on delete cascade,
  constraint session_menus_version_valida check (version >= 1),
  constraint session_menus_nota_valida check (
    note is null
    or (char_length(note) between 1 and 1000
        and note = btrim(note)
        and replace(note, E'\n', '') !~ '[[:cntrl:]]'))
);

comment on table public.session_menus is
  'Menú de una semana (una sesión): la nota para la clienta, la versión (sube en cada guardado) y si Evelyn confirmó los choques con las alergias. Los platos van en session_menu y la lista en session_shopping_items. Se escribe con save_session_menu.';

alter table public.session_menus enable row level security;

create policy "session_menus: la cocinera gestiona los suyos"
  on public.session_menus for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

revoke all on table public.session_menus from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.session_menus to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. public.save_session_menu(p jsonb)
--
-- p: el menú de una semana, como lo arma la app.
--   session_id           uuid (texto). Obligatorio.
--   version              entero o null: la versión que la app tenía cargada (null = todavía no
--                        había menú). Si no coincide con la guardada, nada se escribe
--                        (menu_changed): otro teléfono lo cambió y hay que recargar.
--   note                 texto o null ("" también es null; los \r\n pasan a \n). Si no viene, no se
--                        toca.
--   allergens_confirmed  booleano. Si no viene, no se toca (false en un menú nuevo).
--   dishes               lista, en orden, de {recipe_id, portions}. Obligatoria ([] = sin platos;
--                        el envío exige alguno). Una receta de la cocina, sin repetir, activa o no
--                        (la que se desactivó después de elegirla sigue en el menú).
--   items                lista, en orden, de {name, section?, quantity?, unit?}, como los
--                        ingredientes de save_recipe. Obligatoria ([] = lista vacía).
-- dishes e items se reemplazan enteros. Una clave desconocida, también dentro de un plato o un
-- renglón, es un error. La app del menú (PR siguiente) va a leer c_keys, c_dish_keys y c_item_keys de
-- este archivo en un test.
--
-- Errores:
--   42501 not_a_chef            quien llama no es de una cocina.
--   22023 invalid_payload       tipo, forma o clave inválidos; DETAIL dice el campo (p. ej.
--                               "dishes[1].portions" o "items[0].unit", contando desde 0). Una
--                               receta repetida es "dishes[i].recipe_id".
--   P0002 session_not_found     la sesión no existe o es de otra cocina.
--   P0002 recipe_not_found      una receta no existe o es de otra cocina; DETAIL: "dishes[i].recipe_id".
--   55000 session_not_editable  la sesión está cancelada, cocinada o cobrada; DETAIL: su estado.
--   40001 menu_changed          version no coincide con la guardada.
--   23514                       los checks de las tablas (porciones, más de 30 platos o 150 renglones,
--                               nombres, cantidad y unidad, nota): el mensaje dice cuál.
-- Cualquier error deshace todo. Devuelve la versión nueva.
-- ---------------------------------------------------------------------
create function public.save_session_menu(p jsonb)
returns int
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  -- Las claves que entiende: cualquier otra es invalid_payload.
  c_keys      constant text[] := array['session_id', 'version', 'note', 'allergens_confirmed', 'dishes', 'items'];
  c_dish_keys constant text[] := array['recipe_id', 'portions'];
  c_item_keys constant text[] := array['name', 'section', 'quantity', 'unit'];
  c_uuid      constant text   := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_chef_id    uuid := public.current_chef_id();
  v_session_id uuid;
  v_status     public.session_status;
  v_expected   int;
  v_current    int;
  v_note       text;
  v_confirmed  boolean;
  v_recipes    uuid[];
  v_key        text;
  v_item       jsonb;
  v_i          int;
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

  if jsonb_typeof(p -> 'session_id') is distinct from 'string' or (p ->> 'session_id') !~* c_uuid then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'session_id';
  end if;
  v_session_id := (p ->> 'session_id')::uuid;

  case coalesce(jsonb_typeof(p -> 'version'), 'null')
    when 'null' then
      v_expected := null;
    when 'number' then
      if (p -> 'version')::text !~ '^[0-9]{1,9}$' then
        raise exception 'invalid_payload' using errcode = '22023', detail = 'version';
      end if;
      v_expected := (p ->> 'version')::int;
    else
      raise exception 'invalid_payload' using errcode = '22023', detail = 'version';
  end case;

  if coalesce(jsonb_typeof(p -> 'note'), 'null') not in ('string', 'null') then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'note';
  end if;
  v_note := nullif(btrim(replace(p ->> 'note', E'\r\n', E'\n')), '');

  if p ? 'allergens_confirmed' and jsonb_typeof(p -> 'allergens_confirmed') <> 'boolean' then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'allergens_confirmed';
  end if;
  v_confirmed := (p ->> 'allergens_confirmed')::boolean;

  -- Platos: lista obligatoria. Acá la forma; las porciones fuera de rango y más de 30 platos los
  -- rechazan los checks.
  if jsonb_typeof(p -> 'dishes') is distinct from 'array' then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'dishes';
  end if;
  for v_item, v_i in
    select t.e, (t.o - 1)::int from jsonb_array_elements(p -> 'dishes') with ordinality as t(e, o)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('dishes[%s]', v_i);
    end if;
    select min(k) into v_key from jsonb_object_keys(v_item) as k where k <> all (c_dish_keys);
    if v_key is not null then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('dishes[%s].%s', v_i, v_key);
    end if;
    if jsonb_typeof(v_item -> 'recipe_id') is distinct from 'string' or (v_item ->> 'recipe_id') !~* c_uuid then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('dishes[%s].recipe_id', v_i);
    end if;
    if jsonb_typeof(v_item -> 'portions') is distinct from 'number'
       or (v_item -> 'portions')::text !~ '^-?[0-9]{1,9}$' then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('dishes[%s].portions', v_i);
    end if;
  end loop;

  -- Sin repetir: la primera receta que ya estaba antes en la lista.
  select min(t.o) - 1 into v_i
  from (select (e ->> 'recipe_id')::uuid as id, o,
               row_number() over (partition by (e ->> 'recipe_id')::uuid order by o) as n
        from jsonb_array_elements(p -> 'dishes') with ordinality as x(e, o)) t
  where t.n > 1;
  if v_i is not null then
    raise exception 'invalid_payload' using errcode = '22023', detail = format('dishes[%s].recipe_id', v_i);
  end if;

  -- Renglones de la lista: como los ingredientes de save_recipe.
  if jsonb_typeof(p -> 'items') is distinct from 'array' then
    raise exception 'invalid_payload' using errcode = '22023', detail = 'items';
  end if;
  for v_item, v_i in
    select t.e, (t.o - 1)::int from jsonb_array_elements(p -> 'items') with ordinality as t(e, o)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('items[%s]', v_i);
    end if;
    select min(k) into v_key from jsonb_object_keys(v_item) as k where k <> all (c_item_keys);
    if v_key is not null then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('items[%s].%s', v_i, v_key);
    end if;
    if jsonb_typeof(v_item -> 'name') is distinct from 'string' then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('items[%s].name', v_i);
    end if;
    if coalesce(jsonb_typeof(v_item -> 'section'), 'null') <> 'null'
       and (jsonb_typeof(v_item -> 'section') <> 'string'
            or (v_item ->> 'section') <> all (enum_range(null::public.shopping_section)::text[])) then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('items[%s].section', v_i);
    end if;
    if coalesce(jsonb_typeof(v_item -> 'quantity'), 'null') <> 'null'
       and (jsonb_typeof(v_item -> 'quantity') <> 'number' or (v_item -> 'quantity')::text !~ '^-?[0-9]{1,9}$') then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('items[%s].quantity', v_i);
    end if;
    if coalesce(jsonb_typeof(v_item -> 'unit'), 'null') <> 'null'
       and (jsonb_typeof(v_item -> 'unit') <> 'string'
            or (v_item ->> 'unit') <> all (enum_range(null::public.ingredient_unit)::text[])) then
      raise exception 'invalid_payload' using errcode = '22023', detail = format('items[%s].unit', v_i);
    end if;
  end loop;

  -- La sesión: la RLS deja ver solo las de la cocina de quien llama.
  select s.status into v_status from public.sessions s where s.id = v_session_id;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if v_status not in ('held', 'confirmed', 'shopping_done') then
    raise exception 'session_not_editable' using errcode = '55000', detail = v_status::text;
  end if;

  -- Las recetas: todas de la cocina (la RLS de recipes). La primera que no se ve.
  v_recipes := array(select (e ->> 'recipe_id')::uuid from jsonb_array_elements(p -> 'dishes') as e);
  select min(t.o) - 1 into v_i
  from unnest(v_recipes) with ordinality as t(id, o)
  where not exists (select 1 from public.recipes r where r.id = t.id);
  if v_i is not null then
    raise exception 'recipe_not_found' using errcode = 'P0002', detail = format('dishes[%s].recipe_id', v_i);
  end if;

  -- La fila del menú, bloqueada: dos guardados de la misma semana van uno después del otro y el
  -- segundo ve la versión que dejó el primero.
  select m.version into v_current from public.session_menus m where m.session_id = v_session_id for update;
  if not found then
    if v_expected is not null then
      raise exception 'menu_changed' using errcode = '40001';
    end if;
    begin
      insert into public.session_menus (session_id, chef_id, note, allergens_confirmed)
      values (v_session_id, v_chef_id, v_note, coalesce(v_confirmed, false));
    exception when unique_violation then
      -- Otro guardado creó el menú al mismo tiempo.
      raise exception 'menu_changed' using errcode = '40001';
    end;
    v_current := 1;
  else
    if v_expected is distinct from v_current then
      raise exception 'menu_changed' using errcode = '40001';
    end if;
    v_current := v_current + 1;
    update public.session_menus m
    set version             = v_current,
        note                = case when p ? 'note' then v_note else m.note end,
        allergens_confirmed = coalesce(v_confirmed, m.allergens_confirmed),
        updated_at          = now()
    where m.session_id = v_session_id;
  end if;

  -- Platos y lista, enteros, en el orden de la app.
  delete from public.session_menu d where d.session_id = v_session_id;
  insert into public.session_menu (session_id, recipe_id, chef_id, portions, position)
  select v_session_id, (t.e ->> 'recipe_id')::uuid, v_chef_id, (t.e ->> 'portions')::int, t.o::smallint
  from jsonb_array_elements(p -> 'dishes') with ordinality as t(e, o);

  delete from public.session_shopping_items i where i.session_id = v_session_id;
  insert into public.session_shopping_items (session_id, chef_id, position, name, section, quantity, unit)
  select v_session_id, v_chef_id, t.o::smallint, btrim(t.e ->> 'name'),
         coalesce((t.e ->> 'section')::public.shopping_section, 'other'),
         (t.e ->> 'quantity')::int,
         (t.e ->> 'unit')::public.ingredient_unit
  from jsonb_array_elements(p -> 'items') with ordinality as t(e, o);

  return v_current;
end
$$;

comment on function public.save_session_menu(jsonb) is
  'Guarda el menú de una semana (una sesión) en una transacción (21/11/2026): los platos con sus porciones (session_menu) y la lista de compras (session_shopping_items), que se reemplazan enteros, y la nota y la confirmación de alérgenos (session_menus), que si no vienen no se tocan. Control de versión: version es la que la app tenía cargada (null = sin menú). Security invoker: corre con la RLS de quien llama. Errores: 42501 not_a_chef; 22023 invalid_payload (DETAIL: el campo); P0002 session_not_found y recipe_not_found; 55000 session_not_editable (DETAIL: el estado); 40001 menu_changed; 23514 los checks de las tablas. Devuelve la versión nueva.';

-- La app (authenticated); la RLS decide qué filas. anon y service_role no la ejecutan (service_role
-- no tiene cocina: current_chef_id() es null).
revoke all on function public.save_session_menu(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.save_session_menu(jsonb) to authenticated;
