-- =====================================================================
-- Mestolo · M1 · Funciones helper y triggers
--
-- Helpers de RLS: security definer + search_path vacío + nombres calificados.
-- Son security definer para poder leer chefs/clients sin pasar por RLS (si no,
-- la política de clients que llama a current_client_ids() se llamaría a sí
-- misma). Solo devuelven datos del propio auth.uid().
-- =====================================================================

-- ---------------------------------------------------------------------
-- Helpers de identidad para las políticas
-- ---------------------------------------------------------------------

-- id del chef del usuario actual, o null si no es cocinera
create function public.current_chef_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id
  from public.chefs c
  where c.profile_id = auth.uid()
$$;

-- ¿el usuario actual es la cocinera dueña de p_chef_id?
create function public.is_chef_of(p_chef_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.chefs c
    where c.id = p_chef_id
      and c.profile_id = auth.uid()
  )
$$;

-- fichas de cliente vinculadas al usuario actual (puede ser cliente de más de un chef)
create function public.current_client_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select cl.id
  from public.clients cl
  where cl.profile_id = auth.uid()
$$;

-- chefs de los que el usuario actual es cliente (para leer su ficha y su recetario)
create function public.current_client_chef_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct cl.chef_id
  from public.clients cl
  where cl.profile_id = auth.uid()
$$;

-- ¿el usuario actual es el cliente de la sesión a la que pertenece este ticket?
-- (lo usa la política de storage del bucket receipts)
create function public.client_can_read_receipt(p_object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.receipts r
    join public.sessions s on s.id = r.session_id
    join public.clients cl on cl.id = s.client_id
    where r.storage_path = p_object_name
      and cl.profile_id = auth.uid()
  )
$$;

revoke execute on function public.current_chef_id()                from public, anon;
revoke execute on function public.is_chef_of(uuid)                 from public, anon;
revoke execute on function public.current_client_ids()             from public, anon;
revoke execute on function public.current_client_chef_ids()        from public, anon;
revoke execute on function public.client_can_read_receipt(text)    from public, anon;
grant  execute on function public.current_chef_id()                to authenticated, service_role;
grant  execute on function public.is_chef_of(uuid)                 to authenticated, service_role;
grant  execute on function public.current_client_ids()             to authenticated, service_role;
grant  execute on function public.current_client_chef_ids()        to authenticated, service_role;
grant  execute on function public.client_can_read_receipt(text)    to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Alta de perfil al crear un usuario de auth
-- El rol siempre es 'client': nunca se toma de los metadatos (los controla el
-- usuario). La cocinera se promueve con la service role.
-- ---------------------------------------------------------------------
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_locale text := new.raw_user_meta_data ->> 'locale';
begin
  insert into public.profiles (id, role, full_name, locale)
  values (
    new.id,
    'client',
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    case when v_locale in ('it','es','en') then v_locale else 'it' end
  )
  on conflict (id) do nothing;
  return new;
end
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Datos de salud: sin consentimiento health_data vigente no se guardan
-- restricciones (SPEC §6). Aplica a todos los roles, también a la service role.
-- ---------------------------------------------------------------------
create function public.client_restrictions_require_consent()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.consents c
    where c.client_id = new.client_id
      and c.kind = 'health_data'
      and c.revoked_at is null
  ) then
    raise exception 'health_data_consent_required'
      using errcode = 'P0001',
            detail  = 'El cliente no tiene un consentimiento health_data vigente: no se pueden guardar restricciones.',
            hint    = 'Registrar el consentimiento explícito (consents.kind = health_data) antes de guardar alergias o dietas.';
  end if;
  return new;
end
$$;

create trigger client_restrictions_require_consent
  before insert or update on public.client_restrictions
  for each row execute function public.client_restrictions_require_consent();

-- Al revocar (o borrar) el consentimiento de salud vigente se borran las restricciones del cliente.
create function public.consents_purge_health_data()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_client_id uuid := case when tg_op = 'DELETE' then old.client_id else new.client_id end;
begin
  if not exists (
    select 1
    from public.consents c
    where c.client_id = v_client_id
      and c.kind = 'health_data'
      and c.revoked_at is null
  ) then
    delete from public.client_restrictions r where r.client_id = v_client_id;
  end if;
  return null;
end
$$;

create trigger consents_purge_on_revoke
  after update of revoked_at on public.consents
  for each row
  when (new.kind = 'health_data' and old.revoked_at is null and new.revoked_at is not null)
  execute function public.consents_purge_health_data();

create trigger consents_purge_on_delete
  after delete on public.consents
  for each row
  when (old.kind = 'health_data' and old.revoked_at is null)
  execute function public.consents_purge_health_data();

-- Un consentimiento revocado no se "des-revoca": hay que otorgar uno nuevo
-- (queda la traza de versión de texto y fechas).
create function public.consents_guard_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then
    raise exception 'consent_already_revoked'
      using errcode = 'P0001',
            detail  = 'Un consentimiento revocado no se puede reactivar; registrar uno nuevo.';
  end if;
  return new;
end
$$;

create trigger consents_guard_update
  before update on public.consents
  for each row execute function public.consents_guard_update();

-- ---------------------------------------------------------------------
-- Sesiones: si no vienen los minutos de compra y margen, se copian de
-- chef_settings. Quedan guardados en la fila: busy no cambia si después
-- Evelyn modifica sus tiempos. (Las columnas generadas se calculan después
-- de los triggers BEFORE.)
-- ---------------------------------------------------------------------
create function public.sessions_fill_minutes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.shop_minutes is null or new.gap_minutes is null then
    select coalesce(new.shop_minutes, s.shop_minutes),
           coalesce(new.gap_minutes,  s.gap_minutes)
      into new.shop_minutes, new.gap_minutes
    from public.chef_settings s
    where s.chef_id = new.chef_id;
  end if;
  return new;
end
$$;

create trigger sessions_fill_minutes
  before insert on public.sessions
  for each row execute function public.sessions_fill_minutes();

-- ---------------------------------------------------------------------
-- clients: reglas por rol que los privilegios por columna no pueden expresar
-- (cocinera y cliente usan el mismo rol de Postgres, authenticated).
--   * status: solo la cocinera.
--   * share_pantry: solo el propio cliente (compartir la despensa es decisión suya).
-- La service role y las migraciones no pasan por esta guarda.
-- ---------------------------------------------------------------------
create function public.clients_guard_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user <> 'authenticated' then
    return new;
  end if;

  if new.status is distinct from old.status and not public.is_chef_of(old.chef_id) then
    raise exception 'only_chef_can_change_client_status'
      using errcode = '42501';
  end if;

  if new.share_pantry is distinct from old.share_pantry
     and old.id not in (select public.current_client_ids()) then
    raise exception 'only_client_can_change_share_pantry'
      using errcode = '42501';
  end if;

  return new;
end
$$;

create trigger clients_guard_update
  before update on public.clients
  for each row execute function public.clients_guard_update();
