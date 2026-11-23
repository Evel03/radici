// Tests de la Edge Function client-link con dependencias simuladas (docs/contracts/client-link.md).
// Correr con: npm test (node --test). La función real (index.ts) solo conecta Supabase y Deno.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { hashSubject, rateLimitSubject } from "../_shared/client_ip.ts";
import { CLIENT_LINK_VERSION, readMenuSnapshot } from "../_shared/client_link.ts";
import { recipePhotoUrls } from "../_shared/menu.ts";
import { RESEND_API_URL } from "../_shared/resend.ts";
import {
  ANSWER_RATE_LIMITS,
  DEFAULT_CHEF_LOCALE,
  RETRY_AFTER_SECONDS,
  StoreError,
  VIEW_RATE_LIMITS,
  answerFromRpc,
  answerRateSubject,
  clientLinkConfigWarnings,
  createClientLinkHandler,
  errorReply,
  quoteAnswerFromRpc,
  readClientLinkConfig,
  routeOf,
  storeErrorFrom,
  viewFromRpc,
  viewRateSubject,
  type ClientLinkHandlerDeps,
  type ClientLinkStore,
  type LogFields,
} from "./handler.ts";

const STORAGE = "https://abcdefgh.supabase.co";
const ENDPOINT = "http://127.0.0.1:54321/functions/v1/client-link";
const CHEF_ID = "cef00000-0000-4000-8000-000000000001";
const REQUEST_ID = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";
const RECIPE_ID = "0a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";
const PHOTO_ID = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f";
const SESSION_1 = "5e550000-0000-4000-8000-000000000001";
const SESSION_2 = "5e550000-0000-4000-8000-000000000002";
const SESSION_CANCELLED = "5e550000-0000-4000-8000-000000000003";
const SEND_OLD = "5e0d0000-0000-4000-8000-000000000001";
const SEND_A = "5e0d0000-0000-4000-8000-000000000002";
const MISSING_SEND = "5e0d0000-0000-4000-8000-0000000000ff";

const TOKEN = "B_wWbkraJZQT6glUNfUKI2uxzam1sC16p8ZBTilzOWg";
const TOKEN_HASH = "f6009b5003b250cd9c1eb8fdc2bf28fcf8bf1ef66d24ab121c8692c5ade20cfa";
const UNKNOWN_TOKEN = "OrdK1lNJ7pSQ-fEGuL401rGenNXRim5HBWZUSJuX8Y8";

// Datos con marcas fáciles de buscar en los logs.
const CLIENT_NAME = "Annaxyz Bianchiqwe";
const DISH_NAME = "Lasaña-zzz";
const NOTE = "NOTA-EVELYN-kkk\nel martes llego a las 10.";
const CHANGES_TEXT = "CAMBIO-SECRETO-yyy\r\nsin cebolla, por favor  ";

const ENV: Record<string, string> = {
  SUPABASE_URL: STORAGE,
  SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_prueba" }),
  IP_HASH_SALT: "sal-de-prueba",
  RESEND_API_KEY: "re_prueba",
  MAIL_FROM: "Radici <ciao@radicicucina.app>",
  CHEF_NOTIFY_EMAIL: "evelyn@example.test",
  CHEF_LOCALE: "es",
  ALLOWED_ORIGINS: "https://radicicucina.app,http://localhost:5173",
  INBOX_URL: "https://radicicucina.app/gestione/",
};

/** La foto de un envío como la arma la función chef (SPEC 5.8), con campos de más. */
function snapshot(): Record<string, unknown> {
  return {
    v: 1,
    locale: "es",
    session: { date: "2027-03-01", start: "10:00", week: 1, weeks: 2 },
    weeks: [
      { date: "2027-03-01", start: "10:00" },
      { date: "2027-03-08", start: "10:00" },
    ],
    dishes: [
      {
        name: DISH_NAME,
        description: "Ragú y bechamel.",
        allergens: ["gluten", "eggs", "milk"],
        diet: null,
        portions: 6,
        photo: recipePhotoUrls(STORAGE, CHEF_ID, RECIPE_ID, PHOTO_ID),
        recipeId: RECIPE_ID,
        ingredients: ["no tendría que pasar"],
      },
    ],
    items: [
      { name: "Tomates", section: "produce", quantity: 1250, unit: "g" },
      { name: "Sal", section: "pantry", quantity: null, unit: null },
    ],
    note: NOTE,
  };
}

interface FakeSession {
  id: string;
  date: string;
  start: string;
  status: string;
}

interface FakeSend {
  id: string;
  sessionId: string;
  sentAt: string | null;
  snapshot: unknown;
  confirmedAt: string | null;
  changesRequestedAt: string | null;
  changesText: string | null;
  /** El presupuesto que lleva (el menú de la semana 1 de un presupuesto), o null. */
  quoteId?: string | null;
}

/** El presupuesto de la reserva, como lo ven las funciones client_link_* (migración 20261121120000_quotes.sql). */
interface FakeQuote {
  id: string;
  version: number;
  sentAt: string;
  holdUntil: string | null;
  acceptedAt: string | null;
  declinedAt: string | null;
  withdrawn: boolean;
  /** Pasó el plazo (con o sin private.expire_quotes). */
  expired: boolean;
  /** Evelyn cambió el precio o una semana y no lo reenvió: los términos ya no son los del envío. */
  changed: boolean;
  totalCents: number;
}

/**
 * Como las funciones client_link_* de la migración 20261121100000_menu_sends.sql (con las correcciones de la rama
 * de la base: el nombre del pedido y session_cancelled).
 */
class FakeStore implements ClientLinkStore {
  /** Hashes de los links vigentes de la reserva. */
  links = new Set<string>([TOKEN_HASH]);
  /** El nombre con que llegó el pedido (requests.contact) o, si no tiene, el de la ficha: lo que devuelve la base. */
  clientName: string | null = CLIENT_NAME;
  /** Para simular una base vieja que todavía deja contestar una semana cancelada (sin «semana k»). */
  answerCancelledWeeks = false;
  sessions: FakeSession[] = [
    { id: SESSION_2, date: "2027-03-08", start: "10:00", status: "confirmed" },
    { id: SESSION_CANCELLED, date: "2027-03-04", start: "10:00", status: "cancelled" },
    { id: SESSION_1, date: "2027-03-01", start: "10:00", status: "confirmed" },
  ];
  sends: FakeSend[] = [
    { id: SEND_OLD, sessionId: SESSION_1, sentAt: "2027-02-24T09:00:00+00:00", snapshot: snapshot(), confirmedAt: null, changesRequestedAt: null, changesText: null },
    { id: SEND_A, sessionId: SESSION_1, sentAt: "2027-02-25T18:03:00.123456+00:00", snapshot: snapshot(), confirmedAt: null, changesRequestedAt: null, changesText: null },
  ];
  allow = true;
  /** true: cuenta los intentos de cada clave y aplica los límites (como hit_public_request_rate). */
  countHits = false;
  hits: Array<{ ipHash: string; maxHour: number; maxDay: number }> = [];
  failOn: "rate" | "view" | "confirm" | "changes" | "accept" | "decline" | null = null;
  /** El presupuesto de la reserva (null: una reserva sin presupuesto). */
  quote: FakeQuote | null = null;
  /** Lo que devuelve view en el bloque quote en lugar del calculado (para formas inesperadas). */
  quoteOverride: unknown = undefined;
  acceptCalls: Array<{ tokenHash: string; sendId: string }> = [];
  declineCalls: Array<{ tokenHash: string; sendId: string }> = [];
  /** Para simular una base que rechaza el texto (22023 invalid_text). */
  rejectText = false;
  /** Lo que devuelve view en lugar de la reserva (para formas inesperadas). */
  viewOverride: unknown = undefined;
  viewCalls: string[] = [];
  confirmCalls: Array<{ tokenHash: string; sendId: string }> = [];
  changesCalls: Array<{ tokenHash: string; sendId: string; text: string }> = [];
  private clock = 0;

  private now(): string {
    this.clock += 1;
    return `2027-02-26T10:00:0${this.clock}.000000+00:00`;
  }

  private live(): FakeSession[] {
    return this.sessions.filter((s) => s.status !== "cancelled").sort((a, b) => a.date.localeCompare(b.date) || a.id.localeCompare(b.id));
  }

  private latestSent(sessionId: string): FakeSend | null {
    const sent = this.sends.filter((s) => s.sessionId === sessionId && s.sentAt !== null);
    sent.sort((a, b) => (b.sentAt ?? "").localeCompare(a.sentAt ?? "") || b.id.localeCompare(a.id));
    return sent[0] ?? null;
  }

  async hitRateLimit(ipHash: string, maxHour: number, maxDay: number): Promise<boolean> {
    if (this.failOn === "rate") throw new StoreError("rate_limit", "57014", null);
    this.hits.push({ ipHash, maxHour, maxDay });
    if (!this.countHits) return this.allow;
    const count = this.hits.filter((hit) => hit.ipHash === ipHash).length;
    return count <= maxHour && count <= maxDay;
  }

  /** El estado del presupuesto, como client_link_view. */
  private quoteStatus(quote: FakeQuote): string {
    if (quote.acceptedAt) return "accepted";
    if (quote.declinedAt) return "declined";
    if (quote.withdrawn) return "withdrawn";
    if (quote.expired) return "expired";
    return quote.changed ? "changed" : "sent";
  }

  /** private.quote_closed_reason: accepted, declined, withdrawn, expired o null (abierto y a tiempo). */
  private closedReason(): string | null {
    const quote = this.quote;
    if (!quote) return null;
    if (quote.acceptedAt) return "accepted";
    if (quote.declinedAt) return "declined";
    if (quote.withdrawn) return "withdrawn";
    return quote.expired ? "expired" : null;
  }

  /** El último envío que salió con el presupuesto. */
  private latestQuoteSend(): FakeSend | null {
    const sent = this.sends.filter((s) => s.quoteId && s.quoteId === this.quote?.id && s.sentAt !== null);
    sent.sort((a, b) => (b.sentAt ?? "").localeCompare(a.sentAt ?? "") || b.id.localeCompare(a.id));
    return sent[0] ?? null;
  }

  async view(tokenHash: string): Promise<unknown> {
    if (this.failOn === "view") throw new StoreError("view", "08006", null);
    this.viewCalls.push(tokenHash);
    if (this.viewOverride !== undefined) return this.viewOverride;
    if (!this.links.has(tokenHash)) return null;
    const live = this.live();
    const quote = this.quote;
    return {
      requestId: REQUEST_ID,
      locale: "es",
      chefName: "Evelyn",
      clientName: this.clientName,
      weeks: live.map((session, index) => {
        const send = this.latestSent(session.id);
        return {
          sessionId: session.id,
          date: session.date,
          start: session.start,
          status: session.status,
          week: index + 1,
          weeks: live.length,
          send: send
            ? {
                id: send.id,
                sentAt: send.sentAt,
                snapshot: send.snapshot,
                confirmedAt: send.confirmedAt,
                changesRequestedAt: send.changesRequestedAt,
                quoteId: send.quoteId ?? null,
              }
            : null,
        };
      }),
      quote:
        this.quoteOverride !== undefined
          ? this.quoteOverride
          : quote
            ? {
                id: quote.id,
                version: quote.version,
                status: this.quoteStatus(quote),
                sentAt: quote.sentAt,
                holdUntil: quote.holdUntil,
                acceptedAt: quote.acceptedAt,
                sendId: this.latestQuoteSend()?.id ?? null,
              }
            : null,
    };
  }

  /** private.client_link_send_for_answer. */
  private sendForAnswer(op: string, tokenHash: string, sendId: string): FakeSend {
    if (!this.links.has(tokenHash)) throw new StoreError(op, "P0002", "link_not_found");
    const send = this.sends.find((s) => s.id === sendId && s.sentAt !== null);
    if (!send) throw new StoreError(op, "P0002", "send_not_found");
    if (this.latestSent(send.sessionId)?.id !== send.id) throw new StoreError(op, "55000", "menu_outdated");
    const cancelled = this.sessions.find((s) => s.id === send.sessionId)?.status === "cancelled";
    if (cancelled && !this.answerCancelledWeeks) throw new StoreError(op, "55000", "session_cancelled");
    return send;
  }

  /** private.client_link_answer. */
  private answer(send: FakeSend, already: boolean): Record<string, unknown> {
    const live = this.live();
    const session = this.sessions.find((s) => s.id === send.sessionId);
    const index = live.findIndex((s) => s.id === send.sessionId);
    return {
      sendId: send.id,
      sessionId: send.sessionId,
      requestId: REQUEST_ID,
      chefId: CHEF_ID,
      already,
      confirmedAt: send.confirmedAt,
      changesRequestedAt: send.changesRequestedAt,
      date: session?.date,
      start: session?.start,
      week: index === -1 ? null : index + 1,
      weeks: live.length,
      clientName: this.clientName,
      locale: "es",
    };
  }

  /** Si el envío lleva un presupuesto: open (abierto y a tiempo), accepted o closed; none sin presupuesto. */
  private sendQuoteState(send: FakeSend): "none" | "open" | "accepted" | "closed" {
    if (!send.quoteId || send.quoteId !== this.quote?.id) return "none";
    const reason = this.closedReason();
    return reason === null ? "open" : reason === "accepted" ? "accepted" : "closed";
  }

  async confirmMenu(tokenHash: string, sendId: string): Promise<unknown> {
    if (this.failOn === "confirm") throw new StoreError("confirm_menu", "40001", null);
    this.confirmCalls.push({ tokenHash, sendId });
    const send = this.sendForAnswer("confirm_menu", tokenHash, sendId);
    if (send.confirmedAt !== null) return this.answer(send, true);
    const state = this.sendQuoteState(send);
    // Un menú que va con un presupuesto abierto se acepta con el presupuesto (quote_pending, sin detalle).
    if (state === "open") throw storeErrorFrom("confirm_menu", { code: "55000", message: "quote_pending" });
    if (state === "closed") throw storeErrorFrom("confirm_menu", { code: "55000", message: "quote_closed" });
    if (send.changesRequestedAt !== null) throw new StoreError("confirm_menu", "55000", "changes_requested");
    send.confirmedAt = this.now();
    return this.answer(send, false);
  }

  async requestChanges(tokenHash: string, sendId: string, text: string): Promise<unknown> {
    if (this.failOn === "changes") throw new StoreError("request_changes", "57014", null);
    this.changesCalls.push({ tokenHash, sendId, text });
    if (this.rejectText) throw new StoreError("request_changes", "22023", "invalid_text");
    const send = this.sendForAnswer("request_changes", tokenHash, sendId);
    if (send.confirmedAt !== null) throw new StoreError("request_changes", "55000", "already_confirmed");
    if (this.sendQuoteState(send) === "closed") throw storeErrorFrom("request_changes", { code: "55000", message: "quote_closed" });
    send.changesRequestedAt = this.now();
    send.changesText = text;
    return { ...this.answer(send, false), quoteId: send.quoteId ?? null };
  }

  /** private.client_link_sent_send: el envío que salió de la reserva del link, sin más controles. */
  private sentSend(op: string, tokenHash: string, sendId: string): FakeSend {
    if (!this.links.has(tokenHash)) throw new StoreError(op, "P0002", "link_not_found");
    const send = this.sends.find((s) => s.id === sendId && s.sentAt !== null);
    if (!send) throw new StoreError(op, "P0002", "send_not_found");
    return send;
  }

  /** Lo que suman aceptar y rechazar a la respuesta de siempre. */
  private quoteFields(withTerms: boolean): Record<string, unknown> {
    const quoteWeeks = this.sessions.filter((s) => s.status !== "cancelled").length;
    return withTerms ? { quoteId: this.quote?.id, totalCents: this.quote?.totalCents, quoteWeeks } : { quoteId: this.quote?.id };
  }

  /** Como client_link_accept_quote (con el DETAIL de quote_closed, que index.ts filtra con storeErrorFrom). */
  async acceptQuote(tokenHash: string, sendId: string): Promise<unknown> {
    if (this.failOn === "accept") throw new StoreError("accept_quote", "08006", null);
    this.acceptCalls.push({ tokenHash, sendId });
    const send = this.sentSend("accept_quote", tokenHash, sendId);
    if (!send.quoteId || !this.quote) throw new StoreError("accept_quote", "55000", "not_a_quote");
    const reason = this.closedReason();
    if (reason === "accepted" && send.confirmedAt !== null) return { ...this.answer(send, true), ...this.quoteFields(true) };
    if (reason) throw storeErrorFrom("accept_quote", { code: "55000", message: "quote_closed", details: reason });
    this.sendForAnswer("accept_quote", tokenHash, sendId);
    if (send.changesRequestedAt !== null) throw new StoreError("accept_quote", "55000", "changes_requested");
    if (this.quote.changed) throw storeErrorFrom("accept_quote", { code: "40001", message: "quote_changed" });
    if (!this.sessions.some((s) => s.status === "held")) throw new StoreError("accept_quote", "55000", "quote_empty");
    for (const session of this.sessions) if (session.status === "held") session.status = "confirmed";
    const at = this.now();
    this.quote.acceptedAt = at;
    send.confirmedAt = at;
    return { ...this.answer(send, false), ...this.quoteFields(true) };
  }

  /** Como client_link_decline_quote: las semanas held se cancelan. */
  async declineQuote(tokenHash: string, sendId: string): Promise<unknown> {
    if (this.failOn === "decline") throw new StoreError("decline_quote", "08006", null);
    this.declineCalls.push({ tokenHash, sendId });
    const send = this.sentSend("decline_quote", tokenHash, sendId);
    if (!send.quoteId || !this.quote) throw new StoreError("decline_quote", "55000", "not_a_quote");
    const reason = this.closedReason();
    if (reason === "declined") return { ...this.answer(send, true), ...this.quoteFields(false) };
    if (reason) throw storeErrorFrom("decline_quote", { code: "55000", message: "quote_closed", details: reason });
    this.sendForAnswer("decline_quote", tokenHash, sendId);
    for (const session of this.sessions) if (session.status === "held") session.status = "cancelled";
    this.quote.declinedAt = this.now();
    return { ...this.answer(send, false), ...this.quoteFields(false) };
  }
}

interface Harness {
  handle: (req: Request) => Promise<Response>;
  store: FakeStore;
  logs: Array<{ level: string; event: string; fields: LogFields }>;
  emails: Array<{ body: Record<string, unknown>; headers: Headers }>;
  settle: () => Promise<void>;
}

interface HarnessOptions {
  env?: Record<string, string | undefined>;
  resend?: () => Response | Promise<Response>;
}

function harness(options: HarnessOptions = {}): Harness {
  const env: Record<string, string | undefined> = { ...ENV, ...options.env };
  const store = new FakeStore();
  const logs: Harness["logs"] = [];
  const emails: Harness["emails"] = [];
  const background: Array<Promise<unknown>> = [];
  const fakeFetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    if (url !== RESEND_API_URL) throw new Error(`fetch inesperado: ${url}`);
    emails.push({ body: JSON.parse(String(init?.body)) as Record<string, unknown>, headers: new Headers(init?.headers) });
    return options.resend ? options.resend() : Response.json({ id: `email-${emails.length}` });
  };
  const deps: ClientLinkHandlerDeps = {
    config: readClientLinkConfig((name) => env[name]),
    store,
    fetch: fakeFetch as typeof fetch,
    waitUntil: (task) => {
      background.push(task);
    },
    log: (level, event, fields = {}) => {
      logs.push({ level, event, fields });
    },
    sleep: async () => {},
  };
  return {
    handle: createClientLinkHandler(deps),
    store,
    logs,
    emails,
    settle: async () => {
      await Promise.all(background);
    },
  };
}

function post(route: string, body: unknown, headers: Record<string, string> = {}, rawBody?: string): Request {
  return new Request(`${ENDPOINT}${route}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin: "https://radicicucina.app",
      "cf-connecting-ip": "203.0.113.7",
      ...headers,
    },
    body: rawBody ?? JSON.stringify(body),
  });
}

async function json(response: Response): Promise<Record<string, unknown>> {
  return JSON.parse(await response.text()) as Record<string, unknown>;
}

/** Ningún log lleva el token, su hash, el nombre, el mensaje, la nota ni los platos. */
function assertNoLeaks(logs: Harness["logs"]): void {
  const text = JSON.stringify(logs);
  for (const secret of [TOKEN, TOKEN_HASH, UNKNOWN_TOKEN, "Annaxyz", "Bianchiqwe", "CAMBIO-SECRETO", "cebolla", "NOTA-EVELYN", DISH_NAME, "evelyn@example.test", "203.0.113.7"]) {
    assert.ok(!text.includes(secret), `el log no lleva «${secret}»`);
  }
}

// ---------------------------------------------------------------------------
// HTTP: CORS, ruta, método, tipo, tamaño
// ---------------------------------------------------------------------------

test("OPTIONS: CORS para un origen permitido (solo POST) y nada para otros", async () => {
  const { handle } = harness();
  const allowed = await handle(new Request(`${ENDPOINT}/view`, { method: "OPTIONS", headers: { origin: "https://radicicucina.app" } }));
  assert.equal(allowed.status, 204);
  assert.equal(allowed.headers.get("access-control-allow-origin"), "https://radicicucina.app");
  assert.equal(allowed.headers.get("access-control-allow-methods"), "POST, OPTIONS");
  assert.match(allowed.headers.get("access-control-allow-headers") ?? "", /content-type/);

  const other = await handle(new Request(`${ENDPOINT}/view`, { method: "OPTIONS", headers: { origin: "https://evil.example" } }));
  assert.equal(other.status, 204);
  assert.equal(other.headers.get("access-control-allow-origin"), null);
});

test("las respuestas: JSON, sin caché y con CORS solo para los orígenes permitidos", async () => {
  const { handle } = harness();
  const ok = await handle(post("/view", { token: TOKEN }));
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get("cache-control"), "no-store");
  assert.equal(ok.headers.get("content-type"), "application/json; charset=utf-8");
  assert.equal(ok.headers.get("access-control-allow-origin"), "https://radicicucina.app");
  assert.equal(ok.headers.get("vary"), "Origin");
  const other = await handle(post("/view", { token: TOKEN }, { origin: "https://evil.example" }));
  assert.equal(other.headers.get("access-control-allow-origin"), null);
});

test("ruta desconocida: 404 notFound sin tocar la base", async () => {
  const { handle, store } = harness();
  for (const path of ["", "/", "/other", "/view/extra"]) {
    const response = await handle(post(path, { token: TOKEN }));
    assert.equal(response.status, 404, path);
    assert.deepEqual(await json(response), { error: "notFound" });
  }
  const outside = await handle(new Request("http://127.0.0.1:54321/functions/v1/otra/view", { method: "POST", body: "{}" }));
  assert.equal(outside.status, 404);
  assert.equal(store.hits.length, 0);
});

test("routeOf: lo que sigue al nombre de la función", () => {
  assert.equal(routeOf("/client-link/view"), "/view");
  assert.equal(routeOf("/functions/v1/client-link/confirm"), "/confirm");
  assert.equal(routeOf("/client-link"), "");
  assert.equal(routeOf("/chef/view"), null);
});

test("método, tipo, tamaño y JSON: 405, 415, 413 y 400 invalidPayload", async () => {
  const { handle, store } = harness();
  const get = await handle(new Request(`${ENDPOINT}/view`, { method: "GET", headers: { origin: "https://radicicucina.app" } }));
  assert.equal(get.status, 405);
  assert.equal(get.headers.get("allow"), "POST, OPTIONS");

  const text = await handle(post("/view", null, { "content-type": "text/plain" }, JSON.stringify({ token: TOKEN })));
  assert.equal(text.status, 415);
  assert.deepEqual(await json(text), { error: "contentType" });

  const large = await handle(post("/changes", null, {}, JSON.stringify({ token: TOKEN, sendId: SEND_A, text: "x".repeat(20_000) })));
  assert.equal(large.status, 413);
  assert.deepEqual(await json(large), { error: "tooLarge" });

  for (const raw of ["{", "[]", "null", '"token"', JSON.stringify({ token: 3 }), JSON.stringify({ token: "x".repeat(201) })]) {
    const response = await handle(post("/view", null, {}, raw));
    assert.equal(response.status, 400, raw);
    assert.deepEqual(await json(response), { error: "invalidPayload" });
  }
  for (const body of [{ token: TOKEN }, { token: TOKEN, sendId: "no-es-uuid" }, { token: TOKEN, sendId: 7 }]) {
    const response = await handle(post("/confirm", body));
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.deepEqual(await json(response), { error: "invalidPayload" });
  }
  // Sin texto (o que no es texto) es el cuerpo; un texto vacío, largo o con controles, invalidText.
  const noText = await handle(post("/changes", { token: TOKEN, sendId: SEND_A }));
  assert.deepEqual([noText.status, await json(noText)], [400, { error: "invalidPayload" }]);
  for (const bad of ["", "   \n ", "a".repeat(1001), "\u0000\u0001"]) {
    const response = await handle(post("/changes", { token: TOKEN, sendId: SEND_A, text: bad }));
    assert.equal(response.status, 400);
    assert.deepEqual(await json(response), { error: "invalidText" });
  }
  // Nada llegó a la base ni al límite por IP.
  assert.equal(store.hits.length, 0);
  assert.deepEqual([store.viewCalls.length, store.confirmCalls.length, store.changesCalls.length], [0, 0, 0]);
});

test("configuración: sin IP_HASH_SALT (o sin Supabase) responde 500 y lo deja en el log", async () => {
  for (const missing of ["IP_HASH_SALT", "SUPABASE_URL", "SUPABASE_SECRET_KEYS"]) {
    const { handle, logs, store } = harness({ env: { [missing]: undefined } });
    const response = await handle(post("/view", { token: TOKEN }));
    assert.equal(response.status, 500, missing);
    assert.deepEqual(await json(response), { error: "server" });
    assert.ok(logs.some((log) => log.event === "config_missing" && (log.fields["missing"] as readonly string[]).includes(missing)), missing);
    assert.equal(store.viewCalls.length, 0);
  }
});

test("readClientLinkConfig: idioma de los avisos, transporte, fotos y avisos de arranque", () => {
  const config = readClientLinkConfig((name) => ENV[name]);
  assert.deepEqual(config.missing, []);
  assert.equal(config.chefLocale, "es");
  assert.equal(config.storageOrigin, STORAGE);
  assert.deepEqual(clientLinkConfigWarnings(config), []);

  const bare = readClientLinkConfig((name) => ({ SUPABASE_URL: "http://kong:8000", CHEF_LOCALE: "fr" })[name]);
  assert.deepEqual(bare.missing, ["SUPABASE_SECRET_KEYS", "IP_HASH_SALT"]);
  assert.equal(bare.chefLocale, DEFAULT_CHEF_LOCALE);
  // La dirección interna de Docker no la abre el navegador: sin fotos.
  assert.equal(bare.storageOrigin, null);
  assert.deepEqual(clientLinkConfigWarnings(bare), ["ALLOWED_ORIGINS", "CHEF_NOTIFY_EMAIL", "RESEND_API_KEY", "MAIL_FROM", "INBOX_URL"]);
  assert.equal(readClientLinkConfig((name) => ({ ...ENV, EMAIL_TRANSPORT: "LOG" })[name]).emailTransport, "log");
  assert.deepEqual(clientLinkConfigWarnings(readClientLinkConfig((name) => ({ EMAIL_TRANSPORT: "log" })[name])), ["ALLOWED_ORIGINS", "CHEF_NOTIFY_EMAIL", "INBOX_URL"]);
});

// ---------------------------------------------------------------------------
// POST /view
// ---------------------------------------------------------------------------

test("/view: la reserva con el último menú de cada semana, leído campo por campo, y el nombre de pila", async () => {
  const { handle, store, logs } = harness();
  const response = await handle(post("/view", { token: TOKEN }));
  assert.equal(response.status, 200);
  // A la base llega el sha-256 del token, nunca el token.
  assert.deepEqual(store.viewCalls, [createHash("sha256").update(TOKEN).digest("hex")]);
  const content = readMenuSnapshot(snapshot(), STORAGE);
  assert.deepEqual(await json(response), {
    version: CLIENT_LINK_VERSION,
    locale: "es",
    chefName: "Evelyn",
    clientFirstName: "Annaxyz",
    quote: null,
    weeks: [
      {
        sessionId: SESSION_1,
        week: 1,
        weeks: 2,
        date: "2027-03-01",
        start: "10:00",
        done: false,
        menu: {
          sendId: SEND_A,
          sentAt: "2027-02-25T18:03:00.123456+00:00",
          state: "pending",
          confirmedAt: null,
          changesRequestedAt: null,
          quoteId: null,
          content,
        },
      },
      { sessionId: SESSION_2, week: 2, weeks: 2, date: "2027-03-08", start: "10:00", done: false, menu: null },
    ],
  });
  const body = JSON.stringify(await json(await handle(post("/view", { token: TOKEN }))));
  // Lo que no es del contrato no sale: ni el nombre completo, ni el pedido, ni el id de la receta, ni los ingredientes.
  for (const hidden of ["Bianchiqwe", REQUEST_ID, RECIPE_ID + '"', "ingredients", "no tendría que pasar", "requestId"]) {
    assert.ok(!body.includes(hidden), hidden);
  }
  assert.ok(logs.some((log) => log.event === "link_viewed" && log.fields["requestId"] === REQUEST_ID && log.fields["weeks"] === 2 && log.fields["menus"] === 1));
  assertNoLeaks(logs);
});

test("/view: estados de cada semana (confirmado, con cambios pedidos, ya cocinada)", async () => {
  const { handle, store } = harness();
  const sendA = store.sends.find((s) => s.id === SEND_A);
  assert.ok(sendA);
  sendA.confirmedAt = "2027-02-26T08:00:00+00:00";
  store.sessions[2]!.status = "cooked";
  let body = await json(await handle(post("/view", { token: TOKEN })));
  let week = (body["weeks"] as Array<Record<string, unknown>>)[0];
  assert.equal(week?.["done"], true);
  assert.equal((week?.["menu"] as Record<string, unknown>)["state"], "confirmed");
  assert.equal((week?.["menu"] as Record<string, unknown>)["confirmedAt"], "2027-02-26T08:00:00+00:00");

  sendA.confirmedAt = null;
  sendA.changesRequestedAt = "2027-02-26T09:00:00+00:00";
  store.sessions[2]!.status = "paid";
  body = await json(await handle(post("/view", { token: TOKEN })));
  week = (body["weeks"] as Array<Record<string, unknown>>)[0];
  assert.equal(week?.["done"], true);
  assert.equal((week?.["menu"] as Record<string, unknown>)["state"], "changesRequested");
});

test("/view: un nombre que no parece un nombre no sale (clientFirstName null)", async () => {
  for (const name of ["+39 333 1234567", "bit.ly/x promo", "", null]) {
    const { handle, store } = harness();
    store.clientName = name;
    const body = await json(await handle(post("/view", { token: TOKEN })));
    assert.equal(body["clientFirstName"], null, String(name));
  }
});

test("/view: un link que no existe, vencido o con otra forma da 404 linkNotFound (la forma, sin ir a la base)", async () => {
  const { handle, store, logs } = harness();
  const unknown = await handle(post("/view", { token: UNKNOWN_TOKEN }));
  assert.equal(unknown.status, 404);
  assert.deepEqual(await json(unknown), { error: "linkNotFound" });
  assert.equal(store.viewCalls.length, 1);

  for (const malformed of [TOKEN.slice(1), `${TOKEN}A`, `${TOKEN.slice(0, 42)}+`, ""]) {
    const response = await handle(post("/view", { token: malformed }));
    assert.equal(response.status, 404, malformed);
    assert.deepEqual(await json(response), { error: "linkNotFound" });
  }
  assert.equal(store.viewCalls.length, 1);
  // Cuentan para el límite por IP aunque no lleguen a la base.
  assert.equal(store.hits.length, 5);
  assert.ok(logs.some((log) => log.event === "link_not_found" && log.fields["reason"] === "malformed"));
  assertNoLeaks(logs);
});

test("/view: una foto que no se puede leer deja esa semana sin contenido (y lo avisa con el id del envío)", async () => {
  const { handle, store, logs } = harness();
  store.sends.find((s) => s.id === SEND_A)!.snapshot = { v: 2, dishes: [] };
  const response = await handle(post("/view", { token: TOKEN }));
  assert.equal(response.status, 200);
  const week = ((await json(response))["weeks"] as Array<Record<string, unknown>>)[0];
  assert.equal((week?.["menu"] as Record<string, unknown>)["content"], null);
  assert.ok(logs.some((log) => log.level === "warn" && log.event === "snapshot_unreadable" && log.fields["sendId"] === SEND_A));
});

test("/view: si falla la base, 503; con una forma inesperada, 500", async () => {
  const failing = harness();
  failing.store.failOn = "view";
  const down = await failing.handle(post("/view", { token: TOKEN }));
  assert.equal(down.status, 503);
  assert.deepEqual(await json(down), { error: "unavailable" });
  assert.ok(failing.logs.some((log) => log.event === "db_error" && log.fields["op"] === "view"));

  for (const bad of [[], "texto", { requestId: REQUEST_ID, weeks: [{ date: "2027-03-01", start: "10", status: "confirmed", week: 1, weeks: 1, send: null }] }]) {
    const { handle, store, logs } = harness();
    store.viewOverride = bad;
    const response = await handle(post("/view", { token: TOKEN }));
    assert.equal(response.status, 500, JSON.stringify(bad));
    assert.ok(logs.some((log) => log.event === "unexpected_result"));
  }
});

test("viewFromRpc: el idioma y la cocinera con respaldo; semanas y envíos con otra forma, null", () => {
  const base = { requestId: REQUEST_ID, locale: "xx", chefName: " ", clientName: "Anna", weeks: [] };
  assert.deepEqual(viewFromRpc(base, STORAGE)?.view, { version: 1, locale: "it", chefName: "Evelyn", clientFirstName: "Anna", quote: null, weeks: [] });
  const week = { sessionId: SESSION_1.toUpperCase(), date: "2027-03-01", start: "10:00", status: "held", week: 1, weeks: 1, send: null };
  assert.equal(viewFromRpc({ ...base, weeks: [week] }, STORAGE)?.view.weeks[0]?.done, false);
  assert.equal(viewFromRpc({ ...base, weeks: [week] }, STORAGE)?.view.weeks[0]?.sessionId, SESSION_1);
  assert.equal(viewFromRpc({ ...base, weeks: [{ ...week, week: 2 }] }, STORAGE), null);
  assert.equal(viewFromRpc({ ...base, weeks: [{ ...week, sessionId: undefined }] }, STORAGE), null);
  assert.equal(viewFromRpc({ ...base, weeks: [{ ...week, sessionId: "semana-1" }] }, STORAGE), null);
  assert.equal(viewFromRpc({ ...base, weeks: [{ ...week, send: { id: "x", sentAt: "2027-02-25T18:03:00Z", snapshot: {} } }] }, STORAGE), null);
  assert.equal(viewFromRpc({ ...base, weeks: [{ ...week, send: { id: SEND_A, sentAt: "ayer", snapshot: {} } }] }, STORAGE), null);
  assert.equal(viewFromRpc({ ...base, requestId: "x" }, STORAGE), null);
});

// ---------------------------------------------------------------------------
// POST /confirm
// ---------------------------------------------------------------------------

test("/confirm: confirma el último menú, responde la hora y le avisa a Evelyn una sola vez", async () => {
  const { handle, store, logs, emails, settle } = harness();
  const response = await handle(post("/confirm", { token: TOKEN, sendId: SEND_A.toUpperCase() }));
  assert.equal(response.status, 200);
  assert.deepEqual(await json(response), { confirmedAt: "2027-02-26T10:00:01.000000+00:00", already: false });
  assert.deepEqual(store.confirmCalls, [{ tokenHash: TOKEN_HASH, sendId: SEND_A }]);
  await settle();
  assert.equal(emails.length, 1);
  const email = emails[0]!;
  assert.deepEqual(email.body["to"], ["evelyn@example.test"]);
  assert.equal(email.body["from"], "Radici <ciao@radicicucina.app>");
  assert.equal(email.body["reply_to"], undefined);
  assert.equal(email.body["subject"], "Annaxyz confirmó el menú de la semana 1");
  assert.ok(String(email.body["text"]).includes("Annaxyz Bianchiqwe confirmó el menú de la semana 1 de 2 (lunes, 1 de marzo de 2027, llegada a las 10:00)."));
  assert.ok(String(email.body["text"]).includes(`https://radicicucina.app/gestione/#/richieste/${REQUEST_ID}`));
  assert.equal(email.headers.get("idempotency-key"), `menu-confirmed-${SEND_A}`);
  assert.ok(logs.some((log) => log.event === "menu_confirmed" && log.fields["sendId"] === SEND_A && log.fields["already"] === false));
  assert.ok(logs.some((log) => log.event === "email_sent" && log.fields["kind"] === "confirmed"));

  // Otra vez: ya estaba confirmado, la misma hora y ningún aviso nuevo.
  const again = await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
  assert.deepEqual(await json(again), { confirmedAt: "2027-02-26T10:00:01.000000+00:00", already: true });
  await settle();
  assert.equal(emails.length, 1);
  assertNoLeaks(logs);
});

test("/confirm: errores de la base con su código (404 linkNotFound y sendNotFound, 409 menuOutdated, sessionCancelled y changesRequested)", async () => {
  const cases: Array<[string, Record<string, unknown>, (store: FakeStore) => void, number, string]> = [
    ["link vencido", { token: UNKNOWN_TOKEN, sendId: SEND_A }, () => {}, 404, "linkNotFound"],
    ["envío de otra reserva o que no salió", { token: TOKEN, sendId: MISSING_SEND }, () => {}, 404, "sendNotFound"],
    ["hay un menú más nuevo", { token: TOKEN, sendId: SEND_OLD }, () => {}, 409, "menuOutdated"],
    [
      "la semana se canceló después del envío",
      { token: TOKEN, sendId: SEND_A },
      (store) => {
        store.sessions.find((s) => s.id === SESSION_1)!.status = "cancelled";
      },
      409,
      "sessionCancelled",
    ],
    [
      "ya pidió cambios",
      { token: TOKEN, sendId: SEND_A },
      (store) => {
        store.sends.find((s) => s.id === SEND_A)!.changesRequestedAt = "2027-02-26T09:00:00+00:00";
      },
      409,
      "changesRequested",
    ],
  ];
  for (const [label, body, setup, status, error] of cases) {
    const { handle, store, logs, emails, settle } = harness();
    setup(store);
    const response = await handle(post("/confirm", body));
    assert.equal(response.status, status, label);
    assert.deepEqual(await json(response), { error }, label);
    await settle();
    assert.equal(emails.length, 0, label);
    assert.ok(logs.some((log) => log.event === "rejected" && log.fields["error"] === error), label);
    assertNoLeaks(logs);
  }
});

test("/confirm: si falla la base, 503 y nada de avisos", async () => {
  const { handle, store, emails, settle } = harness();
  store.failOn = "confirm";
  const response = await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
  assert.equal(response.status, 503);
  await settle();
  assert.equal(emails.length, 0);
});

// ---------------------------------------------------------------------------
// POST /changes
// ---------------------------------------------------------------------------

test("/changes: guarda el mensaje normalizado y le avisa a Evelyn sin el mensaje", async () => {
  const { handle, store, logs, emails, settle } = harness();
  const response = await handle(post("/changes", { token: TOKEN, sendId: SEND_A, text: CHANGES_TEXT }));
  assert.equal(response.status, 200);
  assert.deepEqual(await json(response), { changesRequestedAt: "2027-02-26T10:00:01.000000+00:00" });
  assert.deepEqual(store.changesCalls, [{ tokenHash: TOKEN_HASH, sendId: SEND_A, text: "CAMBIO-SECRETO-yyy\nsin cebolla, por favor" }]);
  await settle();
  assert.equal(emails.length, 1);
  const email = emails[0]!;
  assert.equal(email.body["subject"], "Annaxyz pidió cambios en el menú de la semana 1");
  assert.ok(String(email.body["text"]).includes("Su mensaje está en la app, en el pedido"));
  for (const part of ["CAMBIO-SECRETO", "cebolla"]) {
    assert.ok(!String(email.body["html"]).includes(part) && !String(email.body["text"]).includes(part), part);
  }
  assert.equal(email.headers.get("idempotency-key"), `menu-changes-${SEND_A}-${Date.parse("2027-02-26T10:00:01.000000+00:00")}`);
  assert.ok(logs.some((log) => log.event === "changes_requested" && log.fields["sendId"] === SEND_A));
  assertNoLeaks(logs);

  // Un segundo pedido reemplaza al primero y vuelve a avisar (con otra clave de idempotencia).
  await handle(post("/changes", { token: TOKEN, sendId: SEND_A, text: "Otra cosa" }));
  await settle();
  assert.equal(emails.length, 2);
  assert.notEqual(emails[1]!.headers.get("idempotency-key"), email.headers.get("idempotency-key"));
});

test("/changes: 409 alreadyConfirmed, menuOutdated y sessionCancelled, 404 linkNotFound, 400 invalidText de la base", async () => {
  const confirmed = harness();
  confirmed.store.sends.find((s) => s.id === SEND_A)!.confirmedAt = "2027-02-26T08:00:00+00:00";
  const already = await confirmed.handle(post("/changes", { token: TOKEN, sendId: SEND_A, text: "cambio" }));
  assert.deepEqual([already.status, await json(already)], [409, { error: "alreadyConfirmed" }]);

  const outdated = harness();
  const old = await outdated.handle(post("/changes", { token: TOKEN, sendId: SEND_OLD, text: "cambio" }));
  assert.deepEqual([old.status, await json(old)], [409, { error: "menuOutdated" }]);

  const cancelled = harness();
  cancelled.store.sessions.find((s) => s.id === SESSION_1)!.status = "cancelled";
  const gone1 = await cancelled.handle(post("/changes", { token: TOKEN, sendId: SEND_A, text: "cambio" }));
  assert.deepEqual([gone1.status, await json(gone1)], [409, { error: "sessionCancelled" }]);
  assert.ok(cancelled.logs.some((log) => log.event === "rejected" && log.fields["error"] === "sessionCancelled"));

  const expired = harness();
  const gone = await expired.handle(post("/changes", { token: UNKNOWN_TOKEN, sendId: SEND_A, text: "cambio" }));
  assert.deepEqual([gone.status, await json(gone)], [404, { error: "linkNotFound" }]);

  const strict = harness();
  strict.store.rejectText = true;
  const rejected = await strict.handle(post("/changes", { token: TOKEN, sendId: SEND_A, text: "cambio" }));
  assert.deepEqual([rejected.status, await json(rejected)], [400, { error: "invalidText" }]);

  for (const h of [confirmed, outdated, cancelled, expired, strict]) {
    await h.settle();
    assert.equal(h.emails.length, 0);
    assertNoLeaks(h.logs);
  }
});

// ---------------------------------------------------------------------------
// Avisos a Evelyn: un fallo no rompe lo que hizo la clienta
// ---------------------------------------------------------------------------

test("si el email a Evelyn falla, la clienta igual recibe su 200 y queda en el log", async () => {
  const { handle, logs, emails, settle } = harness({ resend: () => Response.json({ name: "internal_server_error" }, { status: 500 }) });
  const response = await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
  assert.equal(response.status, 200);
  await settle();
  // Un reintento con la misma clave (sendWithResend) y después el error en el log.
  assert.equal(emails.length, 2);
  assert.ok(logs.some((log) => log.level === "error" && log.event === "email_failed" && log.fields["status"] === 500 && log.fields["kind"] === "confirmed"));
  assertNoLeaks(logs);
});

test("si el envío del email explota, la clienta igual recibe su 200 (notify_crashed)", async () => {
  const { handle, logs, settle } = harness({
    resend: () => {
      throw new TypeError("boom");
    },
  });
  const response = await handle(post("/changes", { token: TOKEN, sendId: SEND_A, text: "cambio" }));
  assert.equal(response.status, 200);
  await settle();
  assert.ok(logs.some((log) => log.event === "email_failed" || log.event === "notify_crashed"));
});

test("EMAIL_TRANSPORT=log: no sale ningún email, solo los tamaños en el log", async () => {
  const { handle, logs, emails, settle } = harness({ env: { EMAIL_TRANSPORT: "log", RESEND_API_KEY: undefined } });
  await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
  await settle();
  assert.equal(emails.length, 0);
  const logged = logs.find((log) => log.event === "email_logged");
  assert.ok(logged);
  assert.equal(typeof logged.fields["htmlChars"], "number");
  assertNoLeaks(logs);
});

test("sin CHEF_NOTIFY_EMAIL o sin Resend configurado, el aviso se saltea (y la respuesta sale igual)", async () => {
  for (const [env, reason] of [
    [{ CHEF_NOTIFY_EMAIL: undefined }, "no_recipient"],
    [{ RESEND_API_KEY: undefined }, "not_configured"],
    [{ MAIL_FROM: undefined }, "not_configured"],
  ] as const) {
    const { handle, logs, emails, settle } = harness({ env });
    const response = await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
    assert.equal(response.status, 200);
    await settle();
    assert.equal(emails.length, 0);
    assert.ok(logs.some((log) => log.event === "email_skipped" && log.fields["reason"] === reason), reason);
  }
});

test("una base vieja que deja contestar una semana cancelada: la respuesta sale, el aviso no (no hay «semana k»)", async () => {
  const { handle, store, logs, emails, settle } = harness();
  store.answerCancelledWeeks = true;
  store.sessions.find((s) => s.id === SESSION_1)!.status = "cancelled";
  const response = await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
  assert.equal(response.status, 200);
  await settle();
  assert.equal(emails.length, 0);
  assert.ok(logs.some((log) => log.event === "email_skipped" && log.fields["reason"] === "week_cancelled"));
});

test("CHEF_LOCALE: el aviso en el idioma de Evelyn", async () => {
  const { handle, emails, settle } = harness({ env: { CHEF_LOCALE: "it" } });
  await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
  await settle();
  assert.equal(emails[0]?.body["subject"], "Annaxyz ha confermato il menù della settimana 1");
});

// ---------------------------------------------------------------------------
// Límite por IP
// ---------------------------------------------------------------------------

test("límite por IP: /view y las respuestas con su propia clave y sus topes, distintos del formulario", async () => {
  const { handle, store } = harness();
  await handle(post("/view", { token: TOKEN }));
  await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
  await handle(post("/changes", { token: TOKEN, sendId: SEND_OLD, text: "cambio" }));
  const salt = ENV["IP_HASH_SALT"] ?? "";
  const viewHash = await hashSubject(viewRateSubject("203.0.113.7"), salt);
  const answerHash = await hashSubject(answerRateSubject("203.0.113.7"), salt);
  const formHash = await hashSubject(rateLimitSubject("203.0.113.7"), salt);
  assert.deepEqual(store.hits, [
    { ipHash: viewHash, maxHour: VIEW_RATE_LIMITS.perHour, maxDay: VIEW_RATE_LIMITS.perDay },
    { ipHash: answerHash, maxHour: ANSWER_RATE_LIMITS.perHour, maxDay: ANSWER_RATE_LIMITS.perDay },
    { ipHash: answerHash, maxHour: ANSWER_RATE_LIMITS.perHour, maxDay: ANSWER_RATE_LIMITS.perDay },
  ]);
  assert.equal(new Set([viewHash, answerHash, formHash]).size, 3);
  assert.equal(viewRateSubject(null), "client-link:unknown");
  assert.equal(answerRateSubject("2001:db8:1:2:3:4:5:6"), "client-link-answer:2001:db8:1:2::/64");
});

test("límite por IP: pasado el tope, 429 con Retry-After y sin tocar la base", async () => {
  const { handle, store, logs } = harness();
  store.countHits = true;
  for (let i = 0; i < ANSWER_RATE_LIMITS.perHour; i++) {
    const response = await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
    assert.equal(response.status, 200);
  }
  const limited = await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
  assert.equal(limited.status, 429);
  assert.deepEqual(await json(limited), { error: "rateLimited" });
  assert.equal(limited.headers.get("retry-after"), String(RETRY_AFTER_SECONDS));
  assert.equal(limited.headers.get("access-control-expose-headers"), "Retry-After");
  assert.equal(store.confirmCalls.length, ANSWER_RATE_LIMITS.perHour);
  assert.ok(logs.some((log) => log.event === "rate_limited" && log.fields["route"] === "/confirm"));
  // /view tiene su propio contador: sigue funcionando.
  const view = await handle(post("/view", { token: TOKEN }));
  assert.equal(view.status, 200);
});

test("límite por IP: si falla la base, 503", async () => {
  const { handle, store } = harness();
  store.failOn = "rate";
  const response = await handle(post("/view", { token: TOKEN }));
  assert.equal(response.status, 503);
  assert.equal(store.viewCalls.length, 0);
});

// ---------------------------------------------------------------------------
// Piezas
// ---------------------------------------------------------------------------

test("errorReply: cada error propio con su SQLSTATE; el resto, 503 si se puede reintentar o 500", () => {
  const cases: Array<[StoreError, number, string]> = [
    [new StoreError("x", "P0002", "link_not_found"), 404, "linkNotFound"],
    [new StoreError("x", "P0002", "send_not_found"), 404, "sendNotFound"],
    [new StoreError("x", "55000", "menu_outdated"), 409, "menuOutdated"],
    [new StoreError("x", "55000", "changes_requested"), 409, "changesRequested"],
    [new StoreError("x", "55000", "already_confirmed"), 409, "alreadyConfirmed"],
    [new StoreError("x", "55000", "session_cancelled"), 409, "sessionCancelled"],
    [new StoreError("x", "22023", "invalid_text"), 400, "invalidText"],
    // El mensaje sin su código no alcanza.
    [new StoreError("x", "42501", "link_not_found"), 500, "server"],
    [new StoreError("x", "40001", null), 503, "unavailable"],
    [new StoreError("x", null, null), 503, "unavailable"],
    [new StoreError("x", "PGRST002", null), 503, "unavailable"],
    [new StoreError("x", "23514", null), 500, "server"],
  ];
  for (const [error, status, code] of cases) {
    assert.deepEqual(errorReply(error), { status, body: { error: code } }, `${error.code} ${error.safeMessage}`);
  }
  assert.deepEqual(errorReply(new Error("x")), { status: 500, body: { error: "server" } });
});

test("storeErrorFrom: solo el código y un mensaje que es un identificador (nunca la fila)", () => {
  const known = storeErrorFrom("confirm_menu", { code: "55000", message: "menu_outdated" });
  assert.deepEqual([known.op, known.code, known.safeMessage], ["confirm_menu", "55000", "menu_outdated"]);
  const raw = storeErrorFrom("view", { code: "23514", message: 'new row for relation "menu_sends" violates check constraint' });
  assert.equal(raw.safeMessage, null);
  assert.equal(storeErrorFrom("view", {}).code, null);
});

test("answerFromRpc: la forma de private.client_link_answer; otra, null", () => {
  const answer = {
    sendId: SEND_A,
    requestId: REQUEST_ID,
    already: false,
    confirmedAt: "2027-02-26T10:00:00+00:00",
    changesRequestedAt: null,
    date: "2027-03-01",
    start: "10:00",
    week: 1,
    weeks: 2,
    clientName: "Anna",
  };
  assert.deepEqual(answerFromRpc(answer), answer);
  assert.equal(answerFromRpc({ ...answer, week: null })?.week, null);
  assert.equal(answerFromRpc({ ...answer, clientName: undefined })?.clientName, null);
  for (const bad of [null, [], { ...answer, sendId: "x" }, { ...answer, already: "no" }, { ...answer, date: "ayer" }, { ...answer, week: 0 }, { ...answer, confirmedAt: "x" }]) {
    assert.equal(answerFromRpc(bad), null, JSON.stringify(bad));
  }
});

test("/changes: los saltos de línea pegados desde Word (\\v, \\f) y NEL llegan a la base como \\n; los demás controles se sacan", async () => {
  const { handle, store } = harness();
  const response = await handle(post("/changes", { token: TOKEN, sendId: SEND_A, text: "Lasagne\vRisotto\fPollo\u0085Fine\u0007" }));
  assert.equal(response.status, 200);
  assert.deepEqual(store.changesCalls.map((call) => call.text), ["Lasagne\nRisotto\nPollo\nFine"]);
});

// ---------------------------------------------------------------------------
// El presupuesto (SPEC 5.8): /view, /accept, /decline y lo que cambia en /confirm y /changes
// ---------------------------------------------------------------------------

const QUOTE_ID = "9a0e0000-0000-4000-8000-000000000001";

/** La foto del envío de la semana 1 de un presupuesto (2 semanas, 300 €): la de siempre más el presupuesto. */
function quoteSnapshot(): Record<string, unknown> {
  return {
    ...snapshot(),
    quote: {
      version: 2,
      totalCents: 30000,
      weeks: [
        { date: "2027-03-01", start: "10:00", serviceCents: 15000 },
        { date: "2027-03-08", start: "10:00", serviceCents: 15000 },
      ],
      holdHours: 48,
      firstStart: "2027-03-01T10:00",
    },
  };
}

/**
 * Una reserva con un presupuesto por aceptar (versión 2): las dos semanas held y los dos envíos de la semana 1 con
 * el presupuesto (el viejo, versión 1, y el de ahora, SEND_A).
 */
function quoteHarness(options: HarnessOptions = {}): Harness {
  const run = harness(options);
  for (const session of run.store.sessions) if (session.status === "confirmed") session.status = "held";
  for (const send of run.store.sends) {
    send.quoteId = QUOTE_ID;
    send.snapshot = quoteSnapshot();
  }
  run.store.quote = {
    id: QUOTE_ID,
    version: 2,
    sentAt: "2027-02-25T18:03:00.123456+00:00",
    holdUntil: "2027-02-27T18:03:00.123456+00:00",
    acceptedAt: null,
    declinedAt: null,
    withdrawn: false,
    expired: false,
    changed: false,
    totalCents: 30000,
  };
  return run;
}

/** Ningún log lleva importes del presupuesto. */
function assertNoAmounts(logs: Harness["logs"]): void {
  const text = JSON.stringify(logs);
  for (const amount of ["30000", "15000", "300,00", "150,00"]) assert.ok(!text.includes(amount), `el log lleva ${amount}`);
}

test("/view con presupuesto: su estado, el plazo, el envío que lo lleva y lo que vio la clienta (de la foto de ese envío)", async () => {
  const { handle, logs } = quoteHarness();
  const body = await json(await handle(post("/view", { token: TOKEN })));
  assert.deepEqual(body["quote"], {
    id: QUOTE_ID,
    version: 2,
    status: "sent",
    sentAt: "2027-02-25T18:03:00.123456+00:00",
    holdUntil: "2027-02-27T18:03:00.123456+00:00",
    acceptedAt: null,
    sendId: SEND_A,
    summary: {
      totalCents: 30000,
      weeks: [
        { date: "2027-03-01", start: "10:00", serviceCents: 15000 },
        { date: "2027-03-08", start: "10:00", serviceCents: 15000 },
      ],
    },
  });
  const weeks = body["weeks"] as Array<Record<string, unknown>>;
  const menu = weeks[0]?.["menu"] as Record<string, unknown>;
  assert.equal(menu["quoteId"], QUOTE_ID, "el envío de la semana 1 dice qué presupuesto lleva");
  // El contenido del menú no cambia por llevar el presupuesto (los precios van solo en quote).
  assert.deepEqual(menu["content"], readMenuSnapshot(snapshot(), STORAGE));
  assert.equal(weeks[1]?.["menu"], null);
  assertNoLeaks(logs);
  assertNoAmounts(logs);
});

test("/view con presupuesto: los precios solo por aceptar o aceptado; cambiado, rechazado, retirado o vencido, sin resumen", async () => {
  const cases: Array<[string, (quote: FakeQuote) => void, string, boolean]> = [
    ["cambiado sin reenviar", (q) => (q.changed = true), "changed", false],
    ["vencido", (q) => (q.expired = true), "expired", false],
    ["retirado", (q) => (q.withdrawn = true), "withdrawn", false],
    ["aceptado", (q) => (q.acceptedAt = "2027-02-26T09:00:00+00:00"), "accepted", true],
  ];
  for (const [name, change, status, summary] of cases) {
    const { handle, store } = quoteHarness();
    change(store.quote!);
    const quote = (await json(await handle(post("/view", { token: TOKEN }))))["quote"] as Record<string, unknown>;
    assert.equal(quote["status"], status, name);
    assert.equal(quote["summary"] !== null, summary, name);
  }
  // Rechazado: las semanas se cancelaron (no hay envío a la vista) y queda el estado.
  const declined = quoteHarness();
  declined.store.quote!.declinedAt = "2027-02-26T09:00:00+00:00";
  for (const session of declined.store.sessions) session.status = "cancelled";
  const body = await json(await declined.handle(post("/view", { token: TOKEN })));
  assert.deepEqual(body["weeks"], []);
  assert.equal((body["quote"] as Record<string, unknown>)["status"], "declined");
  assert.equal((body["quote"] as Record<string, unknown>)["summary"], null);
});

test("/view con presupuesto: una foto sin el presupuesto deja el resumen en null; un bloque quote con otra forma, 500", async () => {
  const unreadable = quoteHarness();
  unreadable.store.sends.find((s) => s.id === SEND_A)!.snapshot = snapshot();
  const quote = (await json(await unreadable.handle(post("/view", { token: TOKEN }))))["quote"] as Record<string, unknown>;
  assert.equal(quote["summary"], null);
  assert.equal(quote["status"], "sent");

  for (const bad of [
    "presupuesto",
    { id: QUOTE_ID, version: 1, status: "pending", sentAt: "2027-02-25T18:03:00Z", holdUntil: null, acceptedAt: null, sendId: null },
    { id: QUOTE_ID, version: 0, status: "sent", sentAt: "2027-02-25T18:03:00Z", holdUntil: null, acceptedAt: null, sendId: null },
    { id: QUOTE_ID, version: 1, status: "accepted", sentAt: "2027-02-25T18:03:00Z", holdUntil: null, acceptedAt: null, sendId: null },
    { id: "x", version: 1, status: "sent", sentAt: "2027-02-25T18:03:00Z", holdUntil: null, acceptedAt: null, sendId: null },
  ]) {
    const { handle, store, logs } = quoteHarness();
    store.quoteOverride = bad;
    const response = await handle(post("/view", { token: TOKEN }));
    assert.equal(response.status, 500, JSON.stringify(bad));
    assert.ok(logs.some((log) => log.event === "unexpected_result"));
  }
});

test("/accept: acepta el presupuesto (y el menú de la semana 1), responde la hora y le avisa a Evelyn una sola vez", async () => {
  const { handle, store, logs, emails, settle } = quoteHarness();
  const response = await handle(post("/accept", { token: TOKEN, sendId: SEND_A.toUpperCase() }));
  assert.equal(response.status, 200);
  assert.deepEqual(await json(response), { acceptedAt: "2027-02-26T10:00:01.000000+00:00", already: false });
  assert.deepEqual(store.acceptCalls, [{ tokenHash: TOKEN_HASH, sendId: SEND_A }]);
  assert.deepEqual(store.sessions.filter((s) => s.status !== "cancelled").map((s) => s.status), ["confirmed", "confirmed"]);
  await settle();
  assert.equal(emails.length, 1);
  const email = emails[0]!;
  assert.deepEqual(email.body["to"], ["evelyn@example.test"]);
  assert.equal(email.body["subject"], "Annaxyz aceptó el presupuesto");
  assert.ok(String(email.body["text"]).includes("Annaxyz Bianchiqwe aceptó el presupuesto: 2 semanas, 300,00 €."));
  assert.ok(String(email.body["text"]).includes("La primera semana es el lunes, 1 de marzo de 2027, con llegada a las 10:00."));
  assert.ok(String(email.body["text"]).includes(`https://radicicucina.app/gestione/#/richieste/${REQUEST_ID}`));
  assert.equal(email.headers.get("idempotency-key"), `quote-accepted-${QUOTE_ID}`);
  assert.ok(
    logs.some(
      (log) =>
        log.event === "quote_accepted" &&
        log.fields["sendId"] === SEND_A &&
        log.fields["quoteId"] === QUOTE_ID &&
        log.fields["requestId"] === REQUEST_ID &&
        log.fields["already"] === false,
    ),
  );
  assert.ok(logs.some((log) => log.event === "email_sent" && log.fields["kind"] === "accepted" && log.fields["quoteId"] === QUOTE_ID));

  // Otra vez: ya estaba aceptado, la misma hora y ningún aviso nuevo.
  const again = await handle(post("/accept", { token: TOKEN, sendId: SEND_A }));
  assert.deepEqual(await json(again), { acceptedAt: "2027-02-26T10:00:01.000000+00:00", already: true });
  await settle();
  assert.equal(emails.length, 1);
  // Después de aceptarlo, el menú de la semana 1 está confirmado: confirmar de nuevo es already.
  assert.deepEqual(await json(await handle(post("/confirm", { token: TOKEN, sendId: SEND_A }))), { confirmedAt: "2027-02-26T10:00:01.000000+00:00", already: true });
  assertNoLeaks(logs);
  assertNoAmounts(logs);
});

test("/decline: rechaza el presupuesto (las semanas se liberan), responde y le avisa a Evelyn una sola vez", async () => {
  const { handle, store, logs, emails, settle } = quoteHarness();
  const response = await handle(post("/decline", { token: TOKEN, sendId: SEND_A }));
  assert.equal(response.status, 200);
  assert.deepEqual(await json(response), { already: false });
  assert.deepEqual(store.declineCalls, [{ tokenHash: TOKEN_HASH, sendId: SEND_A }]);
  assert.equal(store.sessions.filter((s) => s.status !== "cancelled").length, 0);
  await settle();
  assert.equal(emails.length, 1);
  const email = emails[0]!;
  assert.equal(email.body["subject"], "Annaxyz rechazó el presupuesto");
  assert.ok(String(email.body["text"]).includes("Annaxyz Bianchiqwe rechazó el presupuesto."));
  assert.ok(String(email.body["text"]).includes("El presupuesto empezaba el lunes, 1 de marzo de 2027, con llegada a las 10:00."));
  assert.ok(!String(email.body["text"]).includes("€"));
  assert.equal(email.headers.get("idempotency-key"), `quote-declined-${QUOTE_ID}`);
  assert.ok(logs.some((log) => log.event === "quote_declined" && log.fields["quoteId"] === QUOTE_ID && log.fields["already"] === false));

  const again = await handle(post("/decline", { token: TOKEN, sendId: SEND_A }));
  assert.deepEqual([again.status, await json(again)], [200, { already: true }]);
  await settle();
  assert.equal(emails.length, 1);
  assertNoLeaks(logs);
});

test("/accept: cada error de la base con su código (y el motivo de quoteClosed), sin avisos", async () => {
  const cases: Array<[string, Record<string, unknown>, (store: FakeStore) => void, number, Record<string, unknown>]> = [
    ["link vencido", { token: UNKNOWN_TOKEN, sendId: SEND_A }, () => {}, 404, { error: "linkNotFound" }],
    ["envío de otra reserva o que no salió", { token: TOKEN, sendId: MISSING_SEND }, () => {}, 404, { error: "sendNotFound" }],
    ["la versión vieja", { token: TOKEN, sendId: SEND_OLD }, () => {}, 409, { error: "menuOutdated" }],
    [
      "la semana del envío se canceló",
      { token: TOKEN, sendId: SEND_A },
      (store) => {
        store.sessions.find((s) => s.id === SESSION_1)!.status = "cancelled";
      },
      409,
      { error: "sessionCancelled" },
    ],
    [
      "un envío sin presupuesto",
      { token: TOKEN, sendId: SEND_A },
      (store) => {
        store.sends.find((s) => s.id === SEND_A)!.quoteId = null;
      },
      409,
      { error: "notAQuote" },
    ],
    ["rechazado", { token: TOKEN, sendId: SEND_A }, (store) => (store.quote!.declinedAt = "2027-02-26T09:00:00+00:00"), 409, { error: "quoteClosed", reason: "declined" }],
    ["retirado", { token: TOKEN, sendId: SEND_A }, (store) => (store.quote!.withdrawn = true), 409, { error: "quoteClosed", reason: "withdrawn" }],
    ["vencido", { token: TOKEN, sendId: SEND_A }, (store) => (store.quote!.expired = true), 409, { error: "quoteClosed", reason: "expired" }],
    [
      "pidió cambios a esa versión",
      { token: TOKEN, sendId: SEND_A },
      (store) => {
        store.sends.find((s) => s.id === SEND_A)!.changesRequestedAt = "2027-02-26T09:00:00+00:00";
      },
      409,
      { error: "changesRequested" },
    ],
    ["Evelyn lo cambió sin reenviarlo", { token: TOKEN, sendId: SEND_A }, (store) => (store.quote!.changed = true), 409, { error: "quoteChanged" }],
    [
      "sin semanas por aceptar",
      { token: TOKEN, sendId: SEND_A },
      (store) => {
        store.sessions.find((s) => s.id === SESSION_2)!.status = "cancelled";
        store.sessions.find((s) => s.id === SESSION_1)!.status = "confirmed";
      },
      409,
      { error: "quoteEmpty" },
    ],
  ];
  for (const [label, body, setup, status, expected] of cases) {
    const { handle, store, logs, emails, settle } = quoteHarness();
    setup(store);
    const response = await handle(post("/accept", body));
    assert.equal(response.status, status, label);
    assert.deepEqual(await json(response), expected, label);
    await settle();
    assert.equal(emails.length, 0, label);
    assert.ok(logs.some((log) => log.event === "rejected" && log.fields["error"] === expected["error"]), label);
    if (expected["reason"]) assert.ok(logs.some((log) => log.event === "rejected" && log.fields["reason"] === expected["reason"]), label);
    assertNoLeaks(logs);
  }
});

test("/decline: uno aceptado no se rechaza (quoteClosed accepted); la versión vieja, menuOutdated; sin presupuesto, notAQuote", async () => {
  const accepted = quoteHarness();
  accepted.store.quote!.acceptedAt = "2027-02-26T09:00:00+00:00";
  const closed = await accepted.handle(post("/decline", { token: TOKEN, sendId: SEND_A }));
  assert.deepEqual([closed.status, await json(closed)], [409, { error: "quoteClosed", reason: "accepted" }]);

  const outdated = quoteHarness();
  const old = await outdated.handle(post("/decline", { token: TOKEN, sendId: SEND_OLD }));
  assert.deepEqual([old.status, await json(old)], [409, { error: "menuOutdated" }]);

  const plain = harness();
  const none = await plain.handle(post("/decline", { token: TOKEN, sendId: SEND_A }));
  assert.deepEqual([none.status, await json(none)], [409, { error: "notAQuote" }]);

  // Se puede rechazar aunque haya pedido cambios antes.
  const changes = quoteHarness();
  changes.store.sends.find((s) => s.id === SEND_A)!.changesRequestedAt = "2027-02-26T09:00:00+00:00";
  assert.equal((await changes.handle(post("/decline", { token: TOKEN, sendId: SEND_A }))).status, 200);

  for (const h of [accepted, outdated, plain]) {
    await h.settle();
    assert.equal(h.emails.length, 0);
  }
});

test("/confirm de un menú con el presupuesto abierto: 409 quotePending (se acepta el presupuesto); cerrado, quoteClosed", async () => {
  const open = quoteHarness();
  const pending = await open.handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
  assert.deepEqual([pending.status, await json(pending)], [409, { error: "quotePending" }]);
  assert.ok(open.logs.some((log) => log.event === "rejected" && log.fields["error"] === "quotePending"));

  const expired = quoteHarness();
  expired.store.quote!.expired = true;
  const closed = await expired.handle(post("/confirm", { token: TOKEN, sendId: SEND_A }));
  assert.deepEqual([closed.status, await json(closed)], [409, { error: "quoteClosed" }], "sin motivo: confirm no lo dice");

  // Pedir cambios con el presupuesto abierto, sí (como con cualquier menú); con el presupuesto cerrado, no.
  const changes = quoteHarness();
  assert.equal((await changes.handle(post("/changes", { token: TOKEN, sendId: SEND_A, text: "Mejor a las 11" }))).status, 200);
  const withdrawn = quoteHarness();
  withdrawn.store.quote!.withdrawn = true;
  const refused = await withdrawn.handle(post("/changes", { token: TOKEN, sendId: SEND_A, text: "Mejor a las 11" }));
  assert.deepEqual([refused.status, await json(refused)], [409, { error: "quoteClosed" }]);

  for (const h of [open, expired, withdrawn]) {
    await h.settle();
    assert.equal(h.emails.length, 0);
  }
});

test("/accept y /decline: el cuerpo como /confirm (400 sin sendId), el contador de las respuestas y 503 si la base no responde", async () => {
  const { handle, store } = quoteHarness();
  for (const route of ["/accept", "/decline"]) {
    for (const body of [{ token: TOKEN }, { token: TOKEN, sendId: "x" }, { sendId: SEND_A }]) {
      const response = await handle(post(route, body));
      assert.deepEqual([response.status, await json(response)], [400, { error: "invalidPayload" }], `${route} ${JSON.stringify(body)}`);
    }
  }
  assert.equal(store.hits.length, 0, "un cuerpo inválido no llega al límite");
  await handle(post("/accept", { token: TOKEN, sendId: SEND_OLD }));
  await handle(post("/decline", { token: TOKEN, sendId: SEND_OLD }));
  const answerHash = await hashSubject(answerRateSubject("203.0.113.7"), ENV["IP_HASH_SALT"] ?? "");
  assert.deepEqual(
    store.hits.map((hit) => [hit.ipHash, hit.maxHour, hit.maxDay]),
    [
      [answerHash, ANSWER_RATE_LIMITS.perHour, ANSWER_RATE_LIMITS.perDay],
      [answerHash, ANSWER_RATE_LIMITS.perHour, ANSWER_RATE_LIMITS.perDay],
    ],
    "el mismo contador que /confirm y /changes",
  );

  for (const failOn of ["accept", "decline"] as const) {
    const down = quoteHarness();
    down.store.failOn = failOn;
    const response = await down.handle(post(`/${failOn}`, { token: TOKEN, sendId: SEND_A }));
    assert.deepEqual([response.status, await json(response)], [503, { error: "unavailable" }], failOn);
    await down.settle();
    assert.equal(down.emails.length, 0);
  }
});

test("presupuesto: si el aviso a Evelyn falla la clienta igual recibe su 200; con EMAIL_TRANSPORT=log no sale nada; sin destinatario, se saltea", async () => {
  const failing = quoteHarness({ resend: () => Response.json({ name: "internal_server_error" }, { status: 500 }) });
  assert.equal((await failing.handle(post("/accept", { token: TOKEN, sendId: SEND_A }))).status, 200);
  await failing.settle();
  assert.ok(failing.logs.some((log) => log.level === "error" && log.event === "email_failed" && log.fields["kind"] === "accepted"));

  const logged = quoteHarness({ env: { EMAIL_TRANSPORT: "log", RESEND_API_KEY: undefined } });
  await logged.handle(post("/decline", { token: TOKEN, sendId: SEND_A }));
  await logged.settle();
  assert.equal(logged.emails.length, 0);
  assert.ok(logged.logs.some((log) => log.event === "email_logged" && log.fields["kind"] === "declined"));

  const nobody = quoteHarness({ env: { CHEF_NOTIFY_EMAIL: undefined } });
  assert.equal((await nobody.handle(post("/accept", { token: TOKEN, sendId: SEND_A }))).status, 200);
  await nobody.settle();
  assert.ok(nobody.logs.some((log) => log.event === "email_skipped" && log.fields["reason"] === "no_recipient"));

  const italian = quoteHarness({ env: { CHEF_LOCALE: "it" } });
  await italian.handle(post("/accept", { token: TOKEN, sendId: SEND_A }));
  await italian.settle();
  assert.equal(italian.emails[0]?.body["subject"], "Annaxyz ha accettato il preventivo");
  for (const h of [failing, logged, nobody, italian]) {
    assertNoLeaks(h.logs);
    assertNoAmounts(h.logs);
  }
});

test("errorReply y storeErrorFrom del presupuesto: cada código con su SQLSTATE; de quote_closed, solo un motivo conocido", () => {
  const cases: Array<[StoreError, number, Record<string, unknown>]> = [
    [new StoreError("x", "55000", "quote_pending"), 409, { error: "quotePending" }],
    [new StoreError("x", "55000", "quote_closed"), 409, { error: "quoteClosed" }],
    [new StoreError("x", "55000", "quote_closed", "expired"), 409, { error: "quoteClosed", reason: "expired" }],
    [new StoreError("x", "55000", "quote_closed", "otra cosa"), 409, { error: "quoteClosed" }],
    // 40001 es la clase de los reintentos, pero quote_changed no se arregla reintentando.
    [new StoreError("x", "40001", "quote_changed"), 409, { error: "quoteChanged" }],
    [new StoreError("x", "55000", "not_a_quote"), 409, { error: "notAQuote" }],
    [new StoreError("x", "55000", "quote_empty"), 409, { error: "quoteEmpty" }],
    [new StoreError("x", "55000", "quote_changed"), 500, { error: "server" }],
  ];
  for (const [error, status, body] of cases) {
    assert.deepEqual(errorReply(error), { status, body }, `${error.code} ${error.safeMessage} ${error.safeDetail}`);
  }
  for (const reason of ["accepted", "declined", "withdrawn", "expired"]) {
    assert.equal(storeErrorFrom("accept_quote", { code: "55000", message: "quote_closed", details: reason }).safeDetail, reason);
  }
  // El detalle de Postgres de cualquier otro error (puede traer la fila) no pasa.
  assert.equal(storeErrorFrom("accept_quote", { code: "55000", message: "quote_closed", details: "Failing row contains (Anna)" }).safeDetail, null);
  assert.equal(storeErrorFrom("view", { code: "23514", message: "menu_outdated", details: "accepted" }).safeDetail, null);
});

test("quoteAnswerFromRpc: la respuesta de siempre más el presupuesto (y, al aceptar, semanas y total); otra forma, null", () => {
  const base = {
    sendId: SEND_A,
    requestId: REQUEST_ID,
    already: false,
    confirmedAt: "2027-02-26T10:00:00+00:00",
    changesRequestedAt: null,
    date: "2027-03-01",
    start: "10:00",
    week: 1,
    weeks: 2,
    clientName: "Anna",
  };
  assert.deepEqual(quoteAnswerFromRpc({ ...base, quoteId: QUOTE_ID.toUpperCase(), totalCents: 30000, quoteWeeks: 2 }), {
    ...base,
    quoteId: QUOTE_ID,
    totalCents: 30000,
    quoteWeeks: 2,
  });
  assert.deepEqual(quoteAnswerFromRpc({ ...base, confirmedAt: null, week: null, weeks: 0, quoteId: QUOTE_ID }), {
    ...base,
    confirmedAt: null,
    week: null,
    weeks: 0,
    quoteId: QUOTE_ID,
    totalCents: null,
    quoteWeeks: null,
  });
  for (const bad of [{ ...base }, { ...base, quoteId: "x" }, { ...base, quoteId: QUOTE_ID, totalCents: 1.5 }, { ...base, quoteId: QUOTE_ID, quoteWeeks: -1 }]) {
    assert.equal(quoteAnswerFromRpc(bad), null, JSON.stringify(bad));
  }
});

test("index.ts: aceptar y rechazar con las funciones SQL del presupuesto y sus errores por storeErrorFrom", () => {
  const index = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  for (const [fn, op] of [
    ["client_link_accept_quote", "accept_quote"],
    ["client_link_decline_quote", "decline_quote"],
  ]) {
    assert.match(
      index,
      new RegExp(`supabase\\.rpc\\("${fn}", \\{ p_token_hash: tokenHash, p_send_id: sendId \\}\\);\\s*if \\(error\\) throw storeErrorFrom\\("${op}", error\\);\\s*return data;`),
      fn,
    );
    assert.ok(index.includes(`fail("${op}")`), op);
  }
});
