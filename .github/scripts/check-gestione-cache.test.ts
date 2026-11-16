// Tests del chequeo de caché de /gestione/ que corre Deploy web en producción después de publicar
// (check-gestione-cache.sh, al lado), contra un servidor local. Correr con: npm test (raíz).
// Necesita bash, curl y jq, como el runner de ubuntu del CI: si falta alguno, se saltea. En Windows
// corre solo desde Git Bash (MSYSTEM): desde PowerShell, el bash del PATH es el de WSL, que no ve el
// 127.0.0.1 de este proceso.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createServer, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const BUILD_ID = "abc1234";

function unavailable(): string | false {
  if (process.platform === "win32" && !process.env.MSYSTEM) {
    return "en Windows, solo desde Git Bash (el bash de PowerShell es el de WSL y no ve este servidor)";
  }
  const probe = spawnSync("bash", ["-c", "command -v curl && command -v jq"], { encoding: "utf8" });
  return probe.status === 0 ? false : "faltan bash, curl o jq (el runner del CI los tiene)";
}
const skip = unavailable();

/** Lo que responde el servidor falso. n: número de pedido a esa ruta, desde 1. */
type Handler = (path: string, n: number, res: ServerResponse) => void;

function send(res: ServerResponse, status: number, cacheControl: string, body: string): void {
  res.writeHead(status, { "content-type": "text/plain", "cache-control": cacheControl });
  res.end(body);
}

/** Producción bien: build.json con este id y los dos archivos con no-cache. */
function production(overrides: Partial<Record<string, Handler>> = {}): Handler {
  return (path, n, res) => {
    const override = overrides[path];
    if (override) return override(path, n, res);
    if (path === "/gestione/build.json") return send(res, 200, "no-cache", `{"buildId":"${BUILD_ID}"}\n`);
    if (path === "/gestione/main.dart.js") return send(res, 200, "no-cache", "// main\n");
    // Una lista y en mayúsculas: también vale.
    if (path === "/gestione/flutter_bootstrap.js") return send(res, 200, "public, No-Cache", "// bootstrap\n");
    send(res, 404, "no-store", "404");
  };
}

/** Con la caché del navegador de Cloudflare encima (Browser Cache TTL de fábrica). */
const cloudflareTtl: Handler = (_path, _n, res) => send(res, 200, "max-age=14400", "// js\n");

async function withServer(handler: Handler, fn: (site: string) => Promise<void>): Promise<void> {
  const hits = new Map<string, number>();
  const server = createServer((req, res) => {
    const path = new URL(req.url ?? "/", "http://localhost").pathname;
    const n = (hits.get(path) ?? 0) + 1;
    hits.set(path, n);
    handler(path, n, res);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  try {
    await fn(`http://127.0.0.1:${port}`);
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

/** Corre el script como el paso del workflow: 3 intentos, sin pausa. */
function check(env: Record<string, string>): Promise<{ code: number | null; out: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn("bash", ["check-gestione-cache.sh"], {
      cwd: HERE,
      env: { ...process.env, BUILD_ID, CACHE_CHECK_ATTEMPTS: "3", CACHE_CHECK_PAUSE: "0", ...env },
    });
    let out = "";
    child.stdout.on("data", (chunk) => (out += chunk));
    child.stderr.on("data", (chunk) => (out += chunk));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, out }));
  });
}

test("producción bien: verde, sin avisos", { skip }, async () => {
  await withServer(production(), async (site) => {
    const { code, out } = await check({ SITE_URL: `${site}/` });
    assert.equal(code, 0, out);
    assert.match(out, /build\.json \(intento 1\/3\): abc1234/);
    assert.match(out, /main\.dart\.js \(intento 1\/3\): HTTP 200, Cache-Control: no-cache/);
    assert.doesNotMatch(out, /::(error|warning)::/);
  });
});

test("con la caché de Cloudflare (max-age=14400): rojo, con la indicación de Cloudflare", { skip }, async () => {
  await withServer(production({ "/gestione/main.dart.js": cloudflareTtl }), async (site) => {
    const { code, out } = await check({ SITE_URL: site });
    assert.equal(code, 1, out);
    assert.match(out, /main\.dart\.js \(intento 3\/3\)/);
    assert.match(out, /::error::.*main\.dart\.js llega con Cache-Control: max-age=14400.*Respect Existing Headers/);
  });
});

test("un archivo que no está (404): rojo, sin la indicación de la caché", { skip }, async () => {
  const missing: Handler = (_path, _n, res) => send(res, 404, "no-store", "404");
  await withServer(production({ "/gestione/flutter_bootstrap.js": missing }), async (site) => {
    const { code, out } = await check({ SITE_URL: site });
    assert.equal(code, 1, out);
    assert.match(out, /::error::.*flutter_bootstrap\.js: HTTP 404/);
    assert.doesNotMatch(out, /Respect Existing Headers/);
  });
});

test("la cabecera bien recién al tercer pedido (propagación): verde con 3 intentos, rojo con 2", { skip }, async () => {
  const late: Handler = (path, n, res) => (n < 3 ? cloudflareTtl(path, n, res) : send(res, 200, "no-cache", "// js\n"));
  await withServer(production({ "/gestione/main.dart.js": late }), async (site) => {
    const { code, out } = await check({ SITE_URL: site });
    assert.equal(code, 0, out);
    assert.match(out, /main\.dart\.js \(intento 3\/3\): HTTP 200, Cache-Control: no-cache/);
  });
  await withServer(production({ "/gestione/main.dart.js": late }), async (site) => {
    const { code, out } = await check({ SITE_URL: site, CACHE_CHECK_ATTEMPTS: "2" });
    assert.equal(code, 1, out);
  });
});

test("un corte de la conexión es un intento fallido más, no el final del paso", { skip }, async () => {
  // main.dart.js: el primer pedido se corta sin respuesta (curl 52). flutter_bootstrap.js: se corta a
  // mitad del cuerpo (curl 18), con las cabeceras ya recibidas, que valen.
  const cutBeforeAnswer: Handler = (_path, n, res) =>
    n === 1 ? void res.socket?.destroy() : send(res, 200, "no-cache", "// main\n");
  const cutMidBody: Handler = (_path, _n, res) => {
    res.writeHead(200, { "cache-control": "no-cache", "content-length": "1000" });
    res.write("// parte del archivo");
    setTimeout(() => res.socket?.destroy(), 50);
  };
  await withServer(
    production({ "/gestione/main.dart.js": cutBeforeAnswer, "/gestione/flutter_bootstrap.js": cutMidBody }),
    async (site) => {
      const { code, out } = await check({ SITE_URL: site });
      assert.equal(code, 0, out);
      assert.match(out, /main\.dart\.js \(intento 1\/3\): sin respuesta \(curl \d+\)/);
      assert.match(out, /main\.dart\.js \(intento 2\/3\): HTTP 200, Cache-Control: no-cache/);
      assert.match(out, /flutter_bootstrap\.js \(intento 1\/3\): HTTP 200, Cache-Control: no-cache/);
    },
  );
});

test("build.json todavía sin este id: solo avisa", { skip }, async () => {
  const old: Handler = (_path, _n, res) => send(res, 200, "no-cache", '{"buildId":"0000000"}\n');
  await withServer(production({ "/gestione/build.json": old }), async (site) => {
    const { code, out } = await check({ SITE_URL: site });
    assert.equal(code, 0, out);
    assert.match(out, /build\.json \(intento 3\/3\): 0000000/);
    assert.match(out, /::warning::.*no muestra este build \(abc1234\)/);
  });
});

test("sin el origen del sitio, con una ruta, o sin BUILD_ID: rojo antes de pedir nada", { skip }, async () => {
  let requests = 0;
  await withServer(
    (_path, _n, res) => {
      requests++;
      send(res, 200, "no-cache", "");
    },
    async (site) => {
      for (const env of [{ SITE_URL: "" }, { SITE_URL: `${site}/gestione` }, { SITE_URL: site, BUILD_ID: "" }]) {
        const { code, out } = await check(env);
        assert.equal(code, 1, `${JSON.stringify(env)}: ${out}`);
        assert.match(out, /::error::/);
      }
    },
  );
  assert.equal(requests, 0);
});
