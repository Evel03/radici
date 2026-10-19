// Arma el JSON que la web manda a la Edge Function `public-request` (docs/contracts/public-request.md).
// Pura. Los textos van limpios con las mismas funciones del servidor (que igual vuelve a limpiar):
// así el JSON no crece con caracteres de control escapados y lo que se valida acá es lo que se guarda.
import {
  CONSENT_VERSION,
  PUBLIC_REQUEST_VERSION,
  cleanMultiLine,
  cleanOneLine,
  hasHealthData,
  mealsOf,
  type Locale,
  type PublicRequestPayload,
  type RequestData,
} from "./model.ts";

export interface PayloadOptions {
  /** Idioma de la página: el de los emails y el WhatsApp de confirmación. */
  locale: Locale;
  /** Token de Turnstile ("" si todavía no hay). */
  turnstileToken: string;
}

export function buildPayload(data: RequestData, opts: PayloadOptions): PublicRequestPayload {
  return {
    version: PUBLIC_REQUEST_VERSION,
    type: data.type,
    adults: data.adults,
    kids: data.kids,
    days: data.days,
    meals: mealsOf(data.meals),
    allergens: [...data.allergens],
    diets: [...data.diets],
    restrictionsNote: cleanOneLine(data.restrictionsNote),
    preferredDate: data.preferredDate === "" ? null : data.preferredDate,
    slot: data.slot,
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
      // Solo si hay datos de salud: sin restricciones no se guarda ese consentimiento.
      health: hasHealthData(data) && data.consentHealth ? CONSENT_VERSION : null,
    },
    turnstileToken: opts.turnstileToken,
  };
}
