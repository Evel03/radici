// Tests de la configuración de Auth que deploy-supabase.yml aplica en producción. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { PASSWORD_MIN_LENGTH as WEB_PASSWORD_MIN_LENGTH, passwordProblem } from "../../web/src/access/password.ts";
import { AUTH_EMAIL_KINDS, TEMPLATE_FILES, goTrueSubject, goTrueTemplate } from "../functions/_shared/auth_emails.ts";
import {
  LETTERS_DIGITS,
  PASSWORD_MIN_LENGTH,
  authCaptchaConfig,
  authSecurityConfig,
  authSmtpConfig,
  authTemplatesConfig,
  changedFields,
  parseMailFrom,
  tomlSection,
  verifyAuthConfig,
} from "./auth-config.ts";

const read = (path: string): string => readFileSync(new URL(`../../${path.replace(/^\.\//, "")}`, import.meta.url), "utf8");
const CONFIG = read("supabase/config.toml");
const TEMPLATE = read("supabase/templates/login_code.html");
const PASSWORD_NOTICE = read("supabase/templates/password_changed.html");
const SCRIPT = fileURLToPath(new URL("./auth-config.ts", import.meta.url));

test("TOML: secciones, cadenas con comillas escapadas, enteros, booleanos y comentarios", () => {
  const toml = [
    "# comentario",
    "[auth]",
    "enable_signup = false # al final",
    "[auth.email]",
    'subject = "{{ if eq .Data.locale \\"es\\" }}Hola{{ end }}" # con #',
    "otp_length = 8",
    'path = "./a/b.html"',
    "[otra]",
    "otp_length = 99",
  ].join("\n");
  assert.deepEqual([...tomlSection(toml, "auth")], [["enable_signup", false]]);
  const email = tomlSection(toml, "auth.email");
  assert.equal(email.get("subject"), '{{ if eq .Data.locale "es" }}Hola{{ end }}');
  assert.equal(email.get("otp_length"), 8);
  assert.equal(email.get("path"), "./a/b.html");
  assert.equal(tomlSection(toml, "no.existe").size, 0);
});

test("security: altas apagadas, código de 10 cifras por 1 hora y el captcha de Auth (Turnstile); nada de correo", () => {
  const body = authSecurityConfig(CONFIG);
  assert.deepEqual(body, {
    ...PINNED, // lo del PR04 (más abajo)
    disable_signup: true,
    external_email_enabled: true,
    mailer_otp_length: 10,
    mailer_otp_exp: 3600,
    security_captcha_enabled: true,
    security_captcha_provider: "turnstile",
  });
  // La secreta nunca sale de config.toml ni del cuerpo fijo: la suma authCaptchaConfig desde el entorno.
  assert.equal("security_captcha_secret" in body, false);
});

test("captcha: la secreta viene de TURNSTILE_AUTH_SECRET_KEY, sin espacios; sin ella, falla; nunca se compara (no vuelve en claro)", () => {
  assert.deepEqual(authCaptchaConfig(" 0x4AAAAAAAsecreta "), { security_captcha_secret: "0x4AAAAAAAsecreta" });
  assert.throws(() => authCaptchaConfig(""), /TURNSTILE_AUTH_SECRET_KEY/);
  assert.throws(() => authCaptchaConfig("   "), /TURNSTILE_AUTH_SECRET_KEY/);
  assert.deepEqual(verifyAuthConfig({ security_captcha_secret: "0x4AAAAAAAsecreta" }, { security_captcha_secret: "otra-o-enmascarada" }), []);
  assert.deepEqual(verifyAuthConfig({ security_captcha_enabled: true }, { security_captcha_enabled: false }), ["security_captcha_enabled"]);
});

test("templates: las seis plantillas son las del repo (auth_emails.ts), con el asunto en el idioma del usuario", () => {
  const body = authTemplatesConfig(CONFIG, read);
  for (const kind of AUTH_EMAIL_KINDS) {
    assert.equal(body[`mailer_templates_${kind}_content`], read(`supabase/templates/${TEMPLATE_FILES[kind]}`), kind);
    assert.equal(body[`mailer_templates_${kind}_content`], goTrueTemplate(kind), `${kind}: el archivo es el generado`);
    const subject = String(body[`mailer_subjects_${kind}`]);
    assert.equal(subject, goTrueSubject(kind));
    assert.ok(!subject.includes('\\"'), "comillas sin escapar");
  }
  // La del código de la cocina: el código, sin link. La del alta y la de recuperación: el link, sin código.
  assert.equal(body.mailer_templates_magic_link_content, TEMPLATE);
  assert.ok(String(body.mailer_templates_magic_link_content).includes("{{ .Token }}"));
  for (const text of ["Tu código de acceso", "Your sign-in code", "Il tuo codice di accesso"]) {
    assert.ok(String(body.mailer_subjects_magic_link).includes(text), `magic_link: falta ${text}`);
  }
  for (const kind of ["confirmation", "recovery"]) {
    const html = String(body[`mailer_templates_${kind}_content`]);
    assert.ok(html.includes("{{ .TokenHash }}") && !html.includes("{{ .Token }}"), kind);
  }
  assert.equal(body.rate_limit_email_sent, 100);
  assert.ok(Object.keys(body).every((key) => !key.startsWith("smtp_")));
  // El aviso de contraseña cambiada (PR14): prendido, con su plantilla y el asunto en los tres idiomas.
  assert.equal(body.mailer_notifications_password_changed_enabled, true);
  assert.equal(body.mailer_templates_password_changed_notification_content, PASSWORD_NOTICE);
  const subject = String(body.mailer_subjects_password_changed_notification);
  for (const text of ["Cambió la contraseña de tu cuenta", "Your password was changed", "La password del tuo account è cambiata"]) {
    assert.ok(subject.includes(text), `aviso: falta ${text}`);
  }
});

test("templates: sin el aviso de contraseña prendido en config.toml, corta", () => {
  const off = CONFIG.replace(/(\[auth\.email\.notification\.password_changed\][^[]*?)enabled = true/s, "$1enabled = false");
  assert.notEqual(off, CONFIG);
  assert.throws(() => authTemplatesConfig(off, read), /password_changed/);
});

test("smtp: Resend con el remitente de MAIL_FROM; sin clave, falla", () => {
  assert.deepEqual(authSmtpConfig({ key: " re_clave ", mailFrom: "Radici <ciao@radicicucina.app>" }), {
    smtp_host: "smtp.resend.com",
    smtp_port: "465",
    smtp_user: "resend",
    smtp_pass: "re_clave",
    smtp_admin_email: "ciao@radicicucina.app",
    smtp_sender_name: "Radici",
    smtp_max_frequency: 60,
  });
  assert.throws(() => authSmtpConfig({ key: "", mailFrom: "Radici <ciao@x.example>" }), /RESEND_SMTP_KEY/);
  assert.throws(() => authSmtpConfig({ key: "re_clave", mailFrom: "" }), /MAIL_FROM/);
});

test("producción nunca abre las altas ni prende un CAPTCHA a medias: si config.toml lo pide, falla", () => {
  const open = CONFIG.replace(/^enable_signup = false$/m, "enable_signup = true");
  assert.notEqual(open, CONFIG, "el test tiene que encontrar la línea");
  assert.throws(() => authSecurityConfig(open), /altas/);
  assert.throws(() => authSecurityConfig(`${CONFIG}\n[auth.captcha]\nenabled = true\nprovider = "turnstile"\n`), /CAPTCHA/);
});

test("MAIL_FROM: nombre y dirección", () => {
  assert.deepEqual(parseMailFrom("Radici <ciao@radicicucina.app>"), { name: "Radici", address: "ciao@radicicucina.app" });
  assert.deepEqual(parseMailFrom('"Cucina di Eve" <ciao@example.test>'), { name: "Cucina di Eve", address: "ciao@example.test" });
  assert.deepEqual(parseMailFrom("ciao@example.test"), { name: "Radici", address: "ciao@example.test" });
  assert.throws(() => parseMailFrom("sin dirección"), /MAIL_FROM/);
});

test("línea de comandos (la del workflow): una parte por llamada; sin la clave, smtp sale con error", () => {
  const run = (part: string, env: Record<string, string> = {}): string =>
    execFileSync(process.execPath, [SCRIPT, part], {
      env: { ...process.env, RESEND_SMTP_KEY: "", MAIL_FROM: "", TURNSTILE_AUTH_SECRET_KEY: "0x4AAAAAAAsecreta", ...env },
      encoding: "utf8",
    });
  assert.deepEqual(JSON.parse(run("security")), { ...authSecurityConfig(CONFIG), security_captcha_secret: "0x4AAAAAAAsecreta" });
  assert.throws(
    () => execFileSync(process.execPath, [SCRIPT, "security"], { env: { ...process.env, TURNSTILE_AUTH_SECRET_KEY: "" }, encoding: "utf8", stdio: "pipe" }),
    (error: { status?: number; stderr?: string }) => error.status === 2 && String(error.stderr).includes("TURNSTILE_AUTH_SECRET_KEY"),
  );
  assert.equal(JSON.parse(run("templates")).mailer_templates_magic_link_content, TEMPLATE);
  assert.equal(JSON.parse(run("smtp", { RESEND_SMTP_KEY: "re_x", MAIL_FROM: "Radici <ciao@x.example>" })).smtp_pass, "re_x");
  assert.throws(() => run("smtp"), (error: { status?: number }) => error.status === 2);
  assert.throws(() => run("otra"), (error: { status?: number }) => error.status === 2);
});

// ---------------------------------------------------------------------------------------------
// PR04: Auth fijada desde el repo (contrato auth.md). Los nombres de los campos son los de la
// Management API (PATCH /v1/projects/{ref}/config/auth, OpenAPI https://api.supabase.com/api/v1-json).
// ---------------------------------------------------------------------------------------------

// Los campos del PATCH del OpenAPI público (leído el 23/11/2026) que usa este repo: si un nombre se
// equivoca, la API lo ignora en silencio, así que el test lo compara con esta lista.
const MANAGEMENT_API_AUTH_FIELDS = [
  "site_url", "uri_allow_list", "disable_signup", "external_email_enabled", "external_phone_enabled",
  "external_anonymous_users_enabled", "external_google_enabled", "external_apple_enabled",
  "external_web3_solana_enabled", "external_web3_ethereum_enabled", "saml_enabled",
  "external_email_magic_link_disabled", "mailer_autoconfirm", "sms_autoconfirm",
  "mailer_allow_unverified_email_sign_ins", "mailer_secure_email_change_enabled",
  "security_manual_linking_enabled", "security_captcha_enabled", "rate_limit_verify", "rate_limit_email_sent",
  "hook_custom_access_token_enabled", "hook_custom_access_token_uri", "hook_before_user_created_enabled",
  "rate_limit_token_refresh", "rate_limit_otp", "rate_limit_anonymous_users", "rate_limit_sms_sent", "rate_limit_web3",
  "mailer_otp_length", "mailer_otp_exp", "smtp_host", "smtp_port", "smtp_user", "smtp_pass",
  "smtp_admin_email", "smtp_sender_name", "mailer_subjects_magic_link", "mailer_subjects_confirmation",
  "mailer_templates_magic_link_content", "mailer_templates_confirmation_content",
  // PR14: contraseñas y el aviso de contraseña cambiada (OpenAPI leído el 26/11/2026).
  "password_min_length", "password_required_characters", "security_update_password_require_current_password",
  "security_update_password_require_reauthentication", "mailer_notifications_password_changed_enabled",
  "mailer_subjects_password_changed_notification", "mailer_templates_password_changed_notification_content",
  // PR11: el captcha de Auth y la frecuencia de los emails.
  "security_captcha_provider", "security_captcha_secret", "smtp_max_frequency",
  // PR16: las otras cuatro plantillas de Auth (OpenAPI leído el 26/11/2026).
  "mailer_subjects_recovery", "mailer_templates_recovery_content", "mailer_subjects_email_change",
  "mailer_templates_email_change_content", "mailer_subjects_reauthentication", "mailer_templates_reauthentication_content",
  "mailer_subjects_invite", "mailer_templates_invite_content",
];

const PINNED = {
  site_url: "https://radicicucina.app/app/",
  uri_allow_list: "https://radicicucina.app/app/",
  mailer_autoconfirm: false,
  sms_autoconfirm: false,
  mailer_allow_unverified_email_sign_ins: false,
  mailer_secure_email_change_enabled: true,
  security_manual_linking_enabled: false,
  external_email_magic_link_disabled: false,
  rate_limit_verify: 10,
  // Hooks de Auth (contrato auth.md §8): el de la cocina prendido; el de las altas apagado hasta PR20.
  hook_custom_access_token_enabled: true,
  hook_custom_access_token_uri: "pg-functions://postgres/public/kitchen_access_token_hook",
  hook_before_user_created_enabled: false,
  // Límites de intentos (contrato auth.md §9): /token (contraseña y refresh), /otp y familia, y los flujos apagados al mínimo.
  rate_limit_token_refresh: 20,
  rate_limit_otp: 10,
  rate_limit_anonymous_users: 1,
  rate_limit_sms_sent: 1,
  rate_limit_web3: 1,
  // Contraseñas (contrato auth.md §12): 10 o más con letras y números; la actual para cambiarla; sin reautenticación.
  password_min_length: 10,
  password_required_characters: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ:0123456789",
  security_update_password_require_current_password: true,
  security_update_password_require_reauthentication: false,
  external_google_enabled: false,
  external_apple_enabled: false,
  external_phone_enabled: false,
  external_anonymous_users_enabled: false,
  external_web3_solana_enabled: false,
  external_web3_ethereum_enabled: false,
  saml_enabled: false,
};

test("security: el cuerpo fija cada ajuste del PR04 con el nombre de campo de la Management API", () => {
  const body = authSecurityConfig(CONFIG);
  for (const [key, value] of Object.entries(PINNED)) assert.deepEqual(body[key], value, key);
  // Lo de antes sigue igual: Evelyn entra con el mismo código de 8 cifras.
  assert.equal(body.disable_signup, true);
  assert.equal(body.external_email_enabled, true);
  assert.equal(body.mailer_otp_length, 10);
  assert.equal(body.mailer_otp_exp, 3600);
  assert.equal(body.security_captcha_enabled, true);
});

test("los campos de las tres partes existen en la Management API", () => {
  const all = [
    ...Object.keys(authSecurityConfig(CONFIG)),
    ...Object.keys(authSmtpConfig({ key: "re_x", mailFrom: "a@b.test" })),
    ...Object.keys(authCaptchaConfig("0x4AAAAAAAx")),
    ...Object.keys(authTemplatesConfig(CONFIG, read)),
  ];
  for (const key of all) assert.ok(MANAGEMENT_API_AUTH_FIELDS.includes(key), `campo desconocido: ${key}`);
});

test("combinaciones prohibidas: config.toml que prende autoconfirm (email o sms) o afloja algo, corta", () => {
  const swap = (from: RegExp, to: string): string => {
    const out = CONFIG.replace(from, to);
    assert.notEqual(out, CONFIG, `el test tiene que encontrar ${from}`);
    return out;
  };
  // enable_confirmations = false equivale a autoconfirm = true.
  assert.throws(() => authSecurityConfig(swap(/(\[auth\.email\][^[]*?)enable_confirmations = true/s, "$1enable_confirmations = false")), /autoconfirm/);
  assert.throws(() => authSecurityConfig(swap(/(\[auth\.sms\][^[]*?)enable_confirmations = true/s, "$1enable_confirmations = false")), /autoconfirm/);
  assert.throws(() => authSecurityConfig(swap(/enable_manual_linking = false/, "enable_manual_linking = true")), /linking/);
  assert.throws(() => authSecurityConfig(swap(/enable_anonymous_sign_ins = false/, "enable_anonymous_sign_ins = true")), /anónimos/);
  assert.throws(() => authSecurityConfig(swap(/double_confirm_changes = true/, "double_confirm_changes = false")), /cambio de email/);
  assert.throws(() => authSecurityConfig(swap(/token_verifications = 10/, "token_verifications = 30")), /token_verifications/);
  // Los hooks: si config.toml apaga el de la cocina, cambia su función o prende el de las altas, el despliegue corta.
  assert.throws(() => authSecurityConfig(swap(/(\[auth\.hook\.custom_access_token\][^[]*?)enabled = true/s, "$1enabled = false")), /custom_access_token/);
  assert.throws(() => authSecurityConfig(swap(/kitchen_access_token_hook"/, 'otra_funcion"')), /custom_access_token/);
  assert.throws(() => authSecurityConfig(`${CONFIG}
[auth.hook.before_user_created]
enabled = true
uri = "pg-functions://postgres/public/before_user_created_guard"
`), /before_user_created/);
  // Los límites de intentos de login: si config.toml los afloja, el despliegue corta (local y producción no se separan).
  assert.throws(() => authSecurityConfig(swap(/token_refresh = d+/, "token_refresh = 150")), /token_refresh/);
  assert.throws(() => authSecurityConfig(swap(/sign_in_sign_ups = d+/, "sign_in_sign_ups = 30")), /sign_in_sign_ups/);
  assert.throws(() => authSecurityConfig(swap(/anonymous_users = d+/, "anonymous_users = 30")), /anonymous_users/);
  assert.throws(() => authSecurityConfig(swap(/sms_sent = d+/, "sms_sent = 30")), /sms_sent/);
  assert.throws(() => authSecurityConfig(swap(/^web3 = d+/m, "web3 = 30")), /web3/);
  assert.throws(() => authSecurityConfig(swap(/(\[auth\.external\.apple\][^[]*?)enabled = false/s, "$1enabled = true")), /apple/i);
  // Las contraseñas (PR14): si config.toml afloja la regla o pide reautenticarse, corta.
  assert.throws(() => authSecurityConfig(swap(/minimum_password_length = 10/, "minimum_password_length = 8")), /minimum_password_length/);
  assert.throws(() => authSecurityConfig(swap(/password_requirements = "letters_digits"/, 'password_requirements = ""')), /password_requirements/);
  assert.throws(() => authSecurityConfig(swap(/secure_password_change = false/, "secure_password_change = true")), /secure_password_change/);
  assert.throws(() => authSecurityConfig(swap(/(\[auth\.web3\.solana\][^[]*?)enabled = false/s, "$1enabled = true")), /web3/i);
});

test("config.toml del repo: el hook de la cocina prendido con su función, y el de las altas apagado", () => {
  const kitchen = tomlSection(CONFIG, "auth.hook.custom_access_token");
  assert.equal(kitchen.get("enabled"), true);
  assert.equal(kitchen.get("uri"), "pg-functions://postgres/public/kitchen_access_token_hook");
  assert.notEqual(tomlSection(CONFIG, "auth.hook.before_user_created").get("enabled"), true, "el hook de las altas sigue apagado (PR20)");
});

test("config.toml del repo: confirmaciones prendidas para email y sms, y 10 verificaciones cada 5 minutos", () => {
  assert.equal(tomlSection(CONFIG, "auth.email").get("enable_confirmations"), true);
  assert.equal(tomlSection(CONFIG, "auth.sms").get("enable_confirmations"), true);
  assert.equal(tomlSection(CONFIG, "auth.rate_limit").get("token_verifications"), 10);
  const limits = tomlSection(CONFIG, "auth.rate_limit");
  assert.deepEqual(["token_refresh", "sign_in_sign_ups", "anonymous_users", "sms_sent", "web3"].map((k) => limits.get(k)), [20, 10, 1, 1, 1]);
  assert.equal(tomlSection(CONFIG, "auth").get("enable_signup"), false, "las altas siguen apagadas hasta M2");
});

const live = (): Record<string, unknown> => ({ ...authSecurityConfig(CONFIG), unrelated: "x" });

test("verifyAuthConfig: devuelve los campos que no quedaron como se pidieron, sin sus valores", () => {
  const body = authSecurityConfig(CONFIG);
  assert.deepEqual(verifyAuthConfig(body, live()), []);
  const bad: Record<string, unknown> = { ...live(), mailer_autoconfirm: true, rate_limit_verify: 30 };
  delete bad.site_url;
  assert.deepEqual(verifyAuthConfig(body, bad).sort(), ["mailer_autoconfirm", "rate_limit_verify", "site_url"]);
  // Un nombre de campo equivocado (la API lo ignora y no lo devuelve) no pasa en silencio.
  assert.deepEqual(verifyAuthConfig({ campo_inventado: true }, live()), ["campo_inventado"]);
});

test("verifyAuthConfig: cada combinación prohibida en la respuesta de la API se detecta", () => {
  const body = authSecurityConfig(CONFIG);
  for (const [key, value] of Object.entries(PINNED)) {
    const bad = typeof value === "boolean" ? !value : typeof value === "number" ? value + 1 : `${value}x`;
    assert.deepEqual(verifyAuthConfig(body, { ...live(), [key]: bad }), [key], key);
  }
});

test("changedFields: solo los nombres de lo que cambia en producción, nunca valores", () => {
  assert.deepEqual(changedFields({ a: true, b: "secreto-b", c: 10, d: 1 }, { a: false, b: "otro", c: 10 }), ["a", "b", "d"]);
  assert.deepEqual(changedFields({ a: true }, { a: true }), []);
});

test("línea de comandos: verify compara la respuesta de la API con el cuerpo; changed lista los nombres", () => {
  const run = (args: string[], input: string): string =>
    execFileSync(process.execPath, [SCRIPT, ...args], { input, encoding: "utf8", env: { ...process.env, TURNSTILE_AUTH_SECRET_KEY: "0x4AAAAAAAsecreta" } });
  assert.equal(run(["verify", "security"], JSON.stringify(live())), "");
  assert.throws(
    () => run(["verify", "security"], JSON.stringify({ ...live(), mailer_autoconfirm: true })),
    (error: { status?: number; stderr?: Buffer | string }) => error.status === 2 && String(error.stderr).includes("mailer_autoconfirm"),
  );
  assert.equal(run(["changed", "security"], JSON.stringify({ ...live(), rate_limit_verify: 30 })).trim(), "rate_limit_verify");
});

test("plantillas: .Data solo para comparar el idioma; nada del usuario sale en el email", () => {
  const actions = [CONFIG, TEMPLATE, PASSWORD_NOTICE].flatMap((text) => [...text.matchAll(/\{\{[^}]*\}\}/g)]).map((m) => m[0]);
  const withData = actions.filter((a) => a.includes(".Data"));
  assert.ok(withData.length > 0);
  for (const action of withData) {
    assert.match(action, /^\{\{ (else )?if and \.Data\.locale \(eq \.Data\.locale \\?"(es|en)\\?"\) \}\}$/, `.Data fuera de una comparación: ${action}`);
  }
  for (const text of [TEMPLATE, PASSWORD_NOTICE, CONFIG]) assert.ok(!/\.Data(?!\.locale\b)/.test(text), ".Data sin .locale");
  // Lo único que la plantilla del código imprime es el código (una vez por idioma); nada de links ni datos del usuario.
  const printed = [...TEMPLATE.matchAll(/\{\{\s*([^}]*?)\s*\}\}/g)].map((m) => m[1] ?? "").filter((a) => !/^(if|else|end)\b/.test(a));
  assert.deepEqual([...new Set(printed)], [".Token"]);
  // Lo mismo para los asuntos de config.toml: nada del usuario.
  for (const banned of [".ConfirmationURL", ".TokenHash", ".SiteURL", ".RedirectTo", ".Email", ".NewEmail"]) {
    assert.ok(!TEMPLATE.includes(banned), `la plantilla no usa ${banned}`);
    assert.ok(!PASSWORD_NOTICE.includes(banned), `el aviso de contraseña no usa ${banned}`);
    assert.ok(!CONFIG.includes(banned), `los asuntos de config.toml no usan ${banned}`);
  }
});

test("login_code: avisa en los tres idiomas que el código no se comparte con nadie, ni con Evelyn", () => {
  assert.match(TEMPLATE, /Non condividere questo codice con nessuno, nemmeno con Evelyn\./);
  assert.match(TEMPLATE, /No compartas este código con nadie, ni siquiera con Evelyn\./);
  assert.match(TEMPLATE, /Don't share this code with anyone, not even Evelyn\./);
  assert.ok(TEMPLATE.includes("{{ .Token }}"));
  assert.ok(!/href=/i.test(TEMPLATE), "sin link");
});

test("password_changed: el aviso en los tres idiomas, sin link y sin imprimir nada de la cuenta", () => {
  assert.match(PASSWORD_NOTICE, /La password del tuo account di Radici è appena stata cambiata\./);
  assert.match(PASSWORD_NOTICE, /La contraseña de tu cuenta de Radici acaba de cambiar\./);
  assert.match(PASSWORD_NOTICE, /The password of your Radici account has just been changed\./);
  for (const hint of ["«Password dimenticata?»", "«¿Olvidaste la contraseña?»", "“Forgot password?”"]) assert.ok(PASSWORD_NOTICE.includes(hint), hint);
  assert.ok(!/href=/i.test(PASSWORD_NOTICE), "sin link");
  // No imprime nada: ni el email, ni el código, ni la URL del sitio. Solo compara el idioma.
  const printed = [...PASSWORD_NOTICE.matchAll(/\{\{\s*([^}]*?)\s*\}\}/g)].map((m) => m[1] ?? "").filter((a) => !/^(if|else|end)\b/.test(a));
  assert.deepEqual(printed, []);
});

test("contraseñas: la regla de /accesso/ (web) y la de la app son las mismas que fija Auth", () => {
  const auth = tomlSection(CONFIG, "auth");
  assert.equal(auth.get("minimum_password_length"), PASSWORD_MIN_LENGTH);
  assert.equal(auth.get("password_requirements"), "letters_digits");
  assert.equal(WEB_PASSWORD_MIN_LENGTH, PASSWORD_MIN_LENGTH);
  // La app (Flutter) la revisa antes de mandarla: app/lib/features/auth/domain/password_rules.dart, con los mismos
  // casos en su test (password_rules_test.dart).
  const dart = read("app/lib/features/auth/domain/password_rules.dart");
  assert.match(dart, new RegExp(`const int passwordMinLength = ${PASSWORD_MIN_LENGTH};`));
  assert.match(dart, /const int passwordMaxBytes = 72;/);
  assert.ok(dart.includes("RegExp('[A-Za-z]')") && dart.includes("RegExp('[0-9]')"), "app: letras a-z, A-Z y dígitos");
  // letters_digits = una letra a-z o A-Z y un dígito: la web acepta y rechaza lo mismo.
  assert.deepEqual(LETTERS_DIGITS.split(":"), ["abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", "0123456789"]);
  for (const [password, ok] of [
    ["abcdefghi1", true],
    ["ABCDEFGHI1", true],
    ["abcdefghij", false],
    ["1234567890", false],
    ["abcdefgh1", false],
    ["èèèèèèèèè1", false],
  ] as const) {
    const accepted = password.length >= PASSWORD_MIN_LENGTH && /[a-zA-Z]/.test(password) && /[0-9]/.test(password);
    assert.equal(accepted, ok, password);
    assert.equal(passwordProblem(password) === null, ok, `web: ${password}`);
  }
});

test("contraseñas: las cuentas que crea el despliegue (64 hexadecimales al azar) cumplen la regla; las de prueba no llevan", () => {
  const script = read("supabase/scripts/deploy-accounts.sh");
  assert.match(script, /if \[ "\$\{3:-\}" != "sin-contrasena" \]; then password=\$\(openssl rand -hex 32\); fi/);
  assert.match(script, /--arg password "\$\{password\}"/);
  assert.match(script, /if \$password == "" then \{\} else \{password: \$password\} end/, "sin contraseña, el campo no va");
  // 64 caracteres de 0-9a-f: más de 10, y sin una letra o sin un dígito con probabilidad < 1e-13 (16^-64 · (6^64+10^64)).
  assert.ok(64 >= PASSWORD_MIN_LENGTH && 64 <= 72);
});
