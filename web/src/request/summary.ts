// Resumen del pedido para la pantalla de gracias. Pura: devuelve textos, la página los pinta con textContent.
// Solo datos del pedido (tipo, semanas, personas, días, comidas, fechas, platos elegidos) y qué contestó sobre
// alergias (ninguna o indicadas, nunca cuáles): nada de contacto ni de salud. Ningún precio: la web no los
// muestra (decisión del 22/11/2026), el presupuesto lo prepara Evelyn a mano.
import { localizedText, type MenuChoice } from "../../../supabase/functions/_shared/menu.ts";
import type { I18n } from "../i18n/core.ts";
import { formatIsoDate, formatShortDate } from "../lib/format.ts";
import { weeklyDates, weeksOf, type RequestData } from "./model.ts";

export interface SummaryRow {
  label: string;
  value: string;
}

export function peopleText(adults: number, kids: number, t: I18n["t"]): string {
  const a = adults === 1 ? t("request.summary.adultsOne") : t("request.summary.adultsOther", { n: adults });
  const k = kids === 1 ? t("request.summary.kidsOne") : t("request.summary.kidsOther", { n: kids });
  if (kids === 0) return a;
  if (adults === 0) return k;
  return t("request.summary.peopleJoin", { a, b: k });
}

/**
 * El menù: los platos que guardó el servidor, en el idioma de la página (o en italiano); si son menos que
 * los días, que el resto lo propone Evelyn; sin platos, que lo propone ella.
 */
export function menuSummary(menu: readonly MenuChoice[], days: number, i18n: I18n): string {
  const { t, lang } = i18n;
  if (menu.length === 0) return t("request.summary.menuNone");
  const dishes = menu.map((dish) => localizedText(dish.name, lang)).join(" · ");
  return menu.length < days ? t("request.summary.menuPartial", { dishes }) : dishes;
}

/**
 * @param menu los platos que guardó el servidor (doneMenu en menu.ts); [] si el menù lo propone Evelyn.
 */
export function summaryRows(
  data: RequestData,
  i18n: I18n,
  menu: readonly MenuChoice[] = [],
): SummaryRow[] {
  const { t, locale } = i18n;
  const weeks = weeksOf(data);
  const rows: SummaryRow[] = [{ label: t("request.summary.type"), value: t(`request.type.${data.type}`) }];
  // Las semanas son del pedido semanal; sus días, de cada semana.
  if (data.type === "week") rows.push({ label: t("request.summary.weeks"), value: String(weeks) });
  rows.push(
    { label: t("request.summary.people"), value: peopleText(data.adults, data.kids, t) },
    { label: t(data.type === "week" ? "request.summary.daysPerWeek" : "request.summary.days"), value: String(data.days) },
    { label: t("request.summary.meals"), value: t(`request.meals.${data.meals}`) },
  );
  if (data.preferredDate && weeks > 1) {
    // Una sesión por semana, el mismo día: las fechas de todas las semanas. Con «·» entre fechas (en
    // inglés la fecha corta ya lleva coma: "Mon, 23 Nov") y espacios duros dentro de cada una: en el
    // teléfono la línea se corta entre dos fechas, nunca en medio de una.
    const dates = weeklyDates(data.preferredDate, weeks).map((date) => formatShortDate(date, locale).replace(/ /g, "\u00a0"));
    rows.push({ label: t("request.summary.dates"), value: dates.join(" · ") });
  } else {
    rows.push({
      label: t("request.summary.date"),
      value: data.preferredDate ? formatIsoDate(data.preferredDate, locale) : t("request.summary.dateNone"),
    });
  }
  rows.push({ label: t("request.summary.menu"), value: menuSummary(menu, data.days, i18n) });
  // Qué contestó sobre alergias, nunca cuáles. Un pedido guardado sin la casilla siempre trae alergias
  // escritas (el servidor las exige).
  rows.push({
    label: t("request.summary.allergies"),
    value: t(data.noAllergies ? "request.summary.allergiesNone" : "request.summary.allergiesListed"),
  });
  return rows;
}
