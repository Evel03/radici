// Resumen del pedido para la pantalla de gracias. Pura: devuelve textos, la página los pinta con textContent.
// Solo datos del pedido (tipo, semanas, personas, días, comidas, fechas, platos elegidos, estimación) y qué
// contestó sobre alergias (ninguna o indicadas, nunca cuáles): nada de contacto ni de salud.
import { localizedText, type MenuChoice } from "../../../supabase/functions/_shared/menu.ts";
import type { I18n } from "../i18n/core.ts";
import { formatCents, formatIsoDate, formatShortDate } from "../lib/format.ts";
import { publicEstimate, weeklyDates, weeksOf, type PublicRequestEstimate, type RequestData } from "./model.ts";
import { computeQuote } from "./quote.ts";

/**
 * La estimación que muestra la pantalla de gracias: la del servidor (con las tarifas de la cocinera) o, si
 * no vino (o vino con otra forma), la de la calculadora con los datos de ese pedido. Sin los datos (no se
 * sabe qué guardó el servidor), ninguna.
 */
export function doneEstimate(data: RequestData | null, fromServer: PublicRequestEstimate | null): PublicRequestEstimate | null {
  if (!data) return null;
  if (fromServer) return fromServer;
  const local = computeQuote(data);
  return local ? publicEstimate(local) : null;
}

export interface SummaryRow {
  label: string;
  value: string;
  /** El importe que se paga por el servicio (se destaca). */
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
 * El precio: con precio automático, el servicio (por semana y de todas las semanas, y el ahorro si hay
 * descuento); sin él, que lo prepara Evelyn. La compra la hace el cliente con la lista de Evelyn (decisión del
 * 19/11/2026): no tiene fila.
 */
export function priceRows(estimate: PublicRequestEstimate, i18n: I18n): SummaryRow[] {
  const { t, locale } = i18n;
  const money = (cents: number): string => formatCents(cents, locale);
  const rows: SummaryRow[] = [];
  if (!estimate.autoPrice) {
    rows.push({ label: t("request.summary.service"), value: t("request.summary.servicePending") });
  } else if (estimate.weeks > 1) {
    rows.push({ label: t("request.summary.weeklyService"), value: money(estimate.weeklyServiceCents) });
    rows.push({ label: t("request.summary.serviceWeeks", { weeks: estimate.weeks }), value: money(estimate.serviceCents), total: true });
  } else {
    rows.push({ label: t("request.summary.service"), value: money(estimate.serviceCents), total: true });
  }
  if (estimate.autoPrice && estimate.savingsCents > 0) {
    rows.push({ label: t("request.summary.savings"), value: money(estimate.savingsCents) });
  }
  return rows;
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
 * @param estimate la del servidor (con las tarifas de la cocinera) o, si no vino, la de la calculadora.
 * @param menu los platos que guardó el servidor (doneMenu en menu.ts); [] si el menù lo propone Evelyn.
 */
export function summaryRows(
  data: RequestData,
  estimate: PublicRequestEstimate | null,
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
  if (estimate) rows.push(...priceRows(estimate, i18n));
  return rows;
}
