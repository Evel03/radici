// Configuración de Auth de producción a partir del repo: la misma de la base local
// (supabase/config.toml) y la plantilla del código (supabase/templates/login_code.html).
// deploy-supabase.yml la aplica en cada despliegue con la Management API
// (PATCH /v1/projects/{ref}/config/auth): el panel nunca queda distinto del repo y nadie copia la
// plantilla a mano.
//
// Tres partes, en este orden (cada una es un PATCH):
// - security: altas apagadas, código de 8 cifras y su vencimiento, CAPTCHA. No depende del plan.
// - smtp: el SMTP de Resend (necesita RESEND_SMTP_KEY y MAIL_FROM).
// - templates: asuntos, plantilla del código y límite de emails. En un proyecto Free (desde junio de
//   2026) Supabase solo deja cambiar las plantillas con SMTP propio: sin él, el email del código trae
//   el link de la plantilla por defecto y no el código, y la app no deja entrar. Por eso va después
//   del SMTP y nunca sin él.
//
// Uso (CI, desde la raíz): node supabase/scripts/auth-config.ts security|smtp|templates > body.json
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

/** Altas apagadas, código de 8 cifras y CAPTCHA, desde config.toml. */
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
  return {
    disable_signup: true,
    external_email_enabled: true,
    mailer_otp_length: requireValue<number>(email, "otp_length", "number"),
    mailer_otp_exp: requireValue<number>(email, "otp_expiry", "number"),
    security_captcha_enabled: false,
  };
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
// adentro: va directo al curl del workflow, nunca a un log).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const root = new URL("../../", import.meta.url);
  const read = (path: string): string => readFileSync(new URL(path.replace(/^\.\//, ""), root), "utf8");
  const toml = read("supabase/config.toml");
  const part = process.argv[2];
  try {
    const body =
      part === "security"
        ? authSecurityConfig(toml)
        : part === "smtp"
          ? authSmtpConfig({ key: process.env.RESEND_SMTP_KEY ?? "", mailFrom: process.env.MAIL_FROM ?? "" })
          : part === "templates"
            ? authTemplatesConfig(toml, read)
            : null;
    if (!body) throw new Error("Uso: node supabase/scripts/auth-config.ts security|smtp|templates");
    process.stdout.write(JSON.stringify(body));
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(2);
  }
}
