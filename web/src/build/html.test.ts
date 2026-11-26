import { describe, expect, it } from "vitest";
import notFoundHtml from "../../404.html?raw";
import accessHtml from "../../accesso/index.html?raw";
import captchaHtml from "../../captcha/index.html?raw";
import indexHtml from "../../index.html?raw";
import reservationHtml from "../../prenotazione/index.html?raw";
import privacyHtml from "../../privacy/index.html?raw";
import requestHtml from "../../richiesta/index.html?raw";
import type { AppConfig } from "../config.ts";
import { createI18n, flatten } from "../i18n/core.ts";
import enJson from "../i18n/en.json";
import esJson from "../i18n/es.json";
import itJson from "../i18n/it.json";
import { createSiteI18n } from "../i18n/site.ts";
import footer from "../partials/footer.html?raw";
import header from "../partials/header.html?raw";
import { turnstileView } from "../request/turnstile.ts";
import { NOT_FOUND_PATH, buildJsonLd, fillTranslations, pagePathFromHtmlPath, renderPage, withoutLangHrefs } from "./html.ts";
import { OG_IMAGE } from "./images.ts";

const baseConfig: AppConfig = {
  brandName: "Radici",
  noindex: true,
  siteUrl: null,
  supabaseUrl: null,
  supabasePublishableKey: null,
  turnstileSiteKey: null,
  turnstileAuthSiteKey: null,
};
const i18n = createSiteI18n("it", flatten(itJson), "Radici");
const partials = { header, footer };
const dictFor = (lang: "it" | "es" | "en") => ({ it: itJson, es: esJson, en: enJson })[lang];

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
    ["/prenotazione/", reservationHtml],
    ["/captcha/", captchaHtml],
    ["/accesso/", accessHtml],
  ] as const;

  for (const [path, html] of pages) {
    it(`${path}: queda en italiano, con parciales y sin marcadores pendientes`, () => {
      const out = renderPage(html, { i18n, config: baseConfig, pagePath: path, partials });
      expect(out).not.toMatch(/<!--\s*partial:/);
      expect(out).not.toContain("__BRAND_NAME__");
      expect(out).toMatch(/<title[^>]*>[^<]*Radici[^<]*<\/title>/);
      expect(out).toContain('<meta name="robots" content="noindex, nofollow">');
      expect(out).toMatch(/<meta name="description"[^>]* content="[^"]{40,}"/);
      // Ningún {marcador} sin resolver en el contenido visible.
      expect(out.replace(/<script[\s\S]*?<\/script>/g, "")).not.toMatch(/\{\w+\}/);
    });
  }

  it("la landing no muestra ningún precio: «Cómo se paga» es un presupuesto a medida", () => {
    const out = renderPage(indexHtml, { i18n, config: baseConfig, pagePath: "/", partials });
    // Ni importes ni tarifas en ningún lado (cuerpo, metas, JSON-LD, Open Graph).
    expect(out).not.toMatch(/€|&euro;|EUR|\d+[.,]\d{2}\s?(€|euro)/i);
    expect(out).toContain("Un preventivo su misura, sempre chiaro. Nessun rinnovo automatico, nessun costo nascosto.");
    const start = out.indexOf('<section id="prices"');
    const prices = out.slice(start, out.indexOf("</section>", start));
    expect(prices).toContain('<h3 class="card__title" data-i18n="landing.pricing.serviceTitle">Un preventivo su misura</h3>');
    expect(prices).toContain("Evelyn lo prepara per la tua famiglia in base alle persone");
    expect(prices).not.toContain("card--example");
  });

  it("la tarjeta de «Cómo se paga» invita a pedir el presupuesto y apunta al formulario", () => {
    const out = renderPage(indexHtml, { i18n, config: baseConfig, pagePath: "/", partials });
    const card = /<article class="card card--cta">([\s\S]*?)<\/article>/.exec(out)?.[1] ?? "";
    expect(card).toContain("Quanto costerebbe per te?");
    expect(card).toContain("Raccontaci cosa ti serve e Evelyn ti prepara il preventivo.");
    expect(card).toMatch(/<a class="link-arrow" href="\/richiesta\/"[^>]*>Chiedi il tuo preventivo<\/a>/);
    // Sin la compra ni cifras: es solo la invitación.
    expect(card.replace(/data-i18n="[^"]*"/g, "")).not.toMatch(/spesa|\b\d+\b|€/);
  });

  it("el JSON-LD no implica tarifa (sin moneda ni precio) y las descripciones no prometen una estimación", () => {
    for (const lang of ["it", "es", "en"] as const) {
      const text = createSiteI18n(lang, flatten(dictFor(lang)), "Radici");
      const ld = JSON.stringify(buildJsonLd({ ...baseConfig, siteUrl: "https://radicicucina.app" }, text));
      expect(ld, lang).not.toMatch(/currenciesAccepted|priceRange|price|EUR|€/i);
      expect(text.t("landing.metaDescription"), lang).not.toMatch(/€|stima|estimaci|estimate|calcul|calcol/i);
      expect(text.t("request.metaDescription"), lang).not.toMatch(/€|stima|estimaci|estimate|calcul|calcol/i);
    }
  });

  it("la portada dice que la compra la hace el cliente, con la lista de Evelyn, y no la promete en ningún lado", () => {
    const out = renderPage(indexHtml, { i18n, config: baseConfig, pagePath: "/", partials });
    const start = out.indexOf('<section id="prices"');
    const prices = out.slice(start, out.indexOf("</section>", start));
    expect(prices).toMatch(/<h3 class="card__title" data-i18n="landing\.pricing\.shoppingTitle">La spesa la fai tu<\/h3>/);
    expect(prices).toContain("Prima di ogni sessione Evelyn ti manda la lista degli ingredienti, con le quantità.");
    expect(out).toContain("La spesa la fai tu: prima di ogni sessione Evelyn ti manda la lista degli ingredienti, con le quantità.");
    expect(out).not.toMatch(/scontrin|spesa stimata|fa la spesa|compra tutto|niente spesa/i);
  });

  it("el recuadro «Cómo sigue» del formulario: el resumen de lo que pide, los tres pasos y la compra, sin precios", () => {
    const next = /<aside id="next"[\s\S]*?<\/aside>/.exec(requestHtml)?.[0] ?? "";
    expect(next).toContain('id="next-summary"');
    expect(next).not.toMatch(/q-total|q-weekly|q-savings|q-manual|groceries/);
    expect((next.match(/<li data-i18n="request\.next\.step\d">/g) ?? []).length).toBe(3);
    const out = renderPage(requestHtml, { i18n, config: baseConfig, pagePath: "/richiesta/", partials });
    expect(out).toContain("Come prosegue");
    expect(out).toContain("Invii la richiesta e ricevi un&#39;email di conferma.");
    expect(out).toContain("Evelyn ti prepara un preventivo su misura e te lo manda per email o WhatsApp.");
    expect(out).toContain("Lo rivedi e, se ti convince, lo accetti.");
    expect(out).toContain("La spesa la fai tu, con la lista che ti manda Evelyn.");
    // Ningún precio en todo el formulario ni en la pantalla de gracias.
    expect(out).not.toMatch(/€|&euro;|EUR|\d+[.,]\d{2}|prezzo|stima|risparmi/i);
    expect(out).not.toMatch(/scontrin|spesa stimata|spesa più leggera/i);
  });

  it("las frases de los recuadros de la portada se leen: lista con nombre, sin aria-hidden encima", () => {
    const out = renderPage(indexHtml, { i18n, config: baseConfig, pagePath: "/", partials });
    const start = out.indexOf('<section class="hero"');
    const hero = out.slice(start, out.indexOf("</section>", start));
    // aria-hidden solo puede ir en la foto: en un contenedor ocultaría también las frases.
    for (const [tag] of hero.matchAll(/<\w+[^>]*\saria-hidden="true"[^>]*>/g)) {
      expect(tag).toMatch(/^<figure class="photo hero__photo"/);
    }
    expect(hero).toMatch(/<ul class="hero__labels"[^>]*\saria-label="[^"]+">/);
    const items = [...hero.matchAll(/<li class="fridge-label">([\s\S]*?)<\/li>/g)].map((m) => m[1] ?? "");
    expect(items).toHaveLength(3);
    for (const item of items) {
      expect(item).toMatch(/class="fridge-label__title"[^>]*>[^<]+<[\s\S]*class="fridge-label__text"[^>]*>[^<]+</);
    }
  });

  it("fotos de la portada: las de contenido con texto alternativo; la decorativa, alt vacío y oculta", () => {
    const out = renderPage(indexHtml, { i18n, config: baseConfig, pagePath: "/", partials });
    const photos = [...out.matchAll(/<figure([^>]*)>\s*<img([^>]*)>/g)].map(([, figure = "", img = ""]) => ({
      name: /\ssrc="\/src\/images\/([\w-]+)\.jpg"/.exec(img)?.[1],
      alt: /\salt="([^"]*)"/.exec(img)?.[1],
      hidden: figure.includes('aria-hidden="true"'),
    }));
    // Cada <img> va en una lámina, y una foto nueva obliga a decidir si es contenido o decorativa.
    expect(out.match(/<img\b/g)).toHaveLength(photos.length);
    expect(photos.map((photo) => photo.name)).toEqual(["cocina", "delantal", "menu", "tarjeta"]);
    for (const { name, alt, hidden } of photos) {
      // La tarjeta con el logotipo junto al CTA final solo repite la marca de la cabecera.
      const decorative = name === "tarjeta";
      expect(hidden, name).toBe(decorative);
      if (decorative) expect(alt, name).toBe("");
      else expect(alt?.trim(), name).toBeTruthy();
    }
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
    expect(requestHtml).not.toMatch(/<form[^>]*\saction=/);
  });

  it("formulario: email obligatorio, casilla de WhatsApp junto al teléfono y lugar para Turnstile", () => {
    expect(requestHtml).toMatch(/<input[^>]*id="email"[^>]*\srequired/);
    const phoneField = requestHtml.slice(requestHtml.indexOf('id="phone"'), requestHtml.indexOf('for="email"'));
    expect(phoneField).toContain('id="whatsappOptIn"');
    expect(requestHtml).toContain('<div id="turnstile-widget"');
    // Un elemento con id="turnstile" (o name en form/img/iframe) aparece como window.turnstile y tapa la
    // API de Cloudflare: el script no carga ("Turnstile already has been loaded") y render no existe.
    for (const html of [indexHtml, requestHtml, privacyHtml]) {
      expect(html).not.toMatch(/\s(id|name)="turnstile"/);
    }
    // El script de Turnstile lo carga el JS solo en esta página: ninguna página lo trae en el HTML.
    for (const html of [indexHtml, requestHtml, privacyHtml]) expect(html).not.toContain("challenges.cloudflare.com");
  });

  it("junto al widget: el error, su código (seleccionable), la sugerencia y «Ripeti la verifica», ocultos hasta que hagan falta", () => {
    const start = requestHtml.indexOf('<div class="field field--turnstile">');
    const field = requestHtml.slice(start, requestHtml.indexOf('id="config-warning"', start));
    const ids = ["turnstile-widget", "hint-turnstile", "err-turnstileToken", "turnstile-code", "turnstile-help", "turnstile-retry"];
    const positions = ids.map((id) => field.indexOf(`id="${id}"`));
    expect(positions.filter((i) => i < 0), "faltan").toEqual([]);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);
    // El código va en <code>: se copia tal cual para mandárselo a quien da soporte.
    expect(field).toMatch(/<code id="turnstile-code-value"><\/code>/);
    for (const id of ["err-turnstileToken", "turnstile-code", "turnstile-help", "turnstile-retry"]) {
      expect(field, id).toMatch(new RegExp(`id="${id}"[^>]*\\shidden[\\s>]`));
    }
  });

  it("lo que describe a «Ripeti la verifica» (aria-describedby que arma turnstileView) existe junto al widget", () => {
    const start = requestHtml.indexOf('<div class="field field--turnstile">');
    const field = requestHtml.slice(start, requestHtml.indexOf('id="config-warning"', start));
    const { describedBy } = turnstileView({ status: "failed", errorCode: "300030", stalled: true, rejected: true });
    expect(describedBy).toHaveLength(3);
    for (const id of describedBy) expect(field, id).toContain(`id="${id}"`);
  });

  it("los estados del envío se anuncian (aria-live) y los errores con role=alert", () => {
    expect(requestHtml).toMatch(/<p id="form-status"[^>]*role="status"[^>]*aria-live="polite"/);
    expect(requestHtml).toMatch(/<div id="form-error"[^>]*role="alert"/);
    expect(requestHtml).toMatch(/<section id="done"[^>]*tabindex="-1"[^>]*aria-labelledby="done-title"/);
  });

  it("solo la landing lleva JSON-LD", () => {
    const landing = renderPage(indexHtml, { i18n, config: baseConfig, pagePath: "/", partials });
    const privacy = renderPage(privacyHtml, { i18n, config: baseConfig, pagePath: "/privacy/", partials });
    expect(landing).toContain('<script type="application/ld+json">');
    expect(privacy).not.toContain("application/ld+json");
  });

  it("íconos en todas las páginas: favicon.ico, SVG y apple-touch-icon", () => {
    for (const html of [indexHtml, requestHtml, privacyHtml, notFoundHtml]) {
      expect(html).toContain('<link rel="icon" href="/favicon.ico" sizes="32x32" />');
      expect(html).toContain('<link rel="icon" href="/favicon.svg" type="image/svg+xml" />');
      expect(html).toContain('<link rel="apple-touch-icon" href="/apple-touch-icon.png" />');
    }
  });
});

describe("vista previa al compartir (Open Graph y X)", () => {
  const withSite = { ...baseConfig, siteUrl: "https://radicicucina.app" };
  const pages = [
    ["/", indexHtml],
    ["/richiesta/", requestHtml],
    ["/privacy/", privacyHtml],
  ] as const;

  it("con VITE_SITE_URL: og:image absoluta con tamaño y texto alternativo, y tarjeta grande", () => {
    for (const [path, html] of pages) {
      const out = renderPage(html, { i18n, config: withSite, pagePath: path, partials });
      expect(out).toContain(`<meta property="og:image" content="https://radicicucina.app${OG_IMAGE.path}">`);
      expect(out).toContain('<meta property="og:image:type" content="image/png">');
      expect(out).toContain('<meta property="og:image:width" content="1200">');
      expect(out).toContain('<meta property="og:image:height" content="630">');
      expect(out).toMatch(/<meta property="og:image:alt" content="Radici · Cucina privata[^"]+Cuoca a domicilio a Bergamo\.">/);
      expect(out).toContain('<meta name="twitter:card" content="summary_large_image">');
      expect(out.match(/name="twitter:card"/g), path).toHaveLength(1);
    }
  });

  it("sin VITE_SITE_URL: sin og:image (tendría que ser absoluta) y tarjeta chica", () => {
    for (const [path, html] of pages) {
      const out = renderPage(html, { i18n, config: baseConfig, pagePath: path, partials });
      expect(out).not.toContain("og:image");
      expect(out).toContain('<meta name="twitter:card" content="summary">');
    }
  });
});

describe("página del captcha de Auth (/captcha/)", () => {
  const render = (config: AppConfig) => renderPage(captchaHtml, { i18n, config, pagePath: "/captcha/", partials });

  it("no es para visitar: nunca se indexa ni declara una URL propia, ni con el sitio indexable", () => {
    const out = render({ ...baseConfig, noindex: false, siteUrl: "https://radicicucina.app" });
    expect(out).toContain('<meta name="robots" content="noindex, nofollow">');
    expect(out).not.toMatch(/rel="canonical"|og:url|application\/ld\+json/);
  });

  it("sin cabecera ni pie, con el script propio y sin estilos ni scripts inline (la CSP no los deja)", () => {
    const out = render(baseConfig);
    expect(out).toContain('<script type="module" src="/src/pages/captcha.ts"></script>');
    expect(out).not.toMatch(/<header|<footer|data-lang=/);
    expect(out).not.toMatch(/\sstyle=|<style|<script(?![^>]*src=)/);
    // Los elementos que usa pages/captcha.ts.
    for (const id of ["captcha", "captcha-working", "captcha-interactive", "captcha-widget", "captcha-cancel", "captcha-standalone"]) {
      expect(out, id).toContain(`id="${id}"`);
    }
  });
});

describe("confirmar el alta o elegir la contraseña (/accesso/)", () => {
  const render = (config: AppConfig) => renderPage(accessHtml, { i18n, config, pagePath: "/accesso/", partials });

  it("nunca se indexa ni declara una URL propia (la suya lleva el token), ni con el sitio indexable", () => {
    const out = render({ ...baseConfig, noindex: false, siteUrl: "https://radicicucina.app" });
    expect(out).toContain('<meta name="robots" content="noindex, nofollow">');
    expect(out).not.toMatch(/rel="canonical"|og:url|application\/ld\+json/);
  });

  it("con cabecera (el selector de idioma) y pie, el script propio y sin estilos ni scripts inline (la CSP no los deja)", () => {
    const out = render(baseConfig);
    expect(out).toContain('<script type="module" src="/src/pages/accesso.ts"></script>');
    expect(out).toMatch(/data-lang="es"/);
    expect(out).not.toMatch(/\sstyle=|<style|<script(?![^>]*src=)/);
  });

  it("los textos del build quedan en italiano, también los mensajes ocultos", () => {
    const out = render(baseConfig);
    expect(out).toContain(">Conferma</button>");
    expect(out).toContain(">La password deve avere almeno 10 caratteri.</span>");
    expect(out).toContain(">Reinvia l'email</button>".replace("'", "&#39;"));
  });
});

describe("página de la clienta (/prenotazione/)", () => {
  const render = (config: AppConfig) => renderPage(reservationHtml, { i18n, config, pagePath: "/prenotazione/", partials });

  it("nunca se indexa ni declara una URL propia (la suya lleva el token), ni con el sitio indexable", () => {
    const out = render({ ...baseConfig, noindex: false, siteUrl: "https://radicicucina.app" });
    expect(out).toContain('<meta name="robots" content="noindex, nofollow">');
    expect(out).not.toMatch(/rel="canonical"|og:url|application\/ld\+json/);
    // La vista previa del link en WhatsApp sí muestra la imagen.
    expect(out).toContain(`<meta property="og:image" content="https://radicicucina.app${OG_IMAGE.path}">`);
  });

  it("el script de la página, la región en vivo y el aviso sin JS; sin estilos ni scripts inline", () => {
    const out = render(baseConfig);
    expect(out).toContain('<script type="module" src="/src/pages/prenotazione.ts"></script>');
    expect(out).toMatch(/<p id="reservation-live" class="visually-hidden" role="status" aria-live="polite"><\/p>/);
    expect(out).toContain('id="reservation"');
    expect(out).toMatch(/<noscript>\s*<p class="notice notice--warn" data-i18n="reservation.noscript">Per vedere la tua prenotazione/);
    expect(out).not.toMatch(/\sstyle=/);
    expect(out).not.toMatch(/<style/);
  });

  it("los links de idioma salen sin href (un «?lang=xx» perdería el token del fragmento); el shell se los pone", () => {
    const out = render(baseConfig);
    expect(out).not.toContain('href="?lang=');
    const links = [...out.matchAll(/<a\s[^>]*data-lang="(\w+)"[^>]*>/g)];
    expect(links.map((match) => match[1])).toEqual(["it", "es", "en"]);
    for (const [tag] of links) expect(tag).not.toMatch(/\shref=/);
    // Las páginas públicas los conservan: sin JS, cambian de idioma igual.
    for (const [path, html] of [["/", indexHtml], ["/richiesta/", requestHtml], ["/privacy/", privacyHtml]] as const) {
      expect(renderPage(html, { i18n, config: baseConfig, pagePath: path, partials }), path).toContain('href="?lang=es"');
    }
  });

  it("withoutLangHrefs: solo los links de idioma", () => {
    const html = '<a href="?lang=es" hreflang="es" data-lang="es">ES</a><a href="?lang=es#x">otro</a><a href="/">casa</a>';
    expect(withoutLangHrefs(html)).toBe('<a hreflang="es" data-lang="es">ES</a><a href="?lang=es#x">otro</a><a href="/">casa</a>');
  });
});

describe("página 404", () => {
  const render = (config: AppConfig) => renderPage(notFoundHtml, { i18n, config, pagePath: NOT_FOUND_PATH, partials });

  it("en italiano, con cabecera, pie y estilos del sitio, sin marcadores pendientes", () => {
    const out = render(baseConfig);
    expect(out).toMatch(/<title data-i18n="notFound.metaTitle">Pagina non trovata · Radici<\/title>/);
    expect(out).toContain('class="site-header"');
    expect(out).toContain('class="site-footer"');
    expect(out).toContain('<script type="module" src="/src/pages/not-found.ts"></script>');
    expect(out).not.toMatch(/<!--\s*partial:/);
    expect(out).not.toContain("__BRAND_NAME__");
    expect(out.replace(/<script[\s\S]*?<\/script>/g, "")).not.toMatch(/\{\w+\}/);
  });

  it("nunca se indexa, ni con el sitio indexable, y no declara URL propia ni imagen", () => {
    expect(render(baseConfig)).toContain('<meta name="robots" content="noindex, nofollow">');
    const indexable = render({ ...baseConfig, noindex: false, siteUrl: "https://radicicucina.app" });
    expect(indexable).toContain('<meta name="robots" content="noindex">');
    expect(indexable).not.toMatch(/canonical|og:url|og:image|twitter:card|application\/ld\+json/);
  });

  it("sin estilos ni scripts inline, y con URL absolutas (Pages la sirve en cualquier profundidad)", () => {
    const out = render(baseConfig);
    expect(out).not.toMatch(/\sstyle=/);
    expect(out).not.toMatch(/<style/);
    const urls = [...out.matchAll(/\s(?:href|src)="([^"]+)"/g)].map((m) => m[1] ?? "");
    expect(urls.length).toBeGreaterThan(5);
    for (const url of urls) expect(url, url).toMatch(/^(\/|#|\?lang=|https:\/\/)/);
    expect(urls).toContain("/");
    expect(urls).toContain("/richiesta/");
  });

  it("pagePathFromHtmlPath reconoce la 404", () => {
    expect(pagePathFromHtmlPath("/404.html")).toBe(NOT_FOUND_PATH);
  });
});

describe("JSON-LD", () => {
  it("LocalBusiness con FoodService, areaServed Bergamo e imagen", () => {
    const data = buildJsonLd({ ...baseConfig, siteUrl: "https://example.test" }, i18n);
    expect(data["@type"]).toBe("LocalBusiness");
    expect(data["name"]).toBe("Radici");
    expect(data["url"]).toBe("https://example.test/");
    expect(data["image"]).toBe(`https://example.test${OG_IMAGE.path}`);
    expect(JSON.stringify(data["areaServed"])).toContain("Bergamo");
    expect(JSON.stringify(data["makesOffer"])).toContain("FoodService");
  });

  it("dirección solo con ciudad, provincia y país (nunca calle ni código postal)", () => {
    for (const config of [baseConfig, { ...baseConfig, siteUrl: "https://example.test" }]) {
      expect(buildJsonLd(config, i18n)["address"]).toEqual({
        "@type": "PostalAddress",
        addressLocality: "Bergamo",
        addressRegion: "BG",
        addressCountry: "IT",
      });
    }
  });
});

it("pagePathFromHtmlPath", () => {
  expect(pagePathFromHtmlPath("/index.html")).toBe("/");
  expect(pagePathFromHtmlPath("/richiesta/index.html")).toBe("/richiesta/");
  expect(pagePathFromHtmlPath("privacy\\index.html")).toBe("/privacy/");
});
