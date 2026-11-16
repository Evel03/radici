# Contrato: área de Evelyn, Edge Function `chef`

Estado: implementado el 16/11/2026 (plan del área de Evelyn, PR 4), sobre la base de reservas del PR 3 (migraciones `20261116150000_pay_mode_manual.sql` y `20261116150100_bookings.sql`, pgTAP `13_bookings`). Desde el mismo día la llaman también los colaboradores de la cocinera (migración `20261116190000_chef_members.sql`, pgTAP `15_chef_members`; §2).
Código del contrato: `supabase/functions/_shared/chef_api.ts` (tipos de los cuerpos y de las respuestas, y la validación; tests en `chef_api.test.ts`). La función: `supabase/functions/chef/` (`handler.ts`, con sus tests en `handler.test.ts`, e `index.ts`). Si este documento y el código difieren, manda el código.

## 1. Para qué

- Es la única puerta de la app de Evelyn para crear, mover y cancelar sesiones: los estados de sesión solo cambian vía Edge Functions, nunca desde la app (CLAUDE.md). La app no tiene privilegios sobre esas filas, ni puede borrar pedidos o fichas (borrar una ficha se llevaba en cascada su reserva); la función llama a las funciones SQL `chef_*`, que solo ejecuta `service_role`.
- Una reserva es un pedido aceptado más sus sesiones: una sesión `confirmed` por semana, de 1 a 8 semanas, con `pay_mode = 'manual'` (SPEC §4 y §5.3). Hasta M4 nace sin presupuesto ni retención de 48 h.
- Rutas (todas `POST https://<ref>.supabase.co/functions/v1/chef/<ruta>`):

| Ruta | Función SQL | Qué hace |
|---|---|---|
| `/bookings` | `chef_create_booking` | confirmar una reserva, desde un pedido o a mano (§4) |
| `/sessions/move` | `chef_move_session` | mover una semana (§5) |
| `/sessions/cancel` | `chef_cancel_sessions` | cancelar una o varias semanas (§6) |

  Con el plan crecen: `/sessions/receipts` y `/receipts/remove` (PR 9a, tickets), `/sessions/cooked`, `/sessions/uncook`, `/payments`, `/payments/void` y `/payments/refund` (PR 10a, «Cociné» y cobros).

## 2. Autenticación y CORS

- `verify_jwt = true` (`[functions.chef]` en `supabase/config.toml`): la plataforma rechaza con `401` un pedido sin `Authorization` o con un JWT que no valida (antes de llegar a la función, con su propio cuerpo). Ese chequeo acepta los JWT firmados con las claves asimétricas nuevas y los HS256 viejos, pero también deja pasar las claves de API (`sb_publishable_…`, `sb_secret_…`) y un JWT sin usuario (la clave `anon` vieja). Por eso la función, además:
  1. toma el token de `Authorization: Bearer <token>` y exige que sea un JWT (tres partes base64url, hasta 8 KB). Una clave de API da `401` sin llamar a Auth;
  2. lo valida con Auth (`auth.getUser`): firma, vencimiento y que la sesión siga abierta. Si Auth lo rechaza (4xx), `401`; si no responde (429, 5xx o red), `503`;
  3. busca la cocina del usuario con `public.chef_id_for_user` (migración `20261116190000_chef_members.sql`, solo `service_role`): la de la que es dueña (`chefs.profile_id`) o colaborador (`chef_members`). Es la misma regla de la RLS (`current_chef_id()` la usa con `auth.uid()`). Si no es de ninguna, `403`; una respuesta con otra forma (ni un uuid ni null), `500` y `unexpected_result`.
- Quién llama: la cocinera o un colaborador suyo (SPEC §1 y §6), cada uno con su sesión. Un colaborador hace lo mismo que ella con la cocina de ella: las funciones SQL reciben el mismo `chef_id`. Sale de la lista (`CHEF_MEMBER_EMAILS`, contrato public-request §10.1) y pierde el acceso en el acto: su cuenta se borra y Auth rechaza su token (`401`), y si la cuenta queda (la de una ficha de cliente), `chef_id_for_user` ya no le da cocina (`403`).
- Las funciones SQL reciben siempre el `chef_id` que sale del token, nunca uno del cuerpo.
- La app llama con `functions.invoke('chef/bookings', body: …)` (supabase-js o supabase_flutter), que manda `Authorization: Bearer <access token de la sesión>` y `apikey: <clave publicable>`. Para que la función corra en Frankfurt, como la web (contrato public-request §2), va `?forceFunctionRegion=eu-central-1` en la URL; la cabecera `x-region` no, porque CORS no la permite.
- CORS: `ALLOWED_ORIGINS`, **la misma variable que `public-request`** (contrato public-request §4). El preflight permite `POST, OPTIONS` y las cabeceras de supabase-js (`authorization`, `x-client-info`, `apikey`, `content-type`, …). Un origen que no está en la lista no recibe cabeceras CORS: el navegador no deja pasar la llamada. La app nativa no manda `Origin` y no la afecta.
- **Cualquier origen de `ALLOWED_ORIGINS` puede llamar a esta función con la sesión de Evelyn** (o de un colaborador suyo), si entró a `/gestione/` desde ese origen. La lista tiene que tener solo `https://radicicucina.app`. Antes del primer despliegue de `chef` hay que sacar `https://radici.sepusola10.com` (Paso 0.3 del plan): redirigir o sacar de Pages el dominio viejo, dejar la variable solo con el dominio nuevo, volver a correr Deploy Supabase y sacar el hostname viejo del widget de Turnstile. El despliegue avisa si `ALLOWED_ORIGINS` tiene orígenes además del de `PUBLIC_SITE_URL` (§9).

## 3. Formato común

- `POST` con `Content-Type: application/json` y un cuerpo de hasta 8 KB (`CHEF_MAX_PAYLOAD_BYTES`).
- Orden de los chequeos: CORS → ruta (`404`) → método (`405`) → configuración (`500`) → token (`401`) → usuario (`401` o `503`) → su cocina (`403`) → tipo (`415`) → tamaño (`413`) → JSON y validación (`400`) → función SQL. Sin un token válido de la cocinera o de un colaborador suyo no se lee ni el cuerpo.
- Fechas `"AAAA-MM-DD"` (fechas de negocio en Roma) y horas `"HH:MM"` (hora de Roma). Dinero en centavos enteros: `14050` es 140,50 €; un número con decimales es `invalid`.
- Respuestas en JSON con `Cache-Control: no-store`.

| Código | Cuerpo | Cuándo |
|---|---|---|
| 200 / 201 | según la ruta | §4, §5 y §6 |
| 400 | `{ "errors": { campo: código } }`, más `"date"` cuando el error es de una fecha concreta (de `dates`: fuera de rango, misma semana u orden) | validación de la función o, como defensa, de la base (§7) |
| 401 | `{ "error": "unauthorized" }` y `WWW-Authenticate: Bearer` | sin token, token que no es un JWT o que Auth rechaza (vencido, sesión cerrada). Sin `Authorization`, o con un JWT que no valida, responde la plataforma con su propio cuerpo |
| 403 | `{ "error": "forbidden" }` | usuario válido que no es la cocinera ni un colaborador suyo |
| 404 | `{ "error": "notFound" }` | ruta desconocida |
| 404 | `{ "error": "requestNotFound" \| "clientNotFound" \| "sessionNotFound" }` | el pedido, la ficha o la sesión no existen para esta cocinera |
| 405 | `{ "error": "method" }` y `Allow: POST, OPTIONS` | otro método |
| 409 | ver abajo | choques y estados que no lo permiten; no se escribió nada |
| 413 / 415 | `{ "error": "tooLarge" \| "contentType" }` | cuerpo de más de 8 KB o que no es JSON |
| 500 | `{ "error": "server" }` | configuración rota o error inesperado (el log lleva el código, §10) |
| 503 | `{ "error": "unavailable" }` | Auth o la base no responden, o un error que se puede reintentar: reintentar con la misma `requestKey` |

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

Códigos de los 400 (`ChefApiErrorCode`): `required`, `invalid` (tipo o formato; un número que no es entero), `range`, `tooLong`, `dateOutOfRange`, `sameWeek`, `order`, `weeksOnlyForWeek` y `conflict`. Los campos de un objeto van con punto (`newClient.name`, `household.meals`); `client`, `people` y `cents` agrupan varios.

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
| `groceriesEstCents` | entero de 0 a 10 000 000 | compra estimada de cada semana (0 por defecto). La compra va aparte, al costo del ticket |
| `serviceTotalCents` | entero de 0 a 10 000 000 | precio del servicio de **toda** la reserva, que fija Evelyn. **Obligatorio** salvo en el `dryRun` (`required`): ninguna ruta lo cambia después. `0` vale (sin cargo); en un `dryRun` sin precio las semanas salen con 0. Se reparte en centavos entre las semanas: los que sobran van a las primeras (500 € en 3 son 166,67 + 166,67 + 166,66) |
| `requestKey` | uuid | idempotencia. Obligatoria a mano salvo en el `dryRun`; desde un pedido es opcional (ver abajo) |
| `dryRun` | boolean | `true`: solo devuelve el estado de cada fecha, sin escribir nada |

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
      "suggestedStart": "10:00", "serviceCents": 14000, "sessionId": "uuid" }
  ]
}
```

- `weeks`: las semanas vivas de la reserva en orden de fecha (en el `dryRun`, las pedidas, con `sessionId: null`).
- `requestId` es null en el `dryRun` de una reserva a mano; `clientId`, en el `dryRun` de una ficha nueva. `start` es null solo en un `dryRun` sin hora para un día sin horario.
- `suggestedStart`: la primera llegada del día, la misma que ofrece el calendario de la web (apertura + compra, redondeada a la media hora siguiente); null si ese día no tiene horario.
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
  "cookMinutes": 200, "status": "ok", "suggestedStart": "10:00", "weekTaken": false }
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

- `public.chef_create_booking(p_chef_id, p_dates, p_start, p_cook_minutes, p_service_total_cents, p_portions, p_groceries_est_cents, p_request_id, p_client_id, p_new_client, p_type, p_household, p_locale, p_request_key, p_dry_run) → jsonb`. `p_service_total_cents` no tiene valor por defecto (null es `invalid_cents`).
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

No tiene secretos propios. En local, `npx supabase start` sirve la función con `verify_jwt` de `config.toml` y lee `ALLOWED_ORIGINS` de `supabase/functions/.env` (copiado de `.env.example`); para `/gestione/` con `flutter run -d web-server --web-port 8080` hay que sumar `http://localhost:8080` (desde el teléfono, `http://<IP de la PC>:8080`).

## 9. Despliegue

- `deploy-supabase.yml`, paso «Desplegar chef»: `supabase functions deploy chef --use-api`, después de `db push` (llama a las funciones de la migración de reservas) y de cargar los secretos (`ALLOWED_ORIGINS`). `verify_jwt = true` sale de `config.toml`. Avisa si `ALLOWED_ORIGINS` tiene orígenes además del de `PUBLIC_SITE_URL`.
- Orden: la migración de reservas va en su propio PR (PR 3) y se despliega antes (contrato public-request §8). Sin ella, cada llamada da `500` y el log dice `PGRST202`.
- Antes del primer despliegue: limpiar `ALLOWED_ORIGINS` (§2).
- Se acepta cuando, desplegada, una reserva de 4 semanas hecha con el token de una sesión de prueba crea 4 sesiones, y un reintento con la misma clave no crea nada más.

## 10. Logs

Solo evento, ruta, códigos, contadores e ids. Nunca nombres, teléfonos, emails, zonas, direcciones, notas, restricciones, fechas ni tokens. Los tests lo comprueban con un espía en todos los caminos del handler: cada evento de esta tabla (salvo `config_incomplete`, que escribe `index.ts` al arrancar, solo con nombres de variables), también con errores de la base que traen la fila, una respuesta de la base que lanza al leerla y un cuerpo que se corta mientras se lee.

| Evento | Campos |
|---|---|
| `auth_rejected` | `route`, `reason`: `missing`, `malformed` o `invalid` |
| `forbidden` | `route`, `userId` |
| `invalid_payload` | `route`, `fields` (los nombres de los campos con error) |
| `rejected` | `route`, `status`, `error`, `code` (SQLSTATE), `message` (el código propio) |
| `booking_created` | `requestId`, `sessions`, `client` (`request`, `client` o `newClient`) |
| `booking_duplicate` | `requestId` |
| `session_moved` | `sessionId` |
| `sessions_cancelled` | `cancelled`, `alreadyCancelled`, `withPayments` (cantidades) |
| `db_error` | `op`, `code` y, si lo hay, `message` (el código propio) |
| `unexpected_result` | `op` (también `load_chef`, si `chef_id_for_user` responde algo que no es un uuid ni null) |
| `unexpected_error` | `error` (el tipo, nunca el mensaje) |
| `config_missing`, `config_incomplete` | `missing` (nombres de variables) |

## 11. Pruebas

- `npm test`: `supabase/functions/_shared/chef_api.test.ts` (validación), `supabase/functions/chef/handler.test.ts` (401 antes de leer el cuerpo, 403, un colaborador que entra con la cocina de ella, una cocina con otra forma → 500, 400 por campo, 409 con la fecha o las sesiones cobradas, `dryRun` que no escribe, reintento con la misma clave, la cocinera siempre del token, que `index.ts` use `chef_id_for_user`, errores de la base y el espía de logs) y el paso del workflow en `supabase/scripts/deploy-supabase.test.ts`.
- pgTAP `13_bookings`: las funciones SQL (reparto, chequeos y su prioridad, choques, reintentos, transiciones, mover, cancelar con y sin cobros, y permisos, también que la app no borra fichas). `15_chef_members`: `chef_id_for_user` (quién es de qué cocina, solo `service_role`) y lo que ve y hace un colaborador.
- En local, de punta a punta: `npx supabase start` (con `-x` se pueden dejar afuera los servicios que no hacen falta: alcanza con la base, Kong, Auth, PostgREST y el runtime de funciones), un token con `POST /auth/v1/token?grant_type=password` para `evelyn@example.test` (la contraseña del seed) y las llamadas a `/functions/v1/chef/…`. Con `marco@example.test`, su colaborador en el seed, las mismas llamadas actúan sobre la cocina de Evelyn.
