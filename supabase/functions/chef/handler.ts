// Lógica de la Edge Function chef: el área de Evelyn (docs/contracts/chef-api.md). Es la única puerta
// para crear, mover y cancelar sesiones: los estados de sesión solo cambian vía Edge Functions.
// También traduce los platos con Claude y manda a la clienta el menú de cada semana (SPEC 5.8). No
// depende de Deno, de supabase-js, de Resend ni del SDK de Anthropic: index.ts arma las dependencias
// reales y los tests (handler.test.ts, en Node) las simulan.
//
// Rutas, todas POST: /bookings (chef_create_booking), /sessions/move (chef_move_session),
// /sessions/cancel (chef_cancel_sessions), /translate (el traductor) y el envío del menú de una semana:
// /menus/preview (chef_menu_send_context y chef_prepare_menu_send) y /menus/send (chef_link_menu_send,
// el email y chef_complete_menu_send). Orden: CORS → ruta (404) → método (405) → configuración (500) →
// token (401) → usuario, con auth.getUser (401; 503 si Auth no responde) → su cocina, con
// public.chef_id_for_user: la de la que es dueña o colaborador (403 si no es de ninguna) → tipo (415) →
// tamaño (413) → JSON y validación (400) → función SQL con la cocina del token → 200 o 201, o el error
// de la base traducido (400, 404, 409, 500 o 503).
// - /translate, después de la validación: traductor configurado (501) → límite por cocina (429) →
//   traductor (200, 422, 503 o 500).
// - /menus/preview: lo necesario para el mensaje (chef_menu_send_context: 404, o 409 si la semana ya
//   no se manda; otra versión del menú o un menú sin platos, 409, antes de gastar una traducción) → si la
//   clienta no lee español y hay lista, la traducción de sus renglones (nunca la nota), como /translate y
//   con el mismo límite → la foto del envío y el envío sin salir (chef_prepare_menu_send, con la huella
//   del contexto: si algo cambió mientras tanto, 409) → 200 con el mensaje sin el link.
// - /menus/send: la web del link configurada (500) → el email configurado, si lo pidió (503) → el link
//   (un token nuevo; la base guarda su hash: chef_link_menu_send) → el contacto (409 sin email o sin
//   teléfono) → el email (502 si no sale: el envío queda sin marcar) → chef_complete_menu_send → 200,
//   con el texto del WhatsApp si lo pidió (lo abre la app; el servidor nunca manda WhatsApp).
//
// Los logs llevan solo evento, ruta, códigos, contadores, largos e ids: nunca nombres, teléfonos,
// emails, direcciones, notas, restricciones, fechas, el texto de un plato o de la lista, el mensaje
// ni el token del link.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import {
  CHEF_MAX_PAYLOAD_BYTES,
  CHEF_ROUTES,
  DAY_STATUSES,
  MAX_CANCEL_SESSIONS,
  SESSION_STATUSES,
  menuSendChannels,
  parseBookingRequest,
  parseCancelSessionsRequest,
  parseMenuPreviewRequest,
  parseMenuSendRequest,
  parseMoveSessionRequest,
  parseTranslateRequest,
  textLength,
  type BookingResponse,
  type BookingWeek,
  type CancelReason,
  type CancelSessionsResponse,
  type ChefApiErrorCode,
  type ChefApiErrors,
  type ChefApiField,
  type ChefErrorBody,
  type ChefErrorCode,
  type ChefRoute,
  type MenuPreviewResponse,
  type MenuSendChannel,
  type MenuSendResponse,
  type MoveSessionResponse,
  type NormalizedBooking,
  type TranslationSource,
} from "../_shared/chef_api.ts";
import { corsHeaders, parseAllowedOrigins, type OriginRule } from "../_shared/cors.ts";
import {
  StoreError,
  isJsonContentType,
  logStoreError,
  readBodyLimited,
  resolveServiceKey,
  safeDbMessage,
  type LogFields,
  type Logger,
} from "../_shared/edge.ts";
import { brandFromMailFrom, safeHttpUrl } from "../_shared/emails.ts";
import { photoOrigin } from "../_shared/menu.ts";
import { renderMenuMessage } from "../_shared/menu_message.ts";
import { readMenuSnapshot, type MenuSnapshot } from "../_shared/menu_snapshot.ts";
import { isIsoDate, isOneOf, isUuid, romeToday, type Locale, type Meal, type RequestType } from "../_shared/public_request.ts";
import type { EmailMessage, SendOutcome } from "../_shared/resend.ts";
import {
  buildMenuSnapshot,
  clientLinkUrl,
  completedSendFromRpc,
  linkedSendFromRpc,
  menuSendContextFromRpc,
  newClientToken,
  preparedSendIdFromRpc,
  sendableEmail,
  whatsappPhone,
  type MenuSendContext,
} from "./menu_send.ts";
import {
  menuTextSource,
  readMenuTranslationOutput,
  translatedItemNames,
  type MenuTextTranslation,
} from "./menu_translation.ts";
import {
  TRANSLATE_RATE_LIMITS,
  TRANSLATE_RETRY_AFTER_SECONDS,
  readTranslationOutput,
  translateRateKey,
  readTranslationConfig,
  type TranslationMode,
  type Translator,
  type TranslatorReply,
} from "./translation.ts";

/** Nombre de la función: la plataforma le pasa la ruta como /chef/<ruta>. */
export const FUNCTION_NAME = "chef";
/** La función solo atiende POST (y el preflight). */
export const CHEF_CORS_METHODS = "POST, OPTIONS";
/** Un JWT de Supabase mide menos de 2 KB; más que esto no se manda a Auth. */
export const MAX_TOKEN_LENGTH = 8192;

// ---------------------------------------------------------------------------
// Configuración
// ---------------------------------------------------------------------------

export interface ChefConfig {
  /** ALLOWED_ORIGINS, la misma variable que public-request (contrato public-request §4). */
  allowedOrigins: OriginRule[];
  /** Variables sin las que no se puede atender nada (→ 500). Las pone Supabase. */
  missing: string[];
  /**
   * De dónde sale la traducción de los platos: Claude (ANTHROPIC_API_KEY), la de mentira
   * (TRANSLATE_TRANSPORT=fake, solo con un Supabase local) u off (POST /translate responde 501). La
   * clave no queda acá: la lee solo index.ts para armar el cliente.
   */
  translation: TranslationMode;
  /** TRANSLATE_TRANSPORT=fake fuera de un Supabase local: ignorado (error al arrancar y en cada pedido). */
  translationFakeIgnored: boolean;
  /**
   * El origen de las URL de las fotos de los platos en la foto del envío del menú (photoOrigin de
   * SUPABASE_URL, como el menù de la web); null con functions serve (http://kong:8000): sin fotos.
   */
  photoOrigin: string | null;
  /** EMAIL_TRANSPORT: resend (por defecto) o log (desarrollo: no manda nada, registra solo metadatos). */
  emailTransport: "resend" | "log";
  /** MAIL_FROM, el remitente de los emails (el mismo que public-request). */
  mailFrom: string | null;
  /** A dónde van las respuestas de la clienta: MAIL_REPLY_TO o, si falta, CHEF_NOTIFY_EMAIL (Evelyn). */
  mailReplyTo: string | null;
  /** Hay RESEND_API_KEY. La clave no queda acá: la lee solo index.ts para armar el Mailer. */
  resendConfigured: boolean;
  /** PUBLIC_SITE_URL (http o https): la web del link de la clienta. Sin ella, POST /menus/send da 500. */
  publicSiteUrl: string | null;
}

export function readChefConfig(get: (name: string) => string | undefined): ChefConfig {
  const value = (name: string): string | null => {
    const raw = get(name)?.trim();
    return raw ? raw : null;
  };
  const missing: string[] = [];
  if (!value("SUPABASE_URL")) missing.push("SUPABASE_URL");
  if (!resolveServiceKey(get)) missing.push("SUPABASE_SECRET_KEYS");
  const translation = readTranslationConfig(get);
  return {
    allowedOrigins: parseAllowedOrigins(get("ALLOWED_ORIGINS")),
    missing,
    translation: translation.mode,
    translationFakeIgnored: translation.fakeIgnored,
    photoOrigin: photoOrigin(value("SUPABASE_URL")),
    emailTransport: value("EMAIL_TRANSPORT")?.toLowerCase() === "log" ? "log" : "resend",
    mailFrom: value("MAIL_FROM"),
    mailReplyTo: value("MAIL_REPLY_TO") ?? value("CHEF_NOTIFY_EMAIL"),
    resendConfigured: value("RESEND_API_KEY") !== null,
    publicSiteUrl: safeHttpUrl(value("PUBLIC_SITE_URL")),
  };
}

/**
 * Lo que falta sin cortar todo, para el aviso del arranque (solo nombres de variables): sin
 * ALLOWED_ORIGINS la bandeja web (/gestione/) no puede llamar a la función (la app nativa sí); sin
 * ANTHROPIC_API_KEY la traducción queda apagada; sin PUBLIC_SITE_URL no se puede mandar el menú (no hay
 * link); con Resend, sin RESEND_API_KEY o MAIL_FROM el menú no sale por email (solo por WhatsApp); sin
 * MAIL_REPLY_TO ni CHEF_NOTIFY_EMAIL, las respuestas de la clienta van al remitente.
 */
export function chefConfigWarnings(config: ChefConfig): string[] {
  const warnings: string[] = [];
  if (config.allowedOrigins.length === 0) warnings.push("ALLOWED_ORIGINS");
  if (config.translation === "off") warnings.push("ANTHROPIC_API_KEY");
  if (!config.publicSiteUrl) warnings.push("PUBLIC_SITE_URL");
  if (config.emailTransport === "resend") {
    if (!config.resendConfigured) warnings.push("RESEND_API_KEY");
    if (!config.mailFrom) warnings.push("MAIL_FROM");
  }
  if (!config.mailReplyTo) warnings.push("MAIL_REPLY_TO");
  return warnings;
}

// ---------------------------------------------------------------------------
// Acceso a Auth y a la base (index.ts lo implementa con supabase-js y la clave secreta)
// ---------------------------------------------------------------------------

/** Argumentos de public.chef_create_booking (snake_case, como la base). */
export type CreateBookingParams = {
  p_chef_id: string;
  p_dates: string[];
  p_start: string | null;
  p_cook_minutes: number;
  p_portions: number;
  /** Siempre 0: la compra la hace el cliente (19/11/2026). La firma de la función SQL no cambia. */
  p_groceries_est_cents: 0;
  p_service_total_cents: number;
  p_request_id: string | null;
  p_client_id: string | null;
  p_new_client: { name: string; phone: string | null; email: string | null; zone: string | null; address: string | null } | null;
  p_type: RequestType | null;
  p_household: { adults: number; kids: number; days: number; meals: Meal[] } | null;
  p_locale: Locale | null;
  p_request_key: string | null;
  p_dry_run: boolean;
};

/** Argumentos de public.chef_move_session. */
export type MoveSessionParams = {
  p_chef_id: string;
  p_session_id: string;
  p_date: string;
  p_start: string | null;
  p_cook_minutes: number | null;
  p_dry_run: boolean;
};

/** Argumentos de public.chef_cancel_sessions. */
export type CancelSessionsParams = {
  p_chef_id: string;
  p_session_ids: string[];
  p_reason: CancelReason;
  p_allow_with_payments: boolean;
};

/** Argumentos de public.chef_menu_send_context. */
export type MenuSendContextParams = { p_chef_id: string; p_session_id: string };

/**
 * Argumentos de public.chef_prepare_menu_send. p_translated: se tradujo la lista; p_fingerprint: la
 * huella del contexto con que se armó la foto (si ya no es la de la base, menu_changed).
 */
export type PrepareMenuSendParams = {
  p_chef_id: string;
  p_session_id: string;
  p_menu_version: number;
  p_locale: Locale;
  p_snapshot: MenuSnapshot;
  p_translated: boolean;
  p_fingerprint: string;
};

/** Argumentos de public.chef_link_menu_send: el hash sha-256 (hexadecimal) del token, nunca el token. */
export type LinkMenuSendParams = { p_chef_id: string; p_send_id: string; p_token_hash: string };

/** Argumentos de public.chef_complete_menu_send. */
export type CompleteMenuSendParams = { p_chef_id: string; p_send_id: string; p_via: MenuSendChannel[] };

export interface ChefStore {
  /** auth.getUser: el id del usuario del token; null si Auth lo rechaza. Lanza StoreError si Auth no responde. */
  userIdFromToken(token: string): Promise<string | null>;
  /**
   * public.chef_id_for_user tal cual: el chefs.id de la cocina de la que el usuario es dueño
   * (chefs.profile_id) o colaborador (chef_members), o null si no es de ninguna. Lo interpreta
   * chefIdFromRpc.
   */
  chefIdForUser(userId: string): Promise<unknown>;
  /** public.chef_create_booking: el jsonb tal cual. */
  createBooking(params: CreateBookingParams): Promise<unknown>;
  /** public.chef_move_session: el jsonb tal cual. */
  moveSession(params: MoveSessionParams): Promise<unknown>;
  /** public.chef_cancel_sessions: el jsonb tal cual. */
  cancelSessions(params: CancelSessionsParams): Promise<unknown>;
  /**
   * public.hit_public_request_rate (la misma del formulario, con otra clave: translateRateKey):
   * registra el intento y dice si está dentro de los topes.
   */
  hitRateLimit(key: string, maxPerHour: number, maxPerDay: number): Promise<boolean>;
  /** public.chef_menu_send_context: el jsonb tal cual (lo interpreta menuSendContextFromRpc). */
  menuSendContext(params: MenuSendContextParams): Promise<unknown>;
  /** public.chef_prepare_menu_send: el jsonb tal cual ({sendId}). */
  prepareMenuSend(params: PrepareMenuSendParams): Promise<unknown>;
  /** public.chef_link_menu_send: el jsonb tal cual. */
  linkMenuSend(params: LinkMenuSendParams): Promise<unknown>;
  /** public.chef_complete_menu_send: el jsonb tal cual ({sendId, sentAt, sentVia}). */
  completeMenuSend(params: CompleteMenuSendParams): Promise<unknown>;
}

/** Manda un email: index.ts lo arma con Resend y RESEND_API_KEY (sendWithResend); null sin la clave. */
export interface Mailer {
  send(message: EmailMessage): Promise<SendOutcome>;
}

export function toCreateBookingParams(chefId: string, value: NormalizedBooking): CreateBookingParams {
  const { client } = value;
  return {
    p_chef_id: chefId,
    p_dates: [...value.dates],
    p_start: value.start,
    p_cook_minutes: value.cookMinutes,
    p_portions: value.portions,
    p_groceries_est_cents: 0,
    p_service_total_cents: value.serviceTotalCents,
    p_request_id: client.kind === "request" ? client.requestId : null,
    p_client_id: client.kind === "client" ? client.clientId : null,
    p_new_client: client.kind === "newClient" ? { ...client.newClient } : null,
    p_type: value.type,
    p_household: value.household ? { ...value.household, meals: [...value.household.meals] } : null,
    p_locale: value.locale,
    p_request_key: value.requestKey,
    p_dry_run: value.dryRun,
  };
}

// ---------------------------------------------------------------------------
// Errores de Auth y de la base
// ---------------------------------------------------------------------------

/** Lo que supabase-js devuelve como error de PostgREST ({ code, message, details, hint }). */
export interface DbErrorLike {
  code?: string | null;
  message?: string | null;
  details?: unknown;
  hint?: unknown;
}

const REQUEST_STATUSES = ["new", "quoted", "accepted", "declined", "rejected", "expired", "resolved"] as const;
const DATE_DETAIL_CODES = new Set(["slot_taken", "week_taken", "dates_same_week"]);

/**
 * El detalle de los errores propios de las funciones SQL, solo si tiene la forma esperada: la fecha
 * del choque, el estado actual, la sesión que impide cancelar o las sesiones ya cobradas (ids
 * separados por coma, como mucho MAX_CANCEL_SESSIONS). Cualquier otro detalle (el de Postgres
 * puede traer la fila, con datos personales) se descarta.
 */
export function safeDbDetail(message: string | null, detail: unknown): string | null {
  if (message === null || typeof detail !== "string") return null;
  if (DATE_DETAIL_CODES.has(message)) return isIsoDate(detail) ? detail : null;
  if (message === "request_not_new") return isOneOf(REQUEST_STATUSES, detail) ? detail : null;
  if (message === "session_not_movable" || message === "session_not_editable") return isOneOf(SESSION_STATUSES, detail) ? detail : null;
  if (message === "invalid_transition") return isUuid(detail) ? detail.toLowerCase() : null;
  if (message === "has_payments") {
    const ids = detail.split(",");
    return ids.length <= MAX_CANCEL_SESSIONS && ids.every(isUuid) ? detail.toLowerCase() : null;
  }
  return null;
}

/** Error de supabase-js → StoreError sin datos: el mensaje solo si es un código propio, el detalle filtrado y nunca el hint. */
export function storeErrorFrom(op: string, error: DbErrorLike): StoreError {
  const message = safeDbMessage(error.message);
  return new StoreError(op, error.code ? error.code : null, message, safeDbDetail(message, error.details));
}

/** auth.getUser falló: Auth rechazó el token (4xx: vencido, inválido, sesión cerrada) o no respondió (429, 5xx, red). */
export function authFailureKind(status: number | undefined): "invalid" | "unavailable" {
  return typeof status === "number" && status >= 400 && status < 500 && status !== 429 ? "invalid" : "unavailable";
}

/** Sin código (sin respuesta de la base), conexión, transacción, recursos o PostgREST sin base: se puede reintentar. */
function isRetryable(code: string | null): boolean {
  return code === null || /^(08|40|53|57|58)/.test(code) || /^PGRST00[0-3]$/.test(code);
}

export interface ErrorReply {
  status: number;
  body: ChefErrorBody;
}

const NOT_FOUND = new Map<string, ChefErrorCode>([
  ["request_not_found", "requestNotFound"],
  ["client_not_found", "clientNotFound"],
  ["session_not_found", "sessionNotFound"],
  ["menu_not_found", "menuNotFound"],
  ["send_not_found", "sendNotFound"],
]);

/**
 * Validaciones de las funciones del envío del menú (22023) que nunca son culpa de la app: la función
 * armó mal el pedido (la foto, el hash del token o los canales). 500, no 400.
 */
const SERVER_SIDE_INVALID = new Set(["invalid_snapshot", "invalid_token", "invalid_via"]);

/** Validaciones de las funciones SQL (22023) → campo y código del 400. La función valida antes: es la defensa. */
const FIELD_ERRORS = new Map<string, readonly [ChefApiField, ChefApiErrorCode]>([
  ["invalid_client", ["client", "invalid"]],
  ["invalid_dates", ["dates", "invalid"]],
  ["dates_same_week", ["dates", "sameWeek"]],
  ["invalid_start", ["start", "required"]],
  ["invalid_cook_minutes", ["cookMinutes", "range"]],
  ["invalid_portions", ["portions", "range"]],
  ["invalid_cents", ["cents", "range"]],
  ["invalid_request_type", ["type", "invalid"]],
  ["weeks_only_for_week", ["dates", "weeksOnlyForWeek"]],
  ["invalid_household", ["household", "invalid"]],
  ["invalid_locale", ["locale", "invalid"]],
  ["invalid_new_client", ["newClient", "invalid"]],
  ["name_required", ["newClient.name", "required"]],
  ["request_key_required", ["requestKey", "required"]],
  ["request_key_conflict", ["requestKey", "conflict"]],
  ["invalid_date", ["date", "invalid"]],
  ["invalid_sessions", ["sessionIds", "invalid"]],
  ["invalid_reason", ["reason", "invalid"]],
]);

/** 503 si se puede reintentar, 500 si no. */
function serverFailure(error: unknown): ErrorReply {
  return error instanceof StoreError && isRetryable(error.code)
    ? { status: 503, body: { error: "unavailable" } }
    : { status: 500, body: { error: "server" } };
}

/**
 * Error de una función SQL → respuesta. 409: choques (slot_taken y week_taken, con la fecha) y estados
 * que no lo permiten; 404: lo que no existe para esta cocinera; 400: validaciones; 503 o 500: el resto.
 */
export function dbErrorReply(error: unknown): ErrorReply {
  if (!(error instanceof StoreError)) return { status: 500, body: { error: "server" } };
  const { code, safeMessage: message, safeDetail: detail } = error;

  // El menú cambió desde la vista previa (40001, la clase de los reintentos): reintentar igual no sirve.
  if (code === "40001" && message === "menu_changed") return { status: 409, body: { error: "menuChanged" } };

  if (code === "23P01" || code === "23505") {
    if (detail && message === "slot_taken") return { status: 409, body: { error: "slotTaken", date: detail } };
    if (detail && message === "week_taken") return { status: 409, body: { error: "weekTaken", date: detail } };
    return { status: 409, body: { error: "conflict" } };
  }
  if (code === "55000") {
    if (message === "request_not_new") return { status: 409, body: detail ? { error: "requestNotNew", status: detail } : { error: "requestNotNew" } };
    if (message === "session_not_movable") {
      return { status: 409, body: detail ? { error: "sessionNotMovable", status: detail } : { error: "sessionNotMovable" } };
    }
    if (message === "invalid_transition") {
      return { status: 409, body: detail ? { error: "invalidTransition", sessionId: detail } : { error: "invalidTransition" } };
    }
    if (message === "has_payments") {
      return { status: 409, body: detail ? { error: "hasPayments", sessionIds: detail.split(",") } : { error: "hasPayments" } };
    }
    if (message === "session_not_editable") {
      return { status: 409, body: detail ? { error: "sessionNotEditable", status: detail } : { error: "sessionNotEditable" } };
    }
    if (message === "session_without_request") return { status: 409, body: { error: "sessionWithoutRequest" } };
    if (message === "already_sent") return { status: 409, body: { error: "alreadySent" } };
    return { status: 409, body: { error: "conflict" } };
  }
  if (code === "P0002") {
    const notFound = message === null ? undefined : NOT_FOUND.get(message);
    // chef_not_found: la cocinera está en chefs pero no en chef_settings (configuración rota).
    return notFound ? { status: 404, body: { error: notFound } } : { status: 500, body: { error: "server" } };
  }
  if (code === "22023") {
    if (message === "menu_empty") return { status: 409, body: { error: "menuEmpty" } };
    if (message !== null && SERVER_SIDE_INVALID.has(message)) return { status: 500, body: { error: "server" } };
    const field = message === null ? undefined : FIELD_ERRORS.get(message);
    const errors: ChefApiErrors = {};
    if (field) errors[field[0]] = field[1];
    else errors.payload = "invalid";
    return { status: 400, body: detail && message === "dates_same_week" ? { errors, date: detail } : { errors } };
  }
  // Otro dato inválido (22xxx) o un check / not null de la tabla: algo del cuerpo que la validación no cubrió.
  if (code !== null && (code.startsWith("22") || code === "23514" || code === "23502")) {
    return { status: 400, body: { errors: { payload: "invalid" } } };
  }
  return serverFailure(error);
}

// ---------------------------------------------------------------------------
// Respuestas de las funciones SQL → cuerpo de la API (camelCase, horas HH:MM)
// ---------------------------------------------------------------------------

const DB_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DB_TIME = /^([01]\d|2[0-3]):([0-5]\d)(?::[0-5]\d(?:\.\d+)?)?$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isDbUuid(value: unknown): value is string {
  return typeof value === "string" && DB_UUID.test(value);
}

function isUuidList(value: unknown): value is string[] {
  return Array.isArray(value) && value.every(isDbUuid);
}

function isCount(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

/**
 * Resultado de public.chef_id_for_user: el uuid de la cocina (como lo escribe Postgres, en
 * minúsculas), null si el usuario no es dueño ni colaborador de ninguna, o undefined si tiene otra
 * forma (la respuesta no se entiende: 500, nunca un acceso).
 */
export function chefIdFromRpc(data: unknown): string | null | undefined {
  if (data === null) return null;
  return isDbUuid(data) ? data : undefined;
}

/** time de Postgres ("10:00:00") → "10:00"; null si es null; undefined si no tiene esa forma. */
function timeOf(value: unknown): string | null | undefined {
  if (value === null) return null;
  if (typeof value !== "string") return undefined;
  const match = DB_TIME.exec(value);
  return match ? `${match[1]}:${match[2]}` : undefined;
}

function bookingWeekFromRpc(value: unknown): BookingWeek | null {
  if (!isRecord(value)) return null;
  const date = value["date"];
  const start = timeOf(value["start_time"]);
  const suggestedStart = timeOf(value["suggested_start"]);
  const cookMinutes = value["cook_minutes"];
  const status = value["status"];
  const serviceCents = value["service_cents"];
  const sessionId = value["session_id"];
  if (typeof date !== "string" || !isIsoDate(date) || start === undefined || suggestedStart === undefined) return null;
  if (!isCount(cookMinutes) || !isCount(serviceCents) || !isOneOf(DAY_STATUSES, status)) return null;
  if (sessionId !== null && !isDbUuid(sessionId)) return null;
  return { date, start, cookMinutes, status, suggestedStart, serviceCents, sessionId };
}

/** Resultado de chef_create_booking ({dry_run, duplicate, request_id, client_id, weeks}), o null si no tiene esa forma. */
export function bookingResponseFromRpc(data: unknown): BookingResponse | null {
  if (!isRecord(data)) return null;
  const dryRun = data["dry_run"];
  const duplicate = data["duplicate"];
  const requestId = data["request_id"];
  const clientId = data["client_id"];
  const rawWeeks = data["weeks"];
  if (typeof dryRun !== "boolean" || typeof duplicate !== "boolean" || !Array.isArray(rawWeeks)) return null;
  if ((requestId !== null && !isDbUuid(requestId)) || (clientId !== null && !isDbUuid(clientId))) return null;
  const weeks: BookingWeek[] = [];
  for (const raw of rawWeeks) {
    const week = bookingWeekFromRpc(raw);
    if (!week) return null;
    weeks.push(week);
  }
  return { dryRun, duplicate, requestId: requestId as string | null, clientId: clientId as string | null, weeks };
}

/** Resultado de chef_move_session, o null si no tiene esa forma. */
export function moveSessionResponseFromRpc(data: unknown): MoveSessionResponse | null {
  if (!isRecord(data)) return null;
  const dryRun = data["dry_run"];
  const sessionId = data["session_id"];
  const requestId = data["request_id"];
  const date = data["date"];
  const start = timeOf(data["start_time"]);
  const cookMinutes = data["cook_minutes"];
  const status = data["status"];
  const suggestedStart = timeOf(data["suggested_start"]);
  const weekTaken = data["week_taken"];
  if (typeof dryRun !== "boolean" || typeof weekTaken !== "boolean" || !isDbUuid(sessionId)) return null;
  if (requestId !== null && !isDbUuid(requestId)) return null;
  if (typeof date !== "string" || !isIsoDate(date) || typeof start !== "string" || suggestedStart === undefined) return null;
  if (!isCount(cookMinutes) || !isOneOf(DAY_STATUSES, status)) return null;
  return { dryRun, sessionId, requestId: requestId as string | null, date, start, cookMinutes, status, suggestedStart, weekTaken };
}

/** Resultado de chef_cancel_sessions, o null si no tiene esa forma. */
export function cancelSessionsResponseFromRpc(data: unknown): CancelSessionsResponse | null {
  if (!isRecord(data)) return null;
  const cancelled = data["cancelled"];
  const alreadyCancelled = data["already_cancelled"];
  const withPayments = data["with_payments"];
  const hadPayments = data["had_payments"];
  if (!isUuidList(cancelled) || !isUuidList(alreadyCancelled) || !isUuidList(withPayments) || typeof hadPayments !== "boolean") return null;
  return { cancelled, alreadyCancelled, withPayments, hadPayments };
}

// ---------------------------------------------------------------------------
// Ruta y token
// ---------------------------------------------------------------------------

const ROUTES: ReadonlySet<string> = new Set(Object.values(CHEF_ROUTES));

function isChefRoute(route: string): route is ChefRoute {
  return ROUTES.has(route);
}

/**
 * La ruta que sigue al nombre de la función: "/chef/bookings" (así llega en la plataforma) y
 * "/functions/v1/chef/bookings" dan "/bookings"; "/chef", ""; sin el nombre de la función, null.
 */
export function routeOf(pathname: string): string | null {
  const segments = pathname.split("/").filter((segment) => segment !== "");
  const index = segments.indexOf(FUNCTION_NAME);
  if (index === -1) return null;
  const rest = segments.slice(index + 1);
  return rest.length === 0 ? "" : `/${rest.join("/")}`;
}

const BEARER = /^Bearer\s+([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/i;

/**
 * El JWT de «Authorization: Bearer <token>», o null. Una clave de API (sb_publishable_…, sb_secret_…)
 * no es un JWT: el chequeo de la plataforma la deja pasar, la función no la manda ni a Auth.
 */
export function bearerToken(header: string | null): string | null {
  const token = BEARER.exec((header ?? "").trim())?.[1];
  return token && token.length <= MAX_TOKEN_LENGTH ? token : null;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

export interface ChefHandlerDeps {
  config: ChefConfig;
  store: ChefStore;
  /** Claude (claude_translator.ts), el de mentira o null si la traducción está apagada (501). */
  translator: Translator | null;
  /** Resend (index.ts) o null sin RESEND_API_KEY: el menú no sale por email (503 emailUnavailable). */
  mailer: Mailer | null;
  now: () => Date;
  log: Logger;
}

type Reply = (status: number, body: unknown, extra?: Record<string, string>) => Response;

/**
 * Quién llama: su usuario (la cocinera o un colaborador suyo) y la cocina con que trabaja. El usuario va
 * en los logs de lo que cambia (con colaboradores, la cocina son varias cuentas); las funciones SQL
 * reciben solo la cocina.
 */
type Caller = { chefId: string; userId: string };

type AuthResult = ({ ok: true } & Caller) | { ok: false; status: number; body: ChefErrorBody; headers?: Record<string, string> };

const UNAUTHORIZED: AuthResult = { ok: false, status: 401, body: { error: "unauthorized" }, headers: { "WWW-Authenticate": "Bearer" } };

/**
 * El usuario del token (auth.getUser) y su cocina (public.chef_id_for_user): la de la que es dueña o
 * colaborador. Cualquier otro usuario, 403.
 */
async function authenticate(deps: ChefHandlerDeps, request: Request, route: ChefRoute): Promise<AuthResult> {
  const { store, log } = deps;
  const header = request.headers.get("authorization");
  const token = bearerToken(header);
  if (!token) {
    log("info", "auth_rejected", { route, reason: header ? "malformed" : "missing" });
    return UNAUTHORIZED;
  }

  let userId: string | null;
  try {
    userId = await store.userIdFromToken(token);
  } catch (error) {
    // Un token inválido no llega acá (devuelve null): Auth no respondió.
    logStoreError(log, error, "get_user");
    return { ok: false, status: 503, body: { error: "unavailable" } };
  }
  if (!userId) {
    log("info", "auth_rejected", { route, reason: "invalid" });
    return UNAUTHORIZED;
  }

  let raw: unknown;
  try {
    raw = await store.chefIdForUser(userId);
  } catch (error) {
    logStoreError(log, error, "load_chef");
    const failure = serverFailure(error);
    return { ok: false, status: failure.status, body: failure.body };
  }
  const chefId = chefIdFromRpc(raw);
  if (chefId === undefined) {
    log("error", "unexpected_result", { op: "load_chef" });
    return { ok: false, status: 500, body: { error: "server" } };
  }
  if (chefId === null) {
    log("info", "forbidden", { route, userId });
    return { ok: false, status: 403, body: { error: "forbidden" } };
  }
  return { ok: true, chefId, userId };
}

function invalidPayload(log: Logger, route: ChefRoute, failure: { errors: ChefApiErrors; date?: string }, reply: Reply): Response {
  log("info", "invalid_payload", { route, fields: Object.keys(failure.errors) });
  return reply(400, failure.date === undefined ? { errors: failure.errors } : { errors: failure.errors, date: failure.date });
}

/** Error de una función SQL: el código va al log (sin mensaje de Postgres ni detalle) y la respuesta, traducida. */
function dbFailure(log: Logger, route: ChefRoute, op: string, error: unknown, reply: Reply): Response {
  const mapped = dbErrorReply(error);
  if (mapped.status >= 500) {
    logStoreError(log, error, op);
  } else {
    const store = error instanceof StoreError ? error : null;
    log("info", "rejected", {
      route,
      status: mapped.status,
      error: "error" in mapped.body ? mapped.body.error : "invalid",
      code: store?.code ?? null,
      message: store?.safeMessage ?? null,
    });
  }
  return reply(mapped.status, mapped.body);
}

function unexpectedResult(log: Logger, op: string, reply: Reply): Response {
  log("error", "unexpected_result", { op });
  return reply(500, { error: "server" });
}

async function bookingsRoute(deps: ChefHandlerDeps, caller: Caller, input: unknown, reply: Reply): Promise<Response> {
  const { log } = deps;
  const route = CHEF_ROUTES.bookings;
  const parsed = parseBookingRequest(input, { today: romeToday(deps.now()) });
  if (!parsed.ok) return invalidPayload(log, route, parsed, reply);

  let data: unknown;
  try {
    data = await deps.store.createBooking(toCreateBookingParams(caller.chefId, parsed.value));
  } catch (error) {
    return dbFailure(log, route, "create_booking", error, reply);
  }
  const result = bookingResponseFromRpc(data);
  if (!result || result.dryRun !== parsed.value.dryRun) return unexpectedResult(log, "create_booking", reply);
  if (result.dryRun) return reply(200, result);
  if (result.duplicate) {
    // Reintento de una reserva ya guardada: la misma respuesta, sin crear nada.
    log("info", "booking_duplicate", { requestId: result.requestId, userId: caller.userId });
    return reply(201, result);
  }
  log("info", "booking_created", {
    requestId: result.requestId,
    sessions: result.weeks.length,
    client: parsed.value.client.kind,
    userId: caller.userId,
  });
  return reply(201, result);
}

async function moveRoute(deps: ChefHandlerDeps, { chefId, userId }: Caller, input: unknown, reply: Reply): Promise<Response> {
  const { log } = deps;
  const route = CHEF_ROUTES.moveSession;
  const parsed = parseMoveSessionRequest(input, { today: romeToday(deps.now()) });
  if (!parsed.ok) return invalidPayload(log, route, parsed, reply);

  const { sessionId, date, start, cookMinutes, dryRun } = parsed.value;
  let data: unknown;
  try {
    data = await deps.store.moveSession({
      p_chef_id: chefId,
      p_session_id: sessionId,
      p_date: date,
      p_start: start,
      p_cook_minutes: cookMinutes,
      p_dry_run: dryRun,
    });
  } catch (error) {
    return dbFailure(log, route, "move_session", error, reply);
  }
  const result = moveSessionResponseFromRpc(data);
  if (!result || result.dryRun !== dryRun) return unexpectedResult(log, "move_session", reply);
  if (!result.dryRun) log("info", "session_moved", { sessionId: result.sessionId, userId });
  return reply(200, result);
}

async function cancelRoute(deps: ChefHandlerDeps, { chefId, userId }: Caller, input: unknown, reply: Reply): Promise<Response> {
  const { log } = deps;
  const route = CHEF_ROUTES.cancelSessions;
  const parsed = parseCancelSessionsRequest(input);
  if (!parsed.ok) return invalidPayload(log, route, parsed, reply);

  let data: unknown;
  try {
    data = await deps.store.cancelSessions({
      p_chef_id: chefId,
      p_session_ids: parsed.value.sessionIds,
      p_reason: parsed.value.reason,
      p_allow_with_payments: parsed.value.allowWithPayments,
    });
  } catch (error) {
    return dbFailure(log, route, "cancel_sessions", error, reply);
  }
  const result = cancelSessionsResponseFromRpc(data);
  if (!result) return unexpectedResult(log, "cancel_sessions", reply);
  log("info", "sessions_cancelled", {
    cancelled: result.cancelled.length,
    alreadyCancelled: result.alreadyCancelled.length,
    withPayments: result.withPayments.length,
    userId,
  });
  return reply(200, result);
}

/** Una traducción que no salió: la respuesta, y el nivel y los campos del log translate_failed. */
interface TranslateFailure {
  status: 422 | 500 | 501 | 503;
  body: ChefErrorBody;
  level: "warn" | "error";
  fields: LogFields;
}

const UNTRANSLATABLE: ChefErrorBody = { error: "untranslatable" };
const UNAVAILABLE: ChefErrorBody = { error: "unavailable" };
const SERVER: ChefErrorBody = { error: "server" };

/**
 * Por qué no hubo traducción → la respuesta (contrato §12). 503 solo lo que se puede reintentar (tiempo
 * agotado, conexión, un 5xx o un 429 de Anthropic); 422 lo que no sale con este plato (una negativa,
 * un corte por max_tokens, otro stop_reason o una salida que no pasa la validación); 500 lo que está
 * mal configurado o roto (otro 4xx de Anthropic, como una clave inválida, o un error del SDK).
 */
export function translateFailure(outcome: Exclude<TranslatorReply, { kind: "text" }> | { kind: "invalidOutput" }): TranslateFailure {
  switch (outcome.kind) {
    case "refusal":
      return { status: 422, body: UNTRANSLATABLE, level: "warn", fields: { reason: "refusal", category: outcome.category } };
    case "maxTokens":
      return { status: 422, body: UNTRANSLATABLE, level: "warn", fields: { reason: "maxTokens" } };
    case "invalidOutput":
      return { status: 422, body: UNTRANSLATABLE, level: "error", fields: { reason: "invalidOutput" } };
    case "failed": {
      const fields: LogFields = { reason: outcome.reason, apiStatus: outcome.status };
      switch (outcome.reason) {
        case "stopReason":
          return { status: 422, body: UNTRANSLATABLE, level: "error", fields };
        case "timeout":
        case "connection":
        case "rateLimited":
          return { status: 503, body: UNAVAILABLE, level: "error", fields };
        case "apiError":
          return outcome.status !== null && outcome.status >= 500
            ? { status: 503, body: UNAVAILABLE, level: "error", fields }
            : { status: 500, body: SERVER, level: "error", fields };
        default:
          return { status: 500, body: SERVER, level: "error", fields };
      }
    }
  }
}

/** Una traducción: la ruta (para el log), qué llamar del traductor y cómo leer su salida. */
interface TranslationJob<T> {
  route: ChefRoute;
  /** Largos y cantidades del texto para los logs translated y translate_failed: nunca el texto. */
  lengths: LogFields;
  call: (translator: Translator) => Promise<TranslatorReply>;
  /** La salida validada entera, o null (422 invalidOutput). */
  read: (text: string) => T | null;
}

/**
 * Lo común de /translate y de la traducción de /menus/preview (contrato §12 y §13): sin traductor, 501
 * sin gastar el cupo; pasado el límite de la cocina (uno solo para las dos), 429; si el traductor falla,
 * 503, 422 o 500 según el motivo (translateFailure). Nunca una traducción a medias. El log lleva largos
 * y duración, nunca el texto. Devuelve la traducción o la respuesta con que corta.
 */
async function runTranslation<T>(deps: ChefHandlerDeps, { chefId, userId }: Caller, job: TranslationJob<T>, reply: Reply): Promise<T | Response> {
  const { log } = deps;
  const { route, lengths } = job;
  const fail = (failure: TranslateFailure, extra: LogFields = {}): Response => {
    log(failure.level, "translate_failed", { route, ...failure.fields, ...extra, ...lengths });
    return reply(failure.status, failure.body);
  };

  const translator = deps.translator;
  if (!translator) {
    // TRANSLATE_TRANSPORT=fake fuera de local es un error de configuración; sin clave, una decisión.
    return deps.config.translationFakeIgnored
      ? fail({ status: 501, body: { error: "notConfigured" }, level: "error", fields: { reason: "fakeIgnored" } })
      : fail({ status: 501, body: { error: "notConfigured" }, level: "warn", fields: { reason: "notConfigured" } });
  }

  let allowed: boolean;
  try {
    allowed = await deps.store.hitRateLimit(await translateRateKey(chefId), TRANSLATE_RATE_LIMITS.perHour, TRANSLATE_RATE_LIMITS.perDay);
  } catch (error) {
    logStoreError(log, error, "rate_limit");
    const failure = serverFailure(error);
    return reply(failure.status, failure.body);
  }
  if (!allowed) {
    log("info", "rate_limited", { route, userId });
    return reply(429, { error: "rateLimited" }, { "Retry-After": String(TRANSLATE_RETRY_AFTER_SECONDS) });
  }

  const started = deps.now().getTime();
  let result: TranslatorReply;
  try {
    result = await job.call(translator);
  } catch {
    // Nunca el mensaje: podría traer el texto del plato o de la lista.
    result = { kind: "failed", reason: "unexpected", status: null };
  }
  const ms = Math.max(0, deps.now().getTime() - started);

  if (result.kind !== "text") return fail(translateFailure(result), { ms });
  const translation = job.read(result.text);
  if (translation === null) return fail(translateFailure({ kind: "invalidOutput" }), { ms });
  log("info", "translated", { route, ms, ...lengths, userId });
  return translation;
}

/** POST /translate: el plato en español → italiano e inglés (contrato §12), con runTranslation. */
async function translateRoute(deps: ChefHandlerDeps, caller: Caller, input: unknown, reply: Reply): Promise<Response> {
  const route = CHEF_ROUTES.translate;
  const parsed = parseTranslateRequest(input);
  if (!parsed.ok) return invalidPayload(deps.log, route, parsed, reply);

  const source: TranslationSource = parsed.value;
  const translation = await runTranslation(
    deps,
    caller,
    {
      route,
      lengths: {
        nameLength: textLength(source.name),
        descriptionLength: source.description === null ? null : textLength(source.description),
      },
      call: (translator) => translator.translate(source),
      read: (text) => readTranslationOutput(text, source),
    },
    reply,
  );
  return translation instanceof Response ? translation : reply(200, translation);
}

// ---------------------------------------------------------------------------
// El menú de una semana para la clienta (contrato §13)
// ---------------------------------------------------------------------------

/** Un 409 del envío decidido por la función (antes de la base): al log como rejected, sin código de la base. */
function menuRejected(log: Logger, route: ChefRoute, error: ChefErrorCode, reply: Reply, body: ChefErrorBody = { error }): Response {
  log("info", "rejected", { route, status: 409, error, code: null, message: null });
  return reply(409, body);
}

/**
 * Lo que chef_prepare_menu_send vuelve a mirar, antes de gastar una traducción: otra versión del menú
 * (Evelyn o un colaborador guardó después de que la app lo cargó) o un menú sin platos. Una semana que ya
 * no se manda (cancelada, cocinada o cobrada) la rechaza antes chef_menu_send_context (409
 * sessionNotEditable).
 */
function earlyMenuRejection(context: MenuSendContext, menuVersion: number): ChefErrorCode | null {
  if (context.menu.version !== menuVersion) return "menuChanged";
  if (context.menu.dishes.length === 0) return "menuEmpty";
  return null;
}

/**
 * POST /menus/preview: la vista previa del mensaje en el idioma de la clienta. Si no lee español y hay
 * lista, los nombres de sus renglones se traducen con Claude (como /translate, con el mismo límite;
 * translate: false los deja como están). La nota nunca se traduce: sale como la escribió Evelyn. Guarda
 * el envío sin salir con la foto de lo que va a recibir y la huella del contexto, y devuelve el mensaje
 * sin el link (se crea al enviar) y el contacto, para que Evelyn lo revise.
 */
async function menuPreviewRoute(deps: ChefHandlerDeps, caller: Caller, input: unknown, reply: Reply): Promise<Response> {
  const { config, log } = deps;
  const route = CHEF_ROUTES.menuPreview;
  const parsed = parseMenuPreviewRequest(input);
  if (!parsed.ok) return invalidPayload(log, route, parsed, reply);
  const { sessionId, menuVersion, translate } = parsed.value;

  let raw: unknown;
  try {
    raw = await deps.store.menuSendContext({ p_chef_id: caller.chefId, p_session_id: sessionId });
  } catch (error) {
    return dbFailure(log, route, "menu_send_context", error, reply);
  }
  const context = menuSendContextFromRpc(raw);
  if (!context) return unexpectedResult(log, "menu_send_context", reply);
  const early = earlyMenuRejection(context, menuVersion);
  if (early) return menuRejected(log, route, early, reply);

  // La lista la escribe Evelyn (en español): sus renglones, a otro idioma con Claude. Los platos ya tienen
  // sus traducciones guardadas y la nota sale como ella la escribió (nunca va a Anthropic).
  const locale = context.locale;
  const itemNames = context.menu.items.map((item) => item.name);
  let names: ReadonlyMap<string, string> | null = null;
  let translated = false;
  if (translate && locale !== "es" && itemNames.length > 0) {
    const source = menuTextSource(locale, itemNames);
    const translation = await runTranslation<MenuTextTranslation>(
      deps,
      caller,
      {
        route,
        lengths: { items: source.items.length },
        call: (translator) => translator.translateMenu(source),
        read: (text) => readMenuTranslationOutput(text, source),
      },
      reply,
    );
    if (translation instanceof Response) return translation;
    names = translatedItemNames(source, translation);
    translated = true;
  }

  const snapshot = buildMenuSnapshot(context, { chefId: caller.chefId, photoOrigin: config.photoOrigin, itemNames: names });
  let prepared: unknown;
  try {
    prepared = await deps.store.prepareMenuSend({
      p_chef_id: caller.chefId,
      p_session_id: sessionId,
      p_menu_version: menuVersion,
      p_locale: locale,
      p_snapshot: snapshot,
      p_translated: translated,
      // Si el día, las semanas, el menú o un plato cambiaron mientras se armaba la foto, no se guarda.
      p_fingerprint: context.fingerprint,
    });
  } catch (error) {
    return dbFailure(log, route, "prepare_menu_send", error, reply);
  }
  const sendId = preparedSendIdFromRpc(prepared);
  if (!sendId) return unexpectedResult(log, "prepare_menu_send", reply);

  const message = renderMenuMessage({
    brand: brandFromMailFrom(config.mailFrom),
    chefName: context.chefName,
    clientName: context.contact.name,
    snapshot,
    link: null,
  });
  log("info", "menu_previewed", {
    route,
    sendId,
    sessionId,
    locale,
    translated,
    dishes: snapshot.dishes.length,
    items: snapshot.items.length,
    hasNote: snapshot.note !== null,
    userId: caller.userId,
  });
  const body: MenuPreviewResponse = {
    sendId,
    locale,
    translated,
    contact: context.contact,
    message: { subject: message.subject, emailText: message.text, whatsappText: message.whatsapp },
  };
  return reply(200, body);
}

/** El email del menú se puede mandar: con EMAIL_TRANSPORT=log siempre (no sale); si no, con Resend y MAIL_FROM. */
function emailReady(deps: ChefHandlerDeps): boolean {
  return deps.config.emailTransport === "log" || (deps.mailer !== null && deps.config.mailFrom !== null);
}

/** Manda (o registra, con EMAIL_TRANSPORT=log) el email del menú. true si salió. El log, sin la dirección. */
async function deliverMenuEmail(deps: ChefHandlerDeps, route: ChefRoute, sendId: string, message: EmailMessage): Promise<boolean> {
  const { log } = deps;
  if (deps.config.emailTransport === "log") {
    log("info", "email_logged", { route, sendId, htmlChars: message.html.length, textChars: message.text.length });
    return true;
  }
  if (!deps.mailer) return false;
  let outcome: SendOutcome;
  try {
    outcome = await deps.mailer.send(message);
  } catch {
    outcome = { ok: false, status: null, errorName: "unexpected" };
  }
  if (outcome.ok) {
    log("info", "email_sent", { route, sendId });
    return true;
  }
  log("error", "email_failed", { route, sendId, status: outcome.status, errorName: outcome.errorName });
  return false;
}

/** Un token repetido en client_links (no debería pasar: 256 bits al azar). */
function isTokenCollision(error: unknown): boolean {
  return error instanceof StoreError && error.code === "23505";
}

/**
 * POST /menus/send: manda el envío de una vista previa. Crea el link (un token nuevo; la base guarda su
 * hash), manda el email si lo pidió y lo marca enviado. Si el email no sale, 502 y el envío queda sin
 * marcar (la app ofrece reintentar o mandarlo solo por WhatsApp). El WhatsApp lo abre la app con el texto
 * que devuelve: el servidor nunca lo manda.
 */
async function menuSendRoute(deps: ChefHandlerDeps, caller: Caller, input: unknown, reply: Reply): Promise<Response> {
  const { config, log } = deps;
  const route = CHEF_ROUTES.menuSend;
  const parsed = parseMenuSendRequest(input);
  if (!parsed.ok) return invalidPayload(log, route, parsed, reply);
  const { sendId, email, whatsapp } = parsed.value;

  const siteUrl = config.publicSiteUrl;
  if (!siteUrl) {
    log("error", "config_missing", { missing: ["PUBLIC_SITE_URL"] });
    return reply(500, { error: "server" });
  }
  if (email && !emailReady(deps)) {
    log("warn", "email_skipped", { route, sendId, reason: "not_configured" });
    return reply(503, { error: "emailUnavailable" });
  }

  // El link: el token va solo en el mensaje; la base guarda su hash. Si el hash ya existe, otro token.
  const link = async (hash: string): Promise<unknown> =>
    await deps.store.linkMenuSend({ p_chef_id: caller.chefId, p_send_id: sendId, p_token_hash: hash });
  let token = await newClientToken();
  let raw: unknown;
  try {
    raw = await link(token.hash);
  } catch (error) {
    if (!isTokenCollision(error)) return dbFailure(log, route, "link_menu_send", error, reply);
    log("warn", "token_collision", { route, sendId });
    token = await newClientToken();
    try {
      raw = await link(token.hash);
    } catch (retryError) {
      return dbFailure(log, route, "link_menu_send", retryError, reply);
    }
  }
  const linked = linkedSendFromRpc(raw);
  if (!linked || linked.sendId !== sendId) return unexpectedResult(log, "link_menu_send", reply);
  const snapshot = readMenuSnapshot(linked.snapshot);
  if (!snapshot) return unexpectedResult(log, "menu_snapshot", reply);

  // El contacto de ahora (el del pedido de la web o el de la ficha), antes de mandar nada.
  const to = sendableEmail(linked.contact.email);
  if (email && !to) return menuRejected(log, route, "noEmail", reply);
  const phone = whatsappPhone(linked.contact.phone);
  if (whatsapp && !phone) return menuRejected(log, route, "noPhone", reply);

  const message = renderMenuMessage({
    brand: brandFromMailFrom(config.mailFrom),
    chefName: linked.chefName,
    clientName: linked.contact.name,
    snapshot,
    link: clientLinkUrl(siteUrl, token.token),
  });
  if (email && to) {
    const sent = await deliverMenuEmail(deps, route, sendId, {
      from: config.mailFrom ?? "",
      to,
      // Las respuestas de la clienta le llegan a Evelyn.
      replyTo: config.mailReplyTo,
      subject: message.subject,
      html: message.html,
      text: message.text,
      // Una clave por link: el mismo intento se reintenta sin duplicar; otro intento es otro email (con otro link).
      idempotencyKey: `menu-send-${sendId}-${token.hash.slice(0, 16)}`,
    });
    if (!sent) return reply(502, { error: "emailFailed" });
  }

  // Si el email ya salió y no se puede marcar, la respuesta lo dice (emailSent): reintentar manda otro.
  const afterEmail = (status: number, body: ChefErrorBody): Response =>
    reply(status, email && "error" in body ? { ...body, emailSent: true } : body);
  let completed: unknown;
  try {
    completed = await deps.store.completeMenuSend({ p_chef_id: caller.chefId, p_send_id: sendId, p_via: menuSendChannels(parsed.value) });
  } catch (error) {
    const mapped = dbErrorReply(error);
    if (email) {
      const store = error instanceof StoreError ? error : null;
      log("error", "menu_send_incomplete", { route, sendId, status: mapped.status, code: store?.code ?? null, message: store?.safeMessage ?? null });
      return afterEmail(mapped.status, "error" in mapped.body ? mapped.body : { error: "server" });
    }
    return dbFailure(log, route, "complete_menu_send", error, reply);
  }
  const result = completedSendFromRpc(completed);
  if (!result) {
    log("error", "unexpected_result", { op: "complete_menu_send" });
    return afterEmail(500, { error: "server" });
  }
  log("info", "menu_sent", { route, sendId, via: result.sentVia, userId: caller.userId });
  const body: MenuSendResponse = { sentAt: result.sentAt, sentVia: result.sentVia };
  if (whatsapp && phone) {
    body.whatsappText = message.whatsapp;
    body.whatsappPhone = phone;
  }
  return reply(200, body);
}

export function createChefHandler(deps: ChefHandlerDeps): (request: Request) => Promise<Response> {
  const { config, log } = deps;

  return async (request: Request): Promise<Response> => {
    const origin = request.headers.get("origin");
    const reply: Reply = (status, body, extra = {}) =>
      new Response(JSON.stringify(body), {
        status,
        headers: {
          ...corsHeaders(origin, config.allowedOrigins, { preflight: false, methods: CHEF_CORS_METHODS }),
          "Content-Type": "application/json; charset=utf-8",
          "Cache-Control": "no-store",
          ...extra,
        },
      });

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: corsHeaders(origin, config.allowedOrigins, { preflight: true, methods: CHEF_CORS_METHODS }),
      });
    }

    try {
      const route = routeOf(new URL(request.url).pathname);
      if (route === null || !isChefRoute(route)) return reply(404, { error: "notFound" });
      if (request.method !== "POST") return reply(405, { error: "method" }, { Allow: CHEF_CORS_METHODS });

      if (config.missing.length > 0) {
        log("error", "config_missing", { missing: config.missing });
        return reply(500, { error: "server" });
      }

      // Primero quién llama: sin un token válido de la cocinera o de un colaborador suyo no se lee ni el cuerpo.
      const auth = await authenticate(deps, request, route);
      if (!auth.ok) return reply(auth.status, auth.body, auth.headers);

      if (!isJsonContentType(request.headers.get("content-type"))) return reply(415, { error: "contentType" });
      const body = await readBodyLimited(request, CHEF_MAX_PAYLOAD_BYTES);
      if (!body.ok) return body.reason === "tooLarge" ? reply(413, { error: "tooLarge" }) : reply(400, { errors: { payload: "invalid" } });
      let input: unknown;
      try {
        input = JSON.parse(body.text);
      } catch {
        return reply(400, { errors: { payload: "invalid" } });
      }

      switch (route) {
        case CHEF_ROUTES.bookings:
          return await bookingsRoute(deps, auth, input, reply);
        case CHEF_ROUTES.moveSession:
          return await moveRoute(deps, auth, input, reply);
        case CHEF_ROUTES.cancelSessions:
          return await cancelRoute(deps, auth, input, reply);
        case CHEF_ROUTES.translate:
          return await translateRoute(deps, auth, input, reply);
        case CHEF_ROUTES.menuPreview:
          return await menuPreviewRoute(deps, auth, input, reply);
        case CHEF_ROUTES.menuSend:
          return await menuSendRoute(deps, auth, input, reply);
        default:
          return reply(404, { error: "notFound" });
      }
    } catch (error) {
      // Solo el tipo de error: el mensaje podría traer datos de la reserva.
      log("error", "unexpected_error", { error: error instanceof Error ? error.name : "unknown" });
      return reply(500, { error: "server" });
    }
  };
}
