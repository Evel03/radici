// Tests de las partes puras del envío del menú (menu_send.ts, contrato docs/contracts/chef-api.md §13):
// la lectura de lo que devuelven las funciones SQL, la foto del envío, el token del link y su hash.
// Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readMenuSnapshot } from "../_shared/menu_snapshot.ts";
import {
  CLIENT_TOKEN_BYTES,
  buildMenuSnapshot,
  clientLinkUrl,
  completedSendFromRpc,
  dishDescription,
  dishName,
  linkedSendFromRpc,
  menuSendContextFromRpc,
  newClientToken,
  preparedSendIdFromRpc,
  sendableEmail,
  sha256Hex,
  snapshotQuoteOf,
  whatsappPhone,
  type ContextDish,
} from "./menu_send.ts";

const CHEF_ID = "cef00000-0000-4000-8000-000000000001";
const SESSION_ID = "5e550000-0000-4000-8000-000000000003";
const REQUEST_ID = "5e550000-0000-4000-8000-000000000001";
const RECIPE_A = "aaaa0000-0000-4000-8000-000000000001";
const RECIPE_B = "aaaa0000-0000-4000-8000-000000000002";
const PHOTO_ID = "bbbb0000-0000-4000-8000-000000000001";
const SEND_ID = "5e550000-0000-4000-8000-0000000000aa";
const ORIGIN = "https://abcdefghijklmnop.supabase.co";
/** La huella de private.menu_send_fingerprint: md5 en hexadecimal. */
const FINGERPRINT = "0123456789abcdef0123456789abcdef";

/** Lo que devuelve chef_menu_send_context (la forma de la migración 20261121100000_menu_sends.sql). */
function contextRpc(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    session: { id: SESSION_ID, date: "2026-11-30", start: "10:00", status: "confirmed", requestId: REQUEST_ID, week: 1, weeks: 2 },
    weeks: [
      { sessionId: SESSION_ID, date: "2026-11-30", start: "10:00" },
      { sessionId: "5e550000-0000-4000-8000-000000000004", date: "2026-12-07", start: "10:00" },
    ],
    request: { id: REQUEST_ID, type: "week", locale: "en", adults: 2, kids: 1, days: 5, meals: ["dinner"] },
    contact: { name: "Maria Rossi", email: "maria@example.test", phone: "+393331234567" },
    chef: { displayName: "Evelyn" },
    menu: {
      version: 3,
      note: "Tené listos 4 táperes.",
      allergensConfirmed: false,
      dishes: [
        {
          recipeId: RECIPE_A,
          portions: 6,
          nameIt: "Lasagne",
          nameEs: "Lasaña",
          nameEn: null,
          descriptionIt: "Al ragù.",
          descriptionEs: "Con ragú.",
          descriptionEn: null,
          diet: null,
          photoId: PHOTO_ID,
          allergens: ["gluten", "eggs", "milk"],
        },
        {
          recipeId: RECIPE_B,
          portions: 4,
          nameIt: "Minestrone",
          nameEs: null,
          nameEn: "Vegetable soup",
          descriptionIt: null,
          descriptionEs: null,
          descriptionEn: "With beans.",
          diet: "vegan",
          photoId: null,
          allergens: [],
        },
      ],
      items: [
        { name: "zapallitos", section: "produce", quantity: 1250, unit: "g" },
        { name: "sal", section: "pantry", quantity: null, unit: null },
        { name: "zapallitos", section: "produce", quantity: 300, unit: "g" },
      ],
    },
    lastSend: null,
    fingerprint: FINGERPRINT,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// chef_menu_send_context
// ---------------------------------------------------------------------------

test("menuSendContextFromRpc: lo que usa la función, con el contacto recortado", () => {
  const context = menuSendContextFromRpc(contextRpc());
  assert.ok(context);
  assert.deepEqual(context.session, { id: SESSION_ID, date: "2026-11-30", start: "10:00", status: "confirmed", requestId: REQUEST_ID, week: 1, weeks: 2 });
  assert.deepEqual(context.weeks, [
    { date: "2026-11-30", start: "10:00" },
    { date: "2026-12-07", start: "10:00" },
  ]);
  assert.equal(context.locale, "en");
  assert.deepEqual(context.contact, { name: "Maria Rossi", email: "maria@example.test", phone: "+393331234567" });
  assert.equal(context.chefName, "Evelyn");
  assert.equal(context.menu.version, 3);
  assert.equal(context.menu.note, "Tené listos 4 táperes.");
  assert.equal(context.menu.dishes.length, 2);
  assert.deepEqual(context.menu.items[1], { name: "sal", section: "pantry", quantity: null, unit: null });
  assert.equal(context.fingerprint, FINGERPRINT, "va tal cual a chef_prepare_menu_send");

  const blank = menuSendContextFromRpc(contextRpc({ contact: { name: null, email: "  ", phone: "" }, chef: null }));
  assert.deepEqual(blank?.contact, { name: "", email: null, phone: null });
  assert.equal(blank?.chefName, "Evelyn", "sin nombre de la cocinera, el de public-request");
});

test("menuSendContextFromRpc: cualquier forma inesperada es null (un 500, nunca un mensaje con datos rotos)", () => {
  const base = contextRpc();
  const menu = base["menu"] as Record<string, unknown>;
  const dish = (menu["dishes"] as Array<Record<string, unknown>>)[0];
  const session = base["session"] as Record<string, unknown>;
  const broken: Array<[string, unknown]> = [
    ["no es un objeto", null],
    ["sin sesión", { ...base, session: undefined }],
    ["otro estado", { ...base, session: { ...session, status: "raro" } }],
    ["hora rota", { ...base, session: { ...session, start: "10" } }],
    ["semana mayor que el total", { ...base, session: { ...session, week: 3 } }],
    ["sin pedido en la sesión", { ...base, session: { ...session, requestId: null } }],
    ["otro idioma", { ...base, request: { locale: "fr" } }],
    ["contacto con otra forma", { ...base, contact: { name: 5, email: null, phone: null } }],
    ["versión 0", { ...base, menu: { ...menu, version: 0 } }],
    ["nota que no es texto", { ...base, menu: { ...menu, note: 5 } }],
    ["un plato sin nombre en italiano", { ...base, menu: { ...menu, dishes: [{ ...dish, nameIt: " " }] } }],
    ["un alérgeno desconocido", { ...base, menu: { ...menu, dishes: [{ ...dish, allergens: ["nichel"] }] } }],
    ["otra dieta", { ...base, menu: { ...menu, dishes: [{ ...dish, diet: "keto" }] } }],
    ["foto que no es un uuid", { ...base, menu: { ...menu, dishes: [{ ...dish, photoId: "../../x" }] } }],
    ["porciones 0", { ...base, menu: { ...menu, dishes: [{ ...dish, portions: 0 }] } }],
    ["otra sección", { ...base, menu: { ...menu, items: [{ name: "pan", section: "deli", quantity: 1, unit: "pcs" }] } }],
    ["semanas rotas", { ...base, weeks: [{ date: "30/11/2026", start: "10:00" }] }],
    // Una semana cancelada nunca llega acá (la base da session_not_editable): si llegara, sin número de semana, no se arma nada.
    ["semana sin número", { ...base, session: { ...session, status: "cancelled", week: null, weeks: 1 } }],
    ["sin huella", { ...base, fingerprint: undefined }],
    ["huella en mayúsculas", { ...base, fingerprint: FINGERPRINT.toUpperCase() }],
    ["huella corta", { ...base, fingerprint: FINGERPRINT.slice(1) }],
  ];
  for (const [name, value] of broken) {
    assert.equal(menuSendContextFromRpc(value), null, name);
  }
});

// ---------------------------------------------------------------------------
// La foto
// ---------------------------------------------------------------------------

test("dishName y dishDescription: el idioma de la clienta o el italiano", () => {
  const context = menuSendContextFromRpc(contextRpc());
  assert.ok(context);
  const [lasagne, minestrone] = context.menu.dishes as [ContextDish, ContextDish];
  assert.equal(dishName(lasagne, "it"), "Lasagne");
  assert.equal(dishName(lasagne, "es"), "Lasaña");
  assert.equal(dishName(lasagne, "en"), "Lasagne", "sin inglés, el italiano");
  assert.equal(dishName(minestrone, "es"), "Minestrone");
  assert.equal(dishName(minestrone, "en"), "Vegetable soup");
  assert.equal(dishDescription(lasagne, "es"), "Con ragú.");
  assert.equal(dishDescription(lasagne, "en"), "Al ragù.", "sin inglés, el italiano");
  assert.equal(dishDescription(minestrone, "it"), null);
  assert.equal(dishDescription(minestrone, "es"), null, "sin español ni italiano, ninguna");
  assert.equal(dishDescription(minestrone, "en"), "With beans.");
});

test("buildMenuSnapshot: en el idioma de la clienta, con las fotos de la web, la lista traducida, la nota como la escribió Evelyn y nada de la clienta", () => {
  const context = menuSendContextFromRpc(contextRpc());
  assert.ok(context);
  const snapshot = buildMenuSnapshot(context, {
    chefId: CHEF_ID,
    photoOrigin: ORIGIN,
    itemNames: new Map([
      ["zapallitos", "courgettes"],
      ["sal", "salt"],
    ]),
  });
  assert.deepEqual(snapshot, {
    v: 1,
    locale: "en",
    session: { date: "2026-11-30", start: "10:00", week: 1, weeks: 2 },
    weeks: [
      { date: "2026-11-30", start: "10:00" },
      { date: "2026-12-07", start: "10:00" },
    ],
    dishes: [
      {
        name: "Lasagne",
        description: "Al ragù.",
        allergens: ["gluten", "eggs", "milk"],
        diet: null,
        portions: 6,
        photo: {
          thumb: `${ORIGIN}/storage/v1/object/public/recipe-photos/${CHEF_ID}/${RECIPE_A}/${PHOTO_ID}-thumb.jpg`,
          full: `${ORIGIN}/storage/v1/object/public/recipe-photos/${CHEF_ID}/${RECIPE_A}/${PHOTO_ID}.jpg`,
        },
      },
      { name: "Vegetable soup", description: "With beans.", allergens: [], diet: "vegan", portions: 4, photo: null },
    ],
    items: [
      { name: "courgettes", section: "produce", quantity: 1250, unit: "g" },
      { name: "salt", section: "pantry", quantity: null, unit: null },
      { name: "courgettes", section: "produce", quantity: 300, unit: "g" },
    ],
    note: "Tené listos 4 táperes.",
  });
  assert.deepEqual(readMenuSnapshot(JSON.parse(JSON.stringify(snapshot))), snapshot, "la lee igual quien la guarda y la vuelve a leer");
  const text = JSON.stringify(snapshot);
  for (const marker of ["Maria", "maria@example.test", "3331234567", REQUEST_ID, SESSION_ID, "allergensConfirmed", FINGERPRINT]) {
    assert.ok(!text.includes(marker), `la foto lleva ${marker}`);
  }

  // Sin origen de las fotos (functions serve) ni traducción: sin fotos y la lista como la escribió Evelyn.
  const plain = buildMenuSnapshot(context, { chefId: CHEF_ID, photoOrigin: null, itemNames: null });
  assert.equal(plain.dishes[0]?.photo, null);
  assert.deepEqual(plain.items.map((item) => item.name), ["zapallitos", "sal", "zapallitos"]);
  assert.equal(plain.note, "Tené listos 4 táperes.");
});

// ---------------------------------------------------------------------------
// El presupuesto (la semana 1 de un presupuesto abierto, migración 20261121120000_quotes.sql)
// ---------------------------------------------------------------------------

const QUOTE_ID = "5e550000-0000-4000-8000-0000000000a1";
const OTHER_SESSION = "5e550000-0000-4000-8000-000000000004";

/** Lo que trae chef_menu_send_context en quote (private.session_quote) para la semana 1. */
function quoteRpc(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
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
        { sessionId: SESSION_ID, date: "2026-11-30", start: "10:00", cookMinutes: 180, serviceCents: 15000 },
        { sessionId: OTHER_SESSION, date: "2026-12-07", start: "11:30", cookMinutes: 180, serviceCents: 15000 },
      ],
    },
    ...overrides,
  };
}

/** El contexto de la semana 1 held de un presupuesto. */
function heldContextRpc(quote: unknown = quoteRpc()): Record<string, unknown> {
  const base = contextRpc();
  return { ...base, session: { ...(base["session"] as Record<string, unknown>), status: "held" }, quote };
}

test("menuSendContextFromRpc: el presupuesto de una semana held (sus términos de ahora); sin él, null", () => {
  const context = menuSendContextFromRpc(heldContextRpc());
  assert.ok(context);
  assert.deepEqual(context.quote, {
    id: QUOTE_ID,
    version: 1,
    sent: false,
    holdUntil: "2026-11-17T10:00:00.123456+00:00",
    holdHours: 48,
    firstWeek: true,
    terms: (quoteRpc()["terms"] as Record<string, unknown>),
  });
  assert.equal(menuSendContextFromRpc(contextRpc())?.quote, null, "una semana confirmada no lo trae");
  assert.equal(menuSendContextFromRpc(contextRpc({ quote: null }))?.quote, null);
});

test("menuSendContextFromRpc: un presupuesto con otra forma es null (un 500, nunca un precio roto en el mensaje)", () => {
  const terms = quoteRpc()["terms"] as Record<string, unknown>;
  const broken: Array<[string, unknown]> = [
    ["en una semana confirmada", { ...contextRpc(), quote: quoteRpc() }],
    ["sin términos", heldContextRpc(quoteRpc({ terms: null }))],
    ["términos de otro presupuesto", heldContextRpc(quoteRpc({ terms: { ...terms, quoteId: SEND_ID } }))],
    ["sin semanas vivas", heldContextRpc(quoteRpc({ terms: { ...terms, totalCents: 0, weeks: [] } }))],
    ["la primera semana no es esta", heldContextRpc(quoteRpc({ terms: { ...terms, weeks: [...(terms["weeks"] as unknown[])].reverse() } }))],
    ["versión 0", heldContextRpc(quoteRpc({ version: 0 }))],
    ["plazo de 0 horas", heldContextRpc(quoteRpc({ holdHours: 0 }))],
    ["sent que no es booleano", heldContextRpc(quoteRpc({ sent: "sí" }))],
    ["no es un objeto", heldContextRpc("presupuesto")],
  ];
  for (const [name, value] of broken) assert.equal(menuSendContextFromRpc(value), null, name);
});

test("buildMenuSnapshot: la semana 1 de un presupuesto lleva el presupuesto, con la versión que va a salir", () => {
  const first = menuSendContextFromRpc(heldContextRpc());
  assert.ok(first);
  const snapshot = buildMenuSnapshot(first, { chefId: CHEF_ID, photoOrigin: ORIGIN, itemNames: null });
  assert.deepEqual(snapshot.quote, {
    version: 1,
    totalCents: 30000,
    weeks: [
      { date: "2026-11-30", start: "10:00", serviceCents: 15000 },
      { date: "2026-12-07", start: "11:30", serviceCents: 15000 },
    ],
    holdHours: 48,
    firstStart: "2026-11-30T10:00",
  });
  assert.deepEqual(readMenuSnapshot(JSON.parse(JSON.stringify(snapshot))), snapshot, "la lee igual quien la guarda y la vuelve a leer");
  for (const marker of [QUOTE_ID, SESSION_ID, OTHER_SESSION, "cookMinutes", "holdUntil"]) {
    assert.ok(!JSON.stringify(snapshot.quote).includes(marker), `el presupuesto de la foto lleva ${marker}`);
  }

  // Un reenvío (ya salió): la versión siguiente, la que pone chef_complete_menu_send.
  const resent = menuSendContextFromRpc(heldContextRpc(quoteRpc({ version: 2, sent: true })));
  assert.ok(resent);
  assert.equal(snapshotQuoteOf(resent)?.version, 3);

  // Una semana que no es la primera (la base no la deja salir) o una confirmada: la foto de siempre.
  const second = menuSendContextFromRpc(heldContextRpc(quoteRpc({ firstWeek: false })));
  assert.ok(second);
  assert.equal(snapshotQuoteOf(second), null);
  assert.equal("quote" in buildMenuSnapshot(second, { chefId: CHEF_ID, photoOrigin: null, itemNames: null }), false);
  const confirmed = menuSendContextFromRpc(contextRpc());
  assert.ok(confirmed);
  assert.equal("quote" in buildMenuSnapshot(confirmed, { chefId: CHEF_ID, photoOrigin: null, itemNames: null }), false);
});

// ---------------------------------------------------------------------------
// El link
// ---------------------------------------------------------------------------

test("newClientToken: 32 bytes al azar en base64url (43 caracteres) y su sha-256 en hexadecimal", async () => {
  assert.equal(CLIENT_TOKEN_BYTES, 32);
  const seen = new Set<string>();
  for (let i = 0; i < 20; i++) {
    const { token, hash } = await newClientToken();
    assert.match(token, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(Buffer.from(token, "base64url").length, 32);
    assert.equal(hash, createHash("sha256").update(token, "utf8").digest("hex"));
    assert.match(hash, /^[0-9a-f]{64}$/, "lo que exige client_links.token_hash");
    seen.add(token);
  }
  assert.equal(seen.size, 20);
  assert.equal(await sha256Hex("ñ"), createHash("sha256").update("ñ", "utf8").digest("hex"), "UTF-8");
});

test("clientLinkUrl: la página de la reserva con el token en el fragmento, nunca en la query", () => {
  assert.equal(clientLinkUrl("https://radicicucina.app", "abc_-123"), "https://radicicucina.app/prenotazione/#t=abc_-123");
  assert.equal(clientLinkUrl("https://radicicucina.app//", "abc"), "https://radicicucina.app/prenotazione/#t=abc");
  assert.equal(new URL(clientLinkUrl("http://localhost:5173", "abc")).search, "");
});

test("sendableEmail y whatsappPhone: solo un email con forma de email y un teléfono que se puede normalizar", () => {
  assert.equal(sendableEmail("maria@example.test"), "maria@example.test");
  for (const email of [null, "maria", "maria@example", "a b@example.test"]) assert.equal(sendableEmail(email), null, String(email));
  assert.equal(whatsappPhone("+39 333 123 4567"), "+393331234567");
  assert.equal(whatsappPhone("3331234567"), "+393331234567", "un móvil italiano sin prefijo");
  for (const phone of [null, "123", "llamar a la tarde"]) assert.equal(whatsappPhone(phone), null, String(phone));
});

// ---------------------------------------------------------------------------
// prepare, link y complete
// ---------------------------------------------------------------------------

test("preparedSendIdFromRpc, linkedSendFromRpc y completedSendFromRpc: la forma de la base o null", () => {
  assert.equal(preparedSendIdFromRpc({ sendId: SEND_ID }), SEND_ID);
  for (const raw of [null, {}, { sendId: "x" }, { sendId: SEND_ID.toUpperCase() }]) assert.equal(preparedSendIdFromRpc(raw), null, JSON.stringify(raw));

  const linked = {
    sendId: SEND_ID,
    sessionId: SESSION_ID,
    requestId: REQUEST_ID,
    locale: "it",
    snapshot: { v: 1 },
    contact: { name: " Maria ", email: "maria@example.test", phone: null },
    chefName: "Evelyn",
  };
  assert.deepEqual(linkedSendFromRpc(linked), {
    sendId: SEND_ID,
    locale: "it",
    snapshot: { v: 1 },
    contact: { name: "Maria", email: "maria@example.test", phone: null },
    chefName: "Evelyn",
  });
  for (const raw of [{ ...linked, locale: "de" }, { ...linked, snapshot: null }, { ...linked, contact: null }, { ...linked, sendId: 1 }]) {
    assert.equal(linkedSendFromRpc(raw), null, JSON.stringify(raw));
  }

  assert.deepEqual(completedSendFromRpc({ sendId: SEND_ID, sentAt: "2026-11-21T21:42:26.123456+00:00", sentVia: ["whatsapp", "email"] }), {
    sentAt: "2026-11-21T21:42:26.123456+00:00",
    sentVia: ["email", "whatsapp"],
  });
  for (const raw of [
    { sentAt: null, sentVia: ["email"] },
    { sentAt: "ayer", sentVia: ["email"] },
    { sentAt: "2026-11-21T21:42:26Z", sentVia: [] },
    { sentAt: "2026-11-21T21:42:26Z", sentVia: ["sms"] },
    { sentAt: "2026-11-21T21:42:26Z", sentVia: ["email", "email"] },
  ]) {
    assert.equal(completedSendFromRpc(raw), null, JSON.stringify(raw));
  }
});
