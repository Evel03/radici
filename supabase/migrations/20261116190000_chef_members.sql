-- =====================================================================
-- Radici · Colaboradores de la cocinera
-- Tests: supabase/tests/database/15_chef_members.test.sql.
--
-- Pedido del dueño del 16/11/2026: entrar a /gestione/ con su propio email y código, con el mismo
-- acceso que Evelyn. Hasta acá el sistema reconocía a una sola persona por cocina: la dueña, por
-- chefs.profile_id. Un colaborador es una cuenta que trabaja en la cocina de una cocinera: ve y hace
-- lo mismo que ella desde la app y la Edge Function chef. No hay segunda cocinera: la ficha de chefs
-- sigue siendo una sola.
--
--   1. public.chef_members (chef_id, profile_id, created_at): una fila por colaborador. profile_id es
--      la clave (una cuenta es colaboradora de una sola cocina). La app no la lee ni la escribe: RLS
--      sin políticas y sin privilegios para anon ni authenticated. La escribe el despliegue
--      (private.sync_chef_members, punto 5).
--   2. Dueña o colaboradora, nunca las dos: dos guardas (triggers) para todos los roles, también la
--      service role y postgres. Así un colaborador nunca se vuelve la cocinera dueña (tampoco con
--      promote_to_chef) y la cuenta de una cocinera nunca es colaboradora.
--   3. Quién es la cocina del usuario, en un solo lugar: public.chef_id_for_user(p_user_id) da la
--      cocina de la que es dueño (chefs.profile_id) o colaborador (chef_members); null si no es
--      ninguna. current_chef_id() e is_chef_of() (las que usan las políticas, 20261019100100) pasan
--      a llamarla con auth.uid(): todas las políticas del lado de la cocinera que pasan por ellas
--      dejan pasar a sus colaboradores sin cambiar una por una. chef_id_for_user solo la ejecuta
--      service_role (la Edge Function chef): con otro usuario diría de qué cocina es cualquier cuenta.
--   4. Las políticas que identificaban a la cocinera con profile_id = auth.uid() directo, una por una:
--      * "chefs: la cocinera lee la suya; el cliente, la de sus cocineras": pasa a current_chef_id().
--        El colaborador lee la ficha de su cocina (la app muestra su nombre).
--      * "chefs: la cocinera edita la suya": no cambia. La ficha pública (nombre, zona y WhatsApp que
--        ven los clientes) es de la dueña; un colaborador la lee y no la edita.
--      Las demás con auth.uid() directo son de identidad propia y no cambian: profiles ("el usuario
--      lee el suyo" y "edita el suyo"), push_tokens y notifications (cada aviso es de una persona; el
--      del pedido nuevo, de la cocinera). Todas las otras del lado de la cocinera ya usaban
--      current_chef_id() (chef_settings, availability_*, clients, client_restrictions, consents,
--      recurring_plans, recipes, recipe_allergens, requests, quotes, sessions, session_menu,
--      receipts, payments, prepared_portions, pantry_items, "profiles: la cocinera lee los de sus
--      clientes" y las cuatro de storage.objects del bucket receipts); clients_guard_update usa
--      is_chef_of(). 15_chef_members falla si una política usa auth.uid() directo fuera de esa lista.
--   5. private.sync_chef_members(p_emails, p_chef_id): deploy-supabase.yml la corre en cada despliegue
--      con la lista del secreto CHEF_MEMBER_EMAILS, después de crear las cuentas que falten. La lista
--      manda: agrega a los que faltan y saca a los que ya no están.
--   6. receipts.uploaded_by: con varias cuentas del lado de la cocina, el autor de un ticket es quien
--      lo sube desde la app, y no cambia después.
--
-- El rol de profiles: un colaborador queda con rol chef, como la dueña, para que la app lo lleve al
-- área de la cocinera. El rol no abre nada en la base: ninguna política ni función lo mira (quién es
-- de una cocina lo dicen chefs y chef_members). Una cuenta con rol chef sin cocina ni colaboración no
-- ve nada, y un colaborador no ve nada del lado de los clientes que no vea la cocinera.
--
-- Lo que no cambia: public-request (los avisos del pedido nuevo siguen yendo a la cocinera), las
-- funciones chef_* (reciben el chef_id que les pasa la Edge Function) y promote_to_chef.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. chef_members
-- ---------------------------------------------------------------------
create table public.chef_members (
  -- Una cuenta es colaboradora de una sola cocina: current_chef_id() da una sola.
  profile_id  uuid primary key references public.profiles (id) on delete cascade,
  chef_id     uuid not null references public.chefs (id) on delete cascade,
  created_at  timestamptz not null default now()
);
create index chef_members_chef_idx on public.chef_members (chef_id);

comment on table public.chef_members is
  'Colaboradores de una cocinera: cuentas que entran a su área (/gestione/, la app y la Edge Function chef) con el mismo acceso que ella, salvo su ficha pública. Una cuenta es colaboradora de una sola cocina y nunca es una cocinera dueña (guardas chef_members_guard y chefs_guard_member). La escribe solo private.sync_chef_members (deploy-supabase.yml, secreto CHEF_MEMBER_EMAILS); la app no la lee ni la escribe.';

alter table public.chef_members enable row level security;

-- Sin políticas: authenticated no ve ninguna fila. Tampoco privilegios para la app (20261019130000
-- da los de cada tabla de public en su migración): nadie agrega, saca ni lista colaboradores desde ahí.
revoke all on public.chef_members from public, anon, authenticated;
grant select, insert, update, delete on public.chef_members to service_role;

-- ---------------------------------------------------------------------
-- 2. Dueña o colaboradora, nunca las dos
-- Corren para todos los roles. El lock por cuenta serializa un alta de colaborador y un alta de
-- cocina simultáneas de la misma cuenta (las dos guardas lo toman).
-- ---------------------------------------------------------------------
create function public.chef_members_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('chef_profile:' || new.profile_id::text, 0));
  if exists (select 1 from public.chefs c where c.profile_id = new.profile_id) then
    raise exception 'member_is_chef'
      using errcode = '23514',
            detail  = 'La cuenta de una cocinera no es colaboradora de ninguna cocina.';
  end if;
  return new;
end
$$;

create trigger chef_members_guard
  before insert or update on public.chef_members
  for each row execute function public.chef_members_guard();

create function public.chefs_guard_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('chef_profile:' || new.profile_id::text, 0));
  if exists (select 1 from public.chef_members m where m.profile_id = new.profile_id) then
    raise exception 'chef_is_member'
      using errcode = '23514',
            detail  = 'Un colaborador no pasa a ser la cocinera dueña de ninguna cocina.';
  end if;
  return new;
end
$$;

create trigger chefs_guard_member
  before insert or update of profile_id on public.chefs
  for each row execute function public.chefs_guard_member();

revoke all on function public.chef_members_guard() from public, anon, authenticated;
revoke all on function public.chefs_guard_member() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. La cocina del usuario, en un solo lugar
-- ---------------------------------------------------------------------
create function public.chef_id_for_user(p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  -- Las guardas impiden que una cuenta esté en las dos; el limit es por las dudas.
  select c.id from public.chefs c where c.profile_id = p_user_id
  union all
  select m.chef_id from public.chef_members m where m.profile_id = p_user_id
  limit 1
$$;

comment on function public.chef_id_for_user(uuid) is
  'Cocina del usuario: la de la que es dueño (chefs.profile_id) o colaborador (chef_members); null si no es ninguna. La usan current_chef_id() e is_chef_of() (con auth.uid()) y la Edge Function chef (service_role). Solo service_role la ejecuta directo.';

revoke all on function public.chef_id_for_user(uuid) from public, anon, authenticated;
grant execute on function public.chef_id_for_user(uuid) to service_role;

-- Dentro de una función security definer las llamadas se chequean con su dueño: authenticated
-- ejecuta current_chef_id() e is_chef_of() sin poder llamar a chef_id_for_user directo.
create or replace function public.current_chef_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select public.chef_id_for_user(auth.uid())
$$;

comment on function public.current_chef_id() is
  'Cocina del usuario de la sesión (dueña o colaborador), o null. Las políticas del lado de la cocinera la usan con (select public.current_chef_id()).';

-- Nunca null: clients_guard_update hace "not is_chef_of(...)", y un null ahí dejaría pasar.
create or replace function public.is_chef_of(p_chef_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(p_chef_id = public.chef_id_for_user(auth.uid()), false)
$$;

comment on function public.is_chef_of(uuid) is
  '¿El usuario de la sesión es de la cocina p_chef_id (dueña o colaborador)? true o false, nunca null.';

-- create or replace conserva los privilegios; se repiten para que queden a la vista.
revoke execute on function public.current_chef_id()  from public, anon;
revoke execute on function public.is_chef_of(uuid)   from public, anon;
grant  execute on function public.current_chef_id()  to authenticated, service_role;
grant  execute on function public.is_chef_of(uuid)   to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. chefs: el colaborador lee la ficha de su cocina; editarla sigue siendo de la dueña
-- (alter policy conserva el nombre: "la cocinera" es la cocina, como en las demás políticas)
-- ---------------------------------------------------------------------
alter policy "chefs: la cocinera lee la suya; el cliente, la de sus cocineras"
  on public.chefs
  using (
    id = (select public.current_chef_id())
    or id in (select public.current_client_chef_ids())
  );

comment on policy "chefs: la cocinera lee la suya; el cliente, la de sus cocineras" on public.chefs is
  'La dueña y sus colaboradores leen la ficha de su cocina (current_chef_id); el cliente, la de sus cocineras.';
comment on policy "chefs: la cocinera edita la suya" on public.chefs is
  'Solo la dueña (chefs.profile_id = auth.uid()): la ficha pública (nombre, zona y WhatsApp que ven los clientes) no la edita un colaborador. Excepción a la regla de 15_chef_members.';

comment on table public.profiles is
  'Un perfil por usuario de auth. El rol nunca lo elige el usuario: se crea como client; la cocinera (promote_to_chef) y sus colaboradores (private.sync_chef_members) pasan a chef con la service role o el despliegue. El rol no abre nada en la base: la app lo usa para elegir el área.';

-- ---------------------------------------------------------------------
-- 5. private.sync_chef_members: la lista del despliegue manda
--
-- p_emails: los emails de los colaboradores (se ignoran mayúsculas, espacios y repetidos). La lista
-- vacía (array[]::text[]) deja la cocina sin colaboradores; null es un error.
-- p_chef_id: la cocina; null = la única que hay (producción tiene una sola cocinera).
--
-- Antes de cambiar nada valida todo (un error corta la sincronización entera):
--   22023 invalid_member_email (formato, o null), too_many_members (más de 10),
--         chef_email_not_member (el email de una cocinera: su cuenta nunca se toca);
--   P0002 chef_not_found, member_user_not_found (la cuenta la crea antes el despliegue);
--   P0001 single_chef_required, member_user_not_confirmed (la registró otro, como en
--         promote_to_chef), member_of_other_chef.
-- Después:
--   * Sale quien ya no está en la lista: pierde la colaboración en el acto (las políticas y la
--     función chef la miran en cada pedido). Su cuenta de Auth se borra, con su perfil: la creó el
--     despliegue para entrar al área. Si es la cuenta de una ficha de cliente, o algo impide borrarla,
--     queda como cuenta de cliente (rol client) y se le cierran las sesiones.
--   * Entra quien falta: rol chef y su fila; como en promote_to_chef, una contraseña al azar que nadie
--     conoce y sus sesiones, refresh tokens y factores MFA cerrados, para que solo entre quien recibe
--     el código. A quien ya era colaborador no se le cambia la contraseña ni se le cierra la sesión;
--     solo vuelve a rol chef si alguien se lo cambió a mano.
-- Devuelve {members, added, kept, removed, accounts_deleted} y deja en el log solo esos contadores.
-- Pero si la sincronización falla (cualquiera de los errores de arriba), Postgres registra la sentencia
-- entera, con los emails, en el log de la base del proyecto (log_min_error_statement = error), que ven
-- solo los administradores del proyecto en el panel de Supabase; el log de GitHub no los muestra.
-- Nadie más que el dueño (postgres): deploy-supabase.yml por la Management API, o el SQL editor.
-- ---------------------------------------------------------------------
create function private.sync_chef_members(p_emails text[], p_chef_id uuid default null)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  -- La misma regla que MEMBER_EMAIL_PATTERN en supabase/scripts/chef-members.ts (un test lo compara):
  -- sin comillas, barras, espacios ni %.
  v_pattern   constant text := '^[a-z0-9._+-]+@[a-z0-9.-]+\.[a-z]{2,}$';
  v_emails    text[];
  v_email     text;
  v_chefs     int;
  v_chef_id   uuid;
  v_user_id   uuid;
  v_confirmed timestamptz;
  v_other     uuid;
  v_member    record;
  v_added     int := 0;
  v_kept      int := 0;
  v_removed   int := 0;
  v_deleted   int := 0;
begin
  if p_emails is null then
    raise exception 'invalid_member_email' using errcode = '22023';
  end if;

  v_emails := array(
    select distinct lower(btrim(e))
    from unnest(p_emails) as e
    where e is not null and btrim(e) <> ''
    order by 1
  );
  if exists (select 1 from unnest(v_emails) as e where length(e) > 254 or e !~ v_pattern) then
    raise exception 'invalid_member_email' using errcode = '22023';
  end if;
  if cardinality(v_emails) > 10 then
    raise exception 'too_many_members' using errcode = '22023';
  end if;

  if p_chef_id is null then
    select count(*)::int into v_chefs from public.chefs;
    if v_chefs = 0 then
      raise exception 'chef_not_found' using errcode = 'P0002';
    elsif v_chefs > 1 then
      raise exception 'single_chef_required' using errcode = 'P0001';
    end if;
    select c.id into v_chef_id from public.chefs c;
  else
    select c.id into v_chef_id from public.chefs c where c.id = p_chef_id;
    if v_chef_id is null then
      raise exception 'chef_not_found' using errcode = 'P0002';
    end if;
  end if;

  -- Dos sincronizaciones de la misma cocina, de a una.
  perform pg_advisory_xact_lock(hashtextextended('chef_members:' || v_chef_id::text, 0));

  -- La cuenta de una cocinera (de esta cocina o de otra) nunca es de colaborador.
  if exists (
    select 1 from public.chefs c join auth.users u on u.id = c.profile_id
    where lower(u.email) = any (v_emails)
  ) then
    raise exception 'chef_email_not_member' using errcode = '22023';
  end if;

  foreach v_email in array v_emails loop
    v_user_id := null;
    select u.id, u.email_confirmed_at into v_user_id, v_confirmed
    from auth.users u where lower(u.email) = v_email;
    if v_user_id is null then
      raise exception 'member_user_not_found' using errcode = 'P0002';
    end if;
    if v_confirmed is null then
      raise exception 'member_user_not_confirmed' using errcode = 'P0001';
    end if;
    select m.chef_id into v_other from public.chef_members m where m.profile_id = v_user_id;
    if found and v_other <> v_chef_id then
      raise exception 'member_of_other_chef' using errcode = 'P0001';
    end if;
  end loop;

  -- Salen los que ya no están en la lista.
  for v_member in
    select m.profile_id, lower(u.email) as email
    from public.chef_members m
    left join auth.users u on u.id = m.profile_id
    where m.chef_id = v_chef_id
    order by m.profile_id
  loop
    continue when v_member.email = any (v_emails);

    delete from public.chef_members m where m.profile_id = v_member.profile_id;
    v_removed := v_removed + 1;

    if not exists (select 1 from public.clients cl where cl.profile_id = v_member.profile_id) then
      begin
        -- En cascada: el perfil (y con él sus tokens push y avisos), las identidades y las sesiones.
        -- Lo que subió (tickets, despensa) queda, sin autor (on delete set null).
        delete from auth.users u where u.id = v_member.profile_id;
        v_deleted := v_deleted + 1;
        continue;
      exception
        -- Algo la referencia sin cascada, o el rol no puede borrar en auth: queda como cuenta de
        -- cliente (abajo), igual sin acceso. El aviso de usuarios del despliegue la cuenta de más.
        when foreign_key_violation or insufficient_privilege then
          null;
      end;
    end if;

    update public.profiles p set role = 'client' where p.id = v_member.profile_id;
    delete from auth.sessions s where s.user_id = v_member.profile_id;            -- en cascada: refresh_tokens, mfa_amr_claims
    delete from auth.refresh_tokens t where t.user_id = v_member.profile_id::text; -- por si queda alguno sin sesión
  end loop;

  -- Entran los que faltan; a los que ya estaban no se les cambia la contraseña ni la sesión.
  foreach v_email in array v_emails loop
    select u.id into v_user_id from auth.users u where lower(u.email) = v_email;

    if exists (select 1 from public.chef_members m where m.profile_id = v_user_id) then
      -- Si alguien le cambió el rol a mano, vuelve a chef (la app lo lleva al área por el rol).
      update public.profiles p set role = 'chef' where p.id = v_user_id and p.role <> 'chef';
      v_kept := v_kept + 1;
      continue;
    end if;

    -- El perfil lo crea el trigger de auth.users; si faltara, se crea acá.
    insert into public.profiles (id, role) values (v_user_id, 'chef')
    on conflict (id) do update set role = 'chef';
    insert into public.chef_members (chef_id, profile_id) values (v_chef_id, v_user_id);

    -- Solo entra quien recibe el código (como promote_to_chef).
    update auth.users u
       set encrypted_password = extensions.crypt(encode(extensions.gen_random_bytes(32), 'hex'), extensions.gen_salt('bf'))
     where u.id = v_user_id;
    delete from auth.sessions s where s.user_id = v_user_id;
    delete from auth.refresh_tokens t where t.user_id = v_user_id::text;
    delete from auth.mfa_factors f where f.user_id = v_user_id;
    v_added := v_added + 1;
  end loop;

  -- Solo contadores, nunca emails (si algo falla antes, Postgres registra la sentencia: ver arriba).
  raise log 'sync_chef_members: members=% added=% kept=% removed=% accounts_deleted=%',
    cardinality(v_emails), v_added, v_kept, v_removed, v_deleted;

  return jsonb_build_object(
    'members',          cardinality(v_emails),
    'added',            v_added,
    'kept',             v_kept,
    'removed',          v_removed,
    'accounts_deleted', v_deleted
  );
end
$$;

comment on function private.sync_chef_members(text[], uuid) is
  'Colaboradores de una cocina (la única, si p_chef_id es null) según la lista p_emails, que manda: agrega a los que faltan (rol chef, contraseña al azar y sesiones cerradas), a los que siguen no les cambia la contraseña ni la sesión (solo les devuelve el rol chef) y saca a los que no están (su cuenta se borra; si es la de una ficha de cliente o no se puede borrar, queda como client y sin sesiones). Valida todo antes de cambiar nada. Devuelve {members, added, kept, removed, accounts_deleted}. Solo el dueño (deploy-supabase.yml, SQL editor).';

revoke all on function private.sync_chef_members(text[], uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6. receipts.uploaded_by: quién subió cada ticket
-- La columna la puede escribir authenticated (los privilegios de receipts son de toda la tabla,
-- 20261019130000) y no tiene valor por defecto. Con la dueña y sus colaboradores en la misma cocina,
-- desde la app el autor de un ticket es siempre quien tiene la sesión, y un cambio posterior (de
-- cualquiera de la cocina) no se lo cambia. La service role y postgres (Edge Functions, SQL editor)
-- escriben lo que les pasan. Si la cuenta de quien lo subió se borra, queda sin autor (set null).
-- ---------------------------------------------------------------------
create function public.receipts_set_uploaded_by()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if current_user = 'authenticated' then
    if tg_op = 'INSERT' then
      new.uploaded_by := auth.uid();
    else
      new.uploaded_by := old.uploaded_by;
    end if;
  end if;
  return new;
end
$$;

create trigger receipts_set_uploaded_by
  before insert or update on public.receipts
  for each row execute function public.receipts_set_uploaded_by();

revoke all on function public.receipts_set_uploaded_by() from public, anon, authenticated;
