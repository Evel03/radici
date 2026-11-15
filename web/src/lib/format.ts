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
