// Tests de la configuración de Auth que deploy-supabase.yml aplica en producción. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
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

test("security: altas apagadas, código de 8 cifras por 10 minutos y sin CAPTCHA; nada de correo", () => {
  const body = authSecurityConfig(CONFIG);
  assert.deepEqual(body, {
    ...PINNED, // lo del PR04 (más abajo)
    disable_signup: true,
    external_email_enabled: true,
    mailer_otp_length: 8,
    mailer_otp_exp: 600,
    security_captcha_enabled: false,
  });
});

test("templates: las dos plantillas son el código del repo, con el asunto en el idioma del usuario", () => {
  const body = authTemplatesConfig(CONFIG, read);
  for (const kind of ["magic_link", "confirmation"]) {
    assert.equal(body[`mailer_templates_${kind}_content`], TEMPLATE);
    assert.ok(String(body[`mailer_templates_${kind}_content`]).includes("{{ .Token }}"), "la plantilla trae el código");
    const subject = String(body[`mailer_subjects_${kind}`]);
    for (const text of ["Tu código de acceso", "Your sign-in code", "Il tuo codice di accesso"]) {
      assert.ok(subject.includes(text), `${kind}: falta ${text}`);
    }
    assert.ok(!subject.includes('\\"'), "comillas sin escapar");
  }
  assert.equal(body.rate_limit_email_sent, 100);
  assert.ok(Object.keys(body).every((key) => !key.startsWith("smtp_")));
});

test("smtp: Resend con el remitente de MAIL_FROM; sin clave, falla", () => {
  assert.deepEqual(authSmtpConfig({ key: " re_clave ", mailFrom: "Radici <ciao@radicicucina.app>" }), {
    smtp_host: "smtp.resend.com",
    smtp_port: "465",
    smtp_user: "resend",
    smtp_pass: "re_clave",
    smtp_admin_email: "ciao@radicicucina.app",
    smtp_sender_name: "Radici",
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
    execFileSync(process.execPath, [SCRIPT, part], { env: { ...process.env, RESEND_SMTP_KEY: "", MAIL_FROM: "", ...env }, encoding: "utf8" });
  assert.deepEqual(JSON.parse(run("security")), authSecurityConfig(CONFIG));
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
  assert.equal(body.mailer_otp_length, 8);
  assert.equal(body.mailer_otp_exp, 600);
  assert.equal(body.security_captcha_enabled, false);
});

test("los campos de las tres partes existen en la Management API", () => {
  const all = [
    ...Object.keys(authSecurityConfig(CONFIG)),
    ...Object.keys(authSmtpConfig({ key: "re_x", mailFrom: "a@b.test" })),
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
  const run = (args: string[], input: string): string => execFileSync(process.execPath, [SCRIPT, ...args], { input, encoding: "utf8" });
  assert.equal(run(["verify", "security"], JSON.stringify(live())), "");
  assert.throws(
    () => run(["verify", "security"], JSON.stringify({ ...live(), mailer_autoconfirm: true })),
    (error: { status?: number; stderr?: Buffer | string }) => error.status === 2 && String(error.stderr).includes("mailer_autoconfirm"),
  );
  assert.equal(run(["changed", "security"], JSON.stringify({ ...live(), rate_limit_verify: 30 })).trim(), "rate_limit_verify");
});

test("plantillas: .Data solo para comparar el idioma; nada del usuario sale en el email", () => {
  const actions = [...CONFIG.matchAll(/\{\{[^}]*\}\}/g), ...TEMPLATE.matchAll(/\{\{[^}]*\}\}/g)].map((m) => m[0]);
  const withData = actions.filter((a) => a.includes(".Data"));
  assert.ok(withData.length > 0);
  for (const action of withData) {
    assert.match(action, /^\{\{ (else )?if and \.Data\.locale \(eq \.Data\.locale \\?"(es|en)\\?"\) \}\}$/, `.Data fuera de una comparación: ${action}`);
  }
  for (const text of [TEMPLATE, CONFIG]) assert.ok(!/\.Data(?!\.locale\b)/.test(text), ".Data sin .locale");
  // Lo único que la plantilla imprime es el código; nada de links ni datos del usuario.
  const printed = [...TEMPLATE.matchAll(/\{\{\s*([^}]*?)\s*\}\}/g)].map((m) => m[1] ?? "").filter((a) => !/^(if|else|end)\b/.test(a));
  assert.deepEqual(printed, [".Token"]);
  // Lo mismo para los asuntos de config.toml: nada del usuario.
  for (const banned of [".ConfirmationURL", ".TokenHash", ".SiteURL", ".RedirectTo", ".Email", ".NewEmail"]) {
    assert.ok(!TEMPLATE.includes(banned), `la plantilla no usa ${banned}`);
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
