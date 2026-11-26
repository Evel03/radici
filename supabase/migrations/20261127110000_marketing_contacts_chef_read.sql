-- La lista de ofertas y novedades para Evelyn (contrato public-request §13; la tabla es de
-- 20261127100000_marketing_contacts.sql). La cocina (la cocinera y sus colaboradores: current_chef_id())
-- la lee desde la app, para verla y exportarla; nadie la escribe desde la app (la confirman y la dan de
-- baja las dueñas de los emails, por la función public-request).
--
-- Solo lectura y solo algunas columnas: nunca el hash del token del link (con él no se arma el link, pero
-- no le sirve a nadie en la app) ni el pedido de origen. Las cuentas sin cocina no ven ninguna fila.

grant select (id, chef_id, email, first_name, locale, source, status, requested_at, confirmed_at, withdrawn_at, last_activity_at)
  on public.marketing_contacts to authenticated;

create policy "marketing_contacts: la cocina lee la suya"
  on public.marketing_contacts for select to authenticated
  using (chef_id = (select public.current_chef_id()));

comment on policy "marketing_contacts: la cocina lee la suya" on public.marketing_contacts is
  'La cocinera y sus colaboradores leen los contactos de su cocina (sin token_hash ni request_id: grant por columnas). Nadie escribe desde la API.';

-- ---------------------------------------------------------------------
-- public.chef_marketing_withdraw(p_email): la cocina da de baja un contacto de su lista (cuando la persona
-- se lo pide por WhatsApp, por teléfono o respondiendo un email). Lo mismo que la baja desde el link: queda
-- la prueba (email, fechas y versión del texto) y se borra el nombre. true si había un contacto pendiente o
-- confirmado con ese email en su cocina; false si no (o si ya estaba de baja).
-- ---------------------------------------------------------------------
create function public.chef_marketing_withdraw(p_email text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_chef uuid := public.current_chef_id();
begin
  if v_chef is null then
    raise exception 'chef_marketing_withdraw: solo la cocina' using errcode = '42501';
  end if;
  update public.marketing_contacts
  set status = 'withdrawn', withdrawn_at = now(), first_name = null
  where chef_id = v_chef and email = lower(btrim(coalesce(p_email, ''))) and status <> 'withdrawn';
  return found;
end;
$$;

revoke all on function public.chef_marketing_withdraw(text) from public, anon, authenticated, service_role;
grant execute on function public.chef_marketing_withdraw(text) to authenticated;
