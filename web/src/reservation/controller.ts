// Estado de la página /prenotazione/ y lo que hace cada botón, sin DOM (se testea con un fetch simulado). La
// página (pages/prenotazione.ts) pinta lo que dice el estado (render.ts) y le pasa los clics.
// - Al abrirse: lee la reserva del link (POST …/view). Sin token, o con un link que no existe o venció, lo dice.
// - Por semana: confirmar el menú o pedir cambios con un mensaje. Después de cada respuesta, el estado de esa
//   semana se actualiza con lo que devolvió la función y la reserva se vuelve a leer (por si Evelyn mandó otro
//   menú mientras tanto). Lo que pasó queda como aviso en esa semana; un error (sin conexión, demasiados
//   intentos) queda junto a los botones y se anuncia.
// - Las lecturas de la reserva van numeradas: solo vale la última que se pidió, así una respuesta que llega tarde
//   no pisa una más nueva.
// El estado de cada semana (el formulario abierto, el mensaje a medio escribir, el aviso) va por su sesión
// (sessionId), no por el número ni por el envío: si se cancela una semana anterior las demás se renumeran, y si
// Evelyn manda un menú nuevo mientras la clienta escribe, el mensaje no se pierde (y se le avisa).
// Nunca se registran en la consola el token, la reserva ni el mensaje.
import {
  changesTextProblem,
  cleanChangesText,
  type ChangesTextProblem,
  type ClientLinkMenu,
  type ClientLinkView,
  type ClientLinkWeek,
} from "../../../supabase/functions/_shared/client_link.ts";
import type { MessageKey, Params } from "../i18n/core.ts";
import { confirmMenu, fetchView, requestChanges, type ActionOutcome, type ApiOptions, type ViewOutcome } from "./api.ts";

/** Un texto por traducir: la clave y sus parámetros ({chef} lo agrega quien lo pinta). */
export interface Message {
  key: MessageKey;
  params?: Params;
  /** Un día "AAAA-MM-DD" que quien pinta escribe largo, en el idioma de la página, como {date}. */
  date?: string;
}

export type PageState =
  | { kind: "loading" }
  /** Sin token en el link, con uno que no tiene la forma, o uno que no existe o venció. */
  | { kind: "invalidLink" }
  /** No se pudo leer la reserva (sin conexión, error, demasiados intentos): con «Riprova». */
  | { kind: "error"; message: Message }
  | { kind: "ready"; view: ClientLinkView };

/** Qué tiene de malo el mensaje: vacío, largo, o la función no lo aceptó. */
export type TextError = ChangesTextProblem | "invalid";

export interface WeekUi {
  /** El formulario de cambios está abierto (en lugar de los botones). */
  formOpen: boolean;
  /** El mensaje, tal como lo escribe. */
  draft: string;
  /** El envío para el que abrió el formulario: si llega otro mientras escribe, se le avisa. */
  draftFor: string | null;
  /** Una respuesta en camino: los botones no hacen nada hasta que vuelva. */
  busy: "confirm" | "changes" | null;
  /** El último error de una respuesta (sin conexión, demasiados intentos…), junto a los botones. */
  error: Message | null;
  /** Lo que tiene de malo el mensaje, o null. */
  textError: TextError | null;
  /** Lo que pasó con la última respuesta (confirmado, cambios enviados, hay un menú más nuevo…). */
  notice: Message | null;
}

/** A dónde va el foco después de una acción (render.ts sabe el id de cada cosa). */
export type Focus =
  | { kind: "status" | "confirm" | "askChanges" | "submit" | "textarea"; session: string }
  | { kind: "problem" | "greeting" | "notice" };

export interface ActionResult {
  focus: Focus | null;
  /** Lo que hay que anunciar (región en vivo): los errores, que no mueven el foco. */
  announce: Message | null;
}

export interface ReservationDeps {
  /** El origen de Supabase (VITE_SUPABASE_URL); null: la página no puede leer nada. */
  supabaseUrl: string | null;
  /** El token del fragmento (readToken), o null. */
  token: string | null;
  api?: ApiOptions;
}

export interface Reservation {
  readonly state: PageState;
  /** «Riprova» en camino: el error queda a la vista, con el botón esperando. */
  readonly retrying: boolean;
  /** Un aviso de la página entera (una semana que se canceló y ya no está en la lista), o null. */
  readonly pageNotice: Message | null;
  ui(session: string): Readonly<WeekUi>;
  /** Se llama cada vez que cambia algo que hay que pintar. */
  subscribe(listener: () => void): void;
  /** Lee la reserva al abrir la página. */
  load(): Promise<void>;
  /** «Riprova»: vuelve a leer la reserva sin pasar por «cargando» y dice a dónde va el foco. */
  retry(): Promise<ActionResult>;
  confirm(session: string): Promise<ActionResult>;
  openChanges(session: string): ActionResult;
  closeChanges(session: string): ActionResult;
  /** El mensaje mientras se escribe (sin volver a pintar). textErrorCleared: el error del texto ya no vale. */
  setDraft(session: string, text: string): { textErrorCleared: boolean };
  submitChanges(session: string): Promise<ActionResult>;
}

/** Mensaje del 429: en minutos (hasta una hora) o en horas; sin tiempo si el servidor no lo dio. */
export function rateLimitMessage(seconds: number | null): Message {
  if (seconds === null || seconds <= 0) return { key: "reservation.errors.rateLimited" };
  if (seconds < 3600) return { key: "reservation.errors.rateLimitedMinutes", params: { minutes: Math.ceil(seconds / 60) } };
  return { key: "reservation.errors.rateLimitedHours", params: { hours: Math.ceil(seconds / 3600) } };
}

const EMPTY_UI: WeekUi = { formOpen: false, draft: "", draftFor: null, busy: null, error: null, textError: null, notice: null };
const NOTHING: ActionResult = { focus: null, announce: null };

export function createReservation(deps: ReservationDeps): Reservation {
  let state: PageState = { kind: "loading" };
  let retrying = false;
  let pageNotice: Message | null = null;
  /** Número de la última lectura de la reserva que se pidió: las que llegan después de otra más nueva se descartan. */
  let viewSeq = 0;
  const weeks = new Map<string, WeekUi>();
  const listeners: Array<() => void> = [];

  const emit = (): void => {
    for (const listener of listeners) listener();
  };
  const ui = (session: string): WeekUi => weeks.get(session) ?? EMPTY_UI;
  const update = (session: string, patch: Partial<WeekUi>): void => {
    weeks.set(session, { ...ui(session), ...patch });
    emit();
  };

  /**
   * El estado nuevo. Con una reserva: se olvida lo de las semanas que ya no están, y si llegó otro envío para una
   * semana con el formulario abierto (Evelyn lo mandó de nuevo mientras escribía), se le avisa sin perder el mensaje.
   */
  const setState = (next: PageState): void => {
    state = next;
    if (next.kind === "ready") {
      const live = new Map(next.view.weeks.map((week) => [week.sessionId, week] as const));
      for (const [session, weekUi] of weeks) {
        const week = live.get(session);
        if (!week) {
          weeks.delete(session);
          continue;
        }
        const sendId = week.menu?.sendId ?? null;
        if (weekUi.formOpen && weekUi.draftFor !== null && sendId !== null && sendId !== weekUi.draftFor) {
          weeks.set(session, { ...weekUi, draftFor: sendId, notice: { key: "reservation.notices.menuOutdated" } });
        }
      }
    }
    emit();
  };

  const findWeek = (session: string): ClientLinkWeek | null =>
    state.kind === "ready" ? (state.view.weeks.find((week) => week.sessionId === session) ?? null) : null;

  /** El último envío de una semana, si se puede contestar desde la página: por confirmar, mostrado y no cocinada. */
  const answerable = (session: string): ClientLinkMenu | null => {
    const week = findWeek(session);
    const menu = week?.menu;
    return week && !week.done && menu && menu.state === "pending" && menu.content ? menu : null;
  };

  /** La semana con su envío actualizado con lo que devolvió la función (antes de volver a leer la reserva). */
  const patchMenu = (session: string, patch: Partial<ClientLinkMenu>): void => {
    if (state.kind !== "ready") return;
    const view = state.view;
    setState({
      kind: "ready",
      view: {
        ...view,
        weeks: view.weeks.map((week) => (week.sessionId === session && week.menu ? { ...week, menu: { ...week.menu, ...patch } } : week)),
      },
    });
  };

  const viewState = (outcome: ViewOutcome): PageState => {
    switch (outcome.kind) {
      case "ok":
        return { kind: "ready", view: outcome.view };
      case "linkNotFound":
        return { kind: "invalidLink" };
      case "rateLimited":
        return { kind: "error", message: rateLimitMessage(outcome.retryAfterSeconds) };
      case "network":
        return { kind: "error", message: { key: "reservation.errors.network" } };
      case "server":
        return { kind: "error", message: { key: "reservation.errors.server" } };
    }
  };

  /** Lee la reserva. null: mientras tanto se pidió otra lectura (la de ahora ya no vale). */
  const readView = async (): Promise<ViewOutcome | null> => {
    if (!deps.supabaseUrl || !deps.token) return null;
    const seq = ++viewSeq;
    const outcome = await fetchView(deps.supabaseUrl, deps.token, deps.api);
    return seq === viewSeq ? outcome : null;
  };

  const load = async (): Promise<void> => {
    if (!deps.token) return setState({ kind: "invalidLink" });
    // Sin VITE_SUPABASE_URL en el build la página no puede hablar con la función.
    if (!deps.supabaseUrl) return setState({ kind: "error", message: { key: "reservation.errors.server" } });
    setState({ kind: "loading" });
    const outcome = await readView();
    if (outcome) setState(viewState(outcome));
  };

  /** Vuelve a leer la reserva después de una respuesta. Si no se puede, queda lo que había (ya actualizado). */
  const refresh = async (): Promise<void> => {
    const outcome = await readView();
    if (outcome && (outcome.kind === "ok" || outcome.kind === "linkNotFound")) setState(viewState(outcome));
  };

  /** Lo que pasa después de cada respuesta de la función. date: el día de la semana, tomado antes de contestar. */
  const settle = async (session: string, date: string, action: "confirm" | "changes", outcome: ActionOutcome): Promise<ActionResult> => {
    const status: ActionResult = { focus: { kind: "status", session }, announce: null };
    const failed = (message: Message): ActionResult => {
      update(session, { error: message });
      return { focus: { kind: action === "confirm" ? "confirm" : "submit", session }, announce: message };
    };
    switch (outcome.kind) {
      case "confirmed":
        patchMenu(session, { state: "confirmed", confirmedAt: outcome.confirmedAt });
        update(session, {
          formOpen: false,
          notice: { key: outcome.already ? "reservation.notices.alreadyConfirmed" : "reservation.notices.confirmed" },
        });
        await refresh();
        return status;
      case "changesSent":
        patchMenu(session, { state: "changesRequested", changesRequestedAt: outcome.changesRequestedAt });
        update(session, { formOpen: false, draft: "", draftFor: null, textError: null, notice: { key: "reservation.notices.changesSent" } });
        await refresh();
        return status;
      case "menuOutdated":
        // El mensaje a medio escribir queda: sirve para el menú nuevo.
        update(session, { notice: { key: "reservation.notices.menuOutdated" } });
        await refresh();
        return status;
      case "changesRequested":
        update(session, { formOpen: false, notice: { key: "reservation.notices.changesAlreadyRequested" } });
        await refresh();
        return status;
      case "alreadyConfirmed":
        update(session, { formOpen: false, notice: { key: "reservation.notices.alreadyConfirmedChanges" } });
        await refresh();
        return status;
      case "sendNotFound":
        update(session, { notice: { key: "reservation.notices.sendNotFound" } });
        await refresh();
        return status;
      case "sessionCancelled":
        // La semana se canceló: al volver a leer ya no está en la lista, así que el aviso va arriba, con su fecha.
        weeks.delete(session);
        pageNotice = { key: "reservation.notices.sessionCancelled", date };
        emit();
        await refresh();
        return { focus: { kind: "notice" }, announce: null };
      case "linkNotFound":
        // El link venció mientras la página estaba abierta.
        setState({ kind: "invalidLink" });
        return { focus: { kind: "problem" }, announce: null };
      case "invalidText":
        update(session, { textError: "invalid" });
        return { focus: { kind: "textarea", session }, announce: null };
      case "rateLimited":
        return failed(rateLimitMessage(outcome.retryAfterSeconds));
      case "network":
        return failed({ key: "reservation.errors.network" });
      case "server":
        return failed({ key: "reservation.errors.server" });
    }
  };

  return {
    get state() {
      return state;
    },
    get retrying() {
      return retrying;
    },
    get pageNotice() {
      return pageNotice;
    },
    ui,
    subscribe(listener) {
      listeners.push(listener);
    },
    load,

    async retry() {
      if (retrying) return NOTHING;
      if (!deps.token || !deps.supabaseUrl) {
        await load();
        return { focus: { kind: "problem" }, announce: null };
      }
      retrying = true;
      emit();
      const outcome = await readView();
      retrying = false;
      if (outcome) setState(viewState(outcome));
      else emit();
      // Al enfocar el recuadro del error se lee de nuevo; con la reserva, el saludo.
      return { focus: state.kind === "ready" ? { kind: "greeting" } : { kind: "problem" }, announce: null };
    },

    async confirm(session) {
      const menu = answerable(session);
      const date = findWeek(session)?.date ?? "";
      if (!menu || ui(session).busy || !deps.supabaseUrl || !deps.token) return NOTHING;
      pageNotice = null;
      update(session, { busy: "confirm", error: null, notice: null });
      const outcome = await confirmMenu(deps.supabaseUrl, deps.token, menu.sendId, deps.api);
      update(session, { busy: null });
      return settle(session, date, "confirm", outcome);
    },

    openChanges(session) {
      const menu = answerable(session);
      if (!menu || ui(session).busy) return NOTHING;
      pageNotice = null;
      update(session, { formOpen: true, draftFor: menu.sendId, error: null, notice: null });
      return { focus: { kind: "textarea", session }, announce: null };
    },

    closeChanges(session) {
      if (ui(session).busy) return NOTHING;
      // El mensaje queda guardado por si vuelve a abrir el formulario.
      update(session, { formOpen: false, textError: null, error: null });
      return { focus: { kind: "askChanges", session }, announce: null };
    },

    setDraft(session, text) {
      const current = ui(session);
      const textErrorCleared = current.textError !== null && changesTextProblem(cleanChangesText(text)) === null;
      weeks.set(session, { ...current, draft: text, textError: textErrorCleared ? null : current.textError });
      return { textErrorCleared };
    },

    async submitChanges(session) {
      const menu = answerable(session);
      const date = findWeek(session)?.date ?? "";
      if (!menu || ui(session).busy || !deps.supabaseUrl || !deps.token) return NOTHING;
      const text = cleanChangesText(ui(session).draft);
      const problem = changesTextProblem(text);
      if (problem !== null) {
        update(session, { textError: problem, error: null });
        return { focus: { kind: "textarea", session }, announce: null };
      }
      pageNotice = null;
      update(session, { busy: "changes", draftFor: menu.sendId, error: null, notice: null, textError: null });
      const outcome = await requestChanges(deps.supabaseUrl, deps.token, menu.sendId, text, deps.api);
      update(session, { busy: null });
      return settle(session, date, "changes", outcome);
    },
  };
}
