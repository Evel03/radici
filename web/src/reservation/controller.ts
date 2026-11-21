// Estado de la página /prenotazione/ y lo que hace cada botón, sin DOM (se testea con un fetch simulado). La
// página (pages/prenotazione.ts) pinta lo que dice el estado (render.ts) y le pasa los clics.
// - Al abrirse: lee la reserva del link (POST …/view). Sin token, o con un link que no existe o venció, lo dice.
// - Por semana: confirmar el menú o pedir cambios con un mensaje. Después de cada respuesta, el estado de esa
//   semana se actualiza con lo que devolvió la función y la reserva se vuelve a leer (por si Evelyn mandó otro
//   menú mientras tanto). Lo que pasó queda como aviso en esa semana; un error (sin conexión, demasiados
//   intentos) queda junto a los botones y se anuncia.
// El estado de cada semana (el formulario abierto, el mensaje a medio escribir, el aviso) va por número de
// semana, no por envío: si Evelyn manda un menú nuevo mientras la clienta escribe, el mensaje no se pierde.
// Nunca se registran en la consola el token, la reserva ni el mensaje.
import { normalizeChangesText, type ClientLinkMenu, type ClientLinkView } from "../../../supabase/functions/_shared/client_link.ts";
import type { MessageKey, Params } from "../i18n/core.ts";
import { confirmMenu, fetchView, requestChanges, type ActionOutcome, type ApiOptions, type ViewOutcome } from "./api.ts";

/** Un texto por traducir: la clave y sus parámetros ({chef} lo agrega quien lo pinta). */
export interface Message {
  key: MessageKey;
  params?: Params;
}

export type PageState =
  | { kind: "loading" }
  /** Sin token en el link, con uno que no tiene la forma, o uno que no existe o venció. */
  | { kind: "invalidLink" }
  /** No se pudo leer la reserva (sin conexión, error, demasiados intentos): con «Riprova». */
  | { kind: "error"; message: Message }
  | { kind: "ready"; view: ClientLinkView };

export interface WeekUi {
  /** El formulario de cambios está abierto (en lugar de los botones). */
  formOpen: boolean;
  /** El mensaje, tal como lo escribe. */
  draft: string;
  /** Una respuesta en camino: los botones no hacen nada hasta que vuelva. */
  busy: "confirm" | "changes" | null;
  /** El último error de una respuesta (sin conexión, demasiados intentos…), junto a los botones. */
  error: Message | null;
  /** El mensaje está vacío o es demasiado largo. */
  textError: boolean;
  /** Lo que pasó con la última respuesta (confirmado, cambios enviados, hay un menú más nuevo…). */
  notice: Message | null;
}

/** A dónde va el foco después de una acción (render.ts sabe el id de cada cosa). */
export type Focus =
  | { kind: "status" | "confirm" | "askChanges" | "submit" | "textarea"; week: number }
  | { kind: "problem" };

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
  ui(week: number): Readonly<WeekUi>;
  /** Se llama cada vez que cambia algo que hay que pintar. */
  subscribe(listener: () => void): void;
  /** Lee la reserva (al abrir y con «Riprova»). */
  load(): Promise<void>;
  confirm(week: number): Promise<ActionResult>;
  openChanges(week: number): ActionResult;
  closeChanges(week: number): ActionResult;
  /** El mensaje mientras se escribe (sin volver a pintar). textErrorCleared: el error del texto ya no vale. */
  setDraft(week: number, text: string): { textErrorCleared: boolean };
  submitChanges(week: number): Promise<ActionResult>;
}

/** Mensaje del 429: en minutos (hasta una hora) o en horas; sin tiempo si el servidor no lo dio. */
export function rateLimitMessage(seconds: number | null): Message {
  if (seconds === null || seconds <= 0) return { key: "reservation.errors.rateLimited" };
  if (seconds < 3600) return { key: "reservation.errors.rateLimitedMinutes", params: { minutes: Math.ceil(seconds / 60) } };
  return { key: "reservation.errors.rateLimitedHours", params: { hours: Math.ceil(seconds / 3600) } };
}

const EMPTY_UI: WeekUi = { formOpen: false, draft: "", busy: null, error: null, textError: false, notice: null };
const NOTHING: ActionResult = { focus: null, announce: null };

export function createReservation(deps: ReservationDeps): Reservation {
  let state: PageState = { kind: "loading" };
  const weeks = new Map<number, WeekUi>();
  const listeners: Array<() => void> = [];

  const emit = (): void => {
    for (const listener of listeners) listener();
  };
  const setState = (next: PageState): void => {
    state = next;
    emit();
  };
  const ui = (week: number): WeekUi => weeks.get(week) ?? EMPTY_UI;
  const update = (week: number, patch: Partial<WeekUi>): void => {
    weeks.set(week, { ...ui(week), ...patch });
    emit();
  };

  /** El último envío de una semana, si se puede contestar desde la página: por confirmar, mostrado y no cocinada. */
  const answerable = (week: number): ClientLinkMenu | null => {
    if (state.kind !== "ready") return null;
    const found = state.view.weeks.find((item) => item.week === week);
    const menu = found?.menu;
    return found && !found.done && menu && menu.state === "pending" && menu.content ? menu : null;
  };

  /** La semana con su envío actualizado con lo que devolvió la función (antes de volver a leer la reserva). */
  const patchMenu = (week: number, patch: Partial<ClientLinkMenu>): void => {
    if (state.kind !== "ready") return;
    const view = state.view;
    setState({
      kind: "ready",
      view: { ...view, weeks: view.weeks.map((item) => (item.week === week && item.menu ? { ...item, menu: { ...item.menu, ...patch } } : item)) },
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

  const load = async (): Promise<void> => {
    if (!deps.token) return setState({ kind: "invalidLink" });
    // Sin VITE_SUPABASE_URL en el build la página no puede hablar con la función.
    if (!deps.supabaseUrl) return setState({ kind: "error", message: { key: "reservation.errors.server" } });
    setState({ kind: "loading" });
    setState(viewState(await fetchView(deps.supabaseUrl, deps.token, deps.api)));
  };

  /** Vuelve a leer la reserva después de una respuesta. Si no se puede, queda lo que había (ya actualizado). */
  const refresh = async (): Promise<void> => {
    if (!deps.supabaseUrl || !deps.token) return;
    const outcome = await fetchView(deps.supabaseUrl, deps.token, deps.api);
    if (outcome.kind === "ok" || outcome.kind === "linkNotFound") setState(viewState(outcome));
  };

  /** Lo que pasa después de cada respuesta de la función. */
  const settle = async (week: number, action: "confirm" | "changes", outcome: ActionOutcome): Promise<ActionResult> => {
    const status: ActionResult = { focus: { kind: "status", week }, announce: null };
    const failed = (message: Message): ActionResult => {
      update(week, { error: message });
      return { focus: { kind: action === "confirm" ? "confirm" : "submit", week }, announce: message };
    };
    switch (outcome.kind) {
      case "confirmed":
        patchMenu(week, { state: "confirmed", confirmedAt: outcome.confirmedAt });
        update(week, {
          formOpen: false,
          notice: { key: outcome.already ? "reservation.notices.alreadyConfirmed" : "reservation.notices.confirmed" },
        });
        await refresh();
        return status;
      case "changesSent":
        patchMenu(week, { state: "changesRequested", changesRequestedAt: outcome.changesRequestedAt });
        update(week, { formOpen: false, draft: "", textError: false, notice: { key: "reservation.notices.changesSent" } });
        await refresh();
        return status;
      case "menuOutdated":
        // El mensaje a medio escribir queda: sirve para el menú nuevo.
        update(week, { notice: { key: "reservation.notices.menuOutdated" } });
        await refresh();
        return status;
      case "changesRequested":
        update(week, { formOpen: false, notice: { key: "reservation.notices.changesAlreadyRequested" } });
        await refresh();
        return status;
      case "alreadyConfirmed":
        update(week, { formOpen: false, notice: { key: "reservation.notices.alreadyConfirmedChanges" } });
        await refresh();
        return status;
      case "sendNotFound":
        update(week, { notice: { key: "reservation.notices.sendNotFound" } });
        await refresh();
        return status;
      case "linkNotFound":
        // El link venció mientras la página estaba abierta.
        setState({ kind: "invalidLink" });
        return { focus: { kind: "problem" }, announce: null };
      case "invalidText":
        update(week, { textError: true });
        return { focus: { kind: "textarea", week }, announce: null };
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
    ui,
    subscribe(listener) {
      listeners.push(listener);
    },
    load,

    async confirm(week) {
      const menu = answerable(week);
      if (!menu || ui(week).busy || !deps.supabaseUrl || !deps.token) return NOTHING;
      update(week, { busy: "confirm", error: null, notice: null });
      const outcome = await confirmMenu(deps.supabaseUrl, deps.token, menu.sendId, deps.api);
      update(week, { busy: null });
      return settle(week, "confirm", outcome);
    },

    openChanges(week) {
      if (!answerable(week) || ui(week).busy) return NOTHING;
      update(week, { formOpen: true, error: null, notice: null });
      return { focus: { kind: "textarea", week }, announce: null };
    },

    closeChanges(week) {
      if (ui(week).busy) return NOTHING;
      // El mensaje queda guardado por si vuelve a abrir el formulario.
      update(week, { formOpen: false, textError: false, error: null });
      return { focus: { kind: "askChanges", week }, announce: null };
    },

    setDraft(week, text) {
      const current = ui(week);
      const textErrorCleared = current.textError && normalizeChangesText(text) !== null;
      weeks.set(week, { ...current, draft: text, textError: textErrorCleared ? false : current.textError });
      return { textErrorCleared };
    },

    async submitChanges(week) {
      const menu = answerable(week);
      if (!menu || ui(week).busy || !deps.supabaseUrl || !deps.token) return NOTHING;
      const text = normalizeChangesText(ui(week).draft);
      if (text === null) {
        update(week, { textError: true, error: null });
        return { focus: { kind: "textarea", week }, announce: null };
      }
      update(week, { busy: "changes", error: null, notice: null, textError: false });
      const outcome = await requestChanges(deps.supabaseUrl, deps.token, menu.sendId, text, deps.api);
      update(week, { busy: null });
      return settle(week, "changes", outcome);
    },
  };
}
