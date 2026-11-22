import { describe, expect, it } from "vitest";
import { SESSION_1, TOKEN, content, menu, week } from "../fixtures.ts";
import { focusId } from "../render.ts";
import { readToken } from "../token.ts";
import {
  MAX_DOTS,
  REVEAL_QUIET_MS,
  REVEAL_SETTLE_MS,
  REVEAL_WATCH_MS,
  bookFragment,
  bookPages,
  bookSignature,
  canGo,
  clampPage,
  closingKind,
  closingTargets,
  createBackdropClick,
  createBookHistory,
  createFocusReveal,
  directionOf,
  keyAction,
  needsReveal,
  pagePresentation,
  readBookSession,
  showDots,
  step,
  trapFocus,
  type RevealTarget,
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

/** Un elemento de la página falsa: dónde empieza (px desde arriba del documento), su alto y qué hace Espacio en él. */
interface FakeElement {
  readonly top: number;
  readonly height: number;
  readonly kind: RevealTarget["kind"];
}

/**
 * El teléfono (390 × 844) y una página larga con la semana: el estado (un texto con el foco, tabindex=-1),
 * «Sfoglia il menù», el mensaje de cambios y confirmar.
 */
const VIEW = { width: 390, height: 844 } as const;
const PAGE_HEIGHT = 6000;
const PAGE = {
  status: { top: 1880, height: 85, kind: "other" },
  opener: { top: 2000, height: 48, kind: "button" },
  text: { top: 3400, height: 160, kind: "text" },
  confirm: { top: 3700, height: 48, kind: "button" },
} as const satisfies Record<string, FakeElement>;
type PageElement = keyof typeof PAGE;
/** Lo que deja cada uno centrado en la pantalla (scrollIntoView con block: "center"). */
const CENTERED = { opener: 1602, confirm: 3302 } as const;
/** Un cuadro cada 16 ms; una animación de scroll suave, 600 ms (lo que tarda en Chromium, comprobado en vivo). */
const FRAME_MS = 16;
const SMOOTH_MS = 600;

interface FakeEvent {
  readonly persisted: boolean;
  readonly key: string;
  preventDefault(): void;
}

/**
 * Un navegador falso con lo que importa del historial (HTML, «session history»): cada entrada guarda su estado, su
 * scroll y su scrollRestoration (history.state y history.scrollRestoration son los de la entrada activa) y pushState
 * le copia el modo a la nueva. Ir atrás o adelante en el mismo documento dispara popstate, después restaura el scroll
 * de la entrada a la que llega si dice "auto" (el estándar; Chromium ya lo decide antes de popstate, comprobado en
 * vivo) y recién después hashchange, si cambió el fragmento. Irse del documento dispara pagehide (persisted: queda
 * guardado entero, en el bfcache).
 *
 * Y lo que usa createFocusReveal, con el tiempo en las manos del test (advance): un cuadro cada 16 ms avanza la
 * animación de scroll, despacha scroll si la página se movió y scrollend en el primer cuadro quieto después (sin él
 * con scrollend: false, como Safari; con "lost", el navegador lo tiene pero no llega), y corre los
 * requestAnimationFrame; los setTimeout vencen en orden. Con smooth, la restauración del historial se anima (Chromium
 * con scroll-behavior: smooth, comprobado en vivo) y sigue aunque cambie la entrada; un scroll instantáneo o uno de la
 * persona la cortan. restoreDelayMs: la restauración empieza tarde (la máquina cargada). focus() dice qué tiene el
 * foco (un elemento de la página, "book" si está adentro del libro, o nada); target() es lo que ve createFocusReveal.
 */
function fakeWindow(
  hash: string,
  options: { smooth?: boolean; smoothMs?: number; scrollend?: boolean | "lost"; restoreDelayMs?: number } = {},
) {
  interface Entry {
    hash: string;
    state: unknown;
    mode: ScrollRestoration;
    scroll: number;
  }
  interface Callback {
    id: number;
    at: number;
    run: () => void;
  }
  type Listener = (event: FakeEvent) => void;
  const entries: Entry[] = [{ hash, state: null, mode: "auto", scroll: 0 }];
  let index = 0;
  let listeners = new Map<string, Listener[]>();
  let now = 0;
  let ids = 0;
  let timers: Callback[] = [];
  let frames: Callback[] = [];
  let nextFrame = FRAME_MS;
  /** La página se movió desde el último cuadro (scroll en el próximo) y un scroll que todavía no terminó (scrollend). */
  let moved = false;
  let scrolling = false;
  let animation: { from: number; to: number; start: number } | null = null;
  let pendingRestore: { at: number; y: number } | null = null;
  let focused: PageElement | "book" | null = null;
  const smoothMs = options.smoothMs ?? SMOOTH_MS;
  const current = (): Entry => entries[index] as Entry;
  const hashOf = (url?: string | URL | null): string => new URL(String(url), "https://radici.test/").hash;
  const fire = (type: string, init: Partial<FakeEvent> = {}): void => {
    const event: FakeEvent = { persisted: false, key: "", preventDefault: () => {}, ...init };
    for (const listener of listeners.get(type) ?? []) listener(event);
  };
  const scrollTo = (y: number): void => {
    const next = Math.min(Math.max(Math.round(y), 0), PAGE_HEIGHT - VIEW.height);
    if (next === win.scrollY) return;
    win.scrollY = next;
    moved = true;
  };
  /** La restauración del scroll de una entrada en "auto": con smooth, animada; con restoreDelayMs, más tarde. */
  const startRestore = (y: number): void => {
    if (options.smooth) animation = { from: win.scrollY, to: y, start: now };
    else scrollTo(y);
  };
  const restore = (y: number): void => {
    if (options.restoreDelayMs) pendingRestore = { at: now + options.restoreDelayMs, y };
    else startRestore(y);
  };
  const frame = (): void => {
    if (pendingRestore && now >= pendingRestore.at) {
      startRestore(pendingRestore.y);
      pendingRestore = null;
    }
    if (animation) {
      const progress = Math.min((now - animation.start) / smoothMs, 1);
      scrollTo(animation.from + (animation.to - animation.from) * progress);
      if (progress === 1) animation = null;
    }
    if (moved) {
      moved = false;
      scrolling = true;
      fire("scroll");
    } else if (scrolling && !animation) {
      scrolling = false;
      if (options.scrollend === undefined || options.scrollend === true) fire("scrollend");
    }
    const due = frames;
    frames = [];
    for (const callback of due) callback.run();
  };
  const traverse = (delta: number): void => {
    const from = current();
    from.scroll = win.scrollY;
    index += delta;
    fire("popstate");
    if (current().mode === "auto") restore(current().scroll);
    if (current().hash !== from.hash) fire("hashchange");
  };
  /**
   * Otra carga del documento: lo que sabía la de antes (sus listeners, sus timers, el foco) se pierde; las entradas
   * quedan como estaban.
   */
  const unload = (pagehide: boolean): void => {
    current().scroll = win.scrollY;
    if (pagehide) fire("pagehide");
    listeners = new Map();
    timers = [];
    frames = [];
    animation = null;
    pendingRestore = null;
    moved = false;
    scrolling = false;
    focused = null;
  };
  const seen = (): boolean => {
    if (focused === null || focused === "book") return false;
    const top = PAGE[focused].top - win.scrollY;
    return top >= 0 && top + PAGE[focused].height <= VIEW.height;
  };
  const win = {
    scrollY: 0,
    innerWidth: VIEW.width,
    innerHeight: VIEW.height,
    ...(options.scrollend === false ? {} : { onscrollend: null }),
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
    requestAnimationFrame(run: () => void): number {
      ids += 1;
      frames.push({ id: ids, at: 0, run });
      return ids;
    },
    setTimeout(run: () => void, ms: number): number {
      ids += 1;
      timers.push({ id: ids, at: now + ms, run });
      return ids;
    },
    clearTimeout(id: number): void {
      timers = timers.filter((timer) => timer.id !== id);
    },
    /** Pasa el tiempo: los cuadros (cada 16 ms) y los setTimeout que vencen, en orden. */
    advance(ms: number): void {
      const end = now + ms;
      for (;;) {
        const timer = timers.reduce<Callback | null>((first, item) => (first === null || item.at < first.at ? item : first), null);
        if (timer !== null && timer.at <= nextFrame && timer.at <= end) {
          now = timer.at;
          timers = timers.filter((item) => item !== timer);
          timer.run();
        } else if (nextFrame <= end) {
          now = nextFrame;
          nextFrame += FRAME_MS;
          frame();
        } else {
          break;
        }
      }
      now = end;
    },
    /** Lo que tiene el foco (close() de view.ts lo mueve sin el scroll del foco). */
    focus(target: PageElement | "book" | null): void {
      focused = target;
    },
    focused: (): PageElement | "book" | null => focused,
    /** Lo que ve createFocusReveal: lo que tiene el foco en la reserva (con el libro abierto, nada). */
    target(): RevealTarget | null {
      if (focused === null || focused === "book") return null;
      const el = PAGE[focused];
      return {
        rect: () => ({ top: el.top - win.scrollY, bottom: el.top + el.height - win.scrollY, left: 16, right: VIEW.width - 16 }),
        reveal: () => {
          animation = null;
          scrollTo(el.top + el.height / 2 - VIEW.height / 2);
        },
        kind: el.kind,
      };
    },
    /** Si lo que tiene el foco se ve entero. */
    seen,
    /** La rueda del mouse (o el dedo): la persona mueve la página; corta una animación. */
    wheel(dy: number): void {
      fire("wheel");
      animation = null;
      scrollTo(win.scrollY + dy);
    },
    /** Una tecla: si alguien la frenó y, si no, a qué botón tocó (Espacio o Enter) y si se veía. */
    press(key: string): { prevented: boolean; clicked: PageElement | null; seen: boolean } {
      let prevented = false;
      fire("keydown", {
        key,
        preventDefault: () => {
          prevented = true;
        },
      });
      const el = focused !== null && focused !== "book" ? focused : null;
      const clicked = !prevented && el !== null && PAGE[el].kind === "button" && (key === " " || key === "Enter") ? el : null;
      return { prevented, clicked, seen: seen() };
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
      if (current().mode === "auto") restore(current().scroll);
    },
    /** Ir a otra página y volver a esta guardada entera (bfcache): el mismo documento, con pagehide y pageshow. */
    awayAndBackFromCache(): void {
      fire("pagehide", { persisted: true });
      fire("pageshow", { persisted: true });
    },
  };
  return win;
}

type FakeWindow = ReturnType<typeof fakeWindow>;

const bookUrl = `/prenotazione/${bookFragment(TOKEN, SESSION_1)}`;

/**
 * El primer script de prenotazione.ts en el navegador falso: el historial del libro y el foco a la vista, antes de
 * pedir los textos y la reserva. close() hace lo de view.ts al cerrar el libro: el foco a su destino (sin el scroll
 * del foco) y bookClosed(); después vuelve atrás (si lo abrió el botón: history.back() es asincrónico, llega
 * después) o saca libro del fragmento sin navegar.
 */
function startPage(win: FakeWindow) {
  const bookHistory = createBookHistory(win);
  const reveal = createFocusReveal(win, () => win.target());
  return {
    bookHistory,
    reveal,
    close(to: PageElement, back: boolean): void {
      win.focus(to);
      reveal.bookClosed();
      if (back) win.back();
      else win.history.replaceState(win.history.state, "", `/prenotazione/#t=${TOKEN}`);
    },
  };
}

describe("la entrada del historial del libro (abierto con el botón de la semana)", () => {
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

  it("popstate sin hashchange (entre dos entradas #t= iguales) también le dice en qué entrada está: cerrarlo vuelve atrás", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    // «Sfoglia il menù», Esc y recargar en la página (su entrada queda en "auto").
    let page = startPage(win);
    win.scrollY = 1600;
    page.bookHistory.push(bookUrl);
    win.back();
    win.reload();
    // «Adelante»: la entrada del libro pierde la marca y «Vai alla conferma» la deja como una #t= repetida.
    page = startPage(win);
    win.forward();
    expect(page.bookHistory.onBookEntry()).toBe(false);
    win.history.replaceState(win.history.state, "", `/prenotazione/#t=${TOKEN}`);
    // Desde la repetida, «Sfoglia il menù» (queda en "manual") y Esc; «atrás» a la primera (en "auto") y recargar.
    page.bookHistory.push(bookUrl);
    win.back();
    win.back();
    win.reload();
    page = startPage(win);
    // «Adelante» a la repetida (el mismo fragmento: solo popstate, sin hashchange), que está en "manual", y otra vez al
    // libro: cerrarlo vuelve atrás, porque volver a la repetida no restaura su scroll. Sin escuchar popstate, la
    // carga creía seguir en la primera ("auto") y cerrarlo dejaba otra entrada repetida.
    win.forward();
    expect(win.history.scrollRestoration).toBe("manual");
    win.forward();
    expect(page.bookHistory.onBookEntry()).toBe(true);
    win.scrollY = 3300;
    win.back();
    expect([win.location.hash, win.scrollY]).toEqual([`#t=${TOKEN}`, 3300]);
  });
});

describe("needsReveal: si lo que tiene el foco no se ve entero en la pantalla", () => {
  const phone = { width: 390, height: 844 };
  const box = (top: number, height = 48, left = 16, right = 374) => ({ top, bottom: top + height, left, right });

  it("entero en la pantalla, no; afuera (abajo o arriba) o cortado por un borde, sí", () => {
    expect([needsReveal(box(398), phone), needsReveal(box(0), phone), needsReveal(box(844 - 48), phone)]).toEqual([false, false, false]);
    // Lo que dejaba la restauración del navegador encima del foco: «Confermo il menù» abajo o arriba, afuera.
    expect(needsReveal(box(2144), phone)).toBe(true);
    expect(needsReveal(box(-1348), phone)).toBe(true);
    // Cortado: se ve una parte.
    expect(needsReveal(box(820), phone)).toBe(true);
    expect(needsReveal(box(-20), phone)).toBe(true);
    // A los costados tampoco se ve entero.
    expect(needsReveal(box(398, 48, -30, 300), phone)).toBe(true);
    expect(needsReveal(box(398, 48, 100, 420), phone)).toBe(true);
  });

  it("tolera un píxel en cada borde (getBoundingClientRect da fracciones)", () => {
    expect(needsReveal(box(-0.6), phone)).toBe(false);
    expect(needsReveal(box(844 - 48 + 0.8), phone)).toBe(false);
    expect(needsReveal(box(-1.5), phone)).toBe(true);
    expect(needsReveal(box(844 - 48 + 1.5), phone)).toBe(true);
  });

  it("más grande que la pantalla, basta con que la cubra; sin caja (display: none) o sin pantalla, no", () => {
    expect(needsReveal(box(-100, 1200), phone)).toBe(false);
    expect(needsReveal(box(300, 1200), phone)).toBe(true);
    expect(needsReveal(box(-2000, 1200), phone)).toBe(true);
    expect(needsReveal({ top: 0, bottom: 0, left: 0, right: 0 }, phone)).toBe(false);
    expect(needsReveal(box(2144), { width: 0, height: 0 })).toBe(false);
  });
});

describe("el foco a la vista cuando la página se queda quieta (createFocusReveal)", () => {
  /**
   * Dos entradas #t= iguales en "auto" (la repetida que deja cerrar el libro sin volver atrás) y el foco en
   * «Confermo il menù», a la vista: «atrás» vuelve a la primera, que restaura su scroll (arriba).
   */
  function duplicateEntry(options: Parameters<typeof fakeWindow>[1] = {}) {
    const win = fakeWindow(`#t=${TOKEN}`, options);
    const page = startPage(win);
    win.history.pushState(win.history.state, "", `/prenotazione/#t=${TOKEN}`);
    win.scrollY = CENTERED.confirm;
    win.focus("confirm");
    return { win, page };
  }

  it("M1: recargada en la página con el libro adelante, «Vai alla conferma» y después «atrás»: confirmar vuelve a la vista", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    // Primera carga: «Sfoglia il menù» en el medio de la página y Esc (vuelve atrás).
    const first = startPage(win);
    win.scrollY = 1600;
    first.bookHistory.push(bookUrl);
    win.focus("book");
    first.close("opener", true);
    win.advance(1000);
    // Sube hasta arriba y recarga: la entrada de la página queda en "auto" (restaura su propio scroll).
    win.scrollY = 0;
    win.reload();
    const page = startPage(win);
    // «Adelante»: el libro se abre desde su entrada, que pierde la marca (volver atrás restauraría el scroll).
    win.forward();
    win.focus("book");
    expect(page.bookHistory.onBookEntry()).toBe(false);
    // «Vai alla conferma»: libro sale del fragmento sin navegar (queda una entrada #t= repetida, en "auto") y el foco
    // va a «Confermo il menù», a la vista.
    page.close("confirm", false);
    win.advance(1000);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
    // «Atrás» del navegador: de la repetida a la de la página (el mismo fragmento: solo popstate), que restaura su
    // scroll (arriba) y deja confirmar con el foco fuera de la pantalla…
    win.back();
    expect([win.scrollY, win.seen()]).toEqual([0, false]);
    // …hasta que la página se queda quieta: ahí vuelve a la vista, y Espacio lo confirma viéndolo.
    win.advance(100);
    expect([win.scrollY, win.seen(), win.focused()]).toEqual([CENTERED.confirm, true, "confirm"]);
    expect(win.press(" ")).toEqual({ prevented: false, clicked: "confirm", seen: true });
  });

  it("M2: «adelante» antes de que arranque la página; con el historial creado al cargar, cerrarlo no vuelve atrás", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    const first = startPage(win);
    win.scrollY = 1600;
    first.bookHistory.push(bookUrl);
    first.close("opener", true);
    win.advance(1000);
    win.scrollY = 0;
    win.reload();
    // El primer script de la carga nueva, en la entrada de la página (en "auto")…
    const page = startPage(win);
    // …y «adelante» mientras se piden los textos y la reserva (antes de attachBookView).
    win.forward();
    win.advance(300);
    // Llega la reserva y el libro se abre desde el fragmento: createBookHistory ya vio la entrada de la página en
    // "auto", así que cerrarlo no vuelve atrás (volver restauraría su scroll encima del foco).
    win.focus("book");
    expect(page.bookHistory.onBookEntry()).toBe(false);
    page.close("confirm", false);
    win.advance(1000);
    expect([win.scrollY, win.seen(), win.focused()]).toEqual([CENTERED.confirm, true, "confirm"]);
  });

  it("M2: si el historial se creara recién después de «adelante», cerrarlo volvería atrás y restauraría: el foco vuelve igual", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    const first = startPage(win);
    win.scrollY = 1600;
    first.bookHistory.push(bookUrl);
    first.close("opener", true);
    win.advance(1000);
    win.scrollY = 0;
    win.reload();
    // Al cargar, solo el foco a la vista; el historial, tarde (como antes: en start(), después de los fetch).
    const reveal = createFocusReveal(win, () => win.target());
    win.forward();
    win.advance(300);
    const late = createBookHistory(win);
    win.focus("book");
    // No vio la entrada de la página: cree que volver atrás no la mueve.
    expect(late.onBookEntry()).toBe(true);
    // «Vai alla conferma»: confirmar a la vista y atrás, a la página en "auto", que restaura su scroll encima…
    win.focus("confirm");
    reveal.bookClosed();
    win.back();
    expect([win.scrollY, win.seen()]).toEqual([0, false]);
    // …y cuando se queda quieta, confirmar vuelve a la vista.
    win.advance(100);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
  });

  it("L1: con scroll suave, la restauración que sigue animándose después de cerrar no deja el foco afuera", () => {
    const win = fakeWindow(`#t=${TOKEN}`, { smooth: true });
    const page = startPage(win);
    // «Sfoglia il menù» y «Vai alla conferma»: confirmar a la vista; la entrada del libro guarda ese scroll al volver.
    win.scrollY = 1600;
    page.bookHistory.push(bookUrl);
    win.focus("book");
    page.close("confirm", true);
    win.advance(1000);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
    // Sube hasta «Sfoglia il menù» y «adelante»: el libro se abre y, detrás, el navegador anima la restauración del
    // scroll de su entrada (hacia confirmar).
    win.wheel(CENTERED.opener - CENTERED.confirm);
    win.advance(1000);
    win.forward();
    win.focus("book");
    expect(page.bookHistory.onBookEntry()).toBe(true);
    win.advance(48);
    // Esc enseguida: el foco vuelve a «Sfoglia il menù», todavía a la vista, y se vuelve atrás (a una entrada en
    // "manual", que no restaura); la animación sigue y lo deja afuera…
    page.close("opener", true);
    expect(win.seen()).toBe(true);
    win.advance(300);
    expect(win.seen()).toBe(false);
    // …hasta que termina: ahí vuelve a la vista, sin cortarla antes.
    win.advance(500);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.opener, true]);
  });

  it("una animación más larga que REVEAL_SETTLE_MS: espera a que termine, no la corta a la mitad", () => {
    const { win } = duplicateEntry({ smooth: true, smoothMs: 1200 });
    win.back();
    win.advance(REVEAL_SETTLE_MS + 100);
    expect(win.seen()).toBe(false);
    expect(win.scrollY).toBeGreaterThan(0);
    win.advance(600);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
  });

  it("sin scrollend (Safari): el scroll terminó cuando pasan REVEAL_QUIET_MS sin otro", () => {
    const { win } = duplicateEntry({ scrollend: false });
    win.back();
    win.advance(REVEAL_QUIET_MS - 20);
    expect(win.seen()).toBe(false);
    win.advance(80);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
  });

  it("con scrollend, apenas termina la restauración (dos cuadros), sin esperar REVEAL_QUIET_MS", () => {
    const { win } = duplicateEntry();
    win.back();
    expect(win.seen()).toBe(false);
    win.advance(3 * FRAME_MS);
    expect(win.seen()).toBe(true);
  });

  it("si nada se mueve, se mira igual a los REVEAL_SETTLE_MS del último aviso", () => {
    const win = fakeWindow(`#t=${TOKEN}`);
    startPage(win);
    // Dos entradas #t= en "manual" (volver no restaura) y el foco en confirmar, que la persona dejó afuera.
    win.history.scrollRestoration = "manual";
    win.history.pushState(win.history.state, "", `/prenotazione/#t=${TOKEN}`);
    win.focus("confirm");
    win.back();
    win.advance(REVEAL_SETTLE_MS - 50);
    expect([win.scrollY, win.seen()]).toEqual([0, false]);
    win.advance(100);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
  });

  it("si la persona mueve la página mientras se espera (rueda, dedo, la barra, un clic, teclas), no se la lleva de vuelta", () => {
    const { win } = duplicateEntry();
    win.back();
    win.wheel(400);
    win.advance(2000);
    expect([win.scrollY, win.seen()]).toEqual([400, false]);
    // Las teclas que mueven la página, lo mismo: ni la traen a la vista ni la frenan.
    const keys = duplicateEntry().win;
    keys.back();
    expect(keys.press("PageDown")).toEqual({ prevented: false, clicked: null, seen: false });
    keys.advance(2000);
    expect(keys.seen()).toBe(false);
  });

  it("Espacio o Enter mientras la página se mueve no tocan un botón que no se ve: primero lo traen a la vista", () => {
    const { win } = duplicateEntry();
    win.back();
    expect(win.press(" ")).toEqual({ prevented: true, clicked: null, seen: true });
    // Ahora sí se ve: Espacio lo confirma.
    expect(win.press(" ")).toEqual({ prevented: false, clicked: "confirm", seen: true });
    // Enter, igual.
    const enter = duplicateEntry().win;
    enter.back();
    expect(enter.press("Enter")).toEqual({ prevented: true, clicked: null, seen: true });
    // En el mensaje de cambios (Espacio escribe), lo trae a la vista sin frenar la tecla.
    const text = duplicateEntry().win;
    text.focus("text");
    text.back();
    expect(text.press(" ")).toEqual({ prevented: false, clicked: null, seen: true });
  });

  it("Espacio sobre un botón con la página todavía moviéndose (aunque se vea) no lo toca: lo deja quieto a la vista", () => {
    // La entrada de antes restaura su scroll con una animación (scroll suave) y Espacio llega apenas empieza, con
    // confirmar todavía a la vista. En vivo (390 × 844), la tecla se decidía en keydown, el clic salía en keyup con el
    // botón ya yéndose de la pantalla y el guardia dejaba de esperar: el foco quedaba afuera.
    const { win } = duplicateEntry({ smooth: true });
    win.back();
    win.advance(2 * FRAME_MS);
    expect(win.seen()).toBe(true);
    expect(win.press(" ")).toEqual({ prevented: true, clicked: null, seen: true });
    // Quedó quieto (la animación se cortó) y a la vista; con la página quieta, Espacio lo toca.
    win.advance(1000);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
    expect(win.press(" ")).toEqual({ prevented: false, clicked: "confirm", seen: true });
  });

  it("Espacio en el mensaje de cambios escribe y se sigue esperando; sobre un texto con el foco mueve la página y deja de esperar", () => {
    const text = duplicateEntry({ smooth: true }).win;
    text.focus("text");
    text.back();
    text.advance(2 * FRAME_MS);
    expect(text.press(" ")).toEqual({ prevented: false, clicked: null, seen: true });
    text.advance(1000);
    expect(text.seen()).toBe(true);
    // El estado de la semana (tabindex=-1, afuera): Espacio es scroll de la página, como PageDown.
    const other = duplicateEntry({ smooth: true }).win;
    other.focus("status");
    other.back();
    expect(other.press(" ")).toEqual({ prevented: false, clicked: null, seen: false });
    other.advance(1000);
    expect([other.scrollY, other.seen()]).toEqual([0, false]);
  });

  it("con el foco adentro del libro o sin foco, no mueve nada", () => {
    for (const focus of ["book", null] as const) {
      const { win } = duplicateEntry();
      win.focus(focus);
      win.back();
      win.advance(2000);
      expect(win.scrollY).toBe(0);
    }
  });

  it("si un scroll no termina nunca, a lo sumo REVEAL_WATCH_MS después del último aviso", () => {
    const { win } = duplicateEntry({ smooth: true, smoothMs: 10_000 });
    win.back();
    win.advance(REVEAL_WATCH_MS - 100);
    expect(win.seen()).toBe(false);
    win.advance(200);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
  });

  it("una restauración que el navegador empieza tarde (después de REVEAL_SETTLE_MS, con la máquina cargada) también", () => {
    // Pasó en vivo con cuatro pestañas a la vez (390 × 844, scroll suave): el guardia miraba a los 700 ms, todavía con
    // confirmar a la vista, dejaba de esperar y la restauración lo sacaba de la pantalla después.
    const { win } = duplicateEntry({ smooth: true, restoreDelayMs: 1200 });
    win.back();
    win.advance(REVEAL_SETTLE_MS + 100);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
    win.advance(800);
    expect(win.seen()).toBe(false);
    win.advance(600);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
    // Espacio en ese rato no habría tocado el botón: la ventana sigue abierta hasta REVEAL_WATCH_MS.
    const space = duplicateEntry({ smooth: true, restoreDelayMs: 1200 }).win;
    space.back();
    space.advance(1500);
    expect(space.press(" ")).toEqual({ prevented: true, clicked: null, seen: true });
  });

  it("si scrollend no llega (lo tiene el navegador, pero se pierde), basta con REVEAL_QUIET_MS sin scroll", () => {
    // Pasó en vivo: una animación que siguió después de una vuelta del historial terminó sin scrollend, y el guardia
    // esperaba hasta el tope.
    const { win } = duplicateEntry({ smooth: true, scrollend: "lost" });
    win.back();
    win.advance(SMOOTH_MS);
    expect(win.seen()).toBe(false);
    win.advance(REVEAL_QUIET_MS + 3 * FRAME_MS);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
  });

  it("cerrar el libro lo trae a la vista ya mismo, sin animación (también con scroll suave)", () => {
    const win = fakeWindow(`#t=${TOKEN}`, { smooth: true });
    const page = startPage(win);
    win.scrollY = 1600;
    page.bookHistory.push(bookUrl);
    win.focus("book");
    page.close("confirm", true);
    expect([win.scrollY, win.seen()]).toEqual([CENTERED.confirm, true]);
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
