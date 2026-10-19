# Mestolo

Cocina casera a domicilio en Bergamo (Evelyn). "Mestolo" es nombre provisorio.
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
- Nunca loguear ni mandar por push/email restricciones, alergias, direcciones ni datos de tarjeta.
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
