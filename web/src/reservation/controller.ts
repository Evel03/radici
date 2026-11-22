// Estado de la página /prenotazione/ y lo que hace cada botón, sin DOM (se testea con un fetch simulado). La
// página (pages/prenotazione.ts) pinta lo que dice el estado (render.ts) y le pasa los clics.
// - Al abrirse: lee la reserva del link (POST …/view). Sin token, o con un link que no existe o venció, lo dice.
// - El presupuesto (si Evelyn lo mandó, con el menú de la semana 1): aceptarlo (y con él ese menú) o rechazarlo,
//   con un paso de confirmación que un doble toque nunca atraviesa («Sì, rifiuto» no responde hasta
//   DECLINE_GUARD_MS después de abrirlo). Mientras está abierto, el menú que va con él no se confirma solo, ni
//   uno anterior del mismo presupuesto que quedó en otra semana; los cambios se piden como con cualquier menú.
// - Por semana: confirmar el menú o pedir cambios con un mensaje. Después de cada respuesta, el estado de esa
//   semana (o del presupuesto) se actualiza con lo que devolvió la función y la reserva se vuelve a leer (por si
//   Evelyn mandó otro menú mientras tanto). Lo que pasó queda como aviso (arriba, con la fecha, si la semana ya no
//   está); un error (sin conexión, demasiados intentos) queda junto a los botones y se anuncia.
// - Las lecturas de la reserva van numeradas: solo vale la última que se pidió, así una respuesta que llega tarde
//   no pisa una más nueva.
// El estado de cada semana (el formulario abierto, el mensaje a medio escribir, el aviso) va por su sesión
// (sessionId), no por el número ni por el envío: si se cancela una semana anterior las demás se renumeran, y si
// Evelyn manda un menú nuevo mientras la clienta escribe, el mensaje no se pierde (y se le avisa). El del
// presupuesto va por su id.
// Nunca se registran en la consola el token, la reserva ni el mensaje.
import {
  changesTextProblem,
  cleanChangesText,
  type ChangesTextProblem,
  type ClientLinkMenu,
  type ClientLinkQuote,
  type ClientLinkView,
  type ClientLinkWeek,
  type QuoteClosedReason,
} from "../../../supabase/functions/_shared/client_link.ts";
import type { MessageKey, Params } from "../i18n/core.ts";
import { acceptQuote, confirmMenu, declineQuote, fetchView, requestChanges, type ActionOutcome, type ApiOptions, type ViewOutcome } from "./api.ts";

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

/** El estado del recuadro del presupuesto (va por el id del presupuesto: si llega otro, empieza de cero). */
export interface QuoteUi {
  /** «Rifiuto» pidió confirmar: el paso de la confirmación está abierto. */
  declineOpen: boolean;
  /** El envío para el que abrió la confirmación: si llega otra versión mientras tanto, se cierra y se le avisa. */
  declineFor: string | null;
  /** Una respuesta en camino: los botones no hacen nada hasta que vuelva. */
  busy: "accept" | "decline" | null;
  /** El último error de una respuesta (sin conexión, demasiados intentos…), junto a los botones. */
  error: Message | null;
  /** Lo que pasó con la última respuesta (aceptado, rechazado, hay una versión más nueva…). */
  notice: Message | null;
}

/**
 * Qué muestra el presupuesto: pending (por aceptar), changesRequested (pidió cambios a esta versión: Evelyn manda
 * otra), changed (Evelyn lo cambió y lo va a reenviar), accepted, declined, withdrawn, expired, o unreadable (por
 * aceptar, pero la página no puede mostrar lo que vio: no se contesta lo que no se ve).
 */
export type QuoteDisplay = "pending" | "changesRequested" | "changed" | "accepted" | "declined" | "withdrawn" | "expired" | "unreadable";

export interface QuoteView {
  quote: ClientLinkQuote;
  /** La semana cuyo último envío lleva el presupuesto (la 1), o null si no está a la vista. */
  week: ClientLinkWeek | null;
  display: QuoteDisplay;
  /** Aceptarlo (y con él el menú de esa semana): por aceptar, sin cambios pedidos y con todo a la vista. */
  canAccept: boolean;
  /** Rechazarlo: por aceptar (también con cambios pedidos) y con todo a la vista. */
  canDecline: boolean;
}

/** El presupuesto de la reserva y lo que deja hacer, o null si no hay. */
export function quoteView(view: ClientLinkView): QuoteView | null {
  const quote = view.quote;
  if (!quote) return null;
  const week = quote.sendId === null ? null : (view.weeks.find((item) => item.menu?.sendId === quote.sendId) ?? null);
  const none = { quote, week, canAccept: false, canDecline: false };
  if (quote.status !== "sent") return { ...none, display: quote.status };
  const menu = week?.menu;
  // Lo que no se ve no se contesta: la semana del envío, su menú y lo que vio la clienta (las semanas y el precio).
  if (!week || !menu || !menu.content || week.done || !quote.summary) return { ...none, display: "unreadable" };
  if (menu.state === "changesRequested") return { ...none, display: "changesRequested", canDecline: true };
  if (menu.state === "pending") return { ...none, display: "pending", canAccept: true, canDecline: true };
  return { ...none, display: "pending" };
}

/**
 * Cómo va el menú de un envío con el presupuesto, como lo ve la base (private.client_send_quote_state):
 * - none: no lleva presupuesto, o lleva uno aceptado: se confirma o se le piden cambios como cualquier menú (el
 *   envío con el que se aceptó ya quedó confirmado);
 * - open: es el envío que lleva el presupuesto abierto (quote.sendId): se confirma aceptándolo; los cambios se
 *   piden como siempre;
 * - superseded: un envío anterior del mismo presupuesto, todavía abierto, que quedó en otra semana (la que lo
 *   llevaba pasó al final y Evelyn lo reenvió desde la nueva primera): no se confirma (quote_pending), y aceptar el
 *   presupuesto no lo confirma; los cambios sí se piden;
 * - closed: lleva uno rechazado, retirado o vencido, o uno que la página no conoce: ni se confirma ni se piden
 *   cambios.
 */
export type MenuQuoteMode = "none" | "open" | "superseded" | "closed";

export function menuQuoteMode(view: ClientLinkView, menu: ClientLinkMenu): MenuQuoteMode {
  if (menu.quoteId === null) return "none";
  const quote = view.quote;
  if (!quote || quote.id !== menu.quoteId) return "closed";
  if (quote.status === "accepted") return "none";
  if (quote.status !== "sent" && quote.status !== "changed") return "closed";
  return menu.sendId === quote.sendId ? "open" : "superseded";
}

/** A dónde va el foco después de una acción (render.ts sabe el id de cada cosa). */
export type Focus =
  | { kind: "status" | "confirm" | "askChanges" | "submit" | "textarea"; session: string }
  | { kind: "problem" | "greeting" | "notice" | "quoteStatus" | "quoteAccept" | "quoteDecline" | "quoteDeclineQuestion" | "quoteDeclineConfirm" };

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
  /** Un reloj monótono, en ms (por defecto performance.now): el resguardo del rechazo. Los tests lo mueven a mano. */
  now?: () => number;
}

/**
 * Lo que tiene que pasar entre «Rifiuto» y «Sì, rifiuto il preventivo»: antes, el toque no hace nada. El segundo
 * toque de un doble toque (o el segundo clic de un doble clic) llega antes, aunque la página se haya movido.
 */
export const DECLINE_GUARD_MS = 600;

export interface Reservation {
  readonly state: PageState;
  /** «Riprova» en camino: el error queda a la vista, con el botón esperando. */
  readonly retrying: boolean;
  /** Un aviso de la página entera (una semana que se canceló y ya no está en la lista), o null. */
  readonly pageNotice: Message | null;
  /** El estado del recuadro del presupuesto. */
  readonly quoteUi: Readonly<QuoteUi>;
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
  /** «Accetto il preventivo»: acepta el presupuesto, y con él el menú de la semana 1. */
  acceptQuote(): Promise<ActionResult>;
  /**
   * «Rifiuto»: abre el paso de la confirmación (debajo; «Rifiuto» queda en su lugar). Con el paso abierto, lo
   * cierra, salvo un toque enseguida (el segundo de un doble toque), que no hace nada.
   */
  openDecline(): ActionResult;
  /** «No, torna indietro»: lo cierra sin rechazar nada. */
  closeDecline(): ActionResult;
  /** «Sì, rifiuto il preventivo»: lo rechaza, si pasaron DECLINE_GUARD_MS desde que se abrió el paso. */
  declineQuote(): Promise<ActionResult>;
}

/** Mensaje del 429: en minutos (hasta una hora) o en horas; sin tiempo si el servidor no lo dio. */
export function rateLimitMessage(seconds: number | null): Message {
  if (seconds === null || seconds <= 0) return { key: "reservation.errors.rateLimited" };
  if (seconds < 3600) return { key: "reservation.errors.rateLimitedMinutes", params: { minutes: Math.ceil(seconds / 60) } };
  return { key: "reservation.errors.rateLimitedHours", params: { hours: Math.ceil(seconds / 3600) } };
}

/** El aviso de un presupuesto que ya no se contesta, según por qué (si la función lo dijo). */
const CLOSED_NOTICES: Readonly<Record<QuoteClosedReason, MessageKey>> = {
  accepted: "reservation.quote.notices.closedAccepted",
  declined: "reservation.quote.notices.closedDeclined",
  withdrawn: "reservation.quote.notices.closedWithdrawn",
  expired: "reservation.quote.notices.closedExpired",
};

const EMPTY_UI: WeekUi = { formOpen: false, draft: "", draftFor: null, busy: null, error: null, textError: null, notice: null };
const EMPTY_QUOTE_UI: QuoteUi = { declineOpen: false, declineFor: null, busy: null, error: null, notice: null };
const NOTHING: ActionResult = { focus: null, announce: null };

export function createReservation(deps: ReservationDeps): Reservation {
  const now = deps.now ?? ((): number => performance.now());
  let state: PageState = { kind: "loading" };
  let retrying = false;
  let pageNotice: Message | null = null;
  /** Número de la última lectura de la reserva que se pidió: las que llegan después de otra más nueva se descartan. */
  let viewSeq = 0;
  const weeks = new Map<string, WeekUi>();
  let quoteUi: QuoteUi = EMPTY_QUOTE_UI;
  /** El presupuesto al que se refiere quoteUi. */
  let quoteUiFor: string | null = null;
  /** Cuándo se abrió el paso del rechazo (now()): antes de DECLINE_GUARD_MS, «Sì, rifiuto» no hace nada. */
  let declineOpenedAt = 0;
  const listeners: Array<() => void> = [];

  const emit = (): void => {
    for (const listener of listeners) listener();
  };
  const ui = (session: string): WeekUi => weeks.get(session) ?? EMPTY_UI;
  const update = (session: string, patch: Partial<WeekUi>): void => {
    weeks.set(session, { ...ui(session), ...patch });
    emit();
  };
  const updateQuote = (patch: Partial<QuoteUi>): void => {
    quoteUi = { ...quoteUi, ...patch };
    emit();
  };

  /**
   * El estado nuevo. Con una reserva: se olvida lo de las semanas que ya no están, y si llegó otro envío para una
   * semana con el formulario abierto (Evelyn lo mandó de nuevo mientras escribía), se le avisa sin perder el mensaje.
   * Lo del presupuesto empieza de cero si es otro presupuesto; si llegó otra versión con la confirmación del
   * rechazo abierta, se cierra (no se rechaza lo que no vio) y se le avisa.
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
      const quote = next.view.quote;
      if ((quote?.id ?? null) !== quoteUiFor) {
        quoteUi = EMPTY_QUOTE_UI;
        quoteUiFor = quote?.id ?? null;
      } else if (quoteUi.declineOpen && quote && quote.sendId !== quoteUi.declineFor) {
        quoteUi = { ...quoteUi, declineOpen: false, declineFor: null, notice: { key: "reservation.quote.notices.outdated" } };
      }
    }
    emit();
  };

  const findWeek = (session: string): ClientLinkWeek | null =>
    state.kind === "ready" ? (state.view.weeks.find((week) => week.sessionId === session) ?? null) : null;

  /**
   * El último envío de una semana, si se puede contestar desde la página: por confirmar, mostrado y no cocinada. Un
   * menú que va con el presupuesto abierto no se confirma solo (se acepta el presupuesto), ni uno anterior del mismo
   * presupuesto (superseded), pero sí se piden cambios; uno que va con un presupuesto cerrado no se contesta.
   */
  const answerable = (session: string, action: "confirm" | "changes"): ClientLinkMenu | null => {
    const week = findWeek(session);
    const menu = week?.menu;
    if (state.kind !== "ready" || !week || week.done || !menu || menu.state !== "pending" || !menu.content) return null;
    const mode = menuQuoteMode(state.view, menu);
    if (action === "confirm") return mode === "none" ? menu : null;
    return mode === "closed" ? null : menu;
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

  /** El presupuesto actualizado con lo que devolvió la función (antes de volver a leer la reserva). */
  const patchQuote = (patch: Partial<ClientLinkQuote>): void => {
    if (state.kind !== "ready" || !state.view.quote) return;
    setState({ kind: "ready", view: { ...state.view, quote: { ...state.view.quote, ...patch } } });
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
    /**
     * Vuelve a leer la reserva y dice a dónde va el foco: al estado de la semana, que lleva el aviso. Si la semana
     * ya no está (se canceló mientras tanto, también al cerrarse su presupuesto), lo de esa semana se olvida y el
     * aviso va arriba, con su fecha (gone: lo que pasó); si el link venció, al recuadro del problema.
     */
    const reread = async (gone: MessageKey = "reservation.notices.sessionCancelled"): Promise<ActionResult> => {
      await refresh();
      if (state.kind === "invalidLink") return { focus: { kind: "problem" }, announce: null };
      if (findWeek(session)) return status;
      weeks.delete(session);
      pageNotice = { key: gone, date };
      emit();
      return { focus: { kind: "notice" }, announce: null };
    };
    switch (outcome.kind) {
      case "confirmed":
        patchMenu(session, { state: "confirmed", confirmedAt: outcome.confirmedAt });
        update(session, {
          formOpen: false,
          notice: { key: outcome.already ? "reservation.notices.alreadyConfirmed" : "reservation.notices.confirmed" },
        });
        return reread();
      case "changesSent":
        patchMenu(session, { state: "changesRequested", changesRequestedAt: outcome.changesRequestedAt });
        update(session, { formOpen: false, draft: "", draftFor: null, textError: null, notice: { key: "reservation.notices.changesSent" } });
        return reread();
      case "menuOutdated":
        // El mensaje a medio escribir queda: sirve para el menú nuevo.
        update(session, { notice: { key: "reservation.notices.menuOutdated" } });
        return reread();
      case "changesRequested":
        update(session, { formOpen: false, notice: { key: "reservation.notices.changesAlreadyRequested" } });
        return reread();
      case "alreadyConfirmed":
        update(session, { formOpen: false, notice: { key: "reservation.notices.alreadyConfirmedChanges" } });
        return reread();
      case "quotePending":
        // Va con el presupuesto abierto (la página no lo sabía): se confirma aceptando el presupuesto.
        update(session, { formOpen: false, notice: { key: "reservation.notices.quotePending" } });
        return reread();
      case "quoteClosed":
        // Su presupuesto se cerró sin aceptarse: sus semanas se cancelaron, así que al volver a leer esta ya no
        // suele estar (el aviso va arriba y dice que su respuesta no salió).
        update(session, { formOpen: false, notice: { key: "reservation.notices.quoteClosed" } });
        return reread("reservation.notices.quoteClosedGone");
      case "sendNotFound":
        update(session, { notice: { key: "reservation.notices.sendNotFound" } });
        return reread();
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
      // server y lo que estas dos rutas nunca devuelven (las respuestas del presupuesto).
      default:
        return failed({ key: "reservation.errors.server" });
    }
  };

  /** Lo que pasa después de aceptar o rechazar el presupuesto. El foco va a su estado; un error, junto al botón. */
  const settleQuote = async (action: "accept" | "decline", outcome: ActionOutcome, week: ClientLinkWeek | null): Promise<ActionResult> => {
    const status: ActionResult = { focus: { kind: "quoteStatus" }, announce: null };
    const failed = (message: Message): ActionResult => {
      updateQuote({ error: message });
      return { focus: { kind: action === "accept" ? "quoteAccept" : "quoteDeclineConfirm" }, announce: message };
    };
    const noticed = async (key: MessageKey): Promise<ActionResult> => {
      updateQuote({ declineOpen: false, declineFor: null, notice: { key } });
      await refresh();
      return status;
    };
    switch (outcome.kind) {
      case "quoteAccepted":
        patchQuote({ status: "accepted", acceptedAt: outcome.acceptedAt });
        // El menú de la semana del envío quedó confirmado a la misma hora.
        if (week) patchMenu(week.sessionId, { state: "confirmed", confirmedAt: outcome.acceptedAt });
        return noticed(outcome.already ? "reservation.quote.notices.alreadyAccepted" : "reservation.quote.notices.accepted");
      case "quoteDeclined":
        patchQuote({ status: "declined", summary: null });
        return noticed(outcome.already ? "reservation.quote.notices.alreadyDeclined" : "reservation.quote.notices.declined");
      case "menuOutdated":
        return noticed("reservation.quote.notices.outdated");
      case "changesRequested":
        return noticed("reservation.quote.notices.changesRequested");
      case "quoteChanged":
      case "sessionCancelled":
        // Evelyn cambió el precio o las semanas (también si canceló la del envío): manda una versión nueva.
        return noticed("reservation.quote.notices.changed");
      case "quoteClosed":
        // Cerrado sin aceptar: el estado ya lo dice aunque no se pueda volver a leer (sin precios ni botones).
        if (outcome.reason && outcome.reason !== "accepted") patchQuote({ status: outcome.reason, summary: null });
        return noticed(outcome.reason ? CLOSED_NOTICES[outcome.reason] : "reservation.quote.notices.unavailable");
      case "quoteEmpty":
        return noticed("reservation.quote.notices.empty");
      case "sendNotFound":
      case "notAQuote":
        return noticed("reservation.quote.notices.unavailable");
      case "linkNotFound":
        setState({ kind: "invalidLink" });
        return { focus: { kind: "problem" }, announce: null };
      case "rateLimited":
        return failed(rateLimitMessage(outcome.retryAfterSeconds));
      case "network":
        return failed({ key: "reservation.errors.network" });
      default:
        return failed({ key: "reservation.errors.server" });
    }
  };

  /** El presupuesto de ahora y lo que deja hacer, si la página puede hablar con la función. */
  const currentQuote = (): QuoteView | null => (state.kind === "ready" && deps.supabaseUrl && deps.token ? quoteView(state.view) : null);

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
    get quoteUi() {
      return quoteUi;
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
      const menu = answerable(session, "confirm");
      const date = findWeek(session)?.date ?? "";
      if (!menu || ui(session).busy || !deps.supabaseUrl || !deps.token) return NOTHING;
      pageNotice = null;
      update(session, { busy: "confirm", error: null, notice: null });
      const outcome = await confirmMenu(deps.supabaseUrl, deps.token, menu.sendId, deps.api);
      update(session, { busy: null });
      return settle(session, date, "confirm", outcome);
    },

    openChanges(session) {
      const menu = answerable(session, "changes");
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
      const menu = answerable(session, "changes");
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

    async acceptQuote() {
      const current = currentQuote();
      const sendId = current?.quote.sendId ?? null;
      if (!current || !current.canAccept || sendId === null || quoteUi.busy || !deps.supabaseUrl || !deps.token) return NOTHING;
      pageNotice = null;
      updateQuote({ busy: "accept", declineOpen: false, declineFor: null, error: null, notice: null });
      const outcome = await acceptQuote(deps.supabaseUrl, deps.token, sendId, deps.api);
      updateQuote({ busy: null });
      return settleQuote("accept", outcome, current.week);
    },

    openDecline() {
      const current = currentQuote();
      if (!current || !current.canDecline || quoteUi.busy) return NOTHING;
      if (quoteUi.declineOpen) {
        // «Rifiuto» otra vez: el segundo toque de un doble toque no hace nada; uno después cierra el paso.
        if (now() - declineOpenedAt < DECLINE_GUARD_MS) return { focus: { kind: "quoteDeclineQuestion" }, announce: null };
        updateQuote({ declineOpen: false, declineFor: null, error: null });
        return { focus: { kind: "quoteDecline" }, announce: null };
      }
      pageNotice = null;
      declineOpenedAt = now();
      updateQuote({ declineOpen: true, declineFor: current.quote.sendId, error: null, notice: null });
      // El foco va a la pregunta (se lee entera) y no a «Sì, rifiuto»: un Intro de más no rechaza nada.
      return { focus: { kind: "quoteDeclineQuestion" }, announce: null };
    },

    closeDecline() {
      if (quoteUi.busy) return NOTHING;
      updateQuote({ declineOpen: false, declineFor: null, error: null });
      return { focus: { kind: "quoteDecline" }, announce: null };
    },

    async declineQuote() {
      const current = currentQuote();
      const sendId = current?.quote.sendId ?? null;
      // Solo desde la confirmación, y para la versión que tenía a la vista al abrirla.
      if (!current || !current.canDecline || sendId === null || !quoteUi.declineOpen || quoteUi.declineFor !== sendId) return NOTHING;
      if (quoteUi.busy || !deps.supabaseUrl || !deps.token) return NOTHING;
      // Un toque que llega enseguida de abrir el paso es el segundo de un doble toque en «Rifiuto»: no rechaza.
      if (now() - declineOpenedAt < DECLINE_GUARD_MS) return NOTHING;
      pageNotice = null;
      updateQuote({ busy: "decline", error: null, notice: null });
      const outcome = await declineQuote(deps.supabaseUrl, deps.token, sendId, deps.api);
      updateQuote({ busy: null });
      return settleQuote("decline", outcome, current.week);
    },
  };
}
