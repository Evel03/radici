import { describe, expect, it } from "vitest";
import { i18nFor, validRequest } from "./fixtures.ts";
import type { RequestData } from "./model.ts";
import type { MenuChoice } from "./menu.ts";
import { menuSummary, peopleText, summaryRows } from "./summary.ts";

function rows(lang: "it" | "es" | "en", overrides: Partial<RequestData> = {}) {
  return Object.fromEntries(summaryRows(validRequest(overrides), i18nFor(lang)).map((r) => [r.label, r.value]));
}

const nbsp = (text: string): string => text.replace(/ /g, " ");

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
  it("una semana: resume el pedido en italiano, sin ningún precio", () => {
    expect(rows("it", { preferredDate: "2026-10-26" })).toEqual({
      Servizio: "Settimana di pasti",
      Settimane: "1",
      Persone: "2 adulti e 2 bambini",
      "Giorni a settimana": "5",
      Pasti: "Cena",
      "Giorno preferito": "lunedì 26 ottobre 2026",
      // Sin platos elegidos: el menù lo propone Evelyn.
      Menù: "Lo propone Evelyn",
      "Allergie e intolleranze": "Nessuna",
    });
  });

  it("4 semanas: las fechas de cada semana, y ninguna fila de servicio, total ni ahorro", () => {
    const data = { weeks: 4, preferredDate: "2026-11-23" };
    const it_ = rows("it", data);
    expect(it_["Settimane"]).toBe("4");
    // Espacios duros dentro de cada fecha: en el teléfono no se corta "lun" de "23 nov".
    expect(it_["Giorni (uno a settimana)"]).toBe(["lun 23 nov", "lun 30 nov", "lun 7 dic", "lun 14 dic"].map(nbsp).join(" · "));
    expect(it_["Giorno preferito"]).toBeUndefined();
    expect(Object.keys(it_).filter((label) => /Servizio,|Risparmi|Prezzo/.test(label))).toEqual([]);
    const en = rows("en", data);
    expect(en["Days (one a week)"]).toBe(["Mon, 23 Nov", "Mon, 30 Nov", "Mon, 7 Dec", "Mon, 14 Dec"].map(nbsp).join(" · "));
    // Sin fecha: «a convenir», también con varias semanas.
    expect(rows("es", { weeks: 4 })["Día preferido"]).toBe("A convenir");
  });

  it("nunca hay dinero, para ningún pedido ni idioma: ni «€», ni importes, ni «Preventivo di Evelyn» (el presupuesto lo prepara ella a mano)", () => {
    const cases: Partial<RequestData>[] = [{}, { weeks: 3 }, { weeks: 4 }, { weeks: 8 }, { adults: 3, kids: 3 }, { type: "extra" }, { type: "extra", weeks: 4 }];
    for (const lang of ["it", "es", "en"] as const) {
      for (const overrides of cases) {
        const text = JSON.stringify(summaryRows(validRequest(overrides), i18nFor(lang)));
        expect(text, `${lang} ${JSON.stringify(overrides)}`).not.toMatch(/€|\d+[.,]\d{2}|preventivo di|presupuesto de|quote|price|prezzo|precio|risparmi|ahorr|saving/i);
      }
    }
  });

  it("una sesión extra no tiene semanas, y sus días no son «por semana»", () => {
    const extra = rows("es", { type: "extra", weeks: 4 });
    expect(extra["Semanas"]).toBeUndefined();
    expect(extra["Días"]).toBe("5");
  });

  it("sin compra (la hace el cliente con la lista de Evelyn): ninguna fila la menciona", () => {
    for (const lang of ["it", "es", "en"] as const) {
      for (const overrides of [{}, { weeks: 4 }, { adults: 3, kids: 3 }, { type: "extra" as const }]) {
        const text = JSON.stringify(summaryRows(validRequest(overrides), i18nFor(lang)));
        expect(text, lang).not.toMatch(/spesa|compra|grocer|shopping/i);
      }
    }
    expect(Object.keys(rows("it"))).toEqual([
      "Servizio",
      "Settimane",
      "Persone",
      "Giorni a settimana",
      "Pasti",
      "Giorno preferito",
      "Menù",
      "Allergie e intolleranze",
    ]);
  });

  it("alergias: confirma lo que contestó, nunca cuáles", () => {
    const listed = { noAllergies: false, restrictionsNote: "Celiachia, noci", consentHealth: true };
    expect(rows("es")["Alergias e intolerancias"]).toBe("Ninguna");
    expect(rows("es", listed)["Alergias e intolerancias"]).toBe("Indicadas: Evelyn las tendrá en cuenta");
    expect(rows("en", listed)["Allergies and intolerances"]).toBe("Listed: Evelyn will take them into account");
    expect(rows("it", listed)["Allergie e intolleranze"]).toBe("Indicate: Evelyn ne terrà conto");
    expect(JSON.stringify(summaryRows(validRequest(listed), i18nFor("it")))).not.toMatch(/Celiachia|noci/);
  });

  it("sin fecha: da concordare; en español e inglés", () => {
    expect(rows("es", { meals: "both" })["Día preferido"]).toBe("A convenir");
    expect(rows("es", { meals: "both" })["Comidas"]).toBe("Almuerzo y cena");
    expect(rows("en")["People"]).toBe("2 adults and 2 children");
  });

  it("no incluye datos personales ni de salud", () => {
    const data = validRequest({ notes: "citofono rotto", zone: "Redona", noAllergies: false, restrictionsNote: "lattosio", consentHealth: true });
    const text = JSON.stringify(summaryRows(data, i18nFor("it")));
    for (const secret of ["citofono", "Redona", "Giulia", "333", "lattosio"]) {
      expect(text).not.toContain(secret);
    }
  });
});

describe("menù en la pantalla de gracias", () => {
  const LASAGNE: MenuChoice = { id: "0a1b2c3d-4e5f-4a6b-8c7d-0123456789ab", name: { it: "Lasagne", es: "Lasaña", en: null } };
  const MINESTRONE: MenuChoice = { id: "1a1b2c3d-4e5f-4a6b-8c7d-0123456789ab", name: { it: "Minestrone", es: null, en: "Minestrone soup" } };

  it("los platos que guardó el servidor, en orden; si son menos que los días, que el resto lo propone Evelyn", () => {
    const row = (lang: "it" | "es" | "en", days: number, menu: MenuChoice[]) =>
      Object.fromEntries(summaryRows(validRequest({ days }), i18nFor(lang), menu).map((r) => [r.label, r.value]));
    expect(row("it", 5, [MINESTRONE, LASAGNE])["Menù"]).toBe("Minestrone · Lasagne; il resto lo propone Evelyn");
    expect(row("it", 2, [MINESTRONE, LASAGNE])["Menù"]).toBe("Minestrone · Lasagne");
    // En el idioma de la página, con respaldo al italiano.
    expect(row("es", 2, [MINESTRONE, LASAGNE])["Menú"]).toBe("Minestrone · Lasaña");
    expect(row("en", 3, [MINESTRONE, LASAGNE])["Menu"]).toBe("Minestrone soup · Lasagne; Evelyn will suggest the rest");
    expect(row("en", 3, [])["Menu"]).toBe("Evelyn will suggest it");
    expect(menuSummary([], 5, i18nFor("es"))).toBe("Lo propone Evelyn");
  });

  it("va después de la fecha y antes de las alergias", () => {
    const labels = summaryRows(validRequest(), i18nFor("it"), [LASAGNE]).map((r) => r.label);
    expect(labels.indexOf("Menù")).toBe(labels.indexOf("Giorno preferito") + 1);
    expect(labels.indexOf("Allergie e intolleranze")).toBe(labels.indexOf("Menù") + 1);
  });
});
