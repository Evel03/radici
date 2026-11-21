// Configuración de Vite (dev, build, preview) y Vitest.
// La lógica del HTML vive en src/build/html.ts (pura y testeada); acá solo se conecta con Vite.
import { existsSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type { Connect, Plugin } from "vite";
import { defineConfig } from "vitest/config";
import { headersFor, parseHeadersFile, renderHeadersFile } from "./src/build/headers.ts";
import { pagePathFromHtmlPath, renderPage } from "./src/build/html.ts";
import { notFoundCandidates } from "./src/build/pages.ts";
import { isTurnstileTestKey, resolveConfig, type AppConfig } from "./src/config.ts";
import { flatten } from "./src/i18n/core.ts";
import { createSiteI18n } from "./src/i18n/site.ts";

const root = fileURLToPath(new URL(".", import.meta.url));
// Motor de presupuesto y contrato del pedido, compartidos (solo lectura): supabase/functions/_shared/
const sharedDir = resolve(root, "../supabase/functions/_shared");
// prenotazione: la página de la clienta (su reserva y el menú de cada semana; el token va en el fragmento).
const PAGES = ["richiesta", "privacy", "prenotazione"];

/** /richiesta → /richiesta/ (en dev y preview; el hosting estático debería hacer lo mismo). */
const trailingSlash: Connect.NextHandleFunction = (req, res, next) => {
  const [path = "", query] = (req.url ?? "").split("?");
  const page = path.replace(/^\//, "");
  if (PAGES.includes(page)) {
    res.statusCode = 301;
    res.setHeader("Location", `/${page}/${query ? `?${query}` : ""}`);
    res.end();
    return;
  }
  next();
};

/** Aplica dist/_headers como Cloudflare Pages: `npm run preview` sirve la CSP real (con su cabecera). */
function pagesHeaders(outDir: string): Connect.NextHandleFunction {
  const file = resolve(outDir, "_headers");
  const rules = existsSync(file) ? parseHeadersFile(readFileSync(file, "utf8")) : [];
  return (req, res, next) => {
    const path = (req.url ?? "/").split("?")[0] ?? "/";
    // Con el host del pedido: las reglas https://…pages.dev/* solo valen ahí.
    for (const [name, value] of headersFor(rules, path, req.headers.host)) res.setHeader(name, value);
    next();
  };
}

/**
 * Lo que Vite no sirvió, como Cloudflare Pages (src/build/pages.ts): /carpeta → /carpeta/ si tiene
 * index.html (p. ej. /gestione), y si no existe, el 404.html más cercano con estado 404 y sin caché.
 * Va después de los archivos estáticos y del fallback de HTML de Vite (que reescribe /x/ → /x/index.html).
 */
function pagesNotFound(outDir: string): Connect.NextHandleFunction {
  const fileIn = (path: string): string | null => {
    const full = resolve(outDir, `.${path}`);
    return full.startsWith(outDir + sep) && existsSync(full) && statSync(full).isFile() ? full : null;
  };
  return (req, res, next) => {
    if (req.method !== "GET" && req.method !== "HEAD") return next();
    const [rawPath = "/", query] = (req.url ?? "/").split("?");
    let path: string;
    try {
      path = decodeURIComponent(rawPath);
    } catch {
      return next();
    }
    if (fileIn(path)) return next();
    if (!path.endsWith("/") && fileIn(`${path}/index.html`)) {
      res.statusCode = 308;
      res.setHeader("Location", `${rawPath}/${query ? `?${query}` : ""}`);
      res.end();
      return;
    }
    const page = notFoundCandidates(path).map(fileIn).find((file) => file !== null);
    if (!page) return next();
    res.statusCode = 404;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.setHeader("Cache-Control", "no-store");
    res.end(req.method === "HEAD" ? undefined : readFileSync(page));
  };
}

function radiciHtml(): Plugin {
  let appConfig: AppConfig;
  let production = false;
  let outDir = resolve(root, "dist");
  const read = (file: string): string => readFileSync(resolve(root, file), "utf8");

  return {
    name: "radici-html",
    configResolved(resolved) {
      appConfig = resolveConfig(resolved.env);
      production = resolved.mode === "production";
      outDir = resolve(resolved.root, resolved.build.outDir);
    },
    transformIndexHtml: {
      order: "pre",
      handler(html, ctx) {
        // Se lee en cada transformación: en dev los cambios de textos se ven al recargar.
        const i18n = createSiteI18n("it", flatten(JSON.parse(read("src/i18n/it.json"))), appConfig.brandName);
        return renderPage(html, {
          i18n,
          config: appConfig,
          pagePath: pagePathFromHtmlPath(ctx.path),
          partials: { header: read("src/partials/header.html"), footer: read("src/partials/footer.html") },
        });
      },
    },
    handleHotUpdate({ file, server }) {
      // Los parciales y el italiano del HTML no son módulos: recarga completa.
      if (/[\\/]src[\\/](partials[\\/].+\.html|i18n[\\/]it\.json)$/.test(file)) {
        server.ws.send({ type: "full-reload" });
      }
    },
    configureServer(server) {
      server.middlewares.use(trailingSlash);
    },
    configurePreviewServer(server) {
      server.middlewares.use(trailingSlash);
      server.middlewares.use(pagesHeaders(outDir));
      // Función devuelta: Vite la corre después de sus middlewares de archivos y de HTML.
      return () => {
        server.middlewares.use(pagesNotFound(outDir));
      };
    },
    writeBundle() {
      // Marcadores del origen de Supabase en _headers (connect-src de /richiesta/; sin él, el formulario no puede enviar).
      const headers = resolve(outDir, "_headers");
      if (existsSync(headers)) {
        writeFileSync(headers, renderHeadersFile(readFileSync(headers, "utf8"), appConfig.supabaseUrl));
      }
      if (!appConfig.supabaseUrl || !appConfig.turnstileSiteKey) {
        this.warn("Faltan VITE_SUPABASE_URL o VITE_TURNSTILE_SITE_KEY: el formulario de /richiesta/ no podrá enviar pedidos.");
      } else if (production && isTurnstileTestKey(appConfig.turnstileSiteKey)) {
        this.warn("VITE_TURNSTILE_SITE_KEY es una sitekey de prueba: en producción el servidor rechaza su token.");
      }

      const robots = resolve(outDir, "robots.txt");
      const sitemap = resolve(outDir, "sitemap.xml");
      const url = appConfig.siteUrl;
      if (existsSync(robots)) {
        const text = readFileSync(robots, "utf8");
        writeFileSync(robots, url ? text.replaceAll("__SITE_URL__", url) : text.replace(/^Sitemap:.*\n?/m, ""));
      }
      if (existsSync(sitemap)) {
        if (url) {
          writeFileSync(sitemap, readFileSync(sitemap, "utf8").replaceAll("__SITE_URL__", url));
        } else {
          rmSync(sitemap);
        }
      }
      if (!url) {
        this.warn(
          "VITE_SITE_URL no está definida: sin canonical, sin sitemap.xml y sin og:image (los links compartidos no muestran la imagen).",
        );
      }
    },
  };
}

export default defineConfig({
  appType: "mpa",
  plugins: [radiciHtml()],
  server: {
    fs: {
      // La web (.) y el motor compartido, que vive fuera de web/.
      allow: [root, sharedDir],
    },
  },
  build: {
    // Navegadores internos de WhatsApp en teléfonos no tan nuevos.
    target: ["es2020", "safari14", "chrome87", "firefox78", "edge88"],
    // Sin polyfill: donde no hay modulepreload la página funciona igual, solo sin precarga.
    modulePreload: { polyfill: false },
    // Los textos por idioma (src/i18n/*.json?url, los pide i18n/load.ts con fetch) siempre como archivo:
    // un data: URL no pasaría connect-src 'self' de la CSP.
    assetsInlineLimit: (file) => (file.endsWith(".json") ? false : undefined),
    rolldownOptions: {
      input: {
        main: resolve(root, "index.html"),
        richiesta: resolve(root, "richiesta/index.html"),
        privacy: resolve(root, "privacy/index.html"),
        prenotazione: resolve(root, "prenotazione/index.html"),
        // dist/404.html: con él Pages responde 404 a lo que no existe (src/build/pages.ts).
        notFound: resolve(root, "404.html"),
      },
    },
  },
  test: {
    include: ["src/**/*.test.ts"],
    environment: "node",
  },
});
