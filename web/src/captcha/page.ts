// La lógica de /captcha/: dibuja el widget de Turnstile (sitekey de Auth) cuando el host pide un token y se lo
// devuelve con el id del pedido. Sin DOM propio: recibe el contenedor y avisa el estado (se testea con simulacros).
// Turnstile corre con appearance "interaction-only": sin casilla a la vista salvo que Cloudflare pida que la persona
// la toque (ahí avisa `interactive` y el host agranda el marco o la ventana). Cada token se entrega una sola vez, a
// quien lo pidió, y nunca se guarda ni se registra.
import type { TurnstileApi } from "../request/turnstile.ts";
import { CAPTCHA_ACTION, safeCode, type PageTransport } from "./protocol.ts";

export type PageState = "idle" | "working" | "interactive";

export interface PageDeps {
  siteKey: string | null;
  language: string;
  transport: PageTransport;
  container: HTMLElement;
  loadApi: () => Promise<TurnstileApi>;
  onState: (state: PageState) => void;
}

export interface CaptchaPage {
  /** El botón «Annulla» de la página: el pedido en curso termina con el código "cancelled". */
  cancel(): void;
}

export function startCaptchaPage(deps: PageDeps): CaptchaPage {
  const { transport } = deps;
  let api: TurnstileApi | null = null;
  let widgetId: string | null = null;
  let pending: string | null = null;
  let interactive = false;

  const finish = (message: { type: "token"; token: string } | { type: "error"; code: string }): void => {
    const id = pending;
    if (id === null) return;
    pending = null;
    interactive = false;
    deps.onState("idle");
    transport.post({ ...message, id });
  };

  const fail = (code: unknown): void => finish({ type: "error", code: safeCode(code) });

  const render = (): void => {
    if (!api) return;
    try {
      widgetId =
        api.render(deps.container, {
          sitekey: deps.siteKey ?? "",
          action: CAPTCHA_ACTION,
          theme: "light",
          language: deps.language,
          size: "normal",
          // Solo se ve si Cloudflare pide que la persona toque la casilla.
          appearance: "interaction-only",
          // El token no se guarda para después: cada pedido arranca un desafío nuevo (reset).
          "refresh-expired": "manual",
          "response-field": false,
          callback: (token) => finish({ type: "token", token }),
          "error-callback": (code) => {
            fail(code);
            // Sin return: Turnstile deja en la consola un aviso con el código (útil para diagnosticar).
          },
          "expired-callback": () => {},
          "timeout-callback": () => fail("timeout"),
          "unsupported-callback": () => fail("unsupported"),
          "before-interactive-callback": () => {
            if (pending === null) return;
            interactive = true;
            deps.onState("interactive");
            transport.post({ type: "interactive", id: pending, visible: true });
          },
          "after-interactive-callback": () => {
            if (pending === null || !interactive) return;
            interactive = false;
            deps.onState("working");
            transport.post({ type: "interactive", id: pending, visible: false });
          },
        }) ?? null;
      if (widgetId === null) fail("unavailable");
    } catch {
      fail("unavailable");
    }
  };

  const request = (id: string): void => {
    // Un pedido nuevo reemplaza al anterior (el host ya lo dio por perdido).
    pending = id;
    interactive = false;
    if (!deps.siteKey) {
      fail("misconfigured");
      return;
    }
    deps.onState("working");
    if (api) {
      if (widgetId === null) {
        render();
        return;
      }
      try {
        api.reset(widgetId);
      } catch {
        fail("unavailable");
      }
      return;
    }
    deps
      .loadApi()
      .then((loaded) => {
        api = loaded;
        if (pending !== null && widgetId === null) render();
      })
      .catch(() => fail("unavailable"));
  };

  transport.onRequest(request);
  transport.post({ type: "ready" });

  return { cancel: () => fail("cancelled") };
}
