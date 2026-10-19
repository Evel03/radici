-- =====================================================================
-- Mestolo · M1 · Esquema base (SPEC.md §4)
-- Extensiones, enums, tablas de Fase 1 y Fase 2, claves, checks e índices.
--
-- Convenciones:
--   * PK uuid con gen_random_uuid().
--   * Dinero en centavos (int) con check >= 0. Nunca numeric/float.
--   * Fechas de negocio en Europe/Rome; instantes en timestamptz.
--   * Toda tabla de negocio tiene chef_id. Las tablas hijas apuntan al padre
--     con FK compuestas (x_id, chef_id) → padre (id, chef_id): así la base
--     garantiza que el chef_id de una fila coincide con el de su padre y las
--     políticas RLS pueden filtrar por chef_id sin joins.
--   * Tablas de identidad/infraestructura (profiles, push_tokens,
--     notifications) cuelgan del usuario, no del chef: no llevan chef_id.
-- =====================================================================

-- btree_gist: necesario para mezclar "=" sobre uuid y "&&" sobre rangos en
-- la restricción de exclusión no_overlap.
create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------------------
-- Enums (SPEC §4)
-- ---------------------------------------------------------------------
create type public.user_role        as enum ('chef','client');
create type public.client_status    as enum ('prospect','trial','active','paused','churned');
create type public.pay_mode         as enum ('preauth','pay_after');
create type public.request_type     as enum ('week','extra','change');
create type public.request_status   as enum ('new','quoted','accepted','declined','rejected','expired','resolved');
create type public.session_status   as enum ('held','confirmed','shopping_done','cooked','paid','cancelled');
create type public.payment_kind     as enum ('preauth','capture','groceries_extra','charge','cash','transfer','refund');
create type public.payment_status   as enum ('requires_action','authorized','succeeded','canceled','failed','pending');
create type public.storage_loc      as enum ('fridge','freezer','pantry');
-- Los 14 alérgenos del Reg. UE 1169/2011
create type public.allergen         as enum ('gluten','crustaceans','eggs','fish','peanuts','soy','milk','nuts','celery','mustard','sesame','sulphites','lupin','molluscs');
create type public.diet             as enum ('vegetarian','vegan');

-- Valores que la spec escribe entre paréntesis en la tabla de columnas.
create type public.consent_kind     as enum ('health_data','privacy','marketing');
create type public.payment_provider as enum ('stripe','satispay','cash','transfer');
create type public.plan_freq        as enum ('weekly','biweekly');
create type public.exception_kind   as enum ('blocked');

-- ---------------------------------------------------------------------
-- Identidad
-- ---------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  role        public.user_role not null default 'client',
  full_name   text,
  phone       text,
  locale      text not null default 'it' check (locale in ('it','es','en')),
  created_at  timestamptz not null default now()
);
comment on table public.profiles is 'Un perfil por usuario de auth. El rol nunca lo elige el usuario: se crea como client y la cocinera se promueve con la service role.';

create table public.chefs (
  id            uuid primary key default gen_random_uuid(),
  -- restrict: borrar a la cocinera no puede ser un efecto colateral de borrar su usuario.
  profile_id    uuid not null unique references public.profiles (id) on delete restrict,
  display_name  text not null,
  service_area  text[] not null default '{}',
  whatsapp      text,
  created_at    timestamptz not null default now()
);

create table public.chef_settings (
  chef_id                  uuid primary key references public.chefs (id) on delete cascade,
  hourly_rate_cents        int not null default 2200 check (hourly_rate_cents >= 0),
  travel_fee_cents         int not null default 1200 check (travel_fee_cents >= 0),
  adult_portion_cents      int not null default 380  check (adult_portion_cents >= 0),
  kid_portion_cents        int not null default 250  check (kid_portion_cents >= 0),
  preauth_buffer_pct       int not null default 15   check (preauth_buffer_pct between 0 and 100),
  min_cook_minutes         int not null default 90   check (min_cook_minutes between 0 and 1440),
  shop_minutes             int not null default 45   check (shop_minutes >= 0),
  gap_minutes              int not null default 30   check (gap_minutes >= 0),
  slot_step_minutes        int not null default 30   check (slot_step_minutes > 0),
  booking_horizon_days     int not null default 14   check (booking_horizon_days > 0),
  min_notice_hours         int not null default 24   check (min_notice_hours >= 0),
  quote_hold_hours         int not null default 48   check (quote_hold_hours > 0),
  prospect_retention_days  int not null default 90   check (prospect_retention_days > 0),
  -- Propuesta de SPEC §5.7 (a definir por Evelyn): horas antes de la sesión → % de servicio y qué pasa con los insumos.
  cancellation_policy      jsonb not null default '{
    "draft": true,
    "tiers": [
      {"min_hours_before": 48, "service_pct": 0,   "groceries": "release"},
      {"min_hours_before": 12, "service_pct": 50,  "groceries": "release_if_not_bought"},
      {"min_hours_before": 0,  "service_pct": 100, "groceries": "charge_receipt"}
    ],
    "groceries_bought_means_full_charge": true
  }'::jsonb,
  updated_at               timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Disponibilidad
-- ---------------------------------------------------------------------
create table public.availability_rules (
  id          uuid primary key default gen_random_uuid(),
  chef_id     uuid not null references public.chefs (id) on delete cascade,
  -- 0 = domingo … 6 = sábado (misma convención que extract(dow) de Postgres)
  dow         smallint not null check (dow between 0 and 6),
  start_time  time not null,
  end_time    time not null,
  created_at  timestamptz not null default now(),
  constraint availability_rules_start_before_end check (start_time < end_time),
  unique (chef_id, dow, start_time)
);

create table public.availability_exceptions (
  id          uuid primary key default gen_random_uuid(),
  chef_id     uuid not null references public.chefs (id) on delete cascade,
  date        date not null,
  kind        public.exception_kind not null default 'blocked',
  note        text,
  created_at  timestamptz not null default now(),
  unique (chef_id, date, kind)
);

-- ---------------------------------------------------------------------
-- Clientes (incluye prospectos sin cuenta)
-- ---------------------------------------------------------------------
create table public.clients (
  id                         uuid primary key default gen_random_uuid(),
  -- restrict: un cliente con historia no desaparece por borrar a la cocinera.
  chef_id                    uuid not null references public.chefs (id) on delete restrict,
  -- null = prospecto sin cuenta. set null: si se borra el usuario, la ficha
  -- queda desvinculada (el borrado RGPD completo lo hace la Edge Function de M2).
  profile_id                 uuid references public.profiles (id) on delete set null,
  display_name               text not null,
  contact_email              text,
  contact_phone              text,
  zone                       text,
  address                    text,
  adults                     smallint not null default 1 check (adults >= 0),
  kids                       smallint not null default 0 check (kids >= 0),
  preferences                text,
  kitchen_notes              text,
  pay_mode                   public.pay_mode not null default 'preauth',
  status                     public.client_status not null default 'prospect',
  share_pantry               boolean not null default false,
  stripe_customer_id         text unique,
  default_payment_method_id  text,
  since                      date not null default current_date,
  created_at                 timestamptz not null default now(),
  -- destino de las FK compuestas (client_id, chef_id)
  unique (id, chef_id),
  unique (chef_id, profile_id),
  -- un prospecto es, por definición, una persona sin cuenta (SPEC §1 Roles)
  constraint clients_prospect_sin_cuenta check (status <> 'prospect' or profile_id is null)
);
create index clients_profile_idx on public.clients (profile_id) where profile_id is not null;

-- Una fila por restricción: o un alérgeno o una dieta, nunca ambos.
-- Sin consentimiento health_data vigente no se pueden guardar (trigger en la migración de helpers).
create table public.client_restrictions (
  id          uuid primary key default gen_random_uuid(),
  chef_id     uuid not null,
  client_id   uuid not null,
  allergen    public.allergen,
  diet        public.diet,
  created_at  timestamptz not null default now(),
  foreign key (client_id, chef_id) references public.clients (id, chef_id) on delete cascade,
  constraint client_restrictions_una_sola check (num_nonnulls(allergen, diet) = 1),
  -- nulls not distinct: (cliente, milk, null) no se repite; también cubre las búsquedas por client_id
  constraint client_restrictions_unica unique nulls not distinct (client_id, allergen, diet)
);

create table public.consents (
  id            uuid primary key default gen_random_uuid(),
  chef_id       uuid not null,
  client_id     uuid not null,
  kind          public.consent_kind not null,
  text_version  text not null,
  granted_at    timestamptz not null default now(),
  revoked_at    timestamptz,
  foreign key (client_id, chef_id) references public.clients (id, chef_id) on delete cascade,
  constraint consents_revoked_after_granted check (revoked_at is null or revoked_at >= granted_at)
);
-- Como máximo un consentimiento vigente por tipo y cliente.
create unique index consents_one_active_per_kind on public.consents (client_id, kind) where revoked_at is null;
create index consents_client_idx on public.consents (client_id);

-- ---------------------------------------------------------------------
-- Recetario
-- ---------------------------------------------------------------------
create table public.recipes (
  id            uuid primary key default gen_random_uuid(),
  chef_id       uuid not null references public.chefs (id) on delete cascade,
  name_it       text not null,
  name_es       text,
  fridge_days   smallint not null default 3 check (fridge_days >= 0),
  freezable     boolean not null default false,
  freezer_days  smallint not null default 60 check (freezer_days > 0),
  diet          public.diet,
  notes         text,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (id, chef_id)
);
create index recipes_chef_idx on public.recipes (chef_id);

create table public.recipe_allergens (
  recipe_id  uuid not null,
  chef_id    uuid not null,
  allergen   public.allergen not null,
  primary key (recipe_id, allergen),
  foreign key (recipe_id, chef_id) references public.recipes (id, chef_id) on delete cascade
);

-- ---------------------------------------------------------------------
-- Planes recurrentes (F2)
-- ---------------------------------------------------------------------
create table public.recurring_plans (
  id          uuid primary key default gen_random_uuid(),
  chef_id     uuid not null,
  client_id   uuid not null,
  freq        public.plan_freq not null,
  dow         smallint not null check (dow between 0 and 6),
  start_time  time not null,
  days        smallint not null check (days between 1 and 7),   -- igual que LIMITS.maxDays de quote.ts
  meals       text[] not null check (cardinality(meals) between 1 and 2 and meals <@ array['lunch','dinner']),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  foreign key (client_id, chef_id) references public.clients (id, chef_id) on delete cascade
);
create index recurring_plans_client_idx on public.recurring_plans (client_id);

-- ---------------------------------------------------------------------
-- Pedidos, sesiones y presupuestos
-- (referencias circulares: las FK que cierran el ciclo se agregan al final)
-- ---------------------------------------------------------------------
create table public.requests (
  id                 uuid primary key default gen_random_uuid(),
  chef_id            uuid not null,
  client_id          uuid not null,          -- siempre, también para prospectos
  type               public.request_type not null,
  status             public.request_status not null default 'new',
  adults             smallint check (adults >= 0),
  kids               smallint check (kids >= 0),
  days               smallint check (days between 1 and 7),
  meals              text[] check (meals is null or (cardinality(meals) between 1 and 2 and meals <@ array['lunch','dinner'])),
  -- Copia de las restricciones al momento del pedido: es dato de salud
  -- (se exporta y se borra con la cuenta, SPEC §6).
  restrictions       jsonb,
  wishes             uuid[] not null default '{}',   -- ids de recetas deseadas
  notes              text,
  preferred_date     date,
  preferred_start    time,
  pay_mode           public.pay_mode,
  target_session_id  uuid,                   -- solo para type = 'change'
  text               text,                   -- descripción del cambio (type = 'change')
  created_at         timestamptz not null default now(),
  unique (id, chef_id),
  foreign key (client_id, chef_id) references public.clients (id, chef_id) on delete cascade,
  -- semana o extra: personas, días y comidas obligatorios (mismas reglas que validateInput de quote.ts)
  constraint requests_datos_de_presupuesto check (
    type = 'change'
    or (adults is not null and kids is not null and adults + kids >= 1 and days is not null and meals is not null)
  ),
  constraint requests_change_con_texto check (type <> 'change' or text is not null),
  constraint requests_target_solo_change check (target_session_id is null or type = 'change'),
  constraint requests_resolved_solo_change check (status <> 'resolved' or type = 'change')
);
create index requests_chef_status_idx on public.requests (chef_id, status, created_at desc);
create index requests_client_idx on public.requests (client_id);
create index requests_target_session_idx on public.requests (target_session_id) where target_session_id is not null;

create table public.sessions (
  id                      uuid primary key default gen_random_uuid(),
  chef_id                 uuid not null,
  client_id               uuid not null,
  request_id              uuid,
  quote_id                uuid,
  date                    date not null,      -- día en Europe/Rome
  start_time              time not null,      -- hora de llegada a la casa (Europe/Rome); la compra ocurre antes
  cook_minutes            int not null check (cook_minutes > 0),
  -- Minutos copiados de chef_settings al crear la sesión (trigger sessions_fill_minutes):
  -- si después cambian las tarifas, las sesiones existentes no se mueven.
  shop_minutes            int not null check (shop_minutes >= 0),
  gap_minutes             int not null check (gap_minutes >= 0),
  portions                int not null default 0 check (portions >= 0),
  status                  public.session_status not null default 'held',
  hold_until              timestamptz,        -- solo para held
  pay_mode                public.pay_mode not null default 'preauth',
  service_cents           int not null default 0 check (service_cents >= 0),
  groceries_est_cents     int not null default 0 check (groceries_est_cents >= 0),
  preauth_cents           int not null default 0 check (preauth_cents >= 0),
  groceries_actual_cents  int check (groceries_actual_cents >= 0),
  service_paid_at         timestamptz,
  groceries_paid_at       timestamptz,
  cancelled_at            timestamptz,
  cancel_reason           text,               -- p. ej. 'hold_expired' | 'declined'
  created_at              timestamptz not null default now(),
  -- busy = [inicio − compra, fin de cocina + margen)  (SPEC §4 y §5.2)
  -- El margen va de UN solo lado (después de cocinar). Con rangos semiabiertos
  -- dos sesiones chocan si a_ini < b_fin + margen y b_ini < a_fin + margen.
  --
  -- Inmutabilidad (requisito de columna generada):
  --   timestamptz ± interval es STABLE (depende del TimeZone de la sesión), así
  --   que no se puede usar. Se hace la aritmética en timestamp sin zona en UTC:
  --     (date + start_time)                 timestamp local      datetime_pl            IMMUTABLE
  --     … at time zone 'Europe/Rome'        → timestamptz        timezone(text,ts)      IMMUTABLE
  --     … at time zone 'UTC'                → timestamp UTC      timezone(text,tstz)    IMMUTABLE
  --     ± make_interval(mins => …)          minutos absolutos    timestamp_pl/mi_interval, make_interval IMMUTABLE
  --     … at time zone 'UTC'                → timestamptz        timezone(text,ts)      IMMUTABLE
  --     tstzrange(…, …, '[)')                                    IMMUTABLE
  --   Sumar en UTC hace la cuenta en minutos reales aunque la sesión cruce un
  --   cambio de hora (no pasa en horario laboral, pero queda exacto).
  busy tstzrange generated always as (
    tstzrange(
      (((("date" + start_time) at time zone 'Europe/Rome') at time zone 'UTC')
         - make_interval(mins => shop_minutes)) at time zone 'UTC',
      (((("date" + start_time) at time zone 'Europe/Rome') at time zone 'UTC')
         + make_interval(mins => cook_minutes + gap_minutes)) at time zone 'UTC',
      '[)'
    )
  ) stored,
  unique (id, chef_id),
  unique (id, client_id, chef_id),   -- destino de la FK de prepared_portions
  foreign key (client_id, chef_id) references public.clients (id, chef_id) on delete cascade,
  foreign key (request_id, chef_id) references public.requests (id, chef_id) on delete set null (request_id),
  -- held ⇔ hold_until: el presupuesto enviado reserva el horario hasta hold_until
  constraint sessions_hold_until_solo_held check ((status = 'held') = (hold_until is not null)),
  constraint sessions_cancelled_con_fecha check (status <> 'cancelled' or cancelled_at is not null),
  -- Anti doble reserva (SPEC §4). Las held bloquean igual que las confirmadas.
  constraint no_overlap exclude using gist (chef_id with =, busy with &&) where (status <> 'cancelled')
);
create index sessions_chef_date_idx on public.sessions (chef_id, date);
create index sessions_client_date_idx on public.sessions (client_id, date);
create index sessions_request_idx on public.sessions (request_id) where request_id is not null;
create index sessions_quote_idx on public.sessions (quote_id) where quote_id is not null;
-- para el cron que vence presupuestos
create index sessions_held_until_idx on public.sessions (hold_until) where status = 'held';

create table public.quotes (
  id                   uuid primary key default gen_random_uuid(),
  chef_id              uuid not null,
  request_id           uuid not null,
  session_id           uuid,               -- la sesión held que reserva el horario
  version              smallint not null default 1 check (version >= 1),
  menu                 uuid[] not null default '{}',   -- ids de recetas
  cook_minutes         int not null check (cook_minutes > 0),
  portions             int not null check (portions >= 0),
  service_cents        int not null check (service_cents >= 0),
  groceries_est_cents  int not null check (groceries_est_cents >= 0),
  preauth_cents        int not null check (preauth_cents >= 0),
  -- tarifas y resultado al enviar (+ motivo de ajuste manual). Puede copiar restricciones: dato de salud.
  pricing_snapshot     jsonb not null default '{}',
  allergen_override    text,               -- confirmación explícita de Evelyn ante un conflicto (SPEC §5.6)
  slot_date            date,
  slot_start           time,
  hold_until           timestamptz,
  sent_at              timestamptz,
  accepted_at          timestamptz,
  created_at           timestamptz not null default now(),
  unique (id, chef_id),
  unique (request_id, version),
  foreign key (request_id, chef_id) references public.requests (id, chef_id) on delete cascade,
  foreign key (session_id, chef_id) references public.sessions (id, chef_id) on delete set null (session_id),
  constraint quotes_aceptado_tras_envio check (accepted_at is null or sent_at is not null),
  constraint quotes_enviado_con_horario check (sent_at is null or (slot_date is not null and slot_start is not null and hold_until is not null))
);
create index quotes_session_idx on public.quotes (session_id) where session_id is not null;

-- Cierre de las referencias circulares
alter table public.sessions
  add foreign key (quote_id, chef_id) references public.quotes (id, chef_id) on delete set null (quote_id);
alter table public.requests
  add foreign key (target_session_id, chef_id) references public.sessions (id, chef_id) on delete set null (target_session_id);

create table public.session_menu (
  session_id  uuid not null,
  recipe_id   uuid not null,
  chef_id     uuid not null,
  portions    int not null check (portions > 0),
  primary key (session_id, recipe_id),
  foreign key (session_id, chef_id) references public.sessions (id, chef_id) on delete cascade,
  -- restrict: las recetas usadas se desactivan (active = false), no se borran
  foreign key (recipe_id, chef_id) references public.recipes (id, chef_id) on delete restrict
);
create index session_menu_recipe_idx on public.session_menu (recipe_id);

create table public.receipts (
  id            uuid primary key default gen_random_uuid(),
  chef_id       uuid not null,
  session_id    uuid not null,
  -- ruta dentro del bucket privado 'receipts': {chef_id}/{session_id}/{archivo}
  storage_path  text not null unique,
  total_cents   int not null check (total_cents >= 0),
  store_name    text,
  purchased_at  timestamptz,
  uploaded_by   uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  foreign key (session_id, chef_id) references public.sessions (id, chef_id) on delete cascade,
  constraint receipts_path_en_carpeta_del_chef check (split_part(storage_path, '/', 1) = chef_id::text)
);
create index receipts_session_idx on public.receipts (session_id);

create table public.payments (
  id                        uuid primary key default gen_random_uuid(),
  chef_id                   uuid not null,
  session_id                uuid not null,
  kind                      public.payment_kind not null,
  provider                  public.payment_provider not null,
  stripe_payment_intent_id  text,
  amount_cents              int not null check (amount_cents >= 0),
  captured_cents            int not null default 0 check (captured_cents >= 0),
  -- reparto para documentar servicio e insumos por separado aunque viajen en un mismo cobro (art. 15)
  service_part_cents        int not null default 0 check (service_part_cents >= 0),
  groceries_part_cents      int not null default 0 check (groceries_part_cents >= 0),
  status                    public.payment_status not null default 'pending',
  idempotency_key           text not null unique default gen_random_uuid()::text,
  last_error                text,
  created_at                timestamptz not null default now(),
  -- restrict: un pago es un registro contable; impide borrar la sesión (y, en cascada, el cliente)
  foreign key (session_id, chef_id) references public.sessions (id, chef_id) on delete restrict,
  constraint payments_reparto_no_supera_monto check (service_part_cents + groceries_part_cents <= amount_cents),
  constraint payments_captura_no_supera_monto check (captured_cents <= amount_cents),
  constraint payments_kind_manual_coincide check (kind not in ('cash','transfer') or provider::text = kind::text),
  constraint payments_pi_solo_stripe check (stripe_payment_intent_id is null or provider = 'stripe')
);
create index payments_session_idx on public.payments (session_id);
create index payments_chef_created_idx on public.payments (chef_id, created_at desc);
create index payments_pi_idx on public.payments (stripe_payment_intent_id) where stripe_payment_intent_id is not null;

-- ---------------------------------------------------------------------
-- Porciones y despensa (F2)
-- ---------------------------------------------------------------------
create table public.prepared_portions (
  id             uuid primary key default gen_random_uuid(),
  chef_id        uuid not null,
  client_id      uuid not null,
  session_id     uuid not null,
  recipe_id      uuid not null,
  count_initial  int not null check (count_initial > 0),
  count_left     int not null check (count_left >= 0),
  location       public.storage_loc not null default 'fridge',
  made_on        date not null,
  consume_by     date not null,
  discarded_at   timestamptz,
  created_at     timestamptz not null default now(),
  -- la sesión tiene que ser de ese mismo cliente y chef
  foreign key (session_id, client_id, chef_id) references public.sessions (id, client_id, chef_id) on delete cascade,
  foreign key (recipe_id, chef_id) references public.recipes (id, chef_id) on delete restrict,
  constraint prepared_portions_count_left_max check (count_left <= count_initial),
  constraint prepared_portions_consume_by check (consume_by >= made_on)
);
create index prepared_portions_client_idx on public.prepared_portions (client_id, consume_by);
create index prepared_portions_session_idx on public.prepared_portions (session_id);

create table public.pantry_items (
  id           uuid primary key default gen_random_uuid(),
  chef_id      uuid not null,
  client_id    uuid not null,
  name         text not null,
  qty_text     text,
  location     public.storage_loc not null default 'pantry',
  expires_on   date,
  added_by     uuid default auth.uid() references public.profiles (id) on delete set null,
  consumed_at  timestamptz,
  created_at   timestamptz not null default now(),
  foreign key (client_id, chef_id) references public.clients (id, chef_id) on delete cascade
);
create index pantry_items_client_idx on public.pantry_items (client_id, expires_on);

-- ---------------------------------------------------------------------
-- Notificaciones
-- ---------------------------------------------------------------------
create table public.push_tokens (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references public.profiles (id) on delete cascade,
  token       text not null unique,
  platform    text not null check (platform in ('ios','android','web')),
  created_at  timestamptz not null default now()
);
create index push_tokens_profile_idx on public.push_tokens (profile_id);

-- payload nunca lleva restricciones, alergias ni direcciones (SPEC §6)
create table public.notifications (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null references public.profiles (id) on delete cascade,
  kind           text not null,
  payload        jsonb not null default '{}',
  channel        text not null check (channel in ('push','email')),
  scheduled_for  timestamptz not null default now(),
  sent_at        timestamptz,
  created_at     timestamptz not null default now()
);
create index notifications_profile_idx on public.notifications (profile_id, created_at desc);
create index notifications_pending_idx on public.notifications (scheduled_for) where sent_at is null;
