// Tests del contrato del pedido público. Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CONSENT_VERSION,
  PUBLIC_REQUEST_VERSION,
  addDays,
  cleanMultiLine,
  cleanOneLine,
  isIsoDate,
  normalizePhone,
  parsePublicRequest,
  romeToday,
  type PublicRequestPayload,
} from "./public_request.ts";

const TODAY = "2026-10-19";

function payload(overrides: Partial<PublicRequestPayload> = {}): PublicRequestPayload {
  return {
    version: PUBLIC_REQUEST_VERSION,
    type: "week",
    adults: 2,
    kids: 2,
    days: 5,
    meals: ["dinner"],
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
  assert.equal(result.value.hasRestrictions, false);
  assert.equal(result.value.consents.health, null);
  assert.deepEqual(result.value.quoteInput, { adults: 2, kids: 2, days: 5, meals: 1 });
  assert.equal(result.estimate.totalCents, 14100);
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
    assert.equal(ok.estimate.totalCents, 23700);
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

test("restricciones sin consentimiento de salud: no se aceptan", () => {
  assert.equal(errorsOf(payload({ allergens: ["milk"] })).consentHealth, "healthConsentRequired");
  assert.equal(errorsOf(payload({ diets: ["vegan"] })).consentHealth, "healthConsentRequired");
  assert.equal(errorsOf(payload({ restrictionsNote: "niente maiale" })).consentHealth, "healthConsentRequired");
  assert.equal(
    errorsOf(payload({ allergens: ["milk"], consents: { privacy: CONSENT_VERSION, health: "1999-01-01" } })).consentHealth,
    "healthConsentRequired",
  );
});

test("con consentimiento de salud las restricciones se guardan; sin restricciones el consentimiento se descarta", () => {
  const withHealth = parsePublicRequest(
    payload({ allergens: ["milk", "gluten"], consents: { privacy: CONSENT_VERSION, health: CONSENT_VERSION } }),
    { today: TODAY },
  );
  assert.ok(withHealth.ok);
  if (withHealth.ok) {
    assert.deepEqual(withHealth.value.allergens, ["gluten", "milk"]);
    assert.equal(withHealth.value.consents.health, CONSENT_VERSION);
    assert.equal(withHealth.value.hasRestrictions, true);
  }
  const noRestrictions = parsePublicRequest(
    payload({ consents: { privacy: CONSENT_VERSION, health: CONSENT_VERSION } }),
    { today: TODAY },
  );
  assert.ok(noRestrictions.ok);
  if (noRestrictions.ok) assert.equal(noRestrictions.value.consents.health, null);
});

test("privacy obligatoria y con una versión conocida", () => {
  assert.equal(errorsOf(payload({ consents: { privacy: "", health: null } })).consentPrivacy, "consentRequired");
  assert.equal(errorsOf(payload({ consents: { privacy: "2020-01-01", health: null } })).consentPrivacy, "consentRequired");
  assert.equal(errorsOf({ ...payload(), consents: undefined }).consentPrivacy, "consentRequired");
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

test("fecha preferida: de mañana a +14 días, fechas reales", () => {
  const ok = parsePublicRequest(payload({ preferredDate: "2026-10-20" }), { today: TODAY });
  assert.ok(ok.ok);
  assert.ok(parsePublicRequest(payload({ preferredDate: "2026-11-02" }), { today: TODAY }).ok);
  assert.ok(parsePublicRequest(payload({ preferredDate: "" as unknown as null }), { today: TODAY }).ok);
  assert.equal(errorsOf(payload({ preferredDate: "2026-10-19" })).preferredDate, "dateOutOfRange");
  assert.equal(errorsOf(payload({ preferredDate: "2026-11-03" })).preferredDate, "dateOutOfRange");
  assert.equal(errorsOf(payload({ preferredDate: "2026-02-30" })).preferredDate, "invalid");
  assert.equal(errorsOf(payload({ preferredDate: "20/10/2026" })).preferredDate, "invalid");
});

test("payload que no es un objeto, versión distinta, campos faltantes y token", () => {
  assert.deepEqual(errorsOf(null), { payload: "invalid" });
  assert.deepEqual(errorsOf([]), { payload: "invalid" });
  assert.equal(errorsOf(payload({ version: 99 })).version, "invalid");
  const missing = errorsOf({ version: PUBLIC_REQUEST_VERSION });
  for (const field of ["type", "adults", "kids", "days", "meals", "slot", "name", "zone", "phone", "email", "consentPrivacy", "turnstileToken"]) {
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
