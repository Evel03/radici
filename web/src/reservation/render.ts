// Lo que se ve en /prenotazione/, como árbol de elementos (lib/vdom.ts): puro, sin DOM. Todo texto que llega de
// la función (los platos, la lista, la nota de Evelyn) va como texto, nunca como HTML.
// Orden de la página: el saludo; después (cuando llegue) el presupuesto para aceptar; después las semanas. Cada
// semana: la fecha y la hora de llegada y, si Evelyn mandó el menú, su estado, los platos, la lista de compras y
// la nota, con los botones si está por confirmar. Nada de precios, pagos, dirección ni alergias de la clienta:
// la página muestra solo lo que trae la foto del envío.
import {
  CHANGES_TEXT_MAX,
  type ClientLinkMenu,
  type ClientLinkView,
  type ClientLinkWeek,
  type MenuContent,
  type ShoppingItem,
  type SnapshotDish,
} from "../../../supabase/functions/_shared/client_link.ts";
import type { I18n } from "../i18n/core.ts";
import { formatIsoDate } from "../lib/format.ts";
import { h, type VNode } from "../lib/vdom.ts";
import type { Focus, Message, PageState, WeekUi } from "./controller.ts";
import { formatQuantity, formatRomeDay, shoppingList } from "./format.ts";

/** Lado de la miniatura de un plato, en px CSS (el mismo de .dish__photo en reservation.css). */
export const DISH_PHOTO_SIZE = 72;

export interface RenderInput {
  state: PageState;
  ui: (week: number) => Readonly<WeekUi>;
  i18n: I18n;
  /** Miniaturas que no cargaron: se pintan sin foto. */
  failedPhotos?: ReadonlySet<string>;
}

/** El id de lo que recibe el foco (Focus del controlador). */
export function focusId(focus: Focus): string {
  if (focus.kind === "problem") return "reservation-problem";
  const suffix = { status: "status", confirm: "confirm", askChanges: "changes", submit: "submit", textarea: "text" }[focus.kind];
  return `week-${focus.week}-${suffix}`;
}

/** Un texto del controlador, con {chef} (el nombre de la cocinera de la reserva, o Evelyn sin reserva). */
export function messageText(message: Message, i18n: I18n, state: PageState): string {
  const chef = state.kind === "ready" ? state.view.chefName : "Evelyn";
  return i18n.t(message.key, { chef, ...message.params });
}

/** El contador del mensaje: lo que escribió sobre el tope (los dos en unidades UTF-16, como maxlength). */
export function changesCountText(length: number, i18n: I18n): string {
  return i18n.t("reservation.changesCount", { count: length, max: CHANGES_TEXT_MAX });
}

interface Context {
  i18n: I18n;
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

function statusNode(week: ClientLinkWeek, menu: ClientLinkMenu, ui: Readonly<WeekUi>, ctx: Context): VNode {
  const { i18n } = ctx;
  const date = formatRomeDay(
    menu.state === "confirmed" ? (menu.confirmedAt ?? menu.sentAt) : menu.state === "changesRequested" ? (menu.changesRequestedAt ?? menu.sentAt) : menu.sentAt,
    i18n.locale,
  );
  const modifier = { pending: "pending", confirmed: "confirmed", changesRequested: "changes" }[menu.state];
  return h(
    "div",
    // Recibe el foco después de una respuesta: el aviso y el estado nuevo se leen juntos.
    { class: `week__status week__status--${modifier}`, id: `week-${week.week}-status`, tabindex: -1 },
    ui.notice && h("p", { class: "week__notice" }, i18n.t(ui.notice.key, { chef: ctx.chef, ...ui.notice.params })),
    h(
      "p",
      { class: "week__state" },
      h("span", { class: "state-badge" }, i18n.t(`reservation.state.${menu.state}`)),
      " ",
      i18n.t(`reservation.state.${menu.state}Text`, { chef: ctx.chef, date }),
    ),
  );
}

function actionsNode(week: ClientLinkWeek, ui: Readonly<WeekUi>, ctx: Context): VNode {
  const { i18n } = ctx;
  const n = week.week;
  const busy = ui.busy !== null;
  const error = ui.error && h("p", { class: "week__error", id: `week-${n}-error` }, i18n.t(ui.error.key, { chef: ctx.chef, ...ui.error.params }));
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
          { class: "btn btn--primary", type: "button", id: `week-${n}-confirm`, "data-action": "confirm", "data-week": n, "aria-disabled": busy ? "true" : null },
          ui.busy === "confirm" ? i18n.t("reservation.sending") : i18n.t("reservation.confirm"),
        ),
        h(
          "button",
          { class: "btn btn--ghost", type: "button", id: `week-${n}-changes`, "data-action": "open-changes", "data-week": n, "aria-disabled": busy ? "true" : null },
          i18n.t("reservation.askChanges"),
        ),
      ),
    );
  }
  const describedBy = [`week-${n}-hint`, `week-${n}-count`, ui.textError ? `week-${n}-text-error` : null, ui.error ? `week-${n}-error` : null]
    .filter(Boolean)
    .join(" ");
  return h(
    "div",
    { class: "week__actions" },
    h(
      "form",
      { class: "changes", id: `week-${n}-form`, "data-week": n, novalidate: true },
      h("label", { class: "field__label", for: `week-${n}-text` }, i18n.t("reservation.changesLabel")),
      h("p", { class: "field__hint", id: `week-${n}-hint` }, i18n.t("reservation.changesHint", { chef: ctx.chef })),
      h(
        "textarea",
        {
          class: "input",
          id: `week-${n}-text`,
          name: "changes",
          rows: 5,
          maxlength: CHANGES_TEXT_MAX,
          "data-week": n,
          "aria-describedby": describedBy,
          "aria-invalid": ui.textError ? "true" : null,
        },
        ui.draft,
      ),
      h("p", { class: "changes__count", id: `week-${n}-count` }, changesCountText(ui.draft.length, i18n)),
      ui.textError && h("p", { class: "field__error", id: `week-${n}-text-error` }, i18n.t("reservation.errors.text", { max: CHANGES_TEXT_MAX })),
      error,
      h(
        "div",
        { class: "actions" },
        h(
          "button",
          { class: "btn btn--primary", type: "submit", id: `week-${n}-submit`, "aria-disabled": busy ? "true" : null },
          ui.busy === "changes" ? i18n.t("reservation.sending") : i18n.t("reservation.changesSubmit"),
        ),
        h(
          "button",
          { class: "btn btn--ghost", type: "button", "data-action": "close-changes", "data-week": n, "aria-disabled": busy ? "true" : null },
          i18n.t("reservation.changesCancel"),
        ),
      ),
    ),
  );
}

function weekNode(week: ClientLinkWeek, ui: Readonly<WeekUi>, ctx: Context): VNode {
  const { i18n } = ctx;
  const idBase = `week-${week.week}`;
  const title = week.weeks === 1 ? i18n.t("reservation.weekTitleOne") : i18n.t("reservation.weekTitle", { week: week.week, weeks: week.weeks });
  const menu = week.menu;
  return h(
    "section",
    { class: "week", id: idBase, "aria-labelledby": `${idBase}-title` },
    h(
      "header",
      { class: "week__head" },
      h("h2", { class: "week__title", id: `${idBase}-title` }, title),
      h("p", { class: "week__when" }, i18n.t("reservation.arrival", { date: formatIsoDate(week.date, i18n.locale), time: week.start })),
    ),
    week.done && h("p", { class: "week__done" }, i18n.t("reservation.weekDone", { chef: ctx.chef })),
    menu === null
      ? h("p", { class: "notice" }, i18n.t("reservation.menuNotSent", { chef: ctx.chef }))
      : [
          statusNode(week, menu, ui, ctx),
          menu.content
            ? contentNode(menu.content, ctx, idBase)
            : h("p", { class: "notice notice--warn" }, i18n.t("reservation.menuUnreadable", { chef: ctx.chef })),
          // Solo lo que se puede contestar: por confirmar, mostrado y antes de cocinar.
          menu.state === "pending" && menu.content !== null && !week.done && actionsNode(week, ui, ctx),
        ],
  );
}

function readyNode(view: ClientLinkView, input: RenderInput): VNode {
  const { i18n } = input;
  const ctx: Context = { i18n, chef: view.chefName, failedPhotos: input.failedPhotos ?? new Set() };
  return h(
    "div",
    { class: "reservation__content" },
    h(
      "div",
      { class: "reservation__intro" },
      h(
        "p",
        { class: "reservation__greeting" },
        view.clientFirstName ? i18n.t("reservation.greeting", { name: view.clientFirstName }) : i18n.t("reservation.greetingNoName"),
      ),
      h("p", { class: "reservation__lead" }, i18n.t("reservation.intro", { chef: ctx.chef })),
    ),
    // Acá va, cuando llegue, el presupuesto para aceptar (antes de las semanas).
    view.weeks.length === 0
      ? h("p", { class: "notice" }, i18n.t("reservation.noWeeks", { chef: ctx.chef }))
      : h(
          "div",
          { class: "weeks" },
          view.weeks.map((week) => weekNode(week, input.ui(week.week), ctx)),
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
          h("button", { class: "btn btn--primary", type: "button", "data-action": "retry" }, i18n.t("reservation.errors.retry")),
        ),
      );
    case "ready":
      return readyNode(state.view, input);
  }
}
