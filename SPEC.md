# Radici — Especificación para construir con Claude Code

> **Radici** es el nombre definitivo (ex Mestolo, el provisorio). Repo: `github.com/Evel03/radici`. Dominio: `radicicucina.app` (web pública y bandeja en `/gestione/`). Falta elegir el identificador nativo de la app (sección 14).
>
> **Prototipo de referencia:** `docs/prototipo.html` (también publicado en https://claude.ai/artifact/E5zsqMUGziiWUr2N1BDmsw; pendiente de copiar al repo). Es la referencia visual. Las reglas de negocio de **este documento** prevalecen sobre el prototipo: la fórmula de presupuesto y el margen entre sesiones se corrigieron en la revisión del 19/10/2026, y el 15 y 16/11/2026 el servicio pasó a tener un precio por semana (5.1).
>
> **Especificación de la app (15/11/2026):** el dueño mandó una especificación de la app con área de clientes y tablero de administración. Está integrada en este documento con sus decisiones del mismo día: D1, a las 9:00 empieza la compra (5.2; desde el 19/11/2026 no hay compra); D2, eventos privados con sección y formulario propios (5.3); D3, registro abierto desde M2 (§1 y §6); D4, el cliente solo sugiere platos y el menú lo decide Evelyn (5.1). Lo que quedó sin decidir (D5–D7 y otras) está en la sección 14. La copia original, sin cambios, está en [`docs/especificaciones/2026-11-15-especificacion-app.md`](docs/especificaciones/2026-11-15-especificacion-app.md): es historia y, si difiere de este documento, manda este documento.
>
> **Sin compra (19/11/2026, comentarios de Evelyn):** Evelyn no hace la compra. La hace el cliente, con la lista de ingredientes que ella le manda antes de cada sesión (sale del menú y de las porciones: §4, «Catálogo de platos»). Se van la compra estimada, la pre-autorización de insumos, el ticket y su reembolso, y la primera llegada pasa a las 9:00 (5.2). Lo que la base tiene de la compra queda sin uso (§4, «Sin compra»).

---

## 0. Cómo usar este documento

Estructura del repo:

```
SPEC.md · CLAUDE.md
app/                          Flutter (iOS, Android): app de Evelyn y de clientes
web/                          Web pública estática (Vite + TypeScript): landing, pedido, seguimiento
supabase/migrations/          Esquema, RLS, funciones SQL
supabase/tests/database/      Tests pgTAP (RLS, no_overlap)
supabase/functions/           Edge Functions (Deno/TS)
supabase/functions/_shared/   Lógica compartida: quote.ts + quote_vectors.json (web, Edge Functions y tests de Dart)
docs/                         Prototipo, contratos (contracts/) y especificaciones recibidas (especificaciones/, solo historia)
```

Avanzá por fases y milestones (secciones 2 y 10). Un milestone = un PR con tests en verde. Reglas: dinero en centavos (int), fechas en Europe/Rome, tests primero para presupuesto, disponibilidad y pagos.

---

## 1. Producto

### Problema
Familias y profesionales de Bergamo sin tiempo ni conocimiento de cocina terminan pidiendo delivery o comiendo mal, también los chicos.

### Propuesta
Evelyn cocina **en la casa del cliente**: cocina para varios días y deja todo en porciones etiquetadas con plato y fecha. La compra la hace el cliente, con la lista de ingredientes y cantidades que Evelyn le manda antes de cada sesión, así que el cliente paga solo el **servicio** (decisión del 19/11/2026; antes Evelyn compraba y cobraba los insumos por el ticket).

### Líneas de servicio
Una sola marca, **Radici · Cucina privata**, con dos líneas. Los nombres son provisorios (sección 14): van en los textos de i18n, nunca en el código.
- **Servicio semanal** («Radici Quotidiano»): la propuesta de arriba, de 1 a 8 semanas con un menú y una sesión por semana. Precio por semana estimado con 5.1 (sin precio automático para más de 5 personas) y día elegido en el calendario de disponibilidad (5.2), el mismo en cada semana. El menú lo decide Evelyn: en el formulario de la web el cliente puede elegir hasta un plato por día de los publicados en el catálogo (opcional, desde el 19/11/2026: §4, «Menú de la web»), y el cliente activo puede sugerir platos (M2b).
- **Cenas privadas y eventos** («Radici Privato»): sección y formulario propios, menú a medida y presupuesto que Evelyn pasa después de hablar con el cliente, sin precio automático (5.3).

### Roles
| Rol | Quién | Qué hace |
|---|---|---|
| `chef` | Evelyn (y en el futuro otra cocinera) | Responde pedidos y eventos, arma menú y presupuesto, gestiona agenda, disponibilidad, catálogo de platos, listas de compras para los clientes y cobros |
| colaborador | Cuenta de confianza que trabaja en la cocina de Evelyn (desde el 16/11/2026, para el dueño del proyecto); rol `chef` de `profiles` | Entra a su área (`/gestione/` y la app) con su propio email y código y ve y hace lo mismo que ella, salvo editar la ficha pública de la cocinera (nombre, zona, WhatsApp). Nunca agrega ni saca colaboradores: la lista la define el despliegue (§6). No es otra cocinera: la ficha de `chefs` sigue siendo una sola |
| `client` | Persona con cuenta (rol de `profiles`; desde M2 el registro es abierto) | Lo que permite el estado de su ficha (abajo): pide presupuestos, los acepta, pre-autoriza o paga, sugiere platos, ve porciones y despensa |
| sin cuenta | Persona que pide desde la web | Pide presupuesto o un evento desde un enlace público, sin registrarse; queda como ficha `prospect` |

### Estados del cliente
La ficha (`clients.status`, una por cocinera) se muestra con dos estados (decisión del 15/11/2026):
- **Prospecto** (`prospect`): pidió desde la web o, desde M2, se registró y todavía no es cliente. Con cuenta ve su perfil y sus pedidos y puede pedir presupuesto; no ve el catálogo de platos ni sugiere (los platos publicados del menú de la web los ve cualquiera en el formulario, §4).
- **Cliente activo** (`trial` o `active`): además ve el catálogo de temporada y sugiere platos. Pasa a este estado al aceptar su primer presupuesto (lo hace el servidor, M4), cuando Evelyn le confirma una reserva (5.3) o cuando Evelyn toca «Segna come cliente».

`paused` y `churned` siguen en el enum y no cuentan como activos. El estado lo cambian la cocinera o el servidor, nunca el cliente.

### Principios
- **Cero riesgo de impago para Evelyn** cuando el cliente elige pre-autorización.
- **Sin anticipos**: Evelyn no compra con su dinero; el cliente compra con la lista que ella le manda (19/11/2026).
- **Mobile first**, y el cliente nuevo puede pedir desde un link de WhatsApp sin instalar nada.
- **Italiano por defecto** (clientes de Bergamo); español e inglés como segundo y tercer idioma.
- Datos de alergias = datos de salud: mínimos, con consentimiento explícito y solo visibles para la cocinera y, si los hay, sus colaboradores (sección 6).

---

## 2. Alcance por fases

### Fase 0 — Validación (web liviana, sin app)
- Web pública en italiano (`web/`): cómo funciona, calculadora de presupuesto (misma fórmula 5.1, mismo `quote.ts`) y formulario de pedido con la pregunta de alergias: el cliente confirma que nadie de quienes van a comer (niños incluidos) tiene alergias, intolerancias ni celiaquía, o las escribe con su consentimiento de datos de salud.
- El pedido se guarda en Supabase (Edge Function `public-request`, contrato `docs/contracts/public-request.md`, aprobado el 19/10/2026; reemplaza el envío por WhatsApp). Evelyn recibe un email y un aviso emergente en la app, y lo revisa en la bandeja y la agenda (app y `/gestione/`); el cliente recibe la confirmación por email y, si la pidió, por WhatsApp. El cliente no necesita cuenta.
- Eventos privados con sección y formulario propios (M3b, después del PR del formulario con calendario y alergias), sin precio automático (5.3). Hasta entonces la web los pide como `extra` («Evento o sessione extra»).
- Disponibilidad desde la app (M5a): Evelyn bloquea días y edita su horario semanal. Los bloqueos quedan para las ausencias (vacaciones, feriados): las sesiones acordadas por WhatsApp se cargan como reservas.
- **Reservas** (área de Evelyn; decisiones del dueño del 16/11/2026): Evelyn confirma desde un pedido, o carga a mano, una reserva de 1 a 8 semanas con una sesión de cocina por semana. Confirmarla crea sus sesiones y el calendario de la web descuenta esos días solo (5.2). El precio del servicio lo fija Evelyn al confirmar (la web estima 150 € por semana, 140 € desde 4 semanas, hasta 5 personas); la compra la hace el cliente y el cobro es manual. Hasta M4 se confirman sin presupuesto ni retención (5.3).
- Pendiente de la web que pide la especificación de la app: quitar `noindex` (`VITE_NOINDEX=false`) recién al compartir el sitio (contrato §10.1, paso 12). El texto alternativo de las fotos ya está, en los textos i18n. El contacto directo es la decisión abierta D7.
- Cobro manual: efectivo, transferencia, Satispay o Stripe Payment Links.
- Meta: 10–20 sesiones reales para calibrar tiempos de cocina, costo por porción y política de cancelación **antes** de congelarlos en los vectores.
- En paralelo se construyen M0 y M1. La parte de `public-request` de M3 (formulario conectado al backend) se adelantó a esta fase.

### Fase 1 — MVP (lo que valida el negocio)
- Registro abierto e inicio de sesión con código por email (M2): cualquiera crea su cuenta de cliente, con Turnstile contra el spam; el perfil se crea solo y la ficha empieza como prospecto (§1, §6).
- Perfil del hogar: adultos, niños, zona, dirección, restricciones, preferencias, notas de cocina.
- **Pedir**: semana de comidas, sesión extra o cambio en la próxima sesión. Los eventos privados tienen formulario propio (5.3).
- **Presupuesto estimado instantáneo** al pedir (fórmula 5.1) y horarios libres reales (5.2); los eventos, sin precio automático.
- Formulario público para clientes nuevos (web), con la pregunta de alergias (desde el 15/11/2026): confirmar que nadie tiene o escribirlas, con consentimiento de datos de salud.
- **Bandeja de pedidos** de Evelyn: armar menú con control de alérgenos, ajustar precio, enviar presupuesto.
- **Catálogo de platos** de Evelyn (M4a): unos 20 platos con alérgenos, temporada, nombre en it/es/en e ingredientes con su cantidad para 4 porciones (de ahí sale la lista de compras que Evelyn le manda al cliente); alta, duplicar, baja (desactivar) y rotación por temporada.
- **Sugerencias del menú semanal** (M2b): el cliente activo marca, sin cantidad fija, platos del catálogo de temporada que le gustan y puede pedir cambios o platos especiales en un campo libre; Evelyn decide y arma el menú (5.1, 5.6).
- Aceptación del presupuesto → sesión agendada (con protección contra doble reserva).
- **Agenda** (semana + día con línea de tiempo, con sesiones y eventos). La **disponibilidad** semanal y el **bloqueo de días** llegan antes, con M5a (Fase 0).
- **Pagos con Stripe**: pre-autorización del servicio, captura al cocinar, pago al final; registro manual de efectivo o transferencia.
- **Hoy**, el inicio de Evelyn: la sesión del día, pendientes accionables en uno o dos toques y panel con ingreso por servicio, por cobrar, retenido y ocupación de los próximos 7 días (§7).
- Notificaciones push y email básicas (sección 8).

### Fase 2 — Retención
- **Porciones en la heladera**: etiquetas digitales por plato con fecha de elaboración y "consumir antes de", contador de porciones, aviso el día antes.
- **Despensa compartida**: ingredientes con vencimiento cargados por el cliente; Evelyn ve "usar primero" al armar el menú.
- **Planes recurrentes** (semanal / cada 2 semanas) que generan la próxima sesión automáticamente. Con ellos se decide el plazo para sugerir platos y qué pasa si el cliente no sugiere (D5, sección 14).
- Recetario completo: tiempos de conservación de cada plato para las porciones (el catálogo con los 14 alérgenos UE, la temporada y los ingredientes se adelanta a la Fase 1, M4a).

### Fase 3 — Escala y administración
- Facturación electrónica (API tipo Fatture in Cloud o Aruba → SDI). Decidir con el commercialista.
- Lista de compras automática a partir de las recetas del menú: se adelanta al área de Evelyn, antes de M2, y además se puede editar (decisión del dueño del 16/11/2026; §4, «Catálogo de platos»). Desde el 19/11/2026 es la lista que Evelyn le manda al cliente, que hace la compra.
- Carga de despensa por código de barras u OCR del ticket.
- Etiquetas imprimibles con QR para los tápers.
- Satispay como medio de pago al final (evaluar si su API sirve para este flujo).
- Tiempos de traslado por zona en el cálculo de horarios.
- Multi-cocinera (el modelo de datos ya lo soporta con `chef_id`).

### Fuera de alcance
Marketplace abierto de cocineros, delivery, chat propio (usar enlace a WhatsApp `wa.me`).

---

## 3. Stack

Se reutiliza lo que ya conocés de Se Puso La 10, sin servidor propio.

| Capa | Elección | Por qué |
|---|---|---|
| App | **Flutter 3.x** (iOS y Android) | Evelyn y clientes recurrentes |
| Web pública | **Vite + TypeScript estático** (hosting estático en Cloudflare Pages, en el dominio propio `radicicucina.app`) | Carga instantánea desde el navegador de WhatsApp, posiciona en Google, reutiliza `_shared/quote.ts` |
| Estado / navegación | Riverpod + go_router | Estándar, testeable |
| Modelos | freezed + json_serializable | Inmutables, menos errores |
| Backend | **Supabase** (región UE, Frankfurt) | Postgres, Auth, RLS, Storage, Edge Functions, pg_cron |
| Lógica de servidor | **Supabase Edge Functions** (Deno/TypeScript) | Webhooks de Stripe y tareas programadas sin mantener Render |
| Pagos | **Stripe** (PaymentIntents con captura manual, SetupIntent, Customers, webhooks). En la web: Stripe Checkout `mode=setup` | Pre-autorización y captura parcial; SCA europeo resuelto. `flutter_stripe` en web es experimental |
| Push | Firebase Cloud Messaging, enviado desde Edge Function | |
| Email | **Resend** | Transaccional (avisos y confirmaciones) y SMTP del código de acceso |
| Traducción de los platos y de la lista de compras | **Claude** (API de Anthropic, SDK oficial), desde la Edge Function `chef` | Evelyn escribe en español; el italiano y el inglés de los platos salen solos (20/11/2026, §4), y los renglones de la lista de compras de cada semana se traducen al idioma de la clienta al mandarle el menú (22/11/2026, §5.8). Solo recibe el plato y los nombres de la lista, nunca datos personales ni la nota de la semana (§6) |
| i18n | App: `flutter_localizations` + ARB. Web: un JSON por idioma. `it` por defecto, `es`, `en` | |
| Errores | Sentry | |
| CI | GitHub Actions: `flutter analyze`, `flutter test`, tests de base de datos | |

**Web pública:** Flutter web es pesado para la primera carga y no posiciona; el cliente nuevo llega desde un link de WhatsApp en el celular. Por eso la web pública (landing, `/richiesta`, seguimiento y aceptación del presupuesto) es estática y aparte. Flutter web solo se usa para la bandeja de Evelyn en `/gestione/` (la misma app, publicada dentro del sitio; contrato public-request §7).

**Analítica:** sin Google Analytics (Garante). Si hace falta, una sin cookies (Plausible, Umami): así no se necesita banner de cookies.

---

## 4. Modelo de datos (Postgres)

Convenciones: `uuid` como PK, dinero en **centavos `int`**, fechas `date`, horas `time`, timestamps `timestamptz`, zona horaria de negocio `Europe/Rome`. Todas las tablas de negocio tienen `chef_id` (aunque hoy haya una sola cocinera: evita una migración dolorosa después).

```sql
-- enums
create type user_role       as enum ('chef','client');
create type client_status   as enum ('prospect','trial','active','paused','churned');
create type pay_mode        as enum ('preauth','pay_after','manual');  -- manual: las sesiones que crea Evelyn (reservas), cobro a mano
create type request_type    as enum ('week','extra','change');  -- M3b suma 'event' (5.3)
create type request_status  as enum ('new','quoted','accepted','declined','rejected','expired','resolved');
create type session_status  as enum ('held','confirmed','shopping_done','cooked','paid','cancelled');  -- shopping_done, sin uso desde el 19/11/2026 (sin compra)
create type payment_kind    as enum ('preauth','capture','groceries_extra','charge','cash','transfer','refund');  -- groceries_extra, sin uso desde el 19/11/2026
create type payment_status  as enum ('requires_action','authorized','succeeded','canceled','failed','pending');
create type storage_loc     as enum ('fridge','freezer','pantry');
create type allergen        as enum ('gluten','crustaceans','eggs','fish','peanuts','soy','milk','nuts','celery','mustard','sesame','sulphites','lupin','molluscs'); -- 14 del Reg. UE 1169/2011
create type diet            as enum ('vegetarian','vegan');
create type shopping_section as enum ('produce','meat_fish','dairy_eggs','bakery','pantry','frozen','other'); -- sección del súper, en el orden del recorrido (M4a)
create type ingredient_unit  as enum ('g','ml','pcs');  -- unidad de la cantidad de un ingrediente (M4a)
```

| Tabla | Columnas principales |
|---|---|
| `chefs` | id, profile_id, display_name, service_area text[], whatsapp |
| `chef_members` | profile_id (clave: una cuenta es colaboradora de una sola cocina), chef_id, created_at. Colaboradores de la cocinera (migración `20261116190000_chef_members.sql`): una cuenta es dueña (`chefs.profile_id`) o colaboradora, nunca las dos (guardas en las dos tablas, también para la service role). La escribe solo el despliegue (`private.sync_chef_members`); la app no la lee ni la escribe |
| `profiles` | id (= auth.users.id), role, full_name, phone, locale, created_at |
| `chef_settings` | chef_id PK, hourly_rate_cents (2200) y travel_fee_cents (1200) (ya no entran en la estimación: 5.1), adult_portion_cents (380), kid_portion_cents (250) y preauth_buffer_pct (15) (sin uso desde el 19/11/2026: eran de la compra estimada), min_cook_minutes (90), shop_minutes (0; 45 hasta el 19/11/2026, migración `20261119090000_sin_compra.sql`), gap_minutes (30), slot_step_minutes (30), booking_horizon_days (56), min_notice_hours (24), quote_hold_hours (48), prospect_retention_days (90), cancellation_policy jsonb; precio por semana (migración `20261116120000_weekly_pricing.sql`): weekly_rate_cents (15000), weekly_rate_discounted_cents (14000), weekly_discount_min_weeks (4), weekly_rate_max_people (5) |
| `availability_rules` | id, chef_id, dow (0–6), start_time, end_time |
| `availability_exceptions` | id, chef_id, date, kind ('blocked'), note |
| `clients` | id, chef_id, profile_id null (null = sin cuenta; hasta M2 un prospecto nunca tiene cuenta, desde M2 puede tenerla: §6), display_name, contact_email, contact_phone, zone, address, adults, kids, preferences, kitchen_notes, pay_mode, status, share_pantry bool, stripe_customer_id, default_payment_method_id, since. **El formulario público siempre crea un `clients` con `status = prospect`**, así el consentimiento tiene dónde colgarse |
| `client_restrictions` | client_id, allergen null, diet null (una fila por restricción) |
| `consents` | id, client_id, kind ('health_data','privacy','marketing'), text_version, granted_at, revoked_at |
| `recurring_plans` (F2) | id, client_id, freq ('weekly','biweekly'), dow, start_time, days, meals text[], active |
| `recipes` | id, chef_id, name_it, name_es, name_en (M4a), fridge_days, freezable, freezer_days (60), diet null, season_months smallint[] null (M4a: meses 1–12 en que se ofrece, sin repetir; null = todo el año), active (dar de baja = desactivar: una receta usada no se borra), catalog_visible (M4a; false = receta de un evento, que no se ofrece en el catálogo: 5.3), description_it, description_es, description_en (19/11/2026: la descripción corta del menú de la web, hasta 200 caracteres; checks como los nombres), auto_translated text[] ('{}' por defecto; 20/11/2026: los campos en italiano e inglés que llenó la traducción automática y Evelyn no tocó, «Traducción de los platos»), photo_id null (20/11/2026: la foto del plato, «Fotos de los platos»). Nombres sin espacios al borde y de hasta 120 caracteres; uno traducido vacío es null. Las notas del plato no van acá, porque el cliente lee la fila: van en `recipe_notes` |
| `recipe_ingredients` (M4a) | recipe_id, chef_id, position (1–50: el orden en el plato), name (hasta 80 caracteres), section (`shopping_section`; 'other' por defecto), quantity int null (para 4 porciones, de 1 a 100000), unit null (`ingredient_unit`). quantity y unit van juntas, o ninguna de las dos para «q.b.» (como la sal). Solo de la cocinera |
| `recipe_notes` (M4a) | recipe_id (una fila por plato con notas; sin notas, sin fila), chef_id, notes (sin espacios al borde). Solo de la cocinera |
| `recipe_allergens` | recipe_id, allergen |
| `requests` | id, chef_id, client_id (siempre, también para prospectos), type, status, adults, kids, days, meals text[], weeks (1–8: las semanas de un pedido `week`, una sesión de cocina por semana; 1 en los demás; al confirmar una reserva, las que se crearon), restrictions jsonb, wishes uuid[] (desde el 19/11/2026, los platos que el cliente eligió en el menú de la web, en orden: §4, «Menú de la web»), notes, preferred_date, preferred_start, pay_mode, target_session_id null (para 'change'), text (para 'change'), created_at; del pedido de la web además preferred_slot, locale, whatsapp_opt_in, estimate, source, seen_at, request_key, contact jsonb (el contacto con que llegó) y no_allergies (la pregunta de alergias: true = nadie tiene, false = las escribió y van en restrictions, null = sin respuesta; contrato §3) |
| `quotes` | id, request_id, session_id (la primera sesión `held` que reserva el horario; las demás semanas lo apuntan con `sessions.quote_id`), version (sube en cada reenvío), menu uuid[], cook_minutes, portions, service_cents (el total), groceries_est_cents, preauth_cents, pricing_snapshot jsonb (los términos enviados), allergen_override text null, slot_date, slot_start, hold_until, sent_at (el primer envío), accepted_at; desde el 21/11/2026 last_sent_at, declined_at, withdrawn_at y expired_at (a lo sumo un cierre), y uno abierto por pedido (5.8) |
| `sessions` | id, chef_id, client_id, request_id, quote_id, date, start_time, cook_minutes, shop_minutes, gap_minutes, portions, status, hold_until null (solo `held`), pay_mode, service_cents, groceries_est_cents, preauth_cents, groceries_actual_cents null, service_paid_at, groceries_paid_at, shopping_done_at, cooked_at, cancelled_at, cancel_reason, **busy tstzrange** (generada), week_start (generada: el lunes de la semana ISO). Como máximo una sesión viva (no cancelada) por semana de cada pedido (`sessions_una_por_semana`) |
| `session_menu` | session_id, recipe_id, chef_id, portions (1–500: las de ese plato en la semana), position (1–30: el orden de los platos; 21/11/2026). Los platos del menú de una semana (5.8); se escribe con `save_session_menu` |
| `session_shopping_items` (21/11/2026) | session_id, chef_id, position (1–150), name (hasta 80 caracteres), section (`shopping_section`), quantity int null (1 a 1000000), unit null (`ingredient_unit`); quantity y unit van juntas, o ninguna (q.b.). La lista de compras de la semana para la clienta, tal como la dejó Evelyn (5.8). Solo de la cocinera |
| `session_menus` (21/11/2026) | session_id PK, chef_id, note null (para la clienta, hasta 1000 caracteres, admite saltos de línea), version (1 al crearse; sube en cada guardado), allergens_confirmed (Evelyn confirmó los platos que chocan con las alergias del pedido), updated_at. Una fila por semana con menú (5.8). Solo de la cocinera |
| `receipts` | id, session_id, storage_path, total_cents, store_name, purchased_at, uploaded_by |
| `payments` | id, session_id, kind, provider ('stripe','satispay','cash','transfer'), stripe_payment_intent_id, amount_cents, captured_cents, service_part_cents, groceries_part_cents (reparto para separar servicio e insumos en un mismo cobro), status, idempotency_key unique, last_error, created_at |
| `prepared_portions` (F2) | id, client_id, session_id, recipe_id, count_initial, count_left, location, made_on, consume_by, discarded_at |
| `pantry_items` (F2) | id, client_id, name, qty_text, location, expires_on, added_by, consumed_at |
| `push_tokens` | profile_id, token, platform |
| `notifications` | id, profile_id, kind, payload jsonb, channel, scheduled_for, sent_at |

Sugerencias del menú semanal (M2b): tabla propia por cliente y semana (platos sugeridos, sin cantidad fija, y nota libre con los pedidos especiales y su estado), con `chef_id`, clave foránea compuesta con `clients`, RLS y grants en su propia migración; se diseña con tests primero. Un menú de evento usa recetas creadas para el evento, con sus alérgenos, que no se ofrecen en el catálogo (`catalog_visible = false`, 5.3).

**Sin compra** (19/11/2026): lo que la base tiene de la compra queda sin uso y no se borra, para no romper datos ni funciones. Son las columnas `quotes.groceries_est_cents` y `preauth_cents`; `sessions.groceries_est_cents`, `preauth_cents`, `groceries_actual_cents`, `groceries_paid_at` y `shopping_done_at`; `payments.groceries_part_cents`; y en `chef_settings`, los costos por porción y el margen. Tampoco se usan la tabla `receipts`, el estado `shopping_done` y el tipo de pago `groceries_extra`. `chef_create_booking` todavía recibe `p_groceries_est_cents`: la función `chef` siempre le manda 0. `shop_minutes` sigue en uso, con 0 por defecto (`20261119090000_sin_compra.sql`); cada sesión copia el valor de `chef_settings` al crearse; la misma migración pasa a 0 las vivas que todavía no pasaron (`held` o `confirmed`, desde hoy en Roma: `private.clear_upcoming_shop_minutes`), y las pasadas, cocinadas, cobradas o canceladas guardan sus 45 min. Si se confirma que la compra no vuelve, todo eso se saca en una migración propia.

**Menú de la web** (comentarios de Evelyn del 19/11/2026; migración `20261119150000_menu_web.sql`, tests pgTAP `17_menu_web`): el formulario público muestra los platos **publicados** de la cocinera (activos, `catalog_visible` y con `description_it`) y el cliente elige hasta uno por día del pedido. `save_recipe` guarda las tres descripciones (`""` es null; al actualizar, la que no viene no se toca). `get_public_menu(chef_id)` devuelve los publicados con nombres, descripciones, alérgenos, dieta y meses, nunca ingredientes ni notas; es security definer y solo la ejecuta `service_role` (la web la lee por la Edge Function `public-request`). `submit_public_request` recibe `wishes`: valida que sea un array de uuids sin repetir y de hasta `days` (`invalid_wishes`), guarda en `requests.wishes` solo los publicados de esa cocinera, en el orden del cliente (un plato desactivado entre la carga y el envío se descarta sin error), y devuelve `menu` con sus nombres, también en el reintento. Un array no tiene clave foránea: si después se borra un plato fuera de la app (la app los desactiva; la base deja borrar uno que no esté en ningún `session_menu`), su id queda en `wishes` y el reintento lo omite (y la app del menú lo marca como borrado).

**Traducción de los platos** (pedido de Evelyn del 20/11/2026; migración `20261120090000_recipe_translations.sql`, tests pgTAP `18_recipe_translations`; contrato `docs/contracts/chef-api.md` §12): en el editor el español es la fuente. Evelyn escribe el nombre y la descripción en español y el italiano y el inglés los completa la traducción automática, que ella puede corregir. Traduce Claude (API de Anthropic, decisión de Nicolas) desde la función `chef` (`POST …/chef/translate`): recibe el nombre y la descripción en español y devuelve los dos idiomas enteros, con los límites de la base, o nada; nunca una traducción a medias. Sin traducción responde `422` si ese plato no se pudo traducir (una negativa del modelo, un corte o una salida que no sirve), `503` si se puede reintentar (Claude no respondió en 40 s o dio un error pasajero) y `501` si la traducción está apagada. Cada cocina tiene un límite de 60 traducciones por hora y 150 por día, en ventanas móviles (`429`; el intento rechazado también cuenta y la app no reintenta sola). Sin la clave (`ANTHROPIC_API_KEY`, secreto opcional del despliegue; borrarla de GitHub no la saca de Supabase) la traducción queda apagada y Evelyn escribe los tres idiomas a mano. La traducción de mentira de desarrollo (`TRANSLATE_TRANSPORT=fake`) vale solo con un Supabase local: el despliegue corta si la encuentra en producción. `recipes.auto_translated` guarda qué campos de destino (`name_it`, `description_it`, `name_en`, `description_en`; el español nunca) llenó el traductor y Evelyn no tocó a mano, sin repetir, nunca uno sin texto y nunca sin su fuente (un nombre marcado exige `name_es`; una descripción marcada, `description_es`): así la app sabe qué volver a traducir cuando cambia el español sin pisar lo que ella corrigió. `save_recipe` la recibe en la clave opcional `auto_translated` y la reemplaza en cada guardado: sin la clave queda vacía (una app que no la conoce guarda todo como escrito a mano); un valor fuera de la lista, repetido o de otro tipo, un campo marcado que no llega con texto o uno cuya fuente en español no llega con texto, es `invalid_payload`. Duplicar (guardar con un id nuevo, sin las descripciones de la web) no puede copiar las marcas de las descripciones; las de los nombres copiados, sí.

En el editor de la app (traduccion-app): primero el nombre y la descripción en español, con el aviso de no escribir datos de clientes (nombres, direcciones, salud), porque ese texto va a Anthropic; abajo el italiano y el inglés, con la marca «Tradotto automaticamente» en lo automático. El nombre en español es obligatorio (un plato guardado siempre abre con él). Un plato guardado sin `name_es` (anterior a la traducción) se abre como si lo escrito en italiano estuviera en español, porque Evelyn cargó los platos en español en el campo italiano (decisión de Nicolas del 20/11/2026): el nombre en español es el `name_it` guardado y la descripción en español, la `description_it` si no tenía `description_es`; esos campos en italiano abren vacíos y sin la marca, y se traducen al guardar (la copia hace lo mismo con el nombre). Si se guarda sin traducir (a mano, o un `501` o un `422`) y el nombre en italiano no se escribió a mano, el plato sigue siendo viejo: `name_es` queda null y `name_it` lleva el nombre en español como esté (con lo que se haya corregido), y la descripción que había pasado, igual (`description_es` null y `description_it` con la española); nada queda marcado sin su español. Así nunca hace falta escribir el italiano y, la próxima vez que se abre y se guarda, se traduce. Si escribió el nombre en italiano a mano, deja de ser viejo y todo sigue la regla de siempre: una descripción que había pasado al español queda sin italiano (el aviso dice que el plato sale de la web, y por eso un `501` o un `422` no guarda solo). El nombre en español repetido se avisa mientras se escribe, como el italiano (el de un plato viejo es su `name_it`). Al guardar se traduce, de cada campo de destino, lo vacío y lo automático cuyo español cambió desde la última traducción (el nombre sale del nombre y la descripción, de la descripción); a Anthropic va el nombre y, solo si hay una descripción que traducir, la descripción. Lo escrito a mano nunca se pisa, y escribir en un campo lo saca de los automáticos; un campo vaciado a mano se vuelve a traducir. Si se borra la descripción en español, las descripciones automáticas se vacían y las escritas a mano quedan; con eso, un plato puede salir de la web, y escribir la descripción en español alcanza para que vuelva. Mientras traduce (hasta un minuto) el editor lo dice, también al lector de pantalla, y no deja tocar el formulario, guardar de nuevo, deshacer desde un aviso ni salir (volver se ve deshabilitado); si el formulario igual cambió, no guarda y lo dice. Ante un `401` la app renueva la sesión una vez y reintenta una vez. Si el traductor falla, no se guarda nada ni se pierde lo escrito, y un aviso dice por qué y ofrece escribir a mano el italiano y el inglés (enfoca el primer campo que había que traducir), guardar sin traducir y, solo si la falla puede ser pasajera, reintentar: un `503`, un 502 o 504 de la plataforma, un 429 de la plataforma (sin el código `rateLimited` de la función), la función sin desplegar (`404`), sin conexión o 60 s sin respuesta. Nunca ante un `422`, un `429`, un `501`, un `500` (también un 200 que no cumple el contrato o un error de la app), un `403`, un `400` ni un `401` que sigue después de renovar la sesión (ahí dice que hay que volver a entrar). Después de un `422` o un `429`, guardar con el mismo pedido va directo al aviso sin volver a llamar (un `429` rechazado también gasta cupo, y la app nunca reintenta sola); con otro español, vuelve a llamar. Guardar sin traducir vacía lo automático que había que traducir de nuevo (nunca queda una traducción del español anterior como si fuera la del nuevo), deja vacío lo vacío (se traduce la próxima vez que se guarde) y no toca lo escrito a mano; si vacía una descripción en italiano que había, el aviso dice que el plato sale de la web; si el nombre en italiano quedaría vacío (un plato nuevo, o uno con el italiano automático y el nombre en español cambiado), no se puede: hay que escribirlo. Con la traducción apagada (`501`) o un texto que no se pudo traducir (`422`), y solo campos vacíos para traducir (nada automático que quedaría viejo, el nombre en italiano escrito o un plato viejo que sigue viejo, y sin dejar el plato fuera de la web), el editor guarda sin traducir sin preguntar y la lista lo dice (o el menú de la semana, si el plato se creó desde su «Nuevo plato»), con el motivo, en un aviso que dura como los de error (y con VoiceOver o TalkBack queda hasta cerrarlo); si no, el aviso de siempre (decisión del 20/11/2026). La copia de un plato lleva las marcas de los nombres; si se le cambia el nombre en español, el nombre automático se vuelve a traducir.

**Fotos de los platos** (pedido de Evelyn del 20/11/2026; migración `20261120100000_recipe_photos.sql`, tests pgTAP `18_recipe_photos`): una foto por plato, que se ve en la pestaña «Menù» del formulario (la miniatura al lado de cada plato) y en la app (lista de platos, editor y el recuadro del menù elegido en el detalle del pedido). No en la portada. La app la saca con la cámara o la elige de la galería (en `/gestione/`, un archivo), la achica, le saca los metadatos (EXIF, GPS) y sube dos JPEG al bucket público `recipe-photos`: `{chef_id}/{recipe_id}/{photo_id}.jpg` (lado mayor 1200 px) y `{photo_id}-thumb.jpg` (lado menor 320 px, sin agrandar una más chica: la web la muestra recortada en un cuadrado de 80 px), de hasta 2 MiB, con `cacheControl` de una semana (604800 s: una foto que Evelyn cambia no tiene que seguir mucho en la CDN). Cada cambio lleva un `photo_id` nuevo: la app nunca pisa ni mueve un archivo, sube los nuevos y borra los viejos. Eso es una convención de la app, no una garantía de la base: sin política de UPDATE la cocina no reemplaza ni renombra por la API, pero puede borrar un archivo y subir otro con el mismo nombre. Los tamaños en píxeles tampoco los controla la base. Después llama a `set_recipe_photo(p_recipe_id, p_photo_id)`, que guarda `recipes.photo_id` y devuelve la foto que deja de usarse (null si no había o si es la misma); con `p_photo_id` null saca la foto. Después la app limpia la carpeta del plato: borra todo lo que no sea la foto nueva (así se van también la vieja cuando se perdió una respuesta y las subidas abandonadas). Que estén los dos archivos en la carpeta del plato lo exige el trigger `recipes_check_photo` (security invoker; `photo_not_found`, 22023, con las rutas que faltan), también en un insert o update directo de `recipes` por la API, que `authenticated` puede hacer (privilegios de toda la tabla). `set_recipe_photo` es security invoker y solo la ejecuta `authenticated`; un plato de otra cocina o que no existe es `recipe_not_found` (P0002), como en `save_recipe`, que no toca `photo_id`: **duplicar un plato no copia la foto**. Por la API (listar, subir, borrar) solo la cocinera y sus colaboradores, en la carpeta de su cocina (`current_chef_id()`, como los tickets), y suben solo con esa forma; el cliente y anon, nada. Pero el bucket es público: **una foto se ve con su URL aunque el plato no esté publicado**, igual que cualquier archivo que siga en el bucket. La app no borra platos (los da de baja); si alguna vez lo hace, borra antes sus archivos, y un plato borrado fuera de la app deja los suyos en el bucket. `get_public_menu` devuelve `photoId` y la Edge Function `public-request` arma las URL públicas (contrato public-request §12).

**La foto en la app** (pedido de Nicolas del 20/11/2026; `app/README.md`, «Foto del plato»): se agrega en el mismo editor del plato, **también al crearlo** («Nuovo piatto»), no solo después. La app la prepara en el dispositivo (derecha según el EXIF, los dos tamaños, JPEG sin metadatos: ni EXIF, GPS, XMP, IPTC ni comentarios; solo queda el perfil de color, que no es un dato personal) y la sube al tocar «Salva»: primero la traducción automática, si hay algo que traducir (si falla, no se guarda nada, tampoco la foto, que sigue en el editor: «Traducción de los platos»), después guarda el plato (`save_recipe`, con el id que ya generó la app) y después sube los dos archivos (sin pisar nada; un archivo que ya está, de un intento anterior de la misma foto, cuenta como subido) y llama a `set_recipe_photo`; al final limpia la carpeta del plato, sin avisar si falla: borra todo lo que no sea la foto nueva (la que dejó de usarse y las subidas abandonadas). Mientras se elige o se prepara una foto, «Salva» espera; una foto elegida mientras se guardaba queda para el próximo guardado. **Si la foto falla, el plato queda guardado** (sin foto si era nuevo; con la anterior si se cambiaba) y el editor no se cierra: lo dice con «Riprova», que sube solo la foto con el mismo `photo_id`. En un plato guardado se cambia o se saca desde el mismo editor, y se aplica al guardar; si solo cambió la foto (y no hay nada que traducir), el plato no se vuelve a mandar. Sin foto, la lista y el menù elegido se ven como antes; una foto que no carga deja un cuadrado neutro.

**Catálogo de platos** (M4a; migración `20261116170000_recipe_catalog.sql`, tests pgTAP `14_recipe_catalog`): cada ingrediente de un plato lleva su cantidad para 4 porciones, entera, en g, ml o piezas, o «q.b.», sin cantidad ni unidad. Así la lista de compras de una sesión es automática y editable (decisión del dueño del 16/11/2026): sale del menú de la sesión por las porciones y Evelyn la edita (área de Evelyn, PR de la lista de compras). Un plato se guarda entero con `save_recipe(p jsonb)`, en una transacción: la receta, sus alérgenos, sus ingredientes (las dos listas se reemplazan enteras) y sus notas, así nunca queda con los alérgenos a medio guardar. Es security invoker (corre con la RLS de la cocinera) y solo la ejecuta `authenticated`. El id lo genera la app, así un reintento no duplica el plato. Una clave que no viene no se toca; una desconocida, también dentro de un ingrediente, da `invalid_payload` (si se ignorara, un nombre cambiado de un solo lado perdería el dato en silencio). `allergens` e `ingredients` son obligatorias (`[]` es «ninguno»). La dieta no puede contradecir los alérgenos (5.6). Errores: `not_a_chef` (42501), `invalid_payload` (22023, con el campo en el detalle; `diet` si la dieta contradice los alérgenos), `recipe_not_found` (P0002: el id es de otra cocinera) y los checks de las tablas (23514). Las notas son solo de la cocinera (`recipe_notes`): en `recipes` las leería cualquier cliente de su catálogo, porque la RLS filtra filas, no columnas. Duplicar no tiene función propia: es guardar con un id nuevo el plato cargado, sin las descripciones de la web (19/11/2026: así la copia no sale en el formulario con la descripción del original hasta que Evelyn escriba la suya). Dar de baja es `active = false`: una receta usada en un menú no se puede borrar (`session_menu` la protege con restrict).

**Anti doble reserva** (obligatorio, no confiar solo en la app):

```sql
create extension if not exists btree_gist;
-- busy = [inicio - compra, fin de cocina + margen)   (compra = shop_minutes: 0 desde el 19/11/2026)
-- El margen va de UN solo lado: así dos sesiones chocan si
-- a_ini < b_fin + margen y b_ini < a_fin + margen, exactamente la regla de 5.2.
-- (Con margen a ambos lados la base exigiría 2 × margen y rechazaría horarios ofrecidos.)
alter table sessions add constraint no_overlap
  exclude using gist (chef_id with =, busy with &&)
  where (status <> 'cancelled');
```

Al enviar un presupuesto se crea la sesión con `status = held` y `hold_until` (48 h; un evento, su propio plazo: 5.3): `no_overlap` la protege igual que a una confirmada, así dos presupuestos nunca prometen el mismo horario. Al aceptar pasa a `confirmed`; si el cliente rechaza o vence, un cron la pasa a `cancelled` (`cancel_reason = 'hold_expired' | 'declined'`).

**Reservas** (migraciones `20261116150000_pay_mode_manual.sql` y `20261116150100_bookings.sql`, tests pgTAP `13_bookings`): una reserva es un pedido aceptado más sus sesiones, una por semana (las que tienen ese `request_id`); no hay tabla propia. Las crea `chef_create_booking`, desde un pedido `new` o a mano (ficha existente o nueva y un pedido `source = 'app'`, idempotente por `request_key`): todas `confirmed`, con `pay_mode = manual`, y el servicio que fija Evelyn repartido en centavos entre las semanas (los que sobran, a las primeras: 500 € en 3 son 166,67 + 166,67 + 166,66). Es todo o nada: si una semana choca, no se crea ninguna y el error dice la fecha. `chef_move_session` y `chef_cancel_sessions` mueven y cancelan semanas. Las tres son security definer y solo las ejecuta `service_role`: las llama la Edge Function `chef`, que valida a la cocinera o a un colaborador suyo (JWT con `auth.getUser` y su cocina con `public.chef_id_for_user`) y les pasa siempre el `chef_id` de esa cocina (contrato `docs/contracts/chef-api.md`: `POST …/chef/bookings`, con `dryRun` y `requestKey`, `…/sessions/move` y `…/sessions/cancel`).

---

## 5. Reglas de negocio

### 5.1 Presupuesto

Precio por semana (decisiones del dueño del 15 y 16/11/2026), **solo con enteros** (sin decimales en ningún paso). Fuente única de verdad: el módulo TS `supabase/functions/_shared/quote.ts`, usado por las Edge Functions y por la web. La app replica el cálculo en Dart solo para la vista previa, y **todas las implementaciones pasan los mismos vectores** (`supabase/functions/_shared/quote_vectors.json`, leído por los tests de TS y de Dart).

- **Pedido semanal** (`week`): de 1 a 8 semanas (`LIMITS.maxWeeks`, el check `requests_semanas_validas`), con un menú y una sesión de cocina por semana, el mismo día.
- **Servicio por semana**: `weekly_rate_cents` (150 €) para un hogar de hasta `weekly_rate_max_people` (5) personas, adultos y niños. No cambia con los días ni con las comidas, e incluye el traslado.
- **Desde `weekly_discount_min_weeks` (4) semanas**, cada semana cuesta `weekly_rate_discounted_cents` (140 €): 560 € por 4 semanas. Con más de 4 se mantienen los 140 €. El ahorro se cuenta frente a la tarifa sin descuento; con 1 a 3 semanas no hay. Para no hacer descuento, la misma tarifa en las dos columnas.
- **Sin precio automático**: con más personas que el tope, o en una sesión extra suelta (`extra`, de una sola semana). Evelyn pasa el presupuesto.
- **Compra de ingredientes**: la hace el cliente, con la lista que Evelyn le manda antes de cada sesión (decisión del 19/11/2026). Se cobra solo el servicio: el motor no estima la compra, y ni la web ni la app ni los emails la muestran.
- El precio automático es una **estimación**: Evelyn recibe el pedido y devuelve el costo final. El pago se acuerda con ella (manual) por ahora.
- El **tiempo de cocina** se estima como antes, por sesión: de él dependen los días libres del calendario (`get_free_days`, 5.2) y el tope del horario (360 min desde el 19/11/2026: 5.2). No entra en el precio.

```
div_arriba(a, b)   = (a + b − 1) div b                  -- enteros ≥ 0
comidas            = cantidad de comidas por día (1 o 2: almuerzo, cena)
-- De una semana (una sesión):
porc_adulto        = adultos × días × comidas
porc_niño          = niños × días × comidas
porciones          = porc_adulto + porc_niño
recetas            = clamp( min(div_arriba(días × comidas, 2), porciones div 2), 2, 6 )
minutos_cocina     = max(min_cocina, div_arriba(300 + 150 × recetas + 6 × porciones, 150) × 30)
                     -- = ceil_a_30(60 + 30 × recetas + 1,2 × porciones), escrito en enteros
-- Precio automático: solo un pedido semanal con adultos + niños ≤ tope_personas.
servicio_semana    = semanas ≥ desde_semanas ? tarifa_descuento : tarifa
servicio           = servicio_semana × semanas
ahorro             = tarifa × semanas − servicio
```

Con los valores por defecto (150 € por semana, 140 € desde 4 semanas, hasta 5 personas; mínimo 90 min):

| # | Entrada | Semanas | Porciones | Recetas | Cocina | Servicio/sem. | Servicio | Ahorro |
|---|---|---|---|---|---|---|---|---|
| 1 | 2 ad · 2 niños · 5 días · cena | 1 | 20 | 3 | 180 min | 15000 | 15000 | 0 |
| 2 | Como el 1 (sin descuento) | 3 | 20 | 3 | 180 min | 15000 | 45000 | 0 |
| 3 | Como el 1 (desde 4: 140 €) | 4 | 20 | 3 | 180 min | 14000 | 56000 | 4000 |
| 4 | Como el 1 | 5 | 20 | 3 | 180 min | 14000 | 70000 | 5000 |
| 5 | Como el 1 (máximo) | 8 | 20 | 3 | 180 min | 14000 | 112000 | 8000 |
| 6 | 2 ad · 3 niños · 4 días · cena (5 personas, el tope) | 1 | 20 | 2 | 150 min | 15000 | 15000 | 0 |
| 7 | 3 ad · 3 niños · 5 días · cena (6 personas) | 1 | 30 | 3 | 210 min | — | sin precio automático | — |
| 8 | Extra: 10 ad · 6 niños · 1 día · cena | 1 | 16 | 2 | 150 min | — | sin precio automático | — |
| 9 | Extra: 2 ad · 1 día · almuerzo y cena | 1 | 4 | 2 | 150 min | — | sin precio automático | — |
| 10 | 1 ad · 5 días · almuerzo | 1 | 5 | 2 | 150 min | 15000 | 15000 | 0 |
| 11 | 0 ad · 2 niños · 3 días · almuerzo (porción de niño) | 1 | 6 | 2 | 150 min | 15000 | 15000 | 0 |
| 12 | 2 ad · 2 niños · 5 días · almuerzo y cena | 2 | 40 | 5 | 270 min | 15000 | 30000 | 0 |
| 13 | 4 ad · 7 días · almuerzo y cena (tope de 6 recetas) | 1 | 56 | 6 | 330 min | 15000 | 15000 | 0 |
| 14 | 1 ad · 1 día · cena (mínimo) | 1 | 1 | 2 | 150 min | 15000 | 15000 | 0 |
| 15 | Como el 14, con un mínimo de cocina de 240 min | 1 | 1 | 2 | 240 min | 15000 | 15000 | 0 |
| 16 | Tarifas de Giulia (seed: 160 €, 150 € desde 3 semanas, hasta 6 personas): 3 ad · 3 niños · 5 días · cena | 3 | 30 | 3 | 210 min | 15000 | 45000 | 3000 |
| 17 | Sin descuento (la misma tarifa en las dos columnas): como el 1 | 4 | 20 | 3 | 180 min | 15000 | 60000 | 0 |
| 18 | Como el 7 (6 personas): sin precio, las semanas quedan en la estimación | 4 | 30 | 3 | 210 min | — | sin precio automático | — |

(Montos en centavos. Los 7, 8, 9 y 18 dicen por qué no hay precio: `people` o `extra`. Además, `validSettings` tiene el mínimo y el máximo de cada check de las columnas de `chef_settings` que lee el motor: los dos motores calculan con cualquiera, y `quote.test.ts` compara la lista con las migraciones.)

- `requests.estimate` guarda el resultado del motor y las tarifas usadas (`pricing`): siempre `weeks`, `autoPrice`, porciones, recetas y minutos; `weeklyServiceCents`, `serviceCents` y `savingsCents` solo con precio automático. Sin precio, esas claves no van (ni null ni 0) y van `autoPrice: false` y `reason` (`people` o `extra`). Las guardadas antes del precio por semana no tienen `autoPrice`: eran de una semana, con el servicio por hora (`hourly_rate_cents` y `travel_fee_cents`, que siguen en `chef_settings` pero ya no entran en la estimación). Las guardadas antes del 19/11/2026 traen además la compra (`groceriesEstCents`, `preauthCents`) y, con precio, `totalCents` (servicio más compra): se ignoran.
- La web calcula con `DEFAULT_PRICING`, que es el valor por defecto de `chef_settings` (`quote.test.ts` lo compara con las migraciones y exige que el motor acepte todo lo que la base guarda); el servidor calcula con las tarifas de la cocinera y la pantalla de gracias y los emails muestran las suyas. Mientras la web no lea las tarifas, cambiar una tarifa es un PR: `DEFAULT_PRICING`, el valor por defecto en una migración y la fila de la cocinera.
- El mínimo de 90 min no se aplica con las porciones reales (la sesión más corta es de 150 min); el vector 15 lo prueba con otro valor.

- Evelyn puede **ajustar el servicio a mano** antes de enviar; se guarda en `quotes.service_cents` y el motivo en `pricing_snapshot`.
- Al enviar se guarda un **snapshot** con tarifas y resultado: si Evelyn cambia tarifas después, los presupuestos enviados no cambian.
- Un presupuesto vence a las 48 h (`hold_until`); vencido, el pedido pasa a `expired` y se libera el horario. El de un evento tiene un plazo propio, más largo (5.3).
- Platos (D4, decisión del 15/11/2026): el cliente solo sugiere los que le gustan, sin cantidad fija, y Evelyn decide y arma el menú. Desde el 19/11/2026 (comentarios de Evelyn) el formulario de la web le deja elegir hasta un plato por día del pedido (`days`) entre los publicados, opcional: si elige menos o ninguno, el resto lo propone Evelyn, que tiene la última palabra (alergias, temporada). La cantidad de `recetas` sigue saliendo de esta fórmula: ni la fórmula ni los vectores cambian por las sugerencias ni por lo elegido.
- Eventos privados: sin estimación automática. Evelyn fija el presupuesto después de hablar con el cliente (5.3).

### 5.2 Disponibilidad y horarios libres

Implementado en SQL (migración `20261115130000_free_slots.sql`, tests pgTAP `07_free_slots`): `get_free_slots(chef_id, cook_minutes, from_date, days)` y `get_free_days(chef_id, cook_minutes, from_date, days)`, sobre un generador común (`private.free_slot_candidates`). Las ejecuta **solo `service_role`**: la web pública lee los días por la Edge Function `public-request` (`GET …/availability?minutes=N`, contrato §11, con CORS y su propio límite por IP), nunca con una RPC anónima. La app las usará desde una ruta de servidor (M3c).

- Ventana: desde mañana en Roma, respetando `min_notice_hours` (el inicio menos `shop_minutes`, como pronto tantas horas después de ahora), hasta hoy + `booking_horizon_days` (56, 8 semanas: los mismos días que se pueden elegir en el formulario, `DATE_WINDOW`; un test compara las dos). Decisión del dueño del 15/11/2026: antes eran 14 días y, más de la mitad de los días, la ventana cabía en un solo mes y las flechas del calendario quedaban deshabilitadas (el 15/11, del 16 al 29 de noviembre); ahora toca dos o tres meses y el calendario muestra uno por vez.
- Un día cuenta si tiene regla de disponibilidad y no está bloqueado.
- Candidatos cada `slot_step_minutes`, desde `ceil_a_30(apertura + compra)` (compra = `shop_minutes`, 0 desde el 19/11/2026) mientras `inicio + cocina ≤ cierre`. La **hora mostrada es la de llegada a la casa**.
- Un candidato `[inicio − compra, inicio + cocina]` choca con una sesión no cancelada (incluidas las `held`, también las vencidas mientras el cron no las cancele) si `a_ini < b_fin + margen` y `b_ini < a_fin + margen`. Es la misma condición que `no_overlap`: el rango del candidato se arma igual que `sessions.busy`, con la compra y el margen actuales de la cocinera, y se compara con `&&` contra el `busy` guardado de cada sesión. Un horario ofrecido nunca puede ser rechazado por la base (hay un test que lo verifica en toda la grilla, también en días con cambio de hora).
- `get_free_slots`: se muestran hasta 3 horarios por día, separados al menos 2 h (los primeros que cumplen), en los primeros 5 días con lugar.
- `get_free_days`: cada fecha del rango pedido, con `available` si tiene al menos un horario libre (el calendario de la web). El calendario vale solo para la semana de comidas: con `extra` se puede elegir cualquier día de la ventana (Evelyn confirma la disponibilidad al contactar) y los eventos no usan ni el calendario ni la ventana (5.3).
- Horario inicial (decisión del dueño del 15/11/2026): lunes a viernes de 9:00 a 15:00 para toda cocinera sin reglas (migración `20261115130100_default_availability.sql`; en un proyecto nuevo, `deploy-supabase.yml` al crear la cuenta), hasta que la app tenga editor de disponibilidad (M5a). La ventana, que en esa decisión seguía en 14 días, pasó el mismo día a 8 semanas (migración `20261115130200_booking_horizon_8_weeks.sql`).
- Sin compra (decisión del 19/11/2026): a las 9:00 Evelyn llega a la primera casa (`shop_minutes` = 0, `20261119090000_sin_compra.sql`). Las reglas siguen en 9:00–15:00 y la cocina dura como máximo 360 min (6 h). Un pedido más largo no tiene ningún día libre: la web lo explica y deja enviarlo sin fecha, y Evelyn propone una. Antes (D1, 15/11/2026) a las 9:00 empezaba la compra, de 45 min: la primera llegada era a las 10:00 y el tope, 300 min (el vector 13, de 330 min, no tenía día libre; ahora sí).
- En Fase 0 hay sesiones: las crean las reservas que confirma Evelyn (5.3) y el calendario las descuenta como a cualquier sesión no cancelada. Los días bloqueados (`availability_exceptions`, M5a) quedan para las ausencias.
- F3: sumar tiempo de traslado según zona de la sesión anterior y la siguiente.

### 5.3 Estados

**Pedido (`requests.status`)**
```
new ──(Evelyn envía presupuesto)──▶ quoted ──(cliente acepta)──▶ accepted
 │                                    ├──(cliente rechaza)──▶ declined
 │                                    ├──(vence hold_until)──▶ expired
 │                                    └──(Evelyn lo retira)──▶ new
 ├──(Evelyn rechaza)──▶ rejected
 └──(type = change, Evelyn lo resuelve)──▶ resolved
```

**Evento privado (`requests.type = 'event'`, M3b; D2, decisión del 15/11/2026)**
- Formulario propio: fecha, cantidad de invitados, hora aproximada e idea del evento. La fecha es libre: no usa el calendario de disponibilidad ni la ventana de 8 semanas, y Evelyn confirma día y hora al hablar con el cliente (puede caer fuera de su horario semanal; la sesión del evento igual pasa por `no_overlap`). Los campos y sus límites los fija el contrato del formulario.
- Sin precio automático: `requests.estimate` queda null y ni la web ni los emails muestran precio. Evelyn pasa el presupuesto después de hablar con el cliente, con un vencimiento propio, más largo que 48 h (se fija en M4).
- Menú a medida, acordado con el cliente: recetas creadas para el evento, con sus alérgenos (5.6), que no se ofrecen en el catálogo semanal.
- Estados: los del pedido, sin migración de estados.

| Evento | `requests.status` |
|---|---|
| nueva | `new` sin `seen_at` |
| en charla | `new` con `seen_at` (Evelyn lo abrió) |
| presupuestada | `quoted` |
| confirmada | `accepted` |
| rechazada | `rejected` (Evelyn) o `declined` (cliente) |

Si el presupuesto de un evento vence, el pedido pasa a `expired`, como cualquier otro. `extra` queda para la sesión extra de un cliente: de una sola semana y sin precio automático (5.1); su estimación guarda porciones y minutos, y Evelyn pasa el precio.

**Pedido especial del menú semanal (M2b)**: queda pendiente hasta que Evelyn lo aprueba o propone una alternativa. Las sugerencias de platos no tienen estado: Evelyn las ve al armar el menú. Los estados y las transiciones del pedido especial se definen con tests primero en su milestone, en la tabla de sugerencias (no en `requests.status`).

**Sesión (`sessions.status`)**
```
held ──(cliente acepta)──▶ confirmed ──(ticket cargado)──▶ shopping_done ──(marcar cocinado)──▶ cooked ──(todo cobrado)──▶ paid
  │                          └──(marcar cocinado sin ticket)─────────────────────────────────▶ cooked
  └──(vence o rechaza)──▶ cancelled ◀──(cancelar, desde confirmed o shopping_done)
cooked ──(deshacer «Cociné»)──▶ confirmed o shopping_done          paid ──(anular el cobro)──▶ cooked
```
Son las únicas transiciones válidas: held → confirmed o cancelled; confirmed → shopping_done, cooked o cancelled; shopping_done → cooked o cancelled; cooked → paid, confirmed o shopping_done; paid → cooked. Las aplica la guarda `sessions_guard_update` a todos los roles, también a la service role, y la fecha, la hora y la duración de una sesión cambian solo en `held` o `confirmed` (mover una semana). Sin compra (19/11/2026) no hay ticket: el camino es confirmed → cooked → paid y `shopping_done` queda sin uso (la guarda todavía lo acepta; se saca con el resto de la compra, §4). La app no ofrece ese paso y muestra una sesión vieja en `shopping_done` como confirmada («Confermata»: todavía no se cocinó), sin decir que se hizo la compra; tampoco muestra los minutos de compra que guardan las sesiones de antes (`shop_minutes`): solo la llegada y el fin de la cocina.

`cooked → paid` ocurre solo cuando el servicio está cobrado, y lo decide el **webhook** de Stripe o el registro manual de Evelyn, nunca la app del cliente. `paid → cooked`, solo al anular un cobro.

**Reservas (hasta M4)**: de 1 a 8 semanas, con una sesión por semana. Evelyn las confirma desde el pedido, o las carga a mano, sin presupuesto ni retención de 48 h, como lo que hoy se acuerda por WhatsApp: las sesiones nacen `confirmed`, el pedido pasa a `accepted` con sus semanas y la ficha de un prospecto, a `trial` (§4, «Reservas»). El precio del servicio de toda la reserva es obligatorio al confirmar (0 vale: sin cargo), porque después ninguna ruta lo cambia. A mano, la reserva es para una ficha existente (buscada por nombre o teléfono) o una nueva (si el teléfono ya es de una ficha, la app la ofrece), con la misma hoja: nunca modifica una ficha existente, salvo el paso de prospecto a `trial`. «Renovar» es una reserva a mano para la misma ficha, prellenada así: las semanas de la reserva (las del pedido, `requests.weeks`) y su precio total (contando las semanas canceladas de la reserva, no las de un presupuesto que no se aceptó: retirado, también al confirmarlo sin presupuesto, vencido o rechazado; si las que quedan no son las del pedido, como una semana del presupuesto cancelada antes de que la clienta lo aceptara, el precio queda vacío y lo escribe Evelyn), la hora y los minutos de la última sesión viva, el hogar y el idioma del pedido, y la primera fecha en la última sesión viva + 7 días; con otra cantidad de semanas, el precio sigue las tarifas de la estimación solo si el total era el de esas tarifas (si no, lo escribe Evelyn). No hay renovación automática. Lo que dice el `dryRun` de cada semana son avisos, salvo un choque; la app avisa además los feriados de Bergamo (el servidor solo conoce los días que Evelyn bloqueó) y una llegada de hoy que ya pasó. Una semana ya cobrada no se cancela de entrada: una sesión cancelada no se mueve ni se reactiva, así que la app ofrece primero pasarla al final de la reserva y la cancela, con permiso explícito, solo para registrar la devolución (decisión del dueño del 16/11/2026; los cobros manuales llegan con el área de Evelyn).

**Pago (`payments.status`)**: refleja el PaymentIntent de Stripe (`requires_action`, `authorized` = requires_capture, `succeeded`, `canceled`, `failed`) o `pending` para efectivo y transferencia hasta que Evelyn lo confirma.

### 5.4 Pagos con Stripe

**A. Pre-autorización (`pay_mode = preauth`)**

Desde el 19/11/2026 se cobra solo el servicio: la compra la hace el cliente. Stripe permite **una sola captura** por PaymentIntent: una retención por el servicio de la sesión y una captura al cocinar.

1. Al aceptar el presupuesto: crear `Customer` si no existe y guardar la tarjeta con **SetupIntent** (app: PaymentSheet; web: Stripe Checkout `mode=setup`). Autenticación SCA una vez, uso `off_session`.
2. **No retener al aceptar**: una autorización de tarjeta suele vencer a los 7 días (a veces antes). Un cron crea la retención **48 h antes de la sesión** (o al momento si falta menos): `PaymentIntent` por `service_cents`, `capture_method=manual`, `off_session=true`, `confirm=true`. En un pedido de varias semanas cada sesión es una semana: su servicio es el de esa semana (5.1). Hasta M6 el pago se acuerda con Evelyn (manual).
3. Si Stripe pide autenticación (`requires_action`), se notifica al cliente para confirmarla dentro de la app. Si falla, se avisa a Evelyn: la sesión queda marcada "sin pre-autorizar".
4. Al marcar cocinado: `capture` por el servicio.
5. Si la autorización venció o se canceló antes de capturar: cobrar el servicio con un `PaymentIntent` `off_session` normal.

**B. Pago al final (`pay_mode = pay_after`)**
Al marcar cocinado se genera el cobro del servicio; el cliente paga en la app (PaymentSheet; F3: Satispay). Recordatorios a las 24 h y 72 h.

**C. Efectivo o transferencia**: Evelyn lo registra a mano (`provider = cash | transfer`).

**Reglas técnicas**
- Los **webhooks son la fuente de verdad**: `payment_intent.amount_capturable_updated`, `payment_intent.succeeded`, `payment_intent.payment_failed`, `payment_intent.canceled`, `setup_intent.succeeded`. Verificar la firma.
- `idempotency_key` = `session:{id}:{kind}:{n}` en toda llamada a Stripe.
- Nunca guardar datos de tarjeta propios; solo IDs de Stripe.
- Modo test de Stripe en dev y staging; claves en secretos de Supabase, nunca en la app.
- Cancelar una sesión cancela el PaymentIntent retenido y libera el importe.

### 5.5 Porciones y vencimientos (F2)
- Al marcar cocinado se crean `prepared_portions` repartiendo las porciones entre las recetas del menú.
- `consume_by = made_on + fridge_days` (heladera) o `+ freezer_days` (freezer). Por defecto, a partir del tercer plato congelable se sugiere freezer; Evelyn puede cambiarlo antes de confirmar.
- El cliente descuenta porciones ("comimos una") o descarta las vencidas.
- Aviso push a las 8:00 del día anterior al vencimiento.
- Despensa: el cliente carga ingredientes con vencimiento; si comparte, Evelyn ve en el pedido y en la sesión los que vencen en ≤ 3 días ("usar primero").

### 5.6 Alérgenos
- Recetas etiquetadas con los 14 alérgenos UE y dieta (vegetariana / vegana).
- Un plato se guarda entero, en una transacción (`save_recipe`, §4): nunca queda con los alérgenos a medio guardar, porque el menú y sus alertas dependen de ellos.
- La dieta no puede contradecir los alérgenos: `save_recipe` rechaza (`invalid_payload`, `diet`) un plato vegano con leche, huevos, pescado, crustáceos o moluscos, y uno vegetariano con pescado, crustáceos o moluscos; la app lo avisa antes de guardar. Si no, se le ofrecería a un cliente con esa dieta (el control por dieta mira la etiqueta del plato).
- Al armar un menú, cualquier receta que choque con una restricción del cliente se marca en rojo. **Enviar presupuesto con un conflicto exige una confirmación explícita** de Evelyn (ej.: "adapto la receta sin lácteos") que queda guardada en el presupuesto.
- La celiaquía exige nota de contaminación cruzada visible en la sesión.
- Sugerencias (M2b): el cliente ve tachados los platos que chocan con sus restricciones guardadas y no puede sugerirlos. Sugerir no cambia el control: Evelyn arma el menú con la marca en rojo y la confirmación explícita de arriba.
- Eventos: las recetas creadas para el evento llevan sus alérgenos, como las del catálogo, y las restricciones que cuentan son las del pedido (las de los invitados, `requests.restrictions`), nunca las de la ficha del hogar. Una nota libre de alergias no se cruza sola con las recetas: Evelyn la revisa antes de enviar el presupuesto.

### 5.7 Cancelaciones (a definir por Evelyn; propuesta)
| Cuándo cancela el cliente | Servicio |
|---|---|
| Más de 48 h antes | 0 % (se libera la retención) |
| Entre 48 h y 12 h | 50 % |
| Menos de 12 h | 100 % |

Sin compra (19/11/2026) no hay insumos que cobrar ni liberar: la compra es del cliente.

Guardar la política en `chef_settings.cancellation_policy` y mostrarla antes de aceptar el presupuesto.

Con `pay_after` no hay tarjeta guardada: la penalidad no se puede cobrar automáticamente. Decidir si se pide tarjeta a todos los clientes (sección 14).


### 5.8 Presupuesto y menú de cada semana (proceso de Nicolas del 21/11/2026)

1. La clienta pide desde la web, como siempre.
2. Evelyn recibe el pedido (email y bandeja).
3. Evelyn prepara el presupuesto dentro del pedido: semanas, fechas, hora y precio, y el menú de la semana 1.
4. **Menú de una semana** (una sesión, ligada al pedido por `sessions.request_id`):
   - Platos del catálogo con sus porciones en la semana. En la semana 1 vienen los que la clienta eligió en la web. Si un plato no existe, Evelyn lo crea desde ahí y queda elegido.
   - Si un plato choca con las alergias del pedido, la app pide confirmarlo (§9, criterio 8) y queda registrado (`session_menus.allergens_confirmed`).
   - La lista de compras sale de los ingredientes por las porciones (los ingredientes son para 4), juntando los iguales y agrupada por sección del súper. Evelyn la edita y se guarda tal como queda.
   - Una nota opcional para la clienta.
5. **Envío.** Evelyn ve la vista previa en el idioma de la clienta (los nombres de la lista se traducen solos, como los platos; la nota sale tal como la escribe Evelyn, que la escribe en el idioma de la clienta: decisión del 22/11/2026) y lo manda por email, por WhatsApp o por los dos. El mensaje dice todo sin dejar dudas:
   - los días y la hora de llegada;
   - los platos, con su descripción, sus alérgenos y sus porciones;
   - la lista de compras con cantidades y qué tener listo;
   - la nota;
   - un link para confirmar.

   Nunca lleva la dirección, las alergias de la clienta ni nada de pagos.
6. **La clienta confirma** el presupuesto y el menú en el link (todavía no tiene cuenta), o pide cambios. Evelyn los hace y vuelve a enviar.
7. **Semanas siguientes:** Evelyn vuelve al mismo pedido, arma el menú de la semana siguiente, lo envía y la clienta lo confirma.
8. **Avisos a Evelyn por email** si el menú de una semana todavía no se envió:
   - 4 días y 72 h antes de la cocina;
   - pasado el límite de 48 h, cada 2 horas, sobre ese pedido, hasta que lo envíe o empiece la sesión.
9. Después del servicio se cobra como hoy. Este proceso no cambia ni especifica nada de pagos.

Se construye en PRs chicos: base del menú, menú en la app, envío y link, página de la clienta, avisos y presupuesto. Esta sección se completa con cada uno.

**Base del menú** (migración `20261121090000_session_menus.sql`, tests pgTAP `19_session_menus`). `save_session_menu(p jsonb)` guarda en una transacción, con la RLS de quien llama (security invoker), la cocinera o un colaborador:
- los platos con sus porciones (`session_menu`) y la lista (`session_shopping_items`), que se reemplazan enteros;
- la nota y la confirmación de alérgenos (`session_menus`), que si no vienen no se tocan.

Control de versión: `version` es la que la app tenía cargada (null = todavía no había menú). Si no coincide, nada se escribe (`menu_changed`, 40001), así Evelyn y un colaborador nunca se pisan en silencio. Una receta tiene que ser de la cocina y no repetirse; una desactivada después de elegirla sigue valiendo.

Solo se arma una sesión `held` o `confirmed` (o una vieja en `shopping_done`). Una cancelada, cocinada o cobrada da `session_not_editable` (55000).

Errores: `not_a_chef`, `invalid_payload` (con el campo), `session_not_found`, `recipe_not_found` (con el campo) y los checks de las tablas. Una clave desconocida es un error, como en `save_recipe`.

La lista y la nota son solo de la cocinera: la clienta las recibe en el mensaje y en su link. La política vieja que deja a una clienta con cuenta leer `session_menu` de sus sesiones se revisa en M2, para que vea solo los menús enviados.

**Menú en la app** (`app/lib/features/week_menu/`, pantalla `/sessioni/:id/menu`). Se llega desde el bloque «Menú de la semana» de la ficha de la sesión, desde las semanas de la reserva en el detalle del pedido aceptado, desde «Menús para mandar» en Hoy (§7), al confirmar una reserva, con «Armar el menú de la semana 1» (la acción principal de esa pantalla final), y al crear un presupuesto, que abre el de la semana 1 («Presupuesto en la app», abajo). Una semana cancelada no tiene menú; una cocinada o cobrada lo muestra sin dejar cambiarlo. Un colaborador usa las mismas pantallas (§7).
- Arriba la clienta, «Semana k de N», el día con la llegada, las personas y las alergias de la reserva como en la ficha (§6: nunca «sin alergias» sin datos).
- Los platos, en orden, con su nombre en el idioma de la app (el italiano si falta), su foto y sus porciones (de 1 a 500). Uno que se agrega empieza con (adultos + niños) × comidas por día del pedido: un plato es más o menos un día. El selector muestra los platos activos que no están en el menú, con búsqueda, y marca los que chocan; «Nuevo plato» abre el editor de platos encima, sin ruta ni entrada en el historial del navegador. El plato guardado entra al menú (también si la foto falló), y los que estaban marcados en el selector entran igual. La semana 1 sin menú guardado empieza con los platos que eligió la clienta en la web, los que siguen activos; lo dice mientras todos los platos sean de esos.
- Un plato choca con la reserva si lleva un alérgeno que la reserva evita o si no está marcado con su dieta (vegetariana: vegetariano o vegano; vegana: vegano). La nota de alergias es texto libre y no se cruza: se muestra resaltada. Al guardar con choques, la app los lista y pide confirmarlos; `allergens_confirmed` queda en true (false si no hay choques).
- La lista de compras: cada ingrediente (para 4 porciones) por las porciones del plato, para arriba; en g y ml, de 100 para arriba, a la decena siguiente (103 g → 110 g); las piezas quedan como dan. Los iguales (mismo nombre, sin importar mayúsculas ni espacios, y misma unidad) se suman, con el nombre y la sección de la primera vez; un «q.b.» va una sola vez, y ninguna si el mismo ingrediente va con cantidad. Por sección del súper y, dentro de cada una, en el orden en que aparecen; hasta 1.000.000 por renglón y 150 renglones (si sobran, lo dice). Se muestra 1250 g como 1,25 kg y se guarda en g, ml o piezas.
- Mientras Evelyn no la toca, la lista sigue a los platos. Si cambia, quita o agrega un renglón queda a mano, y «Rehacer la lista con los platos» (con confirmación) la vuelve a armar; «Deshacer» un renglón quitado de una lista que seguía a los platos la deja siguiéndolos. Un menú guardado abre siguiendo a los platos si su lista es justo la que sale de ellos. Si no, no se sabe si la cambió ella o cambió una receta después: la lista guardada queda y un aviso neutro ofrece rehacerla. La base no guarda esa marca.
- Los nombres de la lista le llegan a la clienta traducidos solos a su idioma (`requests.locale`): la lista y el diálogo de cada renglón lo dicen, con el idioma, y piden no escribir datos personales.
- La nota (hasta 1000 caracteres, con saltos de línea) le llega tal como la escribe Evelyn: la ayuda le pide escribirla en el idioma de la clienta (y dice cuál) y no escribir datos de salud, direcciones ni otros datos personales; el ejemplo está en ese idioma.
- Guardar manda la versión cargada. Si otro teléfono guardó antes (`menu_changed`), lo dice y ofrece cargar lo guardado o seguir viendo lo propio. Si lo guardado es un guardado propio, no hay conflicto: lo mismo que se mandaba (un reintento cuya respuesta se perdió) quedó guardado, y el último guardado que se quedó sin respuesta, con la versión siguiente, hace que se reenvíe lo de ahora con esa versión. Sin conexión, lo escrito queda para reintentar. Si la sesión ya no admite menú o ya no existe, el editor queda a la vista pero bloqueado y la ficha se vuelve a leer. Con cambios sin guardar, salir pregunta (también el atrás del navegador en `/gestione/`).

**Envío del menú** (migración `20261121100000_menu_sends.sql`, pgTAP `20_menu_sends`; función `chef`, contrato chef-api §13). En dos pasos, desde la app:
1. **Vista previa** (`POST /chef/menus/preview`): la función arma el mensaje en el idioma de la clienta (el de su pedido) y guarda el envío todavía sin salir (`menu_sends`), con la foto de lo que va a recibir: los platos con sus traducciones guardadas, la lista, la nota y las fechas. La lista la escribe Evelyn en español: si la clienta lee italiano o inglés, los nombres de los renglones se traducen ahí con Claude, con el mismo límite que los platos; si la traducción falla, la app ofrece mandarlos sin traducir. La nota sale como la escribió Evelyn: nunca se traduce ni va a Anthropic (decisión de Nicolas del 22/11/2026, §6). Evelyn ve el mensaje sin el link (en su lugar, un texto de reemplazo) y el contacto (el del pedido de la web o el de la ficha), y elige email, WhatsApp o los dos.
2. **Envío** (`POST /chef/menus/send`): la función crea el link de la clienta (un token al azar en el fragmento de la URL, `/prenotazione/#t=…`; la base guarda solo su hash, `client_links`), manda el email (Resend; las respuestas le llegan a Evelyn) y marca el envío enviado. Si el email no sale, el envío queda sin marcar y la app ofrece reintentar o mandarlo solo por WhatsApp. El WhatsApp lo abre la app desde el teléfono de Evelyn, con el texto y el link que devuelve la función: el servidor nunca lo manda.

La clienta recibe siempre la foto de la vista previa: hace falta otra vista previa si cambió el menú, el día o la hora, las semanas de la reserva o un plato del catálogo (`menu_changed`; la base guarda la huella de lo que entró en la foto y la vuelve a calcular al mandar y al marcar). La vista previa de una semana cancelada, cocinada o cobrada no se arma (`session_not_editable`). El mensaje nunca lleva la dirección, el contacto, las alergias de la clienta ni nada de pagos, y de su nombre solo el de pila, si parece un nombre (el email o el teléfono pueden venir del formulario, sin verificar).

**Envío en la app** (`app/lib/features/week_menu/`: `menu_send_controller.dart`, `menu_send_screen.dart`, `menu_send_status_view.dart` y `data/menu_sends_repository.dart`). «Mandar», al lado de «Guardar el menú» en el editor, y «Mandar a la clienta» (o «Mandar de nuevo») en el bloque de la ficha abren la vista previa encima, sin ruta, con la versión guardada del menú y algún plato; con cambios sin guardar, el editor pide guardarlos antes. Desde las semanas de la reserva se llega por el editor.
- La vista previa (traducida, por defecto) dice a quién va, en qué idioma y si la lista se tradujo, deja elegir email y WhatsApp (cada uno deshabilitado, con el porqué, si el contacto no tiene uno que sirva) y muestra el WhatsApp o el email con su asunto tal como los arma la función, con el texto de reemplazo del link.
- Si la traducción falla, lo dice y ofrece «Reintentar» (solo si la falla es pasajera: sin respuesta o 503) y «Seguir sin traducir» (otra vista previa con `translate: false`; también con un 500 mientras traducía, que puede ser la traducción, como una clave de Claude revocada o sin crédito); nunca reintenta sola. Si el menú se guardó en otro teléfono después de cargarlo, desde el editor vuelve a él, que carga lo guardado, y desde la ficha ofrece la vista previa de lo guardado (si no pudo leer la versión guardada, el reintento la vuelve a leer). Si al mandar cambió algo desde la vista previa, ofrece otra. La falla del envío aparece arriba de la vista previa y se trae a la vista.
- Al mandar con WhatsApp, la app lo abre desde el teléfono de quien manda con el texto y el link que devuelve la función: en el teléfono, sola; en `/gestione/`, con «Abrir WhatsApp» (el navegador bloquea una ventana que no sale de un toque). El envío ya quedó registrado: la pantalla recuerda tocar «Enviar» en WhatsApp. Si el email no sale, «Reintentar» o «Mandar solo por WhatsApp»; sin email configurado en el servidor, solo por WhatsApp; si el contacto cambió y ya no sirve, mandarlo por el otro canal u otra vista previa.
- Un toque doble o una respuesta perdida nunca mandan dos veces: mientras manda no acepta otro envío y el reintento usa el mismo envío. Si ya había salido (`alreadySent`), la app lo confirma leyendo `menu_sends`, con los canales por los que salió (no los que pidió el reintento) y sin el texto del WhatsApp (el link solo viaja en la respuesta: si salió por WhatsApp, para mandarlo hace falta otra vista previa). Sin respuesta (no se sabe si salió), la ficha, el editor, la reserva y Hoy vuelven a leer el envío al fallar y otra vez al cerrar la pantalla (el servidor pudo terminar después): si salió, no lo siguen ofreciendo como sin mandar. Si el email salió pero el envío no quedó registrado (`emailSent`), lo dice: reintentar manda otro email, con otro link.
- Donde se muestra el menú de una semana (el editor, la ficha y las semanas de la reserva, estas con una sola consulta para todas) se ve su último envío, leído de `menu_sends`: sin mandar; mandado el día y la hora, por email, por WhatsApp o por los dos; confirmado por la clienta; o cambios pedidos, con su mensaje entero, en varios renglones y seleccionable (solo en la app: §6). Si la versión guardada es más nueva que la mandada, dice que el menú cambió después de mandarlo y que hay que mandarlo de nuevo. En una semana confirmada, si su último envío llevaba una versión anterior del presupuesto (después salió otro envío de ese presupuesto, desde otra semana) y nadie lo confirmó, también dice que hay que mandarlo de nuevo, como los avisos («Avisos a Evelyn»; para saberlo se leen los envíos de ese presupuesto, solo si hace falta).

**Link de la clienta** (Edge Function `client-link` y página `/prenotazione/`; contrato `docs/contracts/client-link.md`). Cada mensaje del menú lleva `https://radicicucina.app/prenotazione/#t=<token>`: el token (32 bytes al azar) va en el fragmento, que no llega a ningún servidor, y es la llave hasta que la clienta tenga cuenta (M2). La base guarda solo su hash (`client_links`) y un link abre la reserva entera durante 15 días (decisión de Nicolas del 22/11/2026: la semana termina y ese link no se usa más; cada mensaje lleva uno nuevo).
- La página llama a la función, pública como `public-request` (sin JWT, con su propio límite por IP). `POST /view` devuelve las semanas no canceladas (su sesión, fecha, hora de llegada, si ya se cocinó) y, de cada una, el último menú enviado tal como salió y su estado: los platos con descripción, alérgenos, dieta, porciones y foto; la lista por sección del súper, con lo «q.b.» aparte, para tener en casa; la nota de Evelyn. De la clienta, solo el nombre de pila con que llegó el pedido (o el de la ficha), si parece un nombre. Si Evelyn le mandó un presupuesto, también lo trae, con lo que vio la clienta (abajo, «Presupuesto»): del precio, solo el del servicio de ese presupuesto. Nada de pagos, dirección ni alergias.
- La clienta confirma el menú de una semana (`POST /confirm`) o pide cambios con un mensaje de 1 a 1000 caracteres (`POST /changes`); el campo pide no escribir datos de salud. Si Evelyn mandó un menú más nuevo, se contesta ese (`menuOutdated`) y la página lo muestra. Uno confirmado no se cambia desde el link: se habla con Evelyn. Una semana cancelada después del envío ya no se contesta (`sessionCancelled`), y una ya cocinada se ve sin botones ni promesas.
- Cada respuesta le avisa a Evelyn por email (`CHEF_NOTIFY_EMAIL`, en `CHEF_LOCALE`, con el botón al pedido en la bandeja), salvo una confirmación repetida. El mensaje de la clienta no va en el email (es una nota libre, §6): Evelyn lo lee en la app. Un email que falla no rompe la respuesta de la clienta.
- La página sale en el idioma de la reserva, salvo que la clienta haya elegido otro; el token nunca sale de la URL (los links de idioma y las anclas internas lo conservan); nunca se indexa y su CSP suma solo el origen de Supabase (la función y las fotos). El presupuesto se acepta en esta misma página, arriba de las semanas (abajo, «Presupuesto»).

**Avisos a Evelyn** (migración `20261121110000_menu_reminders.sql`, tests pgTAP `21_menu_reminders`; Edge Function `menu-reminders`). Una semana está pendiente si:
- es de una reserva y está confirmada (una `held` es de un presupuesto sin aceptar);
- empieza dentro de 4 días;
- no tiene ningún envío del menú que haya salido, o en el último la clienta pidió cambios (o llevaba una versión anterior del presupuesto y nadie lo confirmó: abajo, «Presupuesto»);
- se creó hace más de una hora.

Para una semana pendiente, Evelyn recibe un email a `CHEF_NOTIFY_EMAIL`, en `CHEF_LOCALE`:
- 4 días antes de la cocina;
- 72 h antes, si sigue pendiente;
- pasado el límite de 48 h, cada 2 horas, hasta que lo envíe o empiece la sesión.

Si Evelyn mueve la semana, los avisos vuelven a empezar para la fecha nueva. Los de cada 2 horas tienen 5 minutos de tolerancia, porque pg_cron pasa cada 15 minutos.

Ningún aviso sale de noche: solo de 8:00 a 20:59, hora de Roma (§8). El que cae de noche sale a las 8:00. Las semanas que tocan en un mismo turno van en un solo email, con la clienta, la semana, el día y la hora de la cocina, el límite y el link al pedido en `/gestione/`. Nunca lleva alergias ni direcciones.

Cómo funciona:
1. pg_cron corre `private.call_menu_reminders()` cada 15 minutos.
2. Esa función llama a la Edge Function con pg_net, usando la URL y un secreto que el despliegue genera en cada corrida y guarda en Vault y como `MENU_REMINDERS_SECRET` de la función. Sin ellos, en local, no hace nada.
3. La función lee `menu_reminders_due` y manda el email.
4. Recién entonces marca los avisos con `menu_reminders_mark`. Si el email falla, el turno siguiente lo reintenta.

Los avisos se prenden con el primer despliegue que guarda la URL y el secreto en Vault. Por eso este cambio se mergea después de la pantalla de envío de la app: si no, a Evelyn le llegarían avisos de semanas que todavía no puede mandar.

**Presupuesto** (migración `20261121120000_quotes.sql`, tests pgTAP `22_quotes`):
- **Preparar.** Desde un pedido `new`, semanal o extra, sin otro presupuesto abierto, `chef_create_quote` crea una sesión `held` por semana (pago manual, como las reservas) y el presupuesto, sin enviar. Valida fechas, hora, minutos, porciones y precio como `chef_create_booking` y reparte el precio entre las semanas. El borrador retiene el horario 24 h (nunca más allá de la llegada de la primera semana); el pedido sigue `new`. La página de la clienta no muestra las semanas de un borrador.
- **Enviar.** Sale con el menú de la semana 1: el envío de esa semana lleva el presupuesto (`menu_sends.quote_id`) y sus términos (`quote_terms`: semanas, horas y precio, calculados por la base; la huella de la foto los incluye). Si cambian antes de mandarlo, el envío no sale (`quote_changed` o `menu_changed`). Al salir, el pedido pasa a `quoted`, el presupuesto guarda los términos enviados (`pricing_snapshot`) y el horario queda retenido `quote_hold_hours` (48 h), nunca más allá de la llegada de la primera semana. Cada reenvío es otra versión y el plazo vuelve a empezar. La versión es la que ve la clienta: el primer presupuesto que le llega de un pedido es la 1, aunque antes haya vencido o se haya retirado un borrador que nunca salió (no gasta número); después de uno que le llegó y se retiró, el nuevo es la versión siguiente («aggiornato»). Mientras no lo acepte, solo la semana 1 sale (`quote_week_not_first`).
- **Cambiar o retirar.** Evelyn cambia el precio con `chef_update_quote` y las fechas y semanas con `chef_move_session` y `chef_cancel_sessions`; después tiene que reenviarlo, y mientras tanto la clienta no puede aceptar (la página lo muestra como cambiado). `chef_withdraw_quote` cancela las semanas (`quote_withdrawn`) y el pedido vuelve a `new`. Si el pedido sigue por otro camino, el presupuesto abierto se retira solo:
  - Evelyn lo confirma sin presupuesto (`chef_create_booking` desde el pedido, también si el presupuesto ya salió y el pedido está `quoted`): se retira antes de crear las semanas, en la misma transacción. Sus semanas `held` se cancelan (`quote_withdrawn`) y no chocan con las nuevas, aunque sean las mismas fechas y hora; el `dryRun` tampoco las cuenta como ocupadas. Si una semana choca con otra reserva, no se retira nada.
  - Evelyn rechaza el pedido desde la bandeja: lo retira `requests_close_open_quotes`.
- **La clienta, en su link:**
  - acepta la última versión (`client_link_accept_quote`), y solo con los términos que vio (si Evelyn los cambió sin reenviarlo, `quote_changed`): las semanas pasan a `confirmed`, el pedido a `accepted`, la ficha de prospecto a `trial`, el presupuesto guarda lo aceptado y el menú de la semana 1 queda confirmado;
  - la rechaza (`client_link_decline_quote`, también solo la última versión): semanas canceladas (`declined`) y pedido `declined`;
  - o pide cambios con un mensaje, como con cualquier menú.

  Un menú que va con un presupuesto abierto no se confirma solo (`quote_pending`): se acepta el presupuesto. Tampoco el de un envío anterior del mismo presupuesto que quedó en otra semana (la que lo llevaba pasó al final y Evelyn lo reenvió desde la nueva primera). Aceptado el presupuesto, ese menú se confirma o se le piden cambios como cualquier otro, y mientras nadie lo confirme esa semana sigue pendiente para los avisos.

  El link muestra el último presupuesto que le llegó a la clienta, salvo uno cerrado sin aceptar (rechazado, retirado o vencido) cuando la reserva se confirmó sin él.
- **Vencer.** Pasado el plazo no se acepta, y `private.expire_quotes` (pg_cron, cada 15 minutos) cancela las semanas (`hold_expired`) y pasa el pedido `quoted` a `expired`. Un borrador que nunca salió deja el pedido en `new`.
- **Función `chef`** (contrato chef-api §14): `POST /chef/quotes` prepara el presupuesto (los campos de una reserva desde un pedido; con `dryRun`, los avisos de cada fecha), `POST /chef/quotes/price` le cambia el precio y `POST /chef/quotes/withdraw` lo retira, con cada error de la base traducido (`quoteExists`, `requestNotQuotable`, `quoteClosed`, `quoteEmpty`, …). Confirmar sin presupuesto desde el pedido (`POST /chef/bookings`, chef-api §4) no necesita retirarlo antes: con el pedido `new` o `quoted`, lo retira y responde `201` como cualquier reserva, sin errores nuevos. La vista previa de la semana 1 suma el presupuesto a la foto del envío (las semanas con su fecha, su llegada y su precio, el total, las horas para aceptarlo y la primera llegada; la versión que va a salir), y el mensaje lo presenta primero: cuántas semanas, cada fecha con su llegada, el precio del servicio de todas (y el de cada semana si no son iguales), hasta cuándo puede aceptarlo («entro 48 ore» o, si la primera llegada es antes, «prima di <día>, alle <hora>»), que mientras tanto esas fechas (o esa fecha, con una sola semana) quedan reservadas para ella y que desde el link lo acepta con el menú, pide cambios o lo rechaza. Desde la versión 2 (la clienta ya recibió otra) dice «il preventivo aggiornato». Nunca cómo ni cuándo se paga. Una semana `held` que no es la primera (`quoteWeekNotFirst`), un presupuesto cerrado (`quoteClosed`) o términos que cambiaron (`quoteChanged`) no salen.
- **Link y página** (contrato client-link §4, §5 y §10): `/view` trae el presupuesto (estado, versión, plazo y el envío que lo lleva) y lo que vio la clienta, sacado de la foto de ese envío, solo por aceptar o aceptado; `POST /accept` y `POST /decline` contestan con las protecciones de las demás respuestas, y la primera vez le avisan a Evelyn («Anna aceptó el presupuesto: 4 semanas, 560,00 €» o «Anna rechazó el presupuesto»; sin texto libre). La página lo muestra arriba de las semanas: las semanas con su llegada y su precio, el total y el estado (por aceptar, con el plazo en hora de Roma; con cambios pedidos; cambiado, con Evelyn preparando otra versión; aceptado; rechazado; retirado; vencido), con «Accetto il preventivo» (acepta también el menú de la semana 1) y «Rifiuto», que abre debajo un paso para confirmarlo («No, torna indietro» o «Sì, rifiuto il preventivo»). Un doble toque en «Rifiuto» nunca rechaza: «Rifiuto» queda en su lugar (tocarlo de nuevo cierra el paso), nada de lo de arriba se mueve (abrir o cerrar el paso no borra los avisos ni el error de aceptar que estén a la vista: se van con la próxima respuesta), y «Sì» no responde hasta 600 ms después de abrir el paso. Mientras está abierto, la semana 1 no ofrece «Confermo il menù» (sí «Chiedo dei cambi»), y un envío anterior del mismo presupuesto que quedó en otra semana tampoco: dice que se confirma después de aceptar el presupuesto, que no lo confirma. Si una respuesta no se registra porque el presupuesto ya se cerró, el aviso dice eso, sin repetir el estado; si su semana ya no está, va arriba, con la fecha. Si lo que ya no está es el presupuesto (Evelyn confirmó la reserva sin él mientras la clienta tenía la página abierta, o mandó otro), el aviso también va arriba y dice por qué no se registró: Evelyn confirmó directamente la reserva, o le mandó un presupuesto nuevo, que está debajo. Con una sola semana, la página, el mensaje y el aviso a Evelyn hablan de una fecha, en singular. La privacy lo cuenta desde su versión `2026-11-23` (§6).

**Presupuesto en la app** (`app/lib/features/quotes/`: `domain/request_quote.dart`, `domain/preview_quote.dart`, `domain/quote_api.dart`, `data/quotes_repository.dart`, `application/quote_providers.dart` y `presentation/quote_block.dart`; la hoja es la de «Confirmar reserva», `BookingSource.quote`). En el detalle de un pedido nuevo, semanal o extra, la acción principal es «Preparar presupuesto»; la de antes pasa a «Confirmar sin presupuesto» (la misma hoja) y «Rechazar» sigue. Con un presupuesto abierto no se prepara otro, pero «Confirmar sin presupuesto» sigue, también con el pedido en `quoted`: la base retira ese presupuesto en la misma transacción (sus semanas retenidas no cuentan como ocupadas en el dryRun), y la hoja lo avisa arriba y, antes de confirmar, pregunta si seguir (la clienta ya no lo puede aceptar desde su enlace). Si la semana 1 tiene un menú guardado, el aviso y la pregunta dicen que ese menú se va con la semana cancelada y que después hay que armarlo y mandarlo de nuevo (si la clienta todavía lo puede aceptar desde su enlace —mandado, a tiempo y sin cambios pedidos ni cambios sin reenviar—, también que si lo acepta el menú queda confirmado tal cual; con cambios pedidos, cambiado o vencido no lo dice, porque no lo puede aceptar); la pregunta antes de retirarlo, también. Las dos preguntas se deslizan si con el texto grande no entran. Un pedido en `quoted` sin un presupuesto leído es un dato viejo: la hoja avisa igual que retira el mandado.
- La hoja es la de la reserva (semanas, fechas, llegada, minutos y porciones prellenados del pedido, y los avisos del dryRun de cada fecha: solo un choque impide crearlo), salvo que la primera fecha arranca en la preferida del pedido o, si es hoy o ya pasó, mañana, y que una llegada que ya pasó o es de ese mismo minuto (una fecha pasada, u hoy con esa hora, mirada con la hora de cuando se toca «Crear») tampoco deja crearlo: el presupuesto nacería vencido (en la reserva es solo un aviso, para cargar lo ya hecho). La hoja dice por qué en la semana y en la barra de abajo (el lector de pantalla lo anuncia). Por ahora esa defensa es solo de la app: la base todavía acepta en `/quotes` una primera llegada pasada y deja mandar un presupuesto cuyo plazo ya pasó mientras el cron no lo cerró (hasta 15 minutos); rechazarlo también en la base (`invalid_dates` al crearlo, `quote_closed` con `hold_until <= now()` al prepararlo o mandarlo) queda para un cambio de la base, con su pgTAP. Lleva el precio del servicio de todo el presupuesto y, debajo, cuánto va exactamente en cada semana (los centavos que sobran, a las primeras, como `split_cents`). «Crear el presupuesto» va a `POST /chef/quotes` y la hoja se reemplaza por el menú de la semana 1, que avisa que sale junto con el presupuesto. La ruta no tiene clave: si la creación se queda sin respuesta, el reintento recibe `quoteExists` y la hoja toma el presupuesto que encuentra solo si es el que mandó (un borrador con esas fechas, esa hora, esos minutos y ese precio); si no, lo dice.
- El bloque «Presupuesto» del pedido (leído con la RLS en una consulta: `quotes`, sus semanas en `sessions` y el último envío que lo llevó en `menu_sends`) dice su estado con la prioridad de la página de la clienta: borrador sin mandar y hasta cuándo retiene las fechas; mandado, con la versión, cuándo salió y hasta cuándo puede aceptarlo (hora de Roma); los cambios que pidió la clienta, con su mensaje entero; cambiado sin reenviar (sus términos ya no son los del último envío); aceptado, rechazado, retirado o vencido. Con cambios pedidos o cambiado, la clienta no lo puede aceptar hasta recibirlo de nuevo: en lugar de «puede aceptarlo hasta…», dice, resaltado, hasta cuándo hay que mandárselo de nuevo antes de que venza y se liberen las fechas. Vencido después de que la clienta pidió cambios no dice «sin respuesta» (dice que no le llegó la versión con los cambios), y su mensaje sigue a la vista también si se cerró sin aceptarse (vencido, rechazado o retirado), sin el «qué hacer». Abierto, sus semanas vivas (fecha, llegada y precio) y el total; cerrado, las que salieron. Cada semana abre su ficha, donde se mueve o se cancela (avisa que el presupuesto cambia): el bloque se vuelve a leer y dice que hay que mandarlo de nuevo (un borrador, que todavía no salió, no). Con una sola semana (un pedido extra o una semana), la app habla de una fecha: sin «semana 1» ni «todas las semanas», en el bloque, la barra, los diálogos, la hoja, la vista previa, el editor y la ficha.
- El bloque sigue al pedido: si el pedido cambia de estado (rechazarlo retira el presupuesto, `requests_close_open_quotes`; la hoja recibe que ya no está nuevo; una relectura de la bandeja trae lo que hizo la clienta, el cron u otro teléfono), el presupuesto se vuelve a leer; y si se cerró en otro lado, la agenda y «Menús para mandar» vuelven a leer sus semanas. Desde un pedido la hoja se puede cerrar mientras espera al servidor: igual se vuelven a leer el pedido y su presupuesto cuando responde.
- Abajo, una al lado de la otra, «Confirmar sin presupuesto» y la principal: «Preparar presupuesto» sin uno abierto, o «Mandar el presupuesto» (borrador) o «Mandar de nuevo» (cambiado o con cambios pedidos), que abre la vista previa del menú de la semana 1, que lo lleva; sin menú guardado con platos, deshabilitado con el porqué (si el menú no se pudo leer, lo dice con «Reintentar», en la barra y en el bloque, sin afirmar que falta). Mandado y a la espera, «Mandar de nuevo» va en el bloque, con el menú de la semana 1, «Cambiar el precio» (un diálogo con el reparto exacto → `/quotes/price`; si ya salió, avisa que hay que mandarlo de nuevo) y «Retirar el presupuesto» (con confirmación → `/quotes/withdraw`). Sin semanas vivas, solo se retira.
- El menú de otra semana del presupuesto no se manda hasta que lo acepte: el editor y la ficha lo dicen y «Mandar» queda deshabilitado (`quoteWeekNotFirst` se traduce igual).
- La vista previa de la semana 1 lee de `menu_sends` (RLS) el presupuesto de su foto (`snapshot.quote`: la respuesta de la vista previa no lo trae) y lo muestra arriba del mensaje: cada semana con su fecha, su llegada y su precio, el total y hasta cuándo puede aceptarlo si sale ahora (las horas del plazo o, si la primera llegada es antes, esa llegada). `quoteClosed` lo dice sin otra vista previa; `quoteChanged`, con otra. Un presupuesto que se cerró sin aceptarse (rechazado, retirado o vencido) llega como la semana cancelada (`sessionNotEditable`: la base contesta por la sesión antes que por el presupuesto), y también se vuelve a leer. Al mandarlo, el pedido (que pasa a `quoted`) y el presupuesto se vuelven a leer, también si la respuesta se pierde (al fallar y otra vez al cerrar la pantalla: pudo haber salido), y el detalle vuelve a leer un pedido que quedó viejo frente a su presupuesto (la clienta contestó, venció).
- La bandeja y la agenda dicen el estado de un pedido con el presupuesto mandado, rechazado o vencido; una semana cancelada de un presupuesto, si se retiró, venció o la clienta lo rechazó. En Hoy, «Menús para mandar» suma la semana 1 de un presupuesto sin aceptar, con el plazo del presupuesto como límite si vence antes que el del menú (§7). Nada dice cómo ni cuándo se paga.

«Confirmar sin presupuesto» (`chef_create_booking`) sigue, para lo que se acordó por fuera: desde un pedido con un presupuesto abierto, lo retira (arriba, «Cambiar o retirar»). Nada de esto toca los pagos.

---

## 6. Seguridad, privacidad y RGPD

- **Alergias, intolerancias y celiaquía son datos de salud** (art. 9 RGPD): consentimiento **explícito y separado** del de privacidad, con versión del texto y fecha (`consents`). Sin consentimiento no se guardan las restricciones.
- Una reserva cargada a mano, o una renovación, no guarda alergias ni restricciones: falta el consentimiento de salud de la clienta (M2).
- Alergias de una sesión, donde la app las muestra (la ficha de la sesión y Hoy): valen las del pedido de su reserva. Si es una sesión semanal (o sin pedido) y ese pedido no responde (ni alérgenos, ni nota, ni la confirmación «nadie tiene»; por ejemplo, una renovación), las del último pedido semanal de la web que se reservó (aceptado) de la misma ficha, con la fecha de ese pedido (decisión del dueño del 18/11/2026). Si ese pedido tampoco responde (uno anterior a la pregunta, o uno cuya respuesta se borró: consentimiento de salud retirado o copia borrada, contrato public-request §10.2), no se busca uno anterior: un «nadie tiene» viejo ya no vale, y dice «sin datos». Solo semanales, como las restricciones del hogar (`client_restrictions` sale solo de un pedido semanal): en una sesión o un pedido extra los que comen pueden ser otros, como los invitados de una cena (5.6), así que una extra no toma la respuesta de otro pedido. Solo aceptados: mientras la ficha es un prospecto, cualquier envío con su email se pega a ella (sin verificar: pudo mandarlo otra persona), y uno rechazado, vencido o pendiente no cuenta. Los alérgenos de la ficha se suman siempre. Una dieta sola no responde sobre alergias: se muestra, pero no reemplaza la respuesta.
- Alergias de una sesión sin ningún dato (ni alérgenos de la ficha, ni nota o alérgenos de su pedido o, en una semanal, del último pedido semanal de la web que se reservó, ni la confirmación «nadie tiene»): dice «sin datos en la app, pregúntale», resaltado como advertencia; nunca «sin alergias». También con solo una dieta. El detalle de un pedido aplica la misma regla a lo que trae ese pedido.
- Mínimo necesario: guardar la restricción ("sin lactosa"), no diagnósticos ni historia clínica.
- Solo la cocinera y sus colaboradores (`chef_members`) ven restricciones y direcciones. Nunca se escriben en logs, Sentry ni analytics. Colaboradores y privacy (decidido el 16/11/2026 por el dueño del proyecto): la privacy y el consentimiento de salud no cambian; el único colaborador es quien gestiona el sistema por cuenta de Evelyn, a quien la privacy ya nombra (`privacy.healthBody` y `privacy.recipientsBody`). Sumar a otra persona exige antes una versión nueva de la privacy y del consentimiento de salud (`request.healthConsentLabel`, `HEALTH_CONSENT_VERSIONS`) que la nombre.
- Derecho de acceso y borrado: exportar los datos del cliente (JSON) y borrar su cuenta desde la app. Incluye las copias de restricciones en `requests.restrictions` y `quotes.pricing_snapshot`, los menús enviados con sus respuestas desde la página de la reserva (`menu_sends`: la confirmación y el mensaje de cambios) y los presupuestos con la suya (`quotes`: aceptado o rechazado, con los términos). Hasta M2 se hace desde el SQL editor (contrato public-request §10.2).
- Conservación: los prospectos que no se convierten se borran con un cron cuando pasan `prospect_retention_days` (90) desde su último pedido. Si la persona pasa a ser clienta (en Fase 0, por WhatsApp), la cocinera le confirma la reserva o la marca como cliente desde el detalle del pedido: la ficha pasa a `trial` y se conserva.
- Un envío del formulario público (sin login, email sin verificar) nunca modifica a una persona que ya existe: cada pedido guarda el contacto con que llegó (`requests.contact`) y las restricciones del hogar solo se suman, desde pedidos semanales.
- Las altas de usuarios van apagadas hasta el área de clientes (M2): la cuenta de la cocinera la crea confirmada el despliegue de Supabase (o el panel) antes de publicar nada, y `promote_to_chef` le cambia la contraseña por una al azar y le cierra las sesiones. En M2 se abren a cualquiera (registro abierto, D3): ese PR cambia esta regla, la de `CLAUDE.md` y el contrato §10.
- Quién entra al área de Evelyn (`/gestione/` y la app): la cocinera y sus colaboradores, cada uno con su email y su código. Las cuentas de los colaboradores también las crea confirmadas el despliegue (secreto `CHEF_MEMBER_EMAILS`, emails separados por coma; contrato public-request §10.1), en cada despliegue, en el último paso (después de publicar las funciones, así un error en la lista no deja la base migrada con las funciones viejas): la lista manda. Un email nuevo recibe su cuenta (contraseña al azar, sesiones cerradas, como en `promote_to_chef`) y queda como colaborador; uno que sale de la lista pierde el acceso en el acto y su cuenta de Auth se borra. La de una ficha de cliente, o una que no se puede borrar (permisos en `auth.users` o una referencia sin cascada), queda como cuenta de cliente, sin colaboración ni sesiones: el paso lo muestra con menos cuentas borradas que salidas y con el aviso de un usuario de más, y se borra a mano en Authentication → Users. Nunca se toca la cuenta de la cocinera.
  - Para sumar o sacar a alguien: cambiar el secreto y correr Deploy Supabase a mano (Actions → Deploy Supabase → Run workflow). Hasta ese despliegue no cambia nada; desde ahí, el acceso se corta en el acto.
- Registro abierto (M2). Antes de abrir las altas:
  - Turnstile en Auth (el CAPTCHA de Supabase, que `supabase/scripts/auth-config.ts` deja anotado para M2), además de los límites de Auth. No es solo del alta: Supabase también lo pide en cada pedido de código (`signInWithOtp`), así que la app lo manda en todo inicio de sesión, también en el de Evelyn (iOS, Android y `/gestione/`). Sin el token nadie entra.
  - La ficha la crea el servidor al registrarse, en `prospect`. M2 define cómo se une con un prospecto de la web del mismo email: solo con el email ya verificado por el código.
  - Un prospecto puede tener cuenta: M2 relaja el check `clients_prospect_sin_cuenta`. Hoy ese check es lo que impide que `submit_public_request` reutilice una ficha con cuenta: sin él, un envío sin login con el email de una cuenta le colgaría a esa ficha pedidos, restricciones y consentimientos de otra persona (y un consentimiento de salud con otra versión del texto le borraría las restricciones). Por eso, en el mismo cambio, la función pasa a reutilizar solo prospectos sin cuenta (`profile_id is null`, como el borrado de 90 días) y, si el email es de una cuenta, crea un prospecto nuevo, como hoy con un cliente con cuenta (contrato §3). Con test pgTAP.
  - Conservación: el borrado de 90 días alcanza solo a prospectos sin cuenta (contrato §9). M2 suma una regla para las cuentas que nunca pasan a cliente activo, y la privacy la cuenta (versión nueva del texto).
  - El catálogo y las sugerencias, solo para clientes activos (precisiones de RLS, abajo), con tests.
- Las notificaciones push y los emails nunca llevan restricciones ni direcciones. De las alergias del formulario, el aviso a la cocinera dice solo qué contestó el cliente (nadie tiene, indicadas o sin datos), nunca cuáles; la confirmación al cliente, que va a un email sin verificar, solo que confirmó que nadie tiene ("hay alergias" también es un dato de salud).
- Las notas libres de las sugerencias, de los pedidos especiales y del formulario de eventos siguen la regla de las notas del formulario: piden no escribir datos de salud y nunca salen en push ni email.
- La política de privacidad lista los subencargados: Supabase, Stripe, el proveedor de email, Firebase (push), Sentry y el hosting de la web.
- Traducción automática (20/11/2026, §4; 22/11/2026, §5.8): a Anthropic (Claude) solo van el nombre y la descripción de un plato en español y, al mandarle el menú de una semana a una clienta que no lee español, los nombres de los renglones de su lista de compras (texto genérico de ingredientes), escritos por la cocinera. Nunca la nota de la semana (sale como la escribió Evelyn), datos de clientes, pedidos, sesiones, restricciones ni direcciones, y la función no loguea ese texto ni la clave (el SDK va sin logs ni trazas). No son datos personales siempre que Evelyn no los escriba ahí: el editor de platos (traduccion-app) y el de la lista le avisan que no ponga datos de clientes. Con eso, Anthropic no es un subencargado y la privacy no cambia. Si algún día se le mandara otra cosa (por ejemplo, la nota de la semana o las notas de un pedido), antes hace falta una versión nueva de la privacy.
- Supabase en región UE; DPA firmado con Supabase y Stripe; política de privacidad en italiano.
- Fotos de tickets en Storage privado, accesibles con URL firmadas de corta duración (sin uso desde el 19/11/2026: sin compra no hay tickets; el bucket queda).
- Fotos de los platos (20/11/2026, §4) en el bucket público `recipe-photos`: no son datos personales (la app les saca EXIF y GPS antes de subirlas). Las ve cualquiera que tenga la URL; por la API solo la cocina. La web las carga desde el origen de Supabase, el mismo con el que el formulario ya habla (la CSP de `/richiesta/*` lo suma a `img-src`, y la de `/gestione/*` también, con `blob:` para la foto elegida y para cómo Safari decodifica las imágenes): no hay un destinatario nuevo y la privacy no cambia.
- Formulario público protegido con Cloudflare Turnstile y límite de solicitudes por IP.
- Página de la reserva (el link de la clienta, 22/11/2026, §5.8): muestra solo la foto de cada envío (nunca dirección ni alergias; del precio, solo el del servicio del presupuesto) y guarda lo que contesta la clienta, la confirmación o el mensaje de cambios, y la aceptación o el rechazo del presupuesto, como dato de la solicitud (art. 6.1.b RGPD), que se conserva como la reserva. El mensaje es una nota libre: el campo pide no escribir datos de salud y nunca sale por email ni push (el aviso a Evelyn dice solo que pidió cambios). Sus visitas y respuestas se cuentan por IP, como el formulario: huella HMAC, 2 días como máximo, interés legítimo. La privacy lo cuenta desde su versión `2026-11-22` y, con el presupuesto (la página muestra su precio, y la clienta lo acepta o lo rechaza ahí), desde la `2026-11-23` (`CONSENT_VERSION`; el texto de salud no cambió; la fecha es la del día siguiente porque la `2026-11-22`, del mismo día, sale antes con el link de la clienta).

**RLS (resumen)**. «Cocinera» es la cocina: la dueña y sus colaboradores, con el mismo acceso salvo la ficha pública (abajo).
| Tabla | Cliente | Cocinera | Anónimo |
|---|---|---|---|
| clients, client_restrictions, consents | lee y edita lo propio | todo lo de su `chef_id`, salvo borrar fichas (en cascada se llevaban sus pedidos y sus sesiones) y consentimientos | — |
| requests | crea y lee lo propio | todo, salvo borrar (un pedido aceptado es el registro de su reserva) | crea vía Edge Function `public-request` |
| quotes, sessions, session_menu, receipts | lee lo propio | todo | — |
| payments | lee lo propio | lee todo; escribe solo con efectivo o transferencia | — |
| prepared_portions | lee y actualiza `count_left` / `discarded_at` | crea y lee | — |
| pantry_items | CRUD de lo propio | lee si `share_pantry = true` | — |
| chef_settings, availability_* | — | CRUD | días libres solo vía la Edge Function `public-request` (`GET …/availability`) |

Precisiones implementadas en M1 (`supabase/migrations/*_rls.sql`):
- `recipes`: el cliente lee las recetas activas y visibles en el catálogo (`catalog_visible`) de su cocinera, para elegir platos deseados: no las desactivadas ni las de eventos. De `recipe_allergens` lee solo los alérgenos de las recetas que ve. Desde M2, solo un cliente activo (`trial` o `active`), con tests: un prospecto con cuenta no las ve. `recipe_ingredients` y `recipe_notes` son solo de la cocinera: el cliente no lee ingredientes ni notas.
- `consents`: el cliente los otorga y revoca; la cocinera los lee y puede registrar una revocación, pero no otorga en nombre del cliente. Nadie los borra desde la app. Un consentimiento revocado no se reactiva: se otorga uno nuevo.
- `clients`: el cliente no crea su propia ficha (con el registro abierto de M2 la crea el servidor, en `prospect`). El estado lo cambia solo la cocinera (y el servidor al aceptar el primer presupuesto, M4); `share_pantry`, solo el cliente.
- `profiles`: el perfil se crea por trigger siempre con rol `client`; nadie cambia su propio rol.
- `recurring_plans`: solo lectura para el cliente.
- Las tarifas (`chef_settings`) no son visibles para clientes: la vista previa y la política de cancelación se exponen con una RPC de solo lectura (M3c, con la pantalla Pedir de la app).
- Colaboradores (16/11/2026, migración `20261116190000_chef_members.sql`): las políticas del lado de la cocinera pasan por `current_chef_id()` e `is_chef_of()`, que llaman a `chef_id_for_user(auth.uid())`: la cocina de la que el usuario es dueño o colaborador. Así un colaborador pasa por todas, también por las de una tabla nueva, sin cambiarlas una por una. El pgTAP `15_chef_members` falla si una política usa `auth.uid()` directo, salvo las de identidad propia (el perfil propio en `profiles`, los tokens push y las notificaciones, porque cada aviso es de una persona) y una excepción del lado de la cocinera: la edición de la ficha pública (`chefs`: nombre, zona y WhatsApp que ven los clientes), que es solo de la dueña. Tampoco deja que una política lea `chefs` o `chef_members` por su cuenta, ni que una función busque la cocina del usuario de la sesión sin `chef_id_for_user`.
- `chef_members`: sin políticas ni privilegios para la app (nadie agrega, saca ni lista colaboradores desde ahí). El rol `chef` de un colaborador no abre nada en la base: ninguna política lo mira; una cuenta con rol `chef` sin cocina no ve nada.
- Quién hizo qué, con varias cuentas en la cocina: desde la app, el autor de un ticket (`receipts.uploaded_by`) es siempre quien lo sube, y no cambia después (guarda `receipts_set_uploaded_by`, misma migración); los logs de la función `chef` de lo que cambia (reservas, mover, cancelar) llevan el `userId` de quien llama.

Las escrituras sensibles (estados de sesión, pagos) pasan por Edge Functions con la service role, nunca por updates directos desde la app. Las reservas también: la app no crea, mueve ni cancela sesiones, y desde el 16/11/2026 tampoco borra pedidos ni fichas (borrar una ficha se llevaba en cascada sus pedidos, sus sesiones y sus consentimientos). Borrar a una persona es del servidor: la purga de prospectos, el SQL editor (contrato public-request §10.2) y, desde M2, la supresión de la cuenta. Tests de políticas RLS obligatorios (pgTAP o la suite de tests de Supabase).

---

## 7. Pantallas

Ver `docs/prototipo.html`; cambiar de vista con el selector de arriba.

**Cliente**
- **Inicio**: próxima sesión (menú, estado, botón de pre-autorizar), presupuestos pendientes con Aceptar/Rechazar, pedidos enviados, porciones en la heladera, ingredientes por vencer.
- **Pedir**: tipo (semana / extra / cambio), semanas (1 a 8), personas, días y comidas, restricciones, platos deseados (los incompatibles tachados), presupuesto estimado en vivo (precio por semana, 5.1), horarios libres, modo de pago, notas.
- **Sugerencias de la semana** (cliente activo, M2b): catálogo de temporada con los incompatibles tachados; marca, sin cantidad fija, los platos que le gustan y escribe cambios o pedidos especiales (el campo pide no escribir datos de salud); ve el estado de sus pedidos especiales.
- **Despensa** (F2): comidas listas (etiquetas) e ingredientes por ubicación, compartir con Evelyn, agregar producto.
- **Pagos**: método guardado, pendientes, historial con detalle servicio / pre-autorización.
- **Detalle de sesión** y **hoja de pago**.

Un prospecto con cuenta ve Inicio, Pedir (sin platos deseados) y su perfil; no ve el catálogo ni sugiere platos (§1).

**Cliente nuevo (web pública)**: explicación en 4 pasos, el mismo formulario de pedido con datos de contacto y consentimiento, y la pestaña «Menù» (19/11/2026): los platos publicados de la temporada, cada uno con su descripción, alérgenos, dieta y, si tiene, su foto (20/11/2026), para elegir hasta uno por día (opcional; lo elegido llega en el pedido y en el email a Evelyn); después, seguimiento del estado y aceptación del presupuesto, que crea la cuenta si todavía no tiene (desde M2 también puede registrarse antes). **Eventos privados** (M3b): sección propia y formulario con fecha libre, invitados, hora aproximada e idea del evento, sin calendario ni precio (5.3).

**Evelyn** (pensado primero para el celular). Un colaborador suyo (§1) entra a las mismas pantallas con su cuenta; «Más», Ajustes y el menú de la cuenta dicen «Colaborador de Evelyn», las notas privadas (de un día bloqueado y de un plato del catálogo) dicen que no las ven los clientes en lugar de «solo tú», y el WhatsApp que la app le prepara para un cliente sale de su propio teléfono, así que escribe de parte de ella («te escribo de parte de Evelyn de Radici») en lugar de «soy Evelyn». Los demás textos le hablan a la cocinera, o hablan como ella, también cuando entra un colaborador, que gestiona por cuenta de ella: «No trabajas este día de la semana» en la agenda; «No trabajas ese día», «Fuera de tu horario» y «Escribe el precio que acordaste» en la hoja de reserva; en la ficha de una sesión, «No trabajas ese día» y «Fuera de tu horario» al moverla y, al cancelarla, «Si queda lugar en tu horario» y el motivo «No puedo ir» (se guarda `chef_unavailable`: la que no puede ir es la cocinera), que también aparece junto al estado de una sesión cancelada.
- **Hoy** (el inicio después del login, área de Evelyn): la sesión de hoy o la próxima (clienta, hora de llegada, personas, las alergias resaltadas como en la ficha (§6), «Cómo llegar» y WhatsApp; con varias hoy, todas, la próxima primero) y pendientes accionables, cada uno en uno o dos toques (pedidos y eventos nuevos, pedidos especiales por aprobar, reservas que terminan, con «Renovar»: una reserva semanal aparece desde 7 días antes hasta 7 días después de su última sesión no cancelada (día de Roma; si ya pasó, dice que terminó) y deja de aparecer si la misma ficha ya tiene una sesión viva posterior (una ficha gemela de la misma persona no cuenta); renovar 4 semanas son dos toques, «Renovar» y «Confirmar 4 semanas»), ocupación de 7 días, ingreso por servicio, por cobrar y retenido. Entre los pendientes, «Menús para mandar» (22/11/2026, §5.8): las semanas confirmadas de una reserva y la semana 1 de un presupuesto sin aceptar (su menú sale con él) de hoy y los 6 días siguientes (días de Roma) que todavía no empezaron y cuyo menú no tiene platos, no se mandó, cambió después de mandarlo o recibió un pedido de cambios de la clienta (una confirmada, también si su último envío salió con una versión anterior del presupuesto y nadie lo confirmó: sigue pendiente, como en los avisos, §5.8), por fecha, cada una con la clienta, «Semana k de N», el día y la llegada, ese estado y el límite para mandarlo (48 h antes de la llegada; en la semana 1 de un presupuesto, su plazo si vence antes —el borrador a las 24 h, mandado a las 48 h del último envío—, dicho como «el presupuesto vence»; resaltado si faltan menos de 24 h o ya pasó; el lector de pantalla también oye que faltan menos de 24 h); tocar una abre su menú, mientras se vuelven a leer queda lo de antes, y «no hay nada pendiente» solo se dice si tampoco hay menús para mandar.
- **Agenda**: semana, día con línea de tiempo (bloque de cocina), sesiones de las reservas y eventos, huecos libres, bloquear día y editor de disponibilidad (estos dos, M5a). Cada sesión abre su ficha: «Semana k de N», mover, cancelar, «Cómo llegar» y WhatsApp.
- **Pedidos**: bandeja de pedidos y eventos (etiqueta y filtro, M3b) con su estado, la marca «menù» en los que traen platos elegidos en la web (19/11/2026) y una pestaña Reservas (los pedidos aceptados) con «Nueva reserva»: a mano, para una clienta existente (buscada por nombre o teléfono) o nueva (si el teléfono ya es de una ficha, la ofrece), con la misma hoja de «Confirmar reserva»; detalle con el menú que eligió el cliente destacado arriba, control de horario, «Preparar presupuesto» (la hoja de la reserva con el precio de todo el presupuesto; sale con el menú de la semana 1) y «Confirmar sin presupuesto» (de 1 a 8 semanas, en dos toques), el bloque del presupuesto con su estado, sus semanas y sus acciones (mandarlo, otro precio, retirarlo; §5.8), armado de menú con alérgenos (con las sugerencias del cliente a la vista), sugerencia automática o rechazar.
- **Clientes**: lista y ficha (estado, «Segna come cliente», plan, restricciones, preferencias, cocina, despensa compartida, porciones, historial, ingreso).
- **Menús de la semana** (M2b): las sugerencias de cada cliente activo y sus pedidos especiales, para aprobar o proponer una alternativa.
- **Catálogo de platos** (M4a): alta, edición, duplicar, baja (desactivar), alérgenos UE, dieta, temporada, nombres en it/es/en, la descripción corta de la web en it/es/en (19/11/2026; sin la italiana el plato no sale en el formulario, y la lista dice si está «Sul sito»; desde el 20/11/2026 Evelyn escribe primero el nombre y la descripción en español y el italiano y el inglés los completa la traducción automática al guardar, que ella puede corregir: §4, «Traducción de los platos») e ingredientes con su cantidad para 4 porciones (o q.b.) y su sección del súper.
- **Cobros**: para cobrar, falta pre-autorizar, próximas, cobradas.
- **Tarifas**: parámetros de la sección 5.1 con ejemplos en vivo.
- **Detalle de sesión**: progreso, menú con conservación y alertas, "usar primero", lista de compras para el cliente (sale sola del menú, se edita y se le manda), pago, marcar cocinado, registrar pago, cancelar. «Renovar» en la última sesión viva de una reserva semanal (si la misma ficha ya tiene otra sesión posterior, lo dice, sin esconder el botón). Alergias: las del pedido de la reserva o, en una sesión semanal cuyo pedido no responde (una renovación), las del último pedido semanal de la web que se reservó, con su fecha; sin ningún dato (o con solo una dieta) dice «sin datos en la app, pregúntale», resaltado, nunca «sin alergias» (también en Hoy, §6).

---

## 8. Notificaciones

| Evento | Para | Canal |
|---|---|---|
| Pedido o evento nuevo | Evelyn | push, una por pedido (de noche: sección 14) |
| Presupuesto enviado | cliente | push + email (prospecto sin app: email + mensaje de WhatsApp que Evelyn manda con un toque) |
| Presupuesto aceptado o rechazado | Evelyn | push |
| Falta pre-autorizar (72 h y 48 h antes) | cliente | push + email |
| Pre-autorización fallida o requiere confirmación | cliente y Evelyn | push |
| Recordatorio de sesión (24 h antes) | cliente | push |
| Cocinado: porciones listas | cliente | push |
| Pedido especial aprobado o con alternativa (M2b) | cliente | push |
| Pago pendiente (24 h y 72 h después) | cliente | push + email |
| Menú de la semana sin enviar (4 días y 72 h antes de la cocina; pasado el límite de 48 h, cada 2 horas), 5.8 | Evelyn | email |
| Porción vence mañana (F2) | cliente | push a las 8:00 |
| Ingrediente compartido vence y hay sesión en ≤ 3 días (F2) | Evelyn | push |

Sin notificaciones entre las 21:00 y las 8:00 (hora de Roma), salvo fallos de pago. Si el aviso de pedido o evento nuevo también es una excepción está sin decidir (sección 14).

---

## 9. Criterios de aceptación del MVP

1. Un prospecto pide desde la web sin cuenta, elige de 1 a 8 semanas y ve el precio (por semana, total y ahorro desde 4 semanas; la compra la hace el cliente; con más de 5 personas o en una sesión extra, que el presupuesto se lo prepara Evelyn) y los días en que Evelyn tiene lugar (calendario con `get_free_days`, que marca el mismo día de las semanas siguientes; la hora se acuerda con ella). Si ningún día tiene lugar para su pedido, la web se lo dice y puede enviarlo sin fecha. Un evento se pide sin precio ni calendario (5.3). No puede enviar sin contestar la pregunta de alergias (confirmar que nadie tiene o escribirlas), ni con alergias escritas sin el consentimiento de datos de salud.
2. El presupuesto mostrado coincide con los vectores de la sección 5.1 (precio por semana) en la app, en la web y en el servidor, y `DEFAULT_PRICING` es el valor por defecto de `chef_settings`.
3. Dos clientes no pueden reservar horarios superpuestos aunque acepten al mismo tiempo (la restricción `no_overlap` lo impide y la app muestra un error claro). Un horario ofrecido por `get_free_slots` nunca es rechazado por `no_overlap`.
4. Un presupuesto enviado bloquea el horario 48 h (sesión `held`; un evento, su propio plazo: 5.3) y se libera al vencer o al ser rechazado.
5. Con `preauth`, la retención del servicio se crea 48 h antes y se captura al cocinar.
6. Evelyn no puede marcar "pagada" una sesión cobrada con Stripe: el estado lo pone el webhook.
7. Un cliente no puede leer datos de otro cliente (test de RLS).
8. Enviar un menú con una receta que choca con una restricción exige confirmación explícita.
9. Cancelar una sesión con retención libera el importe en Stripe.
10. La app funciona en italiano y español; los textos no están hardcodeados.
11. Ningún texto de la web, de los emails ni de la app dice que Evelyn hace la compra ni muestra una compra estimada (19/11/2026). Tampoco la privacy, desde su versión `2026-11-19`.
12. Solo un cliente activo (`trial` o `active`) lee el catálogo y guarda sugerencias de platos; un prospecto, con o sin cuenta, no (test de RLS).

---

## 10. Plan de construcción (milestones para Claude Code)

La tabla sigue el orden de trabajo, reordenado el 15/11/2026 con la especificación de la app y el 16/11/2026 con el plan del área de Evelyn. Los números son nombres estables (los citan el código y el contrato); los milestones nuevos llevan letra: M3b amplía el pedido de M3, M3c lo lleva a la app (con las cuentas de M2), M5a adelanta la disponibilidad de M5, M4a prepara el menú de M4 y M2b necesita las cuentas de M2. Después del PR del formulario con calendario y pregunta de alergias va el área de Evelyn, que incluye M5a y M4a y llega antes de M2; después siguen M2, M3b, M3c y M2b.

| # | Milestone | Entregable verificable |
|---|---|---|
| F0 | Web de validación | `web/`: landing en italiano, calculadora con `quote.ts`, formulario → Edge Function `public-request` (emails a Evelyn y al cliente), bandeja y agenda en `/gestione/`, privacidad. Deploy en `radicicucina.app` |
| M0 | Setup | Repo, Flutter con entornos dev/prod, proyecto Supabase UE, CI en verde, `CLAUDE.md`, `quote.ts` + vectores en TS y Dart |
| M1 | Esquema y RLS | Migraciones de la sección 4, seeds del prototipo, tests de políticas RLS y de `no_overlap` (incluidas sesiones `held` y margen de un lado) |
| M3 | Horarios y pedido | `get_free_slots()` y `get_free_days()` con tests; Edge Function `public-request` con la disponibilidad por día; formulario de la web con calendario y pregunta de alergias. La pantalla Pedir de la app va en M3c |
| — | Área de Evelyn | Plan del 16/11/2026, en PRs chicos con tests primero y cada migración en su propio PR: bloquear días y su horario (M5a); reservas de 1 a 8 semanas, confirmadas desde el pedido o a mano, con una sesión `confirmed` por semana y `pay_mode manual` (sin presupuesto hasta M4); Agenda con las sesiones y su ficha; Hoy; «Cociné» y cobros manuales (efectivo, transferencia o Satispay); Dinero y gastos; catálogo (M4a), menú de cada sesión y la lista de compras que Evelyn le manda al cliente (el ticket con foto salió el 19/11/2026: sin compra) |
| M5a | Disponibilidad en la app | Bloquear y desbloquear días; después, editar el horario semanal (`availability_rules`). Repositorio + providers, textos ARB y tests; reemplaza el horario inicial fijo de 5.2 |
| M4a | Catálogo de platos | Base: `name_en`, `season_months`, `catalog_visible`, `recipe_ingredients` con cantidad para 4 porciones, `recipe_notes` (notas solo de la cocinera) y `save_recipe` (guardado atómico), con pgTAP; pantalla de Evelyn: alta, edición, duplicar, baja (desactivar), alérgenos UE, dieta, temporada e ingredientes; con tests |
| M2 | Auth y perfil, con registro abierto | Registro abierto y login con código, con Turnstile en cada pedido de código (también el de Evelyn); ficha `prospect` creada por el servidor; check `clients_prospect_sin_cuenta` relajado y `submit_public_request` limitado a prospectos sin cuenta (test pgTAP); conservación de las cuentas que no pasan a cliente activo (y privacy); RLS del catálogo solo para clientes activos; roles, perfil del hogar, restricciones con consentimiento, borrado de cuenta. Cambia la regla de altas aquí, en `CLAUDE.md` y en el contrato §10 (§6) |
| M3b | Eventos privados | Tipo `event` (5.3): sección y formulario propios en la web (fecha libre, invitados, hora aproximada, idea), sin estimación en la web ni en los emails; contrato, el check `requests_datos_de_presupuesto`, las validaciones de `submit_public_request` (`invalid_request_type`, `estimate_required`, `invalid_meals`) y los emails, con tests primero; etiqueta y filtro de eventos en la bandeja |
| M3c | Pedir en la app | Pantalla Pedir del cliente con cuenta (§7): presupuesto estimado en vivo (copia Dart de `quote.ts`) y horarios libres reales; RPC de solo lectura con la vista previa y la política de cancelación (§6); ruta de servidor para `get_free_slots`, que hoy ejecuta solo `service_role` (5.2). Repositorio + providers, textos ARB y tests |
| M2b | Sugerencias de menú | Cliente activo: sugerencias de la semana (catálogo de temporada sin cantidad fija, incompatibles tachados, nota libre y pedidos especiales). Evelyn: Menús de la semana, con aprobación o alternativa de los pedidos especiales. Tabla propia con RLS, tests primero |
| M4 | Pedidos y presupuestos | Bandeja, menú con alérgenos y con las sugerencias a la vista, ajuste de precio, envío, aceptación → sesión (y la ficha de un prospecto pasa a `trial`), vencimiento de presupuestos; presupuesto de eventos sin fórmula, con recetas propias y su vencimiento |
| M5 | Agenda | Semana y día con sesiones y eventos, huecos libres; Hoy (el inicio de Evelyn) con pendientes accionables |
| M6 | Pagos | Según 5.4 (D6 abierta: sección 14). Stripe en modo test: SetupIntent (app y Checkout web), pre-autorización programada del servicio, captura al cocinar, pago al final, efectivo, webhooks, idempotencia |
| M7 | Notificaciones | FCM + email + cron, horario silencioso |
| M8 | Lanzamiento | i18n completo, privacidad en italiano, deploy web, TestFlight y Play interno |
| M9 | F2 Porciones | Etiquetas, contador, avisos |
| M10 | F2 Despensa | Ingredientes, compartir, "usar primero" |
| M11 | F2 Recurrencias | Planes semanales que generan sesiones; el plazo de las sugerencias y la repetición del menú anterior, si se decide D5 |

En cada milestone: plan con `planner` → tests primero → implementación → revisión con `code-reviewer` (y `security-reviewer` en M2, M2b, M4 y M6; `database-reviewer` en M1, M3, M3b, M4a, M3c y M2b).

---

## 11. ECC para este proyecto

Instalación selectiva desde el repo oficial **github.com/affaan-m/ECC** (nunca forks ni mirrors). Los nombres son los del README v2.2.3 revisado en octubre de 2026; confirmá antes con `consult`, que muestra el plan sin escribir nada.

| Componente | Para qué acá |
|---|---|
| Reglas `common` | Estilo, git, testing y seguridad base |
| Reglas `typescript` | Edge Functions de Supabase (Deno/TS): webhooks de Stripe, cron, formulario público |
| Skill `security-review` | Pagos, RLS, secretos, datos de salud. Es la más importante en este proyecto |
| Skill `tdd-workflow` | Presupuesto, horarios y flujos de pago se escriben con tests primero |
| Skills `postgres-patterns` y `database-migrations` | Esquema, restricción de exclusión, índices, migraciones |
| Agentes `planner`, `code-reviewer`, `security-reviewer`, `database-reviewer` | Planificar cada milestone y revisar con contexto limpio |

No instales hooks por ahora. ECC no tenía paquete de reglas para Dart o Flutter en la última revisión: esas convenciones van en `CLAUDE.md` (sección 12).

```bash
git clone https://github.com/affaan-m/ECC.git
cd ECC
node scripts/ecc.js consult "supabase stripe security" --target claude   # ver el plan sin instalar
./install.sh --target claude --skills security-review,tdd-workflow,postgres-patterns,database-migrations

# reglas y agentes solo para este proyecto
cd /ruta/a/radici
mkdir -p .claude/rules/ecc .claude/agents
cp -R /ruta/a/ECC/rules/common /ruta/a/ECC/rules/typescript .claude/rules/ecc/
cp /ruta/a/ECC/agents/{planner,code-reviewer,security-reviewer,database-reviewer}.md .claude/agents/
```

Si ya creaste el comando `/ecc-setup` en Claude Code, alcanza con correrlo dentro del repo y comparar su propuesta con esta tabla.

---

## 12. `CLAUDE.md`

Está en la raíz del repo. Si cambian las reglas de esta spec, actualizarlo en el mismo PR.

---

## 13. Fuera del software (la app no lo resuelve)

Verificar con el commercialista antes de cobrar a clientes reales:
- Encuadre de la actividad de Evelyn (partita IVA existente o nueva actividad, código ATECO, régimen).
- Desde el 19/11/2026 no hay insumos que documentar: la compra la hace el cliente y Evelyn cobra solo el servicio (antes eran "spese anticipate in nome e per conto del cliente", art. 15 DPR 633/1972).
- Requisitos sanitarios para cocinar en casas ajenas (formación HACCP) y seguro de responsabilidad civil.
- Términos del servicio y política de cancelación por escrito.

---

## 14. Decisiones abiertas

- Identificador de la app y dominio definitivo. El nombre ya está decidido (Radici) y el dominio es `radicicucina.app`. Falta elegir el bundle id antes de la primera subida a las tiendas: no se puede cambiar después de publicar. Hoy sigue el provisorio (`com.sepusola10.mestolo`); los lugares a cambiar están en `app/README.md`.
- ¿Se pide tarjeta guardada también a los clientes `pay_after` (para poder cobrar la penalidad por cancelación)?
- Al revocar el consentimiento de salud se borran las restricciones del cliente. ¿Se borran también las copias en pedidos y presupuestos pasados? Pueden servir como prueba de que Evelyn fue informada de una alergia: decidir con quien asesore en privacidad. Mientras tanto se hace lo que dice la privacy: el retiro se procesa con `private.revoke_health_consent`, que borra también las copias de los pedidos (contrato §10.2). Si se decide conservarlas, cambiar la privacy (finalidad y plazo) y esa función.
- La confirmación de que nadie tiene alergias (`requests.no_allergies = true`) se trata como dato de la solicitud (art. 6.1.b RGPD, sin consentimiento de salud), y así lo dice la privacy `2026-11-16`. Confirmarlo con quien asesore en privacidad: si se la considera dato de salud, también necesitaría el consentimiento explícito.
- Alergias de otras personas: el formulario pide las de todos los que van a comer (otros adultos de la casa, invitados de un evento), pero el consentimiento del art. 9.2.a RGPD tiene que darlo cada interesado (por un menor, quien tiene su responsabilidad parental). Hoy quien las escribe declara, en la misma casilla del consentimiento de salud, que esas personas están informadas y de acuerdo, y la privacy `2026-11-16` (§5) le pide informarlas (art. 14) y les reconoce a ellas el derecho a pedir el borrado (contrato §10.2). Confirmar con quien asesore en privacidad si alcanza o si hace falta otro mecanismo (por ejemplo, que Evelyn lo confirme con cada invitado de un evento).
- Tarifas reales: el servicio se decidió el 15 y 16/11/2026 (150 € por semana, 140 € desde 4 semanas, hasta 5 personas, traslado incluido; 5.1). Desde el 19/11/2026 no hay compra estimada: la compra la hace el cliente.
- La web muestra el precio con `DEFAULT_PRICING` y no lee las tarifas de la cocinera (5.1). Cuando la app tenga la pantalla de Tarifas (§7), ¿se exponen a la web (por ejemplo en `GET …/availability`, que cambia el contrato) o cambiar un precio sigue siendo un PR?
- Zona de cobertura (¿solo Bergamo y primer cinturón?).
- Pedido mínimo y recargo por zona lejana: el traslado va incluido en el precio por semana (decisión del 16/11/2026). ¿Hace falta un recargo para las zonas lejanas?
- ¿Los tápers los pone el cliente o Evelyn (con depósito)?
- Política de cancelación definitiva.
- Satispay sí o no en el MVP.

**De la especificación de la app (15/11/2026)**
- **D5 · Menú semanal recurrente.** La especificación propone un plazo para sugerir platos (hasta un día antes de la primera sesión de la semana) y repetir el menú de la semana anterior si el cliente no sugiere. Sin decidir: queda para M11, con los planes recurrentes. Si se adopta, el plazo va en hora de Roma, Evelyn ve en Hoy quién no sugirió y la repetición vuelve a pasar el control de alérgenos (5.6): nunca copia un plato inactivo, fuera de temporada o que choque con una restricción vigente.
- **D6 · Pagos.** ¿Cuándo se paga el servicio? (Desde el 19/11/2026 no hay insumos: la compra la hace el cliente.) Desde el 16/11/2026 un pedido semanal puede ser de varias semanas, con descuento desde 4 (5.1), y el pago se acuerda con Evelyn (manual). Hasta decidirlo vale 5.4 (y el cobro manual de Fase 0). Un anticipo cambia §1, 5.4 y el criterio 5; cobrar varias semanas juntas choca con `payments.session_id` obligatorio, y la portada dice «nessun rinnovo automatico» (antes «Nessun abbonamento»): un pago recurrente también la cambia. Decidir antes de M6, con datos del piloto y el commercialista. Mientras tanto (decisiones del 16/11/2026), una reserva de varias semanas se cobra por sesión: `payments.session_id` sigue obligatorio, y un cobro que cubre varias semanas queda en un pago por sesión con el mismo `group_id` (área de Evelyn, PR de cobros).
- **D7 · Contacto directo en la web.** La especificación pide sumar WhatsApp o email. ¿Se suma, y con qué canal? Solo email es posible sin cambiar el contrato (falta elegir la dirección: la privacy ya publica la de Evelyn y `ciao@radicicucina.app` hoy solo envía). Un link de WhatsApp choca con el contrato (§6), que los prohíbe en la web pública, y con el test de la web que lo verifica: sumarlo cambia los dos en el mismo PR.
- **Control de insumos con vencimiento.** ¿Es la despensa del cliente (Fase 2, M10) o un stock propio de Evelyn? Lo segundo es nuevo y, sin compra (19/11/2026), Evelyn no maneja ingredientes de los clientes: verlo con el commercialista si se plantea.
- **Aviso push de pedido nuevo de noche.** Entre las 21:00 y las 8:00 no hay notificaciones (§8). ¿El aviso a Evelyn de un pedido o evento nuevo espera a las 8:00 o es una excepción, como los fallos de pago?
- **Nombres de las líneas de servicio** (§1): «Radici Quotidiano» y «Radici Privato» son provisorios.
