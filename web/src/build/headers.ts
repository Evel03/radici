// Archivo _headers de Cloudflare Pages: el build completa el origen de Supabase y `vite preview`
// lo aplica igual que Pages, para probar la CSP real en local. Funciones puras (se testean sin Vite).
// Semántica (docs de Pages, act. 08/2026, y el asset-server de workers-sdk): un pedido toma las
// cabeceras de todas las reglas que coinciden, en el orden del archivo; en cada regla primero se
// quitan las marcadas con "!" y después se ponen las suyas; si una cabecera ya la puso una regla
// anterior, el valor se agrega separado por coma.

/** Marcador de public/_headers que el build reemplaza por el origen de VITE_SUPABASE_URL. */
export const SUPABASE_ORIGIN_TOKEN = "__SUPABASE_ORIGIN__";
/** El mismo origen con wss:// (o ws:// en local), para Realtime (p. ej. la CSP de /gestione/). */
export const SUPABASE_WS_ORIGIN_TOKEN = "__SUPABASE_WS_ORIGIN__";

export interface HeaderRule {
  /** Ruta con un "*" opcional y marcadores ":nombre" (las URL absolutas no se usan acá). */
  pattern: string;
  set: Array<[string, string]>;
  /** Nombres en minúsculas. */
  unset: string[];
}

export function parseHeadersFile(text: string): HeaderRule[] {
  const rules: HeaderRule[] = [];
  let current: HeaderRule | null = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    if (!/^\s/.test(raw)) {
      current = { pattern: line, set: [], unset: [] };
      rules.push(current);
      continue;
    }
    if (!current) throw new Error(`_headers: cabecera fuera de una regla: "${line}"`);
    if (line.startsWith("!")) {
      current.unset.push(line.slice(1).trim().toLowerCase());
      continue;
    }
    const colon = line.indexOf(":");
    if (colon <= 0) throw new Error(`_headers: línea mal formada: "${line}"`);
    current.set.push([line.slice(0, colon).trim(), line.slice(colon + 1).trim()]);
  }
  return rules;
}

function patternToRegExp(pattern: string): RegExp {
  const source = pattern
    .split(/(\*|:\w+)/)
    .map((part) => {
      if (part === "*") return "(?<splat>.*)";
      if (/^:\w+$/.test(part)) return `(?<${part.slice(1)}>[^/]+)`;
      return part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    })
    .join("");
  return new RegExp(`^${source}$`);
}

/** Cabeceras para una ruta (sin query), con el nombre tal como está escrito en el archivo. */
export function headersFor(rules: readonly HeaderRule[], pathname: string): Map<string, string> {
  const out = new Map<string, { name: string; value: string }>();
  for (const rule of rules) {
    const match = patternToRegExp(rule.pattern).exec(pathname);
    if (!match) continue;
    for (const name of rule.unset) out.delete(name);
    for (const [name, rawValue] of rule.set) {
      // Los marcadores (:slug, :splat) se pueden reusar en el valor.
      const value = rawValue.replace(/:(\w+)/g, (all, key: string) => match.groups?.[key] ?? all);
      const key = name.toLowerCase();
      const previous = out.get(key);
      out.set(key, { name: previous?.name ?? name, value: previous ? `${previous.value}, ${value}` : value });
    }
  }
  return new Map([...out.values()].map(({ name, value }) => [name, value]));
}

/**
 * Completa los marcadores de Supabase con su origen (https y wss), o los quita si no hay
 * (la CSP queda en 'self'). Solo acepta un origen limpio: nada de rutas, espacios ni ";" que
 * puedan agregar directivas.
 */
export function renderHeadersFile(text: string, supabaseOrigin: string | null): string {
  if (supabaseOrigin === null) {
    let out = text;
    for (const token of [SUPABASE_WS_ORIGIN_TOKEN, SUPABASE_ORIGIN_TOKEN]) {
      out = out.replaceAll(` ${token}`, "").replaceAll(token, "");
    }
    return out;
  }
  if (!/^https?:\/\/[a-z0-9.-]+(:\d+)?$/i.test(supabaseOrigin)) {
    throw new Error(`Origen de Supabase no válido para la CSP: ${supabaseOrigin}`);
  }
  return text
    .replaceAll(SUPABASE_WS_ORIGIN_TOKEN, supabaseOrigin.replace(/^http/i, "ws"))
    .replaceAll(SUPABASE_ORIGIN_TOKEN, supabaseOrigin);
}

/** "default-src 'self'; frame-src x" → { "default-src": ["'self'"], "frame-src": ["x"] } */
export function cspDirectives(policy: string): Map<string, string[]> {
  const directives = new Map<string, string[]>();
  for (const part of policy.split(";")) {
    const [name, ...sources] = part.trim().split(/\s+/);
    if (name) directives.set(name.toLowerCase(), sources);
  }
  return directives;
}
