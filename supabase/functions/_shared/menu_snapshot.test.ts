// Tests de la foto del envío del menú (menu_snapshot.ts, contrato chef-api.md §13). Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  INGREDIENT_UNITS,
  MENU_LIMITS,
  MENU_SNAPSHOT_VERSION,
  SHOPPING_SECTIONS,
  readAllergenList,
  readMenuItem,
  readMenuSnapshot,
  type MenuSnapshot,
} from "./menu_snapshot.ts";

const PHOTO = {
  thumb: "https://abc.supabase.co/storage/v1/object/public/recipe-photos/a/b/c-thumb.jpg",
  full: "https://abc.supabase.co/storage/v1/object/public/recipe-photos/a/b/c.jpg",
};

function snapshot(): MenuSnapshot {
  return {
    v: 1,
    locale: "it",
    session: { date: "2026-11-30", start: "10:00", week: 1, weeks: 2 },
    weeks: [
      { date: "2026-11-30", start: "10:00" },
      { date: "2026-12-07", start: "10:00" },
    ],
    dishes: [
      { name: "Lasagne", description: "Al ragù.", allergens: ["gluten", "eggs", "milk"], diet: null, portions: 6, photo: PHOTO },
      { name: "Minestrone", description: null, allergens: [], diet: "vegan", portions: 4, photo: null },
    ],
    items: [
      { name: "Zucchine", section: "produce", quantity: 1250, unit: "g" },
      { name: "Sale", section: "pantry", quantity: null, unit: null },
    ],
    note: "Tieni pronti 4 contenitori.\nGrazie!",
  };
}

test("constantes: versión 1, las secciones y unidades de la base, los topes de las tablas", () => {
  assert.equal(MENU_SNAPSHOT_VERSION, 1);
  assert.deepEqual([...SHOPPING_SECTIONS], ["produce", "meat_fish", "dairy_eggs", "bakery", "pantry", "frozen", "other"], "el orden del enum");
  assert.deepEqual([...INGREDIENT_UNITS], ["g", "ml", "pcs"]);
  assert.deepEqual(MENU_LIMITS, { maxPortions: 500, maxQuantity: 1_000_000, itemNameMax: 80, noteMax: 1000 });
});

test("readMenuSnapshot: una foto válida vuelve igual, armada de nuevo", () => {
  const value = snapshot();
  const read = readMenuSnapshot(JSON.parse(JSON.stringify(value)));
  assert.deepEqual(read, value);
  assert.notEqual(read, value);
});

test("readMenuSnapshot: lo que la foto traiga de más no sale (dirección, alergias, contacto, precios)", () => {
  const raw = {
    ...snapshot(),
    address: "Via Segretissima 42",
    restrictions: "celiachia",
    contact: { email: "maria@example.test" },
    priceCents: 14000,
    dishes: [{ ...snapshot().dishes[0], ingredients: ["segreto"], notes: "nota interna" }],
    items: [{ ...snapshot().items[0], position: 1 }],
    session: { ...snapshot().session, status: "confirmed", requestId: "x" },
  };
  const read = readMenuSnapshot(raw);
  assert.ok(read);
  const text = JSON.stringify(read);
  for (const marker of ["Segretissima", "celiachia", "maria@", "14000", "segreto", "nota interna", "position", "confirmed"]) {
    assert.ok(!text.includes(marker), marker);
  }
});

test("readMenuSnapshot: otra versión, otro idioma o una forma rota → null", () => {
  const broken: Array<[string, unknown]> = [
    ["otra versión", { ...snapshot(), v: 2 }],
    ["sin versión", { ...snapshot(), v: undefined }],
    ["otro idioma", { ...snapshot(), locale: "fr" }],
    ["sin platos", { ...snapshot(), dishes: [] }],
    ["un plato sin nombre", { ...snapshot(), dishes: [{ ...snapshot().dishes[0], name: " " }] }],
    ["descripción vacía", { ...snapshot(), dishes: [{ ...snapshot().dishes[0], description: "" }] }],
    ["un alérgeno desconocido", { ...snapshot(), dishes: [{ ...snapshot().dishes[0], allergens: ["nichel"] }] }],
    ["otra dieta", { ...snapshot(), dishes: [{ ...snapshot().dishes[0], diet: "keto" }] }],
    ["0 porciones", { ...snapshot(), dishes: [{ ...snapshot().dishes[0], portions: 0 }] }],
    ["porciones de más", { ...snapshot(), dishes: [{ ...snapshot().dishes[0], portions: 501 }] }],
    ["foto que no es http", { ...snapshot(), dishes: [{ ...snapshot().dishes[0], photo: { thumb: "javascript:alert(1)", full: PHOTO.full } }] }],
    ["otra sección", { ...snapshot(), items: [{ name: "Pane", section: "deli", quantity: 1, unit: "pcs" }] }],
    ["cantidad sin unidad", { ...snapshot(), items: [{ name: "Pane", section: "bakery", quantity: 1, unit: null }] }],
    ["unidad sin cantidad", { ...snapshot(), items: [{ name: "Pane", section: "bakery", quantity: null, unit: "pcs" }] }],
    ["cantidad con decimales", { ...snapshot(), items: [{ name: "Pane", section: "bakery", quantity: 1.5, unit: "pcs" }] }],
    ["nota vacía", { ...snapshot(), note: "  " }],
    ["semana mayor que el total", { ...snapshot(), session: { ...snapshot().session, week: 3 } }],
    ["hora rota", { ...snapshot(), session: { ...snapshot().session, start: "25:00" } }],
    ["fecha rota en las semanas", { ...snapshot(), weeks: [{ date: "2026-02-30", start: "10:00" }] }],
    ["no es un objeto", [snapshot()]],
  ];
  for (const [name, value] of broken) {
    assert.equal(readMenuSnapshot(value), null, name);
  }
});

test("readMenuSnapshot: el envío de la semana 1 de un presupuesto lleva el presupuesto; sin él, como siempre", () => {
  const quote = {
    version: 2,
    totalCents: 28000,
    weeks: [
      { date: "2026-11-30", start: "10:00", serviceCents: 14000 },
      { date: "2026-12-07", start: "10:00", serviceCents: 14000 },
    ],
    holdHours: 48,
    firstStart: "2026-11-30T10:00",
  };
  const withQuote = { ...snapshot(), quote };
  assert.deepEqual(readMenuSnapshot(JSON.parse(JSON.stringify(withQuote))), withQuote);
  // Sin presupuesto (o con null) no aparece la clave: la foto de siempre.
  assert.equal("quote" in (readMenuSnapshot(snapshot()) ?? {}), false);
  assert.equal("quote" in (readMenuSnapshot({ ...snapshot(), quote: null }) ?? {}), false);
  // Un presupuesto que no cierra no se manda a medias: la foto entera no vale.
  assert.equal(readMenuSnapshot({ ...snapshot(), quote: { ...quote, totalCents: 1 } }), null);
  assert.equal(readMenuSnapshot({ ...snapshot(), quote: "560 €" }), null);
});

test("readAllergenList: sin repetir y en el orden del enum; uno desconocido, null", () => {
  assert.deepEqual(readAllergenList(["milk", "gluten", "milk"]), ["gluten", "milk"]);
  assert.deepEqual(readAllergenList([]), []);
  assert.equal(readAllergenList(["gluten", "nichel"]), null);
  assert.equal(readAllergenList("gluten"), null);
});

test("readMenuItem: la forma de session_shopping_items (q.b. sin cantidad ni unidad)", () => {
  assert.deepEqual(readMenuItem({ name: "Olio", section: "pantry", quantity: null, unit: null }), {
    name: "Olio",
    section: "pantry",
    quantity: null,
    unit: null,
  });
  assert.deepEqual(readMenuItem({ name: "Latte", section: "dairy_eggs", quantity: 1000, unit: "ml", position: 4 }), {
    name: "Latte",
    section: "dairy_eggs",
    quantity: 1000,
    unit: "ml",
  });
  assert.equal(readMenuItem({ name: "Latte", section: "dairy_eggs", quantity: 1_000_001, unit: "ml" }), null);
  assert.equal(readMenuItem({ name: "", section: "dairy_eggs", quantity: null, unit: null }), null);
});
