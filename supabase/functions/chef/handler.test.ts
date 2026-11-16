// Tests de la Edge Function chef con dependencias simuladas (docs/contracts/chef-api.md).
// Correr con: npm test (node --test). La función real (index.ts) solo conecta Supabase y Deno; la
// base simulada imita lo que importa de chef_create_booking, chef_move_session y chef_cancel_sessions
// (lo demás lo prueba supabase/tests/database/13_bookings.test.sql).
import { test } from "node:test";
import assert from "node:assert/strict";
import { StoreError, type LogFields } from "../_shared/edge.ts";
import {
  CHEF_CORS_METHODS,
  authFailureKind,
  bearerToken,
  bookingResponseFromRpc,
  cancelSessionsResponseFromRpc,
  chefConfigWarnings,
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
  type CreateBookingParams,
  type MoveSessionParams,
} from "./handler.ts";

const CHEF_ID = "cef00000-0000-4000-8000-000000000001";
const USER_EVELYN = "e0000000-0000-4000-8000-000000000001";
const USER_CLIENT = "c0000000-0000-4000-8000-000000000001";
const REQUEST_ID = "5e550000-0000-4000-8000-000000000001";
const CLIENT_ID = "5e550000-0000-4000-8000-000000000002";
const SESSION_ID = "5e550000-0000-4000-8000-000000000003";
const OTHER_SESSION_ID = "5e550000-0000-4000-8000-000000000004";
const REQUEST_KEY = "3f2b8c1e-9a4d-4c7b-8e2f-0123456789ab";
// Lunes 16/11/2026, 11:00 en Roma.
const NOW = new Date("2026-11-16T10:00:00Z");
const BASE = "http://127.0.0.1:54321/functions/v1/chef";
const ORIGIN = "https://radicicucina.app";
const FOUR_MONDAYS = ["2026-11-23", "2026-11-30", "2026-12-07", "2026-12-14"];

const ENV: Record<string, string> = {
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_SECRET_KEYS: '{"default":"sb_secret_prueba"}',
  ALLOWED_ORIGINS: `${ORIGIN},http://localhost:8080`,
};

/** Un JWT con la forma de los de Supabase (la firma es falsa: lo valida la base simulada, como Auth). */
function jwt(subject: string): string {
  const part = (value: unknown): string => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "ES256", typ: "JWT" })}.${part({ sub: subject, role: "authenticated" })}.ZmlybWE`;
}
const TOKEN_EVELYN = jwt(USER_EVELYN);
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

type Op = "get_user" | "load_chef" | "create_booking" | "move_session" | "cancel_sessions";

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
    [TOKEN_CLIENT, USER_CLIENT],
  ]);
  chefs = new Map<string, string>([[USER_EVELYN, CHEF_ID]]);
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

  private fail(op: Op): void {
    if (this.failures.has(op)) throw this.failures.get(op);
  }

  async userIdFromToken(token: string): Promise<string | null> {
    this.tokens.push(token);
    this.fail("get_user");
    return this.users.get(token) ?? null;
  }

  async chefIdForUser(userId: string): Promise<string | null> {
    this.chefLookups.push(userId);
    this.fail("load_chef");
    return this.chefs.get(userId) ?? null;
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

  async cancelSessions(params: CancelSessionsParams): Promise<unknown> {
    this.cancelCalls.push(params);
    this.fail("cancel_sessions");
    if (this.raw !== undefined) return this.raw;
    this.writes += params.p_session_ids.length;
    return { cancelled: params.p_session_ids, already_cancelled: [], with_payments: [], had_payments: false };
  }
}

interface Harness {
  handle: (request: Request) => Promise<Response>;
  store: FakeStore;
  logs: Array<{ level: string; event: string; fields: LogFields }>;
}

function harness(options: { env?: Record<string, string | undefined>; now?: Date } = {}): Harness {
  const env: Record<string, string | undefined> = { ...ENV, ...options.env };
  const store = new FakeStore();
  const logs: Harness["logs"] = [];
  const deps: ChefHandlerDeps = {
    config: readChefConfig((name) => env[name]),
    store,
    now: () => options.now ?? NOW,
    log: (level, event, fields = {}) => {
      logs.push({ level, event, fields });
    },
  };
  return { handle: createChefHandler(deps), store, logs };
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
    groceriesEstCents: 7550,
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

test("403 para un usuario válido que no es la cocinera, en todas las rutas, sin tocar las sesiones", async () => {
  const { handle, store, logs } = harness();
  const routes: Array<[string, unknown]> = [
    ["/bookings", bookingBody()],
    ["/sessions/move", { sessionId: SESSION_ID, date: "2026-11-25" }],
    ["/sessions/cancel", { sessionIds: [SESSION_ID] }],
  ];
  for (const [route, body] of routes) {
    const response = await handle(post(route, body, { token: TOKEN_CLIENT }));
    assert.equal(response.status, 403, route);
    assert.deepEqual(await json(response), { error: "forbidden" });
    assert.ok(logs.some((entry) => entry.event === "forbidden" && entry.fields["route"] === route && entry.fields["userId"] === USER_CLIENT));
  }
  assert.deepEqual(store.chefLookups, [USER_CLIENT, USER_CLIENT, USER_CLIENT], "la cocinera se busca por el usuario del token");
  assert.equal(store.bookingCalls.length + store.moveCalls.length + store.cancelCalls.length, 0);
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
    [{ groceriesEstCents: 75.5 }, { errors: { groceriesEstCents: "invalid" } }],
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
      p_groceries_est_cents: 7550,
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
// Logs
// ---------------------------------------------------------------------------

test("los logs nunca llevan nombre, teléfono, email, zona, dirección, notas, restricciones ni fechas", async () => {
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

  const markers = [
    "Mariaxyz", "Bianchiqwe", "765", "4321", "maria.pii", "ZonaPrivadaKkk", "Segretissima", "NOTA-LIBRE", "NOTA-SALUD",
    "2026-11-23", "2026-11-30", TOKEN_EVELYN, TOKEN_REJECTED, TOKEN_CLIENT,
  ];
  const runs = [success, dbError, crash, invalid, conflict, auth, authDown, config, shape, getter, sessionErrors];
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
    "sessions_cancelled", "db_error", "unexpected_result", "unexpected_error", "config_missing",
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

test("readChefConfig: orígenes de ALLOWED_ORIGINS y lo que falta de Supabase", () => {
  const config = readChefConfig((name) => ENV[name]);
  assert.equal(config.allowedOrigins.length, 2);
  assert.deepEqual(config.missing, []);
  assert.deepEqual(chefConfigWarnings(config), []);

  const empty = readChefConfig(() => undefined);
  assert.deepEqual(empty.missing, ["SUPABASE_URL", "SUPABASE_SECRET_KEYS"]);
  assert.deepEqual(chefConfigWarnings(empty), ["ALLOWED_ORIGINS"], "sin CORS la app web no la puede llamar (la nativa sí)");

  const legacy = readChefConfig((name) => ({ SUPABASE_URL: " http://x ", SUPABASE_SERVICE_ROLE_KEY: "legacy" })[name]);
  assert.deepEqual(legacy.missing, []);
});
