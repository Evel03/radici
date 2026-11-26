#!/usr/bin/env bash
# Deploy web, producción, después de publicar (paso «Comprobar la caché de /gestione/ y /app/ en el dominio»).
# Los archivos de /gestione/ y /app/ (PR13, el mismo build) no llevan hash en el nombre, así que el navegador tiene que revalidarlos
# en cada carga (Cache-Control: no-cache, de _headers). Si Cloudflare los pisa con su caché del
# navegador (Browser Cache TTL distinto de «Respect Existing Headers», contrato §10.1, paso 9),
# «Aggiorna» recarga y Evelyn sigue con la versión vieja: sale con 1 y el run queda en rojo.
#
# Primero espera a que el dominio sirva este deploy (el build.json de cada entrada con este id; si no llega, solo avisa).
# Después, por archivo (main.dart.js y flutter_bootstrap.js de cada entrada), hasta CACHE_CHECK_ATTEMPTS intentos (6) cada CACHE_CHECK_PAUSE segundos (10),
# por la propagación. Un corte de la conexión o un timeout de curl es un intento fallido más. Imprime
# solo el estado HTTP, Cache-Control y el id.
#
# Variables: SITE_URL (el origen del sitio: VITE_SITE_URL) y BUILD_ID (paso «App - id del build»).
# Tests: check-gestione-cache.test.ts, al lado (npm test en la raíz), contra un servidor local.

# Sin -e a propósito: un error de curl tiene que llevar al intento siguiente, no cortar el paso.
set +e
set -uo pipefail

site="${SITE_URL:-}"
site="${site%/}"
if ! [[ "${site}" =~ ^https?://[^/[:space:]]+$ ]]; then
  echo "::error::VITE_SITE_URL tiene que ser el origen del sitio (https://…, sin ruta): sin él no se puede comprobar la caché de /gestione/."
  exit 1
fi
build_id="${BUILD_ID:-}"
if [ -z "${build_id}" ]; then
  echo "::error::Falta BUILD_ID (lo deja el paso «App - id del build»)."
  exit 1
fi
attempts="${CACHE_CHECK_ATTEMPTS:-6}"
pause="${CACHE_CHECK_PAUSE:-10}"

# build.json de cada entrada (/gestione/ y /app/ son el mismo build: llevan el mismo id).
for entry in gestione app; do
  live=false
  for attempt in $(seq 1 "${attempts}"); do
    published=$(curl -sS -m 20 "${site}/${entry}/build.json?t=$(date +%s)" 2>/dev/null       | jq -r '.buildId // empty' 2>/dev/null)
    echo "/${entry}/build.json (intento ${attempt}/${attempts}): ${published:-sin id}"
    if [ "${published}" = "${build_id}" ]; then live=true; break; fi
    if [ "${attempt}" -lt "${attempts}" ]; then sleep "${pause}"; fi
  done
  if [ "${live}" != true ]; then
    echo "::warning::${site}/${entry}/build.json no muestra este build (${build_id}): la app instalada no va a avisar que hay una versión nueva hasta que lo muestre."
  fi
done

failed=0
for path in gestione/main.dart.js gestione/flutter_bootstrap.js app/main.dart.js app/flutter_bootstrap.js; do
  ok=false
  for attempt in $(seq 1 "${attempts}"); do
    # Con pipefail, rc es el código de curl. Un corte en medio del cuerpo (18) igual deja las cabeceras.
    headers=$(curl -sS --compressed -m 30 -o /dev/null -D - "${site}/${path}" 2>/dev/null | tr -d '\r')
    rc=$?
    status=$(printf '%s\n' "${headers}" | awk 'NR == 1 { print $2 }')
    cache=$(printf '%s\n' "${headers}" \
      | awk 'tolower($1) == "cache-control:" { sub(/^[^:]*:[ \t]*/, ""); print }' | paste -sd ',' -)
    if [ -n "${status}" ]; then answer="HTTP ${status}"; else answer="sin respuesta (curl ${rc})"; fi
    echo "/${path} (intento ${attempt}/${attempts}): ${answer}, Cache-Control: ${cache:-ninguno}"
    if [ "${status}" = "200" ] && printf '%s' "${cache}" | tr 'A-Z' 'a-z' | tr -d ' ' | tr ',' '\n' | grep -qx 'no-cache'; then
      ok=true
      break
    fi
    if [ "${attempt}" -lt "${attempts}" ]; then sleep "${pause}"; fi
  done
  if [ "${ok}" = true ]; then continue; fi
  failed=1
  if [ "${status}" != "200" ]; then
    echo "::error::${site}/${path}: ${answer} en el último intento, no se pudo comprobar su caché."
  else
    echo "::error::${site}/${path} llega con Cache-Control: ${cache:-ninguno}, sin no-cache: Evelyn seguiría con la versión vieja aunque recargue. En Cloudflare, Caching → Configuration → Browser Cache TTL: «Respect Existing Headers» (contrato §10.1, paso 9)."
  fi
done
exit "${failed}"
