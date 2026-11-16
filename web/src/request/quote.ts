// Calculadora de la web: delega todo el cálculo en el motor compartido (calcQuote).
// Calcula con DEFAULT_PRICING, que es lo que guarda la base por defecto (quote.test.ts compara los dos);
// el servidor calcula con las tarifas de la cocinera y la pantalla de gracias muestra esa.
import { calcQuote, DEFAULT_PRICING, type PricedQuote, type Quote, type QuoteInput } from "../engine.ts";
import { mealsPerDay, weeksOf, type RequestData } from "./model.ts";

type QuoteData = Pick<RequestData, "type" | "adults" | "kids" | "days" | "meals" | "weeks">;

export function toQuoteInput(data: QuoteData): QuoteInput {
  return { type: data.type, adults: data.adults, kids: data.kids, days: data.days, meals: mealsPerDay(data.meals), weeks: weeksOf(data) };
}

/** Presupuesto estimado, o null si la entrada no es válida para el motor (ej. 0 personas). */
export function computeQuote(data: QuoteData): Quote | null {
  try {
    return calcQuote(toQuoteInput(data), DEFAULT_PRICING);
  } catch (error) {
    if (error instanceof RangeError) return null;
    throw error;
  }
}

/**
 * Ejemplo de la portada: el vector 3 de SPEC.md §5.1 (2 adultos, 2 niños, cena 5 días por semana, 4
 * semanas), que muestra la tarifa con descuento.
 */
export const EXAMPLE_INPUT = { type: "week", adults: 2, kids: 2, days: 5, meals: "dinner", weeks: 4 } as const;

export function exampleQuote(): PricedQuote {
  const quote = calcQuote(toQuoteInput(EXAMPLE_INPUT), DEFAULT_PRICING);
  if (!quote.autoPrice) throw new RangeError("El ejemplo de la portada tiene que tener precio automático");
  return quote;
}
