import { describe, expect, it } from "vitest";
import type { Lang } from "../i18n/core.ts";
import { i18nFor, validRequest } from "./fixtures.ts";
import { computeLoad } from "./load.ts";
import type { RequestData } from "./model.ts";
import { nextSummary } from "./next-box.ts";

function rows(lang: Lang, overrides: Partial<RequestData> = {}): Record<string, string> {
  const data = validRequest(overrides);
  const load = computeLoad(data);
  if (!load) throw new Error("pedido inválido");
  return Object.fromEntries(nextSummary(data, load, i18nFor(lang)).map((row) => [row.label, row.value]));
}

describe("recuadro «Cómo sigue» (nextSummary)", () => {
  it("una semana: tipo, semanas, personas, días, comidas y las porciones de la semana, en italiano", () => {
    expect(rows("it")).toEqual({
      Servizio: "Settimana di pasti",
      Settimane: "1",
      Persone: "2 adulti e 2 bambini",
      "Giorni a settimana": "5",
      Pasti: "Cena",
      "Porzioni a settimana": "20",
    });
  });

  it("varias semanas: las semanas pedidas (las porciones siguen siendo las de una semana)", () => {
    expect(rows("it", { weeks: 4 })).toMatchObject({ Settimane: "4", "Porzioni a settimana": "20" });
    expect(rows("es", { weeks: 4, meals: "both" })).toEqual({
      Servicio: "Semana de comidas",
      Semanas: "4",
      Personas: "2 adultos y 2 niños",
      "Días por semana": "5",
      Comidas: "Almuerzo y cena",
      "Porciones por semana": "40",
    });
    expect(rows("en", { weeks: 8 })).toMatchObject({ Weeks: "8", "Portions per week": "20" });
  });

  it("una sesión extra: sin semanas, con los días y las porciones de la sesión", () => {
    const extra = rows("es", { type: "extra", weeks: 4, adults: 10, kids: 6, days: 1 });
    expect(extra["Semanas"]).toBeUndefined();
    expect(extra["Días"]).toBe("1");
    expect(extra["Porciones"]).toBe("16");
    expect(extra["Porciones por semana"]).toBeUndefined();
  });

  it("nunca dinero: ni «€», ni importes, ni ahorro, para ningún pedido ni idioma", () => {
    const cases: Partial<RequestData>[] = [{}, { weeks: 3 }, { weeks: 4 }, { weeks: 8 }, { adults: 3, kids: 3 }, { type: "extra" }];
    for (const lang of ["it", "es", "en"] as const) {
      for (const overrides of cases) {
        const text = JSON.stringify(rows(lang, overrides));
        expect(text, `${lang} ${JSON.stringify(overrides)}`).not.toMatch(/€|\d+[.,]\d{2}|risparmi|ahorr|saving|prezzo|precio|price/i);
      }
    }
  });

  it("no incluye datos personales ni de salud", () => {
    const text = JSON.stringify(rows("it", { notes: "citofono rotto", zone: "Redona", noAllergies: false, restrictionsNote: "lattosio", consentHealth: true }));
    for (const secret of ["citofono", "Redona", "Giulia", "333", "lattosio"]) expect(text).not.toContain(secret);
  });
});
