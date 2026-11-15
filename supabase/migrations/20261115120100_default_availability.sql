-- =====================================================================
-- Radici · Horario inicial de las cocineras (migración de datos)
-- Tests: supabase/tests/database/07_free_slots.test.sql (parte 10).
--
-- Decisión del dueño del 15/11/2026: Evelyn trabaja de lunes a viernes de 9:00 a 15:00 y la
-- ventana de reserva sigue en 14 días (booking_horizon_days, sin cambios). Producción no tiene
-- reglas de disponibilidad y la app todavía no tiene editor: sin reglas, get_free_days no
-- marca ningún día. Hasta que exista el editor, toda cocinera SIN ninguna regla recibe ese
-- horario.
--
-- private.add_default_availability() deja la regla en un solo lugar y la hace testeable.
-- Idempotente: una cocinera que ya tiene alguna regla no se toca, así que otra corrida no
-- agrega nada. En un proyecto nuevo, deploy-supabase.yml crea la cuenta de la cocinera después
-- de las migraciones: ahí hay que correrla a mano una vez (contrato public-request §10.1).
-- =====================================================================

create function private.add_default_availability()
returns int
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_rows int;
begin
  insert into public.availability_rules (chef_id, dow, start_time, end_time)
  select c.id, d.dow, time '09:00', time '15:00'
  from public.chefs c
  cross join generate_series(1, 5) as d (dow)   -- 1 = lunes … 5 = viernes (dow de extract)
  where not exists (select 1 from public.availability_rules r where r.chef_id = c.id)
  on conflict (chef_id, dow, start_time) do nothing;
  get diagnostics v_rows = row_count;

  -- Solo el contador.
  raise log 'add_default_availability: rules=%', v_rows;
  return v_rows;
end
$$;

comment on function private.add_default_availability() is
  'Horario inicial (decisión del 15/11/2026, hasta que la app tenga editor de disponibilidad): lunes a viernes de 9 a 15 para cada cocinera sin ninguna regla. Devuelve cuántas reglas agregó. Idempotente. Solo el dueño (migraciones, SQL editor).';

revoke all on function private.add_default_availability() from public, anon, authenticated, service_role;

select private.add_default_availability();
