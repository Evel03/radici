#!/usr/bin/env bash
# Decide qué jobs de CI hacen falta según los archivos cambiados (uno por línea, por stdin).
# Imprime «area=true|false» para quote, edge, web, app y database. Lo usa ci.yml; tiene tests en
# ci-changes.test.ts. Regla de oro: ante la duda, corre. Las listas salen de lo que los tests leen del
# repo (por eso cada job corre cuando cambia algo de eso):
# - app (flutter analyze + test): app/**; los tests de Dart leen supabase/** (config.toml, migraciones,
#   functions/_shared: chef_api.ts, public_request.test.ts, quote_vectors.json) y .github/ (deploy-web.yml
#   y check-gestione-cache.sh), y la portada de la web (web/src/i18n, web/src/images, web/index.html y
#   web/vite.config.ts: landing_texts_test.dart compara la portada de la app con la de la web).
# - web (vitest + build): web/**; importa supabase/functions/_shared/** (motor, contratos, vectores).
# - database (pgTAP): supabase/migrations, tests, config.toml y seed.
# - edge (deno check): supabase/functions/**.
# - quote (npm test de la raíz): todo menos lo que es solo de app/** o de web/** (los tests de la raíz leen
#   supabase/**, .github/**, los i18n de la web y package*.json). Un archivo desconocido corre la raíz.
# Cambiar .github/** (workflows y scripts) puede romper cualquier job: corre todo.
set -euo pipefail

all=false
quote=false edge=false web=false app=false database=false
while IFS= read -r f; do
  f="${f%$'\r'}"
  [ -z "$f" ] && continue
  case "$f" in
    .github/*) all=true ;;
  esac
  case "$f" in
    app/* | supabase/* | web/src/i18n/* | web/src/images/* | web/index.html | web/vite.config.ts) app=true ;;
  esac
  case "$f" in
    web/* | supabase/functions/_shared/*) web=true ;;
  esac
  case "$f" in
    supabase/migrations/* | supabase/tests/* | supabase/config.toml | supabase/seed*) database=true ;;
  esac
  case "$f" in
    supabase/functions/*) edge=true ;;
  esac
  case "$f" in
    web/src/i18n/*) quote=true ;;
    app/* | web/*) ;;
    *) quote=true ;;
  esac
done

if [ "$all" = true ]; then
  quote=true edge=true web=true app=true database=true
fi
printf '%s=%s\n' quote "$quote" edge "$edge" web "$web" app "$app" database "$database"
