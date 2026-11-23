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
| security | `external_google_enabled`, `external_apple_enabled`, `external_phone_enabled`, `external_anonymous_users_enabled`, `external_web3_solana_enabled`, `external_web3_ethereum_enabled`, `saml_enabled` | `false` | sin proveedores en `config.toml` |
| smtp | `smtp_host`, `smtp_port`, `smtp_user`, `smtp_pass`, `smtp_admin_email`, `smtp_sender_name` | Resend, remitente de `MAIL_FROM` | |
| templates | `mailer_subjects_magic_link`, `mailer_subjects_confirmation`, `mailer_templates_*_content`, `rate_limit_email_sent` | asunto de `config.toml`, `login_code.html`, 100 | |

`site_url` y `uri_allow_list` son la única URL del área de clientes (`/app/`). No incluyen `/gestione/`, porque el login de Evelyn no redirige. Si algún día `/gestione/` usara `emailRedirectTo` (links en lugar de código), hay que sumarlo a `uri_allow_list` en `auth-config.ts` (una lista exacta, sin comodines).

Cada ajuste de la tabla que tiene su par en `config.toml` se comprueba también ahí: `authSecurityConfig` falla si `config.toml` prende un autoconfirm (`enable_confirmations = false`), el linking manual, los anónimos, el teléfono, Web3 o cualquier `[auth.external.*]`, apaga el cambio de email seguro o sube `token_verifications` de 10. Así lo local y lo de producción no se separan y el despliegue corta (con código 2) antes de la primera llamada a la API.

## 3. Cómo se comprueba, y por qué corta antes de migrar

1. El paso lee la configuración vigente (`GET /v1/projects/{ref}/config/auth`) antes del primer PATCH.
2. Después de cada PATCH compara la respuesta con el cuerpo que mandó (`auth-config.ts verify <parte>`, campo por campo). Un campo que no quedó igual, o un nombre de campo equivocado (la API ignora en silencio lo que no conoce y no lo devuelve), da un error con los **nombres** de los campos, nunca sus valores, y el paso falla. `db push` no corre.
3. La clave del SMTP (`smtp_pass`) no se compara (la API no la devuelve en claro). La respuesta entera, que la trae, queda en un archivo temporal que solo leen `jq` y `auth-config.ts`: no se imprime.
4. Una sola vez (mientras haya algo que cambiar) el resumen del paso anota la versión de GoTrue (`GET /v1/projects/{ref}/health?services=auth`, campo `info.version`) y los nombres de los campos de producción que cambian. Sin valores. Si hay que leer la versión y no se puede, avisa y sigue: no es un ajuste.

Lo que este PR cambia en producción respecto de lo que `auth-config.ts` fijaba antes (altas, código de 8 cifras y 600 s, CAPTCHA apagado, SMTP, plantillas, 100 emails por hora): `site_url` y `uri_allow_list`, `mailer_autoconfirm`, `sms_autoconfirm`, `mailer_allow_unverified_email_sign_ins`, `mailer_secure_email_change_enabled`, `security_manual_linking_enabled`, `external_email_magic_link_disabled`, `rate_limit_verify`, y los proveedores apagados. Solo cambian los que hoy tengan otro valor en el panel; la lista exacta la dice el resumen del primer despliegue.

## 4. El perfil de una cuenta nueva

`handle_new_user` (trigger `on_auth_user_created`, migración `20261123120000_auth_profile_name.sql`) crea el perfil siempre como `client` y **sin nombre**: ya no copia `full_name` de `raw_user_meta_data`, que lo escribe quien se registra y nadie verificó. El idioma sí se copia, si es `it`, `es` o `en`. El nombre lo escribe la persona en su perfil (la RLS le deja cambiar `full_name`, `phone` y `locale` de su propia fila) o lo pone la cocina. pgTAP `24_auth_accounts` lo prueba (con `full_name` y `role` en los metadatos) y comprueba la regla en el código de la función.

## 5. Resend: sin seguimiento de aperturas ni de clics

Con el seguimiento prendido, Resend reescribe los links de los emails por su dominio y los ve: en los emails de Auth serían links de acceso. El despliegue lo comprueba antes de tocar Auth (`supabase/scripts/resend-tracking.ts`, paso «Seguimiento de Resend apagado»): lee `GET /domains` y `GET /domains/{id}` (campos `open_tracking` y `click_tracking`) y corta si algún dominio tiene uno prendido, o si Resend no informa el campo. **Lo apaga la dueña de la cuenta de Resend** (Domains → cada dominio); el despliegue nunca lo cambia.

Resend no deja leer los dominios con una clave «solo de envío» (`restricted_api_key`). Con una así el paso corta, para no dar por bueno lo que no pudo comprobar, salvo que alguien ponga a propósito la variable `RESEND_TRACKING_RESTRICTED_OK=true` después de mirar el panel (entonces solo avisa). Lo que corresponde es cargar como `RESEND_API_KEY` una clave con acceso completo, solo para leer.

## 6. Qué se acepta a sabiendas

- **Se puede averiguar si un email tiene cuenta.** Por la API de Auth (`/otp` con `create_user: false`, que hoy responde `otp_disabled` si el email no existe; `/signup`; `/recover`; el login con contraseña) alguien puede distinguir un email con cuenta de uno sin cuenta: los mensajes de error y los tiempos difieren, y con las altas abiertas (M2) `/signup` lo dice sin rodeos. No se promete lo contrario. Mitigaciones: CAPTCHA en cada pedido de código (M2), límites por IP y por email de Auth (`rate_limit_otp`, `max_frequency`, `rate_limit_email_sent`), y que lo único que revela es que una persona tiene cuenta, nunca datos de ella.
- **`rate_limit_verify = 10` no es «11 intentos y 429».** GoTrue (v2.197.0, la del CLI 2.121.0) usa un cubo con ráfaga fija de 30 y recarga de 10 cada 5 minutos por IP: el intento 31 seguido recibe 429, y después unos 2 por minuto. Medido el 23/11/2026 con un GoTrue local con la cabecera de IP configurada: 11 `/verify` seguidos dan 403 (código inválido) y el 31.º, 429. Contra un código de 8 cifras que vale 10 minutos sigue siendo inviable, pero no hay que prometer un tope de 10. Además, con `supabase start` el límite por IP **no se aplica** (el CLI no configura la cabecera de IP): solo se puede probar con `GOTRUE_RATE_LIMIT_HEADER`. En producción lo aplica la infraestructura de Supabase.
- **Linking automático de identidades por email.** Con el linking manual apagado, GoTrue sigue uniendo por email verificado cuando haya proveedores (Google y Apple, en sus PRs). Se acepta para las clientas.
- **Frase en el email de Evelyn.** El código lleva «non condividere questo codice con nessuno, nemmeno con Evelyn» (y su equivalente en es y en): es el mismo email para todas las cuentas, también para la de ella.

## 7. Plantillas

`login_code.html` imprime solo `{{ .Token }}`. Usa `.Data` únicamente para comparar `.Data.locale` con `es` o `en` (un test lo exige, también para los asuntos de `config.toml`): nunca imprime metadatos del usuario, ni `.Email`, `.ConfirmationURL`, `.TokenHash`, `.SiteURL` ni `.RedirectTo`.
