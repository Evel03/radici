// Tests del motor de presupuesto. Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { calcQuote, DEFAULT_PRICING, LIMITS, type PricingSettings, type Quote, type QuoteInput } from "./quote.ts";

interface Fixture {
  defaultSettings: PricingSettings;
  vectors: Array<{
    id: number;
    label: string;
    settings?: Partial<PricingSettings>;
    input: QuoteInput;
    expected: Record<string, number | boolean | string>;
  }>;
  invalid: Array<{ label: string; input: QuoteInput }>;
  invalidSettings: Array<{ label: string; settings: Partial<PricingSettings> }>;
  /** El mínimo y el máximo de cada check de las columnas de chef_settings que lee el motor: los dos motores calculan con cualquiera. */
  validSettings: Array<{ label: string; settings: Partial<PricingSettings> }>;
}

const fixture: Fixture = JSON.parse(
  readFileSync(new URL("./quote_vectors.json", import.meta.url), "utf8"),
);

/** Lo que solo existe con precio automático. */
const PRICE_KEYS = ["weeklyServiceCents", "serviceCents", "savingsCents"] as const;

/** Lo de la compra, que desde el 19/11/2026 hace el cliente: el motor ya no lo calcula. */
const GROCERY_KEYS = ["groceriesEstCents", "preauthCents", "totalCents"] as const;

test("los valores por defecto coinciden con el fixture", () => {
  assert.deepEqual(DEFAULT_PRICING, fixture.defaultSettings);
});

for (const v of fixture.vectors) {
  test(`vector ${v.id}: ${v.label}`, () => {
    const q = calcQuote(v.input, { ...fixture.defaultSettings, ...v.settings });
    for (const [key, value] of Object.entries(v.expected)) {
      assert.equal(q[key as keyof Quote], value, key);
    }
    // Sin precio automático las claves del precio no van (ni null ni 0): así se guardan y se responden.
    if (!q.autoPrice) for (const key of PRICE_KEYS) assert.ok(!(key in q), `sin precio no lleva ${key}`);
    else for (const key of PRICE_KEYS) assert.ok(key in v.expected, `el vector ${v.id} fija ${key}`);
    for (const key of GROCERY_KEYS) {
      assert.ok(!(key in q), `la compra la hace el cliente: no hay ${key}`);
      assert.ok(!(key in v.expected), `el vector ${v.id} no fija ${key}`);
    }
  });
}

test("los vectores cubren 1, 3, 4, 5 y 8 semanas, 5 y 6 personas y una sesión extra", () => {
  const weeks = new Set(fixture.vectors.filter((v) => !v.settings).map((v) => v.input.weeks));
  for (const n of [1, 3, 4, 5, 8]) assert.ok(weeks.has(n), `${n} semanas`);
  const people = (v: Fixture["vectors"][number]): number => v.input.adults + v.input.kids;
  assert.ok(fixture.vectors.some((v) => !v.settings && v.input.type === "week" && people(v) === 5 && v.expected["autoPrice"] === true));
  assert.ok(fixture.vectors.some((v) => !v.settings && v.input.type === "week" && people(v) === 6 && v.expected["autoPrice"] === false));
  assert.ok(fixture.vectors.some((v) => v.input.type === "extra" && v.expected["reason"] === "extra"));
  // Sin precio, las semanas del pedido quedan en la estimación: lo fija la tabla compartida (también para Dart).
  assert.ok(fixture.vectors.some((v) => v.expected["autoPrice"] === false && v.input.weeks > 1 && v.expected["weeks"] === v.input.weeks));
});

for (const c of fixture.invalid) {
  test(`entrada inválida: ${c.label}`, () => {
    assert.throws(() => calcQuote(c.input), RangeError);
  });
}

for (const c of fixture.invalidSettings) {
  test(`tarifas inválidas: ${c.label}`, () => {
    const input: QuoteInput = { type: "week", adults: 2, kids: 0, days: 1, meals: 1, weeks: 1 };
    assert.throws(() => calcQuote(input, { ...DEFAULT_PRICING, ...c.settings }), RangeError);
  });
}

/** Entradas con que se prueban las tarifas válidas: la de siempre, la más chica, la más grande y una extra. */
const VALID_SETTINGS_INPUTS: readonly QuoteInput[] = [
  { type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 4 },
  { type: "week", adults: 1, kids: 0, days: 1, meals: 1, weeks: 1 },
  { type: "week", adults: LIMITS.maxPeople, kids: LIMITS.maxPeople, days: LIMITS.maxDays, meals: LIMITS.maxMeals, weeks: LIMITS.maxWeeks },
  { type: "extra", adults: 2, kids: 0, days: 1, meals: 1, weeks: 1 },
];

for (const c of fixture.validSettings) {
  test(`tarifas válidas (un extremo de chef_settings): ${c.label}`, () => {
    const settings: PricingSettings = { ...DEFAULT_PRICING, ...c.settings };
    for (const input of VALID_SETTINGS_INPUTS) {
      const q = calcQuote(input, settings);
      assert.equal(q.autoPrice, input.type === "week" && input.adults + input.kids <= settings.weeklyRateMaxPeople, JSON.stringify(input));
    }
  });
}

test("reglas del precio por semana: los días y las comidas no cambian el servicio; el descuento, desde 4 semanas", () => {
  const priced = (input: Partial<QuoteInput>): Quote & { autoPrice: true } => {
    const q = calcQuote({ type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 1, ...input });
    assert.ok(q.autoPrice, JSON.stringify(input));
    return q;
  };
  for (const days of [1, 4, 7]) {
    for (const meals of [1, 2]) assert.equal(priced({ days, meals }).weeklyServiceCents, DEFAULT_PRICING.weeklyRateCents);
  }
  for (let weeks = 1; weeks <= LIMITS.maxWeeks; weeks++) {
    const q = priced({ weeks });
    const rate = weeks >= DEFAULT_PRICING.weeklyDiscountMinWeeks ? DEFAULT_PRICING.weeklyRateDiscountedCents : DEFAULT_PRICING.weeklyRateCents;
    assert.equal(q.weeklyServiceCents, rate, `${weeks} semanas`);
    assert.equal(q.serviceCents, rate * weeks);
    // El ahorro es frente a la tarifa sin descuento por cada semana: 0 con 1 a 3 semanas.
    assert.equal(q.savingsCents, DEFAULT_PRICING.weeklyRateCents * weeks - q.serviceCents);
    assert.equal(q.savingsCents > 0, weeks >= 4);
  }
  // 560 € por 4 semanas: lo dice la decisión del dueño.
  assert.equal(priced({ weeks: 4 }).serviceCents, 56000);
});

test("más de 5 personas (adultos y niños) o una sesión extra: sin precio automático, con porciones y minutos", () => {
  const people = calcQuote({ type: "week", adults: 5, kids: 1, days: 5, meals: 1, weeks: 4 });
  assert.equal(people.autoPrice, false);
  assert.equal(people.autoPrice === false && people.reason, "people");
  assert.equal(people.portions, 6 * 5);
  assert.equal(people.weeks, 4, "las semanas del pedido quedan en la estimación");
  const extra = calcQuote({ type: "extra", adults: 2, kids: 0, days: 1, meals: 1, weeks: 1 });
  assert.equal(extra.autoPrice === false && extra.reason, "extra");
  // Una extra con más de 5 personas dice extra: la sesión extra nunca tiene precio automático.
  const bigExtra = calcQuote({ type: "extra", adults: 10, kids: 0, days: 1, meals: 1, weeks: 1 });
  assert.equal(bigExtra.autoPrice === false && bigExtra.reason, "extra");
});

test("todos los importes son enteros en todo el rango de entradas", () => {
  const settingsList: PricingSettings[] = [
    DEFAULT_PRICING,
    { ...DEFAULT_PRICING, weeklyRateCents: 16000, weeklyRateDiscountedCents: 15000, weeklyDiscountMinWeeks: 3, weeklyRateMaxPeople: 6 },
    { ...DEFAULT_PRICING, weeklyRateCents: 14999, weeklyRateDiscountedCents: 13333, weeklyDiscountMinWeeks: 1, weeklyRateMaxPeople: 60 },
  ];
  for (const settings of settingsList) {
    for (let adults = 0; adults <= 8; adults++) {
      for (let kids = 0; kids <= 6; kids++) {
        if (adults + kids === 0) continue;
        for (let days = 1; days <= 7; days++) {
          for (let meals = 1; meals <= 2; meals++) {
            for (let weeks = 1; weeks <= LIMITS.maxWeeks; weeks++) {
              const q = calcQuote({ type: "week", adults, kids, days, meals, weeks }, settings);
              for (const value of Object.values(q)) {
                if (typeof value === "number") assert.ok(Number.isInteger(value) && value >= 0);
              }
              assert.equal(q.cookMinutes % 30, 0);
              assert.ok(q.recipes >= 2 && q.recipes <= 6);
              assert.equal(q.portions, q.adultPortions + q.kidPortions);
              assert.equal(q.autoPrice, adults + kids <= settings.weeklyRateMaxPeople);
              if (q.autoPrice) assert.equal(q.serviceCents, q.weeklyServiceCents * weeks);
            }
          }
        }
      }
    }
  }
});

// ---------------------------------------------------------------------------
// El motor y la base: los valores por defecto y los rangos de chef_settings
// ---------------------------------------------------------------------------

/** Columna de chef_settings de cada tarifa del motor (las que lee public-request). */
const COLUMNS: Readonly<Record<keyof PricingSettings, string>> = {
  weeklyRateCents: "weekly_rate_cents",
  weeklyRateDiscountedCents: "weekly_rate_discounted_cents",
  weeklyDiscountMinWeeks: "weekly_discount_min_weeks",
  weeklyRateMaxPeople: "weekly_rate_max_people",
  minCookMinutes: "min_cook_minutes",
};

const MIGRATIONS = new URL("../../migrations/", import.meta.url);

/** Las migraciones en orden, sin los comentarios de SQL. */
function migrations(): Array<{ file: string; sql: string }> {
  return readdirSync(MIGRATIONS)
    .filter((name) => name.endsWith(".sql"))
    .sort()
    .map((file) => ({ file, sql: readFileSync(new URL(file, MIGRATIONS), "utf8").replace(/--.*$/gm, "") }));
}

test("DEFAULT_PRICING es el valor por defecto de chef_settings: la web calcula lo mismo que la base para una cocinera nueva", () => {
  // La web muestra el precio con DEFAULT_PRICING y el servidor lo guarda con chef_settings: si se separan,
  // el formulario promete un precio y se guarda otro. El último valor por defecto de cada columna manda
  // (create table, add column o alter column … set default).
  for (const [key, column] of Object.entries(COLUMNS) as Array<[keyof PricingSettings, string]>) {
    const pattern = new RegExp(`\\b${column}\\s+int\\s+not\\s+null\\s+default\\s+(\\d+)|alter\\s+column\\s+${column}\\s+set\\s+default\\s+(\\d+)`, "gi");
    let last: { file: string; value: number } | null = null;
    for (const { file, sql } of migrations()) {
      for (const match of sql.matchAll(pattern)) last = { file, value: Number(match[1] ?? match[2]) };
    }
    assert.ok(last, `no se encontró el valor por defecto de chef_settings.${column}`);
    assert.equal(DEFAULT_PRICING[key], last.value, `${key} y ${column} (${last.file})`);
  }
});

let allMigrations: string | null = null;

/**
 * Lo que el check de la columna deja guardar: [mínimo, máximo]. El motor tiene un máximo para cada
 * tarifa: una columna sin tope en la base (solo `>=`) guardaría valores con los que cada pedido da
 * quote_failed, así que falla.
 */
function checkBounds(column: string): [number, number] {
  const between = new RegExp(`check\\s*\\(\\s*${column}\\s+between\\s+(\\d+)\\s+and\\s+(\\d+)\\s*\\)`, "i");
  allMigrations ??= migrations().map((m) => m.sql).join("\n");
  const range = between.exec(allMigrations);
  assert.ok(range, `chef_settings.${column} sin check con mínimo y máximo (between): la base guardaría valores que el motor rechaza`);
  return [Number(range[1]), Number(range[2])];
}

test("el motor acepta todo lo que la base guarda en chef_settings: ninguna fila válida da quote_failed", () => {
  const input: QuoteInput = { type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 4 };
  for (const [key, column] of Object.entries(COLUMNS) as Array<[keyof PricingSettings, string]>) {
    for (const value of checkBounds(column)) {
      const settings: PricingSettings = { ...DEFAULT_PRICING, [key]: value };
      // El check chef_settings_descuento_no_supera_tarifa: la tarifa con descuento nunca supera a la normal.
      if (key === "weeklyRateDiscountedCents") settings.weeklyRateCents = Math.max(settings.weeklyRateCents, value);
      if (key === "weeklyRateCents") settings.weeklyRateDiscountedCents = Math.min(settings.weeklyRateDiscountedCents, value);
      assert.doesNotThrow(() => calcQuote(input, settings), `${column} = ${value}`);
    }
  }
  // Las semanas que se pueden pedir son las de requests_semanas_validas (1 a 8).
  assert.match(migrations().map((m) => m.sql).join("\n"), new RegExp(`check\\s*\\(\\s*weeks\\s+between\\s+1\\s+and\\s+${LIMITS.maxWeeks}\\s*\\)`, "i"));
});

test("validSettings de quote_vectors.json tiene el mínimo y el máximo de cada check de las columnas de chef_settings que lee el motor (la copia Dart los recorre)", () => {
  // La copia Dart no lee las migraciones: recorre esta lista. Si un check cambia, la lista tiene que cambiar.
  for (const [key, column] of Object.entries(COLUMNS) as Array<[keyof PricingSettings, string]>) {
    for (const value of checkBounds(column)) {
      assert.ok(
        fixture.validSettings.some((c) => c.settings[key] === value),
        `validSettings no tiene ${key} = ${value} (check de chef_settings.${column})`,
      );
    }
  }
  // Y cada caso es una fila que la base guarda: la tarifa con descuento nunca supera a la normal.
  for (const c of fixture.validSettings) {
    const settings: PricingSettings = { ...DEFAULT_PRICING, ...c.settings };
    assert.ok(settings.weeklyRateDiscountedCents <= settings.weeklyRateCents, c.label);
    for (const [key, column] of Object.entries(COLUMNS) as Array<[keyof PricingSettings, string]>) {
      const [min, max] = checkBounds(column);
      assert.ok(settings[key] >= min && settings[key] <= max, `${c.label}: ${key}`);
    }
  }
});
