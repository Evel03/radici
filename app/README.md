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
  cocinera, con la ficha de su cocina (`current_chef_id()`, la misma función que la RLS, y su fila de
  `chefs`); cualquier otro → "Area clienti in preparazione". La interfaz pasa al idioma del perfil
  (ver [Idioma](#idioma)). Un colaborador de la cocinera (`chef_members`) entra igual, con su
  cuenta: ve y hace lo mismo que ella, y «Altro», Impostazioni y el menú de la cuenta dicen
  «Collaboratore di Evelyn» en lugar del nombre (`chefAccountTitle`). El WhatsApp que le prepara el
  detalle de un pedido sale de su propio teléfono, así que escribe de parte de ella («ti scrivo da
  parte di Evelyn di Radici», `contactWhatsAppMessageOnBehalf`) en lugar de «sono Evelyn».
- **Richieste**: pestañas Nuove (sin `seen_at`), Viste y Rifiutate, con contador de nuevas. La fila
  de un pedido en el que el cliente eligió platos en la pestaña «Menù» de la web (`requests.wishes`)
  lleva la marca **menù** debajo del resumen (ícono y texto; el lector de pantalla dice «Menù scelto
  dal cliente»): es el aviso que pidió Evelyn. No va al lado de la fecha porque `ListTile` le da a esa
  columna hasta 56 px de alto y, con el texto grande, no entraba. También en la agenda, que usa la
  misma fila.
- **Franja**: la bandeja, el detalle y la agenda muestran mañana o tarde si el pedido la trae. La web
  ya no la pregunta y manda `any`, que la app lee como sin franja y no muestra (como los emails).
- **Agenda**: mes y semana por `preferred_date` con la franja, más la lista "Senza data". "Hoy"
  (Europe/Rome) cambia a la medianoche sin reabrir la app: se vuelve a mirar la fecha a la
  medianoche y, como mucho, cada minuto (un Timer largo llega tarde si el teléfono se suspende).
  Si estaba elegido "hoy", la agenda pasa al día nuevo; si no, respeta el día elegido.
  Días bloqueados (`availability_exceptions`, sin migración: la RLS y los grants ya estaban): la
  tarjeta del día los bloquea o desbloquea con «Annulla» y una nota privada (los clientes no la
  ven; la cocinera y sus colaboradores, sí), y el botón «Blocca giorni» bloquea un rango (una fila por día, upsert que nunca pisa un bloqueo que ya
  existía). La web deja de ofrecerlos en 1 o 2 minutos (`get_free_days` los descuenta; la
  disponibilidad se cachea 60 s). Marca los feriados nacionales (Pasquetta calculada; San Francesco
  desde 2026, legge n. 151/2025) y Sant'Alessandro (26/8) como festivo local de Bergamo.
- **Detalle**: todos los datos (también las restricciones), la estimación guardada (el servicio, sin
  compra ni total: la compra la hace el cliente; las claves de compra de los pedidos de antes se
  ignoran) y las acciones. Si el cliente eligió platos en la web, arriba va un recuadro destacado
  «Menù scelto dal cliente (2 di 5 giorni)» (si el pedido no dice los días, «(2 piatti)») con los
  nombres en el orden en que los tildó (en el idioma de la app, con el italiano si falta la
  traducción); un plato que después se borró dice «Piatto eliminato». Los nombres se piden por id a
  `recipes` (`wishes` es un `uuid[]` sin FK: no se puede embeber), solo si hay platos elegidos; ni
  marcar visto ni releer la bandeja (reconexión, deslizar para actualizar) los vuelve a pedir, porque
  depende del contenido de los ids. Si no se pueden leer, el recuadro lo avisa enseguida, con
  «Riprova» (sin los reintentos automáticos de Riverpod). Sin platos elegidos, nada (el menú lo
  propone Evelyn, que tiene la última palabra). Las acciones:
  WhatsApp (`https://wa.me/<número sin +>?text=…` en el idioma del cliente), llamar (`tel:`),
  email (`mailto:`), rechazar (`new` → `rejected`) y deshacer el rechazo (`rejected` → `new`;
  como ya estaba visto, vuelve a Viste), las dos con confirmación. Al abrirlo se marca visto.
  Si la persona es todavía un prospecto, avisa que sus datos se borran 90 días después de su último
  pedido y ofrece **Segna come cliente** (con confirmación): la ficha pasa a `trial` y se conserva
  (contrato §9).
- **Contacto de cada pedido**: el que llegó con ese pedido (`requests.contact`), y lo que falte (o
  todo, en un pedido de la app), de la ficha. Un envío de la web nunca cambia la ficha de una persona
  que ya existe, así que cada pedido muestra (y llama o escribe a) los datos con que llegó.
- **Altro** (Más): el tercer destino de la barra (o del riel en pantallas anchas), con la cuenta (el
  nombre de la cocinera, o «Collaboratore di …» si entró un colaborador), Piatti, Impostazioni y
  salir. En el teléfono reemplaza al menú de la cuenta de la barra superior, que queda solo en
  pantallas anchas.
- **Piatti** (catálogo, migración `20261116170000_recipe_catalog.sql`): lista con búsqueda en los
  nombres en italiano, español e inglés (sin mayúsculas ni acentos), los activos primero y los
  desactivados al final, cada plato con sus alérgenos, dieta, temporada y, si está activo, si sale en
  la web («Sul sito») o le falta la descripción para salir («Senza descrizione: non è sul sito»). El
  editor pone primero lo rápido (nombre en italiano, los 14 alérgenos, dieta, meses con «Tutto
  l'anno» y la descripción de la web) y después lo opcional: nombres en español e inglés, conservación, ingredientes (cantidad entera para 4
  porciones en g, ml o piezas, o «q.b.»; sección del súper; orden con botones) y notas (de la
  cocinera y sus colaboradores: se leen de `recipe_notes`, que el cliente no lee). Guarda el plato entero con
  `save_recipe`, con un id generado en el teléfono: un reintento no lo duplica y, si falla, no se
  pierde lo cargado. No deja guardar un plato vegano con leche, huevos, pescado o mariscos, ni uno
  vegetariano con pescado o mariscos (`save_recipe` tampoco lo acepta). Duplicar abre la copia (otro
  id) para cambiarle el nombre, sin las descripciones de la web: la copia queda «Senza descrizione: non
  è sul sito» hasta que tenga la suya, así no sale en la web con la del original. Desactivar y
  reactivar tienen «Annulla». Un plato nunca se borra.
- **Descripción de la web** (migración `20261119150000_menu_web.sql`): una frase corta en italiano y,
  si quiere, en español e inglés (`recipes.description_it/_es/_en`), que la web muestra al lado del
  nombre en la pestaña «Menù» del formulario de pedido. Un plato sale en la web si está activo, en el
  catálogo y con la descripción en italiano (`get_public_menu`); sin la española o la inglesa, la web
  muestra la italiana. Hasta 200 caracteres, una sola línea, sin espacios de más (como los nombres,
  `normalizeRecipeText`); el contador avisa sin cortar lo escrito y al guardar lo dice el error. El
  contador cuenta como la validación y la base (`recipeTextLength`: sin los espacios de más, por
  caracteres como `char_length`; una bandera cuenta dos). Se guardan con `save_recipe`, que recibe
  siempre las tres (null borra la que se vació).
- **Foto del plato** (migración `20261120100000_recipe_photos.sql`; una por plato): la sección «Foto»
  del editor, después de la descripción de la web, **también en «Nuovo piatto»**, antes de guardar el
  plato. «Aggiungi foto» pregunta cámara o galería en el teléfono; en `/gestione/` la app le pide a
  image_picker la galería (`ImageSource.gallery`, un `<input type="file">` sin `capture`), y la cámara la
  ofrece la hoja de archivos del iPhone. La foto se prepara en el dispositivo
  (`processRecipePhoto`, `domain/recipe_photo.dart`): se pide al selector ya achicada a 1200 px (en el
  iPhone convierte HEIC a JPEG; en la web la achica el navegador), se endereza con su orientación
  EXIF, se achica a 1200 px de lado mayor y la miniatura a 320 de lado menor (se ve recortada en un
  cuadrado) y se vuelve a codificar en JPEG **sin metadatos** (EXIF, GPS, XMP, IPTC, comentarios ni
  ningún otro segmento), siempre debajo de 2 MiB. Solo queda el perfil de color (ICC): no es un dato
  personal y sin él una foto Display P3 del iPhone se ve apagada. En el teléfono corre en otro
  isolate; en la web, en el hilo principal (la foto ya llega achicada por el navegador), y la URL `blob:`
  de la foto elegida se suelta al leerla. Mientras se elige o se prepara («Preparo la foto…»), «Salva»
  espera: en el teléfono desde que se abre el selector, porque la foto puede seguir cargando (de
  iCloud) con el selector ya cerrado; en la web desde que llega, porque si se cancela, un navegador sin
  el evento `cancel` no avisa nunca. Queda en el editor como un cambio sin guardar y se sube al tocar
  «Salva»: primero el plato (`save_recipe`), después los dos archivos al bucket público
  `recipe-photos` (`{chef_id}/{plato}/{foto}.jpg` y `…-thumb.jpg`, con un uuid nuevo en cada foto,
  `image/jpeg`, caché de una semana, sin pisar nada) y `set_recipe_photo` («Carico la foto…» o, al
  sacarla, «Tolgo la foto…»); la subida espera como mucho 60 s y lo demás 30 s. Al final se limpia la
  carpeta del plato, sin esperar ni avisar si falla: se borra todo lo que no sea la foto nueva (la que
  dejó de usarse y las subidas abandonadas); el próximo cambio de foto del mismo plato espera esa
  limpieza. El guardado sigue aunque el editor se cierre (lo hace el catálogo). Si la foto falla, el
  plato queda guardado (sin foto si era nuevo, con la anterior si se cambiaba), el editor no se cierra
  y la sección lo dice con «Riprova» (sube solo la foto, con el mismo uuid; un archivo que ya estaba
  cuenta como subido). Una foto elegida mientras se guardaba (en la web) queda para el próximo
  guardado: el editor no se cierra. En un plato guardado, «Cambia foto» y «Togli foto» se aplican al
  guardar; si solo cambió la foto, el plato no se vuelve a mandar. Duplicar un plato no copia la foto. La miniatura se ve en la
  lista de platos (a la izquierda) y en el menù elegido del detalle del pedido (a la derecha del
  nombre); la vista previa del editor usa la foto grande; sin foto, como siempre, y si no carga, un
  cuadrado neutro. La URL pública la arma el repositorio (`getPublicUrl`); los widgets la leen de `recipePhotoUrlProvider`. En iOS, los
  textos de permiso de la cámara y de las fotos (`NSCameraUsageDescription`,
  `NSPhotoLibraryUsageDescription` en `ios/Runner/Info.plist`) están en italiano: no hay
  `InfoPlist.strings` por idioma (sumarlos toca el proyecto de Xcode). Con `requestFullMetadata: false`
  elegir de la galería no pide permiso; la cámara, sí. En Android no hace falta nada (el selector de
  fotos del sistema y la cámara por intent).
- **Impostazioni** (en «Altro»; en pantallas anchas, también en el menú de la cuenta): idioma de la
  app (Español, Italiano, English), la cuenta (el nombre de la cocinera, o «Collaboratore di …» si
  entró un colaborador), salir y, en la web, la versión abierta («Versione abc1234»).
- **Avisos de la web** (arriba de cualquier pantalla, también del login): versión nueva publicada y,
  en Safari del iPhone, abrir Radici desde el ícono (ver [Web /gestione/](#web-gestione)).
- **Tiempo real**: canal de Supabase Realtime con los `INSERT` en `requests` de su `chef_id`. Aviso
  emergente "Nuova richiesta da …" en cualquier pantalla, con botón para abrirla; si el cliente eligió
  platos en la web lo dice ("…, con 2 piatti scelti dal menù"; con varios pedidos, "3 nuove richieste
  (1 con menù)"). Al reconectar
  (corte de red, app que vuelve del segundo plano) se relee la lista y se avisa lo que llegó.
- Los teléfonos se normalizan con `lib/core/phone.dart`, copia de `normalizePhone`
  (`supabase/functions/_shared/public_request.ts`); `test/core/phone_test.dart` corre los mismos casos.

Rutas (en la web van en el fragmento: `/gestione/#/richieste/<id>`, el enlace del email a Evelyn):
`/accedi`, `/caricamento`, `/area-clienti`, `/richieste`, `/richieste/:id`, `/agenda`,
`/impostazioni`, `/altro`, `/altro/piatti`, `/altro/piatti/nuovo` (con `?copia=<id>`, la copia de un
plato) y `/altro/piatti/:id`, más `/` y `/preventivo` (públicas). En la web `/` lleva al login.

### Requisitos en Supabase

El orden completo del primer despliegue está en el contrato (§10.1).

- Migración `supabase/migrations/20261019120000_public_requests.sql` (columnas nuevas de `requests`,
  permisos de update solo de `status` y `seen_at`, `requests` en la publicación `supabase_realtime`).
  Su guarda `requests_guard_update` deja a la app pasar `new` → `rejected` y `rejected` → `new`, y
  desde `20261019160000_public_request_hardening.sql` también vale en el alta (un pedido nace en `new`).
  Esa migración agrega `requests.contact` (el contacto con que llegó cada pedido).
- Migración `supabase/migrations/20261120100000_recipe_photos.sql` antes de esta versión: la app lee
  `recipes.photo_id` con el catálogo y con el menù elegido (sin la columna, el catálogo no carga),
  sube al bucket `recipe-photos` y llama a `set_recipe_photo`.
- Migración `supabase/migrations/20261119150000_menu_web.sql`: `recipes.description_*` (las lee el
  editor y las guarda `save_recipe`) y el uso de `requests.wishes` (los platos elegidos en la web, que
  la bandeja y el detalle leen; la columna existe desde la primera migración).
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
  hasta correr Deploy Supabase a mano. Solo quien gestiona el sistema por cuenta de Evelyn (SPEC §6):
  un colaborador ve también las alergias y las direcciones, así que sumar a otra persona exige antes
  una privacy nueva. En local, `marco@example.test` es colaborador de Evelyn en el seed.

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
  vería los avisos. Sus botones quedan a 8 px o más de lo de abajo (las acciones de cada barra,
  como «Salva» del calendario de rango).
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
img-src 'self' blob: https://<ref>.supabase.co;
connect-src 'self' blob: https://<ref>.supabase.co wss://<ref>.supabase.co; object-src 'none';
base-uri 'self'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests
```

- `'wasm-unsafe-eval'`: CanvasKit es WebAssembly (sin él la app no arranca).
- `style-src 'unsafe-inline'`: el motor agrega dos `<style>` cuyo contenido cambia según el navegador
  (Safari, Firefox, Edge), así que los hashes no sirven. La alternativa probada es la opción `nonce`
  del motor en `flutter_bootstrap.js` con `style-src 'self' 'nonce-…'`, pero en un sitio estático el
  nonce sería fijo por deploy (no por respuesta).
- Los scripts siguen estrictos: sin `'unsafe-inline'` ni `'unsafe-eval'`.
- `img-src` y `blob:` (20/11/2026, fotos de los platos), según el código del motor de Flutter 3.47.7 y
  de image_picker_for_web 3.1.1: `Image.network` pide la foto con XMLHttpRequest (`connect-src`,
  `WebHtmlElementStrategy.never` por defecto); Safari y Firefox (sin `ImageDecoder`, que el motor
  solo usa en Chrome y Edge) decodifican toda imagen en un `<img>` con una URL `blob:` (`img-src
  blob:`); image_picker_for_web achica la foto elegida en un `<img>` con su URL `blob:` y cross_file
  la lee con XMLHttpRequest (`connect-src blob:`). El origen de Supabase en `img-src` es por si una
  imagen se carga con un `<img>`. Sin probar todavía en Safari del iPhone.
- La cámara en `/gestione/`: la app pide la galería (un `<input type="file">` sin `capture`) y la
  cámara la ofrece la hoja de archivos del iPhone. La `Permissions-Policy: camera=()` de `/*` es para
  `getUserMedia`: no toca ese `<input>` (sin probar en el iPhone).
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
Sin compra (19/11/2026): la hace el cliente, con la lista que le manda Evelyn. El motor no la estima
y la calculadora (`/preventivo`) muestra porciones, recetas y el servicio.

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
