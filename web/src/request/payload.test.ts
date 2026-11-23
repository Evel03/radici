// El payload de la web tiene que pasar la validación del servidor (parsePublicRequest, el mismo
// código que corre en la Edge Function): así la web y el servidor no pueden desalinearse.
import { describe, expect, it } from "vitest";
import { TEST_TOKEN, TODAY, validRequest } from "./fixtures.ts";
import {
  CONSENT_VERSION,
  HEALTH_CONSENT_VERSION,
  MAX_PAYLOAD_BYTES,
  PUBLIC_REQUEST_VERSION,
  TEXT_LIMITS,
  parsePublicRequest,
  type RequestData,
} from "./model.ts";
import { buildPayload } from "./payload.ts";

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
    expect(result.value.noAllergies).toBe(true);
    expect(result.value.consents).toEqual({ privacy: CONSENT_VERSION, health: null });
    // La entrada del motor es la del vector 1 (el precio lo calcula solo el servidor, y la web no lo muestra).
    expect(result.value.quoteInput).toEqual({ type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 1 });
  });

  it("manda las semanas del pedido semanal; una sesión extra, siempre 1", () => {
    const four = serverParse(validRequest({ weeks: 4 }));
    expect(four.ok && four.value.weeks).toBe(4);
    expect(four.ok && four.value.quoteInput.weeks).toBe(4);
    expect(buildPayload(validRequest({ weeks: 4 }), { locale: "it", turnstileToken: "t" }).weeks).toBe(4);
    // El selector puede haber quedado en otra semana si después eligió "extra": no se manda.
    expect(buildPayload(validRequest({ type: "extra", weeks: 4 }), { locale: "it", turnstileToken: "t" }).weeks).toBe(1);
    expect(serverParse(validRequest({ type: "extra", weeks: 4 })).ok).toBe(true);
    for (let weeks = 1; weeks <= 8; weeks++) expect(serverParse(validRequest({ weeks })).ok, String(weeks)).toBe(true);
    expect(serverParse(validRequest({ weeks: 9 })).ok).toBe(false);
  });

  it("arma el JSON del contrato (versión, idioma, token, comidas y fecha; franja siempre indiferente)", () => {
    const payload = buildPayload(
      validRequest({ meals: "both", preferredDate: "2026-10-26", whatsappOptIn: true }),
      { locale: "es", turnstileToken: TEST_TOKEN },
    );
    expect(PUBLIC_REQUEST_VERSION).toBe(4);
    expect(payload).toMatchObject({
      version: PUBLIC_REQUEST_VERSION,
      type: "week",
      meals: ["lunch", "dinner"],
      weeks: 1,
      preferredDate: "2026-10-26",
      slot: "any",
      whatsappOptIn: true,
      locale: "es",
      turnstileToken: TEST_TOKEN,
    });
    expect(buildPayload(validRequest({ preferredDate: "" }), { locale: "it", turnstileToken: "t" }).preferredDate).toBeNull();
  });

  it("manda los platos elegidos en el orden en que los tildó; sin elegir, la lista vacía", () => {
    const menu = ["1a1b2c3d-4e5f-4a6b-8c7d-0123456789ab", "0a1b2c3d-4e5f-4a6b-8c7d-0123456789ab"];
    expect(buildPayload(validRequest({ menu }), { locale: "it", turnstileToken: TEST_TOKEN }).menu).toEqual(menu);
    expect(buildPayload(validRequest(), { locale: "it", turnstileToken: TEST_TOKEN }).menu).toEqual([]);
    const result = serverParse(validRequest({ days: 2, menu }));
    expect(result.ok && result.value.menu).toEqual(menu);
    // Más platos que días: el servidor lo rechaza (la página frena el envío antes, con la misma validación).
    expect(serverParse(validRequest({ days: 1, menu })).ok).toBe(false);
  });

  it("todas las combinaciones de comidas y tipos pasan", () => {
    for (const meals of ["lunch", "dinner", "both"] as const) {
      for (const type of ["week", "extra"] as const) {
        expect(serverParse(validRequest({ meals, type })).ok, `${meals}/${type}`).toBe(true);
      }
    }
  });

  it("«nadie tiene alergias»: no manda nota ni consentimiento de salud, aunque haya quedado algo escrito", () => {
    const data = validRequest({ noAllergies: true, restrictionsNote: "noci", consentHealth: true });
    const payload = buildPayload(data, { locale: "it", turnstileToken: TEST_TOKEN });
    expect(payload).toMatchObject({ noAllergies: true, allergens: [], diets: [], restrictionsNote: "" });
    expect(payload.consents.health).toBeNull();
    const result = serverParse(data);
    expect(result.ok && result.value.hasRestrictions).toBe(false);
  });

  it("alergias escritas con consentimiento: manda la nota limpia (en varias líneas) y la versión del texto", () => {
    const data = validRequest({ noAllergies: false, restrictionsNote: " Celiachia \r\n\r\n\r\n Noci ", consentHealth: true });
    const payload = buildPayload(data, { locale: "it", turnstileToken: TEST_TOKEN });
    expect(payload).toMatchObject({ noAllergies: false, allergens: [], diets: [], restrictionsNote: "Celiachia\n\nNoci" });
    expect(payload.consents.health).toBe(HEALTH_CONSENT_VERSION);
    const result = serverParse(data);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value).toMatchObject({ noAllergies: false, hasRestrictions: true, restrictionsNote: "Celiachia\n\nNoci" });
    expect(result.value.consents.health).toBe(HEALTH_CONSENT_VERSION);
  });

  it("sin la casilla y sin escribir nada: sin consentimiento de salud (no hay datos que cubra) y el servidor pide la nota", () => {
    const data = validRequest({ noAllergies: false, restrictionsNote: "  \n ", consentHealth: true });
    expect(buildPayload(data, { locale: "it", turnstileToken: TEST_TOKEN }).consents.health).toBeNull();
    const result = serverParse(data);
    expect(result.ok ? {} : result.errors).toEqual({ restrictionsNote: "required" });
  });

  it("sin privacy, sin consentimiento de salud o sin token el servidor lo rechaza con el código del contrato", () => {
    const noPrivacy = serverParse(validRequest({ consentPrivacy: false }));
    expect(noPrivacy.ok ? {} : noPrivacy.errors).toEqual({ consentPrivacy: "consentRequired" });

    const noHealth = serverParse(validRequest({ noAllergies: false, restrictionsNote: "noci", consentHealth: false }));
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
      noAllergies: false,
      restrictionsNote: fill(TEXT_LIMITS.restrictionsNote, "\u0001") + fill(TEXT_LIMITS.restrictionsNote),
      consentHealth: true,
      notes: fill(TEXT_LIMITS.notes, "\u0001") + fill(TEXT_LIMITS.notes),
    });
    const body = JSON.stringify(buildPayload(data, { locale: "it", turnstileToken: "x".repeat(2048) }));
    expect(new TextEncoder().encode(body).length).toBeLessThan(MAX_PAYLOAD_BYTES);
  });
});
