// Link de la clienta (SPEC 5.8, docs/contracts/client-link.md): contrato entre la Edge Function client-link
// y la página /prenotazione/ de la web. Un solo origen, nada copiado.
//
// - El link: https://<sitio>/prenotazione/#t=<token>. El token son 32 bytes al azar en base64url (43
//   caracteres); va en el fragmento, que el navegador no manda a ningún servidor ni en el Referer. La base
//   guarda solo su hash (sha-256 del token en UTF-8, en hexadecimal): client_links.token_hash.
// - Lo que ve la clienta de cada semana es la foto del último envío del menú (menu_sends.snapshot), tal como
//   salió y ya en su idioma. readMenuSnapshot la lee campo por campo: lo que no es del contrato no pasa (ni a
//   la respuesta ni a la página), y una foto con otra forma no se muestra a medias.
// - El presupuesto (SPEC 5.8): el último que salió de la reserva, con su estado y su plazo, y lo que vio la
//   clienta (las semanas con su precio y el total), que sale de la foto del envío que lo llevó (el menú de la
//   semana 1, quote_snapshot.ts). Lo acepta (con el menú de esa semana) o lo rechaza desde la página.
// - Nunca pagos (ni cómo ni cuándo se paga), dirección ni las alergias de la clienta: la foto no los tiene y
//   nada de acá los lee. Del precio, solo el del servicio que propone el presupuesto.
// Solo sintaxis borrable (corre en Node, Deno y Vite sin compilar) e imports con extensión .ts.
import { readStoragePhoto, type MenuPhoto } from "./menu.ts";
import { ALLERGENS, DIETS, LOCALES, isIsoDate, isOneOf, isUuid, type Allergen, type Diet, type Locale } from "./public_request.ts";
import { readSnapshotQuote } from "./quote_snapshot.ts";

/**
 * Versión de la respuesta de POST …/view. Si cambia su forma, se sube: la página vieja dice que hubo un problema.
 * Sumar campos no la cambia: el presupuesto (quote) y el presupuesto de cada envío (menu.quoteId) llegaron así, y
 * la página los toma como ausentes si una función de antes no los manda.
 */
export const CLIENT_LINK_VERSION = 1;
/** Versión de la foto de un envío (snapshot.v) que se sabe leer. */
export const MENU_SNAPSHOT_VERSION = 1;

/** Nombre de la Edge Function (la URL es …/functions/v1/client-link/<ruta>). */
export const CLIENT_LINK_FUNCTION = "client-link";
/** Las rutas, todas POST con un JSON chico. */
export const CLIENT_LINK_ROUTES = { view: "/view", confirm: "/confirm", changes: "/changes", accept: "/accept", decline: "/decline" } as const;
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
/** Ingredientes de un plato (libro del menú): el check de recipe_ingredients.position (de 1 a 50). */
export const MAX_DISH_INGREDIENTS = 50;
/** Caracteres del nombre de un ingrediente: el check de recipe_ingredients.name. */
export const INGREDIENT_NAME_MAX = 80;
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

/** La clave del fragmento que abre el libro del menú de una semana: #t=<token>&libro=<sesión>. */
export const BOOK_FRAGMENT_PARAM = "libro";

/**
 * El link al libro del menú de una semana: el de la reserva con la sesión de esa semana, también en el fragmento
 * (#t=<token>&libro=<sesión>), nunca en la query. La sesión no abre nada sin el token.
 */
export function menuBookUrl(siteUrl: string, token: string, sessionId: string): string {
  return `${reservationPageUrl(siteUrl, token)}&${BOOK_FRAGMENT_PARAM}=${sessionId.toLowerCase()}`;
}

// ---------------------------------------------------------------------------
// Mensaje de cambios
// ---------------------------------------------------------------------------

/** Largo como lo cuenta Postgres (char_length): por code points, no por unidades UTF-16. */
export function textLength(text: string): number {
  return Array.from(text).length;
}

/**
 * Los saltos de línea que llegan pegados desde otros programas: \r\n y \r, la tabulación vertical y el salto de
 * página (los saltos manuales de Word y PowerPoint), NEL y los separadores de línea y de párrafo de Unicode.
 * Pasan a \n: es el único que acepta la base (glibc cuenta como control a los demás).
 */
const LINE_BREAKS = /\r\n?|[\v\f\x85\u2028\u2029]/g;
/** Los demás caracteres de control: no se ven y la base no los acepta, así que se sacan. La tabulación va aparte. */
const OTHER_CONTROLS = /[\x00-\x08\x0e-\x1f\x7f-\x9f]/g;

/**
 * El mensaje limpio, como lo acepta client_link_request_changes: los saltos de línea pasan a \n, las tabulaciones
 * a espacios, sin otros caracteres de control y recortado.
 */
export function cleanChangesText(value: string): string {
  return value.replace(LINE_BREAKS, "\n").replace(/\t/g, " ").replace(OTHER_CONTROLS, "").trim();
}

/** Lo que impide mandar un mensaje limpio: vacío o de más de 1000 caracteres. */
export type ChangesTextProblem = "empty" | "tooLong";

/** Lo que impide mandar un mensaje ya limpio (cleanChangesText), o null si se puede mandar. */
export function changesTextProblem(text: string): ChangesTextProblem | null {
  if (text === "") return "empty";
  return textLength(text) > CHANGES_TEXT_MAX ? "tooLong" : null;
}

/** El mensaje de cambios limpio (cleanChangesText) si se puede mandar (de 1 a 1000 caracteres); si no, null. */
export function normalizeChangesText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = cleanChangesText(value);
  return changesTextProblem(text) === null ? text : null;
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
  /**
   * Los nombres de sus ingredientes, sin cantidades (libro del menú), en el idioma del envío. Sin la clave: el plato
   * no tiene, o la foto es de antes del libro (22/11/2026); nunca una lista vacía.
   */
  ingredients?: string[];
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

/** Caracteres de control: un nombre de ingrediente va en una línea. */
const NAME_CONTROL = /[\u0000-\u001f\u007f-\u009f]/;

/**
 * Los nombres de los ingredientes de un plato (libro del menú), o undefined si no queda ninguno para mostrar. Como la
 * foto, nunca descartan el plato: si no es una lista, sale sin ingredientes; de una lista quedan los nombres de 1 a 80
 * caracteres en una línea, recortados, sin repetir (sin distinguir mayúsculas) y hasta 50.
 */
function readIngredients(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const names: string[] = [];
  const seen = new Set<string>();
  for (const item of value) {
    if (!isText(item) || NAME_CONTROL.test(item) || textLength(item.trim()) > INGREDIENT_NAME_MAX) continue;
    const name = item.trim();
    if (seen.has(name.toLowerCase())) continue;
    seen.add(name.toLowerCase());
    names.push(name);
    if (names.length === MAX_DISH_INGREDIENTS) break;
  }
  return names.length > 0 ? names : undefined;
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
  const ingredients = readIngredients(value["ingredients"]);
  return {
    name,
    description,
    allergens,
    diet,
    portions,
    photo: photo ? { thumb: photo.thumb, full: photo.full } : null,
    ...(ingredients ? { ingredients } : {}),
  };
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
  /**
   * El presupuesto que viaja con este envío (el menú de la semana 1 de un presupuesto), o null. Mientras ese
   * presupuesto está abierto, el menú no se confirma solo (quotePending): el envío que lo lleva (quote.sendId) se
   * acepta con el presupuesto, y uno anterior del mismo presupuesto que quedó en otra semana se confirma después de
   * aceptarlo. Aceptado, se contesta como cualquier menú.
   */
  quoteId: string | null;
  /** null: la foto no se puede leer. La página lo dice y no deja contestar lo que no muestra. */
  content: MenuContent | null;
}

/** Una semana de la reserva (las sesiones no canceladas, por fecha). */
export interface ClientLinkWeek {
  /**
   * La sesión (uuid): la identidad de la semana para la página. El número cambia si se cancela una semana
   * anterior, y la fecha si Evelyn la mueve; el id, no. No abre nada: para contestar hacen falta el token y el envío.
   */
  sessionId: string;
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

/**
 * Estado del presupuesto (client_link_view): sent, por aceptar; changed, Evelyn cambió el precio o una semana
 * después de mandarlo y todavía no lo reenvió (no se acepta: espera la versión nueva); accepted, declined
 * (lo rechazó la clienta), withdrawn (lo retiró Evelyn) o expired (pasó el plazo).
 */
export const QUOTE_STATUSES = ["sent", "changed", "accepted", "declined", "withdrawn", "expired"] as const;
export type QuoteStatus = (typeof QUOTE_STATUSES)[number];

/** Por qué un presupuesto ya no se contesta (el DETAIL de quote_closed). */
export const QUOTE_CLOSED_REASONS = ["accepted", "declined", "withdrawn", "expired"] as const;
export type QuoteClosedReason = (typeof QUOTE_CLOSED_REASONS)[number];

/** Una semana de lo que vio la clienta: la fecha, la llegada (Roma) y el precio del servicio de esa semana. */
export interface QuoteSummaryWeek {
  date: string;
  start: string;
  serviceCents: number;
}

/** Lo que vio la clienta en el envío que lleva el presupuesto: las semanas y el total, en centavos. */
export interface QuoteSummary {
  totalCents: number;
  weeks: QuoteSummaryWeek[];
}

/** El último presupuesto que salió de la reserva. */
export interface ClientLinkQuote {
  id: string;
  /**
   * La que ve la clienta: 1 el primer presupuesto que le llega del pedido (un borrador que nunca salió no cuenta);
   * cada reenvío, y uno nuevo después de otro que le llegó, la siguiente. Solo se acepta la última.
   */
  version: number;
  status: QuoteStatus;
  /** El último envío (timestamptz). */
  sentAt: string;
  /** Hasta cuándo se puede aceptar (timestamptz); null si la base no lo tiene. */
  holdUntil: string | null;
  acceptedAt: string | null;
  /** El último envío que lo llevó (el menú de la semana 1): con ese sendId se acepta o se rechaza. */
  sendId: string | null;
  /**
   * Lo que vio la clienta (la foto de ese envío), solo por aceptar (sent) o aceptado (accepted) y si la semana de
   * ese envío está en la reserva; si no, null (la página dice el estado sin precios).
   */
  summary: QuoteSummary | null;
}

/** 200 de POST …/view. */
export interface ClientLinkView {
  version: typeof CLIENT_LINK_VERSION;
  /** El idioma de la reserva (requests.locale): la página lo usa si la visitante no eligió otro. */
  locale: Locale;
  chefName: string;
  /**
   * El nombre de pila con que llegó el pedido (o, si no tiene, el de la ficha), solo si parece un nombre
   * (safeFirstName); si no, null. Nunca el nombre completo.
   */
  clientFirstName: string | null;
  /**
   * El último presupuesto que salió de la reserva, o null: una reserva sin presupuesto, o una que Evelyn confirmó
   * sin él después de que se cerrara sin aceptarse (no queda un «Ritirato» arriba de la reserva confirmada).
   */
  quote: ClientLinkQuote | null;
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

/**
 * 200 de POST …/accept: aceptó el presupuesto (y el menú de la semana 1, confirmado a la misma hora). already: ya
 * lo había aceptado (no se avisó otra vez a Evelyn).
 */
export interface AcceptQuoteResponse {
  acceptedAt: string;
  already: boolean;
}

/** 200 de POST …/decline. already: ya lo había rechazado. */
export interface DeclineQuoteResponse {
  already: boolean;
}

/** Los códigos de error ({ error }) de la función. */
export type ClientLinkErrorCode =
  | "linkNotFound"
  | "sendNotFound"
  | "menuOutdated"
  | "changesRequested"
  | "alreadyConfirmed"
  | "sessionCancelled"
  | "quotePending"
  | "quoteClosed"
  | "quoteChanged"
  | "notAQuote"
  | "quoteEmpty"
  | "invalidText"
  | "invalidPayload"
  | "rateLimited"
  | "tooLarge"
  | "contentType"
  | "method"
  | "notFound"
  | "unavailable"
  | "server";

/** El cuerpo de un error: el código y, en quoteClosed, por qué (si la base lo dice). */
export interface ClientLinkErrorBody {
  error: ClientLinkErrorCode;
  reason?: QuoteClosedReason;
}

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

/** Un uuid en minúsculas, null (ausente o null) o undefined (otra cosa): para los campos que pueden faltar. */
function optionalUuid(value: unknown): string | null | undefined {
  if (value === null || value === undefined) return null;
  return typeof value === "string" && isUuid(value) ? value.toLowerCase() : undefined;
}

function readMenu(value: unknown, storageOrigin: string | null): ClientLinkMenu | null {
  if (!isRecord(value)) return null;
  const { sendId, sentAt, state, confirmedAt, changesRequestedAt } = value;
  // Una función de antes no manda quoteId: sin presupuesto.
  const quoteId = optionalUuid(value["quoteId"]);
  if (typeof sendId !== "string" || !isUuid(sendId) || !isTimestamp(sentAt) || quoteId === undefined) return null;
  if (!isTimestampOrNull(confirmedAt) || !isTimestampOrNull(changesRequestedAt)) return null;
  if (!isOneOf(MENU_STATES, state) || state !== menuState(confirmedAt, changesRequestedAt)) return null;
  // Un contenido que esta página no puede leer no apaga la reserva: esa semana dice que no se puede mostrar.
  const content = readMenuContent(value["content"], storageOrigin);
  return { sendId: sendId.toLowerCase(), sentAt, state, confirmedAt, changesRequestedAt, quoteId, content };
}

function readSummaryWeek(value: unknown): QuoteSummaryWeek | null {
  if (!isRecord(value)) return null;
  const { date, start, serviceCents } = value;
  if (typeof date !== "string" || !isIsoDate(date) || !isTimeOfDay(start) || !isIntInRange(serviceCents, 0, Number.MAX_SAFE_INTEGER)) return null;
  return { date, start, serviceCents };
}

/** El resumen del presupuesto en la respuesta: null (ausente o null) o undefined si tiene otra forma. */
function readSummary(value: unknown): QuoteSummary | null | undefined {
  if (value === null || value === undefined) return null;
  if (!isRecord(value)) return undefined;
  const totalCents = value["totalCents"];
  const weeks = readAll(value["weeks"], readSummaryWeek);
  if (!isIntInRange(totalCents, 0, Number.MAX_SAFE_INTEGER) || !weeks || weeks.length === 0) return undefined;
  if (weeks.reduce((sum, week) => sum + week.serviceCents, 0) !== totalCents) return undefined;
  return { totalCents, weeks };
}

/** El presupuesto de la respuesta: null si no hay (o una función de antes no lo manda), undefined si tiene otra forma. */
function readQuote(value: unknown): ClientLinkQuote | null | undefined {
  if (value === null || value === undefined) return null;
  if (!isRecord(value)) return undefined;
  const { id, version, status, sentAt, holdUntil, acceptedAt } = value;
  const sendId = optionalUuid(value["sendId"]);
  const summary = readSummary(value["summary"]);
  if (typeof id !== "string" || !isUuid(id) || !isIntInRange(version, 1, 32_767) || !isOneOf(QUOTE_STATUSES, status)) return undefined;
  if (!isTimestamp(sentAt) || !isTimestampOrNull(holdUntil) || !isTimestampOrNull(acceptedAt) || sendId === undefined || summary === undefined) return undefined;
  if ((status === "accepted") !== (acceptedAt !== null)) return undefined;
  return { id: id.toLowerCase(), version, status, sentAt, holdUntil, acceptedAt, sendId, summary };
}

/**
 * Lo que vio la clienta del presupuesto, sacado de la foto del envío que lo lleva (su bloque quote): las semanas
 * con su fecha, su llegada y su precio, y el total. null si la foto no lo tiene o no cierra (quote_snapshot.ts).
 * Lo usa la función client-link para el resumen de POST …/view.
 */
export function quoteSummaryFromSnapshot(snapshot: unknown): QuoteSummary | null {
  if (!isRecord(snapshot)) return null;
  const quote = readSnapshotQuote(snapshot["quote"]);
  if (!quote) return null;
  return { totalCents: quote.totalCents, weeks: quote.weeks.map((week) => ({ date: week.date, start: week.start, serviceCents: week.serviceCents })) };
}

function readWeek(value: unknown, storageOrigin: string | null): ClientLinkWeek | null {
  if (!isRecord(value)) return null;
  const { sessionId, week, weeks, date, start, done } = value;
  if (typeof sessionId !== "string" || !isUuid(sessionId)) return null;
  if (!isIntInRange(weeks, 1, 1000) || !isIntInRange(week, 1, weeks)) return null;
  if (typeof date !== "string" || !isIsoDate(date) || !isTimeOfDay(start) || typeof done !== "boolean") return null;
  const menuRaw = value["menu"];
  const menu = menuRaw === null ? null : readMenu(menuRaw, storageOrigin);
  if (menuRaw !== null && menu === null) return null;
  return { sessionId: sessionId.toLowerCase(), week, weeks, date, start, done, menu };
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
  // Una función de antes no manda quote: una reserva sin presupuesto.
  const quote = readQuote(json["quote"]);
  if (!weeks || quote === undefined) return null;
  return { version: CLIENT_LINK_VERSION, locale, chefName, clientFirstName, quote, weeks };
}
