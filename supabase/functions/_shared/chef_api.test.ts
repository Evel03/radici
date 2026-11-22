// Tests del contrato de la Edge Function chef (docs/contracts/chef-api.md): validación y
// normalización de los cuerpos. Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CANCEL_REASONS,
  CHEF_ROUTES,
  DEFAULT_CANCEL_REASON,
  MAX_CANCEL_SESSIONS,
  MAX_CENTS,
  MAX_COOK_MINUTES,
  MAX_MENU_VERSION,
  MAX_PORTIONS,
  MAX_WEEKS,
  RECIPE_DESCRIPTION_MAX,
  RECIPE_NAME_MAX,
  SESSION_STATUSES,
  isTimeOfDay,
  isoWeekMonday,
  menuSendChannels,
  parseBookingRequest,
  parseCancelSessionsRequest,
  parseMenuPreviewRequest,
  parseMenuSendRequest,
  parseMoveSessionRequest,
  parseTranslateRequest,
  textLength,
} from "./chef_api.ts";
import { LIMITS } from "./quote.ts";

// Lunes. Las fechas valen de hoy − 366 a hoy + 366 (las pasadas, para cargar lo hecho en Fase 0).
const TODAY = "2026-11-16";
const OPTS = { today: TODAY };
const REQUEST_ID = "5e550000-0000-4000-8000-000000000001";
const CLIENT_ID = "5e550000-0000-4000-8000-000000000002";
const SESSION_ID = "5e550000-0000-4000-8000-000000000003";
const REQUEST_KEY = "3f2b8c1e-9a4d-4c7b-8e2f-0123456789ab";
const FOUR_MONDAYS = ["2026-11-23", "2026-11-30", "2026-12-07", "2026-12-14"];

/** Confirmar un pedido de la bandeja: 4 semanas, 560 € de servicio. */
function fromRequest(overrides: Record<string, unknown> = {}): Record<string, unknown> {
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

/** Reserva a mano con una ficha nueva (clienta que llegó por WhatsApp). */
function manual(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    newClient: { name: "  Maria   Bianchi ", phone: "333 765 4321", email: "Maria@Example.TEST", zone: "Città Alta", address: "Via Roma 1" },
    type: "week",
    household: { adults: 2, kids: 3, days: 5, meals: ["dinner", "lunch"] },
    locale: "es",
    dates: ["2026-11-23"],
    start: "10:00",
    cookMinutes: 240,
    serviceTotalCents: 15000,
    requestKey: REQUEST_KEY.toUpperCase(),
    ...overrides,
  };
}

function errorsOf(
  result:
    | ReturnType<typeof parseBookingRequest>
    | ReturnType<typeof parseMoveSessionRequest>
    | ReturnType<typeof parseCancelSessionsRequest>
    | ReturnType<typeof parseTranslateRequest>
    | ReturnType<typeof parseMenuPreviewRequest>
    | ReturnType<typeof parseMenuSendRequest>,
): unknown {
  assert.equal(result.ok, false, "tenía que fallar");
  return result.ok ? null : result.errors;
}

// ---------------------------------------------------------------------------
// Constantes y helpers
// ---------------------------------------------------------------------------

test("rutas y límites del contrato", () => {
  assert.deepEqual(CHEF_ROUTES, {
    bookings: "/bookings",
    moveSession: "/sessions/move",
    cancelSessions: "/sessions/cancel",
    translate: "/translate",
    menuPreview: "/menus/preview",
    menuSend: "/menus/send",
  });
  assert.equal(RECIPE_NAME_MAX, 120, "como recipes_name_*_valido");
  assert.equal(RECIPE_DESCRIPTION_MAX, 200, "como recipes_description_*_valida");
  assert.equal(MAX_WEEKS, 8);
  assert.equal(MAX_COOK_MINUTES, 720, "igual que chef_create_booking y chef_move_session");
  assert.equal(MAX_PORTIONS, 2 * LIMITS.maxPeople * LIMITS.maxDays * LIMITS.maxMeals, "lo más que da quote.ts: 30 + 30 personas, 7 días, 2 comidas");
  assert.equal(MAX_PORTIONS, 840);
  assert.equal(MAX_CENTS, 10_000_000);
  assert.equal(MAX_CANCEL_SESSIONS, 100, "igual que chef_cancel_sessions");
  assert.deepEqual(CANCEL_REASONS, ["chef_cancelled", "client_cancelled", "chef_unavailable"], "los mismos que acepta chef_cancel_sessions");
  assert.equal(DEFAULT_CANCEL_REASON, "chef_cancelled");
});

test("isTimeOfDay: solo HH:MM de 00:00 a 23:59", () => {
  for (const ok of ["00:00", "09:30", "10:00", "23:59"]) assert.ok(isTimeOfDay(ok), ok);
  for (const bad of ["24:00", "9:00", "10:0", "10:60", "10:00:00", " 10:00", "1000", "", null, 600]) {
    assert.ok(!isTimeOfDay(bad), String(bad));
  }
});

test("isoWeekMonday: el lunes de la semana ISO (como date_trunc('week') en SQL)", () => {
  assert.equal(isoWeekMonday("2026-11-16"), "2026-11-16", "un lunes es su propio lunes");
  assert.equal(isoWeekMonday("2026-11-22"), "2026-11-16", "el domingo cierra la semana");
  assert.equal(isoWeekMonday("2026-11-23"), "2026-11-23");
  assert.equal(isoWeekMonday("2027-01-01"), "2026-12-28", "cruza el año");
});

// ---------------------------------------------------------------------------
// POST /bookings
// ---------------------------------------------------------------------------

test("reserva desde un pedido: valores normalizados y los opcionales por defecto", () => {
  const result = parseBookingRequest(fromRequest(), OPTS);
  assert.ok(result.ok);
  assert.deepEqual(result.value, {
    client: { kind: "request", requestId: REQUEST_ID },
    type: null,
    household: null,
    locale: null,
    dates: FOUR_MONDAYS,
    start: "10:00",
    cookMinutes: 240,
    portions: 50,
    serviceTotalCents: 56000,
    requestKey: null,
    dryRun: false,
  });

  const minimal = parseBookingRequest({ requestId: REQUEST_ID.toUpperCase(), dates: ["2026-11-23"], start: "10:00", cookMinutes: 90, serviceTotalCents: 0 }, OPTS);
  assert.ok(minimal.ok);
  assert.equal(minimal.value.client.kind === "request" && minimal.value.client.requestId, REQUEST_ID, "uuid en minúsculas");
  assert.equal(minimal.value.portions, 0);
  assert.equal(minimal.value.serviceTotalCents, 0, "un 0 explícito vale: sin cargo");
});

test("precio del servicio: obligatorio salvo en el dryRun (ninguna ruta lo cambia después)", () => {
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ serviceTotalCents: undefined }), OPTS)), { serviceTotalCents: "required" });
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ serviceTotalCents: null }), OPTS)), { serviceTotalCents: "required" });
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ serviceTotalCents: undefined }), OPTS)), { serviceTotalCents: "required" }, "a mano también");
  const dry = parseBookingRequest(fromRequest({ serviceTotalCents: undefined, dryRun: true }), OPTS);
  assert.ok(dry.ok, "la hoja hace el dryRun antes de que Evelyn cargue el precio");
  assert.equal(dry.value.serviceTotalCents, 0);
});

test("desde un pedido: el hogar y el idioma no se usan (son del pedido); el tipo, si viene, se valida", () => {
  const result = parseBookingRequest(fromRequest({ household: { adults: "x" }, locale: "fr", type: "week", requestKey: REQUEST_KEY }), OPTS);
  assert.ok(result.ok);
  assert.equal(result.value.household, null);
  assert.equal(result.value.locale, null);
  assert.equal(result.value.type, "week");
  assert.equal(result.value.requestKey, REQUEST_KEY);
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ type: "change" }), OPTS)), { type: "invalid" });
});

test("reserva a mano con ficha nueva: texto limpio, teléfono E.164, email en minúsculas y comidas en orden", () => {
  const result = parseBookingRequest(manual(), OPTS);
  assert.ok(result.ok);
  assert.deepEqual(result.value, {
    client: {
      kind: "newClient",
      newClient: { name: "Maria Bianchi", phone: "+393337654321", email: "maria@example.test", zone: "Città Alta", address: "Via Roma 1" },
    },
    type: "week",
    household: { adults: 2, kids: 3, days: 5, meals: ["lunch", "dinner"] },
    locale: "es",
    dates: ["2026-11-23"],
    start: "10:00",
    cookMinutes: 240,
    portions: 0,
    serviceTotalCents: 15000,
    requestKey: REQUEST_KEY,
    dryRun: false,
  });

  const onlyName = parseBookingRequest(manual({ newClient: { name: "Maria", phone: "", email: null } }), OPTS);
  assert.ok(onlyName.ok);
  assert.deepEqual(onlyName.ok && onlyName.value.client, {
    kind: "newClient",
    newClient: { name: "Maria", phone: null, email: null, zone: null, address: null },
  });
  const noLocale = parseBookingRequest(manual({ locale: undefined }), OPTS);
  assert.ok(noLocale.ok);
  assert.equal(noLocale.value.locale, null, "sin idioma: la base usa it");
});

test("reserva a mano con una ficha existente", () => {
  const result = parseBookingRequest(manual({ newClient: undefined, clientId: CLIENT_ID, type: "extra" }), OPTS);
  assert.ok(result.ok);
  assert.deepEqual(result.value.client, { kind: "client", clientId: CLIENT_ID });
  assert.equal(result.value.type, "extra");
});

test("la clienta: una sola de requestId, clientId o newClient", () => {
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ requestId: undefined }), OPTS)), { client: "required" });
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ clientId: CLIENT_ID }), OPTS)), { client: "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ clientId: CLIENT_ID }), OPTS)), { client: "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ requestId: "123" }), OPTS)), { requestId: "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ newClient: undefined, clientId: 7 }), OPTS)), { clientId: "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ newClient: "Maria" }), OPTS)), { newClient: "invalid" });
});

test("ficha nueva: nombre obligatorio, teléfono y email válidos, largos máximos", () => {
  const client = (fields: Record<string, unknown>) => manual({ newClient: { name: "Maria", ...fields } });
  assert.deepEqual(errorsOf(parseBookingRequest(client({ name: "   " }), OPTS)), { "newClient.name": "required" });
  assert.deepEqual(errorsOf(parseBookingRequest(client({ name: 42 }), OPTS)), { "newClient.name": "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(client({ name: "x".repeat(81) }), OPTS)), { "newClient.name": "tooLong" });
  assert.deepEqual(errorsOf(parseBookingRequest(client({ phone: "12345" }), OPTS)), { "newClient.phone": "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(client({ email: "no-es-un-email" }), OPTS)), { "newClient.email": "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(client({ zone: "x".repeat(81) }), OPTS)), { "newClient.zone": "tooLong" });
  assert.deepEqual(errorsOf(parseBookingRequest(client({ address: "x".repeat(201) }), OPTS)), { "newClient.address": "tooLong" });
});

test("a mano: tipo, hogar e idioma", () => {
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ type: undefined }), OPTS)), { type: "required" });
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ type: "change" }), OPTS)), { type: "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ household: undefined }), OPTS)), { household: "required" });
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ household: [2, 3] }), OPTS)), { household: "invalid" });
  const household = (fields: Record<string, unknown>) => manual({ household: { adults: 2, kids: 0, days: 5, meals: ["dinner"], ...fields } });
  assert.deepEqual(errorsOf(parseBookingRequest(household({ adults: 0, kids: 0 }), OPTS)), { people: "range" });
  assert.deepEqual(errorsOf(parseBookingRequest(household({ adults: 31 }), OPTS)), { "household.adults": "range" });
  assert.deepEqual(errorsOf(parseBookingRequest(household({ kids: 31 }), OPTS)), { "household.kids": "range" });
  assert.deepEqual(errorsOf(parseBookingRequest(household({ kids: 1.5 }), OPTS)), { "household.kids": "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(household({ days: 0 }), OPTS)), { "household.days": "range" });
  assert.deepEqual(errorsOf(parseBookingRequest(household({ days: undefined }), OPTS)), { "household.days": "required" });
  for (const meals of [[], ["brunch"], ["dinner", "dinner"], "dinner"]) {
    assert.deepEqual(errorsOf(parseBookingRequest(household({ meals }), OPTS)), { "household.meals": "invalid" }, JSON.stringify(meals));
  }
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ locale: "fr" }), OPTS)), { locale: "invalid" });
});

test("semanas: de 1 a 8 fechas (0 o 9 → range)", () => {
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ dates: [] }), OPTS)), { dates: "range" });
  const nineMondays = ["2026-11-23", "2026-11-30", "2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04", "2027-01-11", "2027-01-18"];
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ dates: nineMondays }), OPTS)), { dates: "range" });
  const eight = parseBookingRequest(fromRequest({ dates: nineMondays.slice(0, 8) }), OPTS);
  assert.ok(eight.ok, "8 semanas sí");
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ dates: undefined }), OPTS)), { dates: "required" });
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ dates: "2026-11-23" }), OPTS)), { dates: "invalid" });
});

test("fechas: formato real, dentro de un año de hoy, una por semana ISO y en orden (con la fecha que falla)", () => {
  const bad = (dates: unknown[]) => parseBookingRequest(fromRequest({ dates }), OPTS);
  assert.deepEqual(errorsOf(bad(["2026-11-23", "2026-02-30"])), { dates: "invalid" });
  assert.deepEqual(errorsOf(bad(["2026-11-23", 20261130])), { dates: "invalid" });

  const far = bad(["2027-11-18"]);
  assert.deepEqual(errorsOf(far), { dates: "dateOutOfRange" });
  assert.equal(!far.ok && far.date, "2027-11-18");
  assert.ok(parseBookingRequest(fromRequest({ dates: ["2027-11-17"] }), OPTS).ok, "hoy + 366 todavía vale");
  assert.ok(parseBookingRequest(fromRequest({ dates: ["2025-11-15"] }), OPTS).ok, "hoy − 366 también (lo ya hecho en Fase 0)");
  assert.deepEqual(errorsOf(bad(["2025-11-14"])), { dates: "dateOutOfRange" });

  // Lunes y viernes de la misma semana: la fecha que choca es la segunda (como dates_same_week en SQL).
  const sameWeek = bad(["2026-11-23", "2026-11-27"]);
  assert.deepEqual(errorsOf(sameWeek), { dates: "sameWeek" });
  assert.equal(!sameWeek.ok && sameWeek.date, "2026-11-27");
  const order = bad(["2026-11-30", "2026-11-23"]);
  assert.deepEqual(errorsOf(order), { dates: "order" });
  assert.equal(!order.ok && order.date, "2026-11-23", "order también dice la fecha que falla");
  // Viernes y lunes de la misma semana: desordenadas, pero primero cuenta la semana repetida.
  const both = bad(["2026-11-27", "2026-11-23"]);
  assert.deepEqual(errorsOf(both), { dates: "sameWeek" });
  assert.equal(!both.ok && both.date, "2026-11-23");
  assert.ok(parseBookingRequest(fromRequest({ dates: ["2026-11-22", "2026-11-23"] }), OPTS).ok, "domingo y lunes son semanas distintas");
});

test("más de una semana solo en un pedido semanal (un evento es de una sola)", () => {
  const result = parseBookingRequest(manual({ type: "extra", dates: ["2026-11-23", "2026-11-30"] }), OPTS);
  assert.deepEqual(errorsOf(result), { dates: "weeksOnlyForWeek" });
  assert.ok(parseBookingRequest(manual({ type: "extra" }), OPTS).ok);
});

test("hora de llegada: HH:MM, obligatoria salvo en el dryRun", () => {
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ start: undefined }), OPTS)), { start: "required" });
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ start: "25:00" }), OPTS)), { start: "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ start: "" }), OPTS)), { start: "invalid" });
  const dry = parseBookingRequest(fromRequest({ start: null, dryRun: true }), OPTS);
  assert.ok(dry.ok);
  assert.equal(dry.value.start, null, "sin hora, la base evalúa cada fecha con su llegada sugerida");
  assert.equal(dry.value.dryRun, true);
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ dryRun: "true" }), OPTS)), { dryRun: "invalid" });
});

test("minutos de cocina, porciones y centavos: enteros dentro de sus límites", () => {
  const field = (overrides: Record<string, unknown>) => errorsOf(parseBookingRequest(fromRequest(overrides), OPTS));
  assert.deepEqual(field({ cookMinutes: undefined }), { cookMinutes: "required" });
  assert.deepEqual(field({ cookMinutes: 0 }), { cookMinutes: "range" });
  assert.deepEqual(field({ cookMinutes: 721 }), { cookMinutes: "range" });
  assert.deepEqual(field({ cookMinutes: 90.5 }), { cookMinutes: "invalid" });
  assert.deepEqual(field({ cookMinutes: "90" }), { cookMinutes: "invalid" });
  assert.deepEqual(field({ portions: -1 }), { portions: "range" });
  assert.deepEqual(field({ portions: 841 }), { portions: "range" });
  // Dinero siempre en centavos enteros: 140,50 € es 14050, nunca 140.5.
  assert.deepEqual(field({ serviceTotalCents: 140.5 }), { serviceTotalCents: "invalid" });
  assert.deepEqual(field({ serviceTotalCents: -100 }), { serviceTotalCents: "range" });
  assert.deepEqual(field({ serviceTotalCents: MAX_CENTS + 1 }), { serviceTotalCents: "range" });
  assert.ok(parseBookingRequest(fromRequest({ serviceTotalCents: MAX_CENTS, cookMinutes: 720, portions: 840 }), OPTS).ok);
});

test("groceriesEstCents ya no existe (19/11/2026, la compra la hace el cliente): si llega, se ignora como cualquier clave desconocida", () => {
  // La app de otras ramas todavía lo manda: no puede fallar, valga lo que valga.
  for (const groceriesEstCents of [7550, 0, "7550", 75.5, -1, Number.NaN, null]) {
    for (const body of [fromRequest({ groceriesEstCents }), manual({ groceriesEstCents })]) {
      const result = parseBookingRequest(body, OPTS);
      assert.ok(result.ok, String(groceriesEstCents));
      assert.ok(!("groceriesEstCents" in result.value), "no pasa a la reserva");
      const { groceriesEstCents: _ignorada, ...rest } = body;
      assert.deepEqual(result.value, (parseBookingRequest(rest, OPTS) as { value: unknown }).value);
    }
  }
});

test("requestKey: uuid (en minúsculas); obligatoria a mano salvo en el dryRun", () => {
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ requestKey: "no-es-uuid" }), OPTS)), { requestKey: "invalid" });
  assert.deepEqual(errorsOf(parseBookingRequest(manual({ requestKey: undefined }), OPTS)), { requestKey: "required" });
  assert.ok(parseBookingRequest(manual({ requestKey: undefined, dryRun: true }), OPTS).ok);
  assert.ok(parseBookingRequest(fromRequest({ requestKey: undefined }), OPTS).ok, "desde un pedido el reintento se reconoce por el estado del pedido");
  assert.deepEqual(errorsOf(parseBookingRequest(fromRequest({ requestKey: 12 }), OPTS)), { requestKey: "invalid" });
});

test("cuerpo que no es un objeto: payload invalid", () => {
  for (const input of [null, [], "x", 42, undefined]) {
    assert.deepEqual(errorsOf(parseBookingRequest(input, OPTS)), { payload: "invalid" });
    assert.deepEqual(errorsOf(parseMoveSessionRequest(input, OPTS)), { payload: "invalid" });
    assert.deepEqual(errorsOf(parseCancelSessionsRequest(input)), { payload: "invalid" });
  }
});

test("varios errores a la vez: un código por campo", () => {
  assert.deepEqual(errorsOf(parseBookingRequest({ requestId: REQUEST_ID, dates: [], cookMinutes: 0, serviceTotalCents: 1.5 }, OPTS)), {
    dates: "range",
    start: "required",
    cookMinutes: "range",
    serviceTotalCents: "invalid",
  });
});

// ---------------------------------------------------------------------------
// POST /sessions/move
// ---------------------------------------------------------------------------

test("mover: sesión, fecha y, si cambian, hora y minutos", () => {
  const result = parseMoveSessionRequest({ sessionId: SESSION_ID.toUpperCase(), date: "2026-11-25", start: "11:30", cookMinutes: 200, dryRun: true }, OPTS);
  assert.ok(result.ok);
  assert.deepEqual(result.value, { sessionId: SESSION_ID, date: "2026-11-25", start: "11:30", cookMinutes: 200, dryRun: true });

  const keep = parseMoveSessionRequest({ sessionId: SESSION_ID, date: "2026-11-25", start: null }, OPTS);
  assert.ok(keep.ok);
  assert.deepEqual(keep.value, { sessionId: SESSION_ID, date: "2026-11-25", start: null, cookMinutes: null, dryRun: false });
});

test("mover: validaciones", () => {
  const move = (overrides: Record<string, unknown>) =>
    errorsOf(parseMoveSessionRequest({ sessionId: SESSION_ID, date: "2026-11-25", ...overrides }, OPTS));
  assert.deepEqual(move({ sessionId: undefined }), { sessionId: "required" });
  assert.deepEqual(move({ sessionId: "abc" }), { sessionId: "invalid" });
  assert.deepEqual(move({ date: undefined }), { date: "required" });
  assert.deepEqual(move({ date: "25/11/2026" }), { date: "invalid" });
  assert.deepEqual(move({ date: "2027-11-18" }), { date: "dateOutOfRange" });
  assert.deepEqual(move({ start: "9:00" }), { start: "invalid" });
  assert.deepEqual(move({ cookMinutes: 0 }), { cookMinutes: "range" });
  assert.deepEqual(move({ cookMinutes: MAX_COOK_MINUTES + 1 }), { cookMinutes: "range" });
  assert.ok(parseMoveSessionRequest({ sessionId: SESSION_ID, date: "2026-11-25", cookMinutes: MAX_COOK_MINUTES }, OPTS).ok);
  assert.deepEqual(move({ cookMinutes: 60.5 }), { cookMinutes: "invalid" });
  assert.deepEqual(move({ dryRun: 1 }), { dryRun: "invalid" });
});

// ---------------------------------------------------------------------------
// POST /sessions/cancel
// ---------------------------------------------------------------------------

test("cancelar: ids en minúsculas y sin repetir; motivo por defecto y sin cancelar semanas cobradas", () => {
  const other = "5e550000-0000-4000-8000-000000000004";
  const result = parseCancelSessionsRequest({ sessionIds: [SESSION_ID.toUpperCase(), other, SESSION_ID] });
  assert.ok(result.ok);
  assert.deepEqual(result.value, { sessionIds: [SESSION_ID, other], reason: DEFAULT_CANCEL_REASON, allowWithPayments: false });
  for (const code of CANCEL_REASONS) {
    const reason = parseCancelSessionsRequest({ sessionIds: [SESSION_ID], reason: code });
    assert.ok(reason.ok, code);
    assert.equal(reason.value.reason, code);
  }
  const paid = parseCancelSessionsRequest({ sessionIds: [SESSION_ID], allowWithPayments: true });
  assert.ok(paid.ok);
  assert.equal(paid.value.allowWithPayments, true, "con permiso, para registrar la devolución");
  assert.deepEqual(errorsOf(parseCancelSessionsRequest({ sessionIds: [SESSION_ID], allowWithPayments: "true" })), { allowWithPayments: "invalid" });
});

test("cancelar: de 1 a 100 sesiones y un motivo de la lista, nunca texto libre", () => {
  assert.deepEqual(errorsOf(parseCancelSessionsRequest({})), { sessionIds: "required" });
  assert.deepEqual(errorsOf(parseCancelSessionsRequest({ sessionIds: [] })), { sessionIds: "range" });
  const many = Array.from({ length: MAX_CANCEL_SESSIONS + 1 }, (_, i) => `5e550000-0000-4000-8000-${String(i).padStart(12, "0")}`);
  assert.deepEqual(errorsOf(parseCancelSessionsRequest({ sessionIds: many })), { sessionIds: "range" });
  assert.ok(parseCancelSessionsRequest({ sessionIds: many.slice(0, MAX_CANCEL_SESSIONS) }).ok);
  assert.deepEqual(errorsOf(parseCancelSessionsRequest({ sessionIds: [SESSION_ID, "x"] })), { sessionIds: "invalid" });
  assert.deepEqual(errorsOf(parseCancelSessionsRequest({ sessionIds: SESSION_ID })), { sessionIds: "invalid" });
  // Una frase en snake_case o un código del sistema (hold_expired, declined) tampoco: la clienta con cuenta lee su sesión.
  for (const reason of ["Se enfermó la clienta", "1abc", "x".repeat(41), "chef-cancelled", 7, "clienta_maleducada_no_paga", "hold_expired", "declined", "CHEF_CANCELLED"]) {
    assert.deepEqual(errorsOf(parseCancelSessionsRequest({ sessionIds: [SESSION_ID], reason })), { reason: "invalid" }, String(reason));
  }
});

// ---------------------------------------------------------------------------
// POST /translate
// ---------------------------------------------------------------------------

test("traducir: el plato en español, recortado; sin descripción (ausente, null, vacía o solo espacios) es null", () => {
  assert.deepEqual(parseTranslateRequest({ name: "  Milanesa a la napolitana ", description: " Con jamón y muzzarella. " }), {
    ok: true,
    value: { name: "Milanesa a la napolitana", description: "Con jamón y muzzarella." },
  });
  for (const description of [undefined, null, "", "   "]) {
    const body = description === undefined ? { name: "Empanadas" } : { name: "Empanadas", description };
    assert.deepEqual(parseTranslateRequest(body), { ok: true, value: { name: "Empanadas", description: null } }, JSON.stringify(description));
  }
  // Espacios dobles en el medio quedan: la base los acepta (la app los normaliza antes de mandar).
  assert.deepEqual(parseTranslateRequest({ name: "Chipá  caliente" }), { ok: true, value: { name: "Chipá  caliente", description: null } });
});

test("traducir: los largos se cuentan por caracteres como la base (un emoji es uno), hasta 120 y 200", () => {
  assert.equal(textLength("🍝"), 1);
  assert.equal(textLength("Ñoquis"), 6);
  assert.ok(parseTranslateRequest({ name: "x".repeat(RECIPE_NAME_MAX), description: "y".repeat(RECIPE_DESCRIPTION_MAX) }).ok);
  assert.ok(parseTranslateRequest({ name: "🍝".repeat(RECIPE_NAME_MAX), description: "🥟".repeat(RECIPE_DESCRIPTION_MAX) }).ok, "240 unidades UTF-16, 120 caracteres");
  assert.ok(parseTranslateRequest({ name: ` ${"x".repeat(RECIPE_NAME_MAX)} ` }).ok, "se cuenta después de recortar");
  assert.deepEqual(errorsOf(parseTranslateRequest({ name: "x".repeat(RECIPE_NAME_MAX + 1) })), { name: "tooLong" });
  assert.deepEqual(errorsOf(parseTranslateRequest({ name: "Locro", description: "🥟".repeat(RECIPE_DESCRIPTION_MAX + 1) })), { description: "tooLong" });
});

test("traducir: nombre obligatorio y de texto; caracteres de control en cualquiera de los dos: invalid", () => {
  for (const name of [undefined, null, "", "   "]) {
    assert.deepEqual(errorsOf(parseTranslateRequest(name === undefined ? {} : { name })), { name: "required" }, JSON.stringify(name));
  }
  for (const name of [5, true, ["Locro"], { es: "Locro" }]) {
    assert.deepEqual(errorsOf(parseTranslateRequest({ name })), { name: "invalid" }, JSON.stringify(name));
  }
  for (const description of [5, false, ["Con zapallo"], { es: "Con zapallo" }]) {
    assert.deepEqual(errorsOf(parseTranslateRequest({ name: "Locro", description })), { description: "invalid" }, JSON.stringify(description));
  }
  // Un salto de línea, un tabulador, un C1 (U+0085) o un separador de línea: la base los rechaza.
  for (const text of ["Locro\ncriollo", "Locro\tcriollo", "Locro\u0085criollo", "Locro\u2028criollo", "Locro\u0000"]) {
    assert.deepEqual(errorsOf(parseTranslateRequest({ name: text })), { name: "invalid" }, JSON.stringify(text));
    assert.deepEqual(errorsOf(parseTranslateRequest({ name: "Locro", description: text })), { description: "invalid" }, JSON.stringify(text));
  }
});

test("traducir: una clave que el contrato no tiene o un cuerpo que no es un objeto: payload invalid", () => {
  for (const extra of [{ nameEs: "Locro" }, { locale: "it" }, { chefId: "cef00000-0000-4000-8000-000000000001" }]) {
    assert.deepEqual(errorsOf(parseTranslateRequest({ name: "Locro", ...extra })), { payload: "invalid" }, JSON.stringify(extra));
  }
  assert.deepEqual(errorsOf(parseTranslateRequest({ name: "", extra: 1 })), { payload: "invalid", name: "required" }, "con los errores de cada campo");
  for (const input of [null, [], "Locro", 7]) {
    assert.deepEqual(errorsOf(parseTranslateRequest(input)), { payload: "invalid" }, JSON.stringify(input));
  }
});

// ---------------------------------------------------------------------------
// Envío del menú de una semana (§13)
// ---------------------------------------------------------------------------

const SEND_ID = "5e550000-0000-4000-8000-0000000000aa";

test("estados de sesión: los del enum; la versión del menú, un int de Postgres", () => {
  assert.deepEqual([...SESSION_STATUSES], ["held", "confirmed", "shopping_done", "cooked", "paid", "cancelled"]);
  assert.equal(MAX_MENU_VERSION, 2_147_483_647);
});

test("vista previa: la sesión en minúsculas, la versión del menú y traducir por defecto", () => {
  assert.deepEqual(parseMenuPreviewRequest({ sessionId: SESSION_ID.toUpperCase(), menuVersion: 3 }), {
    ok: true,
    value: { sessionId: SESSION_ID, menuVersion: 3, translate: true },
  });
  assert.deepEqual(parseMenuPreviewRequest({ sessionId: SESSION_ID, menuVersion: 1, translate: false }), {
    ok: true,
    value: { sessionId: SESSION_ID, menuVersion: 1, translate: false },
  });
  assert.deepEqual(parseMenuPreviewRequest({ sessionId: SESSION_ID, menuVersion: MAX_MENU_VERSION, translate: null }), {
    ok: true,
    value: { sessionId: SESSION_ID, menuVersion: MAX_MENU_VERSION, translate: true },
  });
});

test("vista previa: 400 por campo; una clave de más o un cuerpo que no es un objeto, payload invalid", () => {
  const cases: Array<[unknown, unknown]> = [
    [{}, { sessionId: "required", menuVersion: "required" }],
    [{ sessionId: "x", menuVersion: 1 }, { sessionId: "invalid" }],
    [{ sessionId: SESSION_ID, menuVersion: 0 }, { menuVersion: "range" }],
    [{ sessionId: SESSION_ID, menuVersion: MAX_MENU_VERSION + 1 }, { menuVersion: "range" }],
    [{ sessionId: SESSION_ID, menuVersion: 1.5 }, { menuVersion: "invalid" }],
    [{ sessionId: SESSION_ID, menuVersion: "1" }, { menuVersion: "invalid" }],
    [{ sessionId: SESSION_ID, menuVersion: 1, translate: "no" }, { translate: "invalid" }],
    [{ sessionId: SESSION_ID, menuVersion: 1, locale: "it" }, { payload: "invalid" }],
    [{ sessionId: SESSION_ID, menuVersion: 1, chefId: SESSION_ID }, { payload: "invalid" }],
    [null, { payload: "invalid" }],
    [[SESSION_ID], { payload: "invalid" }],
  ];
  for (const [input, expected] of cases) {
    assert.deepEqual(errorsOf(parseMenuPreviewRequest(input)), expected, JSON.stringify(input));
  }
});

test("enviar: el envío en minúsculas y por dónde sale; ausente es false, y al menos uno", () => {
  assert.deepEqual(parseMenuSendRequest({ sendId: SEND_ID.toUpperCase(), email: true, whatsapp: false }), {
    ok: true,
    value: { sendId: SEND_ID, email: true, whatsapp: false },
  });
  assert.deepEqual(parseMenuSendRequest({ sendId: SEND_ID, whatsapp: true }), {
    ok: true,
    value: { sendId: SEND_ID, email: false, whatsapp: true },
  });
  assert.deepEqual(parseMenuSendRequest({ sendId: SEND_ID, email: true, whatsapp: true }), {
    ok: true,
    value: { sendId: SEND_ID, email: true, whatsapp: true },
  });
});

test("enviar: 400 por campo; sin ningún canal, channels required; una clave de más, payload invalid", () => {
  const cases: Array<[unknown, unknown]> = [
    [{ email: true }, { sendId: "required" }],
    [{ sendId: "abc", email: true }, { sendId: "invalid" }],
    [{ sendId: SEND_ID }, { channels: "required" }],
    [{ sendId: SEND_ID, email: false, whatsapp: false }, { channels: "required" }],
    [{ sendId: SEND_ID, email: "yes" }, { email: "invalid" }],
    [{ sendId: SEND_ID, email: true, whatsapp: 1 }, { whatsapp: "invalid" }],
    [{ sendId: SEND_ID, email: true, to: "otra@example.test" }, { payload: "invalid" }],
    [{ sendId: SEND_ID, whatsapp: true, phone: "+390000" }, { payload: "invalid" }],
    ["x", { payload: "invalid" }],
  ];
  for (const [input, expected] of cases) {
    assert.deepEqual(errorsOf(parseMenuSendRequest(input)), expected, JSON.stringify(input));
  }
});

test("menuSendChannels: en el orden de la base, email antes que whatsapp", () => {
  assert.deepEqual(menuSendChannels({ email: true, whatsapp: true }), ["email", "whatsapp"]);
  assert.deepEqual(menuSendChannels({ email: false, whatsapp: true }), ["whatsapp"]);
  assert.deepEqual(menuSendChannels({ email: true, whatsapp: false }), ["email"]);
});
