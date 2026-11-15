// Disponibilidad por día para el calendario: GET <función public-request>/availability?minutes=N
// (contrato en supabase/functions/_shared/availability.ts y docs/contracts/public-request.md).
// Es una petición simple (GET sin cabeceras propias), así que el navegador no manda preflight de CORS,
// y el servidor la deja cachear 60 s. Si no hay una respuesta útil, el calendario no marca ocupados.
import {
  AVAILABILITY_PATH,
  parseAvailabilityResponse,
  type AvailabilityResponse,
} from "../../../supabase/functions/_shared/availability.ts";
import { FUNCTION_REGION, PUBLIC_REQUEST_PATH } from "./submit.ts";

/** Más que esto y se deja elegir cualquier día: mejor eso que un calendario que no responde. */
export const AVAILABILITY_TIMEOUT_MS = 8_000;

export function availabilityUrl(supabaseUrl: string, minutes: number): string {
  const base = supabaseUrl.replace(/\/+$/, "");
  return `${base}${PUBLIC_REQUEST_PATH}${AVAILABILITY_PATH}?forceFunctionRegion=${FUNCTION_REGION}&minutes=${minutes}`;
}

export interface AvailabilityFetchOptions {
  /** Para los tests; en el navegador, window.fetch. */
  fetch?: (input: string, init: RequestInit) => Promise<Response>;
  timeoutMs?: number;
}

/** null si no hubo una respuesta útil: sin conexión, tiempo agotado, error del servidor u otra forma. */
export async function fetchAvailability(
  url: string,
  opts: AvailabilityFetchOptions = {},
): Promise<AvailabilityResponse | null> {
  // Llamada envuelta: algunos navegadores fallan si fetch se invoca sin su `this` (window).
  const fetchFn = opts.fetch ?? ((input: string, init: RequestInit) => fetch(input, init));
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? AVAILABILITY_TIMEOUT_MS);
  try {
    const response = await fetchFn(url, { method: "GET", credentials: "omit", signal: controller.signal });
    if (!response.ok) return null;
    return parseAvailabilityResponse(JSON.parse(await response.text()) as unknown);
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}
