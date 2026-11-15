# Radici — Especificación para construir con Claude Code

> **Radici** es el nombre definitivo (ex Mestolo, el provisorio). Repo: `github.com/Evel03/radici`. Dominio: `radicicucina.app` (web pública y bandeja en `/gestione/`). Falta elegir el identificador nativo de la app (sección 14).
>
> **Prototipo de referencia:** `docs/prototipo.html` (también publicado en https://claude.ai/artifact/E5zsqMUGziiWUr2N1BDmsw; pendiente de copiar al repo). Es la referencia visual. Las reglas de negocio de **este documento** prevalecen sobre el prototipo: la fórmula de presupuesto y el margen entre sesiones se corrigieron en la revisión del 19/10/2026.
>
> **Especificación de la app (15/11/2026):** el dueño mandó una especificación de la app con área de clientes y tablero de administración. Está integrada en este documento con sus decisiones del mismo día: D1, a las 9:00 empieza la compra (5.2); D2, eventos privados con sección y formulario propios (5.3); D3, registro abierto desde M2 (§1 y §6); D4, el cliente solo sugiere platos y el menú lo decide Evelyn (5.1). Lo que quedó sin decidir (D5–D7 y otras) está en la sección 14. La copia original, sin cambios, está en [`docs/especificaciones/2026-11-15-especificacion-app.md`](docs/especificaciones/2026-11-15-especificacion-app.md): es historia y, si difiere de este documento, manda este documento.

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
Evelyn cocina **en la casa del cliente**: hace las compras, cocina para varios días y deja todo en porciones etiquetadas con plato y fecha. El cliente paga el **servicio** y los **insumos** por separado; los insumos se cobran por el **ticket real** y, si el cliente elige pre-autorizar, Evelyn no corre riesgo de impago (sí adelanta la compra en el súper hasta que Stripe deposita, unos días).

### Líneas de servicio
Una sola marca, **Radici · Cucina privata**, con dos líneas. Los nombres son provisorios (sección 14): van en los textos de i18n, nunca en el código.
- **Servicio semanal** («Radici Quotidiano»): la propuesta de arriba. Presupuesto estimado con la fórmula de 5.1 y día elegido en el calendario de disponibilidad (5.2). El menú lo decide Evelyn; el cliente activo puede sugerir platos.
- **Cenas privadas y eventos** («Radici Privato»): sección y formulario propios, menú a medida y presupuesto que Evelyn pasa después de hablar con el cliente, sin precio automático (5.3).

### Roles
| Rol | Quién | Qué hace |
|---|---|---|
| `chef` | Evelyn (y en el futuro otra cocinera) | Responde pedidos y eventos, arma menú y presupuesto, gestiona agenda, disponibilidad, catálogo de platos, tickets y cobros |
| `client` | Persona con cuenta (rol de `profiles`; desde M2 el registro es abierto) | Lo que permite el estado de su ficha (abajo): pide presupuestos, los acepta, pre-autoriza o paga, sugiere platos, ve porciones y despensa |
| sin cuenta | Persona que pide desde la web | Pide presupuesto o un evento desde un enlace público, sin registrarse; queda como ficha `prospect` |

### Estados del cliente
La ficha (`clients.status`, una por cocinera) se muestra con dos estados (decisión del 15/11/2026):
- **Prospecto** (`prospect`): pidió desde la web o, desde M2, se registró y todavía no es cliente. Con cuenta ve su perfil y sus pedidos y puede pedir presupuesto; no ve el catálogo de platos ni sugiere.
- **Cliente activo** (`trial` o `active`): además ve el catálogo de temporada y sugiere platos. Pasa a este estado al aceptar su primer presupuesto (lo hace el servidor, M4) o cuando Evelyn toca «Segna come cliente».

`paused` y `churned` siguen en el enum y no cuentan como activos. El estado lo cambian la cocinera o el servidor, nunca el cliente.

### Principios
- **Cero riesgo de impago para Evelyn** cuando el cliente elige pre-autorización.
- **Transparencia**: el cliente ve el ticket (foto) y lo que se cobró de insumos.
- **Mobile first**, y el cliente nuevo puede pedir desde un link de WhatsApp sin instalar nada.
- **Italiano por defecto** (clientes de Bergamo); español e inglés como segundo y tercer idioma.
- Datos de alergias = datos de salud: mínimos, con consentimiento explícito y solo visibles para la cocinera (sección 6).

---

## 2. Alcance por fases

### Fase 0 — Validación (web liviana, sin app)
- Web pública en italiano (`web/`): cómo funciona, calculadora de presupuesto (misma fórmula 5.1, mismo `quote.ts`) y formulario de pedido con la pregunta de alergias: el cliente confirma que nadie de quienes van a comer (niños incluidos) tiene alergias, intolerancias ni celiaquía, o las escribe con su consentimiento de datos de salud.
- El pedido se guarda en Supabase (Edge Function `public-request`, contrato `docs/contracts/public-request.md`, aprobado el 19/10/2026; reemplaza el envío por WhatsApp). Evelyn recibe un email y un aviso emergente en la app, y lo revisa en la bandeja y la agenda (app y `/gestione/`); el cliente recibe la confirmación por email y, si la pidió, por WhatsApp. El cliente no necesita cuenta.
- Eventos privados con sección y formulario propios (M3b, después del PR del formulario con calendario y alergias), sin precio automático (5.3). Hasta entonces la web los pide como `extra` («Evento o sessione extra»).
- Disponibilidad desde la app (M5a): Evelyn bloquea días y edita su horario semanal. En Fase 0 no hay sesiones: un día ocupado es un día bloqueado, y así lo ve el calendario de la web (5.2).
- Pendientes de la web que pide la especificación de la app: texto alternativo de las fotos (en los textos i18n) y quitar `noindex` (`VITE_NOINDEX=false`) recién al compartir el sitio (contrato §10.1, paso 12). El contacto directo es la decisión abierta D7.
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
- **Catálogo de platos** de Evelyn (M4a): unos 20 platos con alérgenos, temporada y nombre en it/es/en; alta, baja (desactivar) y rotación por temporada.
- **Sugerencias del menú semanal** (M2b): el cliente activo marca, sin cantidad fija, platos del catálogo de temporada que le gustan y puede pedir cambios o platos especiales en un campo libre; Evelyn decide y arma el menú (5.1, 5.6).
- Aceptación del presupuesto → sesión agendada (con protección contra doble reserva).
- **Agenda** (semana + día con línea de tiempo, con sesiones y eventos). La **disponibilidad** semanal y el **bloqueo de días** llegan antes, con M5a (Fase 0).
- **Pagos con Stripe**: pre-autorización única (servicio + insumos), captura al cocinar según ticket, pago al final; registro manual de efectivo o transferencia.
- Carga del ticket (monto + foto).
- **Inicio** de Evelyn: pendientes accionables en uno o dos toques y panel con ingreso por servicio, por cobrar, retenido, adelantado de su bolsillo y ocupación de los próximos 7 días (§7).
- Notificaciones push y email básicas (sección 8).

### Fase 2 — Retención
- **Porciones en la heladera**: etiquetas digitales por plato con fecha de elaboración y "consumir antes de", contador de porciones, aviso el día antes.
- **Despensa compartida**: ingredientes con vencimiento cargados por el cliente; Evelyn ve "usar primero" al armar el menú.
- **Planes recurrentes** (semanal / cada 2 semanas) que generan la próxima sesión automáticamente. Con ellos se decide el plazo para sugerir platos y qué pasa si el cliente no sugiere (D5, sección 14).
- Recetario completo: tiempos de conservación de cada plato para las porciones (el catálogo con los 14 alérgenos UE y la temporada se adelanta a la Fase 1, M4a).

### Fase 3 — Escala y administración
- Facturación electrónica (API tipo Fatture in Cloud o Aruba → SDI). Decidir con el commercialista.
- Lista de compras automática a partir de las recetas del menú.
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
create type pay_mode        as enum ('preauth','pay_after');
create type request_type    as enum ('week','extra','change');  -- M3b suma 'event' (5.3)
create type request_status  as enum ('new','quoted','accepted','declined','rejected','expired','resolved');
create type session_status  as enum ('held','confirmed','shopping_done','cooked','paid','cancelled');
create type payment_kind    as enum ('preauth','capture','groceries_extra','charge','cash','transfer','refund');
create type payment_status  as enum ('requires_action','authorized','succeeded','canceled','failed','pending');
create type storage_loc     as enum ('fridge','freezer','pantry');
create type allergen        as enum ('gluten','crustaceans','eggs','fish','peanuts','soy','milk','nuts','celery','mustard','sesame','sulphites','lupin','molluscs'); -- 14 del Reg. UE 1169/2011
create type diet            as enum ('vegetarian','vegan');
```

| Tabla | Columnas principales |
|---|---|
| `chefs` | id, profile_id, display_name, service_area text[], whatsapp |
| `profiles` | id (= auth.users.id), role, full_name, phone, locale, created_at |
| `chef_settings` | chef_id PK, hourly_rate_cents (2200), travel_fee_cents (1200), adult_portion_cents (380), kid_portion_cents (250), preauth_buffer_pct (15), min_cook_minutes (90), shop_minutes (45), gap_minutes (30), slot_step_minutes (30), booking_horizon_days (14), min_notice_hours (24), quote_hold_hours (48), prospect_retention_days (90), cancellation_policy jsonb |
| `availability_rules` | id, chef_id, dow (0–6), start_time, end_time |
| `availability_exceptions` | id, chef_id, date, kind ('blocked'), note |
| `clients` | id, chef_id, profile_id null (null = sin cuenta; hasta M2 un prospecto nunca tiene cuenta, desde M2 puede tenerla: §6), display_name, contact_email, contact_phone, zone, address, adults, kids, preferences, kitchen_notes, pay_mode, status, share_pantry bool, stripe_customer_id, default_payment_method_id, since. **El formulario público siempre crea un `clients` con `status = prospect`**, así el consentimiento tiene dónde colgarse |
| `client_restrictions` | client_id, allergen null, diet null (una fila por restricción) |
| `consents` | id, client_id, kind ('health_data','privacy','marketing'), text_version, granted_at, revoked_at |
| `recurring_plans` (F2) | id, client_id, freq ('weekly','biweekly'), dow, start_time, days, meals text[], active |
| `recipes` | id, chef_id, name_it, name_es, name_en (M4a), fridge_days, freezable, freezer_days (60), diet null, season_months smallint[] null (M4a: meses 1–12 en que se ofrece; null = todo el año), notes, active (dar de baja = desactivar: una receta usada no se borra) |
| `recipe_allergens` | recipe_id, allergen |
| `requests` | id, chef_id, client_id (siempre, también para prospectos), type, status, adults, kids, days, meals text[], restrictions jsonb, wishes uuid[], notes, preferred_date, preferred_start, pay_mode, target_session_id null (para 'change'), text (para 'change'), created_at; del pedido de la web además preferred_slot, locale, whatsapp_opt_in, estimate, source, seen_at, request_key, contact jsonb (el contacto con que llegó) y no_allergies (la pregunta de alergias: true = nadie tiene, false = las escribió y van en restrictions, null = sin respuesta; contrato §3) |
| `quotes` | id, request_id, session_id (la sesión `held` que reserva el horario), version, menu uuid[], cook_minutes, portions, service_cents, groceries_est_cents, preauth_cents, pricing_snapshot jsonb, allergen_override text null, slot_date, slot_start, hold_until, sent_at, accepted_at |
| `sessions` | id, chef_id, client_id, request_id, quote_id, date, start_time, cook_minutes, shop_minutes, gap_minutes, portions, status, hold_until null (solo `held`), pay_mode, service_cents, groceries_est_cents, preauth_cents, groceries_actual_cents null, service_paid_at, groceries_paid_at, cancelled_at, cancel_reason, **busy tstzrange** (generada) |
| `session_menu` | session_id, recipe_id, portions |
| `receipts` | id, session_id, storage_path, total_cents, store_name, purchased_at, uploaded_by |
| `payments` | id, session_id, kind, provider ('stripe','satispay','cash','transfer'), stripe_payment_intent_id, amount_cents, captured_cents, service_part_cents, groceries_part_cents (reparto para separar servicio e insumos en un mismo cobro), status, idempotency_key unique, last_error, created_at |
| `prepared_portions` (F2) | id, client_id, session_id, recipe_id, count_initial, count_left, location, made_on, consume_by, discarded_at |
| `pantry_items` (F2) | id, client_id, name, qty_text, location, expires_on, added_by, consumed_at |
| `push_tokens` | profile_id, token, platform |
| `notifications` | id, profile_id, kind, payload jsonb, channel, scheduled_for, sent_at |

Sugerencias del menú semanal (M2b): tabla propia por cliente y semana (platos sugeridos, sin cantidad fija, y nota libre con los pedidos especiales y su estado), con `chef_id`, clave foránea compuesta con `clients`, RLS y grants en su propia migración; se diseña con tests primero. Un menú de evento usa recetas creadas para el evento, con sus alérgenos, que no se ofrecen en el catálogo (5.3).

**Anti doble reserva** (obligatorio, no confiar solo en la app):

```sql
create extension if not exists btree_gist;
-- busy = [inicio - compra, fin de cocina + margen)
-- El margen va de UN solo lado: así dos sesiones chocan si
-- a_ini < b_fin + margen y b_ini < a_fin + margen, exactamente la regla de 5.2.
-- (Con margen a ambos lados la base exigiría 2 × margen y rechazaría horarios ofrecidos.)
alter table sessions add constraint no_overlap
  exclude using gist (chef_id with =, busy with &&)
  where (status <> 'cancelled');
```

Al enviar un presupuesto se crea la sesión con `status = held` y `hold_until` (48 h; un evento, su propio plazo: 5.3): `no_overlap` la protege igual que a una confirmada, así dos presupuestos nunca prometen el mismo horario. Al aceptar pasa a `confirmed`; si el cliente rechaza o vence, un cron la pasa a `cancelled` (`cancel_reason = 'hold_expired' | 'declined'`).

---

## 5. Reglas de negocio

### 5.1 Presupuesto

Es la misma fórmula del prototipo, pero **solo con enteros** (sin decimales en ningún paso). Fuente única de verdad: el módulo TS `supabase/functions/_shared/quote.ts`, usado por las Edge Functions y por la web. La app replica el cálculo en Dart solo para la vista previa, y **todas las implementaciones pasan los mismos vectores** (`supabase/functions/_shared/quote_vectors.json`, leído por los tests de TS y de Dart).

```
div_arriba(a, b)   = (a + b − 1) div b                  -- enteros ≥ 0
comidas            = cantidad de comidas por día (1 o 2: almuerzo, cena)
porc_adulto        = adultos × días × comidas
porc_niño          = niños × días × comidas
porciones          = porc_adulto + porc_niño
recetas            = clamp( min(div_arriba(días × comidas, 2), porciones div 2), 2, 6 )
minutos_cocina     = max(min_cocina, div_arriba(300 + 150 × recetas + 6 × porciones, 150) × 30)
                     -- = ceil_a_30(60 + 30 × recetas + 1,2 × porciones), escrito en enteros
servicio           = (minutos_cocina × tarifa_hora + 30) div 60 + fijo_compra_traslado
                     -- redondeo al centavo, mitad hacia arriba
insumos_estimados  = porc_adulto × costo_adulto + porc_niño × costo_niño
preautorización    = div_arriba(insumos_estimados × (100 + margen%), 100)
retención          = servicio + preautorización          -- monto del PaymentIntent único (§5.4)
total_estimado     = servicio + insumos_estimados
```

Con los valores por defecto (22 €/h, 12 € fijo, 3,80 € adulto, 2,50 € niño, 15 %, mínimo 90 min):

| # | Entrada | Porciones | Recetas | Cocina | Servicio | Insumos | Pre-aut. | Total |
|---|---|---|---|---|---|---|---|---|
| 1 | 2 ad · 2 niños · 5 días · cena | 20 | 3 | 180 min | 7800 | 6300 | 7245 | 14100 |
| 2 | 1 ad · 5 días · almuerzo | 5 | 2 | 150 min | 6700 | 1900 | 2185 | 8600 |
| 3 | 10 ad · 6 niños · 1 día · cena | 16 | 2 | 150 min | 6700 | 5300 | 6095 | 12000 |
| 4 | 2 ad · 3 niños · 4 días · cena | 20 | 2 | 150 min | 6700 | 6040 | 6946 | 12740 |
| 5 | 2 ad · 1 niño · 5 días · cena | 15 | 3 | 180 min | 7800 | 5050 | 5808 | 12850 |
| 6 | 2 ad · 2 niños · 5 días · almuerzo y cena | 40 | 5 | 270 min | 11100 | 12600 | 14490 | 23700 |
| 7 | 4 ad · 7 días · almuerzo y cena (tope de 6 recetas) | 56 | 6 | 330 min | 13300 | 21280 | 24472 | 34580 |
| 8 | 1 ad · 1 día · cena (mínimo) | 1 | 2 | 150 min | 6700 | 380 | 437 | 7080 |
| 9 | Como el 2, con tarifa 21,55 €/h (redondeo) | 5 | 2 | 150 min | 6588 | 1900 | 2185 | 8488 |

(Montos en centavos.)

- Con los valores actuales el mínimo de 90 min nunca se aplica: la sesión más corta posible es de **150 min** (67 € de servicio). Ver decisiones abiertas.

- Evelyn puede **ajustar el servicio a mano** antes de enviar; se guarda en `quotes.service_cents` y el motivo en `pricing_snapshot`.
- Al enviar se guarda un **snapshot** con tarifas y resultado: si Evelyn cambia tarifas después, los presupuestos enviados no cambian.
- Un presupuesto vence a las 48 h (`hold_until`); vencido, el pedido pasa a `expired` y se libera el horario. El de un evento tiene un plazo propio, más largo (5.3).
- Platos (D4, decisión del 15/11/2026): el cliente solo sugiere los que le gustan, sin cantidad fija, y Evelyn decide y arma el menú. La cantidad de `recetas` sigue saliendo de esta fórmula: ni la fórmula ni los vectores cambian por las sugerencias.
- Eventos privados: sin estimación automática. Evelyn fija el presupuesto después de hablar con el cliente (5.3).

### 5.2 Disponibilidad y horarios libres

Implementado en SQL (migración `20261115130000_free_slots.sql`, tests pgTAP `07_free_slots`): `get_free_slots(chef_id, cook_minutes, from_date, days)` y `get_free_days(chef_id, cook_minutes, from_date, days)`, sobre un generador común (`private.free_slot_candidates`). Las ejecuta **solo `service_role`**: la web pública lee los días por la Edge Function `public-request` (`GET …/availability?minutes=N`, contrato §11, con CORS y su propio límite por IP), nunca con una RPC anónima. La app las usará desde el servidor.

- Ventana: desde mañana en Roma, respetando `min_notice_hours` (la compra empieza como pronto tantas horas después de ahora), hasta hoy + `booking_horizon_days` (14: los mismos días que se pueden elegir en el formulario).
- Un día cuenta si tiene regla de disponibilidad y no está bloqueado.
- Candidatos cada `slot_step_minutes`, desde `ceil_a_30(apertura + compra)` mientras `inicio + cocina ≤ cierre`. La **hora mostrada es la de llegada a la casa**; la compra ocurre antes.
- Un candidato `[inicio − compra, inicio + cocina]` choca con una sesión no cancelada (incluidas las `held`, también las vencidas mientras el cron no las cancele) si `a_ini < b_fin + margen` y `b_ini < a_fin + margen`. Es la misma condición que `no_overlap`: el rango del candidato se arma igual que `sessions.busy`, con la compra y el margen actuales de la cocinera, y se compara con `&&` contra el `busy` guardado de cada sesión. Un horario ofrecido nunca puede ser rechazado por la base (hay un test que lo verifica en toda la grilla, también en días con cambio de hora).
- `get_free_slots`: se muestran hasta 3 horarios por día, separados al menos 2 h (los primeros que cumplen), en los primeros 5 días con lugar.
- `get_free_days`: cada fecha del rango pedido, con `available` si tiene al menos un horario libre (el calendario de la web). El calendario vale solo para la semana de comidas: con `extra` se puede elegir cualquier día de la ventana (Evelyn confirma la disponibilidad al contactar) y los eventos no usan ni el calendario ni la ventana (5.3).
- Horario inicial (decisión del dueño del 15/11/2026): lunes a viernes de 9:00 a 15:00 para toda cocinera sin reglas (migración `20261115130100_default_availability.sql`; en un proyecto nuevo, `deploy-supabase.yml` al crear la cuenta), hasta que la app tenga editor de disponibilidad (M5a); la ventana sigue en 14 días.
- A las 9:00 Evelyn empieza la compra, no llega a la casa (D1, decisión del 15/11/2026): las reglas quedan en 9:00–15:00 y la regla de esta sección no cambia. Con 45 min de compra, la primera llegada es a las 10:00 y la cocina dura como máximo 300 min (5 h). Un pedido más largo (el vector 7, de 330 min) no tiene ningún día libre: la web lo explica y deja enviarlo sin fecha, y Evelyn propone una.
- En Fase 0 no hay sesiones: un día ocupado es un día bloqueado (`availability_exceptions`), que Evelyn carga desde la app (M5a).
- F3: sumar tiempo de traslado según zona de la sesión anterior y la siguiente.

### 5.3 Estados

**Pedido (`requests.status`)**
```
new ──(Evelyn envía presupuesto)──▶ quoted ──(cliente acepta)──▶ accepted
 │                                    ├──(cliente rechaza)──▶ declined
 │                                    └──(vence hold_until)──▶ expired
 ├──(Evelyn rechaza)──▶ rejected
 └──(type = change, Evelyn lo resuelve)──▶ resolved
```

**Evento privado (`requests.type = 'event'`, M3b; D2, decisión del 15/11/2026)**
- Formulario propio: fecha, cantidad de invitados, hora aproximada e idea del evento. La fecha es libre: no usa el calendario de disponibilidad ni la ventana de 14 días, y Evelyn confirma día y hora al hablar con el cliente (puede caer fuera de su horario semanal; la sesión del evento igual pasa por `no_overlap`). Los campos y sus límites los fija el contrato del formulario.
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

Si el presupuesto de un evento vence, el pedido pasa a `expired`, como cualquier otro. `extra` queda para la sesión extra de un cliente, con estimación.

**Pedido especial del menú semanal (M2b)**: queda pendiente hasta que Evelyn lo aprueba o propone una alternativa. Las sugerencias de platos no tienen estado: Evelyn las ve al armar el menú. Los estados y las transiciones del pedido especial se definen con tests primero en su milestone, en la tabla de sugerencias (no en `requests.status`).

**Sesión (`sessions.status`)**
```
held ──(cliente acepta)──▶ confirmed ──(ticket cargado)──▶ shopping_done ──(marcar cocinado)──▶ cooked ──(todo cobrado)──▶ paid
  └──(vence o rechaza)──▶ cancelled          └──(cancelar)──▶ cancelled
```
`cooked → paid` ocurre solo cuando servicio e insumos están cobrados, y lo decide el **webhook** de Stripe o el registro manual de Evelyn, nunca la app del cliente.

**Pago (`payments.status`)**: refleja el PaymentIntent de Stripe (`requires_action`, `authorized` = requires_capture, `succeeded`, `canceled`, `failed`) o `pending` para efectivo y transferencia hasta que Evelyn lo confirma.

### 5.4 Pagos con Stripe

**A. Pre-autorización única (`pay_mode = preauth`)**

Stripe permite **una sola captura** por PaymentIntent. Por eso se usa una sola retención por servicio + insumos y una sola captura al final: menos estados, menos webhooks y una comisión fija menos por sesión.

1. Al aceptar el presupuesto: crear `Customer` si no existe y guardar la tarjeta con **SetupIntent** (app: PaymentSheet; web: Stripe Checkout `mode=setup`). Autenticación SCA una vez, uso `off_session`.
2. **No retener al aceptar**: una autorización de tarjeta suele vencer a los 7 días (a veces antes). Un cron crea la retención **48 h antes de la sesión** (o al momento si falta menos): `PaymentIntent` por `service_cents + preauth_cents`, `capture_method=manual`, `off_session=true`, `confirm=true`.
3. Si Stripe pide autenticación (`requires_action`), se notifica al cliente para confirmarla dentro de la app. Si falla, se avisa a Evelyn: la sesión queda marcada "sin pre-autorizar".
4. Al cargar el ticket: se guarda monto y foto (no se cobra todavía).
5. Al marcar cocinado: `capture` por `servicio + min(ticket, autorizado − servicio)`. La captura parcial libera el resto sola. En `payments` se guarda el reparto (`service_part_cents`, `groceries_part_cents`).
6. Si el ticket supera lo autorizado para insumos: nuevo `PaymentIntent` `off_session` por la diferencia, con el enlace a la foto del ticket en la descripción. Si falla → `pending` y pedido de pago en la app.
7. Si la autorización venció o se canceló antes de capturar: cobrar servicio + ticket con un `PaymentIntent` `off_session` normal.

Servicio e insumos se documentan por separado aunque viajen en un mismo cobro (art. 15). Confirmar con el commercialista.

**B. Pago al final (`pay_mode = pay_after`)**
Al marcar cocinado se genera el cobro de servicio + ticket; el cliente paga en la app (PaymentSheet; F3: Satispay). Recordatorios a las 24 h y 72 h.

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
- Al armar un menú, cualquier receta que choque con una restricción del cliente se marca en rojo. **Enviar presupuesto con un conflicto exige una confirmación explícita** de Evelyn (ej.: "adapto la receta sin lácteos") que queda guardada en el presupuesto.
- La celiaquía exige nota de contaminación cruzada visible en la sesión.
- Sugerencias (M2b): el cliente ve tachados los platos que chocan con sus restricciones guardadas y no puede sugerirlos. Sugerir no cambia el control: Evelyn arma el menú con la marca en rojo y la confirmación explícita de arriba.
- Eventos: las recetas creadas para el evento llevan sus alérgenos, como las del catálogo, y las restricciones que cuentan son las del pedido (las de los invitados, `requests.restrictions`), nunca las de la ficha del hogar. Una nota libre de alergias no se cruza sola con las recetas: Evelyn la revisa antes de enviar el presupuesto.

### 5.7 Cancelaciones (a definir por Evelyn; propuesta)
| Cuándo cancela el cliente | Servicio | Insumos |
|---|---|---|
| Más de 48 h antes | 0 % | Se libera la retención |
| Entre 48 h y 12 h | 50 % | Se libera si no compró |
| Menos de 12 h o compra hecha | 100 % | Se cobra el ticket |

Guardar la política en `chef_settings.cancellation_policy` y mostrarla antes de aceptar el presupuesto.

Con `pay_after` no hay tarjeta guardada: la penalidad no se puede cobrar automáticamente. Decidir si se pide tarjeta a todos los clientes (sección 14).

---

## 6. Seguridad, privacidad y RGPD

- **Alergias, intolerancias y celiaquía son datos de salud** (art. 9 RGPD): consentimiento **explícito y separado** del de privacidad, con versión del texto y fecha (`consents`). Sin consentimiento no se guardan las restricciones.
- Mínimo necesario: guardar la restricción ("sin lactosa"), no diagnósticos ni historia clínica.
- Solo la cocinera ve restricciones y direcciones. Nunca se escriben en logs, Sentry ni analytics.
- Derecho de acceso y borrado: exportar los datos del cliente (JSON) y borrar su cuenta desde la app. Incluye las copias de restricciones en `requests.restrictions` y `quotes.pricing_snapshot`.
- Conservación: los prospectos que no se convierten se borran con un cron cuando pasan `prospect_retention_days` (90) desde su último pedido. Si la persona pasa a ser clienta (en Fase 0, por WhatsApp), la cocinera la marca como cliente desde el detalle del pedido (ficha en `trial`) y se conserva.
- Un envío del formulario público (sin login, email sin verificar) nunca modifica a una persona que ya existe: cada pedido guarda el contacto con que llegó (`requests.contact`) y las restricciones del hogar solo se suman, desde pedidos semanales.
- Las altas de usuarios van apagadas hasta el área de clientes (M2): la cuenta de la cocinera la crea confirmada el despliegue de Supabase (o el panel) antes de publicar nada, y `promote_to_chef` le cambia la contraseña por una al azar y le cierra las sesiones. En M2 se abren a cualquiera (registro abierto, D3): ese PR cambia esta regla, la de `CLAUDE.md` y el contrato §10.
- Registro abierto (M2). Antes de abrir las altas:
  - Turnstile en el alta (el CAPTCHA de Supabase Auth, que `supabase/scripts/auth-config.ts` deja anotado para M2), además de los límites de Auth.
  - La ficha la crea el servidor al registrarse, en `prospect`. M2 define cómo se une con un prospecto de la web del mismo email: solo con el email ya verificado por el código.
  - Un prospecto puede tener cuenta: M2 relaja el check `clients_prospect_sin_cuenta`.
  - Conservación: el borrado de 90 días alcanza solo a prospectos sin cuenta (contrato §9). M2 suma una regla para las cuentas que nunca pasan a cliente activo, y la privacy la cuenta (versión nueva del texto).
  - El catálogo y las sugerencias, solo para clientes activos (precisiones de RLS, abajo), con tests.
- Las notificaciones push y los emails nunca llevan restricciones ni direcciones. De las alergias del formulario, el aviso a la cocinera dice solo qué contestó el cliente (nadie tiene, indicadas o sin datos), nunca cuáles; la confirmación al cliente, que va a un email sin verificar, solo que confirmó que nadie tiene ("hay alergias" también es un dato de salud).
- Las notas libres de las sugerencias, de los pedidos especiales y del formulario de eventos siguen la regla de las notas del formulario: piden no escribir datos de salud y nunca salen en push ni email.
- La política de privacidad lista los subencargados: Supabase, Stripe, el proveedor de email, Firebase (push), Sentry y el hosting de la web.
- Supabase en región UE; DPA firmado con Supabase y Stripe; política de privacidad en italiano.
- Fotos de tickets en Storage privado, accesibles con URL firmadas de corta duración.
- Formulario público protegido con Cloudflare Turnstile y límite de solicitudes por IP.

**RLS (resumen)**
| Tabla | Cliente | Cocinera | Anónimo |
|---|---|---|---|
| clients, client_restrictions, consents | lee y edita lo propio | todo lo de su `chef_id` | — |
| requests | crea y lee lo propio | todo | crea vía Edge Function `public-request` |
| quotes, sessions, session_menu, receipts | lee lo propio | todo | — |
| payments | lee lo propio | lee todo; escribe solo con efectivo o transferencia | — |
| prepared_portions | lee y actualiza `count_left` / `discarded_at` | crea y lee | — |
| pantry_items | CRUD de lo propio | lee si `share_pantry = true` | — |
| chef_settings, availability_* | — | CRUD | días libres solo vía la Edge Function `public-request` (`GET …/availability`) |

Precisiones implementadas en M1 (`supabase/migrations/*_rls.sql`):
- `recipes`: el cliente lee las recetas activas de su cocinera (para elegir platos deseados). Desde M2, solo un cliente activo (`trial` o `active`), con tests: un prospecto con cuenta no las ve.
- `consents`: el cliente los otorga y revoca; la cocinera los lee y puede registrar una revocación, pero no otorga en nombre del cliente. Nadie los borra desde la app. Un consentimiento revocado no se reactiva: se otorga uno nuevo.
- `clients`: el cliente no crea su propia ficha (con el registro abierto de M2 la crea el servidor, en `prospect`). El estado lo cambia solo la cocinera (y el servidor al aceptar el primer presupuesto, M4); `share_pantry`, solo el cliente.
- `profiles`: el perfil se crea por trigger siempre con rol `client`; nadie cambia su propio rol.
- `recurring_plans`: solo lectura para el cliente.
- Las tarifas (`chef_settings`) no son visibles para clientes: la vista previa y la política de cancelación se exponen con una RPC de solo lectura (M3).

Las escrituras sensibles (estados de sesión, pagos) pasan por Edge Functions con la service role, nunca por updates directos desde la app. Tests de políticas RLS obligatorios (pgTAP o la suite de tests de Supabase).

---

## 7. Pantallas

Ver `docs/prototipo.html`; cambiar de vista con el selector de arriba.

**Cliente**
- **Inicio**: próxima sesión (menú, estado, botón de pre-autorizar), presupuestos pendientes con Aceptar/Rechazar, pedidos enviados, porciones en la heladera, ingredientes por vencer.
- **Pedir**: tipo (semana / extra / cambio), personas, días y comidas, restricciones, platos deseados (los incompatibles tachados), presupuesto estimado en vivo, horarios libres, modo de pago, notas.
- **Sugerencias de la semana** (cliente activo, M2b): catálogo de temporada con los incompatibles tachados; marca, sin cantidad fija, los platos que le gustan y escribe cambios o pedidos especiales (el campo pide no escribir datos de salud); ve el estado de sus pedidos especiales.
- **Despensa** (F2): comidas listas (etiquetas) e ingredientes por ubicación, compartir con Evelyn, agregar producto.
- **Pagos**: método guardado, pendientes, historial con detalle servicio / ticket / pre-autorización.
- **Detalle de sesión** y **hoja de pago**.

Un prospecto con cuenta ve Inicio, Pedir (sin platos deseados) y su perfil; no ve el catálogo ni sugiere platos (§1).

**Cliente nuevo (web pública)**: explicación en 4 pasos, el mismo formulario de pedido con datos de contacto y consentimiento; después, seguimiento del estado y aceptación del presupuesto, que crea la cuenta si todavía no tiene (desde M2 también puede registrarse antes). **Eventos privados** (M3b): sección propia y formulario con fecha libre, invitados, hora aproximada e idea del evento, sin calendario ni precio (5.3).

**Evelyn** (pensado primero para el celular)
- **Inicio**: pendientes accionables, cada uno en uno o dos toques (pedidos y eventos nuevos, pedidos especiales por aprobar, próximas sesiones), ocupación de 7 días, ingreso por servicio, por cobrar, retenido y adelantado.
- **Agenda**: semana, día con línea de tiempo (bloque de compra + bloque de cocina), sesiones y eventos, huecos libres, bloquear día y editor de disponibilidad (estos dos, M5a).
- **Pedidos**: bandeja de pedidos y eventos (etiqueta y filtro, M3b) con su estado, detalle con control de horario, armado de menú con alérgenos (con las sugerencias del cliente a la vista), sugerencia automática, ajuste de precio, enviar o rechazar.
- **Clientes**: lista y ficha (estado, «Segna come cliente», plan, restricciones, preferencias, cocina, despensa compartida, porciones, historial, ingreso).
- **Menús de la semana** (M2b): las sugerencias de cada cliente activo y sus pedidos especiales, para aprobar o proponer una alternativa.
- **Catálogo de platos** (M4a): alta, edición, baja (desactivar), alérgenos UE, dieta, temporada y nombres en it/es/en.
- **Cobros**: para cobrar, falta pre-autorizar, próximas, cobradas.
- **Tarifas**: parámetros de la sección 5.1 con ejemplos en vivo.
- **Detalle de sesión**: progreso, menú con conservación y alertas, "usar primero", pago, carga de ticket con foto, marcar cocinado, registrar pago, cancelar.

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
| Ticket cargado: monto cobrado y liberado | cliente | push con enlace a la foto |
| Cocinado: porciones listas | cliente | push |
| Pedido especial aprobado o con alternativa (M2b) | cliente | push |
| Pago pendiente (24 h y 72 h después) | cliente | push + email |
| Porción vence mañana (F2) | cliente | push a las 8:00 |
| Ingrediente compartido vence y hay sesión en ≤ 3 días (F2) | Evelyn | push |

Sin notificaciones entre las 21:00 y las 8:00 (hora de Roma), salvo fallos de pago. Si el aviso de pedido o evento nuevo también es una excepción está sin decidir (sección 14).

---

## 9. Criterios de aceptación del MVP

1. Un prospecto pide desde la web sin cuenta y ve el precio y los días en que Evelyn tiene lugar (calendario con `get_free_days`; la hora se acuerda con ella). Si ningún día tiene lugar para su pedido, la web se lo dice y puede enviarlo sin fecha. Un evento se pide sin precio ni calendario (5.3). No puede enviar sin contestar la pregunta de alergias (confirmar que nadie tiene o escribirlas), ni con alergias escritas sin el consentimiento de datos de salud.
2. El presupuesto mostrado coincide con los 9 vectores de la sección 5.1 en la app, en la web y en el servidor.
3. Dos clientes no pueden reservar horarios superpuestos aunque acepten al mismo tiempo (la restricción `no_overlap` lo impide y la app muestra un error claro). Un horario ofrecido por `get_free_slots` nunca es rechazado por `no_overlap`.
4. Un presupuesto enviado bloquea el horario 48 h (sesión `held`; un evento, su propio plazo: 5.3) y se libera al vencer o al ser rechazado.
5. Con `preauth`, la retención (servicio + insumos + margen) se crea 48 h antes; al cocinar se captura servicio + ticket y se libera el resto; con un ticket mayor se cobra la diferencia aparte.
6. Evelyn no puede marcar "pagada" una sesión cobrada con Stripe: el estado lo pone el webhook.
7. Un cliente no puede leer datos de otro cliente (test de RLS).
8. Enviar un menú con una receta que choca con una restricción exige confirmación explícita.
9. Cancelar una sesión con retención libera el importe en Stripe.
10. La app funciona en italiano y español; los textos no están hardcodeados.
11. El panel de Evelyn separa ingreso por servicio de reembolso de insumos.
12. Solo un cliente activo (`trial` o `active`) lee el catálogo y guarda sugerencias de platos; un prospecto, con o sin cuenta, no (test de RLS).

---

## 10. Plan de construcción (milestones para Claude Code)

La tabla sigue el orden de trabajo, reordenado el 15/11/2026 con la especificación de la app. Los números son nombres estables (los citan el código y el contrato); los milestones nuevos llevan letra: M3b amplía el pedido de M3, M5a adelanta la disponibilidad de M5, M4a prepara el menú de M4 y M2b necesita las cuentas de M2. Después del PR del formulario con calendario y pregunta de alergias siguen M3b, M5a, M4a, M2 y M2b.

| # | Milestone | Entregable verificable |
|---|---|---|
| F0 | Web de validación | `web/`: landing en italiano, calculadora con `quote.ts`, formulario → Edge Function `public-request` (emails a Evelyn y al cliente), bandeja y agenda en `/gestione/`, privacidad. Deploy en `radicicucina.app` |
| M0 | Setup | Repo, Flutter con entornos dev/prod, proyecto Supabase UE, CI en verde, `CLAUDE.md`, `quote.ts` + vectores en TS y Dart |
| M1 | Esquema y RLS | Migraciones de la sección 4, seeds del prototipo, tests de políticas RLS y de `no_overlap` (incluidas sesiones `held` y margen de un lado) |
| M3 | Horarios y pedido | `get_free_slots()` y `get_free_days()` con tests; Edge Function `public-request` con la disponibilidad por día; formulario de la web con calendario y pregunta de alergias. La pantalla Pedir de la app va con M2 |
| M3b | Eventos privados | Tipo `event` (5.3): sección y formulario propios en la web (fecha libre, invitados, hora aproximada, idea), sin estimación en la web ni en los emails; contrato, `submit_public_request`, checks de la base (`requests_datos_de_presupuesto`, `estimate_required`) y emails, con tests primero; etiqueta y filtro de eventos en la bandeja |
| M5a | Disponibilidad en la app | Bloquear y desbloquear días; después, editar el horario semanal (`availability_rules`). Repositorio + providers, textos ARB y tests; reemplaza el horario inicial fijo de 5.2 |
| M4a | Catálogo de platos | Migración con `name_en` y `season_months`; pantalla de Evelyn: alta, edición, baja (desactivar), alérgenos UE, dieta y temporada; con tests |
| M2 | Auth y perfil, con registro abierto | Registro abierto con Turnstile y login con código; ficha `prospect` creada por el servidor; check `clients_prospect_sin_cuenta` relajado; conservación de las cuentas que no pasan a cliente activo (y privacy); RLS del catálogo solo para clientes activos; roles, perfil del hogar, restricciones con consentimiento, borrado de cuenta; pantalla Pedir de la app. Cambia la regla de altas aquí, en `CLAUDE.md` y en el contrato §10 (§6) |
| M2b | Sugerencias de menú | Cliente activo: sugerencias de la semana (catálogo de temporada sin cantidad fija, incompatibles tachados, nota libre y pedidos especiales). Evelyn: Menús de la semana, con aprobación o alternativa de los pedidos especiales. Tabla propia con RLS, tests primero |
| M4 | Pedidos y presupuestos | Bandeja, menú con alérgenos y con las sugerencias a la vista, ajuste de precio, envío, aceptación → sesión (y la ficha de un prospecto pasa a `trial`), vencimiento de presupuestos; presupuesto de eventos sin fórmula, con recetas propias y su vencimiento |
| M5 | Agenda | Semana y día con sesiones y eventos, huecos libres; Inicio de Evelyn con pendientes accionables |
| M6 | Pagos | Según 5.4 (D6 abierta: sección 14). Stripe en modo test: SetupIntent (app y Checkout web), pre-autorización programada, captura única al cocinar, diferencia, pago al final, efectivo, webhooks, idempotencia |
| M7 | Notificaciones | FCM + email + cron, horario silencioso |
| M8 | Lanzamiento | i18n completo, privacidad en italiano, deploy web, TestFlight y Play interno |
| M9 | F2 Porciones | Etiquetas, contador, avisos |
| M10 | F2 Despensa | Ingredientes, compartir, "usar primero" |
| M11 | F2 Recurrencias | Planes semanales que generan sesiones; el plazo de las sugerencias y la repetición del menú anterior, si se decide D5 |

En cada milestone: plan con `planner` → tests primero → implementación → revisión con `code-reviewer` (y `security-reviewer` en M2, M2b, M4 y M6; `database-reviewer` en M1, M3, M3b, M4a y M2b).

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
- Cómo documentar los insumos: comprados para el cliente y reembolsados con ticket ("spese anticipate in nome e per conto del cliente", art. 15 DPR 633/1972) y separados de la factura del servicio. La app ya los separa, pero el tratamiento fiscal lo define el commercialista.
- Requisitos sanitarios para cocinar en casas ajenas (formación HACCP) y seguro de responsabilidad civil.
- Términos del servicio y política de cancelación por escrito.

---

## 14. Decisiones abiertas

- Identificador de la app y dominio definitivo. El nombre ya está decidido (Radici) y el dominio es `radicicucina.app`. Falta elegir el bundle id antes de la primera subida a las tiendas: no se puede cambiar después de publicar. Hoy sigue el provisorio (`com.sepusola10.mestolo`); los lugares a cambiar están en `app/README.md`.
- Sesión mínima: hoy es 150 min (67 € de servicio) aunque sea 1 porción. ¿Se mantiene, se baja la base de 60 min o se fija un pedido mínimo?
- ¿Se pide tarjeta guardada también a los clientes `pay_after` (para poder cobrar la penalidad por cancelación)?
- Al revocar el consentimiento de salud se borran las restricciones del cliente. ¿Se borran también las copias en pedidos y presupuestos pasados? Pueden servir como prueba de que Evelyn fue informada de una alergia: decidir con quien asesore en privacidad. Mientras tanto se hace lo que dice la privacy: el retiro se procesa con `private.revoke_health_consent`, que borra también las copias de los pedidos (contrato §10.2). Si se decide conservarlas, cambiar la privacy (finalidad y plazo) y esa función.
- La confirmación de que nadie tiene alergias (`requests.no_allergies = true`) se trata como dato de la solicitud (art. 6.1.b RGPD, sin consentimiento de salud), y así lo dice la privacy `2026-11-16`. Confirmarlo con quien asesore en privacidad: si se la considera dato de salud, también necesitaría el consentimiento explícito.
- Alergias de otras personas: el formulario pide las de todos los que van a comer (otros adultos de la casa, invitados de un evento), pero el consentimiento del art. 9.2.a RGPD tiene que darlo cada interesado (por un menor, quien tiene su responsabilidad parental). Hoy quien las escribe declara, en la misma casilla del consentimiento de salud, que esas personas están informadas y de acuerdo, y la privacy `2026-11-16` (§5) le pide informarlas (art. 14) y les reconoce a ellas el derecho a pedir el borrado (contrato §10.2). Confirmar con quien asesore en privacidad si alcanza o si hace falta otro mecanismo (por ejemplo, que Evelyn lo confirme con cada invitado de un evento).
- Tarifas reales. Con los valores de ejemplo, una sesión de 3 h para 4 personas deja 78 € por unas 4,5 h reales (compra + traslados + cocina): unos 17–18 €/h brutos.
- Zona de cobertura (¿solo Bergamo y primer cinturón?).
- Pedido mínimo (ej.: 10 porciones) y recargo por zona lejana.
- ¿Los tápers los pone el cliente o Evelyn (con depósito)?
- Política de cancelación definitiva.
- Satispay sí o no en el MVP.

**De la especificación de la app (15/11/2026)**
- **D5 · Menú semanal recurrente.** La especificación propone un plazo para sugerir platos (hasta un día antes de la primera sesión de la semana) y repetir el menú de la semana anterior si el cliente no sugiere. Sin decidir: queda para M11, con los planes recurrentes. Si se adopta, el plazo va en hora de Roma, Evelyn ve en Inicio quién no sugirió y la repetición vuelve a pasar el control de alérgenos (5.6): nunca copia un plato inactivo, fuera de temporada o que choque con una restricción vigente.
- **D6 · Pagos.** ¿Cuándo se pagan el servicio y los insumos? La idea original es cobrar los insumos por adelantado; también se habló de packs mensuales de 4 sesiones. Hasta decidirlo vale 5.4 (y el cobro manual de Fase 0). Un anticipo cambia §1, 5.4 y el criterio 5; un pack prepago choca con «Nessun abbonamento» de la portada y con `payments.session_id` obligatorio. Decidir antes de M6, con datos del piloto y el commercialista.
- **D7 · Contacto directo en la web.** La especificación pide sumar WhatsApp o email. ¿Se suma, y con qué canal? Solo email es posible sin cambiar el contrato (falta elegir la dirección: la privacy ya publica la de Evelyn y `ciao@radicicucina.app` hoy solo envía). Un link de WhatsApp choca con el contrato (§6), que los prohíbe en la web pública, y con el test de la web que lo verifica: sumarlo cambia los dos en el mismo PR.
- **Control de insumos con vencimiento.** ¿Es la despensa del cliente (Fase 2, M10) o un stock propio de Evelyn? Lo segundo es nuevo y choca con los insumos cobrados por ticket a cada cliente (art. 15, sección 13): verlo con el commercialista.
- **Aviso push de pedido nuevo de noche.** Entre las 21:00 y las 8:00 no hay notificaciones (§8). ¿El aviso a Evelyn de un pedido o evento nuevo espera a las 8:00 o es una excepción, como los fallos de pago?
- **Nombres de las líneas de servicio** (§1): «Radici Quotidiano» y «Radici Privato» son provisorios.
