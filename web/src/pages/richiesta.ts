// Calculadora + formulario de pedido. Toda la lógica de negocio vive en src/request/ (pura y testeada);
// acá solo se lee el formulario, se pinta el presupuesto y los errores, y se abre WhatsApp.
import "../styles/base.css";
import "../styles/request.css";
import { config } from "../config.ts";
import { LIMITS } from "../engine.ts";
import type { MessageKey } from "../i18n/core.ts";
import { addDays, todayInRome } from "../lib/dates.ts";
import { formatCents, formatDuration } from "../lib/format.ts";
import {
  ALLERGENS,
  DATE_WINDOW,
  DIETS,
  MEAL_OPTIONS,
  REQUEST_TYPES,
  SLOTS,
  TEXT_LIMITS,
  hasRestrictions,
  isOneOf,
  type Allergen,
  type Diet,
  type RequestData,
} from "../request/model.ts";
import { computeQuote } from "../request/quote.ts";
import { FIELD_ORDER, firstErrorField, validateRequest, type FieldErrors, type FieldName } from "../request/validate.ts";
import { buildWhatsAppMessage, buildWhatsAppUrl } from "../request/whatsapp.ts";
import { initShell, type Shell } from "./shell.ts";

function byId<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Falta #${id} en el HTML`);
  return el as T;
}

/** Controles a marcar con aria-invalid para cada error. */
const CONTROLS: Readonly<Record<FieldName, readonly string[]>> = {
  adults: ["adults"],
  kids: ["kids"],
  people: ["adults", "kids"],
  days: ["days"],
  meals: [],
  restrictionsNote: ["restrictionsNote"],
  healthConsent: ["healthConsent"],
  date: ["date"],
  name: ["name"],
  zone: ["zone"],
  phone: ["phone"],
  email: ["email"],
  notes: ["notes"],
  privacyConsent: ["privacyConsent"],
};

const form = byId<HTMLFormElement>("request-form");
const layout = byId("request-layout");
const done = byId("done");
const doneRetry = byId<HTMLAnchorElement>("done-retry");
const doneEdit = byId<HTMLButtonElement>("done-edit");
const healthBlock = byId("health-consent");
const celiacNote = byId("celiac-note");
const configWarning = byId("config-warning");
const formError = byId("form-error");
const quoteBody = byId("quote-body");
const quoteInvalid = byId("quote-invalid");
const quoteOut = {
  total: byId("q-total"),
  service: byId("q-service"),
  groceries: byId("q-groceries"),
  time: byId("q-time"),
  portions: byId("q-portions"),
};

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

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

/** Límites tomados del motor y del modelo: el HTML no los repite. */
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
  const date = byId<HTMLInputElement>("date");
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
    allergens: fd.getAll("allergens").filter((v): v is Allergen => isOneOf(ALLERGENS, v)),
    diets: fd.getAll("diets").filter((v): v is Diet => isOneOf(DIETS, v)),
    restrictionsNote: str("restrictionsNote"),
    date: str("date"),
    slot: isOneOf(SLOTS, slot) ? slot : "any",
    name: str("name"),
    zone: str("zone"),
    phone: str("phone"),
    email: str("email"),
    notes: str("notes"),
    privacyConsent: fd.has("privacyConsent"),
    healthConsent: fd.has("healthConsent"),
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

function startRequestPage(shell: Shell): void {
  let submitted = false;
  let formErrorKey: MessageKey | null = null;

  const renderQuote = (data: RequestData): void => {
    const { i18n } = shell;
    const quote = computeQuote(data);
    quoteBody.hidden = quote === null;
    quoteInvalid.hidden = quote !== null;
    if (!quote) return;
    setText(quoteOut.total, formatCents(quote.totalCents, i18n.locale));
    setText(quoteOut.service, formatCents(quote.serviceCents, i18n.locale));
    setText(quoteOut.groceries, formatCents(quote.groceriesEstCents, i18n.locale));
    setText(quoteOut.time, i18n.t("request.quote.timeValue", { value: formatDuration(quote.cookMinutes, i18n) }));
    setText(quoteOut.portions, String(quote.portions));
  };

  const renderErrors = (errors: FieldErrors): void => {
    const invalid = new Set<string>();
    for (const field of FIELD_ORDER) {
      const error = errors[field];
      const errorEl = byId(`err-${field}`);
      errorEl.textContent = error ? shell.i18n.t(error.key, error.params) : "";
      errorEl.hidden = !error;
      for (const id of CONTROLS[field]) {
        setDescribedBy(byId(id), errorEl.id, Boolean(error));
        if (error) invalid.add(id);
      }
    }
    for (const id of new Set(Object.values(CONTROLS).flat())) {
      if (invalid.has(id)) byId(id).setAttribute("aria-invalid", "true");
      else byId(id).removeAttribute("aria-invalid");
    }
  };

  const showFormError = (key: MessageKey | null): void => {
    formErrorKey = key;
    formError.textContent = key ? shell.i18n.t(key) : "";
    formError.hidden = key === null;
  };

  const focusField = (field: FieldName): void => {
    const id = CONTROLS[field][0];
    const target = id ? byId(id) : form.querySelector<HTMLInputElement>('input[name="meals"]');
    if (!target) return;
    target.focus({ preventScroll: true });
    // Se centra el mensaje de error (el campo queda justo arriba): así el panel fijo no lo tapa.
    byId(`err-${field}`).scrollIntoView({ block: "center", behavior: reducedMotion.matches ? "auto" : "smooth" });
  };

  const update = (): void => {
    const data = readForm();
    healthBlock.hidden = !hasRestrictions(data);
    celiacNote.classList.toggle("note--active", data.allergens.includes("gluten"));
    syncSteppers();
    renderQuote(data);
    if (submitted) {
      const errors = validateRequest(data, todayInRome());
      renderErrors(errors);
      if (formErrorKey === "errors.summary" && !firstErrorField(errors)) showFormError(null);
    }
  };

  const showDone = (): void => {
    layout.hidden = true;
    done.hidden = false;
    done.focus();
  };

  const openWhatsApp = (url: string): void => {
    const win = window.open(url, "_blank");
    if (win) win.opener = null;
    else window.location.href = url; // ventana bloqueada: abrir en la misma pestaña
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
    submitted = true;
    const data = readForm();
    const errors = validateRequest(data, todayInRome());
    renderErrors(errors);
    const first = firstErrorField(errors);
    const quote = computeQuote(data);
    if (first || !quote) {
      showFormError("errors.summary");
      focusField(first ?? "people");
      return;
    }
    if (!config.whatsappNumber) {
      showFormError("request.missingNumber");
      return;
    }
    showFormError(null);
    const url = buildWhatsAppUrl(config.whatsappNumber, buildWhatsAppMessage(data, quote, shell.i18n));
    doneRetry.href = url;
    showDone();
    openWhatsApp(url);
  });

  doneEdit.addEventListener("click", () => {
    done.hidden = true;
    layout.hidden = false;
    form.querySelector<HTMLInputElement>('input[name="type"]:checked')?.focus();
  });

  shell.onLanguageChange(() => {
    update();
    if (submitted) renderErrors(validateRequest(readForm(), todayInRome()));
    if (formErrorKey) showFormError(formErrorKey);
  });

  configWarning.hidden = config.whatsappNumber !== null;
  update();
  // El HTML trae el botón deshabilitado: sin JS el formulario nunca se envía (los datos irían en la URL).
  byId<HTMLButtonElement>("submit").disabled = false;
}

applyLimits(todayInRome());
void initShell().then(startRequestPage);
