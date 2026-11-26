import { describe, expect, it, vi } from "vitest";
import type { AuthApi, ResendResult, UpdateResult, VerifyResult } from "./api.ts";
import { createAccess, isPlausibleEmail, type AccessState } from "./flow.ts";
import type { LinkRead } from "./link.ts";

const HASH = "c".repeat(56);
const ACCESS_TOKEN = "eyJ.access-token-SECRETO.x";
const EMAIL = "ana@libero.it";
const linkRead = (type: "email" | "recovery" = "email"): LinkRead => ({ kind: "link", link: { tokenHash: HASH, type } });

/** Una promesa que se resuelve desde afuera (para ver los estados intermedios). */
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

function fakeApi(overrides: Partial<AuthApi> = {}) {
  const api = {
    available: true,
    verify: vi.fn(async (): Promise<VerifyResult> => ({ kind: "ok", accessToken: ACCESS_TOKEN, email: EMAIL })),
    updatePassword: vi.fn(async (): Promise<UpdateResult> => ({ kind: "ok" })),
    logout: vi.fn(async () => {}),
    resend: vi.fn(async (): Promise<ResendResult> => ({ kind: "ok" })),
    ...overrides,
  };
  return api;
}

function setup(read: LinkRead = linkRead(), apiOverrides: Partial<AuthApi> = {}, captcha: () => Promise<string | null> = async () => "CAPTCHA") {
  const api = fakeApi(apiOverrides);
  const captchaToken = vi.fn(captcha);
  const access = createAccess(read, { api, captchaToken });
  const states: AccessState[] = [];
  access.subscribe(() => states.push(access.state));
  return { api, access, states, captchaToken };
}

/** Lo que se pinta nunca lleva el token del link ni el de la sesión. */
function expectNoSecrets(states: readonly AccessState[]) {
  for (const state of states) {
    const text = JSON.stringify(state);
    expect(text).not.toContain(HASH);
    expect(text).not.toContain(ACCESS_TOKEN);
  }
}

describe("estado inicial", () => {
  it("con un link completo espera el toque en «Conferma», sin llamar a nadie", () => {
    const { api, access, captchaToken } = setup(linkRead("recovery"));
    expect(access.state).toEqual({ kind: "confirm", type: "recovery", busy: false, error: null });
    expect(api.verify).not.toHaveBeenCalled();
    expect(api.updatePassword).not.toHaveBeenCalled();
    expect(api.logout).not.toHaveBeenCalled();
    expect(api.resend).not.toHaveBeenCalled();
    expect(captchaToken).not.toHaveBeenCalled();
  });

  it("sin link, o con uno ilegible de tipo desconocido: missing", () => {
    expect(setup({ kind: "none" }).access.state).toEqual({ kind: "missing" });
    expect(setup({ kind: "broken", type: null }).access.state).toEqual({ kind: "missing" });
  });

  it("con un link cortado de tipo conocido: expired, para pedir otro", () => {
    expect(setup({ kind: "broken", type: "email" }).access.state).toEqual({
      kind: "expired",
      type: "email",
      reason: "link",
      resend: { status: "idle", error: null },
    });
  });
});

describe("«Conferma»", () => {
  it("canjea el link una sola vez y pasa a elegir la contraseña con el email de la cuenta", async () => {
    const { api, access, states } = setup();
    await access.confirm();
    expect(api.verify).toHaveBeenCalledTimes(1);
    expect(api.verify).toHaveBeenCalledWith({ tokenHash: HASH, type: "email" });
    expect(states.map((s) => s.kind)).toEqual(["confirm", "password"]);
    expect(states[0]).toEqual({ kind: "confirm", type: "email", busy: true, error: null });
    expect(access.state).toEqual({ kind: "password", type: "email", email: EMAIL, busy: false, error: null });
    expectNoSecrets(states);
  });

  it("dos toques seguidos mandan un solo pedido", async () => {
    const verify = deferred<VerifyResult>();
    const { api, access } = setup(linkRead(), { verify: vi.fn(() => verify.promise) });
    const first = access.confirm();
    void access.confirm();
    verify.resolve({ kind: "ok", accessToken: ACCESS_TOKEN, email: EMAIL });
    await first;
    expect(api.verify).toHaveBeenCalledTimes(1);
  });

  it("después de canjearlo, el link se olvida: otro «Conferma» no hace nada", async () => {
    const { api, access } = setup();
    await access.confirm();
    await access.confirm();
    expect(api.verify).toHaveBeenCalledTimes(1);
  });

  it("vencido o ya usado: expired, y el link no se vuelve a mandar", async () => {
    const { api, access } = setup(linkRead("recovery"), { verify: vi.fn(async (): Promise<VerifyResult> => ({ kind: "expired" })) });
    await access.confirm();
    expect(access.state).toEqual({ kind: "expired", type: "recovery", reason: "link", resend: { status: "idle", error: null } });
    await access.confirm();
    expect(api.verify).toHaveBeenCalledTimes(1);
  });

  it("sin conexión o demasiados intentos: queda en «Conferma» con el aviso, y se puede reintentar", async () => {
    let reply: VerifyResult = { kind: "failed" };
    const { api, access } = setup(linkRead(), { verify: vi.fn(async () => reply) });
    await access.confirm();
    expect(access.state).toEqual({ kind: "confirm", type: "email", busy: false, error: "network" });
    reply = { kind: "rateLimited" };
    await access.confirm();
    expect(access.state).toEqual({ kind: "confirm", type: "email", busy: false, error: "rateLimited" });
    reply = { kind: "ok", accessToken: ACCESS_TOKEN, email: EMAIL };
    await access.confirm();
    expect(access.state.kind).toBe("password");
    expect(api.verify).toHaveBeenCalledTimes(3);
  });

  it("sin configuración de Supabase: el aviso, sin llamar a nadie", async () => {
    const { api, access } = setup(linkRead(), { available: false });
    await access.confirm();
    expect(access.state).toEqual({ kind: "confirm", type: "email", busy: false, error: "unavailable" });
    expect(api.verify).not.toHaveBeenCalled();
  });
});

describe("«Salva la password»", () => {
  async function atPassword(apiOverrides: Partial<AuthApi> = {}, type: "email" | "recovery" = "email") {
    const ctx = setup(linkRead(type), apiOverrides);
    await ctx.access.confirm();
    return ctx;
  }

  it("la revisa antes de mandarla: corta o sin números no sale", async () => {
    const { api, access } = await atPassword();
    await access.savePassword("corta1");
    expect(access.state).toMatchObject({ kind: "password", error: "tooShort" });
    await access.savePassword("sololetrasaqui");
    expect(access.state).toMatchObject({ kind: "password", error: "lettersDigits" });
    expect(api.updatePassword).not.toHaveBeenCalled();
  });

  it("la guarda con la sesión del link, cierra la sesión y termina", async () => {
    const { api, access, states } = await atPassword({}, "recovery");
    await access.savePassword("Bergamo2026");
    expect(api.updatePassword).toHaveBeenCalledWith(ACCESS_TOKEN, "Bergamo2026");
    expect(api.logout).toHaveBeenCalledTimes(1);
    expect(api.logout).toHaveBeenCalledWith(ACCESS_TOKEN);
    expect(access.state).toEqual({ kind: "done", type: "recovery", email: EMAIL });
    expectNoSecrets(states);
  });

  it("cierra la sesión ANTES de mostrar «Fatto»", async () => {
    const logout = deferred<void>();
    const { access } = await atPassword({ logout: vi.fn(() => logout.promise) });
    const saving = access.savePassword("Bergamo2026");
    await Promise.resolve();
    await Promise.resolve();
    expect(access.state.kind).toBe("password");
    logout.resolve();
    await saving;
    expect(access.state.kind).toBe("done");
  });

  it("después de terminar, la sesión ya no existe: no se puede volver a usar", async () => {
    const { api, access } = await atPassword();
    await access.savePassword("Bergamo2026");
    await access.savePassword("OtraClave2026");
    expect(api.updatePassword).toHaveBeenCalledTimes(1);
    expect(api.logout).toHaveBeenCalledTimes(1);
  });

  it("Auth la rechaza por débil: el motivo según sus razones (filtrada, corta, sin números u otro)", async () => {
    for (const [reasons, error] of [
      [["pwned"], "leaked"],
      [["length", "pwned"], "leaked"],
      [["length"], "tooShort"],
      [["characters"], "lettersDigits"],
      [[], "weak"],
    ] as const) {
      const { api, access } = await atPassword({ updatePassword: vi.fn(async (): Promise<UpdateResult> => ({ kind: "weak", reasons })) });
      await access.savePassword("Bergamo2026");
      expect(access.state).toEqual({ kind: "password", type: "email", email: EMAIL, busy: false, error });
      expect(api.logout).not.toHaveBeenCalled();
    }
  });

  it("la misma de antes: same; sin conexión: network; demasiados intentos: rateLimited (sigue en el paso)", async () => {
    for (const [result, error] of [
      [{ kind: "same" }, "same"],
      [{ kind: "failed" }, "network"],
      [{ kind: "rateLimited" }, "rateLimited"],
    ] as const) {
      const { access } = await atPassword({ updatePassword: vi.fn(async (): Promise<UpdateResult> => result) });
      await access.savePassword("Bergamo2026");
      expect(access.state).toMatchObject({ kind: "password", error });
    }
  });

  it("la sesión venció: expired por sesión, para pedir otro link", async () => {
    const { api, access } = await atPassword({ updatePassword: vi.fn(async (): Promise<UpdateResult> => ({ kind: "session" })) }, "recovery");
    await access.savePassword("Bergamo2026");
    expect(access.state).toEqual({ kind: "expired", type: "recovery", reason: "session", resend: { status: "idle", error: null } });
    expect(api.logout).not.toHaveBeenCalled();
  });

  it("dos envíos seguidos mandan uno solo", async () => {
    const update = deferred<UpdateResult>();
    const { api, access } = await atPassword({ updatePassword: vi.fn(() => update.promise) });
    const first = access.savePassword("Bergamo2026");
    void access.savePassword("Bergamo2026");
    update.resolve({ kind: "ok" });
    await first;
    expect(api.updatePassword).toHaveBeenCalledTimes(1);
  });
});

describe("«Reinvia l'email»", () => {
  const expiredRead: LinkRead = { kind: "broken", type: "email" };

  it("pide un captcha nuevo y después el link, con el email sin espacios; termina en el mensaje neutro", async () => {
    const { api, access, captchaToken, states } = setup(expiredRead);
    await access.resend("  ana@libero.it ");
    expect(captchaToken).toHaveBeenCalledTimes(1);
    expect(api.resend).toHaveBeenCalledWith("email", "ana@libero.it", "CAPTCHA");
    expect(states.map((s) => (s.kind === "expired" ? s.resend.status : s.kind))).toEqual(["busy", "sent"]);
    expect(access.state).toMatchObject({ kind: "expired", resend: { status: "sent", error: null } });
  });

  it("para la contraseña pide un link de recuperación", async () => {
    const { api, access } = setup({ kind: "broken", type: "recovery" });
    await access.resend(EMAIL);
    expect(api.resend).toHaveBeenCalledWith("recovery", EMAIL, "CAPTCHA");
  });

  it("sin captcha no se manda nada", async () => {
    const { api, access } = setup(expiredRead, {}, async () => null);
    await access.resend(EMAIL);
    expect(api.resend).not.toHaveBeenCalled();
    expect(access.state).toMatchObject({ kind: "expired", resend: { status: "idle", error: "captcha" } });
  });

  it("un email que no tiene forma de email no pide captcha", async () => {
    const { api, access, captchaToken } = setup(expiredRead);
    for (const bad of ["", "ana", "ana@libero", "ana @libero.it"]) {
      await access.resend(bad);
      expect(access.state).toMatchObject({ kind: "expired", resend: { status: "idle", error: "email" } });
    }
    expect(captchaToken).not.toHaveBeenCalled();
    expect(api.resend).not.toHaveBeenCalled();
  });

  it("lo que responde Auth: captcha rechazado, email no válido, demasiados pedidos, sin conexión", async () => {
    for (const [result, error] of [
      [{ kind: "captcha" }, "captcha"],
      [{ kind: "invalidEmail" }, "email"],
      [{ kind: "rateLimited" }, "rateLimited"],
      [{ kind: "failed" }, "network"],
    ] as const) {
      const { access } = setup(expiredRead, { resend: vi.fn(async (): Promise<ResendResult> => result) });
      await access.resend(EMAIL);
      expect(access.state).toMatchObject({ kind: "expired", resend: { status: "idle", error } });
    }
  });

  it("se puede volver a pedir después de un envío (los topes los pone Auth)", async () => {
    const { api, access, captchaToken } = setup(expiredRead);
    await access.resend(EMAIL);
    await access.resend(EMAIL);
    expect(captchaToken).toHaveBeenCalledTimes(2);
    expect(api.resend).toHaveBeenCalledTimes(2);
  });

  it("mientras espera, otro envío no hace nada", async () => {
    const captcha = deferred<string | null>();
    const { access, captchaToken } = setup(expiredRead, {}, () => captcha.promise);
    const first = access.resend(EMAIL);
    void access.resend(EMAIL);
    captcha.resolve("CAPTCHA");
    await first;
    expect(captchaToken).toHaveBeenCalledTimes(1);
  });

  it("sin configuración de Supabase: el aviso, sin captcha", async () => {
    const { access, captchaToken } = setup(expiredRead, { available: false });
    await access.resend(EMAIL);
    expect(access.state).toMatchObject({ resend: { error: "unavailable" } });
    expect(captchaToken).not.toHaveBeenCalled();
  });
});

describe("otro link con la página abierta", () => {
  it("empieza de nuevo con el link nuevo, y cierra la sesión que había quedado a medias", async () => {
    const { api, access } = setup(linkRead("email"));
    await access.confirm();
    access.openLink(linkRead("recovery"));
    expect(api.logout).toHaveBeenCalledWith(ACCESS_TOKEN);
    expect(access.state).toEqual({ kind: "confirm", type: "recovery", busy: false, error: null });
  });

  it("la respuesta tardía del link anterior se descarta", async () => {
    const verify = deferred<VerifyResult>();
    const { access } = setup(linkRead("email"), { verify: vi.fn(() => verify.promise) });
    const pending = access.confirm();
    access.openLink({ kind: "none" });
    verify.resolve({ kind: "ok", accessToken: ACCESS_TOKEN, email: EMAIL });
    await pending;
    expect(access.state).toEqual({ kind: "missing" });
  });
});

describe("isPlausibleEmail", () => {
  it("lo mínimo para no pedir un captcha por un error de tipeo", () => {
    expect(isPlausibleEmail("ana@libero.it")).toBe(true);
    expect(isPlausibleEmail(`${"a".repeat(245)}@libero.it`)).toBe(false);
    for (const bad of ["", "ana", "@libero.it", "ana@", "ana@libero", "a na@libero.it"]) expect(isPlausibleEmail(bad), bad).toBe(false);
  });
});
