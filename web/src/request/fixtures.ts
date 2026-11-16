// Datos de prueba compartidos por los tests del pedido.
import { flatten, type Lang } from "../i18n/core.ts";
import en from "../i18n/en.json";
import es from "../i18n/es.json";
import it from "../i18n/it.json";
import { createSiteI18n } from "../i18n/site.ts";
import type { RequestData } from "./model.ts";

/** Hoy en Europe/Rome para los tests: la fecha preferida va del 20/10 al 14/12/2026 (8 semanas). */
export const TODAY = "2026-10-19";

/** Token que generan las sitekeys de prueba de Turnstile. */
export const TEST_TOKEN = "XXXX.DUMMY.TOKEN.XXXX";

const dicts = { it: flatten(it), es: flatten(es), en: flatten(en) };

export function i18nFor(lang: Lang) {
  return createSiteI18n(lang, dicts[lang], "Radici");
}

/** Pedido válido: vector 1 de SPEC.md §5.1 (2 adultos, 2 niños, 5 días, cena, 1 semana), sin alergias. */
export function validRequest(overrides: Partial<RequestData> = {}): RequestData {
  return {
    type: "week",
    adults: 2,
    kids: 2,
    days: 5,
    meals: "dinner",
    weeks: 1,
    preferredDate: "",
    name: "Giulia Rossi",
    zone: "Città Alta",
    phone: "+39 333 123 4567",
    email: "giulia@example.test",
    whatsappOptIn: false,
    notes: "",
    consentPrivacy: true,
    noAllergies: true,
    restrictionsNote: "",
    consentHealth: false,
    ...overrides,
  };
}
