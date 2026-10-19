import { describe, expect, it } from "vitest";
import { i18nFor, validRequest } from "./fixtures.ts";
import { computeQuote } from "./quote.ts";
import { buildWhatsAppMessage, buildWhatsAppUrl } from "./whatsapp.ts";
import type { RequestData } from "./model.ts";

function message(data: RequestData, lang: "it" | "es" | "en" = "it"): string {
  const quote = computeQuote(data);
  if (!quote) throw new Error("pedido inválido en el test");
  return buildWhatsAppMessage(data, quote, i18nFor(lang));
}

describe("buildWhatsAppMessage", () => {
  it("incluye personas, días, comidas, presupuesto y contacto (italiano)", () => {
    const text = message(validRequest({ date: "2026-10-26", slot: "afternoon", email: "giulia@example.com" }));
    expect(text).toContain("Ciao Evelyn!");
    expect(text).toContain("Persone: 2 adulti e 2 bambini");
    expect(text).toContain("Giorni: 5");
    expect(text).toContain("Pasti: Cena");
    expect(text).toMatch(/Totale stimato: 141,00\s€/);
    expect(text).toMatch(/Servizio: 78,00\s€/);
    expect(text).toMatch(/Spesa stimata: 63,00\s€/);
    expect(text).toContain("Tempo di cucina: circa 3 h");
    expect(text).toContain("Porzioni: 20");
    expect(text).toContain("Giorno preferito: lunedì 26 ottobre 2026");
    expect(text).toContain("Fascia oraria: Pomeriggio");
    expect(text).toContain("Nome: Giulia Rossi");
    expect(text).toContain("Zona: Città Alta");
    expect(text).toContain("Telefono: +39 333 123 4567");
    expect(text).toContain("Email: giulia@example.com");
    expect(text).toContain("Informativa privacy accettata (testo 2026-10-19)");
  });

  it("usa singular y omite el grupo vacío", () => {
    const text = message(validRequest({ adults: 1, kids: 0, meals: "both", date: "" }));
    expect(text).toContain("Persone: 1 adulto");
    expect(text).not.toContain("bambin");
    expect(text).toContain("Pasti: Pranzo e cena");
    expect(text).toContain("Giorno preferito: da concordare");
  });

  it("está en el idioma elegido, con el formato de moneda de ese idioma", () => {
    const es = message(validRequest(), "es");
    expect(es).toContain("¡Hola, Evelyn!");
    expect(es).toContain("Personas: 2 adultos y 2 niños");
    expect(es).toMatch(/Total estimado: 141,00\s€/);
    const en = message(validRequest(), "en");
    expect(en).toContain("People: 2 adults and 2 children");
    expect(en).toContain("Estimated total: €141.00");
  });

  describe("restricciones (datos de salud)", () => {
    const withRestrictions = {
      allergens: ["gluten", "milk"] as RequestData["allergens"],
      diets: ["vegetarian"] as RequestData["diets"],
      restrictionsNote: "niente piccante",
    };

    it("se incluyen solo con consentimiento explícito", () => {
      const text = message(validRequest({ ...withRestrictions, healthConsent: true }));
      expect(text).toContain("Allergeni da evitare: Glutine, Latte e derivati");
      expect(text).toContain("Glutine: attenzione alla contaminazione crociata");
      expect(text).toContain("Dieta: Vegetariana");
      expect(text).toContain("Altro: niente piccante");
      expect(text).toContain("Consenso al trattamento dei dati sanitari dato (testo 2026-10-19)");
    });

    it("sin consentimiento no viaja ninguna restricción", () => {
      const text = message(validRequest({ ...withRestrictions, healthConsent: false }));
      expect(text).not.toContain("Glutine");
      expect(text).not.toContain("Latte");
      expect(text).not.toContain("Vegetariana");
      expect(text).not.toContain("piccante");
      expect(text).not.toContain("dati sanitari dato");
      expect(text).toContain("Non comunicate (manca il consenso)");
    });

    it("sin restricciones lo dice explícitamente", () => {
      const text = message(validRequest({ healthConsent: true }));
      expect(text).toContain("Nessuna indicata");
      expect(text).not.toContain("dati sanitari dato");
    });
  });

  it("normaliza los campos de una línea y conserva los saltos de las notas", () => {
    const text = message(validRequest({ name: "  Giulia \n Rossi ", notes: "Riga 1\r\n\r\n\r\nRiga 2" }));
    expect(text).toContain("Nome: Giulia Rossi");
    expect(text).toContain("*Note*\nRiga 1\n\nRiga 2");
  });
});

describe("buildWhatsAppUrl", () => {
  it("codifica el texto para la URL y se decodifica igual", () => {
    const text = message(validRequest({ notes: "Pasta & pizza? 100% sì! #cena\nCiao 😊" }));
    const url = buildWhatsAppUrl("393331234567", text);
    expect(url.startsWith("https://wa.me/393331234567?text=")).toBe(true);
    const encoded = url.slice(url.indexOf("?text=") + "?text=".length);
    expect(encoded).not.toMatch(/[\s&#?\n]/);
    expect(encoded).toContain("%0A");
    expect(encoded).toContain("%26");
    expect(decodeURIComponent(encoded)).toBe(text);
    expect(new URL(url).searchParams.get("text")).toBe(text);
  });

  it("rechaza números mal formados", () => {
    expect(() => buildWhatsAppUrl("+39 333", "hola")).toThrow();
    expect(() => buildWhatsAppUrl("", "hola")).toThrow();
  });
});
