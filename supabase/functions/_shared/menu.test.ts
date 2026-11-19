// Tests del contrato del menù de la web (GET …/menu y el `menu` del 201). Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  MENU_PATH,
  MENU_VERSION,
  buildMenuResponse,
  dishInSeason,
  localizedText,
  menuDishesFromRpc,
  parseMenuResponse,
  readMenuChoices,
  readMenuDish,
  type MenuDish,
} from "./menu.ts";

const LASAGNE_ID = "0a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";
const MINESTRONE_ID = "1a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";

/** Como lo devuelve get_public_menu (contrato §12). */
const LASAGNE = {
  id: LASAGNE_ID,
  name: { it: "Lasagne", es: "Lasaña", en: null },
  description: { it: "Ragù, besciamella e sfoglia fatta in casa.", es: null, en: null },
  allergens: ["gluten", "eggs", "milk"],
  diet: null,
  seasonMonths: [10, 11, 12],
};

const MINESTRONE = {
  id: MINESTRONE_ID,
  name: { it: "Minestrone", es: null, en: "Minestrone soup" },
  description: { it: "Verdure di stagione.", es: "Verduras de temporada.", en: "Seasonal vegetables." },
  allergens: ["celery"],
  diet: "vegan",
  seasonMonths: null,
};

test("ruta y versión de la respuesta", () => {
  assert.equal(MENU_PATH, "/menu");
  assert.equal(MENU_VERSION, 1);
});

test("get_public_menu: los platos tal como los manda la base, en su orden", () => {
  assert.deepEqual(menuDishesFromRpc([LASAGNE, MINESTRONE]), { dishes: [LASAGNE, MINESTRONE], skipped: 0 });
  assert.deepEqual(menuDishesFromRpc([]), { dishes: [], skipped: 0 }, "sin platos publicados: un array vacío");
});

test("un plato se arma solo con las claves del contrato: nunca ingredientes ni notas", () => {
  const dish = readMenuDish({ ...LASAGNE, ingredients: [{ name: "farina" }], notes: "NOTA-PRIVADA", active: true });
  assert.deepEqual(Object.keys(dish ?? {}).sort(), ["allergens", "description", "diet", "id", "name", "seasonMonths"]);
  assert.ok(!JSON.stringify(dish).includes("NOTA-PRIVADA"));
});

test("normaliza: id en minúsculas, alérgenos en el orden del enum, meses de menor a mayor, \"\" como null", () => {
  const dish = readMenuDish({
    ...LASAGNE,
    id: LASAGNE_ID.toUpperCase(),
    name: { it: "Lasagne", es: "", en: undefined },
    allergens: ["milk", "gluten"],
    seasonMonths: [12, 1, 2],
  });
  assert.equal(dish?.id, LASAGNE_ID);
  assert.deepEqual(dish?.name, { it: "Lasagne", es: null, en: null });
  assert.deepEqual(dish?.allergens, ["gluten", "milk"]);
  assert.deepEqual(dish?.seasonMonths, [1, 2, 12]);
  assert.equal(readMenuDish({ ...LASAGNE, diet: undefined, seasonMonths: undefined })?.diet, null);
});

test("cualquier plato con otra forma: null (y la lista entera también)", () => {
  const bad: unknown[] = [
    null,
    "Lasagne",
    { ...LASAGNE, id: "no-es-uuid" },
    { ...LASAGNE, id: 5 },
    { ...LASAGNE, name: { it: "", es: null, en: null } },
    { ...LASAGNE, name: { es: "Lasaña" } },
    { ...LASAGNE, name: { it: "Lasagne", es: 5, en: null } },
    { ...LASAGNE, description: null },
    { ...LASAGNE, description: { it: null, es: "Lasaña", en: null } },
    { ...LASAGNE, allergens: ["gluten", "kiwi"] },
    { ...LASAGNE, allergens: ["gluten", "gluten"] },
    { ...LASAGNE, allergens: null },
    { ...LASAGNE, diet: "pescatarian" },
    { ...LASAGNE, seasonMonths: [] },
    { ...LASAGNE, seasonMonths: [0, 1] },
    { ...LASAGNE, seasonMonths: [13] },
    { ...LASAGNE, seasonMonths: [1.5] },
    { ...LASAGNE, seasonMonths: [3, 3] },
    { ...LASAGNE, seasonMonths: "10" },
  ];
  for (const value of bad) {
    assert.equal(readMenuDish(value), null, JSON.stringify(value));
    // Un plato roto se saltea: no apaga el menú de los demás.
    assert.deepEqual(menuDishesFromRpc([MINESTRONE, value]), { dishes: [MINESTRONE], skipped: 1 }, `lista con ${JSON.stringify(value)}`);
  }
  for (const data of [null, {}, "x", { dishes: [] }]) assert.equal(menuDishesFromRpc(data), null, JSON.stringify(data));
  // Una traducción en blanco (también con el espacio duro, que la base deja pasar) es null: cae al italiano.
  for (const blank of ["", "   ", " ", "  "]) {
    const dish = readMenuDish({ ...LASAGNE, name: { ...LASAGNE.name, es: blank }, description: { ...LASAGNE.description, en: blank } });
    assert.equal(dish?.name.es, null, JSON.stringify(blank));
    assert.equal(dish?.description.en, null, JSON.stringify(blank));
  }
});

test("respuesta de GET …/menu: se arma y se lee con la misma forma; otra versión u otra forma, null", () => {
  const response = buildMenuResponse([LASAGNE, MINESTRONE] as MenuDish[]);
  assert.deepEqual(response, { version: 1, dishes: [LASAGNE, MINESTRONE] });
  assert.deepEqual(parseMenuResponse(JSON.parse(JSON.stringify(response))), response);
  assert.deepEqual(parseMenuResponse({ version: 1, dishes: [] }), { version: 1, dishes: [] });
  for (const json of [null, [], { version: 2, dishes: [] }, { dishes: [] }, { version: 1 }, { version: 1, dishes: [{ ...LASAGNE, diet: "x" }] }, { error: "unavailable" }]) {
    assert.equal(parseMenuResponse(json), null, JSON.stringify(json));
  }
});

test("platos elegidos del 201 (y de submit_public_request): [{ id, name }] en orden; otra forma, null", () => {
  const choices = [{ id: MINESTRONE_ID, name: MINESTRONE.name }, { id: LASAGNE_ID.toUpperCase(), name: LASAGNE.name }];
  assert.deepEqual(readMenuChoices(choices), [
    { id: MINESTRONE_ID, name: MINESTRONE.name },
    { id: LASAGNE_ID, name: LASAGNE.name },
  ]);
  assert.deepEqual(readMenuChoices([]), []);
  // Solo id y nombre: lo demás no viaja en el 201.
  assert.deepEqual(readMenuChoices([LASAGNE]), [{ id: LASAGNE_ID, name: LASAGNE.name }]);
  for (const value of [null, undefined, {}, "x", [null], [{ id: LASAGNE_ID }], [{ id: "x", name: LASAGNE.name }]]) {
    assert.equal(readMenuChoices(value), null, JSON.stringify(value));
  }
});

test("nombre y descripción en el idioma pedido, con respaldo al italiano", () => {
  assert.equal(localizedText(LASAGNE.name, "es"), "Lasaña");
  assert.equal(localizedText(LASAGNE.name, "en"), "Lasagne");
  assert.equal(localizedText(LASAGNE.name, "it"), "Lasagne");
  assert.equal(localizedText(MINESTRONE.name, "en"), "Minestrone soup");
  assert.equal(localizedText(MINESTRONE.description, "es"), "Verduras de temporada.");
});

test("temporada: todo el año (null) o uno de sus meses", () => {
  assert.ok(dishInSeason({ seasonMonths: null }, 7));
  assert.ok(dishInSeason({ seasonMonths: [10, 11, 12] }, 11));
  assert.ok(!dishInSeason({ seasonMonths: [10, 11, 12] }, 1));
});
