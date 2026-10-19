// Datos de prueba compartidos por los tests del pedido.
import { flatten, type Lang } from "../i18n/core.ts";
import en from "../i18n/en.json";
import es from "../i18n/es.json";
import it from "../i18n/it.json";
import { createSiteI18n } from "../i18n/site.ts";
import type { RequestData } from "./model.ts";

const dicts = { it: flatten(it), es: flatten(es), en: flatten(en) };

export function i18nFor(lang: Lang) {
  return createSiteI18n(lang, dicts[lang], "Mestolo");
}

/** Pedido válido: vector 1 de SPEC.md §5.1 (2 adultos, 2 niños, 5 días, cena). */
export function validRequest(overrides: Partial<RequestData> = {}): RequestData {
  return {
    type: "week",
    adults: 2,
    kids: 2,
    days: 5,
    meals: "dinner",
    allergens: [],
    diets: [],
    restrictionsNote: "",
    date: "",
    slot: "any",
    name: "Giulia Rossi",
    zone: "Città Alta",
    phone: "+39 333 123 4567",
    email: "",
    notes: "",
    privacyConsent: true,
    healthConsent: false,
    ...overrides,
  };
}
