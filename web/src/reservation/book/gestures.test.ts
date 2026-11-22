import { describe, expect, it } from "vitest";
import { SWIPE, bindSwipe, createSwipeTracker, dragOffset, lockAxis, swipeDirection } from "./gestures.ts";

describe("el eje del gesto", () => {
  it("hasta moverse lo suficiente no se sabe; después, el que más se movió (un empate es scroll)", () => {
    expect(lockAxis(4, 3)).toBeNull();
    expect(lockAxis(SWIPE.slop, 2)).toBe("x");
    expect(lockAxis(-12, 5)).toBe("x");
    expect(lockAxis(3, -14)).toBe("y");
    expect(lockAxis(12, 12)).toBe("y");
  });
});

describe("cuándo un gesto pasa de página", () => {
  const width = 360;

  it("a la izquierda avanza, a la derecha retrocede", () => {
    expect(swipeDirection({ dx: -120, dy: 10, ms: 300, width })).toBe("next");
    expect(swipeDirection({ dx: 120, dy: -10, ms: 300, width })).toBe("prev");
  });

  it("lejos (el 18 % del ancho, al menos 40 px) aunque sea lento, o rápido aunque sea corto", () => {
    expect(swipeDirection({ dx: -66, dy: 0, ms: 2000, width })).toBe("next");
    expect(swipeDirection({ dx: -60, dy: 0, ms: 2000, width })).toBeNull();
    expect(swipeDirection({ dx: -45, dy: 0, ms: 80, width })).toBe("next");
    // En la computadora (un visor ancho) lejos es más.
    expect(swipeDirection({ dx: -100, dy: 0, ms: 2000, width: 1000 })).toBeNull();
    expect(swipeDirection({ dx: -200, dy: 0, ms: 2000, width: 1000 })).toBe("next");
  });

  it("nunca uno corto, aunque sea rápido, ni uno más vertical que horizontal", () => {
    expect(swipeDirection({ dx: -30, dy: 0, ms: 20, width })).toBeNull();
    expect(swipeDirection({ dx: -120, dy: 130, ms: 200, width })).toBeNull();
    expect(swipeDirection({ dx: 90, dy: 90, ms: 200, width })).toBeNull();
  });
});

describe("la hoja mientras se arrastra", () => {
  it("sigue un poco al dedo, con tope, y menos hacia un borde (no hay más páginas)", () => {
    expect(dragOffset(-100, true, true)).toBe(-35);
    expect(dragOffset(100, true, true)).toBe(35);
    expect(dragOffset(-1000, true, true)).toBe(-SWIPE.maxFollow);
    expect(dragOffset(100, false, true)).toBe(12);
    expect(dragOffset(-100, true, false)).toBe(-12);
    expect(dragOffset(0, true, true)).toBe(0);
  });
});

describe("un gesto de principio a fin", () => {
  it("horizontal: el eje queda fijo hasta soltar y al soltar dice hacia dónde", () => {
    const tracker = createSwipeTracker();
    tracker.start(300, 200, 0);
    expect(tracker.active).toBe(true);
    expect(tracker.move(296, 201)).toEqual({ axis: null, dx: -4 });
    expect(tracker.move(280, 205)).toEqual({ axis: "x", dx: -20 });
    // Aunque después se vaya en diagonal, sigue siendo horizontal.
    expect(tracker.move(270, 240).axis).toBe("x");
    expect(tracker.end(180, 230, 250, 360)).toBe("next");
    expect([tracker.active, tracker.axis]).toEqual([false, null]);
  });

  it("vertical (el scroll de una página larga) o corto: no pasa de página", () => {
    const tracker = createSwipeTracker();
    tracker.start(100, 100, 0);
    expect(tracker.move(103, 130).axis).toBe("y");
    expect(tracker.end(250, 140, 200, 360)).toBeNull();
    tracker.start(100, 100, 0);
    tracker.move(120, 101);
    expect(tracker.end(125, 101, 900, 360)).toBeNull();
  });

  it("cancelado (el navegador tomó el gesto) o sin empezar: nada", () => {
    const tracker = createSwipeTracker();
    tracker.start(100, 100, 0);
    tracker.move(40, 100);
    tracker.cancel();
    expect(tracker.active).toBe(false);
    expect(tracker.end(0, 100, 100, 360)).toBeNull();
    expect(createSwipeTracker().move(10, 10)).toEqual({ axis: null, dx: 0 });
  });
});

/**
 * El visor sin DOM: guarda los listeners de bindSwipe y les pasa eventos como objetos (bindSwipe solo lee sus
 * propiedades). Por defecto, el mouse con el botón principal apretado.
 */
function fakeViewport(width = 360) {
  const listeners = new Map<string, ((event: unknown) => void)[]>();
  const el = {
    clientWidth: width,
    ownerDocument: { defaultView: { getSelection: () => ({ removeAllRanges: () => {} }) } },
    setPointerCapture: () => {},
    addEventListener: (type: string, listener: (event: unknown) => void) => listeners.set(type, [...(listeners.get(type) ?? []), listener]),
  };
  /** Despacha un evento; devuelve si se descartó (preventDefault). */
  const fire = (type: string, init: Record<string, unknown>): boolean => {
    let prevented = false;
    const event = {
      type,
      pointerId: 1,
      isPrimary: true,
      pointerType: "mouse",
      button: 0,
      buttons: 1,
      ...init,
      preventDefault: () => {
        prevented = true;
      },
      stopPropagation: () => {},
    };
    for (const listener of listeners.get(type) ?? []) listener(event);
    return prevented;
  };
  const calls: string[] = [];
  bindSwipe(el as unknown as HTMLElement, { onDrag: (dx) => calls.push(`drag ${dx}`), onRelease: (direction) => calls.push(`release ${direction}`) });
  return { fire, calls };
}

describe("bindSwipe con el mouse", () => {
  it("un arrastre horizontal pasa de página y el clic que manda el mouse al soltar no cuenta", () => {
    const { fire, calls } = fakeViewport();
    fire("pointerdown", { clientX: 300, clientY: 200, timeStamp: 0 });
    fire("pointermove", { clientX: 260, clientY: 202, timeStamp: 40 });
    fire("pointerup", { clientX: 180, clientY: 204, buttons: 0, timeStamp: 120 });
    expect(calls).toEqual(["drag -40", "release next"]);
    expect(fire("click", { timeStamp: 121 })).toBe(true);
  });

  it("soltado fuera del visor antes de saber el eje: mover sin apretar no arrastra la hoja y el clic siguiente cuenta", () => {
    const { fire, calls } = fakeViewport();
    // Aprieta a 3 px del borde de abajo y suelta sobre la barra de las flechas: el pointerup no le llega al visor.
    fire("pointerdown", { clientX: 100, clientY: 597, timeStamp: 0 });
    // Después pasa el mouse por la página, sin apretar.
    fire("pointermove", { clientX: 200, clientY: 591, buttons: 0, timeStamp: 900 });
    expect(calls).toEqual([]);
    // Su próximo clic, en «Vai alla conferma»: ni pasa de página ni se descarta.
    fire("pointerdown", { clientX: 240, clientY: 300, timeStamp: 2000 });
    fire("pointerup", { clientX: 240, clientY: 300, buttons: 0, timeStamp: 2080 });
    expect(fire("click", { timeStamp: 2081 })).toBe(false);
    expect(calls).toEqual([]);
  });

  it("si el mismo puntero vuelve a apretar, el gesto que quedó abierto termina (la hoja vuelve a su lugar) y empieza otro", () => {
    const { fire, calls } = fakeViewport();
    fire("pointerdown", { clientX: 300, clientY: 200, timeStamp: 0 });
    fire("pointermove", { clientX: 260, clientY: 201, timeStamp: 40 });
    // Su pointerup no llegó. Aprieta de nuevo: el viejo se descarta sin pasar de página y el nuevo funciona.
    fire("pointerdown", { clientX: 300, clientY: 400, timeStamp: 1000 });
    fire("pointermove", { clientX: 260, clientY: 401, timeStamp: 1040 });
    fire("pointerup", { clientX: 180, clientY: 402, buttons: 0, timeStamp: 1120 });
    expect(calls).toEqual(["drag -40", "release null", "drag -40", "release next"]);
  });

  it("con el dedo, otro dedo mientras dura el gesto no lo corta", () => {
    const { fire, calls } = fakeViewport();
    const touch = { pointerType: "touch" };
    fire("pointerdown", { ...touch, clientX: 300, clientY: 200, timeStamp: 0 });
    fire("pointermove", { ...touch, clientX: 260, clientY: 201, timeStamp: 40 });
    fire("pointerdown", { ...touch, pointerId: 2, isPrimary: false, clientX: 50, clientY: 50, timeStamp: 60 });
    fire("pointerup", { ...touch, clientX: 180, clientY: 202, buttons: 0, timeStamp: 120 });
    expect(calls).toEqual(["drag -40", "release next"]);
  });
});
