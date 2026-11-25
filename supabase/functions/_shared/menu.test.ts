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
  photoOrigin,
  readMenuChoices,
  readMenuDish,
  recipePhotoUrls,
  RECIPE_PHOTOS_BUCKET,
  type MenuDish,
} from "./menu.ts";

const LASAGNE_ID = "0a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";
const MINESTRONE_ID = "1a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";
const CHEF_ID = "7e651000-0000-4000-8000-000000000001";
const PHOTO_ID = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f";
const ORIGIN = "https://abcdefgh.supabase.co";
/** Lo que necesita menuDishesFromRpc para armar las URL (index.ts: SUPABASE_URL y la cocinera). */
const PHOTOS = { origin: ORIGIN, chefId: CHEF_ID };

/** Como lo devuelve get_public_menu (contrato §12.1). */
const LASAGNE_ROW = {
  id: LASAGNE_ID,
  name: { it: "Lasagne", es: "Lasaña", en: null },
  description: { it: "Ragù, besciamella e sfoglia fatta in casa.", es: null, en: null },
  allergens: ["gluten", "eggs", "milk"],
  diet: null,
  seasonMonths: [10, 11, 12],
  photoId: PHOTO_ID,
  ingredients: ["Carne de res", "Pasta all'uovo", "Leche"],
};

const MINESTRONE_ROW = {
  id: MINESTRONE_ID,
  name: { it: "Minestrone", es: null, en: "Minestrone soup" },
  description: { it: "Verdure di stagione.", es: "Verduras de temporada.", en: "Seasonal vegetables." },
  allergens: ["celery"],
  diet: "vegan",
  seasonMonths: null,
  photoId: null,
  ingredients: [],
};

const LASAGNE_PHOTO = {
  thumb: `${ORIGIN}/storage/v1/object/public/recipe-photos/${CHEF_ID}/${LASAGNE_ID}/${PHOTO_ID}-thumb.jpg`,
  full: `${ORIGIN}/storage/v1/object/public/recipe-photos/${CHEF_ID}/${LASAGNE_ID}/${PHOTO_ID}.jpg`,
};

/** Como sale en GET …/menu (contrato §12): la foto con sus dos URL, o null. */
const { photoId: _lasagnePhotoId, ...LASAGNE_BASE } = LASAGNE_ROW;
const { photoId: _minestronePhotoId, ...MINESTRONE_BASE } = MINESTRONE_ROW;
const LASAGNE = { ...LASAGNE_BASE, photo: LASAGNE_PHOTO };
const MINESTRONE = { ...MINESTRONE_BASE, photo: null };

test("ruta y versión de la respuesta", () => {
  assert.equal(MENU_PATH, "/menu");
  assert.equal(MENU_VERSION, 1);
});

test("get_public_menu: los platos tal como los manda la base, en su orden, con las URL de la foto", () => {
  assert.deepEqual(menuDishesFromRpc([LASAGNE_ROW, MINESTRONE_ROW], PHOTOS), { dishes: [LASAGNE, MINESTRONE], skipped: 0 });
  assert.deepEqual(menuDishesFromRpc([], PHOTOS), { dishes: [], skipped: 0 }, "sin platos publicados: un array vacío");
});

test("un plato se arma solo con las claves del contrato: nunca cantidades, unidades, secciones ni notas", () => {
  const row = { ...LASAGNE_ROW, quantity: 400, unit: "g", section: "pantry", notes: "NOTA-PRIVADA", active: true };
  const fromRpc = menuDishesFromRpc([row], PHOTOS)?.dishes[0];
  const fromResponse = readMenuDish({ ...LASAGNE, quantity: 400, notes: "NOTA-PRIVADA" }, ORIGIN);
  for (const dish of [fromRpc, fromResponse]) {
    assert.deepEqual(Object.keys(dish ?? {}).sort(), ["allergens", "description", "diet", "id", "ingredients", "name", "photo", "seasonMonths"]);
    assert.ok(!JSON.stringify(dish).includes("NOTA-PRIVADA"));
  }
  assert.ok(!("photoId" in (fromRpc ?? {})), "el photoId de la base no sale tal cual: sale la foto con sus URL");
});

test("fotos: las URL públicas del bucket recipe-photos, en minúsculas como las rutas de la base", () => {
  assert.equal(RECIPE_PHOTOS_BUCKET, "recipe-photos");
  assert.deepEqual(recipePhotoUrls(ORIGIN, CHEF_ID, LASAGNE_ID, PHOTO_ID), LASAGNE_PHOTO);
  assert.deepEqual(recipePhotoUrls(ORIGIN, CHEF_ID.toUpperCase(), LASAGNE_ID.toUpperCase(), PHOTO_ID.toUpperCase()), LASAGNE_PHOTO);
});

test("fotos: el origen de Supabase, https (o http solo en la máquina local); si no, sin fotos", () => {
  assert.equal(photoOrigin(" https://abcdefgh.supabase.co/ "), ORIGIN);
  assert.equal(photoOrigin("https://abcdefgh.supabase.co/functions/v1"), ORIGIN);
  assert.equal(photoOrigin("http://127.0.0.1:54321"), "http://127.0.0.1:54321");
  assert.equal(photoOrigin("http://localhost:54321/"), "http://localhost:54321");
  // supabase functions serve: SUPABASE_URL es la dirección interna de Docker, que el navegador no abre.
  for (const raw of ["http://kong:8000", "http://abcdefgh.supabase.co", "ftp://x.supabase.co", "no es una url", "", null, undefined]) {
    assert.equal(photoOrigin(raw), null, String(raw));
  }
});

test("fotos desde get_public_menu: sin photoId (la base de antes), uno roto o sin origen, el plato sale sin foto", () => {
  const { photoId: _, ...withoutPhotoId } = LASAGNE_ROW;
  const noPhoto = { ...LASAGNE, photo: null };
  for (const row of [withoutPhotoId, { ...LASAGNE_ROW, photoId: "no-es-uuid" }, { ...LASAGNE_ROW, photoId: 5 }]) {
    assert.deepEqual(menuDishesFromRpc([row], PHOTOS), { dishes: [noPhoto], skipped: 0 }, JSON.stringify(row));
  }
  assert.deepEqual(menuDishesFromRpc([LASAGNE_ROW], { origin: null, chefId: CHEF_ID }), { dishes: [noPhoto], skipped: 0 });
  // Solo cuenta photoId: una photo que mandara la base no se copia.
  const sneaky = { ...LASAGNE_ROW, photoId: null, photo: { thumb: "https://evil.example/x.jpg", full: "https://evil.example/y.jpg" } };
  assert.deepEqual(menuDishesFromRpc([sneaky], PHOTOS), { dishes: [noPhoto], skipped: 0 });
});

test("normaliza: id en minúsculas, alérgenos en el orden del enum, meses de menor a mayor, \"\" como null", () => {
  const dish = readMenuDish({
    ...LASAGNE,
    id: LASAGNE_ID.toUpperCase(),
    name: { it: "Lasagne", es: "", en: undefined },
    allergens: ["milk", "gluten"],
    seasonMonths: [12, 1, 2],
  }, ORIGIN);
  assert.equal(dish?.id, LASAGNE_ID);
  assert.deepEqual(dish?.name, { it: "Lasagne", es: null, en: null });
  assert.deepEqual(dish?.allergens, ["gluten", "milk"]);
  assert.deepEqual(dish?.seasonMonths, [1, 2, 12]);
  assert.equal(readMenuDish({ ...LASAGNE, diet: undefined, seasonMonths: undefined }, ORIGIN)?.diet, null);
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
    assert.equal(readMenuDish(value, ORIGIN), null, JSON.stringify(value));
    // Un plato roto se saltea: no apaga el menú de los demás.
    assert.deepEqual(menuDishesFromRpc([MINESTRONE_ROW, value], PHOTOS), { dishes: [MINESTRONE], skipped: 1 }, `lista con ${JSON.stringify(value)}`);
  }
  for (const data of [null, {}, "x", { dishes: [] }]) assert.equal(menuDishesFromRpc(data, PHOTOS), null, JSON.stringify(data));
  // Una traducción en blanco (también con el espacio duro, que la base deja pasar) es null: cae al italiano.
  for (const blank of ["", "   ", " ", "  "]) {
    const dish = readMenuDish({ ...LASAGNE, name: { ...LASAGNE.name, es: blank }, description: { ...LASAGNE.description, en: blank } }, ORIGIN);
    assert.equal(dish?.name.es, null, JSON.stringify(blank));
    assert.equal(dish?.description.en, null, JSON.stringify(blank));
  }
});

test("respuesta de GET …/menu: se arma y se lee con la misma forma; otra versión u otra forma, null", () => {
  const response = buildMenuResponse([LASAGNE, MINESTRONE] as MenuDish[]);
  assert.deepEqual(response, { version: 1, dishes: [LASAGNE, MINESTRONE] });
  assert.deepEqual(parseMenuResponse(JSON.parse(JSON.stringify(response)), ORIGIN), response);
  assert.deepEqual(parseMenuResponse({ version: 1, dishes: [] }, ORIGIN), { version: 1, dishes: [] });
  for (const json of [null, [], { version: 2, dishes: [] }, { dishes: [] }, { version: 1 }, { version: 1, dishes: [{ ...LASAGNE, diet: "x" }] }, { error: "unavailable" }]) {
    assert.equal(parseMenuResponse(json, ORIGIN), null, JSON.stringify(json));
  }
});

test("la web lee la foto: sin photo (la función de antes, durante el despliegue) es null", () => {
  const { photo: _, ...withoutPhoto } = LASAGNE;
  assert.deepEqual(parseMenuResponse({ version: 1, dishes: [withoutPhoto, MINESTRONE] }, ORIGIN), {
    version: 1,
    dishes: [{ ...LASAGNE, photo: null }, MINESTRONE],
  });
});

test("la web descarta una foto que no sea del bucket recipe-photos en el origen de Supabase (el plato queda, sin foto)", () => {
  const prefix = `${ORIGIN}/storage/v1/object/public/recipe-photos/${CHEF_ID}/${LASAGNE_ID}`;
  const other = "1f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f";
  const bad: unknown[] = [
    "https://abcdefgh.supabase.co/x.jpg",
    { thumb: LASAGNE_PHOTO.thumb },
    { thumb: LASAGNE_PHOTO.thumb, full: 5 },
    { ...LASAGNE_PHOTO, thumb: LASAGNE_PHOTO.thumb.replace("https://", "http://") },
    { ...LASAGNE_PHOTO, thumb: LASAGNE_PHOTO.thumb.replace(ORIGIN, "https://evil.example") },
    { ...LASAGNE_PHOTO, full: LASAGNE_PHOTO.full.replace(ORIGIN, "https://abcdefgh.supabase.co.evil.example") },
    { ...LASAGNE_PHOTO, full: LASAGNE_PHOTO.full.replace(ORIGIN, "https://user@abcdefgh.supabase.co") },
    { ...LASAGNE_PHOTO, thumb: LASAGNE_PHOTO.thumb.replace("/public/recipe-photos/", "/public/receipts/") },
    { ...LASAGNE_PHOTO, thumb: LASAGNE_PHOTO.thumb.replace("/object/public/", "/object/sign/") },
    { ...LASAGNE_PHOTO, thumb: `${LASAGNE_PHOTO.thumb}?token=x` },
    { ...LASAGNE_PHOTO, thumb: `${LASAGNE_PHOTO.thumb}#x` },
    { ...LASAGNE_PHOTO, thumb: LASAGNE_PHOTO.full },
    { ...LASAGNE_PHOTO, full: LASAGNE_PHOTO.thumb },
    { ...LASAGNE_PHOTO, full: `${prefix}/${other}.jpg` },
    { ...LASAGNE_PHOTO, thumb: LASAGNE_PHOTO.thumb.replace(LASAGNE_ID, MINESTRONE_ID) },
    { thumb: LASAGNE_PHOTO.thumb.replace(LASAGNE_ID, MINESTRONE_ID), full: LASAGNE_PHOTO.full.replace(LASAGNE_ID, MINESTRONE_ID) },
    { ...LASAGNE_PHOTO, full: LASAGNE_PHOTO.full.replace(CHEF_ID, other) },
    { ...LASAGNE_PHOTO, thumb: LASAGNE_PHOTO.thumb.replace(PHOTO_ID, PHOTO_ID.toUpperCase()) },
    { ...LASAGNE_PHOTO, thumb: `${prefix}/../${LASAGNE_ID}/${PHOTO_ID}-thumb.jpg` },
    { ...LASAGNE_PHOTO, full: `${prefix}/${PHOTO_ID}.png` },
    { ...LASAGNE_PHOTO, thumb: "javascript:alert(1)" },
  ];
  for (const photo of bad) {
    const dish = readMenuDish({ ...LASAGNE, photo }, ORIGIN);
    assert.deepEqual(dish, { ...LASAGNE, photo: null }, JSON.stringify(photo));
  }
  // Sin el origen de Supabase (la web sin configurar) no hay con qué compararla: sin foto.
  assert.equal(readMenuDish(LASAGNE, null)?.photo, null);
  // En la máquina local (supabase start) el origen es http://127.0.0.1:54321.
  const local = "http://127.0.0.1:54321";
  const localPhoto = recipePhotoUrls(local, CHEF_ID, LASAGNE_ID, PHOTO_ID);
  assert.deepEqual(readMenuDish({ ...LASAGNE, photo: localPhoto }, local)?.photo, localPhoto);
  assert.equal(readMenuDish({ ...LASAGNE, photo: localPhoto }, ORIGIN)?.photo, null);
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

test("ingredientes (solo para el buscador): los nombres tal cual, y con otra forma el plato sale con []", () => {
  const read = (ingredients: unknown) => menuDishesFromRpc([{ ...LASAGNE_ROW, ingredients }], PHOTOS)?.dishes[0]?.ingredients;
  assert.deepEqual(read(["Carne de res", "Leche"]), ["Carne de res", "Leche"]);
  assert.deepEqual(read([]), []);
  // Un plato de una función o una base de antes (sin la clave) sale sin ingredientes.
  const { ingredients: _omitted, ...old } = LASAGNE_ROW;
  assert.deepEqual(menuDishesFromRpc([old], PHOTOS)?.dishes[0]?.ingredients, []);
  assert.deepEqual(readMenuDish(old, ORIGIN)?.ingredients, []);
  // Cualquier otra forma: [] para ese plato, sin romper el menú (ni saltear el plato).
  const tooMany = Array.from({ length: 41 }, (_, i) => `Ingrediente ${i}`);
  const bad: unknown[] = [
    null, "carne", { name: "carne" }, [{ name: "carne", quantity: 400 }], ["carne", 3], ["carne", ""], ["carne", "   "],
    ["carne\ncerdo"], ["x".repeat(81)], tooMany,
  ];
  for (const value of bad) assert.deepEqual(read(value), [], JSON.stringify(value));
  assert.equal(menuDishesFromRpc([{ ...LASAGNE_ROW, ingredients: tooMany }], PHOTOS)?.skipped, 0);
  // En el límite: 40 nombres de 80 caracteres.
  const limit = Array.from({ length: 40 }, () => "x".repeat(80));
  assert.deepEqual(read(limit), limit);
});

test("GET …/menu: la web lee los ingredientes con la misma validación; una versión vieja de la web los ignora", () => {
  const response = buildMenuResponse([LASAGNE, MINESTRONE].map((dish) => ({ ...dish, photo: dish.photo })));
  const parsed = parseMenuResponse(JSON.parse(JSON.stringify(response)), ORIGIN);
  assert.deepEqual(parsed?.dishes[0]?.ingredients, ["Carne de res", "Pasta all'uovo", "Leche"]);
  assert.equal(response.version, 1, "MENU_VERSION sigue en 1: el campo es nuevo y el lector viejo arma cada plato campo por campo");
});
