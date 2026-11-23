-- =====================================================================
-- Radici · RLS de la clienta cerrada y privilegios por defecto (SPEC §6 y §14, decisión D8).
-- Tests: supabase/tests/database/02_rls.test.sql y 00_schema.test.sql.
--
-- El área de la clienta vive en la app Flutter, pero no lee ni escribe tablas: todo pasa por Edge
-- Functions con la service role (SPEC §6). Esta migración cierra la puerta de la base antes de que
-- exista la primera cuenta de clienta (hoy no hay ninguna: riesgo bajo en producción).
--
--   1. Se borran las políticas de la clienta. Quedan solo su perfil y sus avisos.
--   2. profiles: authenticated solo puede actualizar locale.
--   3. Privilegios por defecto: todo objeto nuevo nace cerrado (sin EXECUTE para PUBLIC y sin nada
--      para anon ni authenticated). Lo que haga falta se concede a mano, en la migración que lo crea.
--   4. Las funciones que ya existen: nada ejecutable por PUBLIC ni anon; authenticated solo ejecuta
--      los helpers de la cocina y las rpc de la app (el inventario de 00_schema lo fija).
--
-- Producción no cambia para la cocinera ni sus colaboradores: sus políticas (current_chef_id /
-- is_chef_of), las rpc de la app y las Edge Functions (service role) siguen como estaban.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Políticas de la clienta
-- ---------------------------------------------------------------------
drop policy "clients: el cliente lee su ficha"                         on public.clients;
drop policy "clients: el cliente edita su ficha"                       on public.clients;
drop policy "client_restrictions: el cliente gestiona las suyas"       on public.client_restrictions;
drop policy "consents: el cliente lee los suyos"                       on public.consents;
drop policy "consents: el cliente otorga los suyos"                    on public.consents;
drop policy "consents: el cliente revoca los suyos"                    on public.consents;
drop policy "requests: el cliente lee los suyos"                       on public.requests;
drop policy "requests: el cliente crea los suyos (siempre como new)"   on public.requests;
drop policy "quotes: el cliente lee los de sus pedidos"                on public.quotes;
drop policy "sessions: el cliente lee las suyas"                       on public.sessions;
drop policy "session_menu: el cliente lee el de sus sesiones"          on public.session_menu;
drop policy "recipes: el cliente lee las del catálogo de su cocinera"  on public.recipes;
drop policy "recipe_allergens: el cliente lee los de las recetas que ve" on public.recipe_allergens;
drop policy "payments: el cliente lee los de sus sesiones"             on public.payments;
drop policy "receipts: el cliente lee los de sus sesiones"             on public.receipts;
drop policy "recurring_plans: el cliente lee los suyos"                on public.recurring_plans;
drop policy "prepared_portions: el cliente lee las suyas"              on public.prepared_portions;
drop policy "prepared_portions: el cliente descuenta o descarta las suyas" on public.prepared_portions;
drop policy "pantry_items: el cliente gestiona su despensa"            on public.pantry_items;
drop policy "push_tokens: el usuario gestiona los suyos"               on public.push_tokens;
drop policy "receipts: el cliente lee los tickets de sus sesiones"     on storage.objects;

-- chefs: la política de lectura mezclaba la cocina y la clienta (current_client_chef_ids). Queda solo
-- la cocina (la dueña y sus colaboradores, current_chef_id): la clienta ya no lee la ficha de su cocinera.
drop policy "chefs: la cocinera lee la suya; el cliente, la de sus cocineras" on public.chefs;
create policy "chefs: la cocinera lee la suya"
  on public.chefs for select to authenticated
  using (id = (select public.current_chef_id()));
comment on policy "chefs: la cocinera lee la suya" on public.chefs is
  'La dueña y sus colaboradores leen la ficha de su cocina (current_chef_id). La clienta no lee nada de chefs: lo que necesita le llega por Edge Functions.';

-- Quedan solo estas (inventario 2 de 00_schema): profiles (leer y editar el suyo, solo locale),
-- notifications (leer las suyas) y chefs (la dueña edita su ficha pública; una cuenta sin cocina no tiene fila).

-- ---------------------------------------------------------------------
-- 2. profiles: authenticated solo actualiza locale
-- ---------------------------------------------------------------------
-- La app (cocinera y colaboradores) solo cambia el idioma (account_repository.updateLanguage). El
-- nombre y el teléfono de la cuenta no los edita nadie desde la API: antes la clienta podía escribir
-- cualquier texto en su nombre y quedaba en lo que ve la cocinera.
revoke update on public.profiles from authenticated;
grant update (locale) on public.profiles to authenticated;

-- ---------------------------------------------------------------------
-- 3. Privilegios por defecto (para lo que cree el rol de las migraciones, postgres)
-- ---------------------------------------------------------------------
-- Global: sin EXECUTE para PUBLIC. Un revoke por esquema solo no lo saca: el EXECUTE de PUBLIC
-- viene del valor por defecto global de Postgres, no de uno del esquema.
alter default privileges for role postgres revoke execute on functions from public;

-- public: lo nuevo nace sin nada para anon ni authenticated (en proyectos viejos de Supabase nacía
-- con todo, y en los nuevos con parte: así los dos quedan igual).
alter default privileges for role postgres in schema public revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated;

-- service_role (las Edge Functions) sigue recibiendo todo lo nuevo de public, como en producción.
alter default privileges for role postgres in schema public grant all on tables    to service_role;
alter default privileges for role postgres in schema public grant all on sequences to service_role;
alter default privileges for role postgres in schema public grant all on functions to service_role;

-- Estos valores valen para los objetos que crea postgres. Los de otro dueño (supabase_admin: sus
-- esquemas) no se tocan: 00_schema exige que las funciones de las migraciones sean de postgres.

-- ---------------------------------------------------------------------
-- 4. Funciones que ya existen
-- ---------------------------------------------------------------------
-- Nada ejecutable por PUBLIC ni anon, y authenticated solo lo de abajo. Las funciones de trigger
-- (clients_guard_update, handle_new_user...) seguían abiertas a PUBLIC: no hace falta, un trigger no
-- comprueba EXECUTE al dispararse. service_role conserva sus grants explícitos (las Edge Functions).
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as fn
    from pg_proc p
    where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
      and p.proowner = (select oid from pg_roles where rolname = current_user)
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.fn);
  end loop;
end
$$;

-- Lo que authenticated sí ejecuta (la cocina y la app):
--   current_chef_id, is_chef_of: las políticas de la cocina y la app (rpc current_chef_id)
--   current_client_ids: clients_guard_update (corre con el rol de quien actualiza una ficha)
--   save_recipe, save_session_menu, set_recipe_photo: rpc de la app, validan current_chef_id()
-- current_client_chef_ids y client_can_read_receipt los usaban solo las políticas de la clienta:
-- ya no las ejecuta nadie de la API (las funciones quedan; las saca otro PR si no hacen falta).
grant execute on function public.current_chef_id()                    to authenticated;
grant execute on function public.is_chef_of(uuid)                     to authenticated;
grant execute on function public.current_client_ids()                 to authenticated;
grant execute on function public.save_recipe(jsonb)                   to authenticated;
grant execute on function public.save_session_menu(jsonb)             to authenticated;
grant execute on function public.set_recipe_photo(uuid, uuid)         to authenticated;
