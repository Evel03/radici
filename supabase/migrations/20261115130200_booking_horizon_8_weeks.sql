-- =====================================================================
-- Radici · Ventana de reserva de 8 semanas (esquema y datos)
-- Tests: supabase/tests/database/07_free_slots.test.sql (parte 5 y parte 9) y
-- supabase/functions/_shared/availability.test.ts (la base y el contrato dicen lo mismo).
--
-- Decisión del dueño del 15/11/2026: el día preferido del formulario se elige de mañana a 8
-- semanas (56 días) y no a 14: con 14 días el calendario casi nunca pasaba de mes. Reemplaza lo
-- que decía 20261115130100_default_availability.sql («la ventana sigue en 14 días»).
--
-- booking_horizon_days es la ventana de la base: private.free_slot_candidates (y con él
-- get_free_slots y get_free_days) ofrece de mañana a hoy + booking_horizon_days. Tiene que ser
-- DATE_WINDOW.maxDaysAhead (supabase/functions/_shared/public_request.ts), la ventana del
-- formulario y de la respuesta de GET …/availability: availability.test.ts compara el último
-- valor por defecto de las migraciones con el contrato y exige que la migración que lo cambia
-- pase a las cocineras que seguían en el anterior.
--
--   1. Valor por defecto 56: lo reciben las cocineras nuevas (promote_to_chef crea su fila de
--      chef_settings con los valores por defecto).
--   2. Las que siguen en 14, el valor por defecto anterior (en producción, solo Evelyn), pasan a
--      56. Un valor distinto de 14 se eligió a propósito y no se toca.
--
-- Despliegue: deploy-supabase.yml corre db push antes de publicar la función. Mientras sigue la
-- función de antes, pide 14 días y la base se los da: nada cambia hasta que se publica la nueva.
-- =====================================================================

alter table public.chef_settings
  alter column booking_horizon_days set default 56;

update public.chef_settings
set booking_horizon_days = 56,
    updated_at = now()
where booking_horizon_days = 14;
