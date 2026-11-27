// /accesso/: confirmar el alta o elegir una contraseña nueva desde el link de un email de Auth (docs/contracts/auth.md
// §11). Toda la lógica vive en src/access/ (pura y testeada); acá se lee el link, se lo saca de la URL, se pinta el
// estado y se pasan los toques. Nunca se registran en la consola el link, la sesión, el email ni la contraseña, y nada
// de eso se guarda: ni localStorage, ni sessionStorage, ni cookies.
import "../styles/base.css";
import "../styles/access.css";
import { createAuthApi } from "../access/api.ts";
import { createAccess } from "../access/flow.ts";
import { addressWithoutFragment, hasLinkParams, readAccessLink } from "../access/link.ts";
import { viewOf, type AccessView, type Step } from "../access/view.ts";
import { openFrameSession, requestCaptchaToken } from "../captcha/host.ts";
import { config } from "../site-config.ts";
import { initLanguage } from "./shell.ts";

function byId<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Falta #${id} en el HTML`);
  return el as T;
}

/** Lee el link del fragmento y lo saca de la URL enseguida (recargar o compartir la pestaña ya no lo lleva). */
function takeLink(): ReturnType<typeof readAccessLink> {
  const hash = window.location.hash;
  const read = readAccessLink(hash);
  if (hasLinkParams(hash)) window.history.replaceState(window.history.state, "", addressWithoutFragment(window.location));
  return read;
}

const read = takeLink();

// Los textos ya vienen en el HTML (en italiano, del build); el selector cambia el idioma sin esperar nada de acá.
initLanguage();

const STEPS: readonly Step[] = ["missing", "confirm", "password", "done", "expired"];
const sections = new Map(STEPS.map((step) => [step, byId(`access-${step}`)]));
const confirmButton = byId<HTMLButtonElement>("access-confirm-button");
const passwordForm = byId<HTMLFormElement>("access-password-form");
const passwordInput = byId<HTMLInputElement>("access-new-password");
const repeatInput = byId<HTMLInputElement>("access-repeat-password");
const passwordButton = byId<HTMLButtonElement>("access-password-button");
const showPassword = byId<HTMLInputElement>("access-show-password");
const username = byId<HTMLInputElement>("access-username");
const maskedEmail = byId("access-masked-email");
const loginLink = byId<HTMLAnchorElement>("access-login");
const resendForm = byId<HTMLFormElement>("access-resend-form");
const resendEmail = byId<HTMLInputElement>("access-resend-email");
const resendButton = byId<HTMLButtonElement>("access-resend-button");
const resendSent = byId("access-resend-sent");
const errors: Partial<Record<Step, HTMLElement>> = {
  confirm: byId("access-confirm-error"),
  password: byId("access-password-error"),
  expired: byId("access-resend-error"),
};

const access = createAccess(read, {
  api: createAuthApi({ supabaseUrl: config.supabaseUrl, publishableKey: config.supabasePublishableKey }),
  captchaToken: () =>
    requestCaptchaToken({
      open: () =>
        openFrameSession<HTMLIFrameElement>(window, document, document.documentElement.lang || "it", byId("access-captcha-title").textContent ?? ""),
    }),
});

/** Muestra solo los hijos de `root` cuyo atributo `attr` vale `value` (null: ninguno). */
function showMatching(root: HTMLElement, attr: string, value: string | null): void {
  for (const el of root.querySelectorAll<HTMLElement>(`[${attr}]`)) el.hidden = el.getAttribute(attr) !== value;
}

/**
 * El mensaje de error del paso. Un error nuevo (o el mismo otra vez) se vuelve a insertar con la región ya visible:
 * así lo anuncian también los lectores de pantalla que no avisan cuando aparece algo que estaba oculto.
 */
function paintError(box: HTMLElement | undefined, error: string | null, announce: boolean): void {
  if (!box) return;
  box.hidden = error === null;
  showMatching(box, "data-error", error);
  if (error !== null && announce) {
    const shown = box.querySelector<HTMLElement>(`[data-error="${error}"]`);
    if (shown) shown.replaceWith(shown.cloneNode(true));
  }
}

/** Un botón ocupado conserva el foco pero no hace nada (aria-disabled, no disabled). */
function setBusy(button: HTMLButtonElement, busy: boolean): void {
  if (busy) button.setAttribute("aria-disabled", "true");
  else button.removeAttribute("aria-disabled");
}

let previous: AccessView | null = null;

function paint(): void {
  const view = viewOf(access.state);
  const stepChanged = previous?.step !== view.step || previous.type !== view.type || previous.reason !== view.reason;
  const errorChanged = stepChanged || previous?.error !== view.error;

  for (const [step, section] of sections) section.hidden = step !== view.step;
  const section = sections.get(view.step);
  if (section) {
    showMatching(section, "data-type", view.type);
    showMatching(section, "data-reason", view.reason);
  }
  for (const [step, box] of Object.entries(errors)) {
    paintError(box, step === view.step ? view.error : null, errorChanged);
  }

  setBusy(confirmButton, view.step === "confirm" && view.busy);
  setBusy(passwordButton, view.step === "password" && view.busy);
  setBusy(resendButton, view.step === "expired" && view.busy);
  // «No coinciden» marca la repetición; los demás errores de la contraseña, el primer campo.
  const passwordError = view.step === "password" ? view.error : null;
  passwordInput.setAttribute("aria-invalid", passwordError !== null && passwordError !== "network" && passwordError !== "mismatch" ? "true" : "false");
  repeatInput.setAttribute("aria-invalid", passwordError === "mismatch" ? "true" : "false");

  maskedEmail.textContent = view.maskedEmail ?? "";
  username.value = view.username ?? "";
  loginLink.setAttribute("href", view.loginHref ?? "#");

  // «Reinvia» terminado: el mensaje neutro (según el tipo de link) y la sugerencia del spam.
  for (const el of resendSent.querySelectorAll<HTMLElement>("[data-type]")) el.hidden = !view.sent || el.dataset["type"] !== view.type;
  const hint = resendSent.querySelector<HTMLElement>("[data-sent-hint]");
  if (hint) hint.hidden = !view.sent;

  if (stepChanged) {
    // La contraseña escrita no sobrevive a un cambio de paso, y la persona sigue desde el título del paso nuevo.
    for (const input of [passwordInput, repeatInput]) {
      input.value = "";
      input.type = "password";
    }
    showPassword.checked = false;
    if (previous !== null) byId(`access-${view.step}-title`).focus();
  }
  previous = view;
}

access.subscribe(paint);
paint();

confirmButton.addEventListener("click", () => void access.confirm());

passwordForm.addEventListener("submit", (event) => {
  event.preventDefault();
  void access.savePassword(passwordInput.value, repeatInput.value);
});

showPassword.addEventListener("change", () => {
  for (const input of [passwordInput, repeatInput]) input.type = showPassword.checked ? "text" : "password";
});

resendForm.addEventListener("submit", (event) => {
  event.preventDefault();
  void access.resend(resendEmail.value);
});

// Otro link pegado en la misma pestaña: se empieza de nuevo con ese. Un ancla interna («Vai al contenuto», #main) no
// trae nada del link y no cambia nada.
window.addEventListener("hashchange", () => {
  if (!hasLinkParams(window.location.hash)) return;
  access.openLink(takeLink());
});
