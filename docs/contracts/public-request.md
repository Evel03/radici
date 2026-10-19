# Contrato: pedido desde la web, bandeja de Evelyn y notificaciones

Estado: aprobado por Nicolas el 19/10/2026 (reemplaza el envío por WhatsApp de la Fase 0).
Código del contrato: `supabase/functions/_shared/public_request.ts` (tipos, validación y normalización; tests en `public_request.test.ts`). Si este documento y ese archivo difieren, manda el archivo.

## 1. Flujo

1. El cliente completa `/richiesta/` en la web. Cloudflare Turnstile protege el envío.
2. La web hace `POST` a la Edge Function `public-request` con el JSON `PublicRequestPayload`.
3. La función valida (`parsePublicRequest`), limita por IP, verifica Turnstile y guarda todo en una transacción (`submit_public_request`):
   cliente prospecto, consentimientos, restricciones (solo con consentimiento de salud), pedido con la estimación calculada en el servidor y una notificación para Evelyn.
4. Responde `201` y, sin hacer esperar al cliente (`EdgeRuntime.waitUntil`), manda:
   - email a Evelyn: aviso de pedido nuevo con resumen y botón a la bandeja;
   - email al cliente: confirmación de que la solicitud fue enviada y que lo contactarán lo antes posible, en su idioma;
   - WhatsApp al cliente con lo mismo, **solo si** aceptó (`whatsappOptIn`) y si la integración de WhatsApp Cloud API está configurada (si no, se omite sin error).
5. Evelyn ve el pedido en la bandeja y en la agenda de la app (Android/iOS) y de la web (`/gestione/`, Flutter web), con aviso emergente en tiempo real si la tiene abierta.
   Desde el detalle puede marcarlo como visto, rechazarlo o contactar al cliente por WhatsApp (link `wa.me` con mensaje armado), teléfono o email.

Notificaciones push en segundo plano (FCM) quedan para una etapa siguiente: necesitan proyecto de Firebase y clave de APNs.

## 2. API: `POST /functions/v1/public-request`

- Público (sin login). `verify_jwt = false` para esta función; la protección es Turnstile + límite por IP + validación.
- `OPTIONS`: CORS. Orígenes permitidos en `ALLOWED_ORIGINS` (lista separada por comas; admite comodín de subdominio, ej. `https://*.mestolo-dsa.pages.dev`). Cualquier otro origen: sin cabeceras CORS.
- Cuerpo: `application/json`, máximo `MAX_PAYLOAD_BYTES` (8 KB).

| Código | Cuerpo | Cuándo |
|---|---|---|
| 201 | `{ "requestId": uuid, "estimate": { portions, recipes, cookMinutes, serviceCents, groceriesEstCents, totalCents } }` | Guardado |
| 400 | `{ "errors": { campo: código } }` | Validación (`PublicRequestErrors`) |
| 403 | `{ "errors": { "turnstileToken": "invalid" } }` | Turnstile rechazado |
| 405 / 413 / 415 | `{ "error": "method" \| "tooLarge" \| "contentType" }` | Método, tamaño o tipo inválidos |
| 429 | `{ "error": "rateLimited" }` + `Retry-After` | Más de 5 por hora o 20 por día por IP |
| 500 | `{ "error": "server" }` | Error interno (sin detalles) |

Los códigos de error por campo son los de `ErrorCode`; la web los traduce a sus textos i18n.

## 3. Base de datos (nueva migración)

`requests` (columnas nuevas):

| Columna | Tipo | Nota |
|---|---|---|
| `preferred_slot` | text, check in (`morning`,`afternoon`,`any`) | franja preferida |
| `locale` | text not null default `it`, check in (`it`,`es`,`en`) | idioma del cliente (emails, WhatsApp) |
| `whatsapp_opt_in` | boolean not null default false | aceptó confirmación por WhatsApp |
| `estimate` | jsonb | resultado de `calcQuote` con las tarifas de `chef_settings` al crear + `pricing` usado |
| `source` | text not null default `app`, check in (`web`,`app`) | origen |
| `seen_at` | timestamptz | Evelyn lo abrió |

`requests.restrictions` (ya existe): `{ "allergens": [...], "diets": [...], "note": "..." }`, solo si hay consentimiento de salud; si no, null.

Nuevas funciones (todas `security definer`, `set search_path = ''`, ejecutables **solo** por `service_role`):

- `public.submit_public_request(p jsonb) returns uuid`: en una transacción crea o reutiliza el cliente, inserta consentimientos, restricciones, pedido y notificación, y devuelve el id del pedido.
  - Reutiliza un cliente **solo** si es `status = 'prospect'` del mismo chef con el mismo `contact_email` (sin distinguir mayúsculas). En ese caso actualiza nombre, teléfono y zona, y reemplaza sus restricciones.
  - Nunca modifica clientes que no sean prospectos: si el email es de un cliente con cuenta, crea un prospecto nuevo. Evelyn los une a mano más adelante.
- `public.hit_public_request_rate(p_ip_hash text, p_max_hour int, p_max_day int) returns boolean`: registra el intento y dice si está dentro del límite. Tabla `public.public_request_hits(ip_hash, created_at)` con RLS sin políticas; borra registros de más de 2 días.
- `public.promote_to_chef(p_email text, p_display_name text) returns uuid`: para el arranque. Convierte el usuario de auth con ese email en cocinera: rol `chef`, fila en `chefs` y `chef_settings` por defecto. Devuelve el `chef_id`. Se corre una vez desde el SQL editor.

Realtime: agregar `public.requests` a la publicación `supabase_realtime`. RLS ya limita qué filas ve cada uno.

La cocinera ya puede actualizar sus pedidos (política "la cocinera gestiona los suyos"). Desde la app solo cambia `seen_at` y `status` (`new` → `rejected`).

## 4. Configuración de la Edge Function (secretos de Supabase)

| Nombre | Secreto | Ejemplo / nota |
|---|---|---|
| `RESEND_API_KEY` | sí | clave de Resend con permiso solo de envío |
| `TURNSTILE_SECRET_KEY` | sí | en local: `1x0000000000000000000000000000000AA` (siempre aprueba) |
| `IP_HASH_SALT` | sí | aleatorio; la IP nunca se guarda en claro |
| `CHEF_ID` | no | uuid de Evelyn en `chefs` (sale de `promote_to_chef`) |
| `CHEF_NOTIFY_EMAIL` | no | email de Evelyn para avisos |
| `CHEF_LOCALE` | no | idioma de los avisos a Evelyn (`it`, `es`, `en`; por defecto `it`) |
| `MAIL_FROM` | no | `Mestolo <ciao@mestolo.sepusola10.com>` |
| `MAIL_REPLY_TO` | no | email de Evelyn; si falta, `CHEF_NOTIFY_EMAIL` |
| `EMAIL_TRANSPORT` | no | `resend` (por defecto) o `log` (desarrollo: no manda, registra) |
| `ALLOWED_ORIGINS` | no | `https://mestolo.sepusola10.com,https://mestolo-dsa.pages.dev,https://*.mestolo-dsa.pages.dev,http://localhost:5173` |
| `INBOX_URL` | no | `https://mestolo.sepusola10.com/gestione/` |
| `PUBLIC_SITE_URL` | no | `https://mestolo.sepusola10.com` |
| `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_TEMPLATE` | sí / no / no | opcionales; sin ellos no se manda WhatsApp |

`SUPABASE_URL` y la clave de servicio las provee Supabase a la función.

## 5. Emails

- Proveedor: Resend (`POST https://api.resend.com/emails`), con `Idempotency-Key` = `request-<id>-<destinatario>`.
- Remitente `MAIL_FROM`, respuesta a `MAIL_REPLY_TO` (las respuestas del cliente le llegan a Evelyn).
- Siempre HTML + texto plano, diseño simple y legible en móvil, sin imágenes remotas ni seguimiento.
- **Sin datos de salud** (alergias, dietas, nota de restricciones) **ni dirección** en ningún email (SPEC §6). Al cliente se le dice "indicaste restricciones alimentarias: Evelyn las tendrá en cuenta"; a Evelyn, "con restricciones: ver en la bandeja".
- Al cliente, en su `locale`: gracias, resumen (tipo, personas, días, comidas, fecha y franja preferidas, estimación con la aclaración de que la compra se paga según el ticket), "Evelyn te contactará lo antes posible", link a la privacy.
- A Evelyn, en `CHEF_LOCALE`: nombre, zona, teléfono, email, resumen, estimación, si aceptó WhatsApp, y botón "Abrir en la bandeja" → `INBOX_URL#/richieste/<id>` (o la ruta que use la app).
- Escapar todo texto del usuario en el HTML. Nada de datos del usuario en el asunto salvo el nombre de pila.
- Un fallo de envío no rompe el pedido: se registra el error (sin datos personales) y `notifications.sent_at` queda null.

## 6. Web (`web/`)

- El formulario deja de abrir WhatsApp y no queda ningún link a WhatsApp en la web pública.
- Email obligatorio. Casilla opcional "Quiero recibir la confirmación también por WhatsApp" (`whatsappOptIn`), visible junto al teléfono.
- Turnstile (render explícito, modo "managed"); el token va en el payload.
- Tipos y constantes desde `_shared/public_request.ts`: `ALLERGENS`, `DIETS`, `TEXT_LIMITS`, `DATE_WINDOW`, `CONSENT_VERSION`, `normalizePhone`, etc. Un solo origen; nada duplicado en `web/src/request/model.ts`.
- Estados: enviando (botón deshabilitado), éxito (pantalla de gracias con resumen y "te mandamos un email a …"), errores por campo (códigos del servidor), 429, Turnstile fallido y error de red, con opción de reintentar sin perder lo cargado.
- Config nueva: `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_TURNSTILE_SITE_KEY` (en local, `1x00000000000000000000AA`). `VITE_WHATSAPP_NUMBER` deja de usarse.
- CSP: sumar Turnstile (`script-src` y `frame-src` `https://challenges.cloudflare.com`) y la URL de Supabase en `connect-src`. Verificar en un servidor local con la cabecera real.
- Privacy: datos en Supabase (UE, Frankfurt), emails con Resend, Turnstile de Cloudflare, WhatsApp solo con aceptación, conservación de 90 días para pedidos que no avanzan.

## 7. App y bandeja web (`app/`, Flutter)

- Login de Evelyn con código por email (Supabase Auth, OTP). Si el usuario no es `chef`, mensaje "área de clientes en preparación".
- Secciones de la cocinera:
  - **Richieste**: nuevas (sin `seen_at`), vistas y rechazadas, con contador de nuevas.
  - **Agenda**: calendario mensual y semanal con los pedidos por `preferred_date` y franja, más una lista "senza data".
  - **Detalle**: todos los datos, incluidas las restricciones (Evelyn sí las ve), la estimación guardada y las acciones: marcar visto (al abrir), rechazar, WhatsApp (`https://wa.me/<phoneE164 sin +>?text=<mensaje en el idioma del cliente>`), llamar (`tel:`) y email (`mailto:`).
- Tiempo real: suscripción a `INSERT` en `requests` (filtrado por su `chef_id`) → aviso emergente "Nueva solicitud de …" con botón para abrirla, y actualización de la lista.
- Web: misma app compilada con `flutter build web --base-href /gestione/`, publicada dentro del sitio de Pages en `/gestione/`. Autocontenida (sin CDN de Google para CanvasKit ni fuentes), con su propia CSP en `_headers` para `/gestione/*`.
- Toda la lógica en repositorios y providers, con tests (Supabase simulado con mocktail).

## 8. Despliegue

- `deploy-supabase.yml` (nuevo): en push a `main` que toque `supabase/**`, hace `supabase link`, `db push` y `functions deploy public-request`, y carga los secretos de la función desde los secretos y variables de GitHub.
  - Secretos de GitHub: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `RESEND_API_KEY`, `TURNSTILE_SECRET_KEY`, `IP_HASH_SALT`.
  - Variables de GitHub: `SUPABASE_PROJECT_REF`, `CHEF_ID`, `CHEF_NOTIFY_EMAIL`, `CHEF_LOCALE`, `MAIL_FROM`, etc.
- `deploy-web.yml`: además de la web, compila la app Flutter web y la copia a `dist/gestione/` antes de publicar.
