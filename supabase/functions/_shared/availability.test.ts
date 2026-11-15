// Tests del contrato de disponibilidad por día. Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  AVAILABILITY_DAYS,
  AVAILABILITY_VERSION,
  availabilityDates,
  buildAvailabilityResponse,
  parseAvailabilityMinutes,
  parseAvailabilityResponse,
} from "./availability.ts";
import { DATE_WINDOW } from "./public_request.ts";

test("la ventana es la del formulario: de mañana a +14 días", () => {
  assert.equal(AVAILABILITY_DAYS, 14);
  assert.equal(DATE_WINDOW.minDaysAhead, 1);
  const dates = availabilityDates("2026-11-15");
  assert.equal(dates.length, 14);
  assert.equal(dates[0], "2026-11-16");
  assert.equal(dates[13], "2026-11-29");
});

test("la ventana cruza meses y años sin huecos", () => {
  const dates = availabilityDates("2026-12-25");
  assert.equal(dates[0], "2026-12-26");
  assert.ok(dates.includes("2027-01-01"));
  assert.equal(dates[13], "2027-01-08");
});

test("minutes: enteros de 30 a 720 en pasos de 30", () => {
  for (const ok of ["30", "150", "180", "330", "720", "0180"]) {
    assert.notEqual(parseAvailabilityMinutes(ok), null, ok);
  }
  assert.equal(parseAvailabilityMinutes("180"), 180);
  for (const bad of [null, "", "0", "29", "45", "750", "180.0", "-30", "1e2", "abc", " 180", "99999"]) {
    assert.equal(parseAvailabilityMinutes(bad), null, String(bad));
  }
});

test("la respuesta trae todas las fechas; las que la base no marcó no están disponibles", () => {
  const res = buildAvailabilityResponse("2026-11-15", 180, ["2026-11-17", "2026-11-18", "2030-01-01"]);
  assert.equal(res.version, AVAILABILITY_VERSION);
  assert.equal(res.minutes, 180);
  assert.equal(res.days.length, 14);
  assert.deepEqual(res.days.slice(0, 3), [
    { date: "2026-11-16", available: false },
    { date: "2026-11-17", available: true },
    { date: "2026-11-18", available: true },
  ]);
  assert.equal(res.days.filter((d) => d.available).length, 2);
});

test("la web lee la respuesta del servidor tal cual", () => {
  const res = buildAvailabilityResponse("2026-11-15", 180, ["2026-11-20"]);
  assert.deepEqual(parseAvailabilityResponse(JSON.parse(JSON.stringify(res))), res);
});

test("la web descarta respuestas con otra forma", () => {
  const ok = buildAvailabilityResponse("2026-11-15", 180, []);
  const bad: unknown[] = [
    null,
    "texto",
    [],
    { ...ok, version: 2 },
    { ...ok, minutes: "180" },
    { ...ok, minutes: 180.5 },
    { ...ok, days: "x" },
    { ...ok, days: [{ date: "2026-11-16" }] },
    { ...ok, days: [{ date: "2026-02-30", available: true }] },
    { ...ok, days: [{ date: "16/11/2026", available: true }] },
    { ...ok, days: [{ date: "2026-11-16", available: "true" }] },
    // Con huecos o desordenada: no se puede confiar en el resto.
    { ...ok, days: [{ date: "2026-11-16", available: true }, { date: "2026-11-18", available: true }] },
    { ...ok, days: [{ date: "2026-11-17", available: true }, { date: "2026-11-16", available: true }] },
  ];
  for (const json of bad) assert.equal(parseAvailabilityResponse(json), null, JSON.stringify(json));
});
