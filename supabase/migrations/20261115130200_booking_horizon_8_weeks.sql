-- =====================================================================
-- Radici · Ventana de reserva de 8 semanas (esquema y datos)
-- Tests: supabase/tests/database/10_booking_horizon.test.sql (private.replace_booking_horizon),
-- 07_free_slots.test.sql (el valor por defecto y el corte: parte 5 y parte 9) y
-- supabase/functions/_shared/availability.test.ts (la base y el contrato dicen lo mismo, y esta
-- migración llama a la función).
--
-- Decisión del dueño del 15/11/2026: el día preferido del formulario se elige de mañana a 8
-- semanas (56 días) y no a 14. Con 14 días, más de la mitad de los días la ventana cabía en un solo
-- mes y las flechas del calendario quedaban deshabilitadas (el 15/11, del 16 al 29 de noviembre).
-- Reemplaza lo que decía 20261115130100_default_availability.sql («la ventana sigue en 14 días»).
--
-- booking_horizon_days es la ventana de la base: private.free_slot_candidates (y con él
-- get_free_slots y get_free_days) ofrece de mañana a hoy + booking_horizon_days. Tiene que ser
-- DATE_WINDOW.maxDaysAhead (supabase/functions/_shared/public_request.ts), la ventana del
-- formulario y de la respuesta de GET …/availability: availability.test.ts compara el último
-- valor por defecto de las migraciones con el contrato y exige que la migración que lo cambia
-- llame a private.replace_booking_horizon(anterior, nuevo).
--
--   1. Valor por defecto 56: lo reciben las cocineras nuevas (promote_to_chef crea su fila de
--      chef_settings con los valores por defecto).
--   2. Las que siguen en 14, el valor por defecto anterior (en producción, solo Evelyn), pasan a
--      56. Un valor distinto de 14 se eligió a propósito y no se toca.
--
-- private.replace_booking_horizon() deja el paso 2 en un solo lugar y lo hace testeable: db reset
-- aplica las migraciones sobre una base vacía (el seed va después, ya con el valor por defecto
-- nuevo), así que en los tests la llamada de abajo no encuentra filas. Otra corrida no cambia nada.
--
-- Despliegue: deploy-supabase.yml corre db push antes de publicar la función. Mientras sigue la
-- función de antes, pide 14 días y la base se los da: nada cambia hasta que se publica la nueva.
-- =====================================================================

alter table public.chef_settings
  alter column booking_horizon_days set default 56;

create function private.replace_booking_horizon(p_from int, p_to int)
returns int
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_rows int;
begin
  -- Sin esto, un null no encontraría filas y la llamada pasaría en silencio.
  if p_from is null or p_to is null or p_from < 1 or p_to < 1 then
    raise exception 'invalid_horizon' using errcode = '22023';
  end if;

  -- No hay trigger de updated_at en chef_settings: se pone acá.
  update public.chef_settings
  set booking_horizon_days = p_to,
      updated_at = now()
  where booking_horizon_days = p_from;
  get diagnostics v_rows = row_count;

  -- Solo los valores y el contador.
  raise log 'replace_booking_horizon: from=% to=% rows=%', p_from, p_to, v_rows;
  return v_rows;
end
$$;

comment on function private.replace_booking_horizon(int, int) is
  'Cambio de ventana de reserva (booking_horizon_days): pasa a p_to las cocineras que siguen en p_from, el valor por defecto anterior; otro valor se eligió a propósito y no se toca. Pone updated_at. Devuelve cuántas filas cambió; otra corrida no cambia nada. Solo el dueño (migraciones, SQL editor).';

revoke all on function private.replace_booking_horizon(int, int) from public, anon, authenticated, service_role;

select private.replace_booking_horizon(14, 56);
