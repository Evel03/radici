// La foto del menú de una semana tal como se le manda a la clienta (menu_sends.snapshot, SPEC 5.8;
// migración 20261121100000_menu_sends.sql). La arma la función chef en la vista previa (POST
// /chef/menus/preview, docs/contracts/chef-api.md §13), la guarda la base y de ella salen el email, el
// WhatsApp y, en el PR siguiente, la página de la clienta (el link). Un solo origen para las tres.
//
// Ya está en el idioma de la clienta: los platos con sus nombres en ese idioma (o en italiano) y la
// lista de compras traducida si se pudo; la nota, como la escribió Evelyn (nunca se traduce). Nunca
// lleva la dirección, las alergias de la clienta, su contacto ni nada de pagos: solo lo que ve en el
// mensaje. El envío de la semana 1 de un presupuesto abierto lleva además el presupuesto (quote: las
// semanas con su precio, el total y el plazo, quote_snapshot.ts); los demás envíos, como siempre.
// Solo sintaxis borrable (corre en Node, Deno y Vite sin compilar) e imports con extensión .ts.
import type { MenuPhoto } from "./menu.ts";
import { ALLERGENS, DIETS, LOCALES, isIsoDate, isOneOf, type Allergen, type Diet, type Locale } from "./public_request.ts";
import { readSnapshotQuote, type SnapshotQuote } from "./quote_snapshot.ts";

/** Versión de la forma. Si cambia, se sube: quien lee una foto de otra versión no la muestra a medias. */
export const MENU_SNAPSHOT_VERSION = 1;

/** Secciones del súper, en el orden del recorrido (el enum shopping_section): la lista agrupa en este orden. */
export const SHOPPING_SECTIONS = ["produce", "meat_fish", "dairy_eggs", "bakery", "pantry", "frozen", "other"] as const;
export type ShoppingSection = (typeof SHOPPING_SECTIONS)[number];

/** Unidades de una cantidad (el enum ingredient_unit): gramos, mililitros o piezas. */
export const INGREDIENT_UNITS = ["g", "ml", "pcs"] as const;
export type IngredientUnit = (typeof INGREDIENT_UNITS)[number];

/** Topes de la base (session_menu, session_shopping_items y session_menus), para leer una foto con cuidado. */
export const MENU_LIMITS = {
  /** Porciones de un plato en la semana. */
  maxPortions: 500,
  /** Cantidad de un renglón de la lista, en g, ml o piezas. */
  maxQuantity: 1_000_000,
  /** Caracteres del nombre de un renglón de la lista. */
  itemNameMax: 80,
  /** Caracteres de la nota para la clienta (admite saltos de línea). */
  noteMax: 1000,
  /** Ingredientes de un plato (recipe_ingredients.position, de 1 a 50). */
  maxIngredients: 50,
  /** Caracteres del nombre de un ingrediente (como el de un renglón de la lista). */
  ingredientNameMax: 80,
} as const;

/**
 * Bytes de la foto (JSON en UTF-8) hasta los que lleva los ingredientes de los platos: la base acepta hasta 64 KB
 * (menu_sends_snapshot_valido, en jsonb, que ocupa algo más que el texto). Pasado esto, los platos salen sin
 * ingredientes (fitMenuSnapshotSize): el menú se manda igual y el libro los muestra sin esa parte.
 */
export const SNAPSHOT_INGREDIENTS_MAX_BYTES = 60_000;

/** La semana del envío: «Semana k de N» (las sesiones no canceladas de la reserva), su día y su llegada. */
export interface MenuSnapshotSession {
  /** "AAAA-MM-DD", fecha de Roma. */
  date: string;
  /** Llegada "HH:MM", hora de Roma. */
  start: string;
  week: number;
  weeks: number;
}

/** Una semana de la reserva (para la lista de fechas). */
export interface MenuSnapshotWeek {
  date: string;
  start: string;
}

export interface MenuSnapshotDish {
  /** En el idioma de la clienta o, si no está traducido, en italiano. */
  name: string;
  description: string | null;
  /** Los de los 14 del Reg. UE 1169/2011 que marcó Evelyn, en el orden del enum; [] sin alérgenos. */
  allergens: Allergen[];
  diet: Diet | null;
  /** Porciones de ese plato en la semana. */
  portions: number;
  /** Las URL públicas de la foto (como el menù de la web), o null. El email no las usa: sin imágenes remotas. */
  photo: MenuPhoto | null;
  /**
   * Los nombres de sus ingredientes para el libro del menú (sin cantidades), en el idioma de la clienta si se
   * tradujeron (como la lista), en el orden de Evelyn y sin repetir. Sin ingredientes no va la clave, como en
   * las fotos de antes del libro (22/11/2026): todo lo que lee una foto tiene que andar sin ella.
   */
  ingredients?: string[];
}

export interface MenuSnapshotItem {
  name: string;
  section: ShoppingSection;
  /** Entera, en unit; null junto con unit = q.b. (para tener en casa). */
  quantity: number | null;
  unit: IngredientUnit | null;
}

export interface MenuSnapshot {
  v: typeof MENU_SNAPSHOT_VERSION;
  locale: Locale;
  session: MenuSnapshotSession;
  /** Las semanas no canceladas de la reserva, por fecha (incluye la del envío). */
  weeks: MenuSnapshotWeek[];
  /** En el orden del menú. */
  dishes: MenuSnapshotDish[];
  /** En el orden en que los dejó Evelyn; el mensaje los agrupa por sección. */
  items: MenuSnapshotItem[];
  note: string | null;
  /**
   * Solo en el envío de la semana 1 de un presupuesto abierto: el presupuesto que viaja con el menú (lo que la
   * clienta acepta). Sin la clave, un envío como los de siempre (también las fotos de antes).
   */
  quote?: SnapshotQuote;
}

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isText(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== "";
}

function isIntBetween(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
}

function isHttpUrl(value: unknown): value is string {
  if (typeof value !== "string") return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:";
  } catch {
    return false;
  }
}

/** Los alérgenos sin repetir, en el orden del enum; null si alguno no es de los 14. */
export function readAllergenList(value: unknown): Allergen[] | null {
  if (!Array.isArray(value) || !value.every((item) => isOneOf(ALLERGENS, item))) return null;
  return ALLERGENS.filter((allergen) => (value as unknown[]).includes(allergen));
}

/** Un renglón de la lista con la forma de la base, o null. */
export function readMenuItem(value: unknown): MenuSnapshotItem | null {
  if (!isRecord(value)) return null;
  const { name, section, quantity, unit } = value;
  if (!isText(name) || !isOneOf(SHOPPING_SECTIONS, section)) return null;
  if (quantity === null && unit === null) return { name, section, quantity: null, unit: null };
  if (!isIntBetween(quantity, 1, MENU_LIMITS.maxQuantity) || !isOneOf(INGREDIENT_UNITS, unit)) return null;
  return { name, section, quantity, unit };
}

function readSession(value: unknown): MenuSnapshotSession | null {
  if (!isRecord(value)) return null;
  const { date, start, week, weeks } = value;
  if (typeof date !== "string" || !isIsoDate(date) || typeof start !== "string" || !TIME.test(start)) return null;
  if (!isIntBetween(weeks, 1, 100) || !isIntBetween(week, 1, weeks)) return null;
  return { date, start, week, weeks };
}

function readWeek(value: unknown): MenuSnapshotWeek | null {
  if (!isRecord(value)) return null;
  const { date, start } = value;
  if (typeof date !== "string" || !isIsoDate(date) || typeof start !== "string" || !TIME.test(start)) return null;
  return { date, start };
}

function readPhoto(value: unknown): MenuPhoto | null | undefined {
  if (value === null || value === undefined) return null;
  if (!isRecord(value) || !isHttpUrl(value["thumb"]) || !isHttpUrl(value["full"])) return undefined;
  return { thumb: value["thumb"], full: value["full"] };
}

/** Caracteres de control (los de la base y los de C1): un nombre de ingrediente va en una línea. */
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/;

/**
 * Los nombres de los ingredientes de un plato (la clave ingredients, libro del menú): undefined si no vienen (null o
 * ausente, como en las fotos de antes del libro) o si la lista está vacía; null si tienen otra forma (no es una
 * lista, más de 50, o un nombre vacío, de más de 80 caracteres o con caracteres de control).
 */
export function readIngredientNames(value: unknown): string[] | null | undefined {
  if (value === null || value === undefined) return undefined;
  if (!Array.isArray(value) || value.length > MENU_LIMITS.maxIngredients) return null;
  const names: string[] = [];
  for (const item of value) {
    if (!isText(item) || CONTROL.test(item) || Array.from(item).length > MENU_LIMITS.ingredientNameMax) return null;
    names.push(item);
  }
  return names.length > 0 ? names : undefined;
}

function readDish(value: unknown): MenuSnapshotDish | null {
  if (!isRecord(value)) return null;
  const { name, description, diet, portions } = value;
  const allergens = readAllergenList(value["allergens"]);
  const photo = readPhoto(value["photo"]);
  const ingredients = readIngredientNames(value["ingredients"]);
  if (!isText(name) || (description !== null && !isText(description))) return null;
  if (!allergens || (diet !== null && !isOneOf(DIETS, diet)) || !isIntBetween(portions, 1, MENU_LIMITS.maxPortions) || photo === undefined) {
    return null;
  }
  if (ingredients === null) return null;
  return { name, description, allergens, diet, portions, photo, ...(ingredients ? { ingredients } : {}) };
}

/** Bytes de la foto como JSON en UTF-8. */
export function menuSnapshotBytes(snapshot: MenuSnapshot): number {
  return new TextEncoder().encode(JSON.stringify(snapshot)).length;
}

/**
 * La foto que entra en la base: la misma si no pasa de SNAPSHOT_INGREDIENTS_MAX_BYTES; si pasa, una copia sin los
 * ingredientes de los platos (lo único que se puede sacar sin cambiar el mensaje: el libro sale sin esa parte).
 */
export function fitMenuSnapshotSize(snapshot: MenuSnapshot): MenuSnapshot {
  if (menuSnapshotBytes(snapshot) <= SNAPSHOT_INGREDIENTS_MAX_BYTES) return snapshot;
  const dishes = snapshot.dishes.map((dish) => {
    const copy: MenuSnapshotDish = { ...dish };
    delete copy.ingredients;
    return copy;
  });
  return { ...snapshot, dishes };
}

function readList<T>(value: unknown, read: (item: unknown) => T | null): T[] | null {
  if (!Array.isArray(value)) return null;
  const list: T[] = [];
  for (const item of value) {
    const parsed = read(item);
    if (parsed === null) return null;
    list.push(parsed);
  }
  return list;
}

/**
 * Una foto guardada (la que devuelve la base) → MenuSnapshot, armada de nuevo campo por campo; null si
 * no tiene la forma de esta versión (otra versión, un plato sin nombre, una sección desconocida, un
 * presupuesto que no cierra). Lo que la foto trajera de más no sale.
 */
export function readMenuSnapshot(value: unknown): MenuSnapshot | null {
  if (!isRecord(value) || value["v"] !== MENU_SNAPSHOT_VERSION || !isOneOf(LOCALES, value["locale"])) return null;
  const session = readSession(value["session"]);
  const weeks = readList(value["weeks"], readWeek);
  const dishes = readList(value["dishes"], readDish);
  const items = readList(value["items"], readMenuItem);
  const note = value["note"];
  const quote = readSnapshotQuote(value["quote"]);
  if (!session || !weeks || !dishes || dishes.length === 0 || !items || (note !== null && !isText(note)) || quote === undefined) return null;
  const snapshot: MenuSnapshot = { v: MENU_SNAPSHOT_VERSION, locale: value["locale"], session, weeks, dishes, items, note };
  if (quote) snapshot.quote = quote;
  return snapshot;
}
