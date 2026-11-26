// /preferenze/: confirmar o darse de baja de las ofertas y novedades desde el link del email (docs/contracts/
// public-request.md §13). La lógica vive en src/preferences/ (pura y testeada); acá se lee el token, se lo saca de la
// URL, se pinta el estado y se pasan los toques. Nunca se registran en la consola el token ni el email, y nada se guarda.
import "../styles/base.css";
import "../styles/access.css";
import { createMarketingApi } from "../preferences/api.ts";
import { createPreferences, type PreferencesState } from "../preferences/flow.ts";
import { readToken } from "../reservation/token.ts";
import { config } from "../site-config.ts";
import { initLanguage } from "./shell.ts";

function byId<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Falta #${id} en el HTML`);
  return el as T;
}

/** Lee el token del fragmento y lo saca de la URL enseguida (recargar o compartir la pestaña ya no lo lleva). */
function takeToken(): string | null {
  const token = readToken(window.location.hash);
  if (window.location.hash !== "") {
    window.history.replaceState(window.history.state, "", `${window.location.pathname}${window.location.search}`);
  }
  return token;
}

const token = takeToken();
initLanguage();

const STEPS = ["missing", "loading", "failed", "notFound", "pending", "confirmed", "withdrawn"] as const;
type Step = (typeof STEPS)[number];
const sections = new Map<Step, HTMLElement>(STEPS.map((step) => [step, byId(`pref-${step}`)]));
const confirmButton = byId<HTMLButtonElement>("pref-confirm");
const declineButton = byId<HTMLButtonElement>("pref-decline");
const withdrawButton = byId<HTMLButtonElement>("pref-withdraw");
const retryButton = byId<HTMLButtonElement>("pref-retry");

const preferences = createPreferences(token, createMarketingApi({ supabaseUrl: config.supabaseUrl }), () => paint());

/** Muestra solo los hijos de `root` cuyo atributo `attr` vale `value` (null: ninguno). */
function showMatching(root: HTMLElement, attr: string, value: string | null): void {
  for (const el of root.querySelectorAll<HTMLElement>(`[${attr}]`)) el.hidden = el.getAttribute(attr) !== value;
}

/** El error de una caja; uno nuevo se vuelve a insertar para que lo anuncien los lectores de pantalla. */
function paintError(box: HTMLElement | null, error: string | null): void {
  if (!box) return;
  box.hidden = error === null;
  showMatching(box, "data-error", error);
  const shown = error === null ? null : box.querySelector<HTMLElement>(`[data-error="${error}"]`);
  if (shown) shown.replaceWith(shown.cloneNode(true));
}

/** Un botón ocupado conserva el foco pero no hace nada (aria-disabled, no disabled). */
function setBusy(button: HTMLButtonElement, busy: boolean): void {
  if (busy) button.setAttribute("aria-disabled", "true");
  else button.removeAttribute("aria-disabled");
}

let previous: PreferencesState | null = null;

function paint(): void {
  const state = preferences.state();
  for (const [step, section] of sections) section.hidden = step !== state.step;
  const section = sections.get(state.step);

  if (state.step === "failed") paintError(byId("pref-failed-error"), state.error);
  if (section && "busy" in state) {
    for (const line of section.querySelectorAll<HTMLElement>("[data-email-line]")) line.hidden = state.email === null;
    for (const strong of section.querySelectorAll<HTMLElement>("[data-email]")) strong.textContent = state.email ?? "";
    if (previous?.step !== state.step || ("error" in previous && previous.error !== state.error)) {
      paintError(section.querySelector<HTMLElement>("[data-action-error]"), state.error);
    }
    for (const button of [confirmButton, declineButton, withdrawButton]) setBusy(button, state.busy);
  }
  // Al cambiar de sección, el foco va al título (lo anuncia el lector de pantalla); no en la primera pintada.
  if (previous !== null && previous.step !== state.step && state.step !== "loading") byId(`pref-${state.step}-title`).focus();
  previous = state;
}

confirmButton.addEventListener("click", () => void preferences.confirm());
declineButton.addEventListener("click", () => void preferences.withdraw());
withdrawButton.addEventListener("click", () => void preferences.withdraw());
retryButton.addEventListener("click", () => void preferences.load());

paint();
void preferences.load();
