// Arma el JSON que la web manda a la Edge Function `public-request` (docs/contracts/public-request.md).
// Pura. Los textos van limpios con las mismas funciones del servidor (que igual vuelve a limpiar):
// así el JSON no crece con caracteres de control escapados y lo que se valida acá es lo que se guarda.
import {
  CONSENT_VERSION,
  HEALTH_CONSENT_VERSION,
  PUBLIC_REQUEST_VERSION,
  cleanMultiLine,
  cleanOneLine,
  hasHealthData,
  mealsOf,
  weeksOf,
  type Locale,
  type PublicRequestPayload,
  type RequestData,
} from "./model.ts";

export interface PayloadOptions {
  /** Idioma de la página: el de los emails y el WhatsApp de confirmación. */
  locale: Locale;
  /** Token de Turnstile ("" si todavía no hay). */
  turnstileToken: string;
  /** Clave de idempotencia del pedido (request-key.ts). La validación local no la necesita. */
  requestKey?: string;
}

export function buildPayload(data: RequestData, opts: PayloadOptions): PublicRequestPayload {
  return {
    version: PUBLIC_REQUEST_VERSION,
    type: data.type,
    adults: data.adults,
    kids: data.kids,
    days: data.days,
    meals: mealsOf(data.meals),
    // Una sesión extra es de una semana: lo que haya quedado en el selector no se manda.
    weeks: weeksOf(data),
    noAllergies: data.noAllergies,
    // Las alergias llegan escritas: los alérgenos y las dietas del contrato van vacíos.
    allergens: [],
    diets: [],
    // Con "nadie tiene alergias" marcado no se manda lo que haya quedado escrito (el bloque se oculta).
    restrictionsNote: data.noAllergies ? "" : cleanMultiLine(data.restrictionsNote),
    preferredDate: data.preferredDate === "" ? null : data.preferredDate,
    // El formulario no pregunta la franja: la hora se acuerda con Evelyn.
    slot: "any",
    name: cleanOneLine(data.name),
    zone: cleanOneLine(data.zone),
    phone: cleanOneLine(data.phone),
    email: cleanOneLine(data.email),
    whatsappOptIn: data.whatsappOptIn,
    notes: cleanMultiLine(data.notes),
    locale: opts.locale,
    consents: {
      // "" = no aceptó: el servidor responde consentRequired.
      privacy: data.consentPrivacy ? CONSENT_VERSION : "",
      // Solo con alergias escritas: sin datos de salud no hay consentimiento de salud que guardar. Con la
      // versión del texto de salud, no la de la privacy (HEALTH_CONSENT_VERSION).
      health: hasHealthData(data) && data.consentHealth ? HEALTH_CONSENT_VERSION : null,
    },
    turnstileToken: opts.turnstileToken,
    // Los platos elegidos, en el orden en que los tildó ([] si el menù lo propone Evelyn).
    menu: [...data.menu],
    ...(opts.requestKey ? { requestKey: opts.requestKey } : {}),
  };
}
