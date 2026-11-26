import { describe, expect, it, vi } from "vitest";
import {
  CAPTCHA_INTERACTIVE_TIMEOUT_MS,
  CAPTCHA_TIMEOUT_MS,
  FRAME_CLASS,
  FRAME_VISIBLE_CLASS,
  openFrameSession,
  requestCaptchaToken,
  type FrameDocument,
  type FrameElement,
  type FrameHostWindow,
  type HostSession,
} from "./host.ts";
import { envelope, type PageMessage } from "./protocol.ts";

const ID = "0123456789abcdef0123456789abcdef";
const OTHER = "ffffffffffffffffffffffffffffffff";
const ORIGIN = "https://radicicucina.app";

/** Una sesión simulada: lo que la página «manda» se entrega con send(). */
function fakeSession() {
  let handler: ((message: PageMessage) => void) | null = null;
  const session = {
    requests: [] as string[],
    disposed: 0,
    onMessage(next: (message: PageMessage) => void) {
      handler = next;
    },
    request(id: string) {
      session.requests.push(id);
    },
    dispose() {
      session.disposed += 1;
    },
    send(message: PageMessage) {
      handler?.(message);
    },
  };
  return session;
}

/** Relojes manuales: fire() dispara el último timer armado. */
function fakeTimers() {
  const timers = new Map<number, { callback: () => void; ms: number }>();
  let next = 1;
  return {
    setTimer: (callback: () => void, ms: number) => {
      const handle = next++;
      timers.set(handle, { callback, ms });
      return handle;
    },
    clearTimer: (handle: unknown) => {
      timers.delete(handle as number);
    },
    armed: () => [...timers.values()].map((t) => t.ms),
    fire: () => {
      const [handle, timer] = [...timers.entries()].at(-1) ?? [];
      if (handle === undefined || !timer) throw new Error("ningún timer armado");
      timers.delete(handle);
      timer.callback();
    },
  };
}

function start(session: HostSession, timers = fakeTimers()) {
  const promise = requestCaptchaToken({ open: () => session, newId: () => ID, ...timers });
  return { promise, timers };
}

describe("requestCaptchaToken", () => {
  it("pide el token con su id cuando la página avisa ready, y devuelve el token de ese id", async () => {
    const session = fakeSession();
    const { promise } = start(session);
    expect(session.requests).toEqual([]);
    session.send({ type: "ready" });
    expect(session.requests).toEqual([ID]);
    session.send({ type: "token", id: ID, token: "0.token" });
    await expect(promise).resolves.toBe("0.token");
    expect(session.disposed).toBe(1);
  });

  it("ignora respuestas con otro id (de otro pedido)", async () => {
    const session = fakeSession();
    const { promise } = start(session);
    session.send({ type: "ready" });
    session.send({ type: "token", id: OTHER, token: "ajeno" });
    session.send({ type: "error", id: OTHER, code: "x" });
    session.send({ type: "token", id: ID, token: "mio" });
    await expect(promise).resolves.toBe("mio");
  });

  it("si la página se recarga y vuelve a avisar ready, repite el pedido", () => {
    const session = fakeSession();
    start(session);
    session.send({ type: "ready" });
    session.send({ type: "ready" });
    expect(session.requests).toEqual([ID, ID]);
  });

  it("un error de la página da null y cierra el marco", async () => {
    const session = fakeSession();
    const { promise } = start(session);
    session.send({ type: "ready" });
    session.send({ type: "error", id: ID, code: "cancelled" });
    await expect(promise).resolves.toBeNull();
    expect(session.disposed).toBe(1);
  });

  it("espera 20 s; si Cloudflare pide tocar la casilla, 120 s; al volver a ocultarse, otra vez 20 s", async () => {
    const session = fakeSession();
    const { promise, timers } = start(session);
    expect(timers.armed()).toEqual([CAPTCHA_TIMEOUT_MS]);
    session.send({ type: "ready" });
    session.send({ type: "interactive", id: ID, visible: true });
    expect(timers.armed()).toEqual([CAPTCHA_INTERACTIVE_TIMEOUT_MS]);
    session.send({ type: "interactive", id: ID, visible: false });
    expect(timers.armed()).toEqual([CAPTCHA_TIMEOUT_MS]);
    timers.fire();
    await expect(promise).resolves.toBeNull();
    expect(session.disposed).toBe(1);
  });

  it("sin respuesta a tiempo: null (y lo que llega después no cambia nada)", async () => {
    const session = fakeSession();
    const { promise, timers } = start(session);
    timers.fire();
    session.send({ type: "ready" });
    session.send({ type: "token", id: ID, token: "tarde" });
    await expect(promise).resolves.toBeNull();
    expect(session.requests).toEqual([]);
    expect(session.disposed).toBe(1);
  });

  it("si no se puede abrir la página, null sin lanzar", async () => {
    await expect(
      requestCaptchaToken({
        open: () => {
          throw new Error("sin DOM");
        },
        newId: () => ID,
        ...fakeTimers(),
      }),
    ).resolves.toBeNull();
  });

  it("si el pedido falla al mandarse, null", async () => {
    const session = fakeSession();
    session.request = () => {
      throw new Error("marco cerrado");
    };
    const { promise } = start(session);
    session.send({ type: "ready" });
    await expect(promise).resolves.toBeNull();
  });

  it("sin newId usa un id al azar de 128 bits", () => {
    const session = fakeSession();
    void requestCaptchaToken({ open: () => session, ...fakeTimers() });
    session.send({ type: "ready" });
    expect(session.requests[0]).toMatch(/^[0-9a-f]{32}$/);
  });
});

/** Un iframe, un documento y una ventana simulados. */
function fakeDom(origin = ORIGIN) {
  const contentWindow = { posted: [] as Array<[unknown, string]>, postMessage(message: unknown, target: string) { contentWindow.posted.push([message, target]); } };
  const attrs = new Map<string, string>();
  const frame: FrameElement & { removed: boolean; focused: number; attrs: Map<string, string> } = {
    src: "",
    className: "",
    tabIndex: 0,
    title: "",
    contentWindow,
    setAttribute: (name, value) => void attrs.set(name, value),
    removeAttribute: (name) => void attrs.delete(name),
    focus: () => {
      frame.focused += 1;
    },
    remove: () => {
      frame.removed = true;
    },
    removed: false,
    focused: 0,
    attrs,
  };
  const appended: FrameElement[] = [];
  const doc: FrameDocument = { createElement: () => frame, body: { append: (node) => void appended.push(node) } };
  type Listener = (event: { origin: string; source: unknown; data: unknown }) => void;
  const listeners = new Set<Listener>();
  const win: FrameHostWindow = {
    location: { origin },
    addEventListener: (_type, listener) => void listeners.add(listener),
    removeEventListener: (_type, listener) => void listeners.delete(listener),
  };
  const dispatch = (event: { origin: string; source: unknown; data: unknown }) => {
    for (const listener of [...listeners]) listener(event);
  };
  return { frame, contentWindow, doc, win, appended, listeners, dispatch };
}

describe("openFrameSession", () => {
  it("abre /captcha/ con el idioma, oculto, sin lectores de pantalla y con referrer del mismo origen", () => {
    const dom = fakeDom();
    openFrameSession(dom.win, dom.doc, "es", "Verificación");
    expect(dom.appended).toEqual([dom.frame]);
    expect(dom.frame.src).toBe("/captcha/?lang=es");
    expect(dom.frame.className).toBe(FRAME_CLASS);
    expect(dom.frame.title).toBe("Verificación");
    expect(dom.frame.tabIndex).toBe(-1);
    expect(dom.frame.attrs.get("aria-hidden")).toBe("true");
    expect(dom.frame.attrs.get("referrerpolicy")).toBe("same-origin");
  });

  it("el pedido va a la ventana del marco con el origen exacto como destino (nunca «*»)", () => {
    const dom = fakeDom();
    const session = openFrameSession(dom.win, dom.doc, "it", "x");
    session.request(ID);
    expect(dom.contentWindow.posted).toEqual([[{ source: "radici-captcha", v: 1, type: "request", id: ID }, ORIGIN]]);
  });

  it("entrega solo lo del mismo origen y del propio marco, ya leído", () => {
    const dom = fakeDom();
    const session = openFrameSession(dom.win, dom.doc, "it", "x");
    const got = vi.fn();
    session.onMessage(got);
    dom.dispatch({ origin: "https://evil.example", source: dom.contentWindow, data: envelope({ type: "ready" }) });
    dom.dispatch({ origin: ORIGIN, source: {}, data: envelope({ type: "ready" }) });
    dom.dispatch({ origin: ORIGIN, source: dom.contentWindow, data: { type: "ready" } });
    expect(got).not.toHaveBeenCalled();
    dom.dispatch({ origin: ORIGIN, source: dom.contentWindow, data: envelope({ type: "token", id: ID, token: "0.t" }) });
    expect(got).toHaveBeenCalledWith({ type: "token", id: ID, token: "0.t" });
  });

  it("si Cloudflare pide tocar la casilla, el marco se muestra, toma el foco y se puede leer; después se vuelve a ocultar", () => {
    const dom = fakeDom();
    openFrameSession(dom.win, dom.doc, "it", "x");
    dom.dispatch({ origin: ORIGIN, source: dom.contentWindow, data: envelope({ type: "interactive", id: ID, visible: true }) });
    expect(dom.frame.className).toBe(FRAME_VISIBLE_CLASS);
    expect(dom.frame.tabIndex).toBe(0);
    expect(dom.frame.attrs.has("aria-hidden")).toBe(false);
    expect(dom.frame.focused).toBe(1);
    dom.dispatch({ origin: ORIGIN, source: dom.contentWindow, data: envelope({ type: "interactive", id: ID, visible: false }) });
    expect(dom.frame.className).toBe(FRAME_CLASS);
    expect(dom.frame.tabIndex).toBe(-1);
    expect(dom.frame.attrs.get("aria-hidden")).toBe("true");
  });

  it("al cerrar saca el marco y deja de escuchar", () => {
    const dom = fakeDom();
    const session = openFrameSession(dom.win, dom.doc, "it", "x");
    expect(dom.listeners.size).toBe(1);
    session.dispose();
    expect(dom.frame.removed).toBe(true);
    expect(dom.listeners.size).toBe(0);
  });

  it("de punta a punta con requestCaptchaToken: ready → pedido → token, y el marco se va", async () => {
    const dom = fakeDom();
    const promise = requestCaptchaToken({ open: () => openFrameSession(dom.win, dom.doc, "en", "x"), newId: () => ID, ...fakeTimers() });
    dom.dispatch({ origin: ORIGIN, source: dom.contentWindow, data: envelope({ type: "ready" }) });
    expect(dom.contentWindow.posted.map(([message]) => (message as { id: string }).id)).toEqual([ID]);
    dom.dispatch({ origin: ORIGIN, source: dom.contentWindow, data: envelope({ type: "token", id: ID, token: "0.ok" }) });
    await expect(promise).resolves.toBe("0.ok");
    expect(dom.frame.removed).toBe(true);
    expect(dom.listeners.size).toBe(0);
  });
});
