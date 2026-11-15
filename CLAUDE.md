# Radici

Cocina casera a domicilio en Bergamo (Evelyn). Nombre definitivo: Radici.
Repo: `Evel03/radici` (GitHub). Dominio: https://radicicucina.app (web pública y bandeja en `/gestione/`), comprado el 15/11/2026 en Cloudflare Registrar, en la misma cuenta que Pages. El anterior, radici.sepusola10.com, se da de baja.
Los identificadores nativos de la app (bundle id) todavía no se eligieron: no cambiarlos sin pedido explícito (lista de lugares en `app/README.md`).
Especificación completa: SPEC.md. Si una regla cambia, actualizar SPEC.md y este archivo en el mismo PR.

## Estructura
- `app/` Flutter (iOS, Android y la bandeja web de Evelyn en `/gestione/`). SDK: `C:\Users\NicolasMansillaBened\dev\flutter-3.47.7\bin\flutter` (el `flutter` del PATH es 3.27, viejo).
- `web/` web pública estática: Vite + TypeScript, sin framework. Italiano por defecto. El formulario manda el pedido a la Edge Function `public-request` (contrato: `docs/contracts/public-request.md`); `deploy-web.yml` publica la web y `/gestione/` juntas.
- `supabase/migrations/` esquema y RLS · `supabase/tests/database/` pgTAP · `supabase/functions/` Edge Functions (Deno).
- `supabase/functions/_shared/quote.ts` motor de presupuesto: fuente única de verdad, compartido por Edge Functions y web.
  `quote_vectors.json` al lado: lo leen los tests de TS y de Dart.

## Reglas
- Dinero siempre en centavos (int). Nunca double para importes. La fórmula de presupuesto usa solo enteros.
- Fechas y horas de negocio en Europe/Rome. Guardar timestamptz.
- Presupuesto: fuente de verdad `quote.ts`; la copia Dart (`app/lib/features/quote/`) es vista previa y pasa los mismos vectores.
- Horarios: `get_free_slots()` en SQL. Su regla de choque es idéntica a `no_overlap` (margen de un solo lado).
- Presupuestos enviados = sesiones `held` con `hold_until`, protegidas por `no_overlap`.
- Estados de sesión y pagos solo cambian vía Edge Functions o webhooks de Stripe, nunca desde la app.
- Nunca loguear ni mandar por push/email restricciones, alergias, direcciones ni datos de tarjeta. De las alergias, un email dice solo qué contestó el cliente (nadie tiene, indicadas o sin datos), nunca cuáles.
- Formulario público (sin login, email sin verificar): nunca modifica a una persona que ya existe; lo que llega queda en el pedido (`requests.contact`). Nada de lo escrito en el formulario sale hacia direcciones o números no verificados salvo un nombre de pila que parezca un nombre (`safeFirstName`).
- Pregunta de alergias del formulario: el cliente confirma que nadie de quienes van a comer tiene (`requests.no_allergies`) o las escribe con el consentimiento de salud de la versión vigente; nunca las dos cosas (contrato §2).
- Altas de usuarios apagadas hasta M2: la cuenta de la cocinera la crea confirmada `deploy-supabase.yml` (o el panel) antes de publicar nada, y la configuración de Auth sale del repo (contrato §10).
- Workflows: actions fijadas por SHA con `# vX.Y.Z` (Dependabot las actualiza).
- Textos de UI: ARB en la app, JSON por idioma en la web (it por defecto, es, en). Nada hardcodeado.
- App: lógica fuera de los widgets (repositorios + providers Riverpod). Widgets sin llamadas a Supabase.
- TS de `_shared/`: solo sintaxis borrable (sin enum, namespace ni parameter properties), imports con extensión `.ts`; así corre en Node, Deno y Vite sin compilar.
- Tests primero para: presupuesto, horarios, transiciones de estado, pagos, RLS.
- Una feature = un PR chico con tests en verde.

## Comandos
- Raíz: `npm test` (contrato, motor de presupuesto y Edge Functions, node --test)
- Web: `cd web && npm run dev | npm run build | npm test`
- App: `cd app && flutter analyze && flutter test` (con el SDK 3.47.7)
- Base: `npx supabase start` · `npx supabase db reset` · `npx supabase test db` (necesita Docker)
- Edge Function local: copiar `supabase/functions/.env.example` y `npx supabase functions serve --env-file <archivo>` (con `EMAIL_TRANSPORT=log` no sale ningún email)
