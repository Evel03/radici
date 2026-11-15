// Disponibilidad por día para el calendario del formulario de la web:
// GET <función public-request>/availability?minutes=<minutos de cocina>.
// Contrato compartido entre la Edge Function y la web: un solo origen, nada copiado.
// Solo sintaxis borrable (corre en Node, Deno y Vite sin compilar) e imports con extensión .ts.
import { DATE_WINDOW, addDays, isIsoDate } from "./public_request.ts";

/** Versión de la respuesta. Si cambia su forma, se sube: la web vieja deja de marcar disponibilidad. */
export const AVAILABILITY_VERSION = 1;

/** Ruta dentro de la función public-request (la URL termina así, antes de la query). */
export const AVAILABILITY_PATH = "/availability";

/**
 * Minutos de cocina que acepta `?minutes=`: los del motor de presupuesto, en múltiplos de 30.
 * El máximo deja margen sobre el pedido más grande posible (7 días con almuerzo y cena: 330 min).
 */
export const AVAILABILITY_MINUTES = { min: 30, max: 720, step: 30 } as const;

/** Días que cubre la respuesta: los mismos que se pueden elegir en el formulario (DATE_WINDOW). */
export const AVAILABILITY_DAYS = DATE_WINDOW.maxDaysAhead - DATE_WINDOW.minDaysAhead + 1;

export interface AvailabilityDay {
  /** "AAAA-MM-DD", día de Europe/Rome. */
  date: string;
  /** true si Evelyn tiene al menos un horario libre ese día para esa duración (SPEC §5.2). */
  available: boolean;
}

export interface AvailabilityResponse {
  version: typeof AVAILABILITY_VERSION;
  /** Los minutos de cocina con que se calculó. */
  minutes: number;
  /** Un día por fecha de availabilityDates(hoy), en orden y sin huecos. */
  days: AvailabilityDay[];
}

/** Valida `?minutes=` tal como llega en la URL. null si no es un entero aceptado. */
export function parseAvailabilityMinutes(raw: string | null): number | null {
  if (raw === null || !/^\d{1,4}$/.test(raw)) return null;
  const minutes = Number(raw);
  const { min, max, step } = AVAILABILITY_MINUTES;
  return minutes >= min && minutes <= max && minutes % step === 0 ? minutes : null;
}

/** Fechas que cubre la respuesta para un "hoy" de Europe/Rome ("AAAA-MM-DD"): desde mañana. */
export function availabilityDates(today: string): string[] {
  return Array.from({ length: AVAILABILITY_DAYS }, (_, i) => addDays(today, DATE_WINDOW.minDaysAhead + i));
}

/**
 * Arma la respuesta del servidor: todas las fechas de la ventana, disponibles solo las que vinieron
 * marcadas así de la base. Una fecha que la base no devolvió cuenta como no disponible.
 */
export function buildAvailabilityResponse(
  today: string,
  minutes: number,
  availableDates: Iterable<string>,
): AvailabilityResponse {
  const free = new Set(availableDates);
  return {
    version: AVAILABILITY_VERSION,
    minutes,
    days: availabilityDates(today).map((date) => ({ date, available: free.has(date) })),
  };
}

/**
 * Lectura defensiva en la web: null si la respuesta no tiene la forma esperada (otra versión, un error,
 * un proxy). Con null el calendario no marca disponibilidad y deja elegir cualquier día de la ventana.
 */
export function parseAvailabilityResponse(json: unknown): AvailabilityResponse | null {
  if (typeof json !== "object" || json === null) return null;
  const { version, minutes, days } = json as Record<string, unknown>;
  if (version !== AVAILABILITY_VERSION || !Number.isInteger(minutes) || !Array.isArray(days)) return null;
  const out: AvailabilityDay[] = [];
  for (const day of days) {
    if (typeof day !== "object" || day === null) return null;
    const { date, available } = day as Record<string, unknown>;
    if (typeof date !== "string" || !isIsoDate(date) || typeof available !== "boolean") return null;
    if (out.length > 0 && date !== addDays(out[out.length - 1].date, 1)) return null;
    out.push({ date, available });
  }
  return { version: AVAILABILITY_VERSION, minutes: minutes as number, days: out };
}
