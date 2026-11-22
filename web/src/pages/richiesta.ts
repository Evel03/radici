// Calculadora + formulario de pedido. Toda la lógica vive en src/request/ (pura y testeada): acá se lee
// el formulario, se pintan presupuesto, calendario, menù, errores y estados, y se manda el pedido a la Edge
// Function `public-request` con el token de Turnstile (docs/contracts/public-request.md §6).
// Nunca se registran en consola datos del pedido (contacto, salud, notas).
import "../styles/base.css";
import "../styles/request.css";
import { LIMITS } from "../engine.ts";
import type { MessageKey, Params } from "../i18n/core.ts";
import { todayInRome } from "../lib/dates.ts";
import { formatIsoDate, formatShortDate } from "../lib/format.ts";
import { availabilityUrl, fetchAvailability } from "../request/availability.ts";
import {
  availabilityState,
  buildMonth,
  calendarNav,
  coversWindow,
  noFreeDays,
  selectionStillValid,
  sessionDays,
  windowMonths,
  type AvailabilityState,
  type CalendarInput,
  type CalendarMonth,
  type DayStatus,
  type SessionStatus,
} from "../request/calendar.ts";
import { hiddenPanels, weeksFromForm } from "../request/form.ts";
import {
  dishPhoto,
  doneMenu,
  fetchMenu,
  menuMax,
  menuPanelView,
  menuState,
  menuUrl,
  reconcileMenu,
  seasonMonth,
  toggleDish,
  type DishCard,
  type MenuChoice,
  type MenuDish,
  type MenuState,
} from "../request/menu.ts";
import {
  MEAL_OPTIONS,
  REQUEST_TYPES,
  TEXT_LIMITS,
  isOneOf,
  weeksOf,
  type PublicRequestEstimate,
  type RequestData,
} from "../request/model.ts";
import { buildPayload, type PayloadOptions } from "../request/payload.ts";
import { quoteBoxView } from "../request/quote-box.ts";
import { computeQuote } from "../request/quote.ts";
import { createRequestKeys, doneViewFor, type DoneView } from "../request/request-key.ts";
import { publicRequestUrl, rateLimitMessage, sendPublicRequest, type SubmitOutcome } from "../request/submit.ts";
import { doneEstimate, summaryRows } from "../request/summary.ts";
import {
  loadTurnstileScript,
  mountTurnstile,
  turnstileView,
  waitingStatus,
  type TurnstileView,
  type TurnstileWidget,
} from "../request/turnstile.ts";
import {
  FIELD_ORDER,
  firstErrorField,
  translateErrors,
  validateRequest,
  type FieldError,
  type FieldErrors,
  type FieldName,
  type SentConsents,
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
  weeks: [],
  adults: ["adults"],
  kids: ["kids"],
  people: ["adults", "kids"],
  days: ["days"],
  meals: [],
  // El día se elige en el calendario: el error se marca en la grilla (role="group", enfocable).
  preferredDate: ["calendar-grid"],
  // Los platos: el error (más que días) se marca en la lista de tarjetas (role="group", enfocable).
  menu: ["menu-list"],
  name: ["name"],
  zone: ["zone"],
  phone: ["phone"],
  whatsappOptIn: ["whatsappOptIn"],
  email: ["email"],
  notes: ["notes"],
  consentPrivacy: ["consentPrivacy"],
  noAllergies: ["noAllergies"],
  restrictionsNote: ["restrictionsNote"],
  consentHealth: ["consentHealth"],
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
// La nota de alergias y su consentimiento: se ocultan si marca que nadie tiene (y no se mandan).
const allergyDetails = byId("allergy-details");
// Las semanas son del pedido semanal: con "extra" se oculta y se manda 1.
const weeksPanel = byId("weeks-panel");
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
const turnstileCode = byId("turnstile-code");
const turnstileCodeValue = byId("turnstile-code-value");
const turnstileHelp = byId("turnstile-help");
const quoteBody = byId("quote-body");
const quoteInvalid = byId("quote-invalid");
const quoteOut = {
  manual: byId("q-manual"),
  totalRow: byId("q-total-row"),
  totalLabel: byId("q-total-label"),
  total: byId("q-total"),
  weeklyRow: byId("q-weekly-row"),
  weekly: byId("q-weekly"),
  portionsLabel: byId("q-portions-label"),
  portions: byId("q-portions"),
  savings: byId("q-savings"),
};
const calendarEls = {
  grid: byId("calendar-grid"),
  weekdays: byId("calendar-weekdays"),
  month: byId("calendar-month"),
  prev: byId<HTMLButtonElement>("calendar-prev"),
  next: byId<HTMLButtonElement>("calendar-next"),
  status: byId("calendar-status"),
  chosen: byId("calendar-chosen"),
  chosenText: byId("calendar-chosen-text"),
  clear: byId<HTMLButtonElement>("calendar-clear"),
  input: byId<HTMLInputElement>("preferredDate"),
  legendRepeat: byId("calendar-legend-repeat"),
  sessions: byId("calendar-sessions"),
  sessionList: byId("calendar-session-list"),
};
const menuEls = {
  hint: byId("hint-menu"),
  count: byId("menu-count"),
  status: byId("menu-status"),
  list: byId("menu-list"),
};

/** Nombre accesible de cada día del calendario según su estado. */
const DAY_LABELS: Readonly<Record<DayStatus, MessageKey>> = {
  available: "request.calendar.dayAvailable",
  unavailable: "request.calendar.dayUnavailable",
  pending: "request.calendar.dayPending",
  outside: "request.calendar.dayUnavailable",
};

/** Qué dice la lista de fechas de cada semana (y el nombre accesible del día de una semana siguiente). */
const SESSION_STATUS: Readonly<Record<SessionStatus, MessageKey>> = {
  selected: "request.calendar.sessionStatus.selected",
  available: "request.calendar.sessionStatus.available",
  unavailable: "request.calendar.sessionStatus.unavailable",
  pending: "request.calendar.sessionStatus.pending",
  unknown: "request.calendar.sessionStatus.unknown",
  outside: "request.calendar.sessionStatus.outside",
};

/** "novembre 2026" → "Novembre 2026" (Intl da el mes en minúscula en italiano y español). */
function monthTitle(month: CalendarMonth, locale: string): string {
  const text = new Intl.DateTimeFormat(locale, { month: "long", year: "numeric", timeZone: "UTC" }).format(
    new Date(Date.UTC(month.year, month.month - 1, 1)),
  );
  return text.charAt(0).toLocaleUpperCase(locale) + text.slice(1);
}

/** Lunes a domingo, abreviados según el idioma (el 16/11/2026 es lunes). */
function weekdayNames(locale: string): string[] {
  const fmt = new Intl.DateTimeFormat(locale, { weekday: "short", timeZone: "UTC" });
  return Array.from({ length: 7 }, (_, i) => fmt.format(new Date(Date.UTC(2026, 10, 16 + i))));
}

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

/** Límites tomados del motor y del contrato: el HTML no los repite. Las fechas las limita el calendario. */
function applyLimits(): void {
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
}

/** Los campos del formulario. Los platos no: la página los guarda en el orden en que los tildó (startRequestPage). */
function readFields(): Omit<RequestData, "menu"> {
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
  const weeks = str("weeks");
  return {
    type: isOneOf(REQUEST_TYPES, type) ? type : "week",
    adults: int("adults"),
    kids: int("kids"),
    days: int("days"),
    meals: isOneOf(MEAL_OPTIONS, meals) ? meals : "dinner",
    weeks: weeksFromForm(weeks),
    // Campo oculto que llena el calendario.
    preferredDate: str("preferredDate"),
    name: str("name"),
    zone: str("zone"),
    phone: str("phone"),
    email: str("email"),
    whatsappOptIn: fd.has("whatsappOptIn"),
    notes: str("notes"),
    consentPrivacy: fd.has("consentPrivacy"),
    noAllergies: fd.has("noAllergies"),
    restrictionsNote: str("restrictionsNote"),
    consentHealth: fd.has("consentHealth"),
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
    estimate: PublicRequestEstimate | null;
    /** Los platos que guardó el servidor (con sus nombres). */
    menu: MenuChoice[];
    replay: DoneView["replay"];
  } | null = null;
  let turnstile: TurnstileWidget | null = null;

  const payloadOptions = (turnstileToken: string): PayloadOptions => ({ locale: shell.i18n.lang, turnstileToken });

  // --- Menù (src/request/menu.ts) ------------------------------------------------------------------
  /** Catálogo de Evelyn (GET …/menu): se pide una vez, al abrir la página. Sin backend, el menù lo propone ella. */
  let menu: MenuState = config.supabaseUrl ? { kind: "loading" } : { kind: "error" };
  /** Los platos elegidos, en el orden en que los tildó (así llegan a Evelyn). */
  let menuSelection: string[] = [];
  /** Los que se quitaron por la temporada en el último cambio de fecha: se avisa hasta que toque otra casilla. */
  let menuRemoved: MenuDish[] = [];
  /** Lo que se pintó por última vez: si no cambió, no se rehacen las tarjetas (la casilla con foco no lo pierde). */
  let menuPainted = "";

  const readForm = (): RequestData => ({ ...readFields(), menu: [...menuSelection] });

  // --- Calendario del día preferido (src/request/calendar.ts) ------------------------------------
  /** Disponibilidad para la duración del pedido (minutos de cocina del motor, que el cliente no ve). */
  let availability: AvailabilityState = { kind: "loading" };
  /** Minutos de la última consulta (null: todavía ninguna). */
  let availabilityFor: number | null = null;
  let availabilityRequested = false;
  let availabilitySeq = 0;
  let availabilityTimer: ReturnType<typeof setTimeout> | undefined;
  /** Respuestas buenas por duración: volver a una duración ya vista no consulta de nuevo. */
  const availabilityCache = new Map<number, AvailabilityState>();
  /** Mes que se muestra (índice en windowMonths). Mientras el cliente no lo cambie, se elige solo. */
  let monthIndex = 0;
  let monthTouched = false;
  /** Aviso cuando el día elegido dejó de estar libre (hasta que el cliente elija o quite la fecha). */
  let calendarNotice: MessageKey | null = null;
  /** Lo que se pintó por última vez: si no cambió, no se rehace la grilla (el día con foco no lo pierde). */
  let calendarPainted = "";

  const calendarInput = (data: RequestData): CalendarInput => ({
    today: todayInRome(),
    selected: data.preferredDate,
    applies: data.type === "week",
    weeks: weeksOf(data),
    availability,
  });

  const setPreferredDate = (date: string): void => {
    calendarEls.input.value = date;
  };

  /**
   * Pide la disponibilidad para la duración actual (solo la semana de comidas). Con caché o sin backend
   * la aplica en el momento; si no, espera un poco (los steppers cambian de a un clic) y consulta.
   */
  const syncAvailability = (data: RequestData): void => {
    const quote = data.type === "week" ? computeQuote(data) : null;
    // Eventos: no aplica. Datos incompletos: se mantiene la última disponibilidad.
    if (!quote || quote.cookMinutes === availabilityFor) return;
    const minutes = quote.cookMinutes;
    availabilityFor = minutes;
    clearTimeout(availabilityTimer);
    availabilitySeq++;
    const cached = availabilityCache.get(minutes);
    if (cached) {
      availability = cached;
      return;
    }
    if (!config.supabaseUrl) {
      availability = { kind: "error" };
      return;
    }
    availability = { kind: "loading" };
    const seq = availabilitySeq;
    const url = availabilityUrl(config.supabaseUrl, minutes);
    const delay = availabilityRequested ? 300 : 0;
    availabilityRequested = true;
    availabilityTimer = setTimeout(() => {
      void fetchAvailability(url).then((response) => {
        // Llegó tarde: mientras tanto cambió la duración.
        if (seq !== availabilitySeq) return;
        const state = availabilityState(response, minutes);
        // Solo si cubre la ventana: la de la función de antes (14 días, durante un despliegue) se vuelve a pedir.
        if (state.kind === "ready" && coversWindow(state.days, todayInRome())) availabilityCache.set(minutes, state);
        availability = state;
        update();
      });
    }, delay);
  };

  const renderCalendar = (data: RequestData): void => {
    const { i18n } = shell;
    const input = calendarInput(data);
    const months = windowMonths(input.today);
    // Dos o tres meses (8 semanas): el mes, el recorte y las flechas salen de calendarNav.
    const nav = calendarNav(input, monthIndex, monthTouched);
    monthIndex = nav.index;
    const ref = months[nav.index];
    if (!ref) return;
    const view = buildMonth(ref, input);
    calendarEls.prev.disabled = !nav.prev;
    calendarEls.next.disabled = !nav.next;
    // Las semanas siguientes del pedido: su estado en la lista (y en el nombre accesible de su día).
    const sessions = sessionDays(input);
    const sessionStatus = new Map(sessions.map((session) => [session.date, session.status] as const));

    const signature = JSON.stringify([
      i18n.lang,
      view.year,
      view.month,
      view.cells.map((c) => `${c.status}${c.selected ? "*" : ""}${c.repeat ?? ""}${sessionStatus.get(c.date) ?? ""}`),
    ]);
    if (signature !== calendarPainted) {
      calendarPainted = signature;
      const active = document.activeElement;
      const focusedDate = active instanceof HTMLElement && calendarEls.grid.contains(active) ? active.dataset["date"] : undefined;
      setText(calendarEls.month, monthTitle(view, i18n.locale));
      calendarEls.weekdays.replaceChildren(
        ...weekdayNames(i18n.locale).map((name) => {
          const el = document.createElement("span");
          el.textContent = name;
          return el;
        }),
      );
      const nodes: HTMLElement[] = [];
      for (let i = 0; i < view.leading; i++) nodes.push(document.createElement("span"));
      for (const cell of view.cells) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "calendar__day";
        btn.dataset["date"] = cell.date;
        btn.dataset["status"] = cell.status;
        btn.disabled = cell.status !== "available";
        btn.setAttribute("aria-pressed", String(cell.selected));
        const date = formatIsoDate(cell.date, i18n.locale);
        const repeatStatus = cell.repeat === null ? undefined : sessionStatus.get(cell.date);
        if (cell.repeat !== null && repeatStatus) {
          // El mismo día de una semana siguiente: se marca y se dice qué semana es y si está libre.
          btn.dataset["repeat"] = String(cell.repeat);
          btn.setAttribute(
            "aria-label",
            i18n.t("request.calendar.dayRepeat", { date, week: cell.repeat, status: i18n.t(SESSION_STATUS[repeatStatus]) }),
          );
        } else {
          btn.setAttribute("aria-label", i18n.t(DAY_LABELS[cell.status], { date }));
        }
        btn.textContent = String(cell.day);
        nodes.push(btn);
      }
      calendarEls.grid.replaceChildren(...nodes);
      if (focusedDate) {
        const again = calendarEls.grid.querySelector<HTMLButtonElement>(`button[data-date="${focusedDate}"]`);
        (again && !again.disabled ? again : calendarEls.grid).focus({ preventScroll: true });
      }
    }

    const notes: string[] = [];
    if (calendarNotice) notes.push(i18n.t(calendarNotice));
    if (!input.applies) notes.push(i18n.t("request.calendar.eventNote"));
    else if (availability.kind === "loading") notes.push(i18n.t("request.calendar.loading"));
    else if (availability.kind === "error") notes.push(i18n.t("request.calendar.error"));
    else if (noFreeDays(input)) notes.push(i18n.t("request.calendar.noneFree"));
    setText(calendarEls.status, notes.join(" "));
    calendarEls.chosen.hidden = data.preferredDate === "";
    setText(
      calendarEls.chosenText,
      data.preferredDate ? i18n.t("request.calendar.chosen", { date: formatIsoDate(data.preferredDate, i18n.locale) }) : "",
    );
    renderSessions(sessions);
  };

  /** Lista de fechas, una por semana, debajo del calendario: solo con más de una semana y un día elegido. */
  let sessionsPainted = "";
  const renderSessions = (sessions: ReturnType<typeof sessionDays>): void => {
    const { i18n } = shell;
    const several = sessions.length > 1;
    calendarEls.sessions.hidden = !several;
    calendarEls.legendRepeat.hidden = !several;
    const signature = JSON.stringify([i18n.lang, sessions]);
    if (signature === sessionsPainted) return;
    sessionsPainted = signature;
    calendarEls.sessionList.replaceChildren(
      ...(several ? sessions : []).map((session) => {
        const item = document.createElement("li");
        item.className = "calendar__session";
        item.dataset["status"] = session.status;
        const when = document.createElement("span");
        when.className = "calendar__session-date";
        // Fecha corta: la lista llega a 8 renglones en el teléfono y la ventana nunca pasa de un año.
        when.textContent = i18n.t("request.calendar.sessionWeek", { week: session.week, date: formatShortDate(session.date, i18n.locale) });
        const status = document.createElement("span");
        status.className = "calendar__session-status";
        status.textContent = i18n.t(SESSION_STATUS[session.status]);
        item.append(when, " ", status);
        return item;
      }),
    );
  };

  /**
   * Una tarjeta de plato: la casilla, el nombre (su nombre accesible) y, como descripción, el texto, los alérgenos
   * y la dieta. Con foto, la miniatura va primera en el texto (dish--photo: flota a la izquierda y el texto la
   * rodea; con letra grande, arriba); si no carga, se saca y la tarjeta queda como una sin foto.
   */
  const dishNode = (card: DishCard): HTMLLabelElement => {
    const label = document.createElement("label");
    label.className = "choice dish";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.name = "menu";
    input.value = card.id;
    const idBase = `dish-${card.id}`;
    const body = document.createElement("span");
    body.className = "choice__body";
    const part = (className: string, id: string, text: string): HTMLSpanElement => {
      const el = document.createElement("span");
      el.className = className;
      el.id = id;
      el.textContent = text;
      return el;
    };
    const meta = part("dish__meta", `${idBase}-meta`, card.allergens);
    if (card.diet) {
      const diet = document.createElement("span");
      diet.className = "dish__diet";
      diet.textContent = card.diet;
      // Espacio duro antes del «·»: en el teléfono el renglón no termina en el punto.
      meta.append("\u00a0· ", diet);
    }
    body.append(part("choice__title", `${idBase}-name`, card.name), part("choice__hint", `${idBase}-desc`, card.description), meta);
    if (card.photo) {
      label.classList.add("dish--photo");
      body.prepend(dishPhoto(document.createElement("img"), card.photo, () => label.classList.remove("dish--photo")));
    }
    input.setAttribute("aria-labelledby", `${idBase}-name`);
    input.setAttribute("aria-describedby", `${idBase}-desc ${idBase}-meta`);
    label.append(input, body);
    return label;
  };

  /** Panel «Menù»: lo que se ve lo decide menuPanelView; acá se pinta. */
  const renderMenu = (data: RequestData): void => {
    const { i18n } = shell;
    const view = menuPanelView(
      { state: menu, selected: data.menu, days: data.days, month: seasonMonth(data.preferredDate, todayInRome()), removed: menuRemoved },
      i18n,
    );
    menuEls.hint.hidden = view.hint === null;
    setText(menuEls.hint, view.hint ?? "");
    menuEls.count.hidden = view.count === null;
    setText(menuEls.count, view.count ?? "");
    menuEls.count.classList.toggle("menu__count--over", view.overLimit);
    setText(menuEls.status, view.message);
    menuEls.list.hidden = view.cards.length === 0;

    const signature = JSON.stringify([
      i18n.lang,
      view.cards.map((card) => [card.id, card.name, card.description, card.allergens, card.diet, card.photo]),
    ]);
    if (signature !== menuPainted) {
      menuPainted = signature;
      const active = document.activeElement;
      const focusedId = active instanceof HTMLInputElement && menuEls.list.contains(active) ? active.value : undefined;
      menuEls.list.replaceChildren(...view.cards.map(dishNode));
      if (focusedId) {
        const again = menuEls.list.querySelector<HTMLInputElement>(`input[value="${focusedId}"]`);
        (again ?? menuEls.list).focus({ preventScroll: true });
      }
    }
    // Marcadas y deshabilitadas, en el lugar: la casilla con foco sigue siendo la misma.
    const cards = new Map(view.cards.map((card) => [card.id, card] as const));
    for (const input of menuEls.list.querySelectorAll<HTMLInputElement>('input[name="menu"]')) {
      const card = cards.get(input.value);
      input.checked = card?.checked ?? false;
      input.disabled = card?.disabled ?? true;
    }
  };

  /** Recuadro del precio: lo que se ve lo decide quoteBoxView (src/request/quote-box.ts); acá se pinta. */
  const renderQuote = (data: RequestData): void => {
    const quote = computeQuote(data);
    quoteBody.hidden = quote === null;
    quoteInvalid.hidden = quote !== null;
    if (!quote) return;
    const view = quoteBoxView(quote, data.type, shell.i18n);
    setText(quoteOut.portionsLabel, view.portions.label);
    setText(quoteOut.portions, view.portions.value);
    quoteOut.manual.hidden = view.manual === null;
    setText(quoteOut.manual, view.manual ?? "");
    quoteOut.totalRow.hidden = view.total === null;
    setText(quoteOut.totalLabel, view.total?.label ?? "");
    setText(quoteOut.total, view.total?.value ?? "");
    quoteOut.weeklyRow.hidden = view.weekly === null;
    setText(quoteOut.weekly, view.weekly ?? "");
    quoteOut.savings.hidden = view.savings === null;
    setText(quoteOut.savings, view.savings ?? "");
  };

  /** Lo que se ve junto al widget (error, código, sugerencia, reintento): lo decide turnstileView. */
  const currentTurnstileView = (): TurnstileView | null =>
    turnstile
      ? turnstileView({
          status: turnstile.status,
          errorCode: turnstile.errorCode,
          stalled: turnstile.stalled,
          rejected: turnstileRejected,
        })
      : null;

  const turnstileError = (): FieldError | null => {
    const key = currentTurnstileView()?.error;
    return key ? { key } : null;
  };

  /** El código del error, la sugerencia y «Ripeti la verifica» (el error lo pinta paintErrors). */
  const paintTurnstile = (view: TurnstileView | null): void => {
    const code = view?.code ?? null;
    turnstileCode.hidden = code === null;
    setText(turnstileCodeValue, code ?? "");
    const help = view?.help ?? false;
    turnstileHelp.hidden = !help;
    // El sitio, el de la página: radicicucina.app en producción (la excepción se agrega para ese).
    setText(turnstileHelp, help ? shell.i18n.t("request.turnstileHelp", { site: window.location.hostname }) : "");
    turnstileRetry.hidden = !(view?.retry ?? false);
    // Con el foco en «Ripeti la verifica» (focusField), el lector de pantalla lee también el error, el código y
    // la sugerencia que se ven (turnstileView).
    const ids = view?.describedBy.join(" ") ?? "";
    if (ids) turnstileRetry.setAttribute("aria-describedby", ids);
    else turnstileRetry.removeAttribute("aria-describedby");
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
  };

  /** Errores de los campos según la validación local, solo después del primer intento de envío. */
  const fieldErrors = (data: RequestData): FieldErrors =>
    submitted ? withoutTurnstile(validateRequest(data, todayInRome(), payloadOptions(""))) : {};

  const renderErrors = (data: RequestData, errors: FieldErrors = fieldErrors(data)): void => {
    const view = currentTurnstileView();
    const all = { ...errors, ...serverErrors(data) };
    paintErrors(view?.error ? { ...all, turnstileToken: { key: view.error } } : all);
    paintTurnstile(view);
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
      // Grupos de opciones (tipo, comidas): la primera opción.
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
      ...summaryRows(success.data, success.estimate, shell.i18n, success.menu).map((row) => {
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
   * del envío que llegó (la estimación y los platos del servidor son los de ese pedido), nunca los del formulario.
   */
  const showDone = (view: DoneView, estimate: PublicRequestEstimate | null, dishes: MenuChoice[] | null): void => {
    phase = "done";
    const { data } = view;
    success = {
      data,
      email: data ? emailOf(data) : null,
      // La del servidor o, si no vino (o con otra forma), la de la calculadora (summary.ts).
      estimate: doneEstimate(data, estimate),
      // Los del servidor o, si no vinieron, los elegidos con los nombres del catálogo (menu.ts).
      menu: doneMenu(data, dishes, menu),
      replay: view.replay,
    };
    renderDone();
    layout.hidden = true;
    done.hidden = false;
    done.focus();
  };

  /** @param sent los consentimientos que llevaba el pedido: uno marcado que el servidor rechaza es de otro texto. */
  const handleOutcome = (outcome: SubmitOutcome, data: RequestData, view: DoneView, sent: SentConsents): void => {
    if (outcome.kind === "created") {
      showDone(view, outcome.estimate, outcome.menu);
      return;
    }
    // Cualquier fallo: el token ya se usó o pudo usarse, Turnstile pide uno nuevo.
    turnstile?.reset();
    switch (outcome.kind) {
      case "invalid": {
        const { fields, outdated } = translateErrors(outcome.errors, sent);
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
        setStatus(waitingStatus(turnstile.stalled));
      } else {
        showFormMessage({ key: "errors.summary" });
      }
      // Falló, o se trabó (p. ej. en blanco por la prevención de seguimiento): al error, a la sugerencia y al reintento.
      if (currentTurnstileView()?.focusOnSubmit) focusField("turnstileToken");
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
    handleOutcome(outcome, data, view, payload.consents);
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
    } else {
      // Sigue esperando; si se trabó mientras tanto, el estado lo dice (sin mover el foco).
      setStatus(waitingStatus(turnstile.stalled));
    }
  };

  const update = (): void => {
    if (phase === "done") return;
    syncAvailability(readForm());
    // El día elegido dejó de estar libre (otra duración, o pasó de evento a semana de comidas): se quita.
    if (!selectionStillValid(calendarInput(readForm()))) {
      setPreferredDate("");
      calendarNotice = "request.calendar.cleared";
    }
    // Con la fecha (o el catálogo) nuevos, los platos elegidos que salieron de temporada se quitan y se avisa.
    const season = reconcileMenu(menuSelection, menu, seasonMonth(readForm().preferredDate, todayInRome()));
    if (season.removed.length > 0) {
      menuSelection = season.selected;
      menuRemoved = season.removed;
    }
    const data = readForm();
    keys.edited(JSON.stringify(data));
    // Lo escrito se conserva si vuelve a desmarcar la casilla, pero oculto no se manda (buildPayload). Lo
    // mismo las semanas: con "extra" se ocultan y se manda 1.
    const hidden = hiddenPanels(data);
    allergyDetails.hidden = hidden.allergyDetails;
    weeksPanel.hidden = hidden.weeks;
    syncSteppers();
    renderQuote(data);
    renderCalendar(data);
    renderMenu(data);
    const errors = fieldErrors(data);
    renderErrors(data, errors);
    if (formMessage?.key === "errors.summary" && !firstErrorField({ ...errors, ...serverErrors(data) })) {
      showFormMessage(null);
    }
  };

  // Una casilla de plato: se suma o se saca en el orden de los clics. Corre antes que el input/change del
  // formulario (que repinta con lo elegido); los dos eventos llegan y la cuenta da lo mismo.
  const onDishToggle = (event: Event): void => {
    const input = event.target;
    if (!(input instanceof HTMLInputElement) || input.name !== "menu") return;
    menuSelection = toggleDish(menuSelection, input.value, input.checked, menuMax(readFields().days));
    menuRemoved = [];
  };
  menuEls.list.addEventListener("input", onDishToggle);
  menuEls.list.addEventListener("change", onDishToggle);

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
  calendarEls.grid.addEventListener("click", (event) => {
    const btn = event.target instanceof Element ? event.target.closest<HTMLButtonElement>("button[data-date]") : null;
    if (!btn || btn.disabled) return;
    const date = btn.dataset["date"] ?? "";
    // Tocar el día elegido lo quita (la fecha es opcional).
    setPreferredDate(calendarEls.input.value === date ? "" : date);
    calendarNotice = null;
    update();
  });
  const moveMonth = (delta: number): void => {
    // Al llegar al primer o al último mes, la flecha tocada se deshabilita. Si tenía el foco, pasa a la
    // otra: si no, se iría a body y con teclado o lector de pantalla habría que volver a buscar el calendario.
    const [clicked, other] = delta < 0 ? [calendarEls.prev, calendarEls.next] : [calendarEls.next, calendarEls.prev];
    const hadFocus = document.activeElement === clicked;
    monthTouched = true;
    monthIndex += delta;
    renderCalendar(readForm());
    if (hadFocus && clicked.disabled) (other.disabled ? calendarEls.grid : other).focus({ preventScroll: true });
  };
  calendarEls.prev.addEventListener("click", () => moveMonth(-1));
  calendarEls.next.addEventListener("click", () => moveMonth(1));
  calendarEls.clear.addEventListener("click", () => {
    setPreferredDate("");
    calendarNotice = null;
    update();
    calendarEls.grid.focus({ preventScroll: true });
  });
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

  // Los platos de Evelyn: una sola consulta. Mientras tanto el panel dice que los está cargando; el envío no
  // los espera (sin platos, el menù lo propone Evelyn).
  if (config.supabaseUrl) {
    void fetchMenu(menuUrl(config.supabaseUrl)).then((dishes) => {
      menu = menuState(dishes);
      update();
    });
  }

  update();
  // El HTML trae el botón deshabilitado: sin JS el formulario nunca se envía (los datos irían en la URL).
  submitButton.disabled = false;
}

applyLimits();
trackQuoteHeight(byId("quote"));
// Si no llegan los textos, initShell muestra el aviso y se resuelve recién si un reintento funciona:
// mientras tanto el botón de envío sigue deshabilitado, como viene en el HTML.
void initShell().then(startRequestPage);
