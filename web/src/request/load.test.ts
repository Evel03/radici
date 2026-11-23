import { describe, expect, it, vi } from "vitest";
import * as engine from "../../../supabase/functions/_shared/cook_load.ts";
import fixture from "../../../supabase/functions/_shared/quote_vectors.json";
import { computeLoad, toQuoteInput } from "./load.ts";

// Espía sobre el cálculo real: la web tiene que delegar en calcCookLoad, no recalcular.
vi.mock("../../../supabase/functions/_shared/cook_load.ts", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../../supabase/functions/_shared/cook_load.ts")>();
  return { ...actual, calcCookLoad: vi.fn(actual.calcCookLoad) };
});

const VECTOR_1 = { type: "week", adults: 2, kids: 2, days: 5, meals: "dinner", weeks: 1 } as const;

describe("carga de cocina de la web (sin precios)", () => {
  it("usa calcCookLoad del motor compartido (vector 1 → 20 porciones, 3 recetas, 180 minutos)", () => {
    vi.mocked(engine.calcCookLoad).mockClear();
    const load = computeLoad(VECTOR_1);
    expect(engine.calcCookLoad).toHaveBeenCalledTimes(1);
    expect(engine.calcCookLoad).toHaveBeenCalledWith({ type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 1 });
    expect(load).toEqual({ adultPortions: 10, kidPortions: 10, portions: 20, recipes: 3, cookMinutes: 180 });
    // Ni claves de dinero: la web no muestra precios (decisión del 22/11/2026).
    expect(Object.keys(load ?? {}).filter((key) => /cents|price|savings|autoPrice/i.test(key))).toEqual([]);
  });

  it("'pranzo e cena' son 2 comidas por día; 'pranzo' o 'cena', 1", () => {
    expect(toQuoteInput({ ...VECTOR_1, meals: "both" }).meals).toBe(2);
    expect(toQuoteInput({ ...VECTOR_1, meals: "lunch" }).meals).toBe(1);
    expect(toQuoteInput({ ...VECTOR_1, meals: "dinner" }).meals).toBe(1);
  });

  it("las semanas valen para la semana de comidas; una sesión extra es de una, aunque el selector diga otra", () => {
    expect(toQuoteInput({ ...VECTOR_1, weeks: 4 }).weeks).toBe(4);
    expect(toQuoteInput({ ...VECTOR_1, type: "extra", weeks: 4 })).toMatchObject({ type: "extra", weeks: 1 });
    expect(computeLoad({ ...VECTOR_1, type: "extra", weeks: 4 })).not.toBeNull();
  });

  it("pasa las porciones, las recetas y los minutos de todos los vectores por defecto de quote_vectors.json", () => {
    const defaults = fixture.vectors.filter((v) => !("settings" in v));
    expect(defaults.length).toBeGreaterThan(0);
    for (const v of defaults) {
      const meals = v.input.meals === 2 ? "both" : "dinner";
      const type = v.input.type === "extra" ? "extra" : "week";
      const load = computeLoad({ type, adults: v.input.adults, kids: v.input.kids, days: v.input.days, meals, weeks: v.input.weeks });
      for (const key of ["adultPortions", "kidPortions", "portions", "recipes", "cookMinutes"] as const) {
        if (key in v.expected) expect(load?.[key], `vector ${v.id} · ${key}`).toBe(v.expected[key as keyof typeof v.expected]);
      }
    }
  });

  it("devuelve null (sin romper) si la entrada no es válida para el motor", () => {
    expect(computeLoad({ ...VECTOR_1, adults: 0, kids: 0 })).toBeNull();
    expect(computeLoad({ ...VECTOR_1, days: 8 })).toBeNull();
    expect(computeLoad({ ...VECTOR_1, adults: Number.NaN })).toBeNull();
    expect(computeLoad({ ...VECTOR_1, weeks: 9 })).toBeNull();
  });
});
