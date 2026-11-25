-- =====================================================================
-- Radici · Una cuenta con ficha de cliente no puede ser colaboradora (PR06 del área de clientas)
-- Tests: supabase/tests/database/15_chef_members.test.sql (7).
--
-- Hasta acá cualquier cuenta de Auth confirmada podía entrar a la lista CHEF_MEMBER_EMAILS. Con
-- las cuentas de clientas (el área de clientas) una persona que se registró sola y tiene ficha en
-- public.clients (clients.profile_id) pasaría a ver las alergias y direcciones de toda la cocina
-- si su email llegara a la lista. private.sync_chef_members ahora corta con member_has_client_record
-- (P0001) en la validación, antes de cambiar nada.
--
-- Reescribe private.sync_chef_members desde su cuerpo más nuevo (20261116190000_chef_members.sql, la
-- única migración que la define); solo agrega esa guarda. Mismos privilegios (solo el dueño): create or
-- replace los conserva, y se repite el revoke por claridad.
-- Un test estructural (pg_proc.prosrc) comprueba la guarda en el código de la función.
-- =====================================================================

create or replace function private.sync_chef_members(p_emails text[], p_chef_id uuid default null)
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
    -- Una cuenta con ficha de cliente nunca es de colaborador: ve las alergias y direcciones de toda la
    -- cocina. Se mira acá, antes de cambiar nada, para que un error corte la sincronización entera.
    if exists (select 1 from public.clients cl where cl.profile_id = v_user_id) then
      raise exception 'member_has_client_record' using errcode = 'P0001';
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
  'Colaboradores de una cocina (la única, si p_chef_id es null) según la lista p_emails, que manda: agrega a los que faltan (rol chef, contraseña al azar y sesiones cerradas), a los que siguen no les cambia la contraseña ni la sesión (solo les devuelve el rol chef) y saca a los que no están (su cuenta se borra; si es la de una ficha de cliente o no se puede borrar, queda como client y sin sesiones). Valida todo antes de cambiar nada; una cuenta con ficha de cliente no puede ser colaboradora (member_has_client_record). Devuelve {members, added, kept, removed, accounts_deleted}. Solo el dueño (deploy-supabase.yml, SQL editor).';

revoke all on function private.sync_chef_members(text[], uuid) from public, anon, authenticated, service_role;
