import { describe, expect, it } from "vitest";
import { SESSION_1, TOKEN, content, menu, week } from "../fixtures.ts";
import { focusId } from "../render.ts";
import { readToken } from "../token.ts";
import {
  MAX_DOTS,
  bookFragment,
  bookPages,
  bookSignature,
  canGo,
  clampPage,
  closingKind,
  closingTargets,
  createBackdropClick,
  createBookHistory,
  directionOf,
  keyAction,
  pagePresentation,
  readBookSession,
  showDots,
  step,
  trapFocus,
} from "./state.ts";

describe("las páginas del libro", () => {
  it("la tapa, un plato por página en el orden del menú y la última", () => {
    expect(bookPages(content())).toEqual([{ kind: "cover" }, { kind: "dish", dish: 0 }, { kind: "dish", dish: 1 }, { kind: "closing" }]);
  });

  it("clampPage: siempre una página que existe (un número roto, la tapa)", () => {
    expect(clampPage(2, 4)).toBe(2);
    expect(clampPage(-1, 4)).toBe(0);
    expect(clampPage(9, 4)).toBe(3);
    expect(clampPage(1.7, 4)).toBe(1);
    expect(clampPage(Number.NaN, 4)).toBe(0);
    expect(clampPage(Number.POSITIVE_INFINITY, 4)).toBe(0);
    expect(clampPage(3, 0)).toBe(0);
  });

  it("canGo y step: las flechas se deshabilitan en los bordes; step no se pasa", () => {
    expect([canGo(0, 4, "prev"), canGo(0, 4, "next")]).toEqual([false, true]);
    expect([canGo(3, 4, "prev"), canGo(3, 4, "next")]).toEqual([true, false]);
    expect([step(0, 4, "next"), step(3, 4, "next"), step(0, 4, "prev"), step(2, 4, "prev")]).toEqual([1, 3, 0, 1]);
  });

  it("directionOf: hacia adelante o hacia atrás (null si es la misma)", () => {
    expect([directionOf(1, 2), directionOf(3, 0), directionOf(2, 2)]).toEqual(["next", "prev", null]);
  });

  it("keyAction: ← y → pasan de página, Esc cierra; en los bordes, nada", () => {
    expect(keyAction("ArrowRight", 0, 4)).toEqual({ kind: "go", page: 1 });
    expect(keyAction("ArrowLeft", 2, 4)).toEqual({ kind: "go", page: 1 });
    expect(keyAction("Escape", 2, 4)).toEqual({ kind: "close" });
    expect([keyAction("ArrowRight", 3, 4), keyAction("ArrowLeft", 0, 4)]).toEqual([null, null]);
    // Las demás siguen su camino: el scroll de una página larga (↑ ↓, Inicio, Fin…) y Enter o espacio en un botón.
    for (const key of ["Enter", " ", "ArrowDown", "ArrowUp", "PageDown", "Home", "End", "Tab"]) expect(keyAction(key, 1, 4), key).toBeNull();
  });
});

describe("cómo se muestra cada página (y qué fotos se cargan ya)", () => {
  it("la actual se ve; la siguiente está lista (oculta) y su foto se carga ya; las demás, con hidden y lazy", () => {
    expect(pagePresentation(2, 2)).toEqual({ current: true, shown: true, eager: true });
    expect(pagePresentation(3, 2)).toEqual({ current: false, shown: true, eager: true });
    expect(pagePresentation(1, 2)).toEqual({ current: false, shown: false, eager: false });
    expect(pagePresentation(5, 2)).toEqual({ current: false, shown: false, eager: false });
  });

  it("la que se va sigue en la página mientras da vuelta la hoja", () => {
    expect(pagePresentation(0, 4, 0)).toEqual({ current: false, shown: true, eager: false });
    expect(pagePresentation(0, 4, null)).toEqual({ current: false, shown: false, eager: false });
  });

  it("los puntos, solo si entran en un teléfono (si no, queda «2 / 14»)", () => {
    expect(MAX_DOTS).toBe(9);
    expect([showDots(1), showDots(2), showDots(MAX_DOTS), showDots(MAX_DOTS + 1)]).toEqual([false, true, true, false]);
  });
});

describe("la última página", () => {
  it("closingKind: por confirmar, con un presupuesto abierto, confirmado, con cambios pedidos o ya cocinada", () => {
    expect(closingKind(week(), null)).toBe("answer");
    expect(closingKind(week(), "quote-accept")).toBe("quote");
    expect(closingKind(week({ menu: menu({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00Z" }) }), null)).toBe("confirmed");
    expect(closingKind(week({ menu: menu({ state: "changesRequested", changesRequestedAt: "2027-02-26T10:00:00Z" }) }), "quote-accept")).toBe(
      "changes",
    );
    expect(closingKind(week({ done: true }), "quote-accept")).toBe("done");
    expect(closingKind(week({ menu: null }), null)).toBe("done");
  });

  it("closingTargets: vuelve a las acciones de la semana (confirmar, el mensaje a medio escribir o el estado) o al presupuesto", () => {
    const status = focusId({ kind: "status", session: SESSION_1 });
    expect(closingTargets("answer", SESSION_1, null)).toEqual([
      focusId({ kind: "confirm", session: SESSION_1 }),
      focusId({ kind: "textarea", session: SESSION_1 }),
      status,
    ]);
    expect(closingTargets("quote", SESSION_1, "quote-accept")).toEqual(["quote-accept", status]);
    expect(closingTargets("quote", SESSION_1, null)).toEqual([status]);
    for (const kind of ["confirmed", "changes", "done"] as const) expect(closingTargets(kind, SESSION_1, null)).toEqual([status]);
  });
});

describe("el fragmento de la URL", () => {
  it("readBookSession: la semana del libro, en minúsculas; tolera un punto o un paréntesis pegados al copiar", () => {
    expect(readBookSession(`#t=${TOKEN}&libro=${SESSION_1}`)).toBe(SESSION_1);
    expect(readBookSession(`#t=${TOKEN}&libro=${SESSION_1.toUpperCase()}`)).toBe(SESSION_1);
    expect(readBookSession(`#libro=${SESSION_1}&t=${TOKEN}`)).toBe(SESSION_1);
    expect(readBookSession(`#t=${TOKEN}&libro=${SESSION_1}.`)).toBe(SESSION_1);
    expect(readBookSession(`#t=${TOKEN}&libro=${SESSION_1})`)).toBe(SESSION_1);
  });

  it("readBookSession: sin libro o con algo que no es un uuid, null", () => {
    for (const hash of ["", "#", `#t=${TOKEN}`, `#t=${TOKEN}&libro=`, `#t=${TOKEN}&libro=semana-1`, `#t=${TOKEN}&libro=${SESSION_1}0`, `#t=${TOKEN}&libro=${SESSION_1.slice(1)}`]) {
      expect(readBookSession(hash), hash).toBeNull();
    }
  });

  it("bookFragment: el token y la semana, solo en el fragmento; el token se sigue leyendo igual", () => {
    const fragment = bookFragment(TOKEN, SESSION_1.toUpperCase());
    expect(fragment).toBe(`#t=${TOKEN}&libro=${SESSION_1}`);
    expect(readToken(fragment)).toBe(TOKEN);
    expect(readBookSession(fragment)).toBe(SESSION_1);
    expect(fragment.includes("?")).toBe(false);
  });
});

/**
 * Un navegador falso con lo que importa del historial (HTML, «session history»): cada entrada guarda su scroll y su
 * scrollRestoration (history.scrollRestoration es el de la entrada activa) y pushState le copia el suyo a la nueva.
 * Volver atrás dispara popstate, después restaura el scroll de la entrada a la que vuelve si dice "auto" y recién
 * después hashchange.
 */
function fakeWindow(hash: string) {
  interface Entry {
    hash: string;
    mode: ScrollRestoration;
    scroll: number;
  }
  const entries: Entry[] = [{ hash, mode: "auto", scroll: 0 }];
  let index = 0;
  const listeners = new Map<string, (() => void)[]>();
  const current = (): Entry => entries[index] as Entry;
  const fire = (type: string): void => {
    for (const listener of listeners.get(type) ?? []) listener();
  };
  const win = {
    scrollY: 0,
    location: {
      get hash(): string {
        return current().hash;
      },
    },
    history: {
      state: null,
      get scrollRestoration(): ScrollRestoration {
        return current().mode;
      },
      set scrollRestoration(mode: ScrollRestoration) {
        current().mode = mode;
      },
      pushState(_data: unknown, _unused: string, url?: string | URL | null): void {
        current().scroll = win.scrollY;
        entries.splice(index + 1, entries.length, { hash: new URL(String(url), "https://radici.test/").hash, mode: current().mode, scroll: win.scrollY });
        index += 1;
      },
    },
    addEventListener(type: string, listener: () => void): void {
      listeners.set(type, [...(listeners.get(type) ?? []), listener]);
    },
    back(): void {
      current().scroll = win.scrollY;
      index -= 1;
      fire("popstate");
      if (current().mode === "auto") win.scrollY = current().scroll;
      fire("hashchange");
    },
  };
  return win;
}

describe("la entrada del historial del libro (abierto con el botón de la semana)", () => {
  const bookUrl = `/prenotazione/${bookFragment(TOKEN, SESSION_1)}`;

  it("cerrarlo vuelve atrás sin restaurar el scroll guardado: la página queda donde la llevó el foco (confirmar)", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    const bookHistory = createBookHistory(win);
    // «Sfoglia il menù», en el medio de la página.
    win.scrollY = 1600;
    bookHistory.push(bookUrl);
    expect(readBookSession(win.location.hash)).toBe(SESSION_1);
    // «Vai alla conferma»: el foco baja la página hasta «Confermo il menù» y después se vuelve atrás.
    win.scrollY = 3300;
    win.back();
    expect(win.location.hash).toBe(`#t=${TOKEN}`);
    expect(win.scrollY).toBe(3300);
  });

  it("solo esa vuelta: el libro abierto y la página, después del hashchange, restauran su scroll como siempre", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    const bookHistory = createBookHistory(win);
    bookHistory.push(bookUrl);
    // Recargar con el libro abierto restaura como siempre.
    expect(win.history.scrollRestoration).toBe("auto");
    win.back();
    // Recargar la página, o volver a ella desde otra, también.
    expect(win.history.scrollRestoration).toBe("auto");
    // Y la próxima vez que se abre y se cierra, lo mismo.
    win.scrollY = 900;
    bookHistory.push(bookUrl);
    win.scrollY = 2400;
    win.back();
    expect([win.scrollY, win.history.scrollRestoration]).toEqual([2400, "auto"]);
  });
});

describe("el foco, el clic en el fondo y lo que cambia el libro", () => {
  it("trapFocus: del último al primero, del primero al último; en el medio sigue el navegador", () => {
    const items = ["close", "prev", "dot", "next"];
    expect(trapFocus(items, "next", false)).toBe("close");
    expect(trapFocus(items, "close", true)).toBe("next");
    expect(trapFocus(items, "prev", false)).toBeNull();
    expect(trapFocus(items, "dot", true)).toBeNull();
    // El foco en la página (que no está en la lista): Tab va al primero, Mayús+Tab al último.
    expect(trapFocus(items, null, false)).toBe("close");
    expect(trapFocus(items, null, true)).toBe("next");
    expect(trapFocus([], null, false)).toBeNull();
  });

  it("el clic en el fondo cierra el libro solo si se apretó y se soltó ahí (como el cierre liviano de un <dialog>)", () => {
    const backdrop = createBackdropClick();
    // Apretar, soltar y el clic en el fondo: cierra.
    backdrop.down(true);
    backdrop.up(true);
    expect(backdrop.click()).toBe(true);
    // Seleccionar texto de la hoja y soltar en el fondo: el clic le llega al fondo (el ancestro común), y no cierra.
    backdrop.down(false);
    backdrop.up(true);
    expect(backdrop.click()).toBe(false);
    // Al revés, de fondo a la hoja: tampoco.
    backdrop.down(true);
    backdrop.up(false);
    expect(backdrop.click()).toBe(false);
    // Cada clic cuenta una vez: otro sin apretar de nuevo no cierra.
    backdrop.down(true);
    backdrop.up(true);
    backdrop.click();
    expect(backdrop.click()).toBe(false);
    // Un clic sin puntero (sin apretar nada), tampoco.
    expect(createBackdropClick().click()).toBe(false);
  });

  it("bookSignature: cambia con el envío, su estado, la semana o el idioma; no con lo demás de la reserva", () => {
    const base = bookSignature(week(), "it", "Evelyn", null);
    expect(bookSignature(week(), "it", "Evelyn", null)).toBe(base);
    for (const other of [
      bookSignature(week({ menu: menu({ sendId: "5e0d0000-0000-4000-8000-000000000009" }) }), "it", "Evelyn", null),
      bookSignature(week({ menu: menu({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00Z" }) }), "it", "Evelyn", null),
      bookSignature(week({ date: "2027-03-02" }), "it", "Evelyn", null),
      bookSignature(week({ done: true }), "it", "Evelyn", null),
      bookSignature(week(), "es", "Evelyn", null),
      bookSignature(week(), "it", "Evelyn", "quote-accept"),
    ]) {
      expect(other).not.toBe(base);
    }
  });
});
