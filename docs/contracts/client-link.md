# Contrato: link de la clienta, Edge Function `client-link` y página `/prenotazione/`

Estado: implementado el 21/11/2026 (proceso de presupuesto y menús, SPEC §5.8), sobre la migración `20261121100000_menu_sends.sql` (pgTAP `20_menu_sends`). Actualizado el 22/11/2026 con la revisión: la semana va por su sesión, `sessionCancelled`, el nombre del pedido, los saltos de línea pegados, las semanas ya cocinadas y la privacy `2026-11-22`. Actualizado el mismo día con el presupuesto (SPEC §5.8, «Presupuesto»; migración `20261121120000_quotes.sql`, pgTAP `22_quotes`): `/view` trae el presupuesto y lo que vio la clienta (§4), que lo acepta o lo rechaza (`/accept`, `/decline`: §5); la página lo muestra arriba de las semanas (§10) y la privacy lo cuenta desde su versión `2026-11-23`.
Código del contrato: `supabase/functions/_shared/client_link.ts` (el token, el link, el mensaje de cambios, la lectura de la foto de un envío, del presupuesto y de la respuesta; tests en `client_link.test.ts`; el presupuesto de la foto, `_shared/quote_snapshot.ts`). La función: `supabase/functions/client-link/` (`handler.ts`, con sus tests en `handler.test.ts`, e `index.ts`); el aviso a Evelyn: `_shared/client_link_emails.ts`. La página: `web/prenotazione/index.html`, `web/src/pages/prenotazione.ts` y `web/src/reservation/` (con sus tests). Si este documento y el código difieren, manda el código.

## 1. Para qué

Evelyn le manda a la clienta el menú de cada semana de su reserva (por email, WhatsApp o los dos). Cada mensaje lleva un link a una página de la web donde la clienta ve su reserva entera y, de cada semana, el último menú que le llegó: lo confirma o pide cambios. Todavía no tiene cuenta (M2): el link es la llave. Si Evelyn le mandó un presupuesto (viaja con el menú de la semana 1, contrato chef-api §13 y §14), la página lo muestra arriba de las semanas y la clienta lo acepta, y con él el menú de la semana 1, o lo rechaza.

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
- Límite por IP (`hit_public_request_rate`, con un HMAC de la IP o de su /64; nunca la IP): `/view`, 60 por hora y 300 por día, con la clave `client-link:<ip>`; `/confirm`, `/changes`, `/accept` y `/decline`, en un solo contador de 10 por hora y 30 por día, con la clave `client-link-answer:<ip>` (cada respuesta le manda un email a Evelyn). Son otros contadores que los del formulario, del calendario y del menù.
- Respuestas en JSON con `Cache-Control: no-store`. Los errores: `{ "error": "<código>" }`; `quoteClosed` puede llevar además `"reason"` (`accepted`, `declined`, `withdrawn` o `expired`).

| Código | Estado | Cuándo |
|---|---|---|
| `linkNotFound` | 404 | el link no existe, venció o el token no tiene la forma de uno |
| `sendNotFound` | 404 | el envío no es de esa reserva o no salió |
| `menuOutdated` | 409 | Evelyn mandó un menú más nuevo para esa semana: se contesta ese |
| `sessionCancelled` | 409 | la semana se canceló después del envío: ya no hay menú que contestar (SQL `session_cancelled`) |
| `changesRequested` | 409 | `/confirm` o `/accept` de un envío para el que ya pidió cambios: Evelyn manda otro |
| `alreadyConfirmed` | 409 | `/changes` de un envío ya confirmado: los cambios se hablan con Evelyn |
| `quotePending` | 409 | `/confirm` de un menú que va con un presupuesto abierto: se confirma aceptando el presupuesto (`/accept`) |
| `quoteClosed` | 409 | el presupuesto ya no se contesta: aceptado, rechazado, retirado o vencido (`reason`, cuando la base lo dice: en `/accept` y `/decline`). En `/confirm` y `/changes`, un menú que iba con un presupuesto cerrado sin aceptar |
| `quoteChanged` | 409 | `/accept` de un presupuesto que Evelyn cambió (precio o semanas) y todavía no reenvió: no se acepta lo que ya no vale |
| `notAQuote` | 409 | `/accept` o `/decline` de un envío que no lleva presupuesto |
| `quoteEmpty` | 409 | `/accept` de un presupuesto sin semanas por aceptar |
| `invalidText` | 400 | el mensaje, ya limpio, está vacío o pasa de 1000 caracteres (o la base no lo aceptó) |
| `invalidPayload` | 400 | el cuerpo no es un objeto JSON, sin `token` de texto, sin `sendId` uuid o sin `text` de texto |
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
  "quote": {
    "id": "9a0e…", "version": 1, "status": "sent", "sentAt": "2027-02-25T18:03:00.123456+00:00",
    "holdUntil": "2027-02-27T18:03:00.123456+00:00", "acceptedAt": null, "sendId": "5e0d…",
    "summary": { "totalCents": 30000, "weeks": [{ "date": "2027-03-01", "start": "10:00", "serviceCents": 15000 },
                                               { "date": "2027-03-08", "start": "10:00", "serviceCents": 15000 }] }
  },
  "weeks": [
    {
      "sessionId": "5e55…", "week": 1, "weeks": 2, "date": "2027-03-01", "start": "10:00", "done": false,
      "menu": {
        "sendId": "5e0d…", "sentAt": "2027-02-25T18:03:00.123456+00:00",
        "state": "pending", "confirmedAt": null, "changesRequestedAt": null, "quoteId": "9a0e…",
        "content": {
          "locale": "es",
          "dishes": [{ "name": "Lasaña", "description": "Ragú y bechamel.", "allergens": ["gluten", "eggs", "milk"], "diet": null, "portions": 6, "photo": { "thumb": "https://…-thumb.jpg", "full": "https://….jpg" } }],
          "items": [{ "name": "Tomates", "section": "produce", "quantity": 1250, "unit": "g" }, { "name": "Sal", "section": "pantry", "quantity": null, "unit": null }],
          "note": "Hola Anna:\nel lunes llego a las 10."
        }
      }
    },
    { "sessionId": "5e55…", "week": 2, "weeks": 2, "date": "2027-03-08", "start": "10:00", "done": false, "menu": null }
  ]
}
```

- `locale`: el idioma de la reserva (`requests.locale`); la página lo usa si la visitante no eligió otro.
- `clientFirstName`: el nombre de pila con que llegó el pedido (`requests.contact`, el mismo del mensaje y de la bandeja) o, si no tiene, el de la ficha, solo si parece un nombre (`safeFirstName`); si no, `null`. Nunca el nombre completo.
- `weeks`: las sesiones no canceladas del pedido, por fecha («Semana k de N»). `sessionId`: la identidad de la semana para la página (el número cambia si se cancela una semana anterior, y la fecha si Evelyn la mueve; el id, no); no abre nada: para contestar hacen falta el token y el envío. `done`: ya cocinada (`cooked` o `paid`); se ve el menú, sin botones. `menu`: el último envío que salió de esa semana, o `null` si Evelyn todavía no lo mandó. `state`: `pending`, `confirmed` o `changesRequested`, según `confirmedAt` y `changesRequestedAt` (la base guarda una sola de las dos).
- `content`: la foto del envío (`menu_sends.snapshot`) tal como salió, ya en el idioma de la clienta, armada de nuevo campo por campo (`readMenuSnapshot`), o `null` si no se puede leer (la función lo deja en el log con el id del envío y la página dice que no puede mostrarlo, sin botones).
- `menu.quoteId`: el presupuesto que viaja con ese envío (el menú de la semana 1 de un presupuesto), o `null`. Mientras ese presupuesto está abierto, el menú no se confirma solo (`409 quotePending`): se acepta el presupuesto.
- `quote`: el último presupuesto que salió de la reserva (`client_link_view`), o `null`. `version` (1 la primera vez; cada reenvío, la siguiente: solo se acepta la última), `status` (`sent`: por aceptar; `changed`: Evelyn le cambió el precio o una semana y todavía no lo reenvió, no se acepta; `accepted`, con `acceptedAt`; `declined`; `withdrawn`; `expired`, también si pasó el plazo y la base todavía no lo venció), `sentAt` (el último envío), `holdUntil` (hasta cuándo se acepta) y `sendId` (el último envío que lo llevó: con ese se acepta o se rechaza).
- `quote.summary`: lo que vio la clienta, de la foto del envío `sendId` (su bloque `quote`, contrato chef-api §13): las semanas con su fecha, su llegada y el precio del servicio de cada una, y el total, en centavos. Solo por aceptar (`sent`) o aceptado (`accepted`) y si ese envío está entre las semanas de la respuesta; si no (cambiado, rechazado, retirado o vencido, o una foto sin el presupuesto), `null`: la página muestra el estado sin precios.
- Una función de antes sin `quote` ni `quoteId` se lee como una reserva sin presupuesto: sumar estos campos no cambió `version`.

### La foto de un envío (versión 1)

La arma la función `chef` al preparar el envío. `client-link` lee solo esto, ignora cualquier otro campo (las fechas de la reserva, el id de la receta, lo que se sume) y no muestra a medias una foto rota:

- `v: 1` y `locale` (`it`, `es` o `en`).
- `dishes` (al menos uno): `name` (texto), `description` (texto o null), `allergens` (los del Reg. UE 1169/2011 del enum `allergen`; se devuelven sin repetir, en su orden), `diet` (`vegetarian`, `vegan` o null), `portions` (entero de 1 a 500), `photo` (`{ thumb, full }` de recipe-photos en el origen de Supabase; con otra forma u otro origen, el plato sale sin foto: la foto nunca descarta un plato).
- `items` (puede estar vacía): `name`, `section` (`produce`, `meat_fish`, `dairy_eggs`, `bakery`, `pantry`, `frozen`, `other`; una desconocida va a `other`), `quantity` (entero de 1 a 1.000.000) y `unit` (`g`, `ml`, `pcs`) juntas, o las dos null: «q.b.», algo para tener en casa.
- `note`: texto (con sus saltos de línea) o null. Sale como la escribió Evelyn (no se traduce); los nombres de la lista sí pueden venir traducidos.

- `quote` (solo en el envío de la semana 1 de un presupuesto): no entra en `content`; de él sale `quote.summary` (arriba). Uno que no cierra no se muestra.

Nunca lleva pagos (ni cómo ni cuándo se paga), dirección ni las alergias de la clienta; nada de esto los lee. Del precio, solo el del servicio del presupuesto.

## 5. `POST /confirm` y `POST /changes`: la respuesta de la clienta

- `/confirm`, cuerpo `{ "token", "sendId" }` → `client_link_confirm_menu`. `200 { "confirmedAt": "<timestamptz>", "already": false }`. Idempotente: si ya estaba confirmado, la misma hora y `already: true`, sin aviso nuevo. Errores: `linkNotFound`, `sendNotFound`, `menuOutdated`, `sessionCancelled`, `changesRequested`, `quotePending` (va con un presupuesto abierto: se acepta el presupuesto) y `quoteClosed` (iba con un presupuesto que se cerró sin aceptarse).
- `/changes`, cuerpo `{ "token", "sendId", "text" }` → `client_link_request_changes`. `200 { "changesRequestedAt": "<timestamptz>" }`. El texto se limpia como lo acepta la base (`cleanChangesText`): los saltos de línea que llegan pegados de otros programas (`\r\n`, `\r`, la tabulación vertical y el salto de página de Word y PowerPoint, NEL, U+2028 y U+2029) pasan a `\n`, las tabulaciones a espacios, los demás caracteres de control (no se ven) se sacan y se recorta. Después tiene que tener de 1 a 1000 caracteres contados como Postgres (code points); si no, `400 invalidText` sin llamar a la base (`changesTextProblem` dice si está vacío o es largo, y la página lo dice así). Un pedido nuevo reemplaza al anterior y vuelve a avisar. Con el presupuesto abierto se piden cambios como con cualquier menú (valen para el presupuesto: esa versión ya no se acepta y Evelyn manda otra). Errores: `linkNotFound`, `sendNotFound`, `menuOutdated`, `sessionCancelled`, `alreadyConfirmed`, `invalidText`, `quoteClosed`.
- Solo se contesta el último envío de una semana: si Evelyn mandó otro, `409 menuOutdated` y la página muestra el nuevo. Una semana cancelada después del envío ya no se contesta: `409 sessionCancelled`.

### `POST /accept` y `POST /decline`: el presupuesto

- `/accept`, cuerpo `{ "token", "sendId" }` (el envío que lleva el presupuesto: `quote.sendId`) → `client_link_accept_quote`. `200 { "acceptedAt": "<timestamptz>", "already": false }`. La base acepta solo la última versión y con los términos que vio la clienta: sus semanas pasan a `confirmed`, el pedido a `accepted`, la ficha de prospecto a `trial`, el presupuesto guarda lo aceptado y el menú de ese envío queda confirmado a la misma hora. Idempotente: si ya lo había aceptado, la misma hora y `already: true`, sin aviso nuevo. Errores: `linkNotFound`, `sendNotFound`, `menuOutdated` (hay una versión más nueva), `sessionCancelled`, `notAQuote`, `quoteClosed` (con `reason`), `changesRequested` (pidió cambios a esa versión), `quoteChanged` (Evelyn lo cambió y no lo reenvió), `quoteEmpty`.
- `/decline`, cuerpo `{ "token", "sendId" }` → `client_link_decline_quote`. `200 { "already": false }`. Sus semanas `held` se cancelan (`declined`) y el pedido pasa a `declined`; se puede rechazar aunque haya pedido cambios antes, pero solo la última versión. Idempotente (`already: true`). Errores: `linkNotFound`, `sendNotFound`, `menuOutdated`, `sessionCancelled`, `notAQuote`, `quoteClosed` (con `reason`).
- El cuerpo, como el de `/confirm` (`400 invalidPayload` sin `sendId` uuid); el límite, el de las respuestas (§3).
- Nada de pagos: aceptar el presupuesto no pide ni guarda datos de pago, y se paga como hoy (SPEC §5.8).

## 6. Avisos a Evelyn

- Después de cada respuesta (salvo una confirmación repetida), en segundo plano (`EdgeRuntime.waitUntil`): un email que falla nunca cambia la respuesta de la clienta; queda en el log (`email_failed`).
- A `CHEF_NOTIFY_EMAIL`, en `CHEF_LOCALE`, con el diseño de los otros emails: «Anna confirmó el menú de la semana 1» / «Anna pidió cambios en el menú de la semana 1», la semana «k de N», la fecha larga y la hora de llegada, y el botón al pedido en la bandeja (`INBOX_URL#/richieste/<id>`). El nombre es el con que llegó el pedido (o, si no tiene, el de la ficha), el mismo del mensaje y de la bandeja: en el asunto solo el de pila si parece un nombre; en el cuerpo, entero y escapado.
- **El mensaje de la clienta no va en el email**: es una nota libre, y las notas libres nunca salen por email ni push (SPEC §6), aunque el aviso vaya a la dirección de Evelyn. El email le dice que lo lea en la app, en el pedido (`menu_sends.changes_text`, que la cocina lee con su RLS).
- Clave de idempotencia de Resend: `menu-confirmed-<sendId>` y `menu-changes-<sendId>-<hora en ms>`. Con `EMAIL_TRANSPORT=log` no sale nada (solo los tamaños en el log). Sin `CHEF_NOTIFY_EMAIL`, o sin `RESEND_API_KEY` y `MAIL_FROM`, se saltea (`email_skipped`). Si la base devolviera una semana sin «semana k» (la de hoy no deja contestar una cancelada), tampoco se avisa.
- El presupuesto, la primera vez que lo acepta o lo rechaza (no en un `already`): «Anna aceptó el presupuesto: 4 semanas, 560,00 €», con la primera semana (fecha larga y llegada) y que las semanas y el menú de la semana 1 quedaron confirmados; o «Anna rechazó el presupuesto», con la primera semana propuesta y que las semanas quedaron libres (ahí ya no hay «semana k»: se avisa igual). Sin texto libre (ninguna de las dos lleva un mensaje) y nada de pagos. Clave: `quote-accepted-<quoteId>` y `quote-declined-<quoteId>` (son definitivas).

## 7. Configuración

Los secretos que ya comparten las funciones (los carga «Secretos de la función» de `deploy-supabase.yml`; local: `supabase/functions/.env`, ver `.env.example`):

- Obligatorias (sin ellas, `500`): `IP_HASH_SALT`, y `SUPABASE_URL` y la clave secreta que pone Supabase. De `SUPABASE_URL` sale el origen de las fotos de los platos (con `supabase functions serve` es la dirección interna de Docker: los platos salen sin foto).
- Para los avisos: `CHEF_NOTIFY_EMAIL`, `CHEF_LOCALE` (es por defecto), `MAIL_FROM`, `RESEND_API_KEY` (o `EMAIL_TRANSPORT=log`) e `INBOX_URL`. Para la web: `ALLOWED_ORIGINS`. Las que faltan se avisan al arrancar (`config_incomplete`, solo los nombres).

## 8. Despliegue

- `deploy-supabase.yml`, paso «Desplegar client-link», después de las migraciones (llama a las `client_link_*`) y de los secretos: `supabase functions deploy client-link --project-ref … --use-api`. `verify_jwt = false` sale de `config.toml`.
- CI: `deno check` de `supabase/functions/client-link/index.ts` (job `edge-functions`) y los tests de Node (`npm test`).
- La página sale con la web (`deploy-web.yml`): necesita `VITE_SUPABASE_URL`, como el formulario.

## 9. Logs y datos

- Solo el evento, la ruta, códigos e ids (del pedido, del envío y del presupuesto): `link_viewed` (con la cantidad de semanas y de menús), `menu_confirmed`, `changes_requested`, `quote_accepted` y `quote_declined` (con `quoteId` y `already`), `link_not_found`, `rejected` (con `reason` en un `quoteClosed`), `invalid_payload`, `rate_limited`, `snapshot_unreadable`, `email_*`, `db_error` (operación y SQLSTATE, nunca el mensaje de Postgres).
- Nunca el token ni su hash, nombres, el mensaje de la clienta, los platos, la nota, importes, direcciones de email ni la IP.
- Lo que se guarda: la huella de la IP de cada visita y de cada respuesta, para el límite (`private.public_request_hits`: el HMAC de la IP, que se borra a los 2 días como máximo, como el del formulario), y la respuesta de la clienta (la confirmación o el mensaje de cambios, con su hora, en `menu_sends`; la aceptación o el rechazo del presupuesto, en `quotes`), que guardan las funciones SQL y se conserva como la reserva. La privacy lo cuenta desde su versión `2026-11-22` y, con el presupuesto (que la página muestra, con su precio), desde la `2026-11-23` (SPEC §6).

## 10. La página `/prenotazione/`

- Italiano por defecto en el HTML; textos en `web/src/i18n/{it,es,en}.json` (`reservation.*`). Idioma: el que eligió la visitante (`?lang=` o el guardado) o, si nunca eligió, el de la reserva (`locale` de `/view`; `initShell({ defaultLang })`).
- El token no se pierde de la URL: los links de idioma del encabezado salen del build sin `href` (un `?lang=xx` descartaría el fragmento) y el shell les pone `?lang=xx#t=…`; si un ancla interna cambia el fragmento (el «Vai al contenuto» lleva a `#main`), la página vuelve a poner `#t=…` sin navegar (`hashChangeAction`, `history.replaceState`), y otro link pegado en la misma pestaña recarga.
- Arriba, el saludo con el nombre de pila (o sin nombre) y, si una semana se canceló mientras la clienta contestaba, un aviso con su fecha (la semana ya no está en la lista). Después, si hay, el presupuesto (abajo). Después cada semana: «Settimana k di N», la fecha y la hora de llegada y, si Evelyn mandó el menú, su estado (por confirmar, con el día del envío; confirmado, con el día; cambios pedidos, «Evelyn te lo vuelve a mandar»; las fechas llevan el día de la semana: en italiano, sin artículo), los platos (miniatura si tiene, nombre, descripción, porciones, dieta y alérgenos con su nombre), la lista de compras por sección (1250 g → «1,25 kg» en it y es, «1.25 kg» en en; ml → l; piezas con su palabra) con lo «q.b.» aparte («Da avere in casa») y la nota de Evelyn (con sus saltos de línea, como texto). Sin menú: «te lo manda Evelyn».
- Una semana ya cocinada no promete nada: sin menú, solo «ya cocinó»; con el menú sin contestar, «Enviado» neutro (sin «por confirmar» ni botones); con cambios pedidos, sin el «te lo vuelve a mandar»; con un envío que no se puede mostrar, sin «te lo reenvía».
- Por confirmar (y antes de cocinar): «Confermo il menù» y «Chiedo dei cambi» (un campo de hasta 1000 caracteres con contador, que pide no escribir datos de salud; el error dice si está vacío, si es largo o si no se pudo recibir). Después de responder, la semana muestra el resultado (el foco va a su estado) y la página vuelve a leer la reserva; las lecturas van numeradas y una que llega tarde no pisa una más nueva. El estado de cada semana (el formulario, el mensaje a medio escribir, el aviso) va por su sesión: si se cancela una semana anterior, nada cae en otra. `menuOutdated`, o un menú nuevo que llega mientras escribe, muestra el menú nuevo con un aviso, sin perder el mensaje. Sin conexión, error o demasiados intentos: el error junto al botón, anunciado en una región en vivo. «Riprova» no pasa por «cargando»: el botón espera con el foco y, al volver, el foco va al saludo o al recuadro del error. Link no válido o vencido: «escribe a Evelyn y te manda uno nuevo».
- El presupuesto (`web/src/reservation/controller.ts`, `quoteView`), en un recuadro arriba de las semanas, con «Il tuo preventivo» (y «Versione N» desde la 2): las semanas de lo que vio (`quote.summary`) con su fecha, su llegada y, si son varias, su precio, y el total del servicio («Totale del servizio»; con una sola semana, «Prezzo del servizio»), con `formatCents` en el idioma de la página. El estado: por aceptar, hasta cuándo (el plazo, `holdUntil`, en Roma: «Puoi accettarlo fino a sabato 27 febbraio 2027 alle 19:03», y que esas fechas quedan reservadas); con cambios pedidos a esa versión, «Evelyn ti manderà il preventivo aggiornato»; cambiado, Evelyn prepara una versión nueva (sin precios ni botones); aceptado, con el día; rechazado, retirado o vencido, sin precios ni botones y «scrivi a Evelyn». Por aceptar: «Accetto il preventivo» (que confirma también el menú de la semana 1, lo dice debajo) y «Rifiuto», que pide confirmar («Vuoi rifiutare il preventivo? …», con «Sì, rifiuto il preventivo» y «No, torna indietro»; el foco va a la pregunta, no al botón); con cambios pedidos, solo «Rifiuto». Los cambios se piden en el menú de la semana 1, con «Chiedo dei cambi». Solo se contesta lo que se ve: sin el menú que lo lleva a la vista o sin `summary`, el presupuesto dice que no se puede mostrar, sin botones.
- El menú que va con el presupuesto abierto (`menu.quoteId`) no ofrece «Confermo il menù»: «Con il preventivo: lo confermi quando accetti il preventivo, qui sopra», con «Chiedo dei cambi»; uno que iba con un presupuesto cerrado, sin botones. Después de aceptar o rechazar, el recuadro muestra el resultado (el foco va a su estado) y la página vuelve a leer la reserva; si llega otra versión con la confirmación del rechazo abierta, se cierra y se le avisa. Cada respuesta de la función (versión más nueva, cambios pedidos, cambiado, cerrado con su motivo, sin semanas, no disponible) tiene su aviso; sin conexión, error o demasiados intentos, el error junto al botón, anunciado en la región en vivo. La presentación de arriba, con el presupuesto abierto, habla de él.
- Todo texto que llega de la función se pinta como texto (`web/src/lib/vdom.ts`: nunca `innerHTML`). Sin pagos, dirección ni alergias de la clienta: la página muestra solo la foto del envío y, del precio, el del servicio del presupuesto (solo en su recuadro).
- Nunca se indexa (`<meta name="robots" content="noindex, nofollow">` y `X-Robots-Tag`), sin canonical; conserva la imagen para la vista previa del link en WhatsApp. CSP propia en `public/_headers`: la de `/*` más el origen de Supabase en `connect-src` (la función) e `img-src` (las fotos). Nada de terceros.

## 11. Pruebas

- `npm test` (raíz): `client_link.test.ts`, `client_link_emails.test.ts` y `client-link/handler.test.ts` (rutas, errores, límite por IP, CORS, avisos por idioma, que un email que falla no rompa la respuesta y que los logs no lleven datos; con el presupuesto: `/view` con cada estado y el resumen de la foto, `/accept` y `/decline` con cada error de la base y su motivo, `quotePending` y `quoteClosed` en `/confirm` y `/changes`, los avisos a Evelyn y que los logs no lleven importes), y `quote_snapshot.test.ts`.
- `cd web && npm test`: `src/reservation/*.test.ts` (fragmento y qué hacer si cambia, llamadas con un fetch simulado, formatos, estados y acciones, lecturas en orden, semanas por su sesión, lo que se pinta en cada idioma y el escapado; el presupuesto: aceptar, rechazar con su confirmación, cada respuesta de la función, la semana 1 sin «Confermo», los estados y los importes por idioma), `src/lib/vdom.test.ts`, el build sin links de idioma navegables en la página (`src/build/html.test.ts`) y la privacy en los tres idiomas (`src/i18n/i18n.test.ts`, también la `2026-11-23` y que ningún texto de la página hable de pagos).
