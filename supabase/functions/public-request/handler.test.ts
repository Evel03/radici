// Tests de la Edge Function public-request con dependencias simuladas (contrato §2, §4 y §5).
// Correr con: npm test (node --test). La función real (index.ts) solo conecta Supabase y Deno.
import { test } from "node:test";
import assert from "node:assert/strict";
import { AVAILABILITY_DAYS, AVAILABILITY_PATH, buildAvailabilityResponse } from "../_shared/availability.ts";
import { hashSubject } from "../_shared/client_ip.ts";
import { MENU_PATH, buildMenuResponse, type MenuChoice, type MenuDish } from "../_shared/menu.ts";
import { CONSENT_VERSION, PUBLIC_REQUEST_VERSION, publicEstimate, type PublicRequestPayload } from "../_shared/public_request.ts";
import { DEFAULT_PRICING, calcQuote } from "../_shared/quote.ts";
import { RESEND_API_URL } from "../_shared/resend.ts";
import { TURNSTILE_VERIFY_URL } from "../_shared/turnstile.ts";
import {
  AVAILABILITY_CACHE_CONTROL,
  AVAILABILITY_RATE_LIMITS,
  CHEF_SETTINGS_COLUMNS,
  DEFAULT_CHEF_LOCALE,
  MENU_CACHE_CONTROL,
  MENU_RATE_LIMITS,
  RATE_LIMITS,
  StoreError,
  availabilityRateSubject,
  availableDatesFromRpc,
  menuRateSubject,
  chefFromRow,
  configWarnings,
  createPublicRequestHandler,
  missingRequiredConfig,
  readConfig,
  resolveServiceKey,
  safeDbMessage,
  submitResultFromRpc,
  type ChefInfo,
  type DefaultChef,
  type HandlerDeps,
  type LogFields,
  type PublicRequestStore,
  type SubmitPublicRequestParams,
  type SubmitResult,
} from "./handler.ts";

const CHEF_ID = "cef00000-0000-4000-8000-000000000001";
const OTHER_CHEF_ID = "cef00000-0000-4000-8000-000000000002";
const REQUEST_ID = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";
const REQUEST_KEY = "3f2b8c1e-9a4d-4c7b-8e2f-0123456789ab";
const NOW = new Date("2026-10-19T10:00:00Z");
const ENDPOINT = "http://127.0.0.1:54321/functions/v1/public-request";
// MARCADOR: el subdominio real de Pages del proyecto "radici" todavía no se conoce (ver cors.test.ts).
const PAGES = "radici-placeholder.pages.dev";

// Como en producción: sin vistas previas de Pages (crearían pedidos reales, contrato §4).
const ENV: Record<string, string> = {
  CHEF_ID,
  TURNSTILE_SECRET_KEY: "1x0000000000000000000000000000000AA",
  IP_HASH_SALT: "sal-de-prueba",
  RESEND_API_KEY: "re_prueba",
  MAIL_FROM: "Radici <ciao@radicicucina.app>",
  MAIL_REPLY_TO: "evelyn.respuestas@example.test",
  CHEF_NOTIFY_EMAIL: "evelyn@example.test",
  CHEF_LOCALE: "es",
  ALLOWED_ORIGINS: "https://radicicucina.app,http://localhost:5173",
  INBOX_URL: "https://radicicucina.app/gestione/",
  PUBLIC_SITE_URL: "https://radicicucina.app",
  WHATSAPP_TOKEN: "EAAprueba",
  WHATSAPP_PHONE_NUMBER_ID: "106540352242922",
  WHATSAPP_TEMPLATE: "richiesta_ricevuta",
};

// Datos personales con marcas fáciles de buscar en los logs. Con alergias escritas (y, para buscar
// fugas, también un alérgeno del contrato, que la web de hoy manda vacío).
function payload(overrides: Partial<PublicRequestPayload> = {}): PublicRequestPayload {
  return {
    version: PUBLIC_REQUEST_VERSION,
    type: "week",
    adults: 2,
    kids: 2,
    days: 5,
    meals: ["dinner"],
    weeks: 1,
    noAllergies: false,
    allergens: ["milk"],
    diets: [],
    restrictionsNote: "NOTA-SALUD-zzz",
    preferredDate: "2026-10-25",
    slot: "afternoon",
    name: "Giuliaxyz Rossiqwe",
    zone: "ZonaPrivadaKkk",
    phone: "+39 333 765 4321",
    email: "giulia.pii@example.test",
    whatsappOptIn: true,
    notes: "NOTA-LIBRE-yyy",
    locale: "it",
    consents: { privacy: CONSENT_VERSION, health: CONSENT_VERSION },
    turnstileToken: "XXXX.DUMMY.TOKEN.XXXX",
    ...overrides,
  };
}

// Tarifas distintas de las de la web (DEFAULT_PRICING): el servidor calcula con las de la cocinera.
const CHEF: ChefInfo = {
  displayName: "Evelyn",
  pricing: { ...DEFAULT_PRICING, weeklyRateCents: 16000, weeklyRateDiscountedCents: 15000 },
};

// Platos publicados de la cocinera (get_public_menu). Las lasagne, solo de octubre a diciembre; el
// minestrone, todo el año y sin traducción al español. UNPUBLISHED_ID: un plato que se despublicó entre la
// carga de la página y el envío.
const LASAGNE: MenuDish = {
  id: "0a1b2c3d-4e5f-4a6b-8c7d-0123456789ab",
  name: { it: "Lasagne", es: "Lasaña", en: null },
  description: { it: "Ragù e besciamella.", es: null, en: null },
  allergens: ["gluten", "eggs", "milk"],
  diet: null,
  seasonMonths: [10, 11, 12],
};
const MINESTRONE: MenuDish = {
  id: "1a1b2c3d-4e5f-4a6b-8c7d-0123456789ab",
  name: { it: "Minestrone", es: null, en: "Minestrone soup" },
  description: { it: "Verdure di stagione.", es: null, en: null },
  allergens: ["celery"],
  diet: "vegan",
  seasonMonths: null,
};
const UNPUBLISHED_ID = "2a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";

/** Lo que guarda submit_public_request de un plato: el id y el nombre actual. */
function choiceOf(dish: MenuDish): MenuChoice {
  return { id: dish.id, name: dish.name };
}

/** Id del n-ésimo pedido guardado (el primero, REQUEST_ID). */
function requestIdFor(n: number): string {
  return n === 0 ? REQUEST_ID : `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
}

/**
 * Base simulada. submit se comporta como public.submit_public_request: con una request_key ya
 * guardada devuelve ese pedido (duplicate) con la estimación guardada y no guarda nada.
 */
class FakeStore implements PublicRequestStore {
  allow = true;
  chef: ChefInfo | null = CHEF;
  /** Filas de public.chefs (para resolveDefaultChef sin CHEF_ID). */
  chefIds: string[] = [CHEF_ID];
  failOn: "rate" | "resolve" | "chef" | "submit" | "mark" | "freeDays" | "menu" | null = null;
  /** true: como hit_public_request_rate, cuenta los intentos de cada clave y aplica los límites (si no, responde allow). */
  countHits = false;
  hits: Array<{ ipHash: string; maxHour: number; maxDay: number }> = [];
  resolveCalls = 0;
  loadedChefIds: string[] = [];
  /** Lo que llegó a submit (también los duplicados). */
  calls: SubmitPublicRequestParams[] = [];
  /** Lo que se guardó de verdad (sin los duplicados). */
  submitted: SubmitPublicRequestParams[] = [];
  byKey = new Map<string, SubmitResult>();
  marked: string[] = [];
  /** Fechas que public.get_free_days marca con available = true. */
  freeDates: string[] = [];
  freeDaysCalls: Array<{ chefId: string; cookMinutes: number; fromDate: string; days: number }> = [];
  /** Platos publicados (get_public_menu). */
  dishes: MenuDish[] = [LASAGNE, MINESTRONE];
  menuCalls: string[] = [];

  async hitRateLimit(ipHash: string, maxHour: number, maxDay: number): Promise<boolean> {
    if (this.failOn === "rate") throw new StoreError("rate_limit", "57014", null);
    this.hits.push({ ipHash, maxHour, maxDay });
    if (!this.countHits) return this.allow;
    const count = this.hits.filter((hit) => hit.ipHash === ipHash).length;
    return count <= maxHour && count <= maxDay;
  }

  async publicMenu(chefId: string): Promise<MenuDish[]> {
    if (this.failOn === "menu") throw new StoreError("public_menu", "57014", null);
    this.menuCalls.push(chefId);
    return [...this.dishes];
  }

  async freeDays(chefId: string, cookMinutes: number, fromDate: string, days: number): Promise<string[]> {
    if (this.failOn === "freeDays") throw new StoreError("free_days", "57014", null);
    this.freeDaysCalls.push({ chefId, cookMinutes, fromDate, days });
    return [...this.freeDates];
  }

  async resolveDefaultChef(): Promise<DefaultChef> {
    this.resolveCalls++;
    if (this.failOn === "resolve") throw new StoreError("resolve_chef", "PGRST301", null);
    const [first, second] = this.chefIds;
    if (first === undefined) return { ok: false, reason: "no_chef" };
    if (second !== undefined) return { ok: false, reason: "multiple_chefs" };
    return { ok: true, chefId: first };
  }

  async loadChef(chefId: string): Promise<ChefInfo | null> {
    if (this.failOn === "chef") throw new StoreError("load_chef", "PGRST301", null);
    this.loadedChefIds.push(chefId);
    return this.chefIds.includes(chefId) ? this.chef : null;
  }

  async submit(params: SubmitPublicRequestParams): Promise<SubmitResult> {
    if (this.failOn === "submit") throw new StoreError("submit", "23514", null);
    this.calls.push(params);
    const existing = params.request_key ? this.byKey.get(`${params.chef_id}:${params.request_key}`) : undefined;
    if (existing) return { ...existing, duplicate: true };
    // Como la base: solo los platos publicados, en el orden en que llegaron, con su nombre actual.
    const storedMenu = params.wishes.flatMap((id) => this.dishes.filter((dish) => dish.id === id).map(choiceOf));
    const saved: SubmitResult = {
      requestId: requestIdFor(this.submitted.length),
      duplicate: false,
      storedEstimate: params.estimate,
      storedMenu,
    };
    this.submitted.push(params);
    if (params.request_key) this.byKey.set(`${params.chef_id}:${params.request_key}`, saved);
    return saved;
  }

  async markChefNotificationSent(requestId: string): Promise<void> {
    if (this.failOn === "mark") throw new StoreError("mark_sent", "42501", null);
    this.marked.push(requestId);
  }
}

interface Harness {
  handle: (req: Request) => Promise<Response>;
  store: FakeStore;
  logs: Array<{ level: string; event: string; fields: LogFields }>;
  fetchCalls: Array<{ url: string; body: unknown; headers: Headers }>;
  background: Array<Promise<unknown>>;
  settle: () => Promise<void>;
}

interface HarnessOptions {
  env?: Record<string, string | undefined>;
  /** Ahora (por defecto NOW). */
  now?: Date;
  turnstile?: () => Response | Promise<Response>;
  resend?: (body: { to: string[] }) => Response | Promise<Response>;
  whatsapp?: () => Response | Promise<Response>;
}

function harness(options: HarnessOptions = {}): Harness {
  const env: Record<string, string | undefined> = { ...ENV, ...options.env };
  const store = new FakeStore();
  const logs: Harness["logs"] = [];
  const fetchCalls: Harness["fetchCalls"] = [];
  const background: Array<Promise<unknown>> = [];
  const fakeFetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    const body: unknown = init?.body ? JSON.parse(String(init.body)) : null;
    fetchCalls.push({ url, body, headers: new Headers(init?.headers) });
    if (url === TURNSTILE_VERIFY_URL) return options.turnstile ? options.turnstile() : Response.json({ success: true });
    if (url === RESEND_API_URL) {
      return options.resend ? options.resend(body as { to: string[] }) : Response.json({ id: `email-${fetchCalls.length}` });
    }
    if (url.startsWith("https://graph.facebook.com/")) {
      return options.whatsapp ? options.whatsapp() : Response.json({ messages: [{ id: "wamid.1" }] });
    }
    throw new Error(`fetch inesperado: ${url}`);
  };
  const deps: HandlerDeps = {
    config: readConfig((name) => env[name]),
    store,
    fetch: fakeFetch as typeof fetch,
    now: () => options.now ?? NOW,
    waitUntil: (task) => {
      background.push(task);
    },
    log: (level, event, fields = {}) => {
      logs.push({ level, event, fields });
    },
    sleep: async () => {},
    newId: () => "00000000-0000-4000-8000-000000000000",
  };
  return {
    handle: createPublicRequestHandler(deps),
    store,
    logs,
    fetchCalls,
    background,
    settle: async () => {
      await Promise.all(background);
    },
  };
}

function post(body: unknown, headers: Record<string, string> = {}, rawBody?: string): Request {
  return new Request(ENDPOINT, {
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

async function json(response: Response): Promise<unknown> {
  return JSON.parse(await response.text());
}

// ---------------------------------------------------------------------------
// HTTP: método, tipo, tamaño, CORS
// ---------------------------------------------------------------------------

test("OPTIONS: CORS para un origen permitido y nada para otros", async () => {
  const { handle } = harness();
  const allowed = await handle(new Request(ENDPOINT, { method: "OPTIONS", headers: { origin: "https://radicicucina.app" } }));
  assert.equal(allowed.status, 204);
  assert.equal(allowed.headers.get("access-control-allow-origin"), "https://radicicucina.app");
  // GET por la disponibilidad del calendario (contrato §11), POST por el pedido.
  assert.equal(allowed.headers.get("access-control-allow-methods"), "GET, POST, OPTIONS");
  assert.match(allowed.headers.get("access-control-allow-headers") ?? "", /content-type/);

  const other = await handle(new Request(ENDPOINT, { method: "OPTIONS", headers: { origin: "https://evil.example" } }));
  assert.equal(other.status, 204);
  assert.equal(other.headers.get("access-control-allow-origin"), null);
  assert.equal(other.headers.get("access-control-allow-methods"), null);
});

test("vistas previas de Pages: fuera por defecto; se habilitan a mano agregando su origen", async () => {
  // Con la lista de producción el navegador no pasa del preflight: la vista previa no crea pedidos.
  const prod = harness();
  const blocked = await prod.handle(new Request(ENDPOINT, { method: "OPTIONS", headers: { origin: `https://pr-12.${PAGES}` } }));
  assert.equal(blocked.headers.get("access-control-allow-origin"), null);

  // Habilitada temporalmente (contrato §4): el origen exacto de esa vista previa, o el comodín.
  for (const extra of [`https://pr-12.${PAGES}`, `https://*.${PAGES}`]) {
    const preview = harness({ env: { ALLOWED_ORIGINS: `${ENV["ALLOWED_ORIGINS"]},${extra}` } });
    const response = await preview.handle(new Request(ENDPOINT, { method: "OPTIONS", headers: { origin: `https://pr-12.${PAGES}` } }));
    assert.equal(response.headers.get("access-control-allow-origin"), `https://pr-12.${PAGES}`, extra);
  }
});

test("método distinto de POST: 405 con Allow", async () => {
  const { handle } = harness();
  for (const method of ["GET", "PUT", "DELETE"]) {
    const response = await handle(new Request(ENDPOINT, { method, headers: { origin: "https://radicicucina.app" } }));
    assert.equal(response.status, 405);
    assert.deepEqual(await json(response), { error: "method" });
    assert.equal(response.headers.get("allow"), "POST, OPTIONS");
    assert.equal(response.headers.get("access-control-allow-origin"), "https://radicicucina.app");
  }
});

test("Content-Type que no es JSON: 415", async () => {
  const { handle, store } = harness();
  for (const type of ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x", ""]) {
    const response = await handle(post(payload(), { "content-type": type }));
    assert.equal(response.status, 415, type);
    assert.deepEqual(await json(response), { error: "contentType" });
  }
  const ok = await handle(post(payload(), { "content-type": "Application/JSON; charset=UTF-8" }));
  assert.equal(ok.status, 201);
  assert.equal(store.submitted.length, 1);
});

test("cuerpo de más de 8 KB: 413, por Content-Length o leyéndolo", async () => {
  const { handle, store } = harness();
  const declared = await handle(post(payload(), { "content-length": "9000" }));
  assert.equal(declared.status, 413);
  assert.deepEqual(await json(declared), { error: "tooLarge" });

  const big = JSON.stringify({ ...payload(), notes: "x".repeat(9000) });
  const streamed = await handle(post(null, {}, big));
  assert.equal(streamed.status, 413);
  assert.equal(store.hits.length, 0);
});

test("JSON roto, vacío o UTF-8 inválido: 400 payload invalid", async () => {
  const { handle } = harness();
  for (const raw of ["{no es json", "", "[1,2"]) {
    const response = await handle(post(null, {}, raw));
    assert.equal(response.status, 400);
    assert.deepEqual(await json(response), { errors: { payload: "invalid" } });
  }
  const invalidUtf8 = new Request(ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: new Uint8Array([0x7b, 0xff, 0xfe, 0x7d]),
  });
  assert.equal((await handle(invalidUtf8)).status, 400);
});

test("validación: 400 con los códigos por campo y sin tocar la base", async () => {
  const { handle, store, fetchCalls } = harness();
  const response = await handle(post(payload({ email: "", adults: 0, kids: 0, consents: { privacy: CONSENT_VERSION, health: null } })));
  assert.equal(response.status, 400);
  assert.deepEqual(await json(response), {
    errors: { people: "range", email: "required", consentHealth: "healthConsentRequired" },
  });
  assert.equal(store.hits.length, 0);
  assert.equal(fetchCalls.length, 0);
});

test("fecha fuera de la ventana según la fecha de Roma de hoy", async () => {
  const { handle } = harness();
  const response = await handle(post(payload({ preferredDate: "2026-10-19" })));
  assert.equal(response.status, 400);
  assert.deepEqual(await json(response), { errors: { preferredDate: "dateOutOfRange" } });

  // Hasta 8 semanas: el último día (+56) entra y el siguiente no.
  const last = harness({ env: { EMAIL_TRANSPORT: "log" } });
  assert.equal((await last.handle(post(payload({ preferredDate: "2026-12-14" })))).status, 201);
  await last.settle();
  const after = await handle(post(payload({ preferredDate: "2026-12-15" })));
  assert.equal(after.status, 400);
  assert.deepEqual(await json(after), { errors: { preferredDate: "dateOutOfRange" } });
});

// ---------------------------------------------------------------------------
// Límite por IP y Turnstile
// ---------------------------------------------------------------------------

test("límite por IP: 429 con Retry-After, sin Turnstile ni guardado; la IP viaja hasheada", async () => {
  const { handle, store, fetchCalls } = harness();
  store.allow = false;
  const response = await handle(post(payload()));
  assert.equal(response.status, 429);
  assert.deepEqual(await json(response), { error: "rateLimited" });
  assert.equal(response.headers.get("retry-after"), "3600");
  assert.equal(response.headers.get("access-control-expose-headers"), "Retry-After");
  assert.equal(store.submitted.length, 0);
  assert.equal(fetchCalls.length, 0);
  assert.equal(store.hits.length, 1);
  assert.match(store.hits[0]?.ipHash ?? "", /^[0-9a-f]{64}$/);
  assert.deepEqual([store.hits[0]?.maxHour, store.hits[0]?.maxDay], [RATE_LIMITS.perHour, RATE_LIMITS.perDay]);
  assert.deepEqual(RATE_LIMITS, { perHour: 5, perDay: 20 });
});

test("misma IP → mismo hash; otra IP u otra sal → otro", async () => {
  const a = harness();
  await a.handle(post(payload()));
  await a.handle(post(payload(), { "cf-connecting-ip": "203.0.113.7" }));
  await a.handle(post(payload(), { "cf-connecting-ip": "203.0.113.8" }));
  const [first, second, third] = a.store.hits.map((hit) => hit.ipHash);
  assert.equal(first, second);
  assert.notEqual(first, third);

  const b = harness({ env: { IP_HASH_SALT: "otra-sal" } });
  await b.handle(post(payload()));
  assert.notEqual(b.store.hits[0]?.ipHash, first);
});

test("Turnstile: manda el token y la IP; si lo rechaza, 403 y no guarda", async () => {
  const { handle, store, fetchCalls } = harness({
    turnstile: () => Response.json({ success: false, "error-codes": ["invalid-input-response"] }),
  });
  const response = await handle(post(payload()));
  assert.equal(response.status, 403);
  assert.deepEqual(await json(response), { errors: { turnstileToken: "invalid" } });
  assert.equal(store.submitted.length, 0);
  assert.deepEqual(fetchCalls[0]?.body, {
    secret: ENV["TURNSTILE_SECRET_KEY"],
    response: "XXXX.DUMMY.TOKEN.XXXX",
    remoteip: "203.0.113.7",
    idempotency_key: "00000000-0000-4000-8000-000000000000",
  });
});

test("Turnstile caído o con el secreto mal configurado: 500", async () => {
  for (const turnstile of [
    () => new Response("", { status: 503 }),
    () => Response.json({ success: false, "error-codes": ["invalid-input-secret"] }),
  ]) {
    const { handle, store, logs } = harness({ turnstile });
    const response = await handle(post(payload()));
    assert.equal(response.status, 500);
    assert.deepEqual(await json(response), { error: "server" });
    assert.equal(store.submitted.length, 0);
    assert.ok(logs.some((entry) => entry.level === "error" && entry.event.startsWith("turnstile_")));
  }
});

// ---------------------------------------------------------------------------
// Configuración y errores internos
// ---------------------------------------------------------------------------

test("falta configuración obligatoria o CHEF_ID mal escrito: 500 sin consultar la base, y el log dice qué", async () => {
  const { handle, store, logs } = harness({ env: { TURNSTILE_SECRET_KEY: undefined, CHEF_ID: "no-es-uuid" } });
  const response = await handle(post(payload()));
  assert.equal(response.status, 500);
  assert.deepEqual(await json(response), { error: "server" });
  assert.equal(store.hits.length, 0);
  assert.equal(store.resolveCalls, 0, "un CHEF_ID inválido no cae en la cocinera por defecto");
  assert.deepEqual(logs.find((item) => item.event === "config_missing")?.fields["missing"], ["TURNSTILE_SECRET_KEY"]);
  assert.deepEqual(logs.find((item) => item.event === "config_invalid")?.fields["invalid"], ["CHEF_ID"]);

  const onlyInvalid = harness({ env: { CHEF_ID: "no-es-uuid" } });
  assert.equal((await onlyInvalid.handle(post(payload()))).status, 500);
  assert.equal(onlyInvalid.store.hits.length, 0);
  assert.ok(!onlyInvalid.logs.some((item) => item.event === "config_missing"));
});

test("errores de la base: 500 sin detalles; el log lleva solo la operación y el código", async () => {
  for (const failOn of ["rate", "chef", "submit"] as const) {
    const { handle, store, logs } = harness();
    store.failOn = failOn;
    const response = await handle(post(payload()));
    assert.equal(response.status, 500, failOn);
    assert.deepEqual(await json(response), { error: "server" });
    const entry = logs.find((item) => item.event === "db_error");
    assert.ok(entry, `sin log de ${failOn}`);
    assert.deepEqual(Object.keys(entry?.fields ?? {}).sort(), ["code", "op"]);
  }
});

test("la cocinera de CHEF_ID no existe: 500", async () => {
  const { handle, store, logs } = harness();
  store.chef = null;
  const response = await handle(post(payload()));
  assert.equal(response.status, 500);
  assert.ok(logs.some((entry) => entry.event === "chef_not_found"));
  assert.equal(store.submitted.length, 0);
});

// ---------------------------------------------------------------------------
// Éxito y notificaciones
// ---------------------------------------------------------------------------

test("éxito: 201 con el id y la estimación con las tarifas de la cocinera; guarda el pedido normalizado", async () => {
  const { handle, store, background } = harness();
  const response = await handle(post(payload()));
  assert.equal(response.status, 201);
  assert.equal(response.headers.get("access-control-allow-origin"), "https://radicicucina.app");
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.match(response.headers.get("content-type") ?? "", /^application\/json/);

  const quote = calcQuote({ type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 1 }, CHEF.pricing);
  assert.ok(quote.autoPrice && quote.serviceCents === 16000, "con 160 € por semana el servicio no es el del vector 1");
  assert.deepEqual(await json(response), {
    requestId: REQUEST_ID,
    estimate: {
      weeks: 1,
      portions: 20,
      recipes: 3,
      cookMinutes: 180,
      autoPrice: true,
      weeklyServiceCents: 16000,
      serviceCents: 16000,
      savingsCents: 0,
    },
    menu: [],
  });

  assert.deepEqual(store.submitted[0], {
    chef_id: CHEF_ID,
    type: "week",
    adults: 2,
    kids: 2,
    days: 5,
    meals: ["dinner"],
    weeks: 1,
    no_allergies: false,
    allergens: ["milk"],
    diets: [],
    restrictions_note: "NOTA-SALUD-zzz",
    preferred_date: "2026-10-25",
    preferred_slot: "afternoon",
    name: "Giuliaxyz Rossiqwe",
    zone: "ZonaPrivadaKkk",
    phone: "+393337654321",
    email: "giulia.pii@example.test",
    whatsapp_opt_in: true,
    notes: "NOTA-LIBRE-yyy",
    locale: "it",
    privacy_consent_version: CONSENT_VERSION,
    health_consent_version: CONSENT_VERSION,
    estimate: { ...quote, pricing: CHEF.pricing },
    request_key: null,
    wishes: [],
  });
  // Sin compra (la hace el cliente): ni la estimación ni las tarifas por porción en requests.estimate.
  const stored = store.submitted[0]?.estimate as unknown as Record<string, unknown>;
  for (const key of [...Object.keys(stored), ...Object.keys(stored["pricing"] as object)]) {
    assert.doesNotMatch(key, /grocer|preauth|hold|total|portionCents/i, `requests.estimate no lleva ${key}`);
  }
  assert.equal(background.length, 1, "los envíos van en segundo plano");
});

// ---------------------------------------------------------------------------
// Precio por semana (contrato v3)
// ---------------------------------------------------------------------------

/** Texto de un email por destinatario (después de settle). */
function emailText(run: Harness, to: string): string {
  const call = run.fetchCalls.find((item) => item.url === RESEND_API_URL && (item.body as { to: string[] }).to[0] === to);
  return String((call?.body as Record<string, unknown> | undefined)?.["text"] ?? "");
}

test("4 semanas: weeks a la base, estimación con el descuento de la cocinera y los emails con las semanas, las fechas y el precio", async () => {
  const run = harness();
  const response = await run.handle(post(payload({ weeks: 4 })));
  assert.equal(response.status, 201);
  const quote = calcQuote({ type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 4 }, CHEF.pricing);
  assert.deepEqual((await json(response) as { estimate: unknown }).estimate, publicEstimate(quote));
  assert.ok(quote.autoPrice && quote.weeklyServiceCents === 15000 && quote.serviceCents === 60000 && quote.savingsCents === 4000);
  assert.equal(run.store.submitted[0]?.weeks, 4);
  assert.deepEqual(run.store.submitted[0]?.estimate, { ...quote, pricing: CHEF.pricing });
  await run.settle();
  const chef = emailText(run, "evelyn@example.test");
  for (const line of ["Semanas: 4", "Semanas siguientes: 1 nov · 8 nov · 15 nov", "Servicio por semana: 150,00 €",
    "Servicio, 4 semanas: 600,00 €", "Ahorro: 40,00 € frente a 160,00 € por semana", "Esto es una estimación."]) {
    assert.ok(chef.includes(line), `Evelyn: falta «${line}»`);
  }
  // A Evelyn, nada de compra.
  assert.doesNotMatch(chef, /compra/i);
  const client = emailText(run, "giulia.pii@example.test");
  for (const line of ["Settimane: 4", "Settimane successive: 1 nov · 8 nov · 15 nov", "Servizio, 4 settimane: 600,00 €",
    "Risparmio: 40,00 € rispetto a 160,00 € a settimana", "Questa è una stima. La spesa la fai tu, con la lista che ti manda Evelyn.",
    "prezzo finale"]) {
    assert.ok(client.includes(line), `cliente: falta «${line}»`);
  }
  assert.doesNotMatch(client, /spesa stimata|scontrino/i);
});

test("versión 2 (la web de antes, sin weeks): se guarda de una semana con la estimación nueva", async () => {
  const run = harness({ env: { EMAIL_TRANSPORT: "log" } });
  const { weeks: _sinSemanas, ...v2 } = payload({ version: 2 });
  const response = await run.handle(post(v2));
  assert.equal(response.status, 201);
  assert.equal(run.store.submitted[0]?.weeks, 1);
  const body = (await json(response)) as { estimate: Record<string, unknown> };
  for (const key of ["portions", "recipes", "cookMinutes", "serviceCents"]) {
    assert.equal(typeof body.estimate[key], "number", key);
  }
  // Desde el 19/11/2026 no hay compra ni total: la página de la versión 2 muestra su propio cálculo.
  for (const key of ["groceriesEstCents", "totalCents"]) assert.ok(!(key in body.estimate), key);
  await run.settle();
});

test("semanas: sin el campo (versión 3), fuera de rango o en una sesión extra → 400 sin tocar la base", async () => {
  const { handle, store } = harness();
  const { weeks: _sinSemanas, ...missing } = payload();
  for (const [body, errors] of [
    [missing, { weeks: "required" }],
    [payload({ weeks: 9 }), { weeks: "range" }],
    [payload({ weeks: 0 }), { weeks: "range" }],
    [payload({ type: "extra", weeks: 2 }), { weeks: "invalid" }],
  ] as const) {
    const response = await handle(post(body));
    assert.equal(response.status, 400, JSON.stringify(errors));
    assert.deepEqual(await json(response), { errors });
  }
  assert.equal(store.hits.length, 0);
});

test("sin precio automático (más personas que el tope de la cocinera o sesión extra): 201 sin claves de precio, se guarda así y los emails lo dicen", async () => {
  // Con el tope de la cocinera, no el de DEFAULT_PRICING: con hasta 6 personas en sus tarifas (como Giulia
  // en el seed), un pedido de 7 dice «más de 6».
  const upTo6: ChefInfo = { ...CHEF, pricing: { ...CHEF.pricing, weeklyRateMaxPeople: 6 } };
  for (const [overrides, reason, chefLine, clientLine, chef] of [
    [{ adults: 3, kids: 3 }, "people", "Más de 5 personas: sin precio automático, prepara tú el presupuesto.",
      "Per più di 5 persone il preventivo per il servizio te lo prepara Evelyn.", CHEF],
    [{ adults: 4, kids: 3 }, "people", "Más de 6 personas: sin precio automático, prepara tú el presupuesto.",
      "Per più di 6 persone il preventivo per il servizio te lo prepara Evelyn.", upTo6],
    [{ type: "extra" as const }, "extra", "Evento o sesión extra: sin precio automático, prepara tú el presupuesto.",
      "Per eventi e sessioni extra il preventivo per il servizio te lo prepara Evelyn.", CHEF],
  ] as const) {
    const run = harness();
    run.store.chef = chef;
    const response = await run.handle(post(payload(overrides)));
    assert.equal(response.status, 201, reason);
    const estimate = ((await json(response)) as { estimate: Record<string, unknown> }).estimate;
    assert.equal(estimate["autoPrice"], false);
    assert.equal(estimate["reason"], reason);
    for (const key of ["weeklyServiceCents", "serviceCents", "savingsCents", "totalCents", "groceriesEstCents"]) {
      assert.ok(!(key in estimate), `${reason}: el 201 no lleva ${key}`);
      assert.ok(!(key in (run.store.submitted[0]?.estimate ?? {})), `${reason}: no se guarda ${key}`);
    }
    await run.settle();
    assert.ok(emailText(run, "evelyn@example.test").includes(chefLine), `${reason}: Evelyn`);
    assert.ok(emailText(run, "giulia.pii@example.test").includes(clientLine), `${reason}: cliente`);
  }
  // Con ese mismo tope, 6 personas sí tienen precio.
  const six = harness();
  six.store.chef = upTo6;
  const priced = ((await json(await six.handle(post(payload({ adults: 3, kids: 3 }))))) as { estimate: Record<string, unknown> }).estimate;
  assert.equal(priced["autoPrice"], true);
  await six.settle();
});

test("tarifas de la cocinera que el motor no acepta: 500 quote_failed sin guardar nada", async () => {
  const run = harness();
  run.store.chef = { displayName: "Evelyn", pricing: { ...DEFAULT_PRICING, weeklyRateDiscountedCents: 99999 } };
  const response = await run.handle(post(payload()));
  assert.equal(response.status, 500);
  assert.ok(run.logs.some((entry) => entry.event === "quote_failed"));
  assert.equal(run.store.submitted.length, 0);
});

test("segundo plano: aviso a Evelyn en su idioma, confirmación al cliente en el suyo, WhatsApp y notificación marcada", async () => {
  const { handle, store, fetchCalls, settle } = harness();
  await handle(post(payload()));
  await settle();

  const emails = fetchCalls.filter((call) => call.url === RESEND_API_URL);
  assert.equal(emails.length, 2);
  const toChef = emails.find((call) => (call.body as { to: string[] }).to[0] === "evelyn@example.test");
  const toClient = emails.find((call) => (call.body as { to: string[] }).to[0] === "giulia.pii@example.test");
  assert.ok(toChef && toClient);

  const chefBody = toChef.body as Record<string, unknown>;
  assert.equal(chefBody["subject"], "Nueva solicitud de Giuliaxyz");
  assert.equal(chefBody["from"], "Radici <ciao@radicicucina.app>");
  assert.equal(chefBody["reply_to"], "giulia.pii@example.test", "Evelyn responde directo al cliente");
  assert.equal(toChef.headers.get("idempotency-key"), `request-${REQUEST_ID}-chef`);
  assert.ok(String(chefBody["html"]).includes(`https://radicicucina.app/gestione/#/richieste/${REQUEST_ID}`));
  assert.ok(String(chefBody["text"]).includes("Indicó restricciones alimentarias: las ves en la app."), "las ve en la app, nunca cuáles");

  const clientBody = toClient.body as Record<string, unknown>;
  assert.equal(clientBody["subject"], "Radici: abbiamo ricevuto la tua richiesta");
  assert.equal(clientBody["reply_to"], "evelyn.respuestas@example.test");
  assert.equal(toClient.headers.get("idempotency-key"), `request-${REQUEST_ID}-client`);
  assert.ok(String(clientBody["text"]).includes("Evelyn ti contatterà al più presto"));
  assert.ok(String(clientBody["html"]).includes('href="https://radicicucina.app/privacy/"'));
  // Al cliente, ni que hay alergias: su email no está verificado y eso también es un dato de salud.
  assert.doesNotMatch(`${String(clientBody["text"])}${String(clientBody["html"])}`, /allerg|intoller|celiach/i);

  for (const call of emails) {
    const body = JSON.stringify(call.body);
    for (const secret of ["NOTA-SALUD-zzz", "NOTA-LIBRE-yyy", "milk"]) {
      assert.ok(!body.includes(secret), `el email lleva ${secret}`);
    }
  }

  const whatsapp = fetchCalls.filter((call) => call.url.startsWith("https://graph.facebook.com/"));
  assert.equal(whatsapp.length, 1);
  assert.equal(whatsapp[0]?.url, "https://graph.facebook.com/v26.0/106540352242922/messages");
  assert.equal((whatsapp[0]?.body as { to: string }).to, "+393337654321");
  assert.deepEqual(whatsAppFirstName(whatsapp[0]?.body), "Giuliaxyz");

  assert.deepEqual(store.marked, [REQUEST_ID]);
});

test("nadie tiene alergias: no_allergies a la base, sin restricciones ni consentimiento de salud; los emails lo confirman", async () => {
  const { handle, store, fetchCalls, settle } = harness();
  const response = await handle(
    post(payload({ noAllergies: true, allergens: [], restrictionsNote: "", consents: { privacy: CONSENT_VERSION, health: CONSENT_VERSION } })),
  );
  assert.equal(response.status, 201);
  assert.deepEqual(
    (({ no_allergies, allergens, diets, restrictions_note, health_consent_version }) =>
      ({ no_allergies, allergens, diets, restrictions_note, health_consent_version }))(store.submitted[0] as SubmitPublicRequestParams),
    { no_allergies: true, allergens: [], diets: [], restrictions_note: "", health_consent_version: null },
    "el consentimiento de salud marcado se descarta: no hay datos de salud",
  );
  await settle();
  const text = (to: string): string =>
    String((fetchCalls.find((call) => call.url === RESEND_API_URL && (call.body as { to: string[] }).to[0] === to)?.body as Record<string, unknown>)["text"]);
  assert.ok(text("evelyn@example.test").includes("Confirmó que nadie tiene alergias, intolerancias ni celiaquía."));
  assert.ok(text("giulia.pii@example.test").includes("Hai confermato che nessuno ha allergie, intolleranze alimentari o celiachia."));
});

test("hay alergias pero sin escribirlas, o la página vieja (versión 1): 400 sin tocar la base", async () => {
  const { handle, store } = harness();
  const empty = await handle(post(payload({ allergens: [], restrictionsNote: "  " })));
  assert.equal(empty.status, 400);
  assert.deepEqual(await json(empty), { errors: { restrictionsNote: "required" } });

  const { noAllergies: _v1, ...old } = payload({ version: 1, noAllergies: true, allergens: [], restrictionsNote: "", consents: { privacy: CONSENT_VERSION, health: null } });
  const outdated = await handle(post(old));
  assert.equal(outdated.status, 400);
  assert.deepEqual(await json(outdated), { errors: { version: "invalid", noAllergies: "invalid" } });
  assert.equal(store.hits.length, 0);
});

/** Texto del parámetro {{first_name}} de la plantilla de WhatsApp. */
function whatsAppFirstName(body: unknown): string | undefined {
  const template = (body as { template?: { components?: Array<{ parameters?: Array<{ text?: string }> }> } }).template;
  return template?.components?.[0]?.parameters?.[0]?.text;
}

test("saludo y WhatsApp: un link (o algo que no parece un nombre) en el nombre no sale hacia el cliente", async () => {
  for (const name of ["https://bit.ly/3xYzAbC Rossiqwe", "paypal-verify.com", "+39 333 765 4321"]) {
    const run = harness();
    await run.handle(post(payload({ name })));
    await run.settle();
    const whatsapp = whatsAppCalls(run);
    assert.equal(whatsapp.length, 1, name);
    assert.equal(whatsAppFirstName(whatsapp[0]?.body), "-", `${name}: el parámetro va genérico`);
    const toClient = resendCalls(run).find((call) => (call.body as { to: string[] }).to[0] === "giulia.pii@example.test");
    const text = String((toClient?.body as Record<string, unknown>)["text"]);
    assert.ok(text.startsWith("Grazie!\n"), `${name}: saludo genérico`);
    for (const leak of ["bit.ly", "paypal", "765"]) {
      assert.ok(!JSON.stringify(toClient?.body).includes(leak), `${name}: el email al cliente lleva ${leak}`);
    }
  }
});

test("sin MAIL_REPLY_TO, las respuestas del cliente van a CHEF_NOTIFY_EMAIL", async () => {
  const { handle, fetchCalls, settle } = harness({ env: { MAIL_REPLY_TO: undefined } });
  await handle(post(payload()));
  await settle();
  const toClient = fetchCalls.find((call) => call.url === RESEND_API_URL && (call.body as { to: string[] }).to[0] === "giulia.pii@example.test");
  assert.equal((toClient?.body as Record<string, unknown>)["reply_to"], "evelyn@example.test");
});

test("EMAIL_TRANSPORT=log: no llama a Resend, registra solo metadatos y marca la notificación", async () => {
  const { handle, store, fetchCalls, logs, settle } = harness({ env: { EMAIL_TRANSPORT: "log", RESEND_API_KEY: undefined } });
  await handle(post(payload({ whatsappOptIn: false })));
  await settle();
  assert.equal(fetchCalls.filter((call) => call.url === RESEND_API_URL).length, 0);
  const logged = logs.filter((entry) => entry.event === "email_logged");
  assert.deepEqual(logged.map((entry) => entry.fields["recipient"]).sort(), ["chef", "client"]);
  assert.deepEqual(store.marked, [REQUEST_ID]);
});

test("un fallo de email no rompe el pedido y deja la notificación sin marcar", async () => {
  const { handle, store, logs, settle } = harness({
    resend: () => Response.json({ name: "validation_error", message: "giulia.pii@example.test no vale" }, { status: 422 }),
  });
  const response = await handle(post(payload()));
  assert.equal(response.status, 201);
  await settle();
  assert.deepEqual(store.marked, []);
  const failures = logs.filter((entry) => entry.event === "email_failed");
  assert.equal(failures.length, 2);
  assert.deepEqual(failures[0]?.fields["errorName"], "validation_error");
});

test("si no se puede marcar la notificación, se registra y no rompe nada", async () => {
  const { handle, store, logs, settle } = harness();
  store.failOn = "mark";
  assert.equal((await handle(post(payload()))).status, 201);
  await settle();
  assert.ok(logs.some((entry) => entry.event === "db_error" && entry.fields["op"] === "mark_sent"));
});

test("sin CHEF_NOTIFY_EMAIL no hay aviso a Evelyn, pero sí confirmación al cliente", async () => {
  const { handle, store, fetchCalls, logs, settle } = harness({ env: { CHEF_NOTIFY_EMAIL: undefined, MAIL_REPLY_TO: undefined } });
  await handle(post(payload()));
  await settle();
  const emails = fetchCalls.filter((call) => call.url === RESEND_API_URL);
  assert.equal(emails.length, 1);
  assert.deepEqual((emails[0]?.body as { to: string[] }).to, ["giulia.pii@example.test"]);
  assert.equal((emails[0]?.body as Record<string, unknown>)["reply_to"], undefined);
  assert.deepEqual(store.marked, []);
  assert.ok(logs.some((entry) => entry.event === "email_skipped" && entry.fields["recipient"] === "chef"));
});

test("sin RESEND_API_KEY o MAIL_FROM no se manda ningún email (y se avisa en el log)", async () => {
  const { handle, fetchCalls, logs, settle } = harness({ env: { MAIL_FROM: undefined } });
  assert.equal((await handle(post(payload()))).status, 201);
  await settle();
  assert.equal(fetchCalls.filter((call) => call.url === RESEND_API_URL).length, 0);
  assert.equal(logs.filter((entry) => entry.event === "email_skipped").length, 2);
});

test("WhatsApp: solo si el cliente aceptó y la integración está configurada", async () => {
  const noOptIn = harness();
  await noOptIn.handle(post(payload({ whatsappOptIn: false })));
  await noOptIn.settle();
  assert.equal(noOptIn.fetchCalls.filter((call) => call.url.startsWith("https://graph.facebook.com/")).length, 0);

  const notConfigured = harness({ env: { WHATSAPP_TOKEN: undefined } });
  await notConfigured.handle(post(payload()));
  await notConfigured.settle();
  assert.equal(notConfigured.fetchCalls.filter((call) => call.url.startsWith("https://graph.facebook.com/")).length, 0);

  const failing = harness({ whatsapp: () => Response.json({ error: { code: 131026, message: "+393337654321" } }, { status: 400 }) });
  assert.equal((await failing.handle(post(payload()))).status, 201);
  await failing.settle();
  const entry = failing.logs.find((item) => item.event === "whatsapp_failed");
  assert.equal(entry?.fields["errorName"], "131026");
});

test("los logs nunca llevan datos personales, de salud ni la IP", async () => {
  const runs = [
    harness(),
    harness({ env: { EMAIL_TRANSPORT: "log" } }),
    harness({ resend: () => Response.json({ name: "x", message: "giulia.pii@example.test" }, { status: 500 }) }),
    harness({ whatsapp: () => Response.json({ error: { code: 1, message: "+393337654321" } }, { status: 400 }) }),
    harness({ env: { CHEF_ID: undefined } }),
  ];
  for (const run of runs) {
    await run.handle(post(payload({ requestKey: REQUEST_KEY })));
    // Y el reintento (duplicado).
    await run.handle(post(payload({ requestKey: REQUEST_KEY })));
    await run.settle();
    const text = JSON.stringify(run.logs);
    for (const secret of ["Giuliaxyz", "Rossiqwe", "giulia.pii", "765", "ZonaPrivadaKkk", "NOTA-SALUD", "NOTA-LIBRE", "203.0.113", "milk"]) {
      assert.ok(!text.includes(secret), `el log lleva ${secret}: ${text}`);
    }
  }
  const ok = runs[0];
  assert.ok(ok?.logs.some((entry) => entry.event === "request_saved" && entry.fields["requestId"] === REQUEST_ID));
  assert.ok(ok?.logs.some((entry) => entry.event === "request_duplicate" && entry.fields["requestId"] === REQUEST_ID));
});

test("sin IP en las cabeceras: se avisa y se usa un contador compartido", async () => {
  const { handle, store, logs } = harness();
  const request = new Request(ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload()),
  });
  assert.equal((await handle(request)).status, 201);
  assert.match(store.hits[0]?.ipHash ?? "", /^[0-9a-f]{64}$/);
  assert.ok(logs.some((entry) => entry.event === "client_ip_missing"));
});

// ---------------------------------------------------------------------------
// Idempotencia (requestKey)
// ---------------------------------------------------------------------------

function resendCalls(run: Harness): Array<{ url: string; body: unknown; headers: Headers }> {
  return run.fetchCalls.filter((call) => call.url === RESEND_API_URL);
}

function whatsAppCalls(run: Harness): Array<{ url: string; body: unknown; headers: Headers }> {
  return run.fetchCalls.filter((call) => call.url.startsWith("https://graph.facebook.com/"));
}

test("requestKey: viaja a la base en minúsculas como request_key", async () => {
  const { handle, store } = harness();
  assert.equal((await handle(post(payload({ requestKey: REQUEST_KEY.toUpperCase() })))).status, 201);
  assert.equal(store.submitted[0]?.request_key, REQUEST_KEY);
});

test("reintento con la misma requestKey: el mismo 201, un solo pedido y los avisos una sola vez", async () => {
  const run = harness();
  const first = await run.handle(post(payload({ requestKey: REQUEST_KEY })));
  await run.settle();
  const second = await run.handle(post(payload({ requestKey: REQUEST_KEY })));
  await run.settle();

  assert.equal(first.status, 201);
  assert.equal(second.status, 201);
  const firstBody = await json(first);
  assert.equal((firstBody as Record<string, unknown>)["duplicate"], undefined, "un pedido nuevo no lleva la marca");
  assert.deepEqual(
    await json(second),
    { ...(firstBody as object), duplicate: true },
    "mismo requestId y la estimación guardada, con duplicate: true (la web avisa si el formulario cambió)",
  );
  assert.equal((firstBody as { requestId: string }).requestId, REQUEST_ID);

  assert.equal(run.store.calls.length, 2, "los dos llegan a submit_public_request");
  assert.equal(run.store.submitted.length, 1, "pero se guarda uno");
  assert.equal(resendCalls(run).length, 2, "un email a Evelyn y uno al cliente, no cuatro");
  assert.equal(whatsAppCalls(run).length, 1, "un solo WhatsApp");
  assert.deepEqual(run.store.marked, [REQUEST_ID], "la notificación se marca una vez");
  assert.equal(run.background.length, 1, "el duplicado no deja tareas en segundo plano");
  assert.ok(run.logs.some((entry) => entry.event === "request_duplicate" && entry.fields["requestId"] === REQUEST_ID));
  assert.equal(run.logs.filter((entry) => entry.event === "request_saved").length, 1);
});

test("dos envíos simultáneos con la misma requestKey: los dos 201 iguales, un pedido, un aviso", async () => {
  const run = harness({ env: { EMAIL_TRANSPORT: "log" } });
  const [a, b] = await Promise.all([
    run.handle(post(payload({ requestKey: REQUEST_KEY }))),
    run.handle(post(payload({ requestKey: REQUEST_KEY }))),
  ]);
  await run.settle();
  assert.deepEqual([a.status, b.status], [201, 201]);
  const bodies = [(await json(a)) as Record<string, unknown>, (await json(b)) as Record<string, unknown>];
  assert.deepEqual(bodies[0]?.["requestId"], bodies[1]?.["requestId"]);
  assert.deepEqual(bodies[0]?.["estimate"], bodies[1]?.["estimate"]);
  assert.deepEqual(bodies.map((body) => body["duplicate"] === true).sort(), [false, true], "uno guardó, el otro es el reintento");
  assert.equal(run.store.submitted.length, 1);
  assert.deepEqual(
    run.logs.filter((entry) => entry.event === "email_logged").map((entry) => entry.fields["recipient"]).sort(),
    ["chef", "client"],
    "cada email una sola vez",
  );
  assert.equal(whatsAppCalls(run).length, 1);
});

test("duplicado: responde con la estimación guardada aunque hoy las tarifas den otra (y aunque pida otras semanas)", async () => {
  const run = harness();
  // El original se guardó con las tarifas de entonces (o la cocinera las cambió después).
  const original = calcQuote({ type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 4 }, DEFAULT_PRICING);
  run.store.byKey.set(`${CHEF_ID}:${REQUEST_KEY}`, {
    requestId: REQUEST_ID,
    duplicate: false,
    storedEstimate: { ...original, pricing: DEFAULT_PRICING },
    storedMenu: [],
  });
  const response = await run.handle(post(payload({ requestKey: REQUEST_KEY, weeks: 2 })));
  await run.settle();
  assert.equal(response.status, 201);
  assert.deepEqual(await json(response), { requestId: REQUEST_ID, estimate: publicEstimate(original), menu: [], duplicate: true });
  assert.equal(run.fetchCalls.filter((call) => call.url !== TURNSTILE_VERIFY_URL).length, 0, "ni emails ni WhatsApp");
  assert.deepEqual(run.store.marked, []);
});

test("duplicado de un pedido guardado antes del precio por semana: la estimación por hora, como una semana con precio y sin compra", async () => {
  const run = harness();
  // La forma de requests.estimate de antes: calcQuote con la tarifa por hora, sin weeks ni autoPrice.
  const stored = {
    adultPortions: 10, kidPortions: 10, portions: 20, recipes: 3, cookMinutes: 180, serviceCents: 7800, groceriesEstCents: 6300,
    preauthCents: 7245, holdCents: 15045, totalCents: 14100,
    pricing: { hourlyRateCents: 2200, travelFeeCents: 1200, adultPortionCents: 380, kidPortionCents: 250, preauthBufferPct: 15, minCookMinutes: 90 },
  };
  // Y sin menu: la base de antes de la versión 4 no lo devolvía.
  run.store.byKey.set(`${CHEF_ID}:${REQUEST_KEY}`, { requestId: REQUEST_ID, duplicate: false, storedEstimate: stored, storedMenu: null });
  const response = await run.handle(post(payload({ requestKey: REQUEST_KEY })));
  assert.equal(response.status, 201);
  assert.deepEqual(await json(response), {
    requestId: REQUEST_ID,
    estimate: {
      weeks: 1, portions: 20, recipes: 3, cookMinutes: 180,
      autoPrice: true, weeklyServiceCents: 7800, serviceCents: 7800, savingsCents: 0,
    },
    menu: [],
    duplicate: true,
  });
  assert.ok(!run.logs.some((entry) => entry.event === "stored_estimate_invalid"));
});

test("duplicado con una estimación guardada rota: responde con la calculada y lo avisa en el log", async () => {
  const run = harness();
  run.store.byKey.set(`${CHEF_ID}:${REQUEST_KEY}`, { requestId: REQUEST_ID, duplicate: false, storedEstimate: { totalCents: "x" }, storedMenu: [] });
  const response = await run.handle(post(payload({ requestKey: REQUEST_KEY })));
  assert.equal(response.status, 201);
  const quote = calcQuote({ type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 1 }, CHEF.pricing);
  assert.deepEqual((await json(response) as { estimate: unknown }).estimate, publicEstimate(quote));
  assert.ok(run.logs.some((entry) => entry.event === "stored_estimate_invalid" && entry.level === "warn"));
});

test("otra requestKey (u otra vez sin clave) es otro pedido", async () => {
  const run = harness({ env: { EMAIL_TRANSPORT: "log" } });
  await run.handle(post(payload({ requestKey: REQUEST_KEY })));
  await run.handle(post(payload({ requestKey: "7d0e1c55-2b1a-4f7e-9c3d-aabbccddeeff" })));
  await run.handle(post(payload()));
  await run.handle(post(payload()));
  await run.settle();
  assert.equal(run.store.submitted.length, 4);
  assert.equal(run.logs.filter((entry) => entry.event === "email_logged").length, 8);
});

test("submitResultFromRpc: solo acepta {request_id uuid, duplicate bool, estimate, menu}", () => {
  const menu = [choiceOf(LASAGNE)];
  assert.deepEqual(submitResultFromRpc({ request_id: REQUEST_ID, duplicate: true, estimate: { totalCents: 1 }, menu }), {
    requestId: REQUEST_ID,
    duplicate: true,
    storedEstimate: { totalCents: 1 },
    storedMenu: menu,
  });
  // Sin estimate ni menu (la base de antes de la versión 4 no devolvía menu): null, sin fallar.
  assert.deepEqual(submitResultFromRpc({ request_id: REQUEST_ID, duplicate: false }), {
    requestId: REQUEST_ID,
    duplicate: false,
    storedEstimate: null,
    storedMenu: null,
  });
  for (const bad of [REQUEST_ID, null, [], { request_id: "x", duplicate: false }, { request_id: REQUEST_ID }, { request_id: REQUEST_ID, duplicate: "no" }]) {
    assert.equal(submitResultFromRpc(bad), null, JSON.stringify(bad));
  }
});

// ---------------------------------------------------------------------------
// CHEF_ID opcional: la única cocinera de public.chefs
// ---------------------------------------------------------------------------

test("sin CHEF_ID y con una sola cocinera: se usa esa", async () => {
  const run = harness({ env: { CHEF_ID: undefined } });
  run.store.chefIds = [OTHER_CHEF_ID];
  const response = await run.handle(post(payload()));
  assert.equal(response.status, 201);
  assert.equal(run.store.resolveCalls, 1);
  assert.deepEqual(run.store.loadedChefIds, [OTHER_CHEF_ID]);
  assert.equal(run.store.submitted[0]?.chef_id, OTHER_CHEF_ID);
});

test("sin CHEF_ID y sin cocineras (antes de promote_to_chef) o con varias: 500 con un código claro", async () => {
  for (const [chefIds, reason] of [[[], "no_chef"], [[CHEF_ID, OTHER_CHEF_ID], "multiple_chefs"]] as const) {
    const run = harness({ env: { CHEF_ID: undefined } });
    run.store.chefIds = [...chefIds];
    const response = await run.handle(post(payload()));
    assert.equal(response.status, 500, reason);
    assert.deepEqual(await json(response), { error: "server" });
    assert.deepEqual(run.logs.find((entry) => entry.event === "chef_id_unresolved")?.fields, { reason });
    assert.equal(run.store.loadedChefIds.length, 0);
    assert.equal(run.store.submitted.length, 0);
  }
});

test("con CHEF_ID no se busca la cocinera por defecto (aunque haya varias)", async () => {
  const run = harness();
  run.store.chefIds = [CHEF_ID, OTHER_CHEF_ID];
  assert.equal((await run.handle(post(payload()))).status, 201);
  assert.equal(run.store.resolveCalls, 0);
  assert.equal(run.store.submitted[0]?.chef_id, CHEF_ID);
});

test("sin CHEF_ID, si la búsqueda falla: 500 y db_error con la operación", async () => {
  const run = harness({ env: { CHEF_ID: undefined } });
  run.store.failOn = "resolve";
  assert.equal((await run.handle(post(payload()))).status, 500);
  assert.deepEqual(run.logs.find((entry) => entry.event === "db_error")?.fields, { op: "resolve_chef", code: "PGRST301" });
});

// ---------------------------------------------------------------------------
// Emails: idioma de Evelyn y asuntos
// ---------------------------------------------------------------------------

test("sin CHEF_LOCALE, el aviso a Evelyn sale en español (Radici)", async () => {
  const run = harness({ env: { CHEF_LOCALE: undefined } });
  await run.handle(post(payload()));
  await run.settle();
  const toChef = resendCalls(run).find((call) => (call.body as { to: string[] }).to[0] === "evelyn@example.test");
  const body = toChef?.body as Record<string, unknown>;
  assert.equal(body["subject"], "Nueva solicitud de Giuliaxyz");
  assert.ok(String(body["text"]).includes("Abrir en la bandeja"));
  assert.ok(String(body["text"]).includes("Aviso automático de Radici."));
});

test("ningún asunto lleva teléfono, email, zona ni datos de salud, aunque el cliente los escriba en el nombre", async () => {
  for (const name of ["+39 333 765 4321", "3337654321 Rossiqwe", "giulia.pii@example.test", "Giuliaxyz"]) {
    const run = harness();
    await run.handle(post(payload({ name, restrictionsNote: "NOTA-SALUD-zzz" })));
    await run.settle();
    const subjects = resendCalls(run).map((call) => String((call.body as Record<string, unknown>)["subject"]));
    assert.equal(subjects.length, 2);
    for (const subject of subjects) {
      for (const secret of ["765", "@", "ZonaPrivadaKkk", "NOTA-SALUD", "milk", "Rossiqwe"]) {
        assert.ok(!subject.includes(secret), `el asunto "${subject}" lleva ${secret}`);
      }
    }
    if (name !== "Giuliaxyz") assert.ok(subjects.includes("Nueva solicitud desde la web"), name);
  }
});

// ---------------------------------------------------------------------------
// Disponibilidad por día: GET …/availability?minutes=N (contrato §11)
// ---------------------------------------------------------------------------

const AVAILABILITY_URL = `${ENDPOINT}${AVAILABILITY_PATH}`;

function getAvailability(query: string, headers: Record<string, string> = {}, method = "GET"): Request {
  return new Request(`${AVAILABILITY_URL}${query}`, {
    method,
    headers: { origin: "https://radicicucina.app", "cf-connecting-ip": "203.0.113.7", ...headers },
  });
}

type AvailabilityBody = { days: Array<{ date: string; available: boolean }> };

test("disponibilidad: 200 con los 56 días desde mañana en Roma, marcados según get_free_days", async () => {
  const run = harness();
  run.store.freeDates = ["2026-10-21", "2026-10-22", "2026-11-02", "2026-12-14"];
  // forceFunctionRegion lo agrega la web (como en el POST); la función no lo lee.
  const response = await run.handle(getAvailability("?minutes=180&forceFunctionRegion=eu-central-1"));
  assert.equal(response.status, 200);
  const body = await json(response);
  assert.deepEqual(body, buildAvailabilityResponse("2026-10-19", 180, ["2026-10-21", "2026-10-22", "2026-11-02", "2026-12-14"]));
  const { days } = body as AvailabilityBody;
  assert.equal(days.length, AVAILABILITY_DAYS);
  assert.deepEqual([days[0]?.date, days[55]?.date], ["2026-10-20", "2026-12-14"]);
  assert.deepEqual(
    days.filter((day) => day.available).map((day) => day.date),
    ["2026-10-21", "2026-10-22", "2026-11-02", "2026-12-14"],
  );
  // De mañana a +56 (8 semanas): los mismos días que se pueden elegir en el formulario.
  assert.deepEqual(run.store.freeDaysCalls, [{ chefId: CHEF_ID, cookMinutes: 180, fromDate: "2026-10-20", days: 56 }]);
  assert.equal(run.store.submitted.length, 0);
  assert.equal(run.fetchCalls.length, 0, "es una lectura: sin Turnstile ni avisos");
});

test("disponibilidad: CORS con la misma lista, Vary: Origin y caché pública de un minuto", async () => {
  const { handle } = harness();
  const ok = await handle(getAvailability("?minutes=150"));
  assert.equal(ok.headers.get("access-control-allow-origin"), "https://radicicucina.app");
  assert.equal(ok.headers.get("vary"), "Origin");
  assert.equal(ok.headers.get("cache-control"), "public, max-age=60");
  assert.equal(AVAILABILITY_CACHE_CONTROL, "public, max-age=60");
  assert.match(ok.headers.get("content-type") ?? "", /^application\/json/);

  const other = await handle(getAvailability("?minutes=150", { origin: "https://evil.example" }));
  assert.equal(other.status, 200, "la respuesta sale igual, pero el navegador no deja leerla");
  assert.equal(other.headers.get("access-control-allow-origin"), null);
  assert.equal(other.headers.get("vary"), "Origin");

  const preflight = await handle(new Request(AVAILABILITY_URL, { method: "OPTIONS", headers: { origin: "https://radicicucina.app" } }));
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-methods"), "GET, POST, OPTIONS");
});

test("disponibilidad: \"hoy\" es la fecha de Roma, no la de UTC", async () => {
  // Las 22:30 UTC del 19/10 son las 00:30 del 20/10 en Roma (CEST): la ventana empieza el 21.
  const run = harness({ now: new Date("2026-10-19T22:30:00Z") });
  const response = await run.handle(getAvailability("?minutes=180"));
  assert.equal(response.status, 200);
  assert.equal(run.store.freeDaysCalls[0]?.fromDate, "2026-10-21");
  assert.equal(((await json(response)) as AvailabilityBody).days[0]?.date, "2026-10-21");
});

test("disponibilidad: minutes inválido o ausente → 400 sin tocar la base", async () => {
  const { handle, store } = harness();
  for (const query of ["", "?minutes=", "?minutes=abc", "?minutes=45", "?minutes=0", "?minutes=750", "?minutes=180.5", "?minutos=180"]) {
    const response = await handle(getAvailability(query));
    assert.equal(response.status, 400, query);
    assert.deepEqual(await json(response), { errors: { minutes: "invalid" } });
    assert.equal(response.headers.get("cache-control"), "public, max-age=60", "depende solo de la URL");
  }
  assert.equal(store.hits.length, 0);
  assert.equal(store.freeDaysCalls.length, 0);
});

test("disponibilidad: solo GET (y OPTIONS); otro método → 405 con Allow, y un POST ahí no es un pedido", async () => {
  const { handle, store } = harness();
  for (const method of ["POST", "PUT", "DELETE"]) {
    const response = await handle(getAvailability("?minutes=180", { "content-type": "application/json" }, method));
    assert.equal(response.status, 405, method);
    assert.deepEqual(await json(response), { error: "method" });
    assert.equal(response.headers.get("allow"), "GET, OPTIONS");
  }
  assert.equal(store.calls.length, 0);
  assert.equal(store.hits.length, 0);
});

test("disponibilidad: límite por IP propio y más generoso; las lecturas no gastan el cupo del formulario", async () => {
  const run = harness({ env: { EMAIL_TRANSPORT: "log" } });
  run.store.countHits = true;
  for (let i = 0; i < 10; i++) {
    assert.equal((await run.handle(getAvailability("?minutes=180"))).status, 200);
  }
  assert.equal((await run.handle(post(payload()))).status, 201, "10 lecturas no tocan los 5 pedidos por hora");
  const read = run.store.hits[0];
  const submit = run.store.hits[10];
  assert.equal(read?.ipHash, await hashSubject("availability:203.0.113.7", ENV["IP_HASH_SALT"] ?? ""), "HMAC de availability:<ip>");
  assert.notEqual(read?.ipHash, submit?.ipHash, "otra clave para la misma IP");
  assert.deepEqual([read?.maxHour, read?.maxDay], [AVAILABILITY_RATE_LIMITS.perHour, AVAILABILITY_RATE_LIMITS.perDay]);
  assert.deepEqual([submit?.maxHour, submit?.maxDay], [RATE_LIMITS.perHour, RATE_LIMITS.perDay]);
  assert.deepEqual(AVAILABILITY_RATE_LIMITS, { perHour: 120, perDay: 600 });

  // Y al revés: con el cupo del formulario agotado, el calendario sigue leyendo.
  for (let i = 0; i < 4; i++) assert.equal((await run.handle(post(payload()))).status, 201);
  assert.equal((await run.handle(post(payload()))).status, 429);
  assert.equal((await run.handle(getAvailability("?minutes=180"))).status, 200);
  await run.settle();
});

test("disponibilidad: pasado el límite → 429 con Retry-After, sin consultar los días", async () => {
  const { handle, store, logs } = harness();
  store.allow = false;
  const response = await handle(getAvailability("?minutes=180"));
  assert.equal(response.status, 429);
  assert.deepEqual(await json(response), { error: "rateLimited" });
  assert.equal(response.headers.get("retry-after"), "3600");
  assert.equal(response.headers.get("access-control-expose-headers"), "Retry-After");
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(store.freeDaysCalls.length, 0);
  assert.ok(logs.some((entry) => entry.event === "rate_limited" && entry.fields["route"] === "availability"));
});

test("disponibilidad: error de la base → 503 sin detalles; el log lleva solo la operación y el código", async () => {
  for (const [failOn, op] of [["freeDays", "free_days"], ["rate", "rate_limit"]] as const) {
    const { handle, store, logs } = harness();
    store.failOn = failOn;
    const response = await handle(getAvailability("?minutes=180"));
    assert.equal(response.status, 503, failOn);
    assert.deepEqual(await json(response), { error: "server" });
    assert.equal(response.headers.get("cache-control"), "no-store", "un error no queda en la caché");
    const entry = logs.find((item) => item.event === "db_error");
    assert.deepEqual(Object.keys(entry?.fields ?? {}).sort(), ["code", "op"]);
    assert.equal(entry?.fields["op"], op);
  }
  // Sin CHEF_ID, si falla la búsqueda de la cocinera, también.
  const run = harness({ env: { CHEF_ID: undefined } });
  run.store.failOn = "resolve";
  assert.equal((await run.handle(getAvailability("?minutes=180"))).status, 503);
  assert.deepEqual(run.logs.find((entry) => entry.event === "db_error")?.fields, { op: "resolve_chef", code: "PGRST301" });
});

test("disponibilidad: sin CHEF_ID usa la única cocinera; sin ninguna o con varias → 500", async () => {
  const run = harness({ env: { CHEF_ID: undefined } });
  run.store.chefIds = [OTHER_CHEF_ID];
  assert.equal((await run.handle(getAvailability("?minutes=150"))).status, 200);
  assert.equal(run.store.freeDaysCalls[0]?.chefId, OTHER_CHEF_ID);

  for (const [chefIds, reason] of [[[], "no_chef"], [[CHEF_ID, OTHER_CHEF_ID], "multiple_chefs"]] as const) {
    const other = harness({ env: { CHEF_ID: undefined } });
    other.store.chefIds = [...chefIds];
    const response = await other.handle(getAvailability("?minutes=150"));
    assert.equal(response.status, 500, reason);
    assert.deepEqual(await json(response), { error: "server" });
    assert.deepEqual(other.logs.find((entry) => entry.event === "chef_id_unresolved")?.fields, { reason });
    assert.equal(other.store.freeDaysCalls.length, 0);
  }
});

test("disponibilidad: solo necesita IP_HASH_SALT (Turnstile es del formulario) y, si está, un CHEF_ID válido", async () => {
  const noTurnstile = harness({ env: { TURNSTILE_SECRET_KEY: undefined } });
  assert.equal((await noTurnstile.handle(getAvailability("?minutes=180"))).status, 200);

  const noSalt = harness({ env: { IP_HASH_SALT: undefined } });
  const response = await noSalt.handle(getAvailability("?minutes=180"));
  assert.equal(response.status, 500);
  assert.deepEqual(await json(response), { error: "server" });
  assert.deepEqual(noSalt.logs.find((entry) => entry.event === "config_missing")?.fields["missing"], ["IP_HASH_SALT"]);
  assert.equal(noSalt.store.hits.length, 0);

  const badChef = harness({ env: { CHEF_ID: "no-es-uuid" } });
  assert.equal((await badChef.handle(getAvailability("?minutes=180"))).status, 500);
  assert.deepEqual(badChef.logs.find((entry) => entry.event === "config_invalid")?.fields["invalid"], ["CHEF_ID"]);
  assert.equal(badChef.store.hits.length, 0);
  assert.equal(badChef.store.resolveCalls, 0);
});

test("disponibilidad: los logs no llevan la IP; sin IP se avisa y se usa un contador compartido", async () => {
  const ok = harness();
  const auto = harness({ env: { CHEF_ID: undefined } });
  const limited = harness();
  limited.store.allow = false;
  const failing = harness();
  failing.store.failOn = "freeDays";
  for (const run of [ok, auto, limited, failing]) await run.handle(getAvailability("?minutes=180"));
  const noIp = harness();
  assert.equal((await noIp.handle(new Request(`${AVAILABILITY_URL}?minutes=180`))).status, 200);
  for (const run of [ok, auto, limited, failing, noIp]) {
    const text = JSON.stringify(run.logs);
    assert.ok(!text.includes("203.0.113"), `el log lleva la IP: ${text}`);
  }
  assert.ok(noIp.logs.some((entry) => entry.event === "client_ip_missing"));
  assert.equal(noIp.store.hits[0]?.ipHash, await hashSubject("availability:unknown", ENV["IP_HASH_SALT"] ?? ""));
});

test("availabilityRateSubject: la clave del límite del formulario con el prefijo del calendario", () => {
  assert.equal(availabilityRateSubject("203.0.113.7"), "availability:203.0.113.7");
  assert.equal(availabilityRateSubject("2001:db8:1:2:3:4:5:6"), "availability:2001:db8:1:2::/64", "una IPv6 cuenta por su /64");
  assert.equal(availabilityRateSubject(null), "availability:unknown");
});

test("availableDatesFromRpc: las fechas con available = true; cualquier otra forma, null", () => {
  assert.deepEqual(
    availableDatesFromRpc([
      { day: "2026-10-20", available: false },
      { day: "2026-10-21", available: true },
      { day: "2026-10-22", available: true },
    ]),
    ["2026-10-21", "2026-10-22"],
  );
  assert.deepEqual(availableDatesFromRpc([]), []);
  const bad: unknown[] = [
    null,
    {},
    "x",
    [null],
    [{ available: true }],
    [{ day: 20261021, available: true }],
    [{ day: "2026-02-30", available: true }],
    [{ day: "2026-10-21", available: "true" }],
  ];
  for (const data of bad) assert.equal(availableDatesFromRpc(data), null, JSON.stringify(data));
});

// ---------------------------------------------------------------------------
// Menù de la web: GET …/menu (contrato §12)
// ---------------------------------------------------------------------------

const MENU_URL = `${ENDPOINT}${MENU_PATH}`;

function getMenu(headers: Record<string, string> = {}, method = "GET"): Request {
  // forceFunctionRegion lo agrega la web (como en el POST); la función no lo lee.
  return new Request(`${MENU_URL}?forceFunctionRegion=eu-central-1`, {
    method,
    headers: { origin: "https://radicicucina.app", "cf-connecting-ip": "203.0.113.7", ...headers },
  });
}

test("menù: 200 con los platos publicados de la cocinera, CORS con la misma lista y caché pública de un minuto", async () => {
  const run = harness();
  const response = await run.handle(getMenu());
  assert.equal(response.status, 200);
  assert.deepEqual(await json(response), { version: 1, dishes: [LASAGNE, MINESTRONE] });
  assert.equal(response.headers.get("access-control-allow-origin"), "https://radicicucina.app");
  assert.equal(response.headers.get("vary"), "Origin");
  assert.equal(response.headers.get("cache-control"), "public, max-age=60");
  assert.equal(MENU_CACHE_CONTROL, AVAILABILITY_CACHE_CONTROL, "la misma caché que la disponibilidad");
  assert.match(response.headers.get("content-type") ?? "", /^application\/json/);
  assert.deepEqual(run.store.menuCalls, [CHEF_ID]);
  assert.equal(run.store.calls.length, 0);
  assert.equal(run.fetchCalls.length, 0, "es una lectura: sin Turnstile ni avisos");

  // Sin platos publicados: la lista vacía (el formulario dice que el menù lo propone Evelyn).
  const empty = harness();
  empty.store.dishes = [];
  assert.deepEqual(await json(await empty.handle(getMenu())), buildMenuResponse([]));

  const other = await run.handle(getMenu({ origin: "https://evil.example" }));
  assert.equal(other.status, 200, "la respuesta sale igual, pero el navegador no deja leerla");
  assert.equal(other.headers.get("access-control-allow-origin"), null);
  assert.equal(other.headers.get("vary"), "Origin");

  const preflight = await run.handle(new Request(MENU_URL, { method: "OPTIONS", headers: { origin: "https://radicicucina.app" } }));
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-methods"), "GET, POST, OPTIONS");
});

test("menù: solo GET (y OPTIONS); otro método → 405 con Allow, y un POST ahí no es un pedido", async () => {
  const { handle, store } = harness();
  for (const method of ["POST", "PUT", "DELETE"]) {
    const response = await handle(getMenu({ "content-type": "application/json" }, method));
    assert.equal(response.status, 405, method);
    assert.deepEqual(await json(response), { error: "method" });
    assert.equal(response.headers.get("allow"), "GET, OPTIONS");
    assert.equal(response.headers.get("access-control-allow-origin"), "https://radicicucina.app");
  }
  assert.equal(store.calls.length, 0);
  assert.equal(store.hits.length, 0);
  assert.equal(store.menuCalls.length, 0);
});

test("menù: límite por IP propio (HMAC de menu:<ip>); no gasta el cupo del formulario ni el del calendario", async () => {
  const run = harness({ env: { EMAIL_TRANSPORT: "log" } });
  run.store.countHits = true;
  for (let i = 0; i < 10; i++) assert.equal((await run.handle(getMenu())).status, 200);
  assert.equal((await run.handle(post(payload()))).status, 201, "10 lecturas del menù no tocan los 5 pedidos por hora");
  assert.equal((await run.handle(new Request(`${ENDPOINT}${AVAILABILITY_PATH}?minutes=180`, { headers: { "cf-connecting-ip": "203.0.113.7" } }))).status, 200);
  const [menu, submit, availability] = [run.store.hits[0], run.store.hits[10], run.store.hits[11]];
  assert.equal(menu?.ipHash, await hashSubject("menu:203.0.113.7", ENV["IP_HASH_SALT"] ?? ""));
  assert.notEqual(menu?.ipHash, submit?.ipHash);
  assert.notEqual(menu?.ipHash, availability?.ipHash);
  assert.deepEqual([menu?.maxHour, menu?.maxDay], [MENU_RATE_LIMITS.perHour, MENU_RATE_LIMITS.perDay]);
  assert.deepEqual(MENU_RATE_LIMITS, { perHour: 120, perDay: 600 });
  await run.settle();
});

test("menù: pasado el límite → 429 con Retry-After, sin caché y sin leer los platos", async () => {
  const { handle, store, logs } = harness();
  store.allow = false;
  const response = await handle(getMenu());
  assert.equal(response.status, 429);
  assert.deepEqual(await json(response), { error: "rateLimited" });
  assert.equal(response.headers.get("retry-after"), "3600");
  assert.equal(response.headers.get("access-control-expose-headers"), "Retry-After");
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(store.menuCalls.length, 0);
  assert.ok(logs.some((entry) => entry.event === "rate_limited" && entry.fields["route"] === "menu"));
});

test("menù: error de la base → 503 { error: unavailable }, sin detalles ni caché; el log lleva la operación y el código", async () => {
  for (const [failOn, op] of [["menu", "public_menu"], ["rate", "rate_limit"]] as const) {
    const { handle, store, logs } = harness();
    store.failOn = failOn;
    const response = await handle(getMenu());
    assert.equal(response.status, 503, failOn);
    assert.deepEqual(await json(response), { error: "unavailable" });
    assert.equal(response.headers.get("cache-control"), "no-store", "un error no queda en la caché");
    const entry = logs.find((item) => item.event === "db_error");
    assert.deepEqual(entry?.fields, { op, code: "57014" });
  }
  const run = harness({ env: { CHEF_ID: undefined } });
  run.store.failOn = "resolve";
  const response = await run.handle(getMenu());
  assert.equal(response.status, 503);
  assert.deepEqual(await json(response), { error: "unavailable" });
  assert.deepEqual(run.logs.find((entry) => entry.event === "db_error")?.fields, { op: "resolve_chef", code: "PGRST301" });
});

test("menù: solo necesita IP_HASH_SALT y, si está, un CHEF_ID válido; sin CHEF_ID, la única cocinera", async () => {
  const noTurnstile = harness({ env: { TURNSTILE_SECRET_KEY: undefined } });
  assert.equal((await noTurnstile.handle(getMenu())).status, 200);

  const noSalt = harness({ env: { IP_HASH_SALT: undefined } });
  const response = await noSalt.handle(getMenu());
  assert.equal(response.status, 500);
  assert.deepEqual(await json(response), { error: "server" });
  assert.deepEqual(noSalt.logs.find((entry) => entry.event === "config_missing")?.fields["missing"], ["IP_HASH_SALT"]);
  assert.equal(noSalt.store.hits.length, 0);

  const badChef = harness({ env: { CHEF_ID: "no-es-uuid" } });
  assert.equal((await badChef.handle(getMenu())).status, 500);
  assert.equal(badChef.store.hits.length, 0);
  assert.equal(badChef.store.resolveCalls, 0);

  const auto = harness({ env: { CHEF_ID: undefined } });
  auto.store.chefIds = [OTHER_CHEF_ID];
  assert.equal((await auto.handle(getMenu())).status, 200);
  assert.deepEqual(auto.store.menuCalls, [OTHER_CHEF_ID]);
  for (const chefIds of [[], [CHEF_ID, OTHER_CHEF_ID]]) {
    const unresolved = harness({ env: { CHEF_ID: undefined } });
    unresolved.store.chefIds = [...chefIds];
    assert.equal((await unresolved.handle(getMenu())).status, 500);
    assert.equal(unresolved.store.menuCalls.length, 0);
  }
});

test("menù: los logs no llevan la IP ni los platos; sin IP, contador compartido menu:unknown", async () => {
  const ok = harness();
  const limited = harness();
  limited.store.allow = false;
  const failing = harness();
  failing.store.failOn = "menu";
  for (const run of [ok, limited, failing]) await run.handle(getMenu());
  const noIp = harness();
  assert.equal((await noIp.handle(new Request(MENU_URL))).status, 200);
  for (const run of [ok, limited, failing, noIp]) {
    const text = JSON.stringify(run.logs);
    for (const secret of ["203.0.113", "Lasagne", "Minestrone"]) assert.ok(!text.includes(secret), `el log lleva ${secret}: ${text}`);
  }
  assert.ok(noIp.logs.some((entry) => entry.event === "client_ip_missing"));
  assert.equal(noIp.store.hits[0]?.ipHash, await hashSubject("menu:unknown", ENV["IP_HASH_SALT"] ?? ""));
});

test("menuRateSubject: la clave del límite del formulario con el prefijo del menù", () => {
  assert.equal(menuRateSubject("203.0.113.7"), "menu:203.0.113.7");
  assert.equal(menuRateSubject("2001:db8:1:2:3:4:5:6"), "menu:2001:db8:1:2::/64", "una IPv6 cuenta por su /64");
  assert.equal(menuRateSubject(null), "menu:unknown");
});

// ---------------------------------------------------------------------------
// Menù en el pedido (versión 4 del contrato)
// ---------------------------------------------------------------------------

test("pedido con menù: los platos van a la base como wishes, en orden; el 201 trae los que guardó, con sus nombres", async () => {
  const run = harness({ env: { EMAIL_TRANSPORT: "log" } });
  const response = await run.handle(post(payload({ menu: [MINESTRONE.id, UNPUBLISHED_ID, LASAGNE.id.toUpperCase()] })));
  assert.equal(response.status, 201);
  assert.deepEqual(run.store.submitted[0]?.wishes, [MINESTRONE.id, UNPUBLISHED_ID, LASAGNE.id]);
  // El que se despublicó entre la carga y el envío lo descarta la base, sin error: el 201 dice lo que quedó.
  assert.deepEqual(((await json(response)) as { menu: unknown }).menu, [choiceOf(MINESTRONE), choiceOf(LASAGNE)]);
  await run.settle();
});

test("pedido con más platos que días o con un menù con otra forma: 400 sin tocar la base", async () => {
  const { handle, store } = harness();
  for (const [body, errors] of [
    [payload({ days: 1, menu: [LASAGNE.id, MINESTRONE.id] }), { menu: "tooMany" }],
    [payload({ menu: [LASAGNE.id, LASAGNE.id] }), { menu: "invalid" }],
    [{ ...payload(), menu: "Lasagne" }, { menu: "invalid" }],
  ] as const) {
    const response = await handle(post(body));
    assert.equal(response.status, 400, JSON.stringify(errors));
    assert.deepEqual(await json(response), { errors });
  }
  assert.equal(store.hits.length, 0);
});

test("versión 3 (la web de antes, sin menù): wishes vacío y el 201 con menu vacío, aunque llegue un menu", async () => {
  const run = harness({ env: { EMAIL_TRANSPORT: "log" } });
  const response = await run.handle(post(payload({ version: 3, menu: [LASAGNE.id] })));
  assert.equal(response.status, 201);
  assert.deepEqual(run.store.submitted[0]?.wishes, []);
  assert.deepEqual(((await json(response)) as { menu: unknown }).menu, []);
  await run.settle();
});

test("reintento: el 201 trae el menù guardado del original, aunque el reintento mande otros platos", async () => {
  const run = harness({ env: { EMAIL_TRANSPORT: "log" } });
  await run.handle(post(payload({ requestKey: REQUEST_KEY, menu: [LASAGNE.id] })));
  const again = await run.handle(post(payload({ requestKey: REQUEST_KEY, menu: [MINESTRONE.id] })));
  await run.settle();
  assert.deepEqual(await json(again), {
    requestId: REQUEST_ID,
    estimate: publicEstimate(calcQuote({ type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 1 }, CHEF.pricing)),
    menu: [choiceOf(LASAGNE)],
    duplicate: true,
  });
});

test("la base devuelve un menu con otra forma: el 201 sale igual, con menu vacío, y se avisa en el log", async () => {
  const run = harness();
  run.store.byKey.set(`${CHEF_ID}:${REQUEST_KEY}`, { requestId: REQUEST_ID, duplicate: false, storedEstimate: null, storedMenu: [{ id: "x" }] });
  const response = await run.handle(post(payload({ requestKey: REQUEST_KEY })));
  assert.equal(response.status, 201);
  assert.deepEqual(((await json(response)) as { menu: unknown }).menu, []);
  assert.ok(run.logs.some((entry) => entry.event === "stored_menu_invalid" && entry.level === "warn"));
});

test("emails con menù: a Evelyn los platos y los días; al cliente, los que eligió y que Evelyn se lo confirma", async () => {
  const run = harness();
  await run.handle(post(payload({ menu: [MINESTRONE.id, LASAGNE.id] })));
  await run.settle();
  // A Evelyn en su idioma (es): el minestrone no tiene nombre en español, va el italiano.
  const chef = emailText(run, "evelyn@example.test");
  assert.ok(chef.includes("Menú elegido por el cliente (2 de 5 días): Minestrone · Lasaña"), chef);
  assert.ok(!chef.includes("Sin menú"));
  // Al cliente en el suyo (it).
  const client = emailText(run, "giulia.pii@example.test");
  assert.ok(client.includes("Piatti scelti: Minestrone · Lasagne"), client);
  assert.ok(client.includes("Evelyn ti conferma il menù e propone i piatti per gli altri giorni."), client);
  // Nunca los alérgenos de los platos ni las alergias del cliente.
  for (const text of [chef, client]) {
    assert.doesNotMatch(text, /\b(gluten|glutine|celery|sedano|apio|uova|huevos|eggs)\b/i);
  }
  assert.doesNotMatch(client, /allerg|intoller|celiach/i);

  const english = harness({ env: { CHEF_LOCALE: "en" } });
  await english.handle(post(payload({ locale: "en", days: 2, menu: [MINESTRONE.id, LASAGNE.id] })));
  await english.settle();
  assert.ok(emailText(english, "evelyn@example.test").includes("Menu chosen by the client (2 of 2 days): Minestrone soup · Lasagne"));
  const clientEn = emailText(english, "giulia.pii@example.test");
  assert.ok(clientEn.includes("Dishes chosen: Minestrone soup · Lasagne"), clientEn);
  assert.ok(clientEn.includes("Evelyn will confirm the menu."), clientEn);
});

test("emails sin menù: a Evelyn, que lo propone ella; al cliente, nada de platos elegidos", async () => {
  const run = harness();
  await run.handle(post(payload()));
  await run.settle();
  assert.ok(emailText(run, "evelyn@example.test").includes("Sin menú: lo propones tú."));
  const client = emailText(run, "giulia.pii@example.test");
  assert.ok(!client.includes("Piatti scelti"));
  assert.ok(!client.includes("ti conferma il menù"));
});

// ---------------------------------------------------------------------------
// Configuración y adaptadores
// ---------------------------------------------------------------------------

test("readConfig: valores por defecto y validaciones", () => {
  const config = readConfig((name) => ({ CHEF_ID: ` ${CHEF_ID.toUpperCase()} `, CHEF_LOCALE: "fr", EMAIL_TRANSPORT: "LOG" })[name]);
  assert.equal(config.chefId, CHEF_ID);
  assert.deepEqual(config.invalid, []);
  assert.equal(config.chefLocale, "es", "un idioma desconocido: el de Evelyn por defecto");
  assert.equal(config.emailTransport, "log");
  assert.equal(config.allowedOrigins.length, 0);
  assert.equal(config.whatsapp, null);
  assert.deepEqual(missingRequiredConfig(config), ["TURNSTILE_SECRET_KEY", "IP_HASH_SALT"]);

  const defaults = readConfig(() => undefined);
  assert.equal(defaults.emailTransport, "resend");
  assert.equal(defaults.chefId, null, "sin CHEF_ID: la única cocinera de public.chefs");
  assert.deepEqual(defaults.invalid, []);
  assert.equal(defaults.chefLocale, "es");
  assert.equal(DEFAULT_CHEF_LOCALE, "es", "Evelyn lee los avisos en español salvo que CHEF_LOCALE diga otra cosa");
  assert.deepEqual(missingRequiredConfig(defaults), ["TURNSTILE_SECRET_KEY", "IP_HASH_SALT"], "CHEF_ID ya no es obligatorio");
  assert.deepEqual(configWarnings(defaults), ["ALLOWED_ORIGINS", "CHEF_NOTIFY_EMAIL", "RESEND_API_KEY", "MAIL_FROM", "INBOX_URL", "PUBLIC_SITE_URL"]);
  assert.deepEqual(configWarnings(readConfig((name) => ENV[name])), []);

  assert.deepEqual(readConfig((name) => ({ CHEF_ID: "cef00000" })[name]).invalid, ["CHEF_ID"]);
  assert.equal(readConfig((name) => ({ CHEF_ID: "   " })[name]).chefId, null, "vacío = no configurado");
  assert.deepEqual(readConfig((name) => ({ CHEF_ID: "   " })[name]).invalid, []);
  assert.equal(readConfig((name) => ({ CHEF_LOCALE: "IT" })[name]).chefLocale, "it");
});

test("resolveServiceKey: clave secreta nueva (default), después las variables de compatibilidad", () => {
  const from = (values: Record<string, string>) => (name: string) => values[name];
  assert.equal(resolveServiceKey(from({ SUPABASE_SECRET_KEYS: '{"default":"sb_secret_a","otra":"sb_secret_b"}', SUPABASE_SERVICE_ROLE_KEY: "legacy" })), "sb_secret_a");
  assert.equal(resolveServiceKey(from({ SUPABASE_SECRET_KEYS: "no es json", SUPABASE_SECRET_KEY: "sb_secret_c" })), "sb_secret_c");
  assert.equal(resolveServiceKey(from({ SUPABASE_SECRET_KEYS: '{"otra":"x"}', SUPABASE_SERVICE_ROLE_KEY: "legacy" })), "legacy");
  assert.equal(resolveServiceKey(from({})), null);
});

test("chefFromRow: tarifas de chef_settings (precio por semana) y nombre de la cocinera", () => {
  // Las de Giulia en el seed: 160 €, 150 € desde 3 semanas, hasta 6 personas.
  const row = {
    weekly_rate_cents: 16000,
    weekly_rate_discounted_cents: 15000,
    weekly_discount_min_weeks: 3,
    weekly_rate_max_people: 6,
    min_cook_minutes: 60,
    chefs: { display_name: "Evelyn" },
  };
  assert.deepEqual(chefFromRow(row), {
    displayName: "Evelyn",
    pricing: {
      weeklyRateCents: 16000,
      weeklyRateDiscountedCents: 15000,
      weeklyDiscountMinWeeks: 3,
      weeklyRateMaxPeople: 6,
      minCookMinutes: 60,
    },
  });
  // Las tarifas por porción y el margen de la preautorización siguen en la base, pero ya no se leen.
  assert.deepEqual(chefFromRow({ ...row, adult_portion_cents: 400, kid_portion_cents: 260, preauth_buffer_pct: 10 }), chefFromRow(row));
  assert.equal(chefFromRow({ ...row, chefs: [{ display_name: "Eve" }] }).displayName, "Eve");
  assert.equal(chefFromRow({ ...row, chefs: null }).displayName, "Evelyn", "sin nombre: Evelyn");
  assert.throws(() => chefFromRow({ ...row, weekly_rate_cents: "16000" }), TypeError);
  // Sin las columnas del precio por semana (la base sin 20261116120000_weekly_pricing.sql) no hay tarifas.
  const { weekly_rate_max_people: _sinTope, ...old } = row;
  assert.throws(() => chefFromRow(old), TypeError);
  // El select de index.ts pide exactamente lo que lee chefFromRow.
  assert.deepEqual(
    CHEF_SETTINGS_COLUMNS.split(",").map((column) => column.trim()).sort(),
    [...Object.keys(row).filter((key) => key !== "chefs"), "chefs(display_name)"].sort(),
  );
});

test("safeDbMessage: solo pasan los códigos propios (snake_case), nunca textos con datos", () => {
  assert.equal(safeDbMessage("health_consent_required"), "health_consent_required");
  assert.equal(safeDbMessage('new row for relation "clients" violates check constraint'), null);
  assert.equal(safeDbMessage(undefined), null);
});
