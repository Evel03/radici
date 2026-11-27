// Tests de auth-email-check.ts contra el handler real de la función auth-email (en memoria, sin red): con el mismo
// secreto pasa, sin secreto o con otro no, y ninguno de los dos pedidos manda un email ni le pregunta a la base.
// Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { parseHookSecrets } from "../functions/_shared/auth_email_hook.ts";
import { createAuthEmailHandler } from "../functions/auth-email/handler.ts";
import { authEmailUrl, checkAuthEmail, validHookSecret } from "./auth-email-check.ts";

const NOW = new Date("2027-01-09T09:00:00Z");
const newSecret = (): string => `v1,whsec_${randomBytes(32).toString("base64")}`;

/** La función auth-email con [functionSecret] (o sin ninguno), y lo que hizo. */
function liveFunction(functionSecret: string | null) {
  const calls = { gate: 0, send: 0 };
  const handler = createAuthEmailHandler({
    config: {
      hookKeys: parseHookSecrets(functionSecret),
      hashSalt: "sal",
      resendKey: "re_x",
      mailFrom: "Radici <ciao@radicicucina.app>",
      emailTransport: "resend",
    },
    store: {
      gate: async () => {
        calls.gate++;
        return "send";
      },
    },
    sendEmail: async () => {
      calls.send++;
      return { ok: true, id: null };
    },
    log: () => {},
    now: () => NOW,
  });
  const fetchFn = ((input: string | URL | Request, init?: RequestInit) => handler(new Request(input, init))) as typeof fetch;
  return { fetchFn, calls };
}

const URL_ = "https://abcdefghijklmnopqrst.supabase.co/functions/v1/auth-email";

test("con el mismo secreto: pasa, sin mandar nada ni preguntarle a la base", async () => {
  const secret = newSecret();
  const fn = liveFunction(secret);
  assert.deepEqual(await checkAuthEmail({ url: URL_, secret, fetchFn: fn.fetchFn, now: NOW }), { kind: "ok" });
  assert.deepEqual(fn.calls, { gate: 0, send: 0 });
});

test("la función sin secreto (503) o con otro (401): no pasa, y lo dice", async () => {
  const secret = newSecret();
  const none = liveFunction(null);
  const result = await checkAuthEmail({ url: URL_, secret, fetchFn: none.fetchFn, now: NOW });
  assert.equal(result.kind, "bad");
  assert.match(result.kind === "bad" ? result.problem : "", /no tiene SEND_EMAIL_HOOK_SECRETS/);

  const other = liveFunction(newSecret());
  const wrong = await checkAuthEmail({ url: URL_, secret, fetchFn: other.fetchFn, now: NOW });
  assert.match(wrong.kind === "bad" ? wrong.problem : "", /otro secreto/);
  assert.deepEqual(other.calls, { gate: 0, send: 0 });
});

test("un secreto con otra forma no sale del runner; sin red, un mensaje sin detalles", async () => {
  let called = false;
  const spy = (async () => {
    called = true;
    return new Response(null, { status: 500 });
  }) as typeof fetch;
  for (const secret of ["", "whsec_abc", "v1,whsec_corto", `v1,whsec_${randomBytes(32).toString("base64")} v1,whsec_${randomBytes(32).toString("base64")}`]) {
    assert.equal(validHookSecret(secret), false, secret);
    assert.equal((await checkAuthEmail({ url: URL_, secret, fetchFn: spy })).kind, "bad");
  }
  assert.equal(called, false, "ningún pedido con un secreto inválido");

  const offline = (async () => {
    throw new Error("ECONNREFUSED 10.0.0.1 con datos");
  }) as typeof fetch;
  assert.deepEqual(await checkAuthEmail({ url: URL_, secret: newSecret(), fetchFn: offline }), {
    kind: "bad",
    problem: "no se pudo hablar con la función auth-email",
  });
});

test("una respuesta rara (200 a un pedido sin firma) no pasa", async () => {
  const ok = (async () => new Response("{}", { status: 200 })) as typeof fetch;
  const result = await checkAuthEmail({ url: URL_, secret: newSecret(), fetchFn: ok });
  assert.match(result.kind === "bad" ? result.problem : "", /sin firma, la función contestó 200/);
});

test("la URL es la de la función del proyecto", () => {
  assert.equal(authEmailUrl("abcdefghijklmnopqrst"), URL_);
});
