// Traductor de la web con los valores globales que pueden aparecer en cualquier texto:
// {brand}, {version}, límites del motor y del formulario, y el ejemplo de precios de la landing
// ({exService}, {exGroceries}, {exTotal}). Así los textos no repiten números del motor.
// El tiempo de cocina no se muestra: lo usa el motor para el precio y los horarios, no el cliente.
import { LIMITS } from "../engine.ts";
import { formatCents } from "../lib/format.ts";
import { CONSENT_VERSION, DATE_WINDOW } from "../request/model.ts";
import { exampleQuote } from "../request/quote.ts";
import { createI18n, type Dict, type I18n, type Lang } from "./core.ts";

export function createSiteI18n(lang: Lang, dict: Dict, brand: string): I18n {
  const globals = {
    brand,
    version: CONSENT_VERSION,
    maxDays: LIMITS.maxDays,
    minRecipes: LIMITS.minRecipes,
    maxRecipes: LIMITS.maxRecipes,
    horizonDays: DATE_WINDOW.maxDaysAhead,
  };
  const base = createI18n(lang, dict, globals);
  const example = exampleQuote();
  return createI18n(lang, dict, {
    ...globals,
    exService: formatCents(example.serviceCents, base.locale),
    exGroceries: formatCents(example.groceriesEstCents, base.locale),
    exTotal: formatCents(example.totalCents, base.locale),
  });
}
