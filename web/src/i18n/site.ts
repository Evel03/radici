// Traductor de la web con los valores globales que pueden aparecer en cualquier texto:
// {brand}, {version}, límites del motor y del formulario, el precio por semana y el ejemplo de precios de
// la portada. Así los textos no repiten números: salen del motor (DEFAULT_PRICING, LIMITS) y del contrato.
// - Precio por semana: {weeklyRate}, {discountRate}, {discountWeeks}, {maxPeople}, {maxWeeks}.
// - Ejemplo de la portada (EXAMPLE_INPUT): {exAdults}, {exKids}, {exDays}, {exWeeks}, {exPortions},
//   {exWeekly}, {exService}, {exSavings}. Sin la compra: la hace el cliente con la lista de Evelyn.
// La ventana de la fecha preferida va en semanas ({horizonWeeks}): «hasta dentro de 56 días» se lee mal.
// El tiempo de cocina no se muestra: lo usa el motor para los horarios, no el cliente.
import { DEFAULT_PRICING, LIMITS } from "../engine.ts";
import { formatCents } from "../lib/format.ts";
import { CONSENT_VERSION, DATE_WINDOW, TEXT_LIMITS } from "../request/model.ts";
import { EXAMPLE_INPUT, exampleQuote } from "../request/quote.ts";
import { createI18n, type Dict, type I18n, type Lang } from "./core.ts";

export function createSiteI18n(lang: Lang, dict: Dict, brand: string): I18n {
  const globals = {
    brand,
    version: CONSENT_VERSION,
    maxDays: LIMITS.maxDays,
    maxWeeks: LIMITS.maxWeeks,
    minRecipes: LIMITS.minRecipes,
    maxRecipes: LIMITS.maxRecipes,
    // Semanas enteras: maxDaysAhead es múltiplo de 7 (lo exige i18n.test.ts).
    horizonWeeks: DATE_WINDOW.maxDaysAhead / 7,
    noteMax: TEXT_LIMITS.restrictionsNote,
    discountWeeks: DEFAULT_PRICING.weeklyDiscountMinWeeks,
    maxPeople: DEFAULT_PRICING.weeklyRateMaxPeople,
    exAdults: EXAMPLE_INPUT.adults,
    exKids: EXAMPLE_INPUT.kids,
    exDays: EXAMPLE_INPUT.days,
    exWeeks: EXAMPLE_INPUT.weeks,
  };
  const { locale } = createI18n(lang, dict, globals);
  const money = (cents: number): string => formatCents(cents, locale);
  const example = exampleQuote();
  return createI18n(lang, dict, {
    ...globals,
    weeklyRate: money(DEFAULT_PRICING.weeklyRateCents),
    discountRate: money(DEFAULT_PRICING.weeklyRateDiscountedCents),
    exPortions: example.portions,
    exWeekly: money(example.weeklyServiceCents),
    exService: money(example.serviceCents),
    exSavings: money(example.savingsCents),
  });
}
