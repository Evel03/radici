-- =====================================================================
-- Esquema: tablas, enums, convenciones (SPEC §4) y RLS habilitado en todo public.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(57);

-- ---------------------------------------------------------------------
-- Tablas esperadas (Fase 1 y Fase 2)
-- ---------------------------------------------------------------------
select has_table('public'::name, t::name, format('existe public.%s', t))
from unnest(array[
  'profiles', 'chefs', 'chef_settings', 'availability_rules', 'availability_exceptions',
  'clients', 'client_restrictions', 'consents', 'recurring_plans',
  'recipes', 'recipe_allergens', 'requests', 'quotes', 'sessions', 'session_menu',
  'receipts', 'payments', 'prepared_portions', 'pantry_items', 'push_tokens', 'notifications'
]) as t;

-- ---------------------------------------------------------------------
-- RLS y privilegios
-- ---------------------------------------------------------------------
select is(
  (select array_agg(c.relname::text order by c.relname)
   from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r','p') and not c.relrowsecurity),
  null::text[],
  'RLS habilitado en todas las tablas de public'
);

select is(
  (select array_agg(t.tablename::text order by t.tablename)
   from pg_tables t
   where t.schemaname = 'public'
     and has_table_privilege('anon', format('%I.%I', t.schemaname, t.tablename), 'SELECT,INSERT,UPDATE,DELETE')),
  null::text[],
  'anon no tiene privilegios sobre ninguna tabla de public'
);

select is(
  (select array_agg(t.tablename::text order by t.tablename)
   from pg_tables t
   where t.schemaname = 'public'
     and has_table_privilege('authenticated', format('%I.%I', t.schemaname, t.tablename), 'TRUNCATE')),
  null::text[],
  'authenticated no puede vaciar tablas (saltearía RLS)'
);

select is(
  (select array_agg(p.tablename || ': ' || p.policyname order by 1)
   from pg_policies p
   where p.schemaname = 'public' and not (p.roles <@ array['authenticated']::name[])),
  null::text[],
  'todas las políticas de public son solo para authenticated (ninguna para anon/public)'
);

select is(
  (select array_agg(t order by t)
   from unnest(array['sessions','quotes']) as t
   where has_table_privilege('authenticated', 'public.' || t, 'INSERT')
      or has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
      or has_table_privilege('authenticated', 'public.' || t, 'DELETE')),
  null::text[],
  'authenticated no puede escribir sesiones ni presupuestos'
);

select ok(
  not has_table_privilege('authenticated', 'public.payments', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.payments', 'DELETE')
  and not has_column_privilege('authenticated', 'public.payments', 'stripe_payment_intent_id', 'INSERT')
  and not has_column_privilege('authenticated', 'public.payments', 'captured_cents', 'INSERT'),
  'payments: authenticated no actualiza, no borra ni escribe columnas de Stripe'
);

select ok(
  has_column_privilege('authenticated', 'public.prepared_portions', 'count_left', 'UPDATE')
  and has_column_privilege('authenticated', 'public.prepared_portions', 'discarded_at', 'UPDATE')
  and not has_column_privilege('authenticated', 'public.prepared_portions', 'location', 'UPDATE')
  and not has_column_privilege('authenticated', 'public.prepared_portions', 'consume_by', 'UPDATE'),
  'prepared_portions: solo count_left y discarded_at son actualizables'
);

select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'role', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.profiles', 'INSERT'),
  'profiles: el usuario no puede elegir ni cambiar su rol'
);

-- ---------------------------------------------------------------------
-- Helpers: security definer, search_path vacío, sin execute para anon
-- ---------------------------------------------------------------------
select is(
  (select array_agg(p.proname::text order by p.proname)
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prosecdef
     and not coalesce(p.proconfig @> array['search_path=""'], false)),
  null::text[],
  'toda función security definer de public fija search_path vacío'
);

select ok(
  (select bool_and(p.prosecdef)
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('current_chef_id','is_chef_of','current_client_ids','current_client_chef_ids','client_can_read_receipt')),
  'los helpers de RLS son security definer'
);

select is(
  (select array_agg(f order by f)
   from unnest(array['public.current_chef_id()','public.is_chef_of(uuid)','public.current_client_ids()',
                     'public.current_client_chef_ids()','public.client_can_read_receipt(text)']) as f
   where has_function_privilege('anon', f, 'EXECUTE')),
  null::text[],
  'anon no puede ejecutar los helpers de RLS'
);

select ok(
  has_function_privilege('authenticated', 'public.current_chef_id()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.current_client_ids()', 'EXECUTE'),
  'authenticated puede ejecutar los helpers (los usan las políticas)'
);

-- ---------------------------------------------------------------------
-- Convenciones del modelo
-- ---------------------------------------------------------------------
select has_extension('btree_gist', 'btree_gist instalado');

select enum_has_labels('public', 'session_status',
  array['held','confirmed','shopping_done','cooked','paid','cancelled'], 'session_status incluye held');
select enum_has_labels('public', 'payment_kind',
  array['preauth','capture','groceries_extra','charge','cash','transfer','refund'], 'payment_kind según la spec');
select enum_has_labels('public', 'payment_status',
  array['requires_action','authorized','succeeded','canceled','failed','pending'], 'payment_status según la spec');

select is(
  (select array_agg(format('%s.%s', c.table_name, c.column_name) order by 1)
   from information_schema.columns c
   where c.table_schema = 'public' and c.column_name like '%\_cents' and c.data_type <> 'integer'),
  null::text[],
  'todo importe *_cents es integer'
);

select is(
  (select array_agg(format('%s.%s', c.relname, a.attname) order by 1)
   from pg_attribute a
   join pg_class c on c.oid = a.attrelid
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and a.attnum > 0 and not a.attisdropped
     and a.attname like '%\_cents'
     and not exists (
       select 1 from pg_constraint k
       where k.conrelid = c.oid and k.contype = 'c'
         and a.attnum = any (k.conkey)
         and pg_get_constraintdef(k.oid) ~ ('\m' || a.attname || ' (>= 0|BETWEEN 0)')
     )),
  null::text[],
  'todo importe *_cents tiene check >= 0'
);

select is(
  (select array_agg(t.tablename::text order by t.tablename)
   from pg_tables t
   where t.schemaname = 'public'
     and t.tablename not in ('profiles','chefs','push_tokens','notifications')
     and not exists (
       select 1 from information_schema.columns c
       where c.table_schema = 'public' and c.table_name = t.tablename and c.column_name = 'chef_id'
     )),
  null::text[],
  'toda tabla de negocio tiene chef_id'
);

select is(
  (select array_agg(c.table_name::text order by 1)
   from information_schema.columns c
   where c.table_schema = 'public' and c.column_name = 'id'
     and (c.data_type <> 'uuid' or coalesce(c.column_default, '') not in ('gen_random_uuid()'))
     and c.table_name <> 'profiles'),
  null::text[],
  'toda PK id es uuid con gen_random_uuid() (profiles.id = auth.users.id)'
);

select col_type_is('public', 'sessions', 'busy', 'tstzrange', 'sessions.busy es tstzrange');

select is(
  (select a.attgenerated::text from pg_attribute a
   where a.attrelid = 'public.sessions'::regclass and a.attname = 'busy'),
  's',
  'sessions.busy es una columna generada almacenada (la expresión es inmutable)'
);

select is(
  (select pg_get_constraintdef(k.oid) from pg_constraint k
   where k.conrelid = 'public.sessions'::regclass and k.conname = 'no_overlap'),
  'EXCLUDE USING gist (chef_id WITH =, busy WITH &&) WHERE ((status <> ''cancelled''::session_status))',
  'no_overlap: exclusión por chef y busy, salvo canceladas'
);

select is(
  (select public from storage.buckets where id = 'receipts'),
  false,
  'el bucket receipts existe y es privado'
);

-- ---------------------------------------------------------------------
-- Privilegios por defecto y inventarios (PR02: RLS de la clienta cerrada)
--
-- Todo lo nuevo nace cerrado: sin EXECUTE para PUBLIC, anon ni authenticated, y sin privilegios de
-- tabla para anon ni authenticated. Lo que la app o una política necesita se concede a mano, en la
-- migración que lo crea (y el inventario de abajo lo cuenta).
-- ---------------------------------------------------------------------
create function public.zz_funcion_nueva() returns int language sql as 'select 1';
create function private.zz_funcion_nueva() returns int language sql as 'select 1';
create table public.zz_tabla_nueva (id int primary key);
create sequence public.zz_secuencia_nueva;

select is(
  (select array_agg(r || ' ' || f order by r, f)
   from unnest(array['public', 'anon', 'authenticated']) as r,
        unnest(array['public.zz_funcion_nueva()', 'private.zz_funcion_nueva()']) as f
   where has_function_privilege(r, f, 'EXECUTE')),
  null::text[],
  'una función nueva, en public y en private, nace sin EXECUTE para public, anon ni authenticated'
);

select is(
  (select array_agg(r order by r)
   from unnest(array['anon', 'authenticated']) as r
   where has_table_privilege(r, 'public.zz_tabla_nueva', 'SELECT,INSERT,UPDATE,DELETE,REFERENCES,TRIGGER')
      or has_sequence_privilege(r, 'public.zz_secuencia_nueva', 'USAGE,SELECT,UPDATE')),
  null::text[],
  'una tabla y una secuencia nuevas de public nacen sin privilegios para anon ni authenticated'
);

select ok(
  has_function_privilege('service_role', 'public.zz_funcion_nueva()', 'EXECUTE')
  and has_table_privilege('service_role', 'public.zz_tabla_nueva', 'SELECT')
  and has_table_privilege('service_role', 'public.zz_tabla_nueva', 'INSERT')
  and has_table_privilege('service_role', 'public.zz_tabla_nueva', 'UPDATE')
  and has_table_privilege('service_role', 'public.zz_tabla_nueva', 'DELETE'),
  'lo nuevo de public sigue naciendo usable para service_role (las Edge Functions)'
);

select is(
  (select array_agg(n.nspname || '.' || p.proname || ' (' || pg_get_userbyid(p.proowner) || ')' order by n.nspname, p.proname)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and p.proname not like 'zz\_%'
     and pg_get_userbyid(p.proowner) <> 'postgres'),
  null::text[],
  'las funciones de las migraciones son de postgres (las de otro dueño no heredan estos privilegios por defecto)'
);

-- Inventario 1: qué funciones de public y private puede ejecutar cada rol de la API.
select is(
  (select array_agg(n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
                    order by n.nspname, p.proname)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and p.proname not like 'zz\_%'
     and has_function_privilege('public', p.oid, 'EXECUTE')),
  null::text[],
  'inventario 1: ninguna función de public ni private es ejecutable por PUBLIC'
);

select is(
  (select array_agg(n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
                    order by n.nspname, p.proname)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and p.proname not like 'zz\_%'
     and has_function_privilege('anon', p.oid, 'EXECUTE')),
  null::text[],
  'inventario 1: anon no ejecuta ninguna función de public ni private'
);

select is(
  (select array_agg(n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
                    order by n.nspname, p.proname)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and p.proname not like 'zz\_%'
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  array[
    'public.current_chef_id()',        -- las políticas de la cocina y la app (rpc)
    'public.current_client_ids()',     -- clients_guard_update, que corre con el rol de la cocinera
    'public.is_chef_of(p_chef_id uuid)',
    'public.save_recipe(p jsonb)',                                  -- rpc de la app, valida current_chef_id()
    'public.save_session_menu(p jsonb)',                            -- rpc de la app
    'public.set_recipe_photo(p_recipe_id uuid, p_photo_id uuid)'    -- rpc de la app
  ]::text[],
  'inventario 1: authenticated ejecuta solo los helpers de la cocina y las rpc de la app; agregar una exige sumarla acá, con su motivo'
);

-- Inventario 2: las políticas que no pasan por la cocina, o sea las que alcanzan a una cuenta sin
-- cocina (la clienta). Lo demás de la clienta pasa por Edge Functions (service role).
-- Es una red parcial: el filtro es textual (nombra current_chef_id o is_chef_of) y no prueba que la
-- política restrinja de verdad. La red real es 02_rls, que recorre las tablas con una cuenta sin
-- cocina y datos reales; los insert abiertos de una tabla nueva los atrapa este inventario (un
-- with_check que no nombra la cocina aparece en la lista), no el catálogo de 02_rls.
select is(
  (select array_agg(p.schemaname || '.' || p.policyname || ' | ' || p.cmd order by p.schemaname, p.policyname)
   from pg_policies p
   where p.schemaname in ('public', 'storage')
     and coalesce(p.qual, '') || ' ' || coalesce(p.with_check, '') !~ '(current_chef_id|is_chef_of)\('),
  array[
    'public.chefs: la cocinera edita la suya | UPDATE',   -- profile_id = auth.uid(): una cuenta sin cocina no tiene fila
    'public.notifications: el usuario lee las suyas | SELECT',
    'public.profiles: el usuario edita el suyo | UPDATE',  -- con grant solo de locale
    'public.profiles: el usuario lee el suyo | SELECT'
  ]::text[],
  'inventario 2: las únicas políticas fuera de la cocina son las del perfil y los avisos propios (y la dueña editando su ficha)'
);

-- Ninguna política de la cocina mezcla funciones de la clienta ni auth.uid() (una cláusula «o» así
-- le abriría filas a una cuenta sin cocina). Solo las 4 conservadas pueden usar auth.uid().
select is(
  (select array_agg(p.policyname::text order by p.policyname)
   from pg_policies p
   where p.schemaname in ('public', 'storage')
     and coalesce(p.qual, '') || ' ' || coalesce(p.with_check, '')
         ~ '(current_client_ids|current_client_chef_ids|client_can_read_receipt|auth\.uid)'
     and p.policyname not in ('chefs: la cocinera edita la suya', 'notifications: el usuario lee las suyas',
                              'profiles: el usuario edita el suyo', 'profiles: el usuario lee el suyo')),
  null::text[],
  'ninguna política de la cocina usa funciones de la clienta ni auth.uid()'
);

-- push_tokens: la app no la usa; sin privilegios para la API (no depende solo de la falta de políticas).
select is(
  (select count(*)::int from unnest(array['anon', 'authenticated']) r
   where has_table_privilege(r, 'public.push_tokens', 'SELECT,INSERT,UPDATE,DELETE')),
  0,
  'push_tokens: ni anon ni authenticated tienen privilegios'
);

-- anon no tiene privilegios sobre ninguna secuencia de public.
select is(
  (select count(*)::int from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'S'
     and case when c.relkind = 'S' then has_sequence_privilege('anon', c.oid, 'USAGE,SELECT,UPDATE') else false end),
  0,
  'anon no tiene privilegios sobre ninguna secuencia de public'
);

select is(
  (select array_agg(a.attname::text order by a.attname)
   from pg_attribute a
   where a.attrelid = 'public.profiles'::regclass and a.attnum > 0 and not a.attisdropped
     and has_column_privilege('authenticated', 'public.profiles', a.attname, 'UPDATE')),
  array['locale'],
  'profiles: authenticated solo puede actualizar locale'
);

select finish();
rollback;
