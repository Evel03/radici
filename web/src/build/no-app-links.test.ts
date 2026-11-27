import { describe, expect, it } from "vitest";

// Los links de la web a /app/ (el área de la clienta) son solo los que se decidieron: desde el 27/11/2026, con las
// altas abiertas (PR20), «Accedi» en el encabezado y en el pie (pedido de Nicolas), más «Vai al login» de /accesso/.
// Este test lee todo lo que la web publica (páginas, partials, textos, código, robots.txt y sitemap.xml) y falla si
// algo más apunta a /app/, ya sea con la ruta sola, con el dominio propio o con el de *.pages.dev. Un link nuevo a
// /app/ se suma acá a propósito. robots.txt y sitemap.xml nunca lo anuncian (/app/ no se indexa).
const files: Record<string, string> = {
  ...import.meta.glob<string>("../../*.html", { query: "?raw", import: "default", eager: true }),
  ...import.meta.glob<string>("../../*/index.html", { query: "?raw", import: "default", eager: true }),
  ...import.meta.glob<string>("../../404.html", { query: "?raw", import: "default", eager: true }),
  ...import.meta.glob<string>("../partials/**/*.html", { query: "?raw", import: "default", eager: true }),
  ...import.meta.glob<string>("../i18n/*.json", { query: "?raw", import: "default", eager: true }),
  ...import.meta.glob<string>(["../**/*.ts", "!../**/*.test.ts"], { query: "?raw", import: "default", eager: true }),
  ...import.meta.glob<string>(["../../public/robots.txt", "../../public/sitemap.xml"], { query: "?raw", import: "default", eager: true }),
};

/**
 * Los links permitidos, con cuántos tiene cada archivo (el test cuenta los dos): «Accedi» del encabezado y del pie, y
 * «Vai al login» de /accesso/ (src/access/login-link.ts).
 */
const ALLOWED: Record<string, number> = {
  "../partials/header.html": 1,
  "../partials/footer.html": 1,
  "../access/login-link.ts": 1,
};

/** Un texto entre comillas, un href o una URL que empieza en /app o en <dominio>/app (con barra, ?, # o el cierre). */
const APP_LINK = /(?:["'(=`]|href=)\s*(?:https?:\/\/[^\s"'`/]+)?\/app(?:[/?#"'`)]|$)/gm;

describe("links a /app/: solo los decididos", () => {
  it("lee las páginas, los partials, los textos, el código y los archivos públicos", () => {
    const names = Object.keys(files);
    expect(names.some((n) => n.endsWith("index.html"))).toBe(true);
    expect(names.some((n) => n.endsWith("richiesta/index.html"))).toBe(true);
    expect(names.some((n) => n.endsWith("i18n/it.json"))).toBe(true);
    expect(names.some((n) => n.endsWith("robots.txt"))).toBe(true);
    expect(names.some((n) => n.endsWith("sitemap.xml"))).toBe(true);
    expect(names.some((n) => n.endsWith("pages/landing.ts"))).toBe(true);
    expect(names.length).toBeGreaterThan(25);
  });

  it("ningún otro archivo apunta a /app/", () => {
    const found: string[] = [];
    for (const [name, source] of Object.entries(files)) {
      if (name in ALLOWED) continue;
      for (const match of source.matchAll(APP_LINK)) found.push(`${name}: ${match[0].trim()}`);
    }
    expect(found).toEqual([]);
  });

  it("los permitidos siguen siendo exactamente esos (si se mueven o crecen, este test lo dice)", () => {
    // robots.txt y sitemap.xml nunca: /app/ no se indexa.
    for (const name of Object.keys(files).filter((n) => /robots\.txt$|sitemap\.xml$/.test(n))) expect(name in ALLOWED, name).toBe(false);
    for (const [name, count] of Object.entries(ALLOWED)) {
      expect(files[name], name).toBeDefined();
      expect([...(files[name] ?? "").matchAll(APP_LINK)].length, name).toBe(count);
    }
  });

  it("el detector reconoce los links a /app/ y deja pasar lo que no lo es", () => {
    const hits = (text: string) => [...text.matchAll(APP_LINK)].length;
    for (const bad of [
      '<a href="/app/">', "<a href='/app'>", 'href="https://radicicucina.app/app/"', '"/app/#/area"', "location.href = '/app/?x=1'",
      '"url": "https://radici.pages.dev/app/"',
    ]) {
      expect(hits(bad), bad).toBeGreaterThan(0);
    }
    for (const ok of ['<a href="/gestione/">', '"https://radicicucina.app/richiesta/"', "radicicucina.app/gestione/", '<a href="/application/">', "import x from '../app/y.ts'"]) {
      expect(hits(ok), ok).toBe(0);
    }
  });
});
