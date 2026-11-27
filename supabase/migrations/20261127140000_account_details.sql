-- =====================================================================
-- Los datos de la cuenta de una clienta (pedido de Nicolas del 27/11/2026, contrato docs/contracts/auth.md §18).
--
-- Al crear la cuenta en la app (PR siguiente), la clienta carga sus datos personales y, si quiere, unas respuestas para
-- conocerla mejor. Esta migración trae dónde se guardan y la única forma de escribirlos; nada los junta todavía.
--
-- public.account_details (una fila por cuenta):
--   * obligatorios: nombre, apellido, teléfono (E.164, el de WhatsApp) y fecha de nacimiento (18 años o más, declarada;
--     no se verifica);
--   * dirección (calle, ciudad, código postal, indicaciones): opcional al crear la cuenta; Evelyn la necesita antes de
--     la primera reserva;
--   * opcionales, para conocerla y ofrecerle lo que le sirve: temporada preferida, cómo nos conoció, qué le interesa,
--     qué días le vienen mejor (lunes a viernes, el horario de Evelyn) y para cuántas personas. Nada de salud: las
--     alergias van aparte, con su consentimiento (SPEC §6);
--   * qué versión de la privacy aceptó y cuándo.
-- Quién la ve: la cuenta, la suya; la cocina (la cocinera y sus colaboradores, current_chef_id()), todas: es una sola
-- cocina y las cuentas son de sus clientas. Nadie más. Nadie escribe por la API: solo public.save_account_details.
--
-- public.save_account_details(p jsonb): la cuenta de la sesión (una clienta, nunca la cocina) guarda o corrige sus
-- datos. Valida cada campo y, si alguno no sirve, corta con 22023 invalid_account_details y los nombres de los campos
-- en el detalle (nunca los valores). Copia el nombre completo y el teléfono a profiles (full_name, phone), que es lo
-- que ya usa el resto (la cocina ve el perfil de sus clientas). Tests: pgTAP 31_account_details.
-- =====================================================================
create table public.account_details (
  profile_id          uuid primary key references public.profiles (id) on delete cascade,
  first_name          text not null check (char_length(first_name) between 1 and 60),
  last_name           text not null check (char_length(last_name) between 1 and 80),
  phone               text not null check (phone ~ '^\+[1-9][0-9]{6,14}$'),
  birth_date          date not null check (birth_date >= date '1900-01-01'),
  address_street      text check (char_length(address_street) between 3 and 120),
  address_city        text check (char_length(address_city) between 2 and 80),
  address_postal_code text check (address_postal_code ~ '^[0-9A-Za-z][0-9A-Za-z -]{1,8}[0-9A-Za-z]$'),
  address_notes       text check (char_length(address_notes) between 1 and 200),
  favorite_season     text check (favorite_season in ('spring', 'summer', 'autumn', 'winter', 'any')),
  heard_from          text check (heard_from in ('instagram', 'google', 'word_of_mouth', 'other')),
  interests           text[] check (cardinality(interests) between 1 and 3 and interests <@ array['weekly', 'dinners', 'events']),
  preferred_days      smallint[] check (cardinality(preferred_days) between 1 and 5 and preferred_days <@ array[1, 2, 3, 4, 5]::smallint[]),
  household_size      text check (household_size in ('1-2', '3-4', '5+')),
  privacy_version     text not null check (privacy_version ~ '^\d{4}-\d{2}-\d{2}$'),
  privacy_accepted_at timestamptz not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
comment on table public.account_details is
  'Datos de la cuenta de una clienta (auth.md §18): nombre, teléfono, nacimiento, dirección y respuestas opcionales. Los escribe solo save_account_details; los lee la cuenta (la suya) y la cocina.';

alter table public.account_details enable row level security;
revoke all on table public.account_details from anon, authenticated;
grant select on table public.account_details to authenticated;

-- La identidad propia: cada cuenta ve solo su fila.
create policy "account_details: la cuenta lee los suyos"
  on public.account_details for select to authenticated
  using (profile_id = (select auth.uid()));

-- La cocina (una sola) ve los de todas sus clientas.
create policy "account_details: la cocina los lee"
  on public.account_details for select to authenticated
  using (public.current_chef_id() is not null);

create function public.save_account_details(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_errors    text[] := '{}';
  v_today     date := (now() at time zone 'Europe/Rome')::date;
  v_first     text;
  v_last      text;
  v_phone     text;
  v_birth     date;
  v_street    text;
  v_city      text;
  v_postal    text;
  v_notes     text;
  v_season    text;
  v_heard     text;
  v_household text;
  v_interests text[];
  v_days      smallint[];
  v_privacy   text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  -- Solo una clienta: la cocina (dueña o colaborador) tiene su propia ficha pública.
  if public.current_chef_id() is not null
     or not exists (select 1 from public.profiles pr where pr.id = v_uid and pr.role = 'client') then
    raise exception 'not_a_client_account' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'invalid_account_details' using errcode = '22023';
  end if;

  -- Textos: string, sin espacios de más; vacío = no está.
  v_first  := case when jsonb_typeof(p -> 'first_name') = 'string' then nullif(btrim(p ->> 'first_name'), '') end;
  v_last   := case when jsonb_typeof(p -> 'last_name') = 'string' then nullif(btrim(p ->> 'last_name'), '') end;
  v_phone  := case when jsonb_typeof(p -> 'phone') = 'string' then nullif(btrim(p ->> 'phone'), '') end;
  v_street := case when jsonb_typeof(p -> 'address_street') = 'string' then nullif(btrim(p ->> 'address_street'), '') end;
  v_city   := case when jsonb_typeof(p -> 'address_city') = 'string' then nullif(btrim(p ->> 'address_city'), '') end;
  v_postal := case when jsonb_typeof(p -> 'address_postal_code') = 'string' then nullif(upper(btrim(p ->> 'address_postal_code')), '') end;
  v_notes  := case when jsonb_typeof(p -> 'address_notes') = 'string' then nullif(btrim(p ->> 'address_notes'), '') end;
  v_season := case when jsonb_typeof(p -> 'favorite_season') = 'string' then p ->> 'favorite_season' end;
  v_heard  := case when jsonb_typeof(p -> 'heard_from') = 'string' then p ->> 'heard_from' end;
  v_household := case when jsonb_typeof(p -> 'household_size') = 'string' then p ->> 'household_size' end;
  v_privacy := case when jsonb_typeof(p -> 'privacy_version') = 'string' then p ->> 'privacy_version' end;

  if v_first is null or char_length(v_first) > 60 then v_errors := array_append(v_errors, 'first_name'); end if;
  if v_last is null or char_length(v_last) > 80 then v_errors := array_append(v_errors, 'last_name'); end if;
  if v_phone is null or v_phone !~ '^\+[1-9][0-9]{6,14}$' then v_errors := array_append(v_errors, 'phone'); end if;

  -- Fecha de nacimiento: AAAA-MM-DD real, desde 1900, y 18 años cumplidos hoy (en Roma).
  begin
    if jsonb_typeof(p -> 'birth_date') = 'string' and (p ->> 'birth_date') ~ '^\d{4}-\d{2}-\d{2}$' then
      v_birth := (p ->> 'birth_date')::date;
    end if;
  exception when others then
    v_birth := null;
  end;
  if v_birth is null or v_birth < date '1900-01-01' then
    v_errors := array_append(v_errors, 'birth_date');
  elsif v_birth > (v_today - interval '18 years')::date then
    v_errors := array_append(v_errors, 'underage');
  end if;

  -- La dirección: toda o nada (calle, ciudad y código postal juntos; las indicaciones, si hay calle).
  if v_street is not null or v_city is not null or v_postal is not null or v_notes is not null then
    if v_street is null or char_length(v_street) not between 3 and 120 then v_errors := array_append(v_errors, 'address_street'); end if;
    if v_city is null or char_length(v_city) not between 2 and 80 then v_errors := array_append(v_errors, 'address_city'); end if;
    if v_postal is null or v_postal !~ '^[0-9A-Z][0-9A-Z -]{1,8}[0-9A-Z]$' then v_errors := array_append(v_errors, 'address_postal_code'); end if;
    if v_notes is not null and char_length(v_notes) > 200 then v_errors := array_append(v_errors, 'address_notes'); end if;
  end if;

  if v_season is not null and v_season not in ('spring', 'summer', 'autumn', 'winter', 'any') then v_errors := array_append(v_errors, 'favorite_season'); end if;
  if v_heard is not null and v_heard not in ('instagram', 'google', 'word_of_mouth', 'other') then v_errors := array_append(v_errors, 'heard_from'); end if;
  if v_household is not null and v_household not in ('1-2', '3-4', '5+') then v_errors := array_append(v_errors, 'household_size'); end if;

  -- Listas: un array de valores conocidos, sin repetidos; vacío = no está.
  if p ? 'interests' and jsonb_typeof(p -> 'interests') <> 'null' then
    if jsonb_typeof(p -> 'interests') <> 'array'
       or exists (select 1 from jsonb_array_elements(p -> 'interests') e
                  where jsonb_typeof(e) <> 'string' or e #>> '{}' not in ('weekly', 'dinners', 'events')) then
      v_errors := array_append(v_errors, 'interests');
    else
      v_interests := nullif(array(select distinct e from jsonb_array_elements_text(p -> 'interests') e order by 1), '{}');
    end if;
  end if;
  if p ? 'preferred_days' and jsonb_typeof(p -> 'preferred_days') <> 'null' then
    if jsonb_typeof(p -> 'preferred_days') <> 'array'
       or exists (select 1 from jsonb_array_elements(p -> 'preferred_days') e
                  where jsonb_typeof(e) <> 'number' or (e #>> '{}') not in ('1', '2', '3', '4', '5')) then
      v_errors := array_append(v_errors, 'preferred_days');
    else
      v_days := nullif(array(select distinct (e #>> '{}')::smallint from jsonb_array_elements(p -> 'preferred_days') e order by 1), '{}');
    end if;
  end if;

  if v_privacy is null or v_privacy !~ '^\d{4}-\d{2}-\d{2}$' then v_errors := array_append(v_errors, 'privacy_version'); end if;

  if cardinality(v_errors) > 0 then
    raise exception 'invalid_account_details' using errcode = '22023', detail = array_to_string(v_errors, ',');
  end if;

  insert into public.account_details as d (
    profile_id, first_name, last_name, phone, birth_date,
    address_street, address_city, address_postal_code, address_notes,
    favorite_season, heard_from, interests, preferred_days, household_size,
    privacy_version, privacy_accepted_at
  ) values (
    v_uid, v_first, v_last, v_phone, v_birth,
    v_street, v_city, v_postal, v_notes,
    v_season, v_heard, v_interests, v_days, v_household,
    v_privacy, now()
  )
  on conflict (profile_id) do update set
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    phone = excluded.phone,
    birth_date = excluded.birth_date,
    address_street = excluded.address_street,
    address_city = excluded.address_city,
    address_postal_code = excluded.address_postal_code,
    address_notes = excluded.address_notes,
    favorite_season = excluded.favorite_season,
    heard_from = excluded.heard_from,
    interests = excluded.interests,
    preferred_days = excluded.preferred_days,
    household_size = excluded.household_size,
    -- La aceptación se renueva solo con otra versión de la privacy.
    privacy_accepted_at = case when d.privacy_version = excluded.privacy_version then d.privacy_accepted_at else now() end,
    privacy_version = excluded.privacy_version,
    updated_at = now();

  update public.profiles pr
     set full_name = v_first || ' ' || v_last, phone = v_phone
   where pr.id = v_uid;

  return jsonb_build_object('ok', true);
end
$$;
comment on function public.save_account_details(jsonb) is
  'La cuenta de la sesión (una clienta) guarda o corrige sus datos (auth.md §18). 22023 invalid_account_details con los campos en el detalle; 42501 si no hay sesión o es de la cocina.';
revoke all on function public.save_account_details(jsonb) from public, anon;
grant execute on function public.save_account_details(jsonb) to authenticated;
