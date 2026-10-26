// Lógica de la Edge Function public-request (docs/contracts/public-request.md §2, §4 y §5).
// No depende de Deno ni de supabase-js: index.ts arma las dependencias reales y los tests
// (handler.test.ts, en Node) las simulan.
//
// Orden: CORS → método (405) → tipo (415) → tamaño (413) → JSON y validación (400) →
// configuración (500) → límite por IP (429) → Turnstile (403) → cocinera (CHEF_ID o la única
// de public.chefs) y sus tarifas → guardado en una transacción (submit_public_request) → 201.
// Los emails y el WhatsApp salen después, en segundo plano (waitUntil): un fallo de envío no
// rompe el pedido. Un reintento con la misma requestKey recibe un 201 con el mismo id y la
// estimación guardada, más duplicate: true, y no repite ningún aviso.
//
// Los logs nunca llevan datos personales, de salud ni la IP: solo ids, códigos y contadores.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import { clientIp, hashSubject, rateLimitSubject } from "../_shared/client_ip.ts";
import { corsHeaders, parseAllowedOrigins, type OriginRule } from "../_shared/cors.ts";
import {
  brandFromMailFrom,
  privacyPageUrl,
  renderChefNotification,
  renderClientConfirmation,
  safeFirstName,
  type RequestSummary,
} from "../_shared/emails.ts";
import {
  LOCALES,
  MAX_PAYLOAD_BYTES,
  isOneOf,
  parsePublicRequest,
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

/** Lo que se guarda en requests.estimate: calcQuote con las tarifas usadas. */
export type StoredEstimate = Quote & { pricing: PricingSettings };

/** Argumento `p` de public.submit_public_request (snake_case, como la base). */
export interface SubmitPublicRequestParams {
  chef_id: string;
  type: RequestType;
  adults: number;
  kids: number;
  days: number;
  meals: Meal[];
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
      hourlyRateCents: int("hourly_rate_cents"),
      travelFeeCents: int("travel_fee_cents"),
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

export function toSubmitParams(chefId: string, value: NormalizedPublicRequest, estimate: StoredEstimate): SubmitPublicRequestParams {
  return {
    chef_id: chefId,
    type: value.type,
    adults: value.adults,
    kids: value.kids,
    days: value.days,
    meals: value.meals,
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

/** Estimación del cuerpo del 201 (contrato §2). */
export interface ResponseEstimate {
  portions: number;
  recipes: number;
  cookMinutes: number;
  serviceCents: number;
  groceriesEstCents: number;
  totalCents: number;
}

const RESPONSE_ESTIMATE_KEYS = ["portions", "recipes", "cookMinutes", "serviceCents", "groceriesEstCents", "totalCents"] as const;

export function responseEstimate(quote: Quote): ResponseEstimate {
  return {
    portions: quote.portions,
    recipes: quote.recipes,
    cookMinutes: quote.cookMinutes,
    serviceCents: quote.serviceCents,
    groceriesEstCents: quote.groceriesEstCents,
    totalCents: quote.totalCents,
  };
}

/** La estimación guardada en requests.estimate, o null si le falta algo (enteros ≥ 0). */
export function responseEstimateFromStored(stored: unknown): ResponseEstimate | null {
  if (typeof stored !== "object" || stored === null || Array.isArray(stored)) return null;
  const record = stored as Record<string, unknown>;
  const result: Partial<Record<(typeof RESPONSE_ESTIMATE_KEYS)[number], number>> = {};
  for (const key of RESPONSE_ESTIMATE_KEYS) {
    const value = record[key];
    if (typeof value !== "number" || !Number.isInteger(value) || value < 0) return null;
    result[key] = value;
  }
  return result as ResponseEstimate;
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
      let chefId = config.chefId;
      if (!chefId) {
        let resolved: DefaultChef;
        try {
          resolved = await deps.store.resolveDefaultChef();
        } catch (error) {
          logStoreError(log, error, "resolve_chef");
          return reply(500, { error: "server" });
        }
        if (!resolved.ok) {
          // no_chef: falta promote_to_chef. multiple_chefs: hay que fijar CHEF_ID.
          log("error", "chef_id_unresolved", { reason: resolved.reason });
          return reply(500, { error: "server" });
        }
        chefId = resolved.chefId;
      }

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
        log("info", "request_duplicate", { requestId });
        const stored = responseEstimateFromStored(saved.storedEstimate);
        if (!stored) log("warn", "stored_estimate_invalid", { requestId });
        return reply(201, { requestId, estimate: stored ?? responseEstimate(estimate), duplicate: true });
      }
      log("info", "request_saved", { requestId });

      deps.waitUntil(
        sendNotifications(deps, { requestId, value, estimate, chef }).catch((error: unknown) => {
          log("error", "notify_crashed", { error: error instanceof Error ? error.name : "unknown" });
        }),
      );

      return reply(201, { requestId, estimate: responseEstimate(estimate) });
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
  const { value, estimate } = context;
  return {
    requestId: context.requestId,
    type: value.type,
    adults: value.adults,
    kids: value.kids,
    days: value.days,
    meals: value.meals,
    preferredDate: value.preferredDate,
    slot: value.slot,
    hasRestrictions: value.hasRestrictions,
    estimate: {
      portions: estimate.portions,
      cookMinutes: estimate.cookMinutes,
      serviceCents: estimate.serviceCents,
      groceriesEstCents: estimate.groceriesEstCents,
      totalCents: estimate.totalCents,
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
