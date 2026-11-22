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
 * Un navegador falso con lo que importa del historial (HTML, «session history»): cada entrada guarda su estado, su
 * scroll y su scrollRestoration (history.state y history.scrollRestoration son los de la entrada activa) y pushState
 * le copia el modo a la nueva. Ir atrás o adelante en el mismo documento dispara popstate, después restaura el scroll
 * de la entrada a la que llega si dice "auto" (el estándar; Chromium ya lo decide antes de popstate, comprobado en
 * vivo) y recién después hashchange, si cambió el fragmento. Irse del documento dispara pagehide (persisted: queda
 * guardado entero, en el bfcache).
 */
function fakeWindow(hash: string) {
  interface Entry {
    hash: string;
    state: unknown;
    mode: ScrollRestoration;
    scroll: number;
  }
  type Listener = (event: { persisted: boolean }) => void;
  const entries: Entry[] = [{ hash, state: null, mode: "auto", scroll: 0 }];
  let index = 0;
  let listeners = new Map<string, Listener[]>();
  const current = (): Entry => entries[index] as Entry;
  const hashOf = (url?: string | URL | null): string => new URL(String(url), "https://radici.test/").hash;
  const fire = (type: string, persisted = false): void => {
    for (const listener of listeners.get(type) ?? []) listener({ persisted });
  };
  const traverse = (delta: number): void => {
    const from = current();
    from.scroll = win.scrollY;
    index += delta;
    fire("popstate");
    if (current().mode === "auto") win.scrollY = current().scroll;
    if (current().hash !== from.hash) fire("hashchange");
  };
  /** Otra carga del documento: lo que sabía la de antes (sus listeners) se pierde; las entradas quedan como estaban. */
  const unload = (pagehide: boolean): void => {
    current().scroll = win.scrollY;
    if (pagehide) fire("pagehide");
    listeners = new Map();
  };
  const win = {
    scrollY: 0,
    location: {
      get hash(): string {
        return current().hash;
      },
    },
    history: {
      get state(): unknown {
        return current().state;
      },
      get scrollRestoration(): ScrollRestoration {
        return current().mode;
      },
      set scrollRestoration(mode: ScrollRestoration) {
        current().mode = mode;
      },
      pushState(data: unknown, _unused: string, url?: string | URL | null): void {
        current().scroll = win.scrollY;
        entries.splice(index + 1, entries.length, { hash: hashOf(url), state: data, mode: current().mode, scroll: win.scrollY });
        index += 1;
      },
      replaceState(data: unknown, _unused: string, url?: string | URL | null): void {
        current().state = data;
        if (url !== undefined && url !== null) current().hash = hashOf(url);
      },
    },
    addEventListener(type: string, listener: Listener): void {
      listeners.set(type, [...(listeners.get(type) ?? []), listener]);
    },
    back(): void {
      traverse(-1);
    },
    forward(): void {
      traverse(1);
    },
    /**
     * Recargar: pagehide y otra carga del documento en la misma entrada. Ir atrás o adelante sigue siendo del mismo
     * documento (popstate y hashchange), como en Chromium, comprobado en vivo.
     */
    reload(): void {
      unload(true);
    },
    /** El teléfono descartó la pestaña y la carga de nuevo: como recargar, pero sin pagehide. */
    discard(): void {
      unload(false);
    },
    /** Volver atrás cargando la página de nuevo (otro documento): corre su script y después restaura, sin popstate. */
    backToNewDocument(load: () => void): void {
      unload(true);
      index -= 1;
      load();
      if (current().mode === "auto") win.scrollY = current().scroll;
    },
    /** Ir a otra página y volver a esta guardada entera (bfcache): el mismo documento, con pagehide y pageshow. */
    awayAndBackFromCache(): void {
      fire("pagehide", true);
      fire("pageshow", true);
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

  it("mientras dura la carga, la entrada de la página queda en manual: ninguna vuelta desde el libro la mueve", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    const bookHistory = createBookHistory(win);
    bookHistory.push(bookUrl);
    // La del libro restaura como siempre (recargar con el libro abierto).
    expect(win.history.scrollRestoration).toBe("auto");
    win.back();
    expect(win.history.scrollRestoration).toBe("manual");
    // La próxima vez que se abre y se cierra, lo mismo.
    win.scrollY = 900;
    bookHistory.push(bookUrl);
    win.scrollY = 2400;
    win.back();
    expect([win.scrollY, win.history.scrollRestoration]).toEqual([2400, "manual"]);
  });

  it("abierto otra vez con «adelante», «Vai alla conferma» lo cierra volviendo atrás y confirmar queda a la vista", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    const bookHistory = createBookHistory(win);
    // «Sfoglia il menù» en 1600 y Esc (o el «atrás» del navegador): el foco vuelve al botón y se vuelve atrás.
    win.scrollY = 1600;
    bookHistory.push(bookUrl);
    win.back();
    expect([win.location.hash, win.scrollY]).toEqual([`#t=${TOKEN}`, 1600]);
    // «Adelante»: el libro se abre desde el fragmento de su entrada, y cerrarlo vuelve atrás.
    win.forward();
    expect(readBookSession(win.location.hash)).toBe(SESSION_1);
    expect(bookHistory.onBookEntry()).toBe(true);
    // «Vai alla conferma»: el foco baja la página hasta «Confermo il menù» y se vuelve atrás.
    win.scrollY = 3300;
    win.back();
    expect([win.location.hash, win.scrollY]).toEqual([`#t=${TOKEN}`, 3300]);
  });

  it("y Esc después de «adelante», con la página movida mientras estaba cerrado: «Sfoglia il menù» queda a la vista", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    const bookHistory = createBookHistory(win);
    win.scrollY = 1600;
    bookHistory.push(bookUrl);
    win.back();
    // Sube hasta 900 y «adelante».
    win.scrollY = 900;
    win.forward();
    expect(bookHistory.onBookEntry()).toBe(true);
    // Esc: el foco vuelve a «Sfoglia il menù» (en 1600: la página va hasta ahí si no estaba) y se vuelve atrás.
    win.scrollY = 1600;
    win.back();
    expect(win.scrollY).toBe(1600);
  });

  it("recargar o irse a otra página la deja en auto antes de la carga nueva (pagehide); guardada entera (bfcache), no", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    const bookHistory = createBookHistory(win);
    win.scrollY = 1600;
    bookHistory.push(bookUrl);
    win.back();
    // A otra página y de vuelta desde el bfcache: el mismo documento; «adelante» y «Vai alla conferma» siguen igual.
    win.awayAndBackFromCache();
    expect(win.history.scrollRestoration).toBe("manual");
    win.forward();
    expect(bookHistory.onBookEntry()).toBe(true);
    win.scrollY = 3300;
    win.back();
    expect(win.scrollY).toBe(3300);
    // Recargar: la entrada ya está en auto cuando empieza la carga nueva (antes de su script) y así queda.
    win.reload();
    expect(win.history.scrollRestoration).toBe("auto");
    createBookHistory(win);
    expect(win.history.scrollRestoration).toBe("auto");
  });

  it("si el teléfono descartó la pestaña (sin pagehide), la carga nueva deja la página en auto igual", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    createBookHistory(win).push(bookUrl);
    win.back();
    win.discard();
    expect(win.history.scrollRestoration).toBe("manual");
    createBookHistory(win);
    expect(win.history.scrollRestoration).toBe("auto");
  });

  it("la entrada que agrega el botón queda marcada, también para otra carga del documento; la del link del mensaje, no", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    const bookHistory = createBookHistory(win);
    expect(bookHistory.onBookEntry()).toBe(false);
    bookHistory.push(bookUrl);
    expect(bookHistory.onBookEntry()).toBe(true);
    // Se recarga con el libro abierto (o el teléfono descarta la pestaña): la carga nueva lo sabe por history.state.
    win.reload();
    expect(createBookHistory(win).onBookEntry()).toBe(true);
    win.back();
    expect(createBookHistory(win).onBookEntry()).toBe(false);
    // El link del mensaje abre la página con el libro en el fragmento: sin marca (cerrarlo solo saca libro).
    expect(createBookHistory(fakeWindow(bookFragment(TOKEN, SESSION_1))).onBookEntry()).toBe(false);
  });

  it("recargada con el libro abierto, cerrarlo vuelve atrás igual sin restaurar el scroll, también después de «adelante»", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    win.scrollY = 1600;
    createBookHistory(win).push(bookUrl);
    win.reload();
    // La página arranca arriba y el libro se abre desde el fragmento.
    win.scrollY = 0;
    const bookHistory = createBookHistory(win);
    expect(bookHistory.onBookEntry()).toBe(true);
    // Esc, la X o «Vai alla conferma» (o el «atrás» del navegador): el foco lleva la página al botón o a confirmar.
    win.scrollY = 3300;
    win.back();
    expect(win.location.hash).toBe(`#t=${TOKEN}`);
    expect([win.scrollY, win.history.scrollRestoration]).toEqual([3300, "manual"]);
    // «Adelante» y Esc: el foco vuelve a «Sfoglia il menù», en 1600.
    win.forward();
    expect(bookHistory.onBookEntry()).toBe(true);
    win.scrollY = 1600;
    win.back();
    expect(win.scrollY).toBe(1600);
    // Recargar la página la deja en auto.
    win.reload();
    expect(win.history.scrollRestoration).toBe("auto");
  });

  it("y si la vuelta carga la página de nuevo (otro documento), su entrada vuelve a restaurar desde que carga", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    win.scrollY = 1600;
    createBookHistory(win).push(bookUrl);
    win.reload();
    createBookHistory(win);
    win.backToNewDocument(() => createBookHistory(win));
    expect([win.scrollY, win.history.scrollRestoration]).toEqual([1600, "auto"]);
  });

  it("si esta carga empezó en la página (se recargó: restaura), «adelante» abre el libro y cerrarlo no vuelve atrás", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    win.scrollY = 1600;
    createBookHistory(win).push(bookUrl);
    win.back();
    // Recargar la deja en auto: volver a ella desde el libro restauraría su scroll sobre el foco.
    win.reload();
    const bookHistory = createBookHistory(win);
    win.forward();
    expect(bookHistory.onBookEntry()).toBe(false);
    // La entrada perdió la marca: recargar con el libro abierto, tampoco vuelve atrás.
    win.reload();
    expect(createBookHistory(win).onBookEntry()).toBe(false);
    // «Vai alla conferma»: el foco baja la página y libro sale del fragmento sin navegar (como el link del mensaje).
    win.scrollY = 3300;
    win.history.replaceState(win.history.state, "", `/prenotazione/#t=${TOKEN}`);
    expect([win.location.hash, win.scrollY]).toEqual([`#t=${TOKEN}`, 3300]);
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
