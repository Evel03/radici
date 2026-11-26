import { describe, expect, it, vi } from "vitest";
import { createAuthApi } from "./api.ts";

const URL_BASE = "https://abcdefgh.supabase.co";
const KEY = "sb_publishable_abc123";
const HASH = "f".repeat(56);

interface Call {
  url: string;
  init: RequestInit;
}

/** fetch simulado: responde lo que diga `reply` y anota cada llamada. */
function fakeFetch(reply: (call: Call) => Response | Promise<Response>) {
  const calls: Call[] = [];
  const fn = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const call = { url: String(input), init: init ?? {} };
    calls.push(call);
    return reply(call);
  });
  return { fetch: fn as unknown as typeof fetch, calls };
}

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const api = (reply: (call: Call) => Response | Promise<Response>) => {
  const fake = fakeFetch(reply);
  return { api: createAuthApi({ supabaseUrl: URL_BASE, publishableKey: KEY, fetch: fake.fetch }), calls: fake.calls };
};
const headersOf = (call: Call) => call.init.headers as Record<string, string>;
const bodyOf = (call: Call) => JSON.parse(String(call.init.body)) as Record<string, unknown>;

describe("verify (POST /verify)", () => {
  it("manda SOLO type y token_hash, con la clave publicable y sin cookies ni referrer", async () => {
    const { api: auth, calls } = api(() => json(200, { access_token: "AT", refresh_token: "RT", user: { email: "ana@libero.it" } }));
    await expect(auth.verify({ tokenHash: HASH, type: "email" })).resolves.toEqual({ kind: "ok", accessToken: "AT", email: "ana@libero.it" });
    expect(calls).toHaveLength(1);
    const [call] = calls;
    expect(call!.url).toBe(`${URL_BASE}/auth/v1/verify`);
    expect(call!.init.method).toBe("POST");
    expect(bodyOf(call!)).toEqual({ type: "email", token_hash: HASH });
    expect(Object.keys(bodyOf(call!)).sort()).toEqual(["token_hash", "type"]);
    expect(headersOf(call!)["apikey"]).toBe(KEY);
    expect(headersOf(call!)["Authorization"]).toBeUndefined();
    expect(call!.init.credentials).toBe("omit");
    expect(call!.init.referrerPolicy).toBe("no-referrer");
    expect(call!.init.cache).toBe("no-store");
  });

  it("el resultado nunca trae el refresh token (no se usa: la sesión dura lo que tarda en elegirse la contraseña)", async () => {
    const { api: auth } = api(() => json(200, { access_token: "AT", refresh_token: "RT-SECRETO", user: { email: "a@b.it" } }));
    expect(JSON.stringify(await auth.verify({ tokenHash: HASH, type: "recovery" }))).not.toContain("RT-SECRETO");
  });

  it("vencido o ya usado (403 otp_expired), o un link mal formado (400): expired", async () => {
    for (const [status, code] of [
      [403, "otp_expired"],
      [400, "validation_failed"],
      [404, "user_not_found"],
    ] as const) {
      const { api: auth } = api(() => json(status, { code, message: "x" }));
      await expect(auth.verify({ tokenHash: HASH, type: "email" })).resolves.toEqual({ kind: "expired" });
    }
  });

  it("429: rateLimited; 500, sin conexión o una respuesta rara: failed", async () => {
    await expect(api(() => json(429, { code: "over_request_rate_limit" })).api.verify({ tokenHash: HASH, type: "email" })).resolves.toEqual({
      kind: "rateLimited",
    });
    await expect(api(() => json(500, {})).api.verify({ tokenHash: HASH, type: "email" })).resolves.toEqual({ kind: "failed" });
    await expect(
      api(() => {
        throw new TypeError("Failed to fetch");
      }).api.verify({ tokenHash: HASH, type: "email" }),
    ).resolves.toEqual({ kind: "failed" });
    await expect(api(() => json(200, { user: { email: "a@b.it" } })).api.verify({ tokenHash: HASH, type: "email" })).resolves.toEqual({ kind: "failed" });
    await expect(api(() => new Response("<html>", { status: 200 })).api.verify({ tokenHash: HASH, type: "email" })).resolves.toEqual({ kind: "failed" });
  });
});

describe("updatePassword (PUT /user)", () => {
  it("manda solo la contraseña, con el access token de la sesión", async () => {
    const { api: auth, calls } = api(() => json(200, { id: "u1" }));
    await expect(auth.updatePassword("AT", "Bergamo2026")).resolves.toEqual({ kind: "ok" });
    expect(calls[0]!.url).toBe(`${URL_BASE}/auth/v1/user`);
    expect(calls[0]!.init.method).toBe("PUT");
    expect(bodyOf(calls[0]!)).toEqual({ password: "Bergamo2026" });
    expect(headersOf(calls[0]!)["Authorization"]).toBe("Bearer AT");
    expect(headersOf(calls[0]!)["apikey"]).toBe(KEY);
  });

  it("weak_password con sus razones (en `code` o, sin la versión de API, en `error_code`)", async () => {
    await expect(
      api(() => json(422, { code: "weak_password", message: "x", weak_password: { reasons: ["length", "pwned", 3] } })).api.updatePassword("AT", "x"),
    ).resolves.toEqual({ kind: "weak", reasons: ["length", "pwned"] });
    await expect(api(() => json(422, { code: 422, error_code: "weak_password", msg: "x" })).api.updatePassword("AT", "x")).resolves.toEqual({
      kind: "weak",
      reasons: [],
    });
  });

  it("same_password: same; 401/403 o una sesión que ya no sirve: session", async () => {
    await expect(api(() => json(422, { code: "same_password" })).api.updatePassword("AT", "x")).resolves.toEqual({ kind: "same" });
    for (const [status, code] of [
      [401, "bad_jwt"],
      [403, "session_not_found"],
      [400, "reauthentication_needed"],
      [400, "current_password_required"],
    ] as const) {
      await expect(api(() => json(status, { code })).api.updatePassword("AT", "x")).resolves.toEqual({ kind: "session" });
    }
  });

  it("429: rateLimited; otro 422: weak sin razones; 500 o sin conexión: failed", async () => {
    await expect(api(() => json(429, {})).api.updatePassword("AT", "x")).resolves.toEqual({ kind: "rateLimited" });
    await expect(api(() => json(422, { code: "validation_failed" })).api.updatePassword("AT", "x")).resolves.toEqual({ kind: "weak", reasons: [] });
    await expect(api(() => json(500, {})).api.updatePassword("AT", "x")).resolves.toEqual({ kind: "failed" });
    await expect(
      api(() => {
        throw new TypeError("offline");
      }).api.updatePassword("AT", "x"),
    ).resolves.toEqual({ kind: "failed" });
  });
});

describe("logout (POST /logout?scope=local)", () => {
  it("cierra solo esta sesión", async () => {
    const { api: auth, calls } = api(() => new Response(null, { status: 204 }));
    await auth.logout("AT");
    expect(calls[0]!.url).toBe(`${URL_BASE}/auth/v1/logout?scope=local`);
    expect(calls[0]!.init.method).toBe("POST");
    expect(headersOf(calls[0]!)["Authorization"]).toBe("Bearer AT");
    expect(calls[0]!.init.body).toBeUndefined();
  });

  it("nunca lanza", async () => {
    await expect(
      api(() => {
        throw new TypeError("offline");
      }).api.logout("AT"),
    ).resolves.toBeUndefined();
    await expect(api(() => json(401, {})).api.logout("AT")).resolves.toBeUndefined();
  });
});

describe("resend («Reinvia»)", () => {
  it("alta: POST /resend type signup, con el email y el token del captcha", async () => {
    const { api: auth, calls } = api(() => json(200, {}));
    await expect(auth.resend("email", "ana@libero.it", "CAPTCHA")).resolves.toEqual({ kind: "ok" });
    expect(calls[0]!.url).toBe(`${URL_BASE}/auth/v1/resend`);
    expect(bodyOf(calls[0]!)).toEqual({ type: "signup", email: "ana@libero.it", gotrue_meta_security: { captcha_token: "CAPTCHA" } });
    expect(headersOf(calls[0]!)["Authorization"]).toBeUndefined();
  });

  it("contraseña: POST /recover con el email y el token del captcha", async () => {
    const { api: auth, calls } = api(() => json(200, {}));
    await expect(auth.resend("recovery", "ana@libero.it", "CAPTCHA")).resolves.toEqual({ kind: "ok" });
    expect(calls[0]!.url).toBe(`${URL_BASE}/auth/v1/recover`);
    expect(bodyOf(calls[0]!)).toEqual({ email: "ana@libero.it", gotrue_meta_security: { captcha_token: "CAPTCHA" } });
  });

  it("captcha rechazado, email no válido, demasiados pedidos y fallas", async () => {
    await expect(api(() => json(400, { code: "captcha_failed" })).api.resend("email", "a@b.it", "C")).resolves.toEqual({ kind: "captcha" });
    await expect(api(() => json(400, { code: "email_address_invalid" })).api.resend("email", "a@b.it", "C")).resolves.toEqual({ kind: "invalidEmail" });
    await expect(api(() => json(422, { code: "validation_failed" })).api.resend("recovery", "a@b.it", "C")).resolves.toEqual({ kind: "invalidEmail" });
    await expect(api(() => json(429, { code: "over_email_send_rate_limit" })).api.resend("email", "a@b.it", "C")).resolves.toEqual({
      kind: "rateLimited",
    });
    await expect(api(() => json(500, {})).api.resend("email", "a@b.it", "C")).resolves.toEqual({ kind: "failed" });
  });
});

describe("sin configuración", () => {
  it("sin URL o sin clave: no disponible y no llama a nadie", async () => {
    for (const options of [
      { supabaseUrl: null, publishableKey: KEY },
      { supabaseUrl: URL_BASE, publishableKey: null },
    ]) {
      const fake = fakeFetch(() => json(200, {}));
      const auth = createAuthApi({ ...options, fetch: fake.fetch });
      expect(auth.available).toBe(false);
      await expect(auth.verify({ tokenHash: HASH, type: "email" })).resolves.toEqual({ kind: "failed" });
      await expect(auth.resend("email", "a@b.it", "C")).resolves.toEqual({ kind: "failed" });
      expect(fake.calls).toEqual([]);
    }
    expect(createAuthApi({ supabaseUrl: URL_BASE, publishableKey: KEY }).available).toBe(true);
  });
});
