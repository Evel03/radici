// Tests de la Edge Function auth-email (el Send Email Hook, auth.md §16) con dependencias simuladas.
// Correr con: npm test (node --test). La función real (index.ts) solo conecta Supabase, Resend y Deno.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import type { AuthEmailKind } from "../_shared/auth_emails.ts";
import { parseHookSecrets, recipientHash, signWebhook } from "../_shared/auth_email_hook.ts";
import { StoreError, type LogFields, type LogLevel } from "../_shared/edge.ts";
import type { EmailMessage, SendOutcome } from "../_shared/resend.ts";
import { createAuthEmailHandler, type AuthEmailConfig, type GateDecision } from "./handler.ts";

const SECRET = `v1,whsec_${randomBytes(32).toString("base64")}`;
const KEYS = parseHookSecrets(SECRET);
const NOW = new Date("2027-01-09T09:00:00Z");
const SALT = "sal-de-prueba";
const USER_ID = "2f1d6a3e-8c1b-4b7e-9a51-0c3f2d4e5a6b";
const EMAIL = "clienta@ejemplo.test";
const TOKEN = "4815162342";
const TOKEN_HASH = "c".repeat(56);

const BASE_CONFIG: AuthEmailConfig = {
  hookKeys: KEYS,
  hashSalt: SALT,
  resendKey: "re_clave_auth",
  mailFrom: "Radici <ciao@radicicucina.app>",
  emailTransport: "resend",
};

interface Setup {
  config?: Partial<AuthEmailConfig>;
  decision?: GateDecision | Error;
  send?: SendOutcome;
}

function setup(options: Setup = {}) {
  const gates: Array<{ userId: string; kind: AuthEmailKind; hash: string }> = [];
  const sent: Array<{ message: EmailMessage; apiKey: string }> = [];
  const logs: Array<{ level: LogLevel; event: string; fields: LogFields }> = [];
  const handler = createAuthEmailHandler({
    config: { ...BASE_CONFIG, ...options.config },
    store: {
      async gate(userId, kind, hash) {
        gates.push({ userId, kind, hash });
        const decision = options.decision ?? "send";
        if (decision instanceof Error) throw decision;
        return decision;
      },
    },
    sendEmail: async (message, apiKey) => {
      sent.push({ message, apiKey });
      return options.send ?? { ok: true, id: "re_123" };
    },
    log: (level, event, fields = {}) => logs.push({ level, event, fields }),
    now: () => NOW,
  });
  return { handler, gates, sent, logs };
}

function hookBody(action: string): string {
  return JSON.stringify({
    user: { id: USER_ID, email: EMAIL, user_metadata: { locale: "it" }, app_metadata: { provider: "email" }, identities: [] },
    email_data: { token: TOKEN, token_hash: TOKEN_HASH, redirect_to: "", email_action_type: action, site_url: "https://radicicucina.app", token_new: "", token_hash_new: "" },
  });
}

async function signed(body: string, options: { id?: string; timestamp?: number; secret?: Uint8Array; method?: string } = {}): Promise<Request> {
  const id = options.id ?? "msg_0001";
  const timestamp = String(options.timestamp ?? NOW.getTime() / 1000);
  const signature = await signWebhook(options.secret ?? (KEYS[0] as Uint8Array), id, timestamp, body);
  return new Request("https://proyecto.supabase.co/functions/v1/auth-email", {
    method: options.method ?? "POST",
    headers: { "Content-Type": "application/json", "webhook-id": id, "webhook-timestamp": timestamp, "webhook-signature": signature },
    body: options.method === "GET" ? undefined : body,
  });
}

async function expectError(response: Response, status: number, message: string): Promise<void> {
  assert.equal(response.status, status);
  assert.deepEqual(await response.json(), { error: { http_code: status, message } });
}

/** Ningún log lleva el email, el código, el token_hash ni el id de la cuenta. */
function assertCleanLogs(logs: Array<{ fields: LogFields }>): void {
  const text = JSON.stringify(logs);
  for (const secret of [EMAIL, TOKEN, TOKEN_HASH, USER_ID]) assert.ok(!text.includes(secret), `un log lleva ${secret.slice(0, 8)}…`);
}

test("recuperación de una clienta: pregunta a la base con el hash (no el email), manda por Resend y contesta 200 {}", async () => {
  const { handler, gates, sent, logs } = setup();
  const response = await handler(await signed(hookBody("recovery")));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {});

  assert.deepEqual(gates, [{ userId: USER_ID, kind: "recovery", hash: await recipientHash(EMAIL, SALT) }]);
  assert.equal(sent.length, 1);
  const { message, apiKey } = sent[0] ?? assert.fail();
  assert.equal(apiKey, "re_clave_auth", "la clave de Resend de Auth, no la de los pedidos");
  assert.equal(message.to, EMAIL);
  assert.equal(message.from, BASE_CONFIG.mailFrom);
  assert.equal(message.replyTo, null);
  assert.equal(message.subject, "Scegli una nuova password");
  assert.ok(message.text.includes(`https://radicicucina.app/accesso/?lang=it#token_hash=${TOKEN_HASH}&type=recovery`));
  assert.match(message.idempotencyKey, /^auth-email-[0-9a-f]{64}$/);
  assertCleanLogs(logs);
  assert.deepEqual(logs.map((log) => log.event), ["hook_sent"]);
});

test("el mismo webhook dos veces (GoTrue reintenta): la misma clave de idempotencia para Resend", async () => {
  const { handler, sent } = setup();
  await handler(await signed(hookBody("recovery"), { id: "msg_reintento" }));
  await handler(await signed(hookBody("recovery"), { id: "msg_reintento" }));
  await handler(await signed(hookBody("recovery"), { id: "msg_otro" }));
  const keys = sent.map((entry) => entry.message.idempotencyKey);
  assert.equal(keys[0], keys[1]);
  assert.notEqual(keys[0], keys[2]);
});

test("el código de la cocina: magiclink (y email) salen con el código", async () => {
  for (const action of ["magiclink", "email"]) {
    const { handler, gates, sent } = setup();
    const response = await handler(await signed(hookBody(action)));
    assert.equal(response.status, 200, action);
    assert.equal(gates[0]?.kind, "magic_link");
    assert.equal(sent[0]?.message.subject, "Il tuo codice di accesso");
    assert.ok(sent[0]?.message.text.includes(TOKEN));
  }
});

test("cambio de email, invitación y reautenticación: 403 sin preguntarle a la base ni mandar nada", async () => {
  for (const action of ["email_change", "invite", "reauthentication", "algo_nuevo"]) {
    const { handler, gates, sent, logs } = setup();
    await expectError(await handler(await signed(hookBody(action))), 403, "email_not_allowed");
    assert.deepEqual(gates, [], action);
    assert.deepEqual(sent, [], action);
    assertCleanLogs(logs);
  }
});

test("lo que decide la base: skip contesta 200 sin mandar, limited 429, reject 403", async () => {
  const skip = setup({ decision: "skip" });
  const skipped = await skip.handler(await signed(hookBody("magiclink")));
  assert.equal(skipped.status, 200, "el código a una clienta no sale, sin decir por qué");
  assert.deepEqual(await skipped.json(), {});
  assert.deepEqual(skip.sent, []);

  const limited = setup({ decision: "limited" });
  await expectError(await limited.handler(await signed(hookBody("recovery"))), 429, "too_many_emails");
  assert.deepEqual(limited.sent, []);

  const reject = setup({ decision: "reject" });
  await expectError(await reject.handler(await signed(hookBody("recovery"))), 403, "email_not_allowed");
  assert.deepEqual(reject.sent, []);
});

test("firma: sin secreto 503; vieja, de otro secreto o sin cabeceras 401; nada llega a la base", async () => {
  const noSecret = setup({ config: { hookKeys: [] } });
  await expectError(await noSecret.handler(await signed(hookBody("recovery"))), 503, "hook_not_configured");
  assert.equal(noSecret.logs[0]?.level, "error");

  for (const request of [
    await signed(hookBody("recovery"), { timestamp: NOW.getTime() / 1000 - 600 }),
    await signed(hookBody("recovery"), { secret: randomBytes(32) }),
    new Request("https://proyecto.supabase.co/functions/v1/auth-email", { method: "POST", body: hookBody("recovery") }),
  ]) {
    const { handler, gates, sent } = setup();
    await expectError(await handler(request), 401, "invalid_signature");
    assert.deepEqual(gates, []);
    assert.deepEqual(sent, []);
  }

  // El cuerpo cambiado después de firmar.
  const { handler } = setup();
  const original = await signed(hookBody("recovery"));
  const tampered = new Request(original.url, { method: "POST", headers: original.headers, body: hookBody("magiclink") });
  await expectError(await handler(tampered), 401, "invalid_signature");
});

test("método, tamaño y forma del pedido", async () => {
  const { handler } = setup();
  await expectError(await handler(await signed("", { method: "GET" })), 405, "method_not_allowed");
  await expectError(await handler(await signed("x".repeat(70 * 1024))), 413, "invalid_body");
  await expectError(await handler(await signed('{"user":{}}')), 400, "invalid_payload");
  await expectError(await handler(await signed(hookBody("recovery").replace(TOKEN_HASH, ""))), 400, "invalid_payload");
});

test("errores al decidir o mandar: 500 y 502, sin datos en el log", async () => {
  const failing = setup({ decision: new StoreError("auth_email_gate", "XX000", "boom") });
  await expectError(await failing.handler(await signed(hookBody("recovery"))), 500, "gate_failed");
  assert.deepEqual(failing.sent, []);
  assertCleanLogs(failing.logs);

  const resend = setup({ send: { ok: false, status: 422, errorName: "validation_error" } });
  await expectError(await resend.handler(await signed(hookBody("recovery"))), 502, "email_not_sent");
  assertCleanLogs(resend.logs);
  assert.deepEqual(resend.logs.at(-1)?.fields, { kind: "recovery", status: 422, error: "validation_error" });
});

test("configuración: sin sal ni clave de Resend no sale nada; EMAIL_TRANSPORT=log no manda", async () => {
  const noSalt = setup({ config: { hashSalt: null } });
  await expectError(await noSalt.handler(await signed(hookBody("recovery"))), 503, "hook_not_configured");
  assert.deepEqual(noSalt.gates, [], "sin sal no se guarda nada");

  const noKey = setup({ config: { resendKey: null } });
  await expectError(await noKey.handler(await signed(hookBody("recovery"))), 503, "email_not_configured");
  assert.deepEqual(noKey.sent, []);
  assert.deepEqual(noKey.logs.at(-1)?.fields, { missing: ["RESEND_AUTH_KEY"] });

  const logOnly = setup({ config: { emailTransport: "log", resendKey: null } });
  const response = await logOnly.handler(await signed(hookBody("recovery")));
  assert.equal(response.status, 200);
  assert.deepEqual(logOnly.sent, []);
  assertCleanLogs(logOnly.logs);
});
