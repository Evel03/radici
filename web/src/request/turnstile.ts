// Cloudflare Turnstile en modo explícito, solo en /richiesta/ (el script no se carga en otras páginas).
// Docs consultadas el 19/10/2026: client-side-rendering y widget-configurations (act. 06/2026),
// client-side-errors y error-codes (act. 05/2026 y 09/2026), testing (sitekeys de prueba). Revisadas
// el 22/11/2026: widget-configurations (act. 28/06/2026), error-codes (25/09/2026) y testing (05/11/2026).
// - El script se carga desde su URL oficial: Cloudflare pide no copiarlo ni cachearlo.
// - La CSP de /richiesta/ permite https://challenges.cloudflare.com en script-src y frame-src.
// - Siempre hay error-callback: sin él, Turnstile tira una excepción ante cualquier error.
// - Widget trabado (22/11/2026): en Edge, la prevención de seguimiento puede dejar el iframe en blanco sin
//   ningún callback (probado con el iframe retenido: el primer error, 300030, llega recién a los ~43 s).
//   Sin token ni error a los TURNSTILE_STALL_MS, la página sugiere otro navegador o una excepción.

import type { MessageKey } from "../i18n/core.ts";

export const TURNSTILE_ORIGIN = "https://challenges.cloudflare.com";
const ONLOAD_CALLBACK = "radiciTurnstileLoaded";
export const TURNSTILE_SCRIPT_URL = `${TURNSTILE_ORIGIN}/turnstile/v0/api.js?render=explicit&onload=${ONLOAD_CALLBACK}`;

/** Acción del widget: la Edge Function puede comprobarla en la respuesta de siteverify. */
export const TURNSTILE_ACTION = "public-request";

export type TurnstileStatus =
  /** Cargando el script. */
  | "loading"
  /** Widget dibujado, todavía sin token (o reiniciado). */
  | "pending"
  /** Hay token. */
  | "solved"
  /** El desafío falló: Turnstile reintenta solo y también se puede reintentar a mano. */
  | "failed"
  /** No cargó el script (red, bloqueador) o el navegador no es compatible. */
  | "unavailable"
  /** Sitekey o dominio no válidos: no depende del cliente. */
  | "misconfigured";

export interface TurnstileRenderOptions {
  sitekey: string;
  action?: string;
  theme?: "auto" | "light" | "dark";
  language?: string;
  size?: "normal" | "flexible" | "compact";
  "response-field"?: boolean;
  callback?: (token: string) => void;
  "error-callback"?: (code: string) => boolean | void;
  "expired-callback"?: () => void;
  "timeout-callback"?: () => void;
  /** El desafío pasa a pedir que la persona toque la casilla (modo interactivo). */
  "before-interactive-callback"?: () => void;
  /** Sale del modo interactivo (la tocó, o venció). */
  "after-interactive-callback"?: () => void;
  "unsupported-callback"?: () => void;
}

/** La parte de window.turnstile que se usa. */
export interface TurnstileApi {
  render(container: HTMLElement, options: TurnstileRenderOptions): string | null | undefined;
  reset(widgetId: string): void;
  remove(widgetId: string): void;
}

/** "flexible" ocupa el ancho del contenedor pero necesita 300 px; si no entra, "compact" (150 × 140 px). */
export function widgetSize(containerWidth: number): "flexible" | "compact" {
  return containerWidth >= 300 ? "flexible" : "compact";
}

/** Error-codes de Turnstile: 1101xx/1102xx/1104xx y 400020 son de configuración; 1105xx, navegador. */
export function classifyError(code: string): "failed" | "unavailable" | "misconfigured" {
  if (/^(110[124]\d\d|400020)$/.test(code)) return "misconfigured";
  if (/^1105\d\d$/.test(code)) return "unavailable";
  return "failed";
}

/**
 * Sin token ni error este tiempo después de dibujar (o reiniciar) el widget, se da por trabado. Un desafío
 * normal termina en pocos segundos; con la casilla a la vista (modo interactivo) no cuenta.
 */
export const TURNSTILE_STALL_MS = 15_000;

/**
 * El código que recibe error-callback, para mostrarlo («Codice: 200500») y que soporte lo diagnostique.
 * Solo letras, dígitos y guiones: cualquier otra cosa no es un código y no se muestra.
 */
export function errorCodeText(code: unknown): string | null {
  // Los códigos llegan como texto ("200500"); un número también vale si es un entero (NaN no).
  const text = typeof code === "string" ? code.trim() : Number.isSafeInteger(code) ? String(code) : "";
  return /^[\w-]{1,32}$/.test(text) ? text : null;
}

export interface TurnstileViewInput {
  status: TurnstileStatus;
  /** Código del último error (errorCodeText), o null. */
  errorCode: string | null;
  /** Sin token ni error TURNSTILE_STALL_MS después de dibujarlo. */
  stalled: boolean;
  /** El servidor rechazó el último token (403) y todavía no llegó otro. */
  rejected: boolean;
}

export interface TurnstileView {
  /** Error junto al widget. */
  error: Extract<MessageKey, "errors.turnstileFailed" | "errors.turnstileUnavailable" | "errors.turnstileMisconfigured"> | null;
  /** Código para soporte, debajo del error. */
  code: string | null;
  /** Sugerencia: la prevención de seguimiento o un bloqueador pueden frenarlo; otro navegador o una excepción. */
  help: boolean;
  /** Botón «Ripeti la verifica». */
  retry: boolean;
}

/** Lo que se muestra junto al widget según su estado. La sugerencia se va en cuanto llega un token. */
export function turnstileView({ status, errorCode, stalled, rejected }: TurnstileViewInput): TurnstileView {
  switch (status) {
    case "failed":
      return { error: "errors.turnstileFailed", code: errorCode, help: true, retry: true };
    case "unavailable":
      return { error: "errors.turnstileUnavailable", code: errorCode, help: true, retry: true };
    case "misconfigured":
      // Sitekey o dominio: no depende del navegador de quien escribe, la sugerencia no le serviría.
      return { error: "errors.turnstileMisconfigured", code: errorCode, help: false, retry: false };
    case "loading":
    case "pending":
      return { error: rejected ? "errors.turnstileFailed" : null, code: null, help: stalled, retry: stalled };
    case "solved":
      return { error: null, code: null, help: false, retry: false };
  }
}

/** Estado del envío que espera el token: si el widget se trabó, que mire la sugerencia. */
export function waitingStatus(stalled: boolean): Extract<MessageKey, "request.statusWaitingTurnstile" | "request.statusTurnstileStalled"> {
  return stalled ? "request.statusTurnstileStalled" : "request.statusWaitingTurnstile";
}

let loading: Promise<TurnstileApi> | null = null;

/**
 * window.turnstile es la API solo si tiene render: un elemento con id="turnstile" también aparece
 * como window.turnstile (acceso por nombre del DOM) y no hay que confundirlo.
 */
export function isTurnstileApi(value: unknown): value is TurnstileApi {
  return typeof value === "object" && value !== null && typeof (value as { render?: unknown }).render === "function";
}

/** Inserta el script una sola vez; si falla, el próximo intento lo vuelve a insertar. */
export function loadTurnstileScript(): Promise<TurnstileApi> {
  const win = window as unknown as Record<string, unknown>;
  const existing = win["turnstile"];
  if (isTurnstileApi(existing)) return Promise.resolve(existing);
  loading ??= new Promise<TurnstileApi>((resolve, reject) => {
    const script = document.createElement("script");
    const fail = (): void => {
      script.remove();
      loading = null;
      reject(new Error("No se pudo cargar Turnstile"));
    };
    const ready = (): void => {
      const api = win["turnstile"];
      if (isTurnstileApi(api)) resolve(api);
      else fail();
    };
    // Lo llama api.js cuando está listo (parámetro onload de la URL).
    win[ONLOAD_CALLBACK] = ready;
    script.src = TURNSTILE_SCRIPT_URL;
    script.async = true;
    // Respaldo: si el callback no llega, a los 5 s de cargado se usa window.turnstile o se da por fallido.
    script.onload = () => window.setTimeout(ready, 5000);
    script.onerror = fail;
    document.head.append(script);
  });
  return loading;
}

export interface TurnstileWidget {
  readonly status: TurnstileStatus;
  /** Token vigente o null. Cada token sirve para un solo envío. */
  readonly token: string | null;
  /** Código del error vigente (error-callback), para soporte; null sin error o si no trajo código. */
  readonly errorCode: string | null;
  /**
   * Sin token ni error TURNSTILE_STALL_MS después de dibujarlo (o reiniciarlo), y sin pedir que toque la
   * casilla: puede estar bloqueado por el navegador. Sigue así, también al reiniciar, hasta que llegue un token.
   */
  readonly stalled: boolean;
  /**
   * Pide un token nuevo: después de un envío fallido (el token ya se usó o pudo usarse) y en el botón
   * "Ripeti la verifica". Si el script no había cargado, lo vuelve a intentar.
   */
  reset(): void;
  /** Cambio de idioma de la página: vuelve a dibujar el widget en ese idioma. */
  setLanguage(language: string): void;
}

export interface MountOptions {
  siteKey: string;
  /** Código ISO 639-1 (it, es, en). */
  language: string;
  /** Se llama en cada cambio de estado o de token. */
  onChange: () => void;
}

export function mountTurnstile(
  container: HTMLElement,
  opts: MountOptions,
  deps: { load: () => Promise<TurnstileApi> } = { load: loadTurnstileScript },
): TurnstileWidget {
  let api: TurnstileApi | null = null;
  let widgetId: string | null = null;
  let status: TurnstileStatus = "loading";
  let token: string | null = null;
  let errorCode: string | null = null;
  let stalled = false;
  /** El desafío muestra la casilla y espera que la toque: está a la vista, no trabado. */
  let interactive = false;
  let stallTimer: ReturnType<typeof setTimeout> | undefined;
  let language = opts.language;

  const changed = (): void => {
    // Para el CSS y para las pruebas de punta a punta.
    container.dataset["status"] = status;
    opts.onChange();
  };

  const set = (next: TurnstileStatus, nextToken: string | null = null): void => {
    status = next;
    token = nextToken;
    changed();
  };

  /** Vuelve a contar TURNSTILE_STALL_MS: si para entonces sigue sin token ni error, está trabado. */
  const watchStall = (): void => {
    clearTimeout(stallTimer);
    stallTimer = setTimeout(() => {
      if (stalled || interactive || (status !== "loading" && status !== "pending")) return;
      stalled = true;
      changed();
    }, TURNSTILE_STALL_MS);
  };

  /** Espera un token: después de dibujarlo, de reiniciarlo o de que venza el anterior. */
  const waitForToken = (): void => {
    errorCode = null;
    if (!interactive) watchStall();
    set("pending");
  };

  const fail = (next: TurnstileStatus, code: string | null): void => {
    interactive = false;
    errorCode = code;
    clearTimeout(stallTimer);
    set(next);
  };

  const render = (): void => {
    if (!api) return;
    if (widgetId) api.remove(widgetId);
    widgetId = null;
    interactive = false;
    try {
      widgetId =
        api.render(container, {
          sitekey: opts.siteKey,
          action: TURNSTILE_ACTION,
          // Claro siempre, como el sitio (solo modo claro): en "auto" saldría oscuro sobre el crema.
          theme: "light",
          language,
          size: widgetSize(container.clientWidth),
          // El token se lee de los callbacks: sin input oculto dentro del formulario.
          "response-field": false,
          callback: (value) => {
            interactive = false;
            stalled = false;
            errorCode = null;
            clearTimeout(stallTimer);
            set("solved", value);
          },
          "error-callback": (code) => {
            fail(classifyError(String(code)), errorCodeText(code));
            // Sin return: Turnstile deja en consola un aviso con el código (útil para diagnosticar).
          },
          "expired-callback": () => {
            interactive = false;
            waitForToken();
          },
          "timeout-callback": () => {
            interactive = false;
            waitForToken();
          },
          "before-interactive-callback": () => {
            interactive = true;
            clearTimeout(stallTimer);
            if (stalled) {
              stalled = false;
              changed();
            }
          },
          "after-interactive-callback": () => {
            interactive = false;
            if (status === "loading" || status === "pending") watchStall();
          },
          "unsupported-callback": () => fail("unavailable", null),
        }) ?? null;
      waitForToken();
    } catch {
      fail("unavailable", null);
    }
  };

  const load = (): void => {
    errorCode = null;
    // Un script que no termina de cargar también deja esperando a quien escribe.
    watchStall();
    set("loading");
    deps
      .load()
      .then((loaded) => {
        api = loaded;
        render();
      })
      .catch(() => fail("unavailable", null));
  };

  const reset = (): void => {
    if (!api) load();
    else if (!widgetId) render();
    else {
      interactive = false;
      api.reset(widgetId);
      waitForToken();
    }
  };

  load();

  return {
    get status() {
      return status;
    },
    get token() {
      return token;
    },
    get errorCode() {
      return errorCode;
    },
    get stalled() {
      return stalled;
    },
    reset,
    setLanguage(next) {
      if (next === language) return;
      language = next;
      render();
    },
  };
}
