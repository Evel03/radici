// Tests de la Edge Function public-request con dependencias simuladas (contrato §2, §4 y §5).
// Correr con: npm test (node --test). La función real (index.ts) solo conecta Supabase y Deno.
import { test } from "node:test";
import assert from "node:assert/strict";
import { CONSENT_VERSION, PUBLIC_REQUEST_VERSION, type PublicRequestPayload } from "../_shared/public_request.ts";
import { DEFAULT_PRICING, calcQuote } from "../_shared/quote.ts";
import { RESEND_API_URL } from "../_shared/resend.ts";
import { TURNSTILE_VERIFY_URL } from "../_shared/turnstile.ts";
import {
  RATE_LIMITS,
  StoreError,
  chefFromRow,
  configWarnings,
  createPublicRequestHandler,
  missingRequiredConfig,
  readConfig,
  resolveServiceKey,
  safeDbMessage,
  type ChefInfo,
  type HandlerDeps,
  type LogFields,
  type PublicRequestStore,
  type SubmitPublicRequestParams,
} from "./handler.ts";

const CHEF_ID = "cef00000-0000-4000-8000-000000000001";
const REQUEST_ID = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";
const NOW = new Date("2026-10-19T10:00:00Z");
const ENDPOINT = "http://127.0.0.1:54321/functions/v1/public-request";

const ENV: Record<string, string> = {
  CHEF_ID,
  TURNSTILE_SECRET_KEY: "1x0000000000000000000000000000000AA",
  IP_HASH_SALT: "sal-de-prueba",
  RESEND_API_KEY: "re_prueba",
  MAIL_FROM: "Mestolo <ciao@mestolo.sepusola10.com>",
  MAIL_REPLY_TO: "evelyn.respuestas@example.test",
  CHEF_NOTIFY_EMAIL: "evelyn@example.test",
  CHEF_LOCALE: "es",
  ALLOWED_ORIGINS: "https://mestolo.sepusola10.com,https://*.mestolo-dsa.pages.dev,http://localhost:5173",
  INBOX_URL: "https://mestolo.sepusola10.com/gestione/",
  PUBLIC_SITE_URL: "https://mestolo.sepusola10.com",
  WHATSAPP_TOKEN: "EAAprueba",
  WHATSAPP_PHONE_NUMBER_ID: "106540352242922",
  WHATSAPP_TEMPLATE: "richiesta_ricevuta",
};

// Datos personales con marcas fáciles de buscar en los logs.
function payload(overrides: Partial<PublicRequestPayload> = {}): PublicRequestPayload {
  return {
    version: PUBLIC_REQUEST_VERSION,
    type: "week",
    adults: 2,
    kids: 2,
    days: 5,
    meals: ["dinner"],
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

const CHEF: ChefInfo = { displayName: "Evelyn", pricing: { ...DEFAULT_PRICING, hourlyRateCents: 2500 } };

class FakeStore implements PublicRequestStore {
  allow = true;
  chef: ChefInfo | null = CHEF;
  failOn: "rate" | "chef" | "submit" | "mark" | null = null;
  hits: Array<{ ipHash: string; maxHour: number; maxDay: number }> = [];
  submitted: SubmitPublicRequestParams[] = [];
  marked: string[] = [];

  async hitRateLimit(ipHash: string, maxHour: number, maxDay: number): Promise<boolean> {
    if (this.failOn === "rate") throw new StoreError("rate_limit", "57014", null);
    this.hits.push({ ipHash, maxHour, maxDay });
    return this.allow;
  }

  async loadChef(chefId: string): Promise<ChefInfo | null> {
    if (this.failOn === "chef") throw new StoreError("load_chef", "PGRST301", null);
    return chefId === CHEF_ID ? this.chef : null;
  }

  async submit(params: SubmitPublicRequestParams): Promise<string> {
    if (this.failOn === "submit") throw new StoreError("submit", "23514", null);
    this.submitted.push(params);
    return REQUEST_ID;
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
    now: () => NOW,
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
      origin: "https://mestolo.sepusola10.com",
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

test("OPTIONS: CORS para un origen permitido (también comodín) y nada para otros", async () => {
  const { handle } = harness();
  const allowed = await handle(new Request(ENDPOINT, { method: "OPTIONS", headers: { origin: "https://pr-12.mestolo-dsa.pages.dev" } }));
  assert.equal(allowed.status, 204);
  assert.equal(allowed.headers.get("access-control-allow-origin"), "https://pr-12.mestolo-dsa.pages.dev");
  assert.equal(allowed.headers.get("access-control-allow-methods"), "POST, OPTIONS");
  assert.match(allowed.headers.get("access-control-allow-headers") ?? "", /content-type/);

  const other = await handle(new Request(ENDPOINT, { method: "OPTIONS", headers: { origin: "https://evil.example" } }));
  assert.equal(other.status, 204);
  assert.equal(other.headers.get("access-control-allow-origin"), null);
  assert.equal(other.headers.get("access-control-allow-methods"), null);
});

test("método distinto de POST: 405 con Allow", async () => {
  const { handle } = harness();
  for (const method of ["GET", "PUT", "DELETE"]) {
    const response = await handle(new Request(ENDPOINT, { method, headers: { origin: "https://mestolo.sepusola10.com" } }));
    assert.equal(response.status, 405);
    assert.deepEqual(await json(response), { error: "method" });
    assert.equal(response.headers.get("allow"), "POST, OPTIONS");
    assert.equal(response.headers.get("access-control-allow-origin"), "https://mestolo.sepusola10.com");
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

test("falta configuración obligatoria: 500 sin consultar la base, y el log dice qué falta", async () => {
  const { handle, store, logs } = harness({ env: { TURNSTILE_SECRET_KEY: undefined, CHEF_ID: "no-es-uuid" } });
  const response = await handle(post(payload()));
  assert.equal(response.status, 500);
  assert.deepEqual(await json(response), { error: "server" });
  assert.equal(store.hits.length, 0);
  const entry = logs.find((item) => item.event === "config_missing");
  assert.deepEqual(entry?.fields["missing"], ["CHEF_ID", "TURNSTILE_SECRET_KEY"]);
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
  assert.equal(response.headers.get("access-control-allow-origin"), "https://mestolo.sepusola10.com");
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.match(response.headers.get("content-type") ?? "", /^application\/json/);

  const quote = calcQuote({ adults: 2, kids: 2, days: 5, meals: 1 }, CHEF.pricing);
  assert.notEqual(quote.serviceCents, 7800, "con 25 €/h el servicio no es el del vector 1");
  assert.deepEqual(await json(response), {
    requestId: REQUEST_ID,
    estimate: {
      portions: quote.portions,
      recipes: quote.recipes,
      cookMinutes: quote.cookMinutes,
      serviceCents: quote.serviceCents,
      groceriesEstCents: quote.groceriesEstCents,
      totalCents: quote.totalCents,
    },
  });

  assert.deepEqual(store.submitted[0], {
    chef_id: CHEF_ID,
    type: "week",
    adults: 2,
    kids: 2,
    days: 5,
    meals: ["dinner"],
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
  });
  assert.equal(background.length, 1, "los envíos van en segundo plano");
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
  assert.equal(chefBody["from"], "Mestolo <ciao@mestolo.sepusola10.com>");
  assert.equal(chefBody["reply_to"], "giulia.pii@example.test", "Evelyn responde directo al cliente");
  assert.equal(toChef.headers.get("idempotency-key"), `request-${REQUEST_ID}-chef`);
  assert.ok(String(chefBody["html"]).includes(`https://mestolo.sepusola10.com/gestione/#/richieste/${REQUEST_ID}`));

  const clientBody = toClient.body as Record<string, unknown>;
  assert.equal(clientBody["subject"], "Mestolo: abbiamo ricevuto la tua richiesta");
  assert.equal(clientBody["reply_to"], "evelyn.respuestas@example.test");
  assert.equal(toClient.headers.get("idempotency-key"), `request-${REQUEST_ID}-client`);
  assert.ok(String(clientBody["text"]).includes("Evelyn ti contatterà al più presto"));
  assert.ok(String(clientBody["html"]).includes('href="https://mestolo.sepusola10.com/privacy/"'));

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

  assert.deepEqual(store.marked, [REQUEST_ID]);
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
  ];
  for (const run of runs) {
    await run.handle(post(payload()));
    await run.settle();
    const text = JSON.stringify(run.logs);
    for (const secret of ["Giuliaxyz", "Rossiqwe", "giulia.pii", "765", "ZonaPrivadaKkk", "NOTA-SALUD", "NOTA-LIBRE", "203.0.113", "milk"]) {
      assert.ok(!text.includes(secret), `el log lleva ${secret}: ${text}`);
    }
  }
  const ok = runs[0];
  assert.ok(ok?.logs.some((entry) => entry.event === "request_saved" && entry.fields["requestId"] === REQUEST_ID));
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
// Configuración y adaptadores
// ---------------------------------------------------------------------------

test("readConfig: valores por defecto y validaciones", () => {
  const config = readConfig((name) => ({ CHEF_ID: ` ${CHEF_ID.toUpperCase()} `, CHEF_LOCALE: "fr", EMAIL_TRANSPORT: "LOG" })[name]);
  assert.equal(config.chefId, CHEF_ID);
  assert.equal(config.chefLocale, "it");
  assert.equal(config.emailTransport, "log");
  assert.equal(config.allowedOrigins.length, 0);
  assert.equal(config.whatsapp, null);
  assert.deepEqual(missingRequiredConfig(config), ["TURNSTILE_SECRET_KEY", "IP_HASH_SALT"]);

  const defaults = readConfig(() => undefined);
  assert.equal(defaults.emailTransport, "resend");
  assert.deepEqual(missingRequiredConfig(defaults), ["CHEF_ID", "TURNSTILE_SECRET_KEY", "IP_HASH_SALT"]);
  assert.deepEqual(configWarnings(defaults), ["ALLOWED_ORIGINS", "CHEF_NOTIFY_EMAIL", "RESEND_API_KEY", "MAIL_FROM", "INBOX_URL", "PUBLIC_SITE_URL"]);
  assert.deepEqual(configWarnings(readConfig((name) => ENV[name])), []);
});

test("resolveServiceKey: clave secreta nueva (default), después las variables de compatibilidad", () => {
  const from = (values: Record<string, string>) => (name: string) => values[name];
  assert.equal(resolveServiceKey(from({ SUPABASE_SECRET_KEYS: '{"default":"sb_secret_a","otra":"sb_secret_b"}', SUPABASE_SERVICE_ROLE_KEY: "legacy" })), "sb_secret_a");
  assert.equal(resolveServiceKey(from({ SUPABASE_SECRET_KEYS: "no es json", SUPABASE_SECRET_KEY: "sb_secret_c" })), "sb_secret_c");
  assert.equal(resolveServiceKey(from({ SUPABASE_SECRET_KEYS: '{"otra":"x"}', SUPABASE_SERVICE_ROLE_KEY: "legacy" })), "legacy");
  assert.equal(resolveServiceKey(from({})), null);
});

test("chefFromRow: tarifas de chef_settings y nombre de la cocinera", () => {
  const row = {
    hourly_rate_cents: 2500,
    travel_fee_cents: 1500,
    adult_portion_cents: 400,
    kid_portion_cents: 260,
    preauth_buffer_pct: 10,
    min_cook_minutes: 60,
    chefs: { display_name: "Evelyn" },
  };
  assert.deepEqual(chefFromRow(row), {
    displayName: "Evelyn",
    pricing: { hourlyRateCents: 2500, travelFeeCents: 1500, adultPortionCents: 400, kidPortionCents: 260, preauthBufferPct: 10, minCookMinutes: 60 },
  });
  assert.equal(chefFromRow({ ...row, chefs: [{ display_name: "Eve" }] }).displayName, "Eve");
  assert.equal(chefFromRow({ ...row, chefs: null }).displayName, "Evelyn", "sin nombre: Evelyn");
  assert.throws(() => chefFromRow({ ...row, hourly_rate_cents: "2500" }), TypeError);
});

test("safeDbMessage: solo pasan los códigos propios (snake_case), nunca textos con datos", () => {
  assert.equal(safeDbMessage("health_consent_required"), "health_consent_required");
  assert.equal(safeDbMessage('new row for relation "clients" violates check constraint'), null);
  assert.equal(safeDbMessage(undefined), null);
});
