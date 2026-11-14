// Tests de la configuración de Auth que deploy-supabase.yml aplica en producción. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { authConfig, parseMailFrom, tomlSection } from "./auth-config.ts";

const read = (path: string): string => readFileSync(new URL(`../../${path.replace(/^\.\//, "")}`, import.meta.url), "utf8");
const CONFIG = read("supabase/config.toml");
const TEMPLATE = read("supabase/templates/login_code.html");

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

test("lo de config.toml: altas apagadas, código de 8 cifras por 10 minutos y la plantilla del repo", () => {
  const body = authConfig(CONFIG, read, null);
  assert.equal(body.disable_signup, true);
  assert.equal(body.external_email_enabled, true);
  assert.equal(body.mailer_otp_length, 8);
  assert.equal(body.mailer_otp_exp, 600);
  assert.equal(body.security_captcha_enabled, false);
  // Las dos plantillas (Magic link y Confirm signup) son el código, con el asunto en el idioma del usuario.
  for (const kind of ["magic_link", "confirmation"]) {
    assert.equal(body[`mailer_templates_${kind}_content`], TEMPLATE);
    const subject = String(body[`mailer_subjects_${kind}`]);
    for (const text of ["Tu código de acceso", "Your sign-in code", "Il tuo codice di accesso"]) {
      assert.ok(subject.includes(text), `${kind}: falta ${text}`);
    }
    assert.ok(!subject.includes('\\"'), "comillas sin escapar");
  }
  // Sin la clave de Resend no se toca el SMTP ni el límite de emails (Supabase lo rechaza sin SMTP propio).
  assert.ok(Object.keys(body).every((key) => !key.startsWith("smtp_") && key !== "rate_limit_email_sent"));
});

test("con la clave de Resend: SMTP de Resend con el remitente de MAIL_FROM y 100 emails por hora", () => {
  const body = authConfig(CONFIG, read, { key: "re_clave", mailFrom: "Radici <ciao@radici.sepusola10.com>" });
  assert.equal(body.smtp_host, "smtp.resend.com");
  assert.equal(body.smtp_port, "465");
  assert.equal(body.smtp_user, "resend");
  assert.equal(body.smtp_pass, "re_clave");
  assert.equal(body.smtp_admin_email, "ciao@radici.sepusola10.com");
  assert.equal(body.smtp_sender_name, "Radici");
  assert.equal(body.rate_limit_email_sent, 100);
});

test("producción nunca abre las altas: si config.toml las abre, falla", () => {
  const open = CONFIG.replace(/^enable_signup = false$/m, "enable_signup = true");
  assert.notEqual(open, CONFIG, "el test tiene que encontrar la línea");
  assert.throws(() => authConfig(open, read, null), /altas/);
});

test("MAIL_FROM: nombre y dirección", () => {
  assert.deepEqual(parseMailFrom("Radici <ciao@radici.sepusola10.com>"), { name: "Radici", address: "ciao@radici.sepusola10.com" });
  assert.deepEqual(parseMailFrom('"Cucina di Eve" <ciao@example.test>'), { name: "Cucina di Eve", address: "ciao@example.test" });
  assert.deepEqual(parseMailFrom("ciao@example.test"), { name: "Radici", address: "ciao@example.test" });
  assert.throws(() => parseMailFrom("sin dirección"), /MAIL_FROM/);
});
