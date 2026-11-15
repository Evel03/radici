import { describe, expect, it } from "vitest";
import { i18nFor, validRequest } from "./fixtures.ts";
import { computeQuote } from "./quote.ts";
import { peopleText, summaryRows } from "./summary.ts";

const ESTIMATE = { portions: 20, recipes: 3, cookMinutes: 180, serviceCents: 7800, groceriesEstCents: 6300, totalCents: 14100 };

function rows(lang: "it" | "es" | "en", overrides = {}, estimate: typeof ESTIMATE | null = ESTIMATE) {
  const data = validRequest(overrides);
  return Object.fromEntries(summaryRows(data, estimate ?? computeQuote(data), i18nFor(lang)).map((r) => [r.label, r.value]));
}

describe("peopleText", () => {
  const { t } = i18nFor("it");
  it("singular, plural y grupo vacío", () => {
    expect(peopleText(2, 2, t)).toBe("2 adulti e 2 bambini");
    expect(peopleText(1, 0, t)).toBe("1 adulto");
    expect(peopleText(0, 1, t)).toBe("1 bambino");
    expect(peopleText(1, 3, t)).toBe("1 adulto e 3 bambini");
  });
});

describe("summaryRows (pantalla de gracias)", () => {
  it("resume el pedido en italiano con la estimación del servidor", () => {
    expect(rows("it", { preferredDate: "2026-10-26" })).toEqual({
      Servizio: "Settimana di pasti",
      Persone: "2 adulti e 2 bambini",
      Giorni: "5",
      Pasti: "Cena",
      "Giorno preferito": "lunedì 26 ottobre 2026",
      "Allergie e intolleranze": "Nessuna",
      "Totale stimato": expect.stringMatching(/^141,00\s€$/) as unknown as string,
    });
  });

  it("alergias: confirma lo que contestó, nunca cuáles", () => {
    const listed = { noAllergies: false, restrictionsNote: "Celiachia, noci", consentHealth: true };
    expect(rows("es")["Alergias e intolerancias"]).toBe("Ninguna");
    expect(rows("es", listed)["Alergias e intolerancias"]).toBe("Indicadas: Evelyn las tendrá en cuenta");
    expect(rows("en", listed)["Allergies and intolerances"]).toBe("Listed: Evelyn will take them into account");
    expect(rows("it", listed)["Allergie e intolleranze"]).toBe("Indicate: Evelyn ne terrà conto");
    expect(JSON.stringify(summaryRows(validRequest(listed), ESTIMATE, i18nFor("it")))).not.toMatch(/Celiachia|noci/);
  });

  it("sin fecha: da concordare; en español e inglés", () => {
    expect(rows("es", { meals: "both" })["Día preferido"]).toBe("A convenir");
    expect(rows("es", { meals: "both" })["Comidas"]).toBe("Almuerzo y cena");
    expect(rows("en")["Estimated total"]).toBe("€141.00");
    expect(rows("en")["People"]).toBe("2 adults and 2 children");
  });

  it("si el servidor no devolvió estimación usa la de la calculadora; sin ninguna, no muestra total", () => {
    expect(rows("it", {}, null)["Totale stimato"]).toMatch(/^141,00\s€$/);
    const data = validRequest();
    expect(summaryRows(data, null, i18nFor("it")).some((r) => r.label === "Totale stimato")).toBe(false);
  });

  it("no incluye datos personales ni de salud", () => {
    const data = validRequest({ notes: "citofono rotto", zone: "Redona", noAllergies: false, restrictionsNote: "lattosio", consentHealth: true });
    const text = JSON.stringify(summaryRows(data, ESTIMATE, i18nFor("it")));
    for (const secret of ["citofono", "Redona", "Giulia", "333", "lattosio"]) {
      expect(text).not.toContain(secret);
    }
  });
});
