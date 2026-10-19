// Configuración de Vite (dev, build, preview) y Vitest.
// La lógica del HTML vive en src/build/html.ts (pura y testeada); acá solo se conecta con Vite.
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { Connect, Plugin } from "vite";
import { defineConfig } from "vitest/config";
import { pagePathFromHtmlPath, renderPage } from "./src/build/html.ts";
import { resolveConfig, type AppConfig } from "./src/config.ts";
import { flatten } from "./src/i18n/core.ts";
import { createSiteI18n } from "./src/i18n/site.ts";

const root = fileURLToPath(new URL(".", import.meta.url));
// Motor de presupuesto compartido (solo lectura): supabase/functions/_shared/quote.ts
const sharedDir = resolve(root, "../supabase/functions/_shared");
const PAGES = ["richiesta", "privacy"];

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

function mestoloHtml(): Plugin {
  let appConfig: AppConfig;
  let outDir = resolve(root, "dist");
  const read = (file: string): string => readFileSync(resolve(root, file), "utf8");

  return {
    name: "mestolo-html",
    configResolved(resolved) {
      appConfig = resolveConfig(resolved.env);
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
    },
    writeBundle() {
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
          this.warn("VITE_SITE_URL no está definida: sitemap.xml no se publica.");
        }
      }
    },
  };
}

export default defineConfig({
  appType: "mpa",
  plugins: [mestoloHtml()],
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
    rolldownOptions: {
      input: {
        main: resolve(root, "index.html"),
        richiesta: resolve(root, "richiesta/index.html"),
        privacy: resolve(root, "privacy/index.html"),
      },
    },
  },
  test: {
    include: ["src/**/*.test.ts"],
    environment: "node",
  },
});
