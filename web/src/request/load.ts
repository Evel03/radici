// Carga de cocina del pedido: porciones, recetas y minutos de cada sesión. Delega en calcCookLoad del motor
// compartido, que no lleva tarifas: la web no calcula ni muestra precios (decisión del 22/11/2026; el
// presupuesto lo prepara Evelyn a mano). De los minutos dependen los días libres del calendario.
import { calcCookLoad, type CookLoad, type QuoteInput } from "../engine.ts";
import { mealsPerDay, weeksOf, type RequestData } from "./model.ts";

type LoadData = Pick<RequestData, "type" | "adults" | "kids" | "days" | "meals" | "weeks">;

export function toQuoteInput(data: LoadData): QuoteInput {
  return { type: data.type, adults: data.adults, kids: data.kids, days: data.days, meals: mealsPerDay(data.meals), weeks: weeksOf(data) };
}

/** La carga de una semana (una sesión), o null si la entrada no es válida para el motor (ej. 0 personas). */
export function computeLoad(data: LoadData): CookLoad | null {
  try {
    return calcCookLoad(toQuoteInput(data));
  } catch (error) {
    if (error instanceof RangeError) return null;
    throw error;
  }
}
