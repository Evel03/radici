-- =====================================================================
-- Mestolo · Privilegios explícitos de la API (Data API, Realtime)
--
-- Supabase dejó de dar privilegios implícitos sobre las tablas nuevas de
-- public a anon, authenticated y service_role: es lo predeterminado en los
-- proyectos creados desde el 30/05/2026 ("Automatically expose new tables"
-- sin marcar) y pasa a los proyectos existentes el 30/10/2026
-- (supabase.com/changelog/45329, revisado el 19/10/2026). Sin estos grants,
-- en un proyecto nuevo la app recibe "permission denied" en todas las
-- tablas y la Edge Function public-request no puede leer chef_settings.
--
-- Acá quedan explícitos los mismos privilegios efectivos que tenían las
-- migraciones anteriores con el comportamiento viejo (verificado comparando
-- ambas bases). Los permisos por columna (update/insert de columnas
-- puntuales) ya son explícitos en 20261019100200_rls.sql y
-- 20261019120000_public_requests.sql; acá NO se da insert ni update a nivel
-- de tabla donde esas migraciones los limitan por columna. RLS sigue
-- decidiendo qué filas ve y toca cada uno.
--
-- anon: nada (20261019100200_rls.sql ya le revoca todo en public).
-- Toda tabla nueva de public tiene que traer sus grants en su migración.
-- =====================================================================

-- service_role (Edge Functions, cron): las cuatro operaciones en todas las tablas de public.
grant select, insert, update, delete on all tables in schema public to service_role;

-- authenticated: lo que gestionan (con RLS) cocinera y clientes.
grant select, insert, update, delete on
  public.availability_exceptions,
  public.availability_rules,
  public.chef_settings,
  public.client_restrictions,
  public.pantry_items,
  public.push_tokens,
  public.receipts,
  public.recipe_allergens,
  public.recipes,
  public.recurring_plans,
  public.session_menu
  to authenticated;

-- authenticated: solo lectura (los cambios van por columnas puntuales o por el servidor).
grant select on
  public.chefs,
  public.consents,
  public.notifications,
  public.payments,
  public.profiles,
  public.quotes,
  public.sessions
  to authenticated;

-- authenticated: altas y cambios solo por columnas (ver las migraciones de arriba).
grant select, delete on public.clients  to authenticated;
grant select, delete on public.requests to authenticated;
grant select, insert on public.prepared_portions to authenticated;
