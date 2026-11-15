// Calendario mensual del día preferido: qué meses se muestran, qué días se pueden elegir y por qué.
// Puro: la página (richiesta.ts) solo pinta lo que devuelve. Fechas "AAAA-MM-DD" de Europe/Rome.
// La ventana (DATE_WINDOW: de mañana a 8 semanas, dos o tres meses) y la disponibilidad salen del
// contrato compartido con el servidor.
import {
  availabilityDates,
  type AvailabilityResponse,
} from "../../../supabase/functions/_shared/availability.ts";

/** Estado de la consulta de disponibilidad (GET <public-request>/availability). */
export type AvailabilityState =
  | { kind: "loading" }
  /** Respuesta válida: true si Evelyn tiene lugar ese día para la duración del pedido. */
  | { kind: "ready"; days: ReadonlyMap<string, boolean> }
  /** Sin respuesta útil (red, servidor, otra versión): se puede elegir cualquier día de la ventana. */
  | { kind: "error" };

/**
 * - available: se puede elegir.
 * - unavailable: dentro de la ventana, pero ocupado o fuera de los días de trabajo de Evelyn.
 * - pending: dentro de la ventana, esperando la disponibilidad.
 * - outside: antes de mañana o después de la ventana.
 */
export type DayStatus = "available" | "unavailable" | "pending" | "outside";

export interface MonthRef {
  year: number;
  /** 1 a 12. */
  month: number;
}

export interface CalendarCell {
  date: string;
  day: number;
  status: DayStatus;
  selected: boolean;
}

export interface CalendarMonth extends MonthRef {
  /** Casilleros vacíos antes del día 1: las semanas van de lunes a domingo. */
  leading: number;
  cells: CalendarCell[];
}

export interface CalendarInput {
  /** Hoy en Europe/Rome. */
  today: string;
  /** Día elegido, o "" si ninguno. */
  selected: string;
  /**
   * Si la disponibilidad aplica. Solo para la semana de comidas: los eventos y sesiones extra suelen ser
   * fuera del horario semanal y Evelyn confirma la fecha cuando contacta.
   */
  applies: boolean;
  availability: AvailabilityState;
}

const pad = (n: number): string => String(n).padStart(2, "0");

export function isoDate(year: number, month: number, day: number): string {
  return `${year}-${pad(month)}-${pad(day)}`;
}

function dateParts(iso: string): { year: number; month: number; day: number } {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!match) throw new RangeError(`Fecha inválida: ${iso}`);
  return { year: Number(match[1]), month: Number(match[2]), day: Number(match[3]) };
}

export function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/** Lunes = 0 … domingo = 6. */
export function mondayIndex(iso: string): number {
  const { year, month, day } = dateParts(iso);
  return (new Date(Date.UTC(year, month - 1, day)).getUTCDay() + 6) % 7;
}

/** Meses que tocan la ventana de fechas elegibles (dos o tres: 56 días nunca caben en uno ni tocan cuatro), en orden. */
export function windowMonths(today: string): MonthRef[] {
  const months: MonthRef[] = [];
  for (const date of availabilityDates(today)) {
    const { year, month } = dateParts(date);
    const last = months[months.length - 1];
    if (!last || last.year !== year || last.month !== month) months.push({ year, month });
  }
  return months;
}

/**
 * Flechas del calendario: el mes a mostrar (índice en windowMonths, recortado a los que hay) y si se
 * puede ir al anterior y al siguiente. Con tres meses, en el del medio se puede ir a los dos lados.
 */
export function monthNav(index: number, count: number): { index: number; prev: boolean; next: boolean } {
  const clamped = Math.min(Math.max(index, 0), count - 1);
  return { index: clamped, prev: clamped > 0, next: clamped < count - 1 };
}

/**
 * La respuesta del servidor como estado del calendario (null: no hubo una respuesta útil). Puede traer
 * otro largo que la ventana (una función de otra versión, durante un despliegue): cada día se busca por
 * fecha, así que los que no vienen cuentan como no disponibles y los de más quedan fuera.
 */
export function availabilityState(response: AvailabilityResponse | null, minutes: number): AvailabilityState {
  if (!response || response.minutes !== minutes) return { kind: "error" };
  return { kind: "ready", days: new Map(response.days.map((d) => [d.date, d.available])) };
}

function statusOf(date: string, window: ReadonlySet<string>, input: CalendarInput): DayStatus {
  if (!window.has(date)) return "outside";
  if (!input.applies) return "available";
  switch (input.availability.kind) {
    case "loading":
      return "pending";
    case "error":
      return "available";
    case "ready":
      return input.availability.days.get(date) === true ? "available" : "unavailable";
  }
}

export function dayStatus(date: string, input: CalendarInput): DayStatus {
  return statusOf(date, new Set(availabilityDates(input.today)), input);
}

export function buildMonth(ref: MonthRef, input: CalendarInput): CalendarMonth {
  const window = new Set(availabilityDates(input.today));
  const cells: CalendarCell[] = [];
  for (let day = 1; day <= daysInMonth(ref.year, ref.month); day++) {
    const date = isoDate(ref.year, ref.month, day);
    cells.push({ date, day, status: statusOf(date, window, input), selected: date === input.selected });
  }
  return { year: ref.year, month: ref.month, leading: mondayIndex(isoDate(ref.year, ref.month, 1)), cells };
}

/** Si el día elegido sigue valiendo. Mientras carga la disponibilidad se conserva. */
export function selectionStillValid(input: CalendarInput): boolean {
  if (input.selected === "") return true;
  const status = dayStatus(input.selected, input);
  return status === "available" || status === "pending";
}

/** Semana de comidas con la disponibilidad cargada y ningún día libre en la ventana. */
export function noFreeDays(input: CalendarInput): boolean {
  const { availability } = input;
  if (!input.applies || availability.kind !== "ready") return false;
  return availabilityDates(input.today).every((date) => availability.days.get(date) !== true);
}

/**
 * Mes a mostrar al entrar: el del día elegido; si no hay, el primero con algún día para elegir; si no,
 * el primero de la ventana. Devuelve el índice dentro de windowMonths(hoy).
 */
export function initialMonthIndex(input: CalendarInput): number {
  const months = windowMonths(input.today);
  const indexOf = (date: string): number => {
    const { year, month } = dateParts(date);
    return months.findIndex((m) => m.year === year && m.month === month);
  };
  if (input.selected !== "") {
    const i = indexOf(input.selected);
    if (i >= 0) return i;
  }
  const firstFree = availabilityDates(input.today).find((date) => dayStatus(date, input) === "available");
  return firstFree ? Math.max(0, indexOf(firstFree)) : 0;
}
