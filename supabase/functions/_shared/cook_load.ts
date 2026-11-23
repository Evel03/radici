// Lo del pedido que no es dinero: los límites, la entrada y la carga de cocina (porciones, recetas y minutos de
// cada sesión). De los minutos dependen los días libres del calendario (get_free_days) y el tope de cocina del
// horario. Sin ninguna tarifa: la web pública importa solo este archivo (decisión del 22/11/2026: la web no
// muestra ni lleva precios). El motor de presupuesto (quote.ts) lo usa y lo reexporta.
// Solo aritmética entera: ningún paso usa decimales.

/** "week": semana de comidas (1 a 8 semanas, precio por semana); "extra": sesión extra suelta (sin precio automático). */
export type QuoteType = "week" | "extra";

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

export function assertInt(name: string, value: number, min: number, max: number): void {
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

export interface CookLoad {
  adultPortions: number;
  kidPortions: number;
  portions: number;
  recipes: number;
  /** Minutos de cocina de cada sesión (los que pide el calendario). */
  cookMinutes: number;
}

/** Mínimo de minutos de cocina de una sesión: el valor por defecto de chef_settings. */
export const DEFAULT_MIN_COOK_MINUTES = 90;

/** La carga de una semana (una sesión): porciones, recetas y minutos de cocina. */
export function calcCookLoad(input: QuoteInput, minCookMinutes: number = DEFAULT_MIN_COOK_MINUTES): CookLoad {
  validateInput(input);
  assertInt("minCookMinutes", minCookMinutes, 0, 24 * 60);
  // Una semana: los días y las comidas de cada sesión.
  const adultPortions = input.adults * input.days * input.meals;
  const kidPortions = input.kids * input.days * input.meals;
  const portions = adultPortions + kidPortions;

  const recipes = Math.min(
    LIMITS.maxRecipes,
    Math.max(LIMITS.minRecipes, Math.min(divUp(input.days * input.meals, 2), Math.floor(portions / 2))),
  );

  // ceil_a_30(60 + 30·recetas + 1,2·porciones), multiplicado por 5 para quedar en enteros.
  const cookMinutes = Math.max(minCookMinutes, divUp(300 + 150 * recipes + 6 * portions, 150) * 30);
  return { adultPortions, kidPortions, portions, recipes, cookMinutes };
}
