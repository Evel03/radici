-- =====================================================================
-- Radici · M1 · Privilegios y Row Level Security (SPEC §6, "RLS (resumen)")
--
-- Dos capas:
--   1. Privilegios (GRANT/REVOKE): qué comandos y qué columnas puede tocar
--      cada rol de Postgres. anon no tiene ninguno; authenticated no puede
--      escribir sesiones, presupuestos, pagos (salvo efectivo/transferencia)
--      ni notificaciones. TRUNCATE se revoca porque saltea RLS.
--   2. Políticas RLS: qué filas. Cocinera = todo lo de su chef_id; cliente =
--      lo propio. Todas las políticas son "to authenticated": anon no ve nada
--      (el formulario público entra por la Edge Function public-request con la
--      service role, M3).
--
-- Las escrituras sensibles (estados de sesión, pagos de Stripe, presupuestos)
-- las hace la service role desde Edge Functions/webhooks. Así se cumple el
-- criterio de aceptación 6: Evelyn no puede marcar pagada una sesión de Stripe.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. RLS habilitado en todas las tablas de public
-- ---------------------------------------------------------------------
alter table public.profiles                 enable row level security;
alter table public.chefs                    enable row level security;
alter table public.chef_settings            enable row level security;
alter table public.availability_rules       enable row level security;
alter table public.availability_exceptions  enable row level security;
alter table public.clients                  enable row level security;
alter table public.client_restrictions      enable row level security;
alter table public.consents                 enable row level security;
alter table public.recurring_plans          enable row level security;
alter table public.recipes                  enable row level security;
alter table public.recipe_allergens         enable row level security;
alter table public.requests                 enable row level security;
alter table public.quotes                   enable row level security;
alter table public.sessions                 enable row level security;
alter table public.session_menu             enable row level security;
alter table public.receipts                 enable row level security;
alter table public.payments                 enable row level security;
alter table public.prepared_portions        enable row level security;
alter table public.pantry_items             enable row level security;
alter table public.push_tokens              enable row level security;
alter table public.notifications            enable row level security;

-- ---------------------------------------------------------------------
-- 2. Privilegios
-- (Supabase da ALL a anon y authenticated por defecto en public.)
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon;
revoke truncate, references, trigger, maintain on all tables in schema public from authenticated;

-- profiles: el usuario edita sus datos, nunca su rol. El alta la hace el trigger de auth.users.
revoke insert, update, delete on public.profiles from authenticated;
grant update (full_name, phone, locale) on public.profiles to authenticated;

-- chefs: la cocinera edita su ficha pública; el alta es de la service role.
revoke insert, update, delete on public.chefs from authenticated;
grant update (display_name, service_area, whatsapp) on public.chefs to authenticated;

-- clients: nadie desde la app toca profile_id (vincular una cuenta le daría
-- acceso a la ficha) ni los ids de Stripe. Reglas por rol en clients_guard_update.
revoke insert, update on public.clients from authenticated;
grant insert (id, chef_id, display_name, contact_email, contact_phone, zone, address, adults, kids,
              preferences, kitchen_notes, pay_mode, status, share_pantry, since)
  on public.clients to authenticated;
grant update (display_name, contact_email, contact_phone, zone, address, adults, kids,
              preferences, kitchen_notes, pay_mode, status, share_pantry)
  on public.clients to authenticated;

-- consents: se otorgan (sin poder antedatar granted_at) y se revocan. No se
-- borran desde la app: son la prueba del consentimiento (art. 7.1 RGPD).
revoke insert, update, delete on public.consents from authenticated;
grant insert (id, chef_id, client_id, kind, text_version) on public.consents to authenticated;
grant update (revoked_at) on public.consents to authenticated;

-- sesiones y presupuestos: solo lectura para la app.
revoke insert, update, delete on public.sessions from authenticated;
revoke insert, update, delete on public.quotes   from authenticated;

-- payments: solo lectura, salvo que la cocinera registra efectivo/transferencia
-- (la política limita a pending). Sin columnas de Stripe ni captura.
revoke insert, update, delete on public.payments from authenticated;
grant insert (id, chef_id, session_id, kind, provider, amount_cents,
              service_part_cents, groceries_part_cents, status, idempotency_key)
  on public.payments to authenticated;

-- prepared_portions: el cliente solo cambia count_left y discarded_at
-- (privilegio por columna; la cocinera no tiene política de update).
revoke update, delete on public.prepared_portions from authenticated;
grant update (count_left, discarded_at) on public.prepared_portions to authenticated;

-- notifications: las escribe la service role.
revoke insert, update, delete on public.notifications from authenticated;

-- ---------------------------------------------------------------------
-- 3. Políticas
-- Patrón: (select public.current_chef_id()) y (select public.current_client_ids())
-- para que Postgres evalúe el helper una vez por consulta y no por fila.
-- ---------------------------------------------------------------------

-- profiles ------------------------------------------------------------
create policy "profiles: el usuario lee el suyo"
  on public.profiles for select to authenticated
  using (id = (select auth.uid()));

create policy "profiles: la cocinera lee los de sus clientes"
  on public.profiles for select to authenticated
  using (id in (
    select cl.profile_id from public.clients cl
    where cl.chef_id = (select public.current_chef_id())
  ));

create policy "profiles: el usuario edita el suyo"
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- chefs ---------------------------------------------------------------
create policy "chefs: la cocinera lee la suya; el cliente, la de sus cocineras"
  on public.chefs for select to authenticated
  using (
    profile_id = (select auth.uid())
    or id in (select public.current_client_chef_ids())
  );

create policy "chefs: la cocinera edita la suya"
  on public.chefs for update to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

-- chef_settings y disponibilidad: solo la cocinera dueña (CRUD) -------
-- (los horarios libres para clientes y anónimos irán por RPC en M3)
create policy "chef_settings: la cocinera gestiona las suyas"
  on public.chef_settings for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "availability_rules: la cocinera gestiona las suyas"
  on public.availability_rules for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "availability_exceptions: la cocinera gestiona las suyas"
  on public.availability_exceptions for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

-- clients -------------------------------------------------------------
create policy "clients: la cocinera gestiona los suyos"
  on public.clients for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "clients: el cliente lee su ficha"
  on public.clients for select to authenticated
  using (id in (select public.current_client_ids()));

create policy "clients: el cliente edita su ficha"
  on public.clients for update to authenticated
  using (id in (select public.current_client_ids()))
  with check (id in (select public.current_client_ids()));

-- client_restrictions (dato de salud) ---------------------------------
create policy "client_restrictions: la cocinera gestiona las de sus clientes"
  on public.client_restrictions for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "client_restrictions: el cliente gestiona las suyas"
  on public.client_restrictions for all to authenticated
  using (client_id in (select public.current_client_ids()))
  with check (client_id in (select public.current_client_ids()));

-- consents ------------------------------------------------------------
-- El consentimiento lo da el interesado: el cliente lo otorga (o la Edge
-- Function del formulario público, con la service role). La cocinera lo ve y
-- puede registrar una revocación, pero no otorgarlo en nombre del cliente.
create policy "consents: la cocinera lee los de sus clientes"
  on public.consents for select to authenticated
  using (chef_id = (select public.current_chef_id()));

create policy "consents: la cocinera registra revocaciones"
  on public.consents for update to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "consents: el cliente lee los suyos"
  on public.consents for select to authenticated
  using (client_id in (select public.current_client_ids()));

create policy "consents: el cliente otorga los suyos"
  on public.consents for insert to authenticated
  with check (client_id in (select public.current_client_ids()));

create policy "consents: el cliente revoca los suyos"
  on public.consents for update to authenticated
  using (client_id in (select public.current_client_ids()))
  with check (client_id in (select public.current_client_ids()));

-- recurring_plans (F2) -------------------------------------------------
create policy "recurring_plans: la cocinera gestiona los suyos"
  on public.recurring_plans for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "recurring_plans: el cliente lee los suyos"
  on public.recurring_plans for select to authenticated
  using (client_id in (select public.current_client_ids()));

-- recetario -----------------------------------------------------------
-- El cliente ve las recetas activas de su cocinera para elegir platos deseados.
create policy "recipes: la cocinera gestiona las suyas"
  on public.recipes for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "recipes: el cliente lee las activas de su cocinera"
  on public.recipes for select to authenticated
  using (active and chef_id in (select public.current_client_chef_ids()));

create policy "recipe_allergens: la cocinera gestiona los suyos"
  on public.recipe_allergens for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "recipe_allergens: el cliente lee los de su cocinera"
  on public.recipe_allergens for select to authenticated
  using (chef_id in (select public.current_client_chef_ids()));

-- requests ------------------------------------------------------------
create policy "requests: la cocinera gestiona los suyos"
  on public.requests for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "requests: el cliente lee los suyos"
  on public.requests for select to authenticated
  using (client_id in (select public.current_client_ids()));

create policy "requests: el cliente crea los suyos (siempre como new)"
  on public.requests for insert to authenticated
  with check (
    client_id in (select public.current_client_ids())
    and status = 'new'
    -- un pedido de cambio solo puede apuntar a una sesión propia
    and (target_session_id is null or target_session_id in (
      select s.id from public.sessions s
      where s.client_id in (select public.current_client_ids())
    ))
  );

-- quotes: solo lectura (los escribe la Edge Function) -------------------
create policy "quotes: la cocinera lee los suyos"
  on public.quotes for select to authenticated
  using (chef_id = (select public.current_chef_id()));

create policy "quotes: el cliente lee los de sus pedidos"
  on public.quotes for select to authenticated
  using (request_id in (
    select r.id from public.requests r
    where r.client_id in (select public.current_client_ids())
  ));

-- sessions: solo lectura (estados vía Edge Functions / webhooks) -------
create policy "sessions: la cocinera lee las suyas"
  on public.sessions for select to authenticated
  using (chef_id = (select public.current_chef_id()));

create policy "sessions: el cliente lee las suyas"
  on public.sessions for select to authenticated
  using (client_id in (select public.current_client_ids()));

-- session_menu --------------------------------------------------------
create policy "session_menu: la cocinera gestiona los suyos"
  on public.session_menu for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "session_menu: el cliente lee el de sus sesiones"
  on public.session_menu for select to authenticated
  using (session_id in (
    select s.id from public.sessions s
    where s.client_id in (select public.current_client_ids())
  ));

-- receipts ------------------------------------------------------------
create policy "receipts: la cocinera gestiona los suyos"
  on public.receipts for all to authenticated
  using (chef_id = (select public.current_chef_id()))
  with check (chef_id = (select public.current_chef_id()));

create policy "receipts: el cliente lee los de sus sesiones"
  on public.receipts for select to authenticated
  using (session_id in (
    select s.id from public.sessions s
    where s.client_id in (select public.current_client_ids())
  ));

-- payments ------------------------------------------------------------
create policy "payments: la cocinera lee los suyos"
  on public.payments for select to authenticated
  using (chef_id = (select public.current_chef_id()));

-- Único camino de escritura desde la app: efectivo o transferencia, pendiente.
-- Confirmarlo (pending → succeeded) y todo lo de Stripe es de la service role.
create policy "payments: la cocinera registra efectivo o transferencia pendiente"
  on public.payments for insert to authenticated
  with check (
    chef_id = (select public.current_chef_id())
    and provider in ('cash','transfer')
    and kind in ('cash','transfer')
    and status = 'pending'
  );

create policy "payments: el cliente lee los de sus sesiones"
  on public.payments for select to authenticated
  using (session_id in (
    select s.id from public.sessions s
    where s.client_id in (select public.current_client_ids())
  ));

-- prepared_portions (F2) ----------------------------------------------
create policy "prepared_portions: la cocinera lee las suyas"
  on public.prepared_portions for select to authenticated
  using (chef_id = (select public.current_chef_id()));

create policy "prepared_portions: la cocinera las crea"
  on public.prepared_portions for insert to authenticated
  with check (chef_id = (select public.current_chef_id()));

create policy "prepared_portions: el cliente lee las suyas"
  on public.prepared_portions for select to authenticated
  using (client_id in (select public.current_client_ids()));

-- columnas limitadas a count_left y discarded_at por privilegio
create policy "prepared_portions: el cliente descuenta o descarta las suyas"
  on public.prepared_portions for update to authenticated
  using (client_id in (select public.current_client_ids()))
  with check (client_id in (select public.current_client_ids()));

-- pantry_items (F2) ---------------------------------------------------
create policy "pantry_items: el cliente gestiona su despensa"
  on public.pantry_items for all to authenticated
  using (client_id in (select public.current_client_ids()))
  with check (client_id in (select public.current_client_ids()));

create policy "pantry_items: la cocinera lee la despensa compartida"
  on public.pantry_items for select to authenticated
  using (
    chef_id = (select public.current_chef_id())
    and exists (
      select 1 from public.clients cl
      where cl.id = pantry_items.client_id
        and cl.share_pantry
    )
  );

-- push_tokens ---------------------------------------------------------
create policy "push_tokens: el usuario gestiona los suyos"
  on public.push_tokens for all to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

-- notifications -------------------------------------------------------
create policy "notifications: el usuario lee las suyas"
  on public.notifications for select to authenticated
  using (profile_id = (select auth.uid()));
