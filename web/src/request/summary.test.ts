import { describe, expect, it } from "vitest";
import { i18nFor, validRequest } from "./fixtures.ts";
import { publicEstimate, type PublicRequestEstimate, type RequestData } from "./model.ts";
import { computeQuote } from "./quote.ts";
import { peopleText, summaryRows } from "./summary.ts";

/** La que devuelve el servidor para el vector 1 (una semana). */
const ONE_WEEK: PublicRequestEstimate = {
  weeks: 1,
  portions: 20,
  recipes: 3,
  cookMinutes: 180,
  groceriesEstCents: 6300,
  autoPrice: true,
  weeklyServiceCents: 15000,
  serviceCents: 15000,
  savingsCents: 0,
  totalCents: 21300,
};

function local(data: RequestData): PublicRequestEstimate {
  const quote = computeQuote(data);
  if (!quote) throw new Error("pedido inválido");
  return publicEstimate(quote);
}

function rows(lang: "it" | "es" | "en", overrides: Partial<RequestData> = {}, estimate?: PublicRequestEstimate | null) {
  const data = validRequest(overrides);
  return Object.fromEntries(summaryRows(data, estimate === undefined ? local(data) : estimate, i18nFor(lang)).map((r) => [r.label, r.value]));
}

const euros = (text: string): RegExp => new RegExp(`^${text.replace(/[  ]/g, "[ \\u00a0]")}$`);

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
  it("una semana: resume el pedido en italiano con la estimación del servidor", () => {
    expect(rows("it", { preferredDate: "2026-10-26" }, ONE_WEEK)).toEqual({
      Servizio: "Settimana di pasti",
      Settimane: "1",
      Persone: "2 adulti e 2 bambini",
      "Giorni a settimana": "5",
      Pasti: "Cena",
      "Giorno preferito": "lunedì 26 ottobre 2026",
      "Allergie e intolleranze": "Nessuna",
      "Prezzo del servizio": expect.stringMatching(euros("150,00 €")) as unknown as string,
      "Spesa stimata a settimana": expect.stringMatching(euros("63,00 €")) as unknown as string,
    });
    // El precio del servicio es lo que se destaca.
    const total = summaryRows(validRequest(), ONE_WEEK, i18nFor("it")).filter((row) => row.total);
    expect(total.map((row) => row.label)).toEqual(["Prezzo del servizio"]);
  });

  it("4 semanas: las fechas de cada semana, el precio por semana, el de las 4 y el ahorro", () => {
    const data = { weeks: 4, preferredDate: "2026-11-23" };
    const it_ = rows("it", data);
    expect(it_["Settimane"]).toBe("4");
    expect(it_["Giorni (uno a settimana)"]).toBe("lun 23 nov · lun 30 nov · lun 7 dic · lun 14 dic");
    expect(it_["Giorno preferito"]).toBeUndefined();
    expect(it_["Prezzo a settimana"]).toMatch(euros("140,00 €"));
    expect(it_["Prezzo per 4 settimane"]).toMatch(euros("560,00 €"));
    expect(it_["Risparmi"]).toMatch(euros("40,00 €"));
    const en = rows("en", data);
    expect(en["Days (one a week)"]).toBe("Mon, 23 Nov · Mon, 30 Nov · Mon, 7 Dec · Mon, 14 Dec");
    expect(en["Price for 4 weeks"]).toBe("€560.00");
    expect(en["You save"]).toBe("€40.00");
    expect(rows("es", data)["Precio por 4 semanas"]).toMatch(euros("560,00 €"));
    // Sin fecha: «a convenir», también con varias semanas.
    expect(rows("es", { weeks: 4 })["Día preferido"]).toBe("A convenir");
  });

  it("3 semanas: sin descuento ni ahorro", () => {
    const three = rows("it", { weeks: 3 });
    expect(three["Prezzo per 3 settimane"]).toMatch(euros("450,00 €"));
    expect(three["Risparmi"]).toBeUndefined();
  });

  it("sin precio automático: más de 5 personas o una sesión extra, «te lo prepara Evelyn», con la compra", () => {
    const six = rows("it", { adults: 3, kids: 3 });
    expect(six["Prezzo del servizio"]).toBe("Te lo prepara Evelyn");
    expect(six["Spesa stimata a settimana"]).toMatch(euros("94,50 €"));
    const extra = rows("es", { type: "extra", weeks: 4 });
    expect(extra["Precio del servicio"]).toBe("Te lo prepara Evelyn");
    // Una sesión extra no tiene semanas: sin la fila, y sus días no son «por semana».
    expect(extra["Semanas"]).toBeUndefined();
    expect(extra["Días"]).toBe("5");
    expect(extra["Compra estimada"]).toMatch(euros("63,00 €"));
    expect(summaryRows(validRequest({ type: "extra" }), local(validRequest({ type: "extra" })), i18nFor("it")).some((r) => r.total)).toBe(false);
  });

  it("alergias: confirma lo que contestó, nunca cuáles", () => {
    const listed = { noAllergies: false, restrictionsNote: "Celiachia, noci", consentHealth: true };
    expect(rows("es")["Alergias e intolerancias"]).toBe("Ninguna");
    expect(rows("es", listed)["Alergias e intolerancias"]).toBe("Indicadas: Evelyn las tendrá en cuenta");
    expect(rows("en", listed)["Allergies and intolerances"]).toBe("Listed: Evelyn will take them into account");
    expect(rows("it", listed)["Allergie e intolleranze"]).toBe("Indicate: Evelyn ne terrà conto");
    expect(JSON.stringify(summaryRows(validRequest(listed), ONE_WEEK, i18nFor("it")))).not.toMatch(/Celiachia|noci/);
  });

  it("sin fecha: da concordare; en español e inglés", () => {
    expect(rows("es", { meals: "both" })["Día preferido"]).toBe("A convenir");
    expect(rows("es", { meals: "both" })["Comidas"]).toBe("Almuerzo y cena");
    expect(rows("en", {}, ONE_WEEK)["Service price"]).toBe("€150.00");
    expect(rows("en")["People"]).toBe("2 adults and 2 children");
  });

  it("sin estimación (no se sabe qué guardó el servidor), no muestra precio", () => {
    const labels = summaryRows(validRequest(), null, i18nFor("it")).map((r) => r.label);
    expect(labels).not.toContain("Prezzo del servizio");
    expect(labels).not.toContain("Spesa stimata a settimana");
  });

  it("no incluye datos personales ni de salud", () => {
    const data = validRequest({ notes: "citofono rotto", zone: "Redona", noAllergies: false, restrictionsNote: "lattosio", consentHealth: true });
    const text = JSON.stringify(summaryRows(data, ONE_WEEK, i18nFor("it")));
    for (const secret of ["citofono", "Redona", "Giulia", "333", "lattosio"]) {
      expect(text).not.toContain(secret);
    }
  });
});
