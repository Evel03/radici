import { describe, expect, it } from "vitest";
import {
  buildAvailabilityResponse,
  parseAvailabilityResponse,
  type AvailabilityResponse,
} from "../../../supabase/functions/_shared/availability.ts";
import { addDays } from "../lib/dates.ts";
import {
  availabilityState,
  buildMonth,
  dayStatus,
  daysInMonth,
  initialMonthIndex,
  mondayIndex,
  monthNav,
  noFreeDays,
  selectionStillValid,
  windowMonths,
  type AvailabilityState,
  type CalendarInput,
} from "./calendar.ts";

// Domingo 15/11/2026: la ventana (8 semanas) va del lunes 16/11/2026 al domingo 10/01/2027.
const TODAY = "2026-11-15";

function ready(free: string[], today = TODAY): AvailabilityState {
  return availabilityState(buildAvailabilityResponse(today, 180, free), 180);
}

function input(overrides: Partial<CalendarInput> = {}): CalendarInput {
  return { today: TODAY, selected: "", applies: true, availability: ready(["2026-11-17", "2026-11-20"]), ...overrides };
}

/** Lo que recibe la web: la respuesta pasada por JSON y leída con parseAvailabilityResponse. */
function received(response: AvailabilityResponse): AvailabilityState {
  return availabilityState(parseAvailabilityResponse(JSON.parse(JSON.stringify(response))), response.minutes);
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

  it("meses de la ventana: dos o tres, también cruzando el año", () => {
    expect(windowMonths(TODAY)).toEqual([
      { year: 2026, month: 11 },
      { year: 2026, month: 12 },
      { year: 2027, month: 1 },
    ]);
    expect(windowMonths("2026-11-01")).toEqual([{ year: 2026, month: 11 }, { year: 2026, month: 12 }]);
    expect(windowMonths("2026-11-30")).toEqual([{ year: 2026, month: 12 }, { year: 2027, month: 1 }]);
    // Fin de año: del 21/12/2026 al 14/02/2027.
    expect(windowMonths("2026-12-20")).toEqual([
      { year: 2026, month: 12 },
      { year: 2027, month: 1 },
      { year: 2027, month: 2 },
    ]);
  });

  it("cualquier día del año: la ventana toca dos o tres meses seguidos, del de mañana al del último día", () => {
    for (let today = "2026-01-01"; today < "2029-01-01"; today = addDays(today, 1)) {
      const months = windowMonths(today);
      expect(months.length === 2 || months.length === 3, today).toBe(true);
      const first = addDays(today, 1);
      const last = addDays(today, 56);
      expect(months[0], today).toEqual({ year: Number(first.slice(0, 4)), month: Number(first.slice(5, 7)) });
      expect(months[months.length - 1], today).toEqual({ year: Number(last.slice(0, 4)), month: Number(last.slice(5, 7)) });
    }
  });
});

describe("estado de cada día", () => {
  it("fuera de la ventana: hoy, antes y después de +56", () => {
    for (const date of ["2026-11-15", "2026-11-01", "2027-01-11"]) expect(dayStatus(date, input()), date).toBe("outside");
    expect(dayStatus("2027-01-10", input({ availability: ready(["2027-01-10"]) }))).toBe("available");
  });

  it("con la disponibilidad cargada: libres y ocupados", () => {
    expect(dayStatus("2026-11-17", input())).toBe("available");
    expect(dayStatus("2026-11-18", input())).toBe("unavailable");
    expect(dayStatus("2026-12-22", input())).toBe("unavailable");
  });

  it("mientras carga: pendiente; si falló: se puede elegir cualquier día de la ventana", () => {
    expect(dayStatus("2026-11-18", input({ availability: { kind: "loading" } }))).toBe("pending");
    expect(dayStatus("2026-11-18", input({ availability: { kind: "error" } }))).toBe("available");
    expect(dayStatus("2027-01-10", input({ availability: { kind: "error" } }))).toBe("available");
    expect(dayStatus("2027-01-11", input({ availability: { kind: "error" } }))).toBe("outside");
  });

  it("eventos y sesiones extra: la disponibilidad semanal no aplica", () => {
    expect(dayStatus("2026-11-18", input({ applies: false }))).toBe("available");
    expect(dayStatus("2026-11-21", input({ applies: false, availability: { kind: "loading" } }))).toBe("available");
    expect(dayStatus("2027-01-11", input({ applies: false }))).toBe("outside");
  });

  it("una respuesta de otra duración o inválida no se usa", () => {
    const res = buildAvailabilityResponse(TODAY, 150, ["2026-11-17"]);
    expect(availabilityState(res, 180)).toEqual({ kind: "error" });
    expect(availabilityState(null, 180)).toEqual({ kind: "error" });
  });
});

describe("despliegue: la web y la función no coinciden unos minutos", () => {
  // La función de antes responde 14 días; la web de antes (en un navegador abierto) espera 14 y recibe 56.
  const full = buildAvailabilityResponse(TODAY, 180, ["2026-11-17", "2026-12-15"]);

  it("web nueva con la función de antes (14 días): los días que no vienen cuentan como no disponibles", () => {
    const old = received({ ...full, days: full.days.slice(0, 14) });
    expect(old.kind).toBe("ready");
    const state = input({ availability: old });
    expect(dayStatus("2026-11-17", state)).toBe("available");
    expect(dayStatus("2026-11-29", state)).toBe("unavailable"); // el día 14, ocupado
    expect(dayStatus("2026-11-30", state)).toBe("unavailable"); // el 15 ya no vino
    expect(dayStatus("2026-12-15", state)).toBe("unavailable"); // libre, pero fuera de esa respuesta
    expect(dayStatus("2027-01-10", state)).toBe("unavailable");
    expect(dayStatus("2027-01-11", state)).toBe("outside");
    expect(selectionStillValid({ ...state, selected: "2026-12-15" })).toBe(false);
    expect(noFreeDays(state)).toBe(false);
    expect(initialMonthIndex(state)).toBe(0);
    // Sin ningún libre en esos 14 días: el aviso de que no hay lugar (envíalo sin fecha).
    expect(noFreeDays(input({ availability: received({ ...full, days: full.days.slice(0, 14).map((d) => ({ ...d, available: false })) }) }))).toBe(true);
  });

  it("una respuesta con días de más (como la que recibe la web de antes): esos días no se pueden elegir", () => {
    const longer = received({
      ...full,
      days: Array.from({ length: 70 }, (_, i) => ({ date: addDays(TODAY, 1 + i), available: true })),
    });
    const state = input({ availability: longer });
    expect(dayStatus("2027-01-10", state)).toBe("available");
    expect(dayStatus("2027-01-11", state)).toBe("outside");
    expect(dayStatus("2027-01-24", state)).toBe("outside");
    expect(windowMonths(TODAY)).toHaveLength(3);
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
    // Del 16 al 30 están en la ventana: 15 días, 2 libres.
    expect(month.cells.filter((c) => c.status === "unavailable")).toHaveLength(13);
  });

  it("diciembre de 2026 empieza en martes y está entero en la ventana", () => {
    const month = buildMonth({ year: 2026, month: 12 }, input());
    expect(month.leading).toBe(1);
    expect(month.cells.filter((c) => c.status === "outside")).toHaveLength(0);
  });

  it("enero de 2027: en la ventana hasta el 10", () => {
    const month = buildMonth({ year: 2027, month: 1 }, input({ availability: ready(["2027-01-08"]) }));
    expect(month.leading).toBe(4); // el 1/1/2027 es viernes
    expect(month.cells.filter((c) => c.status !== "outside").map((c) => c.day)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    expect(month.cells[7]?.status).toBe("available");
  });
});

describe("selección", () => {
  it("se conserva si sigue libre o mientras carga; se pierde si quedó ocupada o fuera", () => {
    expect(selectionStillValid(input())).toBe(true);
    expect(selectionStillValid(input({ selected: "2026-11-17" }))).toBe(true);
    expect(selectionStillValid(input({ selected: "2026-11-18" }))).toBe(false);
    expect(selectionStillValid(input({ selected: "2026-11-18", availability: { kind: "loading" } }))).toBe(true);
    expect(selectionStillValid(input({ selected: "2026-11-18", availability: { kind: "error" } }))).toBe(true);
    expect(selectionStillValid(input({ selected: "2027-01-11", availability: { kind: "error" } }))).toBe(false);
    expect(selectionStillValid(input({ selected: "2026-11-18", applies: false }))).toBe(true);
  });

  it("sin días libres: solo con la disponibilidad cargada y para la semana de comidas", () => {
    expect(noFreeDays(input({ availability: ready([]) }))).toBe(true);
    expect(noFreeDays(input())).toBe(false);
    expect(noFreeDays(input({ availability: ready(["2027-01-10"]) }))).toBe(false);
    expect(noFreeDays(input({ availability: ready([]), applies: false }))).toBe(false);
    expect(noFreeDays(input({ availability: { kind: "loading" } }))).toBe(false);
    expect(noFreeDays(input({ availability: { kind: "error" } }))).toBe(false);
  });

  it("mes inicial: el del elegido, si no el primero con días libres, si no el primero", () => {
    const today = "2026-11-25"; // ventana: 26/11/2026 a 20/01/2027
    const base = { today, selected: "", applies: true };
    expect(initialMonthIndex({ ...base, availability: ready(["2026-11-27"], today) })).toBe(0);
    expect(initialMonthIndex({ ...base, availability: ready(["2026-12-02"], today) })).toBe(1);
    expect(initialMonthIndex({ ...base, availability: ready(["2027-01-05", "2027-01-20"], today) })).toBe(2);
    expect(initialMonthIndex({ ...base, availability: ready([], today) })).toBe(0);
    expect(initialMonthIndex({ ...base, selected: "2026-12-03", availability: ready(["2026-11-27"], today) })).toBe(1);
    expect(initialMonthIndex({ ...base, selected: "2027-01-12", availability: ready(["2026-11-27"], today) })).toBe(2);
  });

  it("mes inicial a fin de año: la ventana del 21/12/2026 al 14/02/2027", () => {
    const today = "2026-12-20";
    const base = { today, selected: "", applies: true };
    expect(initialMonthIndex({ ...base, availability: ready(["2027-02-01"], today) })).toBe(2);
    expect(initialMonthIndex({ ...base, availability: ready(["2027-01-04", "2027-02-01"], today) })).toBe(1);
    expect(initialMonthIndex({ ...base, availability: ready(["2026-12-21"], today) })).toBe(0);
    expect(initialMonthIndex({ ...base, selected: "2027-02-10", availability: ready(["2026-12-21"], today) })).toBe(2);
    // Mientras carga, el primero; si falló, también (se puede elegir cualquier día y el primero es mañana).
    expect(initialMonthIndex({ ...base, availability: { kind: "loading" } })).toBe(0);
    expect(initialMonthIndex({ ...base, availability: { kind: "error" } })).toBe(0);
  });
});

describe("flechas del calendario", () => {
  it("con tres meses: en el del medio se puede ir a los dos lados", () => {
    expect(monthNav(0, 3)).toEqual({ index: 0, prev: false, next: true });
    expect(monthNav(1, 3)).toEqual({ index: 1, prev: true, next: true });
    expect(monthNav(2, 3)).toEqual({ index: 2, prev: true, next: false });
  });

  it("con dos meses, y un índice fuera de rango se recorta (la ventana pasó a tener un mes menos)", () => {
    expect(monthNav(0, 2)).toEqual({ index: 0, prev: false, next: true });
    expect(monthNav(1, 2)).toEqual({ index: 1, prev: true, next: false });
    expect(monthNav(2, 2)).toEqual({ index: 1, prev: true, next: false });
    expect(monthNav(-1, 3)).toEqual({ index: 0, prev: false, next: true });
  });
});
