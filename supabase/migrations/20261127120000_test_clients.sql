-- =====================================================================
-- PR18 (docs/contracts/auth.md §15): cuentas de prueba de clienta en producción.
--
-- Por qué. Las altas siguen cerradas hasta PR20 (después del hook que bloquea el cambio de email), pero
-- el área de clientas (/app/ y la app nativa) ya tiene login con contraseña. Para probarla en producción
-- hacen falta cuentas de clienta que no salgan de un alta: las de la lista del secreto
-- TEST_CLIENT_EMAILS, que el despliegue aplica en cada corrida (deploy-accounts.sh testers, con
-- supabase/scripts/test-clients.ts). El despliegue crea las que faltan por la API de administración de
-- Auth, confirmadas y sin contraseña (cada persona elige la suya con «Password dimenticata?»), y después
-- llama a esta función.
--
-- Qué hace private.sync_test_clients(p_emails). La lista manda:
--   * Cada email de la lista tiene que ser una cuenta confirmada que no sea de la cocina (ni la cocinera
--     ni un colaborador, ni un perfil con otro rol que client): si no, corta antes de cambiar nada.
--   * Marca esas cuentas con app_metadata.radici_test = true (raw_app_meta_data, que solo escribe el
--     servidor: la persona no se la puede poner ni sacar). Llega en el JWT, así la app y la web pueden
--     reconocer una cuenta de prueba (antes de abrir las altas, el botón hacia /app/ solo para ellas).
--     No toca la contraseña, las sesiones ni user_metadata.
--   * Una cuenta marcada que ya no está en la lista sale: sin ficha de cliente, se borra (en cascada el
--     perfil, las identidades y las sesiones); con ficha, o si no se puede borrar, se le saca la marca y
--     queda como cuenta de clienta (la segunda, además, sin sesiones abiertas).
-- Devuelve {testers, added, kept, removed, accounts_deleted}: solo números.
--
-- La corre deploy-supabase.yml como postgres por la Management API; nadie más la ejecuta. Mismo
-- formato de email que private.sync_chef_members (y que TEST_EMAIL_PATTERN de test-clients.ts: un test
-- lo compara), con un tope de 10 cuentas. Tests: pgTAP 29_test_clients.
-- =====================================================================
create or replace function private.sync_test_clients(p_emails text[])
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  -- La misma regla que MEMBER_EMAIL_PATTERN de supabase/scripts/chef-members.ts: sin comillas, barras,
  -- espacios ni %.
  v_pattern   constant text := '^[a-z0-9._+-]+@[a-z0-9.-]+\.[a-z]{2,}$';
  v_flag      constant jsonb := '{"radici_test": true}'::jsonb;
  v_emails    text[];
  v_email     text;
  v_user_id   uuid;
  v_confirmed timestamptz;
  v_old       record;
  v_added     int := 0;
  v_kept      int := 0;
  v_removed   int := 0;
  v_deleted   int := 0;
begin
  if p_emails is null then
    raise exception 'invalid_test_client_email' using errcode = '22023';
  end if;

  v_emails := array(
    select distinct lower(btrim(e))
    from unnest(p_emails) as e
    where e is not null and btrim(e) <> ''
    order by 1
  );
  if exists (select 1 from unnest(v_emails) as e where length(e) > 254 or e !~ v_pattern) then
    raise exception 'invalid_test_client_email' using errcode = '22023';
  end if;
  if cardinality(v_emails) > 10 then
    raise exception 'too_many_test_clients' using errcode = '22023';
  end if;

  -- Dos sincronizaciones, de a una.
  perform pg_advisory_xact_lock(hashtextextended('test_clients', 0));

  -- Todo lo que corta, antes de cambiar nada.
  foreach v_email in array v_emails loop
    v_user_id := null;
    select u.id, u.email_confirmed_at into v_user_id, v_confirmed
    from auth.users u where lower(u.email) = v_email;
    if v_user_id is null then
      raise exception 'test_client_user_not_found' using errcode = 'P0002';
    end if;
    if v_confirmed is null then
      raise exception 'test_client_not_confirmed' using errcode = 'P0001';
    end if;
    -- Una cuenta de la cocina ve las alergias y direcciones de todas las clientas: nunca es de prueba.
    if exists (select 1 from public.chefs c where c.profile_id = v_user_id)
       or exists (select 1 from public.chef_members m where m.profile_id = v_user_id)
       or exists (select 1 from public.profiles p where p.id = v_user_id and p.role <> 'client') then
      raise exception 'test_client_is_kitchen' using errcode = '22023';
    end if;
  end loop;

  -- Salen las cuentas marcadas que ya no están en la lista.
  for v_old in
    select u.id, lower(u.email) as email
    from auth.users u
    where u.raw_app_meta_data -> 'radici_test' = 'true'::jsonb
    order by u.id
  loop
    continue when v_old.email = any (v_emails);
    v_removed := v_removed + 1;

    if not exists (select 1 from public.clients cl where cl.profile_id = v_old.id) then
      begin
        -- En cascada: el perfil (y con él sus tokens push y avisos), las identidades y las sesiones.
        delete from auth.users u where u.id = v_old.id;
        v_deleted := v_deleted + 1;
        continue;
      exception
        -- Algo la referencia sin cascada, o el rol no puede borrar en auth: queda sin la marca y sin
        -- sesiones. El aviso de usuarios del despliegue la cuenta de más.
        when foreign_key_violation or insufficient_privilege then
          delete from auth.sessions s where s.user_id = v_old.id;            -- en cascada: refresh_tokens
          delete from auth.refresh_tokens t where t.user_id = v_old.id::text; -- por si queda alguno sin sesión
      end;
    end if;

    update auth.users u
       set raw_app_meta_data = u.raw_app_meta_data - 'radici_test'
     where u.id = v_old.id;
  end loop;

  -- Entran los que faltan; a los que ya estaban no se les toca nada.
  foreach v_email in array v_emails loop
    select u.id into v_user_id from auth.users u where lower(u.email) = v_email;
    if exists (
      select 1 from auth.users u
      where u.id = v_user_id and u.raw_app_meta_data -> 'radici_test' = 'true'::jsonb
    ) then
      v_kept := v_kept + 1;
      continue;
    end if;
    update auth.users u
       set raw_app_meta_data = coalesce(u.raw_app_meta_data, '{}'::jsonb) || v_flag
     where u.id = v_user_id;
    v_added := v_added + 1;
  end loop;

  return jsonb_build_object(
    'testers', cardinality(v_emails),
    'added', v_added,
    'kept', v_kept,
    'removed', v_removed,
    'accounts_deleted', v_deleted
  );
end
$$;
comment on function private.sync_test_clients(text[]) is
  'Cuentas de prueba de clienta (secreto TEST_CLIENT_EMAILS, auth.md §15): marca las de la lista con app_metadata.radici_test y saca a las que ya no están (se borra la cuenta sin ficha). Solo la corre el despliegue, como postgres.';
revoke all on function private.sync_test_clients(text[]) from public, anon, authenticated, service_role;
