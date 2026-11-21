// Link de la clienta (SPEC 5.8, docs/contracts/client-link.md): contrato entre la Edge Function client-link
// y la página /prenotazione/ de la web. Un solo origen, nada copiado.
//
// - El link: https://<sitio>/prenotazione/#t=<token>. El token son 32 bytes al azar en base64url (43
//   caracteres); va en el fragmento, que el navegador no manda a ningún servidor ni en el Referer. La base
//   guarda solo su hash (sha-256 del token en UTF-8, en hexadecimal): client_links.token_hash.
// - Lo que ve la clienta de cada semana es la foto del último envío del menú (menu_sends.snapshot), tal como
//   salió y ya en su idioma. readMenuSnapshot la lee campo por campo: lo que no es del contrato no pasa (ni a
//   la respuesta ni a la página), y una foto con otra forma no se muestra a medias.
// - Nunca precios, pagos, dirección ni las alergias de la clienta: la foto no los tiene y nada de acá los lee.
// Solo sintaxis borrable (corre en Node, Deno y Vite sin compilar) e imports con extensión .ts.
import { readStoragePhoto, type MenuPhoto } from "./menu.ts";
import { ALLERGENS, DIETS, LOCALES, isIsoDate, isOneOf, isUuid, type Allergen, type Diet, type Locale } from "./public_request.ts";

/** Versión de la respuesta de POST …/view. Si cambia su forma, se sube: la página vieja dice que hubo un problema. */
export const CLIENT_LINK_VERSION = 1;
/** Versión de la foto de un envío (snapshot.v) que se sabe leer. */
export const MENU_SNAPSHOT_VERSION = 1;

/** Nombre de la Edge Function (la URL es …/functions/v1/client-link/<ruta>). */
export const CLIENT_LINK_FUNCTION = "client-link";
/** Las rutas, todas POST con un JSON chico. */
export const CLIENT_LINK_ROUTES = { view: "/view", confirm: "/confirm", changes: "/changes" } as const;
export type ClientLinkRoute = (typeof CLIENT_LINK_ROUTES)[keyof typeof CLIENT_LINK_ROUTES];

/** El cuerpo más grande que acepta la función: el mensaje de cambios (1000 caracteres) con holgura para el JSON. */
export const CLIENT_LINK_MAX_PAYLOAD_BYTES = 16_384;
/** Tope del mensaje de cambios: el check de menu_sends.changes_text (char_length, en code points). */
export const CHANGES_TEXT_MAX = 1000;

/** La página de la clienta en la web. */
export const RESERVATION_PAGE_PATH = "/prenotazione/";
/** Bytes al azar de un token. */
export const CLIENT_LINK_TOKEN_BYTES = 32;

/** Porciones de un plato en la semana: el check de session_menu.portions. */
export const MAX_PORTIONS = 500;
/** Cantidad de un renglón de la lista: el check de session_shopping_items.quantity. */
export const MAX_ITEM_QUANTITY = 1_000_000;

/** Las secciones del súper (enum shopping_section), en el orden en que se muestran. */
export const SHOPPING_SECTIONS = ["produce", "meat_fish", "dairy_eggs", "bakery", "pantry", "frozen", "other"] as const;
export type ShoppingSection = (typeof SHOPPING_SECTIONS)[number];
/** Las unidades (enum ingredient_unit). Sin unidad (y sin cantidad) es «q.b.»: algo para tener en casa. */
export const SHOPPING_UNITS = ["g", "ml", "pcs"] as const;
export type ShoppingUnit = (typeof SHOPPING_UNITS)[number];

// ---------------------------------------------------------------------------
// Token y link
// ---------------------------------------------------------------------------

const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;

/** true si tiene la forma de un token (43 caracteres base64url). */
export function isClientLinkToken(value: unknown): value is string {
  return typeof value === "string" && TOKEN_PATTERN.test(value);
}

/** Un token nuevo: 32 bytes al azar (crypto.getRandomValues) en base64url, sin relleno. */
export function newClientLinkToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(CLIENT_LINK_TOKEN_BYTES));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** El hash que guarda la base: sha-256 del token en UTF-8, en hexadecimal minúscula (64 caracteres). */
export async function hashClientLinkToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** El link de la clienta: la página /prenotazione/ con el token en el fragmento. */
export function reservationPageUrl(siteUrl: string, token: string): string {
  return `${siteUrl.replace(/\/+$/, "")}${RESERVATION_PAGE_PATH}#t=${token}`;
}

// ---------------------------------------------------------------------------
// Mensaje de cambios
// ---------------------------------------------------------------------------

/** Largo como lo cuenta Postgres (char_length): por code points, no por unidades UTF-16. */
export function textLength(text: string): number {
  return Array.from(text).length;
}

/**
 * Caracteres de control que la base no acepta en el mensaje: todos menos el salto de línea. Los separadores de
 * línea y de párrafo (U+2028, U+2029) se cambian antes por saltos: glibc los cuenta como control.
 */
const CHANGES_TEXT_CONTROL = /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/;

/**
 * El mensaje de cambios como lo acepta client_link_request_changes: los saltos de línea (\r\n, \r, U+2028 y
 * U+2029) pasan a \n y las tabulaciones a espacios; recortado; de 1 a 1000 caracteres y sin otros caracteres de
 * control. null si no se puede mandar.
 */
export function normalizeChangesText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = value.replace(/\r\n?|[\u2028\u2029]/g, "\n").replace(/\t/g, " ").trim();
  if (text === "" || textLength(text) > CHANGES_TEXT_MAX || CHANGES_TEXT_CONTROL.test(text)) return null;
  return text;
}

// ---------------------------------------------------------------------------
// La foto de un envío (menu_sends.snapshot)
// ---------------------------------------------------------------------------

/** Un plato del menú de la semana, en el idioma de la clienta. */
export interface SnapshotDish {
  name: string;
  /** La descripción corta, o null si no tiene. */
  description: string | null;
  /** Los de los 14 del Reg. UE 1169/2011 que marcó Evelyn, en el orden del enum; [] sin alérgenos. */
  allergens: Allergen[];
  diet: Diet | null;
  /** Porciones de ese plato en la semana (1 a 500). */
  portions: number;
  /** La foto del plato (bucket recipe-photos del origen de Supabase), o null. */
  photo: MenuPhoto | null;
}

/** Un renglón de la lista de compras. Sin cantidad ni unidad: «q.b.», algo para tener en casa. */
export interface ShoppingItem {
  name: string;
  section: ShoppingSection;
  quantity: number | null;
  unit: ShoppingUnit | null;
}

/** Lo que la clienta ve de un envío: los platos, la lista y la nota de Evelyn, en el idioma del envío. */
export interface MenuContent {
  locale: Locale;
  /** Al menos uno: un menú sin platos no se manda (chef_prepare_menu_send). */
  dishes: SnapshotDish[];
  items: ShoppingItem[];
  /** La nota de Evelyn para la clienta (con sus saltos de línea), o null. */
  note: string | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Texto no vacío (sin contar espacios). */
function isText(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== "";
}

/** Texto, o null si falta, es null o está en blanco; undefined si es otra cosa (forma inválida). */
function optionalText(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") return undefined;
  return value.trim() === "" ? null : value;
}

function isIntInRange(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
}

/** Los alérgenos sin repetir, en el orden del enum; null si no es una lista o alguno no es de los 14. */
function readAllergens(value: unknown): Allergen[] | null {
  if (!Array.isArray(value) || !value.every((item) => isOneOf(ALLERGENS, item))) return null;
  return ALLERGENS.filter((allergen) => (value as unknown[]).includes(allergen));
}

function readDish(value: unknown, storageOrigin: string | null): SnapshotDish | null {
  if (!isRecord(value)) return null;
  const name = value["name"];
  const description = optionalText(value["description"]);
  const allergens = readAllergens(value["allergens"]);
  const dietRaw = value["diet"];
  const diet = dietRaw === null || dietRaw === undefined ? null : isOneOf(DIETS, dietRaw) ? dietRaw : undefined;
  const portions = value["portions"];
  if (!isText(name) || description === undefined || !allergens || diet === undefined || !isIntInRange(portions, 1, MAX_PORTIONS)) {
    return null;
  }
  // La foto nunca descarta el plato: con otra forma, o de otro origen, sale sin foto.
  const photo = readStoragePhoto(value["photo"], storageOrigin);
  return { name, description, allergens, diet, portions, photo: photo ? { thumb: photo.thumb, full: photo.full } : null };
}

function readItem(value: unknown): ShoppingItem | null {
  if (!isRecord(value)) return null;
  const name = value["name"];
  const quantity = value["quantity"];
  const unit = value["unit"];
  if (!isText(name)) return null;
  // Una sección que esta página no conoce todavía no esconde el renglón: va a «other».
  const sectionRaw = value["section"];
  const section: ShoppingSection = isOneOf(SHOPPING_SECTIONS, sectionRaw) ? sectionRaw : "other";
  // La cantidad y la unidad van juntas, o ninguna (q.b.). Una unidad desconocida no se puede mostrar bien.
  if ((quantity === null || quantity === undefined) && (unit === null || unit === undefined)) {
    return { name, section, quantity: null, unit: null };
  }
  if (!isIntInRange(quantity, 1, MAX_ITEM_QUANTITY) || !isOneOf(SHOPPING_UNITS, unit)) return null;
  return { name, section, quantity, unit };
}

/** Todos o null: un menú con un plato o un renglón roto no se muestra a medias. */
function readAll<T>(value: unknown, read: (item: unknown) => T | null): T[] | null {
  if (!Array.isArray(value)) return null;
  const out: T[] = [];
  for (const item of value) {
    const parsed = read(item);
    if (parsed === null) return null;
    out.push(parsed);
  }
  return out;
}

/**
 * { locale, dishes, items, note } armado de nuevo, campo por campo; null si no tiene esa forma. Lo usa la
 * función con la foto del envío (readMenuSnapshot) y la web con la respuesta (parseClientLinkView).
 */
export function readMenuContent(value: unknown, storageOrigin: string | null): MenuContent | null {
  if (!isRecord(value)) return null;
  const locale = value["locale"];
  const dishes = readAll(value["dishes"], (item) => readDish(item, storageOrigin));
  const items = readAll(value["items"], readItem);
  const note = optionalText(value["note"]);
  if (!isOneOf(LOCALES, locale) || !dishes || dishes.length === 0 || !items || note === undefined) return null;
  return { locale, dishes, items, note };
}

/**
 * La foto de un envío (menu_sends.snapshot, versión 1) como la ve la clienta, o null si no tiene la forma del
 * contrato. Los campos que no son del contrato (las fechas de la reserva, el id de la receta, lo que se sume)
 * se ignoran. storageOrigin: el origen de Supabase; las fotos de los platos de otro lado se descartan.
 */
export function readMenuSnapshot(value: unknown, storageOrigin: string | null): MenuContent | null {
  if (!isRecord(value) || value["v"] !== MENU_SNAPSHOT_VERSION) return null;
  return readMenuContent(value, storageOrigin);
}

// ---------------------------------------------------------------------------
// Respuestas
// ---------------------------------------------------------------------------

/** Qué contestó la clienta al último envío de una semana. */
export const MENU_STATES = ["pending", "confirmed", "changesRequested"] as const;
export type MenuState = (typeof MENU_STATES)[number];

/** El estado a partir de las fechas: la base guarda una sola de las dos (menu_sends_una_respuesta). */
export function menuState(confirmedAt: string | null, changesRequestedAt: string | null): MenuState {
  if (confirmedAt !== null) return "confirmed";
  return changesRequestedAt !== null ? "changesRequested" : "pending";
}

/** El último envío del menú de una semana. */
export interface ClientLinkMenu {
  sendId: string;
  sentAt: string;
  state: MenuState;
  confirmedAt: string | null;
  changesRequestedAt: string | null;
  /** null: la foto no se puede leer. La página lo dice y no deja contestar lo que no muestra. */
  content: MenuContent | null;
}

/** Una semana de la reserva (las sesiones no canceladas, por fecha). */
export interface ClientLinkWeek {
  /** «Semana k de N». */
  week: number;
  weeks: number;
  /** "AAAA-MM-DD" (Roma). */
  date: string;
  /** La hora de llegada, "HH:MM" (Roma). */
  start: string;
  /** Ya cocinada (cooked o paid): se ve el menú, sin botones. */
  done: boolean;
  /** null: Evelyn todavía no mandó el menú de esa semana. */
  menu: ClientLinkMenu | null;
}

/** 200 de POST …/view. */
export interface ClientLinkView {
  version: typeof CLIENT_LINK_VERSION;
  /** El idioma de la reserva (requests.locale): la página lo usa si la visitante no eligió otro. */
  locale: Locale;
  chefName: string;
  /** Solo un nombre de pila que parece un nombre (safeFirstName), o null. Nunca el nombre completo. */
  clientFirstName: string | null;
  weeks: ClientLinkWeek[];
}

/** 200 de POST …/confirm. already: ya estaba confirmado (no se avisó otra vez a Evelyn). */
export interface ConfirmMenuResponse {
  confirmedAt: string;
  already: boolean;
}

/** 200 de POST …/changes. */
export interface RequestChangesResponse {
  changesRequestedAt: string;
}

/** Los códigos de error ({ error }) de la función. */
export type ClientLinkErrorCode =
  | "linkNotFound"
  | "sendNotFound"
  | "menuOutdated"
  | "changesRequested"
  | "alreadyConfirmed"
  | "invalidText"
  | "invalidPayload"
  | "rateLimited"
  | "tooLarge"
  | "contentType"
  | "method"
  | "notFound"
  | "unavailable"
  | "server";

const TIME_PATTERN = /^([01]\d|2[0-3]):[0-5]\d$/;

/** "HH:MM" (00:00 a 23:59). */
export function isTimeOfDay(value: unknown): value is string {
  return typeof value === "string" && TIME_PATTERN.test(value);
}

/** Un timestamptz como lo devuelve la base o JSON (ISO 8601 con zona). */
export function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}T/.test(value) && !Number.isNaN(Date.parse(value));
}

function isTimestampOrNull(value: unknown): value is string | null {
  return value === null || isTimestamp(value);
}

function readMenu(value: unknown, storageOrigin: string | null): ClientLinkMenu | null {
  if (!isRecord(value)) return null;
  const { sendId, sentAt, state, confirmedAt, changesRequestedAt } = value;
  if (typeof sendId !== "string" || !isUuid(sendId) || !isTimestamp(sentAt)) return null;
  if (!isTimestampOrNull(confirmedAt) || !isTimestampOrNull(changesRequestedAt)) return null;
  if (!isOneOf(MENU_STATES, state) || state !== menuState(confirmedAt, changesRequestedAt)) return null;
  // Un contenido que esta página no puede leer no apaga la reserva: esa semana dice que no se puede mostrar.
  const content = readMenuContent(value["content"], storageOrigin);
  return { sendId: sendId.toLowerCase(), sentAt, state, confirmedAt, changesRequestedAt, content };
}

function readWeek(value: unknown, storageOrigin: string | null): ClientLinkWeek | null {
  if (!isRecord(value)) return null;
  const { week, weeks, date, start, done } = value;
  if (!isIntInRange(weeks, 1, 1000) || !isIntInRange(week, 1, weeks)) return null;
  if (typeof date !== "string" || !isIsoDate(date) || !isTimeOfDay(start) || typeof done !== "boolean") return null;
  const menuRaw = value["menu"];
  const menu = menuRaw === null ? null : readMenu(menuRaw, storageOrigin);
  if (menuRaw !== null && menu === null) return null;
  return { week, weeks, date, start, done, menu };
}

/**
 * Lectura defensiva en la web del 200 de POST …/view: null si no tiene la forma esperada (otra versión, un
 * proxy, un error). storageOrigin: el origen de Supabase de la web; las fotos de otro lado se descartan.
 */
export function parseClientLinkView(json: unknown, storageOrigin: string | null): ClientLinkView | null {
  if (!isRecord(json) || json["version"] !== CLIENT_LINK_VERSION) return null;
  const { locale, chefName, clientFirstName } = json;
  if (!isOneOf(LOCALES, locale) || !isText(chefName)) return null;
  if (clientFirstName !== null && !isText(clientFirstName)) return null;
  const weeks = readAll(json["weeks"], (item) => readWeek(item, storageOrigin));
  if (!weeks) return null;
  return { version: CLIENT_LINK_VERSION, locale, chefName, clientFirstName, weeks };
}
