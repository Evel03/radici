// Configuración de la web en un solo lugar.
// Lee las variables VITE_* (ver web/.env.example). La lógica es una función pura
// para poder usarla también desde vite.config.ts (Node) y desde los tests.

/** Versión del texto de los consentimientos (privacy y datos de salud). Cambiarla si cambia el texto. */
export const CONSENT_VERSION = "2026-10-19";

export interface AppConfig {
  /** Número de WhatsApp de Evelyn: solo dígitos, formato internacional sin "+". null si falta o no es válido. */
  whatsappNumber: string | null;
  /** Nombre de la marca (provisorio). */
  brandName: string;
  /** true: todas las páginas llevan <meta name="robots" content="noindex">. */
  noindex: boolean;
  /** URL pública sin barra final (ej. https://mestolo.example.com). null si no se configuró. */
  siteUrl: string | null;
}

type EnvLike = Readonly<Record<string, unknown>>;

const DEFAULT_BRAND = "Mestolo";

function readString(env: EnvLike, key: string): string {
  const value = env[key];
  return typeof value === "string" ? value.trim() : "";
}

/** Normaliza el número: acepta espacios, guiones, paréntesis, "+" o "00" inicial. */
export function normalizeWhatsAppNumber(raw: string): string | null {
  let digits = raw.replace(/[\s().-]/g, "");
  if (digits.startsWith("+")) digits = digits.slice(1);
  else if (digits.startsWith("00")) digits = digits.slice(2);
  return /^[1-9]\d{7,14}$/.test(digits) ? digits : null;
}

function parseBoolean(raw: string, fallback: boolean): boolean {
  const v = raw.toLowerCase();
  if (["false", "0", "no", "off"].includes(v)) return false;
  if (["true", "1", "yes", "si", "sí", "on"].includes(v)) return true;
  return fallback;
}

function normalizeSiteUrl(raw: string): string | null {
  if (!/^https?:\/\/[^\s/]+/i.test(raw)) return null;
  return raw.replace(/\/+$/, "");
}

export function resolveConfig(env: EnvLike): AppConfig {
  return {
    whatsappNumber: normalizeWhatsAppNumber(readString(env, "VITE_WHATSAPP_NUMBER")),
    brandName: readString(env, "VITE_BRAND_NAME") || DEFAULT_BRAND,
    noindex: parseBoolean(readString(env, "VITE_NOINDEX"), true),
    siteUrl: normalizeSiteUrl(readString(env, "VITE_SITE_URL")),
  };
}

// En el navegador Vite reemplaza import.meta.env; en Node (vite.config.ts) no existe.
export const config: AppConfig = resolveConfig((import.meta.env as EnvLike | undefined) ?? {});
