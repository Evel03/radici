// Protocolo entre /captcha/ (la página del Turnstile de Auth) y quien la abre: la app de Evelyn (Flutter web
// en /gestione/ y, más adelante, /app/; iOS y Android). Funciones puras: se testean sin navegador.
//
// La página no manda nada sola: espera un pedido con un id al azar y contesta con ese id, así un token
// siempre es la respuesta a un pedido concreto de quien lo hizo y nunca queda uno suelto esperando.
//   página → host: ready · interactive (id, visible) · token (id, token) · error (id, code)
//   host → página: request (id)
// Dos canales, mismo contenido:
// - "frame": la página va en un iframe del mismo origen y se habla con postMessage. Los dos lados comparan el
//   origen EXACTO (event.origin) y, la página, que el emisor sea su ventana padre; el destino de cada
//   postMessage es ese mismo origen, nunca "*".
// - "native": la app (webview_flutter) abre la página con ?channel=native; la página manda por el canal
//   JavaScript `RadiciCaptcha` (un string JSON) y recibe el pedido llamando a window.radiciCaptchaRequest(id).
// Lo que no encaja (otro origen, otra fuente, otro formato) se ignora sin contestar.
// El token es la credencial de un solo uso de Auth: nunca se registra en la consola ni se guarda.

export const CAPTCHA_SOURCE = "radici-captcha";
export const CAPTCHA_VERSION = 1;
/** Acción del widget de Auth (distinta de la del formulario, "public-request"). */
export const CAPTCHA_ACTION = "auth";
/** Nombre del canal JavaScript que la app nativa instala en la página. */
export const NATIVE_CHANNEL = "RadiciCaptcha";
/** Función global con la que la app nativa le hace un pedido a la página. */
export const NATIVE_REQUEST_FN = "radiciCaptchaRequest";

export type CaptchaMode = "frame" | "native" | "standalone";

export type PageMessage =
  | { type: "ready" }
  | { type: "interactive"; id: string; visible: boolean }
  | { type: "token"; id: string; token: string }
  | { type: "error"; id: string; code: string };

/** Id de un pedido: 128 bits al azar en hexadecimal, lo genera la app. */
export function isRequestId(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{32}$/.test(value);
}

/** Un token de Turnstile: letras, dígitos, "-", "_" y "." (hasta 2048 caracteres). */
export function isTokenShape(value: unknown): value is string {
  return typeof value === "string" && /^[\w.-]{1,2048}$/.test(value);
}

/** Código de error corto para diagnóstico: solo letras, dígitos, "_" y "-" (nunca texto libre). */
export function safeCode(code: unknown): string {
  const text = typeof code === "string" ? code.trim() : Number.isSafeInteger(code) ? String(code) : "";
  return /^[\w-]{1,32}$/.test(text) ? text : "unknown";
}

/** El mensaje tal como viaja: con la marca de origen y la versión, para que el host lo reconozca. */
export function envelope(message: PageMessage): Record<string, unknown> {
  return { source: CAPTCHA_SOURCE, v: CAPTCHA_VERSION, ...message };
}

/** El id de un pedido del host, o null si el mensaje no es uno válido (objeto o string JSON). */
export function parseRequest(raw: unknown): string | null {
  let value: unknown = raw;
  if (typeof raw === "string") {
    try {
      value = JSON.parse(raw);
    } catch {
      return null;
    }
  }
  if (typeof value !== "object" || value === null) return null;
  const message = value as Record<string, unknown>;
  if (message["source"] !== CAPTCHA_SOURCE || message["v"] !== CAPTCHA_VERSION || message["type"] !== "request") return null;
  return isRequestId(message["id"]) ? message["id"] : null;
}

export interface FrameEvent {
  readonly origin: string;
  readonly source: unknown;
  readonly data: unknown;
}

/** Ventana mínima que usa el canal "frame" (en los tests, simulada). */
export interface FrameWindow {
  readonly location: { readonly origin: string };
  readonly parent: { postMessage(message: unknown, targetOrigin: string): void };
  addEventListener(type: "message", listener: (event: FrameEvent) => void): void;
}

/**
 * Un mensaje del host es de fiar solo si viene del mismo origen exacto (la página solo se deja enmarcar por el
 * mismo sitio: frame-ancestors 'self') y de la ventana padre.
 */
export function isTrustedHostEvent(event: Pick<FrameEvent, "origin" | "source">, ownOrigin: string, parent: unknown): boolean {
  // El origen de un documento con sandbox o de un data: es "null": nunca vale como el de un sitio real.
  return ownOrigin !== "null" && event.origin === ownOrigin && event.source === parent;
}

/** Cómo se abrió la página: dentro de la app nativa, en un iframe, o suelta (alguien entró por la URL). */
export function detectMode(search: string, hasNativeChannel: boolean, framed: boolean): CaptchaMode {
  if (new URLSearchParams(search).get("channel") === "native") return hasNativeChannel ? "native" : "standalone";
  return framed ? "frame" : "standalone";
}

export interface PageTransport {
  post(message: PageMessage): void;
  /** El host pidió un token: se llama una vez por pedido válido. */
  onRequest(handler: (id: string) => void): void;
}

/** Canal "frame": postMessage al padre, con el origen exacto del propio sitio como destino. */
export function frameTransport(win: FrameWindow): PageTransport {
  const origin = win.location.origin;
  return {
    post(message) {
      win.parent.postMessage(envelope(message), origin);
    },
    onRequest(handler) {
      win.addEventListener("message", (event) => {
        if (!isTrustedHostEvent(event, origin, win.parent)) return;
        const id = parseRequest(event.data);
        if (id !== null) handler(id);
      });
    },
  };
}

/** Lo que la app nativa instala en la página: el canal para mandar y la función de pedido que la página define. */
export interface NativeWindow {
  RadiciCaptcha?: { postMessage(message: string): void };
  radiciCaptchaRequest?: (id: unknown) => void;
}

/** Canal "native": el canal JavaScript de webview_flutter (un string JSON) y una función global para el pedido. */
export function nativeTransport(win: NativeWindow): PageTransport {
  return {
    post(message) {
      win.RadiciCaptcha?.postMessage(JSON.stringify(envelope(message)));
    },
    onRequest(handler) {
      win.radiciCaptchaRequest = (id) => {
        if (isRequestId(id)) handler(id);
      };
    },
  };
}

// ── Lado del host en la web ────────────────────────────────────────────────────────────────────────────────────
// Lo usa /accesso/ (src/captcha/host.ts) para pedir un token con el mismo protocolo que la app de Flutter
// (app/lib/core/captcha/captcha_protocol.dart): el pedido sale con el origen exacto como destino y solo se acepta lo
// que llega de ese origen y de la ventana del marco que se abrió.

/** El pedido del host a la página: la marca, la versión y el id. */
export function requestEnvelope(id: string): Record<string, unknown> {
  return { source: CAPTCHA_SOURCE, v: CAPTCHA_VERSION, type: "request", id };
}

/** Un mensaje de la página, leído por el host, o null si no es uno válido (otra marca, otra versión, otra forma). */
export function parsePageMessage(raw: unknown): PageMessage | null {
  if (typeof raw !== "object" || raw === null) return null;
  const message = raw as Record<string, unknown>;
  if (message["source"] !== CAPTCHA_SOURCE || message["v"] !== CAPTCHA_VERSION) return null;
  const id = message["id"];
  switch (message["type"]) {
    case "ready":
      return { type: "ready" };
    case "interactive":
      return isRequestId(id) && typeof message["visible"] === "boolean" ? { type: "interactive", id, visible: message["visible"] } : null;
    case "token":
      return isRequestId(id) && isTokenShape(message["token"]) ? { type: "token", id, token: message["token"] } : null;
    case "error":
      return isRequestId(id) ? { type: "error", id, code: safeCode(message["code"]) } : null;
    default:
      return null;
  }
}

/**
 * Un mensaje de la página es de fiar para el host solo si viene del mismo origen exacto y de la ventana del marco que
 * abrió (no de otro marco ni de otra ventana del mismo sitio).
 */
export function isTrustedPageEvent(event: Pick<FrameEvent, "origin" | "source">, ownOrigin: string, frameWindow: unknown): boolean {
  return ownOrigin !== "null" && frameWindow !== null && frameWindow !== undefined && event.origin === ownOrigin && event.source === frameWindow;
}

/** Un id de pedido nuevo: 128 bits al azar en hexadecimal (isRequestId). */
export function newRequestId(fillRandom: (bytes: Uint8Array<ArrayBuffer>) => Uint8Array): string {
  return Array.from(fillRandom(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
