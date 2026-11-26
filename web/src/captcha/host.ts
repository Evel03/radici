// El captcha de Auth desde una página de la web (hoy, «Reinvia l'email» de /accesso/): abre /captcha/ en un iframe del
// mismo origen, le pide un token con un id nuevo y espera la respuesta con ese id. Hace lo mismo que la app de Flutter
// (app/lib/core/captcha/captcha_broker.dart y captcha_platform_web.dart):
// - espera 20 s, o 120 s si Cloudflare pide que la persona toque la casilla;
// - si no hay token (error, tiempo, cancelado), devuelve null y nunca lanza;
// - el marco se crea en cada pedido y se saca del DOM al terminar, siempre.
// El marco mide 1 px y no se ve; si Cloudflare pide tocar la casilla, se muestra al centro con el fondo atenuado (las
// clases están en styles/access.css: la CSP no deja estilos en línea). Turnstile corre dentro de /captcha/, nunca en la
// página que lo pide. El token es de un solo uso: no se guarda ni se registra.
import { isTrustedPageEvent, newRequestId, parsePageMessage, requestEnvelope, type PageMessage } from "./protocol.ts";

export const CAPTCHA_TIMEOUT_MS = 20_000;
export const CAPTCHA_INTERACTIVE_TIMEOUT_MS = 120_000;

/** Una apertura de /captcha/ para un solo pedido. Lo que entrega ya pasó la verificación de origen y de fuente. */
export interface HostSession {
  onMessage(handler: (message: PageMessage) => void): void;
  /** Le pide un token a la página (después de su «ready»). */
  request(id: string): void;
  /** Cierra la página. Se llama siempre, una vez. */
  dispose(): void;
}

export interface CaptchaRequestDeps {
  open: () => HostSession;
  newId?: () => string;
  setTimer?: (callback: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  timeoutMs?: number;
  interactiveTimeoutMs?: number;
}

/** Un token de captcha nuevo, o null si no se pudo. */
export function requestCaptchaToken(deps: CaptchaRequestDeps): Promise<string | null> {
  const setTimer = deps.setTimer ?? ((callback: () => void, ms: number) => globalThis.setTimeout(callback, ms));
  const clearTimer = deps.clearTimer ?? ((handle: unknown) => globalThis.clearTimeout(handle as ReturnType<typeof setTimeout>));
  const timeout = deps.timeoutMs ?? CAPTCHA_TIMEOUT_MS;
  const interactiveTimeout = deps.interactiveTimeoutMs ?? CAPTCHA_INTERACTIVE_TIMEOUT_MS;

  return new Promise((resolve) => {
    let session: HostSession | null = null;
    let timer: unknown = null;
    let finished = false;

    const finish = (token: string | null): void => {
      if (finished) return;
      finished = true;
      if (timer !== null) clearTimer(timer);
      try {
        session?.dispose();
      } catch {
        // Ya estaba cerrada.
      }
      resolve(token);
    };

    const arm = (ms: number): void => {
      if (timer !== null) clearTimer(timer);
      timer = setTimer(() => finish(null), ms);
    };

    try {
      const id = (deps.newId ?? (() => newRequestId((bytes) => crypto.getRandomValues(bytes))))();
      const opened = deps.open();
      session = opened;
      opened.onMessage((message) => {
        if (finished) return;
        switch (message.type) {
          case "ready":
            // Una página que se recarga vuelve a avisar: se le repite el pedido.
            try {
              opened.request(id);
            } catch {
              finish(null);
            }
            break;
          case "interactive":
            if (message.id === id) arm(message.visible ? interactiveTimeout : timeout);
            break;
          case "token":
            if (message.id === id) finish(message.token);
            break;
          case "error":
            if (message.id === id) finish(null);
            break;
        }
      });
      arm(timeout);
    } catch {
      // No se pudo abrir la página (sin DOM, sin crypto): sin token.
      finish(null);
    }
  });
}

/** Lo que usa openFrameSession del documento y de la ventana (en los tests, simulados). */
export interface FrameElement {
  src: string;
  className: string;
  tabIndex: number;
  title: string;
  readonly contentWindow: { postMessage(message: unknown, targetOrigin: string): void } | null;
  setAttribute(name: string, value: string): void;
  removeAttribute(name: string): void;
  focus(): void;
  remove(): void;
}

export interface FrameDocument<E extends FrameElement = FrameElement> {
  createElement(tag: "iframe"): E;
  readonly body: { append(node: E): void };
}

export interface FrameHostWindow {
  readonly location: { readonly origin: string };
  addEventListener(type: "message", listener: (event: { origin: string; source: unknown; data: unknown }) => void): void;
  removeEventListener(type: "message", listener: (event: { origin: string; source: unknown; data: unknown }) => void): void;
}

export const FRAME_CLASS = "captcha-frame";
export const FRAME_VISIBLE_CLASS = "captcha-frame captcha-frame--visible";

/**
 * Abre /captcha/ en un iframe del mismo origen. `lang` es el idioma de la página (el de los textos y el botón
 * «Annulla» de /captcha/); `title`, el nombre accesible del marco cuando se muestra.
 */
export function openFrameSession<E extends FrameElement>(win: FrameHostWindow, doc: FrameDocument<E>, lang: string, title: string): HostSession {
  const origin = win.location.origin;
  const frame = doc.createElement("iframe");
  frame.src = `/captcha/?lang=${encodeURIComponent(lang)}`;
  frame.className = FRAME_CLASS;
  frame.title = title;
  frame.tabIndex = -1;
  // Mientras no se ve, los lectores de pantalla no lo encuentran: la página solo habla con este código.
  frame.setAttribute("aria-hidden", "true");
  frame.setAttribute("referrerpolicy", "same-origin");

  let handler: ((message: PageMessage) => void) | null = null;
  const listener = (event: { origin: string; source: unknown; data: unknown }): void => {
    if (!isTrustedPageEvent(event, origin, frame.contentWindow)) return;
    const message = parsePageMessage(event.data);
    if (!message) return;
    if (message.type === "interactive") {
      frame.className = message.visible ? FRAME_VISIBLE_CLASS : FRAME_CLASS;
      frame.tabIndex = message.visible ? 0 : -1;
      if (message.visible) {
        frame.removeAttribute("aria-hidden");
        frame.focus();
      } else {
        frame.setAttribute("aria-hidden", "true");
      }
    }
    handler?.(message);
  };
  win.addEventListener("message", listener);
  doc.body.append(frame);

  return {
    onMessage(next) {
      handler = next;
    },
    request(id) {
      frame.contentWindow?.postMessage(requestEnvelope(id), origin);
    },
    dispose() {
      win.removeEventListener("message", listener);
      frame.remove();
    },
  };
}
