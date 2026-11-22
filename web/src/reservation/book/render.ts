// El libro del menú como árbol de elementos (lib/vdom.ts): puro, sin DOM. Todo lo que llega de la función (los
// platos, sus ingredientes) va como texto, nunca como HTML.
// Un diálogo a pantalla completa (en la computadora, un libro centrado) con un carrusel de páginas: la tapa (la marca,
// «Il menù della settimana k», el día y la llegada, «di Evelyn»), un plato por página (la foto grande arriba, o una
// lámina con la inicial si no tiene; el nombre, la descripción, los ingredientes, los alérgenos y la dieta como
// etiquetas, las porciones) y la última página, que vuelve a lo que se puede hacer en la semana. Abajo, las flechas,
// «2 / 7» y los puntos. view.ts lo monta y, al pasar de página, cambia lo mismo que pinta acá (pagePresentation).
import type { ClientLinkWeek, MenuContent, SnapshotDish } from "../../../../supabase/functions/_shared/client_link.ts";
import type { I18n, MessageKey } from "../../i18n/core.ts";
import { formatIsoDate } from "../../lib/format.ts";
import { h, type VNode } from "../../lib/vdom.ts";
import { bookPages, canGo, clampPage, pagePresentation, showDots, type BookPage, type ClosingKind } from "./state.ts";

export const BOOK_ID = "book";
export const BOOK_LIVE_ID = "book-live";
export const BOOK_COUNT_ID = "book-count";
export const BOOK_PREV_ID = "book-prev";
export const BOOK_NEXT_ID = "book-next";
export const BOOK_CLOSE_ID = "book-close";
export const BOOK_VIEWPORT_ID = "book-viewport";

export function bookPageId(index: number): string {
  return `book-page-${index}`;
}

export function bookDotId(index: number): string {
  return `book-dot-${index}`;
}

export interface BookInput {
  week: ClientLinkWeek;
  /** El envío que se muestra (el último de la semana, ya leído). */
  content: MenuContent;
  /** La página que se ve (se acomoda entre la tapa y la última). */
  page: number;
  i18n: I18n;
  /** La cocinera de la reserva ({chef}). */
  chef: string;
  /** La marca (VITE_BRAND_NAME), como el logotipo de la web. */
  brand: string;
  closing: ClosingKind;
  /** Fotos que no cargaron: la página muestra la lámina sin foto. */
  failedPhotos?: ReadonlySet<string>;
}

/** El nombre del libro (el del diálogo y el título de la tapa): «Il menù della settimana 1», o «Il tuo menù». */
export function bookTitle(week: Pick<ClientLinkWeek, "week" | "weeks">, i18n: I18n): string {
  return week.weeks === 1 ? i18n.t("book.titleOne") : i18n.t("book.title", { week: week.week });
}

/** Cómo se llama una página para los lectores de pantalla: la tapa, el plato o la última. */
export function pageName(page: BookPage | undefined, content: MenuContent, i18n: I18n): string {
  if (!page || page.kind === "closing") return i18n.t("book.closingName");
  if (page.kind === "cover") return i18n.t("book.coverName");
  return content.dishes[page.dish]?.name ?? "";
}

/** «2 di 7: Lasagne al ragù»: el nombre de cada página, de cada punto y lo que se anuncia al pasar de página. */
export function pageLabel(index: number, count: number, name: string, i18n: I18n): string {
  return i18n.t("book.pageLabel", { page: index + 1, count, name });
}

/** Lo que se lee entre las flechas: «2 / 7». */
export function counterText(index: number, count: number, i18n: I18n): string {
  return i18n.t("book.counter", { page: index + 1, count });
}

/** Los atributos de una página que cambian al pasar de página: los mismos que pone view.ts (pagePresentation). */
export function pageAttrs(index: number, current: number): { class: string; hidden: boolean; "aria-hidden": string | null; inert: boolean } {
  const view = pagePresentation(index, current);
  return {
    class: view.current ? "book__page is-current" : "book__page",
    hidden: !view.shown,
    "aria-hidden": view.current ? null : "true",
    inert: !view.current,
  };
}

interface Ctx {
  input: BookInput;
  /** lang de los textos del envío si están en otro idioma que la página (para los lectores de pantalla). */
  lang: string | null;
}

/**
 * Una página: el envoltorio que se muestra, se oculta y da vuelta (pageAttrs) y adentro la hoja, que es la diapositiva
 * del carrusel (role group, «pagina», «2 di 7: Lasagne») y su propio scroll. La hoja entra en el orden del Tab (con las
 * flechas ↑ ↓ se lee una página larga) y recibe el foco al abrir el libro y cuando se va la página que lo tenía.
 */
function pageNode(ctx: Ctx, index: number, label: string, modifier: string, ...children: VNode[]): VNode {
  const attrs = pageAttrs(index, ctx.input.page);
  return h(
    "div",
    { ...attrs, class: `${attrs.class} book__page--${modifier}`, id: bookPageId(index), "data-page": index },
    h(
      "div",
      {
        class: "book__sheet",
        role: "group",
        "aria-roledescription": ctx.input.i18n.t("book.slide"),
        "aria-label": label,
        tabindex: 0,
      },
      ...children,
    ),
  );
}

/** El filete con el rombo, entre el título y lo demás (decorativo). */
function ornament(): VNode {
  return h("div", { class: "book__ornament", "aria-hidden": "true" });
}

function coverNode(ctx: Ctx, index: number, label: string): VNode {
  const { week, i18n, chef, brand, content } = ctx.input;
  const dishes = content.dishes.length;
  return pageNode(
    ctx,
    index,
    label,
    "cover",
    h(
      "div",
      { class: "book__cover" },
      // El logotipo de la web: la marca sobre el filete y el rótulo, en italiano en todos los idiomas.
      h(
        "p",
        { class: "logo book__logo" },
        h("span", { class: "logo__name" }, brand),
        h("span", { class: "logo__tag", lang: "it" }, i18n.t("common.brandTagline")),
      ),
      h("h2", { class: "book__title" }, bookTitle(week, i18n)),
      h("p", { class: "book__by" }, i18n.t("book.by", { chef })),
      ornament(),
      h("p", { class: "book__when" }, i18n.t("book.when", { date: formatIsoDate(week.date, i18n.locale), time: week.start })),
      h("p", { class: "book__count-dishes" }, dishes === 1 ? i18n.t("book.dishesOne") : i18n.t("book.dishesOther", { n: dishes })),
      h("p", { class: "book__hint" }, i18n.t("book.hint")),
    ),
  );
}

function photoNode(dish: SnapshotDish, eager: boolean, failed: ReadonlySet<string>): VNode {
  const src = dish.photo && !failed.has(dish.photo.full) ? dish.photo.full : null;
  // La inicial del plato en una lámina: se ve si no tiene foto, si no carga y mientras carga.
  const initial = Array.from(dish.name.trim())[0]?.toLocaleUpperCase() ?? "";
  return h(
    "figure",
    { class: src ? "book__photo" : "book__photo book__photo--empty" },
    h("span", { class: "book__photo-mark", "aria-hidden": "true" }, initial),
    // Decorativa (alt vacío): el nombre del plato va abajo. Sin arrastrarla: el gesto pasa de página.
    src &&
      h("img", {
        class: "book__img",
        src,
        alt: "",
        loading: eager ? "eager" : "lazy",
        decoding: "async",
        draggable: "false",
      }),
  );
}

function dishNode(ctx: Ctx, index: number, label: string, dish: SnapshotDish, position: number): VNode {
  const { i18n, content } = ctx.input;
  const view = pagePresentation(index, ctx.input.page);
  const id = bookPageId(index);
  const ingredients = dish.ingredients ?? [];
  const portions = dish.portions === 1 ? i18n.t("reservation.portionsOne") : i18n.t("reservation.portionsOther", { n: dish.portions });
  return pageNode(
    ctx,
    index,
    label,
    "dish",
    photoNode(dish, view.eager, ctx.input.failedPhotos ?? new Set()),
    h(
      "div",
      { class: "book__body" },
      h("p", { class: "book__eyebrow" }, i18n.t("book.dishOf", { n: position, count: content.dishes.length })),
      h("h2", { class: "book__dish", lang: ctx.lang }, dish.name),
      dish.description && h("p", { class: "book__desc", lang: ctx.lang }, dish.description),
      ornament(),
      ingredients.length > 0 &&
        h(
          "section",
          { class: "book__part", "aria-labelledby": `${id}-ingredients` },
          h("h3", { class: "book__label", id: `${id}-ingredients` }, i18n.t("book.ingredients")),
          h(
            "ul",
            { class: "book__ingredients", lang: ctx.lang },
            ingredients.map((name) => h("li", { class: "book__ingredient" }, name)),
          ),
        ),
      h(
        "section",
        { class: "book__part", "aria-labelledby": `${id}-allergens` },
        h("h3", { class: "book__label", id: `${id}-allergens` }, i18n.t("book.allergens")),
        dish.allergens.length === 0
          ? h("p", { class: "book__none" }, i18n.t("reservation.allergensNone"))
          : h(
              "ul",
              { class: "book__badges" },
              dish.allergens.map((allergen) => h("li", { class: "book__badge" }, i18n.t(`allergens.${allergen}`))),
            ),
      ),
      h(
        "p",
        { class: "book__facts" },
        h("span", { class: "book__portions" }, portions),
        dish.diet && [" ", h("span", { class: "book__badge book__badge--diet" }, i18n.t(`diets.${dish.diet}`))],
      ),
    ),
  );
}

/** Lo que dice la última página y su botón, según lo que se puede hacer en la semana. */
const CLOSING: Readonly<Record<ClosingKind, { text: MessageKey; button: MessageKey }>> = {
  answer: { text: "book.closingAnswer", button: "book.closingAnswerButton" },
  quote: { text: "book.closingQuote", button: "book.closingQuoteButton" },
  confirmed: { text: "book.closingConfirmed", button: "book.closingBack" },
  changes: { text: "book.closingChanges", button: "book.closingBack" },
  done: { text: "book.closingDone", button: "book.closingBack" },
};

function closingNode(ctx: Ctx, index: number, label: string): VNode {
  const { i18n, chef, week, closing } = ctx.input;
  const texts = CLOSING[closing];
  const primary = closing === "answer" || closing === "quote";
  return pageNode(
    ctx,
    index,
    label,
    "closing",
    h(
      "div",
      { class: "book__closing" },
      ornament(),
      h("h2", { class: "book__title" }, i18n.t("book.closingTitle")),
      h("p", { class: "book__closing-text" }, i18n.t(texts.text, { chef, date: formatIsoDate(week.date, i18n.locale), time: week.start })),
      h(
        "div",
        { class: "actions book__actions" },
        h("button", { class: primary ? "btn btn--primary" : "btn btn--ghost", type: "button", "data-book": "cta" }, i18n.t(texts.button)),
        h("button", { class: "btn btn--ghost", type: "button", "data-book": "restart" }, i18n.t("book.restart")),
      ),
    ),
  );
}

function arrowNode(id: string, action: "prev" | "next", label: string, disabled: boolean): VNode {
  return h(
    "button",
    {
      class: `book__arrow book__arrow--${action}`,
      type: "button",
      id,
      "data-book": action,
      "aria-label": label,
      // aria-disabled y no disabled: en un borde el botón conserva el foco (no se pierde en la página).
      "aria-disabled": disabled ? "true" : null,
    },
    h("span", { class: "book__chevron", "aria-hidden": "true" }),
  );
}

/** El libro abierto en input.page (que se acomoda entre la tapa y la última). */
export function bookTree(input: BookInput): VNode {
  const { i18n, content, week } = input;
  const pages = bookPages(content);
  const count = pages.length;
  const page = clampPage(input.page, count);
  const ctx: Ctx = { input: { ...input, page }, lang: content.locale === i18n.lang ? null : content.locale };
  const labels = pages.map((item, index) => pageLabel(index, count, pageName(item, content, i18n), i18n));
  const title = bookTitle(week, i18n);

  return h(
    "div",
    { class: "book", id: BOOK_ID, role: "dialog", "aria-modal": "true", "aria-label": title },
    h(
      "div",
      { class: "book__frame" },
      h(
        "div",
        { class: "book__bar" },
        h("p", { class: "book__bar-title" }, title),
        h(
          "button",
          { class: "book__close", type: "button", id: BOOK_CLOSE_ID, "data-book": "close", "aria-label": i18n.t("book.close") },
          h("span", { class: "book__cross", "aria-hidden": "true" }),
        ),
      ),
      h(
        "section",
        { class: "book__viewport", id: BOOK_VIEWPORT_ID, "aria-roledescription": i18n.t("book.carousel"), "aria-label": title },
        pages.map((item, index) => {
          const label = labels[index] ?? "";
          if (item.kind === "cover") return coverNode(ctx, index, label);
          if (item.kind === "closing") return closingNode(ctx, index, label);
          const dish = content.dishes[item.dish];
          return dish ? dishNode(ctx, index, label, dish, item.dish + 1) : null;
        }),
      ),
      h(
        "div",
        { class: "book__nav" },
        arrowNode(BOOK_PREV_ID, "prev", i18n.t("book.prev"), !canGo(page, count, "prev")),
        h(
          "div",
          { class: "book__progress" },
          h("p", { class: "book__count", id: BOOK_COUNT_ID, "aria-hidden": "true" }, counterText(page, count, i18n)),
          showDots(count) &&
            h(
              "div",
              { class: "book__dots", role: "group", "aria-label": i18n.t("book.pages") },
              labels.map((label, index) =>
                h("button", {
                  class: "book__dot",
                  type: "button",
                  id: bookDotId(index),
                  "data-book": "go",
                  "data-page": index,
                  "aria-label": label,
                  "aria-current": index === page ? "true" : null,
                }),
              ),
            ),
        ),
        arrowNode(BOOK_NEXT_ID, "next", i18n.t("book.next"), !canGo(page, count, "next")),
      ),
      // Lo que se anuncia al pasar de página (lo escribe view.ts).
      h("p", { class: "visually-hidden", id: BOOK_LIVE_ID, role: "status", "aria-live": "polite" }),
    ),
  );
}
