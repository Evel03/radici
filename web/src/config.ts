// Configuración de la web en un solo lugar.
// Lee las variables VITE_* (ver web/.env.example). Funciones puras: las usan vite.config.ts (Node,
// con el entorno resuelto: HTML, CSP, robots.txt) y los tests. El navegador lee solo lo suyo en
// site-config.ts. Todas son públicas (nada secreto acá).

export interface AppConfig {
  /** Nombre de la marca (VITE_BRAND_NAME; por defecto Radici). */
  brandName: string;
  /** true: todas las páginas llevan <meta name="robots" content="noindex">. */
  noindex: boolean;
  /** URL pública sin barra final (ej. https://radicicucina.app). null si no se configuró. */
  siteUrl: string | null;
  /** Origen del proyecto de Supabase (ej. https://abcd.supabase.co). null si falta o no es válido. */
  supabaseUrl: string | null;
  /**
   * Clave publicable de Supabase (sb_publishable_...). La usa /accesso/ en la cabecera apikey de sus llamadas a
   * Supabase Auth. `public-request` y `client-link` no la necesitan (son funciones con verify_jwt = false).
   */
  supabasePublishableKey: string | null;
  /** Sitekey de Cloudflare Turnstile. null si falta o no es válida. */
  turnstileSiteKey: string | null;
  /**
   * Sitekey de Turnstile de Auth (/captcha/, el captcha de los pedidos a Supabase Auth). Es otro widget que el del
   * formulario: su propio par de claves, y la secreta vive en Supabase (no en el repo). null si falta o no es válida.
   */
  turnstileAuthSiteKey: string | null;
}

type EnvLike = Readonly<Record<string, unknown>>;

const DEFAULT_BRAND = "Radici";

/** Sitekey de prueba de Cloudflare que siempre aprueba (visible): para desarrollo local. */
export const TURNSTILE_TEST_SITE_KEY = "1x00000000000000000000AA";

function readString(env: EnvLike, key: string): string {
  const value = env[key];
  return typeof value === "string" ? value.trim() : "";
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

/**
 * Origen del proyecto de Supabase: https, o http solo en la máquina local (supabase start, mocks).
 * Se queda con el origen: es lo que va a la CSP (connect-src) y la base de la URL de la función.
 */
export function normalizeSupabaseUrl(raw: string): string | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (url.protocol === "https:" || (url.protocol === "http:" && local)) return url.origin;
  return null;
}

/** Claves que se publican tal cual: sin espacios ni caracteres que rompan el HTML o la CSP. */
function normalizeKey(raw: string): string | null {
  return /^[\w.-]{1,200}$/.test(raw) ? raw : null;
}

/**
 * La clave publicable, solo si de verdad lo es: va en el JS público. Acepta sb_publishable_… o la clave anon vieja (un
 * JWT con role "anon", la de `supabase start`). Una secreta (sb_secret_…), la service_role o cualquier otra cosa
 * queda en null: mejor una página que no puede llamar a Auth que una clave secreta publicada.
 */
export function normalizePublishableKey(raw: string): string | null {
  if (/^sb_publishable_[A-Za-z0-9_-]{1,200}$/.test(raw)) return raw;
  const jwt = /^eyJ[A-Za-z0-9_-]+\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+$/.exec(raw);
  if (!jwt?.[1] || raw.length > 2000) return null;
  try {
    const base64 = jwt[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload: unknown = JSON.parse(atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")));
    return typeof payload === "object" && payload !== null && (payload as Record<string, unknown>)["role"] === "anon" ? raw : null;
  } catch {
    return null;
  }
}

/** Las sitekeys de prueba (1x…, 2x…, 3x…) no sirven en producción: el servidor rechaza su token. */
export function isTurnstileTestKey(siteKey: string): boolean {
  return /^[123]x0{20}[A-Z]{2}$/.test(siteKey);
}

export function resolveConfig(env: EnvLike): AppConfig {
  return {
    brandName: readString(env, "VITE_BRAND_NAME") || DEFAULT_BRAND,
    noindex: parseBoolean(readString(env, "VITE_NOINDEX"), true),
    siteUrl: normalizeSiteUrl(readString(env, "VITE_SITE_URL")),
    supabaseUrl: normalizeSupabaseUrl(readString(env, "VITE_SUPABASE_URL")),
    supabasePublishableKey: normalizePublishableKey(readString(env, "VITE_SUPABASE_PUBLISHABLE_KEY")),
    turnstileSiteKey: normalizeKey(readString(env, "VITE_TURNSTILE_SITE_KEY")),
    turnstileAuthSiteKey: normalizeKey(readString(env, "VITE_TURNSTILE_AUTH_SITE_KEY")),
  };
}

/**
 * Lo único que usa el JS del navegador. noindex y la URL del sitio solo sirven en el build (HTML,
 * robots.txt). La clave publicable es pública por diseño (va en el JS de /gestione/ y de /app/ también).
 */
export type SiteConfig = Pick<AppConfig, "brandName" | "supabaseUrl" | "supabasePublishableKey" | "turnstileSiteKey" | "turnstileAuthSiteKey">;

/** Variables que lee el navegador: las únicas que Vite pone en el JS publicado. */
export const SITE_ENV_KEYS = [
  "VITE_BRAND_NAME",
  "VITE_SUPABASE_URL",
  "VITE_SUPABASE_PUBLISHABLE_KEY",
  "VITE_TURNSTILE_SITE_KEY",
  "VITE_TURNSTILE_AUTH_SITE_KEY",
] as const;

export function toSiteConfig(full: AppConfig): SiteConfig {
  return {
    brandName: full.brandName,
    supabaseUrl: full.supabaseUrl,
    supabasePublishableKey: full.supabasePublishableKey,
    turnstileSiteKey: full.turnstileSiteKey,
    turnstileAuthSiteKey: full.turnstileAuthSiteKey,
  };
}
