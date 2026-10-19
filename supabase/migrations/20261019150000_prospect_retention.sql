-- =====================================================================
-- Radici · Conservación: borrado de prospectos que no avanzan (SPEC §6)
-- Contrato: docs/contracts/public-request.md §9. La privacy promete
-- conservar como máximo chef_settings.prospect_retention_days (90) los
-- pedidos que no avanzan.
--
--   1. private.prospect_retention_expired(client_id): la regla, en un solo lugar.
--   2. private.purge_expired_prospects(): borra esos prospectos (en cascada:
--      pedidos y sus presupuestos, consentimientos, restricciones y sesiones
--      canceladas) y las notificaciones que apuntan a esos pedidos. De paso
--      borra los intentos del límite por IP de más de 2 días (hit_public_request_rate
--      solo los borra cuando llega otro intento).
--   3. pg_cron: lo corre todos los días a las 03:30 UTC (04:30/05:30 en Roma).
--
-- Las dos funciones van en el esquema private (fuera de la API): ningún rol
-- de la API las ve ni las ejecuta. Las corre el trabajo de pg_cron como
-- postgres (el rol que lo programa en esta migración) o alguien a mano desde
-- el SQL editor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. La regla
-- Se borra un cliente si:
--   * es un prospecto sin cuenta (status 'prospect', profile_id null);
--   * ninguno de sus pedidos avanzó: todos siguen en new, rejected, expired
--     o declined (quoted, accepted y resolved se conservan);
--   * no tiene sesiones vivas (todas canceladas) ni pagos registrados (un
--     pago es un registro contable: nunca se borra en cascada);
--   * su último pedido es de hace más de prospect_retention_days días de su
--     cocinera (90 si faltara la fila de chef_settings). Sin pedidos (alta a
--     mano desde la app), cuenta la fecha del alta.
-- ---------------------------------------------------------------------
create function private.prospect_retention_expired(p_client_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from public.clients cl
    left join public.chef_settings s on s.chef_id = cl.chef_id
    where cl.id = p_client_id
      and cl.status = 'prospect'
      and cl.profile_id is null
      and not exists (
        select 1 from public.requests r
        where r.client_id = cl.id
          and r.status not in ('new', 'rejected', 'expired', 'declined')
      )
      and not exists (
        select 1 from public.sessions se
        where se.client_id = cl.id
          and (se.status <> 'cancelled'
               or exists (select 1 from public.payments pa where pa.session_id = se.id))
      )
      and coalesce((select max(r.created_at) from public.requests r where r.client_id = cl.id), cl.created_at)
          < now() - make_interval(days => coalesce(s.prospect_retention_days, 90))
  )
$$;

comment on function private.prospect_retention_expired(uuid) is
  'true si el cliente es un prospecto sin cuenta cuyos pedidos no avanzaron (new, rejected, expired, declined), sin sesiones vivas ni pagos, y cuyo último pedido (o alta) supera chef_settings.prospect_retention_days.';

-- ---------------------------------------------------------------------
-- 2. El borrado
-- Devuelve cuántos borró:
--   {"clients": n, "requests": n, "notifications": n, "rate_limit_hits": n}.
-- Idempotente: una segunda corrida no encuentra nada que borrar.
--
-- Concurrencia: por cada candidato toma el mismo advisory lock que
-- submit_public_request (cocinera + email), bloquea la ficha y sus pedidos y
-- vuelve a evaluar la regla con lo último confirmado. Así un pedido nuevo de
-- esa persona termina antes (y el prospecto se conserva) o espera a que esto
-- termine (y crea un prospecto nuevo). Orden de locks: email → filas, igual
-- que submit_public_request; nunca se toma el lock de la clave de idempotencia.
-- ---------------------------------------------------------------------
create function private.purge_expired_prospects()
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_candidate     record;
  v_request_ids   uuid[];
  v_deleted       int;
  v_clients       int := 0;
  v_requests      int := 0;
  v_notifications int := 0;
  v_hits          int := 0;
begin
  for v_candidate in
    select cl.id, cl.chef_id, lower(cl.contact_email) as email
    from public.clients cl
    where cl.status = 'prospect'
      and cl.profile_id is null
      and private.prospect_retention_expired(cl.id)
    order by cl.id
  loop
    begin
      -- Sin email no hay pedido de la web que pueda chocar (siempre trae email).
      if v_candidate.email is not null then
        perform pg_advisory_xact_lock(hashtextextended('public_request:' || v_candidate.chef_id::text || ':' || v_candidate.email, 0));
      end if;

      perform 1 from public.clients cl where cl.id = v_candidate.id for update;
      if not found then
        continue;
      end if;
      perform 1 from public.requests r where r.client_id = v_candidate.id for update;

      -- Con la ficha y sus pedidos bloqueados, otra vez la regla (sentencia nueva: ve lo confirmado).
      if not private.prospect_retention_expired(v_candidate.id) then
        continue;
      end if;

      select coalesce(array_agg(r.id), '{}')
        into v_request_ids
      from public.requests r
      where r.client_id = v_candidate.id;

      -- Avisos que apuntan a esos pedidos (payload {"request_id": ...}), de cualquier tipo.
      delete from public.notifications n
      where n.payload ->> 'request_id' = any (v_request_ids::text[]);
      get diagnostics v_deleted = row_count;

      -- En cascada: pedidos (y presupuestos), consentimientos, restricciones,
      -- sesiones canceladas, planes, porciones y despensa del cliente.
      delete from public.clients cl where cl.id = v_candidate.id;

      v_clients       := v_clients + 1;
      v_requests      := v_requests + cardinality(v_request_ids);
      v_notifications := v_notifications + v_deleted;
    exception
      -- Un pago registrado justo ahora (payments → sessions es restrict): se
      -- deshace solo este cliente y se sigue; mañana la regla ya lo conserva.
      when foreign_key_violation then
        raise warning 'purge_expired_prospects: cliente % conservado (sqlstate %)', v_candidate.id, sqlstate;
    end;
  end loop;

  -- Límite por IP: la ventana más larga es de 1 día; nada necesita más de 2 (igual que
  -- hit_public_request_rate, que solo limpia cuando llega otro intento).
  delete from private.public_request_hits h where h.created_at < now() - interval '2 days';
  get diagnostics v_hits = row_count;

  -- Solo contadores: nunca datos del cliente en los logs.
  raise log 'purge_expired_prospects: clients=% requests=% notifications=% rate_limit_hits=%',
    v_clients, v_requests, v_notifications, v_hits;

  return jsonb_build_object('clients', v_clients, 'requests', v_requests, 'notifications', v_notifications,
                            'rate_limit_hits', v_hits);
end
$$;

comment on function private.purge_expired_prospects() is
  'Conservación (SPEC §6): borra los prospectos de private.prospect_retention_expired, con sus pedidos, consentimientos y restricciones en cascada, las notificaciones que apuntan a esos pedidos y los intentos del límite por IP de más de 2 días. Devuelve {clients, requests, notifications, rate_limit_hits}. Idempotente. La corre pg_cron a diario.';

-- Nadie más que el dueño (postgres): ni siquiera la service role.
revoke all on function private.prospect_retention_expired(uuid) from public, anon, authenticated, service_role;
revoke all on function private.purge_expired_prospects()        from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. pg_cron (Supabase Cron)
-- Habilitarlo así es lo que indica Supabase (supabase.com/docs/guides/cron/install,
-- revisado el 19/10/2026) y funciona igual en local y en un proyecto alojado: la
-- imagen de Postgres de Supabase ya trae pg_cron en shared_preload_libraries y
-- cron.database_name = postgres. Si ya estaba habilitado (panel → Integrations →
-- Cron), no hace nada. El esquema cron es de supabase_admin y postgres lo usa
-- (con grant option); el grant de abajo solo lo deja explícito.
--
-- cron.schedule con un nombre que ya existe actualiza ese trabajo (upsert por
-- nombre): volver a correr esto no duplica nada. Los horarios de pg_cron son en
-- GMT/UTC: 03:30 UTC = 04:30 (invierno) o 05:30 (verano) en Roma.
-- El trabajo corre como postgres (quien lo programa acá).
-- ---------------------------------------------------------------------
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;

select cron.schedule(
  'radici-purge-expired-prospects',
  '30 3 * * *',
  'select private.purge_expired_prospects()'
);
