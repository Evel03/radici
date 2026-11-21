import { describe, expect, it } from "vitest";
import headersFile from "../../public/_headers?raw";
import {
  SUPABASE_ORIGIN_TOKEN,
  SUPABASE_WS_ORIGIN_TOKEN,
  cspDirectives,
  headersFor,
  parseHeadersFile,
  renderHeadersFile,
} from "./headers.ts";

describe("parseHeadersFile y headersFor (semántica de Cloudflare Pages)", () => {
  const rules = parseHeadersFile(
    [
      "# comentario",
      "/*",
      "  Content-Security-Policy: default-src 'self'",
      "  X-Frame-Options: DENY",
      "",
      "/richiesta/*",
      "  ! Content-Security-Policy",
      "  Content-Security-Policy: default-src 'none'",
      "",
      "/assets/*",
      "  Cache-Control: public, max-age=31536000, immutable",
      "  X-Frame-Options: SAMEORIGIN",
      "",
      "/blog/:slug/foto.jpg",
      "  X-Slug: :slug",
    ].join("\n"),
  );

  it("lee reglas, cabeceras y cabeceras a quitar", () => {
    expect(rules.map((r) => r.pattern)).toEqual(["/*", "/richiesta/*", "/assets/*", "/blog/:slug/foto.jpg"]);
    expect(rules[1]?.unset).toEqual(["content-security-policy"]);
  });

  it("todas las reglas que coinciden, en orden; la misma cabecera se une con coma", () => {
    expect(headersFor(rules, "/")).toEqual(
      new Map([
        ["Content-Security-Policy", "default-src 'self'"],
        ["X-Frame-Options", "DENY"],
      ]),
    );
    expect(headersFor(rules, "/assets/app.js").get("X-Frame-Options")).toBe("DENY, SAMEORIGIN");
  });

  it("'!' quita lo que pusieron las reglas anteriores y deja poner un valor nuevo", () => {
    expect(headersFor(rules, "/richiesta/").get("Content-Security-Policy")).toBe("default-src 'none'");
    expect(headersFor(rules, "/richiesta/index.html").get("Content-Security-Policy")).toBe("default-src 'none'");
    expect(headersFor(rules, "/richiestaX").get("Content-Security-Policy")).toBe("default-src 'self'");
  });

  it("marcadores :nombre", () => {
    expect(headersFor(rules, "/blog/pasta/foto.jpg").get("X-Slug")).toBe("pasta");
    expect(headersFor(rules, "/blog/pasta/otra/foto.jpg").has("X-Slug")).toBe(false);
  });

  it("rechaza líneas mal formadas", () => {
    expect(() => parseHeadersFile("  X-Sola: sin regla")).toThrow();
    expect(() => parseHeadersFile("/*\n  sin-dos-puntos")).toThrow();
  });

  describe("reglas con URL absoluta (host)", () => {
    const hostRules = parseHeadersFile(
      [
        "https://:project.pages.dev/*",
        "  X-Robots-Tag: noindex",
        "  X-Project: :project",
        "",
        "https://www.example.com/solo/:page",
        "  X-Page: :page",
      ].join("\n"),
    );

    it("valen solo para ese host, sin importar protocolo ni puerto", () => {
      expect(headersFor(hostRules, "/", "radici.pages.dev").get("X-Robots-Tag")).toBe("noindex");
      expect(headersFor(hostRules, "/richiesta/", "Radici.Pages.Dev:443").get("X-Project")).toBe("radici");
      expect(headersFor(hostRules, "/", "radicicucina.app").has("X-Robots-Tag")).toBe(false);
      expect(headersFor(hostRules, "/solo/uno", "www.example.com").get("X-Page")).toBe("uno");
      expect(headersFor(hostRules, "/solo/uno", "example.com").has("X-Page")).toBe(false);
    });

    it("un marcador del host no cruza puntos", () => {
      expect(headersFor(hostRules, "/", "rama.radici.pages.dev").has("X-Robots-Tag")).toBe(false);
    });

    it("sin host (pedido sin cabecera Host) no se aplican", () => {
      expect(headersFor(hostRules, "/")).toEqual(new Map());
    });
  });
});

describe("renderHeadersFile", () => {
  const text = `/*\n  Content-Security-Policy: connect-src 'self' ${SUPABASE_ORIGIN_TOKEN}; frame-ancestors 'none'\n`;

  it("completa el origen de Supabase", () => {
    expect(renderHeadersFile(text, "https://abcdefgh.supabase.co")).toBe(
      "/*\n  Content-Security-Policy: connect-src 'self' https://abcdefgh.supabase.co; frame-ancestors 'none'\n",
    );
  });

  it("sin Supabase configurado quita el marcador (y el espacio)", () => {
    expect(renderHeadersFile(text, null)).toBe("/*\n  Content-Security-Policy: connect-src 'self'; frame-ancestors 'none'\n");
  });

  it("marcador wss para Realtime (lo puede usar la CSP de /gestione/)", () => {
    const ws = `/*\n  Content-Security-Policy: connect-src 'self' ${SUPABASE_ORIGIN_TOKEN} ${SUPABASE_WS_ORIGIN_TOKEN}\n`;
    expect(renderHeadersFile(ws, "https://abcdefgh.supabase.co")).toContain(
      "connect-src 'self' https://abcdefgh.supabase.co wss://abcdefgh.supabase.co",
    );
    expect(renderHeadersFile(ws, "http://127.0.0.1:54321")).toContain("http://127.0.0.1:54321 ws://127.0.0.1:54321");
    expect(renderHeadersFile(ws, null)).toContain("connect-src 'self'\n");
  });

  it("no acepta algo que no sea un origen (evita inyectar directivas)", () => {
    expect(() => renderHeadersFile(text, "https://x.supabase.co; script-src *")).toThrow();
    expect(() => renderHeadersFile(text, "https://x.supabase.co/ruta")).toThrow();
  });
});

describe("public/_headers real", () => {
  const origin = "https://abcdefgh.supabase.co";
  const rules = parseHeadersFile(renderHeadersFile(headersFile, origin));
  const csp = (path: string): Map<string, string[]> => {
    const value = headersFor(rules, path).get("Content-Security-Policy");
    if (!value) throw new Error(`sin CSP en ${path}`);
    expect(value, "una sola política (sin valores unidos con coma)").not.toContain(",");
    return cspDirectives(value);
  };

  it("respeta los límites de Cloudflare (100 reglas, 2000 caracteres por línea)", () => {
    expect(rules.length).toBeLessThanOrEqual(100);
    for (const line of renderHeadersFile(headersFile, origin).split("\n")) expect(line.length).toBeLessThan(2000);
  });

  it("solo usa los marcadores conocidos", () => {
    expect(headersFile).toContain(SUPABASE_ORIGIN_TOKEN);
    expect(headersFile).toContain(SUPABASE_WS_ORIGIN_TOKEN);
    expect(renderHeadersFile(headersFile, origin)).not.toMatch(/__\w+__/);
  });

  it("landing y privacy: CSP estricta, sin Turnstile ni Supabase", () => {
    for (const path of ["/", "/privacy/", "/no-existe"]) {
      const policy = csp(path);
      expect(policy.get("script-src")).toEqual(["'self'"]);
      expect(policy.get("connect-src")).toEqual(["'self'"]);
      expect(policy.get("img-src")).toEqual(["'self'", "data:"]);
      expect(policy.has("frame-src")).toBe(false);
      expect(policy.get("frame-ancestors")).toEqual(["'none'"]);
    }
  });

  it("/richiesta/: Turnstile en script-src y frame-src, la función de Supabase en connect-src y sus fotos en img-src", () => {
    for (const path of ["/richiesta/", "/richiesta/index.html"]) {
      const policy = csp(path);
      expect(policy.get("script-src")).toEqual(["'self'", "https://challenges.cloudflare.com"]);
      expect(policy.get("frame-src")).toEqual(["https://challenges.cloudflare.com"]);
      expect(policy.get("connect-src")).toEqual(["'self'", origin]);
      // Las fotos de los platos de la pestaña «Menù» (bucket público recipe-photos del mismo proyecto).
      expect(policy.get("img-src")).toEqual(["'self'", "data:", origin]);
    }
  });

  it("/richiesta/ sin Supabase configurado: las imágenes, solo las propias", () => {
    const bare = parseHeadersFile(renderHeadersFile(headersFile, null));
    const policy = cspDirectives(headersFor(bare, "/richiesta/").get("Content-Security-Policy") ?? "");
    expect(policy.get("img-src")).toEqual(["'self'", "data:"]);
    expect(policy.get("connect-src")).toEqual(["'self'"]);
  });

  it("/richiesta/ es la CSP base más esas fuentes (no se desalinean)", () => {
    const base = csp("/");
    const form = csp("/richiesta/");
    for (const [directive, sources] of base) {
      const extra = (form.get(directive) ?? []).filter((s) => !sources.includes(s));
      if (directive === "script-src") expect(extra).toEqual(["https://challenges.cloudflare.com"]);
      else if (directive === "connect-src" || directive === "img-src") expect(extra, directive).toEqual([origin]);
      else expect(form.get(directive), directive).toEqual(sources);
    }
    expect([...form.keys()].filter((d) => !base.has(d))).toEqual(["frame-src"]);
  });

  it("páginas públicas: nada de 'unsafe-inline', 'unsafe-eval' ni comodines", () => {
    for (const path of ["/", "/privacy/", "/richiesta/", "/no-existe"]) {
      const value = headersFor(rules, path).get("Content-Security-Policy") ?? "";
      expect(value, path).not.toContain("unsafe-inline");
      expect(value, path).not.toContain("unsafe-eval");
    }
    expect(renderHeadersFile(headersFile, origin)).not.toMatch(/src[^;]*\s\*(\s|;|$)/);
  });

  it("cabeceras de seguridad en todas las páginas y caché larga solo en assets", () => {
    for (const path of ["/", "/richiesta/", "/privacy/"]) {
      const headers = headersFor(rules, path);
      expect(headers.get("X-Content-Type-Options")).toBe("nosniff");
      expect(headers.get("X-Frame-Options")).toBe("DENY");
      expect(headers.get("Referrer-Policy")).toBe("strict-origin-when-cross-origin");
      expect(headers.has("Cache-Control")).toBe(false);
    }
    expect(headersFor(rules, "/assets/richiesta-abc.js").get("Cache-Control")).toBe("public, max-age=31536000, immutable");
  });

  // App Flutter web (bandeja de Evelyn): CSP propia, verificada en Chrome (app/README.md, "Web /gestione/").
  const gestionePaths = [
    "/gestione/",
    "/gestione/index.html",
    "/gestione/main.dart.js",
    "/gestione/canvaskit/chromium/canvaskit.wasm",
    "/gestione/assets/fonts/MaterialIcons-Regular.otf",
  ];

  it("/gestione/: CSP de Flutter (CanvasKit, estilos del motor, Supabase por https y wss) y no la de /*", () => {
    for (const path of gestionePaths) {
      const policy = csp(path);
      expect(policy.get("default-src"), path).toEqual(["'self'"]);
      expect(policy.get("script-src"), path).toEqual(["'self'", "'wasm-unsafe-eval'"]);
      expect(policy.get("style-src"), path).toEqual(["'self'", "'unsafe-inline'"]);
      expect(policy.get("connect-src"), path).toEqual(["'self'", origin, "wss://abcdefgh.supabase.co"]);
      expect(policy.get("object-src"), path).toEqual(["'none'"]);
      expect(policy.get("base-uri"), path).toEqual(["'self'"]);
      expect(policy.get("form-action"), path).toEqual(["'none'"]);
      expect(policy.get("frame-ancestors"), path).toEqual(["'none'"]);
      expect(policy.has("upgrade-insecure-requests"), path).toBe(true);
      expect(policy.has("frame-src"), path).toBe(false);
    }
  });

  it("/gestione/: sin caché larga (los archivos de Flutter no llevan hash), noindex y las cabeceras de seguridad de /*", () => {
    for (const path of gestionePaths) {
      const headers = headersFor(rules, path);
      expect(headers.get("Cache-Control"), path).toBe("no-cache");
      expect(headers.get("X-Robots-Tag"), path).toBe("noindex, nofollow");
      expect(headers.get("X-Content-Type-Options"), path).toBe("nosniff");
      expect(headers.get("X-Frame-Options"), path).toBe("DENY");
      expect(headers.get("Strict-Transport-Security"), path).toBe("max-age=31536000");
    }
    // /assets/* está anclado a la raíz: los assets de Flutter no quedan "immutable".
    expect(headersFor(rules, "/gestione/assets/AssetManifest.bin").get("Cache-Control")).toBe("no-cache");
    // Fuera de /gestione/ nada cambia.
    expect(headersFor(rules, "/gestionex").get("X-Robots-Tag")).toBeUndefined();
  });

  it("*.pages.dev (producción y vistas previas) nunca se indexa; el dominio propio no cambia", () => {
    const pagesHosts = ["radici.pages.dev", "radici-3xv.pages.dev", "f1-pedidos-bandeja.radici.pages.dev", "a1b2c3d4.radici.pages.dev:443"];
    for (const host of pagesHosts) {
      for (const path of ["/", "/richiesta/", "/privacy/", "/no-existe", "/assets/main-abc.js"]) {
        expect(headersFor(rules, path, host).get("X-Robots-Tag"), `${host}${path}`).toBe("noindex");
      }
      // /gestione/ suma su propio noindex, nofollow.
      expect(headersFor(rules, "/gestione/", host).get("X-Robots-Tag")).toBe("noindex, nofollow, noindex");
    }
    for (const path of ["/", "/richiesta/", "/privacy/", "/no-existe"]) {
      expect(headersFor(rules, path, "radicicucina.app").has("X-Robots-Tag"), path).toBe(false);
    }
    // El host no cambia la CSP de ninguna ruta.
    for (const path of ["/", "/richiesta/", "/gestione/"]) {
      expect(headersFor(rules, path, "radici.pages.dev").get("Content-Security-Policy")).toBe(
        headersFor(rules, path, "radicicucina.app").get("Content-Security-Policy"),
      );
    }
  });

  it("/gestione/ en local (supabase start): Realtime por ws://", () => {
    const local = parseHeadersFile(renderHeadersFile(headersFile, "http://127.0.0.1:54321"));
    const policy = cspDirectives(headersFor(local, "/gestione/").get("Content-Security-Policy") ?? "");
    expect(policy.get("connect-src")).toEqual(["'self'", "http://127.0.0.1:54321", "ws://127.0.0.1:54321"]);
  });
});
