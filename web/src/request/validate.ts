// Validación del formulario de pedido. Pura: devuelve claves de i18n, no textos.
import { LIMITS, validateInput } from "../engine.ts";
import type { MessageKey, Params } from "../i18n/core.ts";
import { addDays, isIsoDate } from "../lib/dates.ts";
import { DATE_WINDOW, MEAL_OPTIONS, TEXT_LIMITS, hasRestrictions, isOneOf, type RequestData } from "./model.ts";
import { toQuoteInput } from "./quote.ts";

/** Campos en el orden en que aparecen en la página (para llevar el foco al primer error). */
export const FIELD_ORDER = [
  "adults",
  "kids",
  "people",
  "days",
  "meals",
  "restrictionsNote",
  "healthConsent",
  "date",
  "name",
  "zone",
  "phone",
  "email",
  "notes",
  "privacyConsent",
] as const;
export type FieldName = (typeof FIELD_ORDER)[number];

export interface FieldError {
  key: MessageKey;
  params?: Params;
}
export type FieldErrors = Partial<Record<FieldName, FieldError>>;

/** Acepta cifras con espacios, guiones, puntos o paréntesis, y "+" o "00" inicial. */
export function isValidPhone(raw: string): boolean {
  const compact = raw.trim().replace(/[\s().\/-]/g, "");
  return /^(\+|00)?[0-9]{6,15}$/.test(compact);
}

export function isValidEmail(raw: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(raw.trim());
}

/**
 * @param today fecha de hoy en Europe/Rome ("AAAA-MM-DD"); la fecha preferida va de mañana a +14 días.
 */
export function validateRequest(data: RequestData, today: string): FieldErrors {
  const errors: FieldErrors = {};

  const intInRange = (field: FieldName, value: number, min: number, max: number): void => {
    if (!Number.isInteger(value) || value < min || value > max) {
      errors[field] = { key: "errors.range", params: { min, max } };
    }
  };
  const maxLength = (field: FieldName, value: string, max: number): void => {
    if (value.length > max) errors[field] = { key: "errors.tooLong", params: { max } };
  };

  intInRange("adults", data.adults, 0, LIMITS.maxPeople);
  intInRange("kids", data.kids, 0, LIMITS.maxPeople);
  intInRange("days", data.days, 1, LIMITS.maxDays);
  if (!isOneOf(MEAL_OPTIONS, data.meals)) errors.meals = { key: "errors.meals" };

  if (!errors.adults && !errors.kids && !errors.days && !errors.meals) {
    // El motor tiene la última palabra sobre la entrada (ej. al menos una persona).
    try {
      validateInput(toQuoteInput(data));
    } catch {
      errors.people = { key: "errors.people" };
    }
  }

  maxLength("restrictionsNote", data.restrictionsNote.trim(), TEXT_LIMITS.restrictionsNote);
  if (hasRestrictions(data) && !data.healthConsent) {
    errors.healthConsent = { key: "errors.healthRequired" };
  }

  if (data.date !== "") {
    const min = addDays(today, DATE_WINDOW.minDaysAhead);
    const max = addDays(today, DATE_WINDOW.maxDaysAhead);
    if (!isIsoDate(data.date) || data.date < min || data.date > max) {
      errors.date = { key: "errors.date", params: { days: DATE_WINDOW.maxDaysAhead } };
    }
  }

  const name = data.name.trim();
  if (name === "") errors.name = { key: "errors.nameRequired" };
  else maxLength("name", name, TEXT_LIMITS.name);

  const zone = data.zone.trim();
  if (zone === "") errors.zone = { key: "errors.zoneRequired" };
  else maxLength("zone", zone, TEXT_LIMITS.zone);

  const phone = data.phone.trim();
  if (phone === "") errors.phone = { key: "errors.phoneRequired" };
  else if (phone.length > TEXT_LIMITS.phone || !isValidPhone(phone)) errors.phone = { key: "errors.phoneInvalid" };

  const email = data.email.trim();
  if (email !== "") {
    if (!isValidEmail(email)) errors.email = { key: "errors.emailInvalid" };
    else maxLength("email", email, TEXT_LIMITS.email);
  }

  maxLength("notes", data.notes.trim(), TEXT_LIMITS.notes);

  if (!data.privacyConsent) errors.privacyConsent = { key: "errors.privacyRequired" };

  return errors;
}

export function firstErrorField(errors: FieldErrors): FieldName | undefined {
  return FIELD_ORDER.find((field) => errors[field] !== undefined);
}
