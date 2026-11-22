# Contrato: área de Evelyn, Edge Function `chef`

Estado: implementado el 16/11/2026 (plan del área de Evelyn, PR 4), sobre la base de reservas del PR 3 (migraciones `20261116150000_pay_mode_manual.sql` y `20261116150100_bookings.sql`, pgTAP `13_bookings`). Desde el mismo día la llaman también los colaboradores de la cocinera (migración `20261116190000_chef_members.sql`, pgTAP `15_chef_members`; §2). Con el PR 8 del plan (18/11/2026), la app manda también `clientId` («Nuova prenotazione» con una ficha existente y «Rinnova», la renovación de una reserva para la misma ficha) y `newClient` («Nuova cliente»): ver «Uso desde la app» en §4.
Código del contrato: `supabase/functions/_shared/chef_api.ts` (tipos de los cuerpos y de las respuestas, y la validación; tests en `chef_api.test.ts`). La función: `supabase/functions/chef/` (`handler.ts`, con sus tests en `handler.test.ts`, `index.ts`; para la traducción, `translation.ts` con `translation.test.ts` y `claude_translator.ts`; para el envío del menú, `menu_send.ts` y `menu_translation.ts`, con sus tests, y en `_shared/` la foto del envío, `menu_snapshot.ts`, y el mensaje, `menu_message.ts`; para el presupuesto, `quotes.ts`, con sus tests, y en `_shared/` el presupuesto de la foto, `quote_snapshot.ts`). Si este documento y el código difieren, manda el código.
Actualizado el 19/11/2026: Evelyn no hace la compra (la hace el cliente, con la lista de ingredientes y cantidades que ella le manda). `POST /bookings` ya no tiene `groceriesEstCents`: si llega (la app de antes lo manda), se ignora como cualquier otra clave que el contrato no tiene, valga lo que valga, y la función le pasa siempre `p_groceries_est_cents: 0` a `chef_create_booking`, cuya firma no cambia (§4, §7). Sin compra, `chef_settings.shop_minutes` es 0 (migración `20261119090000_sin_compra.sql`): la llegada sugerida de un día de 9:00 a 15:00 es las 9:00.
Actualizado el 20/11/2026: `POST /translate` traduce un plato del español al italiano y al inglés con Claude (§12), sobre la migración `20261120090000_recipe_translations.sql` (`recipes.auto_translated`, pgTAP `18_recipe_translations`).
Actualizado el 21/11/2026: `POST /menus/preview` y `POST /menus/send` mandan a la clienta el menú de una semana por email, por WhatsApp o por los dos, con un link para confirmarlo (§13; SPEC §5.8), sobre la migración `20261121100000_menu_sends.sql` (pgTAP `20_menu_sends`).
Actualizado el 22/11/2026: el presupuesto (§14; SPEC §5.8, «Presupuesto»): `POST /quotes` lo prepara desde un pedido, `POST /quotes/price` le cambia el precio y `POST /quotes/withdraw` lo retira, sobre la migración `20261121120000_quotes.sql` (pgTAP `22_quotes`). Sale con el menú de la semana 1: la foto y el mensaje de ese envío lo llevan (§13), y la clienta lo acepta o lo rechaza en su link (contrato `client-link.md`). Con la revisión del mismo día: confirmar sin presupuesto desde el pedido (`/bookings`) retira el presupuesto abierto, también uno que ya salió (§4); la versión cuenta solo los presupuestos que le llegaron a la clienta (§14), y con una sola semana el mensaje habla de esa fecha (§13).

## 1. Para qué

- Es la única puerta de la app de Evelyn para crear, mover y cancelar sesiones: los estados de sesión solo cambian vía Edge Functions, nunca desde la app (CLAUDE.md). La app no tiene privilegios sobre esas filas, ni puede borrar pedidos o fichas (borrar una ficha se llevaba en cascada su reserva); la función llama a las funciones SQL `chef_*`, que solo ejecuta `service_role`.
- Una reserva es un pedido aceptado más sus sesiones: una sesión `confirmed` por semana, de 1 a 8 semanas, con `pay_mode = 'manual'` (SPEC §4 y §5.3). Hasta M4 nace sin presupuesto ni retención de 48 h.
- Rutas (todas `POST https://<ref>.supabase.co/functions/v1/chef/<ruta>`):

| Ruta | Función SQL | Qué hace |
|---|---|---|
| `/bookings` | `chef_create_booking` | confirmar una reserva, desde un pedido o a mano (§4) |
| `/sessions/move` | `chef_move_session` | mover una semana (§5) |
| `/sessions/cancel` | `chef_cancel_sessions` | cancelar una o varias semanas (§6) |
| `/translate` | ninguna (`hit_public_request_rate` para el límite) | traducir el nombre y la descripción de un plato al italiano y al inglés (§12) |
| `/menus/preview` | `chef_menu_send_context`, `chef_prepare_menu_send` | la vista previa del menú de una semana para la clienta, en su idioma, y el envío guardado sin salir (§13); en la semana 1 de un presupuesto abierto, con el presupuesto |
| `/menus/send` | `chef_link_menu_send`, `chef_complete_menu_send` | mandarlo: el link de la clienta, el email y el texto del WhatsApp (§13); con el presupuesto, el presupuesto sale con él |
| `/quotes` | `chef_create_quote` | preparar el presupuesto de un pedido: una semana retenida (`held`) por fecha y el presupuesto sin enviar (§14) |
| `/quotes/price` | `chef_update_quote` | otro precio para un presupuesto abierto (§14) |
| `/quotes/withdraw` | `chef_withdraw_quote` | retirar un presupuesto abierto: sus semanas se cancelan y el pedido vuelve a `new` (§14) |

  Con el plan crecen: `/sessions/cooked`, `/sessions/uncook`, `/payments`, `/payments/void` y `/payments/refund` (PR 10a, «Cociné» y cobros). Las de los tickets (`/sessions/receipts` y `/receipts/remove`, PR 9a) salieron el 19/11/2026: sin compra no hay tickets.

## 2. Autenticación y CORS

- `verify_jwt = true` (`[functions.chef]` en `supabase/config.toml`): la plataforma rechaza con `401` un pedido sin `Authorization` o con un JWT que no valida (antes de llegar a la función, con su propio cuerpo). Ese chequeo acepta los JWT firmados con las claves asimétricas nuevas y los HS256 viejos, pero también deja pasar las claves de API (`sb_publishable_…`, `sb_secret_…`) y un JWT sin usuario (la clave `anon` vieja). Por eso la función, además:
  1. toma el token de `Authorization: Bearer <token>` y exige que sea un JWT (tres partes base64url, hasta 8 KB). Una clave de API da `401` sin llamar a Auth;
  2. lo valida con Auth (`auth.getUser`): firma, vencimiento y que la sesión siga abierta. Si Auth lo rechaza (4xx), `401`; si no responde (429, 5xx o red), `503`;
  3. busca la cocina del usuario con `public.chef_id_for_user` (migración `20261116190000_chef_members.sql`, solo `service_role`): la de la que es dueña (`chefs.profile_id`) o colaborador (`chef_members`). Es la misma regla de la RLS (`current_chef_id()` la usa con `auth.uid()`). Si no es de ninguna, `403`; una respuesta con otra forma (ni un uuid ni null), `500` y `unexpected_result`.
- Quién llama: la cocinera o un colaborador suyo (SPEC §1 y §6), cada uno con su sesión. Un colaborador hace lo mismo que ella con la cocina de ella: las funciones SQL reciben el mismo `chef_id`. Cuando el despliegue que aplica la lista lo saca (`CHEF_MEMBER_EMAILS`, contrato public-request §10.1: cambiar el secreto no hace nada hasta correr Deploy Supabase), pierde el acceso en el acto: su cuenta se borra y Auth rechaza su token (`401`), y si la cuenta queda (la de una ficha de cliente, o una que no se pudo borrar), `chef_id_for_user` ya no le da cocina (`403`).
- Las funciones SQL reciben siempre el `chef_id` que sale del token, nunca uno del cuerpo.
- La app llama con `functions.invoke('chef/bookings', body: …)` (supabase-js o supabase_flutter), que manda `Authorization: Bearer <access token de la sesión>` y `apikey: <clave publicable>`. Para que la función corra en Frankfurt, como la web (contrato public-request §2), va `?forceFunctionRegion=eu-central-1` en la URL; la cabecera `x-region` no, porque CORS no la permite.
- CORS: `ALLOWED_ORIGINS`, **la misma variable que `public-request`** (contrato public-request §4). El preflight permite `POST, OPTIONS` y las cabeceras de supabase-js (`authorization`, `x-client-info`, `apikey`, `content-type`, …). Un origen que no está en la lista no recibe cabeceras CORS: el navegador no deja pasar la llamada. La app nativa no manda `Origin` y no la afecta.
- **Cualquier origen de `ALLOWED_ORIGINS` puede llamar a esta función con la sesión de Evelyn** (o de un colaborador suyo), si entró a `/gestione/` desde ese origen. La lista tiene que tener solo `https://radicicucina.app`. Antes del primer despliegue de `chef` hay que sacar `https://radici.sepusola10.com` (Paso 0.3 del plan): redirigir o sacar de Pages el dominio viejo, dejar la variable solo con el dominio nuevo, volver a correr Deploy Supabase y sacar el hostname viejo del widget de Turnstile. El despliegue avisa si `ALLOWED_ORIGINS` tiene orígenes además del de `PUBLIC_SITE_URL` (§9).

## 3. Formato común

- `POST` con `Content-Type: application/json` y un cuerpo de hasta 8 KB (`CHEF_MAX_PAYLOAD_BYTES`).
- Orden de los chequeos: CORS → ruta (`404`) → método (`405`) → configuración (`500`) → token (`401`) → usuario (`401` o `503`) → su cocina (`403`) → tipo (`415`) → tamaño (`413`) → JSON y validación (`400`) → función SQL (en `/translate`, el traductor: §12; en `/menus/*`, el orden de §13). Sin un token válido de la cocinera o de un colaborador suyo no se lee ni el cuerpo.
- Fechas `"AAAA-MM-DD"` (fechas de negocio en Roma) y horas `"HH:MM"` (hora de Roma). Dinero en centavos enteros: `14050` es 140,50 €; un número con decimales es `invalid`.
- Respuestas en JSON con `Cache-Control: no-store`.

| Código | Cuerpo | Cuándo |
|---|---|---|
| 200 / 201 | según la ruta | §4, §5, §6, §12, §13 y §14 |
| 400 | `{ "errors": { campo: código } }`, más `"date"` cuando el error es de una fecha concreta (de `dates`: fuera de rango, misma semana u orden) | validación de la función o, como defensa, de la base (§7) |
| 401 | `{ "error": "unauthorized" }` y `WWW-Authenticate: Bearer` | sin token, token que no es un JWT o que Auth rechaza (vencido, sesión cerrada). Sin `Authorization`, o con un JWT que no valida, responde la plataforma con su propio cuerpo |
| 403 | `{ "error": "forbidden" }` | usuario válido que no es la cocinera ni un colaborador suyo |
| 404 | `{ "error": "notFound" }` | ruta desconocida |
| 404 | `{ "error": "requestNotFound" \| "clientNotFound" \| "sessionNotFound" \| "menuNotFound" \| "sendNotFound" \| "quoteNotFound" }` | el pedido, la ficha, la sesión, el menú de la semana, el envío o el presupuesto no existen para esta cocinera |
| 405 | `{ "error": "method" }` y `Allow: POST, OPTIONS` | otro método |
| 409 | ver abajo | choques y estados que no lo permiten; no se escribió nada |
| 413 / 415 | `{ "error": "tooLarge" \| "contentType" }` | cuerpo de más de 8 KB o que no es JSON |
| 422 | `{ "error": "untranslatable" }` | solo `/translate` y `/menus/preview`: el texto no se pudo traducir (una negativa, un corte o una salida que no sirve; §12, §13). Reintentar igual no sirve |
| 429 | `{ "error": "rateLimited" }` y `Retry-After: 3600` | solo `/translate` y `/menus/preview`: la cocina pasó su límite de traducciones (§12). La app no reintenta sola |
| 500 | `{ "error": "server" }` | configuración rota o error inesperado (el log lleva el código, §10). En `/menus/send` puede llevar `"emailSent": true` (§13) |
| 501 | `{ "error": "notConfigured" }` | solo `/translate` y `/menus/preview`: la traducción está apagada (sin `ANTHROPIC_API_KEY`; §12) |
| 502 | `{ "error": "emailFailed" }` | solo `/menus/send`: el email no salió (Resend lo rechazó o no respondió); el envío queda sin marcar (§13) |
| 503 | `{ "error": "unavailable" }` | Auth o la base no responden, o un error que se puede reintentar: reintentar con la misma `requestKey`. En `/translate` y `/menus/preview`, Claude no respondió a tiempo o dio un error que se puede reintentar (§12) |
| 503 | `{ "error": "emailUnavailable" }` | solo `/menus/send` con `email: true`: el email no está configurado (sin `RESEND_API_KEY` o sin `MAIL_FROM`); por WhatsApp sale igual (§13) |

Los 409:

| Cuerpo | Cuándo |
|---|---|
| `{ "error": "slotTaken", "date": "AAAA-MM-DD" }` | la semana de esa fecha choca con otra sesión (`no_overlap`). En una reserva no se crea ninguna semana |
| `{ "error": "weekTaken", "date": "AAAA-MM-DD" }` | esa semana ya tiene otra sesión viva de la misma reserva (una por semana). Al mover, la app ofrece pasarla al final de la reserva |
| `{ "error": "requestNotNew", "status": "accepted" }` | el pedido ya no está `new` y no es un reintento; `status` es su estado actual. En `/bookings` se confirma también uno `quoted` con su presupuesto abierto (§4) |
| `{ "error": "sessionNotMovable", "status": "cooked" }` | solo se mueve una sesión `held` o `confirmed`; `status` es el actual |
| `{ "error": "invalidTransition", "sessionId": uuid }` | al cancelar, esa sesión está `cooked` o `paid`; no se cancela ninguna |
| `{ "error": "hasPayments", "sessionIds": [uuid] }` | al cancelar sin `allowWithPayments`, esas semanas ya están cobradas; no se cancela ninguna (§6) |
| `{ "error": "sessionNotEditable", "status": "cancelled" }` | el menú de esa semana ya no se manda: la sesión no está `held`, `confirmed` ni `shopping_done`; `status` es el actual (§13) |
| `{ "error": "sessionWithoutRequest" }` | la sesión no tiene pedido: no hay reserva que mostrar en el link (§13) |
| `{ "error": "menuChanged" }` | el menú se guardó otra vez (Evelyn o un colaborador) desde que la app lo cargó o, desde la vista previa, cambió el menú, el día o la hora, las semanas de la reserva o un plato del catálogo: hay que pedir otra vista previa (§13) |
| `{ "error": "menuEmpty" }` | el menú de la semana no tiene platos (§13) |
| `{ "error": "alreadySent" }` | ese envío ya salió: para mandar otra vez, otra vista previa (§13) |
| `{ "error": "noEmail" }` \| `{ "error": "noPhone" }` | el contacto de la clienta no tiene un email o un teléfono que sirva para lo que se pidió; no salió nada (§13) |
| `{ "error": "requestNotQuotable" }` | el pedido no admite presupuesto (uno de cambios): el cuerpo de `/quotes` no tiene `type`, es el del pedido (§14) |
| `{ "error": "quoteExists" }` | el pedido ya tiene un presupuesto abierto: para preparar otro, primero se retira (§14) |
| `{ "error": "quoteClosed" }` | el presupuesto ya está aceptado, rechazado, retirado o vencido; en `/menus/*`, la semana `held` ya no tiene su presupuesto abierto (§13, §14) |
| `{ "error": "quoteEmpty" }` | el presupuesto no tiene semanas vivas (Evelyn las canceló todas) (§14) |
| `{ "error": "quoteWeekNotFirst" }` | el menú de una semana `held` que no es la primera de su presupuesto: antes de aceptarlo solo sale la semana 1 (§13) |
| `{ "error": "quoteChanged" }` | desde la vista previa cambiaron los términos del presupuesto (otro precio, una semana movida o cancelada): hace falta otra vista previa (§13) |
| `{ "error": "conflict" }` | otro choque (no debería pasar; en `/menus/send`, dos tokens repetidos seguidos) |

Códigos de los 400 (`ChefApiErrorCode`): `required`, `invalid` (tipo o formato; un número que no es entero), `range`, `tooLong`, `dateOutOfRange`, `sameWeek`, `order`, `weeksOnlyForWeek` y `conflict`. Los campos de un objeto van con punto (`newClient.name`, `household.meals`); `client`, `people`, `cents` y `channels` (§13) agrupan varios. `payload` es el cuerpo entero (no es JSON, no es un objeto o, en `/translate` y `/menus/*`, trae una clave de más).

## 4. `POST /bookings`: confirmar una reserva

### Cuerpo

| Campo | Tipo | Regla |
|---|---|---|
| `requestId` \| `clientId` \| `newClient` | uuid \| uuid \| objeto | la clienta, **una sola** de las tres (si no, `client: "required"` o `"invalid"`): el pedido de la bandeja, una ficha existente o una nueva |
| `newClient` | `{ name, phone?, email?, zone?, address? }` | ficha nueva de una reserva a mano. `name` obligatorio (hasta 80); `phone` se guarda en E.164 (`+393331234567`, mismas reglas que el formulario); `email` válido (hasta 120); `zone` hasta 80; `address` hasta 200. Sin restricciones ni alergias: falta su consentimiento de salud (M2) |
| `type` | `"week"` \| `"extra"` | a mano, obligatorio. Desde un pedido vale el del pedido; si viene, tiene que coincidir |
| `household` | `{ adults, kids, days, meals }` | solo a mano, obligatorio: adultos y niños de 0 a 30 (al menos 1 persona, `people`), días de 1 a 7 y comidas `["lunch"]`, `["dinner"]` o las dos. Desde un pedido se ignora |
| `locale` | `"it"` \| `"es"` \| `"en"` | solo a mano: idioma de la clienta (por defecto `it`) |
| `dates` | `string[]` | de 1 a 8 fechas (`range`), una por semana ISO (`sameWeek`) y en orden (`order`), de hoy − 366 a hoy + 366 en Roma (`dateOutOfRange`; las pasadas sirven para cargar lo ya hecho en Fase 0). Más de una solo en un pedido `week` (`weeksOnlyForWeek`) |
| `start` | `"HH:MM"` | llegada de todas las semanas. Puede faltar solo en el `dryRun`: cada fecha se evalúa con su llegada sugerida |
| `cookMinutes` | entero de 1 a 720 | minutos de cocina de cada semana. La compra y el margen los copia la base de `chef_settings` |
| `portions` | entero de 0 a 840 | porciones de cada semana (0 por defecto) |
| `serviceTotalCents` | entero de 0 a 10 000 000 | precio del servicio de **toda** la reserva, que fija Evelyn. **Obligatorio** salvo en el `dryRun` (`required`): ninguna ruta lo cambia después. `0` vale (sin cargo); en un `dryRun` sin precio las semanas salen con 0. Se reparte en centavos entre las semanas: los que sobran van a las primeras (500 € en 3 son 166,67 + 166,67 + 166,66) |
| `requestKey` | uuid | idempotencia. Obligatoria a mano salvo en el `dryRun`; desde un pedido es opcional (ver abajo) |
| `dryRun` | boolean | `true`: solo devuelve el estado de cada fecha, sin escribir nada |

Las claves que el contrato no tiene se ignoran. Entre ellas `groceriesEstCents`, la compra estimada, que existió hasta el 19/11/2026: la compra la hace el cliente, y si la app de antes la manda no da error con ningún valor.

### Respuesta

`200` en el `dryRun`; `201` al crear, y también en un reintento, con `"duplicate": true`.

```json
{
  "dryRun": false,
  "duplicate": false,
  "requestId": "uuid",
  "clientId": "uuid",
  "weeks": [
    { "date": "2026-11-25", "start": "10:00", "cookMinutes": 240, "status": "ok",
      "suggestedStart": "09:00", "serviceCents": 14000, "sessionId": "uuid" }
  ]
}
```

- `weeks`: las semanas vivas de la reserva en orden de fecha (en el `dryRun`, las pedidas, con `sessionId: null`).
- `requestId` es null en el `dryRun` de una reserva a mano; `clientId`, en el `dryRun` de una ficha nueva. `start` es null solo en un `dryRun` sin hora para un día sin horario.
- `suggestedStart`: la primera llegada del día, la misma que ofrece el calendario de la web (apertura + compra, redondeada a la media hora siguiente); null si ese día no tiene horario. Sin compra (0 minutos desde el 19/11/2026) es la apertura: las 9:00 en el horario de Evelyn.
- `status` de cada fecha, en orden de prioridad. Solo `busy` impide crear; los demás son avisos para la hoja «Confirmar reserva»:

| `status` | Qué significa |
|---|---|
| `busy` | choca con otra sesión: la misma cuenta que `no_overlap`. Desde un pedido con un presupuesto abierto, las semanas retenidas de ese presupuesto no cuentan: se retira al confirmar |
| `past` | la fecha ya pasó (hoy no cuenta como pasado) |
| `blocked` | día bloqueado (puede ser justo el que Evelyn bloqueó por la sesión acordada) |
| `closed` | ese día de la semana no tiene horario |
| `outside` | la llegada (menos los minutos de compra de `chef_settings`: 0 desde el 19/11/2026) es antes de la apertura, o la cocina termina después del cierre |
| `ok` | todo bien |

### Reglas

- **Desde un pedido** (`requestId`): el pedido tiene que estar `new`, o `quoted` con su presupuesto abierto (si no, `409 requestNotNew`, también en el `dryRun`). Pasa a `accepted`, con `weeks` = las semanas creadas y `seen_at`; la ficha, de `prospect` a `trial`.
- **Con un presupuesto abierto** (un borrador, o uno que ya le llegó a la clienta: SPEC §5.8, «Presupuesto»): confirmar sin presupuesto lo retira antes de crear las semanas, en la misma transacción. Sus semanas retenidas se cancelan (`quote_withdrawn`) y no chocan con las nuevas, aunque sean las mismas fechas y hora; en el `dryRun` tampoco cuentan como `busy`. Si una semana choca con otra reserva, no se retira nada. No hace falta retirarlo antes (`chef_withdraw_quote`). Si ya le había llegado, el link de la clienta deja de mostrarlo (`quote` es `null`, contrato client-link §4); si justo lo acepta o lo rechaza, su respuesta no se registra y la página le dice que Evelyn confirmó la reserva (client-link §10).
- **A mano** (`clientId` o `newClient`): crea el pedido (`source = 'app'`, `accepted`) y, si es nueva, la ficha (`trial`, `pay_mode manual`). Una ficha existente no se modifica, salvo el paso de `prospect` a `trial`.
- **Todo o nada**: si una semana choca no se crea ninguna, tampoco el pedido ni la ficha (`409` con la fecha).
- **Idempotencia**: la app genera una `requestKey` por hoja «Confirmar reserva» (al abrirla) y la repite en cada envío de esa hoja (botón deshabilitado mientras envía); otra hoja, otra clave (ver «Uso desde la app»). A mano, la misma clave devuelve la reserva guardada con `duplicate: true` sin crear nada; es única por cocinera y compartida con las de la web (una clave ya usada por un pedido de la web da `400 requestKey: "conflict"`). Desde un pedido, el reintento se reconoce por el estado: el pedido ya `accepted` con esas mismas fechas y hora devuelve lo mismo con `duplicate: true`.
- **`dryRun`**: valida todo igual (también el estado del pedido) y no escribe nada.

### Uso desde la app

- A mano, `type` es siempre `"week"` y van siempre `household` y `locale` (el idioma de los WhatsApp de la clienta).
- `newClient` va completo también en el `dryRun`: el primer chequeo ya dice si algún dato no pasa (un `400` con campos `newClient.*`, que la app manda a corregir en el formulario).
- «Rinnova» es una reserva a mano con el `clientId` de la reserva que se renueva: las fechas desde su última sesión viva + 7 días; `start`, `cookMinutes` y `portions` de esa sesión (sin `groceriesEstCents`: la compra la hace el cliente); `household` y `locale` de su pedido; y `serviceTotalCents`, la suma del servicio de todas sus sesiones, también las canceladas. Como la hora ya está elegida, el primer `dryRun` lleva `start`. El servidor no distingue una renovación de otra reserva a mano.
- Una `requestKey` por hoja: se genera al abrirla y se repite en cada envío de esa hoja. Los 4xx no guardan nada; después de una respuesta perdida, el reintento manda lo mismo. Otra hoja, otra clave. A mano (también «Rinnova»), mientras envía y mientras espera ese reintento la hoja no se cierra, tampoco con el atrás del navegador en `/gestione/`: otra hoja usaría otra clave y podría duplicar la reserva (y, con `newClient`, la ficha). Si el reintento tampoco tiene respuesta, la app ofrece cerrarla igual, con el aviso de mirar las reservas antes de rehacerla.

## 5. `POST /sessions/move`: mover una semana

| Campo | Tipo | Regla |
|---|---|---|
| `sessionId` | uuid | obligatorio |
| `date` | `"AAAA-MM-DD"` | obligatoria, de hoy − 366 a hoy + 366 |
| `start` | `"HH:MM"` \| null | null o ausente: la hora guardada |
| `cookMinutes` | entero de 1 a 720 \| null | null o ausente: los minutos guardados |
| `dryRun` | boolean | `true`: solo el chequeo |

Respuesta `200`:

```json
{ "dryRun": false, "sessionId": "uuid", "requestId": "uuid", "date": "2026-12-03", "start": "11:00",
  "cookMinutes": 200, "status": "ok", "suggestedStart": "09:00", "weekTaken": false }
```

- Solo una sesión `held` o `confirmed` (`409 sessionNotMovable`). La compra y el margen guardados no cambian.
- `status` y `suggestedStart`, como en §4, sin contar la sesión que se mueve. `weekTaken`: esa semana ya tiene otra sesión viva de la misma reserva. En el `dryRun` los dos son avisos; al mover de verdad, `409 slotTaken` o `409 weekTaken` con la fecha.

## 6. `POST /sessions/cancel`: cancelar semanas

| Campo | Tipo | Regla |
|---|---|---|
| `sessionIds` | `uuid[]` | de 1 a 100 (se quitan los repetidos) |
| `reason` | `"chef_cancelled"` \| `"client_cancelled"` \| `"chef_unavailable"` | uno de estos códigos (`CANCEL_REASONS`), nunca texto libre: el cliente con cuenta puede leer su sesión. Por defecto `chef_cancelled`; `client_cancelled`, lo pidió la clienta; `chef_unavailable`, Evelyn no puede ir |
| `allowWithPayments` | boolean | `true`: cancela también las semanas ya cobradas, para registrar la devolución (por defecto `false`) |

Respuesta `200`:

```json
{ "cancelled": ["uuid"], "alreadyCancelled": [], "withPayments": [], "hadPayments": false }
```

- Pasa a `cancelled` las sesiones `held`, `confirmed` o `shopping_done`, con `cancelled_at` y `cancel_reason`. Una ya cancelada no falla: va en `alreadyCancelled`.
- Todo o nada: si alguna está `cooked` o `paid`, `409 invalidTransition` con esa sesión y no se cancela ninguna.
- **Semanas ya cobradas** (algún pago `succeeded` que no es una devolución; un cobro pendiente no cuenta). Una sesión cancelada no se mueve ni se reactiva, así que sin `allowWithPayments` la función responde `409 hasPayments` con esas semanas y no cancela ninguna. La app ofrece entonces (decisión 5 del plan):
  1. **Pasar la semana al final de la reserva**, con `/sessions/move` (§5); el cobro queda en esa semana.
  2. **Cancelarla y devolver el cobro**: repite la cancelación con `allowWithPayments: true` y registra la devolución (los cobros manuales y las devoluciones llegan en el PR 10).
- `withPayments`: las de la lista que tienen algún cobro, canceladas ahora (con `allowWithPayments`) o antes. Son las que esperan su devolución.
- Una semana cancelada vuelve a aparecer libre en el calendario de la web (`get_free_days` no cuenta las canceladas).

## 7. Base de datos

Las funciones son de la migración `20261116150100_bookings.sql` (SPEC §4, «Reservas»): `security definer`, `search_path = ''`, ejecutables solo por `service_role`. Ninguna escribe en el log.

- `public.chef_create_booking(p_chef_id, p_dates, p_start, p_cook_minutes, p_service_total_cents, p_portions, p_groceries_est_cents, p_request_id, p_client_id, p_new_client, p_type, p_household, p_locale, p_request_key, p_dry_run) → jsonb`. `p_service_total_cents` no tiene valor por defecto (null es `invalid_cents`). `p_groceries_est_cents` sigue en la firma, pero la Edge Function le pasa siempre 0 (sin compra desde el 19/11/2026); la columna `sessions.groceries_est_cents` queda en 0 en las reservas nuevas. La migración `20261121120000_quotes.sql` la rehace con la misma firma: desde un pedido con un presupuesto abierto, lo retira antes de crear las semanas (§4), sin errores nuevos.
- `public.chef_move_session(p_chef_id, p_session_id, p_date, p_start, p_cook_minutes, p_dry_run) → jsonb`
- `public.chef_cancel_sessions(p_chef_id, p_session_ids, p_reason, p_allow_with_payments) → jsonb`

La función pasa los argumentos en snake_case (`toCreateBookingParams`) y convierte las respuestas a camelCase, con las horas en `"HH:MM"`; una respuesta con otra forma da `500` (`unexpected_result`). Los errores de la base:

| SQLSTATE y mensaje | HTTP |
|---|---|
| `23P01 slot_taken`, `23505 week_taken` (detalle: la fecha) | `409 slotTaken` / `weekTaken` con `date` |
| `55000 request_not_new`, `session_not_movable` (detalle: el estado), `invalid_transition` (detalle: la sesión) | `409` con `status` o `sessionId` |
| `55000 has_payments` (detalle: las sesiones cobradas, separadas por coma) | `409 hasPayments` con `sessionIds` |
| `P0002 request_not_found`, `client_not_found`, `session_not_found` | `404` |
| `P0002 chef_not_found` (la cocinera está en `chefs` pero no en `chef_settings`) | `500` |
| `P0002 menu_not_found`, `send_not_found` (envío del menú, §13) | `404 menuNotFound` / `sendNotFound` |
| `55000 session_not_editable` (detalle: el estado), `session_without_request`, `already_sent` | `409 sessionNotEditable` (con `status`) / `sessionWithoutRequest` / `alreadySent` |
| `40001 menu_changed` (otra versión del menú, u otra huella de la foto: §13) | `409 menuChanged` (no `503`: reintentar igual no sirve) |
| `40001 quote_changed` (los términos del presupuesto ya no son los de la vista previa: §13) | `409 quoteChanged` (tampoco `503`) |
| `P0002 quote_not_found` (§14) | `404 quoteNotFound` |
| `55000 quote_exists`, `quote_closed`, `quote_empty`, `quote_week_not_first` (§13, §14) | `409 quoteExists` / `quoteClosed` / `quoteEmpty` / `quoteWeekNotFirst` |
| `22023 invalid_request_type` en `/quotes` (un pedido de cambios; el cuerpo no tiene `type`) | `409 requestNotQuotable` (en `/bookings`, `400 type: "invalid"`) |
| `22023 menu_empty` | `409 menuEmpty` |
| `22023 invalid_snapshot`, `invalid_token`, `invalid_via` (los arma la función, nunca la app) | `500` |
| `23505` en `chef_link_menu_send` (token repetido) | otro token, una vez; si vuelve a chocar, `409 conflict` |
| `22023` con un código propio (`invalid_dates`, `dates_same_week`, `invalid_household`, `request_key_conflict`, …) | `400` con su campo; un código desconocido, `payload: "invalid"` |
| otro dato inválido (`22xxx`), `23514` o `23502` | `400 payload: "invalid"` |
| sin código (la base no respondió), `08xxx`, `40xxx`, `53xxx`, `57xxx`, `58xxx` o `PGRST000`–`PGRST003` | `503` |
| cualquier otro (por ejemplo `PGRST202`: la función SQL no existe, la migración no está desplegada) | `500` |

Las funciones del envío del menú son de la migración `20261121100000_menu_sends.sql` (SPEC §5.8, contrato §13): `chef_menu_send_context(p_chef_id, p_session_id)`, `chef_prepare_menu_send(p_chef_id, p_session_id, p_menu_version, p_locale, p_snapshot, p_translated, p_fingerprint)`, `chef_link_menu_send(p_chef_id, p_send_id, p_token_hash)` y `chef_complete_menu_send(p_chef_id, p_send_id, p_via)`, también solo de `service_role` y con la cocina del token. Las del presupuesto, de la migración `20261121120000_quotes.sql` (§14), que además rehace esas cuatro con el presupuesto: `chef_create_quote(p_chef_id, p_request_id, p_dates, p_start, p_cook_minutes, p_service_total_cents, p_portions, p_dry_run)`, `chef_update_quote(p_chef_id, p_quote_id, p_service_total_cents)` y `chef_withdraw_quote(p_chef_id, p_quote_id)`.

De un error de la base solo se usan el código, el mensaje si es un código propio en snake_case y el detalle si tiene la forma esperada (una fecha, un estado, un uuid o una lista de hasta 100 uuid). El mensaje y el detalle de Postgres pueden traer la fila, con datos personales: nunca pasan ni a la respuesta ni al log.

## 8. Configuración

| Nombre | De dónde | Nota |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_SECRET_KEYS` (o las variables de compatibilidad) | las pone Supabase | sin ellas, `500` y `config_missing` |
| `ALLOWED_ORIGINS` | secreto de las funciones, compartido con `public-request`; lo carga `deploy-supabase.yml` | CORS (§2). Sin ella, `/gestione/` no puede llamar a la función (la app nativa sí) y el arranque avisa `config_incomplete` |
| `ANTHROPIC_API_KEY` | secreto de las funciones (opcional); lo carga `deploy-supabase.yml` desde el secreto de GitHub del mismo nombre | la clave de Claude para `/translate` (§12). Sin ella, `/translate` responde `501` y el arranque avisa `config_incomplete`. Nunca se loguea. Borrar el secreto de GitHub no la saca de Supabase (el despliegue no pisa ni borra lo que ya está): para apagar la traducción, `supabase secrets unset ANTHROPIC_API_KEY --project-ref <ref>` |
| `TRANSLATE_TRANSPORT` | solo en local (`.env.example` trae `fake`) | `fake`: `/translate` (y la traducción de `/menus/preview`) devuelve una traducción de mentira (`"[it] <nombre>"`) sin llamar a Claude, aunque haya clave; el arranque avisa `translate_fake`. Vale solo con un Supabase local (`SUPABASE_URL` en `kong`, `localhost` o `127.0.0.1`): en otro lado se ignora, el arranque loguea el error `translate_fake_ignored` y `/translate` responde `501`. El despliegue no la carga y corta si la encuentra en los secretos de Supabase |
| `PUBLIC_SITE_URL` | secreto de las funciones, compartido con `public-request` (contrato public-request §4) | la web del link de la clienta (`<PUBLIC_SITE_URL>/prenotazione/#t=<token>`, §13). Sin ella (o si no es http/https), `/menus/send` responde `500` y loguea `config_missing`; el arranque avisa `config_incomplete` |
| `EMAIL_TRANSPORT`, `RESEND_API_KEY`, `MAIL_FROM` | secretos compartidos con `public-request` | el email del menú (§13), como los de `public-request`: con `log` no sale nada (registra solo tamaños). Con Resend, sin la clave o sin `MAIL_FROM`, `/menus/send` con email responde `503 emailUnavailable` y el arranque avisa. La clave la lee solo `index.ts` y nunca se loguea |
| `MAIL_REPLY_TO` (o `CHEF_NOTIFY_EMAIL`) | secretos compartidos con `public-request` | a dónde van las respuestas de la clienta al email del menú: el `Reply-To`. Sin ninguna de las dos, van al remitente y el arranque avisa `MAIL_REPLY_TO` |
| `SUPABASE_URL` | la pone Supabase | además, el origen de las URL de las fotos de los platos en la foto del envío (`photoOrigin`, como el menù de la web; con `functions serve` es `http://kong:8000` y los platos van sin foto) |

En local, `npx supabase start` sirve la función con `verify_jwt` de `config.toml` y lee `ALLOWED_ORIGINS` y las de la traducción de `supabase/functions/.env` (copiado de `.env.example`); para `/gestione/` con `flutter run -d web-server --web-port 8080` hay que sumar `http://localhost:8080` (desde el teléfono, `http://<IP de la PC>:8080`).

## 9. Despliegue

- `deploy-supabase.yml`, paso «Desplegar chef»: `supabase functions deploy chef --use-api`, después de `db push` (llama a las funciones de la migración de reservas) y de cargar los secretos (`ALLOWED_ORIGINS` y, si está, `ANTHROPIC_API_KEY`; sin ella, ni en GitHub ni en Supabase, el paso de los secretos avisa que la traducción queda apagada, sin cortar el despliegue; si está en Supabase y no en GitHub, avisa que sigue prendida y cómo borrarla). Los del email y el link del menú (§13: `RESEND_API_KEY`, `MAIL_FROM`, `MAIL_REPLY_TO`, `CHEF_NOTIFY_EMAIL`, `EMAIL_TRANSPORT`, `PUBLIC_SITE_URL`) son los de `public-request`: los secretos de las funciones son de todo el proyecto y el mismo paso ya los carga y los exige. El mismo paso corta si no puede leer la lista de secretos de Supabase o si encuentra `TRANSLATE_TRANSPORT`. `verify_jwt = true` sale de `config.toml`. Avisa si `ALLOWED_ORIGINS` tiene orígenes además del de `PUBLIC_SITE_URL`.
- Orden: la migración de reservas va en su propio PR (PR 3) y se despliega antes (contrato public-request §8). Sin ella, cada llamada da `500` y el log dice `PGRST202`.
- Antes del primer despliegue: limpiar `ALLOWED_ORIGINS` (§2).
- Se acepta cuando, desplegada, una reserva de 4 semanas hecha con el token de una sesión de prueba crea 4 sesiones, y un reintento con la misma clave no crea nada más.

## 10. Logs

Solo evento, ruta, códigos, contadores, largos, duraciones e ids. Nunca nombres, teléfonos, emails, zonas, direcciones, notas, restricciones, fechas, importes, tokens (tampoco el del link de la clienta ni su hash), el texto de un plato, de la lista o de la nota, el mensaje ni las claves de Anthropic o de Resend. Los tests lo comprueban con un espía en todos los caminos del handler: cada evento de esta tabla (salvo `config_incomplete`, `translate_fake` y `translate_fake_ignored`, que escribe `index.ts` al arrancar, solo con nombres de variables), también con errores de la base que traen la fila, una respuesta de la base que lanza al leerla, un cuerpo que se corta mientras se lee y un traductor que explota o repite el plato en su salida.

| Evento | Campos |
|---|---|
| `auth_rejected` | `route`, `reason`: `missing`, `malformed` o `invalid` |
| `forbidden` | `route`, `userId` |
| `invalid_payload` | `route`, `fields` (los nombres de los campos con error) |
| `rejected` | `route`, `status`, `error`, `code` (SQLSTATE), `message` (el código propio) |
| `booking_created` | `requestId`, `sessions`, `client` (`request`, `client` o `newClient`), `userId` |
| `booking_duplicate` | `requestId`, `userId` |
| `session_moved` | `sessionId`, `userId` |
| `sessions_cancelled` | `cancelled`, `alreadyCancelled`, `withPayments` (cantidades), `userId` |
| `translated` | `route`, `ms` (lo que tardó el traductor), `nameLength`, `descriptionLength` (o null), `userId`. En `/menus/preview`: `items` (los nombres distintos de la lista) en lugar de los largos del plato |
| `translate_failed` | `route`, `reason` (§12), `category` (de una negativa) o `apiStatus` (el estado HTTP de Anthropic), `ms`, `nameLength`, `descriptionLength` (en `/menus/preview`, `items`). `warn` para una negativa, un corte por `max_tokens` o la traducción apagada sin clave; `error` para el resto (también `fakeIgnored`) |
| `rate_limited` | `route`, `userId` |
| `menu_previewed` | `route`, `sendId`, `sessionId`, `locale`, `translated`, `dishes`, `items` (cantidades), `hasNote`, `userId` |
| `menu_sent` | `route`, `sendId`, `via` (`email`, `whatsapp`), `userId` |
| `email_sent` / `email_logged` | `route`, `sendId` (con `EMAIL_TRANSPORT=log`, `htmlChars` y `textChars`) |
| `email_failed` | `route`, `sendId`, `status` (el HTTP de Resend o null), `errorName` (el `name` de Resend, `network` o `unexpected`; nunca el mensaje) |
| `email_skipped` | `route`, `sendId`, `reason: not_configured` (nivel `warn`: `503 emailUnavailable`) |
| `token_collision` | `route`, `sendId` (nivel `warn`: un hash repetido en `client_links`, se generó otro token) |
| `menu_send_incomplete` | `route`, `sendId`, `status`, `code`, `message` (nivel `error`: el email salió pero el envío no se pudo marcar) |
| `quote_created` | `requestId`, `quoteId`, `sessions` (cuántas semanas), `userId` (no el `dryRun`) |
| `quote_priced` | `quoteId`, `weeks` (cuántas semanas vivas), `userId`: nunca el importe |
| `quote_withdrawn` | `quoteId`, `requestId`, `already`, `cancelled` (cuántas semanas), `userId` |
| `db_error` | `op`, `code` y, si lo hay, `message` (el código propio) |
| `unexpected_result` | `op` (también `load_chef`, si `chef_id_for_user` responde algo que no es un uuid ni null) |
| `unexpected_error` | `error` (el tipo, nunca el mensaje) |
| `config_missing`, `config_incomplete` | `missing` (nombres de variables) |
| `translate_fake` | ninguno: `TRANSLATE_TRANSPORT=fake` al arrancar, con un Supabase local |
| `translate_fake_ignored` | ninguno (nivel `error`): `TRANSLATE_TRANSPORT=fake` fuera de un Supabase local, ignorado |

`userId` es el usuario del token: la cocinera o el colaborador que hizo el cambio (con colaboradores, la cocina son varias cuentas; SPEC §6).

## 11. Pruebas

- `npm test`: `supabase/functions/_shared/chef_api.test.ts` (validación), `supabase/functions/chef/handler.test.ts` (401 antes de leer el cuerpo, 403, un colaborador que entra con la cocina de ella y queda en los logs con su propio `userId`, una cocina con otra forma → 500, 400 por campo, 409 con la fecha o las sesiones cobradas, `dryRun` que no escribe, reintento con la misma clave, la cocinera siempre del token, que `index.ts` use `chef_id_for_user` y le pase su respuesta tal cual al handler, errores de la base, `/translate` con un traductor simulado y el espía de logs), `supabase/functions/chef/translation.test.ts` (el pedido a Claude, el prompt, el esquema, la lectura de la respuesta, la validación de la salida, el límite y el traductor de mentira) y el paso del workflow en `supabase/scripts/deploy-supabase.test.ts`. `claude_translator.ts` no corre en Node (importa el SDK): `handler.test.ts` mira su texto (la versión fija del SDK, las opciones del cliente, el pedido, la señal del tope y que le pase sus clases de error a `failureFrom`, que `translation.test.ts` prueba con clases de mentira) y que ni `handler.ts` ni `index.ts` lo importen al arrancar. CI corre además `deno check` de las dos funciones y de `claude_translator.ts`, con el SDK y supabase-js reales (job `edge-functions`).
- Envío del menú (§13): `_shared/menu_snapshot.test.ts` (la foto: forma, lectura defensiva, que no salga nada de más), `_shared/menu_message.test.ts` (el mensaje en los tres idiomas: cantidades, secciones, alérgenos, fechas, vista previa sin link, WhatsApp, escape del HTML y que nunca lleve contacto, dirección, alergias ni precios), `chef/menu_send.test.ts` (lo que devuelven las funciones SQL, la foto, el token y su hash), `chef/menu_translation.test.ts` (el pedido, el prompt, el esquema, la validación de la salida y el de mentira) y, en `handler.test.ts`, las dos rutas con la base, el traductor y el Mailer simulados (con y sin traducción, cada error, email que sale o no, sin email o sin teléfono, sin configuración, WhatsApp, token repetido, `emailSent`) y el espía de logs.
- Presupuesto (§14): `_shared/chef_api.test.ts` (los tres cuerpos), `chef/quotes.test.ts` (lo que devuelven `chef_create_quote`, `chef_update_quote` y `chef_withdraw_quote`), `_shared/quote_snapshot.test.ts` (el presupuesto en la foto: lectura defensiva, el plazo de 48 horas o la primera llegada, la hora de Roma), `chef/menu_send.test.ts` (el presupuesto del contexto y de la foto, con la versión que sale), `_shared/menu_message.test.ts` (la sección del presupuesto en los tres idiomas: semanas, precios con los separadores de cada idioma, el plazo y que nunca hable de pagos) y, en `handler.test.ts`, las tres rutas con cada error de la base, la vista previa y el envío de la semana 1 con el presupuesto (y sus 409), los colaboradores, `index.ts` y el espía de logs.
- pgTAP `13_bookings`: las funciones SQL (reparto, chequeos y su prioridad, choques, reintentos, transiciones, mover, cancelar con y sin cobros, y permisos, también que la app no borra fichas). `22_quotes`: las del presupuesto (§14) y el envío y el link con el presupuesto. `15_chef_members`: `chef_id_for_user` (quién es de qué cocina, solo `service_role`) y lo que ve y hace un colaborador. `18_recipe_translations`: `recipes.auto_translated`, su fuente en español y la clave de `save_recipe`. `20_menu_sends`: las funciones del envío del menú y del link de la clienta (§13).
- En local, de punta a punta: `npx supabase start` (con `-x` se pueden dejar afuera los servicios que no hacen falta: alcanza con la base, Kong, Auth, PostgREST y el runtime de funciones), un token con `POST /auth/v1/token?grant_type=password` para `evelyn@example.test` (la contraseña del seed) y las llamadas a `/functions/v1/chef/…`. Con `marco@example.test`, su colaborador en el seed, las mismas llamadas actúan sobre la cocina de Evelyn. `POST /functions/v1/chef/translate` con `TRANSLATE_TRANSPORT=fake` (lo que trae `.env.example`) devuelve la traducción de mentira sin llamar a Claude; con `EMAIL_TRANSPORT=log` (también de `.env.example`), `/menus/send` marca el envío sin mandar ningún email.

## 12. `POST /translate`: traducir un plato

Pedido de Evelyn del 20/11/2026: escribe el nombre y la descripción de cada plato en español; el italiano y el inglés los completa Claude y ella los puede corregir. La app (PR siguiente, traduccion-app) llama a esta ruta desde el editor y guarda con `save_recipe` qué campos llenó el traductor (`auto_translated`, abajo). Revisado el 20/11/2026 (revisión independiente): códigos de error separados, tope de 40 s, límite de 150 por día, fake solo en local y el español como fuente obligatoria de una marca.

### Cuerpo

| Campo | Tipo | Regla |
|---|---|---|
| `name` | string | obligatorio: de 1 a 120 caracteres después de recortar los espacios del borde y sin caracteres de control (`required`, `tooLong`, `invalid`) |
| `description` | string \| null | opcional: de 1 a 200 caracteres, con las mismas reglas; ausente, null, `""` o solo espacios cuentan como null (`tooLong`, `invalid`) |

- Los caracteres se cuentan como la base y la app (`char_length`, `textLength`: por code points; un emoji es uno). Caracteres de control: los C0, DEL, los C1 y los separadores de línea y de párrafo (U+2028, U+2029), los que la base rechaza y la app normaliza.
- Una clave que el contrato no tiene es `payload: "invalid"` (no se ignora, como en las otras rutas: el pedido es corto y lo arma solo la app).

### Respuesta `200`

```json
{ "it": { "name": "Cotoletta alla napoletana", "description": "Con pomodoro, prosciutto cotto e mozzarella." },
  "en": { "name": "Neapolitan-style milanese", "description": "With tomato sauce, ham and mozzarella." } }
```

- `description` es null en los dos idiomas si y solo si el pedido no la tenía.
- Mismos límites que la base: de 1 a 120 y de 1 a 200 caracteres, una línea (los espacios de cualquier tipo, también los saltos de línea, quedan en uno), sin caracteres de control ni de dirección del texto. Lo que vuelve se puede guardar tal cual con `save_recipe`.
- Todo o nada: nunca vuelve un idioma sin el otro, ni un nombre sin la descripción pedida.

### Errores (además de los comunes, §3)

| HTTP | Cuerpo | Cuándo (`reason` del log `translate_failed`) | Qué hace la app |
|---|---|---|---|
| 400 | `{ "errors": { campo: código } }` | el cuerpo no cumple; no se gasta el cupo | es un error de la app |
| 422 | `{ "error": "untranslatable" }` | este plato no se pudo traducir: Claude declinó, también después del fallback del servidor (`refusal`); cortó por `max_tokens` (`maxTokens`); terminó por otro motivo (`stopReason`); o la salida no pasó la validación (`invalidOutput`) | deja los campos como estaban y Evelyn los escribe a mano; reintentar igual no sirve |
| 429 | `{ "error": "rateLimited" }` y `Retry-After: 3600` | la cocina pasó su límite (abajo) | deja los campos como estaban; no reintenta sola |
| 501 | `{ "error": "notConfigured" }` | la traducción está apagada: sin `ANTHROPIC_API_KEY` (`notConfigured`) o con `TRANSLATE_TRANSPORT=fake` fuera de un Supabase local (`fakeIgnored`). No gasta el cupo | no ofrece traducir |
| 503 | `{ "error": "unavailable" }` | algo que se puede reintentar: Claude no respondió a tiempo (`timeout`), sin conexión (`connection`), un 5xx de Anthropic (`apiError` con `apiStatus` ≥ 500, como el 529 de sobrecarga) o su 429 (`rateLimited`); o la base no respondió al contar el límite | Evelyn puede volver a probar en un rato |
| 500 | `{ "error": "server" }` | algo roto o mal configurado: otro 4xx de Anthropic (`apiError`; por ejemplo, 401 con una clave inválida), un error del SDK (`sdk`), el SDK que no carga (`sdkLoad`), una excepción del traductor (`unexpected`) o un error de la base al contar el límite que no se puede reintentar | error genérico; el log dice el motivo |

### Tiempos

Cada intento espera hasta 25 s y hay un solo reintento; la llamada entera, con el reintento y la espera entre intentos, tiene un tope de 40 s (`AbortSignal.timeout`): el SDK respeta el `retry-after` de Anthropic sin tope y esa espera no cuenta para el timeout de un intento. Pasado el tope, `503` (`timeout`). La app espera hasta 60 s antes de dar el pedido por perdido.

### Orden

Después de la validación (§3): traductor configurado (`501`) → límite de la cocina (`429`; si la base no responde, `503` o `500`) → traductor (`200`, `422`, `503` o `500`). El intento cuenta para el límite antes de llamar a Claude: uno que después falla también se gasta.

### Límite por cocina

- 60 traducciones por hora y 150 por día por cocina (la dueña y sus colaboradores comparten el cupo). Las ventanas son móviles: la última hora y las últimas 24 horas, no la hora ni el día del calendario.
- Un pedido rechazado con `429` también cuenta (la función registra el intento antes de contar): reintentar en un bucle lo deja bloqueado. La app no reintenta sola.
- `Retry-After` es siempre 3600 (la ventana corta): `hit_public_request_rate` solo dice si el intento entra, no qué tope se pasó. Si fue el del día, a la hora puede seguir en `429`.
- `public.hit_public_request_rate`, la función del límite del formulario, con su propio sujeto: `translate:<chef_id>` (la cocina del token), guardado como SHA-256 en hexadecimal (`translateRateKey`). Sin sal, a diferencia de la IP del formulario: el id de la cocina no es un dato personal ni secreto, y así la función no depende de `IP_HASH_SALT`. Es otra fila de la misma tabla: no gasta ningún cupo de la web. Los intentos de más de un día se borran como los del formulario. Los comentarios de la función y de la tabla lo dicen (migración `20261120090000_recipe_translations.sql`).

### La llamada a Claude

- `claude_translator.ts`, con el SDK oficial `npm:@anthropic-ai/sdk@1.6.0`. `index.ts` no lo importa al arrancar: lo carga con un import dinámico en la primera traducción y lo guarda (`lazyTranslator`), así una falla al cargar el SDK solo afecta a `/translate` (`500`, `sdkLoad`; la próxima traducción reintenta la carga) y nunca a `/bookings` ni a `/sessions/*`. `handler.ts` recibe un `Translator` y no conoce el SDK.
- `client.beta.messages.create` con `model: "claude-opus-5-5"`, `max_tokens: 8000`, `output_config: { effort: "low", format: { type: "json_schema", schema } }`, sin `thinking` (en Opus 5.5 es adaptativo y no se puede apagar) ni streaming, `betas: ["server-side-fallback-2026-07-01"]` y `fallbacks: "default"`: si el modelo declina por una política de seguridad, el servidor reintenta en el modelo que corresponde a esa categoría. No todas las categorías tienen modelo de reserva: esas negativas vuelven como `422` (`refusal`).
- El cliente no depende del entorno: `baseURL` fija (`https://api.anthropic.com`: `ANTHROPIC_BASE_URL` no desvía la clave), `logLevel: "off"` (con `ANTHROPIC_LOG=debug` el SDK loguearía el cuerpo, con el plato), `openTelemetry: false` (las variables `ANTHROPIC_OPEN_TELEMETRY_*` podrían exportar el contenido), `timeout` de 25 s y `maxRetries: 1`. Con la clave explícita, el SDK no lee `ANTHROPIC_AUTH_TOKEN` ni perfiles.
- El prompt del sistema es fijo (`TRANSLATION_SYSTEM_PROMPT` en `translation.ts`): traducir del español rioplatense al italiano y al inglés el nombre y la descripción de un plato casero, para el menú de una cocinera a domicilio en Bergamo; los nombres de platos que se usan tal cual quedan (empanadas, chipá, provoleta) y los italianos quedan en italiano; tono de menú, natural; sin agregar información, comillas ni emojis; los largos máximos. El plato va como JSON en el mensaje del usuario: es un dato, nunca instrucciones.
- El esquema de la salida (`translationSchema`) tiene `it` y `en`, cada uno con `name` y, solo si el pedido la tiene, `description`, con `additionalProperties: false`. Los largos no van en el esquema (la API no admite `maxLength`): los mira la validación.
- La respuesta se lee por `stop_reason` primero (`refusal` y `max_tokens` nunca se leen; otro que no sea `end_turn`, `stopReason`); después de un bloque `fallback` vale el texto del último modelo (los bloques de pensamiento no cuentan); la salida se valida entera (`readTranslationOutput`).
- Los errores (`failureFrom`, en `translation.ts`, con las clases del SDK inyectadas): `APIConnectionTimeoutError` y `APIUserAbortError` (el corte del tope de 40 s, o su `TimeoutError` si salta fuera del SDK) son `timeout`; `APIConnectionError`, `connection`; `RateLimitError`, `rateLimited` (429); `APIError`, `apiError` con su estado; `AnthropicError`, `sdk`; cualquier otra cosa, `unexpected`. Nunca el mensaje: puede traer el texto del plato.

### Qué se manda a Anthropic

Solo el nombre y la descripción del plato en español: nunca datos de clientes, pedidos, sesiones, restricciones ni direcciones. No son datos personales mientras Evelyn no los escriba en el plato (el editor de la app le avisa que no ponga datos de clientes), así que la privacy no cambia (SPEC §6).

### En la base: `recipes.auto_translated`

Migración `20261120090000_recipe_translations.sql` (pgTAP `18_recipe_translations`): los campos de destino que llenó el traductor y Evelyn no tocó a mano, de `name_it`, `description_it`, `name_en` y `description_en` (el español es la fuente y nunca está), sin repetir. Un campo marcado siempre tiene texto en la fila, y su fuente en español también: un nombre marcado exige `name_es` y una descripción marcada, `description_es` (checks `recipes_auto_translated_con_texto` y `recipes_auto_translated_con_fuente`). `save_recipe` acepta la clave opcional `auto_translated` (una lista, en cualquier orden; se guarda en ese) y la reemplaza entera en cada guardado: sin la clave queda `{}`, también al actualizar, así una app que no la conoce guarda todo como escrito a mano. Si no es una lista, `invalid_payload` con `auto_translated` en el DETAIL; un valor fuera de la lista, repetido, que no es texto, un campo marcado que no viene en `p` con texto o uno cuya fuente no viene en `p` con texto, `invalid_payload` con `auto_translated[i]`. Una copia de un plato (sin las descripciones, SPEC §4) no puede marcar una descripción.

### En local

`TRANSLATE_TRANSPORT=fake` (lo que trae `.env.example`), solo con un Supabase local: una traducción de mentira reconocible (`"[it] <nombre>"`, `"[en] <nombre>"`, cortada a los largos máximos) con la misma forma y la misma validación que la de Claude, sin llamar a la API. Para probar con Claude: `ANTHROPIC_API_KEY` en `supabase/functions/.env` y sin `TRANSLATE_TRANSPORT`.

## 13. `POST /menus/preview` y `POST /menus/send`: el menú de una semana para la clienta

Proceso de Nicolas del 21/11/2026 (SPEC §5.8, «Envío del menú»): Evelyn arma en la app el menú de una semana (platos con sus porciones, la lista de compras y una nota, `save_session_menu`) y se lo manda a la clienta por email, por WhatsApp o por los dos. El mensaje lleva un link a una página de la web (PR siguiente) donde la clienta ve el menú entero y lo confirma o pide cambios: todavía no tiene cuenta (M2), así que el link es la llave. Base de datos: migración `20261121100000_menu_sends.sql` (pgTAP `20_menu_sends`).

Dos pasos:

1. **Vista previa** (`/menus/preview`): la función lee la semana (`chef_menu_send_context`), arma la foto del envío en el idioma de la clienta (con los nombres de la lista traducidos si hace falta; la nota, como la escribió Evelyn), la guarda en un envío que todavía no salió (`chef_prepare_menu_send`, con la huella del contexto) y devuelve el mensaje, sin el link, y el contacto, para que Evelyn revise las dos cosas.
2. **Envío** (`/menus/send`): con el `sendId` de la vista previa y los canales que eligió Evelyn, la función crea el link (`chef_link_menu_send`: la base guarda solo el hash del token), manda el email si se pidió (Resend) y lo marca enviado (`chef_complete_menu_send`). El WhatsApp lo abre la app desde el teléfono de Evelyn con el texto que devuelve la función: el servidor nunca manda un WhatsApp.

Lo que la clienta recibe es siempre la foto guardada en la vista previa. Si antes de mandarla cambió el menú, el día o la hora, las semanas de la reserva o un plato del catálogo, el envío da `409 menuChanged` y hace falta otra vista previa: la base guarda la huella de lo que entró en la foto (`private.menu_send_fingerprint`: el día y la hora de la sesión, las semanas vivas de la reserva, la versión del menú y, de cada plato, lo que sale del catálogo con sus alérgenos) y `chef_link_menu_send` y `chef_complete_menu_send` la recalculan antes de mandar y de marcar.

### `POST /menus/preview`

| Campo | Tipo | Regla |
|---|---|---|
| `sessionId` | uuid | obligatorio: la semana (una sesión con pedido) |
| `menuVersion` | entero de 1 a 2147483647 | obligatorio: `session_menus.version` que la app tiene cargada; si no es la guardada, `409 menuChanged` |
| `translate` | boolean | por defecto `true`: traducir los nombres de la lista al idioma de la clienta. `false`: van como los escribió Evelyn (la app lo ofrece si la traducción falla). La nota nunca se traduce |

Una clave que el contrato no tiene es `payload: "invalid"`.

Respuesta `200`:

```json
{ "sendId": "uuid", "locale": "it", "translated": true,
  "contact": { "name": "Maria Rossi", "email": "maria@example.com", "phone": "+393331234567" },
  "message": { "subject": "Radici: il menù della settimana 1 di 4 (30 nov)",
               "emailText": "Ciao Maria!\n\n…", "whatsappText": "Ciao Maria!\n…" } }
```

- `locale`: el idioma de la clienta, el del pedido (`requests.locale`). Todo el mensaje va en ese idioma.
- `translated`: los nombres de la lista se tradujeron solos. `false` en español, con `translate: false` o sin lista.
- `contact`: el del pedido de la web (`requests.contact`, también el nombre con que llegó el pedido) o, si no lo tiene, el de la ficha; `email` y `phone` pueden ser null. Es lo que la app le muestra a Evelyn antes de mandar: el envío usa el contacto de ese momento.
- `message`: el asunto, el texto del email (el HTML sale con lo mismo, con el diseño de los emails) y el del WhatsApp. Donde va el link, un texto de reemplazo en el idioma de la clienta (`[link personale per confermare]`, `[enlace personal para confirmar]`, `[personal link to confirm]`): el link se crea recién al enviar.
- Cada vista previa guarda un envío nuevo, sin salir: uno que nunca sale no se muestra en ningún lado.

**Los platos** van con las traducciones que tienen guardadas (§12): el nombre en el idioma de la clienta o, si no está, en italiano; la descripción en su idioma, si no la italiana, o ninguna. Con sus alérgenos (de los 14), la dieta, las porciones de la semana y la foto (las URL públicas de Storage, como el menù de la web; el email no las usa).

**La lista** la escribe Evelyn, en español. Si la clienta lee italiano o inglés, `translate` no es `false` y la lista tiene renglones, sus nombres se traducen con Claude en un solo pedido (`menu_translation.ts`): los nombres sin repetir, nada más. El mismo modelo, esfuerzo, fallback, tiempos y errores que `/translate` (§12), con `max_tokens` 16000, su prompt y su esquema (solo `items`). La salida se valida entera: la misma cantidad de nombres, cada uno de 1 a 80 caracteres en una línea y sin caracteres de control; si no, `422`. Cuenta para el mismo límite de la cocina que `/translate` (60 por hora y 150 por día). Con `TRANSLATE_TRANSPORT=fake`, la de mentira (`"[it] zapallitos"`).

**La nota** sale exactamente como la escribió Evelyn, en cualquier idioma: nunca se traduce ni va a Anthropic (decisión de Nicolas del 22/11/2026, SPEC §6).

**La huella**: `chef_menu_send_context` devuelve `fingerprint` (32 caracteres en hexadecimal) y la función se la pasa tal cual a `chef_prepare_menu_send` (`p_fingerprint`). Si mientras armaba la foto o traducía la lista cambió el menú, el día o la hora, las semanas de la reserva o un plato del catálogo, la base no la guarda (`409 menuChanged`).

**La foto** (`menu_sends.snapshot`, `_shared/menu_snapshot.ts`, versión 1): `{ v: 1, locale, session: { date, start, week, weeks }, weeks: [{ date, start }], dishes: [{ name, description, allergens, diet, portions, photo }], items: [{ name, section, quantity, unit }], note }`. La leen el envío y la página de la clienta. Nunca lleva el contacto, la dirección, las alergias de la clienta ni nada de pagos.

**El presupuesto** (§14): el envío de la semana 1 de un presupuesto abierto (una semana `held`, la primera viva de su presupuesto: `chef_menu_send_context` trae `quote` con `firstWeek: true`) suma a la foto `quote: { version, totalCents, weeks: [{ date, start, serviceCents }], holdHours, firstStart }` (`_shared/quote_snapshot.ts`): la versión que va a salir (la de ahora la primera vez; la siguiente en un reenvío, como `chef_complete_menu_send`; la 1 es el primer presupuesto que le llega del pedido, §14), el precio del servicio de todas las semanas y de cada una (en centavos; los términos que calcula la base y que la clienta acepta: la huella los cubre), las horas que tiene para aceptarlo (`chef_settings.quote_hold_hours`) y la primera llegada (`"AAAA-MM-DDTHH:MM"`, hora de Roma), que el plazo nunca pasa. Sin presupuesto, la foto de siempre (y las de antes se leen igual). Una foto con un presupuesto que no cierra (el total no es la suma, otra forma) no se manda: `500`. Del precio, solo el del servicio; nunca cómo ni cuándo se paga.

Orden: validación (`400`) → `chef_menu_send_context` (`404 sessionNotFound`; `409 sessionNotEditable` con `status` si la semana está cancelada, cocinada o cobrada; `409 sessionWithoutRequest`; `404 menuNotFound`) → lo que la base vuelve a mirar al guardar, antes de gastar una traducción: una semana `held` sin su presupuesto abierto (`409 quoteClosed`) o que no es la primera (`409 quoteWeekNotFirst`), la versión (`409 menuChanged`) y algún plato (`409 menuEmpty`) → si hay que traducir: traductor configurado (`501`) → límite de la cocina (`429`; si la base no responde, `503` o `500`) → traductor (`422`, `503` o `500`) → `chef_prepare_menu_send` (los mismos `404` y `409`, y `409 menuChanged` si cambió la huella, también por los términos del presupuesto) → `200`.

### `POST /menus/send`

| Campo | Tipo | Regla |
|---|---|---|
| `sendId` | uuid | obligatorio: el de la vista previa |
| `email` | boolean | mandar el email desde el servidor (ausente = `false`) |
| `whatsapp` | boolean | devolver el texto para abrir WhatsApp (ausente = `false`) |

Al menos uno de los dos (si no, `channels: "required"`). Una clave que el contrato no tiene es `payload: "invalid"`.

Respuesta `200`:

```json
{ "sentAt": "2026-11-21T21:42:26.123456+00:00", "sentVia": ["email", "whatsapp"],
  "whatsappText": "Ciao Maria!\n…\nhttps://radicicucina.app/prenotazione/#t=…", "whatsappPhone": "+393331234567" }
```

- `sentVia`: en el orden de la base (`email` antes que `whatsapp`).
- `whatsappText` y `whatsappPhone` solo si se pidió WhatsApp: el mismo mensaje de la vista previa con el link. El teléfono en E.164; `https://wa.me/` lo quiere sin el `+`. La app abre WhatsApp desde el teléfono de Evelyn: el envío ya quedó marcado.

**El link**: `<PUBLIC_SITE_URL>/prenotazione/#t=<token>`, con el token en el fragmento (`#t=`), que el navegador no manda a ningún servidor ni pone en el `Referer`; nunca en la query. El token son 32 bytes al azar (WebCrypto) en base64url, 43 caracteres. La base guarda solo su hash (SHA-256 del token en UTF-8, en hexadecimal), en `client_links`: abre la reserva entera durante 15 días (migración `20261121105000_client_links_15_days.sql`), y todos los links de una reserva valen a la vez. El token no se guarda ni se loguea: va solo en el mensaje (y en `whatsappText`). Si el hash ya existe (`23505`, no debería pasar), la función genera otro una vez.

**El email**: de `MAIL_FROM` al email del contacto, con `Reply-To` `MAIL_REPLY_TO` (o `CHEF_NOTIFY_EMAIL`): las respuestas de la clienta le llegan a Evelyn. Asunto, HTML y texto como la vista previa, con el link. `Idempotency-Key`: `menu-send-<sendId>-<16 primeros caracteres del hash>`, una por link: el reintento de un mismo pedido a Resend no duplica el email, y otro intento de envío (otro link) es otro email. Con `EMAIL_TRANSPORT=log` no sale nada: se registra el tamaño y el envío se marca igual (desarrollo).

Orden: validación (`400`) → la web configurada (sin `PUBLIC_SITE_URL`, `500`) → si pidió email, el email configurado (`503 emailUnavailable`, sin crear el link) → `chef_link_menu_send` (`404 sendNotFound`, `409 alreadySent`, `409 sessionNotEditable`, `409 menuChanged` si cambió la versión o la huella desde la vista previa; con el presupuesto, `409 quoteClosed` si ya no está abierto y `409 quoteChanged` si cambiaron sus términos) → el contacto de ahora: un email con forma de email si pidió email (`409 noEmail`) y un teléfono que se puede normalizar si pidió WhatsApp (`409 noPhone`); con cualquiera de los dos no sale nada → el email (`502 emailFailed`: el envío queda sin marcar) → `chef_complete_menu_send` (con el presupuesto, el presupuesto sale con él: versión, el plazo de `quote_hold_hours` sin pasar la primera llegada, también en sus semanas `held`, y el pedido pasa a `quoted`) → `200`.

- Con el presupuesto, el mensaje se arma al mandarlo con la hora de ahora: dice «entro 48 ore» o, si la primera llegada es antes, «prima di <día>, alle <hora>», como el plazo que fija `chef_complete_menu_send` enseguida.

- Un `409 noEmail` o `noPhone` deja creado un link que no salió en ningún mensaje: nadie tiene su token, así que no abre nada.
- Después de un `502`, la app ofrece reintentar (otro link, otro email) o mandarlo solo por WhatsApp.
- Si el email salió y el envío no se pudo marcar (la base no respondió, o justo en ese momento cambió el menú, el día o la hora, las semanas de la reserva o un plato del catálogo), la respuesta es el error de la base con `"emailSent": true` y el log `menu_send_incomplete`: la clienta ya tiene un link que vale, pero el envío no figura enviado (su página no lo muestra). Reintentar manda otro email; si el error es `menuChanged`, hace falta otra vista previa.
- Un envío que ya salió no se vuelve a mandar (`409 alreadySent`): para mandar el menú otra vez, otra vista previa. Si la respuesta de un envío se perdió, la app lo ve en `menu_sends` (lo lee con la RLS de la cocina).

### Errores (además de los comunes, §3)

| HTTP | Cuerpo | Ruta | Cuándo |
|---|---|---|---|
| 400 | `{ "errors": { campo: código } }` | las dos | el cuerpo no cumple (campos `sessionId`, `menuVersion`, `translate`, `sendId`, `email`, `whatsapp`, `channels` o `payload`) |
| 404 | `sessionNotFound`, `menuNotFound` | preview | la sesión no es de esta cocina, o la semana no tiene menú guardado |
| 409 | `menuChanged` | las dos | otra versión del menú, o desde la vista previa cambió el menú, el día o la hora, las semanas de la reserva o un plato del catálogo: otra vista previa |
| 404 | `sendNotFound` | send | el envío no existe para esta cocina |
| 409 | `sessionNotEditable` (con `status`), `sessionWithoutRequest`, `menuChanged`, `menuEmpty` | preview | §3 |
| 409 | `quoteClosed`, `quoteWeekNotFirst`, `quoteChanged` | preview | una semana `held` cuyo presupuesto ya no está abierto, que no es la primera (las demás salen después de aceptarlo) o cuyos términos cambiaron mientras se armaba la foto (§3) |
| 409 | `alreadySent`, `sessionNotEditable`, `menuChanged`, `noEmail`, `noPhone`, `conflict` | send | §3 |
| 409 | `quoteClosed`, `quoteChanged` | send | el presupuesto se cerró, o Evelyn le cambió el precio o una semana después de la vista previa: otra vista previa (con `emailSent: true` si el email ya salió) |
| 422 | `untranslatable` | preview | la traducción no salió con este texto (§12): la app ofrece mandarlo sin traducir (`translate: false`) |
| 429 | `rateLimited` y `Retry-After: 3600` | preview | la cocina pasó su límite de traducciones |
| 501 | `notConfigured` | preview | la traducción está apagada; sin traducir sale igual |
| 502 | `emailFailed` | send | el email no salió; el envío queda sin marcar |
| 503 | `unavailable` | las dos | la base o Claude no respondieron, o un error que se puede reintentar (en send, con `emailSent: true` si el email ya salió) |
| 503 | `emailUnavailable` | send | email pedido sin `RESEND_API_KEY` o `MAIL_FROM` |
| 500 | `server` | las dos | configuración rota (sin `PUBLIC_SITE_URL`), una respuesta de la base con otra forma o un error que no se puede reintentar (en send, con `emailSent: true` si el email ya salió; en preview, también una traducción rota, §12: otro 4xx de Anthropic o un error del SDK, así que, si se pidió traducir y la clienta no lee español, la app ofrece seguir sin traducir) |

### El mensaje

`_shared/menu_message.ts`, en italiano, español o inglés (el de la clienta), con los mismos datos en el email (HTML con el diseño compartido de `emails.ts` y texto) y en el WhatsApp (texto con `*negrita*` y `_cursiva_`, más compacto):

- el saludo con el nombre de pila, solo si parece un nombre (`safeFirstName`): el email o el teléfono pueden venir del formulario, sin verificar;
- la semana (k de N), el día y la hora de llegada y, en el mensaje de la semana 1 de una reserva de varias, las fechas de todas las semanas (con la hora de cada una si alguna llega a otra hora);
- los platos: nombre, descripción, porciones, dieta y alérgenos con su nombre (los de la web; sin alérgenos, «Nessuno dei 14 allergeni principali», como la web);
- la lista de compras agrupada por sección del súper, en el orden del recorrido (`produce`, `meat_fish`, `dairy_eggs`, `bakery`, `pantry`, `frozen`, `other`), con las cantidades legibles: hasta 999 en g o ml; desde 1000, en kg o l redondeados a la centésima («1,25 kg» en italiano y español, «1.25 kg» en inglés); las piezas con su unidad («6 pz», «6 uds.», «6 pcs»). Lo que va q.b. aparte, al final: «Da avere in casa» / «Para tener en casa» / «To have at home»;
- la nota de Evelyn, tal como la escribió;
- el link para ver el menú entero, con las fotos, y confirmarlo o pedir cambios;
- cómo responder (al email o al WhatsApp).

Con el presupuesto (la semana 1 de uno abierto), el mensaje lo presenta primero, sin dejar dudas, y el asunto, el preheader, el saludo y el botón lo dicen («il tuo preventivo e il menù del 30 nov»; desde la versión 2, un reenvío o uno nuevo después de otro que le llegó, «il preventivo aggiornato»; «Vedi e accetta il preventivo»):

- cuántas semanas y cada una con su fecha larga y su hora de llegada (las fechas ya no se repiten en «Tutte le date»);
- el precio del servicio: de todas las semanas y, si todas cuestan lo mismo, por semana («560,00 € in totale (140,00 € a settimana)», «€1,120.00 in total (€280.00 per week)»); si no, cada semana con el suyo y el total; con una sola semana, el precio. Desde los centavos enteros, con los separadores de cada idioma (`formatCents`);
- hasta cuándo puede aceptarlo: las horas del plazo («Accettalo entro 48 ore»), o, si la primera llegada es antes, «Accettalo prima di lunedì 30 novembre 2026, alle 10:00»; y que mientras tanto esas fechas quedan reservadas para ella (con una sola semana, en singular: «questa data resta riservata per te»);
- que desde el link acepta el presupuesto y el menú de la primera semana, pide cambios o lo rechaza.

Nunca lleva la dirección, el contacto, las alergias de la clienta ni nada de pagos (ni cómo ni cuándo se paga); del precio, solo el del servicio del presupuesto: el mensaje sale solo de la foto. Todo el texto va escapado en el HTML, sin imágenes remotas ni seguimiento.

### Qué se manda a Anthropic

Solo los nombres de los renglones de la lista de compras, como los escribió Evelyn, y solo si la clienta no lee español: texto genérico de ingredientes (la app le avisa que no escriba datos de clientes en los renglones). Nunca la nota, datos de la clienta, del pedido ni de la sesión, restricciones ni direcciones. Como con los platos (§12), no son datos personales: la privacy no cambia (SPEC §6).

## 14. `POST /quotes`, `/quotes/price` y `/quotes/withdraw`: el presupuesto

Proceso de Nicolas del 21/11/2026 (SPEC §5.8, «Presupuesto»): desde un pedido, Evelyn prepara el presupuesto (semanas, fechas, hora, minutos, porciones y precio del servicio), arma el menú de la semana 1 y los manda juntos (§13); la clienta lo acepta (y con él ese menú) o lo rechaza en su link (contrato `client-link.md`). Base de datos: migración `20261121120000_quotes.sql` (pgTAP `22_quotes`). Nada de esto toca los pagos: el precio es el del servicio que acuerda con Evelyn, y se paga como hoy.

Cómo lo usa la app (PR siguiente): `/quotes` con `dryRun` (los avisos de cada fecha, como «Confirmar reserva») → `/quotes` → el menú de la semana 1 (`save_session_menu`) → `/menus/preview` → `/menus/send`. Para otro precio, `/quotes/price` y otra vista previa y envío (otra versión: el plazo vuelve a empezar); para otras fechas o semanas, `/sessions/move` y `/sessions/cancel` (§5, §6) sobre sus semanas `held`, y lo mismo. `/quotes/withdraw` lo retira. Para confirmar sin presupuesto lo que se acordó por fuera, `/bookings` con el `requestId` (§4) lo retira solo, también si ya salió (pedido `quoted`): responde `201`, sin retirarlo antes. Mientras no lo acepte, solo sale el menú de la semana 1 (`409 quoteWeekNotFirst`); si la semana que lo llevaba pasa al final (`/sessions/move`) y se reenvía desde la nueva primera, el envío viejo queda en su semana y la clienta lo confirma después de aceptar (contrato client-link §4).

### `POST /quotes`: preparar el presupuesto

| Campo | Tipo | Regla |
|---|---|---|
| `requestId` | uuid | obligatorio: un pedido `new` (semanal o extra) sin otro presupuesto abierto |
| `dates` | `string[]` | como en `/bookings` (§4): de 1 a 8, una por semana ISO y en orden, de hoy − 366 a hoy + 366 (`range`, `sameWeek`, `order`, `dateOutOfRange`, con `date`); más de una solo en un pedido semanal (la base: `400 dates: "weeksOnlyForWeek"`) |
| `start` | `"HH:MM"` | llegada de todas las semanas; puede faltar solo en el `dryRun` |
| `cookMinutes` | entero de 1 a 720 | minutos de cocina de cada semana |
| `portions` | entero de 0 a 840 | porciones de cada semana (0 por defecto) |
| `serviceTotalCents` | entero de 0 a 10 000 000 | el precio del servicio de **todo** el presupuesto; se reparte en centavos entre las semanas (los que sobran, a las primeras). Obligatorio salvo en el `dryRun`; 0 vale |
| `dryRun` | boolean | `true`: el estado de cada fecha, sin escribir nada |

Una clave que el contrato no tiene es `payload: "invalid"` (como en `/translate` y `/menus/*`: lo arma solo la app). No hay `type`, `clientId` ni `newClient`: es siempre el pedido, con su tipo.

Respuesta `201` (en el `dryRun`, `200`):

```json
{ "dryRun": false, "quoteId": "uuid", "requestId": "uuid", "clientId": "uuid", "holdUntil": "2026-11-23T10:00:00.123456+00:00",
  "weeks": [ { "date": "2026-11-30", "start": "10:00", "cookMinutes": 240, "status": "free", "suggestedStart": null,
               "serviceCents": 14000, "sessionId": "uuid" } ] }
```

- Crea una sesión `held` por semana (`pay_mode` manual), con su parte del precio, y el presupuesto sin enviar, con la versión siguiente a la última que salió del pedido (la 1 si no salió ninguna: un borrador que venció o se retiró sin salir no gasta número, y la clienta ve la versión 1 en su primer presupuesto). El pedido sigue `new` (queda visto). La página de la clienta no muestra las semanas de un borrador.
- `holdUntil`: el borrador retiene el horario 24 h, nunca más allá de la llegada de la primera semana. Al salir con el menú, el plazo pasa a ser el de la clienta: `quote_hold_hours` (48 h) desde el envío, tampoco más allá de esa llegada.
- `weeks`: en el `dryRun`, el estado de cada fecha como en `/bookings` (`busy`, `past`, `blocked`, `closed`, `outside`, `ok`, con `suggestedStart`; solo `busy` impide crearlo) y `quoteId`, `holdUntil` y `sessionId` en null. Creado, cada semana con su sesión y `status: "free"` (retenida; los avisos eran los del `dryRun`).
- Todo o nada: si una semana choca no se crea ninguna (`409 slotTaken` / `weekTaken` con la fecha).

### `POST /quotes/price`: otro precio

Cuerpo `{ "quoteId": uuid, "serviceTotalCents": 0 a 10 000 000 }` (los dos obligatorios). Respuesta `200`, los términos de ahora (`private.quote_terms`):

```json
{ "quoteId": "uuid", "totalCents": 42001,
  "weeks": [ { "sessionId": "uuid", "date": "2026-11-30", "start": "10:00", "cookMinutes": 240, "serviceCents": 10501 } ] }
```

Se reparte entre las semanas vivas. Si ya salió, hay que volver a mandarlo: hasta entonces la página de la clienta lo muestra como cambiado y no se acepta, y una vista previa armada antes ya no sale (`409 quoteChanged`). Una respuesta de la base con otro total o de otro presupuesto da `500`.

### `POST /quotes/withdraw`: retirarlo

Cuerpo `{ "quoteId": uuid }`. Respuesta `200 { "quoteId", "requestId", "already", "cancelled" }`: sus semanas `held` se cancelan (`quote_withdrawn`), el presupuesto queda retirado y el pedido vuelve a `new` (para preparar otro o rechazarlo; para confirmar sin presupuesto no hace falta retirarlo antes: `/bookings` lo retira, §4). Idempotente: uno ya retirado da `already: true` y `cancelled: 0`. Si después se confirma la reserva sin él, la página de la clienta deja de mostrarlo (contrato client-link §4).

### Errores (además de los comunes, §3)

| HTTP | Cuerpo | Ruta | Cuándo |
|---|---|---|---|
| 400 | `{ "errors": { campo: código } }` (con `date` en un error de una fecha) | las tres | el cuerpo no cumple, o una validación de la base (`dates: "weeksOnlyForWeek"`, `cents: "range"`, …); no se escribió nada |
| 404 | `requestNotFound` | quotes | el pedido no es de esta cocina |
| 404 | `quoteNotFound` | price, withdraw | el presupuesto no es de esta cocina |
| 409 | `requestNotNew` (con `status`) | quotes | el pedido ya no está `new` |
| 409 | `requestNotQuotable` | quotes | un pedido de cambios |
| 409 | `quoteExists` | quotes | ya tiene un presupuesto abierto: retirarlo antes |
| 409 | `slotTaken` / `weekTaken` (con `date`) | quotes | la semana de esa fecha choca; no se crea ninguna |
| 409 | `quoteClosed` | price, withdraw | ya está aceptado, rechazado o vencido (y, en price, retirado) |
| 409 | `quoteEmpty` | price | no le quedan semanas vivas |
| 500 | `server` | las tres | `chef_not_found`, una respuesta con otra forma o un error que no se puede reintentar |
| 503 | `unavailable` | las tres | la base no respondió |

Los de la base (§7): `P0002 request_not_found`, `quote_not_found` → `404`; `55000 request_not_new` (detalle: el estado), `quote_exists`, `quote_closed`, `quote_empty` → `409`; `22023 invalid_request_type` → `409 requestNotQuotable`; los demás `22023` (`invalid_dates`, `dates_same_week`, `invalid_start`, `invalid_cook_minutes`, `invalid_portions`, `invalid_cents`, `weeks_only_for_week`) → `400` con su campo; `23P01 slot_taken` y `23505 week_taken` → `409` con la fecha; `P0002 chef_not_found` → `500`.

### Logs

`quote_created` (`requestId`, `quoteId`, `sessions`, `userId`), `quote_priced` (`quoteId`, `weeks`, `userId`) y `quote_withdrawn` (`quoteId`, `requestId`, `already`, `cancelled`, `userId`); los errores, como en las otras rutas (`rejected`, `db_error`, `invalid_payload`, `unexpected_result`). Nunca importes, fechas ni datos de la clienta (§10).
