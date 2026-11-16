// Lógica de la Edge Function public-request (docs/contracts/public-request.md §2, §4, §5 y §11).
// No depende de Deno ni de supabase-js: index.ts arma las dependencias reales y los tests
// (handler.test.ts, en Node) las simulan.
//
// Dos rutas:
// - POST <función> (el pedido). Orden: CORS → método (405) → tipo (415) → tamaño (413) → JSON y
//   validación (400) → configuración (500) → límite por IP (429) → Turnstile (403) → cocinera
//   (CHEF_ID o la única de public.chefs) y sus tarifas → guardado en una transacción
//   (submit_public_request) → 201. Los emails y el WhatsApp salen después, en segundo plano
//   (waitUntil): un fallo de envío no rompe el pedido. Un reintento con la misma requestKey recibe
//   un 201 con el mismo id y la estimación guardada, más duplicate: true, y no repite ningún aviso.
// - GET <función>/availability?minutes=N (el calendario, §11). Orden: CORS → método (405) →
//   minutes (400) → configuración (500) → su propio límite por IP (429) → cocinera →
//   get_free_days (503 si falla la base) → 200, con caché pública de un minuto.
//
// Los logs nunca llevan datos personales, de salud ni la IP: solo ids, códigos y contadores.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import {
  AVAILABILITY_DAYS,
  AVAILABILITY_PATH,
  buildAvailabilityResponse,
  parseAvailabilityMinutes,
} from "../_shared/availability.ts";
import { clientIp, hashSubject, rateLimitSubject } from "../_shared/client_ip.ts";
import { corsHeaders, parseAllowedOrigins, type OriginRule } from "../_shared/cors.ts";
import {
  allergyAnswer,
  brandFromMailFrom,
  privacyPageUrl,
  renderChefNotification,
  renderClientConfirmation,
  safeFirstName,
  type RequestSummary,
} from "../_shared/emails.ts";
import {
  DATE_WINDOW,
  LOCALES,
  MAX_PAYLOAD_BYTES,
  addDays,
  isIsoDate,
  isOneOf,
  parsePublicRequest,
  publicEstimate,
  readPublicEstimate,
  romeToday,
  type Allergen,
  type Diet,
  type Locale,
  type Meal,
  type NormalizedPublicRequest,
  type RequestType,
  type Slot,
} from "../_shared/public_request.ts";
import { calcQuote, type PricingSettings, type Quote } from "../_shared/quote.ts";
import { sendWithResend, type EmailMessage } from "../_shared/resend.ts";
import { verifyTurnstile } from "../_shared/turnstile.ts";
import { sendWhatsAppTemplate, whatsAppConfigFrom, type WhatsAppConfig } from "../_shared/whatsapp.ts";

/** Contrato §2: más de 5 por hora o 20 por día por IP → 429. */
export const RATE_LIMITS = { perHour: 5, perDay: 20 } as const;
/** La ventana corta es de una hora: la web puede sugerir reintentar después. */
export const RETRY_AFTER_SECONDS = 3600;

/**
 * Contrato §11: lecturas del calendario por IP. Más generoso que el del pedido (cada cambio de
 * personas, días o comidas puede pedir otra duración) y en otro contador: no gasta el cupo del POST.
 */
export const AVAILABILITY_RATE_LIMITS = { perHour: 120, perDay: 600 } as const;
/** La disponibilidad depende solo de la URL (y del origen, por CORS): el navegador la guarda un minuto. */
export const AVAILABILITY_CACHE_CONTROL = "public, max-age=60";

/**
 * Clave del límite de las lecturas: la del pedido con el prefijo "availability:". Con el HMAC queda
 * otra fila en public_request_hits (la misma función SQL, otro contador), sin migración.
 */
export function availabilityRateSubject(ip: string | null): string {
  return `availability:${ip ? rateLimitSubject(ip) : "unknown"}`;
}

// ---------------------------------------------------------------------------
// Configuración (secretos y variables de la función, contrato §4)
// ---------------------------------------------------------------------------

export interface PublicRequestConfig {
  /** CHEF_ID en minúsculas, o null si no está: entonces se usa la única fila de public.chefs. */
  chefId: string | null;
  /** Variables con un valor que no sirve (ej. CHEF_ID que no es uuid): la función responde 500. */
  invalid: string[];
  turnstileSecret: string | null;
  ipHashSalt: string | null;
  allowedOrigins: OriginRule[];
  emailTransport: "resend" | "log";
  resendApiKey: string | null;
  mailFrom: string | null;
  mailReplyTo: string | null;
  chefNotifyEmail: string | null;
  chefLocale: Locale;
  inboxUrl: string | null;
  publicSiteUrl: string | null;
  whatsapp: WhatsAppConfig | null;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Idioma de los avisos a Evelyn si CHEF_LOCALE falta o no es it, es ni en: lee en español. */
export const DEFAULT_CHEF_LOCALE: Locale = "es";

export function readConfig(get: (name: string) => string | undefined): PublicRequestConfig {
  const value = (name: string): string | null => {
    const raw = get(name)?.trim();
    return raw ? raw : null;
  };
  const chefId = value("CHEF_ID")?.toLowerCase() ?? null;
  const chefIdValid = chefId !== null && UUID_PATTERN.test(chefId);
  const chefLocale = value("CHEF_LOCALE")?.toLowerCase();
  return {
    chefId: chefIdValid ? chefId : null,
    // Un CHEF_ID mal escrito no cae en la cocinera por defecto: mejor un 500 claro que adivinar.
    invalid: chefId !== null && !chefIdValid ? ["CHEF_ID"] : [],
    turnstileSecret: value("TURNSTILE_SECRET_KEY"),
    ipHashSalt: value("IP_HASH_SALT"),
    allowedOrigins: parseAllowedOrigins(value("ALLOWED_ORIGINS")),
    emailTransport: value("EMAIL_TRANSPORT")?.toLowerCase() === "log" ? "log" : "resend",
    resendApiKey: value("RESEND_API_KEY"),
    mailFrom: value("MAIL_FROM"),
    mailReplyTo: value("MAIL_REPLY_TO"),
    chefNotifyEmail: value("CHEF_NOTIFY_EMAIL"),
    chefLocale: isOneOf(LOCALES, chefLocale) ? chefLocale : DEFAULT_CHEF_LOCALE,
    inboxUrl: value("INBOX_URL"),
    publicSiteUrl: value("PUBLIC_SITE_URL"),
    whatsapp: whatsAppConfigFrom(get),
  };
}

/**
 * Sin estas no se puede atender ningún pedido (→ 500). CHEF_ID no está: si falta, se usa la
 * única cocinera de public.chefs (así el primer despliegue funciona antes de conocer su id).
 */
export function missingRequiredConfig(config: PublicRequestConfig): string[] {
  const missing: string[] = [];
  if (!config.turnstileSecret) missing.push("TURNSTILE_SECRET_KEY");
  if (!config.ipHashSalt) missing.push("IP_HASH_SALT");
  return missing;
}

/** Sin estas los pedidos se guardan, pero falta algo (CORS, avisos o links). Se avisan al arrancar. */
export function configWarnings(config: PublicRequestConfig): string[] {
  const warnings: string[] = [];
  if (config.allowedOrigins.length === 0) warnings.push("ALLOWED_ORIGINS");
  if (!config.chefNotifyEmail) warnings.push("CHEF_NOTIFY_EMAIL");
  if (config.emailTransport === "resend") {
    if (!config.resendApiKey) warnings.push("RESEND_API_KEY");
    if (!config.mailFrom) warnings.push("MAIL_FROM");
  }
  if (!config.inboxUrl) warnings.push("INBOX_URL");
  if (!config.publicSiteUrl) warnings.push("PUBLIC_SITE_URL");
  return warnings;
}

/**
 * Clave con permisos de servicio para el cliente de Supabase. Primero la clave secreta nueva
 * (SUPABASE_SECRET_KEYS, JSON con nombre → clave; se usa "default"), después las variables de
 * compatibilidad. Las claves service_role (JWT) dejan de existir a fines de 2026.
 */
export function resolveServiceKey(get: (name: string) => string | undefined): string | null {
  const keys = get("SUPABASE_SECRET_KEYS");
  if (keys) {
    try {
      const parsed: unknown = JSON.parse(keys);
      const key = typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>)["default"] : null;
      if (typeof key === "string" && key) return key;
    } catch {
      // JSON roto: se prueba con las otras variables.
    }
  }
  return get("SUPABASE_SECRET_KEY") || get("SUPABASE_SERVICE_ROLE_KEY") || null;
}

// ---------------------------------------------------------------------------
// Logs: solo valores simples, nunca objetos con datos del pedido
// ---------------------------------------------------------------------------

export type LogLevel = "info" | "warn" | "error";
export type LogValue = string | number | boolean | null | readonly string[];
export type LogFields = Readonly<Record<string, LogValue>>;
export type Logger = (level: LogLevel, event: string, fields?: LogFields) => void;

export const consoleLogger: Logger = (level, event, fields = {}) => {
  const line = JSON.stringify({ level, event, ...fields });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.info(line);
};

// ---------------------------------------------------------------------------
// Acceso a la base (index.ts lo implementa con supabase-js y la clave secreta)
// ---------------------------------------------------------------------------

export interface ChefInfo {
  displayName: string;
  pricing: PricingSettings;
}

/**
 * Lo que se guarda en requests.estimate: calcQuote con las tarifas usadas. Siempre trae weeks, autoPrice,
 * las porciones, los minutos y la compra; las claves del precio, solo con precio automático (SPEC §5.1).
 */
export type StoredEstimate = Quote & { pricing: PricingSettings };

/** Argumento `p` de public.submit_public_request (snake_case, como la base). */
export interface SubmitPublicRequestParams {
  chef_id: string;
  type: RequestType;
  adults: number;
  kids: number;
  days: number;
  meals: Meal[];
  /** requests.weeks: 1 a 8, y 1 si no es un pedido semanal (migración 20261116120000_weekly_pricing.sql). */
  weeks: number;
  /** Respuesta a la pregunta de alergias: true = nadie tiene; false = las escribió (requests.no_allergies). */
  no_allergies: boolean;
  allergens: Allergen[];
  diets: Diet[];
  restrictions_note: string;
  preferred_date: string | null;
  preferred_slot: Slot;
  name: string;
  zone: string;
  /** E.164: "+393331234567". */
  phone: string;
  email: string;
  whatsapp_opt_in: boolean;
  notes: string;
  locale: Locale;
  privacy_consent_version: string;
  health_consent_version: string | null;
  estimate: StoredEstimate;
  /** requestKey de la web (uuid en minúsculas) o null: idempotencia por (chef_id, request_key). */
  request_key: string | null;
}

/** Lo que devuelve public.submit_public_request. */
export interface SubmitResult {
  requestId: string;
  /** true: la clave ya existía y es el pedido guardado antes (la base no cambió nada). */
  duplicate: boolean;
  /** requests.estimate tal como quedó guardado (en un duplicado, la del pedido original). */
  storedEstimate: unknown;
}

/** Si no hay CHEF_ID: la única cocinera de public.chefs, o por qué no se puede elegir una. */
export type DefaultChef = { ok: true; chefId: string } | { ok: false; reason: "no_chef" | "multiple_chefs" };

export interface PublicRequestStore {
  /** public.hit_public_request_rate: registra el intento y dice si está dentro del límite. */
  hitRateLimit(ipHash: string, maxPerHour: number, maxPerDay: number): Promise<boolean>;
  /** Sin CHEF_ID: el id de la única fila de public.chefs (sin filas o con más de una, no hay). */
  resolveDefaultChef(): Promise<DefaultChef>;
  /** Tarifas (chef_settings) y nombre de la cocinera, o null si no existe. */
  loadChef(chefId: string): Promise<ChefInfo | null>;
  /** public.submit_public_request. */
  submit(params: SubmitPublicRequestParams): Promise<SubmitResult>;
  /** Completa notifications.sent_at del aviso 'new_request' de ese pedido. */
  markChefNotificationSent(requestId: string): Promise<void>;
  /**
   * public.get_free_days: las fechas ("AAAA-MM-DD") de [fromDate, fromDate + days − 1] con al menos
   * un horario libre para cookMinutes de cocina.
   */
  freeDays(chefId: string, cookMinutes: number, fromDate: string, days: number): Promise<string[]>;
}

/** Error de la base sin datos: operación, SQLSTATE y, como mucho, un código propio en snake_case. */
export class StoreError extends Error {
  readonly op: string;
  readonly code: string | null;
  readonly safeMessage: string | null;

  constructor(op: string, code: string | null, safeMessage: string | null) {
    super(`db_error:${op}`);
    this.name = "StoreError";
    this.op = op;
    this.code = code;
    this.safeMessage = safeMessage;
  }
}

/**
 * Los mensajes de Postgres pueden traer la fila (con datos personales). Solo pasan los códigos
 * propios de las funciones SQL, que son identificadores (ej. health_consent_required).
 */
export function safeDbMessage(message: string | null | undefined): string | null {
  return message && /^[a-z][a-z0-9_]{2,63}$/.test(message) ? message : null;
}

/**
 * Columnas de chef_settings que lee la función: las tarifas del motor (PricingSettings) y el nombre de la
 * cocinera. Las del precio por semana son de 20261116120000_weekly_pricing.sql: sin esa migración la
 * consulta falla (500, load_chef) y no se guarda ningún pedido de varias semanas como si fuera de una.
 * Un solo literal, sin concatenar: supabase-js lee el tipo del select del texto.
 */
export const CHEF_SETTINGS_COLUMNS =
  "weekly_rate_cents, weekly_rate_discounted_cents, weekly_discount_min_weeks, weekly_rate_max_people, adult_portion_cents, kid_portion_cents, preauth_buffer_pct, min_cook_minutes, chefs(display_name)";

/** Fila de chef_settings con el nombre de la cocinera embebido (chefs.display_name). */
export function chefFromRow(row: Readonly<Record<string, unknown>>): ChefInfo {
  const int = (name: string): number => {
    const value = row[name];
    if (typeof value !== "number" || !Number.isInteger(value)) throw new TypeError(`chef_settings.${name} no es un entero`);
    return value;
  };
  const embedded = row["chefs"];
  const chef: unknown = Array.isArray(embedded) ? embedded[0] : embedded;
  const name = typeof chef === "object" && chef !== null ? (chef as Record<string, unknown>)["display_name"] : null;
  return {
    displayName: typeof name === "string" && name.trim() ? name.trim() : "Evelyn",
    pricing: {
      weeklyRateCents: int("weekly_rate_cents"),
      weeklyRateDiscountedCents: int("weekly_rate_discounted_cents"),
      weeklyDiscountMinWeeks: int("weekly_discount_min_weeks"),
      weeklyRateMaxPeople: int("weekly_rate_max_people"),
      adultPortionCents: int("adult_portion_cents"),
      kidPortionCents: int("kid_portion_cents"),
      preauthBufferPct: int("preauth_buffer_pct"),
      minCookMinutes: int("min_cook_minutes"),
    },
  };
}

/** Resultado de public.submit_public_request ({request_id, duplicate, estimate}), o null si no tiene esa forma. */
export function submitResultFromRpc(data: unknown): SubmitResult | null {
  if (typeof data !== "object" || data === null || Array.isArray(data)) return null;
  const record = data as Record<string, unknown>;
  const requestId = record["request_id"];
  const duplicate = record["duplicate"];
  if (typeof requestId !== "string" || !UUID_PATTERN.test(requestId) || typeof duplicate !== "boolean") return null;
  return { requestId, duplicate, storedEstimate: record["estimate"] ?? null };
}

/**
 * Filas de public.get_free_days ([{ day: "AAAA-MM-DD", available: boolean }, …]): las fechas con
 * available = true, o null si la respuesta no tiene esa forma.
 */
export function availableDatesFromRpc(data: unknown): string[] | null {
  if (!Array.isArray(data)) return null;
  const dates: string[] = [];
  for (const row of data) {
    if (typeof row !== "object" || row === null) return null;
    const { day, available } = row as Record<string, unknown>;
    if (typeof day !== "string" || !isIsoDate(day) || typeof available !== "boolean") return null;
    if (available) dates.push(day);
  }
  return dates;
}

export function toSubmitParams(chefId: string, value: NormalizedPublicRequest, estimate: StoredEstimate): SubmitPublicRequestParams {
  return {
    chef_id: chefId,
    type: value.type,
    adults: value.adults,
    kids: value.kids,
    days: value.days,
    meals: value.meals,
    weeks: value.weeks,
    no_allergies: value.noAllergies,
    allergens: value.allergens,
    diets: value.diets,
    restrictions_note: value.restrictionsNote,
    preferred_date: value.preferredDate,
    preferred_slot: value.slot,
    name: value.name,
    zone: value.zone,
    phone: value.phoneE164,
    email: value.email,
    whatsapp_opt_in: value.whatsappOptIn,
    notes: value.notes,
    locale: value.locale,
    privacy_consent_version: value.consents.privacy,
    health_consent_version: value.consents.health,
    estimate,
    request_key: value.requestKey,
  };
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

export interface HandlerDeps {
  config: PublicRequestConfig;
  store: PublicRequestStore;
  /** Para Turnstile, Resend y WhatsApp. */
  fetch: typeof fetch;
  now: () => Date;
  /** EdgeRuntime.waitUntil: deja terminar los envíos después de responder. */
  waitUntil: (task: Promise<unknown>) => void;
  log: Logger;
  sleep: (ms: number) => Promise<void>;
  /** UUID nuevo (clave de idempotencia de Turnstile). */
  newId: () => string;
}

function isJsonContentType(value: string | null): boolean {
  return (value ?? "").split(";")[0]?.trim().toLowerCase() === "application/json";
}

type BodyResult = { ok: true; text: string } | { ok: false; reason: "tooLarge" | "invalid" };

/** Lee el cuerpo sin pasar de `max` bytes (también si no viene Content-Length). */
async function readBodyLimited(request: Request, max: number): Promise<BodyResult> {
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > max) return { ok: false, reason: "tooLarge" };
  if (!request.body) return { ok: true, text: "" };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      return { ok: false, reason: "tooLarge" };
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return { ok: true, text: new TextDecoder("utf-8", { fatal: true }).decode(bytes) };
  } catch {
    return { ok: false, reason: "invalid" };
  }
}

function logStoreError(log: Logger, error: unknown, op: string): void {
  if (error instanceof StoreError) {
    log("error", "db_error", error.safeMessage ? { op: error.op, code: error.code, message: error.safeMessage } : { op: error.op, code: error.code });
  } else {
    log("error", "db_error", { op, code: null });
  }
}

type ChefResolution = { ok: true; chefId: string } | { ok: false; reason: "db_error" | "unresolved" };

/** Cocinera de la función: CHEF_ID o, si no está configurado, la única de public.chefs. Deja el motivo en el log. */
async function resolveChef(deps: HandlerDeps): Promise<ChefResolution> {
  if (deps.config.chefId) return { ok: true, chefId: deps.config.chefId };
  let resolved: DefaultChef;
  try {
    resolved = await deps.store.resolveDefaultChef();
  } catch (error) {
    logStoreError(deps.log, error, "resolve_chef");
    return { ok: false, reason: "db_error" };
  }
  if (!resolved.ok) {
    // no_chef: falta promote_to_chef. multiple_chefs: hay que fijar CHEF_ID.
    deps.log("error", "chef_id_unresolved", { reason: resolved.reason });
    return { ok: false, reason: "unresolved" };
  }
  return { ok: true, chefId: resolved.chefId };
}

type Reply = (status: number, body: unknown, extra?: Record<string, string>) => Response;

/**
 * GET …/availability?minutes=N (contrato §11): para cada día de la ventana del formulario (de mañana
 * a +56, 8 semanas, en Roma), si la cocinera tiene al menos un horario libre para esa duración de cocina.
 * El 200 y el 400 dependen solo de la URL: caché pública de un minuto. Los errores, no-store.
 */
async function availabilityRoute(deps: HandlerDeps, request: Request, url: URL, reply: Reply): Promise<Response> {
  const { config, log } = deps;
  if (request.method !== "GET") return reply(405, { error: "method" }, { Allow: "GET, OPTIONS" });
  const cacheable = { "Cache-Control": AVAILABILITY_CACHE_CONTROL };

  const minutes = parseAvailabilityMinutes(url.searchParams.get("minutes"));
  if (minutes === null) return reply(400, { errors: { minutes: "invalid" } }, cacheable);

  // Una lectura no pasa por Turnstile: solo hacen falta la sal del límite y, si está, un CHEF_ID válido.
  if (!config.ipHashSalt) log("error", "config_missing", { missing: ["IP_HASH_SALT"] });
  if (config.invalid.length > 0) log("error", "config_invalid", { invalid: config.invalid });
  if (!config.ipHashSalt || config.invalid.length > 0) return reply(500, { error: "server" });

  // Su propio contador (otra clave, la misma función SQL): no gasta el cupo del formulario.
  const ip = clientIp(request.headers);
  if (!ip) log("warn", "client_ip_missing");
  const ipHash = await hashSubject(availabilityRateSubject(ip), config.ipHashSalt);
  let allowed: boolean;
  try {
    allowed = await deps.store.hitRateLimit(ipHash, AVAILABILITY_RATE_LIMITS.perHour, AVAILABILITY_RATE_LIMITS.perDay);
  } catch (error) {
    logStoreError(log, error, "rate_limit");
    return reply(503, { error: "server" });
  }
  if (!allowed) {
    log("info", "rate_limited", { route: "availability" });
    return reply(429, { error: "rateLimited" }, { "Retry-After": String(RETRY_AFTER_SECONDS) });
  }

  const chef = await resolveChef(deps);
  if (!chef.ok) return reply(chef.reason === "db_error" ? 503 : 500, { error: "server" });

  // "Hoy" en Roma; la ventana es la de availabilityDates: desde mañana, AVAILABILITY_DAYS días.
  const today = romeToday(deps.now());
  let free: string[];
  try {
    free = await deps.store.freeDays(chef.chefId, minutes, addDays(today, DATE_WINDOW.minDaysAhead), AVAILABILITY_DAYS);
  } catch (error) {
    logStoreError(log, error, "free_days");
    return reply(503, { error: "server" });
  }
  return reply(200, buildAvailabilityResponse(today, minutes, free), cacheable);
}

export function createPublicRequestHandler(deps: HandlerDeps): (request: Request) => Promise<Response> {
  const { config, log } = deps;

  return async (request: Request): Promise<Response> => {
    const origin = request.headers.get("origin");
    const reply = (status: number, body: unknown, extra: Record<string, string> = {}): Response =>
      new Response(JSON.stringify(body), {
        status,
        headers: {
          ...corsHeaders(origin, config.allowedOrigins, { preflight: false }),
          "Content-Type": "application/json; charset=utf-8",
          "Cache-Control": "no-store",
          ...extra,
        },
      });

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(origin, config.allowedOrigins, { preflight: true }) });
    }

    try {
      // La URL termina en /availability (antes de la query): el calendario. Cualquier otra, el pedido.
      const url = new URL(request.url);
      if (url.pathname.endsWith(AVAILABILITY_PATH)) return await availabilityRoute(deps, request, url, reply);

      if (request.method !== "POST") return reply(405, { error: "method" }, { Allow: "POST, OPTIONS" });
      if (!isJsonContentType(request.headers.get("content-type"))) return reply(415, { error: "contentType" });

      const body = await readBodyLimited(request, MAX_PAYLOAD_BYTES);
      if (!body.ok) {
        return body.reason === "tooLarge" ? reply(413, { error: "tooLarge" }) : reply(400, { errors: { payload: "invalid" } });
      }
      let input: unknown;
      try {
        input = JSON.parse(body.text);
      } catch {
        return reply(400, { errors: { payload: "invalid" } });
      }

      const parsed = parsePublicRequest(input, { today: romeToday(deps.now()) });
      if (!parsed.ok) return reply(400, { errors: parsed.errors });
      const value = parsed.value;

      const missing = missingRequiredConfig(config);
      if (missing.length > 0) log("error", "config_missing", { missing });
      if (config.invalid.length > 0) log("error", "config_invalid", { invalid: config.invalid });
      if (missing.length > 0 || config.invalid.length > 0 || !config.turnstileSecret || !config.ipHashSalt) {
        return reply(500, { error: "server" });
      }

      // Límite por IP: se guarda un HMAC de la IP (o de su /64), nunca la IP.
      const ip = clientIp(request.headers);
      if (!ip) log("warn", "client_ip_missing");
      const ipHash = await hashSubject(ip ? rateLimitSubject(ip) : "unknown", config.ipHashSalt);
      let allowed: boolean;
      try {
        allowed = await deps.store.hitRateLimit(ipHash, RATE_LIMITS.perHour, RATE_LIMITS.perDay);
      } catch (error) {
        logStoreError(log, error, "rate_limit");
        return reply(500, { error: "server" });
      }
      if (!allowed) {
        log("info", "rate_limited");
        return reply(429, { error: "rateLimited" }, { "Retry-After": String(RETRY_AFTER_SECONDS) });
      }

      const turnstile = await verifyTurnstile({
        secret: config.turnstileSecret,
        token: value.turnstileToken,
        remoteIp: ip,
        idempotencyKey: deps.newId(),
        fetch: deps.fetch,
      });
      if (!turnstile.ok) {
        if (turnstile.reason === "rejected") {
          log("info", "turnstile_rejected", { errorCodes: turnstile.errorCodes });
          return reply(403, { errors: { turnstileToken: "invalid" } });
        }
        log("error", `turnstile_${turnstile.reason}`, { errorCodes: turnstile.errorCodes });
        return reply(500, { error: "server" });
      }

      // Cocinera: CHEF_ID o, si no está configurado, la única de public.chefs.
      const resolved = await resolveChef(deps);
      if (!resolved.ok) return reply(500, { error: "server" });
      const chefId = resolved.chefId;

      // Estimación con las tarifas actuales de la cocinera (no las de la web).
      let chef: ChefInfo | null;
      try {
        chef = await deps.store.loadChef(chefId);
      } catch (error) {
        logStoreError(log, error, "load_chef");
        return reply(500, { error: "server" });
      }
      if (!chef) {
        log("error", "chef_not_found");
        return reply(500, { error: "server" });
      }
      let estimate: Quote;
      try {
        estimate = calcQuote(value.quoteInput, chef.pricing);
      } catch {
        log("error", "quote_failed");
        return reply(500, { error: "server" });
      }

      let saved: SubmitResult;
      try {
        saved = await deps.store.submit(toSubmitParams(chefId, value, { ...estimate, pricing: chef.pricing }));
      } catch (error) {
        logStoreError(log, error, "submit");
        return reply(500, { error: "server" });
      }
      const requestId = saved.requestId;

      if (saved.duplicate) {
        // Reintento de un pedido ya guardado: el mismo id y la estimación guardada, ningún aviso, y
        // duplicate: true para que la web no muestre como enviado lo que se cambió después (contrato §2).
        // La guardada puede ser de antes del precio por semana: readPublicEstimate la lee igual.
        log("info", "request_duplicate", { requestId });
        const stored = readPublicEstimate(saved.storedEstimate);
        if (!stored) log("warn", "stored_estimate_invalid", { requestId });
        return reply(201, { requestId, estimate: stored ?? publicEstimate(estimate), duplicate: true });
      }
      log("info", "request_saved", { requestId });

      deps.waitUntil(
        sendNotifications(deps, { requestId, value, estimate, chef }).catch((error: unknown) => {
          log("error", "notify_crashed", { error: error instanceof Error ? error.name : "unknown" });
        }),
      );

      return reply(201, { requestId, estimate: publicEstimate(estimate) });
    } catch (error) {
      // Solo el tipo de error: el mensaje podría traer datos del pedido.
      log("error", "unexpected_error", { error: error instanceof Error ? error.name : "unknown" });
      return reply(500, { error: "server" });
    }
  };
}

// ---------------------------------------------------------------------------
// Notificaciones (segundo plano)
// ---------------------------------------------------------------------------

interface NotifyContext {
  requestId: string;
  value: NormalizedPublicRequest;
  estimate: Quote;
  chef: ChefInfo;
}

type Recipient = "chef" | "client";

function summaryOf(context: NotifyContext): RequestSummary {
  const { value, estimate, chef } = context;
  return {
    requestId: context.requestId,
    type: value.type,
    adults: value.adults,
    kids: value.kids,
    days: value.days,
    meals: value.meals,
    weeks: value.weeks,
    preferredDate: value.preferredDate,
    slot: value.slot,
    allergies: allergyAnswer(value.noAllergies, value.hasRestrictions),
    // El precio con las tarifas de la cocinera: el mismo que se guardó y que vio el 201.
    estimate: estimate.autoPrice
      ? {
          autoPrice: true,
          weeklyServiceCents: estimate.weeklyServiceCents,
          serviceCents: estimate.serviceCents,
          savingsCents: estimate.savingsCents,
          regularWeeklyCents: chef.pricing.weeklyRateCents,
          groceriesEstCents: estimate.groceriesEstCents,
        }
      : {
          autoPrice: false,
          reason: estimate.reason,
          maxPeople: chef.pricing.weeklyRateMaxPeople,
          groceriesEstCents: estimate.groceriesEstCents,
        },
  };
}

async function sendNotifications(deps: HandlerDeps, context: NotifyContext): Promise<void> {
  await Promise.allSettled([notifyChef(deps, context), notifyClient(deps, context), notifyWhatsApp(deps, context)]);
}

/** Manda (o registra, con EMAIL_TRANSPORT=log) un email. true si salió. */
async function deliver(deps: HandlerDeps, recipient: Recipient, context: NotifyContext, message: EmailMessage): Promise<boolean> {
  const { config, log } = deps;
  const requestId = context.requestId;
  if (config.emailTransport === "log") {
    log("info", "email_logged", { requestId, recipient, htmlChars: message.html.length, textChars: message.text.length });
    return true;
  }
  if (!config.resendApiKey) return false;
  const outcome = await sendWithResend(message, { apiKey: config.resendApiKey, fetch: deps.fetch, sleep: deps.sleep });
  if (outcome.ok) {
    log("info", "email_sent", { requestId, recipient });
    return true;
  }
  log("error", "email_failed", { requestId, recipient, status: outcome.status, errorName: outcome.errorName });
  return false;
}

function emailReady(deps: HandlerDeps, recipient: Recipient, requestId: string): boolean {
  const { config } = deps;
  if (config.emailTransport === "log" || (config.resendApiKey && config.mailFrom)) return true;
  deps.log("warn", "email_skipped", { requestId, recipient, reason: "not_configured" });
  return false;
}

async function notifyChef(deps: HandlerDeps, context: NotifyContext): Promise<void> {
  const { config, log } = deps;
  const { requestId, value } = context;
  if (!config.chefNotifyEmail) {
    log("warn", "email_skipped", { requestId, recipient: "chef", reason: "no_recipient" });
    return;
  }
  if (!emailReady(deps, "chef", requestId)) return;
  const email = renderChefNotification(
    {
      brand: brandFromMailFrom(config.mailFrom),
      customerName: value.name,
      zone: value.zone,
      phoneE164: value.phoneE164,
      email: value.email,
      whatsappOptIn: value.whatsappOptIn,
      hasNotes: value.notes !== "",
      summary: summaryOf(context),
      inboxUrl: config.inboxUrl,
    },
    config.chefLocale,
  );
  const sent = await deliver(deps, "chef", context, {
    from: config.mailFrom ?? "",
    to: config.chefNotifyEmail,
    // Evelyn responde directo al cliente.
    replyTo: value.email,
    ...email,
    idempotencyKey: `request-${requestId}-chef`,
  });
  if (!sent) return;
  try {
    await deps.store.markChefNotificationSent(requestId);
  } catch (error) {
    logStoreError(log, error, "mark_sent");
  }
}

async function notifyClient(deps: HandlerDeps, context: NotifyContext): Promise<void> {
  const { config } = deps;
  const { requestId, value } = context;
  if (!emailReady(deps, "client", requestId)) return;
  const email = renderClientConfirmation(
    {
      brand: brandFromMailFrom(config.mailFrom),
      chefName: context.chef.displayName,
      customerName: value.name,
      summary: summaryOf(context),
      privacyUrl: config.publicSiteUrl ? privacyPageUrl(config.publicSiteUrl, value.locale) : null,
    },
    value.locale,
  );
  await deliver(deps, "client", context, {
    from: config.mailFrom ?? "",
    to: value.email,
    // Las respuestas del cliente le llegan a Evelyn.
    replyTo: config.mailReplyTo ?? config.chefNotifyEmail,
    ...email,
    idempotencyKey: `request-${requestId}-client`,
  });
}

async function notifyWhatsApp(deps: HandlerDeps, context: NotifyContext): Promise<void> {
  const { config, log } = deps;
  const { requestId, value } = context;
  if (!value.whatsappOptIn) return;
  if (!config.whatsapp) {
    log("info", "whatsapp_skipped", { requestId, reason: "not_configured" });
    return;
  }
  // Solo un nombre que parece un nombre (si no, "-"): el número no está verificado y el mensaje
  // sale del número de Evelyn, así que no puede llevar un link escrito en el formulario.
  const outcome = await sendWhatsAppTemplate(
    config.whatsapp,
    { to: value.phoneE164, locale: value.locale, firstName: safeFirstName(value.name) },
    { fetch: deps.fetch },
  );
  if (outcome.ok) log("info", "whatsapp_sent", { requestId });
  else log("error", "whatsapp_failed", { requestId, status: outcome.status, errorName: outcome.errorName });
}
