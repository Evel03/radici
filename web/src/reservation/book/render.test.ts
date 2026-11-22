import { describe, expect, it } from "vitest";
import type { MenuContent } from "../../../../supabase/functions/_shared/client_link.ts";
import type { Lang } from "../../i18n/core.ts";
import { find, findAll, textOf, toHtml, type VNode } from "../../lib/vdom.ts";
import { i18nFor } from "../../request/fixtures.ts";
import { PHOTO, content, week } from "../fixtures.ts";
import {
  BOOK_ID,
  BOOK_LIVE_ID,
  BOOK_NEXT_ID,
  BOOK_PREV_ID,
  bookPageId,
  bookTitle,
  bookTree,
  counterText,
  pageAttrs,
  pageLabel,
  pageName,
  type BookInput,
} from "./render.ts";
import { bookPages, type ClosingKind } from "./state.ts";

/** El menú del libro: la lasagne con foto e ingredientes, el minestrone sin foto (ni ingredientes: una foto de antes). */
function bookContent(overrides: Partial<MenuContent> = {}): MenuContent {
  const base = content();
  const [lasagne, minestrone] = base.dishes;
  return {
    ...base,
    dishes: [{ ...lasagne!, ingredients: ["Sfoglia all'uovo", "Ragù di manzo", "Besciamella"] }, minestrone!],
    ...overrides,
  };
}

function render(options: Partial<BookInput> & { lang?: Lang } = {}): VNode {
  const { lang = "it", ...input } = options;
  return bookTree({
    week: week(),
    content: bookContent(),
    page: 0,
    i18n: i18nFor(lang),
    chef: "Evelyn",
    brand: "Radici",
    closing: "answer",
    ...input,
  });
}

const byId = (tree: VNode, id: string): VNode | null => find(tree, (node) => node.attrs["id"] === id);
const byClass = (tree: VNode, cls: string): VNode[] => findAll(tree, (node) => (node.attrs["class"] ?? "").split(" ").includes(cls));
const page = (tree: VNode, index: number): VNode => {
  const found = byId(tree, bookPageId(index));
  if (!found) throw new Error(`falta la página ${index}`);
  return found;
};

describe("el libro: un diálogo con un carrusel de páginas", () => {
  const tree = render();

  it("diálogo modal con el nombre del libro; el carrusel y cada página (su hoja) con su rol descripto y su nombre", () => {
    expect(tree.attrs).toMatchObject({ id: BOOK_ID, role: "dialog", "aria-modal": "true", "aria-label": "Il menù della settimana 1" });
    const viewport = find(tree, (node) => node.tag === "section" && node.attrs["class"] === "book__viewport");
    expect(viewport?.attrs).toMatchObject({ "aria-roledescription": "carosello", "aria-label": "Il menù della settimana 1" });
    const sheets = byClass(tree, "book__sheet");
    expect(sheets.map((item) => item.attrs["aria-label"])).toEqual([
      "1 di 4: copertina",
      "2 di 4: Lasagne al ragù",
      "3 di 4: Minestrone",
      "4 di 4: ultima pagina",
    ]);
    // La hoja tiene su scroll: entra en el orden del Tab (con ↑ ↓ se lee una página larga) y recibe el foco.
    for (const item of sheets) expect(item.attrs).toMatchObject({ role: "group", "aria-roledescription": "pagina", tabindex: "0" });
    expect(byClass(tree, "book__page").every((item) => item.attrs["role"] === undefined)).toBe(true);
  });

  it("solo la página actual se lee y se toca; la siguiente queda lista; las demás, con hidden (sus fotos esperan)", () => {
    expect(page(tree, 0).attrs["class"]).toBe("book__page is-current book__page--cover");
    expect(page(tree, 0).attrs["aria-hidden"]).toBeUndefined();
    expect(page(tree, 0).attrs["inert"]).toBeUndefined();
    expect(page(tree, 1).attrs).toMatchObject({ "aria-hidden": "true", inert: "" });
    expect(page(tree, 1).attrs["hidden"]).toBeUndefined();
    expect(page(tree, 2).attrs).toMatchObject({ "aria-hidden": "true", inert: "", hidden: "" });
    expect(pageAttrs(2, 1)).toEqual({ class: "book__page", hidden: false, "aria-hidden": "true", inert: true });
  });

  it("la tapa: la marca, «Il menù della settimana k», de quién, el día y la llegada, cuántos platos y cómo se hojea", () => {
    const cover = page(tree, 0);
    expect(textOf(byClass(cover, "logo__name")[0] ?? "")).toBe("Radici");
    expect(byClass(cover, "logo__tag")[0]?.attrs["lang"]).toBe("it");
    expect(textOf(byClass(cover, "book__title")[0] ?? "")).toBe("Il menù della settimana 1");
    expect(textOf(byClass(cover, "book__by")[0] ?? "")).toBe("di Evelyn");
    expect(textOf(byClass(cover, "book__when")[0] ?? "")).toBe("lunedì 1 marzo 2027 · arrivo alle 10:00");
    expect(textOf(byClass(cover, "book__count-dishes")[0] ?? "")).toBe("2 piatti");
    expect(textOf(byClass(cover, "book__hint")[0] ?? "")).toContain("un piatto per pagina");
  });

  it("una reserva de una semana: «Il tuo menù»; un plato: «1 piatto»", () => {
    const single = render({ week: week({ week: 1, weeks: 1 }), content: bookContent({ dishes: [bookContent().dishes[0]!] }) });
    expect(single.attrs["aria-label"]).toBe("Il tuo menù");
    expect(textOf(byClass(single, "book__count-dishes")[0] ?? "")).toBe("1 piatto");
  });

  it("abajo: las flechas (deshabilitadas en los bordes, con aria-disabled), «1 / 4», los puntos y la región en vivo", () => {
    expect(byId(tree, BOOK_PREV_ID)?.attrs).toMatchObject({ "aria-label": "Pagina precedente", "aria-disabled": "true", "data-book": "prev" });
    expect(byId(tree, BOOK_NEXT_ID)?.attrs["aria-disabled"]).toBeUndefined();
    expect(textOf(byClass(tree, "book__count")[0] ?? "")).toBe("1 / 4");
    const dots = byClass(tree, "book__dot");
    expect(dots.map((dot) => dot.attrs["aria-label"])).toEqual(byClass(tree, "book__sheet").map((item) => item.attrs["aria-label"]));
    expect(dots.map((dot) => dot.attrs["aria-current"] ?? null)).toEqual(["true", null, null, null]);
    expect(byId(tree, BOOK_LIVE_ID)?.attrs).toMatchObject({ role: "status", "aria-live": "polite" });
    expect(byId(tree, "book-close")?.attrs["aria-label"]).toBe("Chiudi il menù");

    const last = render({ page: 3 });
    expect(byId(last, BOOK_PREV_ID)?.attrs["aria-disabled"]).toBeUndefined();
    expect(byId(last, BOOK_NEXT_ID)?.attrs["aria-disabled"]).toBe("true");
    expect(textOf(byClass(last, "book__count")[0] ?? "")).toBe("4 / 4");
  });

  it("con muchas páginas, sin puntos (no entran en el teléfono): queda «2 / 12»", () => {
    const many = bookContent({ dishes: Array.from({ length: 10 }, (_, i) => ({ ...bookContent().dishes[1]!, name: `Piatto ${i + 1}` })) });
    const tree12 = render({ content: many, page: 1 });
    expect(byClass(tree12, "book__dot")).toEqual([]);
    expect(textOf(byClass(tree12, "book__count")[0] ?? "")).toBe("2 / 12");
  });

  it("una página fuera de rango se acomoda (la última)", () => {
    expect(render({ page: 99 }).children.length).toBeGreaterThan(0);
    expect(page(render({ page: 99 }), 3).attrs["class"]).toContain("is-current");
  });
});

describe("la página de un plato", () => {
  it("la foto grande (la URL completa), decorativa y sin arrastrar; la de la página actual y la siguiente se cargan ya", () => {
    const tree = render({ page: 1 });
    const img = find(page(tree, 1), (node) => node.tag === "img");
    expect(img?.attrs).toEqual({ class: "book__img", src: PHOTO.full, alt: "", loading: "eager", decoding: "async", draggable: "false" });
    const fromCover = find(page(render({ page: 0 }), 1), (node) => node.tag === "img");
    expect(fromCover?.attrs["loading"]).toBe("eager");
    // Dos páginas más allá: lazy (y la página va con hidden).
    const coverTree = render({ content: bookContent({ dishes: [bookContent().dishes[1]!, bookContent().dishes[0]!] }), page: 0 });
    expect(find(page(coverTree, 2), (node) => node.tag === "img")?.attrs["loading"]).toBe("lazy");
  });

  it("nombre, descripción, los ingredientes (solo los nombres), los alérgenos con su nombre, porciones y la dieta", () => {
    const lasagne = page(render({ page: 1 }), 1);
    expect(textOf(byClass(lasagne, "book__eyebrow")[0] ?? "")).toBe("Piatto 1 di 2");
    expect(textOf(byClass(lasagne, "book__dish")[0] ?? "")).toBe("Lasagne al ragù");
    expect(textOf(byClass(lasagne, "book__desc")[0] ?? "")).toBe("Ragù di manzo e besciamella.");
    expect(byClass(lasagne, "book__ingredient").map(textOf)).toEqual(["Sfoglia all'uovo", "Ragù di manzo", "Besciamella"]);
    expect(byClass(lasagne, "book__label").map(textOf)).toEqual(["Ingredienti", "Allergeni"]);
    expect(byClass(lasagne, "book__badge").map(textOf)).toEqual(["glutine", "uova", "latte e derivati"]);
    expect(textOf(byClass(lasagne, "book__portions")[0] ?? "")).toBe("6 porzioni");
    // Cada sección con su título (para los lectores de pantalla).
    const ingredients = find(lasagne, (node) => node.tag === "section" && node.attrs["aria-labelledby"] === `${bookPageId(1)}-ingredients`);
    expect(ingredients).not.toBeNull();
  });

  it("sin foto: la lámina con la inicial; sin ingredientes (una foto de antes del libro): sin esa sección; vegano y sin alérgenos", () => {
    const minestrone = page(render({ page: 2 }), 2);
    const figure = find(minestrone, (node) => node.tag === "figure");
    expect(figure?.attrs["class"]).toBe("book__photo book__photo--empty");
    expect(textOf(byClass(minestrone, "book__photo-mark")[0] ?? "")).toBe("M");
    expect(byClass(minestrone, "book__photo-mark")[0]?.attrs["aria-hidden"]).toBe("true");
    expect(find(minestrone, (node) => node.tag === "img")).toBeNull();
    expect(byClass(minestrone, "book__ingredients")).toEqual([]);
    expect(textOf(byClass(minestrone, "book__none")[0] ?? "")).toBe("Nessuno dei 14 allergeni principali");
    expect(textOf(byClass(minestrone, "book__badge--diet")[0] ?? "")).toBe("Vegano");
    expect(textOf(byClass(minestrone, "book__portions")[0] ?? "")).toBe("1 porzione");
    expect(byClass(minestrone, "book__desc")).toEqual([]);
  });

  it("una foto que no cargó: la lámina, sin volver a pedirla", () => {
    const lasagne = page(render({ page: 1, failedPhotos: new Set([PHOTO.full]) }), 1);
    expect(find(lasagne, (node) => node.tag === "img")).toBeNull();
    expect(find(lasagne, (node) => node.tag === "figure")?.attrs["class"]).toBe("book__photo book__photo--empty");
    expect(textOf(byClass(lasagne, "book__photo-mark")[0] ?? "")).toBe("L");
  });

  it("todo lo que llega de la función va como texto (escapado), nunca como HTML", () => {
    const hostile = bookContent({
      dishes: [
        {
          name: '<img src=x onerror="alert(1)">',
          description: "<b>Ragù</b> & besciamella",
          allergens: [],
          diet: null,
          portions: 2,
          photo: null,
          ingredients: ["<script>alert(1)</script>", "Sale & pepe"],
        },
      ],
    });
    const html = toHtml(render({ content: hostile, page: 1 }));
    expect(html).not.toContain("<script>");
    expect(html).not.toContain("<b>");
    expect(html).not.toContain("<img src=x");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(html).toContain("Sale &amp; pepe");
    expect(html).toContain("&lt;b&gt;Ragù&lt;/b&gt; &amp; besciamella");
  });

  it("con la página en otro idioma que el envío, los textos del envío llevan su lang", () => {
    const tree = render({ lang: "es", page: 1 });
    const lasagne = page(tree, 1);
    expect(byClass(lasagne, "book__dish")[0]?.attrs["lang"]).toBe("it");
    expect(byClass(lasagne, "book__ingredients")[0]?.attrs["lang"]).toBe("it");
    expect(textOf(byClass(lasagne, "book__label")[0] ?? "")).toBe("Ingredientes");
    expect(byClass(page(render({ page: 1 }), 1), "book__dish")[0]?.attrs["lang"]).toBeUndefined();
  });
});

describe("la última página: vuelve a lo que se puede hacer en la semana", () => {
  const closing = (kind: ClosingKind, lang: Lang = "it"): { text: string; buttons: VNode[] } => {
    const node = page(render({ closing: kind, lang, page: 3 }), 3);
    return { text: textOf(byClass(node, "book__closing-text")[0] ?? ""), buttons: findAll(node, (item) => item.tag === "button") };
  };

  it("por confirmar: confirmar o pedir cambios en la semana (donde también están la lista y la nota)", () => {
    const { text, buttons } = closing("answer");
    expect(text).toBe("Ti piace? Torna alla settimana per confermarlo o chiedere dei cambi: lì trovi anche la lista della spesa e la nota di Evelyn.");
    expect(buttons.map((button) => [textOf(button), button.attrs["data-book"], button.attrs["class"]])).toEqual([
      ["Vai alla conferma", "cta", "btn btn--primary"],
      ["Ricomincia dalla copertina", "restart", "btn btn--ghost"],
    ]);
  });

  it("con un presupuesto abierto: aceptarlo; ya contestado o cocinado: solo volver a la reserva", () => {
    expect(closing("quote").text).toContain("accetta il preventivo di Evelyn");
    expect(textOf(closing("quote").buttons[0] ?? "")).toBe("Vai al preventivo");
    expect(closing("confirmed").text).toBe("Hai confermato questo menù: Evelyn arriva lunedì 1 marzo 2027 alle 10:00.");
    expect(closing("changes").text).toBe("Hai chiesto dei cambi: Evelyn ti manderà il menù di nuovo.");
    expect(closing("done").text).toContain("ha già cucinato questo menù");
    for (const kind of ["confirmed", "changes", "done"] as const) {
      const [back] = closing(kind).buttons;
      expect([textOf(back ?? ""), back?.attrs["class"]]).toEqual(["Torna alla prenotazione", "btn btn--ghost"]);
    }
  });

  it("en español y en inglés", () => {
    expect(closing("answer", "es").text).toContain("Vuelve a la semana para confirmarlo o pedir cambios");
    expect(closing("confirmed", "es").text).toBe("Confirmaste este menú: Evelyn llega el lunes, 1 de marzo de 2027 a las 10:00.");
    expect(textOf(closing("answer", "en").buttons[0] ?? "")).toBe("Go to confirm");
    expect(textOf(closing("answer", "es").buttons[0] ?? "")).toBe("Ir a confirmar");
    expect(closing("confirmed", "en").text).toBe("You confirmed this menu: Evelyn arrives on Monday 1 March 2027 at 10:00.");
  });
});

describe("los textos que usa view.ts", () => {
  it("el nombre del libro, de cada página, «2 di 7» y «2 / 7», en los tres idiomas", () => {
    const pages = bookPages(bookContent());
    expect(bookTitle({ week: 2, weeks: 3 }, i18nFor("it"))).toBe("Il menù della settimana 2");
    expect(bookTitle({ week: 2, weeks: 3 }, i18nFor("es"))).toBe("El menú de la semana 2");
    expect(bookTitle({ week: 2, weeks: 3 }, i18nFor("en"))).toBe("The menu for week 2");
    expect(pages.map((item) => pageName(item, bookContent(), i18nFor("en")))).toEqual(["cover", "Lasagne al ragù", "Minestrone", "last page"]);
    expect(pageLabel(1, 4, "Lasagne", i18nFor("es"))).toBe("2 de 4: Lasagne");
    expect(counterText(1, 4, i18nFor("en"))).toBe("2 / 4");
  });
});
