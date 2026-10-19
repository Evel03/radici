import { describe, expect, it } from "vitest";
import { romeToday } from "../../../supabase/functions/_shared/public_request.ts";
import { createI18n } from "../i18n/core.ts";
import { addDays, isIsoDate, todayInRome } from "./dates.ts";
import { formatCents, formatDuration, formatIsoDate } from "./format.ts";

describe("fechas en Europe/Rome", () => {
  it("'hoy' es el día de Bergamo, no el de UTC", () => {
    // 23:30 UTC del 19/10 = 01:30 del 20/10 en Roma (horario de verano, UTC+2).
    expect(todayInRome(new Date("2026-10-19T23:30:00Z"))).toBe("2026-10-20");
    // 22:30 UTC del 31/12 = 23:30 del 31/12 en Roma (invierno, UTC+1).
    expect(todayInRome(new Date("2026-12-31T22:30:00Z"))).toBe("2026-12-31");
  });

  it("coincide con el 'hoy' del servidor (romeToday), también en los cambios de hora", () => {
    for (const instant of ["2026-03-28T23:30:00Z", "2026-03-29T00:59:00Z", "2026-10-24T22:30:00Z", "2026-10-25T01:30:00Z", "2026-07-14T21:59:59Z"]) {
      expect(todayInRome(new Date(instant)), instant).toBe(romeToday(new Date(instant)));
    }
  });

  it("suma días cruzando meses y años", () => {
    expect(addDays("2026-10-19", 14)).toBe("2026-11-02");
    expect(addDays("2026-12-31", 1)).toBe("2027-01-01");
  });

  it("valida fechas ISO reales", () => {
    expect(isIsoDate("2026-10-26")).toBe(true);
    expect(isIsoDate("2026-02-30")).toBe(false);
    expect(isIsoDate("26/10/2026")).toBe(false);
  });
});

describe("formato", () => {
  it("moneda desde centavos enteros según el idioma", () => {
    expect(formatCents(14100, "it-IT")).toMatch(/^141,00\s€$/);
    expect(formatCents(14100, "es-ES")).toMatch(/^141,00\s€$/);
    expect(formatCents(14100, "en-IE")).toBe("€141.00");
    expect(formatCents(8488, "it-IT")).toMatch(/^84,88\s€$/);
  });

  it("rechaza importes no enteros", () => {
    expect(() => formatCents(10.5, "it-IT")).toThrow(RangeError);
  });

  it("duraciones", () => {
    const i18n = createI18n("it", {
      "common.durationHours": "{h} h",
      "common.durationHoursMinutes": "{h} h {m} min",
      "common.durationMinutes": "{m} min",
    });
    expect(formatDuration(180, i18n)).toBe("3 h");
    expect(formatDuration(150, i18n)).toBe("2 h 30 min");
    expect(formatDuration(45, i18n)).toBe("45 min");
  });

  it("fecha larga según el idioma", () => {
    expect(formatIsoDate("2026-10-26", "it-IT")).toBe("lunedì 26 ottobre 2026");
    expect(formatIsoDate("2026-10-26", "en-IE")).toMatch(/Monday,? 26 October 2026/);
  });
});
