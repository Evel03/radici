import { describe, expect, it } from "vitest";
import { clientLinkUrl, confirmMenu, fetchView, requestChanges, type FetchLike } from "./api.ts";
import { SEND_1, SUPABASE_URL, TOKEN, view } from "./fixtures.ts";

interface Call {
  url: string;
  init: RequestInit;
  body: unknown;
}

/** fetch simulado: responde lo que diga `respond` y registra cada llamada. */
function fakeFetch(respond: (url: string) => Response | Promise<Response>): { fetch: FetchLike; calls: Call[] } {
  const calls: Call[] = [];
  return {
    calls,
    fetch: async (url, init) => {
      calls.push({ url, init, body: JSON.parse(String(init.body)) as unknown });
      return respond(url);
    },
  };
}

const json = (status: number, body: unknown, headers: Record<string, string> = {}): Response =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

describe("clientLinkUrl", () => {
  it("la ruta de la función, en la región del proyecto", () => {
    expect(clientLinkUrl(`${SUPABASE_URL}/`, "/view")).toBe(`${SUPABASE_URL}/functions/v1/client-link/view?forceFunctionRegion=eu-central-1`);
    expect(clientLinkUrl(SUPABASE_URL, "/changes")).toBe(`${SUPABASE_URL}/functions/v1/client-link/changes?forceFunctionRegion=eu-central-1`);
  });
});

describe("fetchView", () => {
  it("POST con el token en el cuerpo (nunca en la URL), sin credenciales ni caché", async () => {
    const { fetch, calls } = fakeFetch(() => json(200, view()));
    const outcome = await fetchView(SUPABASE_URL, TOKEN, { fetch });
    expect(outcome).toEqual({ kind: "ok", view: view() });
    expect(calls).toHaveLength(1);
    const call = calls[0];
    expect(call?.url).toBe(clientLinkUrl(SUPABASE_URL, "/view"));
    expect(call?.url).not.toContain(TOKEN);
    expect(call?.body).toEqual({ token: TOKEN });
    expect(call?.init.method).toBe("POST");
    expect(call?.init.credentials).toBe("omit");
    expect(call?.init.cache).toBe("no-store");
    expect(new Headers(call?.init.headers).get("content-type")).toBe("application/json");
  });

  it("404 linkNotFound, 429 con Retry-After (segundos o fecha), 5xx y otra forma", async () => {
    const outcome = async (response: Response, now?: Date) =>
      fetchView(SUPABASE_URL, TOKEN, { fetch: fakeFetch(() => response).fetch, ...(now ? { now } : {}) });
    expect(await outcome(json(404, { error: "linkNotFound" }))).toEqual({ kind: "linkNotFound" });
    // Un 404 de la plataforma (la función no está desplegada) no es un link vencido.
    expect(await outcome(json(404, { code: "NOT_FOUND" }))).toEqual({ kind: "server" });
    expect(await outcome(json(429, { error: "rateLimited" }, { "Retry-After": "3600" }))).toEqual({ kind: "rateLimited", retryAfterSeconds: 3600 });
    const now = new Date("2027-02-26T10:00:00Z");
    expect(await outcome(json(429, {}, { "Retry-After": "Fri, 26 Feb 2027 10:02:00 GMT" }), now)).toEqual({ kind: "rateLimited", retryAfterSeconds: 120 });
    expect(await outcome(json(503, { error: "unavailable" }))).toEqual({ kind: "server" });
    expect(await outcome(json(200, { ...view(), version: 2 }))).toEqual({ kind: "server" });
    expect(await outcome(new Response("<html>", { status: 200 }))).toEqual({ kind: "server" });
  });

  it("sin respuesta (red o tiempo agotado): network", async () => {
    const offline: FetchLike = async () => {
      throw new TypeError("Failed to fetch");
    };
    expect(await fetchView(SUPABASE_URL, TOKEN, { fetch: offline })).toEqual({ kind: "network" });
    const hanging: FetchLike = (_url, init) =>
      new Promise((_resolve, reject) => init.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError"))));
    expect(await fetchView(SUPABASE_URL, TOKEN, { fetch: hanging, timeoutMs: 5 })).toEqual({ kind: "network" });
  });
});

describe("confirmMenu y requestChanges", () => {
  it("confirm: manda el token y el envío; lee la hora y si ya estaba confirmado", async () => {
    const { fetch, calls } = fakeFetch(() => json(200, { confirmedAt: "2027-02-26T10:00:00+00:00", already: false }));
    expect(await confirmMenu(SUPABASE_URL, TOKEN, SEND_1, { fetch })).toEqual({
      kind: "confirmed",
      confirmedAt: "2027-02-26T10:00:00+00:00",
      already: false,
    });
    expect(calls[0]?.url).toBe(clientLinkUrl(SUPABASE_URL, "/confirm"));
    expect(calls[0]?.body).toEqual({ token: TOKEN, sendId: SEND_1 });
  });

  it("changes: manda el mensaje; lee la hora", async () => {
    const { fetch, calls } = fakeFetch(() => json(200, { changesRequestedAt: "2027-02-26T10:00:00+00:00" }));
    expect(await requestChanges(SUPABASE_URL, TOKEN, SEND_1, "Senza cipolla", { fetch })).toEqual({
      kind: "changesSent",
      changesRequestedAt: "2027-02-26T10:00:00+00:00",
    });
    expect(calls[0]?.url).toBe(clientLinkUrl(SUPABASE_URL, "/changes"));
    expect(calls[0]?.body).toEqual({ token: TOKEN, sendId: SEND_1, text: "Senza cipolla" });
  });

  it("los errores del contrato, cada uno con su código; lo demás, server", async () => {
    const cases: Array<[Response, string]> = [
      [json(404, { error: "linkNotFound" }), "linkNotFound"],
      [json(404, { error: "sendNotFound" }), "sendNotFound"],
      [json(409, { error: "menuOutdated" }), "menuOutdated"],
      [json(409, { error: "changesRequested" }), "changesRequested"],
      [json(409, { error: "alreadyConfirmed" }), "alreadyConfirmed"],
      [json(409, { error: "sessionCancelled" }), "sessionCancelled"],
      [json(404, { error: "sessionCancelled" }), "server"],
      [json(400, { error: "invalidText" }), "invalidText"],
      [json(400, { error: "invalidPayload" }), "server"],
      [json(409, { error: "otro" }), "server"],
      [json(500, { error: "server" }), "server"],
      [json(200, { confirmedAt: "ayer", already: false }), "server"],
      [json(200, { changesRequestedAt: null }), "server"],
    ];
    for (const [response, kind] of cases) {
      const outcome = await requestChanges(SUPABASE_URL, TOKEN, SEND_1, "x", { fetch: fakeFetch(() => response.clone()).fetch });
      expect(outcome.kind, `${response.status} ${kind}`).toBe(kind);
    }
    const confirmed = await confirmMenu(SUPABASE_URL, TOKEN, SEND_1, { fetch: fakeFetch(() => json(200, { confirmedAt: "x" })).fetch });
    expect(confirmed).toEqual({ kind: "server" });
    const limited = await confirmMenu(SUPABASE_URL, TOKEN, SEND_1, { fetch: fakeFetch(() => json(429, {}, { "Retry-After": "90" })).fetch });
    expect(limited).toEqual({ kind: "rateLimited", retryAfterSeconds: 90 });
  });
});
