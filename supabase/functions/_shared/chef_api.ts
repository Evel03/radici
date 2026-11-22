// Contrato de la Edge Function chef: la app de Evelyn → reservas, mover y cancelar sesiones, la
// traducción de los platos y el envío del menú de una semana a la clienta (docs/contracts/chef-api.md).
// Tipos de los cuerpos y de las respuestas, y la validación del servidor con los mismos límites que las
// funciones SQL (chef_create_booking, chef_move_session y chef_cancel_sessions, migración
// 20261116150100_bookings.sql; chef_prepare_menu_send y chef_link_menu_send, migración
// 20261121100000_menu_sends.sql), que vuelven a validar todo, y que los checks de recipes (los textos
// de un plato).
// La app (Dart) arma los cuerpos con estos nombres: si el contrato cambia, cambian los dos.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import {
  LOCALES,
  MEALS,
  REQUEST_TYPES,
  TEXT_LIMITS,
  addDays,
  cleanOneLine,
  isIsoDate,
  isOneOf,
  isUuid,
  isValidEmail,
  normalizePhone,
  type Locale,
  type Meal,
  type RequestType,
} from "./public_request.ts";
import { LIMITS } from "./quote.ts";

/** Rutas: POST <función>/<ruta>. */
export const CHEF_ROUTES = {
  bookings: "/bookings",
  moveSession: "/sessions/move",
  cancelSessions: "/sessions/cancel",
  translate: "/translate",
  menuPreview: "/menus/preview",
  menuSend: "/menus/send",
} as const;
export type ChefRoute = (typeof CHEF_ROUTES)[keyof typeof CHEF_ROUTES];

/** Una reserva es de 1 a 8 semanas, con una sesión de cocina por semana. */
export const MAX_WEEKS = 8;
/** Minutos de cocina de una sesión: de 1 a 720 (como chef_create_booking y chef_move_session). */
export const MAX_COOK_MINUTES = 720;
/** Porciones de una sesión: lo más que da quote.ts (30 adultos y 30 niños, 7 días, 2 comidas). */
export const MAX_PORTIONS = 2 * LIMITS.maxPeople * LIMITS.maxDays * LIMITS.maxMeals;
/** Tope de cualquier importe: 100.000 € en centavos (lejos del máximo de un int de Postgres). */
export const MAX_CENTS = 10_000_000;
/** Sesiones por cancelación (como chef_cancel_sessions). */
export const MAX_CANCEL_SESSIONS = 100;
/** Las fechas valen de hoy − 366 a hoy + 366 (en Roma): las pasadas, para cargar lo hecho en Fase 0. */
export const DATE_RANGE_DAYS = 366;
/** El servidor rechaza cuerpos más grandes (413). */
export const CHEF_MAX_PAYLOAD_BYTES = 8192;
/**
 * Largos de un plato, en caracteres (code points, como char_length en Postgres y textLength en la
 * app): los checks recipes_name_*_valido y recipes_description_*_valida.
 */
export const RECIPE_NAME_MAX = 120;
export const RECIPE_DESCRIPTION_MAX = 200;
/**
 * Caracteres de control que la base no acepta en un nombre ni en una descripción ([[:cntrl:]]): los
 * C0, DEL, los C1 y los separadores de línea y de párrafo (la app los normaliza igual, recipe.dart).
 */
export const RECIPE_TEXT_CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;
/** Las claves del cuerpo de POST /translate: cualquier otra es un 400. */
const TRANSLATE_KEYS: readonly string[] = ["name", "description"];
/** Las claves de POST /menus/preview y /menus/send: cualquier otra es un 400 (los arma solo la app). */
const MENU_PREVIEW_KEYS: readonly string[] = ["sessionId", "menuVersion", "translate"];
const MENU_SEND_KEYS: readonly string[] = ["sendId", "email", "whatsapp"];
/** Versión del menú: session_menus.version, un int de Postgres desde 1. */
export const MAX_MENU_VERSION = 2_147_483_647;
/** Largo máximo de la dirección de una ficha nueva. */
export const ADDRESS_MAX = 200;
/**
 * Motivos de cancelación, los mismos que acepta chef_cancel_sessions. Siempre uno de estos códigos,
 * nunca texto libre: el cliente con cuenta puede leer su sesión. chef_cancelled (por defecto),
 * client_cancelled (lo pidió la clienta) y chef_unavailable (Evelyn no puede ir).
 */
export const CANCEL_REASONS = ["chef_cancelled", "client_cancelled", "chef_unavailable"] as const;
export type CancelReason = (typeof CANCEL_REASONS)[number];
export const DEFAULT_CANCEL_REASON: CancelReason = "chef_cancelled";
const TIME_PATTERN = /^([01]\d|2[0-3]):[0-5]\d$/;

/**
 * Estado de cada fecha (private.booking_day_checks), en orden de prioridad. Solo busy (choca con
 * otra sesión) impide crear o mover; los demás son avisos: past (fecha pasada), blocked (día
 * bloqueado), closed (ese día no tiene horario), outside (fuera del horario del día) y ok.
 */
export const DAY_STATUSES = ["busy", "past", "blocked", "closed", "outside", "ok"] as const;
export type DayStatus = (typeof DAY_STATUSES)[number];

/** Estados de una sesión (el enum session_status). */
export const SESSION_STATUSES = ["held", "confirmed", "shopping_done", "cooked", "paid", "cancelled"] as const;
export type SessionStatus = (typeof SESSION_STATUSES)[number];

// ---------------------------------------------------------------------------
// Cuerpos (JSON, camelCase)
// ---------------------------------------------------------------------------

/** Ficha nueva de una reserva a mano. Sin restricciones: falta su consentimiento de salud (M2). */
export interface NewClientPayload {
  name: string;
  /** Se guarda en E.164 ("+393331234567"), como el formulario. */
  phone?: string | null;
  email?: string | null;
  zone?: string | null;
  address?: string | null;
}

/** Hogar y servicio del pedido de una reserva a mano (el check requests_datos_de_presupuesto los exige). */
export interface HouseholdPayload {
  adults: number;
  kids: number;
  days: number;
  meals: Meal[];
}

/** POST /bookings: confirmar una reserva de 1 a 8 semanas (una sesión confirmed por semana). */
export interface BookingPayload {
  /** La clienta, una sola de las tres: el pedido de la bandeja, una ficha existente o una nueva. */
  requestId?: string;
  clientId?: string;
  newClient?: NewClientPayload;
  /** A mano: obligatorio. Desde un pedido vale el del pedido (si viene, tiene que coincidir). */
  type?: RequestType;
  /** Solo a mano (desde un pedido se usan los del pedido). */
  household?: HouseholdPayload;
  /** Solo a mano: idioma de la clienta (it por defecto). */
  locale?: Locale;
  /** De 1 a 8 fechas "AAAA-MM-DD", una por semana ISO y en orden. */
  dates: string[];
  /** Llegada "HH:MM" (hora de Roma). Puede faltar solo en el dryRun: cada fecha se evalúa con su llegada sugerida. */
  start?: string | null;
  cookMinutes: number;
  /** Porciones de cada semana (0 por defecto). */
  portions?: number;
  // Sin groceriesEstCents desde el 19/11/2026: la compra la hace el cliente. Si llega (la app de antes lo
  // manda), se ignora como cualquier otra clave que el contrato no tiene.
  /**
   * Precio del servicio de toda la reserva, en centavos, que fija Evelyn; se reparte entre las
   * semanas. Obligatorio salvo en el dryRun (ninguna ruta lo cambia después); 0 vale: sin cargo.
   */
  serviceTotalCents?: number;
  /** UUID por intento: hace idempotente el reintento. Obligatoria a mano (salvo en el dryRun). */
  requestKey?: string;
  /** true: solo los chequeos de cada fecha, sin escribir nada. */
  dryRun?: boolean;
}

/** POST /sessions/move: mover una semana (solo una sesión held o confirmed). */
export interface MoveSessionPayload {
  sessionId: string;
  date: string;
  /** null o ausente: la hora guardada. */
  start?: string | null;
  /** null o ausente: los minutos guardados. */
  cookMinutes?: number | null;
  dryRun?: boolean;
}

/** POST /sessions/cancel: cancelar una o varias semanas (todo o nada). */
export interface CancelSessionsPayload {
  sessionIds: string[];
  /** Uno de CANCEL_REASONS (por defecto chef_cancelled), nunca texto libre. */
  reason?: CancelReason;
  /**
   * true: cancela también las semanas ya cobradas, para registrar la devolución. Sin esto, una
   * semana cobrada da 409 hasPayments: una cancelada ya no se puede pasar al final de la reserva.
   */
  allowWithPayments?: boolean;
}

/**
 * POST /translate: el nombre y la descripción de un plato, en español (la fuente), para traducirlos
 * al italiano y al inglés. Los mismos límites que la base; se recortan los espacios del borde.
 */
export interface TranslatePayload {
  /** De 1 a 120 caracteres, sin caracteres de control. */
  name: string;
  /** De 1 a 200 caracteres, o null (ausente, "" o solo espacios cuentan como null). */
  description?: string | null;
}

/**
 * POST /menus/preview: la vista previa del mensaje con el menú de una semana, en el idioma de la
 * clienta. Guarda el envío (todavía sin salir) con la foto de lo que va a recibir.
 */
export interface MenuPreviewPayload {
  sessionId: string;
  /** session_menus.version que la app tiene cargada: si Evelyn (o un colaborador) guardó otra, 409 menuChanged. */
  menuVersion: number;
  /**
   * Traducir los nombres de la lista de compras al idioma de la clienta (por defecto true). false: van
   * como los escribió Evelyn (la app lo ofrece si la traducción falla). La nota nunca se traduce.
   */
  translate?: boolean;
}

/** POST /menus/send: manda el envío de una vista previa por email, por WhatsApp o por los dos. */
export interface MenuSendPayload {
  sendId: string;
  /** Mandar el email desde el servidor (ausente = false). */
  email?: boolean;
  /** Devolver el texto para que la app abra WhatsApp desde el teléfono de Evelyn (ausente = false). */
  whatsapp?: boolean;
}

// ---------------------------------------------------------------------------
// Valores validados
// ---------------------------------------------------------------------------

export interface NormalizedNewClient {
  name: string;
  phone: string | null;
  email: string | null;
  zone: string | null;
  address: string | null;
}

export interface NormalizedHousehold {
  adults: number;
  kids: number;
  days: number;
  /** En orden canónico (lunch, dinner) y sin repetir. */
  meals: Meal[];
}

export type BookingClient =
  | { kind: "request"; requestId: string }
  | { kind: "client"; clientId: string }
  | { kind: "newClient"; newClient: NormalizedNewClient };

export interface NormalizedBooking {
  client: BookingClient;
  /** null: el del pedido. */
  type: RequestType | null;
  /** null desde un pedido. */
  household: NormalizedHousehold | null;
  /** null desde un pedido o si no vino (la base usa it). */
  locale: Locale | null;
  dates: string[];
  /** null solo en el dryRun. */
  start: string | null;
  cookMinutes: number;
  portions: number;
  serviceTotalCents: number;
  requestKey: string | null;
  dryRun: boolean;
}

export interface NormalizedMoveSession {
  sessionId: string;
  date: string;
  start: string | null;
  cookMinutes: number | null;
  dryRun: boolean;
}

export interface NormalizedCancelSessions {
  /** En minúsculas y sin repetir, en el orden recibido. */
  sessionIds: string[];
  reason: CancelReason;
  allowWithPayments: boolean;
}

/** El plato en español, recortado y dentro de los límites: lo que se traduce. */
export interface TranslationSource {
  name: string;
  description: string | null;
}

export interface NormalizedMenuPreview {
  /** En minúsculas. */
  sessionId: string;
  menuVersion: number;
  translate: boolean;
}

/** Por dónde sale un envío, en el orden de la base: 'email' antes que 'whatsapp'. */
export type MenuSendChannel = "email" | "whatsapp";

export interface NormalizedMenuSend {
  /** En minúsculas. */
  sendId: string;
  email: boolean;
  whatsapp: boolean;
}

// ---------------------------------------------------------------------------
// Errores
// ---------------------------------------------------------------------------

export type ChefApiErrorCode =
  | "required"
  | "invalid"
  | "range"
  | "tooLong"
  | "dateOutOfRange"
  | "sameWeek"
  | "order"
  | "weeksOnlyForWeek"
  | "conflict";

/** Campos de los 400. Los de un objeto anidado van con punto (newClient.name); client, people y cents agrupan. */
export type ChefApiField =
  | "payload"
  | "client"
  | "requestId"
  | "clientId"
  | "newClient"
  | "newClient.name"
  | "newClient.phone"
  | "newClient.email"
  | "newClient.zone"
  | "newClient.address"
  | "type"
  | "household"
  | "household.adults"
  | "household.kids"
  | "household.days"
  | "household.meals"
  | "people"
  | "locale"
  | "dates"
  | "start"
  | "cookMinutes"
  | "portions"
  | "serviceTotalCents"
  | "cents"
  | "requestKey"
  | "dryRun"
  | "sessionId"
  | "date"
  | "sessionIds"
  | "reason"
  | "allowWithPayments"
  | "name"
  | "description"
  | "menuVersion"
  | "translate"
  | "sendId"
  | "email"
  | "whatsapp"
  | "channels";

export type ChefApiErrors = Partial<Record<ChefApiField, ChefApiErrorCode>>;

/** Si falla, `date` es la fecha que causó el error de `dates` (fuera de rango, misma semana u orden). */
export type ChefParseResult<T> = { ok: true; value: T } | { ok: false; errors: ChefApiErrors; date?: string };

// ---------------------------------------------------------------------------
// Respuestas
// ---------------------------------------------------------------------------

export interface BookingWeek {
  date: string;
  /** "HH:MM"; null solo en un dryRun sin hora para un día sin horario. */
  start: string | null;
  cookMinutes: number;
  status: DayStatus;
  /** Primera llegada del día, como el calendario de la web; null si ese día no tiene horario. */
  suggestedStart: string | null;
  /** Parte del servicio de esa semana, en centavos. */
  serviceCents: number;
  /** null en el dryRun. */
  sessionId: string | null;
}

/** 200 (dryRun) o 201 (creada, o reintento con duplicate: true). */
export interface BookingResponse {
  dryRun: boolean;
  duplicate: boolean;
  /** null en el dryRun de una reserva a mano. */
  requestId: string | null;
  /** null en el dryRun de una ficha nueva. */
  clientId: string | null;
  weeks: BookingWeek[];
}

export interface MoveSessionResponse {
  dryRun: boolean;
  sessionId: string;
  requestId: string | null;
  date: string;
  start: string;
  cookMinutes: number;
  status: DayStatus;
  suggestedStart: string | null;
  /** Esa semana ya tiene otra sesión viva de la misma reserva (la app ofrece pasarla al final). */
  weekTaken: boolean;
}

export interface CancelSessionsResponse {
  cancelled: string[];
  alreadyCancelled: string[];
  /**
   * Las de la lista con algún cobro (canceladas ahora, con allowWithPayments, o antes): esperan su
   * devolución. Pasarlas al final de la reserva se ofrece antes de cancelar (409 hasPayments).
   */
  withPayments: string[];
  hadPayments: boolean;
}

/** Un plato traducido a un idioma, con los mismos límites que la base. */
export interface TranslatedDish {
  name: string;
  /** null si y solo si el pedido no tenía descripción. */
  description: string | null;
}

/** 200 de POST /translate: el plato en italiano y en inglés, siempre los dos (nunca a medias). */
export interface TranslateResponse {
  it: TranslatedDish;
  en: TranslatedDish;
}

/** El contacto de la clienta para el envío: el del pedido de la web o, si no lo tiene, el de la ficha. */
export interface MenuSendContact {
  name: string;
  email: string | null;
  phone: string | null;
}

/** El mensaje como lo ve Evelyn en la vista previa, en el idioma de la clienta y sin el link. */
export interface MenuPreviewMessage {
  subject: string;
  /** El texto del email (el HTML sale igual, con el diseño de los emails). */
  emailText: string;
  whatsappText: string;
}

/** 200 de POST /menus/preview. */
export interface MenuPreviewResponse {
  sendId: string;
  locale: Locale;
  /** Los nombres de la lista se tradujeron solos al idioma de la clienta (la nota nunca se traduce). */
  translated: boolean;
  /** Para que Evelyn lo revise antes de mandar: a dónde va a salir. */
  contact: MenuSendContact;
  message: MenuPreviewMessage;
}

/** 200 de POST /menus/send. */
export interface MenuSendResponse {
  /** timestamptz de la base (ISO 8601). */
  sentAt: string;
  sentVia: MenuSendChannel[];
  /** Solo si pidió WhatsApp: el texto con el link, para abrir WhatsApp desde el teléfono de Evelyn. */
  whatsappText?: string;
  /** Solo si pidió WhatsApp: el teléfono en E.164 ("+393331234567"; wa.me lo quiere sin el "+"). */
  whatsappPhone?: string;
}

export type ChefErrorCode =
  | "unauthorized"
  | "forbidden"
  | "notFound"
  | "requestNotFound"
  | "clientNotFound"
  | "sessionNotFound"
  | "method"
  | "contentType"
  | "tooLarge"
  | "slotTaken"
  | "weekTaken"
  | "requestNotNew"
  | "sessionNotMovable"
  | "invalidTransition"
  | "hasPayments"
  | "conflict"
  | "rateLimited"
  | "untranslatable"
  | "notConfigured"
  | "server"
  | "unavailable"
  | "menuNotFound"
  | "sendNotFound"
  | "sessionNotEditable"
  | "sessionWithoutRequest"
  | "menuChanged"
  | "menuEmpty"
  | "alreadySent"
  | "noEmail"
  | "noPhone"
  | "emailUnavailable"
  | "emailFailed";

/**
 * Cuerpo de un error: `errors` por campo (400) o un `error` con, según el caso, la fecha, el estado o las
 * sesiones. `emailSent`: en POST /menus/send, el email ya salió pero el envío no quedó marcado.
 */
export type ChefErrorBody =
  | { errors: ChefApiErrors; date?: string }
  | { error: ChefErrorCode; date?: string; status?: string; sessionId?: string; sessionIds?: string[]; emailSent?: boolean };

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** "HH:MM" de 00:00 a 23:59. */
export function isTimeOfDay(value: unknown): value is string {
  return typeof value === "string" && TIME_PATTERN.test(value);
}

/** Lunes de la semana ISO de una fecha "AAAA-MM-DD" válida (como date_trunc('week', …) en SQL). */
export function isoWeekMonday(iso: string): string {
  const weekday = new Date(`${iso}T00:00:00Z`).getUTCDay(); // 0 = domingo
  return addDays(iso, -((weekday + 6) % 7));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function absent(value: unknown): boolean {
  return value === undefined || value === null;
}

/** Entero dentro de [min, max]: un número que no es entero es invalid; uno fuera del rango, range. */
function readInt(errors: ChefApiErrors, field: ChefApiField, value: unknown, min: number, max: number): number | null {
  if (typeof value !== "number" || !Number.isInteger(value)) {
    errors[field] = "invalid";
    return null;
  }
  if (value < min || value > max) {
    errors[field] = "range";
    return null;
  }
  return value;
}

/** Texto de una línea, limpio. Vacío cuenta como ausente. */
function readText(errors: ChefApiErrors, field: ChefApiField, value: unknown, max: number, required: boolean): string | null {
  if (absent(value)) {
    if (required) errors[field] = "required";
    return null;
  }
  if (typeof value !== "string") {
    errors[field] = "invalid";
    return null;
  }
  const clean = cleanOneLine(value);
  if (clean === "") {
    if (required) errors[field] = "required";
    return null;
  }
  if (clean.length > max) {
    errors[field] = "tooLong";
    return null;
  }
  return clean;
}

function readUuid(errors: ChefApiErrors, field: ChefApiField, value: unknown): string | null {
  if (absent(value)) {
    errors[field] = "required";
    return null;
  }
  if (typeof value !== "string" || !isUuid(value)) {
    errors[field] = "invalid";
    return null;
  }
  return value.toLowerCase();
}

function readDryRun(errors: ChefApiErrors, value: unknown): boolean {
  if (absent(value)) return false;
  if (typeof value === "boolean") return value;
  errors.dryRun = "invalid";
  return false;
}

/** Comidas: 1 o 2 valores distintos de MEALS, en orden canónico. */
function parseMeals(value: unknown): Meal[] | null {
  if (!Array.isArray(value) || value.length === 0 || value.length > MEALS.length) return null;
  if (!value.every((meal) => isOneOf(MEALS, meal)) || new Set(value).size !== value.length) return null;
  return MEALS.filter((meal) => value.includes(meal));
}

type DatesCheck = { ok: true; dates: string[] } | { ok: false; code: ChefApiErrorCode; date?: string };

/** Fechas reales, a menos de DATE_RANGE_DAYS de hoy, una por semana ISO y en orden (como chef_create_booking). */
function checkDates(values: readonly unknown[], today: string): DatesCheck {
  const min = addDays(today, -DATE_RANGE_DAYS);
  const max = addDays(today, DATE_RANGE_DAYS);
  const dates: string[] = [];
  for (const value of values) {
    if (typeof value !== "string" || !isIsoDate(value)) return { ok: false, code: "invalid" };
    if (value < min || value > max) return { ok: false, code: "dateOutOfRange", date: value };
    dates.push(value);
  }
  let previous: string | null = null;
  for (const current of dates) {
    if (previous !== null) {
      // La fecha que falla es la segunda del par, como dates_same_week en SQL.
      if (isoWeekMonday(current) === isoWeekMonday(previous)) return { ok: false, code: "sameWeek", date: current };
      if (current < previous) return { ok: false, code: "order", date: current };
    }
    previous = current;
  }
  return { ok: true, dates };
}

function parseNewClient(raw: unknown, errors: ChefApiErrors): NormalizedNewClient | null {
  if (!isRecord(raw)) {
    errors.newClient = "invalid";
    return null;
  }
  const name = readText(errors, "newClient.name", raw["name"], TEXT_LIMITS.name, true);
  const phoneText = readText(errors, "newClient.phone", raw["phone"], TEXT_LIMITS.phone, false);
  const phone = phoneText === null ? null : normalizePhone(phoneText);
  if (phoneText !== null && phone === null) errors["newClient.phone"] = "invalid";
  const emailText = readText(errors, "newClient.email", raw["email"], TEXT_LIMITS.email, false);
  const email = emailText === null ? null : emailText.toLowerCase();
  if (email !== null && !isValidEmail(email)) errors["newClient.email"] = "invalid";
  const zone = readText(errors, "newClient.zone", raw["zone"], TEXT_LIMITS.zone, false);
  const address = readText(errors, "newClient.address", raw["address"], ADDRESS_MAX, false);
  const failed = Object.keys(errors).some((field) => field.startsWith("newClient"));
  if (name === null || failed) return null;
  return { name, phone, email, zone, address };
}

function parseHousehold(raw: unknown, errors: ChefApiErrors): NormalizedHousehold | null {
  if (absent(raw)) {
    errors.household = "required";
    return null;
  }
  if (!isRecord(raw)) {
    errors.household = "invalid";
    return null;
  }
  const count = (field: ChefApiField, value: unknown, min: number, max: number): number | null => {
    if (absent(value)) {
      errors[field] = "required";
      return null;
    }
    return readInt(errors, field, value, min, max);
  };
  const adults = count("household.adults", raw["adults"], 0, LIMITS.maxPeople);
  const kids = count("household.kids", raw["kids"], 0, LIMITS.maxPeople);
  const days = count("household.days", raw["days"], 1, LIMITS.maxDays);
  const meals = parseMeals(raw["meals"]);
  if (meals === null) errors["household.meals"] = absent(raw["meals"]) ? "required" : "invalid";
  if (adults !== null && kids !== null && adults + kids < 1) errors.people = "range";
  if (adults === null || kids === null || days === null || meals === null || errors.people) return null;
  return { adults, kids, days, meals };
}

function failure<T>(errors: ChefApiErrors, date?: string): ChefParseResult<T> {
  return date === undefined ? { ok: false, errors } : { ok: false, errors, date };
}

// ---------------------------------------------------------------------------
// Validación del servidor
// ---------------------------------------------------------------------------

const CLIENT_KEYS = ["requestId", "clientId", "newClient"] as const;

/**
 * Valida y normaliza el cuerpo de POST /bookings. Pura: `today` es la fecha de hoy en Europe/Rome
 * (romeToday). Los campos que solo valen a mano (household, locale) se ignoran desde un pedido.
 */
export function parseBookingRequest(input: unknown, opts: { today: string }): ChefParseResult<NormalizedBooking> {
  if (!isRecord(input)) return failure({ payload: "invalid" });
  const errors: ChefApiErrors = {};
  let failedDate: string | undefined;

  const dryRun = readDryRun(errors, input["dryRun"]);

  // La clienta: una sola de las tres.
  const present = CLIENT_KEYS.filter((key) => !absent(input[key]));
  const manual = present.length === 1 && present[0] !== "requestId";
  let client: BookingClient | null = null;
  if (present.length === 0) errors.client = "required";
  else if (present.length > 1) errors.client = "invalid";
  else if (present[0] === "requestId") {
    const requestId = readUuid(errors, "requestId", input["requestId"]);
    if (requestId) client = { kind: "request", requestId };
  } else if (present[0] === "clientId") {
    const clientId = readUuid(errors, "clientId", input["clientId"]);
    if (clientId) client = { kind: "client", clientId };
  } else {
    const newClient = parseNewClient(input["newClient"], errors);
    if (newClient) client = { kind: "newClient", newClient };
  }

  let type: RequestType | null = null;
  if (absent(input["type"])) {
    if (manual) errors.type = "required";
  } else if (isOneOf(REQUEST_TYPES, input["type"])) {
    type = input["type"];
  } else {
    errors.type = "invalid";
  }

  let household: NormalizedHousehold | null = null;
  let locale: Locale | null = null;
  if (manual) {
    household = parseHousehold(input["household"], errors);
    if (!absent(input["locale"])) {
      if (isOneOf(LOCALES, input["locale"])) locale = input["locale"];
      else errors.locale = "invalid";
    }
  }

  let dates: string[] | null = null;
  const rawDates = input["dates"];
  if (absent(rawDates)) errors.dates = "required";
  else if (!Array.isArray(rawDates)) errors.dates = "invalid";
  else if (rawDates.length < 1 || rawDates.length > MAX_WEEKS) errors.dates = "range";
  else {
    const checked = checkDates(rawDates, opts.today);
    if (checked.ok) dates = checked.dates;
    else {
      errors.dates = checked.code;
      failedDate = checked.date;
    }
  }
  // Más de una semana solo en un pedido semanal (un evento es de una sola). Desde un pedido sin
  // tipo explícito lo controla la base, que conoce el tipo del pedido.
  if (dates !== null && dates.length > 1 && type !== null && type !== "week") errors.dates = "weeksOnlyForWeek";

  let start: string | null = null;
  if (absent(input["start"])) {
    if (!dryRun) errors.start = "required";
  } else if (isTimeOfDay(input["start"])) {
    start = input["start"];
  } else {
    errors.start = "invalid";
  }

  let cookMinutes: number | null = null;
  if (absent(input["cookMinutes"])) errors.cookMinutes = "required";
  else cookMinutes = readInt(errors, "cookMinutes", input["cookMinutes"], 1, MAX_COOK_MINUTES);

  const optionalInt = (field: "portions" | "serviceTotalCents", max: number): number =>
    absent(input[field]) ? 0 : readInt(errors, field, input[field], 0, max) ?? 0;
  const portions = optionalInt("portions", MAX_PORTIONS);
  // El precio lo fija Evelyn al confirmar y ninguna ruta lo cambia después: sin él no se crea nada
  // (0 vale: sin cargo). En el dryRun puede faltar (las semanas salen con 0).
  if (absent(input["serviceTotalCents"]) && !dryRun) errors.serviceTotalCents = "required";
  const serviceTotalCents = optionalInt("serviceTotalCents", MAX_CENTS);

  let requestKey: string | null = null;
  const rawKey = input["requestKey"];
  if (!absent(rawKey)) {
    if (typeof rawKey === "string" && isUuid(rawKey)) requestKey = rawKey.toLowerCase();
    else errors.requestKey = "invalid";
  } else if (manual && !dryRun) {
    // A mano el reintento solo es seguro con la clave (desde un pedido lo reconoce el estado).
    errors.requestKey = "required";
  }

  if (Object.keys(errors).length > 0 || client === null || dates === null || cookMinutes === null) {
    return failure(errors, failedDate);
  }
  return {
    ok: true,
    value: {
      client,
      type,
      household,
      locale,
      dates,
      start,
      cookMinutes,
      portions,
      serviceTotalCents,
      requestKey,
      dryRun,
    },
  };
}

/** Valida y normaliza el cuerpo de POST /sessions/move. `today`: la fecha de hoy en Europe/Rome. */
export function parseMoveSessionRequest(input: unknown, opts: { today: string }): ChefParseResult<NormalizedMoveSession> {
  if (!isRecord(input)) return failure({ payload: "invalid" });
  const errors: ChefApiErrors = {};
  const dryRun = readDryRun(errors, input["dryRun"]);
  const sessionId = readUuid(errors, "sessionId", input["sessionId"]);

  let date: string | null = null;
  const rawDate = input["date"];
  if (absent(rawDate)) errors.date = "required";
  else if (typeof rawDate !== "string" || !isIsoDate(rawDate)) errors.date = "invalid";
  else if (rawDate < addDays(opts.today, -DATE_RANGE_DAYS) || rawDate > addDays(opts.today, DATE_RANGE_DAYS)) errors.date = "dateOutOfRange";
  else date = rawDate;

  let start: string | null = null;
  if (!absent(input["start"])) {
    if (isTimeOfDay(input["start"])) start = input["start"];
    else errors.start = "invalid";
  }
  const cookMinutes = absent(input["cookMinutes"]) ? null : readInt(errors, "cookMinutes", input["cookMinutes"], 1, MAX_COOK_MINUTES);

  if (Object.keys(errors).length > 0 || sessionId === null || date === null) return failure(errors);
  return { ok: true, value: { sessionId, date, start, cookMinutes, dryRun } };
}

/** Valida y normaliza el cuerpo de POST /sessions/cancel. */
export function parseCancelSessionsRequest(input: unknown): ChefParseResult<NormalizedCancelSessions> {
  if (!isRecord(input)) return failure({ payload: "invalid" });
  const errors: ChefApiErrors = {};

  let sessionIds: string[] | null = null;
  const raw = input["sessionIds"];
  if (absent(raw)) errors.sessionIds = "required";
  else if (!Array.isArray(raw)) errors.sessionIds = "invalid";
  else if (raw.length < 1 || raw.length > MAX_CANCEL_SESSIONS) errors.sessionIds = "range";
  else if (!raw.every((id) => typeof id === "string" && isUuid(id))) errors.sessionIds = "invalid";
  else sessionIds = [...new Set(raw.map((id) => String(id).toLowerCase()))];

  let reason: CancelReason = DEFAULT_CANCEL_REASON;
  const rawReason = input["reason"];
  if (!absent(rawReason)) {
    if (isOneOf(CANCEL_REASONS, rawReason)) reason = rawReason;
    else errors.reason = "invalid";
  }

  let allowWithPayments = false;
  const rawAllow = input["allowWithPayments"];
  if (!absent(rawAllow)) {
    if (typeof rawAllow === "boolean") allowWithPayments = rawAllow;
    else errors.allowWithPayments = "invalid";
  }

  if (Object.keys(errors).length > 0 || sessionIds === null) return failure(errors);
  return { ok: true, value: { sessionIds, reason, allowWithPayments } };
}

/** Largo como lo cuenta Postgres (char_length) y la app (textLength): por code points, no por unidades UTF-16. */
export function textLength(text: string): number {
  return Array.from(text).length;
}

/**
 * Nombre o descripción de un plato, como lo acepta la base: recortado, sin caracteres de control y
 * de 1 a `max` caracteres. Ausente, null, "" o solo espacios: required si es obligatorio; si no, null.
 */
function readRecipeText(errors: ChefApiErrors, field: "name" | "description", value: unknown, max: number, required: boolean): string | null {
  if (absent(value)) {
    if (required) errors[field] = "required";
    return null;
  }
  if (typeof value !== "string") {
    errors[field] = "invalid";
    return null;
  }
  const text = value.trim();
  if (text === "") {
    if (required) errors[field] = "required";
    return null;
  }
  if (RECIPE_TEXT_CONTROL.test(text)) {
    errors[field] = "invalid";
    return null;
  }
  if (textLength(text) > max) {
    errors[field] = "tooLong";
    return null;
  }
  return text;
}

/**
 * Valida y normaliza el cuerpo de POST /translate: el plato en español. Una clave que el contrato no
 * tiene es payload invalid (no se ignora: el pedido es corto y lo arma solo la app).
 */
export function parseTranslateRequest(input: unknown): ChefParseResult<TranslationSource> {
  if (!isRecord(input)) return failure({ payload: "invalid" });
  const errors: ChefApiErrors = {};
  if (Object.keys(input).some((key) => !TRANSLATE_KEYS.includes(key))) errors.payload = "invalid";
  const name = readRecipeText(errors, "name", input["name"], RECIPE_NAME_MAX, true);
  const description = readRecipeText(errors, "description", input["description"], RECIPE_DESCRIPTION_MAX, false);
  if (Object.keys(errors).length > 0 || name === null) return failure(errors);
  return { ok: true, value: { name, description } };
}

/** true/false; ausente o null: `fallback`. Otro tipo: invalid. */
function readBoolean(errors: ChefApiErrors, field: ChefApiField, value: unknown, fallback: boolean): boolean {
  if (absent(value)) return fallback;
  if (typeof value === "boolean") return value;
  errors[field] = "invalid";
  return fallback;
}

/**
 * Valida y normaliza el cuerpo de POST /menus/preview. Una clave que el contrato no tiene es payload
 * invalid (como en /translate: el pedido es corto y lo arma solo la app).
 */
export function parseMenuPreviewRequest(input: unknown): ChefParseResult<NormalizedMenuPreview> {
  if (!isRecord(input)) return failure({ payload: "invalid" });
  const errors: ChefApiErrors = {};
  if (Object.keys(input).some((key) => !MENU_PREVIEW_KEYS.includes(key))) errors.payload = "invalid";
  const sessionId = readUuid(errors, "sessionId", input["sessionId"]);
  let menuVersion: number | null = null;
  if (absent(input["menuVersion"])) errors.menuVersion = "required";
  else menuVersion = readInt(errors, "menuVersion", input["menuVersion"], 1, MAX_MENU_VERSION);
  const translate = readBoolean(errors, "translate", input["translate"], true);
  if (Object.keys(errors).length > 0 || sessionId === null || menuVersion === null) return failure(errors);
  return { ok: true, value: { sessionId, menuVersion, translate } };
}

/**
 * Valida y normaliza el cuerpo de POST /menus/send: el envío y por dónde sale, al menos uno (si no,
 * channels required). Una clave que el contrato no tiene es payload invalid.
 */
export function parseMenuSendRequest(input: unknown): ChefParseResult<NormalizedMenuSend> {
  if (!isRecord(input)) return failure({ payload: "invalid" });
  const errors: ChefApiErrors = {};
  if (Object.keys(input).some((key) => !MENU_SEND_KEYS.includes(key))) errors.payload = "invalid";
  const sendId = readUuid(errors, "sendId", input["sendId"]);
  const email = readBoolean(errors, "email", input["email"], false);
  const whatsapp = readBoolean(errors, "whatsapp", input["whatsapp"], false);
  if (!email && !whatsapp && !errors.email && !errors.whatsapp) errors.channels = "required";
  if (Object.keys(errors).length > 0 || sendId === null) return failure(errors);
  return { ok: true, value: { sendId, email, whatsapp } };
}

/** Los canales de un envío en el orden de la base (chef_complete_menu_send los ordena igual). */
export function menuSendChannels(value: Pick<NormalizedMenuSend, "email" | "whatsapp">): MenuSendChannel[] {
  const channels: MenuSendChannel[] = [];
  if (value.email) channels.push("email");
  if (value.whatsapp) channels.push("whatsapp");
  return channels;
}
