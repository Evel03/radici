-- =====================================================================
-- Radici · Sin compra: la primera llegada desde las 9:00 (esquema y datos)
-- Tests: supabase/tests/database/16_sin_compra.test.sql (el valor por defecto, los horarios de
-- un día de 9:00 a 15:00 y private.replace_shop_minutes).
--
-- Decisión del 19/11/2026: Evelyn no hace la compra. La hace el cliente, con la lista de
-- ingredientes y cantidades que ella le manda antes de cada sesión. Hasta ahora compraba de 9:00 a
-- 9:45 y la primera llegada a una casa era a las 10:00; sin compra llega desde las 9:00, y una
-- sesión puede durar hasta 6 h (de 9:00 a 15:00).
--
-- chef_settings.shop_minutes son los minutos de compra antes de cada llegada: entran en el rango
-- ocupado de la sesión (sessions.busy = [llegada − compra, llegada + cocina + margen)), en la
-- primera llegada del día (ceil_a_30(apertura + compra), en private.free_slot_candidates y en
-- private.booking_day_checks) y en el aviso mínimo. Con 0 la cuenta es la misma y la compra no
-- suma nada: el rango empieza en la llegada. El check de la columna (shop_minutes >= 0) ya acepta 0.
--
--   1. Valor por defecto 0: lo reciben las cocineras nuevas (promote_to_chef crea su fila de
--      chef_settings con los valores por defecto).
--   2. Las que siguen en 45, el valor por defecto anterior (en producción, Evelyn), pasan a 0. Un
--      valor distinto de 45 se eligió a propósito y no se toca.
--
-- private.replace_shop_minutes() deja el paso 2 en un solo lugar y lo hace testeable, como
-- private.replace_booking_horizon (20261115130200_booking_horizon_8_weeks.sql): db reset aplica las
-- migraciones sobre una base vacía (el seed va después, ya con el valor por defecto nuevo), así que
-- en los tests la llamada de abajo no encuentra filas. Otra corrida no cambia nada.
--
-- Lo que no cambia:
--   * Las sesiones que ya existen: cada una guardó sus minutos de compra al crearse (los copia
--     sessions_fill_minutes) y su busy se calculó con ellos; no se tocan, y moverlas tampoco cambia
--     sus minutos. Las sesiones nuevas copian el 0.
--   * Las columnas de la compra (chef_settings.adult_portion_cents, kid_portion_cents y
--     preauth_buffer_pct; sessions.groceries_est_cents y las demás), el estado shopping_done y la
--     guarda de transiciones. chef_create_booking sigue recibiendo p_groceries_est_cents: la Edge
--     Function chef le pasa 0.
--   * Los comentarios de las funciones de migraciones anteriores que hablan de la compra (la
--     cuenta es la misma; con 0 minutos no suma nada).
-- =====================================================================

alter table public.chef_settings
  alter column shop_minutes set default 0;

create function private.replace_shop_minutes(p_from int, p_to int)
returns int
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_rows int;
begin
  -- Sin esto, un null no encontraría filas y la llamada pasaría en silencio. 0 vale: sin compra.
  if p_from is null or p_to is null or p_from < 0 or p_to < 0 then
    raise exception 'invalid_shop_minutes' using errcode = '22023';
  end if;

  -- No hay trigger de updated_at en chef_settings: se pone acá.
  update public.chef_settings
  set shop_minutes = p_to,
      updated_at = now()
  where shop_minutes = p_from;
  get diagnostics v_rows = row_count;

  -- Solo los valores y el contador.
  raise log 'replace_shop_minutes: from=% to=% rows=%', p_from, p_to, v_rows;
  return v_rows;
end
$$;

comment on function private.replace_shop_minutes(int, int) is
  'Cambio de los minutos de compra (shop_minutes): pasa a p_to las cocineras que siguen en p_from, el valor por defecto anterior; otro valor se eligió a propósito y no se toca. Pone updated_at. No toca las sesiones (cada una guarda los suyos). Devuelve cuántas filas cambió; otra corrida no cambia nada. Solo el dueño (migraciones, SQL editor).';

revoke all on function private.replace_shop_minutes(int, int) from public, anon, authenticated, service_role;

select private.replace_shop_minutes(45, 0);
