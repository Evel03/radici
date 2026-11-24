-- =====================================================================
-- PR04 (Auth fijada desde el repo, docs/contracts/auth.md §4): handle_new_user deja de copiar
-- full_name de raw_user_meta_data al perfil.
--
-- Los metadatos de un usuario los escribe el propio usuario al registrarse (signUp data): un nombre
-- puesto ahí llegaba al perfil sin que nadie lo hubiera verificado, y el perfil se muestra a la cocina.
-- Desde ahora el perfil nace siempre como client y sin nombre; el nombre lo escribe la persona en su
-- perfil (hoy la RLS solo le deja cambiar locale: desde client_rls_lockdown no hay otro camino por la API) o lo pone la cocina.
-- Lo demás queda igual que en 20261019100100_helpers_and_triggers.sql: rol siempre 'client' (nunca de
-- los metadatos), locale solo si es it, es o en, y on conflict do nothing.
--
-- create or replace conserva los privilegios que ya tiene la función (client_rls_lockdown la dejó sin
-- EXECUTE para PUBLIC, anon ni authenticated: un trigger no los necesita). Test estructural de su
-- regla clave: pgTAP 24_auth_accounts.
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_locale text := new.raw_user_meta_data ->> 'locale';
begin
  insert into public.profiles (id, role, locale)
  values (
    new.id,
    'client',
    case when v_locale in ('it','es','en') then v_locale else 'it' end
  )
  on conflict (id) do nothing;
  return new;
end
$$;
