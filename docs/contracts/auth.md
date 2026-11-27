# Contrato: Auth (Supabase) de Radici

Qué hace Auth en el proyecto, qué ajustes fija el repo en producción, cómo se comprueban y qué se acepta a sabiendas. Se aplica en cada despliegue (`deploy-supabase.yml`, paso «Auth desde el repo»), antes de `db push`. SPEC §6. Lo que se cambie de esto en el panel de Supabase lo pisa el próximo despliegue: un cambio es un PR.

## 1. Qué hace Auth hoy (M0, altas apagadas)

- Login con **código por email** (OTP de 10 cifras, vale una hora desde PR16; antes 8 cifras y 600 segundos). La app llama a `signInWithOtp(email, shouldCreateUser: false)` y después `verifyOTP(type: email)`; no manda `emailRedirectTo` y el email no lleva link, solo el código. Por eso `site_url` y `uri_allow_list` no intervienen en el login de `/gestione/` (web, iOS y Android): no hay ninguna redirección que permitir.
- Las altas están apagadas (`disable_signup`): las cuentas de Evelyn y de sus colaboradores las crea confirmadas el despliegue (contrato public-request §10.1), y también las cuentas de prueba de clienta del secreto `TEST_CLIENT_EMAILS` (§15). Se abren en M2, en su propio PR, con Turnstile.
- El email del código sale por el SMTP de Resend (`RESEND_SMTP_KEY`) con la plantilla `supabase/templates/login_code.html`, que se usa para «Magic link» (usuario existente) y «Confirm signup». Sale en el idioma de `user_metadata.locale` (it, es, en).

## 2. Lo que fija el repo

`supabase/scripts/auth-config.ts` arma tres PATCH a `PATCH /v1/projects/{ref}/config/auth` (Management API). Los nombres de campo son los del OpenAPI público (`https://api.supabase.com/api/v1-json`, leído el 23/11/2026, esquema `UpdateAuthConfigBody`); un test los compara con esa lista.

| Parte | Campo (Management API) | Valor | Equivale en `config.toml` |
|---|---|---|---|
| security | `disable_signup` | `true` | `[auth] enable_signup = false` |
| security | `external_email_enabled` | `true` | `[auth.email] enable_signup = true` |
| security | `mailer_otp_length`, `mailer_otp_exp` | 10, 3600 (§13; hasta PR16, 8 y 600) | `otp_length`, `otp_expiry` |
| security | `security_captcha_enabled`, `security_captcha_provider`, `security_captcha_secret` | `true`, `turnstile`, la secreta de `TURNSTILE_AUTH_SECRET_KEY` (§10; no se compara después del PATCH: no vuelve en claro) | sin `[auth.captcha]`: en local va apagado |
| security | `site_url`, `uri_allow_list` | `https://radicicucina.app/app/` (las dos) | (local usa `127.0.0.1`) |
| security | `mailer_autoconfirm`, `sms_autoconfirm` | `false` | `[auth.email]` y `[auth.sms]` `enable_confirmations = true` |
| security | `mailer_allow_unverified_email_sign_ins` | `false` | (por defecto) |
| security | `mailer_secure_email_change_enabled` | `true` | `double_confirm_changes = true` |
| security | `security_manual_linking_enabled` | `false` | `enable_manual_linking = false` |
| security | `external_email_magic_link_disabled` | `false` | (magic link y código por email prendidos: el código de Evelyn sale de esa plantilla) |
| security | `rate_limit_verify` | `10` | `[auth.rate_limit] token_verifications = 10` |
| security | `hook_custom_access_token_enabled`, `hook_custom_access_token_uri` | `true`, `pg-functions://postgres/public/kitchen_access_token_hook` (§8: la cocina solo entra con código) | `[auth.hook.custom_access_token] enabled`, `uri` |
| security | `hook_before_user_created_enabled` | `false` (el freno de altas se prende en PR20, con las altas) | sin `[auth.hook.before_user_created]` |
| security | `rate_limit_token_refresh`, `rate_limit_otp`, `rate_limit_anonymous_users`, `rate_limit_sms_sent`, `rate_limit_web3` | `20`, `10`, `1`, `1`, `1` (§9) | `token_refresh`, `sign_in_sign_ups`, `anonymous_users`, `sms_sent`, `web3` |
| security | `external_google_enabled`, `external_apple_enabled`, `external_phone_enabled`, `external_anonymous_users_enabled`, `external_web3_solana_enabled`, `external_web3_ethereum_enabled`, `saml_enabled` | `false` | sin proveedores en `config.toml` |
| security | `password_min_length`, `password_required_characters` | `10`, letras y números (§12) | `[auth] minimum_password_length = 10`, `password_requirements = "letters_digits"` |
| security | `security_update_password_require_current_password`, `security_update_password_require_reauthentication` | `true`, `false` (§12) | (la CLI 2.121 no tiene el primero), `[auth.email] secure_password_change = false` |
| smtp | `smtp_host`, `smtp_port`, `smtp_user`, `smtp_pass`, `smtp_admin_email`, `smtp_sender_name` | Resend, remitente de `MAIL_FROM` | |
| smtp | `smtp_max_frequency` | `60`: un email de Auth por cuenta por minuto (§10) | `[auth.email] max_frequency = "1s"` en local, para probar sin esperar |
| templates | `mailer_subjects_*` y `mailer_templates_*_content` de `magic_link`, `confirmation`, `recovery`, `email_change`, `reauthentication` e `invite`; `rate_limit_email_sent` | los asuntos de `config.toml` y los HTML de `supabase/templates/`, generados desde `auth_emails.ts` (§13); 100 | `[auth.email.template.*]` |
| templates | `mailer_notifications_password_changed_enabled`, `mailer_subjects_password_changed_notification`, `mailer_templates_password_changed_notification_content` | `true`, asunto de `config.toml`, `password_changed.html` (§12) | `[auth.email.notification.password_changed]` |

`site_url` y `uri_allow_list` son la única URL del área de clientes (`/app/`). No incluyen `/gestione/`, porque el login de Evelyn no redirige. Si algún día `/gestione/` usara `emailRedirectTo` (links en lugar de código), hay que sumarlo a `uri_allow_list` en `auth-config.ts` (una lista exacta, sin comodines).

Cada ajuste de la tabla que tiene su par en `config.toml` se comprueba también ahí: `authSecurityConfig` falla si `config.toml` prende un autoconfirm (`enable_confirmations = false`), el linking manual, los anónimos, el teléfono, Web3 o cualquier `[auth.external.*]`, apaga el cambio de email seguro, cambia `token_verifications` (tiene que ser 10) o afloja las contraseñas (§12). Así lo local y lo de producción no se separan y el despliegue corta (con código 2) antes de la primera llamada a la API.

## 3. Cómo se comprueba, y por qué corta antes de migrar

1. El paso lee la configuración vigente (`GET /v1/projects/{ref}/config/auth`) antes del primer PATCH.
2. Después de cada PATCH compara la respuesta con el cuerpo que mandó (`auth-config.ts verify <parte>`, campo por campo). Un campo que no quedó igual, o un nombre de campo equivocado (la API ignora en silencio lo que no conoce y no lo devuelve), da un error con los **nombres** de los campos, nunca sus valores, y el paso falla. `db push` no corre.
3. La clave del SMTP (`smtp_pass`) no se compara (la API no la devuelve en claro). La respuesta entera, que la trae, queda en un archivo temporal que solo leen `jq` y `auth-config.ts`: no se imprime.
4. Una sola vez (mientras haya algo que cambiar) el resumen del paso anota la versión de GoTrue (`GET /v1/projects/{ref}/health?services=auth`, campo `info.version`) y los nombres de los campos de producción que cambian. Sin valores. Si hay que leer la versión y no se puede, avisa y sigue: no es un ajuste.

Cada PATCH queda aplicado aunque un paso posterior corte: si falla el `verify` de `smtp` o de `templates`, `security` ya está en producción (y la migración de `handle_new_user` todavía no). Nada de eso es más débil que antes y con las altas apagadas es inofensivo. El despliegue es idempotente: se corrige con un nuevo despliegue, sin pasos manuales.

**Si el despliegue corta por un campo distinto.** El error dice los nombres de los campos (nunca los valores) y `db push` no corrió: no se migró nada. La salida es un PR que corrige el nombre o el valor en `auth-config.ts` (por ejemplo, un campo que el plan de Supabase no deja cambiar, o que la API devuelve en otro formato). No arreglarlo en el panel, porque el próximo despliegue lo pisa, ni forzarlo con `RESEND_TRACKING_RESTRICTED_OK`, que es solo del paso de Resend.

Lo que este PR cambia en producción respecto de lo que `auth-config.ts` fijaba antes (altas, código de 8 cifras y 600 s, CAPTCHA apagado, SMTP, plantillas, 100 emails por hora): `site_url` y `uri_allow_list`, `mailer_autoconfirm`, `sms_autoconfirm`, `mailer_allow_unverified_email_sign_ins`, `mailer_secure_email_change_enabled`, `security_manual_linking_enabled`, `external_email_magic_link_disabled`, `rate_limit_verify`, y los proveedores apagados. Solo cambian los que hoy tengan otro valor en el panel; la lista exacta la dice el resumen del primer despliegue.

## 4. El perfil de una cuenta nueva

`handle_new_user` (trigger `on_auth_user_created`, migración `20261123120000_auth_profile_name.sql`) crea el perfil siempre como `client` y **sin nombre**: ya no copia `full_name` de `raw_user_meta_data`, que lo escribe quien se registra y nadie verificó. El idioma sí se copia, si es `it`, `es` o `en`. El nombre no lo escribe la persona por la API: desde `20261123100000_client_rls_lockdown` `authenticated` solo puede actualizar `locale` de su fila. Lo pone la cocina, o una Edge Function que algún PR posterior tiene que dar (hoy no hay ese camino: las cuentas nuevas quedan sin nombre hasta entonces). pgTAP `24_auth_accounts` lo prueba (con `full_name` y `role` en los metadatos) y comprueba la regla en el código de la función.

### La primera confirmación borra la contraseña

Migración `20261123130000_auth_confirm_clears_password.sql`: el trigger `on_auth_user_confirmed_clear_password` (BEFORE UPDATE OF `email`, `email_confirmed_at`, `raw_user_meta_data` en `auth.users`; función `public.auth_confirm_clears_password`, security definer, `search_path` vacío, de postgres y sin EXECUTE para nadie: un trigger no lo necesita; no lee ni escribe tablas ni lanza excepciones, porque una excepción en un trigger de `auth.users` rompe el login de todos).

- **Contra qué protege.** El alta de una clienta es en dos pasos: `signUp` con una contraseña al azar, el link de la confirmación la lleva a `/accesso/` y ahí elige la suya. Sin el trigger, alguien podría registrarse con el email de otra persona y una contraseña que conoce (secuestro previo): cuando la dueña confirma, la cuenta quedaría con la contraseña del atacante. Al borrarla en la primera confirmación, esa contraseña no sobrevive.
- **Qué hace.** Cuando `email_confirmed_at` pasa de null a una fecha, o cuando cambia el `email` de una cuenta confirmada: `encrypted_password` queda en NULL. El segundo caso es el cambio de email con la doble confirmación (`updateUser({email})`): al confirmarlo GoTrue pone `email = email_change` sin tocar `email_confirmed_at`, y sin este caso quien registró un email propio con una contraseña que conoce, y lo cambia al de otra persona, la conservaría cuando la víctima confirma (el mismo secuestro previo). Quien cambia su email y ya había elegido contraseña la pierde: recupera por el email nuevo o entra por código. Eso cubre la confirmación por el link o por el código, la recuperación de una cuenta sin confirmar, que Google o Apple unan una identidad a una cuenta sin confirmar y confirmar a mano desde el panel. En esa confirmación, y en cada escritura posterior de `raw_user_meta_data` de una cuenta confirmada, los metadatos (`user_metadata`) quedan solo con `locale` (si es `it`, `es` o `en`), `email`, `email_verified`, `phone_verified` y `sub`, estos con su tipo. Lo hace también en las posteriores porque GoTrue, después de confirmar, vuelve a escribir los metadatos desde su copia en memoria (agrega `email_verified`) y esa segunda escritura devolvía lo que el alta había puesto: medido contra GoTrue v2.197.0. La contraseña, en cambio, solo se borra la primera vez.
- **Nada lee `user_metadata` salvo `locale`** (`handle_new_user` y la plantilla del email). El onboarding toma el nombre de `identity_data` (Google) o de la credencial de Apple, nunca de los metadatos.
- **`identity_data` no es confiable para el provider email.** El trigger limpia `auth.users`, no `auth.identities`: la identidad `email` conserva el `identity_data` del alta (full_name, role y lo demás que escribió quien se registró; medido contra v2.197.0). Solo las identidades `google` y `apple` traen un nombre verificado: el onboarding tiene que filtrar por `identities.provider in ('google','apple')` y nunca leer el de `email`.
- **Lo que no toca.** Una cuenta creada ya confirmada con `INSERT` no dispara nada; las cuentas que GoTrue crea y confirma después sin contraseña (admin sin contraseña, Google, Apple) no cambian en lo de la contraseña, y la cocina (código, sin contraseña) tampoco: `promote_to_chef` y `sync_chef_members` cambian la contraseña sin tocar `email_confirmed_at` ni los metadatos.
- **Admin con contraseña: la contraseña no sobrevive.** `POST /admin/users` con `email_confirm: true` y `password` crea el usuario y lo confirma en un segundo paso (un UPDATE), así que el trigger borra la contraseña (medido contra GoTrue v2.197.0: queda en NULL y el login con esa contraseña da 400). Una cuenta con contraseña, como la demo, se crea confirmada **sin** `password` y la contraseña se fija después (`PUT /admin/users/{id}` con `password`), que no vuelve a disparar nada. Ojo: un `PUT` que confirma y fija la contraseña a la vez sobre una cuenta sin confirmar la conserva (GoTrue la fija después de confirmar; medido contra v2.197.0); eso no abre nada, porque la contraseña la pone el admin, pero «confirmar desde el panel borra la contraseña» vale solo si en esa operación no se la fija. `deploy-accounts.sh` crea las cuentas de la cocina con una contraseña al azar que no sobrevive: queda en NULL, y la cocina entra con el código; para ella no cambia nada.
- **Límite conocido: un cambio de email no le saca la cuenta a quien lo pidió (sus sesiones siguen, y el último link da otra).** Medido el 23/11/2026 contra GoTrue v2.197.0 local (secure email change prendido): una atacante se registra con un email propio, confirma, fija una contraseña con su sesión y pide `updateUser({email: víctima})`; se siguen los dos links (el del email viejo y el del nuevo). Resultado: `encrypted_password` queda en NULL y la contraseña de ella da 400 (`invalid_credentials`), pero su sesión sigue: el refresh token da tokens nuevos (200) y el access token vale (`GET /user` 200 con el email de la víctima). Se probó cerrar las sesiones desde el mismo trigger (`delete from auth.sessions where user_id = new.id` al cambiar el email; postgres puede, los refresh tokens se van en cascada, GoTrue contesta `refresh_token_not_found` y `session_not_found`, y el verify del cambio sigue andando) y **no se dejó**: no cierra el hueco. GoTrue crea la sesión del link de verificación después del UPDATE, así que quien sigue el último link (la atacante controla el del email viejo y elige cuándo hacerlo) recibe una sesión nueva sobre la cuenta ya con el email de la víctima, con la que fija otra contraseña (`PUT /user`, `security_update_password_require_reauthentication = false`) y entra con ella (200, medido). Tampoco hace falta que siga el último link: si la víctima confirma última, la sesión que la atacante tenía antes del cambio sigue valiendo y con ella fija otra contraseña (200, medido, segunda reproducción). Por lo mismo, borrar la contraseña al cambiar el email tampoco frena a una atacante decidida: es defensa en profundidad. El cierre real es que **un cliente no pueda cambiar su email**: lo hace el PR del hook Send Email que bloquea `email_change`. **Las altas no se abren antes de ese PR**: el PR que las abra comprueba en el despliegue que el hook esté prendido, y el del hook prueba en producción que un `PUT /user {email}` falla sin dejar `email_change` ni `email_change_sent_at` pendientes en `auth.users`. Mientras tanto no hay riesgo en producción: las altas están apagadas y nadie más que la cocina tiene cuenta. El access token vive hasta su vencimiento (`jwt_exp`, 3600 s) salvo que se cierre su sesión.
- **Otros caminos que conservarían acceso (medidos, local, v2.197.0).** Teléfono: `PUT /user {phone}` da 500 (sin proveedor de SMS) y `phone` queda vacío; `external_phone_enabled` y las altas por SMS están apagados. MFA: `POST /factors` (totp y phone) da 422 (`mfa_*_enroll_not_enabled`), y `auth.mfa_factors` queda en 0; si algún día se prende, un factor enrolado antes del cambio sobreviviría a él y habría que borrarlo. Reautenticación: `GET /reauthenticate` manda el nonce al email actual (ya el de la víctima). Identidades: `GET /user/identities/authorize` da 404 `manual_linking_disabled`; Google y Apple están apagados; la única identidad es la `email`.
- **Probado.** pgTAP `24_auth_accounts` modela GoTrue (INSERT sin confirmar y después el UPDATE) y comprueba la regla en el código de la función y en la definición del trigger. En local, con GoTrue v2.197.0 real (el del CLI 2.121.0), `encrypted_password` quedó en NULL y los metadatos limpios al final de: alta ajena y confirmación de la dueña (link y código de 8 cifras; la dueña fija después su contraseña y la del atacante da 400), recuperación de una cuenta sin confirmar (link y código), alta por `signInWithOtp` y confirmación, alta por admin (con y sin contraseña, y confirmar a mano), y el login por código de una cuenta de la cocina (confirmada, sin contraseña) dos veces. Google no se puede correr local (sin proveedor ni ida y vuelta a Google): se modeló con SQL como lo hace GoTrue al vincular una identidad con el email verificado (crea la identidad `google` y confirma al usuario), con el mismo resultado.

## 5. Resend: sin seguimiento de aperturas ni de clics

Con el seguimiento prendido, Resend reescribe los links de los emails por su dominio y los ve: en los emails de Auth serían links de acceso. El despliegue lo comprueba antes de tocar Auth (`supabase/scripts/resend-tracking.ts`, paso «Seguimiento de Resend apagado»): lee `GET /domains` y `GET /domains/{id}` (campos `open_tracking` y `click_tracking`) y corta si algún dominio tiene uno prendido, o si Resend no informa el campo. Se revisan **todos** los dominios de la cuenta de Resend, no solo el de `MAIL_FROM`: uno ajeno con seguimiento también corta. **Lo apaga la dueña de la cuenta de Resend** (Domains → cada dominio → Open Tracking y Click Tracking); el despliegue nunca lo cambia.

Resend no deja leer los dominios con una clave «solo de envío» (`restricted_api_key`). Con una así el paso corta, para no dar por bueno lo que no pudo comprobar, salvo que alguien ponga a propósito la variable `RESEND_TRACKING_RESTRICTED_OK=true` después de mirar el panel (entonces solo avisa). Lo que corresponde es cargar una tercera clave, con acceso completo, solo para leer, como secreto `RESEND_READ_KEY` (el paso la usa si existe y, si no, cae en `RESEND_API_KEY`). No reutilizar la de la función: esa tiene que seguir siendo solo de envío (public-request §4).

**Antes de mergear este PR**: el primer despliegue pasa por este paso y, con la clave actual (probablemente solo de envío), corta antes de Auth y de `db push`. Mirar en resend.com → Domains que el seguimiento esté apagado y cargar `RESEND_READ_KEY` o poner la variable de Actions `RESEND_TRACKING_RESTRICTED_OK=true`. El login de Evelyn no se afecta, pero hasta entonces no se despliega nada de `supabase/`. Con la variable puesta, cada corrida repite el aviso en el log del paso.

## 6. Qué se acepta a sabiendas

- **Se puede averiguar si un email tiene cuenta.** Por la API de Auth (`/otp` con `create_user: false`, que hoy responde `otp_disabled` si el email no existe; `/signup`; `/recover`; el login con contraseña) alguien puede distinguir un email con cuenta de uno sin cuenta: los mensajes de error y los tiempos difieren, y `/signup`, aun con la confirmación de email prendida, contesta 200 en los dos casos pero con un usuario ofuscado que se distingue (para un email ya confirmado devuelve `role` vacío y sin metadatos; medido el 23/11/2026 contra GoTrue v2.197.0 local). No se promete lo contrario. Mitigaciones: CAPTCHA en cada pedido de código (M2), límites por IP y por email de Auth (`rate_limit_otp`, `max_frequency`, `rate_limit_email_sent`), y que lo único que revela es que una persona tiene cuenta, nunca datos de ella.
- **`rate_limit_verify = 10` no es «11 intentos y 429».** GoTrue (v2.197.0, la del CLI 2.121.0) usa un cubo con ráfaga fija de 30 y recarga de 10 cada 5 minutos por IP: el intento 31 seguido recibe 429, y después unos 2 por minuto. Medido el 23/11/2026 con un GoTrue local con la cabecera de IP configurada: 11 `/verify` seguidos dan 403 (código inválido) y el 31.º, 429. Contra un código de 10 cifras que vale una hora (desde PR16; antes, 8 cifras y 10 minutos) sigue siendo inviable, pero no hay que prometer un tope de 10. Además, con `supabase start` el límite por IP **no se aplica** (el CLI no configura la cabecera de IP): solo se puede probar con `GOTRUE_RATE_LIMIT_HEADER`. En producción lo aplica la infraestructura de Supabase.
- **Linking automático de identidades por email.** Con el linking manual apagado, GoTrue sigue uniendo por email verificado cuando haya proveedores (Google y Apple, en sus PRs). Se acepta para las clientas.
- **Frase en el email de Evelyn.** El código lleva «non condividere questo codice con nessuno, nemmeno con Evelyn» (y su equivalente en es y en): es el mismo email para todas las cuentas, también para la de ella.

## 7. Plantillas

Desde PR16 las seis plantillas salen de una sola fuente (§13). `login_code.html` imprime solo `{{ .Token }}`; `confirmation.html` y `recovery.html`, solo `{{ .TokenHash }}` (en el link a `/accesso/`); las otras tres, nada. Todas usan `.Data` únicamente para comparar `.Data.locale` con `es` o `en` (un test lo exige, también para los asuntos de `config.toml`): nunca imprimen metadatos del usuario, ni `.Email`, `.ConfirmationURL`, `.SiteURL` ni `.RedirectTo`.

## 8. Hooks de Auth: la cocina solo con código y el freno de altas (PR07: las funciones, sin prender)

Migración `20261126100000_auth_hooks.sql`, pgTAP `26_auth_hooks`. **PR07 trajo las funciones sin prender nada** (el PATCH de Auth corre antes de `db push`: un hook prendido que apunta a una función que todavía no existe rompería el login de todos). **PR08 prende el de la cocina** (§8.1); el de las altas sigue apagado hasta PR20, cuando se abran.

### Contratos de Supabase (leídos el 25/11/2026)

Fuentes: https://supabase.com/docs/guides/auth/auth-hooks, https://supabase.com/docs/guides/auth/auth-hooks/custom-access-token-hook, https://supabase.com/docs/guides/auth/auth-hooks/before-user-created-hook y, para los valores de `amr`, https://supabase.com/docs/guides/auth/auth-mfa.

- **Custom Access Token hook.** Entrada: `{user_id, claims, authentication_method}`; `claims` trae `aud, exp, iat, sub, email, phone, app_metadata, user_metadata, role, aal, amr, session_id, is_anonymous`, y `amr` es una lista de `{method, timestamp}` con el método más reciente primero. Salida: `{claims}` (los claims finales; si falta uno obligatorio, Auth da error) o `{error: {http_code, message}}`. Sin `http_code`, 500.
- **Before User Created hook.** Entrada: `{metadata: {uuid, time, name: "before-user-created", ip_address}, user: {…forma de auth.users…}}` (el usuario todavía no está en la base). Salida: `{}` para dejar pasar, o `{error: {http_code, message}}` para rechazar.
- **Postgres hooks:** 2 segundos de plazo, dentro de una transacción; los errores no se reintentan. Grants según la documentación: `grant execute … to supabase_auth_admin` y `revoke execute … from authenticated, anon, public`.
- **Medido contra GoTrue v2.197.0 local** (el del CLI 2.121.0), con `pg-functions://postgres/public/<función>`: el error de un hook de Postgres llega al cliente con el `http_code` que devuelve la función (el aviso de la documentación de que 403 y 400 de los hooks HTTP pasan a 500 no vale para los de Postgres) y con `msg` igual al `message` de la función: `403 {"code":403,"error_code":"unknown","msg":"kitchen_code_only"}`. El `error_code` es siempre `unknown`: el cliente distingue por `msg`. Una excepción de la función da 500.

### `public.kitchen_access_token_hook(event jsonb)`

Para el dueño de una cocina (`chefs.profile_id`) o un colaborador (`chef_members.profile_id`): si `claims.amr` no es una lista no vacía donde **todos** los métodos son `otp` o `magiclink`, responde `{error: {http_code: 403, message: "kitchen_code_only"}}`. A cualquier otra cuenta (las clientas) le devuelve `{claims}` tal como llegaron. Decide por `claims.amr` y **nunca** por `authentication_method`: en un refresh vale `token_refresh` (documentado) y lo que cuenta es con qué se abrió la sesión. Un `amr` que falta, vacío, que no es lista, con elementos que no son objetos, con `method` que no es texto o en otra capitalización: 403 (falla cerrado). El orden no importa y una lista con `otp` y `password` juntos también es 403. Un `user_id` ausente o que no es uuid lanza una excepción (500): nunca deja pasar por las dudas.

Una sesión de la cocina abierta con contraseña (antes de prender el hook) se corta en su próximo refresh (el `amr` conserva `password`): hay que volver a entrar con código. Es lo buscado; avisarle a Evelyn y a sus colaboradores al prender el hook (PR08).

### `amr` por flujo (medido contra GoTrue v2.197.0 local, 25/11/2026)

| Flujo | `claims.amr` | Con el hook, en una cuenta de la cocina |
|---|---|---|
| Contraseña (`/token?grant_type=password`) | `[{"method":"password"}]` | 403 `kitchen_code_only` (medido: cocinera y colaborador) |
| Código del email (`/otp` + `/verify type=email`) | `[{"method":"otp"}]` | pasa (medido: cocinera y colaborador) |
| Refresh de una sesión abierta con código | `[{"method":"otp"}]` (el `amr` de la sesión se conserva; en el evento, `authentication_method` vale `token_refresh`, según la documentación) | pasa (medido) |
| Refresh de una sesión abierta con contraseña | `[{"method":"password"}]` (medido en una clienta) | 403 (pgTAP, con `token_refresh` y `amr` password) |
| Confirmación del alta (desde PR16, el link de `/accesso/`: `/verify` con `token_hash`) | `[{"method":"otp"}]` | n/a (es una clienta) |
| Recuperación de contraseña (link del email, `/verify type=recovery`) | `[{"method":"otp"}]` (no `recovery`) | pasaría: es tener el email, igual que el código; si después fija una contraseña, el login con contraseña sí da 403 |
| Admin (`generate_link` magiclink + `/verify` con `token_hash`) | `[{"method":"otp"}]` | pasa (medido) |
| Google en la web (`signInWithOAuth`) | no se puede correr en local (sin proveedores). La documentación lo da como `oauth` | 403 (por la lista blanca, sea cual sea el valor) |
| Google o Apple con `id_token` (`signInWithIdToken`) | no se puede correr en local; sin medir (la documentación no lo lista aparte) | 403 (por la lista blanca: solo `otp` y `magiclink` pasan) |

Por eso es una lista blanca (`otp`, `magiclink`) y no una lista de métodos prohibidos: cualquier método que GoTrue agregue o llame distinto queda afuera de la cocina sin tocar nada. `magiclink` se acepta porque es la variante documentada del link del email (en este GoTrue los links dan `otp`).

### `public.before_user_created_guard(event jsonb)`

Se evalúa en este orden, todo dentro de un candado de transacción (`pg_advisory_xact_lock`): dos altas simultáneas no leen el mismo contador (medido: 10 altas simultáneas de la misma IP con el tope en 5 dejaron pasar exactamente 5).

1. **Pausa** (`private.auth_guard.paused`): `403 signups_paused`.
2. **Tope diario** (`daily_cap`, por defecto **50**): altas permitidas en las últimas 24 h; `429 signups_daily_cap`.
3. **Tope por IP y hora** (`ip_hour_cap`, por defecto **5**): altas permitidas de esa IP en la última hora; `429 signups_ip_cap`.

Solo cuentan las altas **permitidas** (una rechazada no deja renglón: quien insiste no alarga su propio bloqueo ni infla el tope diario). Cuenta toda alta que crea un usuario por Auth (`/signup`, `/otp` con `create_user: true`, Google o Apple con cuenta nueva: medido que `/otp` con `create_user: true` pasa por el hook); **no** frena el alta por la API de admin (`POST /admin/users`: medido, pasa aun en pausa), así que el despliegue que crea la cuenta de la cocinera y las de los colaboradores no depende del freno. Un `/signup` de un email que ya existe no crea usuario y no cuenta.

- **IP.** Entra por `metadata.ip_address`. IPv4 tal cual; **IPv6 reducida a su /64** (rotar dentro de un /64 no da un cubo nuevo); una IPv4 mapeada (`::ffff:a.b.c.d`) cuenta como la IPv4. Sin IP o con un texto que no es una IP: un cubo único `sin-ip` (no es un permiso: comparte el tope por IP). Local: GoTrue toma la IP de `X-Forwarded-For` (medido) y, sin la cabecera, la del socket.
- **Hash.** `HMAC-SHA-256(clave = pepper, mensaje = IP normalizada)` en hexadecimal (`extensions.hmac`, pgcrypto). El pepper (`private.auth_guard.ip_pepper`, 32 bytes al azar generados por la migración) vive en la misma base que los hashes: no protege contra quien lea la base entera, sí contra quien lea solo la tabla `signup_attempts` (un volcado parcial), porque un SHA-256 pelado de una IPv4 se invierte por fuerza bruta en segundos. La IP nunca se guarda ni se loguea. Cambiar el pepper solo reinicia los contadores por IP.
- **Purga a las 48 h.** Cada llamada borra los renglones de más de 48 h (`private.purge_signup_attempts()`) y además corre por pg_cron cada hora (`radici-purge-signup-attempts`, minuto 17), para que no queden hashes viejos si un día no hay altas. La ventana de conteo es de 24 h; las 48 h son margen.
- **Fallo cerrado.** Si falta la fila de `private.auth_guard`, la función lanza y el alta no pasa.

**Permisos.** Las dos funciones son `security definer` (dueño `postgres`, `search_path` vacío): las tablas que tocan (`chefs`, `chef_members`, `auth_guard`, `signup_attempts`) están cerradas y `supabase_auth_admin` no tiene ningún privilegio de tabla ni `usage` sobre `private`, y no se le da. Lo único que se le concede es `EXECUTE` sobre las dos funciones; a `public`, `anon`, `authenticated` y `service_role` se les quita (pgTAP lo comprueba, además del inventario de `00_schema`). `private.purge_signup_attempts()` no la ejecuta nadie de la API ni de Auth.

### Runbook: pausar las altas en una emergencia

Cuando el hook de las altas esté prendido (PR20), desde el SQL editor del panel de Supabase (o `psql` como `postgres`):

```sql
update private.auth_guard set paused = true;    -- pausa: las altas dan 403 signups_paused
update private.auth_guard set paused = false;   -- las reabre
update private.auth_guard set daily_cap = 100, ip_hour_cap = 10;   -- cambiar los topes
select paused, daily_cap, ip_hour_cap from private.auth_guard;    -- ver los valores (sin el pepper)
select count(*) from private.signup_attempts where created_at > now() - interval '24 hours';  -- altas de hoy
```

Rige en la próxima alta (los valores se leen en cada llamada). No toca el login de nadie ni las cuentas que crea el despliegue. Un atacante puede gastar el tope diario (50) y dejar sin alta a la gente de verdad por un día: la salida es subir `daily_cap`, o pausar y abrir de a poco. Es el costo de un tope que no depende de la IP.

### Qué se acepta a sabiendas

- **Rotar de IP.** Quien tiene muchas direcciones (o IPv6 repartida en muchos /64, por ejemplo un /48) evita el tope por IP; lo frena el diario (50). Con IPv6 el límite por IP es por /64, no por dirección.
- **IP spoofeable según el borde.** En local GoTrue confía en `X-Forwarded-For`. En producción la IP del hook la fija la cabecera que Supabase configura detrás de su proxy; no se midió (nada de este PR toca producción). Si no fuera confiable, el tope por IP sería inútil y quedaría el diario: medirlo antes de PR20.
- **IP compartida.** Una red con NAT (una oficina, un operador móvil) comparte el tope de 5 por hora: con altas poco frecuentes no debería pasar; el síntoma es `signups_ip_cap` y se arregla subiendo `ip_hour_cap`.
- **Sin IP.** Todas las altas sin IP comparten un cubo de 5 por hora: más estricto que con IP, a propósito.
- **Altas que fallan después del hook.** Si el alta falla luego (la transacción se revierte), el renglón del contador también: no cuenta.

### Orden de rollback

Si hay que apagar el hook de la cocina (§8.1 trae el comando): **primero** el PATCH de Auth con el hook apagado (`hook_custom_access_token_enabled: false`; corre antes de `db push`) y **después**, recién, tocar o borrar la función en una migración. Al revés, un hook prendido apuntaría a una función que ya no existe y rompería el login de todos. Lo mismo vale para el hook de las altas (PR20): una función de hook no se borra ni cambia de firma mientras haya un hook prendido que la use.

## 9. Límites de intentos

`auth-config.ts` fija los siete límites que la Management API deja cambiar (`rate_limit_*`, todos enteros de 1 a 2147483647; sin ellos valen los de fábrica de Supabase: 150 por 5 minutos para `/token`, 30 para `/otp` y familia). Cada uno tiene su par en `[auth.rate_limit]` de `config.toml` y `authSecurityConfig` corta si no coincide, igual que `token_verifications`. Fuentes (GoTrue v2.197.0): https://github.com/supabase/auth/blob/v2.197.0/internal/api/api.go (qué limitador lleva cada ruta), https://github.com/supabase/auth/blob/v2.197.0/internal/api/apilimiter/apilimiter.go (cómo se arma cada cubo), https://github.com/supabase/auth/blob/v2.197.0/internal/conf/configuration.go (campos y valores de fábrica), https://supabase.com/docs/guides/auth/rate-limits y el OpenAPI público `UpdateAuthConfigBody` (https://api.supabase.com/api/v1-json, leído el 25/11/2026). Sin números de línea: se citan por nombre de archivo e identificador.

**Cómo cuenta GoTrue.** Cada límite es un cubo por IP de **ráfaga fija de 30** (excepto anónimos, cuya ráfaga es el propio valor) que se recarga a `valor / 300` por segundo, o sea `valor` solicitudes cada 5 minutos. El valor **no baja la ráfaga**: frena el goteo sostenido, después de los primeros 30. Todo cuenta por IP: un NAT compartido comparte el cubo. Los límites solo funcionan si GoTrue conoce la IP (`GOTRUE_RATE_LIMIT_HEADER`; con `supabase start` a secas no se aplican). En Supabase alojado lo fija la plataforma; no se midió contra producción.

| Endpoint | Limitador (`apilimiter`) | Campo | Valor fijado | Qué frena | Qué no frena |
|---|---|---|---|---|---|
| `POST /token` (`grant_type=password`, `refresh_token`, id_token, PKCE; también cuenta la contraseña buena) | `Token` (se aplica dentro del handler) | `rate_limit_token_refresh` | **20** cada 5 min (de fábrica, 150) | Adivinar contraseñas desde una IP: 30 seguidos y después uno cada 15 s (240 por hora). Medido: el intento 31 da 429 | Un ataque repartido en muchas IP contra una cuenta (lo frenan el CAPTCHA, PR09–PR11; el hook de la cocina, PR07/PR08; y la política de contraseñas, PR14) |
| `POST /otp`, `/magiclink`, `/recover`, `/resend`, `/signup` (con email), `PUT /user` | `Otp`, `MagicLink`, `Recover`, `Resend`, `Signups`, `User` (todos el mismo valor, cada uno su cubo) | `rate_limit_otp` | **10** cada 5 min (de fábrica, 30) | Pedir códigos en ráfaga (spam de emails a una persona, enumeración de cuentas): 30 seguidos y después 10 cada 5 min | Más pedidos desde muchas IP (los acota `rate_limit_email_sent`, 100 por hora en todo el proyecto, y el máximo por usuario de 1 s/60 s de `[auth.email]`) |
| `GET/POST /verify` | `Verify` | `rate_limit_verify` | **10** cada 5 min (PR04) | Probar códigos de 10 cifras: el 31.º seguido da 429 (§6) | Muchas IP contra un mismo código (vale 600 s) |
| `POST /signup` sin email ni teléfono (anónimos) | `AnonymousSignIns` | `rate_limit_anonymous_users` | **1** por hora (mínimo de la API) | Nada que cuidar: los anónimos están apagados | — |
| SMS (`rate_limit_sms_sent`) y Web3 en `/token` (`rate_limit_web3`) | `Phone`, `Web3` | `rate_limit_sms_sent`, `rate_limit_web3` | **1** (mínimo de la API) | Nada que cuidar: teléfono y Web3 están apagados | — |
| Emails enviados | `Email` | `rate_limit_email_sent` | **100** por hora, todo el proyecto (PR04, parte `templates`) | Un tope al costo y a un ataque de emails | Para uno a uno por usuario, ver `[auth.email] max_frequency` |

No se pueden fijar desde el repo (la Management API no los expone): `/sso` y SAML (apagados), passkeys (apagados), registro de clientes OAuth (apagado) y el límite de MFA challenge y verify (15 por minuto, no se personaliza; MFA está apagado: `/factors` da 422).

**Por qué estos valores.**
- `/token`, 20: la app de Evelyn y la de las clientas renuevan la sesión una vez por hora por dispositivo (la ráfaga de 30 aguanta un NAT con varias personas entrando a la vez). 20 cada 5 minutos baja el goteo sostenido por debajo del de fábrica sin tocar el uso normal. Es poco más que un tope de comodidad: la ráfaga de 30 no se puede bajar, así que quien prueba contraseñas desde una IP todavía hace 30 seguidos y 240 por hora. Lo que de verdad detiene ese ataque no es el límite sino la cocina solo con código (PR07/PR08), el CAPTCHA (PR09–PR11) y la política de contraseñas (PR14).
- `/otp` y familia, 10: pedir un código es una acción rara (una por login). 10 cada 5 minutos sobra para una persona y para la oficina de una clienta.
- Los flujos apagados (anónimos, SMS, Web3): 1, lo mínimo que acepta la API. Si algún día se prenden, hay que subirlo en el mismo PR.

**Medido** (GoTrue v2.197.0 local, 25/11/2026, IP por `X-Forwarded-For` con `GOTRUE_RATE_LIMIT_HEADER`): contraseña mala desde una IP: 30 respuestas sin 429 y la 31.ª da `429 over_request_rate_limit`; la contraseña buena de esa IP también da 429 hasta que recarga (el cubo es de `/token`); otra IP no se afecta (200); `refresh_token` comparte el mismo cubo (el 31.º da 429); tras 16 s se recupera un intento (1 cada 15 s). `/otp` desde una IP: 30 envíos y el 32.º da 429 (la recarga de 10 cada 5 minutos devolvió uno durante la prueba). Uso normal desde otra IP: código, verificación y refresh dan 200.

### 8.1 El hook de la cocina, prendido (PR08)

`auth-config.ts` (parte `security`) fija `hook_custom_access_token_enabled: true` y `hook_custom_access_token_uri: "pg-functions://postgres/public/kitchen_access_token_hook"`, y `hook_before_user_created_enabled: false`. Los nombres son los del OpenAPI público (`UpdateAuthConfigBody` en https://api.supabase.com/api/v1-json, leído el 25/11/2026): cada hook tiene `hook_<nombre>_enabled` (boolean), `hook_<nombre>_uri` (texto) y `hook_<nombre>_secrets` (texto; solo para los hooks HTTP, un hook de Postgres no lleva secreto). `config.toml` lo repite (`[auth.hook.custom_access_token] enabled = true` y la misma `uri`) y `authSecurityConfig` corta si no coincide, o si `config.toml` prende `[auth.hook.before_user_created]`. El despliegue vuelve a leer lo que Supabase guardó (campo por campo, §3).

**Antes del PATCH, el despliegue mira la base de producción.** El paso «Hook de la cocina: la función existe» (`supabase/scripts/auth-hook-check.ts`, con tests y una API falsa) pregunta por `POST /v1/projects/{ref}/database/query/read-only` (Management API, solo lectura, con `SUPABASE_ACCESS_TOKEN`; nunca se imprime) si `public.kitchen_access_token_hook(jsonb)`: existe, es `security definer`, trae la regla `kitchen_code_only`, la ejecuta `supabase_auth_admin` y no la ejecutan `anon`, `authenticated`, `service_role` ni `PUBLIC`. La consulta:

```sql
select p.prosecdef as security_definer,
  has_function_privilege('supabase_auth_admin', p.oid, 'EXECUTE') as auth_admin,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated,
  has_function_privilege('service_role', p.oid, 'EXECUTE') as service_role,
  exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
          where a.grantee = 0 and a.privilege_type = 'EXECUTE') as public_exec,
  position('kitchen_code_only' in p.prosrc) > 0 as has_rule
from pg_proc p where p.oid = to_regprocedure('public.kitchen_access_token_hook(jsonb)')
```

Sin fila (la función no existe), con un grant de más o de menos, o con una respuesta que no se puede leer: el paso falla y **Auth no se toca**. Va antes de «Auth desde el repo» y después de la comprobación de Resend.

**Medido en local** (GoTrue v2.197.0, hook prendido; 25/11/2026): la cocinera y el colaborador entran con código (`amr` `otp`) y 5 refresh encadenados dan 200 en cada uno; con contraseña los dos dan `403 kitchen_code_only`; una clienta entra con contraseña (200) y renueva (200).

**Qué hace la app con un 403 en el refresh** (leído en `gotrue` 2.27.3, el de `pubspec.lock`, y en `session_controller.dart`): un 403 es una `AuthApiException`, no una `AuthRetryableFetchException` (esa es solo de red y de 5xx). `GoTrueClient._doRefresh` borra la sesión y emite `signedOut` (`SignOutReason.sessionExpired`); `SessionController._onUserChanged(null)` pasa a `SessionState.signedOut()` y `routes.dart` manda a la pantalla de login. No hay bucle: la sesión ya no existe y no se vuelve a pedir un refresh. No muestra ningún mensaje: la persona vuelve a la pantalla del código y entra con el código. Una excepción de la función (500) sí es reintentable: la app conserva la sesión y reintenta, sin cerrarla. La verificación con la app real (iOS, Android y `/gestione/`) está pendiente: se midió el comportamiento de GoTrue y se leyó el código de la app, no se corrió.

**Prueba en producción, por Nicolas (después del primer despliegue con el hook prendido):**
1. En una ventana privada, entrar a `/gestione/` con su cuenta de colaborador y el **código** del email (no hay otra manera: la cocina no tiene contraseña).
2. Comprobar que ve el área de Evelyn.
3. Esperar a que venza el token (más de 1 hora; `jwt_expiry` es 3600) y volver a abrir la ventana, o cerrar y reabrir la app pasado ese plazo: el cliente renueva la sesión y ese es el refresh que el hook revisa. Seguir adentro significa que el refresh pasó. Si lo manda a la pantalla del código, el hook rechazó el refresh (la sesión se abrió con otro método): apagar el hook (abajo) y avisar.
4. Con la sesión abierta, probar que otra pestaña con una contraseña no entra (la cocina no tiene contraseña; con una asignada por error daría 403).
Las sesiones de la cocina abiertas antes del despliegue con otro método (contraseña) se cortan en su próximo refresh: se vuelve a entrar con el código. Avisarle a Evelyn y a sus colaboradores antes del primer despliegue.

**Vuelta atrás (un comando).** Apagar el hook con la Management API; recién después tocar la función. Con `SUPABASE_ACCESS_TOKEN` (token personal, https://supabase.com/dashboard/account/tokens) y la referencia del proyecto (`SUPABASE_PROJECT_REF`):

```sh
curl -sS -X PATCH "https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF}/config/auth" \
  -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" -H "Content-Type: application/json" \
  -d '{"hook_custom_access_token_enabled": false}'
```

Eso corta el hook en el acto (los refresh vuelven a pasar). **El próximo despliegue lo vuelve a prender**: para que quede apagado hay que revertir el PR (o poner `enabled = false` en `config.toml` y `hook_custom_access_token_enabled: false` en `auth-config.ts` en un PR), y el despliegue de ese PR corta si ambos no coinciden. Nunca se cambia ni se borra la función con el hook prendido.

## 10. Captcha de Auth: la página `/captcha/` (PR09, 25/11/2026) y Auth que lo exige (PR11, 26/11/2026)

Supabase Auth puede exigir un token de Turnstile en cada pedido que lo necesita (`signInWithOtp` para pedir el código, y después el alta, la contraseña y la recuperación). PR09 agregó **el lado de la app**: cómo se obtiene el token y cómo viaja. **PR11 lo prende en Auth** (§10.1).

**Dónde vive.** Una página estática más del mismo sitio, `https://radicicucina.app/captcha/` (`web/captcha/`), en vez de un dominio aparte (otro proyecto de Cloudflare Pages). Dibuja un widget de Turnstile con la **sitekey de Auth** (`VITE_TURNSTILE_AUTH_SITE_KEY`; no la del formulario, que sigue siendo `VITE_TURNSTILE_SITE_KEY`) con `appearance: interaction-only`: sin casilla a la vista salvo que Cloudflare pida que la persona la toque. No es una página para visitar: abierta suelta muestra un aviso y no carga Turnstile.

**Cabeceras** (`web/public/_headers`, con tests): CSP propia con solo lo que Turnstile necesita (`script-src` y `frame-src` de `https://challenges.cloudflare.com`; nada de Supabase ni de fotos), `frame-ancestors 'self'` y `X-Frame-Options: SAMEORIGIN` (se quita el `DENY` de `/*`: es la única página que se deja enmarcar, y solo por el propio sitio), `X-Robots-Tag: noindex, nofollow` y `<meta name="robots" content="noindex, nofollow">`. `/gestione/` suma `frame-src 'self'` a su CSP para el marco.

**Protocolo** (`web/src/captcha/protocol.ts` y `app/lib/core/captcha/captcha_protocol.dart`). La página no manda nada sola: espera un pedido con un id al azar (128 bits en hexadecimal, lo genera la app) y contesta con ese id, así un token siempre es la respuesta a un pedido de quien lo hizo y nunca queda uno suelto. Mensajes, todos con `source: "radici-captcha"` y `v: 1`:

| Sentido | `type` | Campos |
|---|---|---|
| página → app | `ready` | (la página cargó y espera un pedido) |
| página → app | `interactive` | `id`, `visible` (Cloudflare pide, o ya no, tocar la casilla: la app agranda el marco o la ventana) |
| página → app | `token` | `id`, `token` (`[\w.-]{1,2048}`) |
| página → app | `error` | `id`, `code` (`[\w-]{1,32}`: un código de Turnstile, `timeout`, `unsupported`, `unavailable`, `misconfigured`, `cancelled`) |
| app → página | `request` | `id` |

Todo lo que no encaja (otra marca, otra versión, un id o un campo con otra forma) se ignora sin contestar.

**Canal `frame`** (Flutter web: `/gestione/` hoy, `/app/` más adelante). La app abre un `<iframe>` de `/captcha/` en el mismo origen y habla con `postMessage`. Los dos lados comparan el origen **exacto** (`event.origin`) y que el emisor sea la ventana esperada (la de ese iframe; en la página, la ventana padre); el destino de cada `postMessage` es ese origen, nunca `"*"`. El iframe mide 1 px, sin foco y oculto a los lectores de pantalla, y se muestra en grande solo con `interactive`; se crea en cada pedido y se saca del DOM al terminar.

**Canal `return`** (iOS y Android, desde el 26/11/2026). La app abre `https://radicicucina.app/captcha/?channel=return&id=<id>&lang=<idioma>` en el **navegador real del sistema** con `flutter_web_auth_2` 6.1.0: en iOS una hoja de Safari (`ASWebAuthenticationSession`, efímera: sin las cookies de Safari ni el aviso de «quiere iniciar sesión»), en Android una Auth Tab o Custom Tab de Chrome. La página pide el token sola, con el id de la URL (32 hexadecimales; sin id válido queda suelta), y vuelve a la app cambiando de dirección: `radicicaptcha://result?id=<id>&token=<token>` o `…&code=<código>`. El esquema es fijo en la página (nunca sale de la URL: no hay redirección abierta) y la app solo acepta la vuelta con el id de su pedido (`parseCaptchaReturn`). En iOS la vuelta la recibe solo la sesión que la abrió; en Android, la `CallbackActivity` de `flutter_web_auth_2` declarada en `AndroidManifest.xml` (otra app podría registrar el mismo esquema: se acepta, porque el token es de un solo uso, vale unos minutos y solo sirve para un pedido a Auth). **Por qué no la WebView:** el canal `native` (una `webview_flutter` dentro de la app, hasta el build 9) no pasa Turnstile: Cloudflare responde **600010** («challenge execution failure») aunque se toque la casilla, y en Safari el mismo widget anda. El canal `native` de la página queda para los builds viejos ya instalados.

**Servicio** (`CaptchaService`, `app/lib/core/captcha/`). `Future<String?> token({String? locale})`: una página nueva y un id nuevo por llamada (un token de Turnstile sirve **una sola vez**, ~300 s), de a un pedido por vez, nunca lanza y devuelve `null` si no hay token a los 20 s (120 s si Cloudflare pidió tocar la casilla), si la página no carga o si la plataforma no puede abrir un marco o una WebView. Reintentar es llamar de nuevo: no hay estado que reparar.

**Fail-open hasta PR11 (histórico; hoy rige §10.1).** Hasta PR11 Auth no exigía captcha y el login de Evelyn no puede depender de una página de un tercero (Edge con la prevención de seguimiento deja Turnstile en blanco sin avisar, SPEC §6). La constante `captchaRequired` de `app/lib/core/captcha/captcha_service.dart` es `false`: el login pide un token por cada envío (y reenvío) del código, se lo pasa a `signInWithOtp(captchaToken: …)` y, si no hay token, **manda el pedido igual, sin token**, sin registrar nada. **PR11 la pone en `true` en el mismo cambio que prende `security_captcha_enabled`** (con `[auth.captcha]` en `config.toml` y la secreta de Turnstile de Auth, que va en Supabase y nunca en el repo): desde ahí la falta de token es el error `AuthFailureKind.captcha` («Riprova»), y nada llega a Auth sin token. Antes de eso hay que publicar las dos apps con este PR y comprobar en producción que los tokens llegan (los pedidos a Auth con y sin `gotrue_meta_security.captcha_token`, en los logs de Auth, sin loguear el token).

**Qué tiene que crear la dueña de la cuenta de Cloudflare.** Un widget de Turnstile **nuevo**, distinto del del formulario: modo **Managed**, hostname `radicicucina.app` (los de `*.pages.dev` solo si quiere probar vistas previas), y copiar su sitekey a la variable de GitHub `VITE_TURNSTILE_AUTH_SITE_KEY` y su secreta, más adelante (PR11), a Supabase Auth. `deploy-web.yml` corta la publicación a producción si la variable falta, es una sitekey de prueba (`1x…`, `2x…`, `3x…`) o es igual a la del formulario.

### 10.1 Auth exige el captcha (PR11, 26/11/2026)

Desde PR11, producción exige el token de Turnstile en `/otp` (pedir el código, también el de Evelyn), `/signup`, `/recover`, `/resend`, `/magiclink` y `/token` con contraseña. **No** lo piden el refresh de la sesión ni el canje PKCE (`/token` con `refresh_token` o `pkce`: las sesiones abiertas siguen, también la de Evelyn), `/verify` (el código y el link de `/accesso/`) ni las llamadas con credenciales de admin (el despliegue). Comprobado contra GoTrue v2.197.0 con el captcha prendido.

**Lo que fija el repo** (`auth-config.ts`, §2): `security_captcha_enabled = true` y `security_captcha_provider = turnstile` en la parte security; la secreta (`security_captcha_secret`) la suma `authCaptchaConfig` desde el secreto de GitHub `TURNSTILE_AUTH_SECRET_KEY` (la Secret Key del widget «Radici login»), como la clave del SMTP: va directo al PATCH y nunca se imprime ni se compara. En local el captcha queda apagado (`config.toml` no tiene `[auth.captcha]`, y `auth-config.ts` corta si alguien lo prende ahí).

**La app**: `captchaRequiredProvider` es `true` con `APP_ENV=prod` (la web de `/gestione/` y `/app/`, iOS y Android publicados) y `false` en desarrollo (el Supabase local no lo exige y la página `/captcha/` no está en el origen de la app). En producción, sin token el pedido no sale: «Non siamo riusciti a completare la verifica anti-spam. Riprova» (`AuthFailureKind.captcha`), lo mismo si Auth rechaza el token (`captcha_failed`). `/accesso/` ya lo exigía («Reinvia l'email»).

**El despliegue, para que un error no deje a nadie afuera** (`supabase/scripts/auth-captcha-check.ts`, con tests y probado contra GoTrue y Cloudflare reales):
1. **Antes del PATCH** (paso «Captcha de Auth: la secreta es la del widget»): la secreta existe, no es una de prueba de Cloudflare (`1x…`, `2x…`, `3x…`), tiene la forma de una real (`0x…`) y Cloudflare la reconoce (siteverify con un token inventado responde `invalid-input-response`; una secreta que no existe da `invalid-input-secret`). Si no, corta sin tocar Auth.
2. **Después del PATCH** (paso «Captcha de Auth: Auth lo exige»), como cualquier visitante (con la clave publicable, variable `SUPABASE_PUBLISHABLE_KEY`): un pedido de código para `captcha-check@example.com` con `create_user: false` tiene que dar `captcha_failed` sin token, y `captcha_failed` por `invalid-input-response` con un token inventado (Supabase le preguntó a Cloudflare con la secreta buena). Ninguno de los dos manda un email. Supabase aplica la configuración reiniciando Auth y eso tarda: el control pregunta **cada 10 s, hasta 3 minutos**, mientras la respuesta sea «todavía no» (sin captcha, sin respuesta o un error pasajero); una secreta que Cloudflare no reconoce corta enseguida. (El primer despliegue de PR11, el 26/11/2026, preguntó una sola vez, enseguida, y apagó el captcha: de ahí la espera.) Si no da, **el script apaga el captcha** (PATCH `security_captcha_enabled = false`) y el despliegue falla antes de migrar: el login sigue como antes de PR11.

Lo que el despliegue no puede comprobar: que la secreta y la sitekey (`VITE_TURNSTILE_AUTH_SITE_KEY`) sean **del mismo widget**. Si no lo fueran, todos los tokens reales darían `captcha_failed`. Por eso, después de cada cambio de claves, la prueba manual: pedir el código en `/gestione/` (ventana privada) y en el iPhone.

**Vuelta atrás** (si el login falla por el captcha):
```sh
curl -sS -X PATCH "https://api.supabase.com/v1/projects/<REF>/config/auth" \
  -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  -d '{"security_captcha_enabled": false}'
```
Apaga el captcha en el acto (los builds publicados siguen mandando el token, que Auth ignora). El próximo despliegue lo vuelve a prender: para dejarlo apagado hay que revertir PR11. Las sesiones abiertas no se ven afectadas en ningún momento.

**Diagnóstico en la app** (26/11/2026). En el iPhone (build 7) el pedido del código llegó a Auth sin token (log: «no captcha_token found») aunque la casilla pasó, y en la web anda. Para ver el motivo en el teléfono, cuando el captcha falla la pantalla del login suma un código corto: «(codice: …)». Los códigos: `page-<código>` (un error de Turnstile o de la página, por ejemplo `page-600010`; `page-token-shape` si llegó un token con otra forma), `auth` (Auth rechazó el token); en la web, `app-no-ready`, `app-timeout`, `app-timeout-interactive` y `app-load-<n>`; en iOS y Android, `app-cancelled` (se cerró la hoja), `app-browser-<código>` (el sistema no pudo abrirla) y `app-bad-return` (volvió con otra dirección). Con este diagnóstico el build 9 mostró `page-600010` en el iPhone: de ahí el canal `return`. Nunca lleva el token ni datos de la persona.

**Límite de emails** (`smtp_max_frequency = 60`, parte smtp): un email de Auth por cuenta por minuto; antes, 429 `over_email_send_rate_limit` («Aspetta un minuto e riprova» en la app). Una cuenta que existe responde ese 429 a un segundo pedido rápido y una que no existe no: se acepta a sabiendas (el captcha y el límite por IP de §9 hacen caro aprovecharlo). `rate_limit_otp` ya estaba en 10 (§9).

## 11. La página `/accesso/`: confirmar el alta y elegir la contraseña (PR15, 26/11/2026; todavía no la enlaza ningún email)

Es la segunda mitad del alta en dos pasos y de «Password dimenticata?»: el email de Auth lleva a `https://radicicucina.app/accesso/`, la persona toca «Conferma» y elige la contraseña. Página de Vite (`web/accesso/`, lógica en `web/src/access/`) en it, es y en. **Hoy no llega nadie**: las plantillas que la enlazan son PR16, y las altas siguen cerradas hasta PR20.

**El link** (lo arma PR16; contrato para sus plantillas):

```
https://radicicucina.app/accesso/?lang=<it|es|en>#token_hash=<{{ .TokenHash }}>&type=<email|recovery>
```

- `type=email` para confirmar el alta, `type=recovery` para la contraseña. Cualquier otro `type` (`magiclink`, `email_change`, `invite`…) la página lo trata como link roto: el código de Evelyn sigue siendo `magic_link` y nunca pasa por acá.
- El `token_hash` va en el **fragmento**: no llega a ningún servidor ni va en el `Referer`. La página lo lee al abrir, lo saca de la URL enseguida (`history.replaceState`, conserva `?lang=`) y lo guarda solo en memoria hasta el toque.
- Acepta el token con `pkce_` delante (un alta pedida con PKCE desde la app): **verificado** canjeándolo desde otro navegador, que nunca tuvo el verificador.

**El flujo** (`web/src/access/flow.ts`, con tests):

1. **Sin el toque en «Conferma» no se manda nada**: un escáner de links que abra la página no gasta el link.
2. «Conferma»: `POST /auth/v1/verify` con **solo** `type` y `token_hash` (GoTrue rechaza con 400 cualquier otro campo junto al `token_hash`). Devuelve una sesión con `amr` `otp`. Vencido, ya usado o mal formado: 403 `otp_expired` (o 400) y la página ofrece «Reinvia». 429: «Troppi tentativi».
3. Muestra el email de la cuenta **enmascarado** (`ev•••@g•••.com`), para que quien abrió el link sepa de qué cuenta es, y pide la contraseña **dos veces** (desde el 27/11/2026, pedido de Nicolas: un error de tipeo no deja la cuenta con una contraseña que nadie conoce; «Mostra la password» muestra las dos): 10 o más caracteres, con letras y números, hasta 72 bytes (la regla la fija PR14 en Auth; la página la revisa antes de mandarla, y lo que diga Auth manda). Si la repetición no es igual, «Le due password non coincidono» y no sale nada; la regla se avisa primero.
4. `PUT /auth/v1/user` con solo `password`. La sesión de `/verify` cuenta como recuperación (`Session.IsRecovery` incluye `otp`), así que no pide la actual aunque PR14 prenda `require_current_password`. Errores: `weak_password` con sus razones (corta, sin letras o números, filtrada), `same_password`, 401/403 o una sesión que ya no sirve (pide otro link).
5. Cierra la sesión (`POST /auth/v1/logout?scope=local`) **antes** de mostrar «Fatto!». Para entrar, la persona usa su email y la contraseña nueva: en la web, «Vai al login» lleva a `/app/#/accedi?email=<email>` (el email en la ruta de Flutter, o sea en el fragmento: la app lo precarga desde PR17 y hasta entonces lo ignora); en el teléfono, la app de Radici.

**Lo que nunca hace:** guardar el link, la sesión o la contraseña (ni `localStorage`, ni `sessionStorage`, ni cookies: solo queda el idioma elegido, como en el resto del sitio), registrar algo en la consola, usar el refresh token (la sesión dura lo que tarda en elegirse la contraseña) o mandar algo a otro servidor que Supabase Auth. Usa `fetch` sin `supabase-js`, que guardaría la sesión. Un test recorre los módulos de la página y falla si nombran el almacenamiento o la consola.

**«Reinvia l'email»** (link vencido, usado o roto de tipo conocido, o sesión vencida antes de guardar): pide el email y un **token de captcha nuevo**, y manda `POST /auth/v1/resend` (`type: signup`) para el alta o `POST /auth/v1/recover` para la contraseña, con `gotrue_meta_security.captcha_token`. Las dos responden 200 vacío exista o no la cuenta (y `/resend` tampoco manda nada si la cuenta ya está confirmada), y la página muestra el mismo mensaje neutro, que sugiere «Password dimenticata?» a quien ya había activado la cuenta. Sin token de captcha no manda nada. El captcha es el de §10: un iframe de `/captcha/` del mismo origen (`web/src/captcha/host.ts`, el mismo protocolo, los mismos tiempos y las mismas verificaciones de origen y fuente que la app); Turnstile corre dentro de `/captcha/`, nunca en `/accesso/`.

**Cabeceras** (`web/public/_headers`, con tests): CSP propia con `connect-src` solo a Supabase, `frame-src 'self'` (el marco de `/captcha/`), `form-action 'none'` (sin código, un formulario nunca manda la contraseña ni el email), `frame-ancestors 'none'`; `Referrer-Policy: no-referrer` (también en un `<meta>`), `Cache-Control: no-store` y `noindex`. Es una página privada (`PRIVATE_PATHS`): sin canonical ni sitemap.

**Clave publicable en la web.** `/accesso/` es la primera página que llama a Auth: manda `apikey` con `VITE_SUPABASE_PUBLISHABLE_KEY`, la misma variable que ya usaba `deploy-web.yml` (y la app). El build solo la acepta si es `sb_publishable_…` o la `anon` vieja (un JWT con `role: anon`); una secreta o la `service_role` quedan fuera del JS (`normalizePublishableKey`, con tests).

**Probado de punta a punta** contra GoTrue v2.197.0 local, con `vite preview` (las cabeceras reales) y Edge headless: alta con PKCE, el fragmento fuera de la URL, ninguna llamada antes del toque, la contraseña borrada por el trigger de PR05 al confirmar, la contraseña nueva guardada y la sesión cerrada (ninguna abierta en `auth.sessions`), el login con la contraseña nueva, el link reusado (vencido), «Reinvia» con el captcha de prueba de Cloudflare hasta el link de recuperación, `same_password`, y sin violaciones de la CSP ni nada en la consola.

**Qué se acepta a sabiendas:**
- Quien tiene el link puede elegir la contraseña de esa cuenta: es lo mismo que tener el buzón. Por eso el link dura poco y se usa una vez (PR16), y la página muestra de qué cuenta es antes de pedir la contraseña.
- Si alguien cierra la página entre «Conferma» y guardar la contraseña, la sesión queda abierta en el servidor hasta que vence (nadie más la tiene: vivía solo en esa pestaña). La cuenta confirmada queda sin contraseña (PR05): el login y «Crea account» sugieren «Password dimenticata?» (PR17).
- El aviso «Troppi tentativi» de `/verify` sale del límite por IP de Auth (§9), compartido con el código de Evelyn.

## 12. Contraseñas (PR14, 26/11/2026)

Hoy nadie entra con contraseña (la cocina, solo con código; las altas, cerradas). Las fija el repo antes de que existan, para que la primera que se elija ya cumpla la regla.

**La regla.** 10 caracteres o más, con al menos una letra (a-z o A-Z) y un dígito: `password_min_length = 10` y `password_required_characters` = letras y dígitos (`letters_digits` en `config.toml`). GoTrue la aplica en el alta, en `PUT /user` y en las altas y cambios del panel de admin (`weak_password`, con las razones `length` y `characters`). No acepta más de 72 bytes (bcrypt). Entrar con una contraseña vieja que ya no cumple sigue andando (GoTrue solo avisa). La página `/accesso/` (`web/src/access/password.ts`) aplica la misma regla, y un test de `auth-config.test.ts` compara las dos.

**Cambiarla.**
- Con una sesión abierta con contraseña, hace falta la actual (`security_update_password_require_current_password`): sin ella, 400 `current_password_required`; con una equivocada, 400 `current_password_invalid` (GoTrue v2.197.0; el código fuente más nuevo lo llama `current_password_mismatch`: la app, PR17, acepta los dos).
- Con una sesión de `POST /verify` (amr `otp`: la de `/accesso/`, la recuperación y el código), no: GoTrue la cuenta como recuperación (`Session.IsRecovery`).
- Sin reautenticación por código (`security_update_password_require_reauthentication = false`, `secure_password_change = false`): con la actual alcanza.
- El cambio **cierra las demás sesiones** de la cuenta (la que la cambió sigue) y borra los links pendientes (confirmación, recuperación).

**El aviso.** Después de cada cambio, Auth manda «La password del tuo account è cambiata» (`supabase/templates/password_changed.html`, con el asunto de `config.toml`), en el idioma de `user_metadata.locale`, sin link ni datos de la cuenta, con qué hacer si no fue ella («Password dimenticata?» en la app y avisar a Evelyn). Va en la parte de plantillas (necesita el SMTP propio).

**HIBP** (rechazar contraseñas filtradas, Have I Been Pwned) necesita el plan Pro: `password_hibp_enabled` no va en el cuerpo hasta pasar a Pro (se prende en ese PR, antes del lanzamiento; la puerta de PR69 lo exige). Si un día HIBP no responde, GoTrue deja pasar la contraseña: se acepta a sabiendas.

**Las cuentas que crea el despliegue** (`deploy-accounts.sh`: 64 hexadecimales al azar, que nadie usa) cumplen la regla salvo con probabilidad menor a 10⁻¹³.

**Probado** contra GoTrue v2.197.0 con esta configuración (un contenedor aparte sobre la base local, porque la CLI 2.121 no sabe poner `require_current_password`): contraseñas cortas, sin números y sin letras rechazadas (también en el alta), `current_password_required` y `current_password_invalid`, el cambio con la actual, la otra sesión cerrada y la que la cambió viva, el cambio sin la actual con una sesión de `/verify` de recuperación, y el aviso en it, es y en (asunto, texto y `lang`), sin link ni el email.

## 13. Los emails de Auth (PR16, 26/11/2026)

**Una sola fuente**, `supabase/functions/_shared/auth_emails.ts`, con los textos de los seis tipos en it, es y en. De ahí salen:
- las plantillas de GoTrue (`goTrueTemplate`, `goTrueSubject`): un HTML por tipo con una rama por idioma, elegida por `user_metadata.locale` (italiano si no hay). `node supabase/scripts/auth-templates.ts` las escribe en `supabase/templates/`; `config.toml` las usa en local y `auth-config.ts` las manda a producción. Un test comprueba que los archivos son exactamente los generados, y `auth-config.ts` corta el despliegue si `config.toml` cambia un asunto o un archivo;
- el email de un idioma con los valores reales (`renderAuthEmail`), para el hook de envío de PR19.

| Tipo | Cuándo sale | Qué lleva |
|---|---|---|
| `magic_link` (`login_code.html`) | Pedir el código (la cocina) | El **código de 10 cifras**, que vale una hora, y «no lo compartas con nadie, ni con Evelyn». Sin link |
| `confirmation` | Crear la cuenta (PR17) | Botón y link a `https://radicicucina.app/accesso/?lang=<idioma>#token_hash={{ .TokenHash }}&type=email` (§11) |
| `recovery` | «Password dimenticata?» | Lo mismo con `type=recovery` |
| `email_change` | Pedir otro email | Sin link ni código: «por ahora el email no se puede cambiar» (sirve para la dirección vieja y la nueva). Así nadie completa un cambio de email hasta que el hook de PR19 lo bloquee antes de mandar nada (§4) |
| `reauthentication` | Reautenticarse | Sin código: Radici no usa la reautenticación (§12) |
| `invite` | Invitar una cuenta | Sin link: Radici no invita |

**El código y los links valen una hora** (`mailer_otp_exp = 3600`): un link de alta o de recuperación se abre a veces más tarde o en otro dispositivo. El código de la cocina pasa a **10 cifras** (`mailer_otp_length = 10`) para compensar ese tiempo, con las 10 verificaciones cada 5 minutos por IP de §9; la app ya acepta de 6 a 10 cifras. El link nunca es el de GoTrue (`{{ .ConfirmationURL }}` lo canjea un GET apenas se abre, y lo gastan los escáneres de links): es el de `/accesso/`, que espera el toque en «Conferma».

**Identidad**: el mismo logotipo, la misma paleta y la misma letra que los emails del pedido (`emails.ts` exporta `logoHtml`, `COLOR`, `FONT` y `FONT_DISPLAY`; un test lo compara). Sin imágenes, sin seguimiento.

**Probado** contra GoTrue v2.197.0 con estas plantillas (un contenedor aparte sobre la base local, con Mailpit): el alta con PKCE hasta `/accesso/` y la contraseña, la recuperación, el código de 10 cifras de la cocina, el pedido de cambio de email sin link y los tres idiomas.

## 14. La app: contraseña, alta y recuperación (PR17, 26/11/2026)

**Dónde.** En `/app/` (las clientas, web) y en la app nativa. `/gestione/` sigue solo con el código (la cocina, §8.1). En la app nativa, que sirve a las dos cuentas, el login abre con la contraseña y debajo tiene «Accesso cucina: entra con un codice via email», que lleva al login con código (y vuelve). Una cuenta de la cocina que prueba con contraseña recibe el 403 `kitchen_code_only` del hook (Auth lo dice recién con la contraseña correcta) y la app avisa «questo account è della cucina ed entra solo con il codice».

| Acción | Pedido a Auth | Captcha | Qué ve la persona |
|---|---|---|---|
| Entrar | `POST /token?grant_type=password` | Sí, un token nuevo por intento | La sesión, o «Email o password non corretti. Se non ricordi la password, usa «Password dimenticata?»». `email_not_confirmed` da el mismo aviso: nadie conoce la contraseña del alta |
| «Crea account» | `POST /signup` con una contraseña al azar (40 letras y dígitos, `Random.secure`) y `data` solo con `locale` | Sí | Siempre «Se <email> non ha ancora un account, ti arriva un link… Se hai già un account, entra o usa «Password dimenticata?»». Con las altas cerradas (`signup_disabled`, hoy), «Le iscrizioni apriranno presto» |
| «Password dimenticata?» | `POST /recover` | Sí | Siempre «Se <email> ha un account, ti arriva un link per scegliere la password» |
| «Reinvia l'email» | `POST /resend` (`type=signup`) o `/recover` otra vez | Sí | «Richiesta inviata di nuovo», exista o no la cuenta |
| «Cambia password» (área de la clienta; la nueva, escrita dos veces: si no coinciden no sale nada) | `PUT /user` con `password` y `current_password` | No (Auth no lo pide) | «Password aggiornata. Le altre sessioni aperte sono state chiuse.» (Auth cierra las otras sesiones y manda el aviso de §12). La actual incorrecta: `current_password_invalid` en GoTrue v2.197 o `current_password_mismatch` en las más nuevas, los dos con el mismo aviso |

**El alta en dos pasos** (diseño del 22/11/2026). La contraseña del alta no la conoce nadie: la clienta elige la suya en `/accesso/` desde el link de confirmación (§11, plantilla `confirmation` de §13), y la primera confirmación borra la del alta (§4). Sin `emailRedirectTo`: las plantillas no usan la URL de GoTrue. Con PKCE (el flujo de supabase_flutter), el `token_hash` del email empieza con `pkce_`, y `/accesso/` lo canjea desde cualquier navegador (probado en PR15).

**Antes de mandar.** La app revisa el email (la regla de `isValidEmail`), que haya contraseña al entrar y, al cambiarla, la misma regla de §12 (`app/lib/features/auth/domain/password_rules.dart`; `auth-config.test.ts` compara las tres copias) y que la nueva no sea igual a la actual. Quien decide es Auth: `weak_password` y `same_password` se muestran igual.

**El link a la informativa** (`https://radicicucina.app/privacy/?lang=<idioma>`) está debajo de los botones del alta: se ve antes de mandar el email.

**`/accedi?email=`.** El «Vai al login» de `/accesso/` lleva a `/app/#/accedi?email=…`: el campo del email arranca con ese valor si es un email válido (si no, vacío).

**Qué se acepta a sabiendas.** Los avisos de la app no dicen si un email tiene cuenta, pero Auth limita a un email por minuto a cada destinatario (`smtp_max_frequency`, §9): un segundo pedido al mismo email dentro del minuto da 429 solo si el primero salió, o sea, si la cuenta existe. Es un oráculo de la API de GoTrue, no de la app (la app dice la verdad: «Troppi tentativi in poco tempo. Aspetta un minuto e riprova.»), y el captcha lo encarece. Los topes por destinatario del hook de envío (PR19) no lo cierran: ese chequeo de GoTrue ocurre antes del hook.

## 15. Cuentas de prueba de clienta (PR18, 27/11/2026)

**Para qué.** Con las altas cerradas (hasta PR20), probar en producción el área de clientas (`/app/` y la app nativa: login con contraseña, «Cambia password», y lo que vaya llegando) con cuentas de clienta que no salen de un alta ni de un pedido. También sirven para la revisión de Apple y Google, que piden un login de prueba.

**Cómo.** El secreto de GitHub `TEST_CLIENT_EMAILS` (emails separados por coma, hasta 10; nunca en el repo ni como variable, que sale en claro en el log). En cada despliegue, el paso «Cuentas de prueba» de `deploy-supabase.yml` (`deploy-accounts.sh testers`, antes de los colaboradores) lo aplica. La lista manda:

| Caso | Qué pasa |
|---|---|
| Un email nuevo sin cuenta | El despliegue la crea por la API de administración de Auth, **confirmada y sin contraseña** (`email_confirm` sin `password`, `user_metadata.locale` = `CHEF_LOCALE`). Nadie conoce una contraseña: la persona elige la suya en la app con «Password dimenticata?» (el link lleva a `/accesso/`, §11) |
| Un email con cuenta confirmada | No se toca: ni la contraseña, ni las sesiones, ni `user_metadata` |
| Cualquier email de la lista | `private.sync_test_clients` le pone `app_metadata.radici_test = true` |
| Una cuenta marcada que salió de la lista | Sin ficha de cliente, se borra (en cascada el perfil, las identidades y las sesiones). Con ficha, queda como clienta, sin la marca. Si no se puede borrar, queda sin la marca y sin sesiones (el aviso de usuarios de más la cuenta) |
| Lista vacía o sin cargar | No queda ninguna cuenta de prueba |
| Un email de la cocina (`CHEF_LOGIN_EMAIL`, `CHEF_MEMBER_EMAILS` o una cuenta de `chefs`/`chef_members`/rol distinto de `client`) | Corta antes de cambiar nada: una cuenta de la cocina ve las alergias y direcciones de todas las clientas, nunca es de prueba |
| Una cuenta con ese email sin confirmar | Corta: no la creó el despliegue (como con los colaboradores) |

**La marca.** `app_metadata` (`raw_app_meta_data`) solo la escribe el servidor: la persona no se la puede poner ni sacar, y llega en el JWT (`app_metadata.radici_test`). Hoy nada la lee salvo el informe del despliegue; sirve para que la app y la web reconozcan una cuenta de prueba (por ejemplo, el botón hacia `/app/` antes de abrir las altas). No da ningún permiso: una cuenta de prueba es una clienta más (rol `client`, sin ficha hasta que la tenga), y las políticas no la miran.

**Qué se ve en el log.** Cada email se enmascara (`::add-mask::`) antes de usarlo y los mensajes dicen «p***@e***.com». El informe del final cuenta las cuentas de prueba aparte («de prueba: N») y no las avisa como usuarios de más.

**Código.** Migración `20261127120000_test_clients.sql` (`private.sync_test_clients`, solo la ejecuta postgres; pgTAP `29_test_clients`), `supabase/scripts/test-clients.ts` (la lista; la misma regla del email que la base) y `deploy-accounts.sh testers` (tests con la API simulada en `deploy-accounts.test.ts`).

**Cómo se usa** (Nicolas): cargar el secreto en GitHub → Settings → Secrets and variables → Actions → `TEST_CLIENT_EMAILS`; correr Deploy Supabase (Actions → Run workflow); en la app, «Password dimenticata?» con ese email, elegir la contraseña desde el link, y entrar.
