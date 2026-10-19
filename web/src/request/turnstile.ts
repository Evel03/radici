// Cloudflare Turnstile en modo explícito, solo en /richiesta/ (el script no se carga en otras páginas).
// Docs consultadas el 19/10/2026: client-side-rendering y widget-configurations (act. 06/2026),
// client-side-errors y error-codes (act. 05/2026 y 09/2026), testing (sitekeys de prueba).
// - El script se carga desde su URL oficial: Cloudflare pide no copiarlo ni cachearlo.
// - La CSP de /richiesta/ permite https://challenges.cloudflare.com en script-src y frame-src.
// - Siempre hay error-callback: sin él, Turnstile tira una excepción ante cualquier error.

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
  let language = opts.language;

  const set = (next: TurnstileStatus, nextToken: string | null = null): void => {
    status = next;
    token = nextToken;
    // Para el CSS y para las pruebas de punta a punta.
    container.dataset["status"] = next;
    opts.onChange();
  };

  const render = (): void => {
    if (!api) return;
    if (widgetId) api.remove(widgetId);
    widgetId = null;
    try {
      widgetId =
        api.render(container, {
          sitekey: opts.siteKey,
          action: TURNSTILE_ACTION,
          theme: "auto",
          language,
          size: widgetSize(container.clientWidth),
          // El token se lee de los callbacks: sin input oculto dentro del formulario.
          "response-field": false,
          callback: (value) => set("solved", value),
          "error-callback": (code) => {
            set(classifyError(String(code)));
            // Sin return: Turnstile deja en consola un aviso con el código (útil para diagnosticar).
          },
          "expired-callback": () => set("pending"),
          "timeout-callback": () => set("pending"),
          "unsupported-callback": () => set("unavailable"),
        }) ?? null;
      set("pending");
    } catch {
      set("unavailable");
    }
  };

  const load = (): void => {
    set("loading");
    deps
      .load()
      .then((loaded) => {
        api = loaded;
        render();
      })
      .catch(() => set("unavailable"));
  };

  const reset = (): void => {
    if (!api) load();
    else if (!widgetId) render();
    else {
      api.reset(widgetId);
      set("pending");
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
    reset,
    setLanguage(next) {
      if (next === language) return;
      language = next;
      render();
    },
  };
}
