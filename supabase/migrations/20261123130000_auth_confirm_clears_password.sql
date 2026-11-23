-- =====================================================================
-- PR05 (docs/contracts/auth.md §4): la primera confirmación del email borra la contraseña.
--
-- Por qué. El alta de una clienta es en dos pasos: signUp con una contraseña al azar, el link de la
-- confirmación la lleva a /accesso/ y ahí elige la suya. Sin este trigger, alguien podría registrarse
-- con el email de otra persona y una contraseña que conoce (secuestro previo de la cuenta): cuando la
-- dueña del email confirma, su cuenta quedaría con la contraseña del atacante. Al borrarla en la
-- primera confirmación, esa contraseña no sobrevive; la dueña elige la suya en /accesso/.
--
-- Qué hace. Un trigger BEFORE UPDATE en auth.users sobre las cuentas confirmadas:
--   * Solo cuando email_confirmed_at pasa de null a una fecha (confirmar por el link, por el código,
--     recuperar una cuenta sin confirmar, que Google o Apple unan una identidad a una cuenta sin
--     confirmar, o confirmar a mano desde el panel): encrypted_password queda en NULL.
--   * En esa misma confirmación, y en todo UPDATE posterior que cambie raw_user_meta_data de una cuenta
--     confirmada: raw_user_meta_data (user_metadata) queda solo con locale (si es it, es o en), email,
--     email_verified, phone_verified y sub, con su tipo (email y sub, texto; los otros dos, booleano).
--     Lo demás lo escribió quien se registró (signUp data) y nadie lo verificó, y nada lo lee salvo
--     locale (handle_new_user y la plantilla del email). El nombre, el onboarding lo toma de
--     identity_data o de la credencial de Apple.
--   El segundo punto no puede quedar solo en la confirmación: GoTrue, después de confirmar, vuelve a
--   escribir user_metadata desde su copia en memoria (agrega email_verified) y, medido contra GoTrue
--   v2.197.0, esa segunda escritura devolvía los metadatos de más. Por eso también corre cuando
--   cambian los metadatos de una cuenta ya confirmada; la contraseña solo se borra en la primera vez.
-- Una cuenta creada ya confirmada (INSERT con email_confirmed_at) no dispara nada: la demo, con
-- contraseña, se crea confirmada y la contraseña se fija después. Una cuenta de la cocina (código, sin
-- contraseña) no cambia: promote_to_chef y sync_chef_members actualizan la contraseña sin tocar
-- email_confirmed_at ni los metadatos, así que el trigger no interviene.
--
-- Por qué es mínimo. Una excepción en un trigger de auth.users rompe el alta y el login de todos. La
-- función no lee ni escribe ninguna tabla, no llama a nada de afuera y no lanza excepciones: solo
-- ajusta NEW. security definer con search_path vacío y de postgres, por convención de las funciones
-- de auth.users (handle_new_user). Sin EXECUTE para nadie: un trigger no lo necesita, solo quien crea
-- el trigger.
-- Test estructural de su regla clave: pgTAP 24_auth_accounts.
-- =====================================================================
create or replace function public.auth_confirm_clears_password()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_raw    jsonb := new.raw_user_meta_data;
  v_locale text;
  v_meta   jsonb := '{}'::jsonb;
begin
  -- Solo en la primera confirmación; una escritura posterior de metadatos no toca la contraseña.
  if old.email_confirmed_at is null then
    new.encrypted_password := null;
  end if;

  if pg_catalog.jsonb_typeof(v_raw) = 'object' then
    v_locale := v_raw ->> 'locale';
    if pg_catalog.jsonb_typeof(v_raw -> 'locale') = 'string' and v_locale in ('it', 'es', 'en') then
      v_meta := pg_catalog.jsonb_build_object('locale', v_locale);
    end if;
    select v_meta || coalesce(pg_catalog.jsonb_object_agg(e.key, e.value), '{}'::jsonb)
      into v_meta
      from pg_catalog.jsonb_each(v_raw) as e
     where (e.key in ('email', 'sub') and pg_catalog.jsonb_typeof(e.value) = 'string')
        or (e.key in ('email_verified', 'phone_verified') and pg_catalog.jsonb_typeof(e.value) = 'boolean');
  end if;

  new.raw_user_meta_data := v_meta;
  return new;
end
$$;

comment on function public.auth_confirm_clears_password() is
  'Trigger de auth.users: en la primera confirmación del email borra la contraseña y, en esa y en cada escritura de metadatos de una cuenta confirmada, deja en user_metadata solo locale validado, email, email_verified, phone_verified y sub (contra el secuestro previo de cuentas). No lee ni escribe tablas ni lanza excepciones.';

revoke all on function public.auth_confirm_clears_password() from public, anon, authenticated, service_role;

create trigger on_auth_user_confirmed_clear_password
  before update of email_confirmed_at, raw_user_meta_data on auth.users
  for each row
  when (new.email_confirmed_at is not null
        and (old.email_confirmed_at is null or old.raw_user_meta_data is distinct from new.raw_user_meta_data))
  execute function public.auth_confirm_clears_password();
