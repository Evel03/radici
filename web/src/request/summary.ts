// Resumen del pedido para la pantalla de gracias. Pura: devuelve textos, la página los pinta con textContent.
// Solo datos del pedido (tipo, personas, días, comidas, fecha, estimación) y qué contestó sobre
// alergias (ninguna o indicadas, nunca cuáles): nada de contacto ni de salud.
import type { I18n } from "../i18n/core.ts";
import { formatCents, formatIsoDate } from "../lib/format.ts";
import type { RequestData } from "./model.ts";

export interface SummaryRow {
  label: string;
  value: string;
  /** La fila del total estimado (se destaca). */
  total?: boolean;
}

export function peopleText(adults: number, kids: number, t: I18n["t"]): string {
  const a = adults === 1 ? t("request.summary.adultsOne") : t("request.summary.adultsOther", { n: adults });
  const k = kids === 1 ? t("request.summary.kidsOne") : t("request.summary.kidsOther", { n: kids });
  if (kids === 0) return a;
  if (adults === 0) return k;
  return t("request.summary.peopleJoin", { a, b: k });
}

/**
 * @param estimate la del servidor (con las tarifas de la cocinera) o, si no vino, la de la calculadora.
 */
export function summaryRows(data: RequestData, estimate: { totalCents: number } | null, i18n: I18n): SummaryRow[] {
  const { t, locale } = i18n;
  const rows: SummaryRow[] = [
    { label: t("request.summary.type"), value: t(`request.type.${data.type}`) },
    { label: t("request.summary.people"), value: peopleText(data.adults, data.kids, t) },
    { label: t("request.summary.days"), value: String(data.days) },
    { label: t("request.summary.meals"), value: t(`request.meals.${data.meals}`) },
    {
      label: t("request.summary.date"),
      value: data.preferredDate ? formatIsoDate(data.preferredDate, locale) : t("request.summary.dateNone"),
    },
  ];
  // Qué contestó sobre alergias, nunca cuáles. Un pedido guardado sin la casilla siempre trae alergias
  // escritas (el servidor las exige).
  rows.push({
    label: t("request.summary.allergies"),
    value: t(data.noAllergies ? "request.summary.allergiesNone" : "request.summary.allergiesListed"),
  });
  if (estimate) rows.push({ label: t("request.summary.total"), value: formatCents(estimate.totalCents, locale), total: true });
  return rows;
}
