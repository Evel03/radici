import { describe, expect, it } from "vitest";
import { buildAvailabilityResponse } from "../../../supabase/functions/_shared/availability.ts";
import {
  availabilityState,
  buildMonth,
  dayStatus,
  daysInMonth,
  initialMonthIndex,
  mondayIndex,
  noFreeDays,
  selectionStillValid,
  windowMonths,
  type AvailabilityState,
  type CalendarInput,
} from "./calendar.ts";

// Domingo 15/11/2026: la ventana va del lunes 16/11 al domingo 29/11.
const TODAY = "2026-11-15";

function ready(free: string[]): AvailabilityState {
  return availabilityState(buildAvailabilityResponse(TODAY, 180, free), 180);
}

function input(overrides: Partial<CalendarInput> = {}): CalendarInput {
  return { today: TODAY, selected: "", applies: true, availability: ready(["2026-11-17", "2026-11-20"]), ...overrides };
}

describe("fechas", () => {
  it("días por mes, también febrero bisiesto", () => {
    expect(daysInMonth(2026, 11)).toBe(30);
    expect(daysInMonth(2026, 12)).toBe(31);
    expect(daysInMonth(2028, 2)).toBe(29);
    expect(daysInMonth(2027, 2)).toBe(28);
  });

  it("la semana empieza el lunes", () => {
    expect(mondayIndex("2026-11-16")).toBe(0); // lunes
    expect(mondayIndex("2026-11-15")).toBe(6); // domingo
    expect(mondayIndex("2026-11-01")).toBe(6); // el 1/11/2026 es domingo
  });

  it("meses de la ventana: uno, dos o cruzando el año", () => {
    expect(windowMonths("2026-11-01")).toEqual([{ year: 2026, month: 11 }]);
    expect(windowMonths(TODAY)).toEqual([{ year: 2026, month: 11 }]);
    expect(windowMonths("2026-11-20")).toEqual([{ year: 2026, month: 11 }, { year: 2026, month: 12 }]);
    expect(windowMonths("2026-12-25")).toEqual([{ year: 2026, month: 12 }, { year: 2027, month: 1 }]);
  });
});

describe("estado de cada día", () => {
  it("fuera de la ventana: hoy, antes y después de +14", () => {
    for (const date of ["2026-11-15", "2026-11-01", "2026-11-30"]) expect(dayStatus(date, input()), date).toBe("outside");
  });

  it("con la disponibilidad cargada: libres y ocupados", () => {
    expect(dayStatus("2026-11-17", input())).toBe("available");
    expect(dayStatus("2026-11-18", input())).toBe("unavailable");
  });

  it("mientras carga: pendiente; si falló: se puede elegir cualquier día de la ventana", () => {
    expect(dayStatus("2026-11-18", input({ availability: { kind: "loading" } }))).toBe("pending");
    expect(dayStatus("2026-11-18", input({ availability: { kind: "error" } }))).toBe("available");
    expect(dayStatus("2026-11-30", input({ availability: { kind: "error" } }))).toBe("outside");
  });

  it("eventos y sesiones extra: la disponibilidad semanal no aplica", () => {
    expect(dayStatus("2026-11-18", input({ applies: false }))).toBe("available");
    expect(dayStatus("2026-11-21", input({ applies: false, availability: { kind: "loading" } }))).toBe("available");
    expect(dayStatus("2026-11-30", input({ applies: false }))).toBe("outside");
  });

  it("una respuesta de otra duración o inválida no se usa", () => {
    const res = buildAvailabilityResponse(TODAY, 150, ["2026-11-17"]);
    expect(availabilityState(res, 180)).toEqual({ kind: "error" });
    expect(availabilityState(null, 180)).toEqual({ kind: "error" });
  });
});

describe("mes armado", () => {
  it("noviembre de 2026: empieza en domingo (6 casilleros vacíos), 30 días y el elegido marcado", () => {
    const month = buildMonth({ year: 2026, month: 11 }, input({ selected: "2026-11-20" }));
    expect(month.leading).toBe(6);
    expect(month.cells).toHaveLength(30);
    expect(month.cells[0]).toEqual({ date: "2026-11-01", day: 1, status: "outside", selected: false });
    expect(month.cells[16]).toEqual({ date: "2026-11-17", day: 17, status: "available", selected: false });
    expect(month.cells[19]).toEqual({ date: "2026-11-20", day: 20, status: "available", selected: true });
    expect(month.cells.filter((c) => c.status === "unavailable")).toHaveLength(12);
  });

  it("diciembre de 2026 empieza en martes", () => {
    expect(buildMonth({ year: 2026, month: 12 }, input()).leading).toBe(1);
  });
});

describe("selección", () => {
  it("se conserva si sigue libre o mientras carga; se pierde si quedó ocupada o fuera", () => {
    expect(selectionStillValid(input())).toBe(true);
    expect(selectionStillValid(input({ selected: "2026-11-17" }))).toBe(true);
    expect(selectionStillValid(input({ selected: "2026-11-18" }))).toBe(false);
    expect(selectionStillValid(input({ selected: "2026-11-18", availability: { kind: "loading" } }))).toBe(true);
    expect(selectionStillValid(input({ selected: "2026-11-18", availability: { kind: "error" } }))).toBe(true);
    expect(selectionStillValid(input({ selected: "2026-11-30" }))).toBe(false);
    expect(selectionStillValid(input({ selected: "2026-11-18", applies: false }))).toBe(true);
  });

  it("sin días libres: solo con la disponibilidad cargada y para la semana de comidas", () => {
    expect(noFreeDays(input({ availability: ready([]) }))).toBe(true);
    expect(noFreeDays(input())).toBe(false);
    expect(noFreeDays(input({ availability: ready([]), applies: false }))).toBe(false);
    expect(noFreeDays(input({ availability: { kind: "loading" } }))).toBe(false);
    expect(noFreeDays(input({ availability: { kind: "error" } }))).toBe(false);
  });

  it("mes inicial: el del elegido, si no el primero con días libres, si no el primero", () => {
    const today = "2026-11-25"; // ventana: 26/11 a 9/12
    const free = (dates: string[]): AvailabilityState => availabilityState(buildAvailabilityResponse(today, 180, dates), 180);
    const base = { today, selected: "", applies: true };
    expect(initialMonthIndex({ ...base, availability: free(["2026-11-27"]) })).toBe(0);
    expect(initialMonthIndex({ ...base, availability: free(["2026-12-02"]) })).toBe(1);
    expect(initialMonthIndex({ ...base, availability: free([]) })).toBe(0);
    expect(initialMonthIndex({ ...base, selected: "2026-12-03", availability: free(["2026-11-27"]) })).toBe(1);
  });
});
