// Transformación del HTML en build y en dev (la llama el plugin de vite.config.ts).
// Funciones puras: se testean sin Vite.
//
// - <!-- partial:header --> se reemplaza por src/partials/header.html.
// - __BRAND_NAME__ se reemplaza por la marca configurada.
// - Los elementos con data-i18n / data-i18n-html / data-i18n-attr se rellenan con el italiano
//   de it.json: así la página tiene contenido sin JS y para SEO, sin duplicar textos en el HTML.
// - Se agregan noindex, canonical/og:url, la imagen para compartir (og:image, con URL absoluta) y el
//   JSON-LD según la configuración. La 404 nunca se indexa ni declara una URL propia. Las páginas privadas
//   (la de la clienta, que se abre con su link) nunca se indexan ni declaran canonical, pero conservan la
//   imagen: el link llega por WhatsApp y la vista previa la muestra.
import type { AppConfig } from "../config.ts";
import { parseAttrSpec, type I18n } from "../i18n/core.ts";
import { OG_IMAGE } from "./images.ts";

export interface RenderOptions {
  i18n: I18n;
  config: AppConfig;
  /** Ruta pública de la página: "/", "/richiesta/", "/privacy/", "/prenotazione/", "/accesso/"… o NOT_FOUND_PATH. */
  pagePath: string;
  partials: Readonly<Record<string, string>>;
}

/** La página 404 (dist/404.html): Cloudflare Pages la sirve con estado 404 en cualquier ruta que no existe. */
export const NOT_FOUND_PATH = "/404.html";

/**
 * Páginas que no son para visitar: /prenotazione/ se abre solo con un link personal (#t=…), /captcha/ la abre la app
 * (en un marco o una WebView) y /accesso/, el link de un email de Auth (#token_hash=…). Nunca se indexan ni declaran
 * canonical.
 */
export const PRIVATE_PATHS: readonly string[] = ["/prenotazione/", "/captcha/", "/accesso/"];

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
    ...(url ? { "@id": `${url}#business`, url, image: `${config.siteUrl}${OG_IMAGE.path}` } : {}),
    name: config.brandName,
    description: i18n.t("landing.metaDescription"),
    // Servicio a domicilio, sin local: solo ciudad, provincia y país. Nunca calle ni código postal.
    address: { "@type": "PostalAddress", addressLocality: "Bergamo", addressRegion: "BG", addressCountry: "IT" },
    areaServed,
    knowsLanguage: ["it", "es", "en"],
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
  const notFound = pagePath === NOT_FOUND_PATH;
  const privatePage = PRIVATE_PATHS.includes(pagePath);
  const tags: string[] = [];
  if (config.noindex || privatePage) tags.push('<meta name="robots" content="noindex, nofollow">');
  else if (notFound) tags.push('<meta name="robots" content="noindex">');
  if (notFound) return tags;

  if (config.siteUrl) {
    const url = escapeHtml(`${config.siteUrl}${pagePath}`);
    // Una página privada no declara una URL propia: la suya es la del link, con el token.
    if (!privatePage) tags.push(`<link rel="canonical" href="${url}">`, `<meta property="og:url" content="${url}">`);
    tags.push(
      // Las vistas previas (WhatsApp, Facebook…) piden la imagen con URL absoluta.
      `<meta property="og:image" content="${escapeHtml(`${config.siteUrl}${OG_IMAGE.path}`)}">`,
      `<meta property="og:image:type" content="${OG_IMAGE.type}">`,
      `<meta property="og:image:width" content="${OG_IMAGE.width}">`,
      `<meta property="og:image:height" content="${OG_IMAGE.height}">`,
      `<meta property="og:image:alt" content="${escapeHtml(i18n.t("common.ogImageAlt"))}">`,
      '<meta name="twitter:card" content="summary_large_image">',
    );
  } else {
    // Sin VITE_SITE_URL no hay URL absoluta para la imagen: tarjeta sin imagen grande (el build lo avisa).
    tags.push('<meta name="twitter:card" content="summary">');
  }
  if (pagePath === "/") {
    // "<" escapado para que ningún texto pueda cerrar el <script>.
    const json = JSON.stringify(buildJsonLd(config, i18n)).replace(/</g, "\\u003c");
    tags.push(`<script type="application/ld+json">${json}</script>`);
  }
  return tags;
}

/**
 * Los links de idioma del encabezado sin href (shell.ts se los pone con el fragmento actual). En una página
 * privada el fragmento es el token del link (#t=…) y un href "?lang=xx" lo descarta: si se tocara antes de que
 * cargue el JS, o se abriera en otra pestaña, la página diría que el link no funciona. Esa página no anda sin JS.
 */
export function withoutLangHrefs(html: string): string {
  return html.replace(/<a href="\?lang=[a-z]{2}"(?=[^<>]*\sdata-lang=")/g, "<a");
}

export function renderPage(html: string, opts: RenderOptions): string {
  let out = insertPartials(html, opts.partials);
  out = out.replaceAll("__BRAND_NAME__", escapeHtml(opts.config.brandName));
  out = fillTranslations(out, opts.i18n);
  if (PRIVATE_PATHS.includes(opts.pagePath)) out = withoutLangHrefs(out);
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
