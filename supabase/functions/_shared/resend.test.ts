// Tests del envío de emails con la API REST de Resend. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { RESEND_API_URL, sendWithResend, type EmailMessage } from "./resend.ts";

interface Call {
  url: string;
  init: RequestInit | undefined;
}

function scriptedFetch(responses: Array<() => Response | Promise<Response>>): { fetch: typeof fetch; calls: Call[] } {
  const calls: Call[] = [];
  const fn = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    calls.push({ url: String(input), init });
    const next = responses[calls.length - 1];
    if (!next) throw new Error("llamada de más");
    return next();
  };
  return { fetch: fn as typeof fetch, calls };
}

const MESSAGE: EmailMessage = {
  from: "Radici <ciao@radici.sepusola10.com>",
  to: "giulia@example.test",
  replyTo: "evelyn@example.test",
  subject: "Radici: abbiamo ricevuto la tua richiesta",
  html: "<p>Ciao</p>",
  text: "Ciao",
  idempotencyKey: "request-1b4e28ba-2fa1-41d2-883f-0016d3cca427-client",
};

const noSleep = async (): Promise<void> => {};

test("manda el email con la clave de API, Idempotency-Key y reply_to", async () => {
  const { fetch, calls } = scriptedFetch([() => Response.json({ id: "49a3999c-0ce1-4ea6-ab68-afcd6dc2e794" })]);
  const outcome = await sendWithResend(MESSAGE, { apiKey: "re_test", fetch, sleep: noSleep });
  assert.deepEqual(outcome, { ok: true, id: "49a3999c-0ce1-4ea6-ab68-afcd6dc2e794" });
  assert.equal(calls[0]?.url, RESEND_API_URL);
  assert.equal(calls[0]?.init?.method, "POST");
  const headers = new Headers(calls[0]?.init?.headers);
  assert.equal(headers.get("authorization"), "Bearer re_test");
  assert.equal(headers.get("content-type"), "application/json");
  assert.equal(headers.get("idempotency-key"), MESSAGE.idempotencyKey);
  assert.deepEqual(JSON.parse(String(calls[0]?.init?.body)), {
    from: MESSAGE.from,
    to: [MESSAGE.to],
    subject: MESSAGE.subject,
    html: MESSAGE.html,
    text: MESSAGE.text,
    reply_to: "evelyn@example.test",
  });
});

test("sin reply_to no se manda el campo", async () => {
  const { fetch, calls } = scriptedFetch([() => Response.json({ id: "x" })]);
  await sendWithResend({ ...MESSAGE, replyTo: null }, { apiKey: "re_test", fetch, sleep: noSleep });
  assert.equal("reply_to" in (JSON.parse(String(calls[0]?.init?.body)) as Record<string, unknown>), false);
});

test("429 o 5xx: reintenta una vez con la misma Idempotency-Key, respetando Retry-After con tope", async () => {
  const waits: number[] = [];
  const { fetch, calls } = scriptedFetch([
    () => new Response(JSON.stringify({ name: "rate_limit_exceeded" }), { status: 429, headers: { "Retry-After": "120" } }),
    () => Response.json({ id: "abc" }),
  ]);
  const outcome = await sendWithResend(MESSAGE, {
    apiKey: "re_test",
    fetch,
    sleep: async (ms) => {
      waits.push(ms);
    },
  });
  assert.deepEqual(outcome, { ok: true, id: "abc" });
  assert.equal(calls.length, 2);
  assert.deepEqual(waits, [5000], "Retry-After de 120 s se recorta a 5 s");
  assert.equal(new Headers(calls[1]?.init?.headers).get("idempotency-key"), MESSAGE.idempotencyKey);

  const second = scriptedFetch([() => new Response("", { status: 503 }), () => new Response("", { status: 503 })]);
  const failed = await sendWithResend(MESSAGE, { apiKey: "re_test", fetch: second.fetch, sleep: noSleep });
  assert.deepEqual(failed, { ok: false, status: 503, errorName: null });
  assert.equal(second.calls.length, 2, "un solo reintento");
});

test("409 de una petición igual en curso: reintenta; 409 por payload distinto: no", async () => {
  const busy = scriptedFetch([
    () => Response.json({ name: "concurrent_idempotent_requests" }, { status: 409 }),
    () => Response.json({ id: "ok" }),
  ]);
  assert.deepEqual(await sendWithResend(MESSAGE, { apiKey: "k", fetch: busy.fetch, sleep: noSleep }), { ok: true, id: "ok" });

  const conflict = scriptedFetch([() => Response.json({ name: "invalid_idempotent_request" }, { status: 409 })]);
  assert.deepEqual(await sendWithResend(MESSAGE, { apiKey: "k", fetch: conflict.fetch, sleep: noSleep }), {
    ok: false,
    status: 409,
    errorName: "invalid_idempotent_request",
  });
  assert.equal(conflict.calls.length, 1);
});

test("error de validación: no reintenta y devuelve solo el nombre del error (el mensaje puede traer la dirección)", async () => {
  const { fetch, calls } = scriptedFetch([
    () => Response.json({ statusCode: 422, name: "validation_error", message: "Invalid `to` field: giulia@" }, { status: 422 }),
  ]);
  const outcome = await sendWithResend(MESSAGE, { apiKey: "re_test", fetch, sleep: noSleep });
  assert.deepEqual(outcome, { ok: false, status: 422, errorName: "validation_error" });
  assert.equal(calls.length, 1);
});

test("red caída dos veces: falla sin status", async () => {
  const { fetch, calls } = scriptedFetch([
    () => Promise.reject(new TypeError("fetch failed")),
    () => Promise.reject(new TypeError("fetch failed")),
  ]);
  assert.deepEqual(await sendWithResend(MESSAGE, { apiKey: "re_test", fetch, sleep: noSleep }), {
    ok: false,
    status: null,
    errorName: "network",
  });
  assert.equal(calls.length, 2);
});
