// Lo que se ve en /prenotazione/, como árbol de elementos (lib/vdom.ts): puro, sin DOM. Todo texto que llega de
// la función (los platos, la lista, la nota de Evelyn) va como texto, nunca como HTML.
// Orden de la página: el saludo y, si lo hay, un aviso de la página (una semana que se canceló); después (cuando
// llegue) el presupuesto para aceptar; después las semanas. Cada semana: la fecha y la hora de llegada y, si
// Evelyn mandó el menú, su estado, los platos, la lista de compras y la nota, con los botones si está por
// confirmar. Una semana ya cocinada no promete nada que ya no puede pasar (que llegue el menú, que se reenvíe).
// Nada de precios, pagos, dirección ni alergias de la clienta: la página muestra solo lo que trae la foto del envío.
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
import { formatIsoDate } from "../lib/format.ts";
import { h, type VNode } from "../lib/vdom.ts";
import type { Focus, Message, PageState, TextError, WeekUi } from "./controller.ts";
import { formatQuantity, formatRomeDay, shoppingList } from "./format.ts";

/** Lado de la miniatura de un plato, en px CSS (el mismo de .dish__photo en reservation.css). */
export const DISH_PHOTO_SIZE = 72;

export interface RenderInput {
  state: PageState;
  ui: (session: string) => Readonly<WeekUi>;
  i18n: I18n;
  /** «Riprova» en camino. */
  retrying?: boolean;
  /** Aviso de la página entera (una semana que se canceló), o null. */
  pageNotice?: Message | null;
  /** Miniaturas que no cargaron: se pintan sin foto. */
  failedPhotos?: ReadonlySet<string>;
}

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
 * - sent: enviado, sin pedirle nada (ya cocinada, o un envío que la página no puede mostrar);
 * - confirmed: confirmado, con la fecha;
 * - changes: pidió cambios y Evelyn lo manda de nuevo; changesDone: pidió cambios, pero la semana ya se cocinó.
 */
type StatusKind = "pending" | "sent" | "confirmed" | "changes" | "changesDone";

const STATUS: Readonly<Record<StatusKind, { modifier: string; badge: MessageKey; text: MessageKey }>> = {
  pending: { modifier: "pending", badge: "reservation.state.pending", text: "reservation.state.pendingText" },
  sent: { modifier: "sent", badge: "reservation.state.sent", text: "reservation.state.sentText" },
  confirmed: { modifier: "confirmed", badge: "reservation.state.confirmed", text: "reservation.state.confirmedText" },
  changes: { modifier: "changes", badge: "reservation.state.changesRequested", text: "reservation.state.changesRequestedText" },
  changesDone: { modifier: "changes", badge: "reservation.state.changesRequested", text: "reservation.state.changesRequestedDoneText" },
};

function statusKind(week: ClientLinkWeek, menu: ClientLinkMenu): StatusKind {
  if (menu.state === "confirmed") return "confirmed";
  if (menu.state === "changesRequested") return week.done ? "changesDone" : "changes";
  return menu.content !== null && !week.done ? "pending" : "sent";
}

function statusNode(week: ClientLinkWeek, menu: ClientLinkMenu, ui: Readonly<WeekUi>, ctx: Context): VNode {
  const { i18n } = ctx;
  const kind = statusKind(week, menu);
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

function actionsNode(week: ClientLinkWeek, ui: Readonly<WeekUi>, ctx: Context): VNode {
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

function weekNode(week: ClientLinkWeek, ui: Readonly<WeekUi>, ctx: Context): VNode {
  const { i18n } = ctx;
  const id = weekDomId(week.sessionId);
  const title = week.weeks === 1 ? i18n.t("reservation.weekTitleOne") : i18n.t("reservation.weekTitle", { week: week.week, weeks: week.weeks });
  const menu = week.menu;
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
          statusNode(week, menu, ui, ctx),
          menu.content ? contentNode(menu.content, ctx, id) : unreadable,
          // Solo lo que se puede contestar: por confirmar, mostrado y antes de cocinar.
          statusKind(week, menu) === "pending" && actionsNode(week, ui, ctx),
        ],
  );
}

function readyNode(view: ClientLinkView, input: RenderInput): VNode {
  const { i18n, state } = input;
  const ctx: Context = { i18n, state, chef: view.chefName, failedPhotos: input.failedPhotos ?? new Set() };
  const notice = input.pageNotice ?? null;
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
      h("p", { class: "reservation__lead" }, i18n.t("reservation.intro", { chef: ctx.chef })),
    ),
    // Una semana que se canceló mientras la clienta contestaba: ya no está en la lista, el aviso va acá.
    notice && h("p", { class: "notice notice--warn reservation__notice", id: "reservation-notice", tabindex: -1 }, messageText(notice, i18n, state)),
    // Acá va, cuando llegue, el presupuesto para aceptar (antes de las semanas).
    view.weeks.length === 0
      ? h("p", { class: "notice" }, i18n.t("reservation.noWeeks", { chef: ctx.chef }))
      : h(
          "div",
          { class: "weeks" },
          view.weeks.map((week) => weekNode(week, input.ui(week.sessionId), ctx)),
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
