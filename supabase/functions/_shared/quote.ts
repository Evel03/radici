// Motor de presupuesto (SPEC.md §5.1). Fuente única de verdad.
// Lo usan las Edge Functions (Deno), la web (Vite) y los tests (Node).
// La app Flutter tiene una copia en Dart que pasa los mismos vectores.
// Solo aritmética entera: ningún paso usa decimales.
//
// Precio por semana (decisiones del dueño del 15 y 16/11/2026): el pedido semanal es de 1 a 8 semanas,
// con un menú y una sesión de cocina por semana. El servicio cuesta lo mismo cada semana para un hogar
// de hasta weeklyRateMaxPeople personas (adultos y niños), sin importar los días ni las comidas, e
// incluye el traslado; desde weeklyDiscountMinWeeks semanas, cada semana cuesta la tarifa con
// descuento. Con más personas, o en una sesión extra suelta, no hay precio automático: la cocinera
// pasa el presupuesto. La compra la hace el cliente (decisión del 19/11/2026), así que el motor no
// la estima. El tiempo de cocina se estima como siempre: de él dependen los días libres del
// calendario (get_free_days) y el tope de cocina del horario.
//
// Referencia interna (decisión del 22/11/2026): la fórmula ya no fija el precio que ve el cliente. Evelyn
// escribe a mano el precio de cada presupuesto; esta tarifa es solo su referencia, y el servidor la sigue
// calculando y guardando en requests.estimate. La web pública no la importa (usa cook_load.ts).

import { assertInt, calcCookLoad, DEFAULT_MIN_COOK_MINUTES, LIMITS, validateInput, type QuoteInput } from "./cook_load.ts";

// Lo que no es dinero (límites, entrada, carga de cocina) vive en cook_load.ts, que no lleva tarifas.
export { LIMITS, validateInput } from "./cook_load.ts";
export type { QuoteInput, QuoteType } from "./cook_load.ts";

export interface PricingSettings {
  /** Servicio de una semana (un menú y una sesión de cocina), traslado incluido. */
  weeklyRateCents: number;
  /** Servicio de cada semana desde weeklyDiscountMinWeeks semanas. Nunca más que weeklyRateCents. */
  weeklyRateDiscountedCents: number;
  /** Desde cuántas semanas vale weeklyRateDiscountedCents (de 1 a LIMITS.maxWeeks). */
  weeklyDiscountMinWeeks: number;
  /** Hasta cuántas personas (adultos y niños) tiene precio automático un pedido semanal. */
  weeklyRateMaxPeople: number;
  minCookMinutes: number;
}

/** Lo que vale para cualquier pedido: lo de una semana (una sesión) y las semanas del pedido. */
interface QuoteBase {
  weeks: number;
  adultPortions: number;
  kidPortions: number;
  portions: number;
  recipes: number;
  /** Minutos de cocina de cada sesión (los que pide el calendario). */
  cookMinutes: number;
}

export interface PricedQuote extends QuoteBase {
  autoPrice: true;
  /** Servicio de cada semana: la tarifa, o la de descuento desde weeklyDiscountMinWeeks semanas. */
  weeklyServiceCents: number;
  /** Servicio de todas las semanas. */
  serviceCents: number;
  /** Lo que se ahorra frente a la tarifa sin descuento (0 si no hay descuento). */
  savingsCents: number;
}

/** Por qué no hay precio automático: más personas que weeklyRateMaxPeople, o una sesión extra. */
export const NO_AUTO_PRICE_REASONS = ["people", "extra"] as const;
export type NoAutoPriceReason = (typeof NO_AUTO_PRICE_REASONS)[number];

export interface UnpricedQuote extends QuoteBase {
  autoPrice: false;
  reason: NoAutoPriceReason;
}

/** Sin precio automático no hay claves de precio (ni null ni 0): así se guarda en requests.estimate. */
export type Quote = PricedQuote | UnpricedQuote;

/**
 * Los valores por defecto de chef_settings (quote.test.ts lo compara con las migraciones). El servidor
 * calcula con los de la cocinera; la web no los usa.
 */
export const DEFAULT_PRICING: PricingSettings = {
  weeklyRateCents: 15000,
  weeklyRateDiscountedCents: 14000,
  weeklyDiscountMinWeeks: 4,
  weeklyRateMaxPeople: 5,
  minCookMinutes: DEFAULT_MIN_COOK_MINUTES,
};

/** Los rangos incluyen los checks de chef_settings: una fila que la base guarda nunca hace fallar el cálculo. */
function validateSettings(s: PricingSettings): void {
  assertInt("weeklyRateCents", s.weeklyRateCents, 0, 1_000_000);
  assertInt("weeklyRateDiscountedCents", s.weeklyRateDiscountedCents, 0, s.weeklyRateCents);
  assertInt("weeklyDiscountMinWeeks", s.weeklyDiscountMinWeeks, 1, LIMITS.maxWeeks);
  assertInt("weeklyRateMaxPeople", s.weeklyRateMaxPeople, 1, 2 * LIMITS.maxPeople);
  assertInt("minCookMinutes", s.minCookMinutes, 0, 24 * 60);
}

export function calcQuote(input: QuoteInput, settings: PricingSettings = DEFAULT_PRICING): Quote {
  validateInput(input);
  validateSettings(settings);

  const { adultPortions, kidPortions, portions, recipes, cookMinutes } = calcCookLoad(input, settings.minCookMinutes);

  const base: QuoteBase = {
    weeks: input.weeks,
    adultPortions,
    kidPortions,
    portions,
    recipes,
    cookMinutes,
  };
  if (input.type === "extra") return { ...base, autoPrice: false, reason: "extra" };
  if (input.adults + input.kids > settings.weeklyRateMaxPeople) return { ...base, autoPrice: false, reason: "people" };

  const weeklyServiceCents =
    input.weeks >= settings.weeklyDiscountMinWeeks ? settings.weeklyRateDiscountedCents : settings.weeklyRateCents;
  const serviceCents = weeklyServiceCents * input.weeks;
  return {
    ...base,
    autoPrice: true,
    weeklyServiceCents,
    serviceCents,
    savingsCents: settings.weeklyRateCents * input.weeks - serviceCents,
  };
}
