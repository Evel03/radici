// Tests de la verificación de Cloudflare Turnstile (siteverify). Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { TURNSTILE_VERIFY_URL, verifyTurnstile } from "./turnstile.ts";

interface Call {
  url: string;
  init: RequestInit | undefined;
}

function fakeFetch(respond: () => Response | Promise<Response>): { fetch: typeof fetch; calls: Call[] } {
  const calls: Call[] = [];
  const fn = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    calls.push({ url: String(input), init });
    return respond();
  };
  return { fetch: fn as typeof fetch, calls };
}

function sentBody(call: Call | undefined): unknown {
  return JSON.parse(String(call?.init?.body));
}

test("éxito: manda secret, token, remoteip e idempotency_key como JSON", async () => {
  const { fetch, calls } = fakeFetch(() => Response.json({ success: true, "error-codes": [] }));
  const outcome = await verifyTurnstile({
    secret: "secreto",
    token: "XXXX.DUMMY.TOKEN.XXXX",
    remoteIp: "203.0.113.7",
    idempotencyKey: "4b1c1b8e-1f0e-4a8e-9a43-5f4c4f2d3a10",
    fetch,
  });
  assert.deepEqual(outcome, { ok: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]?.url, TURNSTILE_VERIFY_URL);
  assert.equal(calls[0]?.init?.method, "POST");
  assert.equal(new Headers(calls[0]?.init?.headers).get("content-type"), "application/json");
  assert.deepEqual(sentBody(calls[0]), {
    secret: "secreto",
    response: "XXXX.DUMMY.TOKEN.XXXX",
    remoteip: "203.0.113.7",
    idempotency_key: "4b1c1b8e-1f0e-4a8e-9a43-5f4c4f2d3a10",
  });
});

test("sin IP ni clave de idempotencia: no se mandan esos campos", async () => {
  const { fetch, calls } = fakeFetch(() => Response.json({ success: true }));
  await verifyTurnstile({ secret: "s", token: "t", remoteIp: null, fetch });
  assert.deepEqual(sentBody(calls[0]), { secret: "s", response: "t" });
});

test("token inválido, vencido o repetido: rechazado (403 en la función)", async () => {
  for (const code of ["invalid-input-response", "timeout-or-duplicate", "missing-input-response"]) {
    const { fetch } = fakeFetch(() => Response.json({ success: false, "error-codes": [code] }));
    assert.deepEqual(await verifyTurnstile({ secret: "s", token: "t", remoteIp: null, fetch }), {
      ok: false,
      reason: "rejected",
      errorCodes: [code],
    });
  }
});

test("secreto ausente o inválido, o pedido mal armado: error de configuración", async () => {
  for (const code of ["invalid-input-secret", "missing-input-secret", "bad-request"]) {
    const { fetch } = fakeFetch(() => Response.json({ success: false, "error-codes": [code] }));
    const outcome = await verifyTurnstile({ secret: "s", token: "t", remoteIp: null, fetch });
    assert.deepEqual(outcome, { ok: false, reason: "misconfigured", errorCodes: [code] });
  }
});

test("Cloudflare caído, error interno, HTTP 5xx, JSON roto o timeout: no disponible", async () => {
  const cases: Array<() => Response | Promise<Response>> = [
    () => Response.json({ success: false, "error-codes": ["internal-error"] }),
    () => new Response("oops", { status: 502 }),
    () => new Response("no es json", { status: 200 }),
    () => Promise.reject(new TypeError("fetch failed")),
  ];
  for (const respond of cases) {
    const { fetch } = fakeFetch(respond);
    const outcome = await verifyTurnstile({ secret: "s", token: "t", remoteIp: null, fetch });
    assert.equal(outcome.ok, false);
    if (!outcome.ok) assert.equal(outcome.reason, "unavailable");
  }

  // Timeout: el fetch nunca responde, pero respeta la señal de aborto.
  const hanging = (async (_input: string | URL | Request, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new DOMException("timeout", "TimeoutError")));
    })) as typeof fetch;
  const outcome = await verifyTurnstile({ secret: "s", token: "t", remoteIp: null, fetch: hanging, timeoutMs: 20 });
  assert.deepEqual(outcome, { ok: false, reason: "unavailable", errorCodes: ["timeout"] });
});

test("los códigos de error que no son texto se descartan", async () => {
  const { fetch } = fakeFetch(() => Response.json({ success: false, "error-codes": ["invalid-input-response", 42, null] }));
  assert.deepEqual(await verifyTurnstile({ secret: "s", token: "t", remoteIp: null, fetch }), {
    ok: false,
    reason: "rejected",
    errorCodes: ["invalid-input-response"],
  });
});
