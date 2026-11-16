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
  cuenta: ve y hace lo mismo que ella, e Impostazioni y el menú de la cuenta dicen «Collaboratore di
  Evelyn» en lugar del nombre (`chefAccountTitle`). El WhatsApp que le prepara el detalle de un pedido sale de su propio teléfono, así que
  escribe de parte de ella («ti scrivo da parte di Evelyn di Radici», `contactWhatsAppMessageOnBehalf`)
  en lugar de «sono Evelyn».
- **Richieste**: pestañas Nuove (sin `seen_at`), Viste y Rifiutate, con contador de nuevas.
- **Franja**: la bandeja, el detalle y la agenda muestran mañana o tarde si el pedido la trae. La web
  ya no la pregunta y manda `any`, que la app lee como sin franja y no muestra (como los emails).
- **Agenda**: mes y semana por `preferred_date` con la franja, más la lista "Senza data". "Hoy"
  (Europe/Rome) cambia a la medianoche sin reabrir la app: se vuelve a mirar la fecha a la
  medianoche y, como mucho, cada minuto (un Timer largo llega tarde si el teléfono se suspende).
  Si estaba elegido "hoy", la agenda pasa al día nuevo; si no, respeta el día elegido.
  Días bloqueados (`availability_exceptions`, sin migración: la RLS y los grants ya estaban): la
  tarjeta del día los bloquea o desbloquea con «Annulla» y una nota privada (los clientes no la
  ven; la cocinera y sus colaboradores, sí), y el botón
  «Blocca giorni» bloquea un rango (una fila por día, upsert que nunca pisa un bloqueo que ya
  existía). La web deja de ofrecerlos en 1 o 2 minutos (`get_free_days` los descuenta; la
  disponibilidad se cachea 60 s). Marca los feriados nacionales (Pasquetta calculada; San Francesco
  desde 2026, legge n. 151/2025) y Sant'Alessandro (26/8) como festivo local de Bergamo.
- **Detalle**: todos los datos (también las restricciones), la estimación guardada y las acciones:
  WhatsApp (`https://wa.me/<número sin +>?text=…` en el idioma del cliente), llamar (`tel:`),
  email (`mailto:`), rechazar (`new` → `rejected`) y deshacer el rechazo (`rejected` → `new`;
  como ya estaba visto, vuelve a Viste), las dos con confirmación. Al abrirlo se marca visto.
  Si la persona es todavía un prospecto, avisa que sus datos se borran 90 días después de su último
  pedido y ofrece **Segna come cliente** (con confirmación): la ficha pasa a `trial` y se conserva
  (contrato §9).
- **Contacto de cada pedido**: el que llegó con ese pedido (`requests.contact`), y lo que falte (o
  todo, en un pedido de la app), de la ficha. Un envío de la web nunca cambia la ficha de una persona
  que ya existe, así que cada pedido muestra (y llama o escribe a) los datos con que llegó.
- **Impostazioni** (menú de la cuenta): idioma de la app (Español, Italiano, English), la cuenta (el
  nombre de la cocinera, o «Collaboratore di …» si entró un colaborador), salir y, en la web, la
  versión abierta («Versione abc1234»).
- **Avisos de la web** (arriba de cualquier pantalla, también del login): versión nueva publicada y,
  en Safari del iPhone, abrir Radici desde el ícono (ver [Web /gestione/](#web-gestione)).
- **Tiempo real**: canal de Supabase Realtime con los `INSERT` en `requests` de su `chef_id`. Aviso
  emergente "Nuova richiesta da …" en cualquier pantalla, con botón para abrirla. Al reconectar
  (corte de red, app que vuelve del segundo plano) se relee la lista y se avisa lo que llegó.
- Los teléfonos se normalizan con `lib/core/phone.dart`, copia de `normalizePhone`
  (`supabase/functions/_shared/public_request.ts`); `test/core/phone_test.dart` corre los mismos casos.

Rutas (en la web van en el fragmento: `/gestione/#/richieste/<id>`, el enlace del email a Evelyn):
`/accedi`, `/caricamento`, `/area-clienti`, `/richieste`, `/richieste/:id`, `/agenda`,
`/impostazioni`, más `/` y `/preventivo` (públicas). En la web `/` lleva al login.

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
