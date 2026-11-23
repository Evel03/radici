// Tests del contrato del link de la clienta (docs/contracts/client-link.md): el token y su hash, el link,
// el mensaje de cambios y la lectura defensiva de la foto de un envío y de la respuesta de POST …/view.
// Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  CHANGES_TEXT_MAX,
  CLIENT_LINK_ROUTES,
  CLIENT_LINK_VERSION,
  RESERVATION_PAGE_PATH,
  SHOPPING_SECTIONS,
  changesTextProblem,
  cleanChangesText,
  hashClientLinkToken,
  isClientLinkToken,
  menuState,
  newClientLinkToken,
  normalizeChangesText,
  parseClientLinkView,
  QUOTE_CLOSED_REASONS,
  QUOTE_STATUSES,
  quoteSummaryFromSnapshot,
  readMenuSnapshot,
  reservationPageUrl,
  textLength,
  type ClientLinkQuote,
  type ClientLinkView,
} from "./client_link.ts";
import { recipePhotoUrls } from "./menu.ts";

const ORIGIN = "https://abcdefgh.supabase.co";
const CHEF_ID = "cef00000-0000-4000-8000-000000000001";
const RECIPE_ID = "0a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";
const PHOTO_ID = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f";
const SEND_ID = "5e0d0000-0000-4000-8000-000000000001";
const SESSION_1 = "5e550000-0000-4000-8000-000000000001";
const SESSION_2 = "5e550000-0000-4000-8000-000000000002";
const TOKEN = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCdE";

/** Una foto de un envío como la arma la función chef (SPEC 5.8), con campos de más que hay que ignorar. */
function snapshot(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    v: 1,
    locale: "es",
    session: { date: "2027-03-01", start: "10:00", week: 1, weeks: 4 },
    weeks: [{ date: "2027-03-01", start: "10:00" }],
    dishes: [
      {
        name: "Lasaña",
        description: "Ragú y bechamel.",
        allergens: ["milk", "gluten", "eggs"],
        diet: null,
        portions: 6,
        photo: recipePhotoUrls(ORIGIN, CHEF_ID, RECIPE_ID, PHOTO_ID),
        recipeId: RECIPE_ID,
      },
      { name: "Minestrone", description: null, allergens: [], diet: "vegan", portions: 4, photo: null },
    ],
    items: [
      { name: "Tomates", section: "produce", quantity: 1250, unit: "g" },
      { name: "Sal", section: "pantry", quantity: null, unit: null },
    ],
    note: "Hola Anna:\nel martes llego a las 10.",
    extra: { anything: true },
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Token, hash y link
// ---------------------------------------------------------------------------

test("token: 43 caracteres base64url (32 bytes al azar); nada más", () => {
  assert.equal(isClientLinkToken(TOKEN), true);
  for (const bad of [TOKEN.slice(1), `${TOKEN}A`, `${TOKEN.slice(1)}+`, `${TOKEN.slice(1)}/`, `${TOKEN.slice(1)}=`, ` ${TOKEN.slice(1)}`, "", null, 42, undefined]) {
    assert.equal(isClientLinkToken(bad), false, String(bad));
  }
});

test("newClientLinkToken: 32 bytes al azar en base64url sin relleno, distinto cada vez", () => {
  const a = newClientLinkToken();
  const b = newClientLinkToken();
  assert.equal(isClientLinkToken(a), true);
  assert.notEqual(a, b);
  assert.equal(Buffer.from(a, "base64url").length, 32);
  assert.equal(Buffer.from(a, "base64url").toString("base64url"), a);
});

test("hashClientLinkToken: sha-256 del token en UTF-8, en hexadecimal minúscula (como encode(sha256(convert_to(t, 'UTF8')), 'hex'))", async () => {
  // Vector conocido de SHA-256.
  assert.equal(await hashClientLinkToken("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  for (const token of [TOKEN, newClientLinkToken(), "token-a"]) {
    const hash = await hashClientLinkToken(token);
    assert.match(hash, /^[0-9a-f]{64}$/);
    assert.equal(hash, createHash("sha256").update(token, "utf8").digest("hex"));
  }
});

test("reservationPageUrl: la página /prenotazione/ con el token en el fragmento (#t=…), nunca en la query", () => {
  assert.equal(RESERVATION_PAGE_PATH, "/prenotazione/");
  assert.equal(reservationPageUrl("https://radicicucina.app", TOKEN), `https://radicicucina.app/prenotazione/#t=${TOKEN}`);
  assert.equal(reservationPageUrl("https://radicicucina.app//", TOKEN), `https://radicicucina.app/prenotazione/#t=${TOKEN}`);
  assert.equal(new URL(reservationPageUrl("https://radicicucina.app", TOKEN)).search, "");
});

test("rutas de la función: view, confirm, changes y, para el presupuesto, accept y decline", () => {
  assert.deepEqual(CLIENT_LINK_ROUTES, { view: "/view", confirm: "/confirm", changes: "/changes", accept: "/accept", decline: "/decline" });
  assert.deepEqual([...QUOTE_STATUSES], ["sent", "changed", "accepted", "declined", "withdrawn", "expired"], "los de client_link_view");
  assert.deepEqual([...QUOTE_CLOSED_REASONS], ["accepted", "declined", "withdrawn", "expired"], "el DETAIL de quote_closed");
});

// ---------------------------------------------------------------------------
// Mensaje de cambios
// ---------------------------------------------------------------------------

test("normalizeChangesText: como lo acepta la base (saltos de línea a \\n, recortado, 1 a 1000 caracteres, sin controles)", () => {
  assert.equal(normalizeChangesText("  Sin cebolla, por favor.\r\nGracias  "), "Sin cebolla, por favor.\nGracias");
  // Los saltos que llegan pegados desde otros programas: \r suelto, los manuales de Word y PowerPoint (\v y \f),
  // NEL y los separadores de línea y de párrafo; las tabulaciones, a espacios.
  assert.equal(normalizeChangesText("uno\rdos\u2028tres\u2029cuatro\tcinco"), "uno\ndos\ntres\ncuatro cinco");
  assert.equal(normalizeChangesText("Lasagne\vRisotto\fPollo\u0085Fine"), "Lasagne\nRisotto\nPollo\nFine");
  // Los demás caracteres de control no se ven y la base no los acepta: se sacan.
  assert.equal(normalizeChangesText("hola\u0000"), "hola");
  assert.equal(normalizeChangesText("hola\u0007chau\u009b"), "holachau");
  assert.equal(normalizeChangesText("\n\n  \t \u000b"), null);
  assert.equal(normalizeChangesText("\u0000\u0001"), null);
  assert.equal(normalizeChangesText(""), null);
  for (const bad of [null, undefined, 3, ["a"], { text: "a" }]) assert.equal(normalizeChangesText(bad), null);
});

test("changesTextProblem: vacío o demasiado largo (la página dice cuál)", () => {
  assert.equal(changesTextProblem(cleanChangesText("  \n\u0000 ")), "empty");
  assert.equal(changesTextProblem(cleanChangesText("a".repeat(CHANGES_TEXT_MAX + 1))), "tooLong");
  assert.equal(changesTextProblem(cleanChangesText("Senza cipolla")), null);
  // Lo que queda lo acepta la base: solo \n como salto, sin otros caracteres de control.
  const cleaned = cleanChangesText("a\u0085b\u2028c\u0001d\te");
  assert.equal(cleaned, "a\nb\ncd e");
  assert.doesNotMatch(cleaned.replace(/\n/g, ""), /[\x00-\x1f\x7f-\x9f]/);
});

test("normalizeChangesText: el tope cuenta caracteres como Postgres (code points), no unidades UTF-16", () => {
  const emoji = "🍝";
  assert.equal(emoji.length, 2);
  assert.equal(textLength(emoji), 1);
  const atLimit = emoji.repeat(CHANGES_TEXT_MAX);
  assert.equal(normalizeChangesText(atLimit), atLimit);
  assert.equal(normalizeChangesText(`${atLimit}a`), null);
  assert.equal(normalizeChangesText("a".repeat(CHANGES_TEXT_MAX)), "a".repeat(CHANGES_TEXT_MAX));
  assert.equal(normalizeChangesText("a".repeat(CHANGES_TEXT_MAX + 1)), null);
});

// ---------------------------------------------------------------------------
// Foto de un envío
// ---------------------------------------------------------------------------

test("readMenuSnapshot: platos, lista y nota, sin los campos que no son del contrato", () => {
  const content = readMenuSnapshot(snapshot(), ORIGIN);
  assert.deepEqual(content, {
    locale: "es",
    dishes: [
      {
        name: "Lasaña",
        description: "Ragú y bechamel.",
        // En el orden de los 14 del reglamento.
        allergens: ["gluten", "eggs", "milk"],
        diet: null,
        portions: 6,
        photo: recipePhotoUrls(ORIGIN, CHEF_ID, RECIPE_ID, PHOTO_ID),
      },
      { name: "Minestrone", description: null, allergens: [], diet: "vegan", portions: 4, photo: null },
    ],
    items: [
      { name: "Tomates", section: "produce", quantity: 1250, unit: "g" },
      { name: "Sal", section: "pantry", quantity: null, unit: null },
    ],
    note: "Hola Anna:\nel martes llego a las 10.",
  });
});

test("readMenuSnapshot: la foto nunca descarta un plato (otro origen, otro bucket, sin origen: sin foto)", () => {
  const other = snapshot({
    dishes: [{ name: "Lasaña", description: null, allergens: [], diet: null, portions: 2, photo: recipePhotoUrls("https://evil.example", CHEF_ID, RECIPE_ID, PHOTO_ID) }],
  });
  assert.equal(readMenuSnapshot(other, ORIGIN)?.dishes[0]?.photo, null);
  assert.equal(readMenuSnapshot(snapshot(), null)?.dishes[0]?.photo, null);
  const swapped = recipePhotoUrls(ORIGIN, CHEF_ID, RECIPE_ID, PHOTO_ID);
  const mixed = snapshot({
    dishes: [{ name: "Lasaña", description: null, allergens: [], diet: null, portions: 2, photo: { thumb: swapped.full, full: swapped.thumb } }],
  });
  assert.equal(readMenuSnapshot(mixed, ORIGIN)?.dishes[0]?.photo, null);
  const noPhotoKey = snapshot({ dishes: [{ name: "Lasaña", description: null, allergens: [], diet: null, portions: 2 }] });
  assert.equal(readMenuSnapshot(noPhotoKey, ORIGIN)?.dishes[0]?.photo, null);
});

test("readMenuSnapshot: una sección desconocida va a «other»; alérgenos repetidos, una vez; nota en blanco, null", () => {
  const content = readMenuSnapshot(
    snapshot({
      dishes: [{ name: "Pan", allergens: ["gluten", "gluten"], portions: 1 }],
      items: [{ name: "Harina", section: "bulk", quantity: 1, unit: "pcs" }],
      note: "  \n ",
    }),
    ORIGIN,
  );
  assert.deepEqual(content?.dishes, [{ name: "Pan", description: null, allergens: ["gluten"], diet: null, portions: 1, photo: null }]);
  assert.deepEqual(content?.items, [{ name: "Harina", section: "other", quantity: 1, unit: "pcs" }]);
  assert.equal(content?.note, null);
  assert.deepEqual(readMenuSnapshot(snapshot({ note: undefined }), ORIGIN)?.note, null);
  assert.deepEqual([...SHOPPING_SECTIONS], ["produce", "meat_fish", "dairy_eggs", "bakery", "pantry", "frozen", "other"]);
});

test("readMenuSnapshot: con otra forma no se muestra a medias (null): versión, idioma, platos, alérgenos, porciones, cantidades", () => {
  const dish = { name: "Lasaña", description: null, allergens: [], diet: null, portions: 2, photo: null };
  const item = { name: "Tomates", section: "produce", quantity: 100, unit: "g" };
  const cases: Array<[string, unknown]> = [
    ["no es un objeto", "texto"],
    ["sin versión", snapshot({ v: undefined })],
    ["otra versión", snapshot({ v: 2 })],
    ["idioma desconocido", snapshot({ locale: "fr" })],
    ["sin platos", snapshot({ dishes: [] })],
    ["platos que no son una lista", snapshot({ dishes: "Lasaña" })],
    ["plato sin nombre", snapshot({ dishes: [{ ...dish, name: " " }] })],
    ["descripción que no es texto", snapshot({ dishes: [{ ...dish, description: 3 }] })],
    ["alérgeno desconocido", snapshot({ dishes: [{ ...dish, allergens: ["gluten", "pollen"] }] })],
    ["sin alérgenos", snapshot({ dishes: [{ ...dish, allergens: undefined }] })],
    ["dieta desconocida", snapshot({ dishes: [{ ...dish, diet: "keto" }] })],
    ["porciones 0", snapshot({ dishes: [{ ...dish, portions: 0 }] })],
    ["porciones 501", snapshot({ dishes: [{ ...dish, portions: 501 }] })],
    ["porciones con decimales", snapshot({ dishes: [{ ...dish, portions: 1.5 }] })],
    ["sin lista", snapshot({ items: undefined })],
    ["renglón sin nombre", snapshot({ items: [{ ...item, name: "" }] })],
    ["cantidad sin unidad", snapshot({ items: [{ ...item, unit: null }] })],
    ["unidad sin cantidad", snapshot({ items: [{ ...item, quantity: null }] })],
    ["unidad desconocida", snapshot({ items: [{ ...item, unit: "kg" }] })],
    ["cantidad 0", snapshot({ items: [{ ...item, quantity: 0 }] })],
    ["cantidad con decimales", snapshot({ items: [{ ...item, quantity: 2.5 }] })],
    ["cantidad de más", snapshot({ items: [{ ...item, quantity: 1_000_001 }] })],
    ["nota que no es texto", snapshot({ note: ["hola"] })],
  ];
  for (const [label, value] of cases) assert.equal(readMenuSnapshot(value, ORIGIN), null, label);
});

// ---------------------------------------------------------------------------
// Respuesta de POST …/view (lo que lee la web)
// ---------------------------------------------------------------------------

function view(): ClientLinkView {
  const content = readMenuSnapshot(snapshot(), ORIGIN);
  assert.ok(content);
  return {
    version: CLIENT_LINK_VERSION,
    locale: "es",
    chefName: "Evelyn",
    clientFirstName: "Anna",
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
          sendId: SEND_ID,
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
  };
}

const QUOTE_ID = "5e550000-0000-4000-8000-0000000000a1";

/** El presupuesto por aceptar (2 semanas, 300 €) que lleva el envío de la semana 1. */
function quote(overrides: Partial<ClientLinkQuote> = {}): ClientLinkQuote {
  return {
    id: QUOTE_ID,
    version: 1,
    status: "sent",
    sentAt: "2027-02-25T18:03:00.123456+00:00",
    holdUntil: "2027-02-27T18:03:00.123456+00:00",
    acceptedAt: null,
    sendId: SEND_ID,
    summary: {
      totalCents: 30000,
      weeks: [
        { date: "2027-03-01", start: "10:00", serviceCents: 15000 },
        { date: "2027-03-08", start: "10:00", serviceCents: 15000 },
      ],
    },
    ...overrides,
  };
}

/** La reserva con el presupuesto: el envío de la semana 1 lo lleva. */
function quoteView(overrides: Partial<ClientLinkQuote> = {}): ClientLinkView {
  const value = view();
  const [first, second] = value.weeks;
  assert.ok(first?.menu && second);
  return { ...value, quote: quote(overrides), weeks: [{ ...first, menu: { ...first.menu, quoteId: QUOTE_ID } }, second] };
}

test("menuState: confirmado, con cambios pedidos o por confirmar", () => {
  assert.equal(menuState(null, null), "pending");
  assert.equal(menuState("2027-02-26T10:00:00Z", null), "confirmed");
  assert.equal(menuState(null, "2027-02-26T10:00:00Z"), "changesRequested");
});

test("parseClientLinkView: la respuesta tal cual, después de pasar por JSON", () => {
  const value = view();
  assert.deepEqual(parseClientLinkView(JSON.parse(JSON.stringify(value)), ORIGIN), value);
});

test("parseClientLinkView: un menú que no se puede leer queda sin contenido (la página no deja contestarlo)", () => {
  const value = JSON.parse(JSON.stringify(view())) as { weeks: Array<{ menu: { content: unknown } | null }> };
  const first = value.weeks[0]?.menu;
  assert.ok(first);
  first.content = { locale: "es", dishes: [], items: [], note: null };
  assert.equal(parseClientLinkView(value, ORIGIN)?.weeks[0]?.menu?.content, null);
});

test("parseClientLinkView: con otra forma, null (la página dice que hubo un problema)", () => {
  const mutate = (change: (value: Record<string, unknown> & { weeks: Array<Record<string, unknown>> }) => void): unknown => {
    const value = JSON.parse(JSON.stringify(view())) as Record<string, unknown> & { weeks: Array<Record<string, unknown>> };
    change(value);
    return value;
  };
  const cases: Array<[string, unknown]> = [
    ["no es un objeto", null],
    ["otra versión", mutate((v) => (v["version"] = 2))],
    ["idioma desconocido", mutate((v) => (v["locale"] = "de"))],
    ["sin cocinera", mutate((v) => (v["chefName"] = ""))],
    ["nombre que no es texto", mutate((v) => (v["clientFirstName"] = 3))],
    ["semanas que no son una lista", mutate((v) => (v["weeks"] = {}))],
    ["semana sin sesión", mutate((v) => delete v.weeks[0]!["sessionId"])],
    ["sesión que no es un uuid", mutate((v) => (v.weeks[0]!["sessionId"] = "semana-1"))],
    ["fecha inválida", mutate((v) => (v.weeks[0]!["date"] = "2027-02-30"))],
    ["hora inválida", mutate((v) => (v.weeks[0]!["start"] = "25:00"))],
    ["semana 0", mutate((v) => (v.weeks[0]!["week"] = 0))],
    ["done que no es booleano", mutate((v) => (v.weeks[0]!["done"] = "no"))],
    ["envío sin id", mutate((v) => ((v.weeks[0]!["menu"] as Record<string, unknown>)["sendId"] = "x"))],
    ["estado desconocido", mutate((v) => ((v.weeks[0]!["menu"] as Record<string, unknown>)["state"] = "maybe"))],
    ["fecha de envío inválida", mutate((v) => ((v.weeks[0]!["menu"] as Record<string, unknown>)["sentAt"] = "ayer"))],
    [
      "estado que no coincide con las fechas",
      mutate((v) => ((v.weeks[0]!["menu"] as Record<string, unknown>)["confirmedAt"] = "2027-02-26T10:00:00Z")),
    ],
  ];
  for (const [label, value] of cases) assert.equal(parseClientLinkView(value, ORIGIN), null, label);
});

test("parseClientLinkView: el presupuesto y el de cada envío, tal cual después de pasar por JSON", () => {
  const value = quoteView();
  assert.deepEqual(parseClientLinkView(JSON.parse(JSON.stringify(value)), ORIGIN), value);
  const accepted = quoteView({ status: "accepted", acceptedAt: "2027-02-26T09:00:00+00:00" });
  assert.deepEqual(parseClientLinkView(JSON.parse(JSON.stringify(accepted)), ORIGIN), accepted);
  const closed = quoteView({ status: "withdrawn", summary: null, sendId: null, holdUntil: null });
  assert.deepEqual(parseClientLinkView(JSON.parse(JSON.stringify(closed)), ORIGIN), closed);
});

test("parseClientLinkView: una función de antes (sin quote ni quoteId) es una reserva sin presupuesto", () => {
  const value = JSON.parse(JSON.stringify(view())) as Record<string, unknown> & { weeks: Array<{ menu: Record<string, unknown> | null }> };
  delete value["quote"];
  delete value.weeks[0]?.menu?.["quoteId"];
  const parsed = parseClientLinkView(value, ORIGIN);
  assert.equal(parsed?.quote, null);
  assert.equal(parsed?.weeks[0]?.menu?.quoteId, null);
});

test("parseClientLinkView: un presupuesto con otra forma, null (la página dice que hubo un problema)", () => {
  const mutate = (change: (value: Record<string, unknown>) => void): unknown => {
    const value = JSON.parse(JSON.stringify(quoteView())) as Record<string, unknown>;
    change(value);
    return value;
  };
  const quoteOf = (value: Record<string, unknown>): Record<string, unknown> => value["quote"] as Record<string, unknown>;
  const cases: Array<[string, unknown]> = [
    ["no es un objeto", mutate((v) => (v["quote"] = "presupuesto"))],
    ["estado desconocido", mutate((v) => (quoteOf(v)["status"] = "pending"))],
    ["versión 0", mutate((v) => (quoteOf(v)["version"] = 0))],
    ["sin fecha de envío", mutate((v) => (quoteOf(v)["sentAt"] = null))],
    ["aceptado sin fecha", mutate((v) => (quoteOf(v)["status"] = "accepted"))],
    ["con fecha de aceptado sin estar aceptado", mutate((v) => (quoteOf(v)["acceptedAt"] = "2027-02-26T09:00:00Z"))],
    ["envío que no es un uuid", mutate((v) => (quoteOf(v)["sendId"] = "x"))],
    ["el total no es la suma", mutate((v) => ((quoteOf(v)["summary"] as Record<string, unknown>)["totalCents"] = 1))],
    ["resumen sin semanas", mutate((v) => (quoteOf(v)["summary"] = { totalCents: 0, weeks: [] }))],
    ["precio con decimales", mutate((v) => (quoteOf(v)["summary"] = { totalCents: 1.5, weeks: [{ date: "2027-03-01", start: "10:00", serviceCents: 1.5 }] }))],
    ["quoteId que no es un uuid", mutate((v) => (((v["weeks"] as Array<Record<string, unknown>>)[0]!["menu"] as Record<string, unknown>)["quoteId"] = 7))],
  ];
  for (const [label, value] of cases) assert.equal(parseClientLinkView(value, ORIGIN), null, label);
});

test("quoteSummaryFromSnapshot: lo que vio la clienta sale de la foto del envío (las semanas y el total); sin presupuesto, null", () => {
  const withQuote = snapshot({
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
  });
  assert.deepEqual(quoteSummaryFromSnapshot(withQuote), quote().summary);
  assert.equal(quoteSummaryFromSnapshot(snapshot()), null);
  assert.equal(quoteSummaryFromSnapshot(snapshot({ quote: { version: 1, totalCents: 1, weeks: [] } })), null, "uno que no cierra");
  assert.equal(quoteSummaryFromSnapshot("foto"), null);
  // La foto del menú no cambia por llevar el presupuesto.
  assert.deepEqual(readMenuSnapshot(withQuote, ORIGIN), readMenuSnapshot(snapshot(), ORIGIN));
});
