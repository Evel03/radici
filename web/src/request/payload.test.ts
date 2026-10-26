// El payload de la web tiene que pasar la validación del servidor (parsePublicRequest, el mismo
// código que corre en la Edge Function): así la web y el servidor no pueden desalinearse.
import { describe, expect, it } from "vitest";
import { TEST_TOKEN, TODAY, validRequest } from "./fixtures.ts";
import {
  CONSENT_VERSION,
  MAX_PAYLOAD_BYTES,
  PUBLIC_REQUEST_VERSION,
  TEXT_LIMITS,
  parsePublicRequest,
  type RequestData,
} from "./model.ts";
import { buildPayload } from "./payload.ts";
import { computeQuote } from "./quote.ts";

function serverParse(data: RequestData, token = TEST_TOKEN) {
  // Ida y vuelta por JSON, como viaja de verdad.
  const wire: unknown = JSON.parse(JSON.stringify(buildPayload(data, { locale: "it", turnstileToken: token })));
  return parsePublicRequest(wire, { today: TODAY });
}

describe("buildPayload", () => {
  it("un pedido válido del formulario pasa la validación del servidor", () => {
    const result = serverParse(validRequest());
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.phoneE164).toBe("+393331234567");
    expect(result.value.meals).toEqual(["dinner"]);
    expect(result.value.consents).toEqual({ privacy: CONSENT_VERSION, health: null });
    // La estimación del servidor coincide con la de la calculadora de la web (vector 1).
    expect(result.estimate.totalCents).toBe(computeQuote(validRequest())?.totalCents);
    expect(result.estimate.totalCents).toBe(14100);
  });

  it("arma el JSON del contrato (versión, idioma, token, comidas y fecha)", () => {
    const payload = buildPayload(
      validRequest({ meals: "both", preferredDate: "2026-10-26", slot: "afternoon", whatsappOptIn: true }),
      { locale: "es", turnstileToken: TEST_TOKEN },
    );
    expect(payload).toMatchObject({
      version: PUBLIC_REQUEST_VERSION,
      type: "week",
      meals: ["lunch", "dinner"],
      preferredDate: "2026-10-26",
      slot: "afternoon",
      whatsappOptIn: true,
      locale: "es",
      turnstileToken: TEST_TOKEN,
    });
    expect(buildPayload(validRequest({ preferredDate: "" }), { locale: "it", turnstileToken: "t" }).preferredDate).toBeNull();
  });

  it("todas las combinaciones de comidas, tipos y franjas pasan", () => {
    for (const meals of ["lunch", "dinner", "both"] as const) {
      for (const type of ["week", "extra"] as const) {
        for (const slot of ["morning", "afternoon", "any"] as const) {
          expect(serverParse(validRequest({ meals, type, slot })).ok, `${meals}/${type}/${slot}`).toBe(true);
        }
      }
    }
  });

  it("con restricciones y consentimiento de salud manda la versión del texto y el servidor las acepta", () => {
    const data = validRequest({
      allergens: ["milk", "gluten"],
      diets: ["vegetarian"],
      restrictionsNote: "niente piccante",
      consentHealth: true,
    });
    expect(buildPayload(data, { locale: "it", turnstileToken: TEST_TOKEN }).consents.health).toBe(CONSENT_VERSION);
    const result = serverParse(data);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.value.allergens).toEqual(["gluten", "milk"]);
      expect(result.value.hasRestrictions).toBe(true);
    }
  });

  it("sin restricciones no manda consentimiento de salud aunque esté marcado", () => {
    const payload = buildPayload(validRequest({ consentHealth: true }), { locale: "it", turnstileToken: TEST_TOKEN });
    expect(payload.consents.health).toBeNull();
  });

  it("una nota de restricciones con solo espacios no cuenta como dato de salud", () => {
    const payload = buildPayload(validRequest({ restrictionsNote: "   ", consentHealth: true }), {
      locale: "it",
      turnstileToken: TEST_TOKEN,
    });
    expect(payload.consents.health).toBeNull();
    expect(serverParse(validRequest({ restrictionsNote: "   " })).ok).toBe(true);
  });

  it("sin privacy, sin consentimiento de salud o sin token el servidor lo rechaza con el código del contrato", () => {
    const noPrivacy = serverParse(validRequest({ consentPrivacy: false }));
    expect(noPrivacy.ok ? {} : noPrivacy.errors).toEqual({ consentPrivacy: "consentRequired" });

    const noHealth = serverParse(validRequest({ allergens: ["eggs"], consentHealth: false }));
    expect(noHealth.ok ? {} : noHealth.errors).toEqual({ consentHealth: "healthConsentRequired" });

    const noToken = serverParse(validRequest(), "");
    expect(noToken.ok ? {} : noToken.errors).toEqual({ turnstileToken: "required" });
  });

  it("un campo numérico vacío (NaN) llega como error de rango, no como pedido válido", () => {
    const result = serverParse(validRequest({ adults: Number.NaN }));
    expect(result.ok).toBe(false);
  });

  it("manda los textos limpios, igual que los guarda el servidor", () => {
    const payload = buildPayload(
      validRequest({ name: "  Giulia\u0000   Rossi ", email: " Giulia@Example.TEST ", notes: "a\r\n\r\n\r\n\r\nb  c" }),
      { locale: "it", turnstileToken: TEST_TOKEN },
    );
    expect(payload.name).toBe("Giulia Rossi");
    expect(payload.email).toBe("Giulia@Example.TEST");
    expect(payload.notes).toBe("a\n\nb c");
  });

  it("aun con todos los textos al máximo entra en el límite de tamaño del servidor", () => {
    // Peor caso por unidad UTF-16: 3 bytes en UTF-8 (BMP). Los caracteres de control se limpian antes,
    // así que no llegan a escaparse como \uXXXX (6 bytes cada uno).
    const fill = (max: number, ch = "€"): string => ch.repeat(max);
    const data = validRequest({
      name: fill(TEXT_LIMITS.name),
      zone: fill(TEXT_LIMITS.zone),
      phone: "+39 333 123 4567",
      email: `${"a".repeat(TEXT_LIMITS.email - 13)}@example.test`,
      restrictionsNote: fill(TEXT_LIMITS.restrictionsNote),
      notes: fill(TEXT_LIMITS.notes, "\u0001") + fill(TEXT_LIMITS.notes),
      allergens: ["gluten", "crustaceans", "eggs", "fish", "peanuts", "soy", "milk", "nuts", "celery", "mustard", "sesame", "sulphites", "lupin", "molluscs"],
      diets: ["vegetarian", "vegan"],
      consentHealth: true,
    });
    const body = JSON.stringify(buildPayload(data, { locale: "it", turnstileToken: "x".repeat(2048) }));
    expect(new TextEncoder().encode(body).length).toBeLessThan(MAX_PAYLOAD_BYTES);
  });
});
