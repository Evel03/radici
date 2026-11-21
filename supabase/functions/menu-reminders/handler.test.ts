// Tests de la Edge Function menu-reminders con dependencias simuladas (SPEC 5.8).
// Correr con: npm test (node --test). La función real (index.ts) solo conecta Supabase, Resend y Deno.
import { test } from "node:test";
import assert from "node:assert/strict";
import { StoreError, type LogFields } from "../_shared/edge.ts";
import type { EmailMessage, SendOutcome } from "../_shared/resend.ts";
import {
  DEFAULT_CHEF_LOCALE,
  SECRET_HEADER,
  createMenuRemindersHandler,
  readRemindersConfig,
  remindersConfigWarnings,
  sameSecret,
  type RemindersConfig,
  type RemindersStore,
} from "./handler.ts";

const CHEF = "7e6b1000-0000-4000-8000-000000000001";
const NOW = new Date("2027-01-09T09:01:00Z");

const DUE = [
  {
    sessionId: "7e6b4000-0000-4000-8000-000000000001",
    requestId: "7e6b3000-0000-4000-8000-000000000001",
    kind: "overdue",
    date: "2027-01-11",
    start: "10:00",
    deadline: "2027-01-09T09:00:00+00:00",
    week: 1,
    weeks: 2,
    clientName: "Anna Rota",
    changesRequested: false,
  },
  {
    sessionId: "7e6b4000-0000-4000-8000-000000000006",
    requestId: "7e6b3000-0000-4000-8000-000000000003",
    kind: "last",
    date: "2027-01-12",
    start: "10:00",
    deadline: "2027-01-10T09:00:00+00:00",
    week: 1,
    weeks: 1,
    clientName: "Bruno Sala",
    changesRequested: true,
  },
];

function config(overrides: Partial<RemindersConfig> = {}): RemindersConfig {
  return {
    secret: "s3creto",
    chefId: null,
    invalid: [],
    chefNotifyEmail: "evelyn@radici.test",
    chefLocale: "es",
    inboxUrl: "https://radicicucina.app/gestione/",
    mailFrom: "Radici <ciao@radicicucina.app>",
    resendApiKey: "re_test",
    emailTransport: "resend",
    ...overrides,
  };
}

interface Harness {
  handler: (request: Request) => Promise<Response>;
  logs: Array<{ level: string; event: string; fields: LogFields }>;
  emails: EmailMessage[];
  marked: Array<{ chefId: string; items: ReadonlyArray<{ sessionId: string; kind: string }>; nowIso: string }>;
  dueCalls: Array<{ chefId: string; nowIso: string }>;
}

function harness(options: {
  config?: Partial<RemindersConfig>;
  due?: unknown;
  dueError?: unknown;
  markError?: unknown;
  send?: SendOutcome;
  defaultChef?: Awaited<ReturnType<RemindersStore["resolveDefaultChef"]>>;
} = {}): Harness {
  const logs: Harness["logs"] = [];
  const emails: EmailMessage[] = [];
  const marked: Harness["marked"] = [];
  const dueCalls: Harness["dueCalls"] = [];
  const store: RemindersStore = {
    resolveDefaultChef: async () => options.defaultChef ?? { ok: true, chefId: CHEF },
    due: async (chefId, nowIso) => {
      dueCalls.push({ chefId, nowIso });
      if (options.dueError) throw options.dueError;
      return options.due === undefined ? DUE : options.due;
    },
    mark: async (chefId, items, nowIso) => {
      if (options.markError) throw options.markError;
      marked.push({ chefId, items, nowIso });
      return items.length;
    },
  };
  const handler = createMenuRemindersHandler({
    config: config(options.config),
    store,
    sendEmail: async (message) => {
      emails.push(message);
      return options.send ?? { ok: true, id: "email-1" };
    },
    log: (level, event, fields = {}) => logs.push({ level, event, fields }),
    now: () => NOW,
  });
  return { handler, logs, emails, marked, dueCalls };
}

function post(secret: string | null = "s3creto", method = "POST"): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (secret !== null) headers[SECRET_HEADER] = secret;
  return new Request("https://example.test/functions/v1/menu-reminders", { method, headers, body: method === "GET" ? null : "{}" });
}

test("config: lee las variables y avisa lo que falta", () => {
  const read = readRemindersConfig((name) =>
    ({ MENU_REMINDERS_SECRET: " abc ", CHEF_ID: "7E6B1000-0000-4000-8000-000000000001", CHEF_LOCALE: "IT", EMAIL_TRANSPORT: "log" })[name],
  );
  assert.equal(read.secret, "abc");
  assert.equal(read.chefId, CHEF);
  assert.deepEqual(read.invalid, []);
  assert.equal(read.chefLocale, "it");
  assert.equal(read.emailTransport, "log");
  assert.deepEqual(remindersConfigWarnings(read), ["CHEF_NOTIFY_EMAIL", "INBOX_URL"]);

  const empty = readRemindersConfig(() => undefined);
  assert.equal(empty.chefLocale, DEFAULT_CHEF_LOCALE);
  assert.deepEqual(remindersConfigWarnings(empty), ["MENU_REMINDERS_SECRET", "CHEF_NOTIFY_EMAIL", "RESEND_API_KEY", "MAIL_FROM", "INBOX_URL"]);
  assert.deepEqual(readRemindersConfig((name) => (name === "CHEF_ID" ? "no-es-uuid" : undefined)).invalid, ["CHEF_ID"]);
});

test("sameSecret compara largo y contenido", () => {
  assert.equal(sameSecret("abc", "abc"), true);
  assert.equal(sameSecret("abd", "abc"), false);
  assert.equal(sameSecret("ab", "abc"), false);
  assert.equal(sameSecret("", "abc"), false);
});

test("solo POST", async () => {
  const { handler } = harness();
  const response = await handler(post("s3creto", "GET"));
  assert.equal(response.status, 405);
  assert.equal(response.headers.get("Allow"), "POST");
});

test("sin el secreto configurado: 503 y no lee nada", async () => {
  const h = harness({ config: { secret: null } });
  const response = await h.handler(post());
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "notConfigured" });
  assert.equal(h.dueCalls.length, 0);
});

test("secreto ausente o distinto: 401", async () => {
  for (const secret of [null, "otro"]) {
    const h = harness();
    const response = await h.handler(post(secret));
    assert.equal(response.status, 401);
    assert.equal(h.dueCalls.length, 0);
    assert.equal(h.logs[0]?.event, "auth_rejected");
    assert.equal(h.logs[0]?.fields["reason"], secret === null ? "missing" : "mismatch");
  }
});

test("CHEF_ID inválido: 500", async () => {
  const h = harness({ config: { invalid: ["CHEF_ID"] } });
  assert.equal((await h.handler(post())).status, 500);
  assert.equal(h.dueCalls.length, 0);
});

test("nada que avisar: 200 sin email", async () => {
  const h = harness({ due: [] });
  const response = await h.handler(post());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { sent: 0 });
  assert.equal(h.emails.length, 0);
  assert.equal(h.marked.length, 0);
  assert.deepEqual(h.dueCalls, [{ chefId: CHEF, nowIso: NOW.toISOString() }]);
});

test("avisa: un email a la cocina con todas las semanas y después las marca", async () => {
  const h = harness();
  const response = await h.handler(post());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { sent: 2 });
  assert.equal(h.emails.length, 1);
  const email = h.emails[0]!;
  assert.equal(email.to, "evelyn@radici.test");
  assert.equal(email.from, "Radici <ciao@radicicucina.app>");
  assert.equal(email.subject, "Radici: Urgente: hay 2 menús sin enviar");
  assert.match(email.idempotencyKey, new RegExp(`^menu-reminders/${CHEF}/\\d+/[0-9a-f]{32}$`));
  assert.match(email.text, /ANNA ROTA · SEMANA 1 DE 2/);
  assert.match(email.text, /Ya pasó el límite de 48 horas/);
  assert.match(email.text, /La clienta pidió cambios/);
  assert.match(email.text, /Abrir el pedido: https:\/\/radicicucina\.app\/gestione\/#\/richieste\/7e6b3000-0000-4000-8000-000000000001/);
  assert.deepEqual(h.marked, [
    {
      chefId: CHEF,
      items: [
        { sessionId: DUE[0]!.sessionId, kind: "overdue" },
        { sessionId: DUE[1]!.sessionId, kind: "last" },
      ],
      nowIso: NOW.toISOString(),
    },
  ]);
  const sent = h.logs.find((entry) => entry.event === "reminders_sent");
  assert.deepEqual(sent?.fields, { first: 0, last: 1, overdue: 1, marked: 2 });
});

test("con CHEF_ID no busca la cocina por defecto", async () => {
  const h = harness({ config: { chefId: "7e6b1000-0000-4000-8000-0000000000aa" }, defaultChef: { ok: false, reason: "no_chef" } });
  assert.equal((await h.handler(post())).status, 200);
  assert.equal(h.dueCalls[0]?.chefId, "7e6b1000-0000-4000-8000-0000000000aa");
});

test("sin cocina por defecto: 500", async () => {
  const h = harness({ defaultChef: { ok: false, reason: "multiple_chefs" } });
  assert.equal((await h.handler(post())).status, 500);
  assert.equal(h.logs.find((entry) => entry.event === "chef_unresolved")?.fields["reason"], "multiple_chefs");
});

test("la base no responde: 503; otro error: 500", async () => {
  assert.equal((await harness({ dueError: new StoreError("due", null, null) }).handler(post())).status, 503);
  assert.equal((await harness({ dueError: new StoreError("due", "42501", null) }).handler(post())).status, 500);
});

test("una respuesta de la base que no tiene la forma esperada: 500 sin email", async () => {
  const h = harness({ due: [{ ...DUE[0], kind: "nuevo" }] });
  assert.equal((await h.handler(post())).status, 500);
  assert.equal(h.emails.length, 0);
});

test("sin destinatario o sin Resend: 503 y no marca", async () => {
  for (const overrides of [{ chefNotifyEmail: null }, { resendApiKey: null }, { mailFrom: null }]) {
    const h = harness({ config: overrides });
    const response = await h.handler(post());
    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { error: "emailUnavailable" });
    assert.equal(h.marked.length, 0);
  }
});

test("con EMAIL_TRANSPORT=log no manda nada y marca igual", async () => {
  const h = harness({ config: { emailTransport: "log", resendApiKey: null, mailFrom: null } });
  assert.equal((await h.handler(post())).status, 200);
  assert.equal(h.emails.length, 0);
  assert.equal(h.marked.length, 1);
  assert.ok(h.logs.some((entry) => entry.event === "email_logged"));
});

test("si el email falla: 502 y no marca (el turno siguiente lo reintenta)", async () => {
  const h = harness({ send: { ok: false, status: 500, errorName: "internal_server_error" } });
  const response = await h.handler(post());
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: "emailFailed" });
  assert.equal(h.marked.length, 0);
});

test("si marcar falla después del email: 500 (mejor repetir que no avisar)", async () => {
  const h = harness({ markError: new StoreError("mark", "XX000", null) });
  assert.equal((await h.handler(post())).status, 500);
  assert.equal(h.emails.length, 1);
});

test("los logs nunca llevan nombres, fechas, emails ni el secreto", async () => {
  const h = harness();
  await h.handler(post());
  await harness().handler(post("otro"));
  const all = JSON.stringify(h.logs);
  for (const secret of ["Anna", "Bruno", "2027-01", "evelyn@", "s3creto"]) assert.ok(!all.includes(secret), secret);
});
