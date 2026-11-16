-- =====================================================================
-- Radici · Reservas (1 de 2): pay_mode 'manual'
-- Plan del área de Evelyn, PR 3. Tests: supabase/tests/database/13_bookings.test.sql.
--
-- Decisiones del dueño del 16/11/2026: en Fase 0 el cobro es manual (efectivo, transferencia o
-- Satispay) y las reservas que confirma Evelyn crean sesiones reales. Toda sesión que crea Evelyn
-- nace con pay_mode = 'manual' (chef_create_booking, en la migración siguiente): así el cron de
-- pre-autorización de M6 (SPEC 5.4-A.2), que toma las 'preauth', nunca la toca. 'preauth' sigue
-- siendo el valor por defecto de sessions.pay_mode y clients.pay_mode.
--
-- Va en un archivo propio: un valor nuevo de un enum no se puede usar en la misma transacción que
-- lo agrega, y 20261116150100_bookings.sql lo usa.
-- =====================================================================

alter type public.pay_mode add value if not exists 'manual';
