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
// pasa el presupuesto. La compra va aparte, al costo del ticket: el motor da una estimación por
// semana con las porciones. El tiempo de cocina se estima como siempre: de él dependen los días
// libres del calendario (get_free_days) y el tope de 300 min.

/** "week": semana de comidas (1 a 8 semanas, precio por semana); "extra": sesión extra suelta (sin precio automático). */
export type QuoteType = "week" | "extra";

export interface PricingSettings {
  /** Servicio de una semana (un menú y una sesión de cocina), traslado incluido. */
  weeklyRateCents: number;
  /** Servicio de cada semana desde weeklyDiscountMinWeeks semanas. Nunca más que weeklyRateCents. */
  weeklyRateDiscountedCents: number;
  /** Desde cuántas semanas vale weeklyRateDiscountedCents (de 1 a LIMITS.maxWeeks). */
  weeklyDiscountMinWeeks: number;
  /** Hasta cuántas personas (adultos y niños) tiene precio automático un pedido semanal. */
  weeklyRateMaxPeople: number;
  adultPortionCents: number;
  kidPortionCents: number;
  /** Margen de la pre-autorización de la compra (§5.4, M6). */
  preauthBufferPct: number;
  minCookMinutes: number;
}

export interface QuoteInput {
  type: QuoteType;
  adults: number;
  kids: number;
  /** Días de comidas de cada semana (1 a 7). */
  days: number;
  /** Comidas por día: 1 (almuerzo o cena) o 2 (almuerzo y cena). */
  meals: number;
  /** Semanas del pedido semanal (1 a 8). Una sesión extra siempre es de 1. */
  weeks: number;
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
  /** Compra estimada de una semana; se paga aparte, al costo del ticket. */
  groceriesEstCents: number;
  /** Pre-autorización de la compra de una semana (compra + margen, §5.4). */
  preauthCents: number;
}

export interface PricedQuote extends QuoteBase {
  autoPrice: true;
  /** Servicio de cada semana: la tarifa, o la de descuento desde weeklyDiscountMinWeeks semanas. */
  weeklyServiceCents: number;
  /** Servicio de todas las semanas. */
  serviceCents: number;
  /** Lo que se ahorra frente a la tarifa sin descuento (0 si no hay descuento). */
  savingsCents: number;
  /** Servicio y compra estimada de todas las semanas. */
  totalCents: number;
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
 * Los valores por defecto de chef_settings (quote.test.ts lo compara con las migraciones): la web
 * muestra el precio con estos y el servidor lo calcula con los de la cocinera.
 */
export const DEFAULT_PRICING: PricingSettings = {
  weeklyRateCents: 15000,
  weeklyRateDiscountedCents: 14000,
  weeklyDiscountMinWeeks: 4,
  weeklyRateMaxPeople: 5,
  adultPortionCents: 380,
  kidPortionCents: 250,
  preauthBufferPct: 15,
  minCookMinutes: 90,
};

export const LIMITS = {
  maxPeople: 30,
  maxDays: 7,
  maxMeals: 2,
  /** Lo mismo que el check requests_semanas_validas de la base. */
  maxWeeks: 8,
  minRecipes: 2,
  maxRecipes: 6,
} as const;

/** División entera hacia arriba para enteros no negativos. */
function divUp(a: number, b: number): number {
  return Math.floor((a + b - 1) / b);
}

function assertInt(name: string, value: number, min: number, max: number): void {
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new RangeError(`${name} debe ser un entero entre ${min} y ${max} (recibido: ${value})`);
  }
}

export function validateInput(input: QuoteInput): void {
  if (input.type !== "week" && input.type !== "extra") {
    throw new RangeError(`type debe ser week o extra (recibido: ${String(input.type)})`);
  }
  assertInt("adults", input.adults, 0, LIMITS.maxPeople);
  assertInt("kids", input.kids, 0, LIMITS.maxPeople);
  assertInt("days", input.days, 1, LIMITS.maxDays);
  assertInt("meals", input.meals, 1, LIMITS.maxMeals);
  assertInt("weeks", input.weeks, 1, input.type === "week" ? LIMITS.maxWeeks : 1);
  if (input.adults + input.kids < 1) {
    throw new RangeError("Tiene que haber al menos una persona");
  }
}

/** Los rangos incluyen los checks de chef_settings: una fila que la base guarda nunca hace fallar el cálculo. */
function validateSettings(s: PricingSettings): void {
  assertInt("weeklyRateCents", s.weeklyRateCents, 0, 1_000_000);
  assertInt("weeklyRateDiscountedCents", s.weeklyRateDiscountedCents, 0, s.weeklyRateCents);
  assertInt("weeklyDiscountMinWeeks", s.weeklyDiscountMinWeeks, 1, LIMITS.maxWeeks);
  assertInt("weeklyRateMaxPeople", s.weeklyRateMaxPeople, 1, 2 * LIMITS.maxPeople);
  assertInt("adultPortionCents", s.adultPortionCents, 0, 100_000);
  assertInt("kidPortionCents", s.kidPortionCents, 0, 100_000);
  assertInt("preauthBufferPct", s.preauthBufferPct, 0, 100);
  assertInt("minCookMinutes", s.minCookMinutes, 0, 24 * 60);
}

export function calcQuote(input: QuoteInput, settings: PricingSettings = DEFAULT_PRICING): Quote {
  validateInput(input);
  validateSettings(settings);

  // Una semana: los días y las comidas de cada sesión.
  const adultPortions = input.adults * input.days * input.meals;
  const kidPortions = input.kids * input.days * input.meals;
  const portions = adultPortions + kidPortions;

  const recipes = Math.min(
    LIMITS.maxRecipes,
    Math.max(LIMITS.minRecipes, Math.min(divUp(input.days * input.meals, 2), Math.floor(portions / 2))),
  );

  // ceil_a_30(60 + 30·recetas + 1,2·porciones), multiplicado por 5 para quedar en enteros.
  const cookMinutes = Math.max(
    settings.minCookMinutes,
    divUp(300 + 150 * recipes + 6 * portions, 150) * 30,
  );

  const groceriesEstCents = adultPortions * settings.adultPortionCents + kidPortions * settings.kidPortionCents;
  const preauthCents = divUp(groceriesEstCents * (100 + settings.preauthBufferPct), 100);

  const base: QuoteBase = {
    weeks: input.weeks,
    adultPortions,
    kidPortions,
    portions,
    recipes,
    cookMinutes,
    groceriesEstCents,
    preauthCents,
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
    totalCents: serviceCents + groceriesEstCents * input.weeks,
  };
}
