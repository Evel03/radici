import { describe, expect, it, vi } from "vitest";
import * as engine from "../../../supabase/functions/_shared/quote.ts";
import fixture from "../../../supabase/functions/_shared/quote_vectors.json";
import { computeQuote, EXAMPLE_INPUT, exampleQuote, toQuoteInput } from "./quote.ts";

// Espía sobre el motor real: la calculadora tiene que delegar en calcQuote, no recalcular.
vi.mock("../../../supabase/functions/_shared/quote.ts", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../../supabase/functions/_shared/quote.ts")>();
  return { ...actual, calcQuote: vi.fn(actual.calcQuote) };
});

const VECTOR_1 = { type: "week", adults: 2, kids: 2, days: 5, meals: "dinner", weeks: 1 } as const;

describe("calculadora de la web", () => {
  it("usa calcQuote del motor compartido (vector 1 → 150 € de servicio, sin compra)", () => {
    vi.mocked(engine.calcQuote).mockClear();
    const quote = computeQuote(VECTOR_1);
    expect(engine.calcQuote).toHaveBeenCalledTimes(1);
    expect(engine.calcQuote).toHaveBeenCalledWith(
      { type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 1 },
      engine.DEFAULT_PRICING,
    );
    expect(quote?.autoPrice && quote.serviceCents).toBe(15000);
    expect(quote?.cookMinutes).toBe(180);
    // La compra la hace el cliente (19/11/2026): ni su estimación ni un total con ella.
    expect(quote).not.toHaveProperty("groceriesEstCents");
    expect(quote).not.toHaveProperty("totalCents");
  });

  it("'pranzo e cena' son 2 comidas por día; 'pranzo' o 'cena', 1", () => {
    expect(toQuoteInput({ ...VECTOR_1, meals: "both" }).meals).toBe(2);
    expect(toQuoteInput({ ...VECTOR_1, meals: "lunch" }).meals).toBe(1);
    expect(toQuoteInput({ ...VECTOR_1, meals: "dinner" }).meals).toBe(1);
  });

  it("las semanas valen para la semana de comidas; una sesión extra es de una, aunque el selector diga otra", () => {
    expect(toQuoteInput({ ...VECTOR_1, weeks: 4 }).weeks).toBe(4);
    expect(toQuoteInput({ ...VECTOR_1, type: "extra", weeks: 4 })).toMatchObject({ type: "extra", weeks: 1 });
    expect(computeQuote({ ...VECTOR_1, type: "extra", weeks: 4 })).toMatchObject({ autoPrice: false, reason: "extra" });
  });

  it("pasa todos los vectores por defecto de quote_vectors.json", () => {
    const defaults = fixture.vectors.filter((v) => !("settings" in v));
    expect(defaults.length).toBeGreaterThan(0);
    for (const v of defaults) {
      const meals = v.input.meals === 2 ? "both" : "dinner";
      const type = v.input.type === "extra" ? "extra" : "week";
      const quote = computeQuote({ type, adults: v.input.adults, kids: v.input.kids, days: v.input.days, meals, weeks: v.input.weeks });
      for (const [key, value] of Object.entries(v.expected)) {
        expect(quote?.[key as keyof typeof quote], `vector ${v.id} · ${key}`).toBe(value);
      }
    }
  });

  it("devuelve null (sin romper) si la entrada no es válida para el motor", () => {
    expect(computeQuote({ ...VECTOR_1, adults: 0, kids: 0 })).toBeNull();
    expect(computeQuote({ ...VECTOR_1, days: 8 })).toBeNull();
    expect(computeQuote({ ...VECTOR_1, adults: Number.NaN })).toBeNull();
    expect(computeQuote({ ...VECTOR_1, weeks: 9 })).toBeNull();
  });

  it("el ejemplo de la portada es el vector 3: 4 semanas a 140 €, sin compra", () => {
    expect(EXAMPLE_INPUT.weeks).toBe(4);
    const example = exampleQuote();
    expect(example.weeklyServiceCents).toBe(14000);
    expect(example.serviceCents).toBe(56000);
    expect(example.savingsCents).toBe(4000);
    expect(example).not.toHaveProperty("groceriesEstCents");
  });
});
