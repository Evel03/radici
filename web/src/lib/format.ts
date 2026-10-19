// Formato de importes, duraciones y fechas. Los importes siempre llegan en centavos enteros.
import type { I18n } from "../i18n/core.ts";

const currencyFormatters = new Map<string, Intl.NumberFormat>();

export function formatCents(cents: number, locale: string): string {
  if (!Number.isInteger(cents)) throw new RangeError(`Importe no entero en centavos: ${cents}`);
  let fmt = currencyFormatters.get(locale);
  if (!fmt) {
    fmt = new Intl.NumberFormat(locale, { style: "currency", currency: "EUR" });
    currencyFormatters.set(locale, fmt);
  }
  // La división es solo para mostrar: ningún cálculo usa este valor.
  return fmt.format(cents / 100);
}

export function formatDuration(minutes: number, i18n: Pick<I18n, "t">): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return i18n.t("common.durationMinutes", { m });
  if (m === 0) return i18n.t("common.durationHours", { h });
  return i18n.t("common.durationHoursMinutes", { h, m });
}

/** "2026-10-26" → "lunedì 26 ottobre 2026" (según el locale). */
export function formatIsoDate(iso: string, locale: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!match) return iso;
  const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
  return new Intl.DateTimeFormat(locale, {
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(date);
}
