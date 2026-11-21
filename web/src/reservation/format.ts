// Formatos de la página /prenotazione/: cantidades de la lista de compras, la lista agrupada por sección y las
// fechas de los envíos. Puros (se testean sin DOM).
import {
  SHOPPING_SECTIONS,
  type ShoppingItem,
  type ShoppingSection,
  type ShoppingUnit,
} from "../../../supabase/functions/_shared/client_link.ts";
import type { I18n } from "../i18n/core.ts";
import { BUSINESS_TIME_ZONE } from "../lib/dates.ts";

/** Espacio duro entre el número y la unidad: «1,25 kg» no se parte en dos renglones. */
const NBSP = "\u00a0";

const numberFormatters = new Map<string, Intl.NumberFormat>();

/** Hasta tres decimales, con el separador del idioma: 1.25 → «1,25» (it, es) o «1.25» (en). */
function formatNumber(value: number, locale: string): string {
  let fmt = numberFormatters.get(locale);
  if (!fmt) {
    fmt = new Intl.NumberFormat(locale, { maximumFractionDigits: 3 });
    numberFormatters.set(locale, fmt);
  }
  // La división es solo para mostrar: la cantidad guardada es entera (gramos, mililitros o piezas).
  return fmt.format(value);
}

/**
 * Una cantidad de la lista: gramos y mililitros desde 1000 pasan a kg y l (1250 g → «1,25 kg» en it y es,
 * «1.25 kg» en en); las piezas, con su palabra en el idioma de la página («3 pezzi», «1 unidad»).
 */
export function formatQuantity(quantity: number, unit: ShoppingUnit, i18n: I18n): string {
  switch (unit) {
    case "g":
      return quantity >= 1000 ? `${formatNumber(quantity / 1000, i18n.locale)}${NBSP}kg` : `${quantity}${NBSP}g`;
    case "ml":
      return quantity >= 1000 ? `${formatNumber(quantity / 1000, i18n.locale)}${NBSP}l` : `${quantity}${NBSP}ml`;
    case "pcs":
      return quantity === 1
        ? i18n.t("reservation.units.pcsOne")
        : i18n.t("reservation.units.pcsOther", { n: formatNumber(quantity, i18n.locale) });
  }
}

export interface ShoppingGroup {
  section: ShoppingSection;
  items: ShoppingItem[];
}

/**
 * La lista para la clienta: lo que hay que comprar, agrupado por sección del súper (en el orden de las secciones
 * y, dentro de cada una, en el que la dejó Evelyn), y aparte lo que es «q.b.» (sin cantidad): para tener en casa.
 */
export function shoppingList(items: readonly ShoppingItem[]): { toBuy: ShoppingGroup[]; atHome: ShoppingItem[] } {
  const toBuy = SHOPPING_SECTIONS.map((section) => ({
    section,
    items: items.filter((item) => item.section === section && item.quantity !== null),
  })).filter((group) => group.items.length > 0);
  return { toBuy, atHome: items.filter((item) => item.quantity === null) };
}

/** Un instante (timestamptz) como día de Roma: «2 marzo 2027», «2 de marzo de 2027», «2 March 2027». */
export function formatRomeDay(timestamp: string, locale: string): string {
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return timestamp;
  return new Intl.DateTimeFormat(locale, { day: "numeric", month: "long", year: "numeric", timeZone: BUSINESS_TIME_ZONE }).format(date);
}
