// Validación del formulario: es la misma del servidor (parsePublicRequest del contrato compartido),
// aplicada al payload que se va a mandar. Acá solo se traducen sus códigos a claves de i18n,
// y la misma traducción sirve para los errores que devuelve la Edge Function (400).
import { LIMITS } from "../engine.ts";
import type { MessageKey, Params } from "../i18n/core.ts";
import {
  TEXT_LIMITS,
  isOneOf,
  parsePublicRequest,
  type ErrorCode,
  type PublicRequestErrors,
  type PublicRequestField,
  type PublicRequestPayload,
  type RequestData,
} from "./model.ts";
import { buildPayload, type PayloadOptions } from "./payload.ts";

/** Campos con mensaje propio (err-<campo>) en el formulario, en el orden de la página. */
export const FIELD_ORDER = [
  "type",
  "adults",
  "kids",
  "people",
  "days",
  "meals",
  "preferredDate",
  "noAllergies",
  "restrictionsNote",
  "consentHealth",
  "name",
  "zone",
  "phone",
  "whatsappOptIn",
  "email",
  "notes",
  "consentPrivacy",
  "turnstileToken",
] as const satisfies readonly PublicRequestField[];
export type FieldName = (typeof FIELD_ORDER)[number];

/**
 * Errores que no son de un campo: la página quedó desactualizada respecto del servidor.
 * Si el contrato suma un campo y el formulario no lo muestra, esto deja de compilar.
 * Los alérgenos y las dietas también: las alergias llegan escritas (restrictionsNote) y esos dos van
 * vacíos, así que un error ahí solo puede venir de otra versión del servidor. Lo mismo la franja
 * horaria: el formulario no la pregunta y manda siempre "any".
 */
export const PAGE_FIELDS = {
  payload: true,
  version: true,
  locale: true,
  requestKey: true,
  slot: true,
  allergens: true,
  diets: true,
} as const satisfies Record<Exclude<PublicRequestField, FieldName>, true>;

const ERROR_CODES: readonly ErrorCode[] = [
  "required",
  "invalid",
  "range",
  "tooLong",
  "dateOutOfRange",
  "consentRequired",
  "healthConsentRequired",
];

export interface FieldError {
  key: MessageKey;
  params?: Params;
}
export type FieldErrors = Partial<Record<FieldName, FieldError>>;

const REQUIRED_KEYS: Partial<Record<FieldName, MessageKey>> = {
  restrictionsNote: "errors.restrictionsRequired",
  name: "errors.nameRequired",
  zone: "errors.zoneRequired",
  phone: "errors.phoneRequired",
  email: "errors.emailRequired",
};

const INVALID_KEYS: Partial<Record<FieldName, MessageKey>> = {
  phone: "errors.phoneInvalid",
  email: "errors.emailInvalid",
};

/** Mensaje para un campo y un código de error del contrato. */
export function fieldError(field: FieldName, code: ErrorCode): FieldError {
  switch (field) {
    case "adults":
    case "kids":
      return { key: "errors.range", params: { min: 0, max: LIMITS.maxPeople } };
    case "days":
      return { key: "errors.range", params: { min: 1, max: LIMITS.maxDays } };
    case "people":
      return { key: "errors.people" };
    case "meals":
      return { key: "errors.meals" };
    case "preferredDate":
      // La ventana va en el texto con {horizonWeeks}, un valor global de la web (i18n/site.ts). Es el mismo
      // mensaje si la fecha la rechaza el servidor: por ejemplo, la función de antes durante un despliegue.
      return { key: "errors.date" };
    case "consentPrivacy":
      return { key: "errors.privacyRequired" };
    case "consentHealth":
      return { key: "errors.healthRequired" };
    case "turnstileToken":
      return { key: "errors.turnstileRequired" };
    case "restrictionsNote":
    case "name":
    case "zone":
    case "phone":
    case "email":
    case "notes":
      if (code === "tooLong") return { key: "errors.tooLong", params: { max: TEXT_LIMITS[field] } };
      if (code === "required") return { key: REQUIRED_KEYS[field] ?? "errors.invalid" };
      return { key: INVALID_KEYS[field] ?? "errors.invalid" };
    case "type":
    case "whatsappOptIn":
    case "noAllergies":
      // El formulario no puede producir estos errores: solo con un HTML viejo o alterado (la casilla de
      // "nadie tiene alergias" siempre es true o false, y marcada no se manda la nota).
      return { key: "errors.invalid" };
  }
}

/** Los consentimientos que mandó la página (los de buildPayload). */
export type SentConsents = PublicRequestPayload["consents"];

/**
 * El servidor rechazó la versión de un consentimiento que la página sí mandó (la casilla estaba
 * marcada): la página es de otro texto (abierta antes de un cambio, o durante un despliegue). Marcar
 * la casilla otra vez no lo arregla; hay que recargar.
 */
function rejectedConsentVersion(field: string, sent: SentConsents | undefined): boolean {
  if (!sent) return false;
  if (field === "consentPrivacy") return sent.privacy !== "";
  if (field === "consentHealth") return sent.health !== null;
  return false;
}

/**
 * Traduce los errores del contrato (del servidor o de la validación local).
 * `outdated`: el servidor rechazó algo que la página no controla (versión, formato, la versión de un
 * consentimiento que mandó): hay que recargar.
 * @param sent los consentimientos que se mandaron: con ellos, un consentimiento rechazado que sí iba
 * marcado es de otra versión del texto, no un error del campo.
 */
export function translateErrors(errors: PublicRequestErrors, sent?: SentConsents): { fields: FieldErrors; outdated: boolean } {
  // Con la versión rechazada, el servidor validó con otro contrato y sus errores de campo no valen para
  // esta página (por ejemplo, una versión de la privacy que no conoce): solo hay que recargar.
  if (errors.version !== undefined) return { fields: {}, outdated: true };
  const fields: FieldErrors = {};
  let outdated = false;
  for (const [field, code] of Object.entries(errors)) {
    if (rejectedConsentVersion(field, sent)) {
      outdated = true;
    } else if (isOneOf(FIELD_ORDER, field)) {
      // Un código desconocido (otra versión del servidor) se trata como "invalid".
      fields[field] = fieldError(field, isOneOf(ERROR_CODES, code) ? code : "invalid");
    } else {
      // PAGE_FIELDS o un campo que esta página no conoce: hay que recargarla.
      outdated = true;
    }
  }
  return { fields, outdated };
}

/**
 * Valida el formulario con la misma función del servidor.
 * @param today fecha de hoy en Europe/Rome ("AAAA-MM-DD").
 */
export function validateRequest(data: RequestData, today: string, opts: PayloadOptions): FieldErrors {
  const result = parsePublicRequest(buildPayload(data, opts), { today });
  return result.ok ? {} : translateErrors(result.errors).fields;
}

export function firstErrorField(errors: FieldErrors): FieldName | undefined {
  return FIELD_ORDER.find((field) => errors[field] !== undefined);
}
