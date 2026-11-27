// /preferenze/: la llamada a public-request (…/marketing/…) y los estados de la página.
import { describe, expect, it } from "vitest";
import { createMarketingApi, marketingUrl, type FetchLike, type MarketingApi, type MarketingOutcome } from "./api.ts";
import { createPreferences } from "./flow.ts";

const SUPABASE = "https://ref.supabase.co";
const TOKEN = "T".repeat(43);

function fakeFetch(reply: () => Response | Promise<Response>): { fetch: FetchLike; calls: Array<{ url: string; init: RequestInit }> } {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  return {
    calls,
    fetch: async (url, init) => {
      calls.push({ url, init });
      return reply();
    },
  };
}

describe("api", () => {
  it("POST a public-request/marketing/<ruta> en la región del proyecto, con el token solo en el cuerpo", async () => {
    const { fetch, calls } = fakeFetch(() => Response.json({ status: "pending", locale: "it", email: "g***@example.it" }));
    const api = createMarketingApi({ supabaseUrl: `${SUPABASE}/`, fetch });
    expect(await api("status", TOKEN)).toEqual({ kind: "ok", status: "pending", email: "g***@example.it" });
    expect(calls[0]!.url).toBe(`${SUPABASE}/functions/v1/public-request/marketing/status?forceFunctionRegion=eu-central-1`);
    expect(calls[0]!.url).not.toContain(TOKEN);
    expect(calls[0]!.init.method).toBe("POST");
    expect(JSON.parse(String(calls[0]!.init.body))).toEqual({ token: TOKEN });
    expect(calls[0]!.init.credentials).toBe("omit");
    expect(calls[0]!.init.referrerPolicy).toBe("no-referrer");
    expect(marketingUrl(SUPABASE, "withdraw")).toContain("/marketing/withdraw?");
  });

  it("traduce las respuestas: 404 y 400, 429 con Retry-After, 5xx, otra forma, sin red y sin Supabase", async () => {
    const outcome = async (reply: () => Response | Promise<Response>): Promise<MarketingOutcome> =>
      createMarketingApi({ supabaseUrl: SUPABASE, fetch: fakeFetch(reply).fetch })("confirm", TOKEN);
    expect(await outcome(() => Response.json({ status: "confirmed", locale: "es" }))).toEqual({ kind: "ok", status: "confirmed", email: null });
    expect(await outcome(() => Response.json({ error: "notFound" }, { status: 404 }))).toEqual({ kind: "notFound" });
    expect(await outcome(() => Response.json({ error: "token" }, { status: 400 }))).toEqual({ kind: "notFound" });
    expect(await outcome(() => new Response("{}", { status: 429, headers: { "Retry-After": "3600" } }))).toEqual({ kind: "rateLimited", retryAfterSeconds: 3600 });
    expect(await outcome(() => new Response("{}", { status: 503 }))).toEqual({ kind: "server" });
    expect(await outcome(() => Response.json({ status: "otro" }))).toEqual({ kind: "server" });
    expect(await outcome(() => new Response("no json", { status: 200 }))).toEqual({ kind: "server" });
    expect(await outcome(() => Promise.reject(new TypeError("offline")))).toEqual({ kind: "network" });
    expect(await createMarketingApi({ supabaseUrl: null, fetch: fakeFetch(() => Response.json({})).fetch })("status", TOKEN)).toEqual({ kind: "server" });
  });
});

/** Una API simulada: responde en orden y anota las rutas. */
function scripted(...outcomes: MarketingOutcome[]): { api: MarketingApi; routes: string[] } {
  const routes: string[] = [];
  return {
    routes,
    api: async (route) => {
      routes.push(route);
      const next = outcomes.shift();
      if (!next) throw new Error("respuesta de más");
      return next;
    },
  };
}

describe("flow", () => {
  it("sin token: «link incompleto» y ninguna llamada", async () => {
    const { api, routes } = scripted();
    const prefs = createPreferences(null, api);
    await prefs.load();
    await prefs.confirm();
    expect(prefs.state()).toEqual({ step: "missing" });
    expect(routes).toEqual([]);
  });

  it("al abrir solo lee el estado (un escáner de links no confirma a nadie); confirmar necesita el toque", async () => {
    const { api, routes } = scripted(
      { kind: "ok", status: "pending", email: "g***@example.it" },
      { kind: "ok", status: "confirmed", email: null },
    );
    const prefs = createPreferences(TOKEN, api);
    expect(prefs.state()).toEqual({ step: "loading" });
    await prefs.load();
    expect(routes).toEqual(["status"]);
    expect(prefs.state()).toEqual({ step: "pending", email: "g***@example.it", busy: false, error: null });
    await prefs.confirm();
    expect(routes).toEqual(["status", "confirm"]);
    expect(prefs.state()).toEqual({ step: "confirmed", email: "g***@example.it", busy: false, error: null });
  });

  it("«No, grazie» desde un pendiente y «Non voglio più» desde un confirmado: baja", async () => {
    const pending = scripted({ kind: "ok", status: "pending", email: null }, { kind: "ok", status: "withdrawn", email: null });
    const a = createPreferences(TOKEN, pending.api);
    await a.load();
    await a.withdraw();
    expect(a.state().step).toBe("withdrawn");
    expect(pending.routes).toEqual(["status", "withdraw"]);

    const confirmed = scripted({ kind: "ok", status: "confirmed", email: null }, { kind: "ok", status: "withdrawn", email: null });
    const b = createPreferences(TOKEN, confirmed.api);
    await b.load();
    await b.confirm();
    expect(confirmed.routes, "confirmar solo desde un pendiente").toEqual(["status"]);
    await b.withdraw();
    expect(b.state().step).toBe("withdrawn");
    await b.withdraw();
    expect(confirmed.routes, "una baja no se repite").toEqual(["status", "withdraw"]);
  });

  it("un toque doble mientras espera no repite el pedido", async () => {
    let release: (outcome: MarketingOutcome) => void = () => {};
    const routes: string[] = [];
    const api: MarketingApi = async (route) => {
      routes.push(route);
      if (route === "status") return { kind: "ok", status: "pending", email: null };
      return new Promise<MarketingOutcome>((resolve) => (release = resolve));
    };
    const prefs = createPreferences(TOKEN, api);
    await prefs.load();
    const first = prefs.confirm();
    expect(prefs.state()).toMatchObject({ step: "pending", busy: true });
    await prefs.confirm();
    await prefs.withdraw();
    release({ kind: "ok", status: "confirmed", email: null });
    await first;
    expect(routes).toEqual(["status", "confirm"]);
  });

  it("errores: al leer, «Riprova»; al confirmar, el error en la misma sección; link vencido: notFound", async () => {
    const { api } = scripted(
      { kind: "network" },
      { kind: "ok", status: "pending", email: null },
      { kind: "rateLimited", retryAfterSeconds: 60 },
      { kind: "notFound" },
    );
    const prefs = createPreferences(TOKEN, api);
    await prefs.load();
    expect(prefs.state()).toEqual({ step: "failed", error: "network" });
    await prefs.load();
    expect(prefs.state()).toMatchObject({ step: "pending", error: null });
    await prefs.confirm();
    expect(prefs.state()).toEqual({ step: "pending", email: null, busy: false, error: "rateLimited" });
    await prefs.confirm();
    expect(prefs.state()).toEqual({ step: "notFound" });
  });

  it("avisa cada cambio a la página", async () => {
    const seen: string[] = [];
    const { api } = scripted({ kind: "ok", status: "withdrawn", email: null });
    await createPreferences(TOKEN, api, (state) => seen.push(state.step)).load();
    expect(seen).toEqual(["loading", "withdrawn"]);
  });
});
