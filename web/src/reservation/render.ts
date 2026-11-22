// Lo que se ve en /prenotazione/, como árbol de elementos (lib/vdom.ts): puro, sin DOM. Todo texto que llega de
// la función (los platos, la lista, la nota de Evelyn) va como texto, nunca como HTML.
// Orden de la página: el saludo y, si lo hay, un aviso de la página (una semana que se canceló, o una respuesta
// que no salió porque su semana ya no está); después, si Evelyn lo mandó, el presupuesto (las semanas con su
// llegada y su precio, el total, el estado con el plazo y «Accetto il preventivo» / «Rifiuto», con un paso para
// confirmar el rechazo que se abre debajo de «Rifiuto», sin mover nada de lo de arriba); después las semanas. Cada
// semana: la fecha y la hora de llegada y, si Evelyn mandó el menú, su estado, los platos, la lista de compras y la
// nota, con los botones si está por confirmar (el menú que va con el presupuesto abierto no se confirma solo, ni
// uno anterior del mismo presupuesto que quedó en otra semana: solo «Chiedo dei cambi»). Con una sola semana, los
// textos del presupuesto van en singular. Una semana ya cocinada no promete nada que ya no puede pasar (que llegue
// el menú, que se reenvíe).
// Nada de pagos, dirección ni alergias de la clienta: la página muestra solo lo que trae la foto del envío; del
// precio, solo el del servicio del presupuesto, y solo en su recuadro.
// Cada semana se identifica por su sesión (ids del DOM y data-session), no por su número.
import {
  CHANGES_TEXT_MAX,
  type ClientLinkMenu,
  type ClientLinkView,
  type ClientLinkWeek,
  type MenuContent,
  type ShoppingItem,
  type SnapshotDish,
} from "../../../supabase/functions/_shared/client_link.ts";
import type { I18n, MessageKey } from "../i18n/core.ts";
import { formatCents, formatIsoDate } from "../lib/format.ts";
import { h, type VNode } from "../lib/vdom.ts";
import {
  menuQuoteMode,
  quoteView,
  type Focus,
  type Message,
  type MenuQuoteMode,
  type PageState,
  type QuoteDisplay,
  type QuoteUi,
  type QuoteView,
  type TextError,
  type WeekUi,
} from "./controller.ts";
import { formatQuantity, formatRomeDay, formatRomeTime, shoppingList } from "./format.ts";

/** Lado de la miniatura de un plato, en px CSS (el mismo de .dish__photo en reservation.css). */
export const DISH_PHOTO_SIZE = 72;

export interface RenderInput {
  state: PageState;
  ui: (session: string) => Readonly<WeekUi>;
  i18n: I18n;
  /** El estado del recuadro del presupuesto (sin él, como recién abierto). */
  quoteUi?: Readonly<QuoteUi>;
  /** «Riprova» en camino. */
  retrying?: boolean;
  /** Aviso de la página entera (una semana que se canceló), o null. */
  pageNotice?: Message | null;
  /** Miniaturas que no cargaron: se pintan sin foto. */
  failedPhotos?: ReadonlySet<string>;
}

const EMPTY_QUOTE_UI: QuoteUi = { declineOpen: false, declineFor: null, busy: null, error: null, notice: null };

/** El prefijo de los ids de una semana: la sesión, que no cambia aunque cambie el número o la fecha. */
export function weekDomId(session: string): string {
  return `week-${session}`;
}

/** El id de lo que recibe el foco (Focus del controlador). */
export function focusId(focus: Focus): string {
  switch (focus.kind) {
    case "problem":
      return "reservation-problem";
    case "greeting":
      return "reservation-greeting";
    case "notice":
      return "reservation-notice";
    case "quoteStatus":
      return "quote-status";
    case "quoteAccept":
      return "quote-accept";
    case "quoteDecline":
      return "quote-decline";
    case "quoteDeclineQuestion":
      return "quote-decline-question";
    case "quoteDeclineConfirm":
      return "quote-decline-confirm";
    default: {
      const suffix = { status: "status", confirm: "confirm", askChanges: "changes", submit: "submit", textarea: "text" }[focus.kind];
      return `${weekDomId(focus.session)}-${suffix}`;
    }
  }
}

/**
 * Un texto del controlador, con {chef} (el nombre de la cocinera de la reserva, o Evelyn sin reserva) y, si trae
 * un día, {date} escrito largo en el idioma de la página.
 */
export function messageText(message: Message, i18n: I18n, state: PageState): string {
  const chef = state.kind === "ready" ? state.view.chefName : "Evelyn";
  const date = message.date ? { date: formatIsoDate(message.date, i18n.locale) } : {};
  return i18n.t(message.key, { chef, ...message.params, ...date });
}

/** El contador del mensaje: lo que escribió sobre el tope (los dos en unidades UTF-16, como maxlength). */
export function changesCountText(length: number, i18n: I18n): string {
  return i18n.t("reservation.changesCount", { count: length, max: CHANGES_TEXT_MAX });
}

/** Qué dice el campo según lo que tiene de malo el mensaje. */
const TEXT_ERRORS: Readonly<Record<TextError, MessageKey>> = {
  empty: "reservation.errors.textEmpty",
  tooLong: "reservation.errors.textTooLong",
  invalid: "reservation.errors.textInvalid",
};

interface Context {
  i18n: I18n;
  state: PageState;
  /** El nombre de la cocinera de la reserva ({chef} en los textos). */
  chef: string;
  failedPhotos: ReadonlySet<string>;
}

/** lang en los textos del envío si están en otro idioma que la página (para los lectores de pantalla). */
function contentLang(content: MenuContent, ctx: Context): string | null {
  return content.locale === ctx.i18n.lang ? null : content.locale;
}

function dishNode(dish: SnapshotDish, id: string, content: MenuContent, ctx: Context): VNode {
  const { i18n } = ctx;
  const lang = contentLang(content, ctx);
  const photo = dish.photo && !ctx.failedPhotos.has(dish.photo.thumb) ? dish.photo.thumb : null;
  const portions = dish.portions === 1 ? i18n.t("reservation.portionsOne") : i18n.t("reservation.portionsOther", { n: dish.portions });
  const allergens =
    dish.allergens.length === 0
      ? h("p", { class: "dish__allergens dish__allergens--none" }, i18n.t("reservation.allergensNone"))
      : h(
          "div",
          { class: "dish__allergens" },
          h("span", { class: "dish__allergens-label", id: `${id}-allergens` }, i18n.t("reservation.allergensLabel")),
          " ",
          h(
            "ul",
            { class: "allergens", "aria-labelledby": `${id}-allergens` },
            dish.allergens.map((allergen) => h("li", { class: "allergens__item" }, i18n.t(`allergens.${allergen}`))),
          ),
        );
  return h(
    "li",
    { class: photo ? "dish dish--photo" : "dish" },
    // La miniatura es decorativa (alt vacío): el nombre del plato está al lado. Si no carga, la página la saca.
    photo &&
      h("img", {
        class: "dish__photo",
        src: photo,
        alt: "",
        width: DISH_PHOTO_SIZE,
        height: DISH_PHOTO_SIZE,
        loading: "lazy",
        decoding: "async",
      }),
    h(
      "div",
      { class: "dish__body" },
      h("p", { class: "dish__name", lang }, dish.name),
      dish.description && h("p", { class: "dish__desc", lang }, dish.description),
      h(
        "p",
        { class: "dish__meta" },
        portions,
        // Espacio duro antes del «·»: en el teléfono el renglón no termina en el punto.
        dish.diet && ["\u00a0· ", h("span", { class: "dish__diet" }, i18n.t(`diets.${dish.diet}`))],
      ),
      allergens,
    ),
  );
}

function itemNode(item: ShoppingItem, content: MenuContent, ctx: Context): VNode {
  return h(
    "li",
    { class: "shopping__item" },
    h("span", { class: "shopping__name", lang: contentLang(content, ctx) }, item.name),
    item.quantity !== null && item.unit !== null && h("span", { class: "shopping__qty" }, formatQuantity(item.quantity, item.unit, ctx.i18n)),
  );
}

function shoppingNode(content: MenuContent, ctx: Context, idBase: string): VNode {
  const { i18n } = ctx;
  const { toBuy, atHome } = shoppingList(content.items);
  return h(
    "section",
    { class: "menu__part", "aria-labelledby": `${idBase}-shopping` },
    h("h3", { class: "menu__title", id: `${idBase}-shopping` }, i18n.t("reservation.shoppingTitle")),
    content.items.length === 0
      ? h("p", { class: "menu__empty" }, i18n.t("reservation.shoppingEmpty", { chef: ctx.chef }))
      : h("p", { class: "menu__intro" }, i18n.t("reservation.shoppingIntro")),
    toBuy.map((group) =>
      h(
        "div",
        { class: "shopping__group" },
        h("h4", { class: "shopping__section" }, i18n.t(`reservation.sections.${group.section}`)),
        h(
          "ul",
          { class: "shopping" },
          group.items.map((item) => itemNode(item, content, ctx)),
        ),
      ),
    ),
    atHome.length > 0 &&
      h(
        "div",
        { class: "shopping__group" },
        h("h4", { class: "shopping__section" }, i18n.t("reservation.atHomeTitle")),
        h(
          "ul",
          { class: "shopping shopping--home" },
          atHome.map((item) => itemNode(item, content, ctx)),
        ),
      ),
  );
}

function contentNode(content: MenuContent, ctx: Context, idBase: string): VNode {
  const { i18n } = ctx;
  return h(
    "div",
    { class: "menu" },
    h(
      "section",
      { class: "menu__part", "aria-labelledby": `${idBase}-dishes` },
      h("h3", { class: "menu__title", id: `${idBase}-dishes` }, i18n.t("reservation.dishesTitle")),
      h(
        "ul",
        { class: "dishes" },
        content.dishes.map((dish, index) => dishNode(dish, `${idBase}-dish-${index}`, content, ctx)),
      ),
    ),
    shoppingNode(content, ctx, idBase),
    content.note &&
      h(
        "section",
        { class: "menu__part", "aria-labelledby": `${idBase}-note` },
        h("h3", { class: "menu__title", id: `${idBase}-note` }, i18n.t("reservation.noteTitle", { chef: ctx.chef })),
        // Con sus saltos de línea (white-space: pre-line en reservation.css), como texto.
        h("p", { class: "menu__note", lang: contentLang(content, ctx) }, content.note),
      ),
  );
}

/**
 * Cómo se muestra el estado del último envío de una semana:
 * - pending: por confirmar, con los botones (se ve y la semana no se cocinó);
 * - quotePending: va con el presupuesto abierto: se confirma aceptándolo (arriba); acá solo se piden cambios;
 * - quoteSuperseded: un envío anterior del mismo presupuesto, todavía abierto, que quedó en otra semana: aceptar no
 *   lo confirma (se confirma después, como cualquier menú); acá solo se piden cambios;
 * - quoteClosed: iba con un presupuesto que ya no se contesta (rechazado, retirado o vencido): sin botones;
 * - sent: enviado, sin pedirle nada (ya cocinada, o un envío que la página no puede mostrar);
 * - confirmed: confirmado, con la fecha (también el de un presupuesto aceptado);
 * - changes: pidió cambios y Evelyn lo manda de nuevo; changesDone: pidió cambios, pero ya no hay reenvío (la
 *   semana se cocinó, o el presupuesto se cerró).
 */
type StatusKind = "pending" | "quotePending" | "quoteSuperseded" | "quoteClosed" | "sent" | "confirmed" | "changes" | "changesDone";

const STATUS: Readonly<Record<StatusKind, { modifier: string; badge: MessageKey; text: MessageKey }>> = {
  pending: { modifier: "pending", badge: "reservation.state.pending", text: "reservation.state.pendingText" },
  quotePending: { modifier: "pending", badge: "reservation.state.quotePending", text: "reservation.state.quotePendingText" },
  quoteSuperseded: { modifier: "sent", badge: "reservation.state.sent", text: "reservation.state.quoteSupersededText" },
  quoteClosed: { modifier: "sent", badge: "reservation.state.sent", text: "reservation.state.quoteClosedText" },
  sent: { modifier: "sent", badge: "reservation.state.sent", text: "reservation.state.sentText" },
  confirmed: { modifier: "confirmed", badge: "reservation.state.confirmed", text: "reservation.state.confirmedText" },
  changes: { modifier: "changes", badge: "reservation.state.changesRequested", text: "reservation.state.changesRequestedText" },
  changesDone: { modifier: "changes", badge: "reservation.state.changesRequested", text: "reservation.state.changesRequestedDoneText" },
};

function statusKind(week: ClientLinkWeek, menu: ClientLinkMenu, mode: MenuQuoteMode): StatusKind {
  if (menu.state === "confirmed") return "confirmed";
  if (menu.state === "changesRequested") return week.done || mode === "closed" ? "changesDone" : "changes";
  if (menu.content === null || week.done) return "sent";
  if (mode === "open") return "quotePending";
  if (mode === "superseded") return "quoteSuperseded";
  return mode === "closed" ? "quoteClosed" : "pending";
}

function statusNode(week: ClientLinkWeek, menu: ClientLinkMenu, mode: MenuQuoteMode, ui: Readonly<WeekUi>, ctx: Context): VNode {
  const { i18n } = ctx;
  const kind = statusKind(week, menu, mode);
  const status = STATUS[kind];
  const at = kind === "confirmed" ? menu.confirmedAt : kind === "changes" || kind === "changesDone" ? menu.changesRequestedAt : null;
  const date = formatRomeDay(at ?? menu.sentAt, i18n.locale);
  return h(
    "div",
    // Recibe el foco después de una respuesta: el aviso y el estado nuevo se leen juntos.
    { class: `week__status week__status--${status.modifier}`, id: `${weekDomId(week.sessionId)}-status`, tabindex: -1 },
    ui.notice && h("p", { class: "week__notice" }, messageText(ui.notice, i18n, ctx.state)),
    h(
      "p",
      { class: "week__state" },
      h("span", { class: "state-badge" }, i18n.t(status.badge)),
      " ",
      i18n.t(status.text, { chef: ctx.chef, date }),
    ),
  );
}

/** Los botones de una semana: «Confermo il menù» (salvo un menú con el presupuesto abierto) y «Chiedo dei cambi». */
function actionsNode(week: ClientLinkWeek, ui: Readonly<WeekUi>, ctx: Context, withConfirm: boolean): VNode {
  const { i18n } = ctx;
  const id = weekDomId(week.sessionId);
  const session = week.sessionId;
  const busy = ui.busy !== null;
  const error = ui.error && h("p", { class: "week__error", id: `${id}-error` }, messageText(ui.error, i18n, ctx.state));
  if (!ui.formOpen) {
    return h(
      "div",
      { class: "week__actions" },
      error,
      h(
        "div",
        { class: "actions" },
        // aria-disabled y no disabled: el botón conserva el foco mientras espera la respuesta.
        withConfirm &&
          h(
            "button",
            { class: "btn btn--primary", type: "button", id: `${id}-confirm`, "data-action": "confirm", "data-session": session, "aria-disabled": busy ? "true" : null },
            ui.busy === "confirm" ? i18n.t("reservation.sending") : i18n.t("reservation.confirm"),
          ),
        h(
          "button",
          { class: "btn btn--ghost", type: "button", id: `${id}-changes`, "data-action": "open-changes", "data-session": session, "aria-disabled": busy ? "true" : null },
          i18n.t("reservation.askChanges"),
        ),
      ),
    );
  }
  const describedBy = [`${id}-hint`, `${id}-count`, ui.textError ? `${id}-text-error` : null, ui.error ? `${id}-error` : null]
    .filter(Boolean)
    .join(" ");
  return h(
    "div",
    { class: "week__actions" },
    h(
      "form",
      { class: "changes", id: `${id}-form`, "data-session": session, novalidate: true },
      h("label", { class: "field__label", for: `${id}-text` }, i18n.t("reservation.changesLabel")),
      h("p", { class: "field__hint", id: `${id}-hint` }, i18n.t("reservation.changesHint", { chef: ctx.chef })),
      h(
        "textarea",
        {
          class: "input",
          id: `${id}-text`,
          name: "changes",
          rows: 5,
          maxlength: CHANGES_TEXT_MAX,
          "data-session": session,
          "aria-describedby": describedBy,
          "aria-invalid": ui.textError ? "true" : null,
        },
        ui.draft,
      ),
      h("p", { class: "changes__count", id: `${id}-count` }, changesCountText(ui.draft.length, i18n)),
      ui.textError &&
        h("p", { class: "field__error", id: `${id}-text-error` }, i18n.t(TEXT_ERRORS[ui.textError], { max: CHANGES_TEXT_MAX, chef: ctx.chef })),
      error,
      h(
        "div",
        { class: "actions" },
        h(
          "button",
          { class: "btn btn--primary", type: "submit", id: `${id}-submit`, "aria-disabled": busy ? "true" : null },
          ui.busy === "changes" ? i18n.t("reservation.sending") : i18n.t("reservation.changesSubmit"),
        ),
        h(
          "button",
          { class: "btn btn--ghost", type: "button", "data-action": "close-changes", "data-session": session, "aria-disabled": busy ? "true" : null },
          i18n.t("reservation.changesCancel"),
        ),
      ),
    ),
  );
}

function weekNode(week: ClientLinkWeek, ui: Readonly<WeekUi>, ctx: Context, view: ClientLinkView): VNode {
  const { i18n } = ctx;
  const id = weekDomId(week.sessionId);
  const title = week.weeks === 1 ? i18n.t("reservation.weekTitleOne") : i18n.t("reservation.weekTitle", { week: week.week, weeks: week.weeks });
  const menu = week.menu;
  const mode: MenuQuoteMode = menu ? menuQuoteMode(view, menu) : "none";
  const kind = menu ? statusKind(week, menu, mode) : null;
  // Una semana ya cocinada sin menú enviado (por ejemplo, una que se arregló por WhatsApp): no se promete un menú.
  const missing = week.done ? null : h("p", { class: "notice" }, i18n.t("reservation.menuNotSent", { chef: ctx.chef }));
  const unreadable = week.done
    ? h("p", { class: "notice notice--warn" }, i18n.t("reservation.menuUnreadableDone"))
    : h("p", { class: "notice notice--warn" }, i18n.t("reservation.menuUnreadable", { chef: ctx.chef }));
  return h(
    "section",
    { class: "week", id, "aria-labelledby": `${id}-title` },
    h(
      "header",
      { class: "week__head" },
      h("h2", { class: "week__title", id: `${id}-title` }, title),
      h("p", { class: "week__when" }, i18n.t("reservation.arrival", { date: formatIsoDate(week.date, i18n.locale), time: week.start })),
    ),
    week.done && h("p", { class: "week__done" }, i18n.t("reservation.weekDone", { chef: ctx.chef })),
    menu === null
      ? missing
      : [
          statusNode(week, menu, mode, ui, ctx),
          menu.content ? contentNode(menu.content, ctx, id) : unreadable,
          // Solo lo que se puede contestar: por confirmar, mostrado y antes de cocinar. Con el presupuesto abierto,
          // el menú que lo lleva se confirma aceptándolo (arriba) y uno anterior, después: acá, solo los cambios.
          (kind === "pending" || kind === "quotePending" || kind === "quoteSuperseded") && actionsNode(week, ui, ctx, kind === "pending"),
        ],
  );
}

// ---------------------------------------------------------------------------
// El presupuesto
// ---------------------------------------------------------------------------

/** Cómo se muestra el estado del presupuesto: el modificador del recuadro, la etiqueta y el texto. */
const QUOTE_STATUS: Readonly<Record<QuoteDisplay, { modifier: string; badge: MessageKey; text: MessageKey }>> = {
  pending: { modifier: "pending", badge: "reservation.quote.state.pending", text: "reservation.quote.state.pendingText" },
  changesRequested: { modifier: "changes", badge: "reservation.quote.state.changesRequested", text: "reservation.quote.state.changesRequestedText" },
  changed: { modifier: "changes", badge: "reservation.quote.state.changed", text: "reservation.quote.state.changedText" },
  accepted: { modifier: "accepted", badge: "reservation.quote.state.accepted", text: "reservation.quote.state.acceptedText" },
  declined: { modifier: "closed", badge: "reservation.quote.state.declined", text: "reservation.quote.state.declinedText" },
  withdrawn: { modifier: "closed", badge: "reservation.quote.state.withdrawn", text: "reservation.quote.state.withdrawnText" },
  expired: { modifier: "closed", badge: "reservation.quote.state.expired", text: "reservation.quote.state.expiredText" },
  unreadable: { modifier: "closed", badge: "reservation.quote.state.pending", text: "reservation.quote.state.unreadableText" },
};

/**
 * Cuántas semanas propone el presupuesto: las de lo que vio la clienta o, sin eso (cambiado, o una foto que no se
 * lee), las de la reserva, que son las suyas (un pedido con presupuesto no tiene otras semanas vivas).
 */
function quoteWeekCount(qv: QuoteView, view: ClientLinkView): number {
  return qv.quote.summary?.weeks.length ?? view.weeks.length;
}

/**
 * El texto del estado: por aceptar, hasta cuándo (el plazo en Roma: el día y la hora, y que esas fechas, o esa
 * fecha, quedan reservadas); con cambios pedidos, el día que los pidió; aceptado, el día que lo aceptó; los demás,
 * sin fecha.
 */
function quoteStatusText(qv: QuoteView, ctx: Context, single: boolean): string {
  const { i18n } = ctx;
  const { quote } = qv;
  const day = (at: string): string => formatRomeDay(at, i18n.locale);
  switch (qv.display) {
    case "pending":
      return quote.holdUntil
        ? i18n.t(single ? "reservation.quote.state.pendingTextOne" : "reservation.quote.state.pendingText", {
            date: day(quote.holdUntil),
            time: formatRomeTime(quote.holdUntil),
          })
        : i18n.t("reservation.quote.state.pendingNoDeadline", { chef: ctx.chef, date: day(quote.sentAt) });
    case "changesRequested":
      return i18n.t("reservation.quote.state.changesRequestedText", { chef: ctx.chef, date: day(qv.week?.menu?.changesRequestedAt ?? quote.sentAt) });
    case "accepted":
      return i18n.t("reservation.quote.state.acceptedText", { date: day(quote.acceptedAt ?? quote.sentAt) });
    default:
      return i18n.t(QUOTE_STATUS[qv.display].text, { chef: ctx.chef });
  }
}

/** Lo que vio la clienta: cada semana con su llegada (y su precio si son varias) y el precio del servicio. */
function quoteSummaryNode(qv: QuoteView, ctx: Context): VNode | null {
  const { i18n } = ctx;
  const summary = qv.quote.summary;
  const shown = qv.display === "pending" || qv.display === "changesRequested" || qv.display === "accepted";
  if (!summary || !shown) return null;
  const several = summary.weeks.length > 1;
  return h(
    "div",
    { class: "quote__summary" },
    h(
      "ul",
      { class: "quote__weeks" },
      summary.weeks.map((week, index) =>
        h(
          "li",
          { class: "quote__week" },
          several && h("span", { class: "quote__week-label" }, i18n.t("reservation.quote.weekLabel", { week: index + 1 })),
          h("span", { class: "quote__week-when" }, i18n.t("reservation.arrival", { date: formatIsoDate(week.date, i18n.locale), time: week.start })),
          several && h("span", { class: "quote__week-price" }, formatCents(week.serviceCents, i18n.locale)),
        ),
      ),
    ),
    h(
      "p",
      { class: "quote__total" },
      h("span", { class: "quote__total-label" }, i18n.t(several ? "reservation.quote.total" : "reservation.quote.totalOne")),
      " ",
      h("strong", { class: "quote__total-value" }, formatCents(summary.totalCents, i18n.locale)),
    ),
  );
}

/**
 * Los botones del presupuesto y el paso para confirmar el rechazo. El paso se abre debajo de «Rifiuto», que queda
 * en su lugar (abierto: tocarlo de nuevo lo cierra), y todo lo de arriba sigue igual: un doble toque en «Rifiuto»
 * cae otra vez en «Rifiuto», nunca en «Sì, rifiuto il preventivo», sea cual sea el largo de los textos de cada
 * idioma. «Sì» va al final, después de «No, torna indietro» (y el controlador no lo deja responder enseguida).
 */
function quoteActionsNode(qv: QuoteView, quoteUi: Readonly<QuoteUi>, ctx: Context, single: boolean): VNode | null {
  const { i18n } = ctx;
  if (!qv.canAccept && !qv.canDecline) return null;
  const busy = quoteUi.busy !== null;
  const disabled = busy ? "true" : null;
  const open = quoteUi.declineOpen;
  const error = quoteUi.error && h("p", { class: "quote__error", id: "quote-error" }, messageText(quoteUi.error, i18n, ctx.state));
  return h(
    "div",
    { class: "quote__actions" },
    qv.canAccept && h("p", { class: "quote__hint" }, i18n.t(single ? "reservation.quote.acceptHintOne" : "reservation.quote.acceptHint")),
    // El error de aceptar, arriba de los botones; con el paso abierto, el del rechazo va junto a «Sì» (abajo).
    !open && error,
    h(
      "div",
      { class: "actions" },
      qv.canAccept &&
        h(
          "button",
          { class: "btn btn--primary", type: "button", id: "quote-accept", "data-action": "accept-quote", "aria-disabled": disabled },
          quoteUi.busy === "accept" ? i18n.t("reservation.sending") : i18n.t("reservation.quote.accept"),
        ),
      h(
        "button",
        {
          class: "btn btn--ghost",
          type: "button",
          id: "quote-decline",
          "data-action": "decline-quote",
          "aria-expanded": open ? "true" : "false",
          "aria-controls": open ? "quote-confirm" : null,
          "aria-disabled": disabled,
        },
        i18n.t("reservation.quote.decline"),
      ),
    ),
    // Los cambios se piden en el menú de esa semana (abajo), como con cualquier menú.
    !open && qv.canAccept && h("p", { class: "quote__more" }, i18n.t("reservation.quote.changesHint")),
    open &&
      h(
        "div",
        { class: "quote__confirm", id: "quote-confirm", role: "group", "aria-labelledby": "quote-decline-question" },
        // Recibe el foco al abrirse: se lee la pregunta antes que los botones.
        h(
          "p",
          { class: "quote__question", id: "quote-decline-question", tabindex: -1 },
          i18n.t(single ? "reservation.quote.declineQuestionOne" : "reservation.quote.declineQuestion", { chef: ctx.chef }),
        ),
        error,
        h(
          "div",
          { class: "actions" },
          h(
            "button",
            { class: "btn btn--ghost", type: "button", id: "quote-decline-cancel", "data-action": "decline-quote-cancel", "aria-disabled": disabled },
            i18n.t("reservation.quote.declineCancel"),
          ),
          h(
            "button",
            { class: "btn btn--danger", type: "button", id: "quote-decline-confirm", "data-action": "decline-quote-confirm", "aria-disabled": disabled },
            quoteUi.busy === "decline" ? i18n.t("reservation.sending") : i18n.t("reservation.quote.declineConfirm"),
          ),
        ),
      ),
  );
}

/** El recuadro del presupuesto, arriba de las semanas. single: propone una sola semana (los textos, en singular). */
function quoteNode(qv: QuoteView, quoteUi: Readonly<QuoteUi>, ctx: Context, single: boolean): VNode {
  const { i18n } = ctx;
  const status = QUOTE_STATUS[qv.display];
  return h(
    "section",
    { class: `quote quote--${status.modifier}`, id: "quote", "aria-labelledby": "quote-title" },
    h(
      "header",
      { class: "quote__head" },
      h("h2", { class: "quote__title", id: "quote-title" }, i18n.t("reservation.quote.title")),
      qv.quote.version > 1 && h("p", { class: "quote__version" }, i18n.t("reservation.quote.version", { version: qv.quote.version })),
    ),
    h(
      "div",
      // Recibe el foco después de aceptar o rechazar: el aviso y el estado nuevo se leen juntos.
      { class: `quote__status quote__status--${status.modifier}`, id: "quote-status", tabindex: -1 },
      quoteUi.notice && h("p", { class: "quote__notice" }, messageText(quoteUi.notice, i18n, ctx.state)),
      h("p", { class: "quote__state" }, h("span", { class: "state-badge" }, i18n.t(status.badge)), " ", quoteStatusText(qv, ctx, single)),
    ),
    quoteSummaryNode(qv, ctx),
    quoteActionsNode(qv, quoteUi, ctx, single),
  );
}

function readyNode(view: ClientLinkView, input: RenderInput): VNode {
  const { i18n, state } = input;
  const ctx: Context = { i18n, state, chef: view.chefName, failedPhotos: input.failedPhotos ?? new Set() };
  const notice = input.pageNotice ?? null;
  const qv = quoteView(view);
  // Con el presupuesto por aceptar (o por llegar su versión nueva), la presentación habla del presupuesto.
  const open = qv !== null && (qv.quote.status === "sent" || qv.quote.status === "changed");
  const single = qv !== null && quoteWeekCount(qv, view) === 1;
  const lead = open ? (single ? "reservation.introQuoteOne" : "reservation.introQuote") : "reservation.intro";
  return h(
    "div",
    { class: "reservation__content" },
    h(
      "div",
      { class: "reservation__intro" },
      // Recibe el foco cuando «Riprova» trae la reserva.
      h(
        "p",
        { class: "reservation__greeting", id: "reservation-greeting", tabindex: -1 },
        view.clientFirstName ? i18n.t("reservation.greeting", { name: view.clientFirstName }) : i18n.t("reservation.greetingNoName"),
      ),
      h("p", { class: "reservation__lead" }, i18n.t(lead, { chef: ctx.chef })),
    ),
    // Una semana que ya no está en la lista (se canceló, o se cerró su presupuesto, mientras la clienta contestaba):
    // el aviso va acá, con su fecha.
    notice && h("p", { class: "notice notice--warn reservation__notice", id: "reservation-notice", tabindex: -1 }, messageText(notice, i18n, state)),
    // El presupuesto, antes de las semanas.
    qv && quoteNode(qv, input.quoteUi ?? EMPTY_QUOTE_UI, ctx, single),
    view.weeks.length === 0
      ? h("p", { class: "notice" }, i18n.t("reservation.noWeeks", { chef: ctx.chef }))
      : h(
          "div",
          { class: "weeks" },
          view.weeks.map((week) => weekNode(week, input.ui(week.sessionId), ctx, view)),
        ),
  );
}

/** El contenido de la página para un estado. */
export function reservationTree(input: RenderInput): VNode {
  const { state, i18n } = input;
  switch (state.kind) {
    case "loading":
      return h("div", { class: "reservation__content" }, h("p", { class: "reservation__loading" }, i18n.t("reservation.loading")));
    case "invalidLink":
      return h(
        "div",
        { class: "reservation__content" },
        h(
          "div",
          { class: "problem", id: "reservation-problem", tabindex: -1 },
          h("h2", { class: "problem__title" }, i18n.t("reservation.errors.invalidLinkTitle")),
          h("p", { class: "problem__text" }, i18n.t("reservation.errors.invalidLink")),
          h("a", { class: "btn btn--ghost", href: "/" }, i18n.t("reservation.home")),
        ),
      );
    case "error":
      return h(
        "div",
        { class: "reservation__content" },
        h(
          "div",
          { class: "problem", id: "reservation-problem", tabindex: -1 },
          h("p", { class: "notice notice--error" }, messageText(state.message, i18n, state)),
          // Con id y aria-disabled mientras reintenta: el foco no se pierde.
          h(
            "button",
            {
              class: "btn btn--primary",
              type: "button",
              id: "reservation-retry",
              "data-action": "retry",
              "aria-disabled": input.retrying ? "true" : null,
            },
            input.retrying ? i18n.t("reservation.errors.retrying") : i18n.t("reservation.errors.retry"),
          ),
        ),
      );
    case "ready":
      return readyNode(state.view, input);
  }
}
