#!/usr/bin/env bash
# Decide qué jobs de CI hacen falta según los archivos cambiados (uno por línea, por stdin).
# Imprime «area=true|false» para quote, edge, web, app, database y gestione (¿hay que compilar la app
# para /gestione/ en la vista previa de deploy-web.yml?). Lo usan ci.yml y deploy-web.yml;
# tiene tests en ci-changes.test.ts. Ante la duda, corre: mejor un job de más que un cambio sin revisar.
set -euo pipefail

all=false
quote=false edge=false web=false app=false database=false gestione=false
while IFS= read -r f; do
  f="${f%$'\r'}"
  [ -z "$f" ] && continue
  case "$f" in
    # Tocar el CI o sus scripts puede romper cualquier job: corre todo.
    .github/workflows/* | .github/scripts/*) all=true ;;
  esac
  case "$f" in
    app/* | supabase/functions/_shared/quote_vectors.json) app=true gestione=true ;;
  esac
  # /gestione/ también depende de cómo la web la sirve (CSP, rutas) y de su propio build.
  case "$f" in
    web/public/_headers | web/src/build/* | web/vite.config.ts) gestione=true ;;
  esac
  case "$f" in
    supabase/migrations/* | supabase/tests/* | supabase/config.toml | supabase/seed*) database=true ;;
  esac
  case "$f" in
    supabase/functions/*) edge=true ;;
  esac
  case "$f" in
    web/* | supabase/functions/_shared/*) web=true ;;
  esac
  # Los tests de la raíz leen supabase/** (migraciones, config, plantillas, funciones), el workflow
  # deploy-supabase.yml y los i18n de la web.
  case "$f" in
    supabase/* | .github/* | package.json | package-lock.json | web/src/i18n/* | docs/*) quote=true ;;
  esac
done

if [ "$all" = true ]; then
  quote=true edge=true web=true app=true database=true gestione=true
fi
printf '%s=%s\n' quote "$quote" edge "$edge" web "$web" app "$app" database "$database" gestione "$gestione"
