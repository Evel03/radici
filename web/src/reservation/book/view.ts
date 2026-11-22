// El libro del menú en la página /prenotazione/: lo abre y lo cierra, pasa de página (flechas, puntos, teclado y
// gestos) y lleva el fragmento de la URL (#t=<token>&libro=<sesión>). La lógica está en state.ts, gestures.ts y
// render.ts (puras, con tests); acá solo el DOM.
// - Un diálogo modal: el resto de la página queda inert (y aria-hidden), Tab no sale del libro y, al cerrarlo, el foco
//   vuelve al botón que lo abrió (o a donde lleve la última página: confirmar, el presupuesto o la semana).
// - Abierto desde el botón de una semana, agrega una entrada al historial: «atrás» lo cierra, como se espera en el
//   teléfono. Abierto desde el link del mensaje, cerrarlo solo saca libro del fragmento. El token nunca sale de ahí.
// - Pasar de página da vuelta la hoja (book.css), salvo con prefers-reduced-motion: ahí cambia sin animación.
// - Las fotos: la de la página actual y la de la siguiente se cargan ya; las demás páginas van con hidden (sus fotos
//   esperan a que se acerquen). Una foto que no carga deja la lámina con la inicial del plato.
import type { ClientLinkWeek, MenuContent } from "../../../../supabase/functions/_shared/client_link.ts";
import { isLang, langHref, type I18n } from "../../i18n/core.ts";
import { mount } from "../../lib/vdom.ts";
import type { PageState } from "../controller.ts";
import { bookButtonId, focusId } from "../render.ts";
import { tokenFragment } from "../token.ts";
import { bindSwipe, dragOffset } from "./gestures.ts";
import {
  BOOK_COUNT_ID,
  BOOK_ID,
  BOOK_LIVE_ID,
  BOOK_NEXT_ID,
  BOOK_PREV_ID,
  BOOK_VIEWPORT_ID,
  bookDotId,
  bookPageId,
  bookTree,
  counterText,
  pageLabel,
  pageName,
} from "./render.ts";
import {
  bookFragment,
  bookPages,
  bookSignature,
  canGo,
  clampPage,
  closingKind,
  closingTargets,
  directionOf,
  keyAction,
  pagePresentation,
  readBookSession,
  step,
  trapFocus,
  type BookPage,
  type Direction,
} from "./state.ts";

export interface BookViewDeps {
  /** El token del fragmento (readToken), o null: sin token no hay libro. */
  token: string | null;
  /** La marca del logotipo (config.brandName). */
  brand: string;
  i18n(): I18n;
  /** El estado de la reserva (controller.ts). */
  state(): PageState;
  /** Avisa cada vez que cambia la reserva (Reservation.subscribe). */
  onStateChange(listener: () => void): void;
  /** Avisa cada vez que cambia el idioma (Shell.onLanguageChange). */
  onLanguageChange(listener: () => void): void;
  /**
   * El id del botón con que se acepta el presupuesto, si el menú de esa semana va con uno abierto: la última página
   * lleva ahí. Sin esto (o con null), la última página vuelve a la semana.
   */
  quoteTarget?: (week: ClientLinkWeek) => string | null;
}

export interface BookView {
  /** Abre el libro de una semana desde su botón (openerId: el id del botón, para devolverle el foco). */
  open(session: string, openerId: string | null): void;
}

/** Si la animación no avisa que terminó (una pestaña en segundo plano), se termina igual. */
const TURN_FALLBACK_MS = 900;

interface Inerted {
  el: Element;
  ariaHidden: string | null;
  inert: boolean;
}

interface OpenBook {
  session: string;
  week: ClientLinkWeek;
  content: MenuContent;
  pages: BookPage[];
  page: number;
  signature: string;
  openerId: string | null;
  /** Se abrió con una entrada nueva en el historial (cerrarlo vuelve atrás). */
  pushed: boolean;
  background: Inerted[];
  unbindSwipe: () => void;
  /** Termina ya la vuelta de hoja en curso, si hay una. */
  finishTurn: (() => void) | null;
}

/** Crea el libro de la página y lo conecta con la reserva, el idioma y el historial. */
export function attachBookView(deps: BookViewDeps): BookView {
  const doc = document;
  const win = window;
  /** Fotos que no cargaron (no se vuelven a pedir mientras la página está abierta). */
  const failedPhotos = new Set<string>();
  let root: HTMLElement | null = null;
  let book: OpenBook | null = null;

  const byId = (id: string): HTMLElement | null => doc.getElementById(id);
  /** La hoja de una página (la diapositiva, con su scroll): la que recibe el foco. */
  const sheetOf = (index: number): HTMLElement | null => byId(bookPageId(index))?.querySelector<HTMLElement>(".book__sheet") ?? null;
  /**
   * El foco que mueve el libro (al abrirlo, al pasar de página): sin el contorno de teclado sobre toda la página
   * (focusVisible: false; un navegador que no lo conoce lo ignora). Con Tab, la hoja muestra su contorno.
   */
  const quietFocus = { preventScroll: true, focusVisible: false };
  const focusSheet = (index: number): void => sheetOf(index)?.focus(quietFocus);
  const reducedMotion = (): boolean => typeof win.matchMedia === "function" && win.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const urlWith = (fragment: string): string => `${win.location.pathname}${win.location.search}${fragment}`;
  const chef = (): string => {
    const state = deps.state();
    return state.kind === "ready" ? state.view.chefName : "Evelyn";
  };
  const quoteTargetOf = (week: ClientLinkWeek): string | null => deps.quoteTarget?.(week) ?? null;

  /** La semana con su envío para mostrar, o null (no está, o su foto no se puede leer). */
  const findWeek = (session: string): { week: ClientLinkWeek; content: MenuContent } | null => {
    const state = deps.state();
    if (state.kind !== "ready") return null;
    const week = state.view.weeks.find((item) => item.sessionId === session);
    const content = week?.menu?.content ?? null;
    return week && content ? { week, content } : null;
  };

  /** Los links de idioma llevan el fragmento de ahora (como los pone shell.ts), sin libro si se cerró. */
  const syncLangLinks = (): void => {
    for (const link of doc.querySelectorAll<HTMLAnchorElement>("a[data-lang][href]")) {
      const code = link.dataset["lang"];
      if (isLang(code)) link.setAttribute("href", langHref(code, win.location.hash));
    }
  };

  const inertBackground = (): Inerted[] => {
    const out: Inerted[] = [];
    for (const el of Array.from(doc.body.children)) {
      if (el === root) continue;
      out.push({ el, ariaHidden: el.getAttribute("aria-hidden"), inert: el.hasAttribute("inert") });
      el.setAttribute("aria-hidden", "true");
      el.setAttribute("inert", "");
    }
    return out;
  };

  const restoreBackground = (items: readonly Inerted[]): void => {
    for (const item of items) {
      if (item.ariaHidden === null) item.el.removeAttribute("aria-hidden");
      else item.el.setAttribute("aria-hidden", item.ariaHidden);
      if (!item.inert) item.el.removeAttribute("inert");
    }
  };

  // ---------------------------------------------------------------------------
  // Pintar y pasar de página
  // ---------------------------------------------------------------------------

  /** Cómo se ve cada página (lo mismo que pinta render.ts): la actual, la siguiente y la que se va. */
  const applyPresentation = (open: OpenBook, leaving: number | null): void => {
    open.pages.forEach((_, index) => {
      const el = byId(bookPageId(index));
      if (!el) return;
      const view = pagePresentation(index, open.page, leaving);
      el.classList.toggle("is-current", view.current);
      el.hidden = !view.shown;
      if (view.current) {
        el.removeAttribute("aria-hidden");
        el.removeAttribute("inert");
      } else {
        el.setAttribute("aria-hidden", "true");
        el.setAttribute("inert", "");
      }
      const img = el.querySelector<HTMLImageElement>(".book__img");
      if (img && view.eager && img.getAttribute("loading") !== "eager") img.setAttribute("loading", "eager");
    });
  };

  /** Las flechas (deshabilitadas en los bordes), «2 / 7» y los puntos. */
  const updateNav = (open: OpenBook): void => {
    const count = open.pages.length;
    const counter = byId(BOOK_COUNT_ID);
    if (counter) counter.textContent = counterText(open.page, count, deps.i18n());
    for (const [id, direction] of [
      [BOOK_PREV_ID, "prev"],
      [BOOK_NEXT_ID, "next"],
    ] as const) {
      const arrow = byId(id);
      if (!arrow) continue;
      if (canGo(open.page, count, direction)) arrow.removeAttribute("aria-disabled");
      else arrow.setAttribute("aria-disabled", "true");
    }
    open.pages.forEach((_, index) => {
      const dot = byId(bookDotId(index));
      if (!dot) return;
      if (index === open.page) dot.setAttribute("aria-current", "true");
      else dot.removeAttribute("aria-current");
    });
  };

  /** La región en vivo: se vacía y se escribe un instante después, así se anuncia también una página repetida. */
  const announce = (open: OpenBook): void => {
    const live = byId(BOOK_LIVE_ID);
    if (!live) return;
    const i18n = deps.i18n();
    const text = pageLabel(open.page, open.pages.length, pageName(open.pages[open.page], open.content, i18n), i18n);
    live.textContent = "";
    win.setTimeout(() => {
      if (book === open) live.textContent = text;
    }, 60);
  };

  /** La vuelta de hoja: next, la que se va gira hacia la izquierda; prev, la que llega vuelve desde la izquierda. */
  const startTurn = (open: OpenBook, from: HTMLElement, to: HTMLElement, direction: Direction): void => {
    const turning = direction === "next" ? from : to;
    const cls = direction === "next" ? "is-turning-next" : "is-turning-prev";
    from.classList.add("is-leaving");
    turning.classList.add(cls);
    let timer = 0;
    const onEnd = (event: AnimationEvent): void => {
      if (event.target === turning) finish();
    };
    const finish = (): void => {
      if (open.finishTurn !== finish) return;
      open.finishTurn = null;
      win.clearTimeout(timer);
      turning.removeEventListener("animationend", onEnd);
      from.classList.remove("is-leaving");
      turning.classList.remove(cls);
      if (book === open) applyPresentation(open, null);
    };
    turning.addEventListener("animationend", onEnd);
    timer = win.setTimeout(finish, TURN_FALLBACK_MS);
    open.finishTurn = finish;
  };

  const go = (target: number): void => {
    const open = book;
    if (!open) return;
    const next = clampPage(target, open.pages.length);
    if (next === open.page) return;
    open.finishTurn?.();
    const previous = open.page;
    const from = byId(bookPageId(previous));
    const to = byId(bookPageId(next));
    const focusWasInPage = !!from && from.contains(doc.activeElement);
    const direction = directionOf(previous, next);
    const animate = !!from && !!to && direction !== null && !reducedMotion();
    open.page = next;
    applyPresentation(open, animate ? previous : null);
    updateNav(open);
    announce(open);
    // Cada página empieza arriba.
    const sheet = sheetOf(next);
    if (sheet) sheet.scrollTop = 0;
    if (animate && from && to && direction) startTurn(open, from, to, direction);
    // Si el foco estaba en la página que se fue (un botón de la última, la hoja misma), pasa a la nueva.
    if (focusWasInPage) focusSheet(next);
  };

  /** Mientras se arrastra, la hoja sigue un poco al dedo (sin animación si se pidió menos movimiento). */
  const drag = (dx: number): void => {
    const open = book;
    if (!open || reducedMotion()) return;
    const count = open.pages.length;
    byId(BOOK_ID)?.classList.add("is-dragging");
    byId(bookPageId(open.page))?.style.setProperty(
      "--book-drag",
      `${dragOffset(dx, canGo(open.page, count, "prev"), canGo(open.page, count, "next"))}px`,
    );
  };

  const release = (direction: Direction | null): void => {
    const open = book;
    if (!open) return;
    byId(BOOK_ID)?.classList.remove("is-dragging");
    byId(bookPageId(open.page))?.style.removeProperty("--book-drag");
    if (direction) go(step(open.page, open.pages.length, direction));
  };

  /** Monta el libro en la página open.page (al abrirlo y si cambia lo que muestra). */
  const render = (open: OpenBook): void => {
    if (!root) return;
    open.unbindSwipe();
    open.finishTurn?.();
    const i18n = deps.i18n();
    const tree = bookTree({
      week: open.week,
      content: open.content,
      page: open.page,
      i18n,
      chef: chef(),
      brand: deps.brand,
      closing: closingKind(open.week, quoteTargetOf(open.week)),
      failedPhotos,
    });
    root.replaceChildren(mount(tree, doc));
    const viewport = byId(BOOK_VIEWPORT_ID);
    open.unbindSwipe = viewport ? bindSwipe(viewport, { onDrag: drag, onRelease: release }) : () => {};
  };

  // ---------------------------------------------------------------------------
  // Abrir y cerrar
  // ---------------------------------------------------------------------------

  const show = (session: string, openerId: string | null, push: boolean): boolean => {
    const token = deps.token;
    const found = findWeek(session);
    if (!token || !found) return false;
    if (book?.session === session) return true;
    if (book) close({ fromHistory: true });

    const fragment = bookFragment(token, session);
    let pushed = false;
    if (win.location.hash !== fragment) {
      if (push) {
        win.history.pushState(win.history.state, "", urlWith(fragment));
        pushed = true;
      } else {
        win.history.replaceState(win.history.state, "", urlWith(fragment));
      }
    }
    syncLangLinks();

    if (!root) {
      root = doc.createElement("div");
      root.id = "book-root";
      root.addEventListener("click", onClick);
      // Una foto que no carga deja la lámina (el evento error no sube: se escucha en la captura).
      root.addEventListener("error", onImageError, true);
      doc.body.appendChild(root);
    }
    root.hidden = false;
    // Las teclas, en todo el documento mientras está abierto: también si el foco quedó en el body.
    doc.addEventListener("keydown", onKeydown);
    const open: OpenBook = {
      session,
      week: found.week,
      content: found.content,
      pages: bookPages(found.content),
      page: 0,
      signature: bookSignature(found.week, deps.i18n().lang, chef(), quoteTargetOf(found.week)),
      openerId,
      pushed,
      background: [],
      unbindSwipe: () => {},
      finishTurn: null,
    };
    book = open;
    render(open);
    open.background = inertBackground();
    doc.documentElement.classList.add("book-open");
    focusSheet(open.page);
    return true;
  };

  /**
   * Cierra el libro. fromHistory: el fragmento ya cambió (atrás, adelante, otro link): no se toca el historial. Si no,
   * se vuelve atrás si se abrió con una entrada nueva, o se saca libro del fragmento. El foco va al primero de targets
   * que esté en la página, al botón que lo abrió o al de su semana.
   */
  function close(how: { fromHistory: boolean; targets?: readonly string[] }): void {
    const open = book;
    if (!open) return;
    open.finishTurn?.();
    open.unbindSwipe();
    book = null;
    doc.removeEventListener("keydown", onKeydown);
    if (root) {
      root.replaceChildren();
      root.hidden = true;
    }
    restoreBackground(open.background);
    doc.documentElement.classList.remove("book-open");
    if (!how.fromHistory && deps.token && readBookSession(win.location.hash) === open.session) {
      if (open.pushed) win.history.back();
      else win.history.replaceState(win.history.state, "", urlWith(tokenFragment(deps.token)));
    }
    syncLangLinks();
    const candidates = [...(how.targets ?? []), open.openerId, bookButtonId(open.session), focusId({ kind: "status", session: open.session }), "reservation-greeting"];
    for (const id of candidates) {
      const el = id ? byId(id) : null;
      if (el) {
        el.focus();
        break;
      }
    }
  }

  /** Abre o cierra según el fragmento (al cargar la reserva y cuando cambia: atrás, adelante, otro link). */
  const sync = (): void => {
    syncLangLinks();
    const wanted = readBookSession(win.location.hash);
    if (wanted === null) {
      if (book) close({ fromHistory: true });
      return;
    }
    if (book?.session === wanted || deps.state().kind !== "ready") return;
    if (!show(wanted, null, false) && deps.token) {
      // Un link al libro de una semana que ya no está (o cuyo menú no se puede mostrar): la página, sin libro.
      win.history.replaceState(win.history.state, "", urlWith(tokenFragment(deps.token)));
      syncLangLinks();
    }
  };

  /** Cambió la reserva o el idioma: si cambió lo que muestra el libro, se pinta de nuevo en la misma página. */
  const refresh = (): void => {
    const open = book;
    if (!open) {
      sync();
      return;
    }
    const found = findWeek(open.session);
    if (!found) {
      close({ fromHistory: false });
      return;
    }
    const signature = bookSignature(found.week, deps.i18n().lang, chef(), quoteTargetOf(found.week));
    if (signature === open.signature) return;
    const focused = doc.activeElement instanceof HTMLElement && root?.contains(doc.activeElement) ? doc.activeElement.id : "";
    open.week = found.week;
    open.content = found.content;
    open.pages = bookPages(found.content);
    open.page = clampPage(open.page, open.pages.length);
    open.signature = signature;
    render(open);
    const keep = focused ? byId(focused) : null;
    if (keep) keep.focus({ preventScroll: true });
    else focusSheet(open.page);
  };

  // ---------------------------------------------------------------------------
  // Eventos dentro del libro
  // ---------------------------------------------------------------------------

  function onClick(event: MouseEvent): void {
    const open = book;
    if (!open || !(event.target instanceof Element)) return;
    // Un clic en el fondo, fuera del libro (en la computadora), lo cierra.
    if (event.target.id === BOOK_ID) {
      close({ fromHistory: false });
      return;
    }
    const target = event.target.closest<HTMLElement>("[data-book]");
    if (!target || !root?.contains(target)) return;
    if (target.getAttribute("aria-disabled") === "true") {
      event.preventDefault();
      return;
    }
    switch (target.dataset["book"]) {
      case "close":
        close({ fromHistory: false });
        break;
      case "prev":
        go(open.page - 1);
        break;
      case "next":
        go(open.page + 1);
        break;
      case "go":
        go(Number(target.dataset["page"]));
        break;
      case "restart":
        go(0);
        break;
      case "cta": {
        const quote = quoteTargetOf(open.week);
        close({ fromHistory: false, targets: closingTargets(closingKind(open.week, quote), open.session, quote) });
        break;
      }
    }
  }

  function onKeydown(event: KeyboardEvent): void {
    const open = book;
    if (!open || event.altKey || event.ctrlKey || event.metaKey) return;
    if (event.key === "Tab") {
      const items = Array.from(root?.querySelectorAll<HTMLElement>("button, a[href], [tabindex]:not([tabindex='-1'])") ?? []).filter(
        (el) => !el.closest("[hidden], [inert], [aria-hidden='true']") && el.getClientRects().length > 0,
      );
      const active = doc.activeElement instanceof HTMLElement ? doc.activeElement : null;
      const next = trapFocus(items, active && items.includes(active) ? active : null, event.shiftKey);
      if (next) {
        event.preventDefault();
        next.focus();
      }
      return;
    }
    if (event.shiftKey) return;
    const action = keyAction(event.key, open.page, open.pages.length);
    if (!action) return;
    event.preventDefault();
    if (action.kind === "close") close({ fromHistory: false });
    else go(action.page);
  }

  function onImageError(event: Event): void {
    const img = event.target instanceof HTMLImageElement && event.target.classList.contains("book__img") ? event.target : null;
    if (!img) return;
    failedPhotos.add(img.getAttribute("src") ?? "");
    img.closest(".book__photo")?.classList.add("book__photo--empty");
    img.remove();
  }

  deps.onStateChange(refresh);
  deps.onLanguageChange(refresh);
  win.addEventListener("popstate", sync);
  win.addEventListener("hashchange", sync);
  sync();

  return {
    open(session, openerId) {
      show(session, openerId, true);
    },
  };
}
