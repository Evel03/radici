// Menù de la web: los platos publicados de la cocinera, para la pestaña «Menù» del formulario de pedido.
// GET <función public-request>/menu (docs/contracts/public-request.md §12) y el `menu` del 201 (§2).
// Contrato compartido entre la Edge Function y la web: un solo origen, nada copiado.
// Un plato se arma solo con lo que lista este archivo: nunca ingredientes ni notas, aunque la base
// mandara de más. Los nombres de los platos no son datos de salud; sus alérgenos los marca Evelyn.
// La foto (20/11/2026) son dos URL públicas de Supabase Storage: la base da el photoId y la función arma
// las URL con SUPABASE_URL; la web solo acepta las de ese origen y ese bucket.
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

/**
 * La foto de un plato: las URL públicas de sus dos archivos en el bucket recipe-photos
 * (supabase/migrations/20261120100000_recipe_photos.sql). Por convención de la app cada foto nueva tiene un id
 * nuevo (sube archivos nuevos y borra los viejos), así una URL no cambia de contenido; la base no lo garantiza.
 */
export interface MenuPhoto {
  /** La miniatura (lado menor 320 px): la que muestra la web, recortada en un cuadrado. */
  thumb: string;
  /** La grande (lado mayor 1200 px). */
  full: string;
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
  /** null = sin foto (o una que no es del bucket recipe-photos en el origen de Supabase). */
  photo: MenuPhoto | null;
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

/** El bucket público de las fotos de los platos. */
export const RECIPE_PHOTOS_BUCKET = "recipe-photos";

/** Ruta de un archivo público del bucket, después del origen de Supabase. */
const PHOTO_PATH_PREFIX = `/storage/v1/object/public/${RECIPE_PHOTOS_BUCKET}/`;

const LOWER_UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
/** {chef_id}/{recipe_id}/{photo_id}[-thumb].jpg, con los uuids en minúsculas (como las rutas de la base). */
const PHOTO_FILE_RE = new RegExp(`^(${LOWER_UUID})/(${LOWER_UUID})/(${LOWER_UUID})(-thumb)?\\.jpg$`);

/**
 * El origen de Supabase para las URL de las fotos: https, o http solo en la máquina local (supabase start),
 * como VITE_SUPABASE_URL en la web. null si no: con supabase functions serve, SUPABASE_URL es la dirección
 * interna de Docker (http://kong:8000), que el navegador no abre, y los platos salen sin foto.
 */
export function photoOrigin(raw: string | null | undefined): string | null {
  if (typeof raw !== "string") return null;
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    return null;
  }
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (url.protocol === "https:" || (url.protocol === "http:" && local)) return url.origin;
  return null;
}

/** Las URL públicas de los dos archivos de una foto. origin: el de photoOrigin. */
export function recipePhotoUrls(origin: string, chefId: string, recipeId: string, photoId: string): MenuPhoto {
  const base = `${origin}${PHOTO_PATH_PREFIX}${chefId.toLowerCase()}/${recipeId.toLowerCase()}/${photoId.toLowerCase()}`;
  return { thumb: `${base}-thumb.jpg`, full: `${base}.jpg` };
}

/** Los ids de un archivo de foto si la URL es de ese origen y ese bucket, sin query ni fragmento; si no, null. */
function readPhotoUrl(value: unknown, origin: string): { chefId: string; recipeId: string; photoId: string; thumb: boolean } | null {
  if (typeof value !== "string" || !value.startsWith(`${origin}${PHOTO_PATH_PREFIX}`)) return null;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  // Tal cual, sin nada que el navegador normalice (../, %2F, usuario, puerto de más).
  if (url.href !== value || url.origin !== origin || url.search !== "" || url.hash !== "") return null;
  const match = PHOTO_FILE_RE.exec(url.pathname.slice(PHOTO_PATH_PREFIX.length));
  if (!match) return null;
  return { chefId: match[1] ?? "", recipeId: match[2] ?? "", photoId: match[3] ?? "", thumb: match[4] !== undefined };
}

/**
 * Una foto { thumb, full } como las de recipePhotoUrls: los dos archivos de la misma foto (la misma cocinera,
 * el mismo plato y la misma foto) en el bucket recipe-photos del origen de Supabase (photoOrigin), con el plato
 * de la foto (recipeId). Cualquier otra cosa, o sin origen, es null. Sirve también donde no se sabe el id del
 * plato: los platos del menú que Evelyn le manda a la clienta (_shared/client_link.ts).
 */
export function readStoragePhoto(value: unknown, origin: string | null): (MenuPhoto & { recipeId: string }) | null {
  const allowed = photoOrigin(origin);
  if (!allowed || !isRecord(value)) return null;
  const thumb = readPhotoUrl(value["thumb"], allowed);
  const full = readPhotoUrl(value["full"], allowed);
  if (!thumb || !full || !thumb.thumb || full.thumb) return null;
  if (thumb.recipeId !== full.recipeId || thumb.chefId !== full.chefId || thumb.photoId !== full.photoId) return null;
  return { thumb: value["thumb"] as string, full: value["full"] as string, recipeId: thumb.recipeId };
}

/**
 * La foto de GET …/menu: { thumb, full } del mismo plato y la misma foto, en el bucket recipe-photos del
 * origen de Supabase (photoOrigin). Cualquier otra cosa, o sin origen, es null: el plato se muestra sin foto.
 */
function readPhoto(value: unknown, dishId: string, origin: string | null): MenuPhoto | null {
  const photo = readStoragePhoto(value, origin);
  return photo && photo.recipeId === dishId ? { thumb: photo.thumb, full: photo.full } : null;
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

/** Lo de un plato que es igual en get_public_menu y en GET …/menu (todo menos la foto); null con otra forma. */
function readDishFields(value: unknown): Omit<MenuDish, "photo"> | null {
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

/**
 * Un plato de la respuesta de GET …/menu; null si no tiene la forma del contrato. storageOrigin: el origen de
 * Supabase de la web (VITE_SUPABASE_URL). Sin photo (una función de antes de las fotos) o con una que no es
 * de ese origen y del bucket recipe-photos, el plato queda sin foto: la foto nunca descarta un plato.
 */
export function readMenuDish(value: unknown, storageOrigin: string | null): MenuDish | null {
  const fields = readDishFields(value);
  if (!fields || !isRecord(value)) return null;
  return { ...fields, photo: readPhoto(value["photo"], fields.id, storageOrigin) };
}

/** Todos los platos o null si alguno no tiene la forma del contrato (una respuesta rota no se muestra a medias). */
function readDishes(value: unknown, storageOrigin: string | null): MenuDish[] | null {
  if (!Array.isArray(value)) return null;
  const dishes: MenuDish[] = [];
  for (const item of value) {
    const dish = readMenuDish(item, storageOrigin);
    if (!dish) return null;
    dishes.push(dish);
  }
  return dishes;
}

/** Con qué arma la función las URL de las fotos: el origen de SUPABASE_URL (photoOrigin) y la cocinera. */
export interface PhotoSource {
  /** null: los platos salen sin foto. */
  origin: string | null;
  chefId: string;
}

/**
 * Lo que devuelve public.get_public_menu (un array, vacío si no hay platos), o null si no es un array. Un
 * plato con otra forma (por ejemplo, un nombre en italiano que es solo un espacio duro) se saltea y se
 * cuenta en skipped: no apaga el menú de los demás. La foto sale de photoId (un uuid; null o ausente = sin
 * foto), con las URL públicas de photos; un photoId con otra forma deja el plato sin foto.
 */
export function menuDishesFromRpc(data: unknown, photos: PhotoSource): { dishes: MenuDish[]; skipped: number } | null {
  if (!Array.isArray(data)) return null;
  const dishes: MenuDish[] = [];
  for (const item of data) {
    const fields = readDishFields(item);
    if (!fields || !isRecord(item)) continue;
    const photoId = item["photoId"];
    const photo =
      photos.origin !== null && typeof photoId === "string" && isUuid(photoId)
        ? recipePhotoUrls(photos.origin, photos.chefId, fields.id, photoId)
        : null;
    dishes.push({ ...fields, photo });
  }
  return { dishes, skipped: data.length - dishes.length };
}

/** La respuesta de GET …/menu. */
export function buildMenuResponse(dishes: readonly MenuDish[]): MenuResponse {
  return { version: MENU_VERSION, dishes: [...dishes] };
}

/**
 * Lectura defensiva en la web: null si la respuesta no tiene la forma esperada (otra versión, un error,
 * un proxy). Con null el panel dice que el menù lo propone Evelyn y el pedido se manda igual. storageOrigin:
 * el origen de Supabase de la web; las fotos de otro lado se descartan (readMenuDish).
 */
export function parseMenuResponse(json: unknown, storageOrigin: string | null): MenuResponse | null {
  if (!isRecord(json) || json["version"] !== MENU_VERSION) return null;
  const dishes = readDishes(json["dishes"], storageOrigin);
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
