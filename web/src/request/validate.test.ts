import { describe, expect, it } from "vitest";
import { validRequest } from "./fixtures.ts";
import { firstErrorField, isValidPhone, validateRequest } from "./validate.ts";

const TODAY = "2026-10-19";

describe("validateRequest", () => {
  it("un pedido completo no tiene errores", () => {
    expect(validateRequest(validRequest(), TODAY)).toEqual({});
  });

  describe("consentimientos", () => {
    it("la privacy es obligatoria", () => {
      const errors = validateRequest(validRequest({ privacyConsent: false }), TODAY);
      expect(errors.privacyConsent?.key).toBe("errors.privacyRequired");
    });

    it("el consentimiento de salud es obligatorio solo si hay restricciones", () => {
      expect(validateRequest(validRequest({ healthConsent: false }), TODAY).healthConsent).toBeUndefined();
      for (const restriction of [{ allergens: ["eggs" as const] }, { diets: ["vegan" as const] }, { restrictionsNote: "no maiale" }]) {
        const without = validateRequest(validRequest({ ...restriction, healthConsent: false }), TODAY);
        expect(without.healthConsent?.key).toBe("errors.healthRequired");
        const withConsent = validateRequest(validRequest({ ...restriction, healthConsent: true }), TODAY);
        expect(withConsent.healthConsent).toBeUndefined();
      }
    });

    it("un texto de restricciones con solo espacios no cuenta como restricción", () => {
      expect(validateRequest(validRequest({ restrictionsNote: "   " }), TODAY).healthConsent).toBeUndefined();
    });
  });

  describe("rangos (LIMITS del motor)", () => {
    it("adultos y niños de 0 a 30, al menos una persona", () => {
      expect(validateRequest(validRequest({ adults: 31 }), TODAY).adults).toEqual({ key: "errors.range", params: { min: 0, max: 30 } });
      expect(validateRequest(validRequest({ kids: -1 }), TODAY).kids?.key).toBe("errors.range");
      expect(validateRequest(validRequest({ adults: 1.5 }), TODAY).adults?.key).toBe("errors.range");
      expect(validateRequest(validRequest({ adults: Number.NaN }), TODAY).adults?.key).toBe("errors.range");
      expect(validateRequest(validRequest({ adults: 0, kids: 0 }), TODAY).people?.key).toBe("errors.people");
      expect(validateRequest(validRequest({ adults: 0, kids: 1 }), TODAY)).toEqual({});
      expect(validateRequest(validRequest({ adults: 30, kids: 30 }), TODAY)).toEqual({});
    });

    it("días de 1 a 7", () => {
      expect(validateRequest(validRequest({ days: 0 }), TODAY).days?.params).toEqual({ min: 1, max: 7 });
      expect(validateRequest(validRequest({ days: 8 }), TODAY).days?.key).toBe("errors.range");
      expect(validateRequest(validRequest({ days: 7 }), TODAY)).toEqual({});
    });

    it("fecha opcional, de mañana a +14 días", () => {
      expect(validateRequest(validRequest({ date: "" }), TODAY).date).toBeUndefined();
      expect(validateRequest(validRequest({ date: "2026-10-20" }), TODAY).date).toBeUndefined();
      expect(validateRequest(validRequest({ date: "2026-11-02" }), TODAY).date).toBeUndefined();
      expect(validateRequest(validRequest({ date: "2026-10-19" }), TODAY).date?.key).toBe("errors.date");
      expect(validateRequest(validRequest({ date: "2026-11-03" }), TODAY).date?.key).toBe("errors.date");
      expect(validateRequest(validRequest({ date: "2026-02-30" }), TODAY).date?.key).toBe("errors.date");
    });

    it("largo máximo de los textos", () => {
      expect(validateRequest(validRequest({ notes: "x".repeat(501) }), TODAY).notes).toEqual({ key: "errors.tooLong", params: { max: 500 } });
      expect(validateRequest(validRequest({ restrictionsNote: "x".repeat(201), healthConsent: true }), TODAY).restrictionsNote?.key).toBe("errors.tooLong");
    });
  });

  describe("contacto", () => {
    it("nombre, zona y teléfono obligatorios", () => {
      const errors = validateRequest(validRequest({ name: " ", zone: "", phone: "" }), TODAY);
      expect(errors.name?.key).toBe("errors.nameRequired");
      expect(errors.zone?.key).toBe("errors.zoneRequired");
      expect(errors.phone?.key).toBe("errors.phoneRequired");
    });

    it("teléfono: acepta formatos habituales y rechaza basura", () => {
      for (const ok of ["3331234567", "+39 333 123 4567", "0039 035-123456", "(035) 21.34.56", "+34 600 123 456"]) {
        expect(isValidPhone(ok), ok).toBe(true);
      }
      for (const bad of ["12345", "333-abc-4567", "+39 333 123 4567 890 123", "++39333123456"]) {
        expect(isValidPhone(bad), bad).toBe(false);
      }
      expect(validateRequest(validRequest({ phone: "telefono" }), TODAY).phone?.key).toBe("errors.phoneInvalid");
    });

    it("email opcional pero válido si se escribe", () => {
      expect(validateRequest(validRequest({ email: "" }), TODAY).email).toBeUndefined();
      expect(validateRequest(validRequest({ email: "giulia@example.it" }), TODAY).email).toBeUndefined();
      expect(validateRequest(validRequest({ email: "giulia@" }), TODAY).email?.key).toBe("errors.emailInvalid");
    });
  });

  it("el primer error sigue el orden de la página", () => {
    const errors = validateRequest(validRequest({ privacyConsent: false, phone: "", adults: 0, kids: 0 }), TODAY);
    expect(firstErrorField(errors)).toBe("people");
  });
});
