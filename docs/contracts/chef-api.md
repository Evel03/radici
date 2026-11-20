# Contrato: área de Evelyn, Edge Function `chef`

Estado: implementado el 16/11/2026 (plan del área de Evelyn, PR 4), sobre la base de reservas del PR 3 (migraciones `20261116150000_pay_mode_manual.sql` y `20261116150100_bookings.sql`, pgTAP `13_bookings`). Desde el mismo día la llaman también los colaboradores de la cocinera (migración `20261116190000_chef_members.sql`, pgTAP `15_chef_members`; §2).
Código del contrato: `supabase/functions/_shared/chef_api.ts` (tipos de los cuerpos y de las respuestas, y la validación; tests en `chef_api.test.ts`). La función: `supabase/functions/chef/` (`handler.ts`, con sus tests en `handler.test.ts`, `index.ts` y, para la traducción, `translation.ts` con `translation.test.ts` y `claude_translator.ts`). Si este documento y el código difieren, manda el código.
Actualizado el 19/11/2026: Evelyn no hace la compra (la hace el cliente, con la lista de ingredientes y cantidades que ella le manda). `POST /bookings` ya no tiene `groceriesEstCents`: si llega (la app de antes lo manda), se ignora como cualquier otra clave que el contrato no tiene, valga lo que valga, y la función le pasa siempre `p_groceries_est_cents: 0` a `chef_create_booking`, cuya firma no cambia (§4, §7). Sin compra, `chef_settings.shop_minutes` es 0 (migración `20261119090000_sin_compra.sql`): la llegada sugerida de un día de 9:00 a 15:00 es las 9:00.
Actualizado el 20/11/2026: `POST /translate` traduce un plato del español al italiano y al inglés con Claude (§12), sobre la migración `20261120090000_recipe_translations.sql` (`recipes.auto_translated`, pgTAP `18_recipe_translations`).

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
- Orden de los chequeos: CORS → ruta (`404`) → método (`405`) → configuración (`500`) → token (`401`) → usuario (`401` o `503`) → su cocina (`403`) → tipo (`415`) → tamaño (`413`) → JSON y validación (`400`) → función SQL (en `/translate`, el traductor: §12). Sin un token válido de la cocinera o de un colaborador suyo no se lee ni el cuerpo.
- Fechas `"AAAA-MM-DD"` (fechas de negocio en Roma) y horas `"HH:MM"` (hora de Roma). Dinero en centavos enteros: `14050` es 140,50 €; un número con decimales es `invalid`.
- Respuestas en JSON con `Cache-Control: no-store`.

| Código | Cuerpo | Cuándo |
|---|---|---|
| 200 / 201 | según la ruta | §4, §5, §6 y §12 |
| 400 | `{ "errors": { campo: código } }`, más `"date"` cuando el error es de una fecha concreta (de `dates`: fuera de rango, misma semana u orden) | validación de la función o, como defensa, de la base (§7) |
| 401 | `{ "error": "unauthorized" }` y `WWW-Authenticate: Bearer` | sin token, token que no es un JWT o que Auth rechaza (vencido, sesión cerrada). Sin `Authorization`, o con un JWT que no valida, responde la plataforma con su propio cuerpo |
| 403 | `{ "error": "forbidden" }` | usuario válido que no es la cocinera ni un colaborador suyo |
| 404 | `{ "error": "notFound" }` | ruta desconocida |
| 404 | `{ "error": "requestNotFound" \| "clientNotFound" \| "sessionNotFound" }` | el pedido, la ficha o la sesión no existen para esta cocinera |
| 405 | `{ "error": "method" }` y `Allow: POST, OPTIONS` | otro método |
| 409 | ver abajo | choques y estados que no lo permiten; no se escribió nada |
| 413 / 415 | `{ "error": "tooLarge" \| "contentType" }` | cuerpo de más de 8 KB o que no es JSON |
| 422 | `{ "error": "untranslatable" }` | solo `/translate`: este plato no se pudo traducir (una negativa, un corte o una salida que no sirve; §12). Reintentar igual no sirve |
| 429 | `{ "error": "rateLimited" }` y `Retry-After: 3600` | solo `/translate`: la cocina pasó su límite de traducciones (§12). La app no reintenta sola |
| 500 | `{ "error": "server" }` | configuración rota o error inesperado (el log lleva el código, §10) |
| 501 | `{ "error": "notConfigured" }` | solo `/translate`: la traducción está apagada (sin `ANTHROPIC_API_KEY`; §12) |
| 503 | `{ "error": "unavailable" }` | Auth o la base no responden, o un error que se puede reintentar: reintentar con la misma `requestKey`. En `/translate`, Claude no respondió a tiempo o dio un error que se puede reintentar (§12) |

Los 409:

| Cuerpo | Cuándo |
|---|---|
| `{ "error": "slotTaken", "date": "AAAA-MM-DD" }` | la semana de esa fecha choca con otra sesión (`no_overlap`). En una reserva no se crea ninguna semana |
| `{ "error": "weekTaken", "date": "AAAA-MM-DD" }` | esa semana ya tiene otra sesión viva de la misma reserva (una por semana). Al mover, la app ofrece pasarla al final de la reserva |
| `{ "error": "requestNotNew", "status": "accepted" }` | el pedido ya no está `new` y no es un reintento; `status` es su estado actual |
| `{ "error": "sessionNotMovable", "status": "cooked" }` | solo se mueve una sesión `held` o `confirmed`; `status` es el actual |
| `{ "error": "invalidTransition", "sessionId": uuid }` | al cancelar, esa sesión está `cooked` o `paid`; no se cancela ninguna |
| `{ "error": "hasPayments", "sessionIds": [uuid] }` | al cancelar sin `allowWithPayments`, esas semanas ya están cobradas; no se cancela ninguna (§6) |
| `{ "error": "conflict" }` | otro choque (no debería pasar) |

Códigos de los 400 (`ChefApiErrorCode`): `required`, `invalid` (tipo o formato; un número que no es entero), `range`, `tooLong`, `dateOutOfRange`, `sameWeek`, `order`, `weeksOnlyForWeek` y `conflict`. Los campos de un objeto van con punto (`newClient.name`, `household.meals`); `client`, `people` y `cents` agrupan varios. `payload` es el cuerpo entero (no es JSON, no es un objeto o, en `/translate`, trae una clave de más).

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
| `busy` | choca con otra sesión: la misma cuenta que `no_overlap` |
| `past` | la fecha ya pasó (hoy no cuenta como pasado) |
| `blocked` | día bloqueado (puede ser justo el que Evelyn bloqueó por la sesión acordada) |
| `closed` | ese día de la semana no tiene horario |
| `outside` | la compra empieza antes de la apertura o la cocina termina después del cierre |
| `ok` | todo bien |

### Reglas

- **Desde un pedido** (`requestId`): el pedido tiene que estar `new` (si no, `409 requestNotNew`, también en el `dryRun`). Pasa a `accepted`, con `weeks` = las semanas creadas y `seen_at`; la ficha, de `prospect` a `trial`.
- **A mano** (`clientId` o `newClient`): crea el pedido (`source = 'app'`, `accepted`) y, si es nueva, la ficha (`trial`, `pay_mode manual`). Una ficha existente no se modifica, salvo el paso de `prospect` a `trial`.
- **Todo o nada**: si una semana choca no se crea ninguna, tampoco el pedido ni la ficha (`409` con la fecha).
- **Idempotencia**: la app genera una `requestKey` nueva por cada confirmación y la repite en sus reintentos (botón deshabilitado mientras envía). A mano, la misma clave devuelve la reserva guardada con `duplicate: true` sin crear nada; es única por cocinera y compartida con las de la web (una clave ya usada por un pedido de la web da `400 requestKey: "conflict"`). Desde un pedido, el reintento se reconoce por el estado: el pedido ya `accepted` con esas mismas fechas y hora devuelve lo mismo con `duplicate: true`.
- **`dryRun`**: valida todo igual (también el estado del pedido) y no escribe nada.

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

- `public.chef_create_booking(p_chef_id, p_dates, p_start, p_cook_minutes, p_service_total_cents, p_portions, p_groceries_est_cents, p_request_id, p_client_id, p_new_client, p_type, p_household, p_locale, p_request_key, p_dry_run) → jsonb`. `p_service_total_cents` no tiene valor por defecto (null es `invalid_cents`). `p_groceries_est_cents` sigue en la firma, pero la Edge Function le pasa siempre 0 (sin compra desde el 19/11/2026); la columna `sessions.groceries_est_cents` queda en 0 en las reservas nuevas.
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
| `22023` con un código propio (`invalid_dates`, `dates_same_week`, `invalid_household`, `request_key_conflict`, …) | `400` con su campo; un código desconocido, `payload: "invalid"` |
| otro dato inválido (`22xxx`), `23514` o `23502` | `400 payload: "invalid"` |
| sin código (la base no respondió), `08xxx`, `40xxx`, `53xxx`, `57xxx`, `58xxx` o `PGRST000`–`PGRST003` | `503` |
| cualquier otro (por ejemplo `PGRST202`: la función SQL no existe, la migración no está desplegada) | `500` |

De un error de la base solo se usan el código, el mensaje si es un código propio en snake_case y el detalle si tiene la forma esperada (una fecha, un estado, un uuid o una lista de hasta 100 uuid). El mensaje y el detalle de Postgres pueden traer la fila, con datos personales: nunca pasan ni a la respuesta ni al log.

## 8. Configuración

| Nombre | De dónde | Nota |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_SECRET_KEYS` (o las variables de compatibilidad) | las pone Supabase | sin ellas, `500` y `config_missing` |
| `ALLOWED_ORIGINS` | secreto de las funciones, compartido con `public-request`; lo carga `deploy-supabase.yml` | CORS (§2). Sin ella, `/gestione/` no puede llamar a la función (la app nativa sí) y el arranque avisa `config_incomplete` |
| `ANTHROPIC_API_KEY` | secreto de las funciones (opcional); lo carga `deploy-supabase.yml` desde el secreto de GitHub del mismo nombre | la clave de Claude para `/translate` (§12). Sin ella, `/translate` responde `501` y el arranque avisa `config_incomplete`. Nunca se loguea. Borrar el secreto de GitHub no la saca de Supabase (el despliegue no pisa ni borra lo que ya está): para apagar la traducción, `supabase secrets unset ANTHROPIC_API_KEY --project-ref <ref>` |
| `TRANSLATE_TRANSPORT` | solo en local (`.env.example` trae `fake`) | `fake`: `/translate` devuelve una traducción de mentira (`"[it] <nombre>"`) sin llamar a Claude, aunque haya clave; el arranque avisa `translate_fake`. Vale solo con un Supabase local (`SUPABASE_URL` en `kong`, `localhost` o `127.0.0.1`): en otro lado se ignora, el arranque loguea el error `translate_fake_ignored` y `/translate` responde `501`. El despliegue no la carga y corta si la encuentra en los secretos de Supabase |

En local, `npx supabase start` sirve la función con `verify_jwt` de `config.toml` y lee `ALLOWED_ORIGINS` y las de la traducción de `supabase/functions/.env` (copiado de `.env.example`); para `/gestione/` con `flutter run -d web-server --web-port 8080` hay que sumar `http://localhost:8080` (desde el teléfono, `http://<IP de la PC>:8080`).

## 9. Despliegue

- `deploy-supabase.yml`, paso «Desplegar chef»: `supabase functions deploy chef --use-api`, después de `db push` (llama a las funciones de la migración de reservas) y de cargar los secretos (`ALLOWED_ORIGINS` y, si está, `ANTHROPIC_API_KEY`; sin ella, ni en GitHub ni en Supabase, el paso de los secretos avisa que la traducción queda apagada, sin cortar el despliegue; si está en Supabase y no en GitHub, avisa que sigue prendida y cómo borrarla). El mismo paso corta si no puede leer la lista de secretos de Supabase o si encuentra `TRANSLATE_TRANSPORT`. `verify_jwt = true` sale de `config.toml`. Avisa si `ALLOWED_ORIGINS` tiene orígenes además del de `PUBLIC_SITE_URL`.
- Orden: la migración de reservas va en su propio PR (PR 3) y se despliega antes (contrato public-request §8). Sin ella, cada llamada da `500` y el log dice `PGRST202`.
- Antes del primer despliegue: limpiar `ALLOWED_ORIGINS` (§2).
- Se acepta cuando, desplegada, una reserva de 4 semanas hecha con el token de una sesión de prueba crea 4 sesiones, y un reintento con la misma clave no crea nada más.

## 10. Logs

Solo evento, ruta, códigos, contadores, largos, duraciones e ids. Nunca nombres, teléfonos, emails, zonas, direcciones, notas, restricciones, fechas, tokens, el texto de un plato ni la clave de Anthropic. Los tests lo comprueban con un espía en todos los caminos del handler: cada evento de esta tabla (salvo `config_incomplete`, `translate_fake` y `translate_fake_ignored`, que escribe `index.ts` al arrancar, solo con nombres de variables), también con errores de la base que traen la fila, una respuesta de la base que lanza al leerla, un cuerpo que se corta mientras se lee y un traductor que explota o repite el plato en su salida.

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
| `translated` | `route`, `ms` (lo que tardó el traductor), `nameLength`, `descriptionLength` (o null), `userId` |
| `translate_failed` | `route`, `reason` (§12), `category` (de una negativa) o `apiStatus` (el estado HTTP de Anthropic), `ms`, `nameLength`, `descriptionLength`. `warn` para una negativa, un corte por `max_tokens` o la traducción apagada sin clave; `error` para el resto (también `fakeIgnored`) |
| `rate_limited` | `route`, `userId` |
| `db_error` | `op`, `code` y, si lo hay, `message` (el código propio) |
| `unexpected_result` | `op` (también `load_chef`, si `chef_id_for_user` responde algo que no es un uuid ni null) |
| `unexpected_error` | `error` (el tipo, nunca el mensaje) |
| `config_missing`, `config_incomplete` | `missing` (nombres de variables) |
| `translate_fake` | ninguno: `TRANSLATE_TRANSPORT=fake` al arrancar, con un Supabase local |
| `translate_fake_ignored` | ninguno (nivel `error`): `TRANSLATE_TRANSPORT=fake` fuera de un Supabase local, ignorado |

`userId` es el usuario del token: la cocinera o el colaborador que hizo el cambio (con colaboradores, la cocina son varias cuentas; SPEC §6).

## 11. Pruebas

- `npm test`: `supabase/functions/_shared/chef_api.test.ts` (validación), `supabase/functions/chef/handler.test.ts` (401 antes de leer el cuerpo, 403, un colaborador que entra con la cocina de ella y queda en los logs con su propio `userId`, una cocina con otra forma → 500, 400 por campo, 409 con la fecha o las sesiones cobradas, `dryRun` que no escribe, reintento con la misma clave, la cocinera siempre del token, que `index.ts` use `chef_id_for_user` y le pase su respuesta tal cual al handler, errores de la base, `/translate` con un traductor simulado y el espía de logs), `supabase/functions/chef/translation.test.ts` (el pedido a Claude, el prompt, el esquema, la lectura de la respuesta, la validación de la salida, el límite y el traductor de mentira) y el paso del workflow en `supabase/scripts/deploy-supabase.test.ts`. `claude_translator.ts` no corre en Node (importa el SDK): `handler.test.ts` mira su texto (la versión fija del SDK, las opciones del cliente, el pedido, la señal del tope y que le pase sus clases de error a `failureFrom`, que `translation.test.ts` prueba con clases de mentira) y que ni `handler.ts` ni `index.ts` lo importen al arrancar. CI corre además `deno check` de las dos funciones y de `claude_translator.ts`, con el SDK y supabase-js reales (job `edge-functions`).
- pgTAP `13_bookings`: las funciones SQL (reparto, chequeos y su prioridad, choques, reintentos, transiciones, mover, cancelar con y sin cobros, y permisos, también que la app no borra fichas). `15_chef_members`: `chef_id_for_user` (quién es de qué cocina, solo `service_role`) y lo que ve y hace un colaborador. `18_recipe_translations`: `recipes.auto_translated`, su fuente en español y la clave de `save_recipe`.
- En local, de punta a punta: `npx supabase start` (con `-x` se pueden dejar afuera los servicios que no hacen falta: alcanza con la base, Kong, Auth, PostgREST y el runtime de funciones), un token con `POST /auth/v1/token?grant_type=password` para `evelyn@example.test` (la contraseña del seed) y las llamadas a `/functions/v1/chef/…`. Con `marco@example.test`, su colaborador en el seed, las mismas llamadas actúan sobre la cocina de Evelyn. `POST /functions/v1/chef/translate` con `TRANSLATE_TRANSPORT=fake` (lo que trae `.env.example`) devuelve la traducción de mentira sin llamar a Claude.

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
