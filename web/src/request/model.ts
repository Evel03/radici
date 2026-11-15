// Modelo del pedido de la web. Tipos, constantes y reglas vienen del contrato compartido con la
// Edge Function (supabase/functions/_shared/public_request.ts): un solo origen, nada copiado acá.
// Este archivo agrega solo lo propio del formulario (la opción "pranzo e cena" y su estado).
// Alergias: el cliente confirma que nadie de quienes van a comer tiene, o las escribe (con el
// consentimiento de salud). Los alérgenos y las dietas del contrato van vacíos.
import { MEALS, cleanMultiLine, type Meal, type RequestType, type Slot } from "../../../supabase/functions/_shared/public_request.ts";

export {
  CONSENT_VERSION,
  DATE_WINDOW,
  LOCALES,
  MAX_PAYLOAD_BYTES,
  MEALS,
  PUBLIC_REQUEST_VERSION,
  REQUEST_TYPES,
  SLOTS,
  TEXT_LIMITS,
  cleanMultiLine,
  cleanOneLine,
  isOneOf,
  isValidEmail,
  normalizePhone,
  parsePublicRequest,
} from "../../../supabase/functions/_shared/public_request.ts";
export type {
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
  /** Marcó que nadie de quienes van a comer (niños incluidos) tiene alergias ni intolerancias. */
  noAllergies: boolean;
  /** Las alergias e intolerancias escritas. Con `noAllergies` no se manda (aunque quede algo escrito). */
  restrictionsNote: string;
  /** Consentimiento explícito para esas alergias (dato de salud). Se manda solo con alergias escritas. */
  consentHealth: boolean;
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
}

export function mealsOf(option: MealOption): Meal[] {
  return option === "both" ? [...MEALS] : [option];
}

export function mealsPerDay(option: MealOption): number {
  return mealsOf(option).length;
}

/**
 * Hay alergias escritas que mandar (datos de salud: hace falta el consentimiento explícito). Con la
 * casilla de "nadie tiene" marcada, no. La nota se limpia igual que en el servidor: solo espacios no cuenta.
 */
export function hasHealthData(data: Pick<RequestData, "noAllergies" | "restrictionsNote">): boolean {
  return !data.noAllergies && cleanMultiLine(data.restrictionsNote) !== "";
}
