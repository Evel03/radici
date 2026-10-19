// Núcleo de i18n: funciones puras, sin DOM. Lo usan el navegador, los tests y el build (vite.config.ts).

export const LANGS = ["it", "es", "en"] as const;
export type Lang = (typeof LANGS)[number];
export const DEFAULT_LANG: Lang = "it";

/** Locale de Intl para cada idioma (moneda, fechas). */
export const LOCALES: Readonly<Record<Lang, string>> = { it: "it-IT", es: "es-ES", en: "en-IE" };

/** Claves con puntos ("request.quote.total") derivadas del JSON italiano: el compilador las verifica. */
type Leaves<T> = {
  [K in keyof T & string]: T[K] extends string ? K : `${K}.${Leaves<T[K]>}`;
}[keyof T & string];
export type MessageKey = Leaves<typeof import("./it.json")>;

export type Params = Readonly<Record<string, string | number>>;
export type Dict = Readonly<Record<string, string>>;

export interface I18n {
  readonly lang: Lang;
  readonly locale: string;
  /** Texto para una clave conocida en compilación. */
  t(key: MessageKey, params?: Params): string;
  /** Texto para una clave que viene del HTML (data-i18n). Si falta, devuelve la clave. */
  text(key: string, params?: Params): string;
  has(key: string): boolean;
}

export function isLang(value: unknown): value is Lang {
  return typeof value === "string" && (LANGS as readonly string[]).includes(value);
}

/** Aplana el JSON anidado a claves con puntos. Solo admite strings como hojas. */
export function flatten(value: unknown, prefix = "", out: Record<string, string> = {}): Record<string, string> {
  if (typeof value === "string") {
    out[prefix] = value;
    return out;
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`Valor de traducción no válido en "${prefix}"`);
  }
  for (const [key, child] of Object.entries(value)) {
    if (key === "default" && prefix === "") continue; // artefacto de los módulos JSON
    flatten(child, prefix ? `${prefix}.${key}` : key, out);
  }
  return out;
}

/** Reemplaza {nombre} por su valor. Los marcadores sin valor quedan como están. */
export function interpolate(template: string, params: Params): string {
  return template.replace(/\{(\w+)\}/g, (match, name: string) =>
    Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : match,
  );
}

/** Lista de marcadores {x} de un texto (para comparar idiomas en los tests). */
export function placeholders(template: string): string[] {
  return [...template.matchAll(/\{(\w+)\}/g)].map((m) => m[1] ?? "").sort();
}

/** "content:landing.metaTitle;aria-label:common.homeLink" → [["content", "..."], ["aria-label", "..."]] */
export function parseAttrSpec(spec: string): Array<[string, string]> {
  return spec
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const i = part.indexOf(":");
      if (i <= 0) throw new Error(`data-i18n-attr mal formado: "${spec}"`);
      return [part.slice(0, i).trim(), part.slice(i + 1).trim()] as [string, string];
    });
}

export function resolveLang(search: string, stored: string | null): Lang {
  const fromUrl = new URLSearchParams(search).get("lang")?.toLowerCase();
  if (isLang(fromUrl)) return fromUrl;
  if (isLang(stored)) return stored;
  return DEFAULT_LANG;
}

export function createI18n(lang: Lang, dict: Dict, globals: Params = {}): I18n {
  const text = (key: string, params?: Params): string => {
    const template = dict[key];
    if (template === undefined) return key;
    return interpolate(template, params ? { ...globals, ...params } : globals);
  };
  return {
    lang,
    locale: LOCALES[lang],
    t: text,
    text,
    has: (key) => dict[key] !== undefined,
  };
}
