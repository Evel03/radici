// Envío del pedido a la Edge Function `public-request` y lectura de su respuesta
// (docs/contracts/public-request.md §2). La función es pública: no hace falta apikey ni sesión.
// Nunca se registran en consola los datos del pedido ni la respuesta.
import type { MessageKey, Params } from "../i18n/core.ts";
import { readPublicEstimate, type PublicRequestErrors, type PublicRequestEstimate, type PublicRequestPayload } from "./model.ts";

export const PUBLIC_REQUEST_PATH = "/functions/v1/public-request";

/**
 * Región en la que corre la función: la del proyecto (Frankfurt, como dice la privacy). Sin esto,
 * Supabase la corre en la región más cercana a quien envía: fuera de la UE si escribe desde afuera.
 * Va como parámetro de la URL (forceFunctionRegion): la cabecera x-region necesitaría CORS.
 */
export const FUNCTION_REGION = "eu-central-1";

/** Sin respuesta en este tiempo se corta: se trata como error de red y se puede reintentar. */
export const REQUEST_TIMEOUT_MS = 20_000;

export function publicRequestUrl(supabaseUrl: string): string {
  return `${supabaseUrl.replace(/\/+$/, "")}${PUBLIC_REQUEST_PATH}?forceFunctionRegion=${FUNCTION_REGION}`;
}

export type SubmitOutcome =
  /**
   * 2xx: el pedido quedó guardado (aunque el cuerpo no se pueda leer). `duplicate`: ya estaba guardado
   * de un envío anterior con la misma clave y este no cambió nada (la estimación es la guardada).
   * `estimate`: la que guardó el servidor (calcQuote con las tarifas de la cocinera), con precio o sin él.
   */
  | { kind: "created"; requestId: string | null; estimate: PublicRequestEstimate | null; duplicate: boolean }
  /** 400: errores por campo (códigos del contrato). */
  | { kind: "invalid"; errors: PublicRequestErrors }
  /** 403: Turnstile rechazado. */
  | { kind: "turnstile" }
  /** 429: demasiados pedidos desde esta IP. */
  | { kind: "rateLimited"; retryAfterSeconds: number | null }
  /** 413: cuerpo demasiado grande. */
  | { kind: "tooLarge" }
  /** 5xx, 405, 415 o cualquier otra respuesta inesperada. */
  | { kind: "server" }
  /** Sin respuesta: sin conexión, CORS, DNS o tiempo agotado. */
  | { kind: "network" };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readRequestId(body: Record<string, unknown>): string | null {
  const id = body["requestId"];
  return typeof id === "string" && /^[\w-]{1,64}$/.test(id) ? id : null;
}

function readErrors(body: unknown): PublicRequestErrors | null {
  if (!isRecord(body) || !isRecord(body["errors"])) return null;
  const entries = Object.entries(body["errors"]);
  if (entries.length === 0 || !entries.every(([, code]) => typeof code === "string")) return null;
  // Los campos o códigos desconocidos los resuelve translateErrors.
  return Object.fromEntries(entries) as PublicRequestErrors;
}

/** Retry-After en segundos (número o fecha HTTP). null si falta o no se entiende. */
export function parseRetryAfter(value: string | null, now: Date = new Date()): number | null {
  const raw = value?.trim() ?? "";
  if (raw === "") return null;
  if (/^\d+$/.test(raw)) return Number(raw);
  if (!/[a-z]/i.test(raw)) return null; // "-5" y similares no son fechas
  const at = Date.parse(raw);
  if (Number.isNaN(at)) return null;
  return Math.max(0, Math.ceil((at - now.getTime()) / 1000));
}

/** Mensaje del 429: en minutos (hasta una hora) o en horas; sin tiempo si el servidor no lo dio. */
export function rateLimitMessage(seconds: number | null): { key: MessageKey; params?: Params } {
  if (seconds === null || seconds <= 0) return { key: "errors.rateLimited" };
  if (seconds < 3600) return { key: "errors.rateLimitedMinutes", params: { minutes: Math.ceil(seconds / 60) } };
  return { key: "errors.rateLimitedHours", params: { hours: Math.ceil(seconds / 3600) } };
}

export function interpretResponse(status: number, body: unknown, retryAfter: string | null, now?: Date): SubmitOutcome {
  if (status >= 200 && status < 300) {
    const data = isRecord(body) ? body : {};
    // La estimación se lee con la función del contrato: con otra forma queda en null y la pantalla de
    // gracias usa la de la calculadora.
    return {
      kind: "created",
      requestId: readRequestId(data),
      estimate: readPublicEstimate(data["estimate"]),
      duplicate: data["duplicate"] === true,
    };
  }
  if (status === 400) {
    const errors = readErrors(body);
    return errors ? { kind: "invalid", errors } : { kind: "server" };
  }
  if (status === 403) return { kind: "turnstile" };
  if (status === 413) return { kind: "tooLarge" };
  if (status === 429) return { kind: "rateLimited", retryAfterSeconds: parseRetryAfter(retryAfter, now) };
  return { kind: "server" };
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return null;
  }
}

export interface SendOptions {
  /** Para los tests; en el navegador, window.fetch. */
  fetch?: (input: string, init: RequestInit) => Promise<Response>;
  timeoutMs?: number;
}

export async function sendPublicRequest(
  url: string,
  payload: PublicRequestPayload,
  opts: SendOptions = {},
): Promise<SubmitOutcome> {
  // Llamada envuelta: algunos navegadores fallan si fetch se invoca sin su `this` (window).
  const fetchFn = opts.fetch ?? ((input: string, init: RequestInit) => fetch(input, init));
  // AbortController + setTimeout en vez de AbortSignal.timeout: funciona en Safari 14.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? REQUEST_TIMEOUT_MS);
  try {
    const response = await fetchFn(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      credentials: "omit",
      cache: "no-store",
      signal: controller.signal,
    });
    const text = await response.text();
    // Retry-After solo se puede leer si la función lo expone (Access-Control-Expose-Headers).
    return interpretResponse(response.status, parseJson(text), response.headers.get("Retry-After"));
  } catch {
    return { kind: "network" };
  } finally {
    clearTimeout(timer);
  }
}
