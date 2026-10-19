// Tests del motor de presupuesto. Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { calcQuote, DEFAULT_PRICING, type PricingSettings, type QuoteInput } from "./quote.ts";

interface Fixture {
  defaultSettings: PricingSettings;
  vectors: Array<{
    id: number;
    label: string;
    settings?: Partial<PricingSettings>;
    input: QuoteInput;
    expected: Record<string, number>;
  }>;
  invalid: Array<{ label: string; input: QuoteInput }>;
}

const fixture: Fixture = JSON.parse(
  readFileSync(new URL("./quote_vectors.json", import.meta.url), "utf8"),
);

test("los valores por defecto coinciden con el fixture", () => {
  assert.deepEqual(DEFAULT_PRICING, fixture.defaultSettings);
});

for (const v of fixture.vectors) {
  test(`vector ${v.id}: ${v.label}`, () => {
    const q = calcQuote(v.input, { ...fixture.defaultSettings, ...v.settings });
    for (const [key, value] of Object.entries(v.expected)) {
      assert.equal(q[key as keyof typeof q], value, key);
    }
  });
}

for (const c of fixture.invalid) {
  test(`entrada inválida: ${c.label}`, () => {
    assert.throws(() => calcQuote(c.input), RangeError);
  });
}

test("todos los importes son enteros en todo el rango de entradas", () => {
  for (const hourlyRateCents of [2200, 2155, 1999, 2501]) {
    const settings = { ...DEFAULT_PRICING, hourlyRateCents };
    for (let adults = 0; adults <= 12; adults++) {
      for (let kids = 0; kids <= 8; kids++) {
        if (adults + kids === 0) continue;
        for (let days = 1; days <= 7; days++) {
          for (let meals = 1; meals <= 2; meals++) {
            const q = calcQuote({ adults, kids, days, meals }, settings);
            for (const value of Object.values(q)) assert.ok(Number.isInteger(value));
            assert.equal(q.cookMinutes % 30, 0);
            assert.ok(q.recipes >= 2 && q.recipes <= 6);
            assert.ok(q.preauthCents >= q.groceriesEstCents);
          }
        }
      }
    }
  }
});
