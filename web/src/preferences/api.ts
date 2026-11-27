// Llamadas de la página /preferenze/ a la Edge Function public-request (docs/contracts/public-request.md §13): el estado
// de la suscripción a ofertas y novedades, confirmarla o darse de baja. La función es pública: no hace falta apikey ni
// sesión. El token va en el cuerpo del POST, nunca en la URL, y ni el token ni las respuestas se registran en la consola.
import { MARKETING_ROUTES, MARKETING_STATUSES, type MarketingRoute, type MarketingStatus } from "../../../supabase/functions/_shared/marketing.ts";
import { FUNCTION_REGION, parseRetryAfter } from "../request/submit.ts";

/** Sin respuesta en este tiempo se corta: se trata como error de red y se puede reintentar. */
export const PREFERENCES_TIMEOUT_MS = 20_000;

export type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

/** La URL de una ruta, en la región del proyecto (forceFunctionRegion, como el formulario). */
export function marketingUrl(supabaseUrl: string, route: MarketingRoute): string {
  return `${supabaseUrl.replace(/\/+$/, "")}/functions/v1/public-request${MARKETING_ROUTES[route]}?forceFunctionRegion=${FUNCTION_REGION}`;
}

export type MarketingOutcome =
  /** El estado (después de la acción, si fue confirm o withdraw); el email enmascarado solo en status. */
  | { kind: "ok"; status: MarketingStatus; email: string | null }
  /** 404 (o un token con otra forma): el link no es de nadie o venció. */
  | { kind: "notFound" }
  | { kind: "rateLimited"; retryAfterSeconds: number | null }
  /** 5xx, una respuesta con otra forma o cualquier otra cosa inesperada. */
  | { kind: "server" }
  /** Sin respuesta: sin conexión, CORS, DNS o tiempo agotado. */
  | { kind: "network" };

export interface MarketingApiOptions {
  /** Sin ella (un build sin VITE_SUPABASE_URL), cada llamada responde server. */
  supabaseUrl: string | null;
  fetch?: FetchLike;
  timeoutMs?: number;
  now?: Date;
}

export type MarketingApi = (route: MarketingRoute, token: string) => Promise<MarketingOutcome>;

export function createMarketingApi(options: MarketingApiOptions): MarketingApi {
  const doFetch: FetchLike = options.fetch ?? ((input, init) => fetch(input, init));
  return async (route, token) => {
    const supabaseUrl = options.supabaseUrl;
    if (!supabaseUrl) return { kind: "server" };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? PREFERENCES_TIMEOUT_MS);
    let response: Response;
    try {
      response = await doFetch(marketingUrl(supabaseUrl, route), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token }),
        credentials: "omit",
        referrerPolicy: "no-referrer",
        signal: controller.signal,
      });
    } catch {
      return { kind: "network" };
    } finally {
      clearTimeout(timer);
    }
    if (response.status === 404 || response.status === 400) return { kind: "notFound" };
    if (response.status === 429) {
      return { kind: "rateLimited", retryAfterSeconds: parseRetryAfter(response.headers.get("Retry-After"), options.now ?? new Date()) };
    }
    if (!response.ok) return { kind: "server" };
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      return { kind: "server" };
    }
    if (body === null || typeof body !== "object") return { kind: "server" };
    const { status, email } = body as { status?: unknown; email?: unknown };
    if (typeof status !== "string" || !(MARKETING_STATUSES as readonly string[]).includes(status)) return { kind: "server" };
    return { kind: "ok", status: status as MarketingStatus, email: typeof email === "string" ? email : null };
  };
}
