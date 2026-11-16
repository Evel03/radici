// Recuadro del precio del formulario. Pura: devuelve los textos y qué se ve; richiesta.ts solo los pinta.
// Con precio automático: el servicio de todas las semanas (destacado), el de cada semana si son más de una
// y el ahorro desde el descuento, frente a la tarifa sin descuento. Sin él (más personas que el tope o una
// sesión extra), quién prepara el presupuesto y por qué. La compra estimada siempre, aparte.
import type { I18n } from "../i18n/core.ts";
import { formatCents } from "../lib/format.ts";
import type { Quote } from "../engine.ts";
import type { RequestType } from "./model.ts";

export interface QuoteBoxRow {
  label: string;
  value: string;
}

export interface QuoteBoxView {
  /** Sin precio automático: el texto que va en lugar del total. null si hay precio. */
  manual: string | null;
  /** El servicio destacado: de todas las semanas, o de la única. null sin precio. */
  total: QuoteBoxRow | null;
  /** El servicio de cada semana (el rótulo es fijo en el HTML): solo con precio y más de una semana. */
  weekly: string | null;
  /** El ahorro frente a la tarifa sin descuento: solo si hay. */
  savings: string | null;
  /** La compra estimada: de una semana en el pedido semanal; de la sesión, en una extra. */
  groceries: QuoteBoxRow;
  portions: QuoteBoxRow;
}

export function quoteBoxView(quote: Quote, type: RequestType, i18n: I18n): QuoteBoxView {
  const { t, locale } = i18n;
  const money = (cents: number): string => formatCents(cents, locale);
  // Las porciones y la compra son de una semana; en una sesión extra, de esa sesión.
  const weekly = type === "week";
  const groceries = { label: t(weekly ? "request.quote.groceriesWeekly" : "request.quote.groceries"), value: money(quote.groceriesEstCents) };
  const portions = { label: t(weekly ? "request.quote.portionsWeekly" : "request.quote.portions"), value: String(quote.portions) };
  if (!quote.autoPrice) {
    const manual = t(quote.reason === "extra" ? "request.quote.manualExtra" : "request.quote.manualPeople");
    return { manual, total: null, weekly: null, savings: null, groceries, portions };
  }
  return {
    manual: null,
    total: {
      label: quote.weeks > 1 ? t("request.quote.serviceWeeks", { weeks: quote.weeks }) : t("request.quote.service"),
      value: money(quote.serviceCents),
    },
    // Con una semana el precio por semana es el total: no se repite.
    weekly: quote.weeks > 1 ? money(quote.weeklyServiceCents) : null,
    savings: quote.savingsCents > 0 ? t("request.quote.savings", { amount: money(quote.savingsCents) }) : null,
    groceries,
    portions,
  };
}
