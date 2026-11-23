// Tests del presupuesto en la foto del envío del menú (quote_snapshot.ts, SPEC 5.8): la lectura defensiva, el plazo
// para aceptarlo (horas o la llegada de la primera semana) y el instante de una hora de Roma. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_CENTS, MAX_WEEKS } from "./chef_api.ts";
import {
  QUOTE_MAX_CENTS,
  QUOTE_MAX_WEEKS,
  quoteDeadline,
  quoteFirstStart,
  readSnapshotQuote,
  romeInstant,
  sameWeeklyPrice,
  type SnapshotQuote,
} from "./quote_snapshot.ts";

function quote(overrides: Partial<SnapshotQuote> = {}): SnapshotQuote {
  return {
    version: 1,
    totalCents: 56000,
    weeks: [
      { date: "2026-11-30", start: "10:00", serviceCents: 14000 },
      { date: "2026-12-07", start: "10:00", serviceCents: 14000 },
      { date: "2026-12-14", start: "10:00", serviceCents: 14000 },
      { date: "2026-12-21", start: "10:00", serviceCents: 14000 },
    ],
    holdHours: 48,
    firstStart: "2026-11-30T10:00",
    ...overrides,
  };
}

test("los topes son los de la función chef (semanas y centavos)", () => {
  assert.equal(QUOTE_MAX_WEEKS, MAX_WEEKS);
  assert.equal(QUOTE_MAX_CENTS, MAX_CENTS);
  assert.equal(quoteFirstStart("2026-11-30", "10:00"), "2026-11-30T10:00");
});

test("readSnapshotQuote: un bloque válido vuelve igual, armado de nuevo y sin lo que no es del contrato", () => {
  const value = quote();
  const read = readSnapshotQuote(JSON.parse(JSON.stringify({ ...value, quoteId: "x", pago: "bonifico", weeks: value.weeks.map((week) => ({ ...week, sessionId: "s" })) })));
  assert.deepEqual(read, value);
  assert.equal(readSnapshotQuote(undefined), null, "sin presupuesto");
  assert.equal(readSnapshotQuote(null), null);
});

test("readSnapshotQuote: con otra forma, undefined (nunca un precio o un plazo que no cierran)", () => {
  const week = { date: "2026-11-30", start: "10:00", serviceCents: 14000 };
  const cases: Array<[string, unknown]> = [
    ["no es un objeto", [quote()]],
    ["versión 0", quote({ version: 0 })],
    ["el total no es la suma", quote({ totalCents: 55000 })],
    ["centavos con decimales", quote({ totalCents: 140.5, weeks: [{ ...week, serviceCents: 140.5 }] })],
    ["un precio negativo", quote({ totalCents: -1, weeks: [{ ...week, serviceCents: -1 }] })],
    ["sin semanas", quote({ weeks: [], totalCents: 0 })],
    ["nueve semanas", quote({ weeks: Array.from({ length: 9 }, () => week), totalCents: 9 * 14000 })],
    ["fecha rota", quote({ weeks: [{ ...week, date: "2026-02-30" }], totalCents: 14000, firstStart: "2026-02-30T10:00" })],
    ["hora rota", quote({ weeks: [{ ...week, start: "25:00" }], totalCents: 14000, firstStart: "2026-11-30T25:00" })],
    ["desordenadas", quote({ weeks: [{ ...week, date: "2026-12-07" }, week], totalCents: 28000, firstStart: "2026-12-07T10:00" })],
    ["firstStart que no es la primera llegada", quote({ firstStart: "2026-12-07T10:00" })],
    ["plazo de 0 horas", quote({ holdHours: 0 })],
    ["sin firstStart", { ...quote(), firstStart: undefined }],
  ];
  for (const [name, value] of cases) assert.equal(readSnapshotQuote(value), undefined, name);
});

test("sameWeeklyPrice: todas las semanas al mismo precio o no", () => {
  assert.equal(sameWeeklyPrice(quote()), true);
  assert.equal(
    sameWeeklyPrice(quote({ weeks: [{ date: "2026-11-30", start: "10:00", serviceCents: 15001 }, { date: "2026-12-07", start: "10:00", serviceCents: 15000 }] })),
    false,
  );
  assert.equal(sameWeeklyPrice({ weeks: [] }), false);
});

test("romeInstant: la hora de Roma como instante, en invierno (UTC+1) y en verano (UTC+2), como Postgres", () => {
  assert.equal(new Date(romeInstant("2026-11-30", "10:00")).toISOString(), "2026-11-30T09:00:00.000Z");
  assert.equal(new Date(romeInstant("2027-07-05", "10:00")).toISOString(), "2027-07-05T08:00:00.000Z");
  // El día del cambio de hora (29/3/2026 a las 2:00 pasa a las 3:00; 25/10/2026 a las 3:00 vuelve a las 2:00).
  assert.equal(new Date(romeInstant("2026-03-29", "10:00")).toISOString(), "2026-03-29T08:00:00.000Z");
  assert.equal(new Date(romeInstant("2026-10-25", "10:00")).toISOString(), "2026-10-25T09:00:00.000Z");
  assert.equal(new Date(romeInstant("2026-12-31", "23:30")).toISOString(), "2026-12-31T22:30:00.000Z");
});

test("quoteDeadline: 48 horas si caben antes de la primera llegada; si no, la llegada (como chef_complete_menu_send)", () => {
  // Lunes 30/11 a las 10:00 en Roma = 09:00 UTC.
  const value = quote();
  assert.deepEqual(quoteDeadline(value, new Date("2026-11-27T09:00:00Z")), { kind: "hours", hours: 48 }, "tres días antes");
  assert.deepEqual(quoteDeadline(value, new Date("2026-11-28T09:00:00Z")), { kind: "hours", hours: 48 }, "justo 48 horas antes");
  assert.deepEqual(quoteDeadline(value, new Date("2026-11-28T09:00:01Z")), { kind: "firstArrival", date: "2026-11-30", start: "10:00" });
  assert.deepEqual(quoteDeadline(value, new Date("2026-11-29T20:00:00Z")), { kind: "firstArrival", date: "2026-11-30", start: "10:00" });
  assert.deepEqual(quoteDeadline(quote({ holdHours: 24 }), new Date("2026-11-28T09:00:01Z")), { kind: "hours", hours: 24 }, "con otro plazo");
});
