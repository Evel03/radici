import { describe, expect, it } from "vitest";
import { flatten } from "../i18n/core.ts";
import itJson from "../i18n/it.json";
import { TEST_TOKEN, TODAY, validRequest } from "./fixtures.ts";
import { CONSENT_VERSION, type ErrorCode, type PublicRequestField, type RequestData } from "./model.ts";
import { FIELD_ORDER, PAGE_FIELDS, fieldError, firstErrorField, translateErrors, validateRequest } from "./validate.ts";

const ALL_FIELDS: readonly PublicRequestField[] = [
  "payload", "version", "type", "adults", "kids", "people", "days", "meals", "noAllergies", "allergens", "diets",
  "restrictionsNote", "preferredDate", "slot", "name", "zone", "phone", "email", "whatsappOptIn", "notes",
  "locale", "consentPrivacy", "consentHealth", "turnstileToken", "requestKey",
];
const ALL_CODES: readonly ErrorCode[] = [
  "required", "invalid", "range", "tooLong", "dateOutOfRange", "consentRequired", "healthConsentRequired",
];

function validate(overrides: Partial<RequestData> = {}, token = TEST_TOKEN) {
  return validateRequest(validRequest(overrides), TODAY, { locale: "it", turnstileToken: token });
}

describe("validateRequest (la misma validación del servidor)", () => {
  it("un pedido completo, con token, no tiene errores", () => {
    expect(validate()).toEqual({});
  });

  it("sin token de Turnstile solo falta la verificación", () => {
    expect(validate({}, "")).toEqual({ turnstileToken: { key: "errors.turnstileRequired" } });
  });

  describe("consentimientos", () => {
    it("la privacy es obligatoria", () => {
      expect(validate({ consentPrivacy: false }).consentPrivacy?.key).toBe("errors.privacyRequired");
    });
  });

  describe("alergias e intolerancias", () => {
    it("marcar que nadie tiene alcanza: no pide nota ni consentimiento", () => {
      expect(validate({ noAllergies: true })).toEqual({});
    });

    it("con la casilla marcada lo que haya quedado escrito no se valida (no se manda)", () => {
      expect(validate({ noAllergies: true, restrictionsNote: "x".repeat(500), consentHealth: false })).toEqual({});
    });

    it("sin la casilla hay que escribirlas (solo espacios no cuenta); el consentimiento se pide recién con algo escrito", () => {
      for (const restrictionsNote of ["", "  \n\t "]) {
        expect(validate({ noAllergies: false, restrictionsNote })).toEqual({ restrictionsNote: { key: "errors.restrictionsRequired" } });
      }
    });

    it("escritas, piden el consentimiento explícito de salud", () => {
      expect(validate({ noAllergies: false, restrictionsNote: "noci" })).toEqual({ consentHealth: { key: "errors.healthRequired" } });
      expect(validate({ noAllergies: false, restrictionsNote: "noci", consentHealth: true })).toEqual({});
    });

    it("largo máximo de la nota", () => {
      expect(validate({ noAllergies: false, restrictionsNote: "x".repeat(201), consentHealth: true }).restrictionsNote).toEqual({
        key: "errors.tooLong",
        params: { max: 200 },
      });
    });
  });

  describe("rangos (LIMITS del motor)", () => {
    it("adultos y niños de 0 a 30, al menos una persona", () => {
      expect(validate({ adults: 31 }).adults).toEqual({ key: "errors.range", params: { min: 0, max: 30 } });
      expect(validate({ kids: -1 }).kids?.key).toBe("errors.range");
      expect(validate({ adults: 1.5 }).adults?.key).toBe("errors.range");
      expect(validate({ adults: Number.NaN }).adults?.key).toBe("errors.range");
      expect(validate({ adults: 0, kids: 0 }).people?.key).toBe("errors.people");
      expect(validate({ adults: 0, kids: 1 })).toEqual({});
      expect(validate({ adults: 30, kids: 30 })).toEqual({});
    });

    it("días de 1 a 7", () => {
      expect(validate({ days: 0 }).days).toEqual({ key: "errors.range", params: { min: 1, max: 7 } });
      expect(validate({ days: 8 }).days?.key).toBe("errors.range");
      expect(validate({ days: 7 })).toEqual({});
    });

    it("fecha opcional, de mañana a +56 días: 8 semanas (Europe/Rome)", () => {
      expect(validate({ preferredDate: "" }).preferredDate).toBeUndefined();
      expect(validate({ preferredDate: "2026-10-20" }).preferredDate).toBeUndefined();
      expect(validate({ preferredDate: "2026-11-03" }).preferredDate).toBeUndefined();
      expect(validate({ preferredDate: "2026-12-14" }).preferredDate).toBeUndefined();
      // El texto dice la ventana con {horizonWeeks}, un valor global de la web (i18n/site.ts): sin parámetros.
      expect(validate({ preferredDate: "2026-10-19" }).preferredDate).toEqual({ key: "errors.date" });
      expect(validate({ preferredDate: "2026-12-15" }).preferredDate?.key).toBe("errors.date");
      expect(validate({ preferredDate: "2026-02-30" }).preferredDate?.key).toBe("errors.date");
    });

    it("largo máximo de los textos", () => {
      expect(validate({ notes: "x".repeat(501) }).notes).toEqual({ key: "errors.tooLong", params: { max: 500 } });
      expect(validate({ name: "x".repeat(81) }).name).toEqual({ key: "errors.tooLong", params: { max: 80 } });
    });
  });

  describe("contacto", () => {
    it("nombre, zona, teléfono y email obligatorios", () => {
      const errors = validate({ name: " ", zone: "", phone: "", email: "" });
      expect(errors.name?.key).toBe("errors.nameRequired");
      expect(errors.zone?.key).toBe("errors.zoneRequired");
      expect(errors.phone?.key).toBe("errors.phoneRequired");
      expect(errors.email?.key).toBe("errors.emailRequired");
    });

    it("teléfono: italianos sin prefijo o internacionales con +/00; el resto pide el prefijo", () => {
      for (const ok of ["3331234567", "+39 333 123 4567", "0039 035-123456", "035 21.34.56", "+34 600 123 456", "(+54) 9 11 2345-6789"]) {
        expect(validate({ phone: ok }).phone, ok).toBeUndefined();
      }
      for (const bad of ["612 345 678", "12345", "333-abc-4567", "telefono"]) {
        expect(validate({ phone: bad }).phone?.key, bad).toBe("errors.phoneInvalid");
      }
    });

    it("email válido (se acepta con mayúsculas y espacios alrededor)", () => {
      expect(validate({ email: " Giulia@Example.IT " }).email).toBeUndefined();
      expect(validate({ email: "giulia@" }).email?.key).toBe("errors.emailInvalid");
      expect(validate({ email: "giulia@example" }).email?.key).toBe("errors.emailInvalid");
    });

    it("la casilla de WhatsApp es opcional", () => {
      expect(validate({ whatsappOptIn: true })).toEqual({});
      expect(validate({ whatsappOptIn: false })).toEqual({});
    });
  });

  it("el primer error sigue el orden de la página", () => {
    const errors = validate({ consentPrivacy: false, phone: "", adults: 0, kids: 0 });
    expect(firstErrorField(errors)).toBe("people");
    expect(firstErrorField({})).toBeUndefined();
    // Las alergias van entre «¿Cuándo?» y «Tus datos».
    expect(firstErrorField(validate({ noAllergies: false, phone: "", consentPrivacy: false }))).toBe("restrictionsNote");
    expect(firstErrorField(validate({ noAllergies: false, preferredDate: "2026-10-19" }))).toBe("preferredDate");
  });
});

describe("translateErrors (respuesta 400 del servidor)", () => {
  it("traduce cada campo a su mensaje", () => {
    const { fields, outdated } = translateErrors({
      phone: "invalid",
      email: "required",
      restrictionsNote: "required",
      consentHealth: "healthConsentRequired",
      noAllergies: "invalid",
    });
    expect(outdated).toBe(false);
    expect(fields).toEqual({
      phone: { key: "errors.phoneInvalid" },
      email: { key: "errors.emailRequired" },
      restrictionsNote: { key: "errors.restrictionsRequired" },
      consentHealth: { key: "errors.healthRequired" },
      noAllergies: { key: "errors.invalid" },
    });
  });

  it("una fecha que el servidor deja fuera de su ventana se marca en el calendario, sin pedir recargar", () => {
    // Por ejemplo, unos minutos del despliegue de las 8 semanas: la función de antes (14 días) todavía
    // rechaza una fecha que esta página deja elegir. El mismo contrato y la misma versión: no hay que recargar.
    expect(translateErrors({ preferredDate: "dateOutOfRange" })).toEqual({
      fields: { preferredDate: { key: "errors.date" } },
      outdated: false,
    });
  });

  it("un error en alérgenos o dietas (que la web manda vacíos) es de otra versión del servidor: pide recargar", () => {
    expect(translateErrors({ diets: "invalid" })).toEqual({ fields: {}, outdated: true });
    expect(translateErrors({ allergens: "invalid", name: "required" })).toEqual({
      fields: { name: { key: "errors.nameRequired" } },
      outdated: true,
    });
  });

  it("con la versión rechazada los errores de campo son de otro contrato: solo «página desactualizada»", () => {
    // Por ejemplo, mientras se despliegan la web y la función: la de antes no conoce la privacy ni el
    // consentimiento de salud de esta página, y no hay que marcar esas casillas como faltantes.
    expect(
      translateErrors({ version: "invalid", consentPrivacy: "consentRequired", consentHealth: "healthConsentRequired" }),
    ).toEqual({ fields: {}, outdated: true });
  });

  it("una versión de consentimiento que la página mandó y el servidor no acepta: página desactualizada, no la casilla", () => {
    // Por ejemplo, una página abierta antes de que cambie el texto: la casilla está marcada y volver a
    // marcarla no arregla nada. Hay que recargar.
    const sent = { privacy: CONSENT_VERSION, health: CONSENT_VERSION };
    expect(translateErrors({ consentHealth: "healthConsentRequired" }, sent)).toEqual({ fields: {}, outdated: true });
    expect(translateErrors({ consentPrivacy: "consentRequired", name: "required" }, sent)).toEqual({
      fields: { name: { key: "errors.nameRequired" } },
      outdated: true,
    });
    // Sin la casilla (no mandó la versión), es el error del campo de siempre.
    const unchecked = { privacy: "", health: null };
    expect(translateErrors({ consentPrivacy: "consentRequired", consentHealth: "healthConsentRequired" }, unchecked)).toEqual({
      fields: { consentPrivacy: { key: "errors.privacyRequired" }, consentHealth: { key: "errors.healthRequired" } },
      outdated: false,
    });
  });

  it("versión, payload o idioma rechazados: la página está desactualizada", () => {
    expect(translateErrors({ version: "invalid" })).toEqual({ fields: {}, outdated: true });
    expect(translateErrors({ payload: "invalid" }).outdated).toBe(true);
    expect(translateErrors({ locale: "invalid", name: "required" })).toEqual({
      fields: { name: { key: "errors.nameRequired" } },
      outdated: true,
    });
  });

  it("campos o códigos que no conoce (otra versión del servidor): no se rompe y pide recargar", () => {
    const unknown = { nuevoCampo: "required", phone: "otroCodigo" } as unknown as Parameters<typeof translateErrors>[0];
    expect(translateErrors(unknown)).toEqual({ fields: { phone: { key: "errors.phoneInvalid" } }, outdated: true });
    // La franja ya no se pregunta (la web manda "any"): un error ahí es de otra versión del servidor.
    expect(translateErrors({ slot: "invalid" })).toEqual({ fields: {}, outdated: true });
    expect(translateErrors({ type: "invalid" }).fields).toEqual({ type: { key: "errors.invalid" } });
  });
});

describe("fieldError: cada campo y código del contrato tiene un mensaje que existe en it.json", () => {
  const it_ = flatten(itJson);
  it("todas las combinaciones", () => {
    for (const field of FIELD_ORDER) {
      for (const code of ALL_CODES) {
        const { key } = fieldError(field, code);
        expect(key in it_, `${field}/${code} → ${key}`).toBe(true);
      }
    }
  });

  it("FIELD_ORDER cubre todos los campos del contrato salvo los de la página entera", () => {
    const formLevel = ALL_FIELDS.filter((f) => !(FIELD_ORDER as readonly string[]).includes(f));
    expect(formLevel.sort()).toEqual(Object.keys(PAGE_FIELDS).sort());
  });
});
