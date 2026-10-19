// Modelo del pedido de la web. Tipos, constantes y reglas vienen del contrato compartido con la
// Edge Function (supabase/functions/_shared/public_request.ts): un solo origen, nada copiado acá.
// Este archivo agrega solo lo propio del formulario (la opción "pranzo e cena" y su estado).
import {
  MEALS,
  cleanOneLine,
  hasRestrictions,
  type Allergen,
  type Diet,
  type Meal,
  type RequestType,
  type Slot,
} from "../../../supabase/functions/_shared/public_request.ts";

export {
  ALLERGENS,
  CONSENT_VERSION,
  DATE_WINDOW,
  DIETS,
  LOCALES,
  MAX_PAYLOAD_BYTES,
  MEALS,
  PUBLIC_REQUEST_VERSION,
  REQUEST_TYPES,
  SLOTS,
  TEXT_LIMITS,
  cleanMultiLine,
  cleanOneLine,
  hasRestrictions,
  isOneOf,
  isValidEmail,
  normalizePhone,
  parsePublicRequest,
} from "../../../supabase/functions/_shared/public_request.ts";
export type {
  Allergen,
  Diet,
  ErrorCode,
  Locale,
  Meal,
  PublicRequestErrors,
  PublicRequestField,
  PublicRequestPayload,
  RequestType,
  Slot,
} from "../../../supabase/functions/_shared/public_request.ts";

/** El formulario ofrece almuerzo, cena o los dos; el contrato recibe la lista de comidas. */
export const MEAL_OPTIONS = ["lunch", "dinner", "both"] as const;
export type MealOption = (typeof MEAL_OPTIONS)[number];

/** Estado del formulario tal como lo escribió el cliente (el servidor limpia y valida). */
export interface RequestData {
  type: RequestType;
  /** NaN si el campo quedó vacío. */
  adults: number;
  kids: number;
  days: number;
  meals: MealOption;
  allergens: Allergen[];
  diets: Diet[];
  restrictionsNote: string;
  /** "" si no eligió fecha; si no, "AAAA-MM-DD". */
  preferredDate: string;
  slot: Slot;
  name: string;
  zone: string;
  phone: string;
  email: string;
  /** Quiere la confirmación también por WhatsApp (al teléfono indicado). */
  whatsappOptIn: boolean;
  notes: string;
  consentPrivacy: boolean;
  consentHealth: boolean;
}

export function mealsOf(option: MealOption): Meal[] {
  return option === "both" ? [...MEALS] : [option];
}

export function mealsPerDay(option: MealOption): number {
  return mealsOf(option).length;
}

/**
 * Hay datos de salud (alérgenos, dietas o una nota) y hace falta el consentimiento explícito.
 * La nota se limpia igual que en el servidor: un texto con solo espacios no cuenta.
 */
export function hasHealthData(data: Pick<RequestData, "allergens" | "diets" | "restrictionsNote">): boolean {
  return hasRestrictions({ ...data, restrictionsNote: cleanOneLine(data.restrictionsNote) });
}
