-- =====================================================================
-- Radici · Avisos a Evelyn para completar el menú de cada semana (proceso de presupuesto y menús del
-- 21/11/2026, SPEC 5.8). Tests: supabase/tests/database/21_menu_reminders.test.sql.
--
-- Una semana confirmada necesita que Evelyn le mande el menú a la clienta, a más tardar 48 h antes
-- de la cocina, para que la clienta tenga tiempo de comprar. Si todavía no salió (o la clienta pidió
-- cambios y Evelyn no mandó otro), Evelyn recibe un email:
--   * 4 días antes de la cocina («first»);
--   * 72 h antes, si sigue pendiente («last»: queda un día antes del límite);
--   * pasado el límite de 48 h, cada 2 horas hasta que lo mande o empiece la sesión («overdue»).
-- Nunca de noche: de 8:00 a 20:59, hora de Roma (§8), así que el aviso que cae de noche sale a las
-- 8:00. Tampoco en la primera hora después de crear la sesión: Evelyn la acaba de confirmar y está
-- armando el menú.
--
--   1. pg_net, para que la base llame a la Edge Function menu-reminders.
--   2. private.menu_reminders: qué avisos ya salieron de cada semana.
--   3. public.menu_reminders_due(p_chef_id, p_now): las semanas con un aviso que toca ahora.
--      public.menu_reminders_mark(p_chef_id, p_items, p_now): los marca enviados (la función los
--      marca después de mandar el email; si el email falla, el próximo turno lo reintenta).
--   4. private.call_menu_reminders() y el trabajo de pg_cron cada 15 minutos: llama a la función
--      con la URL y el secreto que el despliegue guarda en Vault (con private.upsert_vault_secret).
--      Sin ellos (en local, o antes del primer despliegue) no hace nada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. pg_net (Supabase: create extension … with schema extensions; sus funciones quedan en net)
-- ---------------------------------------------------------------------
create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------
-- 2. private.menu_reminders
-- ---------------------------------------------------------------------
create table private.menu_reminders (
  session_id     uuid primary key references public.sessions (id) on delete cascade,
  chef_id        uuid not null,
  first_at       timestamptz,
  last_at        timestamptz,
  overdue_at     timestamptz,
  overdue_count  int not null default 0 check (overdue_count >= 0)
);

comment on table private.menu_reminders is
  'Avisos a Evelyn para completar el menú de una semana (SPEC 5.8): cuándo salió el de 4 días, el de 72 h y el último de los de cada 2 horas pasado el límite de 48 h. Solo las funciones de los avisos.';

revoke all on table private.menu_reminders from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3a. public.menu_reminders_due(p_chef_id, p_now)
--
-- Las semanas de la cocina con un aviso que toca en p_now, por fecha. Una semana está pendiente si:
--   * es de una reserva (request_id) y está confirmada (o en el viejo shopping_done): una held es de
--     un presupuesto que la clienta todavía no aceptó;
--   * empieza después de p_now y dentro de 4 días;
--   * no tiene ningún envío del menú que haya salido, o el último pidió cambios (Evelyn tiene que
--     mandar otro);
--   * se creó hace más de una hora.
-- El aviso que toca: «overdue» desde 48 h antes (si el anterior de este tipo salió hace 2 horas o
-- más), «last» desde 72 h antes (si no salió) y «first» desde 4 días antes (si no salió ninguno de
-- los dos). Y solo de 8:00 a 20:59 en Roma.
-- Devuelve [{sessionId, requestId, kind, date, start, deadline, week, weeks, clientName,
-- changesRequested}]; deadline = 48 h antes de la llegada.
-- ---------------------------------------------------------------------
create function public.menu_reminders_due(p_chef_id uuid, p_now timestamptz default now())
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with live as (
    select s.*,
           ((s."date" + s.start_time) at time zone 'Europe/Rome') as starts_at,
           row_number() over (partition by s.request_id order by s."date", s.start_time, s.id)::int as week,
           count(*) over (partition by s.request_id)::int as weeks
    from public.sessions s
    where s.chef_id = p_chef_id and s.request_id is not null and s.status <> 'cancelled'
  ),
  pending as (
    select l.*,
           r.first_at, r.last_at, r.overdue_at,
           coalesce(last_send.changes_requested_at is not null, false) as changes_requested
    from live l
    left join private.menu_reminders r on r.session_id = l.id
    left join lateral (
      select ms.id, ms.changes_requested_at
      from public.menu_sends ms
      where ms.session_id = l.id and ms.sent_at is not null
      order by ms.sent_at desc, ms.id desc
      limit 1
    ) last_send on true
    where l.status in ('confirmed', 'shopping_done')
      and l.starts_at > p_now
      and l.starts_at - interval '4 days' <= p_now
      and l.created_at <= p_now - interval '1 hour'
      and (last_send.id is null or last_send.changes_requested_at is not null)
  ),
  due as (
    select p.*,
           case
             when p_now >= p.starts_at - interval '48 hours' then
               case when p.overdue_at is null or p.overdue_at <= p_now - interval '2 hours' then 'overdue' end
             when p_now >= p.starts_at - interval '72 hours' then
               case when p.last_at is null then 'last' end
             else
               case when p.first_at is null and p.last_at is null then 'first' end
           end as kind
    from pending p
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'sessionId', d.id,
           'requestId', d.request_id,
           'kind', d.kind,
           'date', d."date",
           'start', to_char(d.start_time, 'HH24:MI'),
           'deadline', d.starts_at - interval '48 hours',
           'week', d.week,
           'weeks', d.weeks,
           'clientName', c.display_name,
           'changesRequested', d.changes_requested)
           order by d.starts_at, d.id), '[]'::jsonb)
  from due d
  join public.clients c on c.id = d.client_id
  where d.kind is not null
    and extract(hour from (p_now at time zone 'Europe/Rome')) between 8 and 20
$$;

comment on function public.menu_reminders_due(uuid, timestamptz) is
  'Las semanas de la cocina con un aviso a Evelyn que toca en p_now para completar el menú (SPEC 5.8): pendientes (sin menú enviado, o con cambios pedidos), confirmadas, dentro de 4 días, creadas hace más de una hora; «first» 4 días antes, «last» 72 h antes, «overdue» cada 2 horas pasado el límite de 48 h; de 8 a 20:59 en Roma. Solo service_role.';

-- ---------------------------------------------------------------------
-- 3b. public.menu_reminders_mark(p_chef_id, p_items, p_now)
--
-- p_items: [{sessionId, kind}], los avisos que salieron en el email. Ignora las sesiones de otra
-- cocina y los tipos desconocidos. Devuelve cuántos marcó.
-- ---------------------------------------------------------------------
create function public.menu_reminders_mark(p_chef_id uuid, p_items jsonb, p_now timestamptz default now())
returns int
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_item  jsonb;
  v_count int := 0;
  v_id    uuid;
  v_kind  text;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'invalid_items' using errcode = '22023';
  end if;
  for v_item in select e from jsonb_array_elements(p_items) as e loop
    v_kind := v_item ->> 'kind';
    if jsonb_typeof(v_item) <> 'object'
       or v_kind is null or v_kind not in ('first', 'last', 'overdue')
       or coalesce(v_item ->> 'sessionId', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      continue;
    end if;
    v_id := (v_item ->> 'sessionId')::uuid;
    if not exists (select 1 from public.sessions s where s.id = v_id and s.chef_id = p_chef_id) then
      continue;
    end if;
    insert into private.menu_reminders (session_id, chef_id, first_at, last_at, overdue_at, overdue_count)
    values (v_id, p_chef_id,
            case when v_kind = 'first' then p_now end,
            case when v_kind = 'last' then p_now end,
            case when v_kind = 'overdue' then p_now end,
            case when v_kind = 'overdue' then 1 else 0 end)
    on conflict (session_id) do update
      set first_at      = case when v_kind = 'first' then p_now else private.menu_reminders.first_at end,
          last_at       = case when v_kind = 'last' then p_now else private.menu_reminders.last_at end,
          overdue_at    = case when v_kind = 'overdue' then p_now else private.menu_reminders.overdue_at end,
          overdue_count = private.menu_reminders.overdue_count + case when v_kind = 'overdue' then 1 else 0 end;
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;

comment on function public.menu_reminders_mark(uuid, jsonb, timestamptz) is
  'Marca enviados los avisos a Evelyn de p_items ([{sessionId, kind}]) en p_now (SPEC 5.8). Ignora sesiones de otra cocina y tipos desconocidos. Devuelve cuántos marcó. Solo service_role.';

revoke all on function public.menu_reminders_due(uuid, timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.menu_reminders_mark(uuid, jsonb, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.menu_reminders_due(uuid, timestamptz) to service_role;
grant execute on function public.menu_reminders_mark(uuid, jsonb, timestamptz) to service_role;

-- ---------------------------------------------------------------------
-- 4. private.call_menu_reminders() y pg_cron
--
-- La URL de la función y el secreto que espera los guarda el despliegue en Vault
-- (radici_menu_reminders_url y radici_menu_reminders_secret; el mismo secreto va como secreto de la
-- función, MENU_REMINDERS_SECRET). Sin alguno de los dos no hace nada. net.http_post encola el
-- pedido y vuelve enseguida: la respuesta queda en net._http_response unas horas.
-- ---------------------------------------------------------------------
create function private.call_menu_reminders()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_url    text;
  v_secret text;
begin
  select ds.decrypted_secret into v_url from vault.decrypted_secrets ds where ds.name = 'radici_menu_reminders_url';
  select ds.decrypted_secret into v_secret from vault.decrypted_secrets ds where ds.name = 'radici_menu_reminders_secret';
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return;
  end if;
  perform net.http_post(
    url := v_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-reminders-secret', v_secret),
    timeout_milliseconds := 30000);
end
$$;

comment on function private.call_menu_reminders() is
  'Llama a la Edge Function menu-reminders (pg_net) con la URL y el secreto de Vault (radici_menu_reminders_url y radici_menu_reminders_secret, que guarda el despliegue). Sin ellos no hace nada. La corre pg_cron cada 15 minutos.';

revoke all on function private.call_menu_reminders() from public, anon, authenticated, service_role;

-- private.upsert_vault_secret(p_name, p_value): crea o reemplaza un secreto de Vault por nombre. La
-- llama el despliegue (deploy-supabase.yml, por la Management API como postgres) para guardar la URL
-- y el secreto de los avisos; nadie más.
create function private.upsert_vault_secret(p_name text, p_value text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if coalesce(p_name, '') = '' or coalesce(p_value, '') = '' then
    raise exception 'invalid_secret' using errcode = '22023';
  end if;
  select s.id into v_id from vault.secrets s where s.name = p_name;
  if v_id is null then
    perform vault.create_secret(p_value, p_name);
  else
    perform vault.update_secret(v_id, p_value);
  end if;
end
$$;

comment on function private.upsert_vault_secret(text, text) is
  'Crea o reemplaza un secreto de Vault por nombre. La usa el despliegue para la URL y el secreto de los avisos del menú (radici_menu_reminders_url y radici_menu_reminders_secret).';

revoke all on function private.upsert_vault_secret(text, text) from public, anon, authenticated, service_role;

-- Cada 15 minutos (los horarios de pg_cron son UTC; la función decide si toca según la hora de Roma).
select cron.schedule('radici-menu-reminders', '*/15 * * * *', 'select private.call_menu_reminders()');
