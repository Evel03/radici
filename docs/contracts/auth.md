# Contrato: Auth (Supabase) de Radici

Qué hace Auth en el proyecto, qué ajustes fija el repo en producción, cómo se comprueban y qué se acepta a sabiendas. Se aplica en cada despliegue (`deploy-supabase.yml`, paso «Auth desde el repo»), antes de `db push`. SPEC §6. Lo que se cambie de esto en el panel de Supabase lo pisa el próximo despliegue: un cambio es un PR.

## 1. Qué hace Auth hoy (M0, altas apagadas)

- Login con **código por email** (OTP de 8 cifras, vale 600 segundos). La app llama a `signInWithOtp(email, shouldCreateUser: false)` y después `verifyOTP(type: email)`; no manda `emailRedirectTo` y el email no lleva link, solo el código. Por eso `site_url` y `uri_allow_list` no intervienen en el login de `/gestione/` (web, iOS y Android): no hay ninguna redirección que permitir.
- Las altas están apagadas (`disable_signup`): las cuentas de Evelyn y de sus colaboradores las crea confirmadas el despliegue (contrato public-request §10.1). Se abren en M2, en su propio PR, con Turnstile.
- El email del código sale por el SMTP de Resend (`RESEND_SMTP_KEY`) con la plantilla `supabase/templates/login_code.html`, que se usa para «Magic link» (usuario existente) y «Confirm signup». Sale en el idioma de `user_metadata.locale` (it, es, en).

## 2. Lo que fija el repo

`supabase/scripts/auth-config.ts` arma tres PATCH a `PATCH /v1/projects/{ref}/config/auth` (Management API). Los nombres de campo son los del OpenAPI público (`https://api.supabase.com/api/v1-json`, leído el 23/11/2026, esquema `UpdateAuthConfigBody`); un test los compara con esa lista.

| Parte | Campo (Management API) | Valor | Equivale en `config.toml` |
|---|---|---|---|
| security | `disable_signup` | `true` | `[auth] enable_signup = false` |
| security | `external_email_enabled` | `true` | `[auth.email] enable_signup = true` |
| security | `mailer_otp_length`, `mailer_otp_exp` | 8, 600 | `otp_length`, `otp_expiry` |
| security | `security_captcha_enabled` | `false` | sin `[auth.captcha]` |
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
| smtp | `smtp_host`, `smtp_port`, `smtp_user`, `smtp_pass`, `smtp_admin_email`, `smtp_sender_name` | Resend, remitente de `MAIL_FROM` | |
| templates | `mailer_subjects_magic_link`, `mailer_subjects_confirmation`, `mailer_templates_*_content`, `rate_limit_email_sent` | asunto de `config.toml`, `login_code.html`, 100 | |

`site_url` y `uri_allow_list` son la única URL del área de clientes (`/app/`). No incluyen `/gestione/`, porque el login de Evelyn no redirige. Si algún día `/gestione/` usara `emailRedirectTo` (links en lugar de código), hay que sumarlo a `uri_allow_list` en `auth-config.ts` (una lista exacta, sin comodines).

Cada ajuste de la tabla que tiene su par en `config.toml` se comprueba también ahí: `authSecurityConfig` falla si `config.toml` prende un autoconfirm (`enable_confirmations = false`), el linking manual, los anónimos, el teléfono, Web3 o cualquier `[auth.external.*]`, apaga el cambio de email seguro o cambia `token_verifications` (tiene que ser 10). Así lo local y lo de producción no se separan y el despliegue corta (con código 2) antes de la primera llamada a la API.

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
- **`rate_limit_verify = 10` no es «11 intentos y 429».** GoTrue (v2.197.0, la del CLI 2.121.0) usa un cubo con ráfaga fija de 30 y recarga de 10 cada 5 minutos por IP: el intento 31 seguido recibe 429, y después unos 2 por minuto. Medido el 23/11/2026 con un GoTrue local con la cabecera de IP configurada: 11 `/verify` seguidos dan 403 (código inválido) y el 31.º, 429. Contra un código de 8 cifras que vale 10 minutos sigue siendo inviable, pero no hay que prometer un tope de 10. Además, con `supabase start` el límite por IP **no se aplica** (el CLI no configura la cabecera de IP): solo se puede probar con `GOTRUE_RATE_LIMIT_HEADER`. En producción lo aplica la infraestructura de Supabase.
- **Linking automático de identidades por email.** Con el linking manual apagado, GoTrue sigue uniendo por email verificado cuando haya proveedores (Google y Apple, en sus PRs). Se acepta para las clientas.
- **Frase en el email de Evelyn.** El código lleva «non condividere questo codice con nessuno, nemmeno con Evelyn» (y su equivalente en es y en): es el mismo email para todas las cuentas, también para la de ella.

## 7. Plantillas

`login_code.html` imprime solo `{{ .Token }}`. Usa `.Data` únicamente para comparar `.Data.locale` con `es` o `en` (un test lo exige, también para los asuntos de `config.toml`): nunca imprime metadatos del usuario, ni `.Email`, `.ConfirmationURL`, `.TokenHash`, `.SiteURL` ni `.RedirectTo`.

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
| Confirmación del alta (código de 8 cifras, `/verify type=signup`) | `[{"method":"otp"}]` | n/a (es una clienta) |
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
| `GET/POST /verify` | `Verify` | `rate_limit_verify` | **10** cada 5 min (PR04) | Probar códigos de 8 cifras: el 31.º seguido da 429 (§6) | Muchas IP contra un mismo código (vale 600 s) |
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

## 10. Captcha de Auth: la página `/captcha/` (PR09, 25/11/2026; Auth todavía lo tiene apagado)

Supabase Auth puede exigir un token de Turnstile en cada pedido que lo necesita (`signInWithOtp` para pedir el código, y después el alta, la contraseña y la recuperación). Este PR agrega **el lado de la app**: cómo se obtiene el token y cómo viaja. **No prende el captcha en Auth** (`security_captcha_enabled` sigue en `false`, §2): eso es PR11, cuando las dos apps ya lo manden y estén publicadas.

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

**Canal `native`** (iOS y Android). `webview_flutter` **4.14.1** (fijada, sin `^`) abre `https://radicicucina.app/captcha/?channel=native` (siempre el sitio de producción, no configurable) con JavaScript, sin permisos de plataforma (todos denegados) y un `NavigationDelegate` que solo deja pasar, en el marco principal, esa página (misma ruta exacta, https, puerto 443, sin usuario) y, en los marcos internos, `https://challenges.cloudflare.com` y `about:blank`/`about:srcdoc`; todo lo demás se bloquea. La página manda por el canal JavaScript `RadiciCaptcha` (un string JSON) y recibe el pedido con `window.radiciCaptchaRequest(id)` (la app valida el id antes de armar el código). Solo se activa con el canal instalado: `?channel=native` sin canal se trata como página suelta. Un `CaptchaHost` encima de la app dibuja la WebView (1×1 px, o en grande con la casilla). No hizo falta tocar `Info.plist` ni `AndroidManifest.xml`: el permiso `INTERNET` ya estaba y el sitio es https.

**Servicio** (`CaptchaService`, `app/lib/core/captcha/`). `Future<String?> token({String? locale})`: una página nueva y un id nuevo por llamada (un token de Turnstile sirve **una sola vez**, ~300 s), de a un pedido por vez, nunca lanza y devuelve `null` si no hay token a los 20 s (120 s si Cloudflare pidió tocar la casilla), si la página no carga o si la plataforma no puede abrir un marco o una WebView. Reintentar es llamar de nuevo: no hay estado que reparar.

**Fail-open hasta PR11.** Hoy Auth no exige captcha y el login de Evelyn no puede depender de una página de un tercero (Edge con la prevención de seguimiento deja Turnstile en blanco sin avisar, SPEC §6). La constante `captchaRequired` de `app/lib/core/captcha/captcha_service.dart` es `false`: el login pide un token por cada envío (y reenvío) del código, se lo pasa a `signInWithOtp(captchaToken: …)` y, si no hay token, **manda el pedido igual, sin token**, sin registrar nada. **PR11 la pone en `true` en el mismo cambio que prende `security_captcha_enabled`** (con `[auth.captcha]` en `config.toml` y la secreta de Turnstile de Auth, que va en Supabase y nunca en el repo): desde ahí la falta de token es el error `AuthFailureKind.captcha` («Riprova»), y nada llega a Auth sin token. Antes de eso hay que publicar las dos apps con este PR y comprobar en producción que los tokens llegan (los pedidos a Auth con y sin `gotrue_meta_security.captcha_token`, en los logs de Auth, sin loguear el token).

**Qué tiene que crear la dueña de la cuenta de Cloudflare.** Un widget de Turnstile **nuevo**, distinto del del formulario: modo **Managed**, hostname `radicicucina.app` (los de `*.pages.dev` solo si quiere probar vistas previas), y copiar su sitekey a la variable de GitHub `VITE_TURNSTILE_AUTH_SITE_KEY` y su secreta, más adelante (PR11), a Supabase Auth. `deploy-web.yml` corta la publicación a producción si la variable falta, es una sitekey de prueba (`1x…`, `2x…`, `3x…`) o es igual a la del formulario.
