// Formato de importes y fechas. Los importes siempre llegan en centavos enteros. La web pública no muestra precios
// (decisión del 22/11/2026): el único importe es el que Evelyn escribe en su presupuesto, en la página de la reserva.
const currencyFormatters = new Map<string, Intl.NumberFormat>();

export function formatCents(cents: number, locale: string): string {
  if (!Number.isInteger(cents)) throw new RangeError(`Importe no entero en centavos: ${cents}`);
  let fmt = currencyFormatters.get(locale);
  if (!fmt) {
    // Miles siempre separados: it-IT y es-ES no agrupan los importes de 4 cifras ("1120,00 €") y el email y
    // la app sí ("1.120,00 €"). Un navegador sin Intl.NumberFormat v3 lo toma como true (agrupa como antes).
    // "always" es de ES2023 y la web compila con la lib de ES2022: de ahí la conversión.
    const useGrouping = "always" as unknown as boolean;
    fmt = new Intl.NumberFormat(locale, { style: "currency", currency: "EUR", useGrouping });
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
