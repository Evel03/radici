import { describe, expect, it } from "vitest";
import indexHtml from "../../index.html?raw";
import privacyHtml from "../../privacy/index.html?raw";
import requestHtml from "../../richiesta/index.html?raw";
import type { AppConfig } from "../config.ts";
import { createI18n, flatten } from "../i18n/core.ts";
import itJson from "../i18n/it.json";
import { createSiteI18n } from "../i18n/site.ts";
import footer from "../partials/footer.html?raw";
import header from "../partials/header.html?raw";
import { buildJsonLd, fillTranslations, pagePathFromHtmlPath, renderPage } from "./html.ts";

const baseConfig: AppConfig = { whatsappNumber: null, brandName: "Mestolo", noindex: true, siteUrl: null };
const i18n = createSiteI18n("it", flatten(itJson), "Mestolo");
const partials = { header, footer };

describe("fillTranslations", () => {
  const dict = createI18n("it", { a: "Ciao <tu> & \"voi\"", b: "<strong>forte</strong>", c: "Descrizione" });

  it("rellena texto escapado, HTML de confianza y atributos", () => {
    const html = '<h1 class="x" data-i18n="a"></h1><div data-i18n-html="b"></div><meta name="d" content="vecchio" data-i18n-attr="content:c" />';
    expect(fillTranslations(html, dict)).toBe(
      '<h1 class="x" data-i18n="a">Ciao &lt;tu&gt; &amp; &quot;voi&quot;</h1><div data-i18n-html="b"><strong>forte</strong></div><meta name="d" data-i18n-attr="content:c" content="Descrizione" />',
    );
  });

  it("falla si un elemento traducible trae texto propio", () => {
    expect(() => fillTranslations('<p data-i18n="a">testo</p>', dict)).toThrow(/no están vacíos/);
  });

  it("falla si falta una clave", () => {
    expect(() => fillTranslations('<p data-i18n="zzz"></p>', dict)).toThrow(/zzz/);
  });
});

describe("renderPage con las páginas reales", () => {
  const pages = [
    ["/", indexHtml],
    ["/richiesta/", requestHtml],
    ["/privacy/", privacyHtml],
  ] as const;

  for (const [path, html] of pages) {
    it(`${path}: queda en italiano, con parciales y sin marcadores pendientes`, () => {
      const out = renderPage(html, { i18n, config: baseConfig, pagePath: path, partials });
      expect(out).not.toMatch(/<!--\s*partial:/);
      expect(out).not.toContain("__BRAND_NAME__");
      expect(out).toMatch(/<title[^>]*>[^<]*Mestolo[^<]*<\/title>/);
      expect(out).toContain('<meta name="robots" content="noindex, nofollow">');
      expect(out).toMatch(/<meta name="description"[^>]* content="[^"]{40,}"/);
      // Ningún {marcador} sin resolver en el contenido visible.
      expect(out.replace(/<script[\s\S]*?<\/script>/g, "")).not.toMatch(/\{\w+\}/);
    });
  }

  it("la landing muestra el ejemplo calculado con el motor (vector 1)", () => {
    const out = renderPage(indexHtml, { i18n, config: baseConfig, pagePath: "/", partials });
    expect(out).toMatch(/78,00\s€/);
    expect(out).toMatch(/63,00\s€/);
    expect(out).toMatch(/141,00\s€/);
  });

  it("sin VITE_NOINDEX=true no agrega noindex; con VITE_SITE_URL agrega canonical y og:url", () => {
    const config = { ...baseConfig, noindex: false, siteUrl: "https://example.test" };
    const out = renderPage(requestHtml, { i18n, config, pagePath: "/richiesta/", partials });
    expect(out).not.toContain('name="robots"');
    expect(out).toContain('<link rel="canonical" href="https://example.test/richiesta/">');
    expect(out).toContain('<meta property="og:url" content="https://example.test/richiesta/">');
  });

  it("sin JS el formulario no se puede enviar (los datos irían en la URL)", () => {
    expect(requestHtml).toMatch(/<button id="submit"[^>]*type="submit"[^>]*\sdisabled>/);
    expect(requestHtml).toMatch(/<form id="request-form"[^>]*novalidate>/);
  });

  it("solo la landing lleva JSON-LD", () => {
    const landing = renderPage(indexHtml, { i18n, config: baseConfig, pagePath: "/", partials });
    const privacy = renderPage(privacyHtml, { i18n, config: baseConfig, pagePath: "/privacy/", partials });
    expect(landing).toContain('<script type="application/ld+json">');
    expect(privacy).not.toContain("application/ld+json");
  });
});

describe("JSON-LD", () => {
  it("LocalBusiness con FoodService, areaServed Bergamo y sin dirección", () => {
    const data = buildJsonLd({ ...baseConfig, siteUrl: "https://example.test" }, i18n);
    expect(data["@type"]).toBe("LocalBusiness");
    expect(data["name"]).toBe("Mestolo");
    expect(data["url"]).toBe("https://example.test/");
    expect(JSON.stringify(data["areaServed"])).toContain("Bergamo");
    expect(JSON.stringify(data["makesOffer"])).toContain("FoodService");
    expect(data).not.toHaveProperty("address");
  });
});

it("pagePathFromHtmlPath", () => {
  expect(pagePathFromHtmlPath("/index.html")).toBe("/");
  expect(pagePathFromHtmlPath("/richiesta/index.html")).toBe("/richiesta/");
  expect(pagePathFromHtmlPath("privacy\\index.html")).toBe("/privacy/");
});
