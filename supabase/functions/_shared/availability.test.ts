// Tests del contrato de disponibilidad por día. Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import {
  AVAILABILITY_DAYS,
  AVAILABILITY_VERSION,
  availabilityDates,
  buildAvailabilityResponse,
  parseAvailabilityMinutes,
  parseAvailabilityResponse,
  type AvailabilityResponse,
} from "./availability.ts";
import { DATE_WINDOW, addDays } from "./public_request.ts";

test("la ventana es la del formulario: de mañana a +56 días (8 semanas)", () => {
  assert.equal(AVAILABILITY_DAYS, 56);
  assert.equal(DATE_WINDOW.minDaysAhead, 1);
  const dates = availabilityDates("2026-11-15");
  assert.equal(dates.length, 56);
  assert.equal(dates[0], "2026-11-16");
  assert.equal(dates[55], "2027-01-10");
});

test("la ventana cruza meses y años sin huecos", () => {
  const dates = availabilityDates("2026-12-25");
  assert.equal(dates[0], "2026-12-26");
  assert.ok(dates.includes("2027-01-01"));
  assert.equal(dates[55], "2027-02-19");
  dates.slice(1).forEach((date, i) => assert.equal(date, addDays(dates[i] ?? "", 1), date));
});

const MIGRATIONS = new URL("../../migrations/", import.meta.url);

/**
 * Valores por defecto de chef_settings.booking_horizon_days en las migraciones, en orden: el de la tabla
 * (create table) y cada cambio posterior (alter column … set default). Sin los comentarios de SQL.
 */
function horizonDefaults(): Array<{ file: string; value: number; sql: string }> {
  const found: Array<{ file: string; value: number; sql: string }> = [];
  const pattern = /booking_horizon_days\s+int\s+not\s+null\s+default\s+(\d+)|alter\s+column\s+booking_horizon_days\s+set\s+default\s+(\d+)/gi;
  for (const file of readdirSync(MIGRATIONS).filter((name) => name.endsWith(".sql")).sort()) {
    const sql = readFileSync(new URL(file, MIGRATIONS), "utf8").replace(/--.*$/gm, "");
    for (const match of sql.matchAll(pattern)) found.push({ file, value: Number(match[1] ?? match[2]), sql });
  }
  return found;
}

test("la base corta donde el contrato: booking_horizon_days por defecto es DATE_WINDOW.maxDaysAhead", () => {
  // private.free_slot_candidates (y get_free_days) ofrece de mañana a hoy + booking_horizon_days. Con una
  // ventana del contrato más larga, el calendario marcaría ocupados los últimos días aunque estén libres;
  // más corta, la base calcularía días que nadie puede elegir.
  const defaults = horizonDefaults();
  const current = defaults[defaults.length - 1];
  assert.ok(current, "no se encontró el valor por defecto de booking_horizon_days en las migraciones");
  assert.equal(current.value, DATE_WINDOW.maxDaysAhead, `valor por defecto de ${current.file}`);
  // El valor por defecto vale solo para las cocineras nuevas: la migración que lo cambia también pasa a las
  // que seguían en el anterior (en producción, Evelyn). Si no, la de producción se queda con la ventana vieja.
  // Lo hace private.replace_booking_horizon (pgTAP: 10_booking_horizon prueba qué filas cambia y updated_at).
  // pgTAP no ve la llamada (db reset corre las migraciones sobre una base vacía): la exige este test.
  const previous = defaults[defaults.length - 2];
  if (previous && previous.value !== current.value) {
    const migratesRows = new RegExp(
      `^\\s*select\\s+private\\.replace_booking_horizon\\(\\s*${previous.value}\\s*,\\s*${current.value}\\s*\\)\\s*;`,
      "im",
    );
    assert.match(
      current.sql,
      migratesRows,
      `${current.file} llama a private.replace_booking_horizon(${previous.value}, ${current.value}): pasa a ${current.value} a las cocineras que seguían en ${previous.value}`,
    );
  }
  // Y las dos empiezan mañana: v_today + 1 en free_slot_candidates.
  assert.equal(DATE_WINDOW.minDaysAhead, 1);
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
  assert.equal(res.days.length, 56);
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

test("la web acepta una respuesta de otro largo: la de la función de antes (14 días) o una más larga", () => {
  // Al desplegar, la web y la función se publican por separado: unos minutos puede haber web nueva con la
  // función de 14 días, o una página vieja abierta (14 días) con la función nueva. El largo no se valida:
  // los días que no vienen cuentan como no disponibles y los de más quedan fuera (calendar.ts en la web).
  const full = buildAvailabilityResponse("2026-11-15", 180, ["2026-11-17", "2026-12-15"]);
  const old: AvailabilityResponse = { ...full, days: full.days.slice(0, 14) };
  assert.deepEqual(parseAvailabilityResponse(JSON.parse(JSON.stringify(old))), old);
  const longer: AvailabilityResponse = {
    ...full,
    days: Array.from({ length: 70 }, (_, i) => ({ date: addDays("2026-11-15", 1 + i), available: i % 2 === 0 })),
  };
  assert.deepEqual(parseAvailabilityResponse(JSON.parse(JSON.stringify(longer))), longer);
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
