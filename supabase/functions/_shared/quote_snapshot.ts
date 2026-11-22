// El presupuesto en la foto del envío del menú de la semana 1 (menu_sends.snapshot.quote, SPEC 5.8; migración
// 20261121120000_quotes.sql). Lo arma la función chef en la vista previa con los términos que calcula la base
// (chef_menu_send_context → quote.terms, los mismos que guarda menu_sends.quote_terms y que la clienta acepta: la
// huella de la foto los cubre). De acá salen la sección del presupuesto del email y del WhatsApp
// (menu_message.ts) y el resumen de la página de la clienta (client_link.ts).
// - Solo el servicio: cada semana con su fecha, su llegada y su precio, y el total, en centavos enteros. Nunca la
//   forma ni el momento de pago (este proceso no cambia ni describe nada de pagos), la dirección ni las alergias.
// - El plazo para aceptarlo: holdHours (chef_settings.quote_hold_hours) desde que sale, nunca más allá de la llegada
//   de la primera semana (firstStart), como lo calcula chef_complete_menu_send.
// Solo sintaxis borrable (corre en Node, Deno y Vite sin compilar) e imports con extensión .ts.
import { isIsoDate } from "./public_request.ts";

/** Semanas de un presupuesto: de 1 a 8, como chef_create_quote. */
export const QUOTE_MAX_WEEKS = 8;
/** Tope de un importe: el de la función chef (MAX_CENTS de chef_api.ts, 100.000 € en centavos; un test los compara). */
export const QUOTE_MAX_CENTS = 10_000_000;
/** Tope del plazo en horas, para leer con cuidado (chef_settings.quote_hold_hours solo exige más de 0). */
export const QUOTE_MAX_HOLD_HOURS = 24 * 366;
/** Versión de un presupuesto (quotes.version, un smallint desde 1). */
export const QUOTE_MAX_VERSION = 32_767;

/** Una semana del presupuesto: la fecha y la llegada (Roma) y el precio del servicio de esa semana. */
export interface SnapshotQuoteWeek {
  /** "AAAA-MM-DD". */
  date: string;
  /** "HH:MM". */
  start: string;
  serviceCents: number;
}

export interface SnapshotQuote {
  /** La versión que sale con este envío: 1 la primera vez; cada reenvío, la siguiente (chef_complete_menu_send). */
  version: number;
  /** El precio del servicio de todas las semanas, en centavos: la suma de las semanas. */
  totalCents: number;
  /** Las semanas vivas del presupuesto, por fecha y hora (de 1 a 8). */
  weeks: SnapshotQuoteWeek[];
  /** Horas para aceptarlo desde que sale. */
  holdHours: number;
  /** La llegada de la primera semana, "AAAA-MM-DDTHH:MM" (hora de Roma): el plazo nunca la pasa. */
  firstStart: string;
}

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isIntBetween(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
}

/** "AAAA-MM-DDTHH:MM" de una fecha y una hora: la forma de firstStart. */
export function quoteFirstStart(date: string, start: string): string {
  return `${date}T${start}`;
}

function readWeek(value: unknown): SnapshotQuoteWeek | null {
  if (!isRecord(value)) return null;
  const date = value["date"];
  const start = value["start"];
  const serviceCents = value["serviceCents"];
  if (typeof date !== "string" || !isIsoDate(date) || typeof start !== "string" || !TIME.test(start)) return null;
  if (!isIntBetween(serviceCents, 0, QUOTE_MAX_CENTS)) return null;
  return { date, start, serviceCents };
}

/**
 * El bloque quote de una foto, armado de nuevo campo por campo: null si no tiene (un envío sin presupuesto, o una
 * foto de antes), undefined si tiene otra forma (quien lo lee no muestra nada a medias). Exige que el total sea la
 * suma de las semanas, que estén en orden y que firstStart sea la llegada de la primera: nunca un precio o un
 * plazo que no cierran.
 */
export function readSnapshotQuote(value: unknown): SnapshotQuote | null | undefined {
  if (value === null || value === undefined) return null;
  if (!isRecord(value)) return undefined;
  const { version, totalCents, holdHours, firstStart } = value;
  const raw = value["weeks"];
  if (!isIntBetween(version, 1, QUOTE_MAX_VERSION) || !isIntBetween(totalCents, 0, QUOTE_MAX_CENTS)) return undefined;
  if (!isIntBetween(holdHours, 1, QUOTE_MAX_HOLD_HOURS) || typeof firstStart !== "string") return undefined;
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > QUOTE_MAX_WEEKS) return undefined;
  const weeks: SnapshotQuoteWeek[] = [];
  for (const item of raw) {
    const week = readWeek(item);
    if (!week) return undefined;
    const previous = weeks[weeks.length - 1];
    if (previous && quoteFirstStart(week.date, week.start) < quoteFirstStart(previous.date, previous.start)) return undefined;
    weeks.push(week);
  }
  const first = weeks[0];
  if (!first || firstStart !== quoteFirstStart(first.date, first.start)) return undefined;
  if (weeks.reduce((sum, week) => sum + week.serviceCents, 0) !== totalCents) return undefined;
  return { version, totalCents, weeks, holdHours, firstStart };
}

/** true si todas las semanas tienen el mismo precio (el mensaje dice entonces «x € por semana»). */
export function sameWeeklyPrice(quote: Pick<SnapshotQuote, "weeks">): boolean {
  const first = quote.weeks[0];
  return first !== undefined && quote.weeks.every((week) => week.serviceCents === first.serviceCents);
}

// ---------------------------------------------------------------------------
// El plazo para aceptarlo
// ---------------------------------------------------------------------------

const ROME_PARTS = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/Rome",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

/** Minutos que Roma le lleva a UTC en ese instante (60 en invierno, 120 en verano). */
function romeOffsetMinutes(epochMs: number): number {
  const parts = ROME_PARTS.formatToParts(new Date(epochMs));
  const get = (type: string): number => Number(parts.find((part) => part.type === type)?.value ?? "0");
  const wall = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
  return Math.round((wall - Math.floor(epochMs / 1000) * 1000) / 60_000);
}

/**
 * El instante (ms desde 1970, UTC) de una fecha y una hora de Roma, como `(fecha + hora) at time zone
 * 'Europe/Rome'` en Postgres. Dos pasadas: la segunda corrige el cambio de hora.
 */
export function romeInstant(date: string, time: string): number {
  const [y, m, d] = date.split("-").map(Number);
  const [hh, mm] = time.split(":").map(Number);
  const wall = Date.UTC(y ?? 0, (m ?? 1) - 1, d ?? 1, hh ?? 0, mm ?? 0);
  const guess = wall - romeOffsetMinutes(wall) * 60_000;
  return wall - romeOffsetMinutes(guess) * 60_000;
}

/**
 * Hasta cuándo puede aceptarlo, si sale ahora: holdHours desde `now` o, si eso pasa la llegada de la primera
 * semana, esa llegada (least(now() + quote_hold_hours, primera llegada) de chef_complete_menu_send). El mensaje
 * dice «entro 48 ore» o «prima di <día y hora>».
 */
export type QuoteDeadline = { kind: "hours"; hours: number } | { kind: "firstArrival"; date: string; start: string };

export function quoteDeadline(quote: Pick<SnapshotQuote, "holdHours" | "weeks">, now: Date): QuoteDeadline {
  const first = quote.weeks[0];
  if (!first) return { kind: "hours", hours: quote.holdHours };
  const arrival = romeInstant(first.date, first.start);
  return now.getTime() + quote.holdHours * 3_600_000 <= arrival
    ? { kind: "hours", hours: quote.holdHours }
    : { kind: "firstArrival", date: first.date, start: first.start };
}
