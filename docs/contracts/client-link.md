# Contrato: link de la clienta, Edge Function `client-link` y página `/prenotazione/`

Estado: implementado el 21/11/2026 (proceso de presupuesto y menús, SPEC §5.8), sobre la migración `20261121100000_menu_sends.sql` (pgTAP `20_menu_sends`).
Código del contrato: `supabase/functions/_shared/client_link.ts` (el token, el link, el mensaje de cambios, la lectura de la foto de un envío y de la respuesta; tests en `client_link.test.ts`). La función: `supabase/functions/client-link/` (`handler.ts`, con sus tests en `handler.test.ts`, e `index.ts`); el aviso a Evelyn: `_shared/client_link_emails.ts`. La página: `web/prenotazione/index.html`, `web/src/pages/prenotazione.ts` y `web/src/reservation/` (con sus tests). Si este documento y el código difieren, manda el código.

## 1. Para qué

Evelyn le manda a la clienta el menú de cada semana de su reserva (por email, WhatsApp o los dos). Cada mensaje lleva un link a una página de la web donde la clienta ve su reserva entera y, de cada semana, el último menú que le llegó: lo confirma o pide cambios. Todavía no tiene cuenta (M2): el link es la llave. Más adelante, la misma página muestra el presupuesto para aceptar.

## 2. El link

- `https://<sitio>/prenotazione/#t=<token>` (`reservationPageUrl`). El token son 32 bytes al azar en base64url, sin relleno: 43 caracteres (`newClientLinkToken`, `isClientLinkToken`).
- Va en el **fragmento**: el navegador no lo manda a ningún servidor (tampoco a Cloudflare Pages) ni en el `Referer`. La página lo lee de `location.hash` y lo manda en el cuerpo de un `POST`; nunca en una URL, en la consola ni en analytics (no hay).
- La base guarda solo su hash: sha-256 del token en UTF-8, en hexadecimal minúscula (`hashClientLinkToken`, igual a `encode(sha256(convert_to(token, 'UTF8')), 'hex')`), en `client_links.token_hash`. Lo crea la función `chef` al enviar un menú (`chef_link_menu_send`). Cada envío crea un link; todos los de una reserva valen a la vez y vencen a los 120 días.
- Un token con otra forma, que no existe o vencido son lo mismo para la clienta: `linkNotFound`.

## 3. Formato común

- `POST https://<ref>.supabase.co/functions/v1/client-link/<ruta>?forceFunctionRegion=eu-central-1` (la región del proyecto, como el formulario), `Content-Type: application/json`, cuerpo de hasta 16 KB (`CLIENT_LINK_MAX_PAYLOAD_BYTES`). Las claves que el contrato no tiene se ignoran.
- Pública: `verify_jwt = false` (`[functions.client-link]` en `supabase/config.toml`). No hace falta apikey ni sesión.
- CORS: `ALLOWED_ORIGINS`, la misma variable que `public-request` (contrato public-request §4). El preflight permite `POST, OPTIONS`. Un origen que no está en la lista no recibe cabeceras CORS.
- Orden de los chequeos: CORS → ruta (`404 notFound`) → método (`405 method`) → tipo (`415 contentType`) → tamaño (`413 tooLarge`) → JSON y cuerpo (`400 invalidPayload` o `invalidText`) → configuración (`500 server`) → límite por IP (`429 rateLimited`, con `Retry-After: 3600`) → forma del token (`404 linkNotFound`) → función SQL.
- Límite por IP (`hit_public_request_rate`, con un HMAC de la IP o de su /64; nunca la IP): `/view`, 60 por hora y 300 por día, con la clave `client-link:<ip>`; `/confirm` y `/changes`, 10 por hora y 30 por día, con la clave `client-link-answer:<ip>` (cada respuesta le manda un email a Evelyn). Son otros contadores que los del formulario, del calendario y del menù.
- Respuestas en JSON con `Cache-Control: no-store`. Los errores: `{ "error": "<código>" }`.

| Código | Estado | Cuándo |
|---|---|---|
| `linkNotFound` | 404 | el link no existe, venció o el token no tiene la forma de uno |
| `sendNotFound` | 404 | el envío no es de esa reserva o no salió |
| `menuOutdated` | 409 | Evelyn mandó un menú más nuevo para esa semana: se contesta ese |
| `changesRequested` | 409 | `/confirm` de un envío para el que ya pidió cambios: Evelyn manda otro |
| `alreadyConfirmed` | 409 | `/changes` de un envío ya confirmado: los cambios se hablan con Evelyn |
| `invalidText` | 400 | el mensaje está vacío, pasa de 1000 caracteres o tiene caracteres de control |
| `invalidPayload` | 400 | el cuerpo no es un objeto JSON, sin `token` de texto o sin `sendId` uuid |
| `unavailable` | 503 | la base no respondió (se puede reintentar) |
| `server` | 500 | configuración incompleta, una respuesta de la base con otra forma o cualquier otra cosa |

## 4. `POST /view`: la reserva

Cuerpo: `{ "token": "<43 caracteres>" }`. Llama a `client_link_view(p_token_hash)`; si devuelve null, `404 linkNotFound`.

Respuesta `200` (`ClientLinkView`):

```json
{
  "version": 1,
  "locale": "es",
  "chefName": "Evelyn",
  "clientFirstName": "Anna",
  "weeks": [
    {
      "week": 1, "weeks": 2, "date": "2027-03-01", "start": "10:00", "done": false,
      "menu": {
        "sendId": "5e0d…", "sentAt": "2027-02-25T18:03:00.123456+00:00",
        "state": "pending", "confirmedAt": null, "changesRequestedAt": null,
        "content": {
          "locale": "es",
          "dishes": [{ "name": "Lasaña", "description": "Ragú y bechamel.", "allergens": ["gluten", "eggs", "milk"], "diet": null, "portions": 6, "photo": { "thumb": "https://…-thumb.jpg", "full": "https://….jpg" } }],
          "items": [{ "name": "Tomates", "section": "produce", "quantity": 1250, "unit": "g" }, { "name": "Sal", "section": "pantry", "quantity": null, "unit": null }],
          "note": "Hola Anna:\nel lunes llego a las 10."
        }
      }
    },
    { "week": 2, "weeks": 2, "date": "2027-03-08", "start": "10:00", "done": false, "menu": null }
  ]
}
```

- `locale`: el idioma de la reserva (`requests.locale`); la página lo usa si la visitante no eligió otro.
- `clientFirstName`: solo el nombre de pila de la ficha si parece un nombre (`safeFirstName`); si no, `null`. Nunca el nombre completo.
- `weeks`: las sesiones no canceladas del pedido, por fecha («Semana k de N»). `done`: ya cocinada (`cooked` o `paid`); se ve el menú, sin botones. `menu`: el último envío que salió de esa semana, o `null` si Evelyn todavía no lo mandó. `state`: `pending`, `confirmed` o `changesRequested`, según `confirmedAt` y `changesRequestedAt` (la base guarda una sola de las dos).
- `content`: la foto del envío (`menu_sends.snapshot`) tal como salió, ya en el idioma de la clienta, armada de nuevo campo por campo (`readMenuSnapshot`), o `null` si no se puede leer (la función lo deja en el log con el id del envío y la página dice que no puede mostrarlo, sin botones).

### La foto de un envío (versión 1)

La arma la función `chef` al preparar el envío. `client-link` lee solo esto, ignora cualquier otro campo (las fechas de la reserva, el id de la receta, lo que se sume) y no muestra a medias una foto rota:

- `v: 1` y `locale` (`it`, `es` o `en`).
- `dishes` (al menos uno): `name` (texto), `description` (texto o null), `allergens` (los del Reg. UE 1169/2011 del enum `allergen`; se devuelven sin repetir, en su orden), `diet` (`vegetarian`, `vegan` o null), `portions` (entero de 1 a 500), `photo` (`{ thumb, full }` de recipe-photos en el origen de Supabase; con otra forma u otro origen, el plato sale sin foto: la foto nunca descarta un plato).
- `items` (puede estar vacía): `name`, `section` (`produce`, `meat_fish`, `dairy_eggs`, `bakery`, `pantry`, `frozen`, `other`; una desconocida va a `other`), `quantity` (entero de 1 a 1.000.000) y `unit` (`g`, `ml`, `pcs`) juntas, o las dos null: «q.b.», algo para tener en casa.
- `note`: texto (con sus saltos de línea) o null.

Nunca lleva precios, pagos, dirección ni las alergias de la clienta; nada de esto los lee.

## 5. `POST /confirm` y `POST /changes`: la respuesta de la clienta

- `/confirm`, cuerpo `{ "token", "sendId" }` → `client_link_confirm_menu`. `200 { "confirmedAt": "<timestamptz>", "already": false }`. Idempotente: si ya estaba confirmado, la misma hora y `already: true`, sin aviso nuevo. Errores: `linkNotFound`, `sendNotFound`, `menuOutdated`, `changesRequested`.
- `/changes`, cuerpo `{ "token", "sendId", "text" }` → `client_link_request_changes`. `200 { "changesRequestedAt": "<timestamptz>" }`. El texto se normaliza como lo acepta la base (`normalizeChangesText`): los saltos de línea (`\r\n`, `\r`, U+2028, U+2029) pasan a `\n` y las tabulaciones a espacios; recortado; de 1 a 1000 caracteres contados como Postgres (code points) y sin otros caracteres de control (si no, `400 invalidText` sin llamar a la base). Un pedido nuevo reemplaza al anterior y vuelve a avisar. Errores: `linkNotFound`, `sendNotFound`, `menuOutdated`, `alreadyConfirmed`, `invalidText`.
- Solo se contesta el último envío de una semana: si Evelyn mandó otro, `409 menuOutdated` y la página muestra el nuevo.

## 6. Avisos a Evelyn

- Después de cada respuesta (salvo una confirmación repetida), en segundo plano (`EdgeRuntime.waitUntil`): un email que falla nunca cambia la respuesta de la clienta; queda en el log (`email_failed`).
- A `CHEF_NOTIFY_EMAIL`, en `CHEF_LOCALE`, con el diseño de los otros emails: «Anna confirmó el menú de la semana 1» / «Anna pidió cambios en el menú de la semana 1», la semana «k de N», la fecha larga y la hora de llegada, y el botón al pedido en la bandeja (`INBOX_URL#/richieste/<id>`). En el asunto, del nombre solo el de pila si parece un nombre; en el cuerpo, el de la ficha, escapado.
- **El mensaje de la clienta no va en el email**: es una nota libre, y las notas libres nunca salen por email ni push (SPEC §6), aunque el aviso vaya a la dirección de Evelyn. El email le dice que lo lea en la app, en el pedido (`menu_sends.changes_text`, que la cocina lee con su RLS).
- Clave de idempotencia de Resend: `menu-confirmed-<sendId>` y `menu-changes-<sendId>-<hora en ms>`. Con `EMAIL_TRANSPORT=log` no sale nada (solo los tamaños en el log). Sin `CHEF_NOTIFY_EMAIL`, o sin `RESEND_API_KEY` y `MAIL_FROM`, se saltea (`email_skipped`). Una semana que se canceló después del envío no tiene «semana k»: tampoco se avisa.

## 7. Configuración

Los secretos que ya comparten las funciones (los carga «Secretos de la función» de `deploy-supabase.yml`; local: `supabase/functions/.env`, ver `.env.example`):

- Obligatorias (sin ellas, `500`): `IP_HASH_SALT`, y `SUPABASE_URL` y la clave secreta que pone Supabase. De `SUPABASE_URL` sale el origen de las fotos de los platos (con `supabase functions serve` es la dirección interna de Docker: los platos salen sin foto).
- Para los avisos: `CHEF_NOTIFY_EMAIL`, `CHEF_LOCALE` (es por defecto), `MAIL_FROM`, `RESEND_API_KEY` (o `EMAIL_TRANSPORT=log`) e `INBOX_URL`. Para la web: `ALLOWED_ORIGINS`. Las que faltan se avisan al arrancar (`config_incomplete`, solo los nombres).

## 8. Despliegue

- `deploy-supabase.yml`, paso «Desplegar client-link», después de las migraciones (llama a las `client_link_*`) y de los secretos: `supabase functions deploy client-link --project-ref … --use-api`. `verify_jwt = false` sale de `config.toml`.
- CI: `deno check` de `supabase/functions/client-link/index.ts` (job `edge-functions`) y los tests de Node (`npm test`).
- La página sale con la web (`deploy-web.yml`): necesita `VITE_SUPABASE_URL`, como el formulario.

## 9. Logs y datos

- Solo el evento, la ruta, códigos e ids (del pedido y del envío): `link_viewed` (con la cantidad de semanas y de menús), `menu_confirmed`, `changes_requested`, `link_not_found`, `rejected`, `invalid_payload`, `rate_limited`, `snapshot_unreadable`, `email_*`, `db_error` (operación y SQLSTATE, nunca el mensaje de Postgres).
- Nunca el token ni su hash, nombres, el mensaje de la clienta, los platos, la nota, direcciones de email ni la IP.
- La función no guarda nada propio: las respuestas las guardan las funciones SQL en `menu_sends`.

## 10. La página `/prenotazione/`

- Italiano por defecto en el HTML; textos en `web/src/i18n/{it,es,en}.json` (`reservation.*`). Idioma: el que eligió la visitante (`?lang=` o el guardado) o, si nunca eligió, el de la reserva (`locale` de `/view`; `initShell({ defaultLang })`).
- Arriba, el saludo con el nombre de pila (o sin nombre). Después (cuando llegue) el presupuesto para aceptar. Después cada semana: «Settimana k di N», la fecha y la hora de llegada y, si Evelyn mandó el menú, su estado (por confirmar, con la fecha del envío; confirmado, con la fecha; cambios pedidos, «Evelyn te lo vuelve a mandar»), los platos (miniatura si tiene, nombre, descripción, porciones, dieta y alérgenos con su nombre), la lista de compras por sección (1250 g → «1,25 kg» en it y es, «1.25 kg» en en; ml → l; piezas con su palabra) con lo «q.b.» aparte («Da avere in casa») y la nota de Evelyn (con sus saltos de línea, como texto). Sin menú: «te lo manda Evelyn».
- Por confirmar (y antes de cocinar): «Confermo il menù» y «Chiedo dei cambi» (un campo de hasta 1000 caracteres con contador, que pide no escribir datos de salud). Después de responder, la semana muestra el resultado (el foco va a su estado) y la página vuelve a leer la reserva. `menuOutdated` muestra el menú nuevo sin perder el mensaje a medio escribir. Sin conexión, error o demasiados intentos: el error junto al botón, anunciado en una región en vivo. Link no válido o vencido: «escribe a Evelyn y te manda uno nuevo».
- Todo texto que llega de la función se pinta como texto (`web/src/lib/vdom.ts`: nunca `innerHTML`). Sin precios, pagos, dirección ni alergias de la clienta: la página muestra solo la foto del envío.
- Nunca se indexa (`<meta name="robots" content="noindex, nofollow">` y `X-Robots-Tag`), sin canonical; conserva la imagen para la vista previa del link en WhatsApp. CSP propia en `public/_headers`: la de `/*` más el origen de Supabase en `connect-src` (la función) e `img-src` (las fotos). Nada de terceros.

## 11. Pruebas

- `npm test` (raíz): `client_link.test.ts`, `client_link_emails.test.ts` y `client-link/handler.test.ts` (rutas, errores, límite por IP, CORS, avisos por idioma, que un email que falla no rompa la respuesta y que los logs no lleven datos).
- `cd web && npm test`: `src/reservation/*.test.ts` (fragmento, llamadas con un fetch simulado, formatos, estados y acciones, lo que se pinta en cada idioma y el escapado) y `src/lib/vdom.test.ts`.
