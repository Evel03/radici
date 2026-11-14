// Tests de la configuración de Auth que deploy-supabase.yml aplica en producción. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { authSecurityConfig, authSmtpConfig, authTemplatesConfig, parseMailFrom, tomlSection } from "./auth-config.ts";

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
  assert.deepEqual(authSmtpConfig({ key: " re_clave ", mailFrom: "Radici <ciao@radici.sepusola10.com>" }), {
    smtp_host: "smtp.resend.com",
    smtp_port: "465",
    smtp_user: "resend",
    smtp_pass: "re_clave",
    smtp_admin_email: "ciao@radici.sepusola10.com",
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
  assert.deepEqual(parseMailFrom("Radici <ciao@radici.sepusola10.com>"), { name: "Radici", address: "ciao@radici.sepusola10.com" });
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
