// Fechas de negocio en Europe/Rome, como cadenas ISO "AAAA-MM-DD".
// addDays e isIsoDate son las del contrato compartido: la web y el servidor calculan igual la ventana de fechas.
export { addDays, isIsoDate } from "../../../supabase/functions/_shared/public_request.ts";

export const BUSINESS_TIME_ZONE = "Europe/Rome";

/** Fecha de hoy en Bergamo (no la del dispositivo ni UTC). Con formatToParts: no depende del formato de en-CA. */
export function todayInRome(now: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: BUSINESS_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const get = (type: string): string => parts.find((p) => p.type === type)?.value ?? "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}
