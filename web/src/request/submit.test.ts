import { describe, expect, it, vi } from "vitest";
import { TEST_TOKEN, validRequest } from "./fixtures.ts";
import { buildPayload } from "./payload.ts";
import {
  FUNCTION_REGION,
  PUBLIC_REQUEST_PATH,
  interpretResponse,
  parseRetryAfter,
  publicRequestUrl,
  rateLimitMessage,
  sendPublicRequest,
} from "./submit.ts";

const URL_ = "https://abcdefgh.supabase.co/functions/v1/public-request";
const ESTIMATE = { portions: 20, recipes: 3, cookMinutes: 180, serviceCents: 7800, groceriesEstCents: 6300, totalCents: 14100 };
const payload = buildPayload(validRequest(), { locale: "it", turnstileToken: TEST_TOKEN });

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });
}

describe("publicRequestUrl", () => {
  it("arma la URL de la Edge Function, fijada a la región del proyecto (Frankfurt)", () => {
    expect(FUNCTION_REGION).toBe("eu-central-1");
    expect(publicRequestUrl("https://abcdefgh.supabase.co")).toBe(`${URL_}?forceFunctionRegion=eu-central-1`);
    expect(publicRequestUrl("http://127.0.0.1:54321/")).toBe(
      `http://127.0.0.1:54321${PUBLIC_REQUEST_PATH}?forceFunctionRegion=eu-central-1`,
    );
  });

  it("la región va en la URL y no en una cabecera (x-region necesitaría CORS)", () => {
    const url = new URL(publicRequestUrl("https://abcdefgh.supabase.co"));
    expect(url.origin).toBe("https://abcdefgh.supabase.co");
    expect(url.pathname).toBe(PUBLIC_REQUEST_PATH);
    expect(url.searchParams.get("forceFunctionRegion")).toBe("eu-central-1");
  });
});

describe("interpretResponse (contrato §2)", () => {
  it("201: guardado, con id y estimación del servidor", () => {
    expect(interpretResponse(201, { requestId: "6f1c7c1e-9f7e-4a53-9a77-2f5d2f0f7a10", estimate: ESTIMATE }, null)).toEqual({
      kind: "created",
      requestId: "6f1c7c1e-9f7e-4a53-9a77-2f5d2f0f7a10",
      estimate: ESTIMATE,
      duplicate: false,
    });
  });

  it("201 con duplicate: true: el servidor ya tenía el pedido de un envío anterior con la misma clave", () => {
    expect(
      interpretResponse(201, { requestId: "6f1c7c1e-9f7e-4a53-9a77-2f5d2f0f7a10", estimate: ESTIMATE, duplicate: true }, null),
    ).toEqual({ kind: "created", requestId: "6f1c7c1e-9f7e-4a53-9a77-2f5d2f0f7a10", estimate: ESTIMATE, duplicate: true });
    // Solo cuenta el booleano true.
    expect(interpretResponse(201, { requestId: "x", estimate: ESTIMATE, duplicate: "true" }, null)).toMatchObject({ duplicate: false });
  });

  it("201 con un cuerpo raro igual es éxito (el pedido ya está guardado)", () => {
    expect(interpretResponse(201, null, null)).toEqual({ kind: "created", requestId: null, estimate: null, duplicate: false });
    expect(interpretResponse(201, { requestId: 5, estimate: { ...ESTIMATE, totalCents: 141.5 } }, null)).toEqual({
      kind: "created",
      requestId: null,
      estimate: null,
      duplicate: false,
    });
  });

  it("400 con errores por campo", () => {
    expect(interpretResponse(400, { errors: { phone: "invalid", email: "required" } }, null)).toEqual({
      kind: "invalid",
      errors: { phone: "invalid", email: "required" },
    });
  });

  it("400 sin errores legibles: error del servidor", () => {
    expect(interpretResponse(400, { errors: {} }, null)).toEqual({ kind: "server" });
    expect(interpretResponse(400, { errors: { phone: 3 } }, null)).toEqual({ kind: "server" });
    expect(interpretResponse(400, "<html>", null)).toEqual({ kind: "server" });
  });

  it("403: Turnstile rechazado", () => {
    expect(interpretResponse(403, { errors: { turnstileToken: "invalid" } }, null)).toEqual({ kind: "turnstile" });
  });

  it("429 con Retry-After", () => {
    expect(interpretResponse(429, { error: "rateLimited" }, "120")).toEqual({ kind: "rateLimited", retryAfterSeconds: 120 });
    expect(interpretResponse(429, { error: "rateLimited" }, null)).toEqual({ kind: "rateLimited", retryAfterSeconds: null });
  });

  it("413, 405, 415, 500 y cualquier otro código", () => {
    expect(interpretResponse(413, { error: "tooLarge" }, null)).toEqual({ kind: "tooLarge" });
    for (const status of [401, 404, 405, 415, 500, 502, 503]) {
      expect(interpretResponse(status, { error: "server" }, null), String(status)).toEqual({ kind: "server" });
    }
  });
});

describe("parseRetryAfter", () => {
  const now = new Date("2026-10-19T10:00:00Z");
  it("segundos o fecha HTTP", () => {
    expect(parseRetryAfter("3600", now)).toBe(3600);
    expect(parseRetryAfter(" 90 ", now)).toBe(90);
    expect(parseRetryAfter("Mon, 19 Oct 2026 10:30:00 GMT", now)).toBe(1800);
    expect(parseRetryAfter("Mon, 19 Oct 2026 09:00:00 GMT", now)).toBe(0);
  });
  it("ausente o ilegible: null", () => {
    expect(parseRetryAfter(null, now)).toBeNull();
    expect(parseRetryAfter("", now)).toBeNull();
    expect(parseRetryAfter("pronto", now)).toBeNull();
    expect(parseRetryAfter("-5", now)).toBeNull();
  });
});

describe("rateLimitMessage", () => {
  it("minutos (redondeo hacia arriba), horas, o sin tiempo", () => {
    expect(rateLimitMessage(null)).toEqual({ key: "errors.rateLimited" });
    expect(rateLimitMessage(0)).toEqual({ key: "errors.rateLimited" });
    expect(rateLimitMessage(30)).toEqual({ key: "errors.rateLimitedMinutes", params: { minutes: 1 } });
    expect(rateLimitMessage(121)).toEqual({ key: "errors.rateLimitedMinutes", params: { minutes: 3 } });
    expect(rateLimitMessage(3599)).toEqual({ key: "errors.rateLimitedMinutes", params: { minutes: 60 } });
    expect(rateLimitMessage(3600)).toEqual({ key: "errors.rateLimitedHours", params: { hours: 1 } });
    expect(rateLimitMessage(86_400)).toEqual({ key: "errors.rateLimitedHours", params: { hours: 24 } });
  });
});

describe("sendPublicRequest", () => {
  it("POST JSON a la función, sin cookies ni apikey, y devuelve el resultado", async () => {
    const fetchFn = vi.fn(async () => jsonResponse(201, { requestId: "abc-123", estimate: ESTIMATE }));
    const outcome = await sendPublicRequest(URL_, payload, { fetch: fetchFn });
    expect(outcome).toEqual({ kind: "created", requestId: "abc-123", estimate: ESTIMATE, duplicate: false });
    expect(fetchFn).toHaveBeenCalledTimes(1);
    const [url, init] = fetchFn.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe(URL_);
    expect(init.method).toBe("POST");
    expect(init.credentials).toBe("omit");
    expect(new Headers(init.headers).get("Content-Type")).toBe("application/json");
    expect(new Headers(init.headers).has("apikey")).toBe(false);
    expect(new Headers(init.headers).has("Authorization")).toBe(false);
    expect(JSON.parse(String(init.body))).toEqual(payload);
  });

  it("lee Retry-After de la respuesta 429", async () => {
    const fetchFn = vi.fn(async () => jsonResponse(429, { error: "rateLimited" }, { "Retry-After": "600" }));
    expect(await sendPublicRequest(URL_, payload, { fetch: fetchFn })).toEqual({ kind: "rateLimited", retryAfterSeconds: 600 });
  });

  it("una respuesta que no es JSON no rompe", async () => {
    const fetchFn = vi.fn(async () => new Response("Bad gateway", { status: 502 }));
    expect(await sendPublicRequest(URL_, payload, { fetch: fetchFn })).toEqual({ kind: "server" });
  });

  it("sin conexión (o CORS rechazado): error de red", async () => {
    const fetchFn = vi.fn(async () => {
      throw new TypeError("Failed to fetch");
    });
    expect(await sendPublicRequest(URL_, payload, { fetch: fetchFn })).toEqual({ kind: "network" });
  });

  it("si el servidor no contesta a tiempo se corta y es error de red", async () => {
    const fetchFn = vi.fn(
      (_url: string | URL | Request, init?: RequestInit) =>
        new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
        }),
    );
    expect(await sendPublicRequest(URL_, payload, { fetch: fetchFn, timeoutMs: 10 })).toEqual({ kind: "network" });
  });
});
