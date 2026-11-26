-- Lista de contactos para ofertas y novedades de Radici (pedido de Nicolas del 26/11/2026).
--
-- Quien pide un presupuesto puede marcar, aparte y sin que venga marcada, «quiero recibir ofertas
-- y novedades». Eso no la suma todavía: le llega un link para confirmarlo (doble opt-in: prueba que
-- aceptó y que el email es suyo). La lista vive aparte de las fichas de clientes:
--   - no depende del prospecto, que se borra a los 90 días (§ retención de public-request);
--   - el formulario sigue sin modificar a ninguna persona que ya existe (CLAUDE.md): esto es otra
--     cosa, que confirma la dueña del email.
-- Nunca guarda datos de salud: solo el email, el nombre de pila (para el saludo), el idioma, de dónde
-- vino y el texto que aceptó.
--
-- Estados:
--   pending   → marcó la casilla, falta confirmar (se borra a los 7 días si no confirma).
--   confirmed → confirmó: se le pueden mandar ofertas (se borra a los 24 meses sin novedades).
--   withdrawn → se dio de baja (o dijo «no, grazie» al confirmar): queda el email, las fechas y la
--               versión del texto como prueba y para no volver a escribirle; se borra a los 24 meses.
--
-- El token (32 bytes al azar, base64url) lo arma la Edge Function y viaja en el link del email; acá
-- se guarda solo su sha-256 en hexadecimal, como los links de las clientas (client_links). Sirve para
-- ver el estado, confirmar y darse de baja; nada más.
--
-- Acceso: solo la service role, por las funciones de abajo (security definer). La tabla no tiene
-- políticas: anon y authenticated no la ven. La lista para Evelyn llega en un PR posterior.

create table public.marketing_contacts (
  id                 uuid primary key default gen_random_uuid(),
  chef_id            uuid not null references public.chefs (id) on delete cascade,
  email              text not null,
  first_name         text,
  locale             text not null,
  source             text not null,
  text_version       text not null,
  status             text not null default 'pending',
  requested_at       timestamptz not null default now(),
  confirmed_at       timestamptz,
  withdrawn_at       timestamptz,
  last_activity_at   timestamptz not null default now(),
  token_hash         text not null,
  request_id         uuid references public.requests (id) on delete set null,
  constraint marketing_contacts_email_valido check (email = lower(btrim(email)) and length(email) between 3 and 254 and position('@' in email) > 1),
  constraint marketing_contacts_nombre check (first_name is null or length(first_name) between 1 and 60),
  constraint marketing_contacts_idioma check (locale in ('it', 'es', 'en')),
  constraint marketing_contacts_origen check (source in ('web', 'app')),
  constraint marketing_contacts_version check (length(text_version) between 1 and 40),
  constraint marketing_contacts_hash_valido check (token_hash ~ '^[0-9a-f]{64}$'),
  constraint marketing_contacts_estado check (
    (status = 'pending' and confirmed_at is null and withdrawn_at is null)
    or (status = 'confirmed' and confirmed_at is not null and withdrawn_at is null)
    or (status = 'withdrawn' and withdrawn_at is not null and first_name is null)
  ),
  constraint marketing_contacts_un_email unique (chef_id, email),
  constraint marketing_contacts_un_token unique (token_hash)
);

comment on table public.marketing_contacts is
  'Contactos que aceptaron ofertas y novedades (doble opt-in). Sin datos de salud. Retención: pendientes 7 días, confirmados 24 meses sin novedades, bajas 24 meses. Contrato: docs/contracts/public-request.md §13.';

alter table public.marketing_contacts enable row level security;
revoke all on public.marketing_contacts from public, anon, authenticated, service_role;
-- La service role la lee (el runbook de derechos, y la lista de Evelyn más adelante); escribe solo
-- por las funciones.
grant select on public.marketing_contacts to service_role;

-- ---------------------------------------------------------------------
-- public.marketing_subscribe(p jsonb): la casilla marcada en un pedido.
--   p = { chef_id, email, first_name?, locale, source, text_version, request_id?, token_hash }
-- Devuelve { status, send }: send = true si hay que mandar el link de confirmación con el token de
-- este pedido (nuevo, pendiente o dado de baja que vuelve a aceptar). Con uno ya confirmado no manda
-- nada ni cambia el token: solo anota la actividad (el plazo de 24 meses vuelve a empezar) y el
-- texto aceptado esta vez.
-- ---------------------------------------------------------------------
create function public.marketing_subscribe(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_chef uuid := (p ->> 'chef_id')::uuid;
  v_email text := lower(btrim(coalesce(p ->> 'email', '')));
  v_name text := nullif(btrim(coalesce(p ->> 'first_name', '')), '');
  v_locale text := p ->> 'locale';
  v_source text := p ->> 'source';
  v_version text := p ->> 'text_version';
  v_request uuid := (p ->> 'request_id')::uuid;
  v_hash text := p ->> 'token_hash';
  v_row public.marketing_contacts;
begin
  if v_chef is null or v_hash is null or v_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'marketing_subscribe: datos inválidos' using errcode = '22023';
  end if;
  if v_name is not null and length(v_name) > 60 then
    v_name := null;
  end if;

  select * into v_row from public.marketing_contacts
  where chef_id = v_chef and email = v_email
  for update;

  if not found then
    insert into public.marketing_contacts (chef_id, email, first_name, locale, source, text_version, token_hash, request_id)
    values (v_chef, v_email, v_name, v_locale, v_source, v_version, v_hash, v_request);
    return jsonb_build_object('status', 'pending', 'send', true);
  end if;

  if v_row.status = 'confirmed' then
    update public.marketing_contacts
    set last_activity_at = now(), text_version = v_version, request_id = coalesce(v_request, request_id),
        locale = v_locale, first_name = coalesce(v_name, first_name)
    where id = v_row.id;
    return jsonb_build_object('status', 'confirmed', 'send', false);
  end if;

  -- Pendiente (otro pedido antes de confirmar) o dado de baja que vuelve a aceptar: pendiente otra
  -- vez, con el token nuevo (el link viejo deja de servir) y el plazo de 7 días desde ahora.
  update public.marketing_contacts
  set status = 'pending', confirmed_at = null, withdrawn_at = null, requested_at = now(),
      last_activity_at = now(), token_hash = v_hash, first_name = v_name, locale = v_locale,
      source = v_source, text_version = v_version, request_id = coalesce(v_request, request_id)
  where id = v_row.id;
  return jsonb_build_object('status', 'pending', 'send', true);
end;
$$;

-- ---------------------------------------------------------------------
-- public.marketing_status(p_token_hash): el estado del contacto de un link, o null si el token no
-- es de nadie (o el pendiente ya venció). Devuelve el email para que la función lo muestre
-- enmascarado; nunca el nombre.
-- ---------------------------------------------------------------------
create function public.marketing_status(p_token_hash text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('status', m.status, 'locale', m.locale, 'email', m.email)
  from public.marketing_contacts m
  where m.token_hash = p_token_hash
    and (m.status <> 'pending' or m.requested_at > now() - interval '7 days');
$$;

-- ---------------------------------------------------------------------
-- public.marketing_set(p_token_hash, p_action): «confirm» (pendiente → confirmado; si ya lo estaba,
-- no cambia) o «withdraw» (pendiente o confirmado → baja; si ya lo estaba, no cambia). La baja borra
-- el nombre. Devuelve el estado nuevo, o null si el token no es de nadie (o el pendiente venció).
-- Confirmar una baja no la revive: hace falta volver a marcar la casilla (un consentimiento nuevo).
-- ---------------------------------------------------------------------
create function public.marketing_set(p_token_hash text, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.marketing_contacts;
begin
  if p_action not in ('confirm', 'withdraw') then
    raise exception 'marketing_set: acción inválida' using errcode = '22023';
  end if;
  select * into v_row from public.marketing_contacts
  where token_hash = p_token_hash
    and (status <> 'pending' or requested_at > now() - interval '7 days')
  for update;
  if not found then
    return null;
  end if;

  if p_action = 'confirm' and v_row.status = 'pending' then
    update public.marketing_contacts
    set status = 'confirmed', confirmed_at = now(), last_activity_at = now()
    where id = v_row.id;
    return jsonb_build_object('status', 'confirmed', 'locale', v_row.locale);
  end if;

  if p_action = 'withdraw' and v_row.status <> 'withdrawn' then
    update public.marketing_contacts
    set status = 'withdrawn', withdrawn_at = now(), first_name = null
    where id = v_row.id;
    return jsonb_build_object('status', 'withdrawn', 'locale', v_row.locale);
  end if;

  return jsonb_build_object('status', v_row.status, 'locale', v_row.locale);
end;
$$;

revoke all on function public.marketing_subscribe(jsonb) from public, anon, authenticated, service_role;
revoke all on function public.marketing_status(text) from public, anon, authenticated, service_role;
revoke all on function public.marketing_set(text, text) from public, anon, authenticated, service_role;
grant execute on function public.marketing_subscribe(jsonb) to service_role;
grant execute on function public.marketing_status(text) to service_role;
grant execute on function public.marketing_set(text, text) to service_role;

-- ---------------------------------------------------------------------
-- Retención (todos los días): pendientes sin confirmar a los 7 días; confirmados sin novedades
-- (otro pedido con la casilla, o la confirmación) a los 24 meses; bajas a los 24 meses.
-- ---------------------------------------------------------------------
create function private.purge_marketing_contacts()
returns integer
language sql
security definer
set search_path = ''
as $$
  with gone as (
    delete from public.marketing_contacts
    where (status = 'pending' and requested_at < now() - interval '7 days')
       or (status = 'confirmed' and last_activity_at < now() - interval '24 months')
       or (status = 'withdrawn' and withdrawn_at < now() - interval '24 months')
    returning 1
  )
  select count(*)::integer from gone;
$$;

revoke all on function private.purge_marketing_contacts() from public, anon, authenticated, service_role;

-- 03:45 UTC, después de la de los prospectos (03:30).
select cron.schedule(
  'radici-purge-marketing-contacts',
  '45 3 * * *',
  'select private.purge_marketing_contacts()'
);
