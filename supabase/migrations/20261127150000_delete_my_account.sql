-- =====================================================================
-- «Borrar mi cuenta» desde la app (contrato docs/contracts/auth.md §20). Apple lo exige a toda app que deja crear
-- cuentas (App Store Review Guideline 5.1.1(v)), y la privacy promete que la cuenta y sus datos se borran.
--
-- public.delete_my_account(): la cuenta de la sesión, si es de una clienta, se borra de Auth. En cascada se van el
-- perfil, los datos de la cuenta (account_details), las identidades, las sesiones, los tokens push y los avisos. La
-- ficha que Evelyn tenga de esa clienta (clients, con sus pedidos y reservas) queda, sin la cuenta
-- (clients.profile_id pasa a null): son sus registros y los documentos fiscales se conservan. La lista de ofertas va
-- aparte (marketing_contacts, por email): la baja de las ofertas es su link o «Togli dalla lista».
-- La cocina (dueña o colaborador) no se borra así: 42501 kitchen_account. Sin sesión: 42501 not_authenticated.
-- Tests: pgTAP 32_delete_my_account.
-- =====================================================================
create function public.delete_my_account()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if public.current_chef_id() is not null then
    raise exception 'kitchen_account' using errcode = '42501';
  end if;
  delete from auth.users u where u.id = v_uid;
end
$$;
comment on function public.delete_my_account() is
  'La clienta de la sesión borra su cuenta (auth.md §20): Auth, perfil y datos de la cuenta en cascada; su ficha en clients queda sin la cuenta. La cocina no: 42501.';
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
