// Tests de la comprobación del seguimiento de Resend (resend-tracking.ts): el despliegue corta si
// Resend tiene prendido el seguimiento de aperturas o de clics. Con una API falsa, sin red.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { checkResendTracking } from "./resend-tracking.ts";

const SCRIPT = fileURLToPath(new URL("./resend-tracking.ts", import.meta.url));

interface FakeDomain {
  id: string;
  name: string;
  open_tracking?: boolean;
  click_tracking?: boolean;
}

/** fetch falso de la API de Resend: GET /domains (lista) y GET /domains/{id} (detalle). */
function fakeResend(domains: FakeDomain[], options: { restricted?: boolean; status?: number } = {}): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    assert.match(String((init?.headers as Record<string, string>)?.Authorization), /^Bearer re_/);
    assert.ok(!init?.method || init.method === "GET", "solo lee");
    const json = (status: number, body: unknown): Response => new Response(JSON.stringify(body), { status });
    if (options.restricted) return json(401, { name: "restricted_api_key", message: "This API key is restricted to only send emails" });
    if (options.status) return json(options.status, { name: "x", message: "boom" });
    if (url.pathname === "/domains") return json(200, { object: "list", data: domains.map(({ id, name }) => ({ id, name })) });
    const id = url.pathname.replace("/domains/", "");
    const domain = domains.find((d) => d.id === id);
    return domain ? json(200, { object: "domain", ...domain }) : json(404, { name: "not_found", message: "x" });
  }) as typeof fetch;
}

const OFF = { open_tracking: false, click_tracking: false };

test("sin seguimiento en ningún dominio: pasa", async () => {
  const result = await checkResendTracking("re_clave", fakeResend([{ id: "1", name: "radicicucina.app", ...OFF }, { id: "2", name: "mail.radicicucina.app", ...OFF }]));
  assert.deepEqual(result, { kind: "ok", domains: 2 });
});

test("con seguimiento de clics o de aperturas en algún dominio: corta y dice cuál (sin la clave)", async () => {
  for (const on of [{ click_tracking: true, open_tracking: false }, { click_tracking: false, open_tracking: true }, { click_tracking: true, open_tracking: true }]) {
    const result = await checkResendTracking("re_clave", fakeResend([{ id: "1", name: "radicicucina.app", ...OFF }, { id: "2", name: "mail.radicicucina.app", ...on }]));
    assert.equal(result.kind, "tracking_on");
    assert.deepEqual(result.kind === "tracking_on" ? result.domains.map((d) => d.name) : [], ["mail.radicicucina.app"]);
    assert.ok(!JSON.stringify(result).includes("re_clave"));
  }
});

test("un dominio cuyo detalle no dice el seguimiento no pasa en silencio", async () => {
  const result = await checkResendTracking("re_clave", fakeResend([{ id: "1", name: "radicicucina.app" }]));
  assert.equal(result.kind, "error");
});

test("clave solo de envío (restricted_api_key): no se puede comprobar, y se avisa como tal", async () => {
  assert.deepEqual(await checkResendTracking("re_clave", fakeResend([], { restricted: true })), { kind: "restricted" });
});

test("error de la API o sin dominios: corta (no se da por bueno lo que no se pudo leer)", async () => {
  assert.equal((await checkResendTracking("re_clave", fakeResend([], { status: 500 }))).kind, "error");
  assert.equal((await checkResendTracking("re_clave", fakeResend([]))).kind, "error");
});

/** La línea de comandos contra un servidor local (solo 127.0.0.1 puede reemplazar la URL de Resend). */
async function cli(domains: FakeDomain[], env: Record<string, string> = {}, options: { restricted?: boolean } = {}) {
  const fake = fakeResend(domains, options);
  const server = createServer(async (req, res) => {
    const response = await fake(`http://x${req.url}`, { headers: { Authorization: String(req.headers.authorization) } });
    res.writeHead(response.status, { "content-type": "application/json" });
    res.end(await response.text());
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  try {
    return await new Promise<{ code: number; stdout: string; stderr: string }>((resolve) => {
      execFile(
        process.execPath,
        [SCRIPT],
        { env: { ...process.env, RESEND_API_KEY: "re_clave_de_prueba", RESEND_API_URL: `http://127.0.0.1:${port}`, RESEND_TRACKING_RESTRICTED_OK: "", ...env } },
        (error, stdout, stderr) => resolve({ code: error ? Number((error as { code?: number }).code) : 0, stdout, stderr }),
      );
    });
  } finally {
    server.close();
  }
}

test("línea de comandos: 0 sin seguimiento; 2 con seguimiento; nunca imprime la clave", async () => {
  const ok = await cli([{ id: "1", name: "radicicucina.app", ...OFF }]);
  assert.equal(ok.code, 0);
  const on = await cli([{ id: "1", name: "radicicucina.app", open_tracking: true, click_tracking: false }]);
  assert.equal(on.code, 2);
  assert.match(on.stderr, /radicicucina\.app/);
  assert.match(on.stderr, /open_tracking/);
  for (const out of [ok, on]) assert.ok(!(out.stdout + out.stderr).includes("re_clave_de_prueba"));
});

test("línea de comandos: con una clave solo de envío corta, salvo que se confirme a propósito", async () => {
  const cut = await cli([], {}, { restricted: true });
  assert.equal(cut.code, 2);
  assert.match(cut.stderr, /solo de envío/);
  const warned = await cli([], { RESEND_TRACKING_RESTRICTED_OK: "true" }, { restricted: true });
  assert.equal(warned.code, 0);
  assert.match(warned.stderr, /no se pudo comprobar/i);
});

test("línea de comandos: solo acepta reemplazar la URL de Resend por una local", async () => {
  const result = await new Promise<{ code: number; stderr: string }>((resolve) =>
    execFile(process.execPath, [SCRIPT], { env: { ...process.env, RESEND_API_KEY: "re_x", RESEND_API_URL: "https://otro.example" } }, (error, _out, stderr) =>
      resolve({ code: error ? Number((error as { code?: number }).code) : 0, stderr }),
    ),
  );
  assert.equal(result.code, 2);
  assert.match(result.stderr, /RESEND_API_URL/);
});
