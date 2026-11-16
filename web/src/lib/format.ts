// Formato de importes y fechas. Los importes siempre llegan en centavos enteros.
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

function formatDay(iso: string, locale: string, options: Intl.DateTimeFormatOptions): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!match) return iso;
  const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
  return new Intl.DateTimeFormat(locale, { ...options, timeZone: "UTC" }).format(date);
}

/** "2026-10-26" → "lunedì 26 ottobre 2026" (según el locale). */
export function formatIsoDate(iso: string, locale: string): string {
  return formatDay(iso, locale, { weekday: "long", day: "numeric", month: "long", year: "numeric" });
}

/** "2026-10-26" → "lun 26 ott" (según el locale): para listas de fechas. */
export function formatShortDate(iso: string, locale: string): string {
  return formatDay(iso, locale, { weekday: "short", day: "numeric", month: "short" });
}
