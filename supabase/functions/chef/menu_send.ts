// Envío del menú de una semana a la clienta (POST /chef/menus/preview y /chef/menus/send, contrato
// docs/contracts/chef-api.md §13; SPEC 5.8): las partes puras que usa handler.ts, con sus tests en
// menu_send.test.ts (Node). La lectura de lo que devuelven las funciones SQL (chef_menu_send_context,
// chef_prepare_menu_send, chef_link_menu_send y chef_complete_menu_send, migración
// 20261121100000_menu_sends.sql), el armado de la foto del envío, el token del link y su hash.
//
// El token (32 bytes al azar, base64url) va solo en el link del mensaje, en el fragmento (#t=…): la base
// guarda su hash (sha-256 en hexadecimal) y nada de esto lo loguea ni lo guarda.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import { SESSION_STATUSES, isTimeOfDay, type MenuSendChannel, type MenuSendContact, type SessionStatus } from "../_shared/chef_api.ts";
import { recipePhotoUrls } from "../_shared/menu.ts";
import {
  MENU_SNAPSHOT_VERSION,
  readAllergenList,
  readMenuItem,
  type MenuSnapshot,
  type MenuSnapshotDish,
  type MenuSnapshotItem,
} from "../_shared/menu_snapshot.ts";
import {
  DIETS,
  LOCALES,
  isIsoDate,
  isOneOf,
  isValidEmail,
  normalizePhone,
  type Allergen,
  type Diet,
  type Locale,
} from "../_shared/public_request.ts";

// ---------------------------------------------------------------------------
// chef_menu_send_context
// ---------------------------------------------------------------------------

/** Un plato del menú como lo da la base: los textos en los tres idiomas (el italiano siempre). */
export interface ContextDish {
  recipeId: string;
  portions: number;
  nameIt: string;
  nameEs: string | null;
  nameEn: string | null;
  descriptionIt: string | null;
  descriptionEs: string | null;
  descriptionEn: string | null;
  diet: Diet | null;
  photoId: string | null;
  allergens: Allergen[];
}

export interface MenuSendContext {
  session: { id: string; date: string; start: string; status: SessionStatus; requestId: string; week: number; weeks: number };
  /** Las semanas no canceladas de la reserva, por fecha. */
  weeks: Array<{ date: string; start: string }>;
  /** El idioma de la clienta (requests.locale): el del mensaje. */
  locale: Locale;
  contact: MenuSendContact;
  chefName: string;
  menu: { version: number; note: string | null; dishes: ContextDish[]; items: MenuSnapshotItem[] };
}

const DB_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** La cocinera de un menú sin nombre (no debería pasar: chefs.display_name es not null), como public-request. */
const DEFAULT_CHEF_NAME = "Evelyn";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isDbUuid(value: unknown): value is string {
  return typeof value === "string" && DB_UUID.test(value);
}

function isPositiveInt(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 1;
}

/** Texto con algo más que espacios, o null (ausente, null, "" o solo espacios). undefined si es otra cosa. */
function optionalText(value: unknown): string | null | undefined {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string") return undefined;
  return value.trim() === "" ? null : value;
}

/** El contacto ({name, email, phone}) recortado; los vacíos, null (el nombre, ""). null si tiene otra forma. */
function readContact(value: unknown): MenuSendContact | null {
  if (!isRecord(value)) return null;
  const name = optionalText(value["name"]);
  const email = optionalText(value["email"]);
  const phone = optionalText(value["phone"]);
  if (name === undefined || email === undefined || phone === undefined) return null;
  return { name: name?.trim() ?? "", email: email?.trim() ?? null, phone: phone?.trim() ?? null };
}

function chefNameOf(value: unknown): string {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : DEFAULT_CHEF_NAME;
}

function readContextDish(value: unknown): ContextDish | null {
  if (!isRecord(value)) return null;
  const { recipeId, portions, nameIt, diet, photoId } = value;
  const texts = {
    nameEs: optionalText(value["nameEs"]),
    nameEn: optionalText(value["nameEn"]),
    descriptionIt: optionalText(value["descriptionIt"]),
    descriptionEs: optionalText(value["descriptionEs"]),
    descriptionEn: optionalText(value["descriptionEn"]),
  };
  const allergens = readAllergenList(value["allergens"]);
  if (!isDbUuid(recipeId) || !isPositiveInt(portions) || typeof nameIt !== "string" || nameIt.trim() === "" || !allergens) return null;
  if (texts.nameEs === undefined || texts.nameEn === undefined || texts.descriptionIt === undefined) return null;
  if (texts.descriptionEs === undefined || texts.descriptionEn === undefined) return null;
  if ((diet !== null && !isOneOf(DIETS, diet)) || (photoId !== null && !isDbUuid(photoId))) return null;
  return {
    recipeId,
    portions,
    nameIt,
    nameEs: texts.nameEs,
    nameEn: texts.nameEn,
    descriptionIt: texts.descriptionIt,
    descriptionEs: texts.descriptionEs,
    descriptionEn: texts.descriptionEn,
    diet,
    photoId,
    allergens,
  };
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

function readWeek(value: unknown): { date: string; start: string } | null {
  if (!isRecord(value)) return null;
  const { date, start } = value;
  return typeof date === "string" && isIsoDate(date) && isTimeOfDay(start) ? { date, start } : null;
}

/**
 * Resultado de chef_menu_send_context → lo que usa la función, o null si no tiene la forma esperada (un
 * 500: nunca un mensaje armado con datos rotos). lastSend no se usa.
 */
export function menuSendContextFromRpc(data: unknown): MenuSendContext | null {
  if (!isRecord(data)) return null;
  const session = data["session"];
  const request = data["request"];
  const menu = data["menu"];
  const chef = data["chef"];
  if (!isRecord(session) || !isRecord(request) || !isRecord(menu)) return null;
  const { id, date, start, status, requestId, week, weeks: total } = session;
  if (!isDbUuid(id) || typeof date !== "string" || !isIsoDate(date) || !isTimeOfDay(start)) return null;
  if (!isOneOf(SESSION_STATUSES, status) || !isDbUuid(requestId) || !isPositiveInt(week) || !isPositiveInt(total) || week > total) return null;
  const locale = request["locale"];
  const contact = readContact(data["contact"]);
  const weeks = readList(data["weeks"], readWeek);
  const version = menu["version"];
  const note = optionalText(menu["note"]);
  const dishes = readList(menu["dishes"], readContextDish);
  const items = readList(menu["items"], readMenuItem);
  if (!isOneOf(LOCALES, locale) || !contact || !weeks || !isPositiveInt(version) || note === undefined || !dishes || !items) return null;
  return {
    session: { id, date, start, status, requestId, week, weeks: total },
    weeks,
    locale,
    contact,
    chefName: chefNameOf(isRecord(chef) ? chef["displayName"] : null),
    menu: { version, note, dishes, items },
  };
}

// ---------------------------------------------------------------------------
// La foto del envío
// ---------------------------------------------------------------------------

/** El nombre de un plato en ese idioma: el italiano siempre; el español o el inglés si están. */
export function dishName(dish: ContextDish, locale: Locale): string {
  if (locale === "es") return dish.nameEs ?? dish.nameIt;
  if (locale === "en") return dish.nameEn ?? dish.nameIt;
  return dish.nameIt;
}

/** La descripción en ese idioma o, si no está, en italiano; null sin ninguna. */
export function dishDescription(dish: ContextDish, locale: Locale): string | null {
  const own = locale === "es" ? dish.descriptionEs : locale === "en" ? dish.descriptionEn : dish.descriptionIt;
  return own ?? dish.descriptionIt;
}

export interface SnapshotOptions {
  /** La cocina del token: la carpeta de las fotos en Storage. */
  chefId: string;
  /** photoOrigin(SUPABASE_URL): sin origen (functions serve, http://kong:8000), los platos van sin foto. */
  photoOrigin: string | null;
  /** Los nombres de la lista traducidos (cada nombre original → el suyo); null si no se tradujo. */
  itemNames: ReadonlyMap<string, string> | null;
  /** La nota que va: la traducida o la de Evelyn. */
  note: string | null;
}

/**
 * La foto del envío (menu_snapshot.ts), en el idioma de la clienta: los platos con sus textos en ese
 * idioma y las URL de sus fotos (como el menù de la web), la lista con los nombres traducidos si se
 * tradujo, la nota y las fechas. Nada de la clienta: ni contacto, ni dirección, ni alergias, ni precios.
 */
export function buildMenuSnapshot(context: MenuSendContext, options: SnapshotOptions): MenuSnapshot {
  const { locale, session } = context;
  const dishes: MenuSnapshotDish[] = context.menu.dishes.map((dish) => ({
    name: dishName(dish, locale),
    description: dishDescription(dish, locale),
    allergens: [...dish.allergens],
    diet: dish.diet,
    portions: dish.portions,
    photo:
      options.photoOrigin !== null && dish.photoId !== null
        ? recipePhotoUrls(options.photoOrigin, options.chefId, dish.recipeId, dish.photoId)
        : null,
  }));
  const items: MenuSnapshotItem[] = context.menu.items.map((item) => ({
    ...item,
    name: options.itemNames?.get(item.name) ?? item.name,
  }));
  return {
    v: MENU_SNAPSHOT_VERSION,
    locale,
    session: { date: session.date, start: session.start, week: session.week, weeks: session.weeks },
    weeks: context.weeks.map((week) => ({ date: week.date, start: week.start })),
    dishes,
    items,
    note: options.note,
  };
}

// ---------------------------------------------------------------------------
// El link de la clienta
// ---------------------------------------------------------------------------

/** Bytes al azar del token: 256 bits. */
export const CLIENT_TOKEN_BYTES = 32;

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** SHA-256 de un texto (UTF-8) en hexadecimal, en minúsculas: lo que guarda client_links.token_hash. */
export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Un token nuevo (WebCrypto, base64url sin relleno: 43 caracteres) y su hash. */
export async function newClientToken(): Promise<{ token: string; hash: string }> {
  const token = base64Url(crypto.getRandomValues(new Uint8Array(CLIENT_TOKEN_BYTES)));
  return { token, hash: await sha256Hex(token) };
}

/**
 * El link del mensaje: la página de la reserva en la web, con el token en el fragmento (#t=…), que el
 * navegador no manda a ningún servidor ni pone en el Referer. Nunca en la query.
 */
export function clientLinkUrl(siteUrl: string, token: string): string {
  return `${siteUrl.replace(/\/+$/, "")}/prenotazione/#t=${token}`;
}

/** La dirección del contacto si sirve para mandar un email; null si no hay o no tiene forma de email. */
export function sendableEmail(email: string | null): string | null {
  return email !== null && isValidEmail(email) ? email : null;
}

/** El teléfono del contacto en E.164 para WhatsApp, o null si no hay o no se puede normalizar. */
export function whatsappPhone(phone: string | null): string | null {
  return phone === null ? null : normalizePhone(phone);
}

// ---------------------------------------------------------------------------
// chef_prepare_menu_send, chef_link_menu_send y chef_complete_menu_send
// ---------------------------------------------------------------------------

/** Resultado de chef_prepare_menu_send ({sendId}) → el id, o null. */
export function preparedSendIdFromRpc(data: unknown): string | null {
  return isRecord(data) && isDbUuid(data["sendId"]) ? data["sendId"] : null;
}

export interface LinkedSend {
  sendId: string;
  locale: Locale;
  /** La foto tal como la guardó la base (se lee con readMenuSnapshot). */
  snapshot: unknown;
  /** El contacto de ahora: el del pedido de la web o el de la ficha. */
  contact: MenuSendContact;
  chefName: string;
}

/** Resultado de chef_link_menu_send, o null si no tiene la forma esperada. */
export function linkedSendFromRpc(data: unknown): LinkedSend | null {
  if (!isRecord(data)) return null;
  const sendId = data["sendId"];
  const locale = data["locale"];
  const contact = readContact(data["contact"]);
  if (!isDbUuid(sendId) || !isOneOf(LOCALES, locale) || !contact || !isRecord(data["snapshot"])) return null;
  return { sendId, locale, snapshot: data["snapshot"], contact, chefName: chefNameOf(data["chefName"]) };
}

const CHANNELS: readonly MenuSendChannel[] = ["email", "whatsapp"];
const TIMESTAMP = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/;

/** Resultado de chef_complete_menu_send ({sendId, sentAt, sentVia}), o null si no tiene la forma esperada. */
export function completedSendFromRpc(data: unknown): { sentAt: string; sentVia: MenuSendChannel[] } | null {
  if (!isRecord(data)) return null;
  const sentAt = data["sentAt"];
  const sentVia = data["sentVia"];
  if (typeof sentAt !== "string" || !TIMESTAMP.test(sentAt) || !Array.isArray(sentVia) || sentVia.length === 0) return null;
  if (!sentVia.every((channel) => isOneOf(CHANNELS, channel)) || new Set(sentVia).size !== sentVia.length) return null;
  return { sentAt, sentVia: CHANNELS.filter((channel) => (sentVia as unknown[]).includes(channel)) };
}
