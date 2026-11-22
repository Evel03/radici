-- =====================================================================
-- Radici · Los links de la clienta vencen a los 15 días (decisión de Nicolas del 22/11/2026).
-- Tests: supabase/tests/database/20_menu_sends.test.sql.
--
-- Cada mensaje del menú de una semana (y el del presupuesto) lleva su propio link a la página de la
-- reserva (/prenotazione/#t=…). Cuando la semana termina, ese link ya no se usa: el mensaje de la
-- semana siguiente trae uno nuevo. Antes vencían a los 120 días (20261121100000_menu_sends.sql).
-- Cambia solo el valor por defecto: los links que ya existan conservan su vencimiento (en producción
-- todavía no hay ninguno: la app aún no manda menús).
-- =====================================================================
alter table public.client_links alter column expires_at set default now() + interval '15 days';

comment on table public.client_links is
  'Links de la clienta a su reserva (SPEC 5.8): el hash sha-256 del token, nunca el token. Un link por envío; vencen a los 15 días (la semana termina y el mensaje siguiente trae otro). Solo la service role.';
