// Calculadora de la web: delega todo el cálculo en el motor compartido (calcQuote).
import { calcQuote, DEFAULT_PRICING, type Quote, type QuoteInput } from "../engine.ts";
import { mealsPerDay, type RequestData } from "./model.ts";

export function toQuoteInput(data: Pick<RequestData, "adults" | "kids" | "days" | "meals">): QuoteInput {
  return { adults: data.adults, kids: data.kids, days: data.days, meals: mealsPerDay(data.meals) };
}

/** Presupuesto estimado, o null si la entrada no es válida para el motor (ej. 0 personas). */
export function computeQuote(data: Pick<RequestData, "adults" | "kids" | "days" | "meals">): Quote | null {
  try {
    return calcQuote(toQuoteInput(data), DEFAULT_PRICING);
  } catch (error) {
    if (error instanceof RangeError) return null;
    throw error;
  }
}

/** Ejemplo de la landing: vector 1 de SPEC.md §5.1 (2 adultos, 2 niños, 5 días, cena). */
export const EXAMPLE_INPUT = { adults: 2, kids: 2, days: 5, meals: "dinner" } as const;

export function exampleQuote(): Quote {
  return calcQuote(toQuoteInput(EXAMPLE_INPUT), DEFAULT_PRICING);
}
