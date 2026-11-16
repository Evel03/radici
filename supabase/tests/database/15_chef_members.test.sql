-- =====================================================================
-- Colaboradores de la cocinera (migración 20261116190000_chef_members.sql).
--
-- Pedido del dueño del 16/11/2026: entrar a /gestione/ con su propio email y código, con el mismo
-- acceso que Evelyn. Un colaborador (public.chef_members) es una cuenta que trabaja en la cocina de
-- una cocinera: current_chef_id() e is_chef_of() lo reconocen, así que pasa por todas las políticas
-- del lado de la cocinera. Nunca agrega ni saca colaboradores, nunca cambia chefs.profile_id ni se
-- vuelve la cocinera dueña, y nunca ve otra cocina. No hay segunda cocinera: la ficha de chefs es
-- una sola. La lista la define el despliegue (private.sync_chef_members, secreto CHEF_MEMBER_EMAILS).
--
--   1. La regla de las políticas (estructural): auth.uid() directo solo en las de identidad propia.
--   2. Tabla, privilegios y funciones.
--   3. Quién es quién (chef_id_for_user, current_chef_id, is_chef_of).
--   4. El colaborador: ve y hace lo mismo que la cocinera (también el catálogo de platos), y nada de
--      lo que nunca puede. El autor de un ticket es quien lo sube (receipts.uploaded_by).
--   5. La dueña, una cuenta con rol chef sin cocina, un cliente, service_role y anon.
--   6. Una cuenta es dueña o colaboradora, nunca las dos.
--   7. private.sync_chef_members: la lista manda.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(118);

-- Las expresiones de pg_policies se imprimen según el search_path: así auth.uid() sale calificado.
set local search_path to public, extensions;

-- =====================================================================
-- 1. La regla: el lado de la cocinera pasa por las funciones
-- =====================================================================
-- Una política que compara con auth.uid() directo identifica a una sola cuenta. Del lado de la
-- cocinera eso deja afuera a sus colaboradores: esas políticas usan current_chef_id() o
-- is_chef_of(). Las únicas con auth.uid() directo son estas, con su motivo:
--   * profiles «el usuario lee el suyo» y «el usuario edita el suyo»: el perfil propio.
--   * chefs «la cocinera edita la suya»: la ficha pública de la cocinera (nombre, zona y WhatsApp que
--     ven los clientes) la cambia solo la dueña; un colaborador la lee y no la edita.
--   * push_tokens «el usuario gestiona los suyos»: los dispositivos de cada uno.
--   * notifications «el usuario lee las suyas»: cada aviso es de una persona (el del pedido nuevo, de
--     la cocinera).
-- Una tabla nueva (el catálogo de platos, por ejemplo) queda cubierta sola: si una política suya usa
-- auth.uid() directo, esto falla hasta que use las funciones o se sume acá con su motivo. También
-- cuenta como directo identificar al usuario con auth.jwt() o con request.jwt.claims.
select set_eq(
  $$ select p.schemaname::text, p.tablename::text, p.policyname::text
     from pg_policies p
     where p.schemaname in ('public', 'storage')
       and concat_ws(' ', p.qual, p.with_check) ~ '(auth\.(uid|jwt)\(\)|request\.jwt\.claim)' $$,
  $$ values ('public', 'chefs',         'chefs: la cocinera edita la suya'),
            ('public', 'notifications', 'notifications: el usuario lee las suyas'),
            ('public', 'profiles',      'profiles: el usuario edita el suyo'),
            ('public', 'profiles',      'profiles: el usuario lee el suyo'),
            ('public', 'push_tokens',   'push_tokens: el usuario gestiona los suyos') $$,
  'auth.uid() directo solo en las políticas de identidad propia de la lista: el lado de la cocinera pasa por current_chef_id() o is_chef_of()'
);

select is(
  (select array_agg(format('%s.%s: %s', p.schemaname, p.tablename, p.policyname) order by 1)
   from pg_policies p
   where p.schemaname in ('public', 'storage')
     and concat_ws(' ', p.qual, p.with_check) ~* '\m(from|join)\s+(public\.)?(chefs|chef_members)\M'),
  null::text[],
  'ninguna política lee chefs ni chef_members por su cuenta: quién es la cocinera lo dicen las funciones'
);

select is(
  (select array_agg(p.oid::regprocedure::text order by 1)
   from pg_proc p
   where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
     and p.prosrc ~* '(auth\.(uid|jwt)\(\)|request\.jwt\.claim)'
     and p.prosrc ~* '\m(public\.)?(chefs|chef_members)\M'),
  null::text[],
  'ninguna función busca por su cuenta la cocinera del usuario de la sesión: lo hace chef_id_for_user, que usan current_chef_id() e is_chef_of()'
);

-- =====================================================================
-- 2. Tabla, privilegios y funciones
-- =====================================================================
select has_table('public'::name, 'chef_members'::name, 'existe public.chef_members');
select col_is_pk('public', 'chef_members', 'profile_id',
  'profile_id es la clave: una cuenta es colaboradora de una sola cocina');
select is(
  (select array_agg(format('%s -> %s (%s)', a.attname, k.confrelid::regclass, k.confdeltype) order by 1)
   from pg_constraint k
   join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any (k.conkey)
   where k.conrelid = 'public.chef_members'::regclass and k.contype = 'f'),
  array['chef_id -> chefs (c)', 'profile_id -> profiles (c)'],
  'chef_id y profile_id en cascada: sin la cocina o sin la cuenta, no queda la colaboración'
);
select is(
  (select array_agg(format('%s %s', r, p) order by 1)
   from unnest(array['anon', 'authenticated']) as r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) as p
   where has_table_privilege(r, 'public.chef_members', p)),
  null::text[],
  'ni anon ni authenticated tocan chef_members: desde la app nadie agrega, saca ni lista colaboradores'
);
select ok(
  (select bool_and(has_table_privilege('service_role', 'public.chef_members', p))
   from unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) as p),
  'service_role sí (como en todas las tablas de public)'
);
select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'chef_members'),
  0,
  'chef_members no tiene políticas: con RLS y sin privilegios, authenticated no ve ninguna fila'
);
select ok(
  (select bool_and(p.prosecdef and coalesce(p.proconfig @> array['search_path=""'], false))
   from pg_proc p
   where p.oid in ('public.chef_id_for_user(uuid)'::regprocedure, 'public.current_chef_id()'::regprocedure,
                   'public.is_chef_of(uuid)'::regprocedure)),
  'chef_id_for_user, current_chef_id e is_chef_of: security definer con search_path vacío'
);
select is(
  (select array_agg(r order by r)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, 'public.chef_id_for_user(uuid)', 'EXECUTE')),
  array['service_role'],
  'chef_id_for_user solo la ejecuta service_role (la Edge Function chef): a otro le diría de qué cocina es cualquier cuenta'
);
select is(
  (select array_agg(r order by r)
   from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_function_privilege(r, 'private.sync_chef_members(text[], uuid)', 'EXECUTE')),
  null::text[],
  'private.sync_chef_members: ningún rol de la API la ejecuta'
);
select ok(
  has_function_privilege('postgres', 'private.sync_chef_members(text[], uuid)', 'EXECUTE'),
  'postgres sí (deploy-supabase.yml, por la Management API, y el SQL editor)'
);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
--   C1: dueña chef1, colaboradores M (socio) y K (cliente.socio, que además tiene ficha de cliente).
--       Clientes A (con cuenta, comparte la despensa), B (sin cuenta, no la comparte), P (prospecto)
--       y la ficha de K.
--   C2: dueña chef2, colaborador M2 (socio2), cliente X.
--   S (suelto): rol chef, sin cocina ni colaboración. N (nuevo), U (sin confirmar), L (bloqueado) y
--   R (sin permiso de borrado): cuentas para la sincronización.
-- ---------------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at) values
  ('7e5f0000-0000-4000-8000-00000000c001', 'chef1@colaboradores.test',         now()),
  ('7e5f0000-0000-4000-8000-00000000c002', 'chef2@colaboradores.test',         now()),
  ('7e5f0000-0000-4000-8000-00000000d001', 'socio@colaboradores.test',         now()),
  ('7e5f0000-0000-4000-8000-00000000d002', 'socio2@colaboradores.test',        now()),
  ('7e5f0000-0000-4000-8000-00000000a001', 'a@colaboradores.test',             now()),
  ('7e5f0000-0000-4000-8000-00000000e001', 'suelto@colaboradores.test',        now()),
  ('7e5f0000-0000-4000-8000-00000000f001', 'nuevo@colaboradores.test',         now()),
  ('7e5f0000-0000-4000-8000-00000000f002', 'cliente.socio@colaboradores.test', now()),
  ('7e5f0000-0000-4000-8000-00000000f003', 'sinconfirmar@colaboradores.test',  null),
  ('7e5f0000-0000-4000-8000-00000000f004', 'bloqueado@colaboradores.test',     now()),
  ('7e5f0000-0000-4000-8000-00000000f005', 'sinpermiso@colaboradores.test',    now());
update public.profiles set role = 'chef'
where id in ('7e5f0000-0000-4000-8000-00000000c001', '7e5f0000-0000-4000-8000-00000000c002',
             '7e5f0000-0000-4000-8000-00000000d001', '7e5f0000-0000-4000-8000-00000000d002',
             '7e5f0000-0000-4000-8000-00000000e001', '7e5f0000-0000-4000-8000-00000000f002');

insert into public.chefs (id, profile_id, display_name, whatsapp) values
  ('7e5f1000-0000-4000-8000-000000000001', '7e5f0000-0000-4000-8000-00000000c001', 'Chef Uno', '+393330000001'),
  ('7e5f1000-0000-4000-8000-000000000002', '7e5f0000-0000-4000-8000-00000000c002', 'Chef Due', '+393330000002');
insert into public.chef_settings (chef_id) values
  ('7e5f1000-0000-4000-8000-000000000001'),
  ('7e5f1000-0000-4000-8000-000000000002');
insert into public.availability_rules (chef_id, dow, start_time, end_time) values
  ('7e5f1000-0000-4000-8000-000000000001', 1, '09:00', '15:00'),
  ('7e5f1000-0000-4000-8000-000000000002', 2, '10:00', '19:00');
insert into public.availability_exceptions (chef_id, date, note) values
  ('7e5f1000-0000-4000-8000-000000000001', '2027-03-08', 'C1'),
  ('7e5f1000-0000-4000-8000-000000000002', '2027-03-08', 'C2');

insert into public.chef_members (chef_id, profile_id) values
  ('7e5f1000-0000-4000-8000-000000000001', '7e5f0000-0000-4000-8000-00000000d001'),
  ('7e5f1000-0000-4000-8000-000000000002', '7e5f0000-0000-4000-8000-00000000d002'),
  ('7e5f1000-0000-4000-8000-000000000001', '7e5f0000-0000-4000-8000-00000000f002');

insert into public.clients (id, chef_id, profile_id, display_name, status, share_pantry) values
  ('7e5f2000-0000-4000-8000-00000000000a', '7e5f1000-0000-4000-8000-000000000001', '7e5f0000-0000-4000-8000-00000000a001', 'Cliente A', 'active', true),
  ('7e5f2000-0000-4000-8000-00000000000b', '7e5f1000-0000-4000-8000-000000000001', null, 'Cliente B', 'active', false),
  ('7e5f2000-0000-4000-8000-00000000000c', '7e5f1000-0000-4000-8000-000000000001', null, 'Prospecto P', 'prospect', false),
  ('7e5f2000-0000-4000-8000-00000000000d', '7e5f1000-0000-4000-8000-000000000001', '7e5f0000-0000-4000-8000-00000000f002', 'Ficha de K', 'active', false),
  ('7e5f2000-0000-4000-8000-00000000000f', '7e5f1000-0000-4000-8000-000000000002', null, 'Cliente X', 'active', true);

insert into public.consents (chef_id, client_id, kind, text_version) values
  ('7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a', 'health_data', 'v1'),
  ('7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a', 'privacy',     'v1'),
  ('7e5f1000-0000-4000-8000-000000000002', '7e5f2000-0000-4000-8000-00000000000f', 'health_data', 'v1');
insert into public.client_restrictions (chef_id, client_id, allergen) values
  ('7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a', 'milk'),
  ('7e5f1000-0000-4000-8000-000000000002', '7e5f2000-0000-4000-8000-00000000000f', 'nuts');

insert into public.recipes (id, chef_id, name_it, active) values
  ('7e5f6000-0000-4000-8000-000000000001', '7e5f1000-0000-4000-8000-000000000001', 'Minestrone', true),
  ('7e5f6000-0000-4000-8000-000000000002', '7e5f1000-0000-4000-8000-000000000001', 'Ricetta ritirata', false),
  ('7e5f6000-0000-4000-8000-00000000000f', '7e5f1000-0000-4000-8000-000000000002', 'Ossobuco', true);
insert into public.recipe_allergens (recipe_id, chef_id, allergen) values
  ('7e5f6000-0000-4000-8000-000000000001', '7e5f1000-0000-4000-8000-000000000001', 'celery'),
  ('7e5f6000-0000-4000-8000-00000000000f', '7e5f1000-0000-4000-8000-000000000002', 'gluten');

insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals) values
  ('7e5f3000-0000-4000-8000-00000000000a', '7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a', 'week', 'accepted', 2, 0, 5, '{dinner}'),
  ('7e5f3000-0000-4000-8000-00000000000c', '7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000c', 'week', 'new',      2, 0, 5, '{dinner}'),
  ('7e5f3000-0000-4000-8000-00000000000f', '7e5f1000-0000-4000-8000-000000000002', '7e5f2000-0000-4000-8000-00000000000f', 'week', 'accepted', 1, 0, 5, '{lunch}');

insert into public.sessions (id, chef_id, client_id, request_id, date, start_time, cook_minutes, status) values
  ('7e5f4000-0000-4000-8000-00000000000a', '7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a', '7e5f3000-0000-4000-8000-00000000000a', '2027-03-01', '10:00', 150, 'confirmed'),
  ('7e5f4000-0000-4000-8000-00000000000f', '7e5f1000-0000-4000-8000-000000000002', '7e5f2000-0000-4000-8000-00000000000f', '7e5f3000-0000-4000-8000-00000000000f', '2027-03-01', '10:00', 150, 'confirmed');

insert into public.quotes (id, chef_id, request_id, session_id, cook_minutes, portions, service_cents, groceries_est_cents, preauth_cents) values
  ('7e5f5000-0000-4000-8000-00000000000a', '7e5f1000-0000-4000-8000-000000000001', '7e5f3000-0000-4000-8000-00000000000a', '7e5f4000-0000-4000-8000-00000000000a', 150, 10, 6700, 3800, 4370),
  ('7e5f5000-0000-4000-8000-00000000000f', '7e5f1000-0000-4000-8000-000000000002', '7e5f3000-0000-4000-8000-00000000000f', '7e5f4000-0000-4000-8000-00000000000f', 150, 5, 6700, 1900, 2185);

insert into public.session_menu (session_id, recipe_id, chef_id, portions) values
  ('7e5f4000-0000-4000-8000-00000000000a', '7e5f6000-0000-4000-8000-000000000001', '7e5f1000-0000-4000-8000-000000000001', 10),
  ('7e5f4000-0000-4000-8000-00000000000f', '7e5f6000-0000-4000-8000-00000000000f', '7e5f1000-0000-4000-8000-000000000002', 5);

-- El ticket de C1 lo subió la dueña (como postgres, uploaded_by se escribe tal cual).
insert into public.receipts (id, chef_id, session_id, storage_path, total_cents, uploaded_by) values
  ('7e5f7000-0000-4000-8000-00000000000a', '7e5f1000-0000-4000-8000-000000000001', '7e5f4000-0000-4000-8000-00000000000a',
   '7e5f1000-0000-4000-8000-000000000001/7e5f4000-0000-4000-8000-00000000000a/ticket.jpg', 3900,
   '7e5f0000-0000-4000-8000-00000000c001'),
  ('7e5f7000-0000-4000-8000-00000000000f', '7e5f1000-0000-4000-8000-000000000002', '7e5f4000-0000-4000-8000-00000000000f',
   '7e5f1000-0000-4000-8000-000000000002/7e5f4000-0000-4000-8000-00000000000f/ticket.jpg', 2000, null);

insert into public.payments (id, chef_id, session_id, kind, provider, amount_cents, status) values
  ('7e5f8000-0000-4000-8000-00000000000a', '7e5f1000-0000-4000-8000-000000000001', '7e5f4000-0000-4000-8000-00000000000a', 'preauth', 'stripe', 11070, 'authorized'),
  ('7e5f8000-0000-4000-8000-00000000000f', '7e5f1000-0000-4000-8000-000000000002', '7e5f4000-0000-4000-8000-00000000000f', 'preauth', 'stripe', 8885, 'authorized');

insert into public.prepared_portions (id, chef_id, client_id, session_id, recipe_id, count_initial, count_left, made_on, consume_by) values
  ('7e5fa000-0000-4000-8000-00000000000a', '7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a',
   '7e5f4000-0000-4000-8000-00000000000a', '7e5f6000-0000-4000-8000-000000000001', 5, 5, '2027-03-01', '2027-03-05');

insert into public.pantry_items (id, chef_id, client_id, name) values
  ('7e5fb000-0000-4000-8000-00000000000a', '7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000a', 'Zucchine'),
  ('7e5fb000-0000-4000-8000-00000000000b', '7e5f1000-0000-4000-8000-000000000001', '7e5f2000-0000-4000-8000-00000000000b', 'Riso'),
  ('7e5fb000-0000-4000-8000-00000000000f', '7e5f1000-0000-4000-8000-000000000002', '7e5f2000-0000-4000-8000-00000000000f', 'Latte');

-- El aviso del pedido nuevo va a la cocinera (submit_public_request): es de ella.
insert into public.notifications (profile_id, kind, channel) values
  ('7e5f0000-0000-4000-8000-00000000c001', 'new_request', 'email');

insert into storage.objects (bucket_id, name) values
  ('receipts', '7e5f1000-0000-4000-8000-000000000001/7e5f4000-0000-4000-8000-00000000000a/ticket.jpg'),
  ('receipts', '7e5f1000-0000-4000-8000-000000000002/7e5f4000-0000-4000-8000-00000000000f/ticket.jpg');

-- =====================================================================
-- 3. Quién es quién
-- =====================================================================
select results_eq(
  $$ select public.chef_id_for_user(u.id)
     from unnest(array['7e5f0000-0000-4000-8000-00000000c001', '7e5f0000-0000-4000-8000-00000000d001',
                       '7e5f0000-0000-4000-8000-00000000d002', '7e5f0000-0000-4000-8000-00000000a001',
                       '7e5f0000-0000-4000-8000-00000000e001', null]::uuid[]) with ordinality as u (id, n)
     order by u.n $$,
  $$ values ('7e5f1000-0000-4000-8000-000000000001'::uuid), ('7e5f1000-0000-4000-8000-000000000001'::uuid),
            ('7e5f1000-0000-4000-8000-000000000002'::uuid), (null::uuid), (null::uuid), (null::uuid) $$,
  'chef_id_for_user: la dueña y sus colaboradores dan su cocina; un cliente, un rol chef sin cocina o nadie, null'
);

-- =====================================================================
-- 4. El colaborador M: lo mismo que la cocinera
-- =====================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e5f0000-0000-4000-8000-00000000d001","role":"authenticated"}';

select is(public.current_chef_id(), '7e5f1000-0000-4000-8000-000000000001'::uuid,
  'M: current_chef_id() es la cocina de la que es colaborador');
select ok(
  public.is_chef_of('7e5f1000-0000-4000-8000-000000000001')
  and not public.is_chef_of('7e5f1000-0000-4000-8000-000000000002')
  and public.is_chef_of(null) is false,
  'M: is_chef_of dice sí a su cocina y no a otra ni a null'
);

-- lecturas
select is((select array_agg(id order by id) from public.clients),
  array['7e5f2000-0000-4000-8000-00000000000a', '7e5f2000-0000-4000-8000-00000000000b',
        '7e5f2000-0000-4000-8000-00000000000c', '7e5f2000-0000-4000-8000-00000000000d']::uuid[],
  'M: ve las fichas de la cocina (también el prospecto) y no las de otra');
select is((select array_agg(id order by id) from public.requests),
  array['7e5f3000-0000-4000-8000-00000000000a', '7e5f3000-0000-4000-8000-00000000000c']::uuid[],
  'M: ve los pedidos de la cocina');
select is((select array_agg(id order by id) from public.sessions),
  array['7e5f4000-0000-4000-8000-00000000000a']::uuid[], 'M: ve las sesiones de la cocina (la agenda)');
select is((select array_agg(id order by id) from public.quotes),
  array['7e5f5000-0000-4000-8000-00000000000a']::uuid[], 'M: ve los presupuestos de la cocina');
select is((select array_agg(id order by id) from public.payments),
  array['7e5f8000-0000-4000-8000-00000000000a']::uuid[], 'M: ve los cobros de la cocina');
select is((select array_agg(client_id::text || ' ' || allergen::text) from public.client_restrictions),
  array['7e5f2000-0000-4000-8000-00000000000a milk'],
  'M: ve las restricciones de los clientes de la cocina, como la cocinera');
select is((select count(*)::int from public.consents), 2, 'M: ve los consentimientos de los clientes de la cocina');
select is((select array_agg(id order by id) from public.recipes),
  array['7e5f6000-0000-4000-8000-000000000001', '7e5f6000-0000-4000-8000-000000000002']::uuid[],
  'M: ve todo el recetario de la cocina (también lo dado de baja) y no el de otra');
select is((select array_agg(recipe_id) from public.recipe_allergens),
  array['7e5f6000-0000-4000-8000-000000000001']::uuid[], 'M: ve los alérgenos de los platos de la cocina');
select is((select array_agg(chef_id) from public.chef_settings),
  array['7e5f1000-0000-4000-8000-000000000001']::uuid[], 'M: ve las tarifas de la cocina');
select is(
  (select array_agg(distinct chef_id) from public.availability_rules)
  || (select array_agg(distinct chef_id) from public.availability_exceptions),
  array['7e5f1000-0000-4000-8000-000000000001', '7e5f1000-0000-4000-8000-000000000001']::uuid[],
  'M: ve el horario y los días bloqueados de la cocina');
select is((select array_agg(session_id) from public.session_menu),
  array['7e5f4000-0000-4000-8000-00000000000a']::uuid[], 'M: ve los menús de las sesiones de la cocina');
select is((select array_agg(id) from public.receipts),
  array['7e5f7000-0000-4000-8000-00000000000a']::uuid[], 'M: ve los tickets de la cocina');
select is((select array_agg(id) from public.prepared_portions),
  array['7e5fa000-0000-4000-8000-00000000000a']::uuid[], 'M: ve las porciones de la cocina');
select is((select array_agg(client_id) from public.pantry_items),
  array['7e5f2000-0000-4000-8000-00000000000a']::uuid[],
  'M: ve la despensa que se comparte (A) y no la que no (B), como la cocinera');
select is((select array_agg(id order by id) from public.profiles),
  array['7e5f0000-0000-4000-8000-00000000a001', '7e5f0000-0000-4000-8000-00000000d001',
        '7e5f0000-0000-4000-8000-00000000f002']::uuid[],
  'M: ve su perfil y los de los clientes con cuenta de la cocina; el de la cocinera, no');
select is((select array_agg(id) from public.chefs),
  array['7e5f1000-0000-4000-8000-000000000001']::uuid[],
  'M: lee la ficha de la cocina (la app muestra su nombre) y no la de otra');
select is((select count(*)::int from public.notifications), 0,
  'M: no ve los avisos de la cocinera (cada aviso es de una persona)');
select is((select array_agg(name) from storage.objects where bucket_id = 'receipts'),
  array['7e5f1000-0000-4000-8000-000000000001/7e5f4000-0000-4000-8000-00000000000a/ticket.jpg'],
  'M: en storage ve la carpeta de la cocina y no la de otra');

-- escrituras que la cocinera hace desde la app
select lives_ok(
  $$ insert into public.availability_exceptions (chef_id, date, note)
     values ('7e5f1000-0000-4000-8000-000000000001', '2027-04-05', 'Ferie') $$,
  'M: bloquea un día de la cocina');
select lives_ok(
  $$ update public.chef_settings set weekly_rate_cents = 15500 where chef_id = '7e5f1000-0000-4000-8000-000000000001' $$,
  'M: cambia las tarifas de la cocina');
select lives_ok(
  $$ update public.requests set status = 'rejected', seen_at = now() where id = '7e5f3000-0000-4000-8000-00000000000c' $$,
  'M: marca visto y rechaza un pedido nuevo');
select lives_ok(
  $$ update public.clients set status = 'trial' where id = '7e5f2000-0000-4000-8000-00000000000c' $$,
  'M: «Segna come cliente» (clients_guard_update usa is_chef_of)');
select lives_ok(
  $$ insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
     values ('7e5f1000-0000-4000-8000-000000000001', '7e5f4000-0000-4000-8000-00000000000a', 'cash', 'cash', 5000, 'pending') $$,
  'M: registra un cobro en efectivo pendiente');
select lives_ok(
  $$ insert into public.recipes (chef_id, name_it) values ('7e5f1000-0000-4000-8000-000000000001', 'Risotto') $$,
  'M: suma un plato al recetario');
select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('receipts', '7e5f1000-0000-4000-8000-000000000001/7e5f4000-0000-4000-8000-00000000000a/ticket2.jpg') $$,
  'M: sube un ticket a la carpeta de la cocina');

-- Con varias cuentas del lado de la cocina, el autor de un ticket es quien lo sube (no lo que mande).
insert into public.receipts (id, chef_id, session_id, storage_path, total_cents, uploaded_by) values
  ('7e5f7000-0000-4000-8000-0000000000a2', '7e5f1000-0000-4000-8000-000000000001', '7e5f4000-0000-4000-8000-00000000000a',
   '7e5f1000-0000-4000-8000-000000000001/7e5f4000-0000-4000-8000-00000000000a/ticket2.jpg', 1200,
   '7e5f0000-0000-4000-8000-00000000c001');
update public.receipts set uploaded_by = '7e5f0000-0000-4000-8000-00000000d001', total_cents = 4000
where id = '7e5f7000-0000-4000-8000-00000000000a';
select is(
  (select array_agg(format('%s %s %s', right(id::text, 2), right(uploaded_by::text, 4), total_cents) order by id)
   from public.receipts),
  array['0a c001 4000', 'a2 d001 1200'],
  'receipts.uploaded_by: el ticket que sube M queda a su nombre aunque mande otro, y en uno ajeno corrige el total sin cambiarle el autor');

-- El catálogo de platos (20261116170000): save_recipe usa current_chef_id().
select lives_ok(
  $$ select public.save_recipe(jsonb_build_object(
       'id', '7e5f6000-0000-4000-8000-0000000000a1', 'name_it', 'Pasta e fagioli',
       'notes', 'Ammollare i fagioli la sera prima',
       'allergens', jsonb_build_array('gluten'),
       'ingredients', jsonb_build_array(jsonb_build_object('name', 'Fagioli', 'quantity', 300, 'unit', 'g')))) $$,
  'M: guarda un plato entero en el catálogo de la cocina (save_recipe)');
select is(
  (select format('%s %s %s', r.chef_id, i.name, n.notes)
   from public.recipes r
   join public.recipe_ingredients i on i.recipe_id = r.id
   join public.recipe_notes n on n.recipe_id = r.id
   where r.id = '7e5f6000-0000-4000-8000-0000000000a1'),
  '7e5f1000-0000-4000-8000-000000000001 Fagioli Ammollare i fagioli la sera prima',
  'M: el plato queda en la cocina de la cocinera, y lee sus ingredientes y sus notas (solo de la cocina)');

-- lo que la cocinera tampoco hace desde la app
select throws_ok(
  $$ update public.sessions set status = 'cancelled' where id = '7e5f4000-0000-4000-8000-00000000000a' $$,
  '42501', null, 'M: como la cocinera, no cambia estados de sesión desde la app (eso es de la Edge Function chef)');
select throws_ok(
  $$ insert into public.payments (chef_id, session_id, kind, provider, amount_cents, status)
     values ('7e5f1000-0000-4000-8000-000000000001', '7e5f4000-0000-4000-8000-00000000000a', 'capture', 'stripe', 100, 'succeeded') $$,
  '42501', null, 'M: ni registra cobros de Stripe');
select throws_ok(
  $$ delete from public.requests where id = '7e5f3000-0000-4000-8000-00000000000c' $$,
  '42501', null, 'M: ni borra pedidos');

-- lo que un colaborador nunca puede
select throws_ok(
  $$ insert into public.chef_members (chef_id, profile_id)
     values ('7e5f1000-0000-4000-8000-000000000001', '7e5f0000-0000-4000-8000-00000000e001') $$,
  '42501', null, 'M: no agrega colaboradores');
select throws_ok(
  $$ delete from public.chef_members where profile_id = '7e5f0000-0000-4000-8000-00000000f002' $$,
  '42501', null, 'M: no saca colaboradores');
select throws_ok(
  $$ update public.chef_members set chef_id = '7e5f1000-0000-4000-8000-000000000002' $$,
  '42501', null, 'M: no pasa a nadie a otra cocina');
select throws_ok($$ select * from public.chef_members $$, '42501', null, 'M: no lista colaboradores');
select throws_ok(
  $$ update public.chefs set profile_id = '7e5f0000-0000-4000-8000-00000000d001' where id = '7e5f1000-0000-4000-8000-000000000001' $$,
  '42501', null, 'M: no cambia chefs.profile_id (no se vuelve la dueña)');
select throws_ok(
  $$ update public.profiles set role = 'client' where id = '7e5f0000-0000-4000-8000-00000000d001' $$,
  '42501', null, 'M: no cambia su rol');
select lives_ok(
  $$ update public.chefs set whatsapp = '+390000000000' where id = '7e5f1000-0000-4000-8000-000000000001' $$,
  'M: un update de la ficha pública de la cocinera no falla (la RLS no le deja ninguna fila)');
select is((select whatsapp from public.chefs where id = '7e5f1000-0000-4000-8000-000000000001'), '+393330000001',
  'M: la ficha pública sigue con el WhatsApp de la dueña (el update no tocó nada)');
select throws_ok(
  $$ select public.chef_id_for_user('7e5f0000-0000-4000-8000-00000000a001') $$,
  '42501', null, 'M: no pregunta de qué cocina es otra cuenta');
select throws_ok(
  $$ insert into public.availability_exceptions (chef_id, date)
     values ('7e5f1000-0000-4000-8000-000000000002', '2027-04-06') $$,
  '42501', null, 'M: no toca la disponibilidad de otra cocina');
select lives_ok(
  $$ update public.chef_settings set weekly_rate_cents = 1 where chef_id = '7e5f1000-0000-4000-8000-000000000002' $$,
  'M: un update de las tarifas de otra cocina no afecta filas (se verifica abajo)');

-- =====================================================================
-- 5. La dueña, una cuenta con rol chef sin cocina, un cliente, service_role y anon
-- =====================================================================
set local request.jwt.claims = '{"sub":"7e5f0000-0000-4000-8000-00000000c001","role":"authenticated"}';

select is(public.current_chef_id(), '7e5f1000-0000-4000-8000-000000000001'::uuid, 'la dueña: su cocina, como antes');
select is((select array_agg(id order by id) from public.clients),
  array['7e5f2000-0000-4000-8000-00000000000a', '7e5f2000-0000-4000-8000-00000000000b',
        '7e5f2000-0000-4000-8000-00000000000c', '7e5f2000-0000-4000-8000-00000000000d']::uuid[],
  'la dueña ve las mismas fichas que su colaborador');
select is((select count(*)::int from public.notifications), 1, 'la dueña ve su aviso');
select lives_ok(
  $$ update public.chefs set whatsapp = '+393330000099' where id = '7e5f1000-0000-4000-8000-000000000001' $$,
  'la dueña edita su ficha pública');
select throws_ok($$ select * from public.chef_members $$, '42501', null,
  'la dueña tampoco lista colaboradores desde la app: los define el despliegue');

set local request.jwt.claims = '{"sub":"7e5f0000-0000-4000-8000-00000000e001","role":"authenticated"}';

select is(public.current_chef_id(), null::uuid, 'S (rol chef, sin cocina ni colaboración): ninguna cocina');
select is(
  (select count(*)::int from public.clients) + (select count(*)::int from public.requests)
  + (select count(*)::int from public.sessions) + (select count(*)::int from public.chef_settings)
  + (select count(*)::int from public.availability_exceptions) + (select count(*)::int from public.chefs),
  0,
  'S: el rol chef solo no abre nada (ni fichas, pedidos, sesiones, tarifas, bloqueos ni fichas de cocineras)');
select throws_ok(
  $$ insert into public.availability_exceptions (chef_id, date)
     values ('7e5f1000-0000-4000-8000-000000000001', '2027-04-07') $$,
  '42501', null, 'S: no bloquea días de nadie');
select throws_ok(
  $$ select public.save_recipe(jsonb_build_object(
       'id', '7e5f6000-0000-4000-8000-0000000000a2', 'name_it', 'Intruso',
       'allergens', jsonb_build_array(), 'ingredients', jsonb_build_array())) $$,
  '42501', 'not_a_chef', 'S: ni guarda platos (save_recipe: sin cocina, not_a_chef)');

set local request.jwt.claims = '{"sub":"7e5f0000-0000-4000-8000-00000000a001","role":"authenticated"}';

select is(public.current_chef_id(), null::uuid, 'A (cliente): ninguna cocina');
select is((select array_agg(id) from public.clients),
  array['7e5f2000-0000-4000-8000-00000000000a']::uuid[], 'A: sigue viendo solo su ficha');
select is((select array_agg(id) from public.chefs),
  array['7e5f1000-0000-4000-8000-000000000001']::uuid[], 'A: sigue leyendo la ficha de su cocinera');

reset role;
set local role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

select is(public.chef_id_for_user('7e5f0000-0000-4000-8000-00000000d001'), '7e5f1000-0000-4000-8000-000000000001'::uuid,
  'service_role (la Edge Function chef): el colaborador entra con la cocina de la que es colaborador');
select is(public.chef_id_for_user('7e5f0000-0000-4000-8000-00000000a001'), null::uuid,
  'service_role: un cliente con cuenta no tiene cocina (la función responde 403)');

reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';

select throws_ok($$ select public.chef_id_for_user('7e5f0000-0000-4000-8000-00000000d001') $$,
  '42501', null, 'anon no ejecuta chef_id_for_user');

reset role;

select is((select weekly_rate_cents from public.chef_settings where chef_id = '7e5f1000-0000-4000-8000-000000000001'),
  15500, 'la tarifa que cambió el colaborador quedó guardada');
select is((select weekly_rate_cents from public.chef_settings where chef_id = '7e5f1000-0000-4000-8000-000000000002'),
  15000, 'la de la otra cocina sigue igual');
select is((select whatsapp from public.chefs where id = '7e5f1000-0000-4000-8000-000000000001'),
  '+393330000099', 'la ficha pública tiene el WhatsApp que puso la dueña, no el del colaborador');

-- =====================================================================
-- 6. Dueña o colaboradora, nunca las dos (como postgres: también la service role y el despliegue)
-- =====================================================================
select throws_ok(
  $$ insert into public.chef_members (chef_id, profile_id)
     values ('7e5f1000-0000-4000-8000-000000000002', '7e5f0000-0000-4000-8000-00000000c001') $$,
  '23514', 'member_is_chef', 'la cuenta de una cocinera no es colaboradora de ninguna cocina');
select throws_ok(
  $$ update public.chef_members set profile_id = '7e5f0000-0000-4000-8000-00000000c002'
     where profile_id = '7e5f0000-0000-4000-8000-00000000d002' $$,
  '23514', 'member_is_chef', 'ni con un update de chef_members (la guarda corre también en update)');
select throws_ok(
  $$ insert into public.chefs (profile_id, display_name) values ('7e5f0000-0000-4000-8000-00000000d001', 'Socio') $$,
  '23514', 'chef_is_member', 'un colaborador no pasa a tener cocina propia');
select throws_ok(
  $$ update public.chefs set profile_id = '7e5f0000-0000-4000-8000-00000000d001'
     where id = '7e5f1000-0000-4000-8000-000000000002' $$,
  '23514', 'chef_is_member', 'ni se queda con la de otra (chefs.profile_id)');
select throws_ok(
  $$ select public.promote_to_chef('socio@colaboradores.test', 'Socio') $$,
  '23514', 'chef_is_member', 'promote_to_chef tampoco lo vuelve la cocinera dueña');
select throws_ok(
  $$ insert into public.chef_members (chef_id, profile_id)
     values ('7e5f1000-0000-4000-8000-000000000002', '7e5f0000-0000-4000-8000-00000000d001') $$,
  '23505', null, 'una cuenta es colaboradora de una sola cocina');

-- =====================================================================
-- 7. private.sync_chef_members: la lista manda
-- =====================================================================
-- Antes de sincronizar: sesiones abiertas de M (sigue en la lista) y de K (sale), y en la cuenta de N
-- una contraseña, una sesión, un refresh token y un factor MFA de otra persona (como en promote_to_chef).
-- N y K tienen además un refresh token sin sesión (no se va en cascada con las sesiones).
insert into auth.sessions (id, user_id) values
  ('7e5f9000-0000-4000-8000-000000000001', '7e5f0000-0000-4000-8000-00000000d001'),
  ('7e5f9000-0000-4000-8000-000000000002', '7e5f0000-0000-4000-8000-00000000f002'),
  ('7e5f9000-0000-4000-8000-000000000003', '7e5f0000-0000-4000-8000-00000000f001');
update auth.users set encrypted_password = extensions.crypt('clave-de-otra-persona', extensions.gen_salt('bf'))
where id = '7e5f0000-0000-4000-8000-00000000f001';
insert into auth.refresh_tokens (token, user_id, session_id, revoked) values
  ('rt-de-otra-persona', '7e5f0000-0000-4000-8000-00000000f001', '7e5f9000-0000-4000-8000-000000000003', false),
  ('rt-sin-sesion-n',    '7e5f0000-0000-4000-8000-00000000f001', null, false),
  ('rt-sin-sesion-k',    '7e5f0000-0000-4000-8000-00000000f002', null, false);
insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
values ('7e5f9100-0000-4000-8000-000000000001', '7e5f0000-0000-4000-8000-00000000f001', 'otra persona', 'totp', 'verified', now(), now());

create temp table sync1 as
select private.sync_chef_members(
  array[' NUEVO@colaboradores.test', 'socio@colaboradores.test', 'nuevo@colaboradores.test '],
  '7e5f1000-0000-4000-8000-000000000001') as r;

select is((select r from sync1),
  '{"members": 2, "added": 1, "kept": 1, "removed": 1, "accounts_deleted": 0}'::jsonb,
  'sincroniza con la lista: N entra, M sigue y K sale (con su cuenta: es la de una ficha de cliente)');
select results_eq(
  $$ select profile_id from public.chef_members where chef_id = '7e5f1000-0000-4000-8000-000000000001' order by profile_id $$,
  $$ values ('7e5f0000-0000-4000-8000-00000000d001'::uuid), ('7e5f0000-0000-4000-8000-00000000f001'::uuid) $$,
  'en la cocina quedan los de la lista: sin mayúsculas, espacios ni repetidos');
select is((select role::text from public.profiles where id = '7e5f0000-0000-4000-8000-00000000f001'), 'chef',
  'N pasa a rol chef: la app lo lleva al área de la cocinera');
select ok(
  (select u.encrypted_password <> extensions.crypt('clave-de-otra-persona', u.encrypted_password)
   from auth.users u where u.id = '7e5f0000-0000-4000-8000-00000000f001'),
  'N: la contraseña que hubiera puesto otra persona ya no sirve (se entra con el código)');
select is(
  (select count(*)::int from auth.sessions where user_id = '7e5f0000-0000-4000-8000-00000000f001')
  + (select count(*)::int from auth.refresh_tokens where user_id = '7e5f0000-0000-4000-8000-00000000f001')
  + (select count(*)::int from auth.mfa_factors where user_id = '7e5f0000-0000-4000-8000-00000000f001'),
  0,
  'N: las sesiones, los refresh tokens y los factores MFA de antes se cierran');
select is((select count(*)::int from auth.sessions where user_id = '7e5f0000-0000-4000-8000-00000000d001'), 1,
  'M, que sigue, no se toca: un despliegue no le cierra la sesión');
select is((select count(*)::int from public.chef_members where profile_id = '7e5f0000-0000-4000-8000-00000000f002'), 0,
  'K, que salió de la lista, ya no es colaborador');
select is((select role::text from public.profiles where id = '7e5f0000-0000-4000-8000-00000000f002'), 'client',
  'K vuelve a rol client');
select is((select count(*)::int from auth.users where id = '7e5f0000-0000-4000-8000-00000000f002'), 1,
  'la cuenta de K no se borra: tiene una ficha de cliente');
select is(
  (select count(*)::int from auth.sessions where user_id = '7e5f0000-0000-4000-8000-00000000f002')
  + (select count(*)::int from auth.refresh_tokens where user_id = '7e5f0000-0000-4000-8000-00000000f002'),
  0,
  'pero se le cierran las sesiones y los refresh tokens, también el que no tenía sesión');
select is((select count(*)::int from public.chef_members where profile_id = '7e5f0000-0000-4000-8000-00000000d002'), 1,
  'el colaborador de otra cocina no se toca');

set local role authenticated;
set local request.jwt.claims = '{"sub":"7e5f0000-0000-4000-8000-00000000f002","role":"authenticated"}';

select is(public.current_chef_id(), null::uuid, 'K, fuera de la lista, pierde el acceso en el acto');
select is((select array_agg(id) from public.clients),
  array['7e5f2000-0000-4000-8000-00000000000d']::uuid[], 'K ve solo su ficha de cliente, nada de la cocina');

reset role;

-- N entra después del alta: otra corrida con la misma lista no lo saca. A M alguien le cambió el
-- rol a mano (la app lo mandaría al área de clientes).
insert into auth.sessions (id, user_id) values ('7e5f9000-0000-4000-8000-000000000004', '7e5f0000-0000-4000-8000-00000000f001');
update public.profiles set role = 'client' where id = '7e5f0000-0000-4000-8000-00000000d001';
create temp table sync2 as
select private.sync_chef_members(array['socio@colaboradores.test', 'nuevo@colaboradores.test'],
                                 '7e5f1000-0000-4000-8000-000000000001') as r;
select is((select r from sync2),
  '{"members": 2, "added": 0, "kept": 2, "removed": 0, "accounts_deleted": 0}'::jsonb,
  'otra corrida con la misma lista no cambia nada (idempotente)');
select is((select count(*)::int from auth.sessions where user_id = '7e5f0000-0000-4000-8000-00000000f001'), 1,
  'y no le cierra la sesión a N');
select is((select role::text from public.profiles where id = '7e5f0000-0000-4000-8000-00000000d001'), 'chef',
  'M, que sigue, vuelve a rol chef si alguien se lo cambió a mano');

create temp table sync3 as
select private.sync_chef_members(array['socio@colaboradores.test'], '7e5f1000-0000-4000-8000-000000000001') as r;
select is((select r from sync3),
  '{"members": 1, "added": 0, "kept": 1, "removed": 1, "accounts_deleted": 1}'::jsonb,
  'N sale de la lista: deja de ser colaborador');
select is(
  (select count(*)::int from auth.users where id = '7e5f0000-0000-4000-8000-00000000f001')
  + (select count(*)::int from public.profiles where id = '7e5f0000-0000-4000-8000-00000000f001'),
  0,
  'y su cuenta se borra, con su perfil: era solo para entrar al área');

-- Si algo impide borrar la cuenta (una clave foránea sin cascada), igual pierde la colaboración.
create temp table sync4 as
select private.sync_chef_members(array['socio@colaboradores.test', 'bloqueado@colaboradores.test'],
                                 '7e5f1000-0000-4000-8000-000000000001') as r;
create table private.referencia_de_prueba (user_id uuid not null references auth.users (id));
insert into private.referencia_de_prueba values ('7e5f0000-0000-4000-8000-00000000f004');
create temp table sync5 as
select private.sync_chef_members(array['socio@colaboradores.test'], '7e5f1000-0000-4000-8000-000000000001') as r;
select is((select r from sync5),
  '{"members": 1, "added": 0, "kept": 1, "removed": 1, "accounts_deleted": 0}'::jsonb,
  'una cuenta que no se puede borrar sale igual de la lista');
select is(
  (select role::text from public.profiles where id = '7e5f0000-0000-4000-8000-00000000f004')
  || ' ' || (select count(*)::text from public.chef_members where profile_id = '7e5f0000-0000-4000-8000-00000000f004'),
  'client 0',
  'y queda como cuenta de cliente, sin colaboración');

-- Lo mismo si el rol que sincroniza no puede borrar en auth.users (insufficient_privilege, la duda de
-- producción): un trigger de prueba da 42501 al borrar la cuenta de R, como lo haría el permiso.
create temp table sync_sin_permiso_alta as
select private.sync_chef_members(array['socio@colaboradores.test', 'sinpermiso@colaboradores.test'],
                                 '7e5f1000-0000-4000-8000-000000000001') as r;
insert into auth.sessions (id, user_id) values ('7e5f9000-0000-4000-8000-000000000005', '7e5f0000-0000-4000-8000-00000000f005');
create function private.prueba_sin_permiso() returns trigger language plpgsql as $$
begin
  raise exception 'permission denied for table users' using errcode = '42501';
end
$$;
create trigger prueba_sin_permiso before delete on auth.users
  for each row when (old.id = '7e5f0000-0000-4000-8000-00000000f005')
  execute function private.prueba_sin_permiso();
create temp table sync_sin_permiso as
select private.sync_chef_members(array['socio@colaboradores.test'], '7e5f1000-0000-4000-8000-000000000001') as r;
select is((select r from sync_sin_permiso),
  '{"members": 1, "added": 0, "kept": 1, "removed": 1, "accounts_deleted": 0}'::jsonb,
  'si no se puede borrar la cuenta por permisos, sale igual de la lista (la sincronización sigue)');
select is(
  (select role::text from public.profiles where id = '7e5f0000-0000-4000-8000-00000000f005')
  || ' ' || (select count(*)::text from public.chef_members where profile_id = '7e5f0000-0000-4000-8000-00000000f005')
  || ' ' || (select count(*)::text from auth.users where id = '7e5f0000-0000-4000-8000-00000000f005')
  || ' ' || (select count(*)::text from auth.sessions where user_id = '7e5f0000-0000-4000-8000-00000000f005'),
  'client 0 1 0',
  'y queda como cuenta de cliente: sin colaboración ni sesiones, con la cuenta todavía en Auth');
drop trigger prueba_sin_permiso on auth.users;

-- Errores: nada cambia (cada uno corta la sincronización entera).
select throws_ok(
  $$ select private.sync_chef_members(array['socio@colaboradores.test', 'x''); delete from public.chefs; --@a.it'],
                                      '7e5f1000-0000-4000-8000-000000000001') $$,
  '22023', 'invalid_member_email', 'un email inválido corta todo');
select throws_ok(
  format($$ select private.sync_chef_members(array[%L], '7e5f1000-0000-4000-8000-000000000001') $$,
         repeat('a', 250) || '@colaboradores.test'),
  '22023', 'invalid_member_email', 'también uno de más de 254 caracteres (RFC 5321), aunque cumpla el patrón');
select throws_ok(
  $$ select private.sync_chef_members(array['Chef1@Colaboradores.test'], '7e5f1000-0000-4000-8000-000000000001') $$,
  '22023', 'chef_email_not_member', 'el email de una cocinera no es de colaborador: su cuenta no se toca');
select throws_ok(
  $$ select private.sync_chef_members(array['chef2@colaboradores.test'], '7e5f1000-0000-4000-8000-000000000001') $$,
  '22023', 'chef_email_not_member', 'tampoco el de la dueña de otra cocina');
select throws_ok(
  $$ select private.sync_chef_members(array['nadie@colaboradores.test'], '7e5f1000-0000-4000-8000-000000000001') $$,
  'P0002', 'member_user_not_found', 'sin cuenta en Auth: error (el despliegue la crea antes)');
select throws_ok(
  $$ select private.sync_chef_members(array['sinconfirmar@colaboradores.test'], '7e5f1000-0000-4000-8000-000000000001') $$,
  'P0001', 'member_user_not_confirmed', 'una cuenta sin confirmar (la registró otro): error');
select throws_ok(
  $$ select private.sync_chef_members(array['socio2@colaboradores.test'], '7e5f1000-0000-4000-8000-000000000001') $$,
  'P0001', 'member_of_other_chef', 'el colaborador de otra cocina no se cambia de cocina');
select throws_ok(
  $$ select private.sync_chef_members(array(select format('p%s@colaboradores.test', i) from generate_series(1, 11) as i),
                                      '7e5f1000-0000-4000-8000-000000000001') $$,
  '22023', 'too_many_members', 'más de 10 colaboradores: error');
select throws_ok(
  $$ select private.sync_chef_members(null, '7e5f1000-0000-4000-8000-000000000001') $$,
  '22023', 'invalid_member_email', 'sin lista, error: la lista vacía es array[]::text[]');
select throws_ok(
  $$ select private.sync_chef_members(array['socio@colaboradores.test'], '00000000-0000-4000-8000-000000000000') $$,
  'P0002', 'chef_not_found', 'una cocina que no existe: error');
select throws_ok(
  $$ select private.sync_chef_members(array['socio@colaboradores.test']) $$,
  'P0001', 'single_chef_required', 'sin decir la cocina, con más de una: error (producción tiene una sola)');

create temp table sync6 as
select private.sync_chef_members(array[]::text[], '7e5f1000-0000-4000-8000-000000000001') as r;
select is((select r from sync6),
  '{"members": 0, "added": 0, "kept": 0, "removed": 1, "accounts_deleted": 1}'::jsonb,
  'lista vacía: la cocina se queda sin colaboradores');
select is((select count(*)::int from public.chef_members where chef_id = '7e5f1000-0000-4000-8000-000000000002'), 1,
  'y los de otra cocina siguen');

select finish();
rollback;
