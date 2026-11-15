import { describe, expect, it } from "vitest";
import { buildAvailabilityResponse } from "../../../supabase/functions/_shared/availability.ts";
import { availabilityUrl, fetchAvailability } from "./availability.ts";

const URL_OK = availabilityUrl("https://abc.supabase.co/", 180);

function respond(status: number, body: string): (input: string, init: RequestInit) => Promise<Response> {
  return async () => new Response(body, { status });
}

describe("disponibilidad por día", () => {
  it("la URL es la de la función, en Frankfurt, con los minutos", () => {
    expect(URL_OK).toBe(
      "https://abc.supabase.co/functions/v1/public-request/availability?forceFunctionRegion=eu-central-1&minutes=180",
    );
  });

  it("GET simple: sin cabeceras propias (no hay preflight) ni cookies", async () => {
    let seen: { url: string; init: RequestInit } | null = null;
    const body = JSON.stringify(buildAvailabilityResponse("2026-11-15", 180, ["2026-11-17"]));
    const res = await fetchAvailability(URL_OK, {
      fetch: async (url, init) => {
        seen = { url, init };
        return new Response(body, { status: 200 });
      },
    });
    expect(res?.days.find((d) => d.date === "2026-11-17")?.available).toBe(true);
    expect(seen).not.toBeNull();
    const { url, init } = seen as unknown as { url: string; init: RequestInit };
    expect(url).toBe(URL_OK);
    expect(init.method).toBe("GET");
    expect(init.headers).toBeUndefined();
    expect(init.credentials).toBe("omit");
  });

  it("errores del servidor, JSON roto u otra forma: null", async () => {
    expect(await fetchAvailability(URL_OK, { fetch: respond(503, "{}") })).toBeNull();
    expect(await fetchAvailability(URL_OK, { fetch: respond(400, '{"errors":{"minutes":"invalid"}}') })).toBeNull();
    expect(await fetchAvailability(URL_OK, { fetch: respond(200, "no es json") })).toBeNull();
    expect(await fetchAvailability(URL_OK, { fetch: respond(200, '{"version":9,"minutes":180,"days":[]}') })).toBeNull();
  });

  it("sin conexión o tiempo agotado: null", async () => {
    expect(await fetchAvailability(URL_OK, { fetch: async () => Promise.reject(new TypeError("Failed to fetch")) })).toBeNull();
    const hanging = (_url: string, init: RequestInit): Promise<Response> =>
      new Promise((_resolve, reject) => init.signal?.addEventListener("abort", () => reject(new Error("abort"))));
    expect(await fetchAvailability(URL_OK, { fetch: hanging, timeoutMs: 10 })).toBeNull();
  });
});
