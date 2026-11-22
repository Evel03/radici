// Lógica de la Edge Function client-link (docs/contracts/client-link.md): el link de la clienta (SPEC 5.8).
// No depende de Deno ni de supabase-js: index.ts arma las dependencias reales y los tests (handler.test.ts, en
// Node) las simulan.
//
// Pública, como public-request (verify_jwt = false): la llama la página /prenotazione/ de la web, sin cuenta.
// La llave es el token del link (32 bytes al azar); la base guarda solo su hash. Tres rutas, todas POST:
// - /view {token}: la reserva (client_link_view): semanas y el último menú enviado de cada una.
// - /confirm {token, sendId}: la clienta confirma el menú de una semana (client_link_confirm_menu).
// - /changes {token, sendId, text}: pide cambios con un mensaje (client_link_request_changes).
// Orden: CORS → ruta (404) → método (405) → tipo (415) → tamaño (413) → JSON y validación (400) →
// configuración (500) → límite por IP (429; uno para /view y otro, más corto, para las respuestas) → forma del
// token (404) → función SQL. Después de una respuesta, el aviso a Evelyn sale en segundo plano (waitUntil): un
// email que falla no rompe lo que hizo la clienta.
//
// Los logs llevan solo el evento, la ruta, códigos e ids (del pedido y del envío): nunca el token ni su hash,
// nombres, el mensaje de la clienta, los platos ni la IP.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import {
  CLIENT_LINK_FUNCTION,
  CLIENT_LINK_MAX_PAYLOAD_BYTES,
  CLIENT_LINK_ROUTES,
  CLIENT_LINK_VERSION,
  hashClientLinkToken,
  isClientLinkToken,
  isTimeOfDay,
  isTimestamp,
  menuState,
  normalizeChangesText,
  readMenuSnapshot,
  type ClientLinkErrorCode,
  type ClientLinkMenu,
  type ClientLinkRoute,
  type ClientLinkView,
  type ClientLinkWeek,
  type ConfirmMenuResponse,
  type RequestChangesResponse,
} from "../_shared/client_link.ts";
import { renderMenuAnswerNotification, type MenuAnswerKind } from "../_shared/client_link_emails.ts";
import { clientIp, hashSubject, rateLimitSubject } from "../_shared/client_ip.ts";
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
import { brandFromMailFrom, safeFirstName } from "../_shared/emails.ts";
import { photoOrigin } from "../_shared/menu.ts";
import { LOCALES, isIsoDate, isOneOf, isUuid, type Locale } from "../_shared/public_request.ts";
import { sendWithResend, type EmailMessage } from "../_shared/resend.ts";

export { StoreError, consoleLogger, resolveServiceKey } from "../_shared/edge.ts";
export type { LogFields, LogLevel, Logger } from "../_shared/edge.ts";

/** El preflight: solo POST. */
export const CLIENT_LINK_CORS_METHODS = "POST, OPTIONS";

/**
 * Límite de /view por IP: la página lo pide al abrirse y después de cada respuesta. Otro contador que el del
 * formulario (la misma función SQL, otra clave): no gasta su cupo.
 */
export const VIEW_RATE_LIMITS = { perHour: 60, perDay: 300 } as const;
/** Límite de /confirm y /changes por IP: cada respuesta le manda un email a Evelyn. */
export const ANSWER_RATE_LIMITS = { perHour: 10, perDay: 30 } as const;
/** La ventana corta es de una hora. */
export const RETRY_AFTER_SECONDS = 3600;

/** Clave del límite de /view: la del formulario con el prefijo "client-link:" (otra fila de public_request_hits). */
export function viewRateSubject(ip: string | null): string {
  return `client-link:${ip ? rateLimitSubject(ip) : "unknown"}`;
}

/** Clave del límite de las respuestas (/confirm y /changes): otro contador, con el prefijo "client-link-answer:". */
export function answerRateSubject(ip: string | null): string {
  return `client-link-answer:${ip ? rateLimitSubject(ip) : "unknown"}`;
}

// ---------------------------------------------------------------------------
// Configuración (los secretos que ya comparten las funciones; contrato §7)
// ---------------------------------------------------------------------------

export interface ClientLinkConfig {
  /** Sin estas no se atiende nada (500): SUPABASE_URL, la clave secreta e IP_HASH_SALT. */
  missing: string[];
  ipHashSalt: string | null;
  allowedOrigins: OriginRule[];
  /** El origen de Supabase para las fotos de los platos (photoOrigin de SUPABASE_URL); null: sin fotos. */
  storageOrigin: string | null;
  emailTransport: "resend" | "log";
  resendApiKey: string | null;
  mailFrom: string | null;
  chefNotifyEmail: string | null;
  chefLocale: Locale;
  inboxUrl: string | null;
}

/** Idioma de los avisos a Evelyn si CHEF_LOCALE falta o no es it, es ni en (como en public-request). */
export const DEFAULT_CHEF_LOCALE: Locale = "es";

export function readClientLinkConfig(get: (name: string) => string | undefined): ClientLinkConfig {
  const value = (name: string): string | null => {
    const raw = get(name)?.trim();
    return raw ? raw : null;
  };
  const supabaseUrl = value("SUPABASE_URL");
  const ipHashSalt = value("IP_HASH_SALT");
  const missing: string[] = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!resolveServiceKey(get)) missing.push("SUPABASE_SECRET_KEYS");
  if (!ipHashSalt) missing.push("IP_HASH_SALT");
  const chefLocale = value("CHEF_LOCALE")?.toLowerCase();
  return {
    missing,
    ipHashSalt,
    allowedOrigins: parseAllowedOrigins(value("ALLOWED_ORIGINS")),
    storageOrigin: photoOrigin(supabaseUrl),
    emailTransport: value("EMAIL_TRANSPORT")?.toLowerCase() === "log" ? "log" : "resend",
    resendApiKey: value("RESEND_API_KEY"),
    mailFrom: value("MAIL_FROM"),
    chefNotifyEmail: value("CHEF_NOTIFY_EMAIL"),
    chefLocale: isOneOf(LOCALES, chefLocale) ? chefLocale : DEFAULT_CHEF_LOCALE,
    inboxUrl: value("INBOX_URL"),
  };
}

/** Sin estas la página funciona, pero falta algo (CORS o los avisos a Evelyn). Se avisan al arrancar. */
export function clientLinkConfigWarnings(config: ClientLinkConfig): string[] {
  const warnings: string[] = [];
  if (config.allowedOrigins.length === 0) warnings.push("ALLOWED_ORIGINS");
  if (!config.chefNotifyEmail) warnings.push("CHEF_NOTIFY_EMAIL");
  if (config.emailTransport === "resend") {
    if (!config.resendApiKey) warnings.push("RESEND_API_KEY");
    if (!config.mailFrom) warnings.push("MAIL_FROM");
  }
  if (!config.inboxUrl) warnings.push("INBOX_URL");
  return warnings;
}

// ---------------------------------------------------------------------------
// Acceso a la base (index.ts lo implementa con supabase-js y la clave secreta)
// ---------------------------------------------------------------------------

export interface ClientLinkStore {
  /** public.hit_public_request_rate: registra el intento y dice si está dentro del límite. */
  hitRateLimit(ipHash: string, maxPerHour: number, maxPerDay: number): Promise<boolean>;
  /** public.client_link_view(p_token_hash): la reserva, o null si el link no vale. */
  view(tokenHash: string): Promise<unknown>;
  /** public.client_link_confirm_menu(p_token_hash, p_send_id). */
  confirmMenu(tokenHash: string, sendId: string): Promise<unknown>;
  /** public.client_link_request_changes(p_token_hash, p_send_id, p_text). */
  requestChanges(tokenHash: string, sendId: string, text: string): Promise<unknown>;
}

interface DbErrorLike {
  code?: string;
  message?: string;
}

/** Error de supabase-js sin datos: la operación, el SQLSTATE y el código propio de la función SQL (nunca details ni hint). */
export function storeErrorFrom(op: string, error: DbErrorLike): StoreError {
  return new StoreError(op, error.code ? error.code : null, safeDbMessage(error.message));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPositiveInt(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 1;
}

/** Lo que devuelve client_link_view, ya armado para la página. */
export interface ViewFromRpc {
  view: ClientLinkView;
  requestId: string;
  /** Los envíos cuya foto no se pudo leer (salen sin contenido): para el log. */
  unreadable: string[];
}

/** Lo que pasa de la base a la página de un envío: la foto leída campo por campo (readMenuSnapshot). */
function menuFromRpc(value: unknown, storageOrigin: string | null, unreadable: string[]): ClientLinkMenu | null | undefined {
  if (value === null || value === undefined) return null;
  if (!isRecord(value)) return undefined;
  const { id, sentAt, confirmedAt, changesRequestedAt } = value;
  if (typeof id !== "string" || !isUuid(id) || !isTimestamp(sentAt)) return undefined;
  const confirmed = confirmedAt === null || confirmedAt === undefined ? null : isTimestamp(confirmedAt) ? confirmedAt : undefined;
  const changes =
    changesRequestedAt === null || changesRequestedAt === undefined ? null : isTimestamp(changesRequestedAt) ? changesRequestedAt : undefined;
  if (confirmed === undefined || changes === undefined) return undefined;
  const content = readMenuSnapshot(value["snapshot"], storageOrigin);
  if (!content) unreadable.push(id.toLowerCase());
  return {
    sendId: id.toLowerCase(),
    sentAt,
    state: menuState(confirmed, changes),
    confirmedAt: confirmed,
    changesRequestedAt: changes,
    content,
  };
}

/**
 * public.client_link_view → la respuesta de POST …/view, o null si no tiene la forma esperada (500). Solo pasa lo
 * del contrato: de la clienta, el nombre de pila con que llegó el pedido (o el de la ficha) si parece un nombre
 * (safeFirstName), nunca el nombre completo; de cada semana, su sesión, la fecha, la hora, si ya se cocinó y el
 * último menú enviado.
 */
export function viewFromRpc(data: unknown, storageOrigin: string | null): ViewFromRpc | null {
  if (!isRecord(data)) return null;
  const { requestId, locale, chefName, clientName, weeks } = data;
  if (typeof requestId !== "string" || !isUuid(requestId) || !Array.isArray(weeks)) return null;
  const unreadable: string[] = [];
  const out: ClientLinkWeek[] = [];
  for (const raw of weeks) {
    if (!isRecord(raw)) return null;
    const { sessionId, date, start, status, week, weeks: total } = raw;
    if (typeof sessionId !== "string" || !isUuid(sessionId)) return null;
    if (typeof date !== "string" || !isIsoDate(date) || !isTimeOfDay(start) || typeof status !== "string") return null;
    if (!isPositiveInt(week) || !isPositiveInt(total) || week > total) return null;
    const menu = menuFromRpc(raw["send"], storageOrigin, unreadable);
    if (menu === undefined) return null;
    out.push({
      sessionId: sessionId.toLowerCase(),
      week,
      weeks: total,
      date,
      start,
      done: status === "cooked" || status === "paid",
      menu,
    });
  }
  const first = typeof clientName === "string" ? safeFirstName(clientName) : "";
  return {
    view: {
      version: CLIENT_LINK_VERSION,
      // requests.locale tiene un check (it, es, en); por las dudas, el italiano de la web.
      locale: isOneOf(LOCALES, locale) ? locale : "it",
      chefName: typeof chefName === "string" && chefName.trim() ? chefName.trim() : "Evelyn",
      clientFirstName: first ? first : null,
      weeks: out,
    },
    requestId: requestId.toLowerCase(),
    unreadable,
  };
}

/** Lo que devuelven client_link_confirm_menu y client_link_request_changes (private.client_link_answer). */
export interface MenuAnswer {
  sendId: string;
  requestId: string;
  /** Ya estaba confirmado (solo al confirmar): no se avisa otra vez. */
  already: boolean;
  confirmedAt: string | null;
  changesRequestedAt: string | null;
  date: string;
  start: string;
  /**
   * null: la semana ya no tiene lugar en la reserva. La base de hoy no deja contestar una semana cancelada
   * (session_cancelled), así que no debería llegar; si llega, no se avisa (no hay «semana k» que contar).
   */
  week: number | null;
  weeks: number;
  /**
   * El nombre con que llegó el pedido (o, si no tiene, el de la ficha): el mismo del mensaje y de la bandeja.
   * Solo para el aviso a Evelyn, nunca a la página ni al log.
   */
  clientName: string | null;
}

export function answerFromRpc(data: unknown): MenuAnswer | null {
  if (!isRecord(data)) return null;
  const { sendId, requestId, already, confirmedAt, changesRequestedAt, date, start, week, weeks, clientName } = data;
  if (typeof sendId !== "string" || !isUuid(sendId) || typeof requestId !== "string" || !isUuid(requestId)) return null;
  if (typeof already !== "boolean" || typeof date !== "string" || !isIsoDate(date) || !isTimeOfDay(start)) return null;
  if (confirmedAt !== null && !isTimestamp(confirmedAt)) return null;
  if (changesRequestedAt !== null && !isTimestamp(changesRequestedAt)) return null;
  if ((week !== null && !isPositiveInt(week)) || typeof weeks !== "number" || !Number.isInteger(weeks) || weeks < 0) return null;
  if (clientName !== null && clientName !== undefined && typeof clientName !== "string") return null;
  return {
    sendId: sendId.toLowerCase(),
    requestId: requestId.toLowerCase(),
    already,
    confirmedAt,
    changesRequestedAt,
    date,
    start,
    week,
    weeks,
    clientName: typeof clientName === "string" ? clientName : null,
  };
}

// ---------------------------------------------------------------------------
// Errores
// ---------------------------------------------------------------------------

export interface ErrorReply {
  status: number;
  body: { error: ClientLinkErrorCode };
}

/** Los errores propios de las funciones SQL client_link_*: el SQLSTATE con que salen y la respuesta. */
const SQL_ERRORS: ReadonlyMap<string, { code: string; status: number; error: ClientLinkErrorCode }> = new Map([
  ["link_not_found", { code: "P0002", status: 404, error: "linkNotFound" }],
  ["send_not_found", { code: "P0002", status: 404, error: "sendNotFound" }],
  ["menu_outdated", { code: "55000", status: 409, error: "menuOutdated" }],
  ["changes_requested", { code: "55000", status: 409, error: "changesRequested" }],
  ["already_confirmed", { code: "55000", status: 409, error: "alreadyConfirmed" }],
  // La semana se canceló después del envío: ya no hay menú que contestar.
  ["session_cancelled", { code: "55000", status: 409, error: "sessionCancelled" }],
  ["invalid_text", { code: "22023", status: 400, error: "invalidText" }],
]);

/** Sin código (sin respuesta de la base), conexión, transacción, recursos o PostgREST sin base: se puede reintentar. */
function isRetryable(code: string | null): boolean {
  return code === null || /^(08|40|53|57|58)/.test(code) || /^PGRST00[0-3]$/.test(code);
}

/** Error de la base → respuesta: los de las funciones client_link_* con su código; el resto, 503 (reintentable) o 500. */
export function errorReply(error: unknown): ErrorReply {
  if (!(error instanceof StoreError)) return { status: 500, body: { error: "server" } };
  const known = error.safeMessage === null ? undefined : SQL_ERRORS.get(error.safeMessage);
  if (known && known.code === error.code) return { status: known.status, body: { error: known.error } };
  return isRetryable(error.code) ? { status: 503, body: { error: "unavailable" } } : { status: 500, body: { error: "server" } };
}

// ---------------------------------------------------------------------------
// Ruta y cuerpo
// ---------------------------------------------------------------------------

const ROUTES: ReadonlySet<string> = new Set(Object.values(CLIENT_LINK_ROUTES));

function isClientLinkRoute(route: string): route is ClientLinkRoute {
  return ROUTES.has(route);
}

/**
 * La ruta que sigue al nombre de la función: "/client-link/view" (así llega en la plataforma) y
 * "/functions/v1/client-link/view" dan "/view"; "/client-link", ""; sin el nombre de la función, null.
 */
export function routeOf(pathname: string): string | null {
  const segments = pathname.split("/").filter((segment) => segment !== "");
  const index = segments.indexOf(CLIENT_LINK_FUNCTION);
  if (index === -1) return null;
  const rest = segments.slice(index + 1);
  return rest.length === 0 ? "" : `/${rest.join("/")}`;
}

/** Más largo que esto no es un token ni nada parecido: el cuerpo no se acepta (los 43 caracteres se miran después). */
const TOKEN_MAX_CHARS = 200;

interface ParsedBody {
  token: string;
  sendId: string | null;
  text: string | null;
}

type ParseResult = { ok: true; value: ParsedBody } | { ok: false; error: "invalidPayload" | "invalidText" };

/**
 * El cuerpo de cada ruta. Las claves que el contrato no tiene se ignoran. El token tiene que ser un texto (su
 * forma se mira después del límite por IP: uno con otra forma da linkNotFound); sendId, un uuid; text, el mensaje
 * como lo acepta la base (normalizeChangesText).
 */
function parseBody(route: ClientLinkRoute, input: unknown): ParseResult {
  if (!isRecord(input)) return { ok: false, error: "invalidPayload" };
  const token = input["token"];
  if (typeof token !== "string" || token.length > TOKEN_MAX_CHARS) return { ok: false, error: "invalidPayload" };
  if (route === CLIENT_LINK_ROUTES.view) return { ok: true, value: { token, sendId: null, text: null } };

  const sendId = input["sendId"];
  if (typeof sendId !== "string" || !isUuid(sendId)) return { ok: false, error: "invalidPayload" };
  if (route === CLIENT_LINK_ROUTES.confirm) return { ok: true, value: { token, sendId: sendId.toLowerCase(), text: null } };

  const raw = input["text"];
  if (typeof raw !== "string") return { ok: false, error: "invalidPayload" };
  const text = normalizeChangesText(raw);
  if (text === null) return { ok: false, error: "invalidText" };
  return { ok: true, value: { token, sendId: sendId.toLowerCase(), text } };
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

export interface ClientLinkHandlerDeps {
  config: ClientLinkConfig;
  store: ClientLinkStore;
  /** Para Resend. */
  fetch: typeof fetch;
  /** EdgeRuntime.waitUntil: deja terminar el aviso a Evelyn después de responder. */
  waitUntil: (task: Promise<unknown>) => void;
  log: Logger;
  sleep: (ms: number) => Promise<void>;
}

type Reply = (status: number, body: unknown, extra?: Record<string, string>) => Response;

/** Error de una función SQL: el código va al log (sin mensaje de Postgres ni detalle) y la respuesta, traducida. */
function dbFailure(log: Logger, route: ClientLinkRoute, op: string, error: unknown, reply: Reply): Response {
  const mapped = errorReply(error);
  if (mapped.status >= 500) logStoreError(log, error, op);
  else log("info", "rejected", { route, status: mapped.status, error: mapped.body.error });
  return reply(mapped.status, mapped.body);
}

async function viewRoute(deps: ClientLinkHandlerDeps, tokenHash: string, reply: Reply): Promise<Response> {
  const { log } = deps;
  const route = CLIENT_LINK_ROUTES.view;
  let data: unknown;
  try {
    data = await deps.store.view(tokenHash);
  } catch (error) {
    return dbFailure(log, route, "view", error, reply);
  }
  if (data === null || data === undefined) {
    log("info", "link_not_found", { route });
    return reply(404, { error: "linkNotFound" });
  }
  const result = viewFromRpc(data, deps.config.storageOrigin);
  if (!result) {
    log("error", "unexpected_result", { op: "view" });
    return reply(500, { error: "server" });
  }
  // Una foto que no se puede leer: la semana sale sin contenido y la página lo dice. Solo el id del envío.
  for (const sendId of result.unreadable) log("warn", "snapshot_unreadable", { sendId });
  log("info", "link_viewed", {
    route,
    requestId: result.requestId,
    weeks: result.view.weeks.length,
    menus: result.view.weeks.filter((week) => week.menu !== null).length,
  });
  return reply(200, result.view);
}

async function answerRoute(
  deps: ClientLinkHandlerDeps,
  route: typeof CLIENT_LINK_ROUTES.confirm | typeof CLIENT_LINK_ROUTES.changes,
  tokenHash: string,
  body: ParsedBody,
  reply: Reply,
): Promise<Response> {
  const { log } = deps;
  const sendId = body.sendId ?? "";
  const confirm = route === CLIENT_LINK_ROUTES.confirm;
  const op = confirm ? "confirm_menu" : "request_changes";
  let data: unknown;
  try {
    data = confirm ? await deps.store.confirmMenu(tokenHash, sendId) : await deps.store.requestChanges(tokenHash, sendId, body.text ?? "");
  } catch (error) {
    return dbFailure(log, route, op, error, reply);
  }
  const answer = answerFromRpc(data);
  const at = confirm ? answer?.confirmedAt : answer?.changesRequestedAt;
  if (!answer || !at) {
    log("error", "unexpected_result", { op });
    return reply(500, { error: "server" });
  }

  const kind: MenuAnswerKind = confirm ? "confirmed" : "changes";
  log("info", confirm ? "menu_confirmed" : "changes_requested", {
    route,
    sendId: answer.sendId,
    requestId: answer.requestId,
    ...(confirm ? { already: answer.already } : {}),
  });
  // Una confirmación repetida no le avisa otra vez a Evelyn. Cada pedido de cambios, sí (reemplaza al anterior).
  if (!answer.already) {
    deps.waitUntil(
      notifyChef(deps, kind, answer).catch((error: unknown) => {
        log("error", "notify_crashed", { sendId: answer.sendId, error: error instanceof Error ? error.name : "unknown" });
      }),
    );
  }
  const response: ConfirmMenuResponse | RequestChangesResponse = confirm
    ? { confirmedAt: at, already: answer.already }
    : { changesRequestedAt: at };
  return reply(200, response);
}

export function createClientLinkHandler(deps: ClientLinkHandlerDeps): (request: Request) => Promise<Response> {
  const { config, log } = deps;

  return async (request: Request): Promise<Response> => {
    const origin = request.headers.get("origin");
    const reply: Reply = (status, body, extra = {}) =>
      new Response(JSON.stringify(body), {
        status,
        headers: {
          ...corsHeaders(origin, config.allowedOrigins, { preflight: false, methods: CLIENT_LINK_CORS_METHODS }),
          "Content-Type": "application/json; charset=utf-8",
          "Cache-Control": "no-store",
          ...extra,
        },
      });

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: corsHeaders(origin, config.allowedOrigins, { preflight: true, methods: CLIENT_LINK_CORS_METHODS }),
      });
    }

    try {
      const route = routeOf(new URL(request.url).pathname);
      if (route === null || !isClientLinkRoute(route)) return reply(404, { error: "notFound" });
      if (request.method !== "POST") return reply(405, { error: "method" }, { Allow: CLIENT_LINK_CORS_METHODS });
      if (!isJsonContentType(request.headers.get("content-type"))) return reply(415, { error: "contentType" });

      const body = await readBodyLimited(request, CLIENT_LINK_MAX_PAYLOAD_BYTES);
      if (!body.ok) return body.reason === "tooLarge" ? reply(413, { error: "tooLarge" }) : reply(400, { error: "invalidPayload" });
      let input: unknown;
      try {
        input = JSON.parse(body.text);
      } catch {
        return reply(400, { error: "invalidPayload" });
      }
      const parsed = parseBody(route, input);
      if (!parsed.ok) {
        log("info", "invalid_payload", { route, error: parsed.error });
        return reply(400, { error: parsed.error });
      }

      if (config.missing.length > 0 || !config.ipHashSalt) {
        log("error", "config_missing", { missing: config.missing });
        return reply(500, { error: "server" });
      }

      // Límite por IP: se guarda un HMAC de la IP (o de su /64), nunca la IP. Las respuestas, en su propio contador.
      const ip = clientIp(request.headers);
      if (!ip) log("warn", "client_ip_missing");
      const isView = route === CLIENT_LINK_ROUTES.view;
      const limits = isView ? VIEW_RATE_LIMITS : ANSWER_RATE_LIMITS;
      const ipHash = await hashSubject(isView ? viewRateSubject(ip) : answerRateSubject(ip), config.ipHashSalt);
      let allowed: boolean;
      try {
        allowed = await deps.store.hitRateLimit(ipHash, limits.perHour, limits.perDay);
      } catch (error) {
        return dbFailure(log, route, "rate_limit", error, reply);
      }
      if (!allowed) {
        log("info", "rate_limited", { route });
        return reply(429, { error: "rateLimited" }, { "Retry-After": String(RETRY_AFTER_SECONDS) });
      }

      // Un token con otra forma no existe: como uno vencido (sin decir cuál de las dos).
      if (!isClientLinkToken(parsed.value.token)) {
        log("info", "link_not_found", { route, reason: "malformed" });
        return reply(404, { error: "linkNotFound" });
      }
      const tokenHash = await hashClientLinkToken(parsed.value.token);
      if (isView) return await viewRoute(deps, tokenHash, reply);
      return await answerRoute(deps, route, tokenHash, parsed.value, reply);
    } catch (error) {
      // Solo el tipo de error: el mensaje podría traer datos.
      log("error", "unexpected_error", { error: error instanceof Error ? error.name : "unknown" });
      return reply(500, { error: "server" });
    }
  };
}

// ---------------------------------------------------------------------------
// Aviso a Evelyn (segundo plano)
// ---------------------------------------------------------------------------

/**
 * Le avisa a Evelyn (CHEF_NOTIFY_EMAIL, en CHEF_LOCALE) que la clienta confirmó el menú o pidió cambios, con el
 * link al pedido. El mensaje de la clienta no va (contrato §6). La clave de idempotencia de Resend: una por
 * confirmación y una por pedido de cambios (con su hora).
 */
async function notifyChef(deps: ClientLinkHandlerDeps, kind: MenuAnswerKind, answer: MenuAnswer): Promise<void> {
  const { config, log } = deps;
  const ids = { sendId: answer.sendId, kind };
  if (!config.chefNotifyEmail) {
    log("warn", "email_skipped", { ...ids, reason: "no_recipient" });
    return;
  }
  if (config.emailTransport === "resend" && (!config.resendApiKey || !config.mailFrom)) {
    log("warn", "email_skipped", { ...ids, reason: "not_configured" });
    return;
  }
  if (answer.week === null) {
    // La semana ya no está en la reserva (la base de hoy lo impide con session_cancelled): no hay «semana k».
    log("warn", "email_skipped", { ...ids, reason: "week_cancelled" });
    return;
  }
  const email = renderMenuAnswerNotification(
    {
      kind,
      brand: brandFromMailFrom(config.mailFrom),
      clientName: answer.clientName,
      requestId: answer.requestId,
      week: answer.week,
      weeks: answer.weeks,
      date: answer.date,
      start: answer.start,
      inboxUrl: config.inboxUrl,
    },
    config.chefLocale,
  );
  const at = kind === "confirmed" ? answer.confirmedAt : answer.changesRequestedAt;
  const message: EmailMessage = {
    from: config.mailFrom ?? "",
    to: config.chefNotifyEmail,
    replyTo: null,
    ...email,
    idempotencyKey: kind === "confirmed" ? `menu-confirmed-${answer.sendId}` : `menu-changes-${answer.sendId}-${Date.parse(at ?? "")}`,
  };
  if (config.emailTransport === "log") {
    log("info", "email_logged", { ...ids, htmlChars: message.html.length, textChars: message.text.length });
    return;
  }
  const outcome = await sendWithResend(message, { apiKey: config.resendApiKey ?? "", fetch: deps.fetch, sleep: deps.sleep });
  if (outcome.ok) log("info", "email_sent", ids);
  else log("error", "email_failed", { ...ids, status: outcome.status, errorName: outcome.errorName });
}
