// Envío del menú de una semana a la clienta (POST /chef/menus/preview y /chef/menus/send, contrato
// docs/contracts/chef-api.md §13; SPEC 5.8): las partes puras que usa handler.ts, con sus tests en
// menu_send.test.ts (Node). La lectura de lo que devuelven las funciones SQL (chef_menu_send_context,
// chef_prepare_menu_send, chef_link_menu_send y chef_complete_menu_send, migración
// 20261121100000_menu_sends.sql), el armado de la foto del envío, el token del link y su hash.
// La huella del contexto (fingerprint) va tal cual a chef_prepare_menu_send: si algo de lo que entra en la
// foto cambió mientras se armaba (o se traducía la lista), la base no la guarda (menu_changed). En una semana
// held de un presupuesto abierto, la huella cubre también los términos del presupuesto (migración
// 20261121120000_quotes.sql): el de la semana 1 viaja en la foto (quote_snapshot.ts).
//
// El token (32 bytes al azar, base64url) va solo en el link del mensaje, en el fragmento (#t=…): la base
// guarda su hash (sha-256 en hexadecimal) y nada de esto lo loguea ni lo guarda.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import { CLIENT_LINK_TOKEN_BYTES, hashClientLinkToken, newClientLinkToken, reservationPageUrl } from "../_shared/client_link.ts";
import {
  SESSION_STATUSES,
  isTimeOfDay,
  type MenuSendChannel,
  type MenuSendContact,
  type QuoteTerms,
  type SessionStatus,
} from "../_shared/chef_api.ts";
import { recipePhotoUrls } from "../_shared/menu.ts";
import {
  MENU_SNAPSHOT_VERSION,
  readAllergenList,
  readMenuItem,
  type MenuSnapshot,
  type MenuSnapshotDish,
  type MenuSnapshotItem,
} from "../_shared/menu_snapshot.ts";
import { QUOTE_MAX_HOLD_HOURS, QUOTE_MAX_VERSION, quoteFirstStart, type SnapshotQuote } from "../_shared/quote_snapshot.ts";
import { quoteTermsFromRpc } from "./quotes.ts";
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

/**
 * El presupuesto abierto de una semana held (private.session_quote): su versión, si ya salió, el plazo de ahora,
 * las horas que tiene la clienta para aceptarlo desde que sale, si esta semana es la primera (la que lo lleva) y
 * sus términos de ahora (los mismos que guarda el envío y que la clienta acepta).
 */
export interface ContextQuote {
  id: string;
  version: number;
  sent: boolean;
  holdUntil: string | null;
  holdHours: number;
  firstWeek: boolean;
  terms: QuoteTerms;
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
  /** Solo en una semana held de un presupuesto abierto; null en las demás (una semana confirmada nunca lo tiene). */
  quote: ContextQuote | null;
  /**
   * La huella de lo que entra en la foto (private.menu_send_fingerprint: md5 en hexadecimal): el día y la
   * hora, las semanas de la reserva, la versión del menú, los platos del catálogo y, en una semana held, los
   * términos del presupuesto. Se le pasa a chef_prepare_menu_send; link y complete la recalculan antes de mandar.
   */
  fingerprint: string;
}

const FINGERPRINT = /^[0-9a-f]{32}$/;

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

const TIMESTAMP_PREFIX = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/;

/**
 * El presupuesto del contexto (quote), o null si no tiene (ausente o null), o undefined si tiene otra forma. Sus
 * términos tienen al menos una semana (la de esta sesión, que está viva) y, si es la primera, empiezan por ella.
 */
function readContextQuote(value: unknown, sessionId: string): ContextQuote | null | undefined {
  if (value === null || value === undefined) return null;
  if (!isRecord(value)) return undefined;
  const { id, version, sent, holdUntil, holdHours, firstWeek } = value;
  const terms = quoteTermsFromRpc(value["terms"]);
  if (!isDbUuid(id) || typeof version !== "number" || !Number.isInteger(version) || version < 1 || version > QUOTE_MAX_VERSION) return undefined;
  if (typeof sent !== "boolean" || typeof firstWeek !== "boolean") return undefined;
  if (holdUntil !== null && (typeof holdUntil !== "string" || !TIMESTAMP_PREFIX.test(holdUntil))) return undefined;
  if (!isPositiveInt(holdHours) || holdHours > QUOTE_MAX_HOLD_HOURS || !terms || terms.quoteId !== id || terms.weeks.length === 0) return undefined;
  if (firstWeek && terms.weeks[0]?.sessionId !== sessionId) return undefined;
  return { id, version, sent, holdUntil, holdHours, firstWeek, terms };
}

/**
 * Resultado de chef_menu_send_context → lo que usa la función, o null si no tiene la forma esperada (un
 * 500: nunca un mensaje armado con datos rotos). La base solo lo devuelve para una semana que se puede
 * mandar (held, confirmed o shopping_done, con número de semana): las otras dan session_not_editable.
 * lastSend no se usa.
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
  const fingerprint = data["fingerprint"];
  const quote = readContextQuote(data["quote"], id);
  if (!isOneOf(LOCALES, locale) || !contact || !weeks || !isPositiveInt(version) || note === undefined || !dishes || !items) return null;
  if (typeof fingerprint !== "string" || !FINGERPRINT.test(fingerprint) || quote === undefined) return null;
  // La base trae el presupuesto solo para una semana held.
  if (quote !== null && status !== "held") return null;
  return {
    session: { id, date, start, status, requestId, week, weeks: total },
    weeks,
    locale,
    contact,
    chefName: chefNameOf(isRecord(chef) ? chef["displayName"] : null),
    menu: { version, note, dishes, items },
    quote,
    fingerprint,
  };
}

/**
 * El presupuesto que viaja en la foto del envío (quote_snapshot.ts), o null: solo el de la semana 1 de un
 * presupuesto abierto (la base no deja mandar otra semana held: quote_week_not_first). La versión es la que va a
 * salir: la de ahora la primera vez y la siguiente en cada reenvío (chef_complete_menu_send la sube); las semanas
 * con su fecha, su llegada y su precio, el total y las horas para aceptarlo.
 */
export function snapshotQuoteOf(context: Pick<MenuSendContext, "quote">): SnapshotQuote | null {
  const quote = context.quote;
  if (!quote || !quote.firstWeek) return null;
  const weeks = quote.terms.weeks.map((week) => ({ date: week.date, start: week.start, serviceCents: week.serviceCents }));
  const first = weeks[0];
  if (!first) return null;
  return {
    version: quote.sent ? quote.version + 1 : quote.version,
    totalCents: quote.terms.totalCents,
    weeks,
    holdHours: quote.holdHours,
    firstStart: quoteFirstStart(first.date, first.start),
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
}

/**
 * La foto del envío (menu_snapshot.ts), en el idioma de la clienta: los platos con sus textos en ese
 * idioma y las URL de sus fotos (como el menù de la web), la lista con los nombres traducidos si se
 * tradujo, la nota tal como la escribió Evelyn (nunca se traduce) y las fechas. En la semana 1 de un
 * presupuesto abierto, también el presupuesto (snapshotQuoteOf: el servicio de cada semana y el total,
 * nunca nada de pagos). Nada de la clienta: ni contacto, ni dirección, ni alergias.
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
  const snapshot: MenuSnapshot = {
    v: MENU_SNAPSHOT_VERSION,
    locale,
    session: { date: session.date, start: session.start, week: session.week, weeks: session.weeks },
    weeks: context.weeks.map((week) => ({ date: week.date, start: week.start })),
    dishes,
    items,
    note: context.menu.note,
  };
  const quote = snapshotQuoteOf(context);
  if (quote) snapshot.quote = quote;
  return snapshot;
}

// ---------------------------------------------------------------------------
// El link de la clienta
// ---------------------------------------------------------------------------

/** Bytes al azar del token: 256 bits (los mismos que usa la página de la clienta). */
export const CLIENT_TOKEN_BYTES = CLIENT_LINK_TOKEN_BYTES;

/** SHA-256 de un texto (UTF-8) en hexadecimal, en minúsculas: lo que guarda client_links.token_hash. */
export const sha256Hex = hashClientLinkToken;

/** Un token nuevo (WebCrypto, base64url sin relleno: 43 caracteres) y su hash (_shared/client_link.ts). */
export async function newClientToken(): Promise<{ token: string; hash: string }> {
  const token = newClientLinkToken();
  return { token, hash: await hashClientLinkToken(token) };
}

/**
 * El link del mensaje: la página de la reserva en la web, con el token en el fragmento (#t=…), que el
 * navegador no manda a ningún servidor ni pone en el Referer. Nunca en la query.
 */
export function clientLinkUrl(siteUrl: string, token: string): string {
  return reservationPageUrl(siteUrl, token);
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
