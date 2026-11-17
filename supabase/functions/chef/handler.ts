// Lógica de la Edge Function chef: el área de Evelyn (docs/contracts/chef-api.md). Es la única puerta
// para crear, mover y cancelar sesiones: los estados de sesión solo cambian vía Edge Functions.
// No depende de Deno ni de supabase-js: index.ts arma las dependencias reales y los tests
// (handler.test.ts, en Node) las simulan.
//
// Rutas, todas POST: /bookings (chef_create_booking), /sessions/move (chef_move_session) y
// /sessions/cancel (chef_cancel_sessions). Orden: CORS → ruta (404) → método (405) → configuración
// (500) → token (401) → usuario, con auth.getUser (401; 503 si Auth no responde) → su cocina, con
// public.chef_id_for_user: la de la que es dueña o colaborador (403 si no es de ninguna) → tipo (415)
// → tamaño (413) → JSON y validación (400) → función SQL con la cocina del token → 200 o 201, o el
// error de la base traducido (400, 404, 409, 500 o 503).
//
// Los logs llevan solo evento, ruta, códigos, contadores e ids: nunca nombres, teléfonos, emails,
// direcciones, notas, restricciones ni fechas.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import {
  CHEF_MAX_PAYLOAD_BYTES,
  CHEF_ROUTES,
  DAY_STATUSES,
  MAX_CANCEL_SESSIONS,
  parseBookingRequest,
  parseCancelSessionsRequest,
  parseMoveSessionRequest,
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
  type MoveSessionResponse,
  type NormalizedBooking,
} from "../_shared/chef_api.ts";
import { corsHeaders, parseAllowedOrigins, type OriginRule } from "../_shared/cors.ts";
import {
  StoreError,
  isJsonContentType,
  logStoreError,
  readBodyLimited,
  resolveServiceKey,
  safeDbMessage,
  type Logger,
} from "../_shared/edge.ts";
import { isIsoDate, isOneOf, isUuid, romeToday, type Locale, type Meal, type RequestType } from "../_shared/public_request.ts";

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
}

export function readChefConfig(get: (name: string) => string | undefined): ChefConfig {
  const missing: string[] = [];
  if (!get("SUPABASE_URL")?.trim()) missing.push("SUPABASE_URL");
  if (!resolveServiceKey(get)) missing.push("SUPABASE_SECRET_KEYS");
  return { allowedOrigins: parseAllowedOrigins(get("ALLOWED_ORIGINS")), missing };
}

/** Sin ALLOWED_ORIGINS la bandeja web (/gestione/) no puede llamar a la función; la app nativa sí. */
export function chefConfigWarnings(config: ChefConfig): string[] {
  return config.allowedOrigins.length === 0 ? ["ALLOWED_ORIGINS"] : [];
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
  p_groceries_est_cents: number;
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
}

export function toCreateBookingParams(chefId: string, value: NormalizedBooking): CreateBookingParams {
  const { client } = value;
  return {
    p_chef_id: chefId,
    p_dates: [...value.dates],
    p_start: value.start,
    p_cook_minutes: value.cookMinutes,
    p_portions: value.portions,
    p_groceries_est_cents: value.groceriesEstCents,
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
const SESSION_STATUSES = ["held", "confirmed", "shopping_done", "cooked", "paid", "cancelled"] as const;
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
  if (message === "session_not_movable") return isOneOf(SESSION_STATUSES, detail) ? detail : null;
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
]);

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
    return { status: 409, body: { error: "conflict" } };
  }
  if (code === "P0002") {
    const notFound = message === null ? undefined : NOT_FOUND.get(message);
    // chef_not_found: la cocinera está en chefs pero no en chef_settings (configuración rota).
    return notFound ? { status: 404, body: { error: notFound } } : { status: 500, body: { error: "server" } };
  }
  if (code === "22023") {
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
