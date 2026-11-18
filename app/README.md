# Radici · app Flutter

App de Evelyn (cocinera) y sus clientes, para iOS y Android, y la misma app como web en `/gestione/`.
Paquete Dart: `radici`. Reglas del proyecto: `../SPEC.md` y `../CLAUDE.md`.
El bundle id nativo todavía es el provisorio: ver [TODO: bundle id definitivo](#todo-bundle-id-definitivo).
Pedidos de la web, bandeja y avisos: `../docs/contracts/public-request.md` (§7 es esta app).

## SDK

Usar siempre Flutter **3.47.7** (el mismo que el CI):

```bash
# Windows (bash)
/c/Users/NicolasMansillaBened/dev/flutter-3.47.7/bin/flutter --version
```

El `flutter` del PATH puede ser otra versión: en los comandos de abajo, `flutter` y `dart` son los de 3.47.7.

## Primera vez

```bash
cd app
flutter pub get                    # también genera lib/l10n/app_localizations*.dart
dart run build_runner build        # genera *.freezed.dart y *.g.dart
cp env/dev.example.json env/dev.json   # completar si hay backend (ver abajo)
```

El código generado no se versiona: hay que regenerarlo después de cambiar modelos freezed o ARB
(`dart run build_runner watch` lo hace solo mientras se trabaja).

## Correr

```bash
flutter run --dart-define-from-file=env/dev.json
```

Sin `--dart-define-from-file` la app arranca como `dev` sin backend.

## Entornos

Los valores se inyectan al compilar con `--dart-define-from-file` y se leen en `lib/core/env.dart`.

| Clave | Valores | Uso |
|---|---|---|
| `APP_ENV` | `dev` · `prod` | Otro valor hace fallar el arranque |
| `SUPABASE_URL` | `https://<ref>.supabase.co` | Vacío: la app arranca sin backend |
| `SUPABASE_PUBLISHABLE_KEY` | clave **publicable** (`sb_publishable_...` o la anon) | Nunca la `service_role` ni claves secretas |

- `env/dev.example.json` y `env/prod.example.json` se versionan como plantilla; los `env/*.json` reales están ignorados.
- Si falta la URL o la clave, no se inicializa Supabase. En `dev` aparece un aviso discreto al pie: "Backend non configurato".
- Por ahora no hay flavors nativos: dev y prod comparten el bundle id (hoy el provisorio, ver abajo). Los flavors con bundle id propio llegan en M8.

## TODO: bundle id definitivo

El nombre visible ya es **Radici** (`android:label` en `android/app/src/main/AndroidManifest.xml`,
`CFBundleDisplayName` y `CFBundleName` en `ios/Runner/Info.plist`, `appTitle` en los ARB). El
identificador nativo sigue siendo el provisorio `com.sepusola10.mestolo` hasta que se elija el
definitivo, **antes de la primera subida a las tiendas** (después no se puede cambiar; SPEC §14).
Lugares a cambiar, todos en `app/`:

1. `android/app/build.gradle.kts`: `namespace` y `applicationId` (`"com.sepusola10.mestolo"`).
2. `android/app/src/main/kotlin/com/sepusola10/mestolo/MainActivity.kt`: la línea
   `package com.sepusola10.mestolo` y la carpeta, que se mueve a la del paquete nuevo
   (`kotlin/<id con / en lugar de .>/MainActivity.kt`). `android:name=".MainActivity"` del
   manifiesto es relativo al `namespace`: no cambia.
3. `ios/Runner.xcodeproj/project.pbxproj`: `PRODUCT_BUNDLE_IDENTIFIER` en 6 configuraciones:
   Runner (Debug, Release, Profile) = `com.sepusola10.mestolo` y RunnerTests (Debug, Release,
   Profile) = `com.sepusola10.mestolo.RunnerTests`.
4. Documentación: esta sección, SPEC.md §14 y `CLAUDE.md`.

Fuera del repo, cuando existan: App ID en Apple Developer / App Store Connect, la app en Play
Console y Firebase (FCM). Para comprobar que no quedó nada: `git grep -n -i mestolo` (desde la raíz).

## Verificar (lo mismo que el CI)

```bash
flutter pub get
dart run build_runner build
flutter analyze        # cero issues
flutter test
```

Los tests no necesitan Supabase: los repositorios de Supabase se prueban con el SDK real contra un
servidor HTTP simulado (`test/support/supabase_http_fake.dart`) y un Realtime simulado
(`test/support/fake_realtime_server.dart`, incluye corte y reconexión); providers y pantallas usan
repositorios falsos (`test/support/fakes.dart`).

## Qué hace

- **Login** con código por email (Supabase Auth, OTP de 8 cifras que vale 10 minutos; la app acepta de
  6 a 10): email → código → sesión. No crea usuarios (`shouldCreateUser: false`): hasta el área de
  clientes (M2) solo entra quien ya tiene uno; un email desconocido ve "non è abilitato all'accesso".
  La sesión la guarda supabase_flutter (SharedPreferences en el teléfono, localStorage en la web). El
  email del código llega en el idioma de `user_metadata.locale` (italiano si no hay; cambiar el idioma
  en Impostazioni también lo cambia).
- Después del login se lee el perfil (`profiles.role` y `profiles.locale`): `chef` → área de la
  cocinera, que empieza en **Hoy** (`/oggi`), también al abrir la app con la sesión guardada; un
  enlace directo (el botón del email, `/richieste/<id>`) abre lo suyo; la ficha de su cocina sale de
  `current_chef_id()` (la misma función que la RLS) y de su fila de `chefs`. Cualquier otro →
  "Area clienti in preparazione". La interfaz pasa al idioma del perfil (ver [Idioma](#idioma)). La
  barra de abajo tiene cuatro destinos: Oggi, Richieste, Agenda y Altro (desde 840 px, el mismo riel
  a la izquierda). Un colaborador de la cocinera (`chef_members`) entra igual, con su cuenta: ve y
  hace lo mismo que ella, e Impostazioni y el menú de la cuenta dicen «Collaboratore di Evelyn» en
  lugar del nombre (`chefAccountTitle`). El WhatsApp que le prepara el detalle de un pedido sale de
  su propio teléfono, así que escribe de parte de ella («ti scrivo da parte di Evelyn di Radici»,
  `contactWhatsAppMessageOnBehalf`) en lugar de «sono Evelyn».
- **Hoy** (`features/today/`): la sesión de hoy o, si hoy no hay, la próxima (la más cercana que no
  está cancelada). Con varias hoy, todas: primero las que todavía no terminaron, por llegada, y
  después las terminadas (pasó la hora en que termina la cocina, en hora de Roma, o ya está cocinada
  o cobrada); se reordena sola al minuto. Cada tarjeta dice la clienta, las horas de la sesión
  («Spesa dalle 09:15 · Arrivo 10:00 · fino alle 13:00», como en la ficha), las personas, el estado
  si no está confirmada (una de hoy que ya terminó dice «Terminata» si estaba confirmada o con la
  compra hecha; si está cocinada o cobrada, «Cucinata» o «Pagata»), las alergias resaltadas como en
  la ficha (con la nota de contaminación cruzada si hay gluten, SPEC §5.6; en una renovación, las
  del último pedido semanal de la web que se reservó, con su fecha, y, sin ningún dato o con solo
  una dieta, «Allergie: nessun dato nell'app, chiedile») y las notas de cocina, y abre la ficha.
  Abajo, en el
  tercio inferior del teléfono, «Come arrivare» (Apple Maps en el iPhone, Google Maps en el resto)
  y WhatsApp de la primera; sin dirección, WhatsApp y «Aggiungi indirizzo», como la ficha (con
  varias, una línea dice de quién son, con la hora primero: «Arrivo 16:00 · Marco Bianchi»; si no
  entra, se corta el nombre). El WhatsApp es el de la ficha
  (`sessionLinksFor`, con el mismo día de Roma con que Hoy elige la sesión): lleva la hora de
  llegada salvo en una sesión cocinada o cobrada (en Hoy no hay canceladas ni de días pasados) y,
  si lo manda un colaborador, escribe de parte de la cocinera («ti scrivo da parte di Evelyn di
  Radici…»). Pendientes de uno o dos toques: «N nuove richieste» (lleva a Richieste en «Nuove»,
  aunque se haya dejado en otra pestaña) y las reservas que terminan: las reservas semanales (un
  pedido semanal aceptado; no un presupuesto enviado ni una sesión extra) desde 7 días antes hasta 7
  días después de su última sesión viva (día de Roma; si ya pasó, «È finita la prenotazione di…»),
  salvo que la misma ficha ya tenga una sesión viva posterior (una renovación, otra reserva o una
  suelta: de dos reservas en paralelo queda la que termina última). Tocarla abre la ficha de esa
  sesión; «Rinnova», debajo, abre la hoja de la renovación (ver «Rinnova» más abajo): renovar 4
  semanas son dos toques, «Rinnova» y «Conferma 4 settimane», y al volver el pendiente ya no está,
  aunque la agenda no se haya podido volver a leer. Para el lector de pantalla, «Rinnova» es un
  solo nodo, «Rinnova la prenotazione di …», con la acción de tocar. La
  tira de 7 días (hoy y los 6 siguientes) usa lo de la Agenda: un punto por sesión, el número
  tachado si el día está bloqueado y un punto si es feriado en un día de trabajo; el lector de
  pantalla dice cuál es hoy; si los 7 no entran con 48 dp cada uno (menos de 368 dp de ancho, como
  360 o 320), van en dos filas (4 y 3); tocar un día abre la Agenda con ese día elegido y a la vista
  (su primera sesión, por encima del botón flotante), igual aunque la Agenda haya quedado
  desplazada: antes vuelve su lista arriba. "Hoy" es el día de Roma y cambia a la medianoche sin
  reabrir la app (`romeTodayProvider`, el de la Agenda). Deslizar para actualizar, o «Ricarica» en
  la barra de arriba (sin el gesto, que VoiceOver y el mouse de /gestione/ no hacen), vuelve a leer
  la bandeja, la disponibilidad y las sesiones. Mientras cargan las sesiones (también mientras
  Riverpod reintenta una lectura que falló), una rueda en el lugar de la tarjeta; si no se pudieron
  leer, el aviso con «Riprova» en su lugar; en los dos casos, los pendientes y la tira siguen.
  Mientras se lee la bandeja, los pendientes muestran una barra, y «Niente in sospeso» sale solo con
  la bandeja y las sesiones leídas. Sin ninguna sesión, lo dice y ofrece, con dos botones abajo, ir a
  las solicitudes o cargar una reserva a mano («Nuova prenotazione»).
- **Richieste**: pestañas Nuove (sin `seen_at` y no aceptadas), Viste, Prenotazioni (los pedidos
  `accepted`: una reserva es un pedido aceptado más sus sesiones) y Rifiutate, con contador de
  nuevas. En cada fila, la fecha preferida va en su propia línea: un resumen largo se corta en dos
  y no la tapa; una reserva sin fecha preferida (cargada a mano) no dice «Senza data». Abajo de
  «Prenotazioni», «Nuova prenotazione» (ver más abajo), también mientras la bandeja carga o si no se
  pudo leer: es también la acción de la pestaña vacía.
- **Franja**: la bandeja, el detalle y la agenda muestran mañana o tarde si el pedido la trae. La web
  ya no la pregunta y manda `any`, que la app lee como sin franja y no muestra (como los emails).
- **Agenda**: mes y semana con las **sesiones** (`features/sessions/`): en el mes, un punto por
  sesión en la celda (el texto accesible las cuenta) y, al tocar el día, sus bloques junto a la
  tarjeta del día; en la semana, bloques «Spesa dalle 09:15 · Arrivo 10:00 · fino alle 13:00» con
  las horas de cada sesión (`start_time`, `shop_minutes` y `cook_minutes` guardados en ella; nada
  fijo). Cada bloque abre la ficha de la sesión. `SessionsRepository` las lee con la RLS («la
  cocinera lee las suyas»), con la ficha (`clients`, y sus `client_restrictions`) y el pedido de la
  reserva embebidos por el nombre de la FK (`requests.target_session_id` también apunta a
  `sessions`), desde el lunes de la primera semana del mes de hoy, o desde 7 días antes de hoy si es
  antes (así Hoy tiene las reservas que terminaron hace hasta 7 días), o desde el lunes de la
  primera semana del mes elegido, si es anterior. Los pedidos que todavía no son una reserva siguen
  por `preferred_date` con la franja,
  más la lista "Senza data"; los `accepted` ya no (se ven por sus sesiones). "Hoy"
  (Europe/Rome) cambia a la medianoche sin reabrir la app: se vuelve a mirar la fecha a la
  medianoche y, como mucho, cada minuto (un Timer largo llega tarde si el teléfono se suspende).
  Si estaba elegido "hoy", la agenda pasa al día nuevo; si no, respeta el día elegido. Deslizar
  para actualizar, o «Ricarica» en la barra de arriba, vuelve a leer la bandeja, la disponibilidad
  y las sesiones (sin Realtime de sesiones). Mientras se lee la bandeja, una barra; si no se pudo
  leer, el error con «Riprova» (también en la primera lectura).
  Días bloqueados (`availability_exceptions`, sin migración: la RLS y los grants ya estaban): la
  tarjeta del día los bloquea o desbloquea con «Annulla» y una nota privada (los clientes no la
  ven; la cocinera y sus colaboradores, sí), y el botón
  «Blocca giorni» bloquea un rango (una fila por día, upsert que nunca pisa un bloqueo que ya
  existía). La web deja de ofrecerlos en 1 o 2 minutos (`get_free_days` los descuenta; la
  disponibilidad se cachea 60 s). Marca los feriados nacionales (Pasquetta calculada; San Francesco
  desde 2026, legge n. 151/2025) y Sant'Alessandro (26/8) como festivo local de Bergamo. Un día con
  sesiones (y el rango que las incluya) avisa que bloquearlo no las cancela; si las sesiones no se
  pudieron leer, el rango lo dice en lugar de callarse. La celda del día y cada bloque llevan la
  acción de tocar en su nodo de accesibilidad: en `/gestione/`, el clic de VoiceOver solo llega a
  un nodo que la tiene.
- **Ficha de la sesión** (`/sessioni/:id`, a pantalla completa; abierta con un enlace directo, sin
  nada debajo, su flecha de volver lleva a la Agenda): el día, «Settimana k di N» (sin
  contar las canceladas), las horas (el renglón se parte solo después de un «·»: nunca «fino alle»
  y la hora en dos renglones), «Come arrivare» (la dirección de la ficha en Apple Maps en el
  iPhone, también en `/gestione/` con Safari, y en Google Maps en el resto), WhatsApp en el idioma
  de la clienta (la fecha y, según la sesión, la hora de llegada; nunca la dirección ni las
  alergias) y llamar. Si la abre un colaborador, el WhatsApp sale de su propio teléfono y escribe
  de parte de la cocinera (`sessionWhatsAppMessageOnBehalf`; el del detalle es
  `contactWhatsAppMessageOnBehalf` y el de la reserva, `bookingWhatsAppMessageOnBehalf`): «ti
  scrivo da parte di Evelyn di Radici per la sessione di…, con arrivo di Evelyn alle 10:00» en
  lugar de «sono Evelyn… con arrivo alle 10:00». Los dos mensajes de la ficha (el de la cocinera
  y el del colaborador) describen el horario y no afirman que la llegada sea futura: valen también
  en una sesión de hoy cuya llegada ya pasó. La hora de llegada va solo si la sesión no está
  cancelada, cocinada ni cobrada y es de hoy en adelante (el día de Roma, que en una ficha abierta
  cambia a la medianoche); en las demás (de un día que ya pasó, cocinada, cobrada o cancelada) el
  mensaje nombra la sesión por su fecha, sin la hora: «Ti scrivo per la sessione di mercoledì 25
  novembre.» (`sessionWhatsAppMessageNoArrival`; de parte de la cocinera,
  `sessionWhatsAppMessageNoArrivalOnBehalf`). El formulario web
  no pide la dirección: sin ella, WhatsApp pasa a ser el botón principal y en lugar de «Come
  arrivare» va «Aggiungi indirizzo», que la guarda en la ficha (`clients.address`, con la RLS «la
  cocinera gestiona los suyos» y el grant por columna; vale para todas sus sesiones y se corrige
  desde la fila de la dirección). Después, las alergias de la ficha y del pedido, con la nota del
  pedido resaltada (también sola, como llega de la web) y, con gluten, la de contaminación cruzada
  (SPEC §5.6). En una sesión semanal cuyo pedido no responde (ni alérgenos, ni nota, ni «nadie
  tiene»; por ejemplo, una renovación, que no guarda alergias), las del último pedido semanal de la
  web que se reservó (aceptado) de la misma ficha, con una línea chica arriba: «Secondo la sua
  richiesta (19 ott 2026)» (`sessionAllergiesEarlierRequest`; la fecha de ese pedido, en Roma). Si
  ese pedido tampoco responde (anterior a la pregunta, o con la respuesta borrada al retirar el
  consentimiento de salud o a pedido de otra persona), no se busca uno anterior: un «nadie tiene»
  viejo ya no vale. Una sesión extra no las toma: los que comen pueden ser otros (SPEC §5.6), y un
  pedido rechazado, vencido o pendiente no cuenta (pudo mandarlo otra persona con su email). Ese
  pedido llega embebido en la ficha de cada sesión (`client.answers`: el más nuevo de los semanales,
  de la web y aceptados, `clientAnswersLimit` = 1): en la misma lectura que la sesión (en Hoy, la
  de la agenda), sin una consulta aparte que pueda fallar sola. Sin ningún dato (ni alérgenos de la
  ficha, ni nota o alérgenos del pedido o de ese otro, ni la confirmación «nadie tiene»), la
  advertencia «Allergie: nessun dato nell'app,
  chiedile» (`sessionAllergiesNoData`, con el ícono de aviso y el fondo de la de contaminación
  cruzada), nunca «sin alergias». Una dieta sola no responde sobre alergias: se muestra, debajo de
  la advertencia (en el detalle de un pedido, igual). Cada una es un nodo
  propio en el orden en que se ven (el lector de pantalla no las mezcla con el título); después,
  los datos de la clienta y las semanas de la reserva (cada una abre su ficha). En la última sesión
  viva de una reserva semanal (también cocinada o cobrada), al final: «È l'ultima sessione della
  prenotazione.» y «Rinnova» (`/sessioni/:id/rinnova`); si la ficha ya tiene otra sesión viva
  después (con la agenda leída, o una renovación hecha desde este dispositivo), «Ha già un'altra
  sessione: …», sin esconder el botón (con dos reservas en paralelo, cada una conserva el suyo). Va
  al final porque ese día la ficha es la de cocinar. Abajo, **Mover**:
  el calendario y una hoja (`/sessioni/:id/sposta`) que pide el `dryRun` de
  `POST chef/sessions/move` antes de confirmar (libre, un aviso, un choque o la semana con otra
  sesión de la reserva, que ofrece «Passa alla fine della prenotazione»: una por semana; no deja
  mover hasta que vuelve, y el lector de pantalla anuncia lo que dice); al mover, la ficha ofrece
  «Annulla», que la devuelve a su fecha y hora (si la hoja termina tapada por un pedido abierto
  desde el aviso, se cierra al volver a ella). Y **Cancelar** (`POST chef/sessions/cancel`), con
  confirmación (que no promete que la web vuelva a ofrecer el día: no lo hace si está bloqueado,
  pasó o no queda lugar), el motivo (la lista cerrada del contrato, preseleccionado el neutro
  `chef_cancelled`: la clienta con cuenta puede leerlo) y «anche le successive». Un 409
  `hasPayments` no cancela nada y dice qué semanas están cobradas, por fecha: si se cancelaba solo
  la de la ficha, ofrece pasarla al final de la reserva (decisión 5 del plan); si eran varias,
  cancelar solo las que no están cobradas (pasarla al final la dejaría detrás de las que se querían
  cancelar). Lo explica igual si llega al tocar «Riprova» después de una falla de red. La
  cancelación con devolución llega con los cobros (PR 10): la app nunca manda `allowWithPayments`.
  Mientras una sesión espera al servidor, Mover y Cancelar quedan deshabilitados. Lo que devuelve
  la función se aplica en la agenda y en la ficha sin volver a leer (también las que ya estaban
  canceladas en otro dispositivo, `alreadyCancelled`); los errores se traducen a
  `SessionFailure` sin loguear nada (contrato `docs/contracts/chef-api.md` §5 y §6). Los modelos
  no imprimen la dirección, las alergias ni las notas en `toString`.
- **Detalle**: todos los datos (también las restricciones), la estimación guardada y las acciones:
  WhatsApp (`https://wa.me/<número sin +>?text=…` en el idioma del cliente), llamar (`tel:`),
  email (`mailto:`), rechazar (`new` → `rejected`) y deshacer el rechazo (`rejected` → `new`;
  como ya estaba visto, vuelve a Viste), las dos con confirmación. Al abrirlo se marca visto.
  Si la persona es todavía un prospecto, avisa que sus datos se borran 90 días después de su último
  pedido y ofrece **Segna come cliente** (con confirmación): la ficha pasa a `trial` y se conserva
  (contrato §9). Una reserva cargada a mano no muestra la fecha preferida, «Conferma su WhatsApp» ni
  la estimación: no los tiene (lo que sí dice es que no hay datos de alergias).
- **Conferma prenotazione** (`features/bookings/`): desde el detalle de un pedido `new` (o a mano,
  desde «Nuova prenotazione» o «Rinnova»: `BookingSource`), una hoja a pantalla completa que lo
  convierte en una
  reserva de 1 a 8 semanas (una sesión `confirmed` por semana). Es la primera llamada de la app a una Edge Function: `BookingsRepository` hace
  `functions.invoke('chef/bookings')` con la sesión de quien entró (Evelyn o un colaborador
  suyo) y `?forceFunctionRegion=eu-central-1` (nunca la cabecera `x-region`, que CORS no
  permite) y traduce los errores a `BookingFailure` sin loguear nada (contrato
  `docs/contracts/chef-api.md`). Prellena las semanas con `requests.weeks`,
  las fechas cada 7 días desde la preferida (cambiar la primera mueve todas), la llegada que sugiere
  el `dryRun`, los minutos de la estimación (tope de 300) y el precio de la estimación (con las
  tarifas guardadas en `estimate.pricing` si cambian las semanas; vacío sin precio automático), que
  se pasa a centavos sin `double` (`parseEuroCents`). Cada cambio de fechas, hora o minutos vuelve a
  pedir el `dryRun`: cada semana dice si está libre, un aviso (bloqueado, sin horario, fuera de
  horario, pasada) o si choca, y con un choque no deja confirmar. La hoja avisa además lo que el
  servidor no marca: el feriado de Bergamo de una semana (cuenta solo si Evelyn lo bloqueó) y una
  llegada de hoy que ya pasó; tampoco impiden confirmar. Mientras corre el `dryRun`, la barra dice
  «Controllo le date…» (también al lector de pantalla). La barra de abajo queda a la vista
  en un teléfono en vertical, también con el teclado abierto (en `/gestione/` los avisos de arriba
  se esconden mientras tanto; probado hasta 375×548, un iPhone SE con las barras de Safari; en
  horizontal puede no entrar), y muestra arriba del botón el precio que se va a confirmar, lo que
  queda por semana y la llegada, con «Modifica», que lleva al campo del precio (en un teléfono el
  campo queda fuera de la vista, y después ninguna ruta cambia el precio); si algo impide confirmar,
  dice qué (la semana que choca, una fecha o el precio) con «Vedi», que lleva hasta ahí. Una
  `requestKey` por hoja, la misma en los reintentos; mientras envía no se puede cambiar nada. Si la
  confirmación se queda sin respuesta (pudo haberse guardado), la hoja queda igual hasta
  «Riprova», que manda lo mismo: el servidor reconoce el reintento por las fechas y la hora, y con
  otros datos diría que el pedido ya no está nuevo. Si lo guardado no coincide con lo que tenía la
  hoja (otro dispositivo confirmó las mismas fechas con otro precio), lo avisa. Al confirmar, el
  WhatsApp para la clienta en su idioma, con las fechas y la hora (sin dirección ni alergias). Si
  confirma un colaborador, el mensaje sale de su teléfono y escribe de parte de la cocinera
  (`bookingWhatsAppMessageOnBehalf`; el del detalle es `contactWhatsAppMessageOnBehalf`):
  «ti scrivo da parte di Evelyn di Radici» en lugar de «sono Evelyn» y, con varias semanas,
  «Evelyn arriva alle…» en lugar de «Arrivo alle…».
- **Nuova prenotazione** (`features/bookings/` y `features/clients/`): una reserva a mano, desde
  «Prenotazioni» o desde Hoy sin sesiones. Primero se elige la clienta (a pantalla completa, con X):
  las fichas se leen con la RLS de la cocinera, sin dirección, email ni restricciones
  (`ClientsRepository`, con el último pedido semanal de cada una), y se buscan por nombre (sin
  mayúsculas, acentos ni apóstrofos: el ’ del iPhone) o por teléfono (desde 3 cifras). Van primero
  las fichas que no son prospecto y después las del pedido semanal más reciente; un prospecto dice
  «Non ancora cliente» (con la fecha de su pedido): así se distinguen dos fichas de la misma persona
  (la web crea un prospecto nuevo cuando una clienta vuelve a pedir, contrato public-request §3).
  «Nuova cliente» abre el formulario (nombre obligatorio; teléfono, zona, dirección, adultos y niños,
  y el idioma de sus WhatsApp), prellenado con lo que se buscó: lo que parece un teléfono va al
  teléfono. Lo escrito vive en un borrador mientras el elegir esté abierto: volver (con la flecha o
  el gesto) no lo borra. Si el teléfono (normalizado como en la web) ya es de una ficha, lo dice una
  tarjeta (anunciada por el lector de pantalla) y la barra de abajo ofrece «Usa la scheda di…» como
  acción principal (abre la hoja de esa ficha sin modificarla: lo que se tocó en adultos, niños o
  idioma va al pedido) y «Crea una scheda nuova»; lo que impide crearla (sin nombre: «Per creare una
  scheda nuova, scrivi il nome.») va debajo de ese botón, no arriba de «Usa la scheda di…», que no
  lo necesita. Un número copiado de Contactos trae marcas invisibles de dirección (U+202A…U+202C,
  U+200E) que `normalizePhone` no saca: `phoneFromInput` las limpia. Los campos de la clienta (el
  buscador, «Nuova cliente» y el diálogo de la dirección de la ficha) pasan `autofillHints: null`:
  sin pasarlo, `TextField` usa una lista vacía y Flutter web arma igual un `<input
  autocomplete="on">` dentro de un `<form>`, y en `/gestione/` Safari podría ofrecer el teléfono o
  la dirección de la tarjeta propia del iPhone (el WhatsApp iría a Evelyn). Con `null` sale
  `autocomplete="off"`; cuánto sugiere Safari igual solo se ve en el iPhone. El nombre, la zona y
  el buscador van además sin autocorrección (`autocorrect: false`): con el teclado en español de
  Evelyn, iOS cambiaría un apellido italiano al tocar espacio. Después, la misma hoja «Conferma
  prenotazione»: 4 semanas desde mañana, «Persone e pasti» y el idioma (los de su último pedido
  semanal: un evento no describe la casa; sin pedido semanal, el italiano, aunque haya pedido un
  evento en otro idioma, y se cambia con el chip), los minutos que siguen a las personas hasta
  tocarlos y el precio vacío y obligatorio. El POST lleva `clientId` o `newClient` (completo
  también en el `dryRun`), `type: "week"`, `household` y `locale` (contrato chef-api §4); en una
  ficha nueva, el hogar y el idioma tienen una sola fuente con el formulario. Si el servidor no
  acepta los datos de la ficha nueva, «Correggi» vuelve al formulario. Mientras se manda y con una
  respuesta perdida, la hoja no se cierra hasta reintentar: otra hoja tendría otra clave y podría
  duplicar la reserva (y la ficha). Tampoco con el atrás del navegador en `/gestione/`, que no pasa
  por `PopScope`: lo frena el `onExit` de la ruta (sin la sesión de la cocinera, la redirección al
  login la saca igual). Si el reintento tampoco tiene respuesta (un corte largo o la función caída),
  aparece «Chiudi comunque», con el aviso de que la reserva pudo haber quedado guardada y conviene
  mirar «Prenotazioni» o la Agenda antes de rehacerla: sin esa salida, la hoja quedaría abierta hasta
  que vuelva la red. Al confirmar, la reserva está en «Prenotazioni» aunque la relectura falle, y
  «Fatto», la X y el atrás llevan ahí; si la bandeja estaba en error, se relee entera (la reserva
  sola taparía el error y escondería los demás pedidos). No guarda alergias (falta el consentimiento
  de salud, M2). En la URL van solo ids, nunca el nombre, el teléfono ni la dirección.
- **Rinnova** (`features/bookings/domain/renewal.dart`, `/sessioni/:id/rinnova`): desde el
  pendiente de Hoy o la ficha de la última sesión viva de una reserva semanal, la hoja «Rinnova
  prenotazione», una reserva a mano para la misma ficha (`clientId`), prellenada y editable:
  - se renueva si el pedido está aceptado, es semanal y tiene alguna sesión viva; si no, «Questa
    prenotazione non si può rinnovare.»;
  - la primera fecha es la última sesión viva + 7 días (el mismo día de la semana) y las demás, cada
    7 días; la hora es la de esa sesión. Si su día y su hora no son los de más de la mitad de las
    semanas vivas (alguna se movió), salen igual de ella y el encabezado avisa «Non tutte le
    settimane avevano lo stesso giorno e la stessa ora…», sin decir que se movió la última: las
    sesiones no guardan cuál se movió y, con dos semanas distintas, no se puede saber (duda D7);
  - las semanas y el precio son los de la reserva, contando las sesiones canceladas (lo que se
    reservó y se acordó);
  - la llegada (el primer `dryRun` ya la lleva), los minutos (tal cual, también más de 300: «+» no
    sube y «−» lleva a 300), las porciones y la compra son los de la última sesión viva; los minutos
    no siguen a las personas;
  - las personas, los días y las comidas (dentro de los límites del contrato) y el idioma son los
    del pedido renovado;
  - con otra cantidad de semanas, el precio sale de las tarifas de su estimación solo si el total
    era el de esas tarifas (560 € en 4 semanas pasa a 300 € en 2); si no, queda vacío y obligatorio;
  - el encabezado y el WhatsApp van a la ficha, que es lo que muestran las sesiones nuevas; si el
    pedido renovado traía otro teléfono, el encabezado lo dice (y, si la ficha no tiene uno válido,
    que no hay WhatsApp, en lugar de decir que va al de la ficha);
  - los feriados de Bergamo y una llegada de hoy que ya pasó se avisan como en cualquier hoja (el día
    +7 del pendiente, la primera fecha es hoy: duda D1);
  - con una respuesta perdida no se cierra hasta reintentar, tampoco con el atrás del navegador, y
    si el reintento tampoco tiene respuesta ofrece «Chiudi comunque» (como la hoja a mano); al
    confirmar, la reserva está en «Prenotazioni», la renovada queda marcada en el dispositivo
    (`renewedBookingsProvider`, en memoria) y «Fatto» vuelve a donde estaba;
  - no guarda alergias, como toda reserva a mano: sus sesiones muestran las del último pedido
    semanal de la web que se reservó (en general, el de la reserva que vino de la web), con su
    fecha; si no hay o no responde, «Allergie: nessun dato nell'app, chiedile».
- **Contacto de cada pedido**: el que llegó con ese pedido (`requests.contact`), y lo que falte (o
  todo, en un pedido de la app), de la ficha. Un envío de la web nunca cambia la ficha de una persona
  que ya existe, así que cada pedido muestra (y llama o escribe a) los datos con que llegó.
- **Altro** (Más): el cuarto destino de la barra (o del riel en pantallas anchas), con la cuenta,
  Piatti, Impostazioni y salir. En el teléfono reemplaza al menú de la cuenta de la barra superior,
  que queda solo en pantallas anchas.
- **Piatti** (catálogo, migración `20261116170000_recipe_catalog.sql`): lista con búsqueda en los
  nombres en italiano, español e inglés (sin mayúsculas ni acentos), los activos primero y los
  desactivados al final, cada plato con sus alérgenos, dieta y temporada. El editor pone primero lo
  rápido (nombre en italiano, los 14 alérgenos, dieta y meses con «Tutto l'anno») y después lo
  opcional: nombres en español e inglés, conservación, ingredientes (cantidad entera para 4
  porciones en g, ml o piezas, o «q.b.»; sección del súper; orden con botones) y notas (solo de la
  cocinera: se leen de `recipe_notes`, que el cliente no lee). Guarda el plato entero con
  `save_recipe`, con un id generado en el teléfono: un reintento no lo duplica y, si falla, no se
  pierde lo cargado. No deja guardar un plato vegano con leche, huevos, pescado o mariscos, ni uno
  vegetariano con pescado o mariscos (`save_recipe` tampoco lo acepta). Duplicar abre la copia (otro
  id) para cambiarle el nombre; desactivar y reactivar tienen «Annulla». Un plato nunca se borra.
- **Impostazioni** (en «Altro»; en pantallas anchas, también en el menú de la cuenta): idioma de la
  app (Español, Italiano, English), la cuenta (el nombre de la cocinera, o «Collaboratore di …» si
  entró un colaborador), salir y, en la web, la versión abierta («Versione abc1234»).
- **Avisos de la web** (arriba de cualquier pantalla, también del login, salvo con el teclado o un
  diálogo abiertos): versión nueva publicada y, en Safari del iPhone, abrir Radici desde el ícono
  (ver [Web /gestione/](#web-gestione)).
- **Tiempo real**: canal de Supabase Realtime con los `INSERT` en `requests` de su `chef_id`: cada
  pedido que llega se suma a la lista. Aviso emergente "Nuova richiesta da …", con botón para abrirla,
  solo para los pedidos sin abrir que llegan de la web (`ChefRequest.alertsOnArrival`). Uno de la
  app se suma sin aviso: una reserva cargada a mano (nace aceptada y va a «Prenotazioni») o un
  pedido nuevo (que igual cuenta en el contador y va a «Nuove»). El aviso sale en cualquier
  pantalla salvo la ficha de una sesión y el formulario del editor de platos (y sus diálogos):
  tienen su propio `ScaffoldMessenger` y, en el navegador raíz, tapan el Scaffold de la barra, que
  es donde sale el aviso. Ahí no se ve, y aparece al volver de esas pantallas. Con varios pedidos
  («N nuove richieste») el botón lleva a la bandeja, en «Nuove» aunque se haya dejado en otra
  pestaña, salvo con una hoja «Conferma prenotazione», «Nuova prenotazione» (el elegir, el
  formulario «Nuova cliente» o la hoja a mano), la hoja «Rinnova» o la ficha de una sesión (con su
  hoja «Sposta») abierta o tapada por otro pedido: ahí abre encima el más reciente, porque ir a la
  bandeja las sacaría sin preguntar, y se perdería lo que tienen a medias (lo escrito; mientras se
  manda la reserva, la pantalla final con el WhatsApp; mientras se mueve una sesión, el «Annulla»
  de la ficha). Al reconectar (corte de red, app que vuelve del segundo plano) se relee la lista y
  se avisa lo que llegó, con la misma regla.
- Los teléfonos se normalizan con `lib/core/phone.dart`, copia de `normalizePhone`
  (`supabase/functions/_shared/public_request.ts`); `test/core/phone_test.dart` corre los mismos casos.
  Lo que se escribe o se pega en la app pasa antes por `phoneFromInput` (`cleanOneLine`, la copia de
  la de TS, y sin los caracteres invisibles de formato), con su propio test (`phone_input_test.dart`).

Rutas (en la web van en el fragmento: `/gestione/#/richieste/<id>`, el enlace del email a Evelyn):
`/accedi`, `/caricamento`, `/area-clienti`, `/oggi` (el inicio de la cocinera), `/richieste`,
`/richieste/:id`,
`/richieste/:id/prenota`, `/richieste/nuova`, `/richieste/nuova/cliente`, `/richieste/nuova/prenota`
(con `?cliente=<id>` y, desde el formulario, `&modulo=1`), `/agenda`, `/sessioni/:id`, `/sessioni/:id/sposta` (con `?data=AAAA-MM-DD`
si la fecha ya se eligió), `/sessioni/:id/rinnova`, `/impostazioni`, `/altro`, `/altro/piatti`, `/altro/piatti/nuovo` (con
`?copia=<id>`, la copia de un plato) y `/altro/piatti/:id`, más `/` y `/preventivo` (públicas). En la
web `/` lleva al login.

### Requisitos en Supabase

El orden completo del primer despliegue está en el contrato (§10.1).

- Migración `supabase/migrations/20261019120000_public_requests.sql` (columnas nuevas de `requests`,
  permisos de update solo de `status` y `seen_at`, `requests` en la publicación `supabase_realtime`).
  Su guarda `requests_guard_update` deja a la app pasar `new` → `rejected` y `rejected` → `new`, y
  desde `20261019160000_public_request_hardening.sql` también vale en el alta (un pedido nace en `new`).
  Esa migración agrega `requests.contact` (el contacto con que llegó cada pedido).
- `clients.status`: la cocinera lo cambia (privilegio por columna y `clients_guard_update`); la app lo
  pasa de `prospect` a `trial` con "Segna come cliente".
- `profiles.locale`: el usuario lo puede cambiar en su propio perfil (`grant update (full_name,
  phone, locale)` y la política "el usuario edita el suyo", `20261019100200_rls.sql`).
- Auth de producción, desde el repo: `deploy-supabase.yml` aplica en cada despliegue lo de
  `supabase/config.toml` (`supabase/scripts/auth-config.ts`): altas **apagadas** (la app tampoco crea
  usuarios), código de 8 cifras que vale 600 s, las plantillas "Magic link" y "Confirm signup" con el
  código (`{{ .Token }}`, HTML de `supabase/templates/login_code.html`) y **SMTP propio** con Resend
  (`RESEND_SMTP_KEY`). En un proyecto Free, Supabase no deja cambiar las plantillas sin SMTP propio:
  sin la clave, el email trae un link en lugar del código y Evelyn no puede entrar.
- Usuario de Evelyn **antes de publicar** la web o una vista previa: lo crea el mismo workflow
  (variables `CHEF_LOGIN_EMAIL` y `CHEF_DISPLAY_NAME`) mientras no haya ninguna cocinera: confirmado,
  con una contraseña al azar que nadie conoce, y después `promote_to_chef`. La función exige el email
  confirmado, le cambia la contraseña por una al azar y le cierra las sesiones (nadie que haya
  registrado antes ese email entra como cocinera); por eso el workflow no la vuelve a correr. Si
  Evelyn ya tenía la app abierta cuando se corrió, tiene que salir y volver a entrar con el código.
- Colaboradores: sus cuentas también las crea el workflow, en cada despliegue (en su último paso), con
  el secreto `CHEF_MEMBER_EMAILS` (la lista manda; contrato §10.1). Cambiar el secreto no hace nada
  hasta correr Deploy Supabase a mano. **Antes de cargar el primero en producción**, la decisión de
  privacy de SPEC §14: un colaborador ve también las alergias y las direcciones, y la privacy vigente
  nombra solo a Evelyn y, para la asistencia técnica, a quien gestiona el sistema. En local,
  `marco@example.test` es colaborador de Evelyn en el seed.

## Web `/gestione/`

La misma app compilada para la web y publicada dentro del sitio de Cloudflare Pages.

```bash
flutter pub get
dart run build_runner build            # el código generado no se versiona: también en CI
flutter build web --release --base-href /gestione/ --no-web-resources-cdn --csp \
  --dart-define-from-file=env/prod.json        # APP_ENV=prod, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY
# salida: build/web/ → se copia a dist/gestione/ de la web
```

En Git Bash (Windows) anteponer `MSYS_NO_PATHCONV=1`: si no, `/gestione/` se convierte en una ruta de Windows.

`deploy-web.yml` la compila con el backend de producción solo en `main`. En las vistas previas de los
PR (código sin revisar en una URL pública) va con `APP_ENV=dev` y sin Supabase: muestra "Backend non
configurato" y no se conecta a los datos de producción. En los dos casos agrega
`--dart-define=BUILD_ID=<sha corto>` y publica `gestione/build.json` (ver "Versión nueva"); a mano no
hace falta: sin `BUILD_ID` la app no avisa nada.

- **Versión nueva**: Evelyn deja la app abierta en el iPhone, así que no se entera sola de un deploy.
  `BUILD_ID` (los 7 primeros caracteres del commit, `lib/core/build_id.dart`) queda compilado en la
  app y el deploy escribe el mismo en `gestione/build.json` (`{"buildId":"abc1234"}`).
  `AppUpdateController` (`lib/features/web_app/`) lee `build.json` resuelto contra la base de la página
  (`/gestione/build.json?t=<ms>`, con `cache: 'no-store'`) al abrir y al volver a primer plano, como
  mucho una vez cada 5 minutos, y si el id es otro muestra «C'è una nuova versione · Aggiorna» arriba
  de cualquier pantalla. Nunca recarga sola: «Aggiorna» recarga la página. Sin red, con una respuesta
  rara o sin `BUILD_ID` (flutter run, tests, iOS y Android) no avisa nada. Impostazioni dice
  «Versione abc1234». `version.json` no sirve: el build no pasa `--build-number` y siempre dice
  `1.0.0+1`. El id es el del commit, no el del contenido: un deploy que solo cambia la web pública
  también muestra el aviso, y volver a publicar el mismo commit (por ejemplo, después de cambiar
  `SUPABASE_URL` o `SUPABASE_PUBLISHABLE_KEY`, que quedan compiladas) no lo muestra: ahí hay que
  recargar a mano.
- **Aviso de Safari**: el botón del email abre el navegador, que tiene otra sesión que la app de la
  pantalla de inicio. En el iPhone o el iPad fuera de la app instalada (`navigator.standalone` y
  `display-mode: standalone`), una tarjeta arriba de cualquier pantalla, también del login: «Para no
  volver a entrar, abre Radici desde el ícono de tu pantalla de inicio». Cerrada, no vuelve en ese
  dispositivo (marca `radici.install_hint_dismissed` en localStorage).
- Lo que es solo de la web (fetch sin caché, `location.reload`, `navigator.standalone`, `matchMedia`,
  localStorage) está en `lib/core/browser_web.dart`, detrás de un import condicional
  (`lib/core/browser.dart`): en iOS, Android y los tests en la VM se usa `browser_stub.dart`, que no
  hace nada. Los avisos aparecen desde el segundo cuadro: en la web, runApp arma la app antes del
  primer layout y un cambio de foco en ese momento mide los botones (con uno sin tamaño, «RenderBox
  was not laid out»). La app de abajo va en su propio contenedor de semántica: la barrera de cada
  ruta (un `BlockSemantics`) descarta lo pintado antes en el mismo contenedor, y sin eso VoiceOver no
  vería los avisos. Sus botones quedan a 8 px o más de lo de abajo (las acciones de cada barra).
  Con el teclado abierto (Flutter web lo informa como `viewInsets`) los avisos se esconden y vuelven
  al cerrarlo: le quitan su alto a todas las pantallas, y en un iPhone SE en Safari la hoja
  «Conferma prenotazione» se quedaba sin lugar para el campo que se escribe y, con los dos avisos,
  «Conferma» bajaba detrás del teclado. Mientras haya un diálogo abierto en el navegador raíz
  (`showDialog`, el calendario o el reloj; los cuenta `OpenDialogsObserver`, en
  `lib/core/open_dialogs.dart`, hasta que cada uno termina de cerrarse), también: los diálogos van
  en el Navigator, debajo de los avisos, y con los dos, a 375×548, las filas del calendario medían
  14 px y «OK» del reloj quedaba cortado, sin poder tocarse. Los menús y las listas desplegables no
  los esconden. Esconder la tarjeta de Safari no es cerrarla.
- **iPhone** (`web/index.html`, `web/manifest.json`): `<meta name="viewport">` solo para la pantalla
  de carga (al arrancar, Flutter pone el suyo; por eso tampoco va `viewport-fit=cover`),
  `apple-mobile-web-app-capable` y la barra de estado `default`; en la carga, el ícono y la rueda, sin
  texto (antes de Flutter no hay traducciones). El manifest lleva `"id": "/gestione/"`, la misma
  identidad que ya tenía la app instalada (sin `id`, el navegador usa `start_url`). Sin service worker
  con caché: volvería a traer versiones viejas.

- **Autocontenida**: `--no-web-resources-cdn` copia CanvasKit a `canvaskit/` y `web/flutter_bootstrap.js`
  fija `canvasKitBaseUrl` (nada de `www.gstatic.com`). Roboto va empaquetada (`assets/fonts/`, familia
  "Roboto"), así el motor no la descarga de `fonts.gstatic.com`; las fuentes de respaldo (glifos que
  Roboto no tiene, como emoji) apuntan a `fonts-fallback/`, que no existe: se ve un recuadro en lugar
  del glifo y no se pide nada a Google. `--csp` evita código generado dinámicamente en `main.dart.js`.
  También van empaquetadas las de la marca (ver "Identidad").
- **Rutas con `#`** (estrategia por defecto de Flutter web): los enlaces directos funcionan sin reglas
  de reescritura. Con rutas sin `#` habría que reescribir `/gestione/*` a `/gestione/index.html`, y en
  Pages un `_redirects` 200 también taparía `main.dart.js`, `canvaskit/` y `assets/` (los redirects
  ganan sobre los archivos estáticos), además de que sin `404.html` Pages devuelve la landing.
- **Opcional, para subir menos (42 MB → 18 MB)**: un build JS con CanvasKit no usa
  `canvaskit/skwasm*`, `canvaskit/wimp*`, `canvaskit/webparagraph/`, los `*.symbols`,
  `flutter_service_worker.js` ni `.last_build_id`; se pueden excluir al copiar a `dist/gestione/`.
  Hay que conservar `canvaskit/canvaskit.{js,wasm}` (Safari, Firefox) y
  `canvaskit/chromium/canvaskit.{js,wasm}` (Chrome, Edge).

CSP de `/gestione/*` (verificada en Chrome headless recorriendo login, bandeja, aviso en tiempo real,
detalle, reconexión del WebSocket y agenda: sin violaciones ni errores de consola):

```
default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline';
connect-src 'self' https://<ref>.supabase.co wss://<ref>.supabase.co; object-src 'none';
base-uri 'self'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests
```

- `'wasm-unsafe-eval'`: CanvasKit es WebAssembly (sin él la app no arranca).
- `style-src 'unsafe-inline'`: el motor agrega dos `<style>` cuyo contenido cambia según el navegador
  (Safari, Firefox, Edge), así que los hashes no sirven. La alternativa probada es la opción `nonce`
  del motor en `flutter_bootstrap.js` con `style-src 'self' 'nonce-…'`, pero en un sitio estático el
  nonce sería fijo por deploy (no por respuesta).
- Los scripts siguen estrictos: sin `'unsafe-inline'` ni `'unsafe-eval'`.
- Caché: los nombres de archivo de Flutter **no** llevan hash. Nada de `immutable` ni `max-age` largo
  en `/gestione/*`: `_headers` pone `Cache-Control: no-cache` y cada carga revalida (304 si no
  cambió). En Cloudflare, Browser Cache TTL tiene que quedar en «Respect Existing Headers» (contrato
  §10.1, paso 9): con el valor de fábrica llegaba `max-age=14400` y «Aggiorna» recargaba la versión
  vieja. Cada deploy de producción comprueba que `main.dart.js` y `flutter_bootstrap.js` lleguen con
  `no-cache` y, si no, queda en rojo (`.github/scripts/check-gestione-cache.sh`, contrato §8).

## Estructura

```
lib/
  main.dart            arranque: entorno, Supabase (si está configurado), licencias, ProviderScope
  app.dart             MaterialApp.router, tema, localizaciones, aviso de pedidos nuevos y avisos de la web
  core/                env, id del build, rutas y router (go_router), tema, dinero, teléfonos, fechas
                       de Roma, navegador (browser*.dart: solo hace algo en la web)
  features/<feature>/
    domain/            Dart puro (modelos, reglas). Ej.: quote/domain/quote.dart, copia del motor quote.ts
    data/              repositorios: interfaz + implementación con Supabase
    application/       providers Riverpod y estado
    presentation/      pantallas y widgets: solo leen providers, nunca llaman a Supabase ni calculan
  l10n/                app_it.arb (plantilla), app_es.arb, app_en.arb
web/                   index.html, flutter_bootstrap.js y manifest para /gestione/
tool/                  generate_icons.dart (íconos con la R de la marca), fonts/ (fuentes de la marca)
test/                  espejo de lib/ y tool/, más support/ con utilidades
```

## Presupuesto

`lib/features/quote/domain/quote.dart` es una copia de `supabase/functions/_shared/quote.ts`, que es la fuente de verdad.
`test/features/quote/quote_vectors_test.dart` lee `supabase/functions/_shared/quote_vectors.json` y verifica todos los vectores.
Si cambia la fórmula, se cambian `quote.ts`, los vectores y esta copia en el mismo PR.

## Textos

Ningún texto de UI va hardcodeado: todo sale de `lib/l10n/*.arb`. La plantilla es italiano (`app_it.arb`), que también es el idioma de respaldo.
`test/l10n/arb_keys_test.dart` falla si `es` o `en` no tienen exactamente las mismas claves.
Los mensajes al cliente (WhatsApp, email) van en el idioma del pedido (`requests.locale`), no en el
de la interfaz.

### Idioma

- **Sin sesión** (inicio, login): el idioma del dispositivo; si no es it, es ni en, italiano.
- **Con sesión**: el del perfil (`profiles.locale`), en cualquier dispositivo. Se cambia en
  Impostazioni (cocinera) o en el área de clientes; las opciones van escritas en su propio idioma.
  El cambio se ve enseguida y se guarda en el perfil; si no se puede guardar, vuelve al anterior y
  avisa. También se copia a `user_metadata.locale`, que decide el idioma del email del código
  (si eso falla, el perfil igual queda guardado).
- **Arranque en frío**: el idioma elegido se guarda también en el dispositivo (SharedPreferences;
  localStorage en la web) junto con el id del usuario, y `main.dart` lo lee antes del primer cuadro:
  la app arranca ya en ese idioma y el perfil, al cargarse, lo confirma o lo corrige. Al salir se
  borra (el login vuelve al idioma del dispositivo).
- `profiles.locale` es `not null default 'it'`: no hay forma de distinguir "eligió italiano" de "no
  eligió", así que no se fuerza el español para la cocinera. El perfil nace con el idioma de la
  interfaz al pedir el primer código (`user_metadata.locale`); si Evelyn lo tiene en italiano, lo
  cambia una vez en Impostazioni.
- Lógica: `features/settings/` (`LanguageController`, `LanguageCache`) y
  `AccountRepository.updateLanguage`.

## Identidad

La misma de la web y de los emails (manual de marca). Colores y nombres de fuentes en
`lib/core/brand.dart` (Dart puro):

- **Tema** (`lib/core/theme.dart`): en claro, los colores de la web (fondo crema, tarjetas crema clara
  con borde lino, texto tinta, oliva para lo principal, terra para restricciones); en oscuro, los
  tonos que Material deriva del oliva. Títulos en Cormorant Garamond con números de caja alta; el texto
  chico (listas, formularios, botones) sigue en la letra del sistema, que se lee mejor en el teléfono.
  Esquinas casi rectas. `test/core/theme_test.dart` verifica el contraste (AA) de los pares de colores.
- **Logotipo** (`lib/core/radici_logo.dart`, en el login y el inicio): RADICI en Cinzel sobre el
  filete y CUCINA PRIVATA debajo, en texto (nada que cargar).
- **Fuentes**: Cinzel 500 y Cormorant Garamond 600, estáticas y solo con letras latinas (~190 KB en
  total), generadas desde las variables de Google Fonts con `tool/fonts/make_brand_fonts.py`
  (Python con fontTools). Licencia OFL, en la pantalla de licencias.
- **Pantalla de carga de `/gestione/`** (`web/loading.css`, `index.html`, `manifest.json`): el ícono
  de la app y la rueda, con los colores del tema, en claro y en oscuro
  (`test/web/gestione_shell_test.dart`).

## Íconos

La R de Cinzel en crema sobre oliva, como el favicon de la web. La R sale de la fuente que usa la app
(`assets/fonts/Cinzel-Medium.ttf`, leída por `tool/icons/glyph_outline.dart`): favicon y
`web/icons/*` (`/gestione/`), `android/.../mipmap-*/ic_launcher.png` y
`ios/Runner/Assets.xcassets/AppIcon.appiconset/*`. Mismos nombres y tamaños que la plantilla de
Flutter: no cambia nada de los proyectos nativos (ni el bundle id).

```bash
dart run tool/generate_icons.dart    # desde app/: vuelve a escribir los PNG
```

El script no usa dependencias (lee la fuente, rasteriza y escribe PNG con dart:io) y da siempre el
mismo resultado. `test/tool/app_icons_test.dart` falla si algún PNG no coincide con lo que genera o si
falta alguno de los que piden `Contents.json` (iOS), `manifest.json` (web) o los `mipmap-*`.
Android usa el ícono clásico (redondo), sin ícono adaptativo: en Android 8+ el sistema lo muestra
dentro de su forma.
