// Calculadora + formulario de pedido. Toda la lógica vive en src/request/ (pura y testeada): acá se lee
// el formulario, se pintan presupuesto, errores y estados, y se manda el pedido a la Edge Function
// `public-request` con el token de Turnstile (docs/contracts/public-request.md §6).
// Nunca se registran en consola datos del pedido (contacto, salud, notas).
import "../styles/base.css";
import "../styles/request.css";
import { LIMITS } from "../engine.ts";
import type { MessageKey, Params } from "../i18n/core.ts";
import { addDays, todayInRome } from "../lib/dates.ts";
import { formatCents } from "../lib/format.ts";
import { DATE_WINDOW, MEAL_OPTIONS, REQUEST_TYPES, SLOTS, TEXT_LIMITS, isOneOf, type RequestData } from "../request/model.ts";
import { buildPayload, type PayloadOptions } from "../request/payload.ts";
import { computeQuote } from "../request/quote.ts";
import { createRequestKeys, doneViewFor, type DoneView } from "../request/request-key.ts";
import { publicRequestUrl, rateLimitMessage, sendPublicRequest, type SubmitOutcome } from "../request/submit.ts";
import { summaryRows } from "../request/summary.ts";
import { loadTurnstileScript, mountTurnstile, type TurnstileWidget } from "../request/turnstile.ts";
import {
  FIELD_ORDER,
  firstErrorField,
  translateErrors,
  validateRequest,
  type FieldError,
  type FieldErrors,
  type FieldName,
} from "../request/validate.ts";
import { config } from "../site-config.ts";
import { initShell, type Shell } from "./shell.ts";

function byId<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Falta #${id} en el HTML`);
  return el as T;
}

/** Controles a marcar con aria-invalid para cada error (los grupos de opciones no tienen uno solo). */
const CONTROLS: Readonly<Record<FieldName, readonly string[]>> = {
  type: [],
  adults: ["adults"],
  kids: ["kids"],
  people: ["adults", "kids"],
  days: ["days"],
  meals: [],
  preferredDate: ["preferredDate"],
  slot: [],
  name: ["name"],
  zone: ["zone"],
  phone: ["phone"],
  whatsappOptIn: ["whatsappOptIn"],
  email: ["email"],
  notes: ["notes"],
  consentPrivacy: ["consentPrivacy"],
  turnstileToken: [],
};
const CONTROL_IDS = [...new Set(Object.values(CONTROLS).flat())];

const form = byId<HTMLFormElement>("request-form");
const layout = byId("request-layout");
const done = byId("done");
const doneReplay = byId("done-replay");
const doneContact = byId("done-contact");
const doneEmail = byId("done-email");
const doneDetails = byId("done-details");
const doneSummary = byId("done-summary");
const configWarning = byId("config-warning");
const formError = byId("form-error");
const formErrorText = byId("form-error-text");
const formRetry = byId<HTMLButtonElement>("form-retry");
const formStatus = byId("form-status");
const submitButton = byId<HTMLButtonElement>("submit");
const submitLabel = byId("submit-label");
// Nunca id="turnstile": el navegador lo expone como window.turnstile y tapa la API de Cloudflare.
const turnstileBox = byId("turnstile-widget");
const turnstileRetry = byId<HTMLButtonElement>("turnstile-retry");
const quoteBody = byId("quote-body");
const quoteInvalid = byId("quote-invalid");
const quoteOut = {
  total: byId("q-total"),
  service: byId("q-service"),
  groceries: byId("q-groceries"),
  portions: byId("q-portions"),
};

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

const endpoint = config.supabaseUrl ? publicRequestUrl(config.supabaseUrl) : null;
const siteKey = endpoint ? config.turnstileSiteKey : null;
// Cloudflare recomienda cargar Turnstile lo antes posible: el script arranca ya, el widget se dibuja
// cuando están los textos. Si falla, mountTurnstile lo vuelve a intentar.
if (siteKey) loadTurnstileScript().catch(() => undefined);

function setText(el: HTMLElement, text: string): void {
  // Evita reescribir (y que el lector de pantalla repita) si no cambió.
  if (el.textContent !== text) el.textContent = text;
}

function setDescribedBy(el: HTMLElement, id: string, on: boolean): void {
  const ids = new Set((el.getAttribute("aria-describedby") ?? "").split(/\s+/).filter(Boolean));
  if (on) ids.add(id);
  else ids.delete(id);
  if (ids.size > 0) el.setAttribute("aria-describedby", [...ids].join(" "));
  else el.removeAttribute("aria-describedby");
}

/** Límites tomados del motor y del contrato: el HTML no los repite. */
function applyLimits(today: string): void {
  const range = (id: string, min: number, max: number): void => {
    const input = byId<HTMLInputElement>(id);
    input.min = String(min);
    input.max = String(max);
  };
  range("adults", 0, LIMITS.maxPeople);
  range("kids", 0, LIMITS.maxPeople);
  range("days", 1, LIMITS.maxDays);
  for (const [id, max] of Object.entries(TEXT_LIMITS)) {
    const el = document.getElementById(id);
    if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) el.maxLength = max;
  }
  const date = byId<HTMLInputElement>("preferredDate");
  date.min = addDays(today, DATE_WINDOW.minDaysAhead);
  date.max = addDays(today, DATE_WINDOW.maxDaysAhead);
}

function readForm(): RequestData {
  const fd = new FormData(form);
  const str = (name: string): string => {
    const value = fd.get(name);
    return typeof value === "string" ? value : "";
  };
  const int = (name: string): number => {
    const value = str(name).trim();
    return value === "" ? Number.NaN : Number(value);
  };
  const type = str("type");
  const meals = str("meals");
  const slot = str("slot");
  return {
    type: isOneOf(REQUEST_TYPES, type) ? type : "week",
    adults: int("adults"),
    kids: int("kids"),
    days: int("days"),
    meals: isOneOf(MEAL_OPTIONS, meals) ? meals : "dinner",
    preferredDate: str("preferredDate"),
    slot: isOneOf(SLOTS, slot) ? slot : "any",
    name: str("name"),
    zone: str("zone"),
    phone: str("phone"),
    email: str("email"),
    whatsappOptIn: fd.has("whatsappOptIn"),
    notes: str("notes"),
    consentPrivacy: fd.has("consentPrivacy"),
  };
}

function syncSteppers(): void {
  for (const btn of form.querySelectorAll<HTMLButtonElement>("button[data-step]")) {
    const input = byId<HTMLInputElement>(btn.getAttribute("aria-controls") ?? "");
    const value = Number(input.value);
    const atLimit = Number(btn.dataset["step"]) < 0 ? value <= Number(input.min) : value >= Number(input.max);
    // aria-disabled en vez de disabled: el botón no pierde el foco al llegar al límite.
    btn.setAttribute("aria-disabled", String(input.value !== "" && atLimit));
  }
}

/** Al salir de un stepper escrito a mano, el valor vuelve a un entero dentro del rango. */
function normalizeStepper(input: HTMLInputElement): void {
  if (input.value.trim() === "") return;
  const value = Math.round(Number(input.value));
  const next = Number.isNaN(value) ? Number(input.min) : Math.min(Number(input.max), Math.max(Number(input.min), value));
  if (String(next) !== input.value) input.value = String(next);
}

function step(btn: HTMLButtonElement): void {
  const input = byId<HTMLInputElement>(btn.getAttribute("aria-controls") ?? "");
  const min = Number(input.min);
  const max = Number(input.max);
  const current = Number.parseInt(input.value, 10);
  const next = Number.isNaN(current) ? min : Math.min(max, Math.max(min, current + Number(btn.dataset["step"])));
  if (String(next) !== input.value) {
    input.value = String(next);
    form.dispatchEvent(new Event("input"));
  }
}

/** Los errores de Turnstile se muestran junto al widget, según su estado (no los da la validación). */
function withoutTurnstile(errors: FieldErrors): FieldErrors {
  const copy = { ...errors };
  delete copy.turnstileToken;
  return copy;
}

interface FormMessage {
  key: MessageKey;
  params?: Params;
  /** Muestra el botón "Riprova" (errores de red o del servidor). */
  retry?: boolean;
}

/**
 * En mobile el panel del presupuesto queda fijo abajo y tapa lo que pasa por detrás. Su alto real (cambia
 * con el idioma, el tamaño de letra o el zoom) va a --quote-height, que usa el scroll-padding de
 * request.css: así el control con foco nunca queda debajo del panel.
 */
function trackQuoteHeight(panel: HTMLElement): void {
  const root = document.documentElement;
  const apply = (): void => {
    root.style.setProperty("--quote-height", `${Math.ceil(panel.getBoundingClientRect().height)}px`);
  };
  apply();
  if (typeof ResizeObserver === "function") new ResizeObserver(apply).observe(panel);
}

function startRequestPage(shell: Shell): void {
  let phase: "editing" | "sending" | "done" = "editing";
  /** Clave de idempotencia: la misma en los reintentos, para que el servidor nunca duplique el pedido. */
  const keys = createRequestKeys();
  /** Después del primer intento de envío los errores se actualizan mientras se escribe. */
  let submitted = false;
  /** El cliente pidió enviar y falta el token de Turnstile: se envía solo cuando llegue. */
  let pendingSubmit = false;
  /** El servidor rechazó el token (403): se avisa hasta que haya uno nuevo. */
  let turnstileRejected = false;
  /**
   * Errores que devolvió el servidor (400) y los datos con que se mandó el pedido: valen mientras el
   * formulario no cambie (un evento change por mover el foco no cuenta como cambio).
   */
  let server: { errors: FieldErrors; data: string } | null = null;
  const serverErrors = (data: RequestData): FieldErrors =>
    server && server.data === JSON.stringify(data) ? server.errors : {};
  let formMessage: FormMessage | null = null;
  let statusKey: MessageKey | null = null;
  /**
   * Pantalla de gracias: los datos y el email que tiene guardados el servidor (null si no se sabe: un
   * reintento después de varios envíos sin respuesta con datos distintos) y el aviso de reintento.
   */
  let success: {
    data: RequestData | null;
    email: string | null;
    estimate: { totalCents: number } | null;
    replay: DoneView["replay"];
  } | null = null;
  let turnstile: TurnstileWidget | null = null;

  const payloadOptions = (turnstileToken: string): PayloadOptions => ({ locale: shell.i18n.lang, turnstileToken });

  const renderQuote = (data: RequestData): void => {
    const { i18n } = shell;
    const quote = computeQuote(data);
    quoteBody.hidden = quote === null;
    quoteInvalid.hidden = quote !== null;
    if (!quote) return;
    setText(quoteOut.total, formatCents(quote.totalCents, i18n.locale));
    setText(quoteOut.service, formatCents(quote.serviceCents, i18n.locale));
    setText(quoteOut.groceries, formatCents(quote.groceriesEstCents, i18n.locale));
    setText(quoteOut.portions, String(quote.portions));
  };

  const turnstileError = (): FieldError | null => {
    switch (turnstile?.status) {
      case "unavailable":
        return { key: "errors.turnstileUnavailable" };
      case "misconfigured":
        return { key: "errors.turnstileMisconfigured" };
      case "failed":
        return { key: "errors.turnstileFailed" };
      case "loading":
      case "pending":
        return turnstileRejected ? { key: "errors.turnstileFailed" } : null;
      default:
        return null;
    }
  };

  const paintErrors = (errors: FieldErrors): void => {
    const invalid = new Set<string>();
    for (const field of FIELD_ORDER) {
      const error = errors[field];
      const errorEl = byId(`err-${field}`);
      setText(errorEl, error ? shell.i18n.t(error.key, error.params) : "");
      errorEl.hidden = !error;
      for (const id of CONTROLS[field]) {
        setDescribedBy(byId(id), errorEl.id, Boolean(error));
        if (error) invalid.add(id);
      }
    }
    for (const id of CONTROL_IDS) {
      if (invalid.has(id)) byId(id).setAttribute("aria-invalid", "true");
      else byId(id).removeAttribute("aria-invalid");
    }
    turnstileRetry.hidden = !(turnstile?.status === "failed" || turnstile?.status === "unavailable");
  };

  /** Errores de los campos según la validación local, solo después del primer intento de envío. */
  const fieldErrors = (data: RequestData): FieldErrors =>
    submitted ? withoutTurnstile(validateRequest(data, todayInRome(), payloadOptions(""))) : {};

  const renderErrors = (data: RequestData, errors: FieldErrors = fieldErrors(data)): void => {
    const ts = turnstileError();
    const all = { ...errors, ...serverErrors(data) };
    paintErrors(ts ? { ...all, turnstileToken: ts } : all);
  };

  const paintFormMessage = (): void => {
    formError.hidden = formMessage === null;
    setText(formErrorText, formMessage ? shell.i18n.t(formMessage.key, formMessage.params) : "");
    formRetry.hidden = !formMessage?.retry;
  };

  const showFormMessage = (message: FormMessage | null): void => {
    formMessage = message;
    paintFormMessage();
  };

  const setStatus = (key: MessageKey | null): void => {
    statusKey = key;
    setText(formStatus, key ? shell.i18n.t(key) : "");
  };

  const setSending = (sending: boolean): void => {
    submitButton.disabled = sending;
    setText(submitLabel, shell.i18n.t(sending ? "request.sending" : "request.submit"));
    setStatus(sending ? "request.statusSending" : null);
  };

  const focusField = (field: FieldName): void => {
    let target: HTMLElement | null;
    if (field === "turnstileToken") target = turnstileRetry.hidden ? turnstileBox : turnstileRetry;
    else {
      const id = CONTROLS[field][0];
      // Grupos de opciones (tipo, comidas, alérgenos, dietas, franja): la primera opción.
      target = id ? byId(id) : form.querySelector<HTMLInputElement>(`input[name="${field}"]`);
    }
    if (!target) return;
    target.focus({ preventScroll: true });
    // Se centra el mensaje de error (el campo queda justo arriba): así el panel fijo no lo tapa.
    const errorEl = byId(`err-${field}`);
    (errorEl.hidden ? target : errorEl).scrollIntoView({
      block: "center",
      behavior: reducedMotion.matches ? "auto" : "smooth",
    });
  };

  const renderDone = (): void => {
    if (!success) return;
    const { t } = shell.i18n;
    doneReplay.hidden = success.replay === null;
    if (success.replay !== null) {
      setText(doneReplay, t(success.replay === "earlier" ? "request.done.replayedEarlier" : "request.done.replayedUnknown"));
    }
    doneContact.hidden = success.email === null;
    if (success.email !== null) setText(doneEmail, t("request.done.email", { email: success.email }));
    doneDetails.hidden = success.data === null;
    if (success.data === null) {
      doneSummary.replaceChildren();
      return;
    }
    doneSummary.replaceChildren(
      ...summaryRows(success.data, success.estimate, shell.i18n).map((row) => {
        const item = document.createElement("div");
        item.className = row.total ? "summary__row summary__row--total" : "summary__row";
        const dt = document.createElement("dt");
        dt.textContent = row.label;
        const dd = document.createElement("dd");
        dd.textContent = row.value;
        item.append(dt, dd);
        return item;
      }),
    );
  };

  /** El servidor guarda el email limpio y en minúsculas: se muestra igual. */
  const emailOf = (data: RequestData): string => buildPayload(data, payloadOptions("")).email.toLowerCase();

  /**
   * @param view lo que tiene guardado el servidor (doneViewFor): en un reintento con cambios, los datos
   * del envío que llegó (la estimación del servidor es la de ese pedido), nunca los del formulario.
   */
  const showDone = (view: DoneView, estimate: { totalCents: number } | null): void => {
    phase = "done";
    const { data } = view;
    success = {
      data,
      email: data ? emailOf(data) : null,
      estimate: data ? (estimate ?? computeQuote(data)) : null,
      replay: view.replay,
    };
    renderDone();
    layout.hidden = true;
    done.hidden = false;
    done.focus();
  };

  const handleOutcome = (outcome: SubmitOutcome, data: RequestData, view: DoneView): void => {
    if (outcome.kind === "created") {
      showDone(view, outcome.estimate);
      return;
    }
    // Cualquier fallo: el token ya se usó o pudo usarse, Turnstile pide uno nuevo.
    turnstile?.reset();
    switch (outcome.kind) {
      case "invalid": {
        const { fields, outdated } = translateErrors(outcome.errors);
        server = { errors: withoutTurnstile(fields), data: JSON.stringify(data) };
        renderErrors(data);
        const first = firstErrorField({ ...fieldErrors(data), ...serverErrors(data) });
        showFormMessage({ key: outdated ? "errors.outdated" : "errors.summary" });
        if (first) focusField(first);
        else formError.focus();
        return;
      }
      case "turnstile":
        turnstileRejected = true;
        renderErrors(data);
        showFormMessage({ key: "errors.turnstileFailed" });
        focusField("turnstileToken");
        return;
      case "rateLimited":
        showFormMessage(rateLimitMessage(outcome.retryAfterSeconds));
        formError.focus();
        return;
      case "tooLarge":
        showFormMessage({ key: "errors.tooLarge" });
        focusField("notes");
        return;
      case "server":
      case "network":
        showFormMessage({ key: outcome.kind === "server" ? "errors.server" : "errors.network", retry: true });
        formRetry.focus();
        return;
    }
  };

  const submitRequest = async (): Promise<void> => {
    if (phase !== "editing") return;
    submitted = true;
    pendingSubmit = false;
    server = null;
    const data = readForm();
    const errors = fieldErrors(data);
    renderErrors(data, errors);
    const first = firstErrorField(errors);
    if (first) {
      setStatus(null);
      showFormMessage({ key: "errors.summary" });
      focusField(first);
      return;
    }
    if (!endpoint || !turnstile) {
      showFormMessage({ key: "request.configMissing" });
      return;
    }
    const token = turnstile.token;
    if (!token) {
      if (turnstile.status === "loading" || turnstile.status === "pending") {
        // Se manda solo en cuanto Turnstile dé el token (onTurnstileChange).
        pendingSubmit = true;
        showFormMessage(null);
        setStatus("request.statusWaitingTurnstile");
      } else {
        showFormMessage({ key: "errors.summary" });
        focusField("turnstileToken");
      }
      return;
    }

    showFormMessage(null);
    phase = "sending";
    setSending(true);
    // La clave se reutiliza en los reintentos (red, 5xx, 429) y cambia solo según request-key.ts.
    const snapshot = JSON.stringify(data);
    keys.edited(snapshot);
    const payload = buildPayload(data, { ...payloadOptions(token), requestKey: keys.current() });
    const outcome = await sendPublicRequest(endpoint, payload);
    // Un reintento que el servidor ya tenía guardado (duplicate): qué datos guardó. Antes de settle,
    // que olvida los envíos anteriores.
    const view = doneViewFor(
      outcome.kind === "created" && outcome.duplicate ? keys.replayed(snapshot) : { kind: "sent" },
      data,
    );
    keys.settle(outcome.kind, snapshot);
    phase = "editing";
    setSending(false);
    handleOutcome(outcome, data, view);
  };

  const onTurnstileChange = (): void => {
    if (!turnstile || phase === "done") return;
    if (turnstile.token) turnstileRejected = false;
    renderErrors(readForm());
    if (!pendingSubmit) return;
    if (turnstile.token) {
      void submitRequest();
    } else if (turnstile.status !== "loading" && turnstile.status !== "pending") {
      pendingSubmit = false;
      setStatus(null);
      const error = turnstileError();
      if (error) showFormMessage(error);
    }
  };

  const update = (): void => {
    if (phase === "done") return;
    const data = readForm();
    keys.edited(JSON.stringify(data));
    syncSteppers();
    renderQuote(data);
    const errors = fieldErrors(data);
    renderErrors(data, errors);
    if (formMessage?.key === "errors.summary" && !firstErrorField({ ...errors, ...serverErrors(data) })) {
      showFormMessage(null);
    }
  };

  form.addEventListener("click", (event) => {
    const btn = event.target instanceof Element ? event.target.closest<HTMLButtonElement>("button[data-step]") : null;
    if (btn) step(btn);
  });
  form.addEventListener("input", update);
  form.addEventListener("change", (event) => {
    if (event.target instanceof HTMLInputElement && event.target.classList.contains("stepper__input")) {
      normalizeStepper(event.target);
    }
    update();
  });
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    void submitRequest();
  });
  formRetry.addEventListener("click", () => void submitRequest());
  turnstileRetry.addEventListener("click", () => {
    turnstile?.reset();
    turnstileBox.focus({ preventScroll: true });
  });

  shell.onLanguageChange((i18n) => {
    // applyTranslations ya cambió los textos fijos; acá los que arma el código.
    update();
    paintFormMessage();
    setStatus(statusKey);
    setText(submitLabel, i18n.t(phase === "sending" ? "request.sending" : "request.submit"));
    renderDone();
    turnstile?.setLanguage(i18n.lang);
  });

  const configured = endpoint !== null && siteKey !== null;
  configWarning.hidden = configured;
  const turnstileField = turnstileBox.closest<HTMLElement>(".field--turnstile");
  if (turnstileField) turnstileField.hidden = !configured;
  if (siteKey) {
    turnstile = mountTurnstile(turnstileBox, { siteKey, language: shell.i18n.lang, onChange: onTurnstileChange });
    onTurnstileChange();
  }

  update();
  // El HTML trae el botón deshabilitado: sin JS el formulario nunca se envía (los datos irían en la URL).
  submitButton.disabled = false;
}

applyLimits(todayInRome());
trackQuoteHeight(byId("quote"));
// Si no llegan los textos, initShell muestra el aviso y se resuelve recién si un reintento funciona:
// mientras tanto el botón de envío sigue deshabilitado, como viene en el HTML.
void initShell().then(startRequestPage);
