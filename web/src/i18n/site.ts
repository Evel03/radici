// Traductor de la web con los valores globales que pueden aparecer en cualquier texto:
// {brand}, {version}, límites del motor y del formulario, y el ejemplo de precios de la landing
// ({exService}, {exGroceries}, {exTotal}). Así los textos no repiten números del motor.
// La ventana de la fecha preferida va en semanas ({horizonWeeks}): «hasta dentro de 56 días» se lee mal.
// El tiempo de cocina no se muestra: lo usa el motor para el precio y los horarios, no el cliente.
import { LIMITS } from "../engine.ts";
import { formatCents } from "../lib/format.ts";
import { CONSENT_VERSION, DATE_WINDOW, TEXT_LIMITS } from "../request/model.ts";
import { exampleQuote } from "../request/quote.ts";
import { createI18n, type Dict, type I18n, type Lang } from "./core.ts";

export function createSiteI18n(lang: Lang, dict: Dict, brand: string): I18n {
  const globals = {
    brand,
    version: CONSENT_VERSION,
    maxDays: LIMITS.maxDays,
    minRecipes: LIMITS.minRecipes,
    maxRecipes: LIMITS.maxRecipes,
    // Semanas enteras: maxDaysAhead es múltiplo de 7 (lo exige i18n.test.ts).
    horizonWeeks: DATE_WINDOW.maxDaysAhead / 7,
    noteMax: TEXT_LIMITS.restrictionsNote,
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
