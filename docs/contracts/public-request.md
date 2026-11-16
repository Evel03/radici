# Contrato: pedido desde la web, bandeja de Evelyn y notificaciones

Estado: aprobado por Nicolas el 19/10/2026 (reemplaza el envío por WhatsApp de la Fase 0).
Actualizado el 19/10/2026 para reflejar lo implementado: idempotencia con `requestKey`, `CHEF_ID` opcional, borrado diario de prospectos vencidos (§9), avisos a Evelyn en español por defecto y vistas previas fuera de `ALLOWED_ORIGINS`.
Actualizado el 19/10/2026 después de la revisión de seguridad y privacidad: un envío sin login nunca modifica a una persona existente (copia del contacto en cada pedido, §3), `duplicate: true` en los reintentos (§2), Evelyn creada confirmada antes de publicar y altas apagadas (§8, §10), "Segna come cliente" en la app (§7, §9) y procedimientos de arranque y de derechos (§10).
Código del contrato: `supabase/functions/_shared/public_request.ts` (tipos, validación y normalización; tests en `public_request.test.ts`). Si este documento y ese archivo difieren, manda el archivo.
Actualizado el 15/11/2026: el formulario de la web ya no pide alergias, intolerancias ni dietas (datos de salud); Evelyn las ve con el cliente cuando lo contacta. El contrato conserva `allergens`, `diets`, `restrictionsNote` y `consents.health`: la web los manda vacíos (`consents.health` en `null`) y la función los sigue aceptando.
Actualizado el 15/11/2026: disponibilidad por día para el calendario del formulario (`GET …/public-request/availability`, §11), con las funciones de horarios libres de la base y el horario inicial de lunes a viernes de 9 a 15. El formulario ya no pregunta la franja horaria (manda `slot: "any"`). La privacy cuenta esas consultas (§6).
Actualizado el 15/11/2026: el formulario vuelve a preguntar por las alergias e intolerancias. Versión 2 del contrato (el servidor acepta solo la 2): campo `noAllergies` (§2) — el cliente confirma que nadie de quienes van a comer, niños incluidos, tiene, o las escribe en `restrictionsNote` con el consentimiento de salud —, guardado en `requests.no_allergies` (§3); emails con tres casos (§5). Privacy y consentimientos de la versión `2026-11-16`, que también cuenta las consultas del calendario (§6).
Actualizado el 15/11/2026: el día preferido se elige de mañana a 8 semanas (56 días) y no a 14, en el formulario (`DATE_WINDOW`, §2), en la disponibilidad del calendario (§11) y en la base (`booking_horizon_days`, §11.1). Sin cambio de versión del contrato ni de la respuesta de disponibilidad: mientras se despliega, ninguna combinación de web y función rompe el calendario (§11, §8).
Actualizado el 16/11/2026: precio por semana (SPEC §5.1). Versión 3 del contrato: el pedido semanal es de 1 a 8 semanas (`weeks`, obligatorio en la 3) y la estimación del 201 trae el precio por semana o dice que no hay precio automático (§2, «Semanas y estimación»). El servidor acepta la 3 y la 2 (una página de antes es de una semana) y guarda las semanas en `requests.weeks` (§3). Emails (§5), web (§6), app (§7) y despliegue en dos PR (§8).
Actualizado el 16/11/2026: la Edge Function `chef` (área de Evelyn, contrato `docs/contracts/chef-api.md`) comparte `ALLOWED_ORIGINS` (§4) y el despliegue (§8). Los logs, los errores de la base y la lectura del cuerpo de las dos funciones están en `supabase/functions/_shared/edge.ts`.

## 1. Flujo

1. El cliente completa `/richiesta/` en la web. El calendario marca los días en que Evelyn tiene lugar para la duración estimada (`GET …/availability`, §11) y, con varias semanas, el mismo día de las semanas siguientes. Cloudflare Turnstile protege el envío.
2. La web hace `POST` a la Edge Function `public-request` con el JSON `PublicRequestPayload`, que lleva una `requestKey` (UUID) generada una vez por pedido y repetida en cada reintento (§2).
3. La función valida (`parsePublicRequest`), limita por IP, verifica Turnstile, elige la cocinera (`CHEF_ID` o la única de `public.chefs`, §4) y guarda todo en una transacción (`submit_public_request`):
   cliente prospecto (uno que ya existe no se modifica), consentimientos, restricciones (solo con consentimiento de salud), pedido con la respuesta a la pregunta de alergias, la estimación calculada en el servidor y la copia del contacto, y una notificación para Evelyn.
   Si la `requestKey` ya se usó, no guarda nada y devuelve el pedido original (con `duplicate: true`).
4. Responde `201` y, sin hacer esperar al cliente (`EdgeRuntime.waitUntil`), manda:
   - email a Evelyn: aviso de pedido nuevo con resumen y botón a la bandeja;
   - email al cliente: confirmación de que la solicitud fue enviada y que lo contactarán lo antes posible, en su idioma;
   - WhatsApp al cliente con lo mismo, **solo si** aceptó (`whatsappOptIn`) y si la integración de WhatsApp Cloud API está configurada (si no, se omite sin error).

   Un reintento con la misma `requestKey` recibe el mismo `201` y no repite ninguno de estos avisos.
5. Evelyn ve el pedido en la bandeja y en la agenda de la app (Android/iOS) y de la web (`/gestione/`, Flutter web), con aviso emergente en tiempo real si la tiene abierta.
   Desde el detalle puede marcarlo como visto, rechazarlo, contactar al cliente por WhatsApp (link `wa.me` con mensaje armado), teléfono o email (con los datos que llegaron con ese pedido) y, si la persona pasa a ser clienta, marcarla como cliente (§9).
6. Todos los días, pg_cron borra los prospectos cuyos pedidos no avanzaron en `prospect_retention_days` (90 días; §9).

Notificaciones push en segundo plano (FCM) quedan para una etapa siguiente: necesitan proyecto de Firebase y clave de APNs.

## 2. API: `POST /functions/v1/public-request`

- Público (sin login). `verify_jwt = false` para esta función; la protección es Turnstile + límite por IP + validación.
- La web la llama con `?forceFunctionRegion=eu-central-1` (`FUNCTION_REGION` en `web/src/request/submit.ts`): la función corre en Frankfurt, como dice la privacy, aunque el cliente escriba desde fuera de la UE (sin esto Supabase usa la región más cercana a quien envía). Va en la URL y no en la cabecera `x-region`, que necesitaría CORS. La función no lee ese parámetro: de la URL solo mira si la ruta termina en `/availability` (§11) y, en ese caso, `minutes`.
- `OPTIONS`: CORS. Orígenes permitidos en `ALLOWED_ORIGINS` (lista separada por comas; admite comodín de una etiqueta, ej. `https://*.example.com`). Cualquier otro origen: sin cabeceras CORS, así que el navegador no llega a mandar el `POST` (un `POST` JSON siempre pasa antes por el preflight). Las vistas previas de Pages quedan fuera por defecto (§4). El preflight permite `GET, POST, OPTIONS`: el `GET` es la disponibilidad del calendario (§11).
- Cuerpo: `application/json`, máximo `MAX_PAYLOAD_BYTES` (8 KB).

| Código | Cuerpo | Cuándo |
|---|---|---|
| 201 | `{ "requestId": uuid, "estimate": PublicRequestEstimate }` (§2, «Semanas y estimación»), más `"duplicate": true` en un reintento | Guardado, o reintento de un pedido ya guardado (misma `requestKey`: el mismo `requestId` y la estimación guardada, con `duplicate: true`) |
| 400 | `{ "errors": { campo: código } }` | Validación (`PublicRequestErrors`; una `requestKey` que no es UUID da `requestKey: "invalid"`) |
| 403 | `{ "errors": { "turnstileToken": "invalid" } }` | Turnstile rechazado |
| 405 / 413 / 415 | `{ "error": "method" \| "tooLarge" \| "contentType" }` | Método, tamaño o tipo inválidos |
| 429 | `{ "error": "rateLimited" }` + `Retry-After` | Más de 5 por hora o 20 por día por IP (los reintentos también cuentan) |
| 500 | `{ "error": "server" }` | Error interno o de configuración (sin detalles; el log lleva el código, §4) |

Los códigos de error por campo son los de `ErrorCode`; la web los traduce a sus textos i18n.

### Versión y pregunta de alergias (`noAllergies`)

- `version`: la web manda `PUBLIC_REQUEST_VERSION` (hoy 3) y el servidor acepta `PUBLIC_REQUEST_VERSIONS` (hoy 3 y 2: «Semanas y estimación», abajo). Una página vieja en caché (versión 1, sin `noAllergies`) recibe `{ "version": "invalid", "noAllergies": "invalid" }`: los dos son errores de página para su código (`translateErrors` en `web/src/request/validate.ts`) y muestra "página desactualizada, recárgala". Para que no reciba además `consentPrivacy`, `CONSENT_VERSIONS` conserva las privacy anteriores (§6). Desde la versión 2, con `version` rechazada la web ignora los errores de campo (son de otro contrato, por ejemplo durante un despliegue) y solo pide recargar. También pide recargar si el servidor rechaza un consentimiento que la página mandó marcado (`consentPrivacy` o `consentHealth` con versión): es una versión del texto que ya no acepta, y volver a marcar la casilla no lo arregla.
- `noAllergies` (boolean, obligatorio): `true` = nadie de quienes van a comer, niños incluidos, tiene alergias, intolerancias alimentarias ni celiaquía; `false` = las escribe en `restrictionsNote`. Reglas de `parsePublicRequest`:
  - no es booleano (también si falta) → `noAllergies: "invalid"`;
  - `true` con restricciones (`restrictionsNote`, `allergens` o `diets`) → `noAllergies: "invalid"`;
  - `false` sin restricciones → `restrictionsNote: "required"`;
  - `false` con restricciones → `consents.health` con una versión aceptada (`HEALTH_CONSENT_VERSIONS`, lista explícita: hoy solo `2026-11-16`, §6); si no, `consentHealth: "healthConsentRequired"`. Con `true`, un `consents.health` que llegue se descarta.
- `restrictionsNote`: las alergias escritas, hasta `TEXT_LIMITS.restrictionsNote` (200) caracteres, en varias líneas (se limpia como las notas). `allergens` y `diets` siguen en el contrato y la web los manda vacíos.

### Semanas y estimación (versión 3)

Agregado el 16/11/2026 con el precio por semana (SPEC §5.1).

- `weeks`: semanas del pedido semanal, con un menú y una sesión de cocina por semana, el mismo día. Entero de 1 a `LIMITS.maxWeeks` (8, el check `requests_semanas_validas`). Reglas de `parsePublicRequest`:
  - versión 3 sin el campo (o en `null`) → `weeks: "required"`: nunca se da por 1 en silencio;
  - que no sea un entero de 1 a 8 → `weeks: "range"`;
  - más de 1 con `type: "extra"` → `weeks: "invalid"` (una sesión extra es una sola; la web manda 1);
  - versión 2 sin el campo → una semana (esa página no podía pedir más).
- Versiones: la web manda la 3 y el servidor acepta la 3 y la 2 (`PUBLIC_REQUEST_VERSIONS`), por las páginas en caché y porque la web y la función se despliegan por separado (§8). Una función de antes (solo la 2) rechaza la 3 por versión, así que un pedido de varias semanas nunca se guarda como si fuera de una; la web muestra «página desactualizada» (`translateErrors`). Sacar la 2 en un PR propio, cuando ya no queden páginas viejas abiertas.
- `preferredDate` es el día de la primera semana; las siguientes son el mismo día de cada semana (`weeklyDates`). Las que caen después de la ventana (`DATE_WINDOW`) no se validan: las confirma Evelyn.
- Estimación del 201 (`PublicRequestEstimate`, armada con `publicEstimate`): la del motor con las tarifas de la cocinera, sin las tarifas. Porciones, recetas, minutos y compra son de una semana (una sesión).

  ```json
  { "weeks": 4, "portions": 20, "recipes": 3, "cookMinutes": 180, "groceriesEstCents": 6300,
    "autoPrice": true, "weeklyServiceCents": 14000, "serviceCents": 56000, "savingsCents": 4000, "totalCents": 81200 }
  { "weeks": 1, "portions": 16, "recipes": 2, "cookMinutes": 150, "groceriesEstCents": 5300,
    "autoPrice": false, "reason": "extra" }
  ```

  - Sin precio automático (`reason`: `people`, más personas que el tope de la cocinera; `extra`, una sesión extra) no lleva claves de precio.
  - Con precio lleva también las seis claves de la versión 2 (`portions`, `recipes`, `cookMinutes`, `serviceCents`, `groceriesEstCents`, `totalCents`), así una página de antes la sigue leyendo: muestra `totalCents` (servicio y compra de todas las semanas) como «Totale stimato». Sin precio, esa página no encuentra `serviceCents` y muestra su propio cálculo (el de la tarifa por hora) hasta que se recarga; el email dice que el presupuesto lo prepara Evelyn. Dura lo que duren las páginas viejas abiertas.
  - La web la lee con `readPublicEstimate`: con otra forma queda en null y la pantalla de gracias usa la de la calculadora.
- Reintento (`duplicate: true`): la estimación guardada, leída con `readPublicEstimate`, que también lee las de antes del precio por semana (sin `autoPrice` ni `weeks`) como una semana con precio y sin ahorro.
- La web calcula el precio con `DEFAULT_PRICING`, que es el valor por defecto de `chef_settings` (`quote.test.ts`); el servidor, con las tarifas de la cocinera. Mientras la web no las lea, cambiar una tarifa es un PR (SPEC §5.1).

### Día preferido (`preferredDate`)

Actualizado el 15/11/2026: la ventana pasó de 14 días a 8 semanas.

- Opcional: `"AAAA-MM-DD"` o `null` (`""` cuenta como `null`). De mañana a 8 semanas, con la fecha de hoy de Roma en el servidor: `DATE_WINDOW`, de +1 a +56 días. Fuera de la ventana, `preferredDate: "dateOutOfRange"`; una fecha que no existe o con otro formato, `"invalid"`.
- La web lo elige en el calendario (§11) y dice la ventana en semanas: sus textos usan `{horizonWeeks}`, que sale de `DATE_WINDOW` (un test exige que `maxDaysAhead` sea múltiplo de 7). La base corta en el mismo día (`booking_horizon_days`, §11.1).
- Cambiar la ventana no cambia `PUBLIC_REQUEST_VERSION`: el payload es el mismo. Mientras se despliega (la web y la función salen por separado, §8), la función de antes puede rechazar con `dateOutOfRange` una fecha que la web nueva ya ofrece (con `extra`, o si el calendario no pudo cargar la disponibilidad): la web lo marca en el calendario con su mensaje (`errors.date`), sin pedir recargar. Una página de antes manda fechas de su ventana, que la función nueva también acepta.

### Idempotencia (`requestKey`)

- Opcional en el payload (para no romper clientes viejos). UUID en formato canónico; el servidor lo pasa a minúsculas.
- Se guarda en `requests.request_key`, única por cocinera (§3).
- La misma clave otra vez, uno después del otro o al mismo tiempo: `201` con el mismo `requestId`, la estimación **guardada** del original (aunque las tarifas hayan cambiado o el reintento traiga otros datos) y `duplicate: true`. Un pedido nuevo no lleva `duplicate`. No se guarda ni se actualiza nada (tampoco el prospecto) y no sale ningún email ni WhatsApp. El log dice `request_duplicate`.
- El reintento se valida igual (400 si es inválido) y pasa por el límite por IP y por Turnstile. Los tokens de Turnstile sirven una sola vez: cada intento lleva un token nuevo y la misma clave.
- La web genera la clave al empezar un pedido (`crypto.randomUUID()`) y la conserva en todos los reintentos hasta recibir un `201`; el pedido siguiente lleva otra. Si el primer intento sí se había guardado, el reintento devuelve ese pedido aunque el formulario haya cambiado entre medio.
- Con `duplicate: true` la web no muestra como enviado lo que se cambió después (`replayed` y `doneViewFor` en `web/src/request/request-key.ts`): recuerda los datos de cada intento con esta clave que terminó en error de red o 5xx (uno de esos es el guardado).
  - Si fue uno solo y es igual al formulario actual: la pantalla de gracias de siempre.
  - Si fue uno solo y distinto: la pantalla de gracias con los datos y el email de **ese** intento, y el aviso de que los cambios de después no se guardaron (que mande una solicitud nueva si algo no va).
  - Si hubo varios distintos (o ninguno): sin resumen ni email, con un aviso parecido.
- Sin clave, cada envío es un pedido nuevo.

## 3. Base de datos

Migraciones: `20261019120000_public_requests.sql`, `20261019130000_api_grants.sql`, `20261019140000_public_request_idempotency.sql`, `20261019150000_prospect_retention.sql`, `20261019160000_public_request_hardening.sql` (copia del contacto, prospecto sin modificar, guarda en el alta, `promote_to_chef` endurecida, intentos por IP de 1 día y `private.revoke_health_consent`), `20261115120000_requests_no_allergies.sql` (pregunta de alergias) y `20261116120000_weekly_pricing.sql` (semanas del pedido, columnas del precio por semana de `chef_settings` y el tope de 0 a 100000 del costo por porción). Tests pgTAP: `supabase/tests/database/03_health_consent`, `04_public_requests`, `05_public_request_idempotency`, `06_prospect_retention`, `09_allergy_answer` y `12_weekly_pricing`. Las de la disponibilidad del calendario están en §11.

`requests` (columnas nuevas):

| Columna | Tipo | Nota |
|---|---|---|
| `preferred_slot` | text, check in (`morning`,`afternoon`,`any`) | franja preferida |
| `locale` | text not null default `it`, check in (`it`,`es`,`en`) | idioma del cliente (emails, WhatsApp) |
| `whatsapp_opt_in` | boolean not null default false | aceptó confirmación por WhatsApp |
| `estimate` | jsonb | resultado de `calcQuote` con las tarifas de `chef_settings` al crear + `pricing` usado (SPEC §5.1): siempre `weeks`, `autoPrice`, porciones, recetas, minutos y compra; `weeklyServiceCents`, `serviceCents`, `savingsCents` y `totalCents` solo con precio automático (sin precio, `reason`). Las de antes del 16/11/2026 no tienen `autoPrice` (una semana, servicio por hora) |
| `source` | text not null default `app`, check in (`web`,`app`) | origen |
| `seen_at` | timestamptz | Evelyn lo abrió |
| `request_key` | uuid | `requestKey` de la web; índice único `(chef_id, request_key)` donde no es null. También la lleva el pedido de una reserva a mano (`source = 'app'`): la clave de idempotencia de `chef_create_booking`, que comparte el índice con las de la web (SPEC §4, «Reservas», y contrato `chef-api.md` §4). Los pedidos que la app crea directamente no la llevan |
| `contact` | jsonb (objeto) | contacto tal como llegó con el pedido: `{ "name", "zone", "phone" (E.164), "email" }`. Lo escribe solo `submit_public_request`; la app lo muestra en lugar de la ficha (§7). Null en los pedidos de la app |
| `no_allergies` | boolean | respuesta a la pregunta de alergias: `true` = nadie tiene; `false` = las escribió (van en `restrictions`); null = sin respuesta (pedidos de la app, de la web anteriores a la versión 2 o con el consentimiento de salud retirado). Check: `true` nunca va con `restrictions`. Lo escribe solo `submit_public_request`; la app lo lee (§7) |
| `weeks` | smallint not null default 1, check entre 1 y 8 (`requests_semanas_validas`) y 1 si `type` no es `week` (`requests_semanas_solo_week`) | semanas del pedido semanal: un menú y una sesión de cocina por semana. 1 en los demás y en los pedidos anteriores (eran de una semana). Lo escriben `submit_public_request` (`p.weeks`) y `chef_create_booking` (SPEC §4, «Reservas», y contrato `chef-api.md` §4): al confirmar una reserva desde un pedido, las semanas que se crearon; el pedido de una reserva a mano (`source = 'app'`) nace con ellas. La app lo lee y no lo escribe (privilegios por columna): un pedido que crea directamente queda en 1 |

`chef_settings`: la función lee las tarifas del motor con la clave secreta (`CHEF_SETTINGS_COLUMNS` en `handler.ts`: las cuatro del precio por semana de `20261116120000_weekly_pricing.sql`, las porciones, el margen y el mínimo de cocina; ya no la tarifa por hora ni el fijo de traslado). Sin esa migración la lectura falla (`500`, `db_error` con `op: load_chef`) y no se guarda ningún pedido.

`requests.restrictions` (ya existe): `{ "allergens": [...], "diets": [...], "note": "..." }`, solo si hay consentimiento de salud; si no, null. Desde la versión 2 la web manda las alergias escritas: `{ "allergens": [], "diets": [], "note": "<lo que escribió>" }`.

Funciones para la Edge Function y el arranque (todas `security definer`, `set search_path = ''`, ejecutables **solo** por `service_role`):

- `public.submit_public_request(p jsonb) returns jsonb` → `{ "request_id": uuid, "duplicate": boolean, "estimate": jsonb }`. En una transacción crea o reutiliza el cliente, inserta consentimientos, restricciones, pedido y notificación.
  - `p.request_key` (UUID en texto, o null): si ya existe para esa cocinera, devuelve ese pedido con `duplicate: true` y su `estimate` guardada, sin tocar nada. Valida el resto antes de buscar la clave: un reintento inválido falla igual.
  - `p.no_allergies` (true, false, o null / ausente): va a `requests.no_allergies`. Ausente queda null, así la función de antes de la versión 2 sigue guardando pedidos mientras se despliega la nueva. Defensa (la función ya valida con `parsePublicRequest`): que no sea booleano (`invalid_no_allergies`), `true` con restricciones (`no_allergies_with_restrictions`) o `false` sin ellas (`restrictions_required`) fallan con `22023`.
  - `p.weeks` (número entero de 1 a 8, o null / ausente): va a `requests.weeks`. Ausente o null es 1, así la función que no lo manda sigue guardando pedidos mientras se despliega la que sí. Defensa: fuera de 1–8 o que no es un número entero (un texto, un decimal) falla con `22023` `invalid_weeks`, y más de 1 en un pedido que no es `week`, con `22023` `weeks_only_for_week`. Se valida antes de buscar la `request_key`: un reintento inválido falla igual, y uno válido devuelve el pedido guardado con sus semanas, aunque pida otras. La función de la versión 3 lo manda siempre (`toSubmitParams`).
  - Dos llamadas simultáneas con la misma clave se serializan con un advisory lock por cocinera y clave (se toma antes que el del email): la segunda espera el commit de la primera y la encuentra. El índice único es la garantía final.
  - Reutiliza un cliente **solo** si es `status = 'prospect'` del mismo chef con el mismo `contact_email` (sin distinguir mayúsculas). En ese caso **no le cambia nada**: ni nombre, ni teléfono, ni zona, ni el hogar. El email no está verificado: cualquiera que conozca el de otra persona podía cambiarle el teléfono (y con él los botones de WhatsApp y llamada de sus pedidos) o borrarle las alergias. Lo que llegó con cada pedido queda en `requests.contact`.
  - Restricciones del hogar (`client_restrictions`): solo las de un pedido semanal (`week`), y **se suman** a las que ya tenía (nunca se borran desde la web; las cura Evelyn o el cliente con cuenta). Las de un evento (`extra`) son de sus invitados: quedan solo en la copia del pedido (`requests.restrictions`), igual que el hogar (`adults`, `kids`) se toma solo de un pedido semanal. El consentimiento de salud se registra en los dos casos. Un consentimiento con otra versión del texto cierra el anterior y eso, como siempre, borra las restricciones del prospecto (trigger `consents_purge_health_data`). Después solo se cargan los alérgenos y las dietas del pedido semanal, que la web de la versión 2 manda vacíos: las alergias escritas no pasan a `client_restrictions` (quedan en la copia de cada pedido, `requests.restrictions.note`), así que lo que se borró de la ficha no vuelve solo.
  - Nunca modifica clientes que no sean prospectos: si el email es de un cliente con cuenta, crea un prospecto nuevo. Evelyn los une a mano más adelante.
- `public.hit_public_request_rate(p_ip_hash text, p_max_hour int, p_max_day int) returns boolean`: registra el intento y dice si está dentro del límite. La tabla es `private.public_request_hits(ip_hash, created_at)`: el esquema `private` está fuera de la API (ni `anon`, ni `authenticated`, ni `service_role` lo ven), con RLS y sin políticas. `ip_hash` es un HMAC-SHA-256 en hexadecimal (`IP_HASH_SALT` como clave; de una IPv6, su /64), nunca la IP. Cada llamada borra los registros de más de 1 día (la ventana más larga), y el borrado diario también (§9): ninguno dura 2 días. La disponibilidad (§11) usa la misma función con otra clave (el HMAC de `availability:<ip>`): otro contador, con sus propios límites.
- `public.promote_to_chef(p_email text, p_display_name text) returns uuid`: para el arranque (§10). Convierte el usuario de auth con ese email en cocinera: rol `chef`, fila en `chefs` y `chef_settings` por defecto. Devuelve el `chef_id`. La corre una vez `deploy-supabase.yml` (o el SQL editor); repetirla devuelve la misma ficha.
  - Exige el email confirmado (`user_not_confirmed` si no): creado confirmado por el despliegue o desde el panel, o después de entrar una vez con el código.
  - Le pone una contraseña al azar (nadie la conoce: la app entra con código) y borra sus sesiones, refresh tokens y factores MFA. Así nadie que haya registrado antes ese email con una contraseña propia entra como cocinera. Un access token ya emitido vale hasta que vence (1 h). Repetirla también cierra las sesiones de Evelyn: vuelve a entrar con el código.
- `private.revoke_health_consent(p_client_id uuid) returns jsonb`: el cliente retira el consentimiento de salud (§10). Lo revoca (el trigger borra `client_restrictions`) y borra de sus pedidos las copias (`requests.restrictions`) y el "hay alergias" (`no_allergies` `false` pasa a null: también es un dato de salud; el `true` no se toca). Devuelve `{ "consents", "requests" }`. Solo el dueño, desde el SQL editor (ningún rol de la API la ejecuta). No va en el trigger: ese también corre cuando `submit_public_request` reemplaza la versión del texto, y ahí las copias valen.

Privilegios explícitos (`20261019130000_api_grants.sql`): Supabase dejó de dar privilegios implícitos sobre las tablas nuevas de `public` a `anon`, `authenticated` y `service_role` (proyectos nuevos desde el 30/05/2026; todos desde el 30/10/2026). La migración los da explícitos: `service_role`, las cuatro operaciones en todas las tablas de `public`; `authenticated`, lo que gestiona con RLS, y en `requests`, `clients`, `consents`, `profiles`, `chefs`, `payments` y `prepared_portions` las altas y cambios solo por columnas; `anon`, nada. En local `auto_expose_new_tables = false` (`supabase/config.toml`): una tabla nueva sin sus `GRANT` falla también en local y en CI. Toda tabla nueva de `public` trae sus grants en su propia migración.

Realtime: `public.requests` está en la publicación `supabase_realtime`. RLS limita qué filas ve cada uno.

Cambios desde la app: la cocinera actualiza sus pedidos (política "la cocinera gestiona los suyos"), pero solo las columnas `seen_at` y `status`, y el trigger `requests_guard_update` solo deja estos cambios de estado:

| De | A | Para |
|---|---|---|
| `new` | `rejected` | rechazar |
| `rejected` | `new` | deshacer el rechazo |
| `new` | `resolved` | resolver un pedido de cambio (`type = 'change'`) |

Cualquier otro (`quoted`, `accepted`, `declined`, `expired`) lo hace el servidor (Edge Functions o cron con la service role); desde la app falla con `42501 request_status_change_not_allowed`. La guarda vale también en el alta: desde la app un pedido empieza en `new` (crear uno ya presupuestado o aceptado da el mismo error). El cliente con cuenta crea sus pedidos pero no los actualiza. Al crear un pedido desde la app no se pueden escribir `estimate`, `source`, `seen_at`, `created_at`, `request_key`, `contact`, `no_allergies` ni `weeks` (privilegios por columna).

La cocinera también cambia el estado de la ficha de un cliente (`clients.status`, privilegio por columna y `clients_guard_update`): la app la pasa de `prospect` a `trial` con "Segna come cliente" (§7, §9).

## 4. Configuración de la Edge Function (secretos de Supabase)

| Nombre | Secreto | Ejemplo / nota |
|---|---|---|
| `RESEND_API_KEY` | sí | clave de Resend con permiso solo de envío |
| `TURNSTILE_SECRET_KEY` | sí | **obligatoria** para el pedido (la disponibilidad, §11, no la usa). En local: `1x0000000000000000000000000000000AA` (siempre aprueba) |
| `IP_HASH_SALT` | sí | **obligatoria** (también para el límite de la disponibilidad, §11). Aleatoria (`openssl rand -hex 32`); la IP nunca se guarda en claro |
| `CHEF_ID` | no | opcional: uuid de Evelyn en `chefs` (sale de `promote_to_chef`). Sin él se usa la única fila de `public.chefs` (ver abajo). Hace falta solo con más de una cocinera (el seed local tiene dos) |
| `CHEF_NOTIFY_EMAIL` | no | email de Evelyn para avisos |
| `CHEF_LOCALE` | no | idioma de los avisos a Evelyn: `es` (por defecto), `it` o `en` |
| `MAIL_FROM` | no | `Radici <ciao@radicicucina.app>`; el nombre es la marca de los emails (si falta, Radici) |
| `MAIL_REPLY_TO` | no | email de Evelyn; si falta, `CHEF_NOTIFY_EMAIL` (§5) |
| `EMAIL_TRANSPORT` | no | `resend` (por defecto) o `log` (desarrollo: no manda, registra) |
| `ALLOWED_ORIGINS` | no | producción: `https://radicicucina.app`; local: `http://localhost:5173,http://127.0.0.1:5173`. **Sin vistas previas** (ver abajo). La usa también la función `chef` (área de Evelyn, contrato `chef-api.md` §2): cada origen de la lista puede llamarla con la sesión de Evelyn, así que lleva solo el dominio del sitio |
| `INBOX_URL` | no | `https://radicicucina.app/gestione/` |
| `PUBLIC_SITE_URL` | no | `https://radicicucina.app` |
| `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_TEMPLATE` | sí / no / no | opcionales; sin ellos no se manda WhatsApp |

`SUPABASE_URL` y la clave de servicio (`SUPABASE_SECRET_KEYS`, o las variables de compatibilidad) las provee Supabase a la función.

Cocinera sin `CHEF_ID`: la función busca en `public.chefs`. Con una sola fila, usa esa. Sin filas (por ejemplo, en el primer despliegue, antes de correr `promote_to_chef`) o con más de una, responde `500` y registra `chef_id_unresolved` con `reason: "no_chef"` o `"multiple_chefs"`. Un `CHEF_ID` que no es uuid no cae en la cocinera por defecto: `500` y log `config_invalid`.

Logs de configuración, solo con nombres de variables: al arrancar, `config_missing` (faltan obligatorias), `config_invalid`, `config_incomplete` (faltan las de emails, CORS o links) y `chef_id_auto` (sin `CHEF_ID`); en cada pedido que no se puede atender, `config_missing`, `config_invalid` o `chef_id_unresolved`.

**Vistas previas de los PR.** `deploy-web.yml` construye la web de las vistas previas (`https://<rama>.<pages>.pages.dev`) con el mismo `SUPABASE_URL` de producción. Si su origen estuviera en `ALLOWED_ORIGINS`, desde una vista previa se crearían pedidos reales (con emails a Evelyn y al cliente). Por eso no van ni en el ejemplo ni en producción. La bandeja (`/gestione/`) de una vista previa se compila sin backend (modo dev, "Backend non configurato"): es código sin revisar en una URL pública y no se conecta a los datos de producción. Nunca entrar con la cuenta de Evelyn en una vista previa. Para probar el formulario de una a mano:

1. Sumar a la variable `ALLOWED_ORIGINS` el origen exacto de esa vista previa (`https://<rama>.<pages>.pages.dev`; mejor que el comodín `https://*.<pages>.pages.dev`, y nunca `https://*.pages.dev`) y desplegar (`deploy-supabase.yml` a mano, o `supabase secrets set ALLOWED_ORIGINS=...`).
2. El widget de Turnstile tiene que aceptar ese hostname (Cloudflare → Turnstile → el widget → Hostnames).
3. Probar con datos de prueba y un email propio: el pedido y los emails son reales.
4. Al terminar, sacar el origen y volver a desplegar (el workflow avisa mientras `ALLOWED_ORIGINS` tenga un `.pages.dev`), y borrar el pedido de prueba desde el SQL editor (la bandeja no borra; §10, "Borrar a una persona").

`<pages>` es el subdominio que Cloudflare asigne al proyecto de Pages `radici` (todavía sin confirmar).

## 5. Emails

- Proveedor: Resend (`POST https://api.resend.com/emails`).
- `Idempotency-Key` por pedido y por **rol** del destinatario, no por dirección: `request-<id>-chef` y `request-<id>-client`. Resend la guarda 24 h: el reintento de un envío (ante 429, 5xx o error de red, una sola vez) no sale dos veces. Un pedido duplicado (misma `requestKey`) ni siquiera llega a Resend.
- Remitente `MAIL_FROM`. Respuestas (`reply_to`):
  - aviso a Evelyn: el email del cliente (al responder, Evelyn le escribe directo al cliente);
  - confirmación al cliente: `MAIL_REPLY_TO`, o `CHEF_NOTIFY_EMAIL` si falta (las respuestas del cliente le llegan a Evelyn); sin ninguno de los dos, sin `reply_to` (las respuestas van a `MAIL_FROM`).
- Siempre HTML + texto plano, diseño simple y legible en móvil, sin imágenes remotas ni seguimiento.
- **Sin datos de salud** (alergias, dietas, nota de restricciones) **ni dirección** en ningún email (SPEC §6), ni las notas libres. De las alergias, solo qué contestó el cliente (`AllergyAnswer` en `emails.ts`), nunca cuáles:
  - a Evelyn: "Confirmó que nadie tiene alergias, intolerancias ni celiaquía.", "Indicó restricciones alimentarias: las ves en la app." o, si el pedido no trae respuesta (uno anterior a la pregunta), "Sin datos de alergias: pregúntale al cliente antes de preparar el menú.";
  - al cliente, solo si confirmó que nadie tiene: "Confirmaste que nadie tiene alergias, intolerancias alimentarias ni celiaquía." (así ve si se equivocó). Con alergias escritas o sin respuesta, nada: su email no está verificado y "hay alergias" también es un dato de salud (`private.revoke_health_consent` lo borra, §3); lo que contestó ya lo vio en la pantalla de gracias.
- Al cliente, en su `locale`: gracias, que Evelyn lo contactará lo antes posible para confirmar los días, los horarios, el menú y el precio final, resumen (tipo, semanas de un pedido semanal, personas, días por semana, comidas, fecha preferida y las fechas de las semanas siguientes, cortas y separadas por «·», sin cortes de renglón dentro de una fecha, y la franja solo si no es `any`), la confirmación de que nadie tiene alergias (si la dio), la estimación (precio por semana, el de todas las semanas, destacado, y el ahorro frente a la tarifa sin descuento; sin precio automático, que el presupuesto del servicio se lo prepara Evelyn y por qué) con la compra estimada aparte y la aclaración de que se paga según el ticket, y link a la privacy.
- A Evelyn, en `CHEF_LOCALE` (español por defecto): nombre, zona, teléfono, email, resumen (el mismo, con las semanas y las fechas), qué contestó sobre alergias, estimación (sin precio automático: «prepara tú el presupuesto», con el motivo: más de N personas, con el tope de sus tarifas, o sesión extra), si aceptó WhatsApp, y botón "Abrir en la bandeja" → `INBOX_URL#/richieste/<id>`. Los importes son los del servidor (las tarifas de la cocinera), los mismos que guarda `requests.estimate`.
- Asuntos: al cliente, "`<marca>`: hemos recibido tu solicitud" en su idioma, sin datos suyos; a Evelyn, "Nueva solicitud de `<nombre de pila>`", solo si la primera palabra del nombre parece un nombre (`safeFirstName`: letras, y entre ellas apóstrofo o guion, hasta 30 caracteres). Si trae dígitos, puntos, `@`, `+`, `/` u otros signos (un teléfono, un email o un link escritos en ese campo), el asunto es "Nueva solicitud desde la web". Nunca teléfono, email, zona, dirección ni datos de salud en un asunto.
- El saludo de la confirmación al cliente ("Gracias, `<nombre de pila>`") y el parámetro `first_name` del WhatsApp usan la misma regla; si no, "¡Gracias!" y `-`. Llegan a un email o a un número que nadie verificó: no pueden llevar un link escrito en el formulario.
- Escapar todo texto del usuario en el HTML. El link `mailto:` del aviso a Evelyn lleva la dirección codificada (`mailtoHref`): un `?`, `&` o `#` escrito en el campo del email no agrega destinatarios ocultos, copias ni un cuerpo al responder.
- Un fallo de envío no rompe el pedido: se registra el error (sin datos personales) y `notifications.sent_at` queda null.
- Con `EMAIL_TRANSPORT=log` no sale nada: se registra `email_logged` con el pedido, el destinatario por rol (`chef` / `client`) y el largo del HTML y del texto.

## 6. Web (`web/`)

- El formulario deja de abrir WhatsApp y no queda ningún link a WhatsApp en la web pública.
- Email obligatorio. Casilla opcional "Quiero recibir la confirmación también por WhatsApp" (`whatsappOptIn`), visible junto al teléfono.
- Turnstile (render explícito, modo "managed"); el token va en el payload y se pide uno nuevo después de cada intento fallido (sirve una sola vez).
- `requestKey`: una por pedido, la misma en todos los reintentos hasta el `201` (§2). Con `duplicate: true`, la pantalla de gracias muestra lo que se guardó, no lo que se cambió después (§2).
- La URL de la función lleva `?forceFunctionRegion=eu-central-1` (§2).
- Bloque "Alergias e intolerancias", entre "¿Cuándo?" y "Tus datos" (§2): la casilla `noAllergies` ("nadie de quienes van a comer, niños incluidos, tiene alergias, intolerancias alimentarias ni celiaquía": la celiaquía no es ni alergia ni intolerancia, hay que nombrarla) y, sin marcar, el área de texto `restrictionsNote` (obligatoria, `maxlength` de `TEXT_LIMITS`; la ayuda pide también si alcanza una traza para hacer daño) y la casilla del consentimiento de salud `consentHealth`, con link a la privacy (punto 5). Con esa casilla, quien escribe también declara que las personas a las que se refieren (o quien tiene su responsabilidad parental) están informadas y de acuerdo. Marcada `noAllergies`, la nota y el consentimiento se ocultan y no se mandan. Las notas libres piden no escribir datos de salud y apuntan a ese bloque. La pantalla de gracias dice "Ninguna" o "Indicadas", nunca cuáles.
- Precio por semana (16/11/2026, SPEC §5.1): selector de semanas (1 a 8, números grandes; con "extra" se oculta y se manda 1). Recuadro del precio (`web/src/request/quote-box.ts`; la página solo pinta): el servicio de todas las semanas destacado, el de cada semana y el ahorro desde 4 semanas frente a la tarifa sin descuento; con más de 5 personas o en una sesión extra, que el presupuesto lo prepara Evelyn; la compra estimada aparte, «según el ticket». Los rótulos son los mismos en el recuadro, la pantalla de gracias, la portada, los emails y la app («Servizio a settimana», «Servizio, N settimane», «Spesa stimata a settimana»). El calendario, con el primer día elegido, marca el mismo día de las semanas siguientes con su disponibilidad (la misma consulta, los mismos minutos de una sesión) y debajo lista las fechas; las que caen fuera de la ventana las confirma Evelyn. La pantalla de gracias muestra las semanas, las fechas y el precio. Los textos no escriben números: salen de `DEFAULT_PRICING` y `LIMITS` (`web/src/i18n/site.ts`).
- Tipos y constantes desde `_shared/public_request.ts`: `TEXT_LIMITS`, `DATE_WINDOW`, `CONSENT_VERSION`, `normalizePhone`, `weeklyDates`, `readPublicEstimate`, etc. Un solo origen; nada duplicado en `web/src/request/model.ts`.
- Estados: enviando (botón deshabilitado), éxito (pantalla de gracias con resumen y "te mandamos un email a …"), errores por campo (códigos del servidor), 429, Turnstile fallido y error de red, con opción de reintentar sin perder lo cargado.
- Config (`web/.env.example`): `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_TURNSTILE_SITE_KEY` (en local, `1x00000000000000000000AA`), `VITE_SITE_URL`, `VITE_NOINDEX` y `VITE_BRAND_NAME` (si falta, Radici). `VITE_WHATSAPP_NUMBER` ya no se usa.
- CSP: sumar Turnstile (`script-src` y `frame-src` `https://challenges.cloudflare.com`) y la URL de Supabase en `connect-src`. Verificar en un servidor local con la cabecera real.
- Privacy: datos en Supabase (UE, Frankfurt), emails con Resend, Turnstile de Cloudflare, WhatsApp solo con aceptación, borrado 90 días después del último pedido para los que no avanzan (§9), emails y chats dentro de los 30 días siguientes (§10.3), quién más ve los datos de salud (la asistencia técnica) y que no van en las notas libres. Completada el 15/11/2026 (versión del texto `2026-11-15`); la de `2026-10-19` era el borrador. La de `2026-11-16` (`CONSENT_VERSION`) suma las consultas del calendario: el calendario consulta la disponibilidad antes de enviar, solo con la duración estimada (ningún otro dato del formulario), y esas consultas también se cuentan por IP como huella (hash), con la misma conservación (2 días como máximo) y la misma base (interés legítimo) que el límite de envíos (§11). Y suma la pregunta de alergias: qué se pregunta (también la celiaquía), que de "nadie tiene" solo se guarda la confirmación, el consentimiento explícito de las escritas (art. 9.2.a), que quien escribe las de otras personas tiene que haberlas informado y contar con su acuerdo (y que ellas pueden pedir el borrado), que sin consentimiento el formulario no envía y se puede usar el contacto del punto 1 en lugar de marcar "nadie tiene", que lo escrito en las notas o mandado sin consentimiento se borra, quién las ve, que no van a terceros, qué dicen los emails (el aviso a Evelyn, si se indicaron; la confirmación, solo "nadie tiene"), que se conservan como la solicitud y que el retiro las borra. Un pedido de la versión 2 solo se guarda con la privacy vigente (`CONSENT_VERSIONS`); las dos viejas están aparte (`LEGACY_PAGE_CONSENT_VERSIONS`) y se aceptan solo en pedidos de otra versión, que fallan por versión, para que las páginas v1 reciban solo errores de página (§2). Un v2 con una privacy vieja (solo posible armado a mano) recibe `consentRequired`. El consentimiento de salud, la lista explícita `HEALTH_CONSENT_VERSIONS` (hoy solo `2026-11-16`): al cambiar `CONSENT_VERSION`, sumarla ahí (un test lo exige) y dejar la anterior mientras haya páginas en caché si el texto de salud no cambió. Una página con una versión que el servidor ya no acepta recibe "página desactualizada" (§2).

## 7. App y bandeja web (`app/`, Flutter)

- Login de Evelyn con código por email (Supabase Auth, OTP de 8 cifras que vale 10 minutos). La app no crea usuarios (`shouldCreateUser: false`) y en el proyecto las altas van apagadas: hasta el área de clientes (M2) solo entra quien ya tiene usuario (§10). Un email sin usuario ve "Questo indirizzo email non è abilitato all'accesso". Si el usuario no es `chef`, mensaje "área de clientes en preparación".
- Secciones de la cocinera:
  - **Richieste**: nuevas (sin `seen_at`), vistas y rechazadas, con contador de nuevas. El resumen de cada pedido dice las semanas si son más de una (`requests.weeks`).
  - **Agenda**: calendario mensual y semanal con los pedidos por `preferred_date` y franja, más una lista "senza data". Desde ahí Evelyn bloquea días sueltos o rangos (`availability_exceptions`, con su sesión y la RLS de M1; nota privada): `get_free_days` los descuenta y el calendario de la web (§11) deja de ofrecerlos.
  - **Detalle**: todos los datos, incluidas las restricciones (Evelyn sí las ve) o lo que contestó el cliente a la pregunta de alergias (`requests.no_allergies`: "nadie tiene", las alergias escritas o, en un pedido sin respuesta, el aviso destacado de preguntarle antes de preparar el menú), las semanas y las fechas de las siguientes, la estimación guardada (con el precio por semana: el de cada semana, el de todas, el ahorro y la compra por semana, o por qué no hay precio automático; las de antes, como se guardaron) y las acciones: marcar visto (al abrir), rechazar, WhatsApp (`https://wa.me/<phoneE164 sin +>?text=<mensaje en el idioma del cliente>`), llamar (`tel:`) y email (`mailto:`), y "Segna come cliente" mientras la persona sea un prospecto (§9).
- Contacto de cada pedido: el que llegó con él (`requests.contact`), campo por campo, y si falta (pedidos de la app), el de la ficha. El nombre del detalle, la bandeja, el aviso emergente y los links de WhatsApp, llamada y email salen de ahí.
- Cambios de estado permitidos desde la app: §3.
- Tiempo real: suscripción a `INSERT` en `requests` (filtrado por su `chef_id`) → aviso emergente "Nueva solicitud de …" con botón para abrirla, y actualización de la lista.
- Web: misma app compilada con `flutter build web --base-href /gestione/`, publicada dentro del sitio de Pages en `/gestione/`. Autocontenida (sin CDN de Google para CanvasKit ni fuentes), con su propia CSP en `_headers` para `/gestione/*`. Avisa «Hay una versión nueva · Actualizar» cuando se publicó otra (§8) y, en el iPhone o el iPad fuera de la app instalada, que conviene abrirla desde el ícono de la pantalla de inicio (`app/README.md`, "Web /gestione/").
- Toda la lógica en repositorios y providers, con tests (Supabase simulado con mocktail).

## 8. Despliegue

- `deploy-supabase.yml`: en push a `main` que toque `supabase/**` (o a mano): tests de TypeScript y pgTAP; después `supabase link`, la configuración de Auth desde el repo (§10.1, paso 6), `db push` (solo migraciones, nunca el seed; incluye el trabajo de pg_cron de §9), la cuenta de la cocinera si todavía no hay ninguna (con su horario inicial, §11.1), carga los secretos de las funciones y `functions deploy public-request` y `functions deploy chef` (el área de Evelyn, con `verify_jwt = true`; contrato `chef-api.md` §9; avisa si `ALLOWED_ORIGINS` tiene orígenes además del de `PUBLIC_SITE_URL`).
  - Secretos de GitHub: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `RESEND_API_KEY`, `RESEND_SMTP_KEY` (SMTP de Auth: sin ella el despliegue sigue, pero el email del código no trae el código), `TURNSTILE_SECRET_KEY`, `IP_HASH_SALT` (opcional `WHATSAPP_TOKEN`).
  - Variables de GitHub: `SUPABASE_PROJECT_REF`, `CHEF_NOTIFY_EMAIL`, `MAIL_FROM`, `MAIL_REPLY_TO`, `ALLOWED_ORIGINS`, `INBOX_URL`, `PUBLIC_SITE_URL`; opcionales `CHEF_LOGIN_EMAIL` y `CHEF_DISPLAY_NAME` (crean la cuenta de la cocinera mientras no haya ninguna), `CHEF_ID`, `CHEF_LOCALE`, `EMAIL_TRANSPORT`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_TEMPLATE`.
  - La configuración de Auth la arma `supabase/scripts/auth-config.ts` (con tests) y va a la Management API (`PATCH /v1/projects/{ref}/config/auth`, en tres partes: seguridad siempre; SMTP y plantillas con `RESEND_SMTP_KEY`), y comprueba en la respuesta que las altas quedaron apagadas y la plantilla guardada; los cuerpos (con la plantilla y la clave del SMTP) y la respuesta no se imprimen. La cuenta de la cocinera se crea por la API de administración de Auth con la clave secreta del proyecto, leída en ese paso y enmascarada; con una cocinera ya creada el paso no hace nada (`promote_to_chef` le cerraría las sesiones).
  - Los valores vacíos no se cargan (no pisan los que ya estén): para volver a la cocinera automática después de haber cargado `CHEF_ID`, `supabase secrets unset CHEF_ID`.
  - Antes de cargar los secretos corta si `TURNSTILE_SECRET_KEY` es una clave de prueba (`1x…AA`, `2x…AA`, `3x…AA`) o si `ALLOWED_ORIGINS`, `INBOX_URL` o `PUBLIC_SITE_URL` apuntan a localhost; avisa si `EMAIL_TRANSPORT=log` o si `CHEF_ID` es el del seed. Después comprueba (solo los nombres) que en Supabase estén `TURNSTILE_SECRET_KEY` e `IP_HASH_SALT`, cargadas desde GitHub o a mano: sin ellas corta.
  - Primer despliegue: en el orden de §10. Sin `CHEF_ID`, la función responde `500` (`chef_id_unresolved`, `no_chef`) hasta que se corre `promote_to_chef`; desde ahí funciona sin tocar nada más.
- `deploy-web.yml`: además de la web, compila la app Flutter web y la copia a `dist/gestione/` antes de publicar. Proyecto de Pages `radici` (lo crea el workflow si no existe), servido en el dominio propio `radicicucina.app`.
  - Secreto `CLOUDFLARE_API_TOKEN`; variables `CLOUDFLARE_ACCOUNT_ID`, `SUPABASE_URL` (`https://<ref>.supabase.co`, solo el origen) y `SUPABASE_PUBLISHABLE_KEY` (`sb_publishable_…`, nunca una secreta): un solo valor para la web (`VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` y la CSP) y para `/gestione/` (`--dart-define`). Además `VITE_TURNSTILE_SITE_KEY` (la real: el workflow rechaza las de prueba), `VITE_SITE_URL`, `VITE_NOINDEX` y, opcional, `VITE_BRAND_NAME`. En producción falla antes de publicar si falta la configuración de Supabase o de Turnstile; en una vista previa solo avisa.
  - `SUPABASE_PUBLISHABLE_KEY` se compara con una lista de permitidas (`sb_publishable_…` o un JWT con rol `anon`, sin espacios): cualquier otra cosa corta, también en una vista previa.
  - Solo en producción: corta si `ALLOWED_ORIGINS` (la misma variable de `deploy-supabase.yml`; si no está en GitHub, solo avisa) no incluye el origen de `VITE_SITE_URL`, y si la privacy sigue en borrador (texto entre corchetes en `privacy.*` o el aviso de borrador de `web/privacy/index.html`). Para una prueba interna antes de completarla, la variable `ALLOW_DRAFT_PRIVACY=true` la deja pasar con un aviso. Después de publicar prueba el CORS de `public-request` desde el sitio (solo avisa).
  - Id del build (producción y vistas previas): los 7 primeros caracteres del commit que se publica (`BUILD_ID`, el mismo de `--commit-hash`). `/gestione/` se compila con `--dart-define=BUILD_ID=<id>` y el mismo id va en `gestione/build.json` (`{"buildId":"<id>"}`); el workflow corta si `main.dart.js` no lo tiene. La app lee `build.json` (sin caché del navegador y con `?t=<ms>`) al abrir y al volver a primer plano, como mucho una vez cada 5 minutos, y si el id es otro muestra «Hay una versión nueva · Actualizar»; nunca recarga sola. `version.json` no sirve para esto: el build no pasa `--build-number` y siempre dice `1.0.0+1`. El id es el del commit, no el del contenido: un deploy que solo cambia la web pública también muestra el aviso, y volver a publicar el mismo commit (por ejemplo, después de cambiar `SUPABASE_URL` o `SUPABASE_PUBLISHABLE_KEY`, que quedan compiladas en la app) no lo muestra: ahí Evelyn tiene que recargar a mano.
  - Solo en producción, después de publicar (`.github/scripts/check-gestione-cache.sh`, con tests contra un servidor local en el `npm test` de la raíz): espera a que `<VITE_SITE_URL>/gestione/build.json` muestre el id nuevo (si no llega, solo avisa) y pone el run en rojo si `/gestione/main.dart.js` o `/gestione/flutter_bootstrap.js` no responden `200` con `Cache-Control: no-cache` (hasta 6 intentos por archivo, cada 10 s, por la propagación; un corte de la conexión o un timeout de curl cuenta como un intento más). Sin `VITE_SITE_URL` también falla: no puede comprobar nada. Solo imprime el estado, `Cache-Control` y el id. Si falla por la caché, ver §10.1, paso 9.
  - Las vistas previas usan el backend de producción para la web, fuera de `ALLOWED_ORIGINS` (§4); su `/gestione/` va sin backend.
  - Concurrencia: un grupo por PR y otro por rama; un PR (también de un fork) nunca cancela producción, y producción no se corta a la mitad.
- Los dos workflows corren por separado y sin orden: un push a `main` que toque `supabase/functions/_shared/**` dispara los dos. La web puede quedar publicada aunque falle el backend; por eso la prueba de CORS y el orden de §10.
  - Una migración que agrega algo que leen la app o la web (como `requests.no_allergies`, que pide la bandeja) va en un PR propio, antes que el código que la usa, y tiene que andar con la función y la web que siguen en producción. Se mergea ese PR, se espera a que Deploy Supabase termine en verde y recién después se mergea el resto. Con todo en un solo merge, si Deploy web termina primero, `/gestione/` no carga la bandeja hasta que corre la migración. Correr Deploy Supabase a mano desde la rama antes del merge no sirve: publica también la función nueva mientras sigue en línea la web vieja.
  - Pregunta de alergias (versión 2): primer PR con `supabase/migrations/20261115120000_requests_no_allergies.sql`, `supabase/tests/database/09_allergy_answer.test.sql` y `supabase/seed.sql` (la función de la versión 1 sigue guardando pedidos con esa migración: caso "vieja" del test); segundo PR con la función, la web, la app y los documentos.
  - Precio por semanas (16/11/2026): primer PR con `supabase/migrations/20261116120000_weekly_pricing.sql`, `supabase/tests/database/12_weekly_pricing.test.sql` y `supabase/seed.sql`: `requests.weeks`, las columnas del precio por semana de `chef_settings`, los checks del costo por porción (de 0 a 100000; las filas de producción, 380 y 250, los cumplen) y `p.weeks` en `submit_public_request` (§3). La función de hoy sigue guardando pedidos con esa migración: no manda `weeks` y quedan en 1 (caso "sin weeks" del test). Segundo PR con el motor de presupuesto, la función, la web, la app y los documentos (versión 3 del contrato). La app de ese PR lee `requests.weeks` y la función, las columnas nuevas de `chef_settings` (sin ellas responde `500` en `load_chef` y no guarda nada): se mergea recién con Deploy Supabase del primero en verde.
    - La función nueva acepta la versión 3 y la 2, así que atiende a la web de antes; la de antes rechaza la 3 por versión y nunca guarda un pedido de varias semanas como si fuera de una. Para no tener los minutos de "página desactualizada" del punto siguiente: con el PR aprobado y el primero ya en producción, correr Deploy Supabase a mano desde la rama (`workflow_dispatch`) justo antes del merge, como con la ventana de 8 semanas. Sirve porque el segundo PR no trae migraciones y la web de antes anda con la función nueva. El merge después publica la web y vuelve a desplegar la misma función. Sin ese paso, si Deploy web termina antes, unos minutos los envíos de la web nueva reciben "página desactualizada" (`version: invalid`).
    - Mientras queden páginas de la versión 2 abiertas, sus pedidos se guardan de una semana con la estimación nueva (§2, «Semanas y estimación»).
  - Un cambio de versión del contrato (como la 2) deja igual unos minutos, entre los dos despliegues del segundo PR, en que la web y la función no coinciden y los envíos reciben "página desactualizada".
  - Ventana de 8 semanas (15/11/2026): un solo PR con la migración, la función, la web y los documentos, porque la migración no agrega nada que lean la web o la app y la función de antes anda con la base nueva. `db push` deja `booking_horizon_days` en 56 antes de publicar la función, y la de antes sigue pidiendo 14 días. Unos minutos la web y la función pueden no coincidir (14 contra 56 días): ninguna combinación rompe el calendario (§11) y una fecha que la función de antes todavía rechaza recibe `dateOutOfRange`, con su mensaje (§2). Ese mensaje pide «un día de las próximas 8 semanas» aunque la fecha ya está dentro, y si ninguno de los 14 días que manda la función de antes está libre, el calendario dice que no hay días libres en las 8 semanas.
  - Para no tener esos minutos (ventana de 8 semanas): con el PR aprobado y la migración ya definitiva, correr Deploy Supabase a mano desde la rama (`workflow_dispatch`) justo antes del merge. Acá sí sirve, al revés que con la pregunta de alergias: la web de antes anda con la función nueva, porque no valida el largo de la respuesta y solo manda fechas hasta +14, que la nueva acepta. El merge después publica la web y vuelve a desplegar la misma función, sin migraciones pendientes. Hasta el merge, producción tiene una migración que main no tiene y cualquier Deploy Supabase desde main falla en `db push`: si el PR no se mergea enseguida, hay que arreglarlo a mano.
  - La versión de una migración nueva tiene que ser posterior a la última aplicada en producción: `db push` corre sin `--include-all` y rechaza una más vieja (corta antes de aplicar nada). Con ramas en paralelo, la que llega segunda a producción lleva la versión más nueva: `20261115120000_requests_no_allergies.sql` va antes que las de los horarios libres del calendario (`20261115130000` y `20261115130100`). Si esas llegan antes, cambiarle la versión a una libre posterior antes de mergearla (y actualizar §3). Lo mismo con el catálogo de platos (`20261116170000_recipe_catalog.sql`, de otra rama): llega a producción después de la migración del primer PR del precio por semana (`20261116120000`) y de las de la base de las reservas, que lo siguen en la misma cadena (`20261116150000` y `20261116150100`). Si llegara antes, `db push` rechazaría esas tres y habría que darles versiones posteriores (y actualizar §3 y sus referencias).
- Las actions de terceros van fijadas por SHA con su versión en un comentario; Dependabot (`.github/dependabot.yml`) propone las actualizaciones. `ci.yml` corre con `contents: read`.

## 9. Conservación de datos: prospectos que no avanzan

SPEC §6 y la privacy: un prospecto cuyos pedidos no avanzan se borra, con todo lo suyo, cuando pasan `chef_settings.prospect_retention_days` (90 por defecto) desde su **último** pedido; un pedido nuevo de la misma persona vuelve a contar desde ahí. La privacy lo dice así ("90 giorni dopo l'ultima richiesta della stessa persona"). Migraciones `20261019150000_prospect_retention.sql` y `20261019160000_public_request_hardening.sql`.

- `private.purge_expired_prospects()` borra cada cliente que cumple `private.prospect_retention_expired(client_id)`:
  - prospecto sin cuenta (`status = 'prospect'`, `profile_id` null);
  - sin pedidos que avanzaron: todos en `new`, `rejected`, `expired` o `declined` (uno en `quoted`, `accepted` o `resolved` lo conserva);
  - sin sesiones vivas (todas `cancelled`) ni pagos registrados (un pago es un registro contable);
  - y con el último pedido (o el alta, si no tiene pedidos) de hace más de `prospect_retention_days` de su cocinera (90 si faltara su `chef_settings`).
- En cascada se van sus pedidos (con la copia del contacto) y presupuestos, consentimientos, restricciones y sesiones canceladas; además se borran las notificaciones cuyo `payload.request_id` apunta a esos pedidos (de cualquier tipo) y los intentos de `private.public_request_hits` de más de 1 día.
- Conservar a una persona que ya es clienta (Fase 0: servicios acordados por WhatsApp, fuera del sistema): en la app, "Segna come cliente" en cualquiera de sus pedidos, que pasa la ficha de `prospect` a `trial`; la regla de arriba ya no la alcanza. A mano: `update public.clients set status = 'trial' where id = '<client_id>' and status = 'prospect';`.
- Devuelve `{ "clients", "requests", "notifications", "rate_limit_hits" }` (cuántos borró) y deja en el log de Postgres solo esos contadores. Idempotente: otra corrida no borra nada más.
- Concurrencia: por cada candidato toma el mismo lock que `submit_public_request` (cocinera + email), bloquea la ficha y sus pedidos, y vuelve a evaluar la regla. Un pedido nuevo de esa persona lo conserva, o espera a que termine el borrado y crea un prospecto nuevo. Si justo se registra un pago, ese cliente se conserva y el resto sigue.
- Las dos funciones están en el esquema `private`: ningún rol de la API las ejecuta (tampoco `service_role`).
- pg_cron (Supabase Cron): la migración habilita la extensión como indica Supabase (`create extension if not exists pg_cron with schema pg_catalog`; la imagen de Postgres de Supabase ya la precarga, en local y en el proyecto alojado) y programa el trabajo `radici-purge-expired-prospects` todos los días a las 03:30 UTC (04:30 o 05:30 en Roma), como `postgres`. `cron.schedule` con un nombre existente actualiza ese trabajo: volver a correr la migración no lo duplica.
- A mano, desde el SQL editor: `select private.purge_expired_prospects();`. Las corridas quedan en `cron.job_run_details` (Supabase no limpia esa tabla sola; es una fila por día).
- No cubre a los clientes con cuenta: su borrado (derecho de supresión) es el de la cuenta, en M2.

## 10. Puesta en marcha y operación

### 10.1 Primer despliegue, en este orden

Nada que publique `SUPABASE_URL` y la clave publicable (producción o una vista previa) antes del paso 6: con las altas abiertas, cualquiera que conociera el email de Evelyn podía registrarse antes que ella con una contraseña propia y entrar después como cocinera (`promote_to_chef` ahora también lo impide, §3). Por eso las variables `SUPABASE_URL` y `SUPABASE_PUBLISHABLE_KEY` de la web (paso 7) van después.

1. Privacy: completar lo que está entre corchetes en `privacy.*` de `web/src/i18n/{it,es,en}.json` (titular, contactos, razones sociales de los proveedores, quién da la asistencia técnica y las dos notas "[da verificare …]"), hacerla revisar y sacar el aviso de borrador (`<p class="draft">` de `web/privacy/index.html` y las claves `privacy.draftBadge` y `privacy.draftNotice`). Hasta entonces producción solo se publica con la variable `ALLOW_DRAFT_PRIVACY=true` (prueba interna, sin compartir el sitio).
2. Supabase: proyecto `radici` en la región Central EU (Frankfurt), con la Data API y sin "Automatically expose new tables".
3. Resend: dominio `radicicucina.app` (región UE) con sus registros DNS en Cloudflare; dos claves "Sending access" para ese dominio: una para la función (`RESEND_API_KEY`) y otra para el SMTP de Auth (`RESEND_SMTP_KEY`). Sin seguimiento de aperturas ni clics.
4. Cloudflare Turnstile: un widget con el hostname `radicicucina.app` (modo managed). Sitekey → `VITE_TURNSTILE_SITE_KEY` (paso 7); secreta → `TURNSTILE_SECRET_KEY` (paso 5).
5. GitHub, para el backend: secretos `SUPABASE_ACCESS_TOKEN` (token de supabase.com/dashboard/account/tokens, solo para este proyecto), `SUPABASE_DB_PASSWORD`, `RESEND_SMTP_KEY` y los de la función (§8); variables `SUPABASE_PROJECT_REF`, `CHEF_LOGIN_EMAIL` (el email con que entra Evelyn), `CHEF_DISPLAY_NAME` (`Evelyn`) y las de la función. Nunca valores de `supabase/functions/.env.example`.
6. Deploy Supabase (push a `main` o a mano), en verde y sin "Faltan …". Hace lo que antes eran pasos en el panel:
   - Auth desde el repo (`supabase/scripts/auth-config.ts`), en tres partes. Siempre: altas apagadas, código de 8 cifras que vale 600 segundos y CAPTCHA apagado (la app no manda el token; para M2 hay que sumar el proveedor y su secreto a `auth-config.ts`). Con `RESEND_SMTP_KEY`: SMTP propio con Resend (`smtp.resend.com`, puerto 465, usuario `resend`, remitente de `MAIL_FROM`), después las plantillas "Magic link" y "Confirm signup" con el asunto de `supabase/config.toml` y el HTML de `supabase/templates/login_code.html`, y 100 emails por hora (cualquiera puede pedir un código por minuto para el email de Evelyn: 60 por hora; el límite es de todo el proyecto). En un proyecto Free, Supabase no deja cambiar las plantillas sin SMTP propio: sin `RESEND_SMTP_KEY` el email trae un link en lugar del código y **Evelyn no puede entrar** (el workflow avisa y sigue). Si Supabase no guardara la plantilla, el paso falla. Se vuelve a aplicar en cada despliegue: cambiar la plantilla o el asunto es un PR, y lo que se cambie de esto en el panel lo pisa el próximo despliegue.
   - La cuenta de Evelyn, solo si todavía no hay ninguna cocinera: usuario confirmado con una contraseña al azar que nadie conoce y `user_metadata.locale` = `CHEF_LOCALE` (el email del código sale en su idioma), y `promote_to_chef(CHEF_LOGIN_EMAIL, CHEF_DISPLAY_NAME)`. Si ya hay una cuenta con ese email sin confirmar (la registró otro antes de apagar las altas, o se creó en el panel sin "Auto Confirm User"), el paso falla y dice que hay que borrarla. El log dice cuántos usuarios hay en Auth (tiene que ser 1).
   - Migraciones, secretos y las funciones (`public-request` y `chef`).
   - Horario de Evelyn (§11.1), lunes a viernes de 9 a 15: a una cocinera que ya existe y no tiene reglas se lo da la migración `20261115130100_default_availability.sql`. En un proyecto nuevo `db push` corre antes de crear la cuenta, así que el paso de la cuenta se lo carga justo después de `promote_to_chef` (`private.add_default_availability()`; el log dice cuántas reglas). Sin reglas, el calendario de la web no marca ningún día.
   - Sin `TURNSTILE_SECRET_KEY` corta en "Secretos de la función", con Auth, las migraciones y la cuenta ya hechas: completar el paso 4 y volver a correrlo.
7. GitHub, para la web: variables `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `VITE_TURNSTILE_SITE_KEY` y las demás de §8.
8. Revisar en el panel (solo mirar): Authentication → Sign In / Providers, Emails (SMTP y plantillas), Rate Limits y Users; en el SQL editor, `select id, email, email_confirmed_at, created_at from auth.users;` (no tiene que haber otro usuario además de Evelyn). Para crear la cuenta a mano en lugar del workflow, antes del paso 7: Authentication → Users → Create new user con "Auto Confirm User", y después, en el SQL editor, `select public.promote_to_chef('<email>', 'Evelyn');` y `select private.add_default_availability();` para su horario inicial (§11.1). También se pueden cargar `CHEF_LOGIN_EMAIL` y `CHEF_DISPLAY_NAME` y volver a correr el paso 6, que promueve la cuenta existente y le carga el horario. Esa cuenta no lleva `user_metadata.locale`: el email del código le llega en italiano hasta que elige su idioma en la app.
9. Deploy web: en verde. En Pages, el dominio propio `radicicucina.app`. La prueba de CORS del workflow no tiene que avisar nada. En la zona `radicicucina.app` de Cloudflare, Caching → Configuration → Browser Cache TTL en «Respect Existing Headers» (hecho el 16/11/2026; la otra opción es una Cache Rule para `/gestione/*` que respete el origen). Con el valor de fábrica, Cloudflare cambiaba el `Cache-Control: no-cache` de `/gestione/*` por `max-age=14400` y el iPhone podía seguir hasta 4 horas con la versión vieja, aunque «Actualizar» recargara. Se comprueba con `curl -sI https://radicicucina.app/gestione/main.dart.js`, que tiene que decir `cache-control: no-cache`; cada deploy de producción lo comprueba solo (§8). Los archivos con hash de `/assets/*` siguen con `max-age=31536000, immutable`.
10. Evelyn entra en `https://radicicucina.app/gestione/` con el código del email (si la interfaz no está en español: Impostazioni → Español).
11. Un pedido de prueba con un email propio: pantalla de gracias, aviso a Evelyn en español, confirmación en italiano y aviso en `/gestione/`. En los logs de la función, `request_saved` y `email_sent`, sin `config_missing`, `client_ip_missing` ni `email_failed`. Después, borrarlo (10.2, "Borrar a una persona").
12. Recién ahí compartir el sitio.

### 10.2 Pedidos de las personas sobre sus datos

La privacy promete acceso, rectificación, supresión, portabilidad, oposición y retiro del consentimiento, con respuesta dentro de un mes. La app no exporta, no corrige pedidos y no borra: se hace desde el SQL editor (como `postgres`). Reemplazar `<email>`, `<client_id>` y `<request_id>`.

- Encontrar a la persona (cada pedido de la web guarda además el contacto con que llegó):

  ```sql
  select cl.id, cl.status, cl.display_name, cl.contact_email, cl.contact_phone, cl.zone, cl.created_at
  from public.clients cl where lower(cl.contact_email) = lower('<email>');
  select r.id, r.client_id, r.created_at, r.contact
  from public.requests r where lower(r.contact ->> 'email') = lower('<email>');
  ```

- Acceso y portabilidad (un JSON para mandarle):

  ```sql
  with persona as (select cl.id from public.clients cl where lower(cl.contact_email) = lower('<email>'))
  select jsonb_pretty(jsonb_build_object(
    'fichas',          (select jsonb_agg(to_jsonb(cl)) from public.clients cl where cl.id in (select id from persona)),
    'pedidos',         (select jsonb_agg(to_jsonb(r)) from public.requests r where r.client_id in (select id from persona)),
    'sesiones',        (select jsonb_agg(to_jsonb(s) order by s.date, s.start_time) from public.sessions s where s.client_id in (select id from persona)),
    'consentimientos', (select jsonb_agg(to_jsonb(c)) from public.consents c where c.client_id in (select id from persona)),
    'restricciones',   (select jsonb_agg(to_jsonb(cr)) from public.client_restrictions cr where cr.client_id in (select id from persona))));
  ```

- Rectificación: la ficha y, si hace falta, la copia de un pedido (es lo que muestra la app):

  ```sql
  update public.clients set contact_phone = '<+39…>' where id = '<client_id>';
  update public.requests set contact = contact || jsonb_build_object('phone', '<+39…>') where id = '<request_id>';
  ```

- Retiro del consentimiento de salud (borra las restricciones del hogar y, de sus pedidos, las copias y el "hay alergias", §3):
  `select private.revoke_health_consent('<client_id>');`
- Alergias de otra persona (un familiar o un invitado de quien hizo el pedido) que pide que se borren (privacy §5): sacar sus datos de la nota de ese pedido o, si no se pueden separar, borrar la copia entera (el pedido queda sin respuesta y la app avisa que hay que preguntar):
  `update public.requests set restrictions = jsonb_set(restrictions, '{note}', to_jsonb('<nota sin sus datos>'::text)) where id = '<request_id>';`
  `update public.requests set restrictions = null, no_allergies = null where id = '<request_id>';`
- Datos de salud escritos en las notas libres (sin consentimiento; la privacy §5 dice que se borran):
  `update public.requests set notes = null where id = '<request_id>';`
- Borrar a una persona (supresión; también un pedido de prueba). En cascada se van sus pedidos, presupuestos, consentimientos, restricciones y todas sus sesiones, no solo las canceladas: también las semanas por venir de una reserva, cuyos días vuelven a quedar libres en el calendario de la web. Si tiene pagos registrados falla (son registro contable): conservar solo eso y consultar. Un cliente con cuenta se borra con su cuenta (M2).

  ```sql
  begin;
  delete from public.notifications n
  where n.payload ->> 'request_id' in (select r.id::text from public.requests r where r.client_id = '<client_id>');
  delete from public.clients where id = '<client_id>';
  commit;
  ```

- Fuera de la base: borrar sus emails (avisos y respuestas) del buzón de Evelyn y su chat de WhatsApp. Los emails enviados también quedan en el panel de Resend durante el tiempo que guarde su plan.

### 10.3 Emails y chats de las solicitudes que no avanzan

La privacy promete borrarlos dentro de los 30 días siguientes al borrado de la solicitud (§9). En el buzón de Evelyn (`CHEF_NOTIFY_EMAIL`), un filtro que etiquete "Radici" los avisos ("Nueva solicitud …") y las respuestas de los clientes. Una vez al mes, esta lista (aproximada: no mira los estados) dice quién se borra en los próximos 30 días; cuando ya no está en la app, borrar sus emails y su chat de WhatsApp:

```sql
select cl.display_name, cl.contact_email, cl.contact_phone, coalesce(max(r.created_at), cl.created_at) as ultimo_pedido
from public.clients cl left join public.requests r on r.client_id = cl.id
where cl.status = 'prospect' and cl.profile_id is null
group by cl.id
having coalesce(max(r.created_at), cl.created_at) < now() - interval '60 days'
order by ultimo_pedido;
```

## 11. Disponibilidad por día: `GET /functions/v1/public-request/availability?minutes=N`

Agregada el 15/11/2026 para el calendario del formulario. Código del contrato: `supabase/functions/_shared/availability.ts` (lo comparten la función y la web; tests en `availability.test.ts`). Si este documento y ese archivo difieren, manda el archivo. La ruta está en `supabase/functions/public-request/handler.ts` (tests en `handler.test.ts`).

- Pública (sin login), como el `POST`. La URL termina en `/availability` (`AVAILABILITY_PATH`), antes de la query. La web agrega siempre `?forceFunctionRegion=eu-central-1` (`availabilityUrl`), como en el `POST` (§2), así la consulta también corre en Frankfurt; la función no lo lee y de la query solo usa `minutes`.
- `minutes`: los minutos de cocina que calcula el motor de presupuesto para el pedido (los de una sesión: con varias semanas, la web usa la misma respuesta para el mismo día de las semanas siguientes). Entero de 30 a 720, en pasos de 30 (`AVAILABILITY_MINUTES`, `parseAvailabilityMinutes`).
- Respuesta `200` (`AvailabilityResponse`, armada con `buildAvailabilityResponse`):

  ```json
  { "version": 1, "minutes": 180, "days": [{ "date": "2026-11-16", "available": false }, { "date": "2026-11-17", "available": true }] }
  ```

  Un día por cada fecha de la ventana del formulario (`DATE_WINDOW`: de mañana a +56, 8 semanas, en Roma; `AVAILABILITY_DAYS` = 56; actualizado el 15/11/2026, antes 14), en orden y sin huecos. `available` es `true` si Evelyn tiene al menos un horario libre ese día para esa duración (SPEC §5.2, `get_free_days`). "Hoy" es la fecha de Roma en la función. La web la lee con `parseAvailabilityResponse`: con otra forma, otra `version` o un error, el calendario no marca disponibilidad y deja elegir cualquier día de la ventana.

  El largo no se valida, a propósito: el calendario busca cada fecha de su ventana en la respuesta, así que las que no vienen cuentan como no disponibles y las que sobran no se muestran. Por eso un cambio de ventana no sube `AVAILABILITY_VERSION` ni rompe el calendario mientras se despliega: con la función de antes (14 días), la web nueva marca no disponibles los días 15 a 56 y no guarda esa respuesta en su caché por duración (`coversWindow`), así que al volver a esa duración la pide de nuevo; una página de antes abierta (14 días) con la función nueva usa los primeros 14 y deja afuera el resto. El calendario muestra un mes por vez, con flechas: la ventana toca dos o tres meses.

| Código | Cuerpo | Cuándo |
|---|---|---|
| 200 | `AvailabilityResponse` (arriba) | — |
| 400 | `{ "errors": { "minutes": "invalid" } }` | `minutes` falta o no es un valor aceptado |
| 405 | `{ "error": "method" }` + `Allow: GET, OPTIONS` | otro método (un `POST` a esta ruta no es un pedido) |
| 429 | `{ "error": "rateLimited" }` + `Retry-After: 3600` | más de 120 por hora o 600 por día por IP |
| 500 | `{ "error": "server" }` | configuración: falta `IP_HASH_SALT`, `CHEF_ID` inválido o no se puede elegir la cocinera (`chef_id_unresolved`) |
| 503 | `{ "error": "server" }` | error de la base (límite, cocinera o `get_free_days`), sin detalles |

- CORS: la misma `ALLOWED_ORIGINS` que el `POST`. Un `GET` simple no necesita preflight; si lo hay, permite `GET, POST, OPTIONS`. Siempre `Vary: Origin`.
- Caché: el `200` y el `400` llevan `Cache-Control: public, max-age=60` (dependen solo de la URL y del origen); los demás, `no-store`, para que un error o un `429` no queden guardados.
- Límite por IP propio: la misma `hit_public_request_rate` (§3) con otra clave, el HMAC de `availability:<ip>` (de una IPv6, su /64; sin IP, `availability:unknown`). Es otro contador en `private.public_request_hits`: las lecturas no gastan el cupo del formulario (5 por hora, 20 por día) ni al revés, y no hizo falta migración. Más generoso (`AVAILABILITY_RATE_LIMITS`: 120 por hora, 600 por día) porque cada cambio de personas, días o comidas puede pedir otra duración.
- Privacy (versión `2026-11-16`, §6): `privacy.flowBody` dice que el calendario consulta la disponibilidad antes de enviar, solo con la duración estimada; `legalBody` y `retentionBody` suman estas consultas al límite por IP (interés legítimo; la huella dura 2 días como máximo). Si cambia lo que manda la consulta o lo que se guarda por IP, cambian la privacy y su versión.
- No pasa por Turnstile (es una lectura): de la configuración (§4) usa `IP_HASH_SALT` y, si está, `CHEF_ID`. La cocinera se elige igual que en el `POST`.
- Pide `get_free_days(cocinera, minutes, mañana, AVAILABILITY_DAYS)` (56 días) con la clave secreta (`PublicRequestStore.freeDays`, `supabase.rpc` en `index.ts`); una respuesta con otra forma cuenta como error de la base (`unexpected_result`).
- Logs: nunca la IP. `rate_limited` con `route: "availability"`, `db_error` con la operación (`rate_limit`, `resolve_chef` o `free_days`) y el código, y los de configuración del `POST` (`config_missing`, `config_invalid`, `chef_id_unresolved`, `client_ip_missing`).

### 11.1 Base de datos

Migraciones `20261115130000_free_slots.sql`, `20261115130100_default_availability.sql` y `20261115130200_booking_horizon_8_weeks.sql`; tests pgTAP `07_free_slots`, `08_default_availability` y `10_booking_horizon`.

- `public.get_free_days(p_chef_id uuid, p_cook_minutes int, p_from_date date, p_days int) returns table (day date, available boolean)`: cada fecha de `[p_from_date, p_from_date + p_days − 1]`, en orden, con `available` si hay al menos un horario libre. Las fechas fuera de la ventana (hoy, el pasado, después de `booking_horizon_days`) salen en `false`.
- `chef_settings.booking_horizon_days` es la ventana de la base y tiene que ser la del contrato (`DATE_WINDOW.maxDaysAhead`): 56 por defecto desde `20261115130200_booking_horizon_8_weeks.sql`, que también pasó a 56 a las cocineras que seguían en 14 (en producción, Evelyn; un valor distinto de 14 no se toca) con `private.replace_booking_horizon(14, 56)`. Esa función pasa a `p_to` las filas que siguen en `p_from`, pone `updated_at` y devuelve cuántas cambió (otra corrida no cambia nada); ningún rol de la API la ejecuta. `availability.test.ts` compara el último valor por defecto de las migraciones con el contrato y exige que la migración que lo cambie la llame con el valor anterior y el nuevo; `10_booking_horizon` prueba la función (`db reset` corre las migraciones sobre una base vacía, así que en los tests la llamada no encuentra filas) y `07_free_slots`, el valor por defecto y el corte en hoy + 56.
- `public.get_free_slots(p_chef_id uuid, p_cook_minutes int, p_from_date date, p_days int) returns table (day date, start_time time)`: los horarios para mostrar (hasta 3 por día, separados al menos 2 h, en los primeros 5 días con lugar; `start_time` es la llegada a la casa, hora de Roma). Todavía no lo usa nadie: es para la pantalla Pedir de la app y los presupuestos.
- Las dos salen de `private.free_slot_candidates(…, p_now timestamptz default now())`, el generador común, con la regla de choque de `no_overlap` (SPEC §5.2), y validan los datos: `22023` con `invalid_cook_minutes` (de 1 a 720), `invalid_days` (de 1 a 366) o `invalid_from_date` (null o infinita), y `P0002` con `chef_not_found`.
- Las ejecuta **solo** `service_role` (ni `anon` ni `authenticated`, tampoco la cocinera): la web no lee horarios con una RPC anónima, sino por esta ruta, con CORS y límite por IP. Son `security definer` con `search_path` vacío porque el generador vive en el esquema `private`, fuera de la API (ni `service_role` tiene `USAGE` ahí); corren como su dueño solo para poder llamarlo.
- Horario inicial (decisión del dueño del 15/11/2026, hasta que la app tenga editor de disponibilidad): `private.add_default_availability()` le da lunes a viernes de 9:00 a 15:00 a cada cocinera sin ninguna regla, y devuelve cuántas reglas agregó. Es idempotente y ningún rol de la API la ejecuta. La corren la migración, para las cocineras que ya existen, y en un proyecto nuevo `deploy-supabase.yml`, justo después de `promote_to_chef` (la cuenta se crea después de `db push`; §10.1, paso 6). Si la cuenta se crea a mano, también se corre a mano (§10.1, paso 8). Con 45 min de compra, la primera llegada es a las 10:00 y una sesión de más de 300 min no entra ningún día.
