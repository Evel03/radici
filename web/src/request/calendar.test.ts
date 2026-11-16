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
  calendarNav,
  coversWindow,
  dayStatus,
  daysInMonth,
  initialMonthIndex,
  mondayIndex,
  monthNav,
  noFreeDays,
  selectionStillValid,
  sessionDays,
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
  return { today: TODAY, selected: "", applies: true, weeks: 1, availability: ready(["2026-11-17", "2026-11-20"]), ...overrides };
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
    // Sin ningún libre en esos 14 días, el aviso dice que no hay lugar en las 8 semanas aunque solo se
    // consultaron 2. Dura lo que el despliegue; con más de 300 min de cocina es cierto igual (no entra ningún
    // día) y mandarlo sin fecha es lo único que se puede hacer.
    expect(noFreeDays(input({ availability: received({ ...full, days: full.days.slice(0, 14).map((d) => ({ ...d, available: false })) }) }))).toBe(true);
  });

  it("una respuesta con días de más (como la que recibe la web de antes): se usa, y esos días no se pueden elegir", () => {
    const longer = received({
      ...full,
      // El día 10 (25/11) ocupado: si la respuesta se descartara (error), ese día se podría elegir.
      days: Array.from({ length: 70 }, (_, i) => ({ date: addDays(TODAY, 1 + i), available: i !== 9 })),
    });
    expect(longer.kind).toBe("ready");
    const state = input({ availability: longer });
    expect(dayStatus("2026-11-25", state)).toBe("unavailable");
    expect(dayStatus("2027-01-10", state)).toBe("available");
    expect(dayStatus("2027-01-11", state)).toBe("outside");
    expect(dayStatus("2027-01-24", state)).toBe("outside");
    expect(windowMonths(TODAY)).toHaveLength(3);
  });

  it("caché de la página: solo guarda una respuesta que cubre la ventana", () => {
    const days = (state: AvailabilityState): ReadonlyMap<string, boolean> => (state.kind === "ready" ? state.days : new Map());
    expect(coversWindow(days(received(full)), TODAY)).toBe(true);
    // La de la función de antes no: al volver a esa duración, la página la pide de nuevo.
    expect(coversWindow(days(received({ ...full, days: full.days.slice(0, 14) })), TODAY)).toBe(false);
    expect(coversWindow(days(received({ ...full, days: full.days.slice(0, 55) })), TODAY)).toBe(false);
    // Una con días de más, sí.
    const longer = { ...full, days: Array.from({ length: 70 }, (_, i) => ({ date: addDays(TODAY, 1 + i), available: false })) };
    expect(coversWindow(days(received(longer)), TODAY)).toBe(true);
  });
});

describe("mes armado", () => {
  it("noviembre de 2026: empieza en domingo (6 casilleros vacíos), 30 días y el elegido marcado", () => {
    const month = buildMonth({ year: 2026, month: 11 }, input({ selected: "2026-11-20" }));
    expect(month.leading).toBe(6);
    expect(month.cells).toHaveLength(30);
    expect(month.cells[0]).toEqual({ date: "2026-11-01", day: 1, status: "outside", selected: false, repeat: null });
    expect(month.cells[16]).toEqual({ date: "2026-11-17", day: 17, status: "available", selected: false, repeat: null });
    expect(month.cells[19]).toEqual({ date: "2026-11-20", day: 20, status: "available", selected: true, repeat: null });
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
    const base = { today, selected: "", applies: true, weeks: 1 };
    expect(initialMonthIndex({ ...base, availability: ready(["2026-11-27"], today) })).toBe(0);
    expect(initialMonthIndex({ ...base, availability: ready(["2026-12-02"], today) })).toBe(1);
    expect(initialMonthIndex({ ...base, availability: ready(["2027-01-05", "2027-01-20"], today) })).toBe(2);
    expect(initialMonthIndex({ ...base, availability: ready([], today) })).toBe(0);
    expect(initialMonthIndex({ ...base, selected: "2026-12-03", availability: ready(["2026-11-27"], today) })).toBe(1);
    expect(initialMonthIndex({ ...base, selected: "2027-01-12", availability: ready(["2026-11-27"], today) })).toBe(2);
  });

  it("mes inicial a fin de año: la ventana del 21/12/2026 al 14/02/2027", () => {
    const today = "2026-12-20";
    const base = { today, selected: "", applies: true, weeks: 1 };
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

  it("calendarNav: el mes inicial mientras el cliente no usó las flechas; después, el que eligió", () => {
    const today = "2026-11-25"; // ventana: 26/11/2026 a 20/01/2027, tres meses
    const state = { today, selected: "", applies: true, weeks: 1, availability: ready(["2026-12-02"], today) };
    expect(calendarNav(state, 0, false)).toEqual({ index: 1, prev: true, next: true }); // el del primer día libre
    expect(calendarNav(state, 2, false)).toEqual({ index: 1, prev: true, next: true });
    expect(calendarNav(state, 2, true)).toEqual({ index: 2, prev: true, next: false });
    expect(calendarNav(state, 0, true)).toEqual({ index: 0, prev: false, next: true });
  });

  it("calendarNav: si a medianoche la ventana pierde un mes, el índice se recorta y el calendario sigue teniendo mes", () => {
    // Domingo 29/11/2026: de noviembre a enero. Lunes 30/11: de diciembre a enero.
    expect(windowMonths("2026-11-29")).toHaveLength(3);
    expect(windowMonths("2026-11-30")).toEqual([{ year: 2026, month: 12 }, { year: 2027, month: 1 }]);
    const after = { today: "2026-11-30", selected: "", applies: true, weeks: 1, availability: ready([], "2026-11-30") };
    // El cliente estaba en enero (el tercero): enero sigue siendo el último.
    expect(calendarNav(after, 2, true)).toEqual({ index: 1, prev: true, next: false });
  });
});

describe("varias semanas: el mismo día de las semanas siguientes", () => {
  // Ventana del 16/11/2026 al 10/01/2027. Libres: los lunes 23/11, 30/11 y 14/12 (el 7/12 no).
  const free = ready(["2026-11-23", "2026-11-30", "2026-12-14", "2027-01-04"]);
  const fourWeeks = input({ selected: "2026-11-23", weeks: 4, availability: free });

  it("el calendario marca las semanas siguientes con su número y su disponibilidad", () => {
    const november = buildMonth({ year: 2026, month: 11 }, fourWeeks);
    expect(november.cells[22]).toMatchObject({ date: "2026-11-23", selected: true, repeat: null });
    expect(november.cells[29]).toMatchObject({ date: "2026-11-30", status: "available", selected: false, repeat: 2 });
    const december = buildMonth({ year: 2026, month: 12 }, fourWeeks);
    expect(december.cells[6]).toMatchObject({ date: "2026-12-07", status: "unavailable", repeat: 3 });
    expect(december.cells[13]).toMatchObject({ date: "2026-12-14", status: "available", repeat: 4 });
    // Solo esas: el 21/12 sería la quinta semana.
    expect(december.cells.filter((cell) => cell.repeat !== null).map((cell) => cell.day)).toEqual([7, 14]);
  });

  it("la lista de fechas: la primera es la elegida; las de fuera de la ventana las confirma Evelyn", () => {
    expect(sessionDays(fourWeeks)).toEqual([
      { week: 1, date: "2026-11-23", status: "selected" },
      { week: 2, date: "2026-11-30", status: "available" },
      { week: 3, date: "2026-12-07", status: "unavailable" },
      { week: 4, date: "2026-12-14", status: "available" },
    ]);
    // 8 semanas desde el 7/12: la ventana termina el 10/01, así que las del 11/01 en adelante quedan fuera.
    const eight = sessionDays(input({ selected: "2026-12-07", weeks: 8, availability: ready(["2026-12-07", "2027-01-04"]) }));
    expect(eight.map((day) => day.status)).toEqual([
      "selected", "unavailable", "unavailable", "unavailable", "available", "outside", "outside", "outside",
    ]);
    expect(eight.at(-1)).toEqual({ week: 8, date: "2027-01-25", status: "outside" });
    // Fuera de la ventana también se marcan en el calendario (si se ve ese mes): no se pueden elegir.
    const january = buildMonth({ year: 2027, month: 1 }, input({ selected: "2026-12-07", weeks: 8 }));
    expect(january.cells.filter((cell) => cell.repeat !== null).map((cell) => [cell.day, cell.status, cell.repeat])).toEqual([
      [4, "unavailable", 5], [11, "outside", 6], [18, "outside", 7], [25, "outside", 8],
    ]);
  });

  it("sin disponibilidad (error), mientras carga, sin fecha o con una sola semana", () => {
    expect(sessionDays(input({ selected: "2026-11-23", weeks: 2, availability: { kind: "error" } })).map((d) => d.status)).toEqual(["selected", "unknown"]);
    // Con error, las semanas que caen después de la ventana (termina el 10/01) siguen siendo «fuera del
    // calendario», no «te lo confirma Evelyn» a secas.
    expect(sessionDays(input({ selected: "2026-12-07", weeks: 8, availability: { kind: "error" } })).map((d) => d.status)).toEqual([
      "selected", "unknown", "unknown", "unknown", "unknown", "outside", "outside", "outside",
    ]);
    expect(sessionDays(input({ selected: "2026-11-23", weeks: 2, availability: { kind: "loading" } })).map((d) => d.status)).toEqual(["selected", "pending"]);
    expect(sessionDays(input({ selected: "", weeks: 4 }))).toEqual([]);
    expect(sessionDays(input({ selected: "2026-11-17", weeks: 1 }))).toEqual([{ week: 1, date: "2026-11-17", status: "selected" }]);
    expect(buildMonth({ year: 2026, month: 11 }, input({ selected: "2026-11-17" })).cells.every((cell) => cell.repeat === null)).toBe(true);
  });

  it("eventos y sesiones extra: una sola fecha, sin semanas siguientes", () => {
    const extra = input({ selected: "2026-11-18", weeks: 4, applies: false });
    expect(sessionDays(extra)).toEqual([{ week: 1, date: "2026-11-18", status: "selected" }]);
    expect(buildMonth({ year: 2026, month: 11 }, extra).cells.every((cell) => cell.repeat === null)).toBe(true);
  });

  it("las semanas siguientes no cambian qué día se puede elegir ni si la elección sigue valiendo", () => {
    expect(selectionStillValid(fourWeeks)).toBe(true);
    expect(dayStatus("2026-12-07", fourWeeks)).toBe("unavailable");
    expect(noFreeDays(fourWeeks)).toBe(false);
  });
});
