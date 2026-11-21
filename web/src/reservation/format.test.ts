import { describe, expect, it } from "vitest";
import { i18nFor } from "../request/fixtures.ts";
import { content } from "./fixtures.ts";
import { formatQuantity, formatRomeDay, shoppingList } from "./format.ts";

const NBSP = String.fromCharCode(0xa0);

describe("formatQuantity", () => {
  it("gramos y mililitros; desde 1000, kg y l con el separador decimal del idioma", () => {
    const cases: Array<[number, "g" | "ml", string, string, string]> = [
      [250, "g", "250 g", "250 g", "250 g"],
      [999, "g", "999 g", "999 g", "999 g"],
      [1000, "g", "1 kg", "1 kg", "1 kg"],
      [1250, "g", "1,25 kg", "1,25 kg", "1.25 kg"],
      [1234, "g", "1,234 kg", "1,234 kg", "1.234 kg"],
      [1500, "ml", "1,5 l", "1,5 l", "1.5 l"],
      [330, "ml", "330 ml", "330 ml", "330 ml"],
    ];
    for (const [quantity, unit, it, es, en] of cases) {
      expect(formatQuantity(quantity, unit, i18nFor("it"))).toBe(it.replace(" ", NBSP));
      expect(formatQuantity(quantity, unit, i18nFor("es"))).toBe(es.replace(" ", NBSP));
      expect(formatQuantity(quantity, unit, i18nFor("en"))).toBe(en.replace(" ", NBSP));
    }
  });

  it("piezas, con su palabra en cada idioma (una o varias)", () => {
    expect(formatQuantity(1, "pcs", i18nFor("it"))).toBe("1 pezzo");
    expect(formatQuantity(3, "pcs", i18nFor("it"))).toBe("3 pezzi");
    expect(formatQuantity(1, "pcs", i18nFor("es"))).toBe("1 unidad");
    expect(formatQuantity(3, "pcs", i18nFor("es"))).toBe("3 unidades");
    expect(formatQuantity(1, "pcs", i18nFor("en"))).toBe("1 piece");
    expect(formatQuantity(12, "pcs", i18nFor("en"))).toBe("12 pieces");
  });
});

describe("shoppingList", () => {
  it("lo que hay que comprar, por sección (en el orden del súper y en el de Evelyn dentro de cada una), y aparte lo de tener en casa", () => {
    const { toBuy, atHome } = shoppingList(content().items);
    expect(toBuy.map((group) => [group.section, group.items.map((item) => item.name)])).toEqual([
      ["produce", ["Pomodori", "Zucchine"]],
      ["dairy_eggs", ["Latte", "Uova"]],
    ]);
    expect(atHome.map((item) => item.name)).toEqual(["Sale", "Olio"]);
  });

  it("sin renglones, nada", () => {
    expect(shoppingList([])).toEqual({ toBuy: [], atHome: [] });
  });
});

describe("formatRomeDay", () => {
  it("el día en Roma, no en UTC ni en el del dispositivo", () => {
    // 23:30 UTC del 28/2 son las 0:30 del 1/3 en Roma.
    expect(formatRomeDay("2027-02-28T23:30:00Z", "it-IT")).toBe("1 marzo 2027");
    expect(formatRomeDay("2027-02-25T18:03:00.123456+00:00", "es-ES")).toBe("25 de febrero de 2027");
    expect(formatRomeDay("2027-02-25T18:03:00Z", "en-IE")).toBe("25 February 2027");
    expect(formatRomeDay("ayer", "it-IT")).toBe("ayer");
  });
});
