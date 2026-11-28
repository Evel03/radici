// Tests del contrato del pedido público. Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CONSENT_VERSION,
  CONSENT_VERSIONS,
  HEALTH_CONSENT_VERSION,
  HEALTH_CONSENT_VERSIONS,
  LEGACY_PAGE_CONSENT_VERSIONS,
  PUBLIC_REQUEST_VERSION,
  PUBLIC_REQUEST_VERSIONS,
  addDays,
  cleanMultiLine,
  cleanOneLine,
  isIsoDate,
  normalizePhone,
  parsePublicRequest,
  romeToday,
  weeklyDates,
  type PublicRequestPayload,
} from "./public_request.ts";

const TODAY = "2026-10-19";

/** Pedido válido: vector 1 (una semana), y nadie de quienes van a comer tiene alergias. */
function payload(overrides: Partial<PublicRequestPayload> = {}): PublicRequestPayload {
  return {
    version: PUBLIC_REQUEST_VERSION,
    type: "week",
    adults: 2,
    kids: 2,
    days: 5,
    meals: ["dinner"],
    weeks: 1,
    noAllergies: true,
    allergens: [],
    diets: [],
    restrictionsNote: "",
    preferredDate: null,
    slot: "any",
    name: "Giulia Rossi",
    zone: "Città Alta",
    phone: "+39 333 123 4567",
    email: "giulia@example.test",
    whatsappOptIn: true,
    notes: "",
    locale: "it",
    consents: { privacy: CONSENT_VERSION, health: null },
    turnstileToken: "token-de-prueba",
    ...overrides,
  };
}

/** Lo que manda el formulario si no marca "ninguna": las alergias escritas y el consentimiento de salud. */
function withAllergies(overrides: Partial<PublicRequestPayload> = {}): PublicRequestPayload {
  return payload({
    noAllergies: false,
    restrictionsNote: "Celiachia",
    consents: { privacy: CONSENT_VERSION, health: HEALTH_CONSENT_VERSION },
    ...overrides,
  });
}

function errorsOf(input: unknown): Record<string, string> {
  const result = parsePublicRequest(input, { today: TODAY });
  assert.equal(result.ok, false, "se esperaba un error");
  return result.ok ? {} : result.errors;
}

test("un pedido válido se normaliza y trae la estimación del vector 1", () => {
  const result = parsePublicRequest(payload(), { today: TODAY });
  assert.ok(result.ok);
  if (!result.ok) return;
  assert.equal(result.value.phoneE164, "+393331234567");
  assert.deepEqual(result.value.meals, ["dinner"]);
  assert.equal(result.value.weeks, 1);
  assert.equal(result.value.noAllergies, true);
  assert.equal(result.value.hasRestrictions, false);
  assert.equal(result.value.consents.health, null);
  assert.deepEqual(result.value.quoteInput, { type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 1 });
  // La validación no calcula precios: el servidor los calcula con las tarifas de la cocinera (handler.ts).
  assert.ok(!("estimate" in result));
});

test("limpia espacios y caracteres de control, y pasa el email a minúsculas", () => {
  const result = parsePublicRequest(
    payload({ name: "  Giulia\u0000   Rossi ‮ ", email: " Giulia@Example.TEST ", notes: "a\r\n\r\n\r\n\r\nb  c" }),
    { today: TODAY },
  );
  assert.ok(result.ok);
  if (!result.ok) return;
  assert.equal(result.value.name, "Giulia Rossi");
  assert.equal(result.value.email, "giulia@example.test");
  assert.equal(result.value.notes, "a\n\nb c");
});

test("las comidas se devuelven en orden canónico y sin repetir", () => {
  const ok = parsePublicRequest(payload({ meals: ["dinner", "lunch"] }), { today: TODAY });
  assert.ok(ok.ok);
  if (ok.ok) {
    assert.deepEqual(ok.value.meals, ["lunch", "dinner"]);
    assert.equal(ok.value.quoteInput.meals, 2);
  }
  assert.equal(errorsOf(payload({ meals: ["lunch", "lunch"] })).meals, "invalid");
  assert.equal(errorsOf(payload({ meals: [] })).meals, "invalid");
  assert.equal(errorsOf(payload({ meals: ["brunch" as "lunch"] })).meals, "invalid");
});

test("rangos de personas y días", () => {
  assert.equal(errorsOf(payload({ adults: 0, kids: 0 })).people, "range");
  assert.equal(errorsOf(payload({ adults: 31 })).adults, "range");
  assert.equal(errorsOf(payload({ adults: 1.5 })).adults, "range");
  assert.equal(errorsOf(payload({ days: 0 })).days, "range");
  assert.equal(errorsOf(payload({ days: 8 })).days, "range");
});

test("pregunta de alergias: solo true o false (ausente o de otro tipo, invalid)", () => {
  for (const value of [undefined, null, "true", "sí", 1, 0]) {
    assert.deepEqual(errorsOf({ ...payload(), noAllergies: value }), { noAllergies: "invalid" }, String(value));
  }
});

test("nadie tiene alergias (true) junto con restricciones: invalid, sin pedir consentimiento de salud", () => {
  const health = { privacy: CONSENT_VERSION, health: HEALTH_CONSENT_VERSION };
  for (const restriction of [
    { restrictionsNote: "noci" },
    { allergens: ["milk" as const] },
    { diets: ["vegan" as const] },
  ]) {
    assert.deepEqual(errorsOf(payload({ ...restriction, consents: health })), { noAllergies: "invalid" }, JSON.stringify(restriction));
    assert.deepEqual(errorsOf(payload(restriction)), { noAllergies: "invalid" }, "ni con el consentimiento ni sin él");
  }
});

test("hay alergias (false) sin escribirlas: restrictionsNote required (también con solo espacios)", () => {
  assert.deepEqual(errorsOf(withAllergies({ restrictionsNote: "" })), { restrictionsNote: "required" });
  assert.deepEqual(errorsOf(withAllergies({ restrictionsNote: " \n\t " })), { restrictionsNote: "required" });
  // Si la nota ya tiene otro error, ese es el que vale.
  assert.deepEqual(errorsOf(withAllergies({ restrictionsNote: 5 as unknown as string })), { restrictionsNote: "invalid" });
  assert.deepEqual(errorsOf(withAllergies({ restrictionsNote: "x".repeat(201) })), { restrictionsNote: "tooLong" });
});

test("alergias escritas sin consentimiento de salud (o con una versión que no es la vigente): no se aceptan", () => {
  for (const health of [null, "", "1999-01-01"]) {
    assert.deepEqual(
      errorsOf(withAllergies({ consents: { privacy: CONSENT_VERSION, health } })),
      { consentHealth: "healthConsentRequired" },
      String(health),
    );
  }
  // Las restricciones del contrato (alérgenos y dietas, que la web manda vacíos) siguen la misma regla.
  assert.equal(errorsOf(withAllergies({ restrictionsNote: "", allergens: ["milk"], consents: { privacy: CONSENT_VERSION, health: null } })).consentHealth, "healthConsentRequired");
});

test("alergias escritas con consentimiento: se aceptan, con la nota en varias líneas", () => {
  const result = parsePublicRequest(withAllergies({ restrictionsNote: "  Marco: celiachia \r\n\r\n\r\n Anna:  noci  " }), { today: TODAY });
  assert.ok(result.ok);
  if (!result.ok) return;
  assert.equal(result.value.noAllergies, false);
  assert.equal(result.value.hasRestrictions, true);
  assert.equal(result.value.restrictionsNote, "Marco: celiachia\n\nAnna: noci");
  assert.equal(result.value.consents.health, HEALTH_CONSENT_VERSION);
});

test("sin alergias, un consentimiento de salud marcado se descarta: no hay datos de salud que cubra", () => {
  const result = parsePublicRequest(payload({ consents: { privacy: CONSENT_VERSION, health: HEALTH_CONSENT_VERSION } }), { today: TODAY });
  assert.ok(result.ok);
  if (result.ok) assert.equal(result.value.consents.health, null);
});

test("restricciones del contrato con consentimiento: alérgenos en orden canónico", () => {
  const result = parsePublicRequest(withAllergies({ allergens: ["milk", "gluten"], restrictionsNote: "" }), { today: TODAY });
  assert.ok(result.ok);
  if (!result.ok) return;
  assert.deepEqual(result.value.allergens, ["gluten", "milk"]);
  assert.equal(result.value.hasRestrictions, true);
});

test("privacy obligatoria y con una versión conocida", () => {
  assert.equal(errorsOf(payload({ consents: { privacy: "", health: null } })).consentPrivacy, "consentRequired");
  assert.equal(errorsOf(payload({ consents: { privacy: "2020-01-01", health: null } })).consentPrivacy, "consentRequired");
  assert.equal(errorsOf({ ...payload(), consents: undefined }).consentPrivacy, "consentRequired");
});

test("privacy: un pedido de la versión vigente solo se guarda con el texto vigente; las viejas, nunca", () => {
  // 2026-11-15 no hablaba de la pregunta de alergias ni de las consultas del calendario (contrato §11):
  // un pedido v2 con esa versión (solo posible armado a mano) no se guarda.
  const ok = parsePublicRequest(payload({ consents: { privacy: CONSENT_VERSION, health: null } }), { today: TODAY });
  assert.ok(ok.ok);
  if (ok.ok) assert.equal(ok.value.consents.privacy, CONSENT_VERSION);
  assert.deepEqual([...LEGACY_PAGE_CONSENT_VERSIONS], ["2026-11-15", "2026-10-19"]);
  for (const version of LEGACY_PAGE_CONSENT_VERSIONS) {
    assert.deepEqual(errorsOf(payload({ consents: { privacy: version, health: null } })), { consentPrivacy: "consentRequired" }, version);
  }
});

test("email obligatorio y válido; teléfono obligatorio y normalizable", () => {
  assert.equal(errorsOf(payload({ email: "" })).email, "required");
  assert.equal(errorsOf(payload({ email: "giulia@" })).email, "invalid");
  assert.equal(errorsOf(payload({ phone: "" })).phone, "required");
  assert.equal(errorsOf(payload({ phone: "612 345 678" })).phone, "invalid");
  assert.equal(errorsOf(payload({ name: "x".repeat(81) })).name, "tooLong");
});

test("normalizePhone: formatos italianos sin prefijo y números internacionales", () => {
  assert.equal(normalizePhone("+39 333 123 4567"), "+393331234567");
  assert.equal(normalizePhone("0039 333-123-4567"), "+393331234567");
  assert.equal(normalizePhone("333 1234567"), "+393331234567");
  assert.equal(normalizePhone("393447936567"), "+393447936567");
  assert.equal(normalizePhone("035 123456"), "+39035123456");
  assert.equal(normalizePhone("+34 612 345 678"), "+34612345678");
  assert.equal(normalizePhone("(+54) 9 11 2345-6789"), "+5491123456789", "los paréntesis alrededor del prefijo se ignoran");
  assert.equal(normalizePhone("+54 9 11 2345-6789"), "+5491123456789");
  assert.equal(normalizePhone("612345678"), null);
  assert.equal(normalizePhone("+0 123"), null);
  assert.equal(normalizePhone("hola"), null);
});

test("fecha preferida: de mañana a +56 días (8 semanas), fechas reales", () => {
  const ok = parsePublicRequest(payload({ preferredDate: "2026-10-20" }), { today: TODAY });
  assert.ok(ok.ok);
  assert.ok(parsePublicRequest(payload({ preferredDate: "2026-11-03" }), { today: TODAY }).ok, "lo que antes quedaba fuera (+15)");
  assert.ok(parsePublicRequest(payload({ preferredDate: "2026-12-14" }), { today: TODAY }).ok);
  assert.ok(parsePublicRequest(payload({ preferredDate: "" as unknown as null }), { today: TODAY }).ok);
  assert.equal(errorsOf(payload({ preferredDate: "2026-10-19" })).preferredDate, "dateOutOfRange");
  assert.equal(errorsOf(payload({ preferredDate: "2026-12-15" })).preferredDate, "dateOutOfRange");
  assert.equal(errorsOf(payload({ preferredDate: "2026-02-30" })).preferredDate, "invalid");
  assert.equal(errorsOf(payload({ preferredDate: "20/10/2026" })).preferredDate, "invalid");
});

test("textos de 2026-11-29 (y 2026-11-28, 2026-11-27, 2026-11-23, 2026-11-22, 2026-11-19 y 2026-11-16 para las páginas abiertas antes): privacy y salud; las privacy viejas solo para que una página v1 reciba errores de página", () => {
  assert.equal(CONSENT_VERSION, "2026-11-29");
  // 2026-11-29 cuenta que la cuenta se borra desde «Mi cuenta», sin cambiar el formulario: una página abierta antes
  // manda 2026-11-28.
  assert.ok(parsePublicRequest(payload({ consents: { privacy: "2026-11-28", health: null } }), { today: TODAY }).ok);
  // 2026-11-28 suma la cuenta de la clienta, sin cambiar el formulario: una página abierta antes manda 2026-11-27.
  assert.ok(parsePublicRequest(payload({ consents: { privacy: "2026-11-27", health: null } }), { today: TODAY }).ok);
  // Una página abierta antes de la casilla de ofertas (punto 6 de la privacy) manda la privacy de 2026-11-23: se
  // sigue guardando, sin ofertas.
  const before = parsePublicRequest(payload({ consents: { privacy: "2026-11-23", health: null } }), { today: TODAY });
  assert.ok(before.ok);
  assert.equal(before.ok && before.value.consents.marketing, null);
  assert.ok(parsePublicRequest(withAllergies({ consents: { privacy: "2026-11-23", health: HEALTH_CONSENT_VERSION } }), { today: TODAY }).ok);
  // Una página abierta antes del despliegue del presupuesto en la página de la reserva manda la privacy de
  // 2026-11-22: el formulario no cambió, así que se sigue guardando, con la salud vigente.
  assert.ok(parsePublicRequest(payload({ consents: { privacy: "2026-11-22", health: null } }), { today: TODAY }).ok);
  assert.ok(parsePublicRequest(withAllergies({ consents: { privacy: "2026-11-22", health: HEALTH_CONSENT_VERSION } }), { today: TODAY }).ok);
  // Una página abierta antes del despliegue de la página de la reserva manda la privacy de 2026-11-19: el
  // formulario no cambió, así que se sigue guardando, con la salud vigente.
  assert.ok(parsePublicRequest(payload({ consents: { privacy: "2026-11-19", health: null } }), { today: TODAY }).ok);
  assert.ok(parsePublicRequest(withAllergies({ consents: { privacy: "2026-11-19", health: HEALTH_CONSENT_VERSION } }), { today: TODAY }).ok);
  // Una página abierta antes del menú manda la privacy de 2026-11-16 (sin el menú, que esa página no
  // tiene): se sigue guardando, con su salud.
  assert.ok(parsePublicRequest(payload({ version: 3, consents: { privacy: "2026-11-16", health: null } }), { today: TODAY }).ok);
  assert.ok(parsePublicRequest(withAllergies({ version: 3, consents: { privacy: "2026-11-16", health: "2026-11-16" } }), { today: TODAY }).ok);
  // La página de la versión 1 en caché manda la privacy de 2026-11-15 y no manda noAllergies: solo errores
  // de página (la web vieja muestra "página desactualizada", sin marcar la casilla de privacy como faltante).
  const { noAllergies: _sinRespuesta, ...old } = payload({ version: 1, consents: { privacy: "2026-11-15", health: null } });
  assert.deepEqual(errorsOf(old), { version: "invalid", noAllergies: "invalid" });
  // El consentimiento de salud, solo con el texto vigente: ninguno anterior pedía las alergias escritas.
  for (const health of ["2026-11-15", "2026-10-19"]) {
    assert.deepEqual(errorsOf(withAllergies({ consents: { privacy: CONSENT_VERSION, health } })), { consentHealth: "healthConsentRequired" }, health);
  }
});

test("versiones aceptadas: la vigente vale para la privacy; la salud tiene su propia versión y su lista explícita", () => {
  // La web manda CONSENT_VERSION en consents.privacy y, con alergias escritas, HEALTH_CONSENT_VERSION en
  // consents.health.
  assert.ok(CONSENT_VERSIONS.includes(CONSENT_VERSION), "CONSENT_VERSIONS acepta la vigente");
  assert.ok(
    HEALTH_CONSENT_VERSIONS.includes(HEALTH_CONSENT_VERSION),
    "al cambiar el texto de salud, sumar la versión nueva a HEALTH_CONSENT_VERSIONS y dejar la anterior mientras haya páginas en caché",
  );
  // La salud no sigue a CONSENT_VERSION: las privacy 2026-11-19, 2026-11-22, 2026-11-23, 2026-11-27, 2026-11-28 y 2026-11-29 no la tocaron. Si la web
  // mandara la versión de la privacy, la base cerraría el consentimiento de salud de un prospecto que vuelve (y le
  // borraría las restricciones), y las páginas ya abiertas quedarían afuera.
  assert.equal(HEALTH_CONSENT_VERSION, "2026-11-16");
  assert.deepEqual([...HEALTH_CONSENT_VERSIONS], ["2026-11-16"]);
  assert.deepEqual([...CONSENT_VERSIONS], ["2026-11-29", "2026-11-28", "2026-11-27", "2026-11-23", "2026-11-22", "2026-11-19", "2026-11-16"]);
  for (const list of [CONSENT_VERSIONS, HEALTH_CONSENT_VERSIONS, LEGACY_PAGE_CONSENT_VERSIONS]) {
    assert.equal(new Set(list).size, list.length, `sin repetidas: ${list.join(", ")}`);
  }
  // Una versión vieja nunca vale para guardar un pedido de la versión vigente.
  assert.deepEqual(CONSENT_VERSIONS.filter((v) => LEGACY_PAGE_CONSENT_VERSIONS.includes(v)), []);
});

test("versiones 4, 3 y 2: una página de la versión 1 (en caché) recibe version invalid y la web pide recargar", () => {
  assert.equal(PUBLIC_REQUEST_VERSION, 4);
  assert.deepEqual([...PUBLIC_REQUEST_VERSIONS], [4, 3, 2]);
  // Lo que mandaba la página de la versión 1: sin noAllergies ni semanas.
  const { noAllergies: _sinRespuesta, weeks: _sinSemanas, ...v1 } = payload({ version: 1 });
  assert.deepEqual(errorsOf(v1), { version: "invalid", noAllergies: "invalid" });
});

/** Lo que manda una página de la versión 2 (la de antes del precio por semana): sin weeks. */
function v2(overrides: Partial<PublicRequestPayload> = {}): Omit<PublicRequestPayload, "weeks"> {
  const { weeks: _sinSemanas, ...rest } = payload({ version: 2, ...overrides });
  return rest;
}

test("versión 2 (páginas en caché y la web de antes durante el despliegue): se acepta y el pedido es de una semana", () => {
  const result = parsePublicRequest(v2(), { today: TODAY });
  assert.ok(result.ok);
  if (!result.ok) return;
  assert.equal(result.value.weeks, 1, "la versión 2 no podía pedir más de una semana: no se pierde nada");
  assert.equal(result.value.quoteInput.weeks, 1);
  // La privacy y el consentimiento de salud son los mismos de la versión 3.
  const health = parsePublicRequest(v2({ noAllergies: false, restrictionsNote: "noci", consents: { privacy: CONSENT_VERSION, health: HEALTH_CONSENT_VERSION } }), {
    today: TODAY,
  });
  assert.ok(health.ok);
  // Una privacy vieja sigue sin valer para guardar (como en la 3).
  assert.deepEqual(errorsOf(v2({ consents: { privacy: "2026-11-15", health: null } })), { consentPrivacy: "consentRequired" });
});

const DISH_A = "0a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";
const DISH_B = "1a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";
const DISH_C = "2a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";

test("menù (versión 4): opcional; los platos en el orden en que los tildó, en minúsculas", () => {
  const chosen = parsePublicRequest(payload({ days: 3, menu: [DISH_B, DISH_A.toUpperCase()] }), { today: TODAY });
  assert.ok(chosen.ok);
  if (chosen.ok) assert.deepEqual(chosen.value.menu, [DISH_B, DISH_A]);
  // Sin el campo, en null o vacío: ninguno (el menù lo propone Evelyn).
  const { menu: _sinMenu, ...without } = payload();
  for (const input of [without, { ...payload(), menu: null }, payload({ menu: [] })]) {
    const result = parsePublicRequest(input, { today: TODAY });
    assert.ok(result.ok, JSON.stringify(input));
    if (result.ok) assert.deepEqual(result.value.menu, []);
  }
  // Hasta uno por día: tantos platos como días, justo.
  const full = parsePublicRequest(payload({ days: 3, menu: [DISH_A, DISH_B, DISH_C] }), { today: TODAY });
  assert.ok(full.ok && full.value.menu.length === 3);
});

test("menù: invalid si no es un array de uuids sin repetir; tooMany si son más que los días", () => {
  for (const menu of ["x", {}, 5, true, [DISH_A, "no-es-uuid"], [DISH_A, 5], [DISH_A, null], [DISH_A, DISH_A], [DISH_A, DISH_A.toUpperCase()]]) {
    assert.deepEqual(errorsOf({ ...payload({ days: 5 }), menu }), { menu: "invalid" }, JSON.stringify(menu));
  }
  assert.deepEqual(errorsOf(payload({ days: 2, menu: [DISH_A, DISH_B, DISH_C] })), { menu: "tooMany" });
  assert.deepEqual(errorsOf(payload({ days: 1, menu: [DISH_A, DISH_B] })), { menu: "tooMany" });
  // Repetidos y de más: el formato primero.
  assert.deepEqual(errorsOf(payload({ days: 1, menu: [DISH_A, DISH_A, DISH_B] })), { menu: "invalid" });
  // Con los días inválidos no se sabe el tope: solo el error de los días.
  assert.deepEqual(errorsOf(payload({ days: 0, menu: [DISH_A, DISH_B] })), { days: "range" });
});

test("menù: en las versiones 3 y 2 no existe; si llega, se ignora como antes", () => {
  for (const input of [payload({ version: 3, days: 1, menu: [DISH_A, DISH_B] }), { ...v2({ days: 1 }), menu: "x" }]) {
    const result = parsePublicRequest(input, { today: TODAY });
    assert.ok(result.ok, JSON.stringify(input));
    if (result.ok) assert.deepEqual(result.value.menu, []);
  }
});

test("semanas (versión 3): obligatorias, enteras de 1 a 8; más de una solo en el pedido semanal", () => {
  for (const weeks of [1, 3, 4, 5, 8]) {
    const result = parsePublicRequest(payload({ weeks }), { today: TODAY });
    assert.ok(result.ok, String(weeks));
    if (result.ok) {
      assert.equal(result.value.weeks, weeks);
      assert.equal(result.value.quoteInput.weeks, weeks);
    }
  }
  // Sin el campo, desde la versión 3 no se da por 1: nunca se pierden semanas en silencio.
  const { weeks: _sinSemanas, ...missing } = payload();
  assert.deepEqual(errorsOf(missing), { weeks: "required" });
  assert.deepEqual(errorsOf({ ...payload(), weeks: null }), { weeks: "required" });
  // Con el 3 escrito, no la constante: ahora que la vigente es la 4 y se sigue aceptando la 3, un pedido
  // de la 3 sin semanas tampoco se guarda de una.
  assert.deepEqual(errorsOf({ ...missing, version: 3 }), { weeks: "required" });
  assert.deepEqual(errorsOf({ ...missing, version: 4 }), { weeks: "required" });
  assert.deepEqual(errorsOf({ ...missing, version: 5 }), { version: "invalid", weeks: "required" });
  for (const weeks of [0, 9, 1.5, -1, "3", true]) {
    assert.deepEqual(errorsOf({ ...payload(), weeks }), { weeks: "range" }, String(weeks));
  }
  // Una sesión extra es de una semana.
  assert.ok(parsePublicRequest(payload({ type: "extra", weeks: 1 }), { today: TODAY }).ok);
  assert.deepEqual(errorsOf(payload({ type: "extra", weeks: 2 })), { weeks: "invalid" });
  // Con el tipo inválido, solo el error del tipo.
  assert.deepEqual(errorsOf({ ...payload(), type: "change", weeks: 2 }), { type: "invalid" });
});

test("4 semanas, extra y más de 5 personas: la entrada del motor lleva las semanas y el tipo", () => {
  const result = parsePublicRequest(payload({ weeks: 4 }), { today: TODAY });
  assert.ok(result.ok);
  if (result.ok) assert.deepEqual(result.value.quoteInput, { type: "week", adults: 2, kids: 2, days: 5, meals: 1, weeks: 4 });
  const extra = parsePublicRequest(payload({ type: "extra" }), { today: TODAY });
  assert.ok(extra.ok && extra.value.quoteInput.type === "extra" && extra.value.quoteInput.weeks === 1);
  const six = parsePublicRequest(payload({ adults: 3, kids: 3 }), { today: TODAY });
  assert.ok(six.ok && six.value.quoteInput.adults + six.value.quoteInput.kids === 6);
});

test("weeklyDates: el primer día y el mismo día de cada semana siguiente", () => {
  assert.deepEqual(weeklyDates("2026-11-23", 1), ["2026-11-23"]);
  assert.deepEqual(weeklyDates("2026-11-23", 4), ["2026-11-23", "2026-11-30", "2026-12-07", "2026-12-14"]);
  assert.deepEqual(weeklyDates("2026-12-28", 2), ["2026-12-28", "2027-01-04"]);
  assert.equal(weeklyDates("2026-11-23", 8).at(-1), "2027-01-11");
});

test("payload que no es un objeto, versión distinta, campos faltantes y token", () => {
  assert.deepEqual(errorsOf(null), { payload: "invalid" });
  assert.deepEqual(errorsOf([]), { payload: "invalid" });
  assert.equal(errorsOf(payload({ version: 99 })).version, "invalid");
  const missing = errorsOf({ version: PUBLIC_REQUEST_VERSION });
  for (const field of ["type", "adults", "kids", "days", "meals", "noAllergies", "slot", "name", "zone", "phone", "email", "consentPrivacy", "turnstileToken"]) {
    assert.ok(field in missing, `falta el error de ${field}`);
  }
  assert.equal(errorsOf(payload({ turnstileToken: "" })).turnstileToken, "required");
  assert.equal(errorsOf(payload({ whatsappOptIn: "sí" as unknown as boolean })).whatsappOptIn, "invalid");
});

test("clave de idempotencia: opcional, UUID, normalizada a minúsculas", () => {
  const sin = parsePublicRequest(payload(), { today: TODAY });
  assert.ok(sin.ok);
  if (sin.ok) assert.equal(sin.value.requestKey, null);

  const key = "3F2B8C1E-9A4D-4C7B-8E2F-0123456789AB";
  const con = parsePublicRequest(payload({ requestKey: key }), { today: TODAY });
  assert.ok(con.ok);
  if (con.ok) assert.equal(con.value.requestKey, key.toLowerCase());

  assert.equal(errorsOf(payload({ requestKey: "no-es-un-uuid" })).requestKey, "invalid");
  assert.equal(errorsOf(payload({ requestKey: 123 as unknown as string })).requestKey, "invalid");
  assert.ok(parsePublicRequest({ ...payload(), requestKey: null }, { today: TODAY }).ok);
});

test("idioma desconocido: italiano por defecto", () => {
  const result = parsePublicRequest(payload({ locale: "fr" as "it" }), { today: TODAY });
  assert.ok(result.ok);
  if (result.ok) assert.equal(result.value.locale, "it");
});

test("helpers de fechas y texto", () => {
  assert.equal(addDays("2026-10-31", 1), "2026-11-01");
  assert.equal(addDays("2026-12-31", 14), "2027-01-14");
  assert.ok(isIsoDate("2028-02-29"));
  assert.ok(!isIsoDate("2026-02-29"));
  // Cambio de hora: 2026-03-28 23:30 UTC ya es 29 de marzo en Roma (UTC+1).
  assert.equal(romeToday(new Date("2026-03-28T23:30:00Z")), "2026-03-29");
  // Verano (UTC+2): 2026-07-14 22:30 UTC ya es 15 de julio en Roma.
  assert.equal(romeToday(new Date("2026-07-14T22:30:00Z")), "2026-07-15");
  assert.equal(romeToday(new Date("2026-07-14T21:30:00Z")), "2026-07-14");
  // Fin de año: 31/12 23:30 UTC ya es 1 de enero en Roma.
  assert.equal(romeToday(new Date("2026-12-31T23:30:00Z")), "2027-01-01");
  assert.throws(() => addDays("19/10/2026", 1), RangeError);
  assert.equal(cleanOneLine(" a \n b\t c "), "a b c");
  assert.equal(cleanMultiLine("x\n\n\n\ny"), "x\n\ny");
});

test("consents.marketing: opcional; marcada, con una versión aceptada; otra versión o tipo, error", async () => {
  const { MARKETING_CONSENT_VERSION, parsePublicRequest } = await import("./public_request.ts");
  const base = payload();
  const parse = (marketing: unknown) =>
    parsePublicRequest({ ...base, consents: { ...base.consents, ...(marketing === undefined ? {} : { marketing }) } }, { today: TODAY });
  const absent = parse(undefined);
  assert.ok(absent.ok);
  assert.equal(absent.ok && absent.value.consents.marketing, null);
  const unticked = parse(null);
  assert.ok(unticked.ok);
  assert.equal(unticked.ok && unticked.value.consents.marketing, null);
  const ticked = parse(MARKETING_CONSENT_VERSION);
  assert.ok(ticked.ok);
  assert.equal(ticked.ok && ticked.value.consents.marketing, MARKETING_CONSENT_VERSION);
  for (const bad of ["1999-01-01", true, 1]) {
    const result = parse(bad);
    assert.ok(!result.ok);
    assert.equal(!result.ok && result.errors.consentMarketing, "invalid", String(bad));
  }
});
