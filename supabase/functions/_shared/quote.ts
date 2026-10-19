// Motor de presupuesto (SPEC.md §5.1). Fuente única de verdad.
// Lo usan las Edge Functions (Deno), la web (Vite) y los tests (Node).
// La app Flutter tiene una copia en Dart que pasa los mismos vectores.
// Solo aritmética entera: ningún paso usa decimales.

export interface PricingSettings {
  hourlyRateCents: number;
  travelFeeCents: number;
  adultPortionCents: number;
  kidPortionCents: number;
  preauthBufferPct: number;
  minCookMinutes: number;
}

export interface QuoteInput {
  adults: number;
  kids: number;
  days: number;
  /** Comidas por día: 1 (almuerzo o cena) o 2 (almuerzo y cena). */
  meals: number;
}

export interface Quote {
  adultPortions: number;
  kidPortions: number;
  portions: number;
  recipes: number;
  cookMinutes: number;
  serviceCents: number;
  groceriesEstCents: number;
  preauthCents: number;
  /** Máximo retenido en la tarjeta con pre-autorización única (§5.4): servicio + preauthCents. */
  holdCents: number;
  totalCents: number;
}

export const DEFAULT_PRICING: PricingSettings = {
  hourlyRateCents: 2200,
  travelFeeCents: 1200,
  adultPortionCents: 380,
  kidPortionCents: 250,
  preauthBufferPct: 15,
  minCookMinutes: 90,
};

export const LIMITS = {
  maxPeople: 30,
  maxDays: 7,
  maxMeals: 2,
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
  assertInt("adults", input.adults, 0, LIMITS.maxPeople);
  assertInt("kids", input.kids, 0, LIMITS.maxPeople);
  assertInt("days", input.days, 1, LIMITS.maxDays);
  assertInt("meals", input.meals, 1, LIMITS.maxMeals);
  if (input.adults + input.kids < 1) {
    throw new RangeError("Tiene que haber al menos una persona");
  }
}

function validateSettings(s: PricingSettings): void {
  assertInt("hourlyRateCents", s.hourlyRateCents, 0, 1_000_000);
  assertInt("travelFeeCents", s.travelFeeCents, 0, 1_000_000);
  assertInt("adultPortionCents", s.adultPortionCents, 0, 100_000);
  assertInt("kidPortionCents", s.kidPortionCents, 0, 100_000);
  assertInt("preauthBufferPct", s.preauthBufferPct, 0, 100);
  assertInt("minCookMinutes", s.minCookMinutes, 0, 24 * 60);
}

export function calcQuote(input: QuoteInput, settings: PricingSettings = DEFAULT_PRICING): Quote {
  validateInput(input);
  validateSettings(settings);

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

  // Redondeo al centavo, mitad hacia arriba.
  const serviceCents = Math.floor((cookMinutes * settings.hourlyRateCents + 30) / 60) + settings.travelFeeCents;
  const groceriesEstCents = adultPortions * settings.adultPortionCents + kidPortions * settings.kidPortionCents;
  const preauthCents = divUp(groceriesEstCents * (100 + settings.preauthBufferPct), 100);

  return {
    adultPortions,
    kidPortions,
    portions,
    recipes,
    cookMinutes,
    serviceCents,
    groceriesEstCents,
    preauthCents,
    holdCents: serviceCents + preauthCents,
    totalCents: serviceCents + groceriesEstCents,
  };
}
