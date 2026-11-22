// El libro del menú (SPEC 5.8, «Libro del menú»): el menú que Evelyn mandó para una semana, como el libro de un
// restaurante, un plato por página. Acá está la lógica pura (sin DOM, con tests): las páginas, a cuál se puede ir,
// qué hace cada tecla, cómo se muestra cada página (y qué fotos se cargan ya), qué ofrece la última página, el
// fragmento de la URL (#t=<token>&libro=<sesión>) con su entrada del historial y el clic en el fondo. El token nunca
// sale del fragmento.
import {
  BOOK_FRAGMENT_PARAM,
  type ClientLinkWeek,
  type MenuContent,
} from "../../../../supabase/functions/_shared/client_link.ts";
import { isUuid } from "../../../../supabase/functions/_shared/public_request.ts";
import { focusId } from "../render.ts";
import { tokenFragment } from "../token.ts";

// ---------------------------------------------------------------------------
// Las páginas
// ---------------------------------------------------------------------------

/** Una página: la tapa, un plato (su lugar en el menú) o la última, con lo que se puede hacer después. */
export type BookPage = { kind: "cover" } | { kind: "dish"; dish: number } | { kind: "closing" };

/** La tapa, un plato por página en el orden del menú y la última página. */
export function bookPages(content: MenuContent): BookPage[] {
  const dishes: BookPage[] = content.dishes.map((_, dish) => ({ kind: "dish", dish }));
  return [{ kind: "cover" }, ...dishes, { kind: "closing" }];
}

export type Direction = "next" | "prev";

/** Una página que existe: de 0 a count - 1 (un número roto, la tapa). */
export function clampPage(page: number, count: number): number {
  if (count <= 0 || !Number.isFinite(page)) return 0;
  return Math.min(Math.max(Math.trunc(page), 0), count - 1);
}

/** Si se puede avanzar o retroceder desde esa página (las flechas, deshabilitadas en los bordes). */
export function canGo(page: number, count: number, direction: Direction): boolean {
  return direction === "next" ? page < count - 1 : page > 0;
}

/** La página siguiente o la anterior; en los bordes, la misma. */
export function step(page: number, count: number, direction: Direction): number {
  return clampPage(page + (direction === "next" ? 1 : -1), count);
}

/** Hacia dónde se da vuelta la hoja al ir de una página a otra (null: es la misma). */
export function directionOf(from: number, to: number): Direction | null {
  if (to === from) return null;
  return to > from ? "next" : "prev";
}

/** Lo que hace una tecla con el libro abierto: ir a una página, cerrarlo o nada (la tecla sigue su camino). */
export type KeyAction = { kind: "go"; page: number } | { kind: "close" } | null;

/**
 * ← y → pasan de página y Esc cierra; en los bordes, nada. Las demás teclas siguen su camino: ↑ ↓, Re Pág, Av Pág,
 * Inicio y Fin leen una página larga (su hoja tiene scroll), y Enter o espacio tocan el botón con el foco.
 */
export function keyAction(key: string, page: number, count: number): KeyAction {
  switch (key) {
    case "Escape":
      return { kind: "close" };
    case "ArrowRight":
      return canGo(page, count, "next") ? { kind: "go", page: page + 1 } : null;
    case "ArrowLeft":
      return canGo(page, count, "prev") ? { kind: "go", page: page - 1 } : null;
    default:
      return null;
  }
}

/**
 * Cómo se muestra una página con el libro en `current` (leaving: la que se va mientras da vuelta la hoja):
 * - current: la que se ve, la única que se lee y se toca;
 * - shown: está en la página (la actual, la siguiente, lista para la animación, y la que se va); las demás van con
 *   hidden, así sus fotos no se cargan hasta que se acercan;
 * - eager: su foto se carga ya (la actual y la siguiente); las demás, loading="lazy".
 */
export interface PagePresentation {
  current: boolean;
  shown: boolean;
  eager: boolean;
}

export function pagePresentation(index: number, current: number, leaving: number | null = null): PagePresentation {
  const isCurrent = index === current;
  const isNext = index === current + 1;
  return { current: isCurrent, shown: isCurrent || isNext || index === leaving, eager: isCurrent || isNext };
}

/** Con más páginas los puntos (24 px cada uno, para el dedo) no entran entre las flechas en 360 px: queda «2 / 14». */
export const MAX_DOTS = 9;

export function showDots(count: number): boolean {
  return count > 1 && count <= MAX_DOTS;
}

// ---------------------------------------------------------------------------
// La última página
// ---------------------------------------------------------------------------

/**
 * Qué ofrece la última página, según el último envío de la semana:
 * - answer: por confirmar; vuelve a la semana para confirmarlo o pedir cambios (los botones de siempre);
 * - quote: va con un presupuesto abierto; lleva a aceptarlo (donde esté en la página);
 * - confirmed / changes: ya contestó; solo vuelve a la reserva;
 * - done: la semana ya se cocinó.
 */
export type ClosingKind = "answer" | "quote" | "confirmed" | "changes" | "done";

/** quoteTarget: el id de donde se acepta el presupuesto, si el menú de esa semana va con uno abierto; si no, null. */
export function closingKind(week: ClientLinkWeek, quoteTarget: string | null): ClosingKind {
  const menu = week.menu;
  if (!menu || week.done) return "done";
  if (menu.state === "confirmed") return "confirmed";
  if (menu.state === "changesRequested") return "changes";
  return quoteTarget ? "quote" : "answer";
}

/**
 * A dónde lleva el botón de la última página después de cerrar el libro, en orden de preferencia (el primero que
 * esté en la página): a confirmar (o al mensaje de cambios, si lo estaba escribiendo), al presupuesto o al estado de
 * la semana. Son las acciones que ya están en la página: el libro no las repite.
 */
export function closingTargets(kind: ClosingKind, session: string, quoteTarget: string | null): string[] {
  const status = focusId({ kind: "status", session });
  switch (kind) {
    case "answer":
      return [focusId({ kind: "confirm", session }), focusId({ kind: "textarea", session }), status];
    case "quote":
      return quoteTarget ? [quoteTarget, status] : [status];
    default:
      return [status];
  }
}

// ---------------------------------------------------------------------------
// El fragmento de la URL
// ---------------------------------------------------------------------------

/** Un uuid al principio, sin otro carácter de uuid pegado detrás (tolera un punto o un paréntesis copiados). */
const SESSION_AT_START = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9a-fA-F-])/;

/** La semana del libro en el fragmento (#t=…&libro=<sesión>), en minúsculas, o null si no está o no es un uuid. */
export function readBookSession(hash: string): string | null {
  const value = new URLSearchParams(hash.replace(/^#/, "")).get(BOOK_FRAGMENT_PARAM);
  const session = value === null ? undefined : SESSION_AT_START.exec(value)?.[0];
  return session && isUuid(session) ? session.toLowerCase() : null;
}

/** El fragmento con el libro abierto: "#t=<token>&libro=<sesión>". Al cerrarlo vuelve a ser tokenFragment(token). */
export function bookFragment(token: string, session: string): string {
  return `${tokenFragment(token)}&${BOOK_FRAGMENT_PARAM}=${session.toLowerCase()}`;
}

/** Lo que usa createBookHistory de window (en los tests, uno falso). */
export interface HistoryWindow {
  readonly history: Pick<History, "state" | "scrollRestoration" | "pushState" | "replaceState">;
  readonly location: Pick<Location, "hash">;
  addEventListener(type: "popstate" | "hashchange", listener: () => void): void;
  addEventListener(type: "pagehide", listener: (event: { readonly persisted: boolean }) => void): void;
}

export interface BookHistory {
  /** Agrega la entrada del libro (el botón de una semana): cerrarlo vuelve atrás. */
  push(url: string): void;
  /**
   * El libro se abre desde el fragmento (se recargó con el libro abierto, el teléfono descartó la pestaña, o se volvió
   * a su entrada con «adelante»): si cerrarlo vuelve atrás, como si lo hubiera abierto el botón. Sí cuando la entrada
   * de ahora la agregó push (queda marcada en history.state, también para otra carga del documento), salvo que esta
   * carga haya empezado en la página: ahí su entrada quedó en "auto" (para restaurar su propio scroll) y volver a ella
   * lo restauraría encima del foco. Entonces la entrada del libro pierde la marca y cerrarlo solo saca libro del
   * fragmento, como el link del mensaje (queda otra entrada #t= repetida).
   */
  onBookEntry(): boolean;
}

/** La marca de la entrada del libro en history.state (el resto del estado sigue igual). */
const BOOK_STATE_KEY = "radiciLibro";

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null;

/**
 * La entrada del historial del libro abierto con el botón de una semana (cerrarlo vuelve atrás). Al volver, el
 * navegador restauraba el scroll guardado de la página (donde estaba el botón) y pisaba el que dejó el foco al
 * cerrar: confirmar, desde la última página, quedaba fuera de la pantalla. scrollRestoration vale por entrada, cuenta
 * el de la entrada a la que se vuelve y solo se cambia el de la entrada activa: el de la página va a "manual" antes
 * del pushState (que lo copia; la del libro vuelve a "auto", así recargar con el libro abierto restaura) y queda así
 * mientras dure esta carga del documento. Ninguna vuelta desde el libro mueve la página: tampoco la de un libro abierto
 * otra vez con «adelante» (si la página volviera a "auto" al cerrarlo, ese segundo cierre restauraría). Vuelve a
 * "auto" al irse del documento sin quedar guardado entero (pagehide sin bfcache: recargar, otra página) y al cargar
 * sin libro en el fragmento (si no hubo pagehide: el teléfono descartó la pestaña), así la carga nueva restaura su
 * scroll.
 */
export function createBookHistory(win: HistoryWindow): BookHistory {
  const onPage = (): boolean => readBookSession(win.location.hash) === null;
  const toAuto = (): void => {
    if (onPage() && win.history.scrollRestoration === "manual") win.history.scrollRestoration = "auto";
  };
  /**
   * El scrollRestoration de la entrada de la página: de la última sin libro en la que estuvo esta carga (cambia solo
   * mientras está activa). null si la carga empezó con el libro abierto: la dejó la carga que lo agregó, en "manual".
   */
  let pageMode: ScrollRestoration | null = null;
  const look = (): void => {
    if (onPage()) pageMode = win.history.scrollRestoration;
  };
  toAuto();
  look();
  win.addEventListener("popstate", look);
  win.addEventListener("hashchange", look);
  win.addEventListener("pagehide", (event) => {
    if (!event.persisted) toAuto();
  });
  return {
    push(url) {
      const state: unknown = win.history.state;
      win.history.scrollRestoration = "manual";
      pageMode = "manual";
      win.history.pushState({ ...(isRecord(state) ? state : {}), [BOOK_STATE_KEY]: true }, "", url);
      win.history.scrollRestoration = "auto";
    },
    onBookEntry() {
      const state: unknown = win.history.state;
      if (!isRecord(state) || state[BOOK_STATE_KEY] !== true) return false;
      if (pageMode !== "auto") return true;
      const unmarked: Record<string, unknown> = { ...state };
      delete unmarked[BOOK_STATE_KEY];
      win.history.replaceState(unmarked, "");
      return false;
    },
  };
}

// ---------------------------------------------------------------------------
// El foco dentro del libro y el clic en el fondo
// ---------------------------------------------------------------------------

/**
 * Tab y Mayús+Tab no salen del libro abierto: desde el último se vuelve al primero y al revés (también si el foco no
 * está en ninguno, por ejemplo en la página). Devuelve a cuál pasar, o null para que el navegador siga solo.
 */
export function trapFocus<T>(items: readonly T[], active: T | null, backwards: boolean): T | null {
  if (items.length === 0) return null;
  const index = active === null ? -1 : items.indexOf(active);
  if (backwards) return index <= 0 ? (items[items.length - 1] ?? null) : null;
  return index === -1 || index === items.length - 1 ? (items[0] ?? null) : null;
}

/**
 * El clic en el fondo oscuro (fuera del libro, en la computadora), que lo cierra: solo si se apretó y se soltó ahí,
 * como el cierre liviano de un <dialog>. Un arrastre que empieza en la hoja (al seleccionar texto) y termina en el
 * fondo también le manda el click al fondo, el ancestro común de los dos; y uno del fondo a la hoja, también: ninguno
 * cierra. Cada clic cuenta una vez.
 */
export interface BackdropClick {
  /** pointerdown: si fue en el fondo. */
  down(onBackdrop: boolean): void;
  /** pointerup: si fue en el fondo. */
  up(onBackdrop: boolean): void;
  /** Llegó un click al fondo: si cierra el libro. */
  click(): boolean;
}

export function createBackdropClick(): BackdropClick {
  let pressed = false;
  let released = false;
  return {
    down(onBackdrop) {
      pressed = onBackdrop;
      released = false;
    },
    up(onBackdrop) {
      released = onBackdrop;
    },
    click() {
      const closes = pressed && released;
      pressed = false;
      released = false;
      return closes;
    },
  };
}

/** Lo que cambia en el libro cuando cambia esto (la semana, su envío y su estado, el idioma): hay que pintarlo de nuevo. */
export function bookSignature(week: ClientLinkWeek, lang: string, chef: string, quoteTarget: string | null): string {
  const menu = week.menu;
  return JSON.stringify([lang, chef, quoteTarget, week.week, week.weeks, week.date, week.start, week.done, menu?.sendId, menu?.state]);
}
