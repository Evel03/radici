import { describe, expect, it, vi } from "vitest";
import * as engine from "../../../supabase/functions/_shared/quote.ts";
import fixture from "../../../supabase/functions/_shared/quote_vectors.json";
import { computeQuote, exampleQuote, toQuoteInput } from "./quote.ts";

// Espía sobre el motor real: la calculadora tiene que delegar en calcQuote, no recalcular.
vi.mock("../../../supabase/functions/_shared/quote.ts", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../../supabase/functions/_shared/quote.ts")>();
  return { ...actual, calcQuote: vi.fn(actual.calcQuote) };
});

describe("calculadora de la web", () => {
  it("usa calcQuote del motor compartido (vector 1 → total 14100 centavos)", () => {
    vi.mocked(engine.calcQuote).mockClear();
    const quote = computeQuote({ adults: 2, kids: 2, days: 5, meals: "dinner" });
    expect(engine.calcQuote).toHaveBeenCalledTimes(1);
    expect(engine.calcQuote).toHaveBeenCalledWith({ adults: 2, kids: 2, days: 5, meals: 1 }, engine.DEFAULT_PRICING);
    expect(quote?.totalCents).toBe(14100);
    expect(quote?.serviceCents).toBe(7800);
    expect(quote?.groceriesEstCents).toBe(6300);
    expect(quote?.cookMinutes).toBe(180);
  });

  it("'pranzo e cena' son 2 comidas por día; 'pranzo' o 'cena', 1", () => {
    expect(toQuoteInput({ adults: 1, kids: 0, days: 1, meals: "both" }).meals).toBe(2);
    expect(toQuoteInput({ adults: 1, kids: 0, days: 1, meals: "lunch" }).meals).toBe(1);
    expect(toQuoteInput({ adults: 1, kids: 0, days: 1, meals: "dinner" }).meals).toBe(1);
  });

  it("pasa todos los vectores por defecto de quote_vectors.json", () => {
    const defaults = fixture.vectors.filter((v) => !("settings" in v));
    expect(defaults.length).toBeGreaterThan(0);
    for (const v of defaults) {
      const meals = v.input.meals === 2 ? "both" : "dinner";
      const quote = computeQuote({ adults: v.input.adults, kids: v.input.kids, days: v.input.days, meals });
      for (const [key, value] of Object.entries(v.expected)) {
        expect(quote?.[key as keyof typeof quote], `vector ${v.id} · ${key}`).toBe(value);
      }
    }
  });

  it("devuelve null (sin romper) si la entrada no es válida para el motor", () => {
    expect(computeQuote({ adults: 0, kids: 0, days: 5, meals: "dinner" })).toBeNull();
    expect(computeQuote({ adults: 2, kids: 0, days: 8, meals: "dinner" })).toBeNull();
    expect(computeQuote({ adults: Number.NaN, kids: 0, days: 1, meals: "dinner" })).toBeNull();
  });

  it("el ejemplo de la landing es el vector 1", () => {
    expect(exampleQuote().totalCents).toBe(14100);
  });
});
