// Tests de la Edge Function chef con dependencias simuladas (docs/contracts/chef-api.md).
// Correr con: npm test (node --test). La función real (index.ts) solo conecta Supabase, Deno, Resend y
// el SDK de Anthropic; la base simulada imita lo que importa de chef_create_booking, chef_move_session,
// chef_cancel_sessions, hit_public_request_rate y las funciones del envío del menú (chef_menu_send_context,
// chef_prepare_menu_send, chef_link_menu_send y chef_complete_menu_send; lo demás lo prueba
// supabase/tests/database/), el traductor simulado responde como claude_translator.ts (sus partes puras:
// translation.test.ts y menu_translation.test.ts) y el Mailer simulado, como Resend.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import type { TranslationSource } from "../_shared/chef_api.ts";
import { StoreError, type LogFields } from "../_shared/edge.ts";
import type { EmailMessage, SendOutcome } from "../_shared/resend.ts";
import {
  CHEF_CORS_METHODS,
  authFailureKind,
  bearerToken,
  bookingResponseFromRpc,
  cancelSessionsResponseFromRpc,
  chefConfigWarnings,
  chefIdFromRpc,
  createChefHandler,
  dbErrorReply,
  moveSessionResponseFromRpc,
  readChefConfig,
  routeOf,
  safeDbDetail,
  storeErrorFrom,
  type CancelSessionsParams,
  type ChefHandlerDeps,
  type ChefStore,
  type CompleteMenuSendParams,
  type CreateBookingParams,
  type CreateQuoteParams,
  type LinkMenuSendParams,
  type Mailer,
  type MenuSendContextParams,
  type MoveSessionParams,
  type PrepareMenuSendParams,
  type UpdateQuoteParams,
  type WithdrawQuoteParams,
} from "./handler.ts";
import type { MenuTextSource } from "./menu_translation.ts";
import { fakeTranslator, translateRateKey, type Translator, type TranslatorReply } from "./translation.ts";

const CHEF_ID = "cef00000-0000-4000-8000-000000000001";
const USER_EVELYN = "e0000000-0000-4000-8000-000000000001";
/** Un colaborador de Evelyn (chef_members): entra con la cocina de ella. */
const USER_MEMBER = "e0000000-0000-4000-8000-0000000000c1";
const USER_CLIENT = "c0000000-0000-4000-8000-000000000001";
const REQUEST_ID = "5e550000-0000-4000-8000-000000000001";
const CLIENT_ID = "5e550000-0000-4000-8000-000000000002";
const SESSION_ID = "5e550000-0000-4000-8000-000000000003";
const OTHER_SESSION_ID = "5e550000-0000-4000-8000-000000000004";
const REQUEST_KEY = "3f2b8c1e-9a4d-4c7b-8e2f-0123456789ab";
/** El presupuesto que crea la base simulada (§14). */
const QUOTE_ID = "5e550000-0000-4000-8000-0000000000a1";
// Lunes 16/11/2026, 11:00 en Roma.
const NOW = new Date("2026-11-16T10:00:00Z");
const BASE = "http://127.0.0.1:54321/functions/v1/chef";
const ORIGIN = "https://radicicucina.app";
const FOUR_MONDAYS = ["2026-11-23", "2026-11-30", "2026-12-07", "2026-12-14"];

const ENV: Record<string, string> = {
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_SECRET_KEYS: '{"default":"sb_secret_prueba"}',
  ALLOWED_ORIGINS: `${ORIGIN},http://localhost:8080`,
  // Las del email y el link del menú (§13), compartidas con public-request.
  RESEND_API_KEY: "re_prueba",
  MAIL_FROM: "Radici <ciao@radicicucina.app>",
  MAIL_REPLY_TO: "evelyn.reply@example.test",
  PUBLIC_SITE_URL: "https://radicicucina.app",
};

/** Un JWT con la forma de los de Supabase (la firma es falsa: lo valida la base simulada, como Auth). */
function jwt(subject: string): string {
  const part = (value: unknown): string => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "ES256", typ: "JWT" })}.${part({ sub: subject, role: "authenticated" })}.ZmlybWE`;
}
const TOKEN_EVELYN = jwt(USER_EVELYN);
const TOKEN_MEMBER = jwt(USER_MEMBER);
const TOKEN_CLIENT = jwt(USER_CLIENT);
const TOKEN_REJECTED = jwt("vencido");

/** Id de la n-ésima sesión creada por la base simulada. */
function sessionId(n: number): string {
  return `00000000-0000-4000-8000-${String(100 + n).padStart(12, "0")}`;
}

/** Como private.split_cents: los centavos que sobran, a las primeras partes. */
function split(total: number, parts: number): number[] {
  return Array.from({ length: parts }, (_, i) => Math.floor(total / parts) + (i < total % parts ? 1 : 0));
}

type Op =
  | "get_user"
  | "load_chef"
  | "create_booking"
  | "move_session"
  | "cancel_sessions"
  | "rate_limit"
  | "menu_send_context"
  | "prepare_menu_send"
  | "link_menu_send"
  | "complete_menu_send"
  | "create_quote"
  | "update_quote"
  | "withdraw_quote";

// El menú de una semana (§13), con textos fáciles de buscar en los logs.
const MENU_VERSION = 3;
const RECIPE_ID = "aaaa0000-0000-4000-8000-000000000001";
const PHOTO_ID = "bbbb0000-0000-4000-8000-000000000001";
const MENU_NOTE = "NOTA-MENU-qqq: tené listos 4 táperes.";
const LINK_CONTACT = { name: "Mariaxyz Bianchiqwe", email: "maria.pii@example.test", phone: "+393337654321" };
const SENT_AT = "2026-11-16T10:00:00.123456+00:00";
/** La huella de la foto (private.menu_send_fingerprint, md5): la de ahora y la de después de un cambio. */
const FINGERPRINT = "0123456789abcdef0123456789abcdef";
const MOVED_FINGERPRINT = "fedcba9876543210fedcba9876543210";

/** Id del n-ésimo envío preparado por la base simulada. */
function sendIdOf(n: number): string {
  return `5e550000-0000-4000-8000-${String(900 + n).padStart(12, "0")}`;
}

/**
 * Lo que devuelve chef_menu_send_context (la forma de la migración 20261121100000_menu_sends.sql), más
 * datos que la base nunca manda (dirección, restricciones) para comprobar que tampoco salen.
 */
function menuContextRpc(overrides: Record<string, unknown> = {}, menu: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    session: { id: SESSION_ID, date: "2026-11-30", start: "10:00", status: "confirmed", requestId: REQUEST_ID, week: 1, weeks: 2 },
    weeks: [
      { sessionId: SESSION_ID, date: "2026-11-30", start: "10:00" },
      { sessionId: OTHER_SESSION_ID, date: "2026-12-07", start: "10:00" },
    ],
    request: { id: REQUEST_ID, type: "week", locale: "it", adults: 2, kids: 0, days: 5, meals: ["dinner"], restrictions: "NOTA-SALUD-zzz" },
    contact: { name: "Mariaxyz Bianchiqwe", email: "maria.pii@example.test", phone: "+39 333 765 4321", address: "Via Segretissima 42" },
    chef: { displayName: "Evelyn" },
    menu: {
      version: MENU_VERSION,
      note: MENU_NOTE,
      allergensConfirmed: true,
      dishes: [
        {
          recipeId: RECIPE_ID,
          portions: 6,
          nameIt: "Milanesaxyz alla napoletana",
          nameEs: "Milanesaxyz a la napolitana",
          nameEn: null,
          descriptionIt: "Con DescripQwe pomodoro.",
          descriptionEs: null,
          descriptionEn: null,
          diet: null,
          photoId: PHOTO_ID,
          allergens: ["gluten", "milk"],
        },
      ],
      items: [
        { name: "Zapallitoszzz", section: "produce", quantity: 1250, unit: "g" },
        { name: "sal", section: "pantry", quantity: null, unit: null },
        { name: "Zapallitoszzz", section: "produce", quantity: 250, unit: "g" },
      ],
      ...menu,
    },
    lastSend: null,
    fingerprint: FINGERPRINT,
    ...overrides,
  };
}

interface FakeSession {
  id: string;
  requestId: string;
  date: string;
  start: string;
  cookMinutes: number;
  serviceCents: number;
}

/**
 * Base y Auth simuladas. Un reintento (la misma requestKey a mano, o el mismo pedido) devuelve la
 * reserva guardada con duplicate = true y no escribe nada; un dryRun nunca escribe.
 */
class FakeStore implements ChefStore {
  users = new Map<string, string>([
    [TOKEN_EVELYN, USER_EVELYN],
    [TOKEN_MEMBER, USER_MEMBER],
    [TOKEN_CLIENT, USER_CLIENT],
  ]);
  /** Lo que devuelve public.chef_id_for_user por usuario: la cocina de la dueña y la de su colaborador. */
  chefs = new Map<string, unknown>([
    [USER_EVELYN, CHEF_ID],
    [USER_MEMBER, CHEF_ID],
  ]);
  failures = new Map<Op, unknown>();
  tokens: string[] = [];
  chefLookups: string[] = [];
  bookingCalls: CreateBookingParams[] = [];
  moveCalls: MoveSessionParams[] = [];
  cancelCalls: CancelSessionsParams[] = [];
  sessions: FakeSession[] = [];
  /** Escrituras de verdad: sesiones creadas, movidas o canceladas. */
  writes = 0;
  /** Estado de cada fecha en los chequeos (por defecto ok). */
  dayStatus = new Map<string, string>();
  /** Reserva guardada por clave de reintento: la requestKey (a mano) o el pedido. */
  bookings = new Map<string, string>();
  /** Respuesta cruda que reemplaza a la simulada (para probar formas inesperadas). */
  raw: unknown = undefined;
  /** Intentos registrados en hit_public_request_rate (la clave y los topes). */
  rateHits: Array<{ key: string; maxPerHour: number; maxPerDay: number }> = [];
  /** Lo que contesta hit_public_request_rate: dentro del límite o no. */
  rateAllowed = true;
  /** Lo que devuelve chef_menu_send_context. */
  menuContext: unknown = menuContextRpc();
  contextCalls: MenuSendContextParams[] = [];
  prepareCalls: PrepareMenuSendParams[] = [];
  linkCalls: LinkMenuSendParams[] = [];
  completeCalls: CompleteMenuSendParams[] = [];
  /** Los envíos preparados: la foto (como la guarda la base, en JSON), el idioma, su huella y si ya salió. */
  sends = new Map<string, { snapshot: unknown; locale: string; fingerprint: string; sent: boolean }>();
  /**
   * La huella de ahora (private.menu_send_fingerprint). Cambiarla simula que se movió la sesión, se
   * canceló otra semana o cambió un plato: prepare, link y complete dan menu_changed.
   */
  fingerprint = FINGERPRINT;
  /** El contacto de ahora que devuelve chef_link_menu_send. */
  linkContact: unknown = { ...LINK_CONTACT };
  /** Cuántas veces chef_link_menu_send responde 23505 (token repetido) antes de crear el link. */
  linkCollisions = 0;
  /** Respuestas crudas que reemplazan a las simuladas del envío. */
  prepareRaw: unknown = undefined;
  linkRaw: unknown = undefined;
  completeRaw: unknown = undefined;
  /** El presupuesto (§14): llamadas, presupuestos creados (id → sesiones y si se retiró) y respuestas crudas. */
  createQuoteCalls: CreateQuoteParams[] = [];
  updateQuoteCalls: UpdateQuoteParams[] = [];
  withdrawQuoteCalls: WithdrawQuoteParams[] = [];
  quotes = new Map<string, { requestId: string; sessions: FakeSession[]; withdrawn: boolean }>();
  quoteRaw: unknown = undefined;

  private fail(op: Op): void {
    if (this.failures.has(op)) throw this.failures.get(op);
  }

  async userIdFromToken(token: string): Promise<string | null> {
    this.tokens.push(token);
    this.fail("get_user");
    return this.users.get(token) ?? null;
  }

  async chefIdForUser(userId: string): Promise<unknown> {
    this.chefLookups.push(userId);
    this.fail("load_chef");
    return this.chefs.has(userId) ? this.chefs.get(userId) : null;
  }

  async createBooking(params: CreateBookingParams): Promise<unknown> {
    this.bookingCalls.push(params);
    this.fail("create_booking");
    if (this.raw !== undefined) return this.raw;
    const parts = split(params.p_service_total_cents, params.p_dates.length);
    if (params.p_dry_run) {
      return {
        dry_run: true,
        duplicate: false,
        request_id: params.p_request_id,
        client_id: params.p_client_id,
        weeks: params.p_dates.map((date, i) => ({
          date,
          start_time: `${params.p_start ?? "10:00"}:00`,
          cook_minutes: params.p_cook_minutes,
          status: this.dayStatus.get(date) ?? "ok",
          suggested_start: "10:00:00",
          service_cents: parts[i],
          session_id: null,
        })),
      };
    }
    const key = params.p_request_id ?? `key:${params.p_request_key}`;
    const saved = this.bookings.get(key);
    if (saved) return this.result(saved, true);
    const requestId = params.p_request_id ?? `00000000-0000-4000-8000-${String(200 + this.bookings.size).padStart(12, "0")}`;
    params.p_dates.forEach((date, i) => {
      this.sessions.push({
        id: sessionId(this.sessions.length),
        requestId,
        date,
        start: `${params.p_start}:00`,
        cookMinutes: params.p_cook_minutes,
        serviceCents: parts[i] ?? 0,
      });
      this.writes++;
    });
    this.bookings.set(key, requestId);
    return this.result(requestId, false);
  }

  private result(requestId: string, duplicate: boolean): unknown {
    return {
      dry_run: false,
      duplicate,
      request_id: requestId,
      client_id: CLIENT_ID,
      weeks: this.sessions
        .filter((session) => session.requestId === requestId)
        .map((session) => ({
          date: session.date,
          start_time: session.start,
          cook_minutes: session.cookMinutes,
          status: "ok",
          suggested_start: "10:00:00",
          service_cents: session.serviceCents,
          session_id: session.id,
        })),
    };
  }

  async moveSession(params: MoveSessionParams): Promise<unknown> {
    this.moveCalls.push(params);
    this.fail("move_session");
    if (this.raw !== undefined) return this.raw;
    if (!params.p_dry_run) this.writes++;
    return {
      dry_run: params.p_dry_run,
      session_id: params.p_session_id,
      request_id: REQUEST_ID,
      date: params.p_date,
      start_time: `${params.p_start ?? "10:00"}:00`,
      cook_minutes: params.p_cook_minutes ?? 240,
      status: this.dayStatus.get(params.p_date) ?? "ok",
      suggested_start: "10:00:00",
      week_taken: false,
    };
  }

  async hitRateLimit(key: string, maxPerHour: number, maxPerDay: number): Promise<boolean> {
    this.fail("rate_limit");
    this.rateHits.push({ key, maxPerHour, maxPerDay });
    return this.rateAllowed;
  }

  async cancelSessions(params: CancelSessionsParams): Promise<unknown> {
    this.cancelCalls.push(params);
    this.fail("cancel_sessions");
    if (this.raw !== undefined) return this.raw;
    this.writes += params.p_session_ids.length;
    return { cancelled: params.p_session_ids, already_cancelled: [], with_payments: [], had_payments: false };
  }

  async menuSendContext(params: MenuSendContextParams): Promise<unknown> {
    this.contextCalls.push(params);
    this.fail("menu_send_context");
    return this.menuContext;
  }

  private menuChanged(op: Op): StoreError {
    return storeErrorFrom(op, { code: "40001", message: "menu_changed" });
  }

  async prepareMenuSend(params: PrepareMenuSendParams): Promise<unknown> {
    this.prepareCalls.push(params);
    this.fail("prepare_menu_send");
    if (this.prepareRaw !== undefined) return this.prepareRaw;
    if (params.p_fingerprint !== this.fingerprint) throw this.menuChanged("prepare_menu_send");
    const sendId = sendIdOf(this.sends.size);
    this.sends.set(sendId, {
      snapshot: JSON.parse(JSON.stringify(params.p_snapshot)),
      locale: params.p_locale,
      fingerprint: params.p_fingerprint,
      sent: false,
    });
    return { sendId };
  }

  async linkMenuSend(params: LinkMenuSendParams): Promise<unknown> {
    this.linkCalls.push(params);
    if (this.linkCollisions > 0) {
      this.linkCollisions--;
      throw storeErrorFrom("link_menu_send", {
        code: "23505",
        message: 'duplicate key value violates unique constraint "client_links_pkey"',
        details: `Key (token_hash)=(${params.p_token_hash}) already exists.`,
      });
    }
    this.fail("link_menu_send");
    if (this.linkRaw !== undefined) return this.linkRaw;
    const send = this.sends.get(params.p_send_id);
    if (!send) throw storeErrorFrom("link_menu_send", { code: "P0002", message: "send_not_found" });
    if (send.sent) throw storeErrorFrom("link_menu_send", { code: "55000", message: "already_sent" });
    if (send.fingerprint !== this.fingerprint) throw this.menuChanged("link_menu_send");
    return {
      sendId: params.p_send_id,
      sessionId: SESSION_ID,
      requestId: REQUEST_ID,
      locale: send.locale,
      snapshot: send.snapshot,
      contact: this.linkContact,
      chefName: "Evelyn",
    };
  }

  async completeMenuSend(params: CompleteMenuSendParams): Promise<unknown> {
    this.completeCalls.push(params);
    this.fail("complete_menu_send");
    if (this.completeRaw !== undefined) return this.completeRaw;
    const send = this.sends.get(params.p_send_id);
    if (send && send.fingerprint !== this.fingerprint) throw this.menuChanged("complete_menu_send");
    if (send) send.sent = true;
    return { sendId: params.p_send_id, sentAt: SENT_AT, sentVia: [...params.p_via].sort() };
  }

  /** Como chef_create_quote: el dryRun con el estado de cada fecha; creado, una sesión held por semana. */
  async createQuote(params: CreateQuoteParams): Promise<unknown> {
    this.createQuoteCalls.push(params);
    this.fail("create_quote");
    if (this.quoteRaw !== undefined) return this.quoteRaw;
    const parts = split(params.p_service_total_cents, params.p_dates.length);
    if (params.p_dry_run) {
      return {
        dry_run: true,
        quote_id: null,
        request_id: params.p_request_id,
        client_id: CLIENT_ID,
        hold_until: null,
        weeks: params.p_dates.map((date, i) => ({
          date,
          start_time: params.p_start === null ? "09:00:00" : `${params.p_start}:00`,
          cook_minutes: params.p_cook_minutes,
          status: this.dayStatus.get(date) ?? "ok",
          suggested_start: "09:00:00",
          service_cents: parts[i],
          session_id: null,
        })),
      };
    }
    const quoteId = QUOTE_ID;
    const sessions = params.p_dates.map((date, i) => {
      const session: FakeSession = {
        id: sessionId(this.sessions.length),
        requestId: params.p_request_id,
        date,
        start: params.p_start ?? "",
        cookMinutes: params.p_cook_minutes,
        serviceCents: parts[i] ?? 0,
      };
      this.sessions.push(session);
      this.writes++;
      return session;
    });
    this.quotes.set(quoteId, { requestId: params.p_request_id, sessions, withdrawn: false });
    return {
      dry_run: false,
      quote_id: quoteId,
      request_id: params.p_request_id,
      client_id: CLIENT_ID,
      hold_until: "2026-11-17T10:00:00.123456+00:00",
      weeks: sessions.map((session) => ({
        date: session.date,
        start_time: session.start,
        cook_minutes: session.cookMinutes,
        status: "free",
        suggested_start: null,
        service_cents: session.serviceCents,
        session_id: session.id,
      })),
    };
  }

  /** Como chef_update_quote: el precio nuevo, repartido; devuelve private.quote_terms. */
  async updateQuote(params: UpdateQuoteParams): Promise<unknown> {
    this.updateQuoteCalls.push(params);
    this.fail("update_quote");
    if (this.quoteRaw !== undefined) return this.quoteRaw;
    const quote = this.quotes.get(params.p_quote_id);
    if (!quote) throw storeErrorFrom("update_quote", { code: "P0002", message: "quote_not_found" });
    const parts = split(params.p_service_total_cents, quote.sessions.length);
    quote.sessions.forEach((session, i) => {
      session.serviceCents = parts[i] ?? 0;
    });
    this.writes++;
    return {
      quoteId: params.p_quote_id,
      totalCents: params.p_service_total_cents,
      weeks: quote.sessions.map((session) => ({
        sessionId: session.id,
        date: session.date,
        start: session.start,
        cookMinutes: session.cookMinutes,
        serviceCents: session.serviceCents,
      })),
    };
  }

  /** Como chef_withdraw_quote: idempotente (already). */
  async withdrawQuote(params: WithdrawQuoteParams): Promise<unknown> {
    this.withdrawQuoteCalls.push(params);
    this.fail("withdraw_quote");
    if (this.quoteRaw !== undefined) return this.quoteRaw;
    const quote = this.quotes.get(params.p_quote_id);
    if (!quote) throw storeErrorFrom("withdraw_quote", { code: "P0002", message: "quote_not_found" });
    const already = quote.withdrawn;
    quote.withdrawn = true;
    if (!already) this.writes++;
    return { quote_id: params.p_quote_id, request_id: quote.requestId, already, cancelled: already ? 0 : quote.sessions.length };
  }
}

/** El Mailer simulado: guarda los emails y responde como Resend (`outcome`); `throws` lo hace explotar. */
class FakeMailer implements Mailer {
  messages: EmailMessage[] = [];
  outcome: SendOutcome = { ok: true, id: "re_123" };
  throws: unknown = undefined;
  /** Se llama mientras «manda» (para simular algo que cambia en la base en ese momento). */
  during: () => void = () => {};

  async send(message: EmailMessage): Promise<SendOutcome> {
    this.messages.push(message);
    this.during();
    if (this.throws !== undefined) throw this.throws;
    return this.outcome;
  }
}

/**
 * El traductor simulado: por defecto, el de mentira de TRANSLATE_TRANSPORT=fake (la misma forma que la
 * salida de Claude). `reply` reemplaza la respuesta; `throws`, la hace explotar.
 */
class FakeTranslator implements Translator {
  calls: TranslationSource[] = [];
  reply: TranslatorReply | null = null;
  throws: unknown = undefined;
  /** Los nombres de la lista de un menú: lo que recibió y lo que contesta (por defecto, el de mentira). */
  menuCalls: MenuTextSource[] = [];
  menuReply: TranslatorReply | null = null;
  /** Se llama mientras «traduce» (para simular el tiempo que tarda). */
  during: () => void = () => {};

  async translate(source: TranslationSource): Promise<TranslatorReply> {
    this.calls.push(source);
    this.during();
    if (this.throws !== undefined) throw this.throws;
    return this.reply ?? (await fakeTranslator.translate(source));
  }

  async translateMenu(source: MenuTextSource): Promise<TranslatorReply> {
    this.menuCalls.push(source);
    this.during();
    if (this.throws !== undefined) throw this.throws;
    return this.menuReply ?? (await fakeTranslator.translateMenu(source));
  }
}

interface Harness {
  handle: (request: Request) => Promise<Response>;
  store: FakeStore;
  translator: FakeTranslator;
  mailer: FakeMailer;
  logs: Array<{ level: string; event: string; fields: LogFields }>;
}

function harness(options: { env?: Record<string, string | undefined>; now?: () => Date; translator?: null; mailer?: null } = {}): Harness {
  const env: Record<string, string | undefined> = { ...ENV, ...options.env };
  const store = new FakeStore();
  const translator = new FakeTranslator();
  const mailer = new FakeMailer();
  const logs: Harness["logs"] = [];
  const deps: ChefHandlerDeps = {
    config: readChefConfig((name) => env[name]),
    store,
    translator: options.translator === null ? null : translator,
    mailer: options.mailer === null ? null : mailer,
    now: options.now ?? (() => NOW),
    log: (level, event, fields = {}) => {
      logs.push({ level, event, fields });
    },
  };
  return { handle: createChefHandler(deps), store, translator, mailer, logs };
}

interface PostOptions {
  /** Token de Authorization (por defecto el de Evelyn; null = sin cabecera). */
  token?: string | null;
  headers?: Record<string, string>;
  raw?: string | Uint8Array;
  url?: string;
}

function post(route: string, body: unknown, options: PostOptions = {}): Request {
  const token = options.token === undefined ? TOKEN_EVELYN : options.token;
  return new Request(options.url ?? `${BASE}${route}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin: ORIGIN,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...options.headers,
    },
    body: options.raw ?? JSON.stringify(body),
  });
}

// deno-lint-ignore no-explicit-any
async function json(response: Response): Promise<any> {
  return JSON.parse(await response.text());
}

/** Confirmar un pedido de la bandeja: 4 semanas, 560 € de servicio. */
function bookingBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    requestId: REQUEST_ID,
    dates: FOUR_MONDAYS,
    start: "10:00",
    cookMinutes: 240,
    portions: 50,
    serviceTotalCents: 56000,
    ...overrides,
  };
}

// Reserva a mano con datos personales fáciles de buscar en los logs, y campos que la función no usa
// (notas, alergias) para comprobar que tampoco salen.
function manualBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    newClient: {
      name: "Mariaxyz Bianchiqwe",
      phone: "+39 333 765 4321",
      email: "maria.pii@example.test",
      zone: "ZonaPrivadaKkk",
      address: "Via Segretissima 42",
    },
    type: "week",
    household: { adults: 2, kids: 2, days: 5, meals: ["dinner"] },
    locale: "it",
    dates: ["2026-11-23", "2026-11-30"],
    start: "10:00",
    cookMinutes: 240,
    serviceTotalCents: 28000,
    requestKey: REQUEST_KEY,
    notes: "NOTA-LIBRE-yyy",
    restrictions: "NOTA-SALUD-zzz",
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// HTTP: CORS, rutas, método, tipo y tamaño
// ---------------------------------------------------------------------------

test("OPTIONS: CORS solo para los orígenes de ALLOWED_ORIGINS, con POST y las cabeceras de supabase-js", async () => {
  const { handle, store } = harness();
  const allowed = await handle(new Request(`${BASE}/bookings`, { method: "OPTIONS", headers: { origin: ORIGIN } }));
  assert.equal(allowed.status, 204);
  assert.equal(allowed.headers.get("access-control-allow-origin"), ORIGIN);
  assert.equal(allowed.headers.get("access-control-allow-methods"), "POST, OPTIONS");
  assert.equal(CHEF_CORS_METHODS, "POST, OPTIONS");
  const allowHeaders = (allowed.headers.get("access-control-allow-headers") ?? "").split(", ");
  for (const name of ["authorization", "apikey", "content-type", "x-client-info"]) {
    assert.ok(allowHeaders.includes(name), `falta ${name}`);
  }
  // Un origen que no está en la lista (por ejemplo, el dominio viejo) no recibe CORS.
  const other = await handle(new Request(`${BASE}/bookings`, { method: "OPTIONS", headers: { origin: "https://radici.sepusola10.com" } }));
  assert.equal(other.status, 204);
  assert.equal(other.headers.get("access-control-allow-origin"), null);
  assert.equal(store.tokens.length, 0, "el preflight no autentica");
});

test("ruta desconocida: 404 sin autenticar; las rutas valen con o sin /functions/v1 delante", async () => {
  const { handle, store } = harness();
  for (const route of ["", "/", "/bookings/x", "/sessions", "/payments", "/BOOKINGS"]) {
    const response = await handle(post(route, bookingBody()));
    assert.equal(response.status, 404, route);
    assert.deepEqual(await json(response), { error: "notFound" });
  }
  assert.equal(store.tokens.length, 0);

  // En la plataforma la función recibe /chef/<ruta>; con la barra final también vale.
  const direct = await handle(post("", bookingBody(), { url: "http://localhost/chef/bookings" }));
  assert.equal(direct.status, 201);
  const slash = await handle(post("", bookingBody({ requestId: CLIENT_ID }), { url: `${BASE}/bookings/` }));
  assert.equal(slash.status, 201);
});

test("método distinto de POST: 405 con Allow y CORS (la app lee el error)", async () => {
  const { handle } = harness();
  for (const method of ["GET", "PUT", "DELETE"]) {
    const response = await handle(new Request(`${BASE}/bookings`, { method, headers: { origin: ORIGIN, authorization: `Bearer ${TOKEN_EVELYN}` } }));
    assert.equal(response.status, 405, method);
    assert.deepEqual(await json(response), { error: "method" });
    assert.equal(response.headers.get("allow"), "POST, OPTIONS");
    assert.equal(response.headers.get("access-control-allow-origin"), ORIGIN);
  }
});

test("Content-Type que no es JSON: 415; cuerpo de más de 8 KB: 413; JSON roto o UTF-8 inválido: 400", async () => {
  const { handle, store } = harness();
  for (const type of ["text/plain", "application/x-www-form-urlencoded", ""]) {
    const response = await handle(post("/bookings", bookingBody(), { headers: { "content-type": type } }));
    assert.equal(response.status, 415, type);
    assert.deepEqual(await json(response), { error: "contentType" });
  }
  const declared = await handle(post("/bookings", bookingBody(), { headers: { "content-length": "9000" } }));
  assert.equal(declared.status, 413);
  assert.deepEqual(await json(declared), { error: "tooLarge" });
  const streamed = await handle(post("/bookings", null, { raw: JSON.stringify({ ...bookingBody(), relleno: "x".repeat(9000) }) }));
  assert.equal(streamed.status, 413);
  for (const raw of ["{no es json", "", "[1,2"]) {
    const response = await handle(post("/bookings", null, { raw }));
    assert.equal(response.status, 400);
    assert.deepEqual(await json(response), { errors: { payload: "invalid" } });
  }
  const invalidUtf8 = await handle(post("/bookings", null, { raw: new Uint8Array([0x7b, 0xff, 0xfe, 0x7d]) }));
  assert.equal(invalidUtf8.status, 400);
  assert.equal(store.bookingCalls.length, 0);
});

// ---------------------------------------------------------------------------
// Autenticación: 401, 403, configuración
// ---------------------------------------------------------------------------

test("sin token válido no se lee el cuerpo: 401 antes que el tipo (415), el tamaño (413) y el JSON (400)", async () => {
  const { handle, store } = harness();
  const big = JSON.stringify({ ...bookingBody(), relleno: "x".repeat(9000) });
  const cases: Array<[string, Request]> = [
    ["text/plain", post("/bookings", bookingBody(), { token: null, headers: { "content-type": "text/plain" } })],
    // La plataforma (verify_jwt) deja pasar las claves de API: es lo que de verdad llega sin JWT.
    ["clave de API y text/plain", post("/bookings", bookingBody(), { token: null, headers: { authorization: "Bearer sb_publishable_abc123", "content-type": "text/plain" } })],
    ["Content-Length 9000", post("/bookings", bookingBody(), { token: null, headers: { "content-length": "9000" } })],
    ["más de 8 KB sin Content-Length", post("/bookings", null, { token: null, raw: big })],
    ["clave de API y más de 8 KB", post("/bookings", null, { token: null, raw: big, headers: { authorization: "Bearer sb_publishable_abc123" } })],
    ["JSON roto", post("/bookings", null, { token: null, raw: "{no es json" })],
  ];
  for (const [name, request] of cases) {
    const response = await handle(request);
    assert.equal(response.status, 401, name);
    assert.deepEqual(await json(response), { error: "unauthorized" }, name);
    assert.equal(request.bodyUsed, false, `${name}: el cuerpo no se leyó`);
  }
  assert.deepEqual(store.tokens, [], "ninguno llega a Auth");
  assert.equal(store.bookingCalls.length, 0);
});

test("401 sin token, con otro esquema, con algo que no es un JWT o con un token que Auth rechaza", async () => {
  const { handle, store, logs } = harness();
  const cases: Array<[Record<string, string>, string]> = [
    [{}, "missing"],
    [{ authorization: "Basic ZXZlbHluOnB3" }, "malformed"],
    [{ authorization: "Bearer no-es-un-jwt" }, "malformed"],
    // El chequeo de la plataforma (verify_jwt) deja pasar las claves de API: la función no.
    [{ authorization: "Bearer sb_publishable_abc123" }, "malformed"],
    [{ authorization: `Bearer ${TOKEN_REJECTED}` }, "invalid"],
  ];
  for (const [headers, reason] of cases) {
    const response = await handle(post("/bookings", bookingBody(), { token: null, headers }));
    assert.equal(response.status, 401, reason);
    assert.deepEqual(await json(response), { error: "unauthorized" });
    assert.equal(response.headers.get("www-authenticate"), "Bearer");
    assert.equal(response.headers.get("access-control-allow-origin"), ORIGIN);
    assert.ok(logs.some((entry) => entry.event === "auth_rejected" && entry.fields["reason"] === reason && entry.fields["route"] === "/bookings"), reason);
  }
  assert.deepEqual(store.tokens, [TOKEN_REJECTED], "solo un JWT llega a Auth");
  assert.equal(store.bookingCalls.length, 0);

  // Primero la autenticación: un cuerpo inválido sin token también es 401.
  const invalid = await handle(post("/bookings", { dates: [] }, { token: null }));
  assert.equal(invalid.status, 401);
});

test("403 para un usuario válido que no es la cocinera, en todas las rutas, sin tocar las sesiones ni traducir", async () => {
  const { handle, store, translator, logs } = harness();
  const routes: Array<[string, unknown]> = [
    ["/bookings", bookingBody()],
    ["/sessions/move", { sessionId: SESSION_ID, date: "2026-11-25" }],
    ["/sessions/cancel", { sessionIds: [SESSION_ID] }],
    ["/translate", { name: "Locro" }],
    ["/menus/preview", { sessionId: SESSION_ID, menuVersion: MENU_VERSION }],
    ["/menus/send", { sendId: sendIdOf(0), email: true }],
    ["/quotes", { requestId: REQUEST_ID, dates: FOUR_MONDAYS, start: "10:00", cookMinutes: 240, serviceTotalCents: 56000 }],
    ["/quotes/price", { quoteId: QUOTE_ID, serviceTotalCents: 1 }],
    ["/quotes/withdraw", { quoteId: QUOTE_ID }],
  ];
  for (const [route, body] of routes) {
    const response = await handle(post(route, body, { token: TOKEN_CLIENT }));
    assert.equal(response.status, 403, route);
    assert.deepEqual(await json(response), { error: "forbidden" });
    assert.ok(logs.some((entry) => entry.event === "forbidden" && entry.fields["route"] === route && entry.fields["userId"] === USER_CLIENT));
  }
  assert.deepEqual(store.chefLookups, Array(routes.length).fill(USER_CLIENT), "la cocinera se busca por el usuario del token");
  assert.equal(store.bookingCalls.length + store.moveCalls.length + store.cancelCalls.length, 0);
  assert.equal(translator.calls.length + translator.menuCalls.length + store.rateHits.length, 0, "ni traduce ni gasta el cupo de la cocina");
  assert.equal(store.contextCalls.length + store.prepareCalls.length + store.linkCalls.length + store.completeCalls.length, 0, "ni toca los envíos");
  assert.equal(store.createQuoteCalls.length + store.updateQuoteCalls.length + store.withdrawQuoteCalls.length, 0, "ni toca los presupuestos");
});

test("un colaborador de la cocinera entra con la cocina de la que es colaborador, en todas las rutas", async () => {
  const { handle, store, logs } = harness();
  const booking = await handle(post("/bookings", bookingBody(), { token: TOKEN_MEMBER }));
  assert.equal(booking.status, 201);
  const move = await handle(post("/sessions/move", { sessionId: SESSION_ID, date: "2026-11-25" }, { token: TOKEN_MEMBER }));
  assert.equal(move.status, 200);
  const cancel = await handle(post("/sessions/cancel", { sessionIds: [SESSION_ID] }, { token: TOKEN_MEMBER }));
  assert.equal(cancel.status, 200);
  const translate = await handle(post("/translate", { name: "Locro" }, { token: TOKEN_MEMBER }));
  assert.equal(translate.status, 200);

  assert.deepEqual(store.chefLookups, [USER_MEMBER, USER_MEMBER, USER_MEMBER, USER_MEMBER], "la cocina sale de su propio usuario");
  assert.equal(store.rateHits[0]?.key, await translateRateKey(CHEF_ID), "y traduce con el cupo de la cocina de ella");
  assert.deepEqual(
    [store.bookingCalls[0]?.p_chef_id, store.moveCalls[0]?.p_chef_id, store.cancelCalls[0]?.p_chef_id],
    [CHEF_ID, CHEF_ID, CHEF_ID],
    "las funciones SQL reciben la cocina de la cocinera, la misma que con el token de ella",
  );
  assert.ok(!logs.some((entry) => entry.event === "forbidden"));
  // Con varias cuentas en la cocina, el log de lo que cambia dice quién lo hizo (un id, como el del 403).
  for (const event of ["booking_created", "session_moved", "sessions_cancelled", "translated"]) {
    assert.equal(logs.find((entry) => entry.event === event)?.fields["userId"], USER_MEMBER, event);
  }
});

test("los logs de lo que cambia llevan el usuario de quien llama: con el token de la cocinera, el de ella", async () => {
  const { handle, logs } = harness();
  assert.equal((await handle(post("/bookings", manualBody()))).status, 201);
  assert.equal((await handle(post("/bookings", manualBody()))).status, 201, "el reintento con la misma clave");
  for (const event of ["booking_created", "booking_duplicate"]) {
    assert.equal(logs.find((entry) => entry.event === event)?.fields["userId"], USER_EVELYN, event);
  }
});

test("la cocina del usuario con otra forma (ni un uuid ni null): 500 unexpected_result, sin leer el cuerpo ni tocar nada", async () => {
  // Por ejemplo, la forma de antes ({ id }, la fila de chefs) o la función SQL cambiada por otra cosa.
  for (const raw of [{ id: CHEF_ID }, "no-es-un-uuid", CHEF_ID.toUpperCase(), 42, [CHEF_ID], undefined]) {
    const { handle, store, logs } = harness();
    store.chefs.set(USER_EVELYN, raw);
    const request = post("/bookings", bookingBody());
    const response = await handle(request);
    assert.equal(response.status, 500, JSON.stringify(raw));
    assert.deepEqual(await json(response), { error: "server" });
    assert.equal(request.bodyUsed, false, "el cuerpo no se leyó");
    assert.equal(store.bookingCalls.length, 0);
    assert.ok(logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "load_chef"));
    assert.ok(!logs.some((entry) => entry.event === "forbidden"), "no es un 403: la base respondió algo que no se entiende");
  }
});

test("Auth o la base caídas al autenticar: 503; un error de permisos: 500; sin detalles", async () => {
  const auth = harness();
  auth.store.failures.set("get_user", new StoreError("get_user", "503", null));
  const authDown = await auth.handle(post("/bookings", bookingBody()));
  assert.equal(authDown.status, 503);
  assert.deepEqual(await json(authDown), { error: "unavailable" });
  assert.ok(auth.logs.some((entry) => entry.event === "db_error" && entry.fields["op"] === "get_user" && entry.fields["code"] === "503"));

  const network = harness();
  network.store.failures.set("load_chef", storeErrorFrom("load_chef", { code: "", message: "TypeError: fetch failed" }));
  assert.equal((await network.handle(post("/bookings", bookingBody()))).status, 503);

  const denied = harness();
  denied.store.failures.set("load_chef", storeErrorFrom("load_chef", { code: "42501", message: "permission denied for table chefs" }));
  const response = await denied.handle(post("/bookings", bookingBody()));
  assert.equal(response.status, 500);
  assert.deepEqual(await json(response), { error: "server" });
  assert.equal(denied.store.bookingCalls.length, 0);
});

test("sin SUPABASE_URL o sin la clave secreta: 500 antes de autenticar, y el log dice qué falta", async () => {
  for (const [env, missing] of [
    [{ SUPABASE_URL: undefined }, ["SUPABASE_URL"]],
    [{ SUPABASE_SECRET_KEYS: undefined }, ["SUPABASE_SECRET_KEYS"]],
  ] as const) {
    const { handle, store, logs } = harness({ env });
    const response = await handle(post("/bookings", bookingBody()));
    assert.equal(response.status, 500);
    assert.deepEqual(await json(response), { error: "server" });
    assert.equal(store.tokens.length, 0);
    assert.ok(logs.some((entry) => entry.event === "config_missing" && JSON.stringify(entry.fields["missing"]) === JSON.stringify(missing)));
  }
});

// ---------------------------------------------------------------------------
// POST /bookings
// ---------------------------------------------------------------------------

test("400 por campo: 0 o 9 semanas, centavos no enteros, sin precio y fechas en la misma semana o desordenadas, sin llamar a la base", async () => {
  const { handle, store, logs } = harness();
  const nine = ["2026-11-23", "2026-11-30", "2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04", "2027-01-11", "2027-01-18"];
  const cases: Array<[Record<string, unknown>, unknown]> = [
    [{ dates: [] }, { errors: { dates: "range" } }],
    [{ dates: nine }, { errors: { dates: "range" } }],
    [{ serviceTotalCents: 560.5 }, { errors: { serviceTotalCents: "invalid" } }],
    [{ serviceTotalCents: undefined }, { errors: { serviceTotalCents: "required" } }],
    [{ dates: ["2026-11-23", "2026-11-27"] }, { errors: { dates: "sameWeek" }, date: "2026-11-27" }],
    [{ dates: ["2026-11-30", "2026-11-23"] }, { errors: { dates: "order" }, date: "2026-11-23" }],
  ];
  for (const [overrides, expected] of cases) {
    const response = await handle(post("/bookings", bookingBody(overrides)));
    assert.equal(response.status, 400, JSON.stringify(overrides));
    assert.deepEqual(await json(response), expected);
  }
  assert.equal(store.bookingCalls.length, 0);
  assert.ok(logs.some((entry) => entry.event === "invalid_payload" && JSON.stringify(entry.fields["fields"]) === '["dates"]'));
});

test("confirmar un pedido: 201 con las 4 semanas; la base recibe todo en snake_case y la cocinera del token", async () => {
  const { handle, store, logs } = harness();
  const response = await handle(post("/bookings", bookingBody({ requestKey: REQUEST_KEY.toUpperCase(), household: { adults: 9 }, locale: "en" })));
  assert.equal(response.status, 201);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("access-control-allow-origin"), ORIGIN);
  assert.deepEqual(store.bookingCalls, [
    {
      p_chef_id: CHEF_ID,
      p_dates: FOUR_MONDAYS,
      p_start: "10:00",
      p_cook_minutes: 240,
      p_portions: 50,
      p_groceries_est_cents: 0,
      p_service_total_cents: 56000,
      p_request_id: REQUEST_ID,
      p_client_id: null,
      p_new_client: null,
      p_type: null,
      // Desde un pedido el hogar y el idioma son los del pedido: no viajan.
      p_household: null,
      p_locale: null,
      p_request_key: REQUEST_KEY,
      p_dry_run: false,
    },
  ]);
  assert.deepEqual(await json(response), {
    dryRun: false,
    duplicate: false,
    requestId: REQUEST_ID,
    clientId: CLIENT_ID,
    weeks: FOUR_MONDAYS.map((date, i) => ({
      date,
      start: "10:00",
      cookMinutes: 240,
      status: "ok",
      suggestedStart: "10:00",
      serviceCents: 14000,
      sessionId: sessionId(i),
    })),
  });
  assert.ok(logs.some((entry) => entry.event === "booking_created" && entry.fields["requestId"] === REQUEST_ID && entry.fields["sessions"] === 4 && entry.fields["client"] === "request"));
});

test("groceriesEstCents (la app de antes del 19/11/2026 lo manda): se ignora con cualquier valor y la base recibe 0", async () => {
  const { handle, store } = harness();
  for (const groceriesEstCents of [7550, 75.5, "7550", -1]) {
    const response = await handle(post("/bookings", bookingBody({ groceriesEstCents })));
    assert.equal(response.status, 201, String(groceriesEstCents));
  }
  assert.equal(store.bookingCalls.length, 4);
  for (const call of store.bookingCalls) assert.equal(call.p_groceries_est_cents, 0, "la compra la hace el cliente");
});

test("la cocinera sale siempre del token: un chefId o p_chef_id en el cuerpo se ignora, en todas las rutas", async () => {
  const { handle, store } = harness();
  const other = "cef00000-0000-4000-8000-0000000000ff";
  const intruder = { chefId: other, p_chef_id: other, chef_id: other };
  assert.equal((await handle(post("/bookings", bookingBody(intruder)))).status, 201);
  assert.equal((await handle(post("/sessions/move", { sessionId: SESSION_ID, date: "2026-11-25", ...intruder }))).status, 200);
  assert.equal((await handle(post("/sessions/cancel", { sessionIds: [SESSION_ID], ...intruder }))).status, 200);
  assert.deepEqual(
    [store.bookingCalls[0]?.p_chef_id, store.moveCalls[0]?.p_chef_id, store.cancelCalls[0]?.p_chef_id],
    [CHEF_ID, CHEF_ID, CHEF_ID],
  );
});

test("reserva a mano con ficha nueva: la base recibe la ficha limpia, el hogar, el idioma y la clave", async () => {
  const { handle, store } = harness();
  const response = await handle(post("/bookings", manualBody()));
  assert.equal(response.status, 201);
  const call = store.bookingCalls[0];
  assert.ok(call);
  assert.deepEqual(call.p_new_client, {
    name: "Mariaxyz Bianchiqwe",
    phone: "+393337654321",
    email: "maria.pii@example.test",
    zone: "ZonaPrivadaKkk",
    address: "Via Segretissima 42",
  });
  assert.deepEqual(call.p_household, { adults: 2, kids: 2, days: 5, meals: ["dinner"] });
  assert.equal(call.p_type, "week");
  assert.equal(call.p_locale, "it");
  assert.equal(call.p_request_key, REQUEST_KEY);
  assert.equal(call.p_request_id, null);
  assert.equal(call.p_client_id, null);
  // 280 € en 2 semanas.
  const body = await json(response);
  assert.deepEqual(body.weeks.map((week: { serviceCents: number }) => week.serviceCents), [14000, 14000]);
  assert.ok(!JSON.stringify(body).includes("Mariaxyz"), "la respuesta no repite los datos de la ficha");

  const existing = harness();
  const withClient = await existing.handle(post("/bookings", manualBody({ newClient: undefined, clientId: CLIENT_ID })));
  assert.equal(withClient.status, 201);
  assert.equal(existing.store.bookingCalls[0]?.p_client_id, CLIENT_ID);
  assert.equal(existing.store.bookingCalls[0]?.p_new_client, null);
});

test("reintento con la misma clave: el mismo 201 con duplicate: true y nada creado dos veces", async () => {
  const { handle, store, logs } = harness();
  const first = await handle(post("/bookings", manualBody()));
  const second = await handle(post("/bookings", manualBody()));
  assert.equal(first.status, 201);
  assert.equal(second.status, 201);
  const original = await json(first);
  const replay = await json(second);
  assert.equal(original.duplicate, false);
  assert.equal(replay.duplicate, true);
  assert.deepEqual({ ...replay, duplicate: false }, original, "el mismo pedido y las mismas sesiones");
  assert.equal(store.writes, 2, "las 2 semanas, una sola vez");
  assert.equal(logs.filter((entry) => entry.event === "booking_created").length, 1);
  assert.ok(logs.some((entry) => entry.event === "booking_duplicate" && entry.fields["requestId"] === original.requestId));

  // Desde un pedido el reintento se reconoce por el pedido (ya aceptado con esas sesiones).
  const fromRequest = harness();
  await fromRequest.handle(post("/bookings", bookingBody()));
  const again = await fromRequest.handle(post("/bookings", bookingBody()));
  assert.equal(again.status, 201);
  assert.equal((await json(again)).duplicate, true);
  assert.equal(fromRequest.store.writes, 4);
});

test("a mano sin requestKey: 400 (el reintento no sería seguro); en el dryRun no hace falta", async () => {
  const { handle, store } = harness();
  const response = await handle(post("/bookings", manualBody({ requestKey: undefined })));
  assert.equal(response.status, 400);
  assert.deepEqual(await json(response), { errors: { requestKey: "required" } });
  assert.equal(store.bookingCalls.length, 0);
  const dry = await handle(post("/bookings", manualBody({ requestKey: undefined, dryRun: true })));
  assert.equal(dry.status, 200);
});

test("dryRun: 200 con el estado de cada fecha y sin escribir nada, también sin hora", async () => {
  const { handle, store, logs } = harness();
  store.dayStatus.set("2026-11-30", "blocked");
  store.dayStatus.set("2026-12-07", "busy");
  const response = await handle(post("/bookings", bookingBody({ dryRun: true, start: null })));
  assert.equal(response.status, 200);
  const body = await json(response);
  assert.equal(body.dryRun, true);
  assert.equal(body.duplicate, false);
  assert.deepEqual(body.weeks.map((week: { status: string }) => week.status), ["ok", "blocked", "busy", "ok"]);
  assert.deepEqual(body.weeks[0], { date: "2026-11-23", start: "10:00", cookMinutes: 240, status: "ok", suggestedStart: "10:00", serviceCents: 14000, sessionId: null });
  assert.equal(store.bookingCalls[0]?.p_dry_run, true);
  assert.equal(store.bookingCalls[0]?.p_start, null);
  assert.equal(store.writes, 0, "un dryRun no escribe");
  assert.equal(store.sessions.length, 0);
  assert.ok(!logs.some((entry) => entry.event === "booking_created"));
});

test("409 con la fecha del choque: slotTaken y weekTaken; no se crea nada", async () => {
  const slot = harness();
  slot.store.failures.set("create_booking", storeErrorFrom("create_booking", { code: "23P01", message: "slot_taken", details: "2026-11-30" }));
  const taken = await slot.handle(post("/bookings", bookingBody()));
  assert.equal(taken.status, 409);
  assert.deepEqual(await json(taken), { error: "slotTaken", date: "2026-11-30" });
  assert.equal(slot.store.writes, 0);
  assert.ok(slot.logs.some((entry) => entry.event === "rejected" && entry.fields["error"] === "slotTaken" && entry.fields["code"] === "23P01"));

  const week = harness();
  week.store.failures.set("create_booking", storeErrorFrom("create_booking", { code: "23505", message: "week_taken", details: "2026-12-07" }));
  const weekTaken = await week.handle(post("/bookings", bookingBody()));
  assert.equal(weekTaken.status, 409);
  assert.deepEqual(await json(weekTaken), { error: "weekTaken", date: "2026-12-07" });

  // Otro choque sin nuestro código (no debería pasar): 409 genérico, sin el detalle de Postgres.
  const other = harness();
  other.store.failures.set(
    "create_booking",
    storeErrorFrom("create_booking", { code: "23505", message: 'duplicate key value violates unique constraint "x"', details: "Key (chef_id)=(…) already exists." }),
  );
  const conflict = await other.handle(post("/bookings", bookingBody()));
  assert.equal(conflict.status, 409);
  assert.deepEqual(await json(conflict), { error: "conflict" });
});

test("pedido que ya no está nuevo: 409 requestNotNew con su estado; no encontrado: 404", async () => {
  const notNew = harness();
  notNew.store.failures.set("create_booking", storeErrorFrom("create_booking", { code: "55000", message: "request_not_new", details: "rejected" }));
  const response = await notNew.handle(post("/bookings", bookingBody()));
  assert.equal(response.status, 409);
  assert.deepEqual(await json(response), { error: "requestNotNew", status: "rejected" });

  for (const [message, error] of [
    ["request_not_found", "requestNotFound"],
    ["client_not_found", "clientNotFound"],
    ["session_not_found", "sessionNotFound"],
  ] as const) {
    const run = harness();
    run.store.failures.set("create_booking", storeErrorFrom("create_booking", { code: "P0002", message }));
    const missing = await run.handle(post("/bookings", bookingBody()));
    assert.equal(missing.status, 404, message);
    assert.deepEqual(await json(missing), { error });
  }

  // chef_not_found: la cocinera está en chefs pero no en chef_settings (configuración rota).
  const settings = harness();
  settings.store.failures.set("create_booking", storeErrorFrom("create_booking", { code: "P0002", message: "chef_not_found" }));
  assert.equal((await settings.handle(post("/bookings", bookingBody()))).status, 500);
});

test("validaciones de la base (22023): 400 con el campo, por si la función y la base no coinciden", async () => {
  const cases: Array<[string, string | undefined, unknown]> = [
    ["dates_same_week", "2026-11-27", { errors: { dates: "sameWeek" }, date: "2026-11-27" }],
    ["weeks_only_for_week", undefined, { errors: { dates: "weeksOnlyForWeek" } }],
    ["invalid_request_type", undefined, { errors: { type: "invalid" } }],
    ["invalid_household", undefined, { errors: { household: "invalid" } }],
    ["invalid_cents", undefined, { errors: { cents: "range" } }],
    ["name_required", undefined, { errors: { "newClient.name": "required" } }],
    ["request_key_conflict", undefined, { errors: { requestKey: "conflict" } }],
    ["un_codigo_nuevo", undefined, { errors: { payload: "invalid" } }],
  ];
  for (const [message, details, expected] of cases) {
    const run = harness();
    run.store.failures.set("create_booking", storeErrorFrom("create_booking", { code: "22023", message, details }));
    const response = await run.handle(post("/bookings", bookingBody()));
    assert.equal(response.status, 400, message);
    assert.deepEqual(await json(response), expected);
  }
  // Otros errores de datos, checks o not null: 400 genérico.
  for (const code of ["23514", "23502", "22P02", "22007"]) {
    const check = harness();
    check.store.failures.set("create_booking", storeErrorFrom("create_booking", { code, message: 'new row for relation "requests" violates check constraint "x"' }));
    const response = await check.handle(post("/bookings", bookingBody()));
    assert.equal(response.status, 400, code);
    assert.deepEqual(await json(response), { errors: { payload: "invalid" } }, code);
  }
});

test("errores de la base: caída o reintentable → 503, el resto → 500; el log lleva solo operación y código", async () => {
  const cases: Array<[string | undefined, number]> = [
    [undefined, 503],
    ["", 503],
    ["08006", 503],
    ["40001", 503],
    ["57014", 503],
    ["53300", 503],
    ["58000", 503],
    ["PGRST000", 503],
    ["PGRST003", 503],
    ["PGRST202", 500],
    ["42501", 500],
    ["XX000", 500],
  ];
  for (const [code, status] of cases) {
    const run = harness();
    run.store.failures.set("create_booking", storeErrorFrom("create_booking", { code, message: "Mariaxyz no anda" }));
    const response = await run.handle(post("/bookings", bookingBody()));
    assert.equal(response.status, status, String(code));
    assert.deepEqual(await json(response), { error: status === 503 ? "unavailable" : "server" });
    const entry = run.logs.find((log) => log.event === "db_error");
    assert.ok(entry, String(code));
    assert.deepEqual(entry.fields, { op: "create_booking", code: code || null });
  }
});

test("respuesta de la base con otra forma: 500 y unexpected_result", async () => {
  // Bien formada, pero de un dryRun cuando se pidió crear (o al revés): tampoco se confía en ella.
  const dryAnswer = { dry_run: true, duplicate: false, request_id: REQUEST_ID, client_id: CLIENT_ID, weeks: [] };
  for (const [raw, body] of [
    [null, bookingBody()],
    [[], bookingBody()],
    [{ dry_run: false }, bookingBody()],
    [{ dry_run: false, duplicate: false, request_id: "x", client_id: null, weeks: [] }, bookingBody()],
    [dryAnswer, bookingBody()],
    [{ ...dryAnswer, dry_run: false }, bookingBody({ dryRun: true })],
  ] as const) {
    const run = harness();
    run.store.raw = raw;
    const response = await run.handle(post("/bookings", body));
    assert.equal(response.status, 500, JSON.stringify(raw));
    assert.deepEqual(await json(response), { error: "server" });
    assert.ok(run.logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "create_booking"));
  }

  const move = {
    dry_run: false,
    session_id: SESSION_ID,
    request_id: REQUEST_ID,
    date: "2026-11-25",
    start_time: "10:00:00",
    cook_minutes: 240,
    status: "ok",
    suggested_start: "10:00:00",
    week_taken: false,
  };
  for (const raw of [{ ...move, dry_run: true }, { ...move, session_id: "x" }, { ...move, request_id: "x" }]) {
    const run = harness();
    run.store.raw = raw;
    const response = await run.handle(post("/sessions/move", { sessionId: SESSION_ID, date: "2026-11-25" }));
    assert.equal(response.status, 500, JSON.stringify(raw));
    assert.ok(run.logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "move_session"));
  }
});

test("un error fuera de la base (el cuerpo que se corta, una respuesta que explota al leerla): 500 y unexpected_error solo con el tipo", async () => {
  const secret = "Mariaxyz Bianchiqwe, Via Segretissima 42, NOTA-SALUD-zzz";

  // El cliente corta mientras se lee el cuerpo.
  const stream = harness();
  const cut = new Request(`${BASE}/bookings`, {
    method: "POST",
    headers: { "content-type": "application/json", origin: ORIGIN, authorization: `Bearer ${TOKEN_EVELYN}` },
    body: new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.error(new Error(secret));
      },
    }),
    duplex: "half",
  } as RequestInit & { duplex: "half" });
  const cutResponse = await stream.handle(cut);
  assert.equal(cutResponse.status, 500);
  assert.deepEqual(await json(cutResponse), { error: "server" });

  // La respuesta de la base lanza al leerla.
  const getter = harness();
  getter.store.raw = Object.defineProperty({}, "dry_run", {
    enumerable: true,
    get() {
      throw new Error(secret);
    },
  });
  const getterResponse = await getter.handle(post("/bookings", bookingBody()));
  assert.equal(getterResponse.status, 500);

  for (const run of [stream, getter]) {
    const entry = run.logs.find((log) => log.event === "unexpected_error");
    assert.ok(entry);
    assert.deepEqual(entry.fields, { error: "Error" });
    assert.equal(entry.level, "error");
    assert.ok(!JSON.stringify(run.logs).includes("Mariaxyz"));
  }
});

test("una excepción inesperada: 500 y en el log solo la operación, nunca el mensaje", async () => {
  const { handle, store, logs } = harness();
  store.failures.set("create_booking", new TypeError("Mariaxyz Bianchiqwe +393337654321"));
  const response = await handle(post("/bookings", manualBody()));
  assert.equal(response.status, 500);
  assert.deepEqual(await json(response), { error: "server" });
  assert.ok(logs.some((entry) => entry.event === "db_error" && entry.fields["op"] === "create_booking" && entry.fields["code"] === null));
  assert.ok(!JSON.stringify(logs).includes("Mariaxyz"));
});

// ---------------------------------------------------------------------------
// POST /sessions/move y /sessions/cancel
// ---------------------------------------------------------------------------

test("mover: dryRun sin escribir y movimiento real; hora y minutos en null dejan los guardados", async () => {
  const { handle, store, logs } = harness();
  store.dayStatus.set("2026-11-25", "outside");
  const dry = await handle(post("/sessions/move", { sessionId: SESSION_ID, date: "2026-11-25", dryRun: true }));
  assert.equal(dry.status, 200);
  assert.deepEqual(await json(dry), {
    dryRun: true,
    sessionId: SESSION_ID,
    requestId: REQUEST_ID,
    date: "2026-11-25",
    start: "10:00",
    cookMinutes: 240,
    status: "outside",
    suggestedStart: "10:00",
    weekTaken: false,
  });
  assert.deepEqual(store.moveCalls[0], {
    p_chef_id: CHEF_ID,
    p_session_id: SESSION_ID,
    p_date: "2026-11-25",
    p_start: null,
    p_cook_minutes: null,
    p_dry_run: true,
  });
  assert.equal(store.writes, 0);

  const moved = await handle(post("/sessions/move", { sessionId: SESSION_ID, date: "2026-11-26", start: "11:30", cookMinutes: 200 }));
  assert.equal(moved.status, 200);
  const body = await json(moved);
  assert.equal(body.dryRun, false);
  assert.equal(body.start, "11:30");
  assert.equal(body.cookMinutes, 200);
  assert.equal(store.writes, 1);
  assert.ok(logs.some((entry) => entry.event === "session_moved" && entry.fields["sessionId"] === SESSION_ID));
});

test("mover: semana ocupada por la misma reserva → 409 weekTaken; horario ocupado → slotTaken; ya cocinada → sessionNotMovable", async () => {
  const cases: Array<[Parameters<typeof storeErrorFrom>[1], unknown]> = [
    [{ code: "23505", message: "week_taken", details: "2026-11-26" }, { error: "weekTaken", date: "2026-11-26" }],
    [{ code: "23P01", message: "slot_taken", details: "2026-11-26" }, { error: "slotTaken", date: "2026-11-26" }],
    [{ code: "55000", message: "session_not_movable", details: "cooked" }, { error: "sessionNotMovable", status: "cooked" }],
    // La guarda del trigger trae una frase en el detalle: no se repite.
    [{ code: "55000", message: "session_not_movable", details: "Una sesión paid no cambia de fecha, hora ni duración." }, { error: "sessionNotMovable" }],
  ];
  for (const [error, expected] of cases) {
    const run = harness();
    run.store.failures.set("move_session", storeErrorFrom("move_session", error));
    const response = await run.handle(post("/sessions/move", { sessionId: SESSION_ID, date: "2026-11-26" }));
    assert.equal(response.status, 409, JSON.stringify(error));
    assert.deepEqual(await json(response), expected);
  }
  const invalid = harness();
  const response = await invalid.handle(post("/sessions/move", { sessionId: SESSION_ID, date: "26/11/2026" }));
  assert.equal(response.status, 400);
  assert.deepEqual(await json(response), { errors: { date: "invalid" } });
  assert.equal(invalid.store.moveCalls.length, 0);
});

test("cancelar: 200 con las canceladas, las ya canceladas y las que tenían cobros; motivo por defecto", async () => {
  const { handle, store, logs } = harness();
  const response = await handle(post("/sessions/cancel", { sessionIds: [SESSION_ID, OTHER_SESSION_ID.toUpperCase()] }));
  assert.equal(response.status, 200);
  assert.deepEqual(store.cancelCalls, [
    { p_chef_id: CHEF_ID, p_session_ids: [SESSION_ID, OTHER_SESSION_ID], p_reason: "chef_cancelled", p_allow_with_payments: false },
  ]);
  assert.deepEqual(await json(response), {
    cancelled: [SESSION_ID, OTHER_SESSION_ID],
    alreadyCancelled: [],
    withPayments: [],
    hadPayments: false,
  });
  assert.ok(logs.some((entry) => entry.event === "sessions_cancelled" && entry.fields["cancelled"] === 2 && entry.fields["withPayments"] === 0));

  // Con permiso (Evelyn va a registrar la devolución), la semana cobrada se cancela.
  const paid = harness();
  paid.store.raw = { cancelled: [SESSION_ID], already_cancelled: [OTHER_SESSION_ID], with_payments: [SESSION_ID], had_payments: true };
  const withPayments = await paid.handle(
    post("/sessions/cancel", { sessionIds: [SESSION_ID, OTHER_SESSION_ID], reason: "client_cancelled", allowWithPayments: true }),
  );
  assert.deepEqual(await json(withPayments), {
    cancelled: [SESSION_ID],
    alreadyCancelled: [OTHER_SESSION_ID],
    withPayments: [SESSION_ID],
    hadPayments: true,
  });
  assert.equal(paid.store.cancelCalls[0]?.p_reason, "client_cancelled");
  assert.equal(paid.store.cancelCalls[0]?.p_allow_with_payments, true);
});

test("cancelar una semana ya cobrada sin permiso: 409 hasPayments con las sesiones, para ofrecer antes pasarla al final", async () => {
  const run = harness();
  run.store.failures.set(
    "cancel_sessions",
    storeErrorFrom("cancel_sessions", { code: "55000", message: "has_payments", details: `${SESSION_ID},${OTHER_SESSION_ID.toUpperCase()}` }),
  );
  const response = await run.handle(post("/sessions/cancel", { sessionIds: [SESSION_ID, OTHER_SESSION_ID] }));
  assert.equal(response.status, 409);
  assert.deepEqual(await json(response), { error: "hasPayments", sessionIds: [SESSION_ID, OTHER_SESSION_ID] });
  assert.ok(run.logs.some((entry) => entry.event === "rejected" && entry.fields["error"] === "hasPayments" && entry.fields["code"] === "55000"));

  // Un detalle que no son ids no se repite.
  const odd = harness();
  odd.store.failures.set("cancel_sessions", storeErrorFrom("cancel_sessions", { code: "55000", message: "has_payments", details: "Mariaxyz pagó 140 €" }));
  const oddResponse = await odd.handle(post("/sessions/cancel", { sessionIds: [SESSION_ID] }));
  assert.equal(oddResponse.status, 409);
  assert.deepEqual(await json(oddResponse), { error: "hasPayments" });
});

test("cancelar una cocinada o pagada: 409 invalidTransition con la sesión; motivo con texto libre: 400", async () => {
  const run = harness();
  run.store.failures.set("cancel_sessions", storeErrorFrom("cancel_sessions", { code: "55000", message: "invalid_transition", details: OTHER_SESSION_ID }));
  const response = await run.handle(post("/sessions/cancel", { sessionIds: [SESSION_ID, OTHER_SESSION_ID] }));
  assert.equal(response.status, 409);
  assert.deepEqual(await json(response), { error: "invalidTransition", sessionId: OTHER_SESSION_ID });

  const reason = harness();
  const invalid = await reason.handle(post("/sessions/cancel", { sessionIds: [SESSION_ID], reason: "La clienta se enfermó" }));
  assert.equal(invalid.status, 400);
  assert.deepEqual(await json(invalid), { errors: { reason: "invalid" } });
  assert.equal(reason.store.cancelCalls.length, 0);
});

// ---------------------------------------------------------------------------
// POST /translate
// ---------------------------------------------------------------------------

// Un plato con textos fáciles de buscar en los logs.
const DISH = { name: "  Milanesaxyz a la napolitana ", description: "Con salsa de tomate y DescripQwe muzzarella." };

test("traducir: 200 con el italiano y el inglés; el traductor recibe el plato recortado y la cocina gasta su cupo", async () => {
  const { handle, store, translator, logs } = harness();
  const response = await handle(post("/translate", DISH));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("access-control-allow-origin"), ORIGIN);
  assert.deepEqual(await json(response), {
    it: { name: "[it] Milanesaxyz a la napolitana", description: "[it] Con salsa de tomate y DescripQwe muzzarella." },
    en: { name: "[en] Milanesaxyz a la napolitana", description: "[en] Con salsa de tomate y DescripQwe muzzarella." },
  });
  assert.deepEqual(translator.calls, [{ name: "Milanesaxyz a la napolitana", description: "Con salsa de tomate y DescripQwe muzzarella." }]);
  assert.deepEqual(store.rateHits, [{ key: await translateRateKey(CHEF_ID), maxPerHour: 60, maxPerDay: 150 }]);
  assert.equal(store.bookingCalls.length + store.moveCalls.length + store.cancelCalls.length, 0, "no toca ninguna sesión");
  const entry = logs.find((log) => log.event === "translated");
  assert.deepEqual(entry?.fields, { route: "/translate", ms: 0, nameLength: 27, descriptionLength: 44, userId: USER_EVELYN });
});

test("traducir: sin descripción (o vacía), null en los dos idiomas", async () => {
  const { handle, translator } = harness();
  for (const body of [{ name: "Empanadas" }, { name: "Empanadas", description: null }, { name: "Empanadas", description: "  " }]) {
    const response = await handle(post("/translate", body));
    assert.equal(response.status, 200, JSON.stringify(body));
    assert.deepEqual(await json(response), {
      it: { name: "[it] Empanadas", description: null },
      en: { name: "[en] Empanadas", description: null },
    });
  }
  assert.deepEqual(translator.calls.map((call) => call.description), [null, null, null]);
});

test("traducir: 400 por campo, sin traducir ni gastar el cupo", async () => {
  const { handle, store, translator, logs } = harness();
  const cases: Array<[unknown, unknown]> = [
    [{}, { errors: { name: "required" } }],
    [{ name: "x".repeat(121) }, { errors: { name: "tooLong" } }],
    [{ name: "Locro", description: 5 }, { errors: { description: "invalid" } }],
    [{ name: "Locro\ncriollo" }, { errors: { name: "invalid" } }],
    [{ name: "Locro", nameEs: "Locro" }, { errors: { payload: "invalid" } }],
    [["Locro"], { errors: { payload: "invalid" } }],
  ];
  for (const [body, expected] of cases) {
    const response = await handle(post("/translate", body));
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.deepEqual(await json(response), expected);
  }
  assert.equal(translator.calls.length + store.rateHits.length, 0);
  assert.ok(logs.some((entry) => entry.event === "invalid_payload" && entry.fields["route"] === "/translate" && JSON.stringify(entry.fields["fields"]) === '["name"]'));
});

test("traducir con la traducción apagada (sin ANTHROPIC_API_KEY): 501 notConfigured sin gastar el cupo", async () => {
  const { handle, store, logs } = harness({ translator: null });
  const response = await handle(post("/translate", DISH));
  assert.equal(response.status, 501);
  assert.deepEqual(await json(response), { error: "notConfigured" });
  assert.equal(store.rateHits.length, 0, "no se gasta el cupo si no se puede traducir");
  assert.ok(logs.some((entry) => entry.event === "translate_failed" && entry.fields["reason"] === "notConfigured" && entry.level === "warn"));
  // Igual valida primero: un cuerpo roto sigue siendo un 400.
  assert.equal((await handle(post("/translate", {}))).status, 400);
});

test("traducir con TRANSLATE_TRANSPORT=fake fuera de un Supabase local: 501 notConfigured y un error en el log", async () => {
  // index.ts no arma ningún traductor (la configuración dice off): el handler recibe null.
  const { handle, store, logs } = harness({
    env: { SUPABASE_URL: "https://abcdefghijklmnop.supabase.co", TRANSLATE_TRANSPORT: "fake" },
    translator: null,
  });
  const response = await handle(post("/translate", DISH));
  assert.equal(response.status, 501);
  assert.deepEqual(await json(response), { error: "notConfigured" });
  assert.equal(store.rateHits.length, 0);
  const entry = logs.find((log) => log.event === "translate_failed");
  assert.equal(entry?.fields["reason"], "fakeIgnored");
  assert.equal(entry?.level, "error");
});

test("traducir pasado el límite de la cocina: 429 rateLimited con Retry-After, sin llamar al traductor", async () => {
  const { handle, store, translator, logs } = harness();
  store.rateAllowed = false;
  const response = await handle(post("/translate", DISH));
  assert.equal(response.status, 429);
  assert.deepEqual(await json(response), { error: "rateLimited" });
  assert.equal(response.headers.get("retry-after"), "3600");
  assert.equal(response.headers.get("access-control-expose-headers"), "Retry-After", "la bandeja web lo puede leer");
  assert.equal(translator.calls.length, 0);
  assert.equal(store.rateHits.length, 1, "el intento rechazado también se registra");
  assert.ok(logs.some((entry) => entry.event === "rate_limited" && entry.fields["route"] === "/translate" && entry.fields["userId"] === USER_EVELYN));
});

test("traducir con la base caída al contar el límite: 503 (o 500 si no se puede reintentar), sin traducir", async () => {
  const down = harness();
  down.store.failures.set("rate_limit", storeErrorFrom("rate_limit", { code: "", message: "TypeError: fetch failed" }));
  const response = await down.handle(post("/translate", DISH));
  assert.equal(response.status, 503);
  assert.deepEqual(await json(response), { error: "unavailable" });
  assert.equal(down.translator.calls.length, 0);
  assert.ok(down.logs.some((entry) => entry.event === "db_error" && entry.fields["op"] === "rate_limit"));

  const denied = harness();
  denied.store.failures.set("rate_limit", storeErrorFrom("rate_limit", { code: "42501", message: "permission denied for function hit_public_request_rate" }));
  const deniedResponse = await denied.handle(post("/translate", DISH));
  assert.equal(deniedResponse.status, 500);
  assert.deepEqual(await json(deniedResponse), { error: "server" });
  assert.equal(denied.translator.calls.length, 0);
});

test("traducir sin traducción: 503 lo que se puede reintentar, 422 lo que no sale con este plato, 500 lo que está roto; nunca a medias", async () => {
  const cases: Array<[string, TranslatorReply | Error, number, string, Record<string, unknown>, "warn" | "error"]> = [
    // Se puede reintentar: tiempo agotado, conexión, 5xx o 429 de Anthropic.
    ["timeout", { kind: "failed", reason: "timeout", status: null }, 503, "unavailable", { reason: "timeout", apiStatus: null }, "error"],
    ["sin conexión", { kind: "failed", reason: "connection", status: null }, 503, "unavailable", { reason: "connection" }, "error"],
    ["sobrecargada", { kind: "failed", reason: "apiError", status: 529 }, 503, "unavailable", { reason: "apiError", apiStatus: 529 }, "error"],
    ["error interno", { kind: "failed", reason: "apiError", status: 500 }, 503, "unavailable", { reason: "apiError", apiStatus: 500 }, "error"],
    ["límite de Anthropic", { kind: "failed", reason: "rateLimited", status: 429 }, 503, "unavailable", { reason: "rateLimited", apiStatus: 429 }, "error"],
    // No sale con este plato.
    ["negativa", { kind: "refusal", category: "cyber" }, 422, "untranslatable", { reason: "refusal", category: "cyber" }, "warn"],
    ["max_tokens", { kind: "maxTokens" }, 422, "untranslatable", { reason: "maxTokens" }, "warn"],
    ["otro stop_reason", { kind: "failed", reason: "stopReason", status: null }, 422, "untranslatable", { reason: "stopReason" }, "error"],
    ["JSON cortado", { kind: "text", text: '{"it":{"name":"Cotoletta","description":"Con' }, 422, "untranslatable", { reason: "invalidOutput" }, "error"],
    ["sin inglés", { kind: "text", text: JSON.stringify({ it: { name: "Cotoletta", description: "Con pomodoro." } }) }, 422, "untranslatable", { reason: "invalidOutput" }, "error"],
    ["sin la descripción", { kind: "text", text: JSON.stringify({ it: { name: "A" }, en: { name: "B" } }) }, 422, "untranslatable", { reason: "invalidOutput" }, "error"],
    // Roto o mal configurado: no sirve reintentar.
    ["clave inválida", { kind: "failed", reason: "apiError", status: 401 }, 500, "server", { reason: "apiError", apiStatus: 401 }, "error"],
    ["pedido rechazado", { kind: "failed", reason: "apiError", status: 400 }, 500, "server", { reason: "apiError", apiStatus: 400 }, "error"],
    ["error del SDK", { kind: "failed", reason: "sdk", status: null }, 500, "server", { reason: "sdk" }, "error"],
    ["el SDK no carga", { kind: "failed", reason: "sdkLoad", status: null }, 500, "server", { reason: "sdkLoad" }, "error"],
    ["explota", new Error("Milanesaxyz DescripQwe"), 500, "server", { reason: "unexpected" }, "error"],
  ];
  for (const [name, reply, status, error, expected, level] of cases) {
    const { handle, translator, logs } = harness();
    if (reply instanceof Error) translator.throws = reply;
    else translator.reply = reply;
    const response = await handle(post("/translate", DISH));
    assert.equal(response.status, status, name);
    assert.deepEqual(await json(response), { error }, name);
    const entry = logs.find((log) => log.event === "translate_failed");
    assert.ok(entry, name);
    for (const [field, value] of Object.entries(expected)) assert.equal(entry.fields[field], value, `${name}: ${field}`);
    assert.equal(entry.fields["route"], "/translate");
    assert.equal(entry.fields["nameLength"], 27);
    assert.equal(entry.level, level, name);
  }
});

test("traducir: el log lleva cuánto tardó el traductor", async () => {
  let clock = NOW.getTime();
  const run = harness({ now: () => new Date(clock) });
  run.translator.during = () => {
    clock += 1830;
  };
  assert.equal((await run.handle(post("/translate", DISH))).status, 200);
  assert.equal(run.logs.find((entry) => entry.event === "translated")?.fields["ms"], 1830);

  run.translator.reply = { kind: "failed", reason: "timeout", status: null };
  assert.equal((await run.handle(post("/translate", DISH))).status, 503);
  assert.equal(run.logs.find((entry) => entry.event === "translate_failed")?.fields["ms"], 1830);
});

test("traducir sin token válido: 401 sin leer el cuerpo ni traducir", async () => {
  const { handle, store, translator } = harness();
  const request = post("/translate", DISH, { token: null });
  const response = await handle(request);
  assert.equal(response.status, 401);
  assert.equal(request.bodyUsed, false);
  assert.equal(translator.calls.length + store.rateHits.length, 0);
});

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

test("los logs nunca llevan nombre, teléfono, email, zona, dirección, notas, restricciones, fechas ni el texto de un plato", async () => {
  const success = harness();
  await success.handle(post("/bookings", manualBody()));
  await success.handle(post("/bookings", manualBody()));
  await success.handle(post("/bookings", manualBody({ dryRun: true, requestKey: undefined })));
  await success.handle(post("/sessions/move", { sessionId: SESSION_ID, date: "2026-11-30", start: "10:00" }));
  await success.handle(post("/sessions/cancel", { sessionIds: [SESSION_ID] }));

  const dbError = harness();
  dbError.store.failures.set(
    "create_booking",
    storeErrorFrom("create_booking", {
      code: "23514",
      message: 'new row for relation "clients" violates check constraint: Mariaxyz Bianchiqwe',
      details: "Failing row contains (Mariaxyz, +393337654321, maria.pii@example.test, Via Segretissima 42).",
    }),
  );
  await dbError.handle(post("/bookings", manualBody()));

  const crash = harness();
  crash.store.failures.set("create_booking", new Error("Mariaxyz Bianchiqwe, Via Segretissima 42, NOTA-SALUD-zzz"));
  await crash.handle(post("/bookings", manualBody()));

  const invalid = harness();
  await invalid.handle(post("/bookings", manualBody({ newClient: { name: "Mariaxyz Bianchiqwe", phone: "765 4321 nope" }, dates: ["2026-11-23", "2026-11-30", "x"] })));

  const conflict = harness();
  conflict.store.failures.set("create_booking", storeErrorFrom("create_booking", { code: "23P01", message: "slot_taken", details: "2026-11-30" }));
  await conflict.handle(post("/bookings", manualBody()));

  // Quién llama: sin token, token rechazado, quien no es la cocinera y Auth caída.
  const auth = harness();
  await auth.handle(post("/bookings", manualBody(), { token: null }));
  await auth.handle(post("/bookings", manualBody(), { token: TOKEN_REJECTED }));
  await auth.handle(post("/bookings", manualBody(), { token: TOKEN_CLIENT }));
  const authDown = harness();
  authDown.store.failures.set("get_user", new StoreError("get_user", "503", null));
  await authDown.handle(post("/bookings", manualBody()));

  const config = harness({ env: { SUPABASE_URL: undefined } });
  await config.handle(post("/bookings", manualBody()));

  // Respuestas de la base con otra forma y errores fuera de la base.
  const shape = harness();
  shape.store.raw = { dry_run: false, nombre: "Mariaxyz Bianchiqwe" };
  await shape.handle(post("/bookings", manualBody()));
  const getter = harness();
  getter.store.raw = Object.defineProperty({}, "dry_run", {
    enumerable: true,
    get() {
      throw new Error("Mariaxyz Bianchiqwe, Via Segretissima 42, NOTA-SALUD-zzz");
    },
  });
  await getter.handle(post("/bookings", manualBody()));

  // Mover y cancelar con errores de la base que traen fechas o datos.
  const sessionErrors = harness();
  sessionErrors.store.failures.set("move_session", storeErrorFrom("move_session", { code: "23P01", message: "slot_taken", details: "2026-11-30" }));
  await sessionErrors.handle(post("/sessions/move", { sessionId: SESSION_ID, date: "2026-11-30" }));
  sessionErrors.store.failures.set("cancel_sessions", storeErrorFrom("cancel_sessions", { code: "55000", message: "has_payments", details: "Mariaxyz" }));
  await sessionErrors.handle(post("/sessions/cancel", { sessionIds: [SESSION_ID] }));

  // Traducir: lo que sale bien, un 400, sin traductor, el límite, la base caída, cada falla del
  // traductor (también una salida que repite el plato y uno que explota con el plato en el mensaje).
  const translations = harness();
  await translations.handle(post("/translate", DISH));
  await translations.handle(post("/translate", { name: "Milanesaxyz", description: 5, extra: "DescripQwe" }));
  for (const reply of [
    { kind: "refusal", category: "cyber" },
    { kind: "maxTokens" },
    { kind: "failed", reason: "apiError", status: 529 },
    { kind: "text", text: JSON.stringify({ it: { name: "Milanesaxyz" }, en: { name: "DescripQwe" } }) },
  ] as TranslatorReply[]) {
    translations.translator.reply = reply;
    await translations.handle(post("/translate", DISH));
  }
  translations.translator.throws = new Error("Milanesaxyz a la napolitana, DescripQwe");
  await translations.handle(post("/translate", DISH));
  translations.store.rateAllowed = false;
  await translations.handle(post("/translate", DISH));
  translations.store.failures.set("rate_limit", storeErrorFrom("rate_limit", { code: "", message: "Milanesaxyz DescripQwe" }));
  await translations.handle(post("/translate", DISH));
  const noTranslator = harness({ translator: null });
  await noTranslator.handle(post("/translate", DISH));

  const markers = [
    "Mariaxyz", "Bianchiqwe", "765", "4321", "maria.pii", "ZonaPrivadaKkk", "Segretissima", "NOTA-LIBRE", "NOTA-SALUD",
    "2026-11-23", "2026-11-30", TOKEN_EVELYN, TOKEN_REJECTED, TOKEN_CLIENT, "Milanesaxyz", "DescripQwe", "napolitana",
  ];
  const runs = [success, dbError, crash, invalid, conflict, auth, authDown, config, shape, getter, sessionErrors, translations, noTranslator];
  for (const run of runs) {
    const text = JSON.stringify(run.logs);
    assert.ok(run.logs.length > 0);
    for (const marker of markers) {
      assert.ok(!text.includes(marker), `el log lleva ${marker}: ${text}`);
    }
  }
  // Todos los eventos del handler pasaron por el espía (contrato §10).
  const events = new Set(runs.flatMap((run) => run.logs.map((entry) => entry.event)));
  for (const event of [
    "auth_rejected", "forbidden", "invalid_payload", "rejected", "booking_created", "booking_duplicate", "session_moved",
    "sessions_cancelled", "db_error", "unexpected_result", "unexpected_error", "config_missing", "translated", "translate_failed",
    "rate_limited",
  ]) {
    assert.ok(events.has(event), `falta el camino ${event}`);
  }
});

// ---------------------------------------------------------------------------
// Helpers puros
// ---------------------------------------------------------------------------

test("routeOf: lo que sigue al nombre de la función, con o sin /functions/v1", () => {
  assert.equal(routeOf("/chef/bookings"), "/bookings");
  assert.equal(routeOf("/functions/v1/chef/sessions/move"), "/sessions/move");
  assert.equal(routeOf("/chef/sessions/cancel/"), "/sessions/cancel");
  assert.equal(routeOf("/chef"), "");
  assert.equal(routeOf("/otra/bookings"), null);
});

test("bearerToken: solo «Bearer <JWT>» (tres partes base64url)", () => {
  assert.equal(bearerToken(`Bearer ${TOKEN_EVELYN}`), TOKEN_EVELYN);
  assert.equal(bearerToken(`bearer   ${TOKEN_EVELYN}`), TOKEN_EVELYN);
  for (const header of [null, "", "Bearer", "Bearer ", `Basic ${TOKEN_EVELYN}`, "Bearer sb_secret_abc", "Bearer a.b", `Bearer ${TOKEN_EVELYN} extra`, `Bearer ${"a".repeat(9000)}.b.c`]) {
    assert.equal(bearerToken(header), null, String(header).slice(0, 40));
  }
});

test("chefIdFromRpc: el uuid que devuelve public.chef_id_for_user, null (sin cocina) u otra forma (undefined)", () => {
  assert.equal(chefIdFromRpc(CHEF_ID), CHEF_ID);
  assert.equal(chefIdFromRpc(null), null);
  for (const raw of [undefined, "", "no-es-un-uuid", CHEF_ID.toUpperCase(), ` ${CHEF_ID}`, 1, true, { id: CHEF_ID }, [CHEF_ID]]) {
    assert.equal(chefIdFromRpc(raw), undefined, JSON.stringify(raw));
  }
});

test("index.ts: la cocina del usuario sale de public.chef_id_for_user (la dueña o un colaborador), no de chefs", () => {
  // index.ts no corre en Node (Deno y supabase-js): esto cuida que use la regla de la base, la misma
  // de las políticas (15_chef_members), y no una consulta propia que dejaría afuera a los colaboradores.
  const index = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  // La respuesta va tal cual al handler (chefIdFromRpc la interpreta): leerle un campo, como la forma de
  // antes ({ id }), daría null y un 403 a todos, también a Evelyn.
  assert.match(
    index,
    /const \{ data, error \} = await supabase\.rpc\("chef_id_for_user", \{ p_user_id: userId \}\);\s*if \(error\) throw storeErrorFrom\("load_chef", error\);\s*return data;/,
  );
  assert.ok(!index.includes('from("chefs")'), "sin consultas propias a chefs");
  assert.ok(!index.includes('from("chef_members")'), "ni a chef_members");
});

test("index.ts: el traductor real solo con ANTHROPIC_API_KEY, cargado en la primera traducción; el de mentira con TRANSLATE_TRANSPORT=fake; la clave no se loguea", () => {
  const index = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  // El SDK no se importa al arrancar: una falla al cargarlo solo afecta a /translate.
  assert.doesNotMatch(index, /^import [^\n]*claude_translator/m, "sin import estático de claude_translator.ts");
  assert.doesNotMatch(index, /@anthropic-ai\/sdk/);
  assert.match(index, /return lazyTranslator\(async \(\) => \{\s*const \{ createClaudeTranslator \} = await import\("\.\/claude_translator\.ts"\);\s*return createClaudeTranslator\(apiKey\);\s*\}\);/);
  assert.match(index, /if \(config\.translation === "fake"\) return fakeTranslator;/);
  assert.match(index, /if \(config\.translationFakeIgnored\) consoleLogger\("error", "translate_fake_ignored"\);/, "error al arrancar, sin datos");
  assert.match(index, /if \(config\.translation === "off"\) return null;/);
  assert.match(index, /translator: createTranslator\(\),/);
  // El límite por cocina va a la misma función SQL que el formulario, con la clave que arma el handler.
  assert.match(index, /supabase\.rpc\("hit_public_request_rate", \{\s*p_ip_hash: key,\s*p_max_hour: maxPerHour,\s*p_max_day: maxPerDay,\s*\}\)/);
  for (const line of index.split("\n").filter((text) => /consoleLogger|console\./.test(text))) {
    assert.ok(!/apiKey|ANTHROPIC_API_KEY"\)/.test(line), `un log con la clave: ${line.trim()}`);
  }
});

test("handler.ts no conoce el SDK de Anthropic: recibe un Translator (index.ts arma el real)", () => {
  const imports = (file: string): string[] =>
    readFileSync(new URL(file, import.meta.url), "utf8")
      .split("\n")
      .filter((line) => /^import |^\} from /.test(line));
  for (const line of imports("./handler.ts")) {
    assert.doesNotMatch(line, /anthropic|claude_translator/, line);
  }
  for (const file of ["./translation.ts", "./menu_translation.ts", "./menu_send.ts"]) {
    for (const line of imports(file)) {
      assert.doesNotMatch(line, /anthropic|claude_translator|npm:/, `las partes puras tampoco (corren en Node): ${file}: ${line}`);
    }
  }
});

test("claude_translator.ts: el SDK oficial fijado, sin nada del entorno, timeout por intento, un reintento y un tope de 40 s; los errores, a failureFrom", () => {
  // No corre en Node (importa npm:@anthropic-ai/sdk): esto cuida lo que el diseño fija de la llamada.
  // El mapeo de errores se prueba de verdad en translation.test.ts (failureFrom, con clases inyectadas).
  const source = readFileSync(new URL("./claude_translator.ts", import.meta.url), "utf8");
  assert.match(source, /^import Anthropic from "npm:@anthropic-ai\/sdk@1\.6\.0";$/m, "versión exacta, la de la guía");
  // La URL fija (ANTHROPIC_BASE_URL no desvía la clave), sin logs del SDK (ANTHROPIC_LOG=debug loguearía
  // el cuerpo, con el plato) ni trazas (ANTHROPIC_OPEN_TELEMETRY_* podría exportar el contenido).
  assert.match(
    source,
    /new Anthropic\(\{\s*apiKey,\s*baseURL: ANTHROPIC_API_URL,\s*logLevel: "off",\s*openTelemetry: false,\s*timeout: TRANSLATION_TIMEOUT_MS,\s*maxRetries: TRANSLATION_MAX_RETRIES,\s*\}\)/,
  );
  assert.doesNotMatch(source, /authToken|defaultHeaders|fetchOptions/, "ninguna otra credencial ni cabecera");
  // El tope de toda la llamada (el SDK respeta el retry-after sin tope y esa espera no cuenta para el timeout).
  assert.match(
    source,
    /await client\.beta\.messages\.create\(buildTranslationRequest\(source\), \{\s*signal: AbortSignal\.timeout\(TRANSLATION_DEADLINE_MS\),\s*\}\)/,
    "beta: el fallback del servidor",
  );
  assert.match(source, /return replyFromMessage\(message\);/, "stop_reason antes que el contenido, en la parte pura");
  assert.match(source, /return failureFrom\(error, Anthropic\);/, "las clases de error del SDK, a la parte pura");
  for (const forbidden of [/\bstream\s*:/, /\bthinking\s*:/, /console\./, /error\.message/, /JSON\.stringify\(error/, /String\(error/]) {
    assert.doesNotMatch(source, forbidden);
  }
});

test("authFailureKind: Auth rechaza el token (4xx) o no responde (429, 5xx, red)", () => {
  for (const status of [400, 401, 403, 404, 422]) assert.equal(authFailureKind(status), "invalid", String(status));
  for (const status of [429, 500, 502, 503, 0, undefined]) assert.equal(authFailureKind(status), "unavailable", String(status));
});

test("safeDbDetail: solo la fecha, el estado o el id que esperamos de cada código propio", () => {
  assert.equal(safeDbDetail("slot_taken", "2026-11-30"), "2026-11-30");
  assert.equal(safeDbDetail("week_taken", "2026-11-30"), "2026-11-30");
  assert.equal(safeDbDetail("dates_same_week", "2026-11-27"), "2026-11-27");
  assert.equal(safeDbDetail("slot_taken", "Key (chef_id, busy)=(…) conflicts"), null);
  assert.equal(safeDbDetail("request_not_new", "accepted"), "accepted");
  assert.equal(safeDbDetail("request_not_new", "Mariaxyz"), null);
  assert.equal(safeDbDetail("session_not_movable", "shopping_done"), "shopping_done");
  assert.equal(safeDbDetail("invalid_transition", OTHER_SESSION_ID.toUpperCase()), OTHER_SESSION_ID);
  assert.equal(safeDbDetail("invalid_transition", "Una sesión no pasa de paid a cancelled."), null);
  assert.equal(safeDbDetail("invalid_dates", "De 1 a 8 fechas."), null);
  assert.equal(safeDbDetail(null, "2026-11-30"), null);
  assert.equal(safeDbDetail("slot_taken", 20261130), null);
  assert.equal(safeDbDetail("has_payments", `${SESSION_ID},${OTHER_SESSION_ID.toUpperCase()}`), `${SESSION_ID},${OTHER_SESSION_ID}`);
  assert.equal(safeDbDetail("has_payments", `${SESSION_ID},Mariaxyz`), null);
  assert.equal(safeDbDetail("has_payments", `${SESSION_ID},`), null);
  assert.equal(safeDbDetail("has_payments", Array.from({ length: 101 }, () => SESSION_ID).join(",")), null, "como mucho 100");
});

test("storeErrorFrom: código, mensaje solo si es un identificador propio y detalle filtrado", () => {
  const error = storeErrorFrom("create_booking", { code: "23P01", message: "slot_taken", details: "2026-11-30", hint: "Mariaxyz" });
  assert.ok(error instanceof StoreError);
  assert.equal(error.op, "create_booking");
  assert.equal(error.code, "23P01");
  assert.equal(error.safeMessage, "slot_taken");
  assert.equal(error.safeDetail, "2026-11-30");
  const unsafe = storeErrorFrom("load_chef", { code: "23514", message: "violates check constraint Mariaxyz", details: "Failing row contains (Mariaxyz)" });
  assert.equal(unsafe.safeMessage, null);
  assert.equal(unsafe.safeDetail, null);
  assert.equal(storeErrorFrom("x", {}).code, null);
  assert.equal(storeErrorFrom("x", { code: "" }).code, null);
});

test("dbErrorReply: lo que no es un error de la base es un 500", () => {
  assert.deepEqual(dbErrorReply(new Error("x")), { status: 500, body: { error: "server" } });
  assert.deepEqual(dbErrorReply(storeErrorFrom("x", { code: "23P01", message: "slot_taken" })), { status: 409, body: { error: "conflict" } }, "sin fecha válida: choque genérico");
});

test("bookingResponseFromRpc: camelCase, horas HH:MM y nada que no tenga la forma esperada", () => {
  const week = {
    date: "2026-11-23",
    start_time: "10:00:00",
    cook_minutes: 240,
    status: "ok",
    suggested_start: "10:00:00",
    service_cents: 14000,
    session_id: SESSION_ID,
  };
  const rpc = { dry_run: false, duplicate: false, request_id: REQUEST_ID, client_id: CLIENT_ID, weeks: [week] };
  assert.deepEqual(bookingResponseFromRpc(rpc), {
    dryRun: false,
    duplicate: false,
    requestId: REQUEST_ID,
    clientId: CLIENT_ID,
    weeks: [{ date: "2026-11-23", start: "10:00", cookMinutes: 240, status: "ok", suggestedStart: "10:00", serviceCents: 14000, sessionId: SESSION_ID }],
  });
  // dryRun de una reserva a mano con ficha nueva: sin pedido ni ficha todavía, y un día sin horario.
  const dry = bookingResponseFromRpc({
    ...rpc,
    dry_run: true,
    request_id: null,
    client_id: null,
    weeks: [{ ...week, start_time: null, suggested_start: null, status: "closed", session_id: null }],
  });
  assert.equal(dry?.requestId, null);
  assert.deepEqual(dry?.weeks[0], { date: "2026-11-23", start: null, cookMinutes: 240, status: "closed", suggestedStart: null, serviceCents: 14000, sessionId: null });

  for (const broken of [
    { ...rpc, weeks: [{ ...week, status: "raro" }] },
    { ...rpc, weeks: [{ ...week, service_cents: 140.5 }] },
    { ...rpc, weeks: [{ ...week, date: "23/11/2026" }] },
    { ...rpc, weeks: [{ ...week, start_time: "10" }] },
    { ...rpc, weeks: "[]" },
    { ...rpc, request_id: "x" },
    { ...rpc, duplicate: "no" },
  ]) {
    assert.equal(bookingResponseFromRpc(broken), null, JSON.stringify(broken));
  }
});

test("moveSessionResponseFromRpc y cancelSessionsResponseFromRpc: la forma de la base o null", () => {
  const move = {
    dry_run: true,
    session_id: SESSION_ID,
    request_id: null,
    date: "2026-11-25",
    start_time: "11:30:00",
    cook_minutes: 200,
    status: "busy",
    suggested_start: "10:00:00",
    week_taken: true,
  };
  assert.deepEqual(moveSessionResponseFromRpc(move), {
    dryRun: true,
    sessionId: SESSION_ID,
    requestId: null,
    date: "2026-11-25",
    start: "11:30",
    cookMinutes: 200,
    status: "busy",
    suggestedStart: "10:00",
    weekTaken: true,
  });
  assert.equal(moveSessionResponseFromRpc({ ...move, week_taken: null }), null);
  assert.equal(moveSessionResponseFromRpc({ ...move, start_time: null }), null, "una sesión siempre tiene hora");

  assert.deepEqual(cancelSessionsResponseFromRpc({ cancelled: [SESSION_ID], already_cancelled: [], with_payments: [], had_payments: false }), {
    cancelled: [SESSION_ID],
    alreadyCancelled: [],
    withPayments: [],
    hadPayments: false,
  });
  assert.equal(cancelSessionsResponseFromRpc({ cancelled: ["x"], already_cancelled: [], with_payments: [], had_payments: false }), null);
  assert.equal(cancelSessionsResponseFromRpc({ cancelled: [], already_cancelled: [], with_payments: [] }), null);
});

test("readChefConfig: orígenes de ALLOWED_ORIGINS, lo que falta de Supabase y de dónde sale la traducción", () => {
  const config = readChefConfig((name) => ENV[name]);
  assert.equal(config.allowedOrigins.length, 2);
  assert.deepEqual(config.missing, []);
  assert.equal(config.translation, "off");
  assert.deepEqual(chefConfigWarnings(config), ["ANTHROPIC_API_KEY"], "sin la clave, la traducción queda apagada (503) y el arranque avisa");

  const withKey = readChefConfig((name) => ({ ...ENV, ANTHROPIC_API_KEY: "sk-ant-prueba" })[name]);
  assert.equal(withKey.translation, "claude");
  assert.deepEqual(chefConfigWarnings(withKey), []);
  assert.ok(!JSON.stringify(withKey).includes("sk-ant-prueba"), "la clave no queda en la configuración (la lee solo index.ts)");
  assert.ok(!JSON.stringify(withKey).includes("re_prueba"), "la de Resend tampoco: solo si está (la lee index.ts)");
  assert.equal(withKey.resendConfigured, true);
  const fake = readChefConfig((name) => ({ ...ENV, TRANSLATE_TRANSPORT: "fake" })[name]);
  assert.equal(fake.translation, "fake", "con el Supabase local de los tests (127.0.0.1)");
  assert.equal(fake.translationFakeIgnored, false);
  assert.deepEqual(chefConfigWarnings(fake), []);
  const fakeInProduction = readChefConfig(
    (name) => ({ ...ENV, SUPABASE_URL: "https://abcdefghijklmnop.supabase.co", TRANSLATE_TRANSPORT: "fake", ANTHROPIC_API_KEY: "sk-ant-prueba" })[name],
  );
  assert.equal(fakeInProduction.translation, "off", "nunca traducciones de mentira en producción, aunque haya clave");
  assert.equal(fakeInProduction.translationFakeIgnored, true);
  assert.deepEqual(chefConfigWarnings(fakeInProduction), ["ANTHROPIC_API_KEY"]);

  const empty = readChefConfig(() => undefined);
  assert.deepEqual(empty.missing, ["SUPABASE_URL", "SUPABASE_SECRET_KEYS"]);
  assert.deepEqual(
    chefConfigWarnings(empty),
    ["ALLOWED_ORIGINS", "ANTHROPIC_API_KEY", "PUBLIC_SITE_URL", "RESEND_API_KEY", "MAIL_FROM", "MAIL_REPLY_TO"],
    "sin CORS la app web no la puede llamar (la nativa sí); sin la web, el menú no sale; sin Resend, solo por WhatsApp",
  );

  const legacy = readChefConfig((name) => ({ SUPABASE_URL: " http://x ", SUPABASE_SERVICE_ROLE_KEY: "legacy" })[name]);
  assert.deepEqual(legacy.missing, []);
});

// ---------------------------------------------------------------------------
// POST /menus/preview y /menus/send: el menú de una semana para la clienta (§13)
// ---------------------------------------------------------------------------

function previewBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { sessionId: SESSION_ID, menuVersion: MENU_VERSION, ...overrides };
}

/** El token del link en un mensaje (#t=…, 43 caracteres base64url), o null. */
function tokenIn(text: string): string | null {
  return /\/prenotazione\/#t=([A-Za-z0-9_-]{43})(?![A-Za-z0-9_-])/.exec(text)?.[1] ?? null;
}

function sha256(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/** Una vista previa que salió bien: su respuesta. */
// deno-lint-ignore no-explicit-any
async function previewed(run: Harness, body: Record<string, unknown> = previewBody()): Promise<any> {
  const response = await run.handle(post("/menus/preview", body));
  assert.equal(response.status, 200, "la vista previa");
  return await json(response);
}

test("vista previa: 200 con el mensaje en italiano sin link, el contacto, la lista traducida y la nota tal cual", async () => {
  const run = harness();
  const response = await run.handle(post("/menus/preview", previewBody()));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("access-control-allow-origin"), ORIGIN);
  const body = await json(response);
  assert.deepEqual(Object.keys(body).sort(), ["contact", "locale", "message", "sendId", "translated"]);
  assert.equal(body.sendId, sendIdOf(0));
  assert.equal(body.locale, "it");
  assert.equal(body.translated, true);
  assert.deepEqual(body.contact, { name: "Mariaxyz Bianchiqwe", email: "maria.pii@example.test", phone: "+39 333 765 4321" }, "para que Evelyn lo revise");
  assert.deepEqual(Object.keys(body.message).sort(), ["emailText", "subject", "whatsappText"]);
  assert.equal(body.message.subject, "Radici: il menù della settimana 1 di 2 (30 nov)");
  for (const text of [body.message.emailText, body.message.whatsappText]) {
    assert.ok(text.includes("Ciao Mariaxyz!"));
    assert.ok(text.includes("Milanesaxyz alla napoletana"));
    assert.ok(text.includes("[it] Zapallitoszzz: 1,25 kg"));
    assert.ok(text.includes("[it] Zapallitoszzz: 250 g"));
    assert.ok(text.includes(MENU_NOTE), "la nota, como la escribió Evelyn");
    assert.ok(!text.includes("[it] NOTA"), "la nota nunca se traduce");
    assert.ok(text.includes("[link personale per confermare]"), "sin link: se crea al enviar");
    assert.equal(tokenIn(text), null);
    for (const marker of ["Segretissima", "NOTA-SALUD", "maria.pii", "765 4321"]) assert.ok(!text.includes(marker), marker);
  }

  // A Claude, solo los nombres de la lista (sin repetir), nunca la nota; con el cupo de la cocina, el de /translate.
  assert.deepEqual(run.translator.menuCalls, [{ target: "it", items: ["Zapallitoszzz", "sal"] }]);
  assert.ok(!JSON.stringify(run.translator.menuCalls).includes("NOTA-MENU"));
  assert.deepEqual(run.store.rateHits, [{ key: await translateRateKey(CHEF_ID), maxPerHour: 60, maxPerDay: 150 }]);
  assert.deepEqual(run.store.contextCalls, [{ p_chef_id: CHEF_ID, p_session_id: SESSION_ID }]);

  // La foto que guarda la base: en italiano, con la foto del plato de la web y la lista traducida.
  const [prepare] = run.store.prepareCalls;
  assert.ok(prepare);
  assert.equal(prepare.p_chef_id, CHEF_ID);
  assert.equal(prepare.p_session_id, SESSION_ID);
  assert.equal(prepare.p_menu_version, MENU_VERSION);
  assert.equal(prepare.p_locale, "it");
  assert.equal(prepare.p_translated, true, "se tradujo la lista");
  assert.equal(prepare.p_fingerprint, FINGERPRINT, "la huella del contexto con que se armó la foto");
  assert.deepEqual(prepare.p_snapshot, {
    v: 1,
    locale: "it",
    session: { date: "2026-11-30", start: "10:00", week: 1, weeks: 2 },
    weeks: [
      { date: "2026-11-30", start: "10:00" },
      { date: "2026-12-07", start: "10:00" },
    ],
    dishes: [
      {
        name: "Milanesaxyz alla napoletana",
        description: "Con DescripQwe pomodoro.",
        allergens: ["gluten", "milk"],
        diet: null,
        portions: 6,
        photo: {
          thumb: `http://127.0.0.1:54321/storage/v1/object/public/recipe-photos/${CHEF_ID}/${RECIPE_ID}/${PHOTO_ID}-thumb.jpg`,
          full: `http://127.0.0.1:54321/storage/v1/object/public/recipe-photos/${CHEF_ID}/${RECIPE_ID}/${PHOTO_ID}.jpg`,
        },
      },
    ],
    items: [
      { name: "[it] Zapallitoszzz", section: "produce", quantity: 1250, unit: "g" },
      { name: "[it] sal", section: "pantry", quantity: null, unit: null },
      { name: "[it] Zapallitoszzz", section: "produce", quantity: 250, unit: "g" },
    ],
    note: MENU_NOTE,
  });
  const snapshotText = JSON.stringify(prepare.p_snapshot);
  for (const marker of ["Mariaxyz", "maria.pii", "765", "Segretissima", "NOTA-SALUD", REQUEST_ID, FINGERPRINT]) assert.ok(!snapshotText.includes(marker), marker);

  assert.deepEqual(run.logs.find((entry) => entry.event === "translated")?.fields, {
    route: "/menus/preview",
    ms: 0,
    items: 2,
    userId: USER_EVELYN,
  });
  assert.deepEqual(run.logs.find((entry) => entry.event === "menu_previewed")?.fields, {
    route: "/menus/preview",
    sendId: sendIdOf(0),
    sessionId: SESSION_ID,
    locale: "it",
    translated: true,
    dishes: 1,
    items: 3,
    hasNote: true,
    userId: USER_EVELYN,
  });
});

test("vista previa en español, sin traducir (translate: false) o sin lista (aunque haya nota): no llama a Claude ni gasta el cupo", async () => {
  const spanish = harness();
  spanish.store.menuContext = menuContextRpc({ request: { locale: "es" } });
  const es = await previewed(spanish);
  assert.equal(es.translated, false);
  assert.equal(es.message.subject, "Radici: el menú de la semana 1 de 2 (30 nov)");
  assert.ok(es.message.emailText.includes("Milanesaxyz a la napolitana"), "el nombre en español");
  assert.ok(es.message.emailText.includes("Zapallitoszzz: 1,25 kg"));
  assert.ok(es.message.emailText.includes(MENU_NOTE));

  const untranslated = harness();
  const it = await previewed(untranslated, previewBody({ translate: false }));
  assert.equal(it.translated, false);
  assert.equal(untranslated.store.prepareCalls[0]?.p_translated, false);
  assert.deepEqual(untranslated.store.prepareCalls[0]?.p_snapshot.items.map((item) => item.name), ["Zapallitoszzz", "sal", "Zapallitoszzz"]);
  assert.equal(untranslated.store.prepareCalls[0]?.p_snapshot.note, MENU_NOTE, "la nota como la escribió Evelyn");

  const empty = harness();
  empty.store.menuContext = menuContextRpc({}, { items: [] });
  const noList = await previewed(empty);
  assert.equal(noList.translated, false, "la nota sola no se traduce");
  assert.ok(noList.message.emailText.includes(MENU_NOTE));

  for (const run of [spanish, untranslated, empty]) {
    assert.equal(run.translator.menuCalls.length + run.store.rateHits.length, 0);
    assert.equal(run.store.prepareCalls.length, 1);
  }
});

test("vista previa en inglés: el plato sin inglés va en italiano; la lista, a inglés; la nota, como está", async () => {
  const run = harness();
  run.store.menuContext = menuContextRpc({ request: { locale: "en" } });
  const body = await previewed(run);
  assert.equal(body.locale, "en");
  assert.equal(run.translator.menuCalls[0]?.target, "en");
  assert.ok(body.message.emailText.includes("• Milanesaxyz alla napoletana"));
  assert.ok(body.message.emailText.includes("[en] Zapallitoszzz: 1.25 kg"));
  assert.ok(body.message.emailText.includes(`A NOTE FROM EVELYN\n${MENU_NOTE}`), "la nota, en el idioma en que la escribió Evelyn");
  assert.ok(body.message.emailText.includes("[personal link to confirm]"));
});

test("vista previa sin traductor: 501 notConfigured sin gastar el cupo ni guardar nada (la app ofrece mandar sin traducir)", async () => {
  const run = harness({ translator: null });
  const response = await run.handle(post("/menus/preview", previewBody()));
  assert.equal(response.status, 501);
  assert.deepEqual(await json(response), { error: "notConfigured" });
  assert.equal(run.store.rateHits.length + run.store.prepareCalls.length, 0);
  const entry = run.logs.find((log) => log.event === "translate_failed");
  assert.equal(entry?.fields["route"], "/menus/preview");
  assert.equal(entry?.fields["reason"], "notConfigured");
  // Sin traducir sale igual.
  assert.equal((await run.handle(post("/menus/preview", previewBody({ translate: false })))).status, 200);
});

test("vista previa pasado el límite de la cocina (el de /translate): 429 con Retry-After, sin traducir ni guardar", async () => {
  const run = harness();
  run.store.rateAllowed = false;
  const response = await run.handle(post("/menus/preview", previewBody()));
  assert.equal(response.status, 429);
  assert.deepEqual(await json(response), { error: "rateLimited" });
  assert.equal(response.headers.get("retry-after"), "3600");
  assert.equal(run.translator.menuCalls.length + run.store.prepareCalls.length, 0);
  assert.ok(run.logs.some((entry) => entry.event === "rate_limited" && entry.fields["route"] === "/menus/preview"));

  const down = harness();
  down.store.failures.set("rate_limit", storeErrorFrom("rate_limit", { code: "", message: "TypeError: fetch failed" }));
  const downResponse = await down.handle(post("/menus/preview", previewBody()));
  assert.equal(downResponse.status, 503);
  assert.deepEqual(await json(downResponse), { error: "unavailable" });
});

test("vista previa sin traducción: 503, 422 o 500 como /translate; nunca una lista a medias ni un envío guardado", async () => {
  const cases: Array<[string, TranslatorReply | Error, number, string, string]> = [
    ["timeout", { kind: "failed", reason: "timeout", status: null }, 503, "unavailable", "timeout"],
    ["sobrecargada", { kind: "failed", reason: "apiError", status: 529 }, 503, "unavailable", "apiError"],
    ["negativa", { kind: "refusal", category: "cyber" }, 422, "untranslatable", "refusal"],
    ["max_tokens", { kind: "maxTokens" }, 422, "untranslatable", "maxTokens"],
    ["uno de menos", { kind: "text", text: JSON.stringify({ items: ["zucchine"] }) }, 422, "untranslatable", "invalidOutput"],
    ["con una nota que nadie pidió", { kind: "text", text: JSON.stringify({ items: ["zucchine", "sale"], note: "Nota" }) }, 422, "untranslatable", "invalidOutput"],
    ["clave inválida", { kind: "failed", reason: "apiError", status: 401 }, 500, "server", "apiError"],
    ["explota", new Error("Zapallitoszzz NOTA-MENU-qqq"), 500, "server", "unexpected"],
  ];
  for (const [name, reply, status, error, reason] of cases) {
    const run = harness();
    if (reply instanceof Error) run.translator.throws = reply;
    else run.translator.menuReply = reply;
    const response = await run.handle(post("/menus/preview", previewBody()));
    assert.equal(response.status, status, name);
    assert.deepEqual(await json(response), { error }, name);
    assert.equal(run.store.prepareCalls.length, 0, `${name}: no se guarda nada`);
    const entry = run.logs.find((log) => log.event === "translate_failed");
    assert.equal(entry?.fields["reason"], reason, name);
    assert.equal(entry?.fields["route"], "/menus/preview");
    assert.equal(entry?.fields["items"], 2);
    assert.equal(entry?.fields["noteLength"], undefined, "la nota no entra en la traducción");
  }
});

test("vista previa: lo que la base vuelve a mirar se rechaza antes de traducir (otra versión, sin platos)", async () => {
  const cases: Array<[string, (run: Harness) => void, Record<string, unknown>, unknown]> = [
    ["otra versión del menú", () => {}, previewBody({ menuVersion: MENU_VERSION - 1 }), { error: "menuChanged" }],
    [
      "sin platos",
      (run) => {
        run.store.menuContext = menuContextRpc({}, { dishes: [] });
      },
      previewBody(),
      { error: "menuEmpty" },
    ],
  ];
  for (const [name, setup, body, expected] of cases) {
    const run = harness();
    setup(run);
    const response = await run.handle(post("/menus/preview", body));
    assert.equal(response.status, 409, name);
    assert.deepEqual(await json(response), expected, name);
    assert.equal(run.translator.menuCalls.length + run.store.rateHits.length + run.store.prepareCalls.length, 0, `${name}: sin traducir ni guardar`);
    assert.ok(run.logs.some((entry) => entry.event === "rejected" && entry.fields["route"] === "/menus/preview"), name);
  }
});

test("vista previa de una semana cancelada, cocinada o cobrada: la base la rechaza (55000) y es 409 sessionNotEditable con el estado", async () => {
  for (const status of ["cancelled", "cooked", "paid"]) {
    const run = harness();
    run.store.failures.set("menu_send_context", storeErrorFrom("menu_send_context", { code: "55000", message: "session_not_editable", details: status }));
    const response = await run.handle(post("/menus/preview", previewBody()));
    assert.equal(response.status, 409, status);
    assert.deepEqual(await json(response), { error: "sessionNotEditable", status });
    assert.equal(run.translator.menuCalls.length + run.store.rateHits.length + run.store.prepareCalls.length, 0, `${status}: sin traducir ni guardar`);
    assert.ok(run.logs.some((entry) => entry.event === "rejected" && entry.fields["message"] === "session_not_editable"));
  }
});

test("vista previa: si algo cambia mientras se traduce la lista (la semana se mueve, un plato), la base no guarda la foto: 409 menuChanged", async () => {
  const run = harness();
  run.translator.during = () => {
    run.store.fingerprint = MOVED_FINGERPRINT;
  };
  const response = await run.handle(post("/menus/preview", previewBody()));
  assert.equal(response.status, 409);
  assert.deepEqual(await json(response), { error: "menuChanged" });
  assert.equal(run.store.prepareCalls[0]?.p_fingerprint, FINGERPRINT, "la huella con que se armó la foto");
  assert.equal(run.store.sends.size, 0);

  const missing = harness();
  missing.store.menuContext = menuContextRpc({ fingerprint: undefined });
  assert.equal((await missing.handle(post("/menus/preview", previewBody()))).status, 500, "un contexto sin huella no se usa");
  assert.ok(missing.logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "menu_send_context"));
});

test("vista previa: los errores de la base, traducidos (404, 409, 500, 503); una respuesta con otra forma, 500", async () => {
  const cases: Array<[string, "menu_send_context" | "prepare_menu_send", Record<string, unknown>, number, unknown]> = [
    ["sesión de otra cocina", "menu_send_context", { code: "P0002", message: "session_not_found" }, 404, { error: "sessionNotFound" }],
    ["sin menú guardado", "menu_send_context", { code: "P0002", message: "menu_not_found" }, 404, { error: "menuNotFound" }],
    ["sesión sin pedido", "menu_send_context", { code: "55000", message: "session_without_request" }, 409, { error: "sessionWithoutRequest" }],
    ["la base no responde", "menu_send_context", { code: "", message: "TypeError: fetch failed" }, 503, { error: "unavailable" }],
    ["sin permiso", "menu_send_context", { code: "42501", message: "permission denied" }, 500, { error: "server" }],
    ["el menú cambió entretanto", "prepare_menu_send", { code: "40001", message: "menu_changed" }, 409, { error: "menuChanged" }],
    [
      "la sesión ya se cocinó",
      "prepare_menu_send",
      { code: "55000", message: "session_not_editable", details: "cooked" },
      409,
      { error: "sessionNotEditable", status: "cooked" },
    ],
    ["el menú quedó sin platos", "prepare_menu_send", { code: "22023", message: "menu_empty" }, 409, { error: "menuEmpty" }],
    ["la foto rota (un error de la función)", "prepare_menu_send", { code: "22023", message: "invalid_snapshot" }, 500, { error: "server" }],
    ["la base no responde al guardar", "prepare_menu_send", { code: "08006", message: "connection failure" }, 503, { error: "unavailable" }],
  ];
  for (const [name, op, error, status, expected] of cases) {
    const run = harness();
    run.store.failures.set(op, storeErrorFrom(op, error));
    const response = await run.handle(post("/menus/preview", previewBody({ translate: false })));
    assert.equal(response.status, status, name);
    assert.deepEqual(await json(response), expected, name);
  }

  const shape = harness();
  shape.store.menuContext = { session: { id: SESSION_ID } };
  assert.equal((await shape.handle(post("/menus/preview", previewBody()))).status, 500);
  assert.ok(shape.logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "menu_send_context"));
  assert.equal(shape.store.prepareCalls.length, 0);

  const prepared = harness();
  prepared.store.prepareRaw = { send_id: "x" };
  assert.equal((await prepared.handle(post("/menus/preview", previewBody({ translate: false })))).status, 500);
  assert.ok(prepared.logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "prepare_menu_send"));
});

test("vista previa: 400 por campo o con una clave de más, sin tocar la base", async () => {
  const run = harness();
  const cases: Array<[unknown, unknown]> = [
    [{}, { errors: { sessionId: "required", menuVersion: "required" } }],
    [{ sessionId: SESSION_ID, menuVersion: 0 }, { errors: { menuVersion: "range" } }],
    [{ sessionId: SESSION_ID, menuVersion: 1, translate: "sí" }, { errors: { translate: "invalid" } }],
    [{ sessionId: SESSION_ID, menuVersion: 1, locale: "en" }, { errors: { payload: "invalid" } }],
  ];
  for (const [body, expected] of cases) {
    const response = await run.handle(post("/menus/preview", body));
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.deepEqual(await json(response), expected);
  }
  assert.equal(run.store.contextCalls.length, 0);
});

test("enviar por email: crea el link (la base guarda solo el hash), manda el email con el link y lo marca enviado", async () => {
  const run = harness();
  const preview = await previewed(run);
  const response = await run.handle(post("/menus/send", { sendId: preview.sendId, email: true }));
  assert.equal(response.status, 200);
  assert.deepEqual(await json(response), { sentAt: SENT_AT, sentVia: ["email"] }, "sin el texto del WhatsApp");

  const [link] = run.store.linkCalls;
  assert.ok(link);
  assert.equal(link.p_chef_id, CHEF_ID);
  assert.equal(link.p_send_id, preview.sendId);
  assert.match(link.p_token_hash, /^[0-9a-f]{64}$/);

  const [mail] = run.mailer.messages;
  assert.ok(mail);
  assert.equal(mail.from, "Radici <ciao@radicicucina.app>");
  assert.equal(mail.to, "maria.pii@example.test");
  assert.equal(mail.replyTo, "evelyn.reply@example.test", "las respuestas le llegan a Evelyn");
  assert.equal(mail.subject, preview.message.subject);
  const token = tokenIn(mail.text);
  assert.ok(token);
  assert.equal(sha256(token), link.p_token_hash, "el link del email abre el hash que guardó la base");
  const url = `https://radicicucina.app/prenotazione/#t=${token}`;
  assert.ok(mail.html.includes(`href="${url}"`));
  assert.equal(mail.idempotencyKey, `menu-send-${preview.sendId}-${link.p_token_hash.slice(0, 16)}`);
  // Lo que salió es lo que Evelyn vio en la vista previa, con el link en lugar del texto de reemplazo.
  assert.equal(mail.text, preview.message.emailText.replace("[link personale per confermare]", url));
  assert.ok(!mail.html.includes("[link personale per confermare]"));

  assert.deepEqual(run.store.completeCalls, [{ p_chef_id: CHEF_ID, p_send_id: preview.sendId, p_via: ["email"] }]);
  assert.ok(run.logs.some((entry) => entry.event === "email_sent" && entry.fields["sendId"] === preview.sendId));
  assert.deepEqual(run.logs.find((entry) => entry.event === "menu_sent")?.fields, {
    route: "/menus/send",
    sendId: preview.sendId,
    via: ["email"],
    userId: USER_EVELYN,
  });
});

test("enviar por WhatsApp: el servidor no manda nada; devuelve el texto con el link y el teléfono en E.164", async () => {
  const run = harness();
  const preview = await previewed(run);
  const response = await run.handle(post("/menus/send", { sendId: preview.sendId, whatsapp: true }));
  assert.equal(response.status, 200);
  const body = await json(response);
  assert.deepEqual(Object.keys(body).sort(), ["sentAt", "sentVia", "whatsappPhone", "whatsappText"]);
  assert.deepEqual(body.sentVia, ["whatsapp"]);
  assert.equal(body.whatsappPhone, "+393337654321");
  const token = tokenIn(body.whatsappText);
  assert.ok(token);
  assert.equal(sha256(token), run.store.linkCalls[0]?.p_token_hash);
  assert.equal(body.whatsappText, preview.message.whatsappText.replace("[link personale per confermare]", `https://radicicucina.app/prenotazione/#t=${token}`));
  assert.equal(run.mailer.messages.length, 0);
  assert.deepEqual(run.store.completeCalls[0]?.p_via, ["whatsapp"]);
});

test("enviar por los dos: el email y el texto del WhatsApp con el mismo link; se marca con los dos", async () => {
  const run = harness();
  const preview = await previewed(run);
  const response = await run.handle(post("/menus/send", { sendId: preview.sendId, email: true, whatsapp: true }));
  assert.equal(response.status, 200);
  const body = await json(response);
  assert.deepEqual(body.sentVia, ["email", "whatsapp"]);
  assert.equal(run.mailer.messages.length, 1);
  assert.equal(tokenIn(body.whatsappText), tokenIn(run.mailer.messages[0]?.text ?? ""));
  assert.deepEqual(run.store.completeCalls[0]?.p_via, ["email", "whatsapp"]);
});

test("enviar con EMAIL_TRANSPORT=log: no sale ningún email (ni hace falta Resend), se registra solo el tamaño y se marca", async () => {
  const run = harness({ env: { EMAIL_TRANSPORT: "log", RESEND_API_KEY: undefined }, mailer: null });
  const preview = await previewed(run);
  const response = await run.handle(post("/menus/send", { sendId: preview.sendId, email: true }));
  assert.equal(response.status, 200);
  const entry = run.logs.find((log) => log.event === "email_logged");
  assert.equal(entry?.fields["sendId"], preview.sendId);
  assert.equal(typeof entry?.fields["htmlChars"], "number");
  assert.equal(run.store.completeCalls.length, 1);
});

test("enviar por email sin Resend o sin MAIL_FROM: 503 emailUnavailable sin crear el link; por WhatsApp sale igual", async () => {
  for (const options of [{ mailer: null }, { env: { MAIL_FROM: undefined } }] as const) {
    const run = harness(options);
    const preview = await previewed(run);
    const response = await run.handle(post("/menus/send", { sendId: preview.sendId, email: true, whatsapp: true }));
    assert.equal(response.status, 503, JSON.stringify(options));
    assert.deepEqual(await json(response), { error: "emailUnavailable" });
    assert.equal(run.store.linkCalls.length + run.store.completeCalls.length, 0);
    assert.ok(run.logs.some((entry) => entry.event === "email_skipped" && entry.fields["reason"] === "not_configured"));
    assert.equal((await run.handle(post("/menus/send", { sendId: preview.sendId, whatsapp: true }))).status, 200);
  }
});

test("enviar sin PUBLIC_SITE_URL (o con una que no es http): 500 sin crear el link, y el log dice qué falta", async () => {
  for (const site of [undefined, "javascript:alert(1)"]) {
    const run = harness({ env: { PUBLIC_SITE_URL: site } });
    const preview = await previewed(run);
    const response = await run.handle(post("/menus/send", { sendId: preview.sendId, whatsapp: true }));
    assert.equal(response.status, 500, String(site));
    assert.deepEqual(await json(response), { error: "server" });
    assert.equal(run.store.linkCalls.length, 0);
    assert.ok(run.logs.some((entry) => entry.event === "config_missing" && JSON.stringify(entry.fields["missing"]) === '["PUBLIC_SITE_URL"]'));
  }
});

test("enviar sin email o sin teléfono en el contacto: 409 noEmail / noPhone, sin mandar nada ni marcar", async () => {
  const cases: Array<[string, unknown, Record<string, unknown>, string]> = [
    ["sin email", { ...LINK_CONTACT, email: null }, { email: true }, "noEmail"],
    ["un email sin forma de email", { ...LINK_CONTACT, email: "maria-en-example" }, { email: true }, "noEmail"],
    ["sin teléfono", { ...LINK_CONTACT, phone: null }, { whatsapp: true }, "noPhone"],
    ["un teléfono que no se puede normalizar", { ...LINK_CONTACT, phone: "a la tarde" }, { whatsapp: true }, "noPhone"],
    ["los dos sin teléfono: tampoco sale el email", { ...LINK_CONTACT, phone: null }, { email: true, whatsapp: true }, "noPhone"],
  ];
  for (const [name, contact, channels, error] of cases) {
    const run = harness();
    const preview = await previewed(run);
    run.store.linkContact = contact;
    const response = await run.handle(post("/menus/send", { sendId: preview.sendId, ...channels }));
    assert.equal(response.status, 409, name);
    assert.deepEqual(await json(response), { error }, name);
    assert.equal(run.mailer.messages.length + run.store.completeCalls.length, 0, name);
  }
});

test("enviar con el email que no sale: 502 emailFailed y el envío queda sin marcar; el reintento manda otro link", async () => {
  const run = harness();
  const preview = await previewed(run);
  run.mailer.outcome = { ok: false, status: 422, errorName: "validation_error" };
  const response = await run.handle(post("/menus/send", { sendId: preview.sendId, email: true }));
  assert.equal(response.status, 502);
  assert.deepEqual(await json(response), { error: "emailFailed" });
  assert.equal(run.store.completeCalls.length, 0, "no se marca");
  assert.deepEqual(
    run.logs.find((entry) => entry.event === "email_failed")?.fields,
    { route: "/menus/send", sendId: preview.sendId, status: 422, errorName: "validation_error" },
  );

  run.mailer.outcome = { ok: true, id: "re_2" };
  assert.equal((await run.handle(post("/menus/send", { sendId: preview.sendId, email: true }))).status, 200);
  assert.equal(run.store.linkCalls.length, 2);
  assert.notEqual(run.store.linkCalls[0]?.p_token_hash, run.store.linkCalls[1]?.p_token_hash, "otro token");
  assert.notEqual(run.mailer.messages[0]?.idempotencyKey, run.mailer.messages[1]?.idempotencyKey, "otro email, con otra clave");

  const crash = harness();
  const crashPreview = await previewed(crash);
  crash.mailer.throws = new Error("maria.pii@example.test");
  assert.equal((await crash.handle(post("/menus/send", { sendId: crashPreview.sendId, email: true }))).status, 502);
  assert.equal(crash.store.completeCalls.length, 0);
});

test("enviar con un token repetido (23505): genera otro una vez; si vuelve a chocar, 409", async () => {
  const run = harness();
  const preview = await previewed(run);
  run.store.linkCollisions = 1;
  const response = await run.handle(post("/menus/send", { sendId: preview.sendId, whatsapp: true }));
  assert.equal(response.status, 200);
  const body = await json(response);
  assert.equal(run.store.linkCalls.length, 2);
  assert.notEqual(run.store.linkCalls[0]?.p_token_hash, run.store.linkCalls[1]?.p_token_hash);
  assert.equal(sha256(tokenIn(body.whatsappText) ?? ""), run.store.linkCalls[1]?.p_token_hash, "el link es el del segundo token");
  assert.ok(run.logs.some((entry) => entry.event === "token_collision" && entry.fields["sendId"] === preview.sendId));

  const twice = harness();
  const twicePreview = await previewed(twice);
  twice.store.linkCollisions = 2;
  const conflict = await twice.handle(post("/menus/send", { sendId: twicePreview.sendId, whatsapp: true }));
  assert.equal(conflict.status, 409);
  assert.deepEqual(await json(conflict), { error: "conflict" });
  assert.equal(twice.store.linkCalls.length, 2, "una sola vez otro");
  assert.equal(twice.store.completeCalls.length, 0);
});

test("enviar: los errores de la base al crear el link, traducidos (404, 409, 503); el que ya salió no se vuelve a mandar", async () => {
  const unknown = harness();
  const missing = await unknown.handle(post("/menus/send", { sendId: sendIdOf(7), email: true }));
  assert.equal(missing.status, 404);
  assert.deepEqual(await json(missing), { error: "sendNotFound" });

  const again = harness();
  const preview = await previewed(again);
  assert.equal((await again.handle(post("/menus/send", { sendId: preview.sendId, whatsapp: true }))).status, 200);
  const repeated = await again.handle(post("/menus/send", { sendId: preview.sendId, email: true }));
  assert.equal(repeated.status, 409);
  assert.deepEqual(await json(repeated), { error: "alreadySent" });
  assert.equal(again.mailer.messages.length, 0);

  const cases: Array<[string, Record<string, unknown>, number, unknown]> = [
    ["el menú cambió desde la vista previa", { code: "40001", message: "menu_changed" }, 409, { error: "menuChanged" }],
    ["la sesión se canceló", { code: "55000", message: "session_not_editable", details: "cancelled" }, 409, { error: "sessionNotEditable", status: "cancelled" }],
    ["un estado que no es de sesión en el detalle", { code: "55000", message: "session_not_editable", details: "Mariaxyz" }, 409, { error: "sessionNotEditable" }],
    ["el hash con otra forma (un error de la función)", { code: "22023", message: "invalid_token" }, 500, { error: "server" }],
    ["la base no responde", { code: "", message: "TypeError: fetch failed" }, 503, { error: "unavailable" }],
  ];
  for (const [name, error, status, expected] of cases) {
    const run = harness();
    const sendPreview = await previewed(run);
    run.store.failures.set("link_menu_send", storeErrorFrom("link_menu_send", error));
    const response = await run.handle(post("/menus/send", { sendId: sendPreview.sendId, email: true }));
    assert.equal(response.status, status, name);
    assert.deepEqual(await json(response), expected, name);
    assert.equal(run.mailer.messages.length + run.store.completeCalls.length, 0, name);
  }
});

test("enviar después de mover la semana, cancelar otra o cambiar un plato: 409 menuChanged sin mandar nada (hace falta otra vista previa)", async () => {
  const run = harness();
  const preview = await previewed(run);
  run.store.fingerprint = MOVED_FINGERPRINT;
  const response = await run.handle(post("/menus/send", { sendId: preview.sendId, email: true, whatsapp: true }));
  assert.equal(response.status, 409);
  assert.deepEqual(await json(response), { error: "menuChanged" });
  assert.equal(run.mailer.messages.length + run.store.completeCalls.length, 0);

  // Con otra vista previa (armada con la huella de ahora) sale.
  run.store.menuContext = menuContextRpc({ fingerprint: MOVED_FINGERPRINT });
  const again = await previewed(run);
  assert.equal((await run.handle(post("/menus/send", { sendId: again.sendId, whatsapp: true }))).status, 200);

  // Si cambia justo mientras sale el email: no se marca y la respuesta dice que el email salió.
  const during = harness();
  const duringPreview = await previewed(during);
  during.mailer.during = () => {
    during.store.fingerprint = MOVED_FINGERPRINT;
  };
  const late = await during.handle(post("/menus/send", { sendId: duringPreview.sendId, email: true }));
  assert.equal(late.status, 409);
  assert.deepEqual(await json(late), { error: "menuChanged", emailSent: true });
  assert.ok(during.logs.some((entry) => entry.event === "menu_send_incomplete"));
});

test("enviar: si el email salió pero no se puede marcar, la respuesta lo dice (emailSent) y el log, menu_send_incomplete", async () => {
  const cases: Array<[string, Record<string, unknown>, number, unknown]> = [
    ["el menú cambió mientras salía el email", { code: "40001", message: "menu_changed" }, 409, { error: "menuChanged", emailSent: true }],
    ["la base no responde", { code: "", message: "TypeError: fetch failed" }, 503, { error: "unavailable", emailSent: true }],
    ["los canales (un error de la función)", { code: "22023", message: "invalid_via" }, 500, { error: "server", emailSent: true }],
  ];
  for (const [name, error, status, expected] of cases) {
    const run = harness();
    const preview = await previewed(run);
    run.store.failures.set("complete_menu_send", storeErrorFrom("complete_menu_send", error));
    const response = await run.handle(post("/menus/send", { sendId: preview.sendId, email: true }));
    assert.equal(response.status, status, name);
    assert.deepEqual(await json(response), expected, name);
    assert.equal(run.mailer.messages.length, 1);
    const entry = run.logs.find((log) => log.event === "menu_send_incomplete");
    assert.equal(entry?.level, "error", name);
    assert.equal(entry?.fields["sendId"], preview.sendId);
  }

  // Solo por WhatsApp no salió nada: el error de siempre, sin emailSent.
  const whatsapp = harness();
  const preview = await previewed(whatsapp);
  whatsapp.store.failures.set("complete_menu_send", storeErrorFrom("complete_menu_send", { code: "", message: "fetch failed" }));
  const response = await whatsapp.handle(post("/menus/send", { sendId: preview.sendId, whatsapp: true }));
  assert.equal(response.status, 503);
  assert.deepEqual(await json(response), { error: "unavailable" });

  // Una respuesta con otra forma después del email: 500 con emailSent.
  const shape = harness();
  const shapePreview = await previewed(shape);
  shape.store.completeRaw = { sent_at: "ayer" };
  const shapeResponse = await shape.handle(post("/menus/send", { sendId: shapePreview.sendId, email: true }));
  assert.equal(shapeResponse.status, 500);
  assert.deepEqual(await json(shapeResponse), { error: "server", emailSent: true });
  assert.ok(shape.logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "complete_menu_send"));
});

test("enviar: el link o la foto con otra forma, 500 sin mandar nada", async () => {
  const link = harness();
  const preview = await previewed(link);
  link.store.linkRaw = { sendId: preview.sendId };
  assert.equal((await link.handle(post("/menus/send", { sendId: preview.sendId, email: true }))).status, 500);
  assert.ok(link.logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "link_menu_send"));

  const other = harness();
  const otherPreview = await previewed(other);
  other.store.linkRaw = { sendId: sendIdOf(5), locale: "it", snapshot: {}, contact: LINK_CONTACT, chefName: "Evelyn" };
  assert.equal((await other.handle(post("/menus/send", { sendId: otherPreview.sendId, email: true }))).status, 500, "otro envío");

  const snapshot = harness();
  const snapshotPreview = await previewed(snapshot);
  snapshot.store.linkRaw = { sendId: snapshotPreview.sendId, locale: "it", snapshot: { v: 2 }, contact: LINK_CONTACT, chefName: "Evelyn" };
  assert.equal((await snapshot.handle(post("/menus/send", { sendId: snapshotPreview.sendId, email: true }))).status, 500);
  assert.ok(snapshot.logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "menu_snapshot"));
  for (const run of [link, other, snapshot]) assert.equal(run.mailer.messages.length + run.store.completeCalls.length, 0);
});

test("enviar: 400 sin canal, con un canal que no es booleano o con una clave de más, sin tocar la base", async () => {
  const run = harness();
  const cases: Array<[unknown, unknown]> = [
    [{ sendId: sendIdOf(0) }, { errors: { channels: "required" } }],
    [{ sendId: sendIdOf(0), email: false, whatsapp: false }, { errors: { channels: "required" } }],
    [{ sendId: sendIdOf(0), email: "true" }, { errors: { email: "invalid" } }],
    [{ sendId: sendIdOf(0), email: true, to: "otra@example.test" }, { errors: { payload: "invalid" } }],
    [{ email: true }, { errors: { sendId: "required" } }],
  ];
  for (const [body, expected] of cases) {
    const response = await run.handle(post("/menus/send", body));
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.deepEqual(await json(response), expected);
  }
  assert.equal(run.store.linkCalls.length, 0);
});

test("menús sin token válido: 401 sin leer el cuerpo; un colaborador trabaja con la cocina de ella y queda en el log", async () => {
  const auth = harness();
  for (const [route, body] of [
    ["/menus/preview", previewBody()],
    ["/menus/send", { sendId: sendIdOf(0), email: true }],
  ] as const) {
    const request = post(route, body, { token: null });
    assert.equal((await auth.handle(request)).status, 401, route);
    assert.equal(request.bodyUsed, false);
  }
  assert.equal(auth.store.contextCalls.length + auth.store.linkCalls.length, 0);

  const member = harness();
  const preview = await member.handle(post("/menus/preview", previewBody(), { token: TOKEN_MEMBER }));
  assert.equal(preview.status, 200);
  const { sendId } = await json(preview);
  assert.equal((await member.handle(post("/menus/send", { sendId, email: true, whatsapp: true }, { token: TOKEN_MEMBER }))).status, 200);
  assert.deepEqual(
    [member.store.contextCalls[0]?.p_chef_id, member.store.prepareCalls[0]?.p_chef_id, member.store.linkCalls[0]?.p_chef_id, member.store.completeCalls[0]?.p_chef_id],
    [CHEF_ID, CHEF_ID, CHEF_ID, CHEF_ID],
  );
  assert.equal(member.store.rateHits[0]?.key, await translateRateKey(CHEF_ID));
  for (const event of ["menu_previewed", "menu_sent", "translated"]) {
    assert.equal(member.logs.find((entry) => entry.event === event)?.fields["userId"], USER_MEMBER, event);
  }
});

test("los logs del envío del menú nunca llevan nombres, emails, teléfonos, platos, la lista, la nota, fechas ni el link", async () => {
  const runs: Harness[] = [];
  const tokens: string[] = [];
  const hashes: string[] = [];
  const track = (run: Harness): Harness => {
    runs.push(run);
    return run;
  };

  // Lo que sale bien: vista previa traducida y envío por los dos.
  const ok = track(harness());
  const preview = await previewed(ok);
  const sent = await ok.handle(post("/menus/send", { sendId: preview.sendId, email: true, whatsapp: true }));
  const token = tokenIn((await json(sent)).whatsappText);
  if (token) tokens.push(token);

  // Con EMAIL_TRANSPORT=log, un email que no sale y un token repetido.
  const logged = track(harness({ env: { EMAIL_TRANSPORT: "log" } }));
  await logged.handle(post("/menus/send", { sendId: (await previewed(logged)).sendId, email: true }));
  const failed = track(harness());
  failed.mailer.outcome = { ok: false, status: 500, errorName: "application_error" };
  await failed.handle(post("/menus/send", { sendId: (await previewed(failed)).sendId, email: true }));
  failed.mailer.throws = new Error("maria.pii@example.test Mariaxyz");
  await failed.handle(post("/menus/send", { sendId: (await previewed(failed)).sendId, email: true }));
  const collision = track(harness());
  collision.store.linkCollisions = 1;
  await collision.handle(post("/menus/send", { sendId: (await previewed(collision)).sendId, whatsapp: true }));

  // Sin Resend, sin web, sin contacto, ya enviado, y la base que falla con la fila en el mensaje.
  const noMailer = track(harness({ mailer: null }));
  await noMailer.handle(post("/menus/send", { sendId: (await previewed(noMailer)).sendId, email: true }));
  const noSite = track(harness({ env: { PUBLIC_SITE_URL: undefined } }));
  await noSite.handle(post("/menus/send", { sendId: (await previewed(noSite)).sendId, email: true }));
  const noContact = track(harness());
  noContact.store.linkContact = { name: "Mariaxyz Bianchiqwe", email: null, phone: null };
  await noContact.handle(post("/menus/send", { sendId: (await previewed(noContact)).sendId, email: true }));
  await noContact.handle(post("/menus/send", { sendId: (await previewed(noContact)).sendId, whatsapp: true }));
  const dbErrors = track(harness());
  dbErrors.store.failures.set(
    "complete_menu_send",
    storeErrorFrom("complete_menu_send", {
      code: "23514",
      message: "violates check constraint: Mariaxyz",
      details: "Failing row contains (Mariaxyz, maria.pii@example.test, NOTA-MENU-qqq, 2026-11-30).",
    }),
  );
  await dbErrors.handle(post("/menus/send", { sendId: (await previewed(dbErrors)).sendId, email: true }));
  dbErrors.store.failures.set("menu_send_context", storeErrorFrom("menu_send_context", { code: "P0002", message: "session_not_found", details: "Mariaxyz" }));
  await dbErrors.handle(post("/menus/preview", previewBody()));
  const down = track(harness());
  down.store.failures.set("prepare_menu_send", storeErrorFrom("prepare_menu_send", { code: "08006", message: "connection failure: Mariaxyz" }));
  await down.handle(post("/menus/preview", previewBody()));

  // La traducción que falla o devuelve el texto de vuelta, el límite y sin traductor.
  const translation = track(harness());
  for (const reply of [
    { kind: "refusal", category: "cyber" },
    { kind: "failed", reason: "timeout", status: null },
    { kind: "text", text: JSON.stringify({ items: ["Zapallitoszzz"], note: MENU_NOTE }) },
  ] as TranslatorReply[]) {
    translation.translator.menuReply = reply;
    await translation.handle(post("/menus/preview", previewBody()));
  }
  translation.translator.throws = new Error("Zapallitoszzz NOTA-MENU-qqq");
  await translation.handle(post("/menus/preview", previewBody()));
  translation.store.rateAllowed = false;
  await translation.handle(post("/menus/preview", previewBody()));
  const noTranslator = track(harness({ translator: null }));
  await noTranslator.handle(post("/menus/preview", previewBody()));
  const invalid = track(harness());
  await invalid.handle(post("/menus/preview", { sessionId: "Mariaxyz", menuVersion: "NOTA-MENU-qqq" }));
  await invalid.handle(post("/menus/send", { sendId: SESSION_ID, email: true, to: "maria.pii@example.test" }));

  for (const run of runs) for (const call of run.store.linkCalls) hashes.push(call.p_token_hash);
  assert.ok(tokens.length > 0 && hashes.length > 0);
  const markers = [
    "Mariaxyz", "Bianchiqwe", "maria.pii", "765", "4321", "Milanesaxyz", "napoletana", "DescripQwe", "Zapallitoszzz",
    "NOTA-MENU", "táperes", "Segretissima", "NOTA-SALUD", "2026-11-30", "2026-12-07", "prenotazione", "evelyn.reply",
    "ciao@radicicucina", ...tokens, ...hashes,
  ];
  for (const run of runs) {
    const text = JSON.stringify(run.logs);
    assert.ok(run.logs.length > 0);
    for (const marker of markers) assert.ok(!text.includes(marker), `el log lleva ${marker}: ${text}`);
  }
  const events = new Set(runs.flatMap((run) => run.logs.map((entry) => entry.event)));
  for (const event of [
    "menu_previewed", "menu_sent", "email_sent", "email_logged", "email_failed", "email_skipped", "token_collision",
    "menu_send_incomplete", "translated", "translate_failed", "rate_limited", "rejected", "db_error", "config_missing",
    "invalid_payload",
  ]) {
    assert.ok(events.has(event), `falta el camino ${event}`);
  }
});

test("index.ts: las cuatro funciones del envío con la clave secreta, sus errores sin datos, y el email con Resend", () => {
  const index = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  for (const [fn, op] of [
    ["chef_menu_send_context", "menu_send_context"],
    ["chef_prepare_menu_send", "prepare_menu_send"],
    ["chef_link_menu_send", "link_menu_send"],
    ["chef_complete_menu_send", "complete_menu_send"],
  ]) {
    assert.match(
      index,
      new RegExp(`const \\{ data, error \\} = await supabase\\.rpc\\("${fn}", params\\);\\s*if \\(error\\) throw storeErrorFrom\\("${op}", error\\);\\s*return data;`),
      fn,
    );
  }
  assert.match(index, /return \{ send: \(message\) => sendWithResend\(message, \{ apiKey \}\) \};/);
  assert.match(index, /mailer: createMailer\(\),/);
  for (const line of index.split("\n").filter((text) => /consoleLogger|console\./.test(text))) {
    assert.ok(!/apiKey|RESEND_API_KEY"\)/.test(line), `un log con la clave: ${line.trim()}`);
  }
});

// ---------------------------------------------------------------------------
// El presupuesto: POST /quotes, /quotes/price y /quotes/withdraw (§14)
// ---------------------------------------------------------------------------

/** Preparar el presupuesto de un pedido de la bandeja: 4 semanas, 560 € de servicio. */
function quoteBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { requestId: REQUEST_ID, dates: FOUR_MONDAYS, start: "10:00", cookMinutes: 240, portions: 50, serviceTotalCents: 56000, ...overrides };
}

/** Un harness con el presupuesto ya preparado (la base simulada lo guarda). */
async function withQuote(options: Parameters<typeof harness>[0] = {}): Promise<Harness> {
  const run = harness(options);
  assert.equal((await run.handle(post("/quotes", quoteBody()))).status, 201, "el presupuesto");
  return run;
}

test("preparar el presupuesto: 201 con las semanas retenidas, sus sesiones y el plazo del borrador; la base recibe la cocina del token", async () => {
  const { handle, store, logs } = harness();
  const response = await handle(post("/quotes", quoteBody({ requestId: REQUEST_ID.toUpperCase() })));
  assert.equal(response.status, 201);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await json(response), {
    dryRun: false,
    quoteId: QUOTE_ID,
    requestId: REQUEST_ID,
    clientId: CLIENT_ID,
    holdUntil: "2026-11-17T10:00:00.123456+00:00",
    weeks: FOUR_MONDAYS.map((date, i) => ({ date, start: "10:00", cookMinutes: 240, status: "free", suggestedStart: null, serviceCents: 14000, sessionId: sessionId(i) })),
  });
  assert.deepEqual(store.createQuoteCalls, [
    {
      p_chef_id: CHEF_ID,
      p_request_id: REQUEST_ID,
      p_dates: FOUR_MONDAYS,
      p_start: "10:00",
      p_cook_minutes: 240,
      p_service_total_cents: 56000,
      p_portions: 50,
      p_dry_run: false,
    },
  ]);
  assert.deepEqual(logs.find((entry) => entry.event === "quote_created")?.fields, { requestId: REQUEST_ID, quoteId: QUOTE_ID, sessions: 4, userId: USER_EVELYN });
});

test("presupuesto en dryRun: 200 con el estado de cada fecha, sin hora ni precio, y sin escribir nada", async () => {
  const { handle, store, logs } = harness();
  store.dayStatus.set("2026-11-30", "busy");
  const response = await handle(post("/quotes", { requestId: REQUEST_ID, dates: FOUR_MONDAYS, cookMinutes: 240, dryRun: true }));
  assert.equal(response.status, 200);
  const body = await json(response);
  assert.equal(body.dryRun, true);
  assert.equal(body.quoteId, null);
  assert.equal(body.holdUntil, null);
  assert.deepEqual(
    body.weeks.map((week: { status: string; sessionId: string | null; start: string }) => [week.status, week.sessionId, week.start]),
    [
      ["ok", null, "09:00"],
      ["busy", null, "09:00"],
      ["ok", null, "09:00"],
      ["ok", null, "09:00"],
    ],
  );
  assert.equal(store.createQuoteCalls[0]?.p_start, null);
  assert.equal(store.createQuoteCalls[0]?.p_service_total_cents, 0);
  assert.equal(store.writes, 0);
  assert.ok(!logs.some((entry) => entry.event === "quote_created"));
});

test("presupuesto: 400 por campo (con la fecha del error) o con una clave de más, sin llamar a la base", async () => {
  const { handle, store, logs } = harness();
  const cases: Array<[Record<string, unknown>, unknown]> = [
    [quoteBody({ dates: ["2026-11-23", "2026-11-25"] }), { errors: { dates: "sameWeek" }, date: "2026-11-25" }],
    [quoteBody({ serviceTotalCents: undefined }), { errors: { serviceTotalCents: "required" } }],
    [quoteBody({ start: "25:00", cookMinutes: 0 }), { errors: { start: "invalid", cookMinutes: "range" } }],
    [quoteBody({ requestId: undefined }), { errors: { requestId: "required" } }],
    [quoteBody({ type: "week" }), { errors: { payload: "invalid" } }],
    [quoteBody({ chefId: "cef00000-0000-4000-8000-000000000099" }), { errors: { payload: "invalid" } }],
  ];
  for (const [body, expected] of cases) {
    const response = await handle(post("/quotes", body));
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.deepEqual(await json(response), expected);
  }
  assert.equal(store.createQuoteCalls.length, 0);
  assert.ok(logs.some((entry) => entry.event === "invalid_payload" && entry.fields["route"] === "/quotes"));
});

test("presupuesto: los errores de la base, traducidos (404, 409, 400, 500, 503); una respuesta con otra forma, 500", async () => {
  const cases: Array<[string, Record<string, unknown>, number, unknown]> = [
    ["pedido de otra cocina", { code: "P0002", message: "request_not_found" }, 404, { error: "requestNotFound" }],
    ["el pedido ya no está new", { code: "55000", message: "request_not_new", details: "quoted" }, 409, { error: "requestNotNew", status: "quoted" }],
    ["ya tiene un presupuesto abierto", { code: "55000", message: "quote_exists" }, 409, { error: "quoteExists" }],
    ["un pedido de cambios", { code: "22023", message: "invalid_request_type" }, 409, { error: "requestNotQuotable" }],
    ["varias semanas en uno extra", { code: "22023", message: "weeks_only_for_week" }, 400, { errors: { dates: "weeksOnlyForWeek" } }],
    ["horario ocupado", { code: "23P01", message: "slot_taken", details: "2026-11-30" }, 409, { error: "slotTaken", date: "2026-11-30" }],
    ["semana ocupada", { code: "23505", message: "week_taken", details: "2026-12-07" }, 409, { error: "weekTaken", date: "2026-12-07" }],
    ["cocinera sin chef_settings", { code: "P0002", message: "chef_not_found" }, 500, { error: "server" }],
    ["la base no responde", { code: "", message: "TypeError: fetch failed" }, 503, { error: "unavailable" }],
    ["la función no está desplegada", { code: "PGRST202", message: "Could not find the function" }, 500, { error: "server" }],
  ];
  for (const [name, error, status, expected] of cases) {
    const run = harness();
    run.store.failures.set("create_quote", storeErrorFrom("create_quote", error));
    const response = await run.handle(post("/quotes", quoteBody()));
    assert.equal(response.status, status, name);
    assert.deepEqual(await json(response), expected, name);
    if (status < 500) assert.ok(run.logs.some((entry) => entry.event === "rejected" && entry.fields["route"] === "/quotes"), name);
    else assert.ok(run.logs.some((entry) => entry.event === "db_error" && entry.fields["op"] === "create_quote"), name);
  }

  for (const raw of [{ dry_run: false }, { dry_run: true, quote_id: null, request_id: REQUEST_ID, client_id: CLIENT_ID, hold_until: null, weeks: [] }]) {
    const shape = harness();
    shape.store.quoteRaw = raw;
    assert.equal((await shape.handle(post("/quotes", quoteBody()))).status, 500, JSON.stringify(raw));
    assert.ok(shape.logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "create_quote"));
  }
  // Un dryRun que vuelve como creado (o al revés) no se entiende.
  const mismatch = harness();
  const created = await mismatch.store.createQuote({
    p_chef_id: CHEF_ID,
    p_request_id: REQUEST_ID,
    p_dates: ["2026-11-23"],
    p_start: "10:00",
    p_cook_minutes: 240,
    p_service_total_cents: 15000,
    p_portions: 0,
    p_dry_run: false,
  });
  mismatch.store.quoteRaw = created;
  assert.equal((await mismatch.handle(post("/quotes", quoteBody({ dryRun: true })))).status, 500);
});

test("otro precio: 200 con los términos nuevos, repartidos entre las semanas; la base recibe la cocina del token", async () => {
  const run = await withQuote();
  const response = await run.handle(post("/quotes/price", { quoteId: QUOTE_ID.toUpperCase(), serviceTotalCents: 42001 }));
  assert.equal(response.status, 200);
  assert.deepEqual(await json(response), {
    quoteId: QUOTE_ID,
    totalCents: 42001,
    weeks: FOUR_MONDAYS.map((date, i) => ({ sessionId: sessionId(i), date, start: "10:00", cookMinutes: 240, serviceCents: i === 0 ? 10501 : 10500 })),
  });
  assert.deepEqual(run.store.updateQuoteCalls, [{ p_chef_id: CHEF_ID, p_quote_id: QUOTE_ID, p_service_total_cents: 42001 }]);
  assert.deepEqual(run.logs.find((entry) => entry.event === "quote_priced")?.fields, { quoteId: QUOTE_ID, weeks: 4, userId: USER_EVELYN });
});

test("otro precio: 404 quoteNotFound, 409 quoteClosed y quoteEmpty, 400 por campo; una respuesta que no es lo pedido, 500", async () => {
  const missing = harness();
  const notFound = await missing.handle(post("/quotes/price", { quoteId: QUOTE_ID, serviceTotalCents: 100 }));
  assert.deepEqual([notFound.status, await json(notFound)], [404, { error: "quoteNotFound" }]);

  const cases: Array<[Record<string, unknown>, number, unknown]> = [
    [{ code: "55000", message: "quote_closed" }, 409, { error: "quoteClosed" }],
    [{ code: "55000", message: "quote_empty" }, 409, { error: "quoteEmpty" }],
    [{ code: "22023", message: "invalid_cents" }, 400, { errors: { cents: "range" } }],
  ];
  for (const [error, status, expected] of cases) {
    const run = await withQuote();
    run.store.failures.set("update_quote", storeErrorFrom("update_quote", error));
    const response = await run.handle(post("/quotes/price", { quoteId: QUOTE_ID, serviceTotalCents: 100 }));
    assert.deepEqual([response.status, await json(response)], [status, expected], JSON.stringify(error));
  }

  const invalid = harness();
  const bad = await invalid.handle(post("/quotes/price", { quoteId: "x" }));
  assert.deepEqual([bad.status, await json(bad)], [400, { errors: { quoteId: "invalid", serviceTotalCents: "required" } }]);
  assert.equal(invalid.store.updateQuoteCalls.length, 0);

  // La base devuelve otro total (o los términos de otro presupuesto): no se entiende.
  for (const raw of [
    { quoteId: QUOTE_ID, totalCents: 0, weeks: [] },
    { quoteId: SESSION_ID, totalCents: 100, weeks: [{ sessionId: SESSION_ID, date: "2026-11-23", start: "10:00", cookMinutes: 240, serviceCents: 100 }] },
  ]) {
    const shape = await withQuote();
    shape.store.quoteRaw = raw;
    assert.equal((await shape.handle(post("/quotes/price", { quoteId: QUOTE_ID, serviceTotalCents: 100 }))).status, 500, JSON.stringify(raw));
    assert.ok(shape.logs.some((entry) => entry.event === "unexpected_result" && entry.fields["op"] === "update_quote"));
  }
});

test("retirar: 200 con las semanas canceladas; otra vez, already; 404 quoteNotFound y 409 quoteClosed", async () => {
  const run = await withQuote();
  const first = await run.handle(post("/quotes/withdraw", { quoteId: QUOTE_ID }));
  assert.equal(first.status, 200);
  assert.deepEqual(await json(first), { quoteId: QUOTE_ID, requestId: REQUEST_ID, already: false, cancelled: 4 });
  const again = await run.handle(post("/quotes/withdraw", { quoteId: QUOTE_ID }));
  assert.deepEqual(await json(again), { quoteId: QUOTE_ID, requestId: REQUEST_ID, already: true, cancelled: 0 });
  assert.deepEqual(run.store.withdrawQuoteCalls[0], { p_chef_id: CHEF_ID, p_quote_id: QUOTE_ID });
  assert.deepEqual(run.logs.find((entry) => entry.event === "quote_withdrawn")?.fields, {
    quoteId: QUOTE_ID,
    requestId: REQUEST_ID,
    already: false,
    cancelled: 4,
    userId: USER_EVELYN,
  });

  const missing = harness();
  const notFound = await missing.handle(post("/quotes/withdraw", { quoteId: QUOTE_ID }));
  assert.deepEqual([notFound.status, await json(notFound)], [404, { error: "quoteNotFound" }]);
  const closed = await withQuote();
  closed.store.failures.set("withdraw_quote", storeErrorFrom("withdraw_quote", { code: "55000", message: "quote_closed" }));
  const refused = await closed.handle(post("/quotes/withdraw", { quoteId: QUOTE_ID }));
  assert.deepEqual([refused.status, await json(refused)], [409, { error: "quoteClosed" }]);
  const extra = await closed.handle(post("/quotes/withdraw", { quoteId: QUOTE_ID, reason: "otro" }));
  assert.deepEqual([extra.status, await json(extra)], [400, { errors: { payload: "invalid" } }]);
  const shape = await withQuote();
  shape.store.quoteRaw = { quote_id: QUOTE_ID };
  assert.equal((await shape.handle(post("/quotes/withdraw", { quoteId: QUOTE_ID }))).status, 500);
});

test("presupuesto sin token válido: 401 sin leer el cuerpo; un colaborador trabaja con la cocina de ella y queda en el log", async () => {
  const auth = harness();
  for (const [route, body] of [
    ["/quotes", quoteBody()],
    ["/quotes/price", { quoteId: QUOTE_ID, serviceTotalCents: 1 }],
    ["/quotes/withdraw", { quoteId: QUOTE_ID }],
  ] as const) {
    const request = post(route, body, { token: null });
    assert.equal((await auth.handle(request)).status, 401, route);
    assert.equal(request.bodyUsed, false);
  }
  assert.equal(auth.store.createQuoteCalls.length + auth.store.updateQuoteCalls.length + auth.store.withdrawQuoteCalls.length, 0);

  const member = harness();
  assert.equal((await member.handle(post("/quotes", quoteBody(), { token: TOKEN_MEMBER }))).status, 201);
  assert.equal((await member.handle(post("/quotes/price", { quoteId: QUOTE_ID, serviceTotalCents: 50000 }, { token: TOKEN_MEMBER }))).status, 200);
  assert.equal((await member.handle(post("/quotes/withdraw", { quoteId: QUOTE_ID }, { token: TOKEN_MEMBER }))).status, 200);
  assert.deepEqual(
    [member.store.createQuoteCalls[0]?.p_chef_id, member.store.updateQuoteCalls[0]?.p_chef_id, member.store.withdrawQuoteCalls[0]?.p_chef_id],
    [CHEF_ID, CHEF_ID, CHEF_ID],
  );
  for (const event of ["quote_created", "quote_priced", "quote_withdrawn"]) {
    assert.equal(member.logs.find((entry) => entry.event === event)?.fields["userId"], USER_MEMBER, event);
  }
});

// ---------------------------------------------------------------------------
// El menú de la semana 1 con el presupuesto (§13 y §14)
// ---------------------------------------------------------------------------

/** chef_menu_send_context de la semana 1 held de un presupuesto abierto (2 semanas, 300 €). */
function quoteContextRpc(quote: Record<string, unknown> = {}): Record<string, unknown> {
  const base = menuContextRpc();
  return {
    ...base,
    session: { ...(base["session"] as Record<string, unknown>), status: "held" },
    quote: {
      id: QUOTE_ID,
      version: 1,
      sent: false,
      holdUntil: "2026-11-17T10:00:00.123456+00:00",
      holdHours: 48,
      firstWeek: true,
      terms: {
        quoteId: QUOTE_ID,
        totalCents: 30000,
        weeks: [
          { sessionId: SESSION_ID, date: "2026-11-30", start: "10:00", cookMinutes: 240, serviceCents: 15000 },
          { sessionId: OTHER_SESSION_ID, date: "2026-12-07", start: "10:00", cookMinutes: 240, serviceCents: 15000 },
        ],
      },
      ...quote,
    },
  };
}

test("vista previa de la semana 1 de un presupuesto: la foto lleva el presupuesto y el mensaje lo presenta, sin pagos", async () => {
  const run = harness();
  run.store.menuContext = quoteContextRpc();
  const body = await previewed(run);
  assert.deepEqual(run.store.prepareCalls[0]?.p_snapshot.quote, {
    version: 1,
    totalCents: 30000,
    weeks: [
      { date: "2026-11-30", start: "10:00", serviceCents: 15000 },
      { date: "2026-12-07", start: "10:00", serviceCents: 15000 },
    ],
    holdHours: 48,
    firstStart: "2026-11-30T10:00",
  });
  assert.equal(body.message.subject, "Radici: il tuo preventivo e il menù del 30 nov");
  for (const text of [body.message.emailText, body.message.whatsappText]) {
    for (const expected of [
      "Evelyn ha preparato il preventivo per le tue 2 settimane e il menù della prima.",
      "Settimana 1: lunedì 30 novembre 2026, arrivo alle 10:00",
      "Settimana 2: lunedì 7 dicembre 2026, arrivo alle 10:00",
      "300,00 € in totale (150,00 € a settimana)",
      "Accettalo entro 48 ore.",
      "[link personale per confermare]",
    ]) {
      assert.ok(text.includes(expected), `falta: ${expected}\n${text}`);
    }
    assert.ok(!/pagament|bonifico|contanti|carta di credito/i.test(text));
  }
  assert.ok(body.message.emailText.includes("Vedi e accetta il preventivo: [link personale per confermare]"));
  // Un reenvío: la versión que va a salir.
  const resent = harness();
  resent.store.menuContext = quoteContextRpc({ version: 2, sent: true });
  const again = await previewed(resent);
  assert.equal(resent.store.prepareCalls[0]?.p_snapshot.quote?.version, 3);
  assert.equal(again.message.subject, "Radici: il preventivo aggiornato e il menù del 30 nov");
});

test("vista previa de una semana held: sin su presupuesto abierto, 409 quoteClosed; si no es la primera, quoteWeekNotFirst; sin traducir ni guardar", async () => {
  const closedContext = quoteContextRpc();
  delete closedContext["quote"];
  const cases: Array<[string, Record<string, unknown>, string]> = [
    ["el presupuesto ya no está abierto", closedContext, "quoteClosed"],
    [
      "no es la primera semana",
      quoteContextRpc({
        firstWeek: false,
        terms: {
          quoteId: QUOTE_ID,
          totalCents: 30000,
          weeks: [
            { sessionId: OTHER_SESSION_ID, date: "2026-11-23", start: "10:00", cookMinutes: 240, serviceCents: 15000 },
            { sessionId: SESSION_ID, date: "2026-11-30", start: "10:00", cookMinutes: 240, serviceCents: 15000 },
          ],
        },
      }),
      "quoteWeekNotFirst",
    ],
  ];
  for (const [name, context, error] of cases) {
    const run = harness();
    run.store.menuContext = context;
    const response = await run.handle(post("/menus/preview", previewBody()));
    assert.equal(response.status, 409, name);
    assert.deepEqual(await json(response), { error }, name);
    assert.equal(run.translator.menuCalls.length + run.store.rateHits.length + run.store.prepareCalls.length, 0, `${name}: sin traducir ni guardar`);
    assert.ok(run.logs.some((entry) => entry.event === "rejected" && entry.fields["error"] === error), name);
  }
});

test("vista previa y envío: los errores del presupuesto de la base, traducidos (quote_week_not_first, quote_closed, quote_changed)", async () => {
  const previewCases: Array<[Record<string, unknown>, unknown]> = [
    [{ code: "55000", message: "quote_week_not_first" }, { error: "quoteWeekNotFirst" }],
    [{ code: "55000", message: "quote_closed" }, { error: "quoteClosed" }],
    [{ code: "40001", message: "quote_changed" }, { error: "quoteChanged" }],
  ];
  for (const [error, expected] of previewCases) {
    const run = harness();
    run.store.menuContext = quoteContextRpc();
    run.store.failures.set("prepare_menu_send", storeErrorFrom("prepare_menu_send", error));
    const response = await run.handle(post("/menus/preview", previewBody({ translate: false })));
    assert.deepEqual([response.status, await json(response)], [409, expected], JSON.stringify(error));
  }

  // Al crear el link: el presupuesto cambió (otro precio, una semana movida) o se cerró: no sale nada.
  for (const [error, expected] of [
    [{ code: "40001", message: "quote_changed" }, { error: "quoteChanged" }],
    [{ code: "55000", message: "quote_closed" }, { error: "quoteClosed" }],
  ] as const) {
    const run = harness();
    run.store.menuContext = quoteContextRpc();
    const preview = await previewed(run);
    run.store.failures.set("link_menu_send", storeErrorFrom("link_menu_send", error));
    const response = await run.handle(post("/menus/send", { sendId: preview.sendId, email: true }));
    assert.deepEqual([response.status, await json(response)], [409, expected], JSON.stringify(error));
    assert.equal(run.mailer.messages.length, 0, "sin email");
    assert.equal(run.store.completeCalls.length, 0);
  }

  // El email salió y justo cambió el presupuesto: la respuesta lo dice (emailSent) y hace falta otra vista previa.
  const late = harness();
  late.store.menuContext = quoteContextRpc();
  const preview = await previewed(late);
  late.store.failures.set("complete_menu_send", storeErrorFrom("complete_menu_send", { code: "40001", message: "quote_changed" }));
  const response = await late.handle(post("/menus/send", { sendId: preview.sendId, email: true }));
  assert.deepEqual([response.status, await json(response)], [409, { error: "quoteChanged", emailSent: true }]);
  assert.ok(late.logs.some((entry) => entry.event === "menu_send_incomplete" && entry.fields["message"] === "quote_changed"));
});

test("enviar el presupuesto con la semana 1: el email lleva el presupuesto, el plazo de ahora y el botón para aceptarlo", async () => {
  // Sábado 28/11 a las 20:00 en Roma: la primera llegada (lunes 30 a las 10:00) está a menos de 48 horas.
  const run = harness({ now: () => new Date("2026-11-28T19:00:00Z") });
  run.store.menuContext = quoteContextRpc();
  const preview = await previewed(run);
  assert.ok(preview.message.emailText.includes("Accettalo prima di lunedì 30 novembre 2026, alle 10:00."), "la vista previa ya lo dice");
  const response = await run.handle(post("/menus/send", { sendId: preview.sendId, email: true, whatsapp: true }));
  assert.equal(response.status, 200);
  const body = await json(response);
  const [email] = run.mailer.messages;
  assert.ok(email);
  assert.equal(email.subject, "Radici: il tuo preventivo e il menù del 30 nov");
  for (const text of [email.text, body.whatsappText]) {
    assert.ok(text.includes("Prezzo del servizio") && text.includes("300,00 € in totale (150,00 € a settimana)"), text);
    assert.ok(text.includes("Accettalo prima di lunedì 30 novembre 2026, alle 10:00."), text);
    assert.ok(tokenIn(text), "con el link");
  }
  assert.ok(email.text.includes("Vedi e accetta il preventivo: https://radicicucina.app/prenotazione/#t="));
  assert.ok(email.html.includes(">Vedi e accetta il preventivo</a>"));
  assert.equal(tokenIn(email.text), tokenIn(body.whatsappText), "el mismo link");
});

test("los logs del presupuesto nunca llevan nombres, fechas, importes ni el texto del mensaje", async () => {
  const runs: Harness[] = [];
  const track = (run: Harness): Harness => {
    runs.push(run);
    return run;
  };
  const ok = track(await withQuote());
  await ok.handle(post("/quotes", { requestId: REQUEST_ID, dates: FOUR_MONDAYS, cookMinutes: 240, dryRun: true }));
  await ok.handle(post("/quotes/price", { quoteId: QUOTE_ID, serviceTotalCents: 42001 }));
  await ok.handle(post("/quotes/withdraw", { quoteId: QUOTE_ID }));
  const errors = track(harness());
  errors.store.failures.set(
    "create_quote",
    storeErrorFrom("create_quote", {
      code: "23514",
      message: "violates check constraint: Mariaxyz",
      details: "Failing row contains (Mariaxyz, 2026-11-23, 56000).",
    }),
  );
  await errors.handle(post("/quotes", quoteBody()));
  errors.store.failures.set("create_quote", storeErrorFrom("create_quote", { code: "23P01", message: "slot_taken", details: "Mariaxyz 2026-11-30" }));
  await errors.handle(post("/quotes", quoteBody()));
  errors.store.failures.set("update_quote", storeErrorFrom("update_quote", { code: "08006", message: "connection failure: Mariaxyz" }));
  await errors.handle(post("/quotes/price", { quoteId: QUOTE_ID, serviceTotalCents: 42001 }));
  const invalid = track(harness());
  await invalid.handle(post("/quotes", quoteBody({ requestId: "Mariaxyz", dates: ["2026-11-23", "2026-11-24"] })));
  const crash = track(harness());
  crash.store.failures.set("withdraw_quote", new Error("Mariaxyz 2026-11-23 56000"));
  await crash.handle(post("/quotes/withdraw", { quoteId: QUOTE_ID }));
  const preview = track(harness());
  preview.store.menuContext = quoteContextRpc();
  const sent = await previewed(preview);
  await preview.handle(post("/menus/send", { sendId: sent.sendId, email: true }));

  const markers = ["Mariaxyz", "2026-11-23", "2026-11-30", "2026-12-07", "56000", "42001", "30000", "560,00", "300,00", "preventivo", "Milanesaxyz"];
  for (const run of runs) {
    const text = JSON.stringify(run.logs);
    assert.ok(run.logs.length > 0);
    for (const marker of markers) assert.ok(!text.includes(marker), `el log lleva ${marker}: ${text}`);
  }
  const events = new Set(runs.flatMap((run) => run.logs.map((entry) => entry.event)));
  // Una excepción de la base que no es un StoreError (crash) también queda como db_error, sin su mensaje.
  for (const event of ["quote_created", "quote_priced", "quote_withdrawn", "rejected", "db_error", "invalid_payload", "menu_previewed", "menu_sent"]) {
    assert.ok(events.has(event), `falta el camino ${event}`);
  }
});

test("index.ts: las tres funciones del presupuesto con la clave secreta y sus errores sin datos", () => {
  const index = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  for (const [fn, op] of [
    ["chef_create_quote", "create_quote"],
    ["chef_update_quote", "update_quote"],
    ["chef_withdraw_quote", "withdraw_quote"],
  ]) {
    assert.match(
      index,
      new RegExp(`const \\{ data, error \\} = await supabase\\.rpc\\("${fn}", params\\);\\s*if \\(error\\) throw storeErrorFrom\\("${op}", error\\);\\s*return data;`),
      fn,
    );
    assert.ok(index.includes(`fail("${op}")`), `sin Supabase, ${op} también falla`);
  }
});
