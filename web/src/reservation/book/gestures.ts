// Los gestos del libro del menú: deslizar con el dedo (o arrastrar con el mouse) pasa de página. La decisión es pura
// (con tests): cuándo un gesto es horizontal, cuándo alcanza para pasar de página y cuánto sigue la hoja al dedo.
// bindSwipe la conecta con los eventos de puntero de un elemento (dedo, lápiz y mouse).
//
// Sin secuestrar el scroll: el visor tiene touch-action: pan-y (el navegador sigue haciendo el scroll vertical de una
// página larga) y un gesto que arranca vertical no pasa de página. Para pasar hace falta un mínimo (40 px, o el 18 %
// del ancho del visor) o un gesto rápido; uno corto o lento deja la hoja donde estaba.
import type { Direction } from "./state.ts";

export const SWIPE = {
  /** Lo que hay que moverse para saber si el gesto es horizontal o vertical. */
  slop: 10,
  /** Lo mínimo para pasar de página. */
  minDistance: 40,
  /** O esta parte del ancho del visor… */
  fraction: 0.18,
  /** …o así de rápido (px por ms): lo que llegue primero. */
  fastVelocity: 0.45,
  /** Cuánto sigue la hoja al dedo; en un borde (no hay más páginas), menos. Con tope, en px. */
  follow: 0.35,
  edgeFollow: 0.12,
  maxFollow: 64,
} as const;

export type Axis = "x" | "y";

/** El eje del gesto cuando ya se movió lo suficiente (slop), o null. Un empate es vertical: el scroll primero. */
export function lockAxis(dx: number, dy: number): Axis | null {
  const ax = Math.abs(dx);
  const ay = Math.abs(dy);
  if (Math.max(ax, ay) < SWIPE.slop) return null;
  return ax > ay ? "x" : "y";
}

/** Un gesto horizontal al soltar: cuánto se movió, en cuánto tiempo y el ancho del visor. */
export interface SwipeEnd {
  dx: number;
  dy: number;
  ms: number;
  width: number;
}

/**
 * Hacia dónde pasar de página al soltar, o null. A la izquierda (dx < 0) avanza, a la derecha retrocede, como al
 * dar vuelta una hoja. Tiene que ser más horizontal que vertical y llegar al mínimo, y además lejos o rápido.
 */
export function swipeDirection(end: SwipeEnd): Direction | null {
  const ax = Math.abs(end.dx);
  if (ax < SWIPE.minDistance || ax <= Math.abs(end.dy)) return null;
  const far = ax >= Math.max(SWIPE.minDistance, end.width * SWIPE.fraction);
  const fast = ax / Math.max(end.ms, 1) >= SWIPE.fastVelocity;
  if (!far && !fast) return null;
  return end.dx < 0 ? "next" : "prev";
}

/** Cuánto se corre la hoja mientras se arrastra (px): una parte del gesto, menos hacia un borde y con tope. */
export function dragOffset(dx: number, canPrev: boolean, canNext: boolean): number {
  const toEdge = (dx > 0 && !canPrev) || (dx < 0 && !canNext);
  const offset = dx * (toEdge ? SWIPE.edgeFollow : SWIPE.follow);
  return Math.round(Math.max(-SWIPE.maxFollow, Math.min(SWIPE.maxFollow, offset)));
}

/** Un gesto de principio a fin, sin DOM: dónde y cuándo empezó y hacia dónde va. */
export interface SwipeTracker {
  readonly active: boolean;
  /** El eje, cuando ya se sabe (no cambia hasta soltar). */
  readonly axis: Axis | null;
  start(x: number, y: number, time: number): void;
  /** Mientras se mueve: el eje (si ya se sabe) y cuánto se corrió en horizontal. */
  move(x: number, y: number): { axis: Axis | null; dx: number };
  /** Al soltar: hacia dónde pasar de página (solo un gesto horizontal), o null. Termina el gesto. */
  end(x: number, y: number, time: number, width: number): Direction | null;
  cancel(): void;
}

export function createSwipeTracker(): SwipeTracker {
  let origin: { x: number; y: number; time: number } | null = null;
  let axis: Axis | null = null;
  return {
    get active() {
      return origin !== null;
    },
    get axis() {
      return axis;
    },
    start(x, y, time) {
      origin = { x, y, time };
      axis = null;
    },
    move(x, y) {
      if (!origin) return { axis: null, dx: 0 };
      const dx = x - origin.x;
      axis ??= lockAxis(dx, y - origin.y);
      return { axis, dx };
    },
    end(x, y, time, width) {
      const from = origin;
      const wasHorizontal = axis === "x";
      origin = null;
      axis = null;
      if (!from || !wasHorizontal) return null;
      return swipeDirection({ dx: x - from.x, dy: y - from.y, ms: time - from.time, width });
    },
    cancel() {
      origin = null;
      axis = null;
    },
  };
}

export interface SwipeHandlers {
  /** El gesto es horizontal y se movió: dx en px desde donde empezó (para correr la hoja). */
  onDrag(dx: number): void;
  /** Terminó un gesto horizontal: hacia dónde pasar de página, o null (la hoja vuelve a su lugar). */
  onRelease(direction: Direction | null): void;
}

/** El clic que llega justo después de soltar un gesto horizontal (el mouse lo manda) no cuenta: era un arrastre. */
export const SWALLOW_CLICK_MS = 500;

/**
 * Conecta los gestos con un elemento (pointer events: dedo, lápiz y mouse). Recién cuando el gesto es horizontal toma
 * el puntero (setPointerCapture), así un toque en un botón sigue siendo un clic; el clic que llega enseguida después
 * de deslizar no cuenta. Ojo: el navegador decide el gesto con el touch-action desde el elemento tocado hasta su
 * contenedor de scroll más cercano (la hoja de cada página, en book.css). Devuelve cómo desconectarlos.
 */
export function bindSwipe(el: HTMLElement, handlers: SwipeHandlers): () => void {
  const tracker = createSwipeTracker();
  let pointer: number | null = null;
  /** Hasta cuándo (event.timeStamp) un clic es el de un arrastre que terminó. */
  let swallowUntil = 0;

  const down = (event: PointerEvent): void => {
    if (pointer !== null || !event.isPrimary || (event.pointerType === "mouse" && event.button !== 0)) return;
    pointer = event.pointerId;
    swallowUntil = 0;
    tracker.start(event.clientX, event.clientY, event.timeStamp);
  };
  const move = (event: PointerEvent): void => {
    if (event.pointerId !== pointer) return;
    const before = tracker.axis;
    const { axis, dx } = tracker.move(event.clientX, event.clientY);
    if (axis === "y") {
      // Un gesto vertical es scroll: no es de página.
      pointer = null;
      tracker.cancel();
      return;
    }
    if (axis !== "x") return;
    if (before === null) {
      try {
        el.setPointerCapture(event.pointerId);
      } catch {
        // Un puntero que ya no existe: el gesto sigue con los eventos que lleguen.
      }
      el.ownerDocument.defaultView?.getSelection()?.removeAllRanges();
    }
    handlers.onDrag(dx);
  };
  const finish = (event: PointerEvent, cancelled: boolean): void => {
    if (event.pointerId !== pointer) return;
    pointer = null;
    const horizontal = tracker.axis === "x";
    let direction: Direction | null = null;
    if (cancelled) tracker.cancel();
    else direction = tracker.end(event.clientX, event.clientY, event.timeStamp, el.clientWidth);
    // Un gesto cancelado (el navegador lo tomó) no manda clic; uno que terminó, con el mouse, sí.
    if (horizontal && !cancelled) swallowUntil = event.timeStamp + SWALLOW_CLICK_MS;
    if (horizontal) handlers.onRelease(direction);
  };
  const up = (event: PointerEvent): void => finish(event, false);
  const cancel = (event: PointerEvent): void => finish(event, true);
  const click = (event: MouseEvent): void => {
    if (event.timeStamp > swallowUntil) return;
    swallowUntil = 0;
    event.preventDefault();
    event.stopPropagation();
  };

  el.addEventListener("pointerdown", down);
  el.addEventListener("pointermove", move);
  el.addEventListener("pointerup", up);
  el.addEventListener("pointercancel", cancel);
  el.addEventListener("click", click, true);
  return () => {
    el.removeEventListener("pointerdown", down);
    el.removeEventListener("pointermove", move);
    el.removeEventListener("pointerup", up);
    el.removeEventListener("pointercancel", cancel);
    el.removeEventListener("click", click, true);
  };
}
