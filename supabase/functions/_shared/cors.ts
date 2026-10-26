// CORS con lista de orígenes permitidos (contrato §2, ALLOWED_ORIGINS).
// Admite comodín de subdominio: "https://*.<pages>.pages.dev" acepta
// "https://abc.<pages>.pages.dev" (una sola etiqueta: así son las vistas
// previas de Cloudflare Pages), pero no el dominio pelado ni niveles más profundos.
// <pages> es el subdominio que Cloudflare asigna al proyecto de Pages "radici"
// (puede llevar un sufijo si "radici" ya está tomado). Por defecto la lista NO
// incluye las vistas previas: usan el backend de producción y crearían pedidos
// reales; se suma una a mano y por un rato (contrato §4).
// Un origen que no está en la lista no recibe ninguna cabecera CORS.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).

export interface OriginRule {
  scheme: "http" | "https";
  /** Host en minúsculas; con comodín, el sufijo después de "*." */
  host: string;
  /** "" si es el puerto por defecto del esquema. */
  port: string;
  wildcard: boolean;
}

/** Las cabeceras que manda supabase-js (lista de @supabase/supabase-js/cors) más las de un fetch simple. */
export const CORS_ALLOWED_HEADERS =
  "authorization, x-client-info, apikey, content-type, x-retry-count, traceparent, tracestate, baggage";
export const CORS_ALLOWED_METHODS = "POST, OPTIONS";
/** Firefox respeta 24 h; Chrome recorta a 2 h. */
export const CORS_MAX_AGE_SECONDS = 86400;

const LABEL = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?";
const HOST = `${LABEL}(?:\\.${LABEL})*`;
const RULE_PATTERN = new RegExp(`^(https?)://(\\*\\.)?(${HOST})(?::(\\d{1,5}))?/?$`);
const ORIGIN_PATTERN = new RegExp(`^(https?)://(${HOST})(?::(\\d{1,5}))?$`);
const SINGLE_LABEL = new RegExp(`^${LABEL}$`);

function normalizePort(scheme: string, port: string | undefined): string | null {
  if (port === undefined || port === "") return "";
  const value = Number(port);
  if (!Number.isInteger(value) || value < 1 || value > 65535) return null;
  if ((scheme === "https" && value === 443) || (scheme === "http" && value === 80)) return "";
  return String(value);
}

/** Lee ALLOWED_ORIGINS (separados por comas). Las entradas inválidas se ignoran. */
export function parseAllowedOrigins(raw: string | null | undefined): OriginRule[] {
  if (!raw) return [];
  const rules: OriginRule[] = [];
  for (const entry of raw.split(",")) {
    const match = RULE_PATTERN.exec(entry.trim().toLowerCase());
    if (!match) continue;
    const scheme = match[1] === "https" ? "https" : "http";
    const port = normalizePort(scheme, match[4]);
    if (port === null) continue;
    rules.push({ scheme, host: match[3] ?? "", port, wildcard: match[2] !== undefined });
  }
  return rules;
}

/** true si la cabecera Origin coincide con alguna regla. */
export function isOriginAllowed(origin: string | null | undefined, rules: readonly OriginRule[]): boolean {
  if (!origin) return false;
  const match = ORIGIN_PATTERN.exec(origin.toLowerCase());
  if (!match) return false;
  const scheme = match[1];
  const host = match[2] ?? "";
  const port = normalizePort(scheme ?? "", match[3]);
  if (port === null) return false;
  return rules.some((rule) => {
    if (rule.scheme !== scheme || rule.port !== port) return false;
    if (!rule.wildcard) return rule.host === host;
    const suffix = `.${rule.host}`;
    return host.endsWith(suffix) && SINGLE_LABEL.test(host.slice(0, -suffix.length));
  });
}

/**
 * Cabeceras CORS para la respuesta. `Vary: Origin` siempre (la respuesta depende del origen);
 * el resto solo si el origen está permitido.
 */
export function corsHeaders(
  origin: string | null | undefined,
  rules: readonly OriginRule[],
  { preflight }: { preflight: boolean },
): Record<string, string> {
  const headers: Record<string, string> = { Vary: "Origin" };
  if (!origin || !isOriginAllowed(origin, rules)) return headers;
  headers["Access-Control-Allow-Origin"] = origin;
  if (preflight) {
    headers["Access-Control-Allow-Methods"] = CORS_ALLOWED_METHODS;
    headers["Access-Control-Allow-Headers"] = CORS_ALLOWED_HEADERS;
    headers["Access-Control-Max-Age"] = String(CORS_MAX_AGE_SECONDS);
  } else {
    // La web lee Retry-After de un 429 para decir cuándo reintentar.
    headers["Access-Control-Expose-Headers"] = "Retry-After";
  }
  return headers;
}
