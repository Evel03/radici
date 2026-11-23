// Recuadro «Cómo sigue» del formulario. Pura: devuelve el resumen de lo que pide (nunca dinero: la web no
// muestra precios, el presupuesto lo prepara Evelyn a mano) y richiesta.ts solo lo pinta. Los pasos y la frase
// de la compra son fijos en el HTML.
import type { I18n } from "../i18n/core.ts";
import type { CookLoad } from "../engine.ts";
import { weeksOf, type RequestData } from "./model.ts";
import { peopleText, type SummaryRow } from "./summary.ts";

/**
 * Lo que pide, con los mismos rótulos que la pantalla de gracias: tipo, semanas (solo el pedido semanal),
 * personas, días y comidas, y las porciones (de una semana en el pedido semanal; de la sesión, en una extra).
 */
export function nextSummary(data: RequestData, load: CookLoad, i18n: I18n): SummaryRow[] {
  const { t } = i18n;
  const weekly = data.type === "week";
  const rows: SummaryRow[] = [{ label: t("request.summary.type"), value: t(`request.type.${data.type}`) }];
  if (weekly) rows.push({ label: t("request.summary.weeks"), value: String(weeksOf(data)) });
  rows.push(
    { label: t("request.summary.people"), value: peopleText(data.adults, data.kids, t) },
    { label: t(weekly ? "request.summary.daysPerWeek" : "request.summary.days"), value: String(data.days) },
    { label: t("request.summary.meals"), value: t(`request.meals.${data.meals}`) },
    { label: t(weekly ? "request.next.portionsWeekly" : "request.next.portions"), value: String(load.portions) },
  );
  return rows;
}
