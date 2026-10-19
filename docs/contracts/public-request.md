# Contrato: pedido desde la web, bandeja de Evelyn y notificaciones

Estado: aprobado por Nicolas el 19/10/2026 (reemplaza el envío por WhatsApp de la Fase 0).
Actualizado el 19/10/2026 para reflejar lo implementado: idempotencia con `requestKey`, `CHEF_ID` opcional, borrado diario de prospectos vencidos (§9), avisos a Evelyn en español por defecto y vistas previas fuera de `ALLOWED_ORIGINS`.
Código del contrato: `supabase/functions/_shared/public_request.ts` (tipos, validación y normalización; tests en `public_request.test.ts`). Si este documento y ese archivo difieren, manda el archivo.

## 1. Flujo

1. El cliente completa `/richiesta/` en la web. Cloudflare Turnstile protege el envío.
2. La web hace `POST` a la Edge Function `public-request` con el JSON `PublicRequestPayload`, que lleva una `requestKey` (UUID) generada una vez por pedido y repetida en cada reintento (§2).
3. La función valida (`parsePublicRequest`), limita por IP, verifica Turnstile, elige la cocinera (`CHEF_ID` o la única de `public.chefs`, §4) y guarda todo en una transacción (`submit_public_request`):
   cliente prospecto, consentimientos, restricciones (solo con consentimiento de salud), pedido con la estimación calculada en el servidor y una notificación para Evelyn.
   Si la `requestKey` ya se usó, no guarda nada y devuelve el pedido original.
4. Responde `201` y, sin hacer esperar al cliente (`EdgeRuntime.waitUntil`), manda:
   - email a Evelyn: aviso de pedido nuevo con resumen y botón a la bandeja;
   - email al cliente: confirmación de que la solicitud fue enviada y que lo contactarán lo antes posible, en su idioma;
   - WhatsApp al cliente con lo mismo, **solo si** aceptó (`whatsappOptIn`) y si la integración de WhatsApp Cloud API está configurada (si no, se omite sin error).

   Un reintento con la misma `requestKey` recibe el mismo `201` y no repite ninguno de estos avisos.
5. Evelyn ve el pedido en la bandeja y en la agenda de la app (Android/iOS) y de la web (`/gestione/`, Flutter web), con aviso emergente en tiempo real si la tiene abierta.
   Desde el detalle puede marcarlo como visto, rechazarlo o contactar al cliente por WhatsApp (link `wa.me` con mensaje armado), teléfono o email.
6. Todos los días, pg_cron borra los prospectos cuyos pedidos no avanzaron en `prospect_retention_days` (90 días; §9).

Notificaciones push en segundo plano (FCM) quedan para una etapa siguiente: necesitan proyecto de Firebase y clave de APNs.

## 2. API: `POST /functions/v1/public-request`

- Público (sin login). `verify_jwt = false` para esta función; la protección es Turnstile + límite por IP + validación.
- `OPTIONS`: CORS. Orígenes permitidos en `ALLOWED_ORIGINS` (lista separada por comas; admite comodín de una etiqueta, ej. `https://*.example.com`). Cualquier otro origen: sin cabeceras CORS, así que el navegador no llega a mandar el `POST` (un `POST` JSON siempre pasa antes por el preflight). Las vistas previas de Pages quedan fuera por defecto (§4).
- Cuerpo: `application/json`, máximo `MAX_PAYLOAD_BYTES` (8 KB).

| Código | Cuerpo | Cuándo |
|---|---|---|
| 201 | `{ "requestId": uuid, "estimate": { portions, recipes, cookMinutes, serviceCents, groceriesEstCents, totalCents } }` | Guardado, o reintento de un pedido ya guardado (misma `requestKey`: el mismo cuerpo) |
| 400 | `{ "errors": { campo: código } }` | Validación (`PublicRequestErrors`; una `requestKey` que no es UUID da `requestKey: "invalid"`) |
| 403 | `{ "errors": { "turnstileToken": "invalid" } }` | Turnstile rechazado |
| 405 / 413 / 415 | `{ "error": "method" \| "tooLarge" \| "contentType" }` | Método, tamaño o tipo inválidos |
| 429 | `{ "error": "rateLimited" }` + `Retry-After` | Más de 5 por hora o 20 por día por IP (los reintentos también cuentan) |
| 500 | `{ "error": "server" }` | Error interno o de configuración (sin detalles; el log lleva el código, §4) |

Los códigos de error por campo son los de `ErrorCode`; la web los traduce a sus textos i18n.

### Idempotencia (`requestKey`)

- Opcional en el payload (para no romper clientes viejos). UUID en formato canónico; el servidor lo pasa a minúsculas.
- Se guarda en `requests.request_key`, única por cocinera (§3).
- La misma clave otra vez, uno después del otro o al mismo tiempo: `201` con el mismo `requestId` y la estimación **guardada** del original (aunque las tarifas hayan cambiado o el reintento traiga otros datos). No se guarda ni se actualiza nada (tampoco el prospecto) y no sale ningún email ni WhatsApp. El log dice `request_duplicate`.
- El reintento se valida igual (400 si es inválido) y pasa por el límite por IP y por Turnstile. Los tokens de Turnstile sirven una sola vez: cada intento lleva un token nuevo y la misma clave.
- La web genera la clave al empezar un pedido (`crypto.randomUUID()`) y la conserva en todos los reintentos hasta recibir un `201`; el pedido siguiente lleva otra. Si el primer intento sí se había guardado, el reintento devuelve ese pedido aunque el formulario haya cambiado entre medio.
- Sin clave, cada envío es un pedido nuevo.

## 3. Base de datos

Migraciones: `20261019120000_public_requests.sql`, `20261019130000_api_grants.sql`, `20261019140000_public_request_idempotency.sql` y `20261019150000_prospect_retention.sql`. Tests pgTAP: `supabase/tests/database/04_public_requests`, `05_public_request_idempotency` y `06_prospect_retention`.

`requests` (columnas nuevas):

| Columna | Tipo | Nota |
|---|---|---|
| `preferred_slot` | text, check in (`morning`,`afternoon`,`any`) | franja preferida |
| `locale` | text not null default `it`, check in (`it`,`es`,`en`) | idioma del cliente (emails, WhatsApp) |
| `whatsapp_opt_in` | boolean not null default false | aceptó confirmación por WhatsApp |
| `estimate` | jsonb | resultado de `calcQuote` con las tarifas de `chef_settings` al crear + `pricing` usado |
| `source` | text not null default `app`, check in (`web`,`app`) | origen |
| `seen_at` | timestamptz | Evelyn lo abrió |
| `request_key` | uuid | `requestKey` de la web; índice único `(chef_id, request_key)` donde no es null. Los pedidos de la app no la llevan |

`requests.restrictions` (ya existe): `{ "allergens": [...], "diets": [...], "note": "..." }`, solo si hay consentimiento de salud; si no, null.

Funciones para la Edge Function y el arranque (todas `security definer`, `set search_path = ''`, ejecutables **solo** por `service_role`):

- `public.submit_public_request(p jsonb) returns jsonb` → `{ "request_id": uuid, "duplicate": boolean, "estimate": jsonb }`. En una transacción crea o reutiliza el cliente, inserta consentimientos, restricciones, pedido y notificación.
  - `p.request_key` (UUID en texto, o null): si ya existe para esa cocinera, devuelve ese pedido con `duplicate: true` y su `estimate` guardada, sin tocar nada. Valida el resto antes de buscar la clave: un reintento inválido falla igual.
  - Dos llamadas simultáneas con la misma clave se serializan con un advisory lock por cocinera y clave (se toma antes que el del email): la segunda espera el commit de la primera y la encuentra. El índice único es la garantía final.
  - Reutiliza un cliente **solo** si es `status = 'prospect'` del mismo chef con el mismo `contact_email` (sin distinguir mayúsculas). En ese caso actualiza nombre, teléfono y zona, y reemplaza sus restricciones.
  - Nunca modifica clientes que no sean prospectos: si el email es de un cliente con cuenta, crea un prospecto nuevo. Evelyn los une a mano más adelante.
- `public.hit_public_request_rate(p_ip_hash text, p_max_hour int, p_max_day int) returns boolean`: registra el intento y dice si está dentro del límite. La tabla es `private.public_request_hits(ip_hash, created_at)`: el esquema `private` está fuera de la API (ni `anon`, ni `authenticated`, ni `service_role` lo ven), con RLS y sin políticas. `ip_hash` es un HMAC-SHA-256 en hexadecimal (`IP_HASH_SALT` como clave; de una IPv6, su /64), nunca la IP. Cada llamada borra los registros de más de 2 días, y el borrado diario también (§9).
- `public.promote_to_chef(p_email text, p_display_name text) returns uuid`: para el arranque. Convierte el usuario de auth con ese email en cocinera: rol `chef`, fila en `chefs` y `chef_settings` por defecto. Devuelve el `chef_id`. Se corre una vez desde el SQL editor; repetirla devuelve la misma ficha.

Privilegios explícitos (`20261019130000_api_grants.sql`): Supabase dejó de dar privilegios implícitos sobre las tablas nuevas de `public` a `anon`, `authenticated` y `service_role` (proyectos nuevos desde el 30/05/2026; todos desde el 30/10/2026). La migración los da explícitos: `service_role`, las cuatro operaciones en todas las tablas de `public`; `authenticated`, lo que gestiona con RLS, y en `requests`, `clients`, `consents`, `profiles`, `chefs`, `payments` y `prepared_portions` las altas y cambios solo por columnas; `anon`, nada. En local `auto_expose_new_tables = false` (`supabase/config.toml`): una tabla nueva sin sus `GRANT` falla también en local y en CI. Toda tabla nueva de `public` trae sus grants en su propia migración.

Realtime: `public.requests` está en la publicación `supabase_realtime`. RLS limita qué filas ve cada uno.

Cambios desde la app: la cocinera actualiza sus pedidos (política "la cocinera gestiona los suyos"), pero solo las columnas `seen_at` y `status`, y el trigger `requests_guard_update` solo deja estos cambios de estado:

| De | A | Para |
|---|---|---|
| `new` | `rejected` | rechazar |
| `rejected` | `new` | deshacer el rechazo |
| `new` | `resolved` | resolver un pedido de cambio (`type = 'change'`) |

Cualquier otro (`quoted`, `accepted`, `declined`, `expired`) lo hace el servidor (Edge Functions o cron con la service role); desde la app falla con `42501 request_status_change_not_allowed`. El cliente con cuenta crea sus pedidos pero no los actualiza. Al crear un pedido desde la app no se pueden escribir `estimate`, `source`, `seen_at`, `created_at` ni `request_key` (privilegios por columna).

## 4. Configuración de la Edge Function (secretos de Supabase)

| Nombre | Secreto | Ejemplo / nota |
|---|---|---|
| `RESEND_API_KEY` | sí | clave de Resend con permiso solo de envío |
| `TURNSTILE_SECRET_KEY` | sí | **obligatoria**. En local: `1x0000000000000000000000000000000AA` (siempre aprueba) |
| `IP_HASH_SALT` | sí | **obligatoria**. Aleatoria (`openssl rand -hex 32`); la IP nunca se guarda en claro |
| `CHEF_ID` | no | opcional: uuid de Evelyn en `chefs` (sale de `promote_to_chef`). Sin él se usa la única fila de `public.chefs` (ver abajo). Hace falta solo con más de una cocinera (el seed local tiene dos) |
| `CHEF_NOTIFY_EMAIL` | no | email de Evelyn para avisos |
| `CHEF_LOCALE` | no | idioma de los avisos a Evelyn: `es` (por defecto), `it` o `en` |
| `MAIL_FROM` | no | `Radici <ciao@radici.sepusola10.com>`; el nombre es la marca de los emails (si falta, Radici) |
| `MAIL_REPLY_TO` | no | email de Evelyn; si falta, `CHEF_NOTIFY_EMAIL` (§5) |
| `EMAIL_TRANSPORT` | no | `resend` (por defecto) o `log` (desarrollo: no manda, registra) |
| `ALLOWED_ORIGINS` | no | producción: `https://radici.sepusola10.com`; local: `http://localhost:5173,http://127.0.0.1:5173`. **Sin vistas previas** (ver abajo) |
| `INBOX_URL` | no | `https://radici.sepusola10.com/gestione/` |
| `PUBLIC_SITE_URL` | no | `https://radici.sepusola10.com` |
| `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_TEMPLATE` | sí / no / no | opcionales; sin ellos no se manda WhatsApp |

`SUPABASE_URL` y la clave de servicio (`SUPABASE_SECRET_KEYS`, o las variables de compatibilidad) las provee Supabase a la función.

Cocinera sin `CHEF_ID`: la función busca en `public.chefs`. Con una sola fila, usa esa. Sin filas (por ejemplo, en el primer despliegue, antes de correr `promote_to_chef`) o con más de una, responde `500` y registra `chef_id_unresolved` con `reason: "no_chef"` o `"multiple_chefs"`. Un `CHEF_ID` que no es uuid no cae en la cocinera por defecto: `500` y log `config_invalid`.

Logs de configuración, solo con nombres de variables: al arrancar, `config_missing` (faltan obligatorias), `config_invalid`, `config_incomplete` (faltan las de emails, CORS o links) y `chef_id_auto` (sin `CHEF_ID`); en cada pedido que no se puede atender, `config_missing`, `config_invalid` o `chef_id_unresolved`.

**Vistas previas de los PR.** `deploy-web.yml` construye las vistas previas (`https://<rama>.<pages>.pages.dev`) con el mismo `SUPABASE_URL` de producción. Si su origen estuviera en `ALLOWED_ORIGINS`, desde una vista previa se crearían pedidos reales (con emails a Evelyn y al cliente). Por eso no van ni en el ejemplo ni en producción. Para probar una a mano:

1. Sumar a la variable `ALLOWED_ORIGINS` el origen exacto de esa vista previa (`https://<rama>.<pages>.pages.dev`; mejor que el comodín `https://*.<pages>.pages.dev`, y nunca `https://*.pages.dev`) y desplegar (`deploy-supabase.yml` a mano, o `supabase secrets set ALLOWED_ORIGINS=...`).
2. El widget de Turnstile tiene que aceptar ese hostname (Cloudflare → Turnstile → el widget → Hostnames).
3. Probar con datos de prueba y un email propio: el pedido y los emails son reales.
4. Al terminar, sacar el origen y volver a desplegar (el workflow avisa mientras `ALLOWED_ORIGINS` tenga un `.pages.dev`), y borrar el pedido de prueba desde la bandeja o el SQL editor.

`<pages>` es el subdominio que Cloudflare asigne al proyecto de Pages `radici` (todavía sin confirmar).

## 5. Emails

- Proveedor: Resend (`POST https://api.resend.com/emails`).
- `Idempotency-Key` por pedido y por **rol** del destinatario, no por dirección: `request-<id>-chef` y `request-<id>-client`. Resend la guarda 24 h: el reintento de un envío (ante 429, 5xx o error de red, una sola vez) no sale dos veces. Un pedido duplicado (misma `requestKey`) ni siquiera llega a Resend.
- Remitente `MAIL_FROM`. Respuestas (`reply_to`):
  - aviso a Evelyn: el email del cliente (al responder, Evelyn le escribe directo al cliente);
  - confirmación al cliente: `MAIL_REPLY_TO`, o `CHEF_NOTIFY_EMAIL` si falta (las respuestas del cliente le llegan a Evelyn); sin ninguno de los dos, sin `reply_to` (las respuestas van a `MAIL_FROM`).
- Siempre HTML + texto plano, diseño simple y legible en móvil, sin imágenes remotas ni seguimiento.
- **Sin datos de salud** (alergias, dietas, nota de restricciones) **ni dirección** en ningún email (SPEC §6), ni las notas libres. Al cliente se le dice "indicaste restricciones alimentarias: Evelyn las tendrá en cuenta"; a Evelyn, "indicó restricciones alimentarias: las ves en la app".
- Al cliente, en su `locale`: gracias, resumen (tipo, personas, días, comidas, fecha y franja preferidas, estimación con la aclaración de que la compra se paga según el ticket), "Evelyn te contactará lo antes posible", link a la privacy.
- A Evelyn, en `CHEF_LOCALE` (español por defecto): nombre, zona, teléfono, email, resumen, estimación, si aceptó WhatsApp, y botón "Abrir en la bandeja" → `INBOX_URL#/richieste/<id>`.
- Asuntos: al cliente, "`<marca>`: hemos recibido tu solicitud" en su idioma, sin datos suyos; a Evelyn, "Nueva solicitud de `<nombre de pila>`", solo si la primera palabra del nombre parece un nombre (letras, y entre ellas apóstrofo, guion o punto). Si trae dígitos, `@`, `+` u otros signos (un teléfono o un email escritos en ese campo), el asunto es "Nueva solicitud desde la web". Nunca teléfono, email, zona, dirección ni datos de salud en un asunto.
- Escapar todo texto del usuario en el HTML.
- Un fallo de envío no rompe el pedido: se registra el error (sin datos personales) y `notifications.sent_at` queda null.
- Con `EMAIL_TRANSPORT=log` no sale nada: se registra `email_logged` con el pedido, el destinatario por rol (`chef` / `client`) y el largo del HTML y del texto.

## 6. Web (`web/`)

- El formulario deja de abrir WhatsApp y no queda ningún link a WhatsApp en la web pública.
- Email obligatorio. Casilla opcional "Quiero recibir la confirmación también por WhatsApp" (`whatsappOptIn`), visible junto al teléfono.
- Turnstile (render explícito, modo "managed"); el token va en el payload y se pide uno nuevo después de cada intento fallido (sirve una sola vez).
- `requestKey`: una por pedido, la misma en todos los reintentos hasta el `201` (§2).
- Tipos y constantes desde `_shared/public_request.ts`: `ALLERGENS`, `DIETS`, `TEXT_LIMITS`, `DATE_WINDOW`, `CONSENT_VERSION`, `normalizePhone`, etc. Un solo origen; nada duplicado en `web/src/request/model.ts`.
- Estados: enviando (botón deshabilitado), éxito (pantalla de gracias con resumen y "te mandamos un email a …"), errores por campo (códigos del servidor), 429, Turnstile fallido y error de red, con opción de reintentar sin perder lo cargado.
- Config (`web/.env.example`): `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_TURNSTILE_SITE_KEY` (en local, `1x00000000000000000000AA`), `VITE_SITE_URL`, `VITE_NOINDEX` y `VITE_BRAND_NAME` (si falta, Radici). `VITE_WHATSAPP_NUMBER` ya no se usa.
- CSP: sumar Turnstile (`script-src` y `frame-src` `https://challenges.cloudflare.com`) y la URL de Supabase en `connect-src`. Verificar en un servidor local con la cabecera real.
- Privacy: datos en Supabase (UE, Frankfurt), emails con Resend, Turnstile de Cloudflare, WhatsApp solo con aceptación, conservación de 90 días para pedidos que no avanzan (§9).

## 7. App y bandeja web (`app/`, Flutter)

- Login de Evelyn con código por email (Supabase Auth, OTP). Si el usuario no es `chef`, mensaje "área de clientes en preparación".
- Secciones de la cocinera:
  - **Richieste**: nuevas (sin `seen_at`), vistas y rechazadas, con contador de nuevas.
  - **Agenda**: calendario mensual y semanal con los pedidos por `preferred_date` y franja, más una lista "senza data".
  - **Detalle**: todos los datos, incluidas las restricciones (Evelyn sí las ve), la estimación guardada y las acciones: marcar visto (al abrir), rechazar, WhatsApp (`https://wa.me/<phoneE164 sin +>?text=<mensaje en el idioma del cliente>`), llamar (`tel:`) y email (`mailto:`).
- Cambios de estado permitidos desde la app: §3.
- Tiempo real: suscripción a `INSERT` en `requests` (filtrado por su `chef_id`) → aviso emergente "Nueva solicitud de …" con botón para abrirla, y actualización de la lista.
- Web: misma app compilada con `flutter build web --base-href /gestione/`, publicada dentro del sitio de Pages en `/gestione/`. Autocontenida (sin CDN de Google para CanvasKit ni fuentes), con su propia CSP en `_headers` para `/gestione/*`.
- Toda la lógica en repositorios y providers, con tests (Supabase simulado con mocktail).

## 8. Despliegue

- `deploy-supabase.yml`: en push a `main` que toque `supabase/**` (o a mano): tests de TypeScript y pgTAP; después `supabase link`, `db push` (solo migraciones, nunca el seed; incluye el trabajo de pg_cron de §9), carga los secretos de la función y `functions deploy public-request`.
  - Secretos de GitHub: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `RESEND_API_KEY`, `TURNSTILE_SECRET_KEY`, `IP_HASH_SALT` (opcional `WHATSAPP_TOKEN`).
  - Variables de GitHub: `SUPABASE_PROJECT_REF`, `CHEF_NOTIFY_EMAIL`, `MAIL_FROM`, `MAIL_REPLY_TO`, `ALLOWED_ORIGINS`, `INBOX_URL`, `PUBLIC_SITE_URL`; opcionales `CHEF_ID`, `CHEF_LOCALE`, `EMAIL_TRANSPORT`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_TEMPLATE`.
  - Los valores vacíos no se cargan (no pisan los que ya estén): para volver a la cocinera automática después de haber cargado `CHEF_ID`, `supabase secrets unset CHEF_ID`.
  - Primer despliegue: sin `CHEF_ID`, la función responde `500` (`chef_id_unresolved`, `no_chef`) hasta que Evelyn entra una vez y se corre `promote_to_chef`; desde ahí funciona sin tocar nada más.
- `deploy-web.yml`: además de la web, compila la app Flutter web y la copia a `dist/gestione/` antes de publicar. Proyecto de Pages `radici` (lo crea el workflow si no existe), servido en el dominio propio `radici.sepusola10.com`.
  - Secreto `CLOUDFLARE_API_TOKEN`; variables `CLOUDFLARE_ACCOUNT_ID`, `SUPABASE_URL` (`https://<ref>.supabase.co`, solo el origen) y `SUPABASE_PUBLISHABLE_KEY` (`sb_publishable_…`, nunca una secreta): un solo valor para la web (`VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` y la CSP) y para `/gestione/` (`--dart-define`). Además `VITE_TURNSTILE_SITE_KEY` (la real: el workflow rechaza las de prueba), `VITE_SITE_URL`, `VITE_NOINDEX` y, opcional, `VITE_BRAND_NAME`. En producción falla antes de publicar si falta la configuración de Supabase o de Turnstile; en una vista previa solo avisa.
  - Las vistas previas usan el backend de producción: fuera de `ALLOWED_ORIGINS` (§4).

## 9. Conservación de datos: prospectos que no avanzan

SPEC §6 y la privacy: los pedidos que no avanzan se conservan como máximo `chef_settings.prospect_retention_days` (90 por defecto). Migración `20261019150000_prospect_retention.sql`.

- `private.purge_expired_prospects()` borra cada cliente que cumple `private.prospect_retention_expired(client_id)`:
  - prospecto sin cuenta (`status = 'prospect'`, `profile_id` null);
  - sin pedidos que avanzaron: todos en `new`, `rejected`, `expired` o `declined` (uno en `quoted`, `accepted` o `resolved` lo conserva);
  - sin sesiones vivas (todas `cancelled`) ni pagos registrados (un pago es un registro contable);
  - y con el último pedido (o el alta, si no tiene pedidos) de hace más de `prospect_retention_days` de su cocinera (90 si faltara su `chef_settings`).
- En cascada se van sus pedidos y presupuestos, consentimientos, restricciones y sesiones canceladas; además se borran las notificaciones cuyo `payload.request_id` apunta a esos pedidos (de cualquier tipo) y los intentos de `private.public_request_hits` de más de 2 días.
- Devuelve `{ "clients", "requests", "notifications", "rate_limit_hits" }` (cuántos borró) y deja en el log de Postgres solo esos contadores. Idempotente: otra corrida no borra nada más.
- Concurrencia: por cada candidato toma el mismo lock que `submit_public_request` (cocinera + email), bloquea la ficha y sus pedidos, y vuelve a evaluar la regla. Un pedido nuevo de esa persona lo conserva, o espera a que termine el borrado y crea un prospecto nuevo. Si justo se registra un pago, ese cliente se conserva y el resto sigue.
- Las dos funciones están en el esquema `private`: ningún rol de la API las ejecuta (tampoco `service_role`).
- pg_cron (Supabase Cron): la migración habilita la extensión como indica Supabase (`create extension if not exists pg_cron with schema pg_catalog`; la imagen de Postgres de Supabase ya la precarga, en local y en el proyecto alojado) y programa el trabajo `radici-purge-expired-prospects` todos los días a las 03:30 UTC (04:30 o 05:30 en Roma), como `postgres`. `cron.schedule` con un nombre existente actualiza ese trabajo: volver a correr la migración no lo duplica.
- A mano, desde el SQL editor: `select private.purge_expired_prospects();`. Las corridas quedan en `cron.job_run_details` (Supabase no limpia esa tabla sola; es una fila por día).
- No cubre a los clientes con cuenta: su borrado (derecho de supresión) es el de la cuenta, en M2.
