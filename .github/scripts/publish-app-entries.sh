#!/usr/bin/env bash
# Deploy web, paso «Copiar /gestione/ y /app/ al sitio»: arma dist/gestione/ (la cocina) y dist/app/ (las
# clientas) a partir de UN solo build de Flutter web (app/build/web, compilado con --base-href /gestione/).
#
# Por qué un build y no dos: lo único que cambia entre las dos entradas es el <base href> y el
# <meta name="radici-entry"> de index.html, y el manifest. main.dart.js, flutter_bootstrap.js y los assets
# usan rutas relativas al <base> (CanvasKit con canvasKitBaseUrl "canvaskit/", assets/, build.json), no
# llevan «/gestione/» en el código, y el service worker no se publica; la app elige su entrada en
# tiempo de ejecución con el meta (app/lib/core/app_entry.dart). Un segundo build costaba ~1,5 min de
# Actions por deploy y daba el mismo código. Si algún día el JS llevara la ruta base, el chequeo de
# «/gestione/» en dist/app/ (abajo) lo frena.
#
# Variables: BUILD_ID (obligatoria: el de --dart-define=BUILD_ID), SRC (build de la app, por defecto
# ../app/build/web), DIST (por defecto dist; vite build lo dejó con _headers, robots.txt y sitemap.xml),
# MAIN_JS_WARN_BYTES (umbral de aviso del peso de main.dart.js, por defecto 6000000; solo avisa).
# Se corre desde web/. Tests: publish-app-entries.test.ts, al lado (npm test en la raíz).
set -euo pipefail

src="${SRC:-../app/build/web}"
dist="${DIST:-dist}"
build_id="${BUILD_ID:-}"
warn_bytes="${MAIN_JS_WARN_BYTES:-6000000}"

fail() { echo "::error::$*"; exit 1; }

[ -n "${build_id}" ] || fail "Falta BUILD_ID (lo deja el paso «App - id del build»)."
grep -q '"useLocalCanvasKit":true' "${src}/flutter_bootstrap.js" \
  || fail "CanvasKit no es local (falta --no-web-resources-cdn): la CSP lo bloquearía."
if grep -q '"renderer":"skwasm"' "${src}/flutter_bootstrap.js"; then
  fail "El build de la app usa skwasm (--wasm): revisar qué archivos se descartan en este paso."
fi
if grep -q '__SUPABASE' "${dist}/_headers"; then
  fail "dist/_headers tiene marcadores de Supabase sin completar."
fi
# Hasta PR69 (cuando se enlace la app desde la web pública) /app/ no se anuncia: ni sitemap ni robots.txt.
for f in sitemap.xml robots.txt; do
  if [ -e "${dist}/${f}" ] && grep -q '/app/' "${dist}/${f}"; then
    fail "dist/${f} menciona /app/: no se anuncia hasta PR69."
  fi
done

# Reemplaza un texto exacto de un archivo; si no está, corta (el build de la app cambió y este paso no se enteró).
replace() {
  local file="$1" from="$2" to="$3" content
  content="$(cat "${file}")"
  [[ "${content}" == *"${from}"* ]] || fail "${file}: no está «${from}» (¿cambió app/web/index.html o el manifest?)."
  printf '%s\n' "${content//"${from}"/"${to}"}" > "${file}"
}

# Sin lo que un build JS con CanvasKit nunca carga (42 MB → ~18 MB): los renderers skwasm, wimp y
# webparagraph, los símbolos de depuración y el service worker (no se registra). Se conservan canvaskit/
# (Safari, Firefox) y canvaskit/chromium/ (Chrome, Edge).
copy_build() {
  local out="$1"
  # vite build vacía dist/: estas carpetas no pueden existir todavía.
  [ ! -e "${out}" ] || fail "${out} ya existe: el build de la web tendría que haberlo vaciado."
  mkdir -p "${out}"
  tar -C "${src}" -cf - \
    --exclude='./canvaskit/skwasm*' --exclude='./canvaskit/wimp*' --exclude='./canvaskit/webparagraph' \
    --exclude='*.symbols' --exclude='./.last_build_id' --exclude='./flutter_service_worker.js' \
    . | tar -C "${out}" -xf -
  if find "${out}" \( -name '*.symbols' -o -name 'skwasm*' -o -name 'wimp*' -o -name webparagraph -o -name flutter_service_worker.js \) | grep -q .; then
    fail "Se copiaron archivos que se tenían que descartar en ${out} (revisar los --exclude de tar)."
  fi
  # El aviso de versión nueva compara el id compilado con este: sin el id en main.dart.js, la app nunca avisaría.
  grep -qF "\"${build_id}\"" "${out}/main.dart.js" \
    || fail "${out}/main.dart.js no tiene el id del build (${build_id}): revisar --dart-define=BUILD_ID en el build de la app."
  printf '{"buildId":"%s"}\n' "${build_id}" > "${out}/build.json"
  local f
  for f in index.html manifest.json flutter_bootstrap.js main.dart.js build.json canvaskit/canvaskit.js canvaskit/canvaskit.wasm \
           canvaskit/chromium/canvaskit.js canvaskit/chromium/canvaskit.wasm; do
    [ -s "${out}/${f}" ] || fail "Falta ${out}/${f}"
  done
}

copy_build "${dist}/gestione"
copy_build "${dist}/app"

# --- /app/: el mismo build con su base, su entrada, su manifest y sus textos ---------------------
app="${dist}/app"
replace "${app}/index.html" '<base href="/gestione/">' '<base href="/app/">'
replace "${app}/index.html" '<meta name="radici-entry" content="gestione">' '<meta name="radici-entry" content="app">'
replace "${app}/index.html" '<title>Radici · Gestione</title>' '<title>Radici Cucina</title>'
replace "${app}/index.html" 'content="Radici: richieste e agenda di Evelyn."' 'content="Radici Cucina: le tue richieste, i tuoi menù e le tue prenotazioni."'
replace "${app}/manifest.json" '"id": "/gestione/"' '"id": "/app/"'
replace "${app}/manifest.json" '"name": "Radici · Gestione"' '"name": "Radici Cucina"'
replace "${app}/manifest.json" '"start_url": "."' '"start_url": "/app/"'
replace "${app}/manifest.json" '"scope": "."' '"scope": "/app/"'
replace "${app}/manifest.json" '"description": "Radici: richieste e agenda di Evelyn."'   '"description": "Radici Cucina: le tue richieste, i tuoi menù e le tue prenotazioni."'

# --- Controles: cada entrada es la suya, nunca cruzadas -----------------------------------------
check_entry() {
  local out="$1" entry="$2" other="$3"
  grep -q "<base href=\"/${entry}/\">" "${out}/index.html" || fail "${out}/index.html no tiene <base href=\"/${entry}/\">"
  grep -q "<meta name=\"radici-entry\" content=\"${entry}\">" "${out}/index.html" \
    || fail "${out}/index.html no tiene <meta name=\"radici-entry\" content=\"${entry}\">"
  if grep -q "radici-entry\" content=\"${other}\"" "${out}/index.html"; then
    fail "${out}/index.html tiene la entrada de ${other}: las entradas no pueden ir cruzadas."
  fi
  grep -q "\"id\": \"/${entry}/\"" "${out}/manifest.json" || fail "${out}/manifest.json no tiene id /${entry}/"
  if grep -q "/${other}/" "${out}/manifest.json"; then
    fail "${out}/manifest.json nombra /${other}/."
  fi
  # La base solo está en index.html y en el manifest: el JS no la lleva (ver arriba el porqué de un solo build).
  # (sin las líneas de comentario //: ahí se puede nombrar cualquier ruta)
  if grep -vE '^[[:space:]]*//' "${out}/flutter_bootstrap.js" | grep -qE "[\"'(=]/${other}/"; then
    fail "${out}/flutter_bootstrap.js lleva la ruta /${other}/: hace falta un build propio para esta entrada."
  fi
}
check_entry "${dist}/gestione" gestione app
check_entry "${dist}/app" app gestione

# --- Peso de main.dart.js: avisa, no corta -------------------------------------------------------
size=$(wc -c < "${dist}/app/main.dart.js" | tr -d '[:space:]')
if [ "${size}" -gt "${warn_bytes}" ]; then
  echo "::warning::main.dart.js pesa ${size} bytes (más de ${warn_bytes}): revisar qué sumó peso antes de que la clienta lo note en el celular."
else
  echo "main.dart.js: ${size} bytes (aviso desde ${warn_bytes})."
fi
echo "dist/gestione: $(du -sh "${dist}/gestione" | cut -f1) en $(find "${dist}/gestione" -type f | wc -l) archivos"
echo "dist/app: $(du -sh "${app}" | cut -f1) en $(find "${app}" -type f | wc -l) archivos"
