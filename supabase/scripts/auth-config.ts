// Configuración de Auth de producción a partir del repo: la misma de la base local
// (supabase/config.toml) y la plantilla del código (supabase/templates/login_code.html).
// deploy-supabase.yml la aplica en cada despliegue con la Management API
// (PATCH /v1/projects/{ref}/config/auth): el panel nunca queda distinto del repo y nadie copia la
// plantilla a mano.
//
// Tres partes, en este orden (cada una es un PATCH, y el despliegue vuelve a leer lo que Supabase guardó y
// lo compara con el cuerpo: `verify`; un campo que no quedó igual, o un nombre de campo equivocado que la
// API ignora en silencio, corta el despliegue antes de db push):
// - security: altas apagadas, código de 8 cifras y su vencimiento, CAPTCHA, sin autoconfirm, sin entrar
//   con emails sin verificar, cambio de email seguro, linking manual apagado, 10 verificaciones cada 5
//   minutos, URLs de redirección exactas y solo el email como proveedor (contrato docs/contracts/auth.md).
//   No depende del plan.
// - smtp: el SMTP de Resend (necesita RESEND_SMTP_KEY y MAIL_FROM).
// - templates: asuntos, plantilla del código y límite de emails. En un proyecto Free (desde junio de
//   2026) Supabase solo deja cambiar las plantillas con SMTP propio: sin él, el email del código trae
//   el link de la plantilla por defecto y no el código, y la app no deja entrar. Por eso va después
//   del SMTP y nunca sin él.
//
// Uso (CI, desde la raíz): node supabase/scripts/auth-config.ts security|smtp|templates > body.json
//   node supabase/scripts/auth-config.ts verify <parte> < respuesta.json   (falla con 2 si algo no quedó)
//   node supabase/scripts/auth-config.ts changed <parte> < respuesta.json  (nombres de campo que cambian)
// Solo sintaxis borrable: corre con node, sin compilar.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export interface SmtpSettings {
  /** Clave de Resend ("Sending access") que hace de contraseña del SMTP. */
  key: string;
  /** Remitente, como MAIL_FROM: "Radici <ciao@…>". */
  mailFrom: string;
}

type TomlValue = string | number | boolean;
export type AuthBody = Record<string, TomlValue>;

/**
 * Pares `clave = valor` de una sección de un TOML simple: cadenas básicas (con \" y \\), enteros y
 * booleanos. Lo demás (listas, tablas en línea) se ignora: config.toml no lo usa en estas secciones.
 */
export function tomlSection(toml: string, section: string): Map<string, TomlValue> {
  const values = new Map<string, TomlValue>();
  let current = "";
  for (const raw of toml.split(/\r?\n/)) {
    const line = raw.trim();
    const header = /^\[([^\][]+)\]\s*(#.*)?$/.exec(line);
    if (header) {
      current = (header[1] ?? "").trim();
      continue;
    }
    if (current !== section) continue;
    const pair = /^([A-Za-z0-9_-]+)\s*=\s*(.*)$/.exec(line);
    if (!pair) continue;
    const value = parseValue(pair[2] ?? "");
    if (value !== undefined) values.set(pair[1] ?? "", value);
  }
  return values;
}

function parseValue(text: string): TomlValue | undefined {
  if (text.startsWith('"')) {
    let out = "";
    for (let i = 1; i < text.length; i++) {
      const char = text[i];
      if (char === '"') return out;
      if (char === "\\") {
        const next = text[++i];
        out += next === "n" ? "\n" : next === "t" ? "\t" : (next ?? "");
      } else {
        out += char;
      }
    }
    return undefined; // sin la comilla de cierre
  }
  const bare = text.replace(/\s+#.*$/, "").trim();
  if (bare === "true") return true;
  if (bare === "false") return false;
  if (/^-?\d+$/.test(bare)) return Number(bare);
  return undefined;
}

/** "Radici <ciao@…>" → { name: "Radici", address: "ciao@…" }; sin nombre, "Radici". */
export function parseMailFrom(mailFrom: string): { name: string; address: string } {
  const withName = /^\s*"?([^"<]*?)"?\s*<([^<>\s]+@[^<>\s]+)>\s*$/.exec(mailFrom);
  if (withName) return { name: withName[1]?.trim() || "Radici", address: withName[2] ?? "" };
  const bare = mailFrom.trim();
  if (/^[^\s<>@]+@[^\s<>@]+$/.test(bare)) return { name: "Radici", address: bare };
  throw new Error("MAIL_FROM no es una dirección de email válida");
}

function requireValue<T extends TomlValue>(section: Map<string, TomlValue>, key: string, type: string): T {
  const value = section.get(key);
  if (typeof value !== type) throw new Error(`config.toml: falta ${key} (${type})`);
  return value as T;
}

/** Única URL de redirección de Auth: el área de clientes (M2). /gestione/ entra con el código de 8 cifras, sin redirección. */
export const AUTH_SITE_URL = "https://radicicucina.app/app/";

/** Falla si config.toml no coincide con lo que producción tiene fijado (así local y producción no se separan). */
function requireLocalMatch(toml: string, section: string, key: string, expected: TomlValue, message: string): void {
  if (tomlSection(toml, section).get(key) !== expected) throw new Error(`config.toml: ${message}`);
}

/** Proveedores externos ([auth.external.*]) que config.toml prende. */
function enabledExternalProviders(toml: string): string[] {
  const names = [...toml.matchAll(/^\[auth\.external\.([A-Za-z0-9_]+)\]/gm)].map((m) => m[1] ?? "");
  return names.filter((name) => tomlSection(toml, `auth.external.${name}`).get("enabled") === true);
}

/**
 * Lo fijo de Auth, desde config.toml y las constantes de arriba: altas apagadas, código de 8 cifras,
 * CAPTCHA apagado, sin autoconfirm, sin entrar con emails sin verificar, cambio de email seguro, linking
 * manual apagado, magic link prendido (el código de Evelyn sale de esa plantilla), 10 verificaciones
 * cada 5 minutos y solo el email como proveedor. Nombres de campo: Management API, PATCH
 * /v1/projects/{ref}/config/auth.
 */
export function authSecurityConfig(toml: string): AuthBody {
  const auth = tomlSection(toml, "auth");
  const email = tomlSection(toml, "auth.email");
  // Hasta M2 nadie se registra solo: la cuenta de la cocinera la crea el despliegue (contrato §10).
  if (requireValue<boolean>(auth, "enable_signup", "boolean")) {
    throw new Error("config.toml abre las altas ([auth] enable_signup): producción las tiene apagadas hasta M2");
  }
  // La app no manda captchaToken. Para M2 hay que sumar acá el proveedor y su secreto (y el token en la
  // app): prenderlo solo en config.toml (o en el panel) no alcanza, y el próximo despliegue lo apagaría.
  if (tomlSection(toml, "auth.captcha").get("enabled") === true) {
    throw new Error("config.toml prende el CAPTCHA: falta su proveedor y su secreto en auth-config.ts (M2)");
  }
  // enable_confirmations = false es el autoconfirm de la Management API (mailer_autoconfirm y
  // sms_autoconfirm = true): una cuenta quedaría confirmada sin probar que el email es suyo.
  requireLocalMatch(toml, "auth.email", "enable_confirmations", true, "[auth.email] enable_confirmations = false prende el autoconfirm del email");
  requireLocalMatch(toml, "auth.sms", "enable_confirmations", true, "[auth.sms] enable_confirmations = false prende el autoconfirm del teléfono");
  requireLocalMatch(toml, "auth", "enable_manual_linking", false, "[auth] enable_manual_linking prende el linking manual");
  requireLocalMatch(toml, "auth", "enable_anonymous_sign_ins", false, "[auth] enable_anonymous_sign_ins prende los anónimos");
  requireLocalMatch(toml, "auth.email", "double_confirm_changes", true, "[auth.email] double_confirm_changes apagado: el cambio de email tiene que confirmarse en los dos emails");
  requireLocalMatch(toml, "auth.sms", "enable_signup", false, "[auth.sms] enable_signup prende el teléfono");
  requireLocalMatch(toml, "auth.web3.solana", "enabled", false, "[auth.web3.solana] enabled prende Web3");
  requireLocalMatch(toml, "auth.rate_limit", "token_verifications", 10, "[auth.rate_limit] token_verifications tiene que ser 10 (rate_limit_verify de producción)");
  const providers = enabledExternalProviders(toml);
  if (providers.length > 0) {
    throw new Error(`config.toml prende proveedores externos (${providers.join(", ")}): Google y Apple se prenden en su PR, con su secreto en auth-config.ts`);
  }
  return {
    disable_signup: true,
    external_email_enabled: true,
    mailer_otp_length: requireValue<number>(email, "otp_length", "number"),
    mailer_otp_exp: requireValue<number>(email, "otp_expiry", "number"),
    security_captcha_enabled: false,
    // /gestione/ entra con el código por email, sin redirección: estas URLs son solo las del área de
    // clientes y no abren /gestione/ a ningún redirect (contrato auth.md §3).
    site_url: AUTH_SITE_URL,
    uri_allow_list: AUTH_SITE_URL,
    mailer_autoconfirm: false,
    sms_autoconfirm: false,
    mailer_allow_unverified_email_sign_ins: false,
    mailer_secure_email_change_enabled: true,
    security_manual_linking_enabled: false,
    // false = el magic link / código por email prendido (signInWithOtp de la app lo usa).
    external_email_magic_link_disabled: false,
    rate_limit_verify: 10,
    external_google_enabled: false,
    external_apple_enabled: false,
    external_phone_enabled: false,
    external_anonymous_users_enabled: false,
    external_web3_solana_enabled: false,
    external_web3_ethereum_enabled: false,
    saml_enabled: false,
  };
}

/** Campos que la API guarda pero no devuelve en claro: no se comparan. */
const NOT_COMPARABLE = new Set(["smtp_pass"]);

const same = (expected: unknown, live: unknown): boolean => live !== undefined && live !== null && String(expected) === String(live);

/** Nombres de los campos de [body] que la configuración vigente [live] no tiene igual (nunca valores). */
export function verifyAuthConfig(body: AuthBody, live: Record<string, unknown>): string[] {
  return Object.keys(body).filter((key) => !NOT_COMPARABLE.has(key) && !same(body[key], live[key]));
}

/** Lo que cambiaría en producción: los nombres de campo que hoy no tienen el valor del repo. */
export function changedFields(body: AuthBody, live: Record<string, unknown>): string[] {
  return verifyAuthConfig(body, live);
}

/** SMTP de Resend con el remitente de MAIL_FROM. */
export function authSmtpConfig(smtp: SmtpSettings): AuthBody {
  if (!smtp.key.trim()) throw new Error("Falta la clave del SMTP (RESEND_SMTP_KEY)");
  const sender = parseMailFrom(smtp.mailFrom);
  return {
    smtp_host: "smtp.resend.com",
    smtp_port: "465",
    smtp_user: "resend",
    smtp_pass: smtp.key.trim(),
    smtp_admin_email: sender.address,
    smtp_sender_name: sender.name,
  };
}

/** Asuntos y plantilla del código (rutas de config.toml, leídas con [readFile]) y límite de emails. */
export function authTemplatesConfig(toml: string, readFile: (path: string) => string): AuthBody {
  const magicLink = tomlSection(toml, "auth.email.template.magic_link");
  const confirmation = tomlSection(toml, "auth.email.template.confirmation");
  return {
    mailer_subjects_magic_link: requireValue<string>(magicLink, "subject", "string"),
    mailer_templates_magic_link_content: readFile(requireValue<string>(magicLink, "content_path", "string")),
    mailer_subjects_confirmation: requireValue<string>(confirmation, "subject", "string"),
    mailer_templates_confirmation_content: readFile(requireValue<string>(confirmation, "content_path", "string")),
    // Cualquiera puede pedir un código por minuto para el email de Evelyn (60 por hora), y el límite es
    // de todo el proyecto. Supabase solo deja cambiarlo con SMTP propio.
    rate_limit_email_sent: 100,
  };
}

// Uso desde la línea de comandos: imprime el cuerpo de una parte en JSON (con la clave del SMTP
// adentro: va directo al curl del workflow, nunca a un log). `verify` y `changed` leen de la entrada
// estándar la configuración vigente (la respuesta de la API, con la clave del SMTP: no se imprime) y solo
// escriben nombres de campo.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const root = new URL("../../", import.meta.url);
  const read = (path: string): string => readFileSync(new URL(path.replace(/^\.\//, ""), root), "utf8");
  const toml = read("supabase/config.toml");
  const bodyOf = (part: string | undefined): AuthBody => {
    const body =
      part === "security"
        ? authSecurityConfig(toml)
        : part === "smtp"
          ? authSmtpConfig({ key: process.env.RESEND_SMTP_KEY ?? "", mailFrom: process.env.MAIL_FROM ?? "" })
          : part === "templates"
            ? authTemplatesConfig(toml, read)
            : null;
    if (!body) throw new Error("Uso: node supabase/scripts/auth-config.ts [verify|changed] security|smtp|templates");
    return body;
  };
  try {
    const command = process.argv[2];
    if (command === "verify" || command === "changed") {
      const live = JSON.parse(readFileSync(0, "utf8")) as Record<string, unknown>;
      const wrong = verifyAuthConfig(bodyOf(process.argv[3]), live);
      if (command === "changed") process.stdout.write(wrong.map((name) => `${name}\n`).join(""));
      else if (wrong.length > 0) throw new Error(`Auth no quedó como pide el repo, campos: ${wrong.join(", ")}`);
    } else {
      process.stdout.write(JSON.stringify(bodyOf(command)));
    }
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(2);
  }
}
