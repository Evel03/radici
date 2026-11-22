// Formato de fechas. La web no formatea importes: no muestra precios (decisión del 22/11/2026).
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
