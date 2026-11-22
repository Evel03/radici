// Llamadas de la página /prenotazione/ a la Edge Function client-link (docs/contracts/client-link.md). La función
// es pública: no hace falta apikey ni sesión. El token va en el cuerpo del POST, nunca en la URL, y ni el token
// ni las respuestas se registran en la consola.
import {
  CLIENT_LINK_FUNCTION,
  CLIENT_LINK_ROUTES,
  isTimestamp,
  parseClientLinkView,
  type ClientLinkRoute,
  type ClientLinkView,
} from "../../../supabase/functions/_shared/client_link.ts";
import { FUNCTION_REGION, parseRetryAfter } from "../request/submit.ts";

/** Sin respuesta en este tiempo se corta: se trata como error de red y se puede reintentar. */
export const CLIENT_LINK_TIMEOUT_MS = 20_000;

/** fetch (en los tests, simulado). */
export type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

export interface ApiOptions {
  fetch?: FetchLike;
  timeoutMs?: number;
  /** Para leer un Retry-After con fecha (tests). */
  now?: Date;
}

/** La URL de una ruta, en la región del proyecto (forceFunctionRegion, como el formulario). */
export function clientLinkUrl(supabaseUrl: string, route: ClientLinkRoute): string {
  return `${supabaseUrl.replace(/\/+$/, "")}/functions/v1/${CLIENT_LINK_FUNCTION}${route}?forceFunctionRegion=${FUNCTION_REGION}`;
}

export type ViewOutcome =
  | { kind: "ok"; view: ClientLinkView }
  /** 404: el link no existe o venció (o el token no tiene la forma de uno). */
  | { kind: "linkNotFound" }
  | { kind: "rateLimited"; retryAfterSeconds: number | null }
  /** 5xx, una respuesta con otra forma o cualquier otra cosa inesperada. */
  | { kind: "server" }
  /** Sin respuesta: sin conexión, CORS, DNS o tiempo agotado. */
  | { kind: "network" };

export type ActionOutcome =
  | { kind: "confirmed"; confirmedAt: string; already: boolean }
  | { kind: "changesSent"; changesRequestedAt: string }
  /** Evelyn mandó un menú más nuevo para esa semana: se contesta ese. */
  | { kind: "menuOutdated" }
  /** Ya pidió cambios para ese menú: no se puede confirmar hasta que Evelyn mande otro. */
  | { kind: "changesRequested" }
  /** Ya lo confirmó: los cambios se hablan con Evelyn. */
  | { kind: "alreadyConfirmed" }
  /** La semana se canceló después del envío: ya no hay menú que contestar. */
  | { kind: "sessionCancelled" }
  | { kind: "sendNotFound" }
  | { kind: "linkNotFound" }
  | { kind: "invalidText" }
  | { kind: "rateLimited"; retryAfterSeconds: number | null }
  | { kind: "server" }
  | { kind: "network" };

interface RawResponse {
  status: number;
  body: unknown;
  retryAfter: string | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return null;
  }
}

function errorCode(body: unknown): string | null {
  const code = isRecord(body) ? body["error"] : null;
  return typeof code === "string" ? code : null;
}

/** POST con JSON; null si no hubo respuesta (red, CORS, tiempo agotado). */
async function post(url: string, body: Readonly<Record<string, string>>, opts: ApiOptions): Promise<RawResponse | null> {
  // Llamada envuelta: algunos navegadores fallan si fetch se invoca sin su `this` (window).
  const fetchFn = opts.fetch ?? ((input: string, init: RequestInit) => fetch(input, init));
  // AbortController + setTimeout en vez de AbortSignal.timeout: funciona en Safari 14.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? CLIENT_LINK_TIMEOUT_MS);
  try {
    const response = await fetchFn(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      credentials: "omit",
      cache: "no-store",
      signal: controller.signal,
    });
    const text = await response.text();
    // Retry-After solo se puede leer porque la función lo expone (Access-Control-Expose-Headers).
    return { status: response.status, body: parseJson(text), retryAfter: response.headers.get("Retry-After") };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** La reserva del link. Las fotos de los platos tienen que ser del mismo proyecto de Supabase que la función. */
export async function fetchView(supabaseUrl: string, token: string, opts: ApiOptions = {}): Promise<ViewOutcome> {
  const raw = await post(clientLinkUrl(supabaseUrl, CLIENT_LINK_ROUTES.view), { token }, opts);
  if (!raw) return { kind: "network" };
  if (raw.status === 200) {
    const view = parseClientLinkView(raw.body, new URL(supabaseUrl).origin);
    return view ? { kind: "ok", view } : { kind: "server" };
  }
  if (raw.status === 404 && errorCode(raw.body) === "linkNotFound") return { kind: "linkNotFound" };
  if (raw.status === 429) return { kind: "rateLimited", retryAfterSeconds: parseRetryAfter(raw.retryAfter, opts.now) };
  return { kind: "server" };
}

/** Lo que no es un 200: los errores del contrato, o server. */
function actionError(raw: RawResponse, opts: ApiOptions): ActionOutcome {
  const code = errorCode(raw.body);
  if (raw.status === 404 && (code === "linkNotFound" || code === "sendNotFound")) return { kind: code };
  if (raw.status === 409 && (code === "menuOutdated" || code === "changesRequested" || code === "alreadyConfirmed" || code === "sessionCancelled")) {
    return { kind: code };
  }
  if (raw.status === 400 && code === "invalidText") return { kind: "invalidText" };
  if (raw.status === 429) return { kind: "rateLimited", retryAfterSeconds: parseRetryAfter(raw.retryAfter, opts.now) };
  return { kind: "server" };
}

/** La clienta confirma el menú de una semana (el envío sendId). */
export async function confirmMenu(supabaseUrl: string, token: string, sendId: string, opts: ApiOptions = {}): Promise<ActionOutcome> {
  const raw = await post(clientLinkUrl(supabaseUrl, CLIENT_LINK_ROUTES.confirm), { token, sendId }, opts);
  if (!raw) return { kind: "network" };
  if (raw.status !== 200) return actionError(raw, opts);
  const body = isRecord(raw.body) ? raw.body : {};
  const confirmedAt = body["confirmedAt"];
  const already = body["already"];
  return isTimestamp(confirmedAt) && typeof already === "boolean" ? { kind: "confirmed", confirmedAt, already } : { kind: "server" };
}

/** La clienta pide cambios para el menú de una semana, con su mensaje (ya normalizado: normalizeChangesText). */
export async function requestChanges(
  supabaseUrl: string,
  token: string,
  sendId: string,
  text: string,
  opts: ApiOptions = {},
): Promise<ActionOutcome> {
  const raw = await post(clientLinkUrl(supabaseUrl, CLIENT_LINK_ROUTES.changes), { token, sendId, text }, opts);
  if (!raw) return { kind: "network" };
  if (raw.status !== 200) return actionError(raw, opts);
  const at = isRecord(raw.body) ? raw.body["changesRequestedAt"] : null;
  return isTimestamp(at) ? { kind: "changesSent", changesRequestedAt: at } : { kind: "server" };
}
