import { describe, expect, it } from "vitest";

// Hasta PR69 ningún link público lleva a /app/ (el área de la clienta ya está publicada, pero no se anuncia: la
// enlaza la web recién cuando la app esté lista para las clientas). Este test lee todo lo que la web publica
// (páginas, partials, textos, código, robots.txt y sitemap.xml) y falla si algo apunta a /app/, ya sea con la
// ruta sola, con el dominio propio o con el de *.pages.dev. Cuando llegue PR69, se cambia este test a propósito.
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
 * La única excepción, a propósito: «Vai al login» de /accesso/ (src/access/login-link.ts). A /accesso/ solo se llega desde
 * el link de un email de Auth (no la enlaza ninguna página ni se indexa) y las altas siguen cerradas hasta PR20: hasta
 * el lanzamiento, ese botón solo lo ven las cuentas de prueba. Un archivo, un solo link (el test cuenta los dos).
 */
const ALLOWED: Record<string, number> = { "../access/login-link.ts": 1 };

/** Un texto entre comillas, un href o una URL que empieza en /app o en <dominio>/app (con barra, ?, # o el cierre). */
const APP_LINK = /(?:["'(=`]|href=)\s*(?:https?:\/\/[^\s"'`/]+)?\/app(?:[/?#"'`)]|$)/gm;

describe("sin links públicos a /app/ (hasta PR69)", () => {
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

  it("ningún archivo apunta a /app/ (salvo la excepción de /accesso/)", () => {
    const found: string[] = [];
    for (const [name, source] of Object.entries(files)) {
      if (name in ALLOWED) continue;
      for (const match of source.matchAll(APP_LINK)) found.push(`${name}: ${match[0].trim()}`);
    }
    expect(found).toEqual([]);
  });

  it("la excepción sigue siendo exactamente la que se permitió (si se mueve o crece, este test lo dice)", () => {
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
