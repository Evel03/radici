// /captcha/: el Turnstile de Auth. La abre la app de Evelyn (en un iframe del mismo sitio, o en una WebView con
// ?channel=native) para obtener un token de captcha antes de pedir el código de acceso a Supabase Auth. Toda la
// lógica vive en src/captcha/ (pura y testeada); acá se conecta con el DOM, la ventana y el script de Cloudflare.
// Nunca se registran en la consola ni el token ni el id del pedido.
import "../styles/base.css";
import "../styles/captcha.css";
import { isLang, resolveLang } from "../i18n/core.ts";
import { readStoredLang } from "../lib/storage.ts";
import { loadTurnstileScript } from "../request/turnstile.ts";
import { detectMode, frameTransport, nativeTransport, type FrameWindow, type NativeWindow, type PageTransport } from "../captcha/protocol.ts";
import { startCaptchaPage, type PageState } from "../captcha/page.ts";
import { config } from "../site-config.ts";
import { initShell } from "./shell.ts";

function byId<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Falta #${id} en el HTML`);
  return el as T;
}

const root = byId("captcha");
const working = byId("captcha-working");
const interactive = byId("captcha-interactive");
const cancel = byId<HTMLButtonElement>("captcha-cancel");
const standalone = byId("captcha-standalone");

// Los textos y el idioma (?lang= de quien abre la página): no hace falta esperarlos para hablar con la app.
void initShell();
const lang = resolveLang(window.location.search, readStoredLang());

function show(state: PageState): void {
  root.dataset["state"] = state;
  working.hidden = state !== "working";
  interactive.hidden = state !== "interactive";
  cancel.hidden = state !== "interactive";
}

const mode = detectMode(
  window.location.search,
  typeof (window as unknown as NativeWindow).RadiciCaptcha?.postMessage === "function",
  window.parent !== window,
);

if (mode === "standalone") {
  // Abierta suelta (alguien entró por la URL): no carga Turnstile ni habla con nadie.
  root.dataset["state"] = "standalone";
  standalone.hidden = false;
} else {
  const transport: PageTransport =
    mode === "native" ? nativeTransport(window as unknown as NativeWindow) : frameTransport(window as unknown as FrameWindow);
  show("idle");
  const page = startCaptchaPage({
    siteKey: config.turnstileAuthSiteKey,
    language: isLang(lang) ? lang : "it",
    transport,
    container: byId("captcha-widget"),
    loadApi: loadTurnstileScript,
    onState: show,
  });
  cancel.addEventListener("click", () => page.cancel());
}
