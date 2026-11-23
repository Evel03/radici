// Traductor de la web con los valores globales que pueden aparecer en cualquier texto:
// {brand}, {version} y los límites del motor y del formulario. Así los textos no repiten números: salen del motor
// (LIMITS) y del contrato. Ningún importe: la web pública no muestra precios (decisión del 22/11/2026), el
// presupuesto lo prepara Evelyn a mano; i18n.test.ts exige que ningún texto lleve «€» ni una tarifa.
// La ventana de la fecha preferida va en semanas ({horizonWeeks}): «hasta dentro de 56 días» se lee mal.
// El tiempo de cocina no se muestra: lo usa el motor para los horarios, no el cliente.
import { LIMITS } from "../engine.ts";
import { CONSENT_VERSION, DATE_WINDOW, TEXT_LIMITS } from "../request/model.ts";
import { createI18n, type Dict, type I18n, type Lang } from "./core.ts";

export function createSiteI18n(lang: Lang, dict: Dict, brand: string): I18n {
  return createI18n(lang, dict, {
    brand,
    version: CONSENT_VERSION,
    maxDays: LIMITS.maxDays,
    maxWeeks: LIMITS.maxWeeks,
    minRecipes: LIMITS.minRecipes,
    maxRecipes: LIMITS.maxRecipes,
    // Semanas enteras: maxDaysAhead es múltiplo de 7 (lo exige i18n.test.ts).
    horizonWeeks: DATE_WINDOW.maxDaysAhead / 7,
    noteMax: TEXT_LIMITS.restrictionsNote,
  });
}
