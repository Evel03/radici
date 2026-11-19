// Menù de la web: los platos publicados de la cocinera, para la pestaña «Menù» del formulario de pedido.
// GET <función public-request>/menu (docs/contracts/public-request.md §12) y el `menu` del 201 (§2).
// Contrato compartido entre la Edge Function y la web: un solo origen, nada copiado.
// Un plato se arma solo con lo que lista este archivo: nunca ingredientes ni notas, aunque la base
// mandara de más. Los nombres de los platos no son datos de salud; sus alérgenos los marca Evelyn.
// Solo sintaxis borrable (corre en Node, Deno y Vite sin compilar) e imports con extensión .ts.
import { ALLERGENS, DIETS, isOneOf, isUuid, type Allergen, type Diet, type Locale } from "./public_request.ts";

/** Versión de la respuesta. Si cambia su forma, se sube: la web vieja deja de mostrar los platos. */
export const MENU_VERSION = 1;

/** Ruta dentro de la función public-request (la URL termina así, antes de la query). */
export const MENU_PATH = "/menu";

/** Un texto en los tres idiomas: el italiano siempre; el español y el inglés, o null sin traducción. */
export interface LocalizedText {
  it: string;
  es: string | null;
  en: string | null;
}

/** Un plato elegido, como lo devuelve el 201 (los nombres actuales de la receta). */
export interface MenuChoice {
  /** uuid en minúsculas. */
  id: string;
  name: LocalizedText;
}

/** Un plato publicado (activo, visible en el catálogo y con descripción en italiano). */
export interface MenuDish extends MenuChoice {
  /** La descripción corta (de 1 a 200 caracteres); el italiano siempre está. */
  description: LocalizedText;
  /** Los de los 14 del Reg. UE 1169/2011 que marcó Evelyn, en el orden del enum; [] sin alérgenos. */
  allergens: Allergen[];
  diet: Diet | null;
  /** Meses de 1 a 12 en que lo ofrece, de menor a mayor; null = todo el año. */
  seasonMonths: number[] | null;
}

export interface MenuResponse {
  version: typeof MENU_VERSION;
  /** Ordenados por nombre en italiano (get_public_menu). */
  dishes: MenuDish[];
}

/** El texto en ese idioma o, si no está traducido, en italiano. */
export function localizedText(text: LocalizedText, locale: Locale): string {
  return text[locale] ?? text.it;
}

/** true si el plato se ofrece en ese mes (1 a 12): todo el año o uno de sus meses. */
export function dishInSeason(dish: Pick<MenuDish, "seasonMonths">, month: number): boolean {
  return dish.seasonMonths === null || dish.seasonMonths.includes(month);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Texto no vacío (sin contar espacios). */
function isText(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== "";
}

/**
 * { it, es, en }: el italiano obligatorio; los otros, texto o null. Ausente, "" o solo espacios (también
 * los de Unicode, como el espacio duro, que el check de la base deja pasar porque btrim recorta solo los
 * ASCII) también es null: una traducción en blanco cae al italiano.
 */
function readLocalizedText(value: unknown): LocalizedText | null {
  if (!isRecord(value)) return null;
  const it = value["it"];
  if (!isText(it)) return null;
  const optional = (key: "es" | "en"): string | null | undefined => {
    const item = value[key];
    if (item === undefined || item === null) return null;
    if (typeof item !== "string") return undefined;
    return isText(item) ? item : null;
  };
  const es = optional("es");
  const en = optional("en");
  if (es === undefined || en === undefined) return null;
  return { it, es, en };
}

function readChoice(value: unknown): MenuChoice | null {
  if (!isRecord(value)) return null;
  const id = value["id"];
  const name = readLocalizedText(value["name"]);
  if (typeof id !== "string" || !isUuid(id) || !name) return null;
  return { id: id.toLowerCase(), name };
}

/** Los alérgenos sin repetir, en el orden del enum; null si alguno no es de los 14. */
function readAllergens(value: unknown): Allergen[] | null {
  if (!Array.isArray(value) || !value.every((item) => isOneOf(ALLERGENS, item))) return null;
  if (new Set(value).size !== value.length) return null;
  return ALLERGENS.filter((allergen) => (value as unknown[]).includes(allergen));
}

/** Meses de 1 a 12, sin repetir y al menos uno, de menor a mayor; null/ausente = todo el año. */
function readSeason(value: unknown): number[] | null | undefined {
  if (value === null || value === undefined) return null;
  if (!Array.isArray(value) || value.length === 0) return undefined;
  if (!value.every((month) => Number.isInteger(month) && month >= 1 && month <= 12)) return undefined;
  if (new Set(value).size !== value.length) return undefined;
  return [...(value as number[])].sort((a, b) => a - b);
}

/** Un plato de get_public_menu o de la respuesta de GET …/menu; null si no tiene la forma del contrato. */
export function readMenuDish(value: unknown): MenuDish | null {
  const choice = readChoice(value);
  if (!choice || !isRecord(value)) return null;
  const description = readLocalizedText(value["description"]);
  const allergens = readAllergens(value["allergens"]);
  const dietRaw = value["diet"];
  const diet = dietRaw === null || dietRaw === undefined ? null : isOneOf(DIETS, dietRaw) ? dietRaw : undefined;
  const seasonMonths = readSeason(value["seasonMonths"]);
  if (!description || !allergens || diet === undefined || seasonMonths === undefined) return null;
  // Se arma de nuevo, campo por campo: nada que no sea del contrato sale hacia la web.
  return { id: choice.id, name: choice.name, description, allergens, diet, seasonMonths };
}

/** Todos los platos o null si alguno no tiene la forma del contrato (una respuesta rota no se muestra a medias). */
function readDishes(value: unknown): MenuDish[] | null {
  if (!Array.isArray(value)) return null;
  const dishes: MenuDish[] = [];
  for (const item of value) {
    const dish = readMenuDish(item);
    if (!dish) return null;
    dishes.push(dish);
  }
  return dishes;
}

/**
 * Lo que devuelve public.get_public_menu (un array, vacío si no hay platos), o null si no es un array. Un
 * plato con otra forma (por ejemplo, un nombre en italiano que es solo un espacio duro) se saltea y se
 * cuenta en skipped: no apaga el menú de los demás.
 */
export function menuDishesFromRpc(data: unknown): { dishes: MenuDish[]; skipped: number } | null {
  if (!Array.isArray(data)) return null;
  const dishes: MenuDish[] = [];
  for (const item of data) {
    const dish = readMenuDish(item);
    if (dish) dishes.push(dish);
  }
  return { dishes, skipped: data.length - dishes.length };
}

/** La respuesta de GET …/menu. */
export function buildMenuResponse(dishes: readonly MenuDish[]): MenuResponse {
  return { version: MENU_VERSION, dishes: [...dishes] };
}

/**
 * Lectura defensiva en la web: null si la respuesta no tiene la forma esperada (otra versión, un error,
 * un proxy). Con null el panel dice que el menù lo propone Evelyn y el pedido se manda igual.
 */
export function parseMenuResponse(json: unknown): MenuResponse | null {
  if (!isRecord(json) || json["version"] !== MENU_VERSION) return null;
  const dishes = readDishes(json["dishes"]);
  return dishes ? { version: MENU_VERSION, dishes } : null;
}

/**
 * Los platos elegidos que devuelve submit_public_request (y el 201): [{ id, name }], en el orden en que
 * los tildó el cliente. null si no es un array con esa forma.
 */
export function readMenuChoices(value: unknown): MenuChoice[] | null {
  if (!Array.isArray(value)) return null;
  const choices: MenuChoice[] = [];
  for (const item of value) {
    const choice = readChoice(item);
    if (!choice) return null;
    choices.push(choice);
  }
  return choices;
}
