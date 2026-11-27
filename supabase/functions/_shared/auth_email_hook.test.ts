// Tests de auth_email_hook.ts: la firma Standard Webhooks (contra una implementación aparte con node:crypto), el
// pedido de GoTrue y el email que arma el hook. Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac, randomBytes } from "node:crypto";
import {
  ACTION_KINDS,
  DEFAULT_AUTH_LOCALE,
  WEBHOOK_TOLERANCE_SECONDS,
  hookError,
  missingValue,
  parseHookPayload,
  parseHookSecrets,
  recipientHash,
  renderHookEmail,
  signWebhook,
  verifyWebhook,
} from "./auth_email_hook.ts";

const KEY = randomBytes(32);
const SECRET = `v1,whsec_${KEY.toString("base64")}`;
const NOW = new Date("2027-01-09T09:00:00Z");
const TS = String(NOW.getTime() / 1000);
const ID = "msg_2b7Qd1hTg9x";
const BODY = '{"user":{"id":"x"},"email_data":{}}';

/** La firma de la especificación, escrita aparte (node:crypto), para no probar la implementación contra sí misma. */
function reference(key: Buffer, id: string, ts: string, body: string): string {
  return `v1,${createHmac("sha256", key).update(`${id}.${ts}.${body}`).digest("base64")}`;
}

const USER_ID = "2f1d6a3e-8c1b-4b7e-9a51-0c3f2d4e5a6b";
function payload(action: string, extra: Record<string, unknown> = {}): string {
  return JSON.stringify({
    user: { id: USER_ID, email: "Clienta@Ejemplo.test", user_metadata: { locale: "es" }, app_metadata: {} },
    email_data: { token: "1234567890", token_hash: "a".repeat(56), redirect_to: "", email_action_type: action, site_url: "", token_new: "", token_hash_new: "", ...extra },
  });
}

test("secretos: v1,whsec_<base64>, uno o varios (para cambiarlo sin cortar); lo demás se ignora", () => {
  assert.equal(parseHookSecrets(SECRET).length, 1);
  assert.deepEqual([...parseHookSecrets(SECRET)[0] ?? []], [...KEY]);
  const other = `v1,whsec_${randomBytes(32).toString("base64")}`;
  assert.equal(parseHookSecrets(`${SECRET}|${other}`).length, 2);
  assert.equal(parseHookSecrets(`${SECRET} ${other}`).length, 2);
  assert.deepEqual(parseHookSecrets(""), []);
  assert.deepEqual(parseHookSecrets(null), []);
  assert.deepEqual(parseHookSecrets("whsec_sinversion v1,otra_cosa v1,whsec_YQ=="), [], "sin forma o una clave de menos de 16 bytes");
});

test("firma: la de la especificación (HMAC-SHA256 de id.timestamp.cuerpo, en base64) es la que se acepta", async () => {
  const keys = parseHookSecrets(SECRET);
  const signature = reference(KEY, ID, TS, BODY);
  assert.equal(await signWebhook(keys[0] as Uint8Array, ID, TS, BODY), signature);
  assert.deepEqual(await verifyWebhook(keys, { id: ID, timestamp: TS, signature }, BODY, NOW), { ok: true });
  // Varias firmas en la cabecera (GoTrue firma con cada secreto): alcanza con una.
  const several = `v1,${randomBytes(32).toString("base64")} ${signature}`;
  assert.deepEqual(await verifyWebhook(keys, { id: ID, timestamp: TS, signature: several }, BODY, NOW), { ok: true });
  // Con dos secretos cargados, sirve la del segundo.
  const rotated = parseHookSecrets(`v1,whsec_${randomBytes(32).toString("base64")}|${SECRET}`);
  assert.deepEqual(await verifyWebhook(rotated, { id: ID, timestamp: TS, signature }, BODY, NOW), { ok: true });
});

test("firma: otro cuerpo, otro id, otro secreto o sin firma no pasan", async () => {
  const keys = parseHookSecrets(SECRET);
  const signature = reference(KEY, ID, TS, BODY);
  const bad = { ok: false, reason: "bad_signature" };
  assert.deepEqual(await verifyWebhook(keys, { id: ID, timestamp: TS, signature }, `${BODY} `, NOW), bad);
  assert.deepEqual(await verifyWebhook(keys, { id: "msg_otro", timestamp: TS, signature }, BODY, NOW), bad);
  assert.deepEqual(await verifyWebhook(parseHookSecrets(`v1,whsec_${randomBytes(32).toString("base64")}`), { id: ID, timestamp: TS, signature }, BODY, NOW), bad);
  assert.deepEqual(await verifyWebhook(keys, { id: ID, timestamp: TS, signature: "v1,no-es-base64!" }, BODY, NOW), bad);
  for (const headers of [
    { id: null, timestamp: TS, signature },
    { id: ID, timestamp: null, signature },
    { id: ID, timestamp: TS, signature: null },
    { id: ID, timestamp: "ayer", signature },
  ]) {
    assert.deepEqual(await verifyWebhook(keys, headers, BODY, NOW), { ok: false, reason: "missing_headers" });
  }
  assert.deepEqual(await verifyWebhook([], { id: ID, timestamp: TS, signature }, BODY, NOW), { ok: false, reason: "no_secret" });
});

test(`firma: más de ${WEBHOOK_TOLERANCE_SECONDS / 60} minutos de diferencia (para atrás o para adelante) no pasa`, async () => {
  const keys = parseHookSecrets(SECRET);
  for (const delta of [-WEBHOOK_TOLERANCE_SECONDS - 1, WEBHOOK_TOLERANCE_SECONDS + 1]) {
    const ts = String(Number(TS) + delta);
    const signature = reference(KEY, ID, ts, BODY);
    assert.deepEqual(await verifyWebhook(keys, { id: ID, timestamp: ts, signature }, BODY, NOW), { ok: false, reason: "stale" });
  }
  const edge = String(Number(TS) - WEBHOOK_TOLERANCE_SECONDS);
  assert.deepEqual(await verifyWebhook(keys, { id: ID, timestamp: edge, signature: reference(KEY, ID, edge, BODY) }, BODY, NOW), { ok: true });
});

test("el pedido de GoTrue: el tipo de email pasa a la plantilla; lo desconocido queda sin plantilla", () => {
  assert.deepEqual(ACTION_KINDS, {
    magiclink: "magic_link",
    email: "magic_link",
    signup: "confirmation",
    recovery: "recovery",
    email_change: "email_change",
    invite: "invite",
    reauthentication: "reauthentication",
  });
  const recovery = parseHookPayload(payload("recovery"));
  assert.deepEqual(recovery, {
    userId: USER_ID,
    email: "Clienta@Ejemplo.test",
    locale: "es",
    action: "recovery",
    kind: "recovery",
    token: "1234567890",
    tokenHash: "a".repeat(56),
  });
  assert.equal(parseHookPayload(payload("magiclink"))?.kind, "magic_link");
  assert.equal(parseHookPayload(payload("signup"))?.kind, "confirmation");
  assert.equal(parseHookPayload(payload("otra_cosa"))?.kind, null);
  assert.equal(parseHookPayload(payload("constructor"))?.kind, null, "nada del prototipo cuenta como tipo");
  assert.equal(parseHookPayload(payload("recovery", { token_hash: "pkce_" + "b".repeat(56) }))?.tokenHash, `pkce_${"b".repeat(56)}`);
});

test("el pedido de GoTrue: idioma por defecto, y nada con otra forma entra al email", () => {
  const noLocale = JSON.parse(payload("recovery")) as { user: Record<string, unknown> };
  noLocale.user["user_metadata"] = { locale: "fr" };
  assert.equal(parseHookPayload(JSON.stringify(noLocale))?.locale, DEFAULT_AUTH_LOCALE);
  for (const broken of [
    "no es json",
    "[]",
    JSON.stringify({ user: { id: USER_ID, email: "a@b.it" } }),
    payload("recovery").replace(USER_ID, "no-es-uuid"),
    payload("recovery").replace("Clienta@Ejemplo.test", ""),
    payload("recovery", { token: "<b>123</b>" }),
    payload("recovery", { token_hash: '"><script>' }),
    payload("Recovery"),
  ]) {
    assert.equal(parseHookPayload(broken), null, broken.slice(0, 60));
  }
});

test("hash del destinatario: HMAC con la sal, sin mayúsculas ni espacios; el email no se puede leer de él", async () => {
  const hash = await recipientHash(" Clienta@Ejemplo.test ", "sal-1");
  assert.match(hash, /^[0-9a-f]{64}$/);
  assert.equal(await recipientHash("clienta@ejemplo.test", "sal-1"), hash);
  assert.notEqual(await recipientHash("clienta@ejemplo.test", "sal-2"), hash, "otra sal, otro hash");
  assert.ok(!hash.includes("clienta"));
});

test("el email: el código para la cocina, el link a /accesso/ para el alta y la contraseña; nunca el email de la cuenta", () => {
  const values = { locale: "es" as const, token: "1234567890", tokenHash: "a".repeat(56) };
  const code = renderHookEmail("magic_link", values);
  assert.equal(code.subject, "Tu código de acceso");
  assert.ok(code.html.includes("1234567890") && code.text.includes("1234567890"));
  assert.ok(!code.html.includes("accesso") && !code.text.includes("accesso"), "el código va sin link");

  const recovery = renderHookEmail("recovery", values);
  const link = `https://radicicucina.app/accesso/?lang=es#token_hash=${"a".repeat(56)}&type=recovery`;
  assert.ok(recovery.text.includes(link), recovery.text);
  assert.ok(recovery.html.includes(link.replace("&", "&amp;")) || recovery.html.includes(link));
  assert.ok(!recovery.html.includes("1234567890") && !recovery.text.includes("1234567890"), "el link va sin código");
  // El alta: el código, para escribirlo en la app (sin link).
  const confirmation = renderHookEmail("confirmation", values);
  assert.ok(confirmation.html.includes("1234567890") && confirmation.text.includes("1234567890"));
  assert.ok(!confirmation.html.includes("accesso") && !confirmation.text.includes("accesso"));
  for (const email of [code, recovery]) assert.ok(!/clienta|ejemplo\.test/i.test(email.html + email.text));
});

test("lo que falta para armar cada email, y el error en la forma de GoTrue", () => {
  assert.equal(missingValue("magic_link", { token: "", tokenHash: "x" }), true);
  assert.equal(missingValue("magic_link", { token: "123456", tokenHash: "" }), false);
  assert.equal(missingValue("recovery", { token: "123456", tokenHash: "" }), true);
  assert.equal(missingValue("confirmation", { token: "", tokenHash: "abc" }), true);
  assert.equal(missingValue("confirmation", { token: "123456", tokenHash: "" }), false);
  assert.deepEqual(hookError(429, "too_many_emails"), { error: { http_code: 429, message: "too_many_emails" } });
});
