-- =====================================================================
-- PR07 (docs/contracts/auth.md §8): las funciones de los hooks de Auth. Solo la base: este PR no prende
-- ningún hook (el PATCH de Auth corre antes de `db push`: un hook prendido que apunta a una función que
-- todavía no existe rompe el login de todos). PR08 prende el de la cocina; el de las altas, PR20.
--
--   1. public.kitchen_access_token_hook(event jsonb): Custom Access Token hook. La cocina (cocinera y
--      colaboradores) entra solo con código del email. Si la cuenta es de la cocina y claims.amr trae
--      algo que no sea otp ni magiclink, responde 403 kitchen_code_only. A las demás cuentas (las
--      clientas) les devuelve los claims sin tocar. Decide por claims.amr, nunca por
--      authentication_method: en un refresh vale token_refresh, y el amr del refresh conserva los métodos
--      con los que se abrió la sesión.
--   2. public.before_user_created_guard(event jsonb): Before User Created hook, el freno de las altas:
--      pausa de emergencia, tope diario y tope por IP y por hora. Las IP se guardan con hash (HMAC-SHA-256
--      con un pepper de private.auth_guard, IPv6 reducida a su /64) y se borran a las 48 h.
--   3. private.auth_guard (una sola fila con los valores, se cambian por SQL) y
--      private.signup_attempts (un renglón por alta permitida).
--
-- Por qué security definer (las dos funciones). Las tablas que leen y escriben (chefs, chef_members,
-- auth_guard, signup_attempts) están cerradas: supabase_auth_admin no tiene ningún privilegio sobre ellas
-- ni usage sobre el esquema private, y no se le da. Las funciones corren como postgres (dueño), con
-- search_path vacío y todo calificado. Lo único que se le da a supabase_auth_admin es EXECUTE sobre las
-- dos funciones; a PUBLIC, anon, authenticated y service_role se les quita (la service role tampoco las
-- necesita: un hook lo llama GoTrue, nadie más). Con el esquema private cerrado, una función security
-- definer es lo que menos abre.
--
-- Fallo cerrado. Si algo raro llega (user_id que no es uuid, un renglón de auth_guard que falta), la
-- función lanza una excepción y GoTrue contesta 500: la cuenta de la cocina no entra y el alta no pasa.
-- Nunca se «deja pasar por las dudas».
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Valores del freno de altas (una sola fila) y registro de altas permitidas
-- ---------------------------------------------------------------------
create table private.auth_guard (
  -- Una sola fila: la clave es el booleano true.
  id          boolean primary key default true constraint auth_guard_single_row check (id),
  paused      boolean not null default false,
  daily_cap   int not null default 50 constraint auth_guard_daily_cap check (daily_cap >= 1),
  ip_hour_cap int not null default 5 constraint auth_guard_ip_hour_cap check (ip_hour_cap >= 1),
  -- Pepper del hash de las IP: lo genera esta migración y no sale de la base. Cambiarlo reinicia los
  -- contadores por IP (los hashes viejos dejan de coincidir) y nada más.
  ip_pepper   text not null default pg_catalog.encode(extensions.gen_random_bytes(32), 'hex')
    constraint auth_guard_ip_pepper check (length(ip_pepper) >= 32)
);
insert into private.auth_guard (id) values (true);

comment on table private.auth_guard is
  'Valores del freno de altas (before_user_created_guard). Una sola fila. Se cambian por SQL (runbook: docs/contracts/auth.md §8): update private.auth_guard set paused = true. daily_cap = altas permitidas en 24 h; ip_hour_cap = altas permitidas por IP (IPv6: por /64) en 1 h.';

create table private.signup_attempts (
  id         bigint generated always as identity primary key,
  -- HMAC-SHA-256 en hexadecimal de la IP (con el pepper de auth_guard): la IP nunca se guarda en claro.
  ip_hash    text not null constraint signup_attempts_ip_hash_sha256 check (ip_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);
create index signup_attempts_ip_created_idx on private.signup_attempts (ip_hash, created_at);
create index signup_attempts_created_idx on private.signup_attempts (created_at);

comment on table private.signup_attempts is
  'Un renglón por alta permitida por before_user_created_guard: hash de la IP y hora. Se borra a las 48 h (purge_signup_attempts, desde la función y desde pg_cron).';

alter table private.auth_guard enable row level security;
alter table private.signup_attempts enable row level security;
revoke all on private.auth_guard, private.signup_attempts from public, anon, authenticated, service_role;
-- (sin ningún grant a supabase_auth_admin: las funciones son security definer)

-- ---------------------------------------------------------------------
-- 2. Purga de los renglones de más de 48 h
-- ---------------------------------------------------------------------
create function private.purge_signup_attempts()
returns int
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_deleted int;
begin
  delete from private.signup_attempts where created_at < pg_catalog.now() - interval '48 hours';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;
revoke all on function private.purge_signup_attempts() from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. Custom Access Token hook: la cocina solo con código
-- ---------------------------------------------------------------------
create function public.kitchen_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_amr     jsonb := event -> 'claims' -> 'amr';
begin
  v_user_id := (event ->> 'user_id')::uuid;
  if v_user_id is null then
    raise exception 'kitchen_hook_without_user' using errcode = '22023';
  end if;

  -- Una cuenta que no es de la cocina (la clienta): los claims pasan sin tocar.
  if not (
    exists (select 1 from public.chefs c where c.profile_id = v_user_id)
    or exists (select 1 from public.chef_members m where m.profile_id = v_user_id)
  ) then
    return pg_catalog.jsonb_build_object('claims', event -> 'claims');
  end if;

  -- La cocina: claims.amr tiene que ser una lista no vacía donde TODOS los métodos son otp o magiclink.
  -- Cualquier otra cosa (password, oauth, recovery, totp, un amr que falta o con otra forma) es 403.
  -- Se mira claims.amr y nunca authentication_method: en el refresh vale token_refresh.
  if pg_catalog.jsonb_typeof(v_amr) = 'array'
     and pg_catalog.jsonb_array_length(v_amr) > 0
     and not exists (
       select 1
       from pg_catalog.jsonb_array_elements(v_amr) as e (entry)
       where pg_catalog.jsonb_typeof(e.entry) is distinct from 'object'
          or pg_catalog.jsonb_typeof(e.entry -> 'method') is distinct from 'string'
          or (e.entry ->> 'method') not in ('otp', 'magiclink')
     )
  then
    return pg_catalog.jsonb_build_object('claims', event -> 'claims');
  end if;

  return pg_catalog.jsonb_build_object('error', pg_catalog.jsonb_build_object(
    'http_code', 403, 'message', 'kitchen_code_only'));
end;
$$;

comment on function public.kitchen_access_token_hook(jsonb) is
  'Custom Access Token hook (auth.md §8): la cocina (chefs y chef_members) solo con código. 403 kitchen_code_only si claims.amr trae algo que no sea otp o magiclink, o no es una lista no vacía. Decide por claims.amr, nunca por authentication_method. Las demás cuentas pasan sin tocar. Solo la ejecuta supabase_auth_admin.';

revoke all on function public.kitchen_access_token_hook(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.kitchen_access_token_hook(jsonb) to supabase_auth_admin;

-- ---------------------------------------------------------------------
-- 4. Before User Created hook: el freno de altas
-- ---------------------------------------------------------------------
create function public.before_user_created_guard(event jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  g        private.auth_guard%rowtype;
  v_raw    text := event -> 'metadata' ->> 'ip_address';
  v_inet   inet;
  v_key    text;
  v_hash   text;
  v_daily  int;
  v_ip_n   int;
begin
  -- Una alta a la vez: sin esto, dos altas simultáneas leen el mismo contador y pasan las dos
  -- (el tope se pasaría). Se suelta solo al terminar la transacción del hook.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('radici.before_user_created_guard', 0));

  select * into g from private.auth_guard where id;
  if not found then
    raise exception 'auth_guard_missing' using errcode = '55000';
  end if;

  perform private.purge_signup_attempts();

  if g.paused then
    return pg_catalog.jsonb_build_object('error', pg_catalog.jsonb_build_object(
      'http_code', 403, 'message', 'signups_paused'));
  end if;

  -- IP: IPv4 tal cual; IPv6 reducida a su /64 (rotar dentro del /64 no da un cubo nuevo); una IPv4
  -- mapeada (::ffff:a.b.c.d) cuenta como la IPv4. Sin IP, o con algo que no es una IP: un cubo único
  -- «sin-ip» (no es un permiso: comparte el tope por IP).
  if v_raw ~* '^::ffff:\d{1,3}(\.\d{1,3}){3}$' then
    v_raw := pg_catalog.substr(v_raw, 8);
  end if;
  begin
    v_inet := v_raw::inet;
  exception when others then
    v_inet := null;
  end;
  if v_inet is null then
    v_key := 'sin-ip';
  elsif pg_catalog.family(v_inet) = 6 then
    v_key := pg_catalog.host(pg_catalog.network(pg_catalog.set_masklen(v_inet, 64))) || '/64';
  else
    v_key := pg_catalog.host(v_inet);
  end if;
  v_hash := pg_catalog.encode(extensions.hmac(v_key, g.ip_pepper, 'sha256'), 'hex');

  select pg_catalog.count(*)::int into v_daily
    from private.signup_attempts where created_at > pg_catalog.now() - interval '24 hours';
  if v_daily >= g.daily_cap then
    return pg_catalog.jsonb_build_object('error', pg_catalog.jsonb_build_object(
      'http_code', 429, 'message', 'signups_daily_cap'));
  end if;

  select pg_catalog.count(*)::int into v_ip_n
    from private.signup_attempts
   where ip_hash = v_hash and created_at > pg_catalog.now() - interval '1 hour';
  if v_ip_n >= g.ip_hour_cap then
    return pg_catalog.jsonb_build_object('error', pg_catalog.jsonb_build_object(
      'http_code', 429, 'message', 'signups_ip_cap'));
  end if;

  insert into private.signup_attempts (ip_hash) values (v_hash);
  return '{}'::jsonb;
end;
$$;

comment on function public.before_user_created_guard(jsonb) is
  'Before User Created hook (auth.md §8): freno de altas. Pausa (403 signups_paused), tope diario (429 signups_daily_cap) y tope por IP y por hora (429 signups_ip_cap), con valores de private.auth_guard. IP con HMAC y pepper, IPv6 por /64, sin IP = un cubo «sin-ip». Solo cuenta las altas permitidas. Solo la ejecuta supabase_auth_admin.';

revoke all on function public.before_user_created_guard(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.before_user_created_guard(jsonb) to supabase_auth_admin;

-- ---------------------------------------------------------------------
-- 5. pg_cron: purga por hora (además de la que hace la función en cada alta)
-- ---------------------------------------------------------------------
select cron.schedule(
  'radici-purge-signup-attempts',
  '17 * * * *',
  'select private.purge_signup_attempts()'
);
