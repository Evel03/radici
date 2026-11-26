// Tests del control del captcha de Auth en el despliegue (auth-captcha-check.ts). Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  CHECK_EMAIL,
  DUMMY_TOKEN,
  checkAuthRequiresCaptcha,
  checkSecret,
  disableCaptcha,
  isSecretShape,
  isTestSecret,
  verifyOrRollback,
  type AuthCheckOptions,
} from "./auth-captcha-check.ts";

const SECRET = "0x4AAAAAAABkMYinukE8nzYS_BcFvA_HjqY";
const SCRIPT = fileURLToPath(new URL("./auth-captcha-check.ts", import.meta.url));

interface Call {
  url: string;
  init: RequestInit;
}

function fakeFetch(reply: (call: Call) => Response | Promise<Response>) {
  const calls: Call[] = [];
  const fn = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const call = { url: String(input), init: init ?? {} };
    calls.push(call);
    return reply(call);
  }) as typeof fetch;
  return { fn, calls };
}
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

test("formas: las secretas de prueba de Cloudflare y la forma de una real", () => {
  for (const testSecret of ["1x0000000000000000000000000000000AA", "2x0000000000000000000000000000000AA", "3x0000000000000000000000000000000AA"]) {
    assert.equal(isTestSecret(testSecret), true, testSecret);
  }
  assert.equal(isTestSecret(SECRET), false);
  assert.equal(isSecretShape(SECRET), true);
  for (const bad of ["", "0x", "0x4AAA con espacio", "1x00000000000000000000AA", "sb_secret_abc", `"${SECRET}"`]) assert.equal(isSecretShape(bad), false, bad);
});

test("secret: con una secreta válida Cloudflare responde invalid-input-response al token inventado → ok", async () => {
  const fake = fakeFetch(() => json(200, { success: false, "error-codes": ["invalid-input-response"] }));
  assert.deepEqual(await checkSecret(` ${SECRET} `, fake.fn, "https://cf.test/siteverify"), { kind: "ok" });
  assert.equal(fake.calls.length, 1);
  assert.equal(fake.calls[0]!.url, "https://cf.test/siteverify");
  const sent = new URLSearchParams(String(fake.calls[0]!.init.body));
  assert.equal(sent.get("secret"), SECRET, "sin los espacios");
  assert.equal(sent.get("response"), DUMMY_TOKEN);
});

test("secret: falta, es de prueba o no tiene forma → corta sin llamar a Cloudflare", async () => {
  for (const [secret, pattern] of [
    ["", /falta/],
    ["1x0000000000000000000000000000000AA", /prueba/],
    ["0x4AAA corta", /forma/],
  ] as const) {
    const fake = fakeFetch(() => json(200, {}));
    const result = await checkSecret(secret, fake.fn);
    assert.equal(result.kind, "bad");
    assert.match(result.kind === "bad" ? result.message : "", pattern);
    assert.equal(fake.calls.length, 0);
  }
});

test("secret: Cloudflare no la reconoce, acepta el token inventado, responde raro o no responde → corta", async () => {
  const cases: Array<[() => Response | Promise<Response>, RegExp]> = [
    [() => json(200, { success: false, "error-codes": ["invalid-input-secret"] }), /no reconoce/],
    [() => json(200, { success: true }), /aceptó un token inventado/],
    [() => json(200, { success: false, "error-codes": ["internal-error"] }), /inesperada/],
    [() => new Response("<html>", { status: 502 }), /502/],
    [() => Promise.reject(new TypeError("offline")), /no se pudo consultar/],
  ];
  for (const [reply, pattern] of cases) {
    const result = await checkSecret(SECRET, fakeFetch(reply).fn);
    assert.equal(result.kind, "bad");
    assert.match(result.kind === "bad" ? result.message : "", pattern);
  }
});

/** Auth simulado: cómo responde a un pedido sin token y a uno con el token inventado. */
function fakeAuth(withoutToken: () => Response, withDummy: () => Response, patchStatus = 200) {
  return fakeFetch((call) => {
    if (call.url.endsWith("/config/auth")) return new Response("{}", { status: patchStatus });
    const body = JSON.parse(String(call.init.body)) as { gotrue_meta_security?: { captcha_token?: string } };
    return body.gotrue_meta_security ? withDummy() : withoutToken();
  });
}
const options = (fn: typeof fetch): AuthCheckOptions => ({
  projectRef: "abcdefgh",
  publishableKey: "sb_publishable_x",
  accessToken: "sbp_token",
  fetchFn: fn,
  authBase: "https://auth.test",
  managementBase: "https://api.test",
});
const noToken = () => json(400, { code: "captcha_failed", message: "captcha protection: request disallowed (no captcha_token found)" });
const goodSecret = () => json(400, { code: "captcha_failed", message: "captcha protection: request disallowed (invalid-input-response)" });

test("auth: exige el token y Cloudflare reconoce la secreta de Supabase → ok, sin apagar nada", async () => {
  const fake = fakeAuth(noToken, goodSecret);
  assert.equal(await verifyOrRollback(options(fake.fn)), null);
  assert.equal(fake.calls.length, 2);
  const [first, second] = fake.calls.map((c) => ({ url: c.url, body: JSON.parse(String(c.init.body)) as Record<string, unknown>, headers: c.init.headers as Record<string, string> }));
  assert.equal(first!.url, "https://auth.test/auth/v1/otp");
  assert.deepEqual(first!.body, { email: CHECK_EMAIL, create_user: false }, "nunca crea la cuenta");
  assert.deepEqual(second!.body, { email: CHECK_EMAIL, create_user: false, gotrue_meta_security: { captcha_token: DUMMY_TOKEN } });
  assert.equal(first!.headers["apikey"], "sb_publishable_x");
  assert.equal(first!.headers["Authorization"], undefined, "como cualquier visitante: sin credenciales de admin (las de admin se saltean el captcha)");
});

test("auth: si Auth no exige el captcha o tiene otra secreta, lo apaga y falla", async () => {
  const cases: Array<[() => Response, () => Response, RegExp]> = [
    // Sin token, Auth sigue de largo (el handler dice que no hay altas): no exige el captcha.
    [() => json(422, { code: "otp_disabled", message: "Signups not allowed for otp" }), goodSecret, /no está exigiendo el captcha/],
    [() => json(200, {}), goodSecret, /no está exigiendo el captcha/],
    [noToken, () => json(400, { code: "captcha_failed", message: "captcha protection: request disallowed (invalid-input-secret)" }), /no reconoce/],
    [noToken, () => json(500, { code: "unexpected_failure", message: "captcha verification process failed" }), /no quedó bien/],
    [() => json(429, { code: "over_request_rate_limit" }), goodSecret, /captcha_failed/],
  ];
  for (const [without, dummy, pattern] of cases) {
    const fake = fakeAuth(without, dummy);
    const error = await verifyOrRollback(options(fake.fn));
    assert.ok(error, "falla");
    assert.match(error!, pattern);
    assert.match(error!, /Se apagó el captcha/);
    const patch = fake.calls.find((c) => c.url === "https://api.test/v1/projects/abcdefgh/config/auth");
    assert.ok(patch, "apaga el captcha");
    assert.equal(patch!.init.method, "PATCH");
    assert.deepEqual(JSON.parse(String(patch!.init.body)), { security_captcha_enabled: false }, "solo el captcha: nada más");
    assert.equal((patch!.init.headers as Record<string, string>)["Authorization"], "Bearer sbp_token");
  }
});

test("auth: si tampoco se puede apagar, el error pide hacerlo a mano", async () => {
  const fake = fakeAuth(() => json(200, {}), goodSecret, 500);
  assert.match((await verifyOrRollback(options(fake.fn)))!, /NO se pudo apagar el captcha/);
  assert.equal(await disableCaptcha(options(fakeFetch(() => Promise.reject(new TypeError("x"))).fn)), false);
});

test("auth: sin respuesta de Auth → falla y apaga", async () => {
  const fake = fakeFetch((call) => (call.url.endsWith("/config/auth") ? new Response("{}", { status: 200 }) : Promise.reject(new TypeError("offline"))));
  assert.match((await verifyOrRollback(options(fake.fn)))!, /no respondió.*Se apagó/s);
  assert.deepEqual(await checkAuthRequiresCaptcha(options(fakeFetch(() => Promise.reject(new TypeError("x"))).fn)), {
    kind: "bad",
    message: "Auth no respondió al pedido de código de prueba",
  });
});

test("línea de comandos: sin la secreta o sin las credenciales sale con error, sin imprimir valores", () => {
  const run = (args: string[], env: Record<string, string>) => {
    try {
      execFileSync(process.execPath, [SCRIPT, ...args], { env: { ...process.env, TURNSTILE_AUTH_SECRET_KEY: "", SUPABASE_PROJECT_REF: "", SUPABASE_PUBLISHABLE_KEY: "", SUPABASE_ACCESS_TOKEN: "", ...env }, encoding: "utf8", stdio: "pipe" });
      return { status: 0, stderr: "" };
    } catch (error) {
      const e = error as { status?: number; stderr?: string };
      return { status: e.status ?? -1, stderr: String(e.stderr ?? "") };
    }
  };
  const missing = run(["secret"], {});
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /::error::Captcha de Auth: falta el secreto TURNSTILE_AUTH_SECRET_KEY/);
  const testSecret = run(["secret"], { TURNSTILE_AUTH_SECRET_KEY: "1x0000000000000000000000000000000AA" });
  assert.match(testSecret.stderr, /prueba/);
  assert.ok(!testSecret.stderr.includes("1x0000000000000000000000000000000AA"), "no imprime la secreta");
  assert.match(run(["auth"], {}).stderr, /faltan SUPABASE_PROJECT_REF/);
  assert.match(run(["otra"], {}).stderr, /uso:/);
});
