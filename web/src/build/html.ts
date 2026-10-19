// Transformación del HTML en build y en dev (la llama el plugin de vite.config.ts).
// Funciones puras: se testean sin Vite.
//
// - <!-- partial:header --> se reemplaza por src/partials/header.html.
// - __BRAND_NAME__ se reemplaza por la marca configurada.
// - Los elementos con data-i18n / data-i18n-html / data-i18n-attr se rellenan con el italiano
//   de it.json: así la página tiene contenido sin JS y para SEO, sin duplicar textos en el HTML.
// - Se agregan noindex, canonical/og:url y el JSON-LD según la configuración.
import type { AppConfig } from "../config.ts";
import { parseAttrSpec, type I18n } from "../i18n/core.ts";

export interface RenderOptions {
  i18n: I18n;
  config: AppConfig;
  /** Ruta pública de la página: "/", "/richiesta/", "/privacy/". */
  pagePath: string;
  partials: Readonly<Record<string, string>>;
}

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const PARTIAL_RE = /<!--\s*partial:([\w-]+)\s*-->/g;
// Elemento vacío con data-i18n o data-i18n-html: <h1 class="x" data-i18n="clave"></h1>
const CONTENT_RE = /<([a-zA-Z][a-zA-Z0-9-]*)(\s(?:[^<>]*?\s)?data-i18n(-html)?="([^"]+)"[^<>]*)><\/\1>/g;
const CONTENT_ATTR_RE = /\sdata-i18n(?:-html)?="/g;
// Etiqueta de apertura con data-i18n-attr="attr:clave;attr2:clave2"
const ATTR_TAG_RE = /<([a-zA-Z][a-zA-Z0-9-]*)(\s(?:[^<>]*?\s)?data-i18n-attr="([^"]+)"[^<>]*?)(\s?\/?)>/g;

export function insertPartials(html: string, partials: Readonly<Record<string, string>>): string {
  return html.replace(PARTIAL_RE, (_match, name: string) => {
    const partial = partials[name];
    if (partial === undefined) throw new Error(`Parcial desconocido: ${name}`);
    return partial.trim();
  });
}

export function fillTranslations(html: string, i18n: I18n): string {
  const missing: string[] = [];
  const text = (key: string): string => {
    if (!i18n.has(key)) missing.push(key);
    return i18n.text(key);
  };

  const expected = html.match(CONTENT_ATTR_RE)?.length ?? 0;
  let filled = 0;
  let out = html.replace(CONTENT_RE, (_m, tag: string, attrs: string, isHtml: string | undefined, key: string) => {
    filled += 1;
    const value = isHtml ? text(key) : escapeHtml(text(key));
    return `<${tag}${attrs}>${value}</${tag}>`;
  });
  if (filled !== expected) {
    throw new Error(
      `Hay ${expected - filled} elemento(s) con data-i18n que no están vacíos: el texto debe venir solo del JSON.`,
    );
  }

  out = out.replace(ATTR_TAG_RE, (_m, tag: string, attrs: string, spec: string, close: string) => {
    let result = attrs;
    for (const [attr, key] of parseAttrSpec(spec)) {
      const existing = new RegExp(`\\s${attr.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}="[^"]*"`, "g");
      result = result.replace(existing, "") + ` ${attr}="${escapeHtml(text(key))}"`;
    }
    return `<${tag}${result}${close}>`;
  });

  if (missing.length > 0) throw new Error(`Faltan claves en it.json: ${[...new Set(missing)].join(", ")}`);
  return out;
}

export function buildJsonLd(config: AppConfig, i18n: I18n): Record<string, unknown> {
  const url = config.siteUrl ? `${config.siteUrl}/` : null;
  const areaServed = {
    "@type": "City",
    name: "Bergamo",
    containedInPlace: { "@type": "AdministrativeArea", name: "Lombardia" },
  };
  return {
    "@context": "https://schema.org",
    "@type": "LocalBusiness",
    ...(url ? { "@id": `${url}#business`, url } : {}),
    name: config.brandName,
    description: i18n.t("landing.metaDescription"),
    areaServed,
    knowsLanguage: ["it", "es", "en"],
    currenciesAccepted: "EUR",
    makesOffer: {
      "@type": "Offer",
      itemOffered: {
        "@type": "FoodService",
        name: i18n.t("landing.hero.eyebrow"),
        description: i18n.t("landing.hero.lead"),
        areaServed,
      },
    },
  };
}

function headExtras(opts: RenderOptions): string[] {
  const { config, pagePath, i18n } = opts;
  const tags: string[] = [];
  if (config.noindex) tags.push('<meta name="robots" content="noindex, nofollow">');
  if (config.siteUrl) {
    const url = escapeHtml(`${config.siteUrl}${pagePath}`);
    tags.push(`<link rel="canonical" href="${url}">`, `<meta property="og:url" content="${url}">`);
  }
  if (pagePath === "/") {
    // "<" escapado para que ningún texto pueda cerrar el <script>.
    const json = JSON.stringify(buildJsonLd(config, i18n)).replace(/</g, "\\u003c");
    tags.push(`<script type="application/ld+json">${json}</script>`);
  }
  return tags;
}

export function renderPage(html: string, opts: RenderOptions): string {
  let out = insertPartials(html, opts.partials);
  out = out.replaceAll("__BRAND_NAME__", escapeHtml(opts.config.brandName));
  out = fillTranslations(out, opts.i18n);
  const extras = headExtras(opts);
  return out.replace(/\n([ \t]*)<\/head>/, (_m, indent: string) =>
    `\n${extras.map((tag) => `${indent}  ${tag}\n`).join("")}${indent}</head>`,
  );
}

/** "/richiesta/index.html" → "/richiesta/" */
export function pagePathFromHtmlPath(htmlPath: string): string {
  const path = htmlPath.replace(/\\/g, "/").replace(/index\.html$/, "");
  return path.startsWith("/") ? path : `/${path}`;
}
