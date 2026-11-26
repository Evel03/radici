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

  it("/prenotazione/: la función de Supabase en connect-src y las fotos en img-src; sin Turnstile ni nada de terceros", () => {
    for (const path of ["/prenotazione/", "/prenotazione/index.html"]) {
      const policy = csp(path);
      expect(policy.get("script-src")).toEqual(["'self'"]);
      expect(policy.get("connect-src")).toEqual(["'self'", origin]);
      expect(policy.get("img-src")).toEqual(["'self'", "data:", origin]);
      expect(policy.has("frame-src")).toBe(false);
      expect(policy.get("frame-ancestors")).toEqual(["'none'"]);
    }
  });

  it("/prenotazione/ es la CSP base más el origen de Supabase (no se desalinean)", () => {
    const base = csp("/");
    const page = csp("/prenotazione/");
    for (const [directive, sources] of base) {
      const extra = (page.get(directive) ?? []).filter((s) => !sources.includes(s));
      if (directive === "connect-src" || directive === "img-src") expect(extra, directive).toEqual([origin]);
      else expect(page.get(directive), directive).toEqual(sources);
    }
    expect([...page.keys()].filter((d) => !base.has(d))).toEqual([]);
  });

  it("/prenotazione/ sin Supabase configurado: solo lo propio", () => {
    const bare = parseHeadersFile(renderHeadersFile(headersFile, null));
    const policy = cspDirectives(headersFor(bare, "/prenotazione/").get("Content-Security-Policy") ?? "");
    expect(policy.get("connect-src")).toEqual(["'self'"]);
    expect(policy.get("img-src")).toEqual(["'self'", "data:"]);
  });

  it("/prenotazione/ nunca se indexa (se abre con un link personal), con las cabeceras de seguridad de /*", () => {
    for (const path of ["/prenotazione/", "/prenotazione/index.html"]) {
      const headers = headersFor(rules, path, "radicicucina.app");
      expect(headers.get("X-Robots-Tag"), path).toBe("noindex, nofollow");
      expect(headers.get("X-Frame-Options")).toBe("DENY");
      expect(headers.get("Referrer-Policy")).toBe("strict-origin-when-cross-origin");
      expect(headers.has("Cache-Control")).toBe(false);
    }
    expect(headersFor(rules, "/prenotazionex", "radicicucina.app").has("X-Robots-Tag")).toBe(false);
  });

  // Captcha de Auth: la abre la app de Evelyn en un iframe del mismo sitio (o en una WebView).
  const captchaPaths = ["/captcha/", "/captcha/index.html"];

  it("/captcha/: solo lo que Turnstile necesita (script y marco de Cloudflare); sin Supabase ni fotos", () => {
    for (const path of captchaPaths) {
      const policy = csp(path);
      expect(policy.get("default-src"), path).toEqual(["'self'"]);
      expect(policy.get("script-src"), path).toEqual(["'self'", "https://challenges.cloudflare.com"]);
      expect(policy.get("frame-src"), path).toEqual(["https://challenges.cloudflare.com"]);
      expect(policy.get("connect-src"), path).toEqual(["'self'"]);
      expect(policy.get("img-src"), path).toEqual(["'self'", "data:"]);
      expect(policy.get("object-src"), path).toEqual(["'none'"]);
      expect(policy.get("base-uri"), path).toEqual(["'self'"]);
    }
  });

  it("/captcha/ es la única página que se deja enmarcar, y solo por el propio sitio (frame-ancestors 'self' y SAMEORIGIN)", () => {
    for (const path of captchaPaths) {
      expect(csp(path).get("frame-ancestors"), path).toEqual(["'self'"]);
      // El DENY de /* se quita (si quedara, el navegador mostraría el marco en blanco) y no se junta con coma.
      expect(headersFor(rules, path, "radicicucina.app").get("X-Frame-Options"), path).toBe("SAMEORIGIN");
    }
    for (const path of ["/", "/richiesta/", "/prenotazione/", "/privacy/", "/gestione/", "/captchax"]) {
      expect(csp(path).get("frame-ancestors"), path).toEqual(["'none'"]);
      expect(headersFor(rules, path).get("X-Frame-Options"), path).toBe("DENY");
    }
  });

  it("/captcha/ es la CSP base más Turnstile (script y marco) y frame-ancestors 'self' (no se desalinean)", () => {
    const base = csp("/");
    const page = csp("/captcha/");
    for (const [directive, sources] of base) {
      const extra = (page.get(directive) ?? []).filter((s) => !sources.includes(s));
      if (directive === "script-src") expect(extra).toEqual(["https://challenges.cloudflare.com"]);
      else if (directive === "frame-ancestors") expect(page.get(directive)).toEqual(["'self'"]);
      else expect(page.get(directive), directive).toEqual(sources);
    }
    expect([...page.keys()].filter((d) => !base.has(d))).toEqual(["frame-src"]);
  });

  it("/captcha/ nunca se indexa y conserva las demás cabeceras de seguridad de /*", () => {
    for (const path of captchaPaths) {
      const headers = headersFor(rules, path, "radicicucina.app");
      expect(headers.get("X-Robots-Tag"), path).toBe("noindex, nofollow");
      expect(headers.get("X-Content-Type-Options")).toBe("nosniff");
      expect(headers.get("Referrer-Policy")).toBe("strict-origin-when-cross-origin");
      expect(headers.get("Strict-Transport-Security")).toBe("max-age=31536000");
    }
    expect(headersFor(rules, "/captchax", "radicicucina.app").has("X-Robots-Tag")).toBe(false);
  });

  // /accesso/: el link de un email de Auth (docs/contracts/auth.md §11). Canjea el token por una sesión en memoria.
  const accessPaths = ["/accesso/", "/accesso/index.html"];

  it("/accesso/: solo Supabase (Auth) en connect-src y el marco de /captcha/ (mismo origen); nada de terceros", () => {
    for (const path of accessPaths) {
      const policy = csp(path);
      expect(policy.get("default-src"), path).toEqual(["'self'"]);
      expect(policy.get("script-src"), path).toEqual(["'self'"]);
      expect(policy.get("connect-src"), path).toEqual(["'self'", origin]);
      expect(policy.get("frame-src"), path).toEqual(["'self'"]);
      expect(policy.get("img-src"), path).toEqual(["'self'", "data:"]);
      expect(policy.get("frame-ancestors"), path).toEqual(["'none'"]);
    }
    expect(renderHeadersFile(headersFile, origin)).not.toMatch(/\/accesso\/\*[^#]*challenges\.cloudflare\.com/);
  });

  it("/accesso/: form-action 'none' (sin código, un formulario nunca manda la contraseña a ningún lado)", () => {
    for (const path of accessPaths) expect(csp(path).get("form-action"), path).toEqual(["'none'"]);
  });

  it("/accesso/ es la CSP base más Supabase y el marco de /captcha/, con form-action 'none' (no se desalinean)", () => {
    const base = csp("/");
    const page = csp("/accesso/");
    for (const [directive, sources] of base) {
      const extra = (page.get(directive) ?? []).filter((s) => !sources.includes(s));
      if (directive === "connect-src") expect(extra, directive).toEqual([origin]);
      else if (directive === "form-action") expect(page.get(directive)).toEqual(["'none'"]);
      else expect(page.get(directive), directive).toEqual(sources);
    }
    expect([...page.keys()].filter((d) => !base.has(d))).toEqual(["frame-src"]);
  });

  it("/accesso/ sin Supabase configurado: solo lo propio", () => {
    const bare = parseHeadersFile(renderHeadersFile(headersFile, null));
    expect(cspDirectives(headersFor(bare, "/accesso/").get("Content-Security-Policy") ?? "").get("connect-src")).toEqual(["'self'"]);
  });

  it("/accesso/: sin Referer, sin caché, nunca se indexa ni se deja enmarcar; las demás cabeceras de /*", () => {
    for (const path of accessPaths) {
      const headers = headersFor(rules, path, "radicicucina.app");
      // La de /* se quita: si no, Pages las uniría con una coma.
      expect(headers.get("Referrer-Policy"), path).toBe("no-referrer");
      expect(headers.get("Cache-Control"), path).toBe("no-store");
      expect(headers.get("X-Robots-Tag"), path).toBe("noindex, nofollow");
      expect(headers.get("X-Frame-Options"), path).toBe("DENY");
      expect(headers.get("X-Content-Type-Options")).toBe("nosniff");
      expect(headers.get("Strict-Transport-Security")).toBe("max-age=31536000");
    }
    // Sus scripts y estilos (en /assets/) siguen con la caché larga: llevan hash en el nombre.
    expect(headersFor(rules, "/assets/accesso-abc.js").get("Cache-Control")).toBe("public, max-age=31536000, immutable");
    expect(headersFor(rules, "/accessox", "radicicucina.app").has("X-Robots-Tag")).toBe(false);
  });

  // /preferenze/: el link de ofertas y novedades (docs/contracts/public-request.md §13). POST a public-request con el token.
  const preferencesPaths = ["/preferenze/", "/preferenze/index.html"];

  it("/preferenze/: solo Supabase (la función) en connect-src; sin marcos, sin terceros, form-action 'none'", () => {
    for (const path of preferencesPaths) {
      const policy = csp(path);
      expect(policy.get("default-src"), path).toEqual(["'self'"]);
      expect(policy.get("script-src"), path).toEqual(["'self'"]);
      expect(policy.get("connect-src"), path).toEqual(["'self'", origin]);
      expect(policy.get("img-src"), path).toEqual(["'self'", "data:"]);
      expect(policy.has("frame-src"), path).toBe(false);
      expect(policy.get("form-action"), path).toEqual(["'none'"]);
      expect(policy.get("frame-ancestors"), path).toEqual(["'none'"]);
    }
  });

  it("/preferenze/ es la CSP base más Supabase, con form-action 'none' (no se desalinean)", () => {
    const base = csp("/");
    const page = csp("/preferenze/");
    for (const [directive, sources] of base) {
      const extra = (page.get(directive) ?? []).filter((s) => !sources.includes(s));
      if (directive === "connect-src") expect(extra, directive).toEqual([origin]);
      else if (directive === "form-action") expect(page.get(directive)).toEqual(["'none'"]);
      else expect(page.get(directive), directive).toEqual(sources);
    }
    expect([...page.keys()].filter((d) => !base.has(d))).toEqual([]);
  });

  it("/preferenze/: sin Referer, sin caché y nunca se indexa ni se deja enmarcar", () => {
    for (const path of preferencesPaths) {
      const headers = headersFor(rules, path, "radicicucina.app");
      expect(headers.get("Referrer-Policy"), path).toBe("no-referrer");
      expect(headers.get("Cache-Control"), path).toBe("no-store");
      expect(headers.get("X-Robots-Tag"), path).toBe("noindex, nofollow");
      expect(headers.get("X-Frame-Options"), path).toBe("DENY");
    }
  });

  it("páginas públicas: nada de 'unsafe-inline', 'unsafe-eval' ni comodines", () => {
    for (const path of ["/", "/privacy/", "/richiesta/", "/prenotazione/", "/captcha/", "/accesso/", "/preferenze/", "/no-existe"]) {
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

  it("/gestione/: CSP de Flutter (CanvasKit, estilos del motor, Supabase por https y wss, las fotos) y no la de /*", () => {
    for (const path of gestionePaths) {
      const policy = csp(path);
      expect(policy.get("default-src"), path).toEqual(["'self'"]);
      expect(policy.get("script-src"), path).toEqual(["'self'", "'wasm-unsafe-eval'"]);
      expect(policy.get("style-src"), path).toEqual(["'self'", "'unsafe-inline'"]);
      // Fotos de los platos: Safari y Firefox decodifican cada imagen en un <img> con una URL blob:, y la
      // foto elegida se achica en un <img> y se lee con XMLHttpRequest desde su URL blob:. El bucket
      // público está en el origen de Supabase.
      expect(policy.get("img-src"), path).toEqual(["'self'", "blob:", origin]);
      expect(policy.get("connect-src"), path).toEqual(["'self'", "blob:", origin, "wss://abcdefgh.supabase.co"]);
      expect(policy.get("object-src"), path).toEqual(["'none'"]);
      expect(policy.get("base-uri"), path).toEqual(["'self'"]);
      expect(policy.get("form-action"), path).toEqual(["'none'"]);
      expect(policy.get("frame-ancestors"), path).toEqual(["'none'"]);
      expect(policy.has("upgrade-insecure-requests"), path).toBe(true);
      // El marco del captcha de Auth (/captcha/, mismo origen): ningún tercero puede ir en un marco de la app.
      expect(policy.get("frame-src"), path).toEqual(["'self'"]);
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

  // La misma app Flutter web, publicada también en /app/ (clientas, PR13): mismas reglas que /gestione/.
  const appPaths = gestionePaths.map((p) => p.replace("/gestione/", "/app/"));

  it("/app/: la misma CSP que /gestione/ (CanvasKit, estilos del motor, Supabase https y wss, fotos, marco del captcha)", () => {
    for (const path of appPaths) {
      const policy = csp(path);
      expect(policy.get("script-src"), path).toEqual(["'self'", "'wasm-unsafe-eval'"]);
      expect(policy.get("style-src"), path).toEqual(["'self'", "'unsafe-inline'"]);
      expect(policy.get("img-src"), path).toEqual(["'self'", "blob:", origin]);
      expect(policy.get("connect-src"), path).toEqual(["'self'", "blob:", origin, "wss://abcdefgh.supabase.co"]);
      expect(policy.get("frame-src"), path).toEqual(["'self'"]);
      expect(policy.get("frame-ancestors"), path).toEqual(["'none'"]);
      expect(policy.get("form-action"), path).toEqual(["'none'"]);
      expect(policy.has("upgrade-insecure-requests"), path).toBe(true);
      // Ni Turnstile ni ningún tercero: el captcha corre dentro de /captcha/, no acá.
      expect(headersFor(rules, path).get("Content-Security-Policy"), path).not.toContain("challenges.cloudflare.com");
    }
    for (const [i, path] of appPaths.entries()) {
      const g = headersFor(rules, gestionePaths[i] ?? "");
      const a = headersFor(rules, path);
      for (const name of ["Content-Security-Policy", "Cache-Control", "X-Robots-Tag", "X-Frame-Options", "Strict-Transport-Security"]) {
        expect(a.get(name), `${path} ${name}`).toBe(g.get(name));
      }
    }
  });

  it("/app/: no-cache, noindex, nofollow y las cabeceras de seguridad de /*; fuera de /app/ nada cambia", () => {
    for (const path of [...appPaths, "/app/assets/AssetManifest.bin", "/app/build.json", "/app/manifest.json"]) {
      const headers = headersFor(rules, path);
      expect(headers.get("Cache-Control"), path).toBe("no-cache");
      expect(headers.get("X-Robots-Tag"), path).toBe("noindex, nofollow");
      expect(headers.get("X-Content-Type-Options"), path).toBe("nosniff");
      expect(headers.get("X-Frame-Options"), path).toBe("DENY");
    }
    expect(headersFor(rules, "/appx").get("X-Robots-Tag")).toBeUndefined();
    expect(headersFor(rules, "/application/").get("Cache-Control")).toBeUndefined();
    // /gestione/ y /app/ no se pisan entre sí.
    expect(headersFor(rules, "/gestione/").get("Content-Security-Policy")).toContain("'wasm-unsafe-eval'");
  });

  it("/app/ en una vista previa de *.pages.dev suma su noindex a los propios", () => {
    expect(headersFor(rules, "/app/", "radici.pages.dev").get("X-Robots-Tag")).toBe("noindex, nofollow, noindex");
  });

  it("/app/ sin Supabase configurado y en local sigue a /gestione/", () => {
    const bare = parseHeadersFile(renderHeadersFile(headersFile, null));
    const bareCsp = cspDirectives(headersFor(bare, "/app/").get("Content-Security-Policy") ?? "");
    expect(bareCsp.get("img-src")).toEqual(["'self'", "blob:"]);
    expect(bareCsp.get("connect-src")).toEqual(["'self'", "blob:"]);
    const local = parseHeadersFile(renderHeadersFile(headersFile, "http://127.0.0.1:54321"));
    const localCsp = cspDirectives(headersFor(local, "/app/").get("Content-Security-Policy") ?? "");
    expect(localCsp.get("connect-src")).toEqual(["'self'", "blob:", "http://127.0.0.1:54321", "ws://127.0.0.1:54321"]);
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
    expect(policy.get("connect-src")).toEqual(["'self'", "blob:", "http://127.0.0.1:54321", "ws://127.0.0.1:54321"]);
    expect(policy.get("img-src")).toEqual(["'self'", "blob:", "http://127.0.0.1:54321"]);
  });

  it("/gestione/ sin Supabase configurado (vista previa de un PR): las imágenes y las conexiones, solo propias y blob:", () => {
    const bare = parseHeadersFile(renderHeadersFile(headersFile, null));
    const policy = cspDirectives(headersFor(bare, "/gestione/").get("Content-Security-Policy") ?? "");
    expect(policy.get("img-src")).toEqual(["'self'", "blob:"]);
    expect(policy.get("connect-src")).toEqual(["'self'", "blob:"]);
  });

  it("blob: solo en /gestione/ y /app/ (la app Flutter): las páginas públicas no lo necesitan", () => {
    for (const path of ["/", "/privacy/", "/richiesta/", "/no-existe"]) {
      expect(headersFor(rules, path).get("Content-Security-Policy"), path).not.toContain("blob:");
    }
  });
});
